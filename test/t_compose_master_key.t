#!/usr/bin/perl
# OMK-12827 Slice C: the encryption-of-secrets master key must survive
# container recreate. Asserts both shipped compose files mount the
# nmis_master_key named volume at /usr/local/etc/firstwave (the DIRECTORY,
# so first boot can create the key inside it) and declare the volume.
# Dependency-free static parsing, matching t_mongo_exposure.t.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $root = "$Bin/..";

my %composes = (
	'compose.yaml'                     => "$root/compose.yaml",
	'conf-default/docker/compose.yaml' => "$root/conf-default/docker/compose.yaml",
);

for my $name (sort keys %composes) {
	open(my $fh, '<', $composes{$name}) or BAIL_OUT("cannot read $composes{$name}: $!");
	my $content = do { local $/; <$fh> };
	close $fh;

	like($content, qr{^\s*-\s*nmis_master_key:/usr/local/etc/firstwave\s*$}m,
		"$name mounts nmis_master_key at /usr/local/etc/firstwave");
	like($content, qr{^\s{2}nmis_master_key:\s*$}m,
		"$name declares the nmis_master_key named volume");
	unlike($content, qr{nmis_master_key:/usr/local/etc/firstwave/master\.key},
		"$name mounts the directory, not the key file");
	like($content, qr{never bake a key}i,
		"$name carries the image-baked-key guard comment");
}

# --- entrypoint wiring (source assertions) ---
my $entrypoint = "$root/docker-entrypoint.sh";
open(my $eh, '<', $entrypoint) or BAIL_OUT("cannot read $entrypoint: $!");
my $esrc = do { local $/; <$eh> };
close $eh;

like($esrc, qr/^provision_master_key\(\)/m, "entrypoint defines provision_master_key");
like($esrc, qr/nmis_masterkey_provision\s+"\$\{NMIS_USER\}"/,
	"provisioning owner is the nmis user (no apache in the production image)");
like($esrc, qr/^master_key_swap_warning\(\)/m, "entrypoint defines master_key_swap_warning");

my ($runbody) = $esrc =~ /^run\(\)\s*\{(.*?)^\}/ms;
ok(defined $runbody, "found run()") or BAIL_OUT("run() not found in $entrypoint");
my $i_setup = index($runbody, "setup");
my $i_prov  = index($runbody, "provision_master_key");
my $i_db    = index($runbody, "setup_db");
ok($i_prov > -1, "run() calls provision_master_key");
ok($i_setup > -1 && $i_prov > $i_setup, "provisioning runs after setup");
ok($i_db > -1 && $i_prov < $i_db, "provisioning runs before setup_db");
my ($provbody) = $esrc =~ /^(provision_master_key\(\)\s*\{.*?^\})/ms;
ok(defined $provbody, "extracted provision_master_key source");
# Non-greedy match to the FIRST "fi" is not enough here: provision_master_key
# has more than one "if [ "$MASTERKEY_WAS_ABSENT" -eq 1 ]" block (the
# stale-tmp cleanup runs before the swap-warning gate), so a single match
# would just find the first (unrelated) block and miss the real one. Loop
# over every such block and require the call inside at least one of them.
my $swap_in_branch = 0;
my $fresh_key_branch = '';
# block terminator anchored to a line that is ONLY "fi" (optional trailing
# whitespace): a bare "^\s*fi" would let a future line merely starting with
# "fi..." end the match early and silently truncate the captured block.
while ($provbody =~ /if\s*\[\s*"\$MASTERKEY_WAS_ABSENT"\s+-eq\s+1\s*\];\s*then(.*?)^\s*fi\s*$/msg) {
	# stash $1 first: testing $1 itself against another pattern is still a
	# match, and even a group-less one clears $1 on success.
	my $block = $1;
	if ($block =~ /master_key_swap_warning/) {
		$swap_in_branch = 1;
		$fresh_key_branch = $block;
		last;
	}
}
ok($swap_in_branch, "the swap warning call sits inside a fresh-key branch");

# OMK-12827 Fix 2b: the existing-key path (the else of the same fresh/existing
# key branch just located above) must verify ownership rather than silently
# trusting an existing key, using the shared checker.
my ($existing_key_else) = $fresh_key_branch =~ /\belse\b(.*)/s;
ok(defined $existing_key_else, "found the existing-key else branch within the fresh-key if")
	or BAIL_OUT("cannot extract the existing-key else branch");
like($existing_key_else, qr/nmis_masterkey_owner_ok/,
	"the existing-key else-branch calls nmis_masterkey_owner_ok");

# --- swap-warning behaviour: drive the real function ---
use File::Temp;
my $tempdir = File::Temp::tempdir(CLEANUP => 1);
mkdir "$tempdir/conf" or die "mkdir: $!";

my ($fnsrc) = $esrc =~ /^(master_key_swap_warning\(\)\s*\{.*?^\})/ms;
ok(defined $fnsrc, "extracted master_key_swap_warning source")
	or BAIL_OUT("cannot extract master_key_swap_warning");
my $fnfile = "$tempdir/fn.sh";
open(my $ff, '>', $fnfile) or die "write fn: $!";
print $ff $fnsrc;
close $ff;

sub swap_warning_run {
	# $extra_env: optional literal shell assignment(s), semicolon-terminated,
	# spliced in before the function call (e.g. env for the operator-key case).
	my ($confcontent, $extra_env) = @_;
	$extra_env = '' unless defined $extra_env;
	open(my $cf, '>', "$tempdir/conf/Config.nmis") or die "write conf: $!";
	print $cf $confcontent;
	close $cf;
	my $out = qx{bash -c 'set -e; . $fnfile; NMIS_HOME=$tempdir; $extra_env master_key_swap_warning' 2>&1};
	return ($out, $? >> 8);
}

my ($warn, $warn_rc) = swap_warning_run(q{'db_password' => '!!deadbeef',});
like($warn, qr/GENERATED A NEW master key/,
	"fresh key beside a '!!' config warns about the key swap");
like($warn, qr/nmis_master_key volume/, "the warning names the recovery volume");
unlike($warn, qr/deadbeef/, "the warning never echoes a stored value");
is($warn_rc, 0, "the warning path exits 0 under set -e");

my ($quiet, $quiet_rc) = swap_warning_run(q{'db_password' => 'plaintext',});
is($quiet, '', "fresh key beside a clean config stays silent");
is($quiet_rc, 0, "the silent path exits 0 under set -e (a failed grep must not kill the boot)");

# operator-key configuration (NMIS_MASTER_KEY_FILE, the documented
# compose-secrets alternative): the runtime ignores the generated default-path
# key when this is set, so a fresh generated key beside a '!!' config implies
# nothing - the warning would be false. Must stay silent even with a '!!'
# config that would otherwise trigger it.
my ($opkey, $opkey_rc) = swap_warning_run(
	q{'db_password' => '!!deadbeef',},
	'NMIS_MASTER_KEY_FILE=/run/secrets/whatever;'
);
is($opkey, '', "NMIS_MASTER_KEY_FILE set beside a '!!' config stays silent (no false swap warning)");
is($opkey_rc, 0, "the operator-key path exits 0 under set -e");

done_testing();
