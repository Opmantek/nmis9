#!/bin/bash

set -e

NMIS_HOME=/usr/local/nmis9
# Perl lib location seperate from Debian vendor and Debian site perl lib location
# Avoids conflicts between Debian perl and cpanm perl package installations
PERL5LIB=/usr/local/lib/site_perl/lib/perl5:/usr/local/lib/site_perl/lib/perl5/x86_64-linux-gnu

# shellcheck disable=SC1091
source /etc/profile

setup() {
  # Create data directories
  for d in assets var/nmis_system models-custom database conf logs htdocs/nmis9 htdocs/cache
  do
    dir=${NMIS_HOME}/${d}
    [[ -d "${dir}" ]] || mkdir -p "${dir}"    
  done

  # Add base configuration
  for f in Users.nmis users.dat Access.nmis; do
    if [[ ! -e "${NMIS_HOME}/conf/$f" ]]; then
      cp -a "${NMIS_HOME}/conf-default/$f" "${NMIS_HOME}/conf/$f"
    fi
  done

  if [[ ! -e "${NMIS_HOME}/conf/Config.nmis" ]]; then
    cp "${NMIS_HOME}/conf-default/docker/Config.nmis.docker" "${NMIS_HOME}/conf/Config.nmis"
  fi

  # after the Config.nmis copy above, so nmis-cli loads the container's config.
  # generate-password=f for the same reason as the production entrypoint.
  # .env-dev carries a value, so this normally just works.
  if ! "${NMIS_HOME}/bin/nmis-cli" act=seed-htpasswd-password user=nmis \
      file="${NMIS_HOME}/conf/users.dat" reveal=none generate-password=f; then
    echo "ERROR: no usable nmis administrator password." >&2
    echo "  Set NMIS_ADMIN_PASSWORD in docker-dev/.env-dev and start again." >&2
    exit 1
  fi

  # OMK-12687: containers never run installer_hooks, so generate a unique
  # auth_web_key on first boot. Idempotent: only placeholder/old-fallback/unset
  # keys are replaced, so a restart never rotates a good key (conf is a volume).
  CONFIG="${NMIS_HOME}/conf/Config.nmis"
  # the deny-set, the effective-key read and key generation live in one place,
  # shared with installer_hooks/11-postcopy-authkey.
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
      # dev: setup() never chowns to nmis (only mkdir -p) and dev_user_map
      # re-chowns the whole tree to the host-mapped dev user afterwards, so
      # patch as whoever is running this script (root) rather than nmis.
      elif "${NMIS_HOME}/admin/patch_config.pl" "$CONFIG" "/authentication/auth_web_key=$NEWKEY" >/dev/null 2>&1; then
        echo "Generated a unique auth_web_key for this container."
      else
        echo "WARNING: failed to set auth_web_key; set it manually in $CONFIG"
      fi
      ;;
    esac
  fi

  # fake a couple of assets dirs for mojo
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

  # Remove pid file that gets saved in /var mount, otherwise stops nmisd from running when starting the container
  rm -f /usr/local/nmis9/var/nmis_system/nmisd.pid
}


nmis_frontend() {
  set -m
    /usr/local/nmis9/bin/nmisd foreground=1 debug=1 &
    /usr/bin/morbo /usr/local/nmis9/script/nmisx daemon -m development -p -l "http://*:8080" &
}


setup_db() {
  yes '' | /usr/local/nmis9/admin/setup_mongodb.pl
}

dev_user_map() {
  group="$(getent group "$DEV_GID" | cut -d: -f1)"
  user="$(getent passwd "$DEV_UID" | cut -d: -f1)"

  if [[ -n "$group" ]]; then
    DEV_GROUP="$group"
  else
    groupadd -g "$DEV_GID" dev
    DEV_GROUP="dev"
  fi

  if [[ -n "$user" ]]; then
    DEV_USER="$user"
  else
    useradd -m -u "$DEV_UID" -g "${DEV_GROUP}" -s /bin/bash dev
    DEV_USER="dev"
  fi

  find "$NMIS_HOME" \
    -path "$NMIS_HOME/.git" -prune -o \
    -exec chown "$DEV_UID:$DEV_GID" {} +
}

provision_master_key() {
  # OMK-12827 Slice B: dev/CI-only master key so encryption-of-secrets work
  # and the dev daemons can run non-root. Production provisioning is the
  # installer hook (21-postcopy-encryption) or the Slice C entrypoint work.
  # Never touches an existing key. Dev-only liberty: the key is chowned to
  # the dev user so the test suite (DEV_UID) can read it.
  MASTERKEY_LIB="${NMIS_HOME}/installer_hooks/common_masterkey.sh"
  if [[ ! -f "$MASTERKEY_LIB" ]]; then
    echo "WARNING: $MASTERKEY_LIB missing; no master key provisioned for this container."
    return 0
  fi
  # shellcheck disable=SC1090
  . "$MASTERKEY_LIB"
  # every command guarded: this file runs under set -e, and a bare failing
  # chown/chmod in the then-body would kill the whole entrypoint (statements
  # inside an if body are NOT exempt from errexit)
  if nmis_masterkey_provision www-data; then
    chown "$DEV_UID:$DEV_GID" "$NMIS_MASTERKEY_DEFAULT_DIR" "$NMIS_MASTERKEY_DEFAULT_FILE" \
      || echo "WARNING: could not chown the master key to the dev user."
    chmod 0750 "$NMIS_MASTERKEY_DEFAULT_DIR" || echo "WARNING: could not chmod the master key directory."
    chmod 0440 "$NMIS_MASTERKEY_DEFAULT_FILE" || echo "WARNING: could not chmod the master key file."
  else
    echo "WARNING: could not provision a master key for this container."
  fi
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
  setup_db
  start_apps
  dev_user_map
  provision_master_key
  nmis_frontend
  # Tail something to keep the container alive
  tail -f /dev/null
}

run "$@"