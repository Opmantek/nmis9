#!/bin/bash

set -e

NMIS_HOME=/usr/local/nmis9
NMIS_LOG=${NMIS_HOME}/logs/nmis.log
NMIS_USER=nmis
NMIS_GROUP=nmis

# shellcheck disable=SC1091
source /etc/profile

setup() {
  # Create data directories
  for d in assets var/nmis_system models-custom database conf logs htdocs/cache htdocs/nmis9
  do
    dir=${NMIS_HOME}/${d}

    if [[ "$(stat --format='%U:%G' "$dir")" != 'nmis:nmis' ]] && [[ -w "$dir" ]]; then
      chown -R nmis:nmis "$dir" || echo "Warning can not change owner to nmis:nmis"
    fi
  done

  # fake a couple of aseets dirs for mojo
 ln -s "${NMIS_HOME}"/menu "${NMIS_HOME}"/assets/menu9 || echo "Could not symlink menu9 dir"
 ln -s "${NMIS_HOME}"/htdocs/cache "${NMIS_HOME}"/htdocs/nmis9/cache || echo "Could not symlink cache dir"

  NODESIMPORT="${NMIS_HOME}"/import
  #check if there are any nodes to import
  echo "seeing if there are any nodes to import from ${NODESIMPORT}"
  if [ -d "${NODESIMPORT}" ]; then
    for filename in "$NODESIMPORT"/*.json; do
     echo "maybe a filename? $filename"
      if [ -e "$filename" ]; then
        echo "creating node from file: ${filename}"
        /usr/local/nmis9/admin/node_admin.pl act=import file="${filename}" || echo "could not create node"
      fi
    done
  fi

  # OMK-12687: containers never run installer_hooks, so generate a unique
  # auth_web_key on first boot. Idempotent: only placeholder/old-fallback/unset
  # keys are replaced, so a restart never rotates a good key (conf is a volume).
  CONFIG="${NMIS_HOME}/conf/Config.nmis"
  # the deny-set, the effective-key read and key generation live in one place,
  # shared with installer_hooks/11-postcopy-authkey. dockerfile does COPY . into
  # NMIS_HOME, so installer_hooks/ is present in the image.
  AUTHKEY_LIB="${NMIS_HOME}/installer_hooks/common_authkey.sh"
  if [ ! -f "$CONFIG" ]; then
    : # nothing to check yet
  elif [ ! -r "$AUTHKEY_LIB" ]; then
    echo "WARNING: $AUTHKEY_LIB is missing; cannot verify auth_web_key for this container."
  else
    # shellcheck disable=SC1090
    . "$AUTHKEY_LIB"
    # non-zero is ordinary control flow here, and this script runs under set -e,
    # so the status has to be captured with && / || rather than a bare $?.
    nmis_authkey_classify "${NMIS_HOME}" && AUTHKEY_CLASS=0 || AUTHKEY_CLASS=$?
    case "$AUTHKEY_CLASS" in
    0)
      : # already a unique key, leave it alone
      ;;
    3)
      # the read failed, so a secure key is indistinguishable from an insecure
      # one. Generating here would rotate a good site key out of the conf volume,
      # invalidating every session, so change nothing.
      echo "WARNING: could not read auth_web_key (config loader failed); leaving $CONFIG unchanged."
      ;;
    1)
      # ENV supplies an insecure key. Writing the file would not take effect
      # and would create the overlap, so tell the operator to fix the env var.
      echo "WARNING: NMIS_AUTH_WEB_KEY is insecure or empty. Set it to a unique secret in the environment."
      ;;
    2)
      NEWKEY="$(nmis_authkey_generate)" || NEWKEY=""
      if [ -z "$NEWKEY" ]; then
        echo "WARNING: could not generate an auth_web_key; set it manually in $CONFIG"
      # conf/ is a volume kept nmis:nmis (see chown loop above), and the web
      # UI writes Config.nmis at runtime as the nmis user (nmis_frontend
      # runs the daemons via su), so patch as nmis to preserve that ownership.
      elif su -s /bin/sh "${NMIS_USER}" -c "${NMIS_HOME}/admin/patch_config.pl ${CONFIG} /authentication/auth_web_key=${NEWKEY}" >/dev/null 2>&1; then
        echo "Generated a unique auth_web_key for this container."
      else
        echo "WARNING: failed to set auth_web_key; set it manually in $CONFIG"
      fi
      ;;
    esac
  fi

  # Remove pid file that gets saved in /var mount, otherwise stops nmisd from running when starting the container
  rm -f "${NMIS_HOME}/var/nmis_system/nmisd.pid"

  # generate-password=f: nmis_frontend below su's nmisd to ${NMIS_USER}, which
  # could neither read nor remove an invented password's root-owned file. Refuse
  # to start rather than strand one. Password arrives via env, so not in ps.
  if ! /usr/local/nmis9/bin/nmis-cli act=seed-htpasswd-password user=nmis \
      file="${NMIS_HOME}/conf/users.dat" reveal=none generate-password=f; then
    echo "ERROR: no usable nmis administrator password." >&2
    echo "  Set NMIS_ADMIN_PASSWORD in your .env (compose passes it in as" >&2
    echo "  NMIS9_ADMIN_PASSWORD), or point NMIS9_ADMIN_PASSWORD_FILE at a" >&2
    echo "  docker secret, then start again." >&2
    exit 1
  fi
}

provision_master_key() {
  # an operator-supplied key (NMIS_MASTER_KEY_FILE) makes the generated
  # default-path key dead weight; skip provisioning entirely
  if [ -n "${NMIS_MASTER_KEY_FILE:-}" ]; then
    echo "NMIS_MASTER_KEY_FILE is set; skipping default master key provisioning."
    return 0
  fi
  # OMK-12827 Slice C: containers never run installer_hooks, so provision the
  # encryption-of-secrets master key on first boot, into the nmis_master_key
  # volume (see compose.yaml). Shared code with the installer hook and the
  # dev entrypoint. Runs BEFORE setup_db: setup_mongodb.pl decrypts
  # db_password, and provisioning first also keeps _make_seed's lazy root
  # creation (wrong ownership for this image) out of play.
  MASTERKEY_LIB="${NMIS_HOME}/installer_hooks/common_masterkey.sh"
  if [ ! -r "$MASTERKEY_LIB" ]; then
    echo "WARNING: $MASTERKEY_LIB is missing; cannot provision a master key for this container." >&2
    return 0
  fi
  # shellcheck disable=SC1090
  . "$MASTERKEY_LIB"
  MASTERKEY_WAS_ABSENT=0
  [ -e "$NMIS_MASTERKEY_DEFAULT_FILE" ] || MASTERKEY_WAS_ABSENT=1
  if [ "$MASTERKEY_WAS_ABSENT" -eq 1 ]; then
    # a crash on a previous boot can leave the provisioning temp file behind
    # in the (persistent) volume, and its noclobber write would then fail on
    # every boot. No key exists yet, so removing the temp destroys nothing.
    rm -f "${NMIS_MASTERKEY_DEFAULT_FILE}.tmp."* 2>/dev/null || :
  fi
  # every command guarded: this script runs under set -e, and provisioning
  # failure must warn, not kill the boot (runtime fails closed and the
  # "Encryption of secrets" selftest reports it in the GUI).
  # Owner is nmis: this image has no apache; nmisd and the nmisx web daemon
  # run as nmis via su and must be able to read the key.
  if nmis_masterkey_provision "${NMIS_USER}"; then
    if [ "$MASTERKEY_WAS_ABSENT" -eq 1 ]; then
      echo "Generated a master key for this container (${NMIS_MASTERKEY_DEFAULT_FILE})."
      master_key_swap_warning
    else
      master_key_existing_owner_warning
    fi
  else
    echo "WARNING: could not provision a master key; encryption of secrets cannot run until ${NMIS_MASTERKEY_DEFAULT_FILE} exists and is readable by ${NMIS_USER}." >&2
  fi
}

master_key_swap_warning() {
  # OMK-12827 Slice C: a FRESH key beside a config that already carries
  # encrypted ('!!') values means those values were encrypted under a
  # previous key this container no longer has - the pre-Slice-C upgrade,
  # where the old key lived in the writable layer and the new
  # nmis_master_key volume started empty. Decryption fails closed; nothing
  # is wiped. Cheap proxy only: encrypted node secrets in Mongo are not
  # visible from shell at boot; those surface via the "Encryption of
  # secrets" selftest banner.
  # the runtime ignores the generated key when NMIS_MASTER_KEY_FILE points at
  # an operator-supplied key, so a fresh generated key implies nothing then
  [ -z "${NMIS_MASTER_KEY_FILE:-}" ] || return 0
  MK_CONFIG="${NMIS_HOME}/conf/Config.nmis"
  [ -f "$MK_CONFIG" ] || return 0
  if grep -q "'!!" "$MK_CONFIG"; then
    echo "WARNING: ############################################################" >&2
    echo "WARNING: conf/Config.nmis contains encrypted ('!!') values, but this" >&2
    echo "WARNING: boot just GENERATED A NEW master key. Those values were" >&2
    echo "WARNING: encrypted under a previous key and cannot be read with the" >&2
    echo "WARNING: new one (reads fail closed; nothing is deleted)." >&2
    echo "WARNING: Recovery: restore the previous master.key into the" >&2
    echo "WARNING: nmis_master_key volume, replacing the newly generated" >&2
    echo "WARNING: file, then restart the container." >&2
    echo "WARNING: The previous key is in the OLD container's writable layer:" >&2
    echo "WARNING:   docker cp <old-container>:/usr/local/etc/firstwave/master.key ." >&2
    echo "WARNING: (run BEFORE removing the old container), then copy it into" >&2
    echo "WARNING: this container's /usr/local/etc/firstwave/ and restart." >&2
    echo "WARNING: After copying the key in, make it readable by nmis inside" >&2
    echo "WARNING: this container: chown nmis:nmis and chmod 0440 the file." >&2
    echo "WARNING: A boot never modifies an existing key." >&2
    echo "WARNING: If the old container is already removed and no backup of" >&2
    echo "WARNING: master.key exists, those values are unrecoverable;" >&2
    echo "WARNING: re-enter the affected secrets." >&2
    echo "WARNING: ############################################################" >&2
  fi
}

master_key_existing_owner_warning() {
  # OMK-12827 Slice C: an existing key is never modified, so a wrongly-owned
  # one (e.g. a root-owned docker cp restore) stays wrong silently unless we
  # say so. Pure diagnostic: never chowns, never touches the key file; safe
  # under set -e (nmis_masterkey_owner_ok's non-zero return is ordinary
  # control flow here, caught by && / ||).
  MK_OWNER="$(nmis_masterkey_owner_ok "${NMIS_USER}")" && : || {
    echo "WARNING: ${NMIS_MASTERKEY_DEFAULT_FILE} exists but is owned '${MK_OWNER:-unknown}', wanted '${NMIS_USER}:nmis'." >&2
    echo "WARNING: the nmis daemons cannot read it; fix with: chown ${NMIS_USER}:nmis ${NMIS_MASTERKEY_DEFAULT_FILE} && chmod 0440 ${NMIS_MASTERKEY_DEFAULT_FILE}" >&2
  }
}

nmis_frontend() {
  su -s /bin/bash ${NMIS_USER} -c '
    /usr/local/nmis9/bin/nmisd foreground=1 &
    /usr/local/nmis9/script/nmisx daemon -m production -p -l "http://*:8080" &
  '
}

setup_db() {
  yes '' | /usr/local/nmis9/admin/setup_mongodb.pl
}

# Start any services required by NMIS
start_apps() {
  services=("snmpd" "snmptrapd")
  for service in "${services[@]}"; do
    echo "Starting $service daemon..."
    service $service start
    if [ $? -eq 0 ]; then
        echo "$service service started successfully."
    else
        echo "Failed to start $service service."
    fi
  done
}

run() {
  setup
  provision_master_key
  setup_db
  start_apps
  nmis_frontend

  # Tail NMIS out to keep container alive
  sleep 5
  tail -f "${NMIS_LOG}"
}

run "$@"
