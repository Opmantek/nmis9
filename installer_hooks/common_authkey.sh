# OMK-12687: shared auth_web_key logic for the installer hook and the Docker
# entrypoints. POSIX sh, sourceable from both sh and bash, and free of side
# effects at source time so an entrypoint can pull it in before doing anything.
#
# Why this file exists: the same deny-set and the same "is the effective key
# safe" decision used to be copy-pasted into 11-postcopy-authkey,
# docker-entrypoint.sh and docker-dev/docker-entrypoint-dev.sh. The copies drifted
# (only the hook fail-safed on a failed read), so a container could rotate a good
# site key that the installer would have left alone. One copy, three callers.
#
# The callers are NOT identical, and this file deliberately does not try to make
# them so. They differ in how they log (echolog vs echo), where the install lives
# ($TARGETDIR vs $NMIS_HOME), how they write (direct vs su to the nmis user),
# whether they honour SIMULATE, and whether they may exit. So the shared part
# stops at the decision, and each caller acts on the returned code.
#
# API
#   nmis_authkey_is_insecure <key>
#       returns 0 when <key> must not be used to sign cookies.
#
#   nmis_authkey_classify <basedir>
#       <basedir> is the install root, holding conf/ and lib/.
#       sets NMIS_AUTHKEY_CURRENT   the effective key, "" when unset
#       sets NMIS_AUTHKEY_FROM_ENV  1 when a NMIS_* var maps to auth_web_key
#       returns 0  effective key is already unique, do nothing
#               1  key is insecure and comes from the environment, warn only
#               2  key is insecure and is not from the environment, regenerate
#               3  the read FAILED, state unknown, change nothing
#
#   nmis_authkey_generate
#       prints a 64 hex character key on stdout, returns 1 if it cannot make one.
#
# Calling under `set -e`: a non-zero return is normal control flow here, so use
#   nmis_authkey_classify "$dir" && rc=0 || rc=$?
# rather than a bare call followed by rc=$?, which would abort the script.
#
# No `local` is used, because the installer hook runs under /bin/sh. Function
# scratch variables are prefixed nmis_authkey_ to keep them out of the caller's way.

# the pre-OMK-12687 hardcoded fallback. Anyone with a copy of the old source can
# forge an admin cookie signed with this, so it is treated as a default.
NMIS_AUTHKEY_OLD_FALLBACK='5nJv80DvEr3N/921tdKLk+fCjGzOS5F9IqMFhugxVHIguRC8PJKN4f2JJgcATkhv'

# This set MUST mirror NMISNG::Auth @INSECURE_WEB_KEYS plus the ^CHANGE_ME prefix
# (lib/NMISNG/Auth.pm) and OMK::AuthKeySync @DEFAULT_KEYS. If it falls behind, a
# key that Auth.pm rejects is left in place, and login stays broken with no
# remediation and no message saying why.
nmis_authkey_is_insecure()
{
	case "$1" in
	"" | "Please Change Me!" | "$NMIS_AUTHKEY_OLD_FALLBACK" | "My new Opmantek Secret" \
		| "42 new Opmantek Secrets" | "thisismysecretkey" | CHANGE_ME*)
		return 0 ;;
	esac
	return 1
}

nmis_authkey_classify()
{
	nmis_authkey_basedir="$1"
	NMIS_AUTHKEY_CURRENT=""
	NMIS_AUTHKEY_FROM_ENV=""

	# read the EFFECTIVE key via NMISNG::Util::loadConfTable, the same loader NMIS
	# uses at runtime, so NMIS_* environment overrides are merged in and we test the
	# value the daemons will actually see. A regex over Config.nmis alone misses an
	# operator-supplied NMIS_AUTH_WEB_KEY and would wrongly rotate the file key.
	# Passing an explicit dir avoids the FindBin-in-a-one-liner trap, where a bare
	# perl -e resolves conf from the process cwd and dies in a container.
	#
	# The exit status matters as much as the output. The loader prints an empty
	# string and exits 0 for a genuinely unset key. It prints nothing and exits
	# non-zero when it dies. Conflating the two means regenerating over a good
	# site secret, invalidating every live session and desyncing any shared SSO
	# key, so the status is captured and reported as its own outcome.
	NMIS_AUTHKEY_CURRENT="$(AUTHKEY_CONFDIR="$nmis_authkey_basedir/conf" \
		perl -I "$nmis_authkey_basedir/lib" -MNMISNG::Util \
		-e 'print NMISNG::Util::loadConfTable(dir => $ENV{AUTHKEY_CONFDIR})->{auth_web_key} // ""' 2>/dev/null)"
	nmis_authkey_read_status=$?
	if [ "$nmis_authkey_read_status" -ne 0 ]; then
		NMIS_AUTHKEY_CURRENT=""
		return 3
	fi

	# does the effective key come from a NMIS_* override? If so, a bad value has to
	# be fixed in the environment. Patching the file would not take effect, because
	# ENV wins at runtime, and it would add a file plus ENV overlap that NMIS logs
	# on every config load.
	NMIS_AUTHKEY_FROM_ENV="$(perl -e 'print 1 if grep { /^NMIS_(.+)$/ && lc($1) eq "auth_web_key" } keys %ENV' 2>/dev/null)"

	if ! nmis_authkey_is_insecure "$NMIS_AUTHKEY_CURRENT"; then
		return 0
	fi
	if [ -n "$NMIS_AUTHKEY_FROM_ENV" ]; then
		return 1
	fi
	return 2
}

# generate a strong random 32 byte key as 64 hex characters. Prefer the kernel
# CSPRNG. Fall back to Math::Random::Secure, an installer dependency pulled in by
# 30-pre-dependencies, so a missing /dev/urandom does not leave a site with
# authentication disabled. In a container the fallback is usually absent, in which
# case it simply fails and the caller reports that no key could be generated.
nmis_authkey_generate()
{
	nmis_authkey_new="$(perl -e 'open(my $f,"<:raw","/dev/urandom") or exit 1; read($f,my $b,32)==32 or exit 1; print unpack("H*",$b)' 2>/dev/null)" \
		|| nmis_authkey_new=""
	if [ "${#nmis_authkey_new}" -ne 64 ]; then
		# stdout carries the key, so this diagnostic has to go to stderr. Both
		# callers surface stderr, the installer to its console and Docker to the
		# container log.
		echo "WARNING /dev/urandom unavailable for auth_web_key, falling back to Math::Random::Secure" >&2
		nmis_authkey_new="$(perl -e 'use Math::Random::Secure qw(irand); my $k=""; $k .= sprintf("%08x", irand()) for (1..8); print $k' 2>/dev/null)" \
			|| nmis_authkey_new=""
	fi
	if [ "${#nmis_authkey_new}" -ne 64 ]; then
		return 1
	fi
	printf '%s' "$nmis_authkey_new"
	return 0
}
