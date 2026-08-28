# OMK-12709: shared db_password inspection for the installer hook and the Docker
# entrypoints. POSIX sh, sourceable from both sh and bash, and free of side
# effects at source time so an entrypoint can pull it in before doing anything.
#
# Deliberately modelled on common_authkey.sh (OMK-12687), for the same reason:
# one deny-set and one "is the effective value a shipped default" decision, used
# by three callers, so the copies cannot drift.
#
# IMPORTANT, and the difference from common_authkey.sh: this file does NOT
# generate or write anything, and no caller of it may rotate db_password.
#
# auth_web_key is NMIS's own secret, so rotating it costs at most a re-login.
# db_password is NOT NMIS's own secret. It is the password of `opUserRW`, a
# single MongoDB identity shared with every other OMK product on the host:
# opmojo4's install/opCommon.json carries the same username and the same shipped
# default against the same server, differing only in db_name (omk_shared vs
# nmisng). Both products ship a setup_mongodb.pl that pushes its own config's
# password onto that account, so rotating it from here breaks every OMK app
# immediately, and the next OMK app install rotates it back and breaks NMIS.
# See OMK-12826. The supported fix is a per-product user, not a rotation.
#
# So the job of this file is to make a default credential VISIBLE on every
# install and every container boot, and nothing else.
#
# API
#   nmis_dbpassword_is_insecure <password>
#       returns 0 when <password> is a known shipped default or empty.
#
#   nmis_dbpassword_classify <basedir>
#       <basedir> is the install root, holding conf/ and lib/.
#       sets NMIS_DBPASSWORD_USER     the effective db_username, "" when unset
#       sets NMIS_DBPASSWORD_FROM_ENV 1 when a NMIS_* var maps to db_password
#       returns 0  the effective password is not a known default, nothing to say
#               1  it is a known default AND comes from the environment
#               2  it is a known default and comes from the config file
#               3  the read FAILED, state unknown, say nothing
#
#       The password itself is deliberately NOT exported. Callers only need the
#       verdict, and a secret in a shell variable tends to end up in a log.
#
# After setup_mongodb.pl has migrated NMIS to its own scoped user, db_password is
# no longer a shipped default, so classify returns 0 and this helper stays quiet.
#
# Calling under `set -e`: a non-zero return is normal control flow here, so use
#   nmis_dbpassword_classify "$dir" && rc=0 || rc=$?
# rather than a bare call followed by rc=$?, which would abort the script.
#
# No `local` is used, because the installer hook runs under /bin/sh. Function
# scratch variables are prefixed nmis_dbpassword_ to keep them out of the
# caller's way.

# The published shipped default. Anyone with a copy of the source or the public
# packages knows it, and on a stock install it is also the MongoDB `root`
# password, because setup_mongodb.pl uses db_password for the admin account too.
NMIS_DBPASSWORD_SHIPPED_DEFAULT='op42flow42'

# "example" is the value shipped in conf-default/docker/.env and
# docker-dev/.env-dev as MONGODB_PASSWORD, so a container brought up on the
# stock env files ends up with it. "password" is NOT one of ours; it is included
# because it is the first value any scanner tries and an operator who set it
# should be told. The set is otherwise kept to values we actually ship, so that
# a deliberate site choice is never reported as a default.
nmis_dbpassword_is_insecure()
{
	case "$1" in
	"" | "$NMIS_DBPASSWORD_SHIPPED_DEFAULT" | "example" | "password" | CHANGE_ME*)
		return 0 ;;
	esac
	return 1
}

nmis_dbpassword_classify()
{
	nmis_dbpassword_basedir="$1"
	NMIS_DBPASSWORD_USER=""
	NMIS_DBPASSWORD_FROM_ENV=""

	# Read the EFFECTIVE value through NMISNG::Util::loadConfTable, the same
	# loader the daemons use, so NMIS_* environment overrides are merged in and we
	# judge the value NMIS will actually authenticate with. A regex over
	# Config.nmis alone would miss an operator-supplied NMIS_DB_PASSWORD.
	# Passing an explicit dir avoids the FindBin-in-a-one-liner trap, where a bare
	# perl -e resolves conf from the process cwd and dies in a container.
	#
	# This inspection must not CHANGE anything that matters, and reaching decrypt()
	# at all is dangerous, so the one-liner below avoids it wherever possible.
	#
	# It is not literally side-effect free, and claiming so would be wrong: simply
	# calling loadConfTable can persist a freshly generated cluster_id and rewrite
	# Config.nmis in canonical form. That is loadConfTable's own behaviour, it is
	# idempotent after the first call, and the OMK-12687 authkey hook already does
	# exactly the same thing on every install, so it is not introduced here. What
	# matters is that this function never alters db_password and never turns off
	# encryption, which is what the two guards below are for.
	#
	# Two separate side effects live in NMISNG::Util::decrypt:
	#
	#  1. Called WITH a section and keyword on a cleartext value while encryption
	#     is enabled, it encrypts and rewrites the config (Util.pm:4764-4781).
	#     Avoided by never passing a section or keyword.
	#  2. If Crypt::CBC, Crypt::Cipher::AES or Math::Random::Secure cannot be
	#     loaded and encryption is enabled, it sets
	#     global_enable_password_encryption to "false" and rewrites the config
	#     (Util.pm:4739-4747). Verified: one decrypt() call on a host without
	#     those modules flips the flag. An installer hook must not be the thing
	#     that turns off encryption of secrets, so we do not call decrypt unless
	#     we have already confirmed the modules load.
	#
	# So: a cleartext value is compared directly with no decrypt call at all,
	# which is the case that matters because a shipped default is cleartext. Only
	# an already-encrypted ("!!") value needs decrypting, and if the crypto
	# modules are absent we report "unknown" rather than inspect it.
	#
	# Passing an explicit dir avoids the FindBin-in-a-one-liner trap, where a bare
	# perl -e resolves conf from the process cwd and dies in a container.
	#
	# The exit status matters as much as the output. The loader prints an empty
	# string and exits 0 for a genuinely unset value, and prints nothing and exits
	# non-zero when it dies. Conflating the two means telling an operator their
	# credential is a default when we simply could not read it.
	nmis_dbpassword_probe="$(DBPW_CONFDIR="$nmis_dbpassword_basedir/conf" \
		perl -I "$nmis_dbpassword_basedir/lib" -MNMISNG::Util \
		-e 'my $c = NMISNG::Util::loadConfTable(dir => $ENV{DBPW_CONFDIR});
		    my $raw = $c->{db_password} // "";
		    my $pw;
		    if (substr($raw, 0, 2) ne "!!") { $pw = $raw }
		    else {
		      eval { require Crypt::CBC; require Crypt::Cipher::AES;
		             require Math::Random::Secure; 1 } or exit 4;
		      $pw = NMISNG::Util::decrypt($raw);
		    }
		    print(($c->{db_username} // ""), "\n", ($pw // ""), "\n");' 2>/dev/null)"
	nmis_dbpassword_read_status=$?
	# 4 is our own "encrypted, and we will not risk decrypting it" signal; both it
	# and a genuine loader failure mean the same thing to the caller: say nothing.
	if [ "$nmis_dbpassword_read_status" -ne 0 ]; then
		return 3
	fi

	NMIS_DBPASSWORD_USER="$(printf '%s' "$nmis_dbpassword_probe" | sed -n '1p')"
	nmis_dbpassword_value="$(printf '%s' "$nmis_dbpassword_probe" | sed -n '2p')"

	# Does the effective value come from a NMIS_* override? If so it has to be
	# fixed in the environment, because ENV wins at runtime and editing the file
	# would have no effect while adding a file-plus-ENV overlap that NMIS logs on
	# every config load.
	NMIS_DBPASSWORD_FROM_ENV="$(perl -e 'print 1 if grep { /^NMIS_(.+)$/ && lc($1) eq "db_password" } keys %ENV' 2>/dev/null)"

	if ! nmis_dbpassword_is_insecure "$nmis_dbpassword_value"; then
		nmis_dbpassword_value=""
		return 0
	fi
	nmis_dbpassword_value=""

	if [ -n "$NMIS_DBPASSWORD_FROM_ENV" ]; then
		return 1
	fi
	return 2
}

# The advisory text, kept here so the installer hook and both entrypoints say the
# same thing. Takes the effective username. Writes to stdout; callers route it
# through echolog or echo as appropriate.
#
# It deliberately does NOT tell the operator to just change db_password, because
# doing that alone breaks the other OMK products (see the header). It tells them
# what the exposure is and points at the supported path.
nmis_dbpassword_advice()
{
	echo "WARNING: MongoDB user '${1:-unknown}' is using a shipped default password."
	echo "WARNING: That credential is also the MongoDB administrative password on a stock"
	echo "WARNING: install, so anyone who can read the config, or who knows the published"
	echo "WARNING: default, has full control of the database."
	echo "WARNING: Do NOT hand-edit db_password to a new value: on an un-migrated install"
	echo "WARNING: this MongoDB user is shared with the other OMK products on this host."
	echo "WARNING: Run 'admin/setup_mongodb.pl' to migrate NMIS to its own scoped database"
	echo "WARNING: user with a generated password (OMK-12709, OMK-12826)."
}
