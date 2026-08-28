# Master-key generation and provisioning for encryption of secrets
# (OMK-12827 Slice B). Shared between installer_hooks/21-postcopy-encryption
# and the Docker entrypoints so the two cannot drift.
#
# The key file is one line of 256 [A-Za-z0-9] characters (NMISNG::Util
# _resolve_seed reads the first line and chomps it). Never rotate or
# relocate an existing key: values already encrypted with it would become
# permanently undecryptable. Only ever create at the shipped default path;
# a custom master_key_file location is operator-provisioned.

NMIS_MASTERKEY_DEFAULT_DIR='/usr/local/etc/firstwave'
NMIS_MASTERKEY_DEFAULT_FILE="${NMIS_MASTERKEY_DEFAULT_DIR}/master.key"

# print a 256-char [A-Za-z0-9] key on stdout. Prefer the kernel CSPRNG with
# rejection sampling (no modulo bias); fall back to Math::Random::Secure, an
# installer dependency (30-pre-dependencies). NEVER core rand(): it is
# deterministic from a 32-bit seed (the OMK-12827 item 4 defect).
# returns 1 when no CSPRNG worked.
nmis_masterkey_generate()
{
	nmis_masterkey_new="$(perl -e '
		open(my $f, "<:raw", "/dev/urandom") or exit 1;
		my @cs = (("A".."Z"), ("a".."z"), (0..9));
		my $limit = 256 - (256 % scalar(@cs));
		my $out = "";
		while (length($out) < 256) {
			read($f, my $b, 64) or exit 1;
			for my $byte (unpack("C*", $b)) {
				next if ($byte >= $limit);
				$out .= $cs[$byte % scalar(@cs)];
				last if (length($out) == 256);
			}
		}
		print $out;' 2>/dev/null)" || nmis_masterkey_new=""
	if [ "${#nmis_masterkey_new}" -ne 256 ]; then
		# stdout carries the key, so diagnostics go to stderr.
		echo "WARNING /dev/urandom unavailable for master.key, falling back to Math::Random::Secure" >&2
		nmis_masterkey_new="$(perl -e '
			use Math::Random::Secure qw(irand);
			my @cs = (("A".."Z"), ("a".."z"), (0..9));
			my $out = ""; $out .= $cs[irand(scalar(@cs))] for (1..256);
			print $out;' 2>/dev/null)" || nmis_masterkey_new=""
	fi
	if [ "${#nmis_masterkey_new}" -ne 256 ]; then
		return 1
	fi
	printf '%s' "$nmis_masterkey_new"
	return 0
}

# create the default-path master key if absent. $1 = owning user for the
# key (the web user: www-data or apache; the web tier must decrypt).
# Never touches an existing key. The key is never echoed, logged, or passed
# through execPrint, and xtrace is suppressed around the write.
# returns 0 when the key exists or was created, 1 on failure.
nmis_masterkey_provision()
{
	nmis_masterkey_owner="${1:-root}"
	if [ -e "$NMIS_MASTERKEY_DEFAULT_FILE" ]; then
		return 0
	fi

	nmis_masterkey_val="$(nmis_masterkey_generate)" || nmis_masterkey_val=""
	if [ -z "$nmis_masterkey_val" ]; then
		return 1
	fi

	if [ ! -d "$NMIS_MASTERKEY_DEFAULT_DIR" ]; then
		mkdir -p "$NMIS_MASTERKEY_DEFAULT_DIR" || return 1
	fi
	chmod 0770 "$NMIS_MASTERKEY_DEFAULT_DIR"
	chown "${nmis_masterkey_owner}:nmis" "$NMIS_MASTERKEY_DEFAULT_DIR" 2>/dev/null || :

	# suppress xtrace around the secret write, restore it afterwards
	nmis_masterkey_xtrace=0
	case $- in *x*) nmis_masterkey_xtrace=1; set +x;; esac
	nmis_masterkey_umask="$(umask)"
	umask 337
	if ! printf '%s\n' "$nmis_masterkey_val" > "$NMIS_MASTERKEY_DEFAULT_FILE"; then
		umask "$nmis_masterkey_umask"
		[ "$nmis_masterkey_xtrace" -eq 1 ] && set -x
		return 1
	fi
	umask "$nmis_masterkey_umask"
	[ "$nmis_masterkey_xtrace" -eq 1 ] && set -x

	chown "${nmis_masterkey_owner}:nmis" "$NMIS_MASTERKEY_DEFAULT_FILE" 2>/dev/null || :
	chmod 0440 "$NMIS_MASTERKEY_DEFAULT_FILE"
	return 0
}
