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
like($esrc, qr/^master_key_existing_owner_warning\(\)/m,
	"entrypoint defines master_key_existing_owner_warning");

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
# trusting an existing key. PR 74 review Fix 1 extracted the actual check
# into master_key_existing_owner_warning() (verified behaviourally below),
# so the source-text assertion here is just the wiring: the else-branch
# calls it.
my ($existing_key_else) = $fresh_key_branch =~ /\belse\b(.*)/s;
ok(defined $existing_key_else, "found the existing-key else branch within the fresh-key if")
	or BAIL_OUT("cannot extract the existing-key else branch");
like($existing_key_else, qr/master_key_existing_owner_warning/,
	"the existing-key else-branch calls master_key_existing_owner_warning");

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

# --- provision_master_key behaviour: drive the real function end-to-end ---
# PR 74 review Fix 1 (Important): the stale-tmp cleanup and the existing-key
# ownership warning were previously covered only by the source-text
# assertions above. Drive them for real: source the REAL
# installer_hooks/common_masterkey.sh (so key generation/checking is
# genuine, never stubbed) alongside the extracted provision_master_key,
# master_key_swap_warning and master_key_existing_owner_warning bodies -
# provision_master_key calls the other two, so all three must be in scope
# together.
#
# provision_master_key sources "${NMIS_HOME}/installer_hooks/common_masterkey.sh"
# ITSELF, every time it runs, so pointing NMIS_MASTERKEY_DEFAULT_DIR/FILE at
# a sandbox has to survive that internal re-source, not just an outer one -
# the lib's own two path assignments are unconditional, so an override made
# only in the test's shell context would be silently wiped out again the
# moment provision_master_key re-sources the pristine lib from NMIS_HOME.
# Fix: copy the real lib byte-for-byte into the sandbox's installer_hooks/,
# then APPEND (never edit) two override lines after it. Every source of
# that file - ours below, or provision_master_key's own - runs the real
# generator/checker code first and then lands on the sandbox paths, in that
# order, every time.

my ($existing_owner_fnsrc) = $esrc =~ /^(master_key_existing_owner_warning\(\)\s*\{.*?^\})/ms;
ok(defined $existing_owner_fnsrc, "extracted master_key_existing_owner_warning source")
	or BAIL_OUT("cannot extract master_key_existing_owner_warning");

my $fnsfile_all = "$tempdir/entrypoint_fns_all.sh";
open(my $fa, '>', $fnsfile_all) or die "write fns: $!";
print $fa "$provbody\n\n$fnsrc\n\n$existing_owner_fnsrc\n";
close $fa;

my $masterkey_lib_real = "$root/installer_hooks/common_masterkey.sh";
open(my $lib_rh, '<', $masterkey_lib_real) or die "read lib: $!";
my $lib_src = do { local $/; <$lib_rh> };
close $lib_rh;

sub build_masterkey_sandbox {
	# a fresh temp NMIS_HOME per case: conf/Config.nmis (empty, so
	# master_key_swap_warning stays silent) and installer_hooks/ holding the
	# real common_masterkey.sh plus the sandbox path override appended after
	# it (see the note above this section for why the override has to live
	# inside that file rather than the calling shell).
	my $home = File::Temp::tempdir(CLEANUP => 1);
	my $keydir = "$home/masterkey_default_dir";
	mkdir "$home/conf" or die "mkdir conf: $!";
	mkdir "$home/installer_hooks" or die "mkdir installer_hooks: $!";
	mkdir $keydir or die "mkdir keydir: $!";
	open(my $cf, '>', "$home/conf/Config.nmis") or die "write conf: $!";
	close $cf;
	open(my $lw, '>', "$home/installer_hooks/common_masterkey.sh") or die "write lib copy: $!";
	print $lw $lib_src;
	print $lw "\n# t_compose_master_key.t sandbox override, appended after the\n";
	print $lw "# real lib above (which is copied in verbatim, untouched): redirect\n";
	print $lw "# the default key path into this test's temp dir.\n";
	print $lw "NMIS_MASTERKEY_DEFAULT_DIR='$keydir'\n";
	print $lw qq{NMIS_MASTERKEY_DEFAULT_FILE="\${NMIS_MASTERKEY_DEFAULT_DIR}/master.key"\n};
	close $lw;
	return ($home, $keydir);
}

sub provision_run {
	# runs provision_master_key in the sandbox named by home=>, with an
	# optional extra_env=> literal shell assignment spliced in before the
	# call (e.g. NMIS_MASTER_KEY_FILE=...). Returns (stdout, stderr, rc),
	# captured separately so a stderr-routing assertion (PR 74 review Fix 3)
	# actually means something.
	my (%args) = @_;
	my $home = $args{home};
	my $extra_env = defined $args{extra_env} ? $args{extra_env} : '';
	my $errpath = "$home/stderr.log";
	my $cmd = "set -e; unset NMIS_MASTER_KEY_FILE; "
		. "{ . $home/installer_hooks/common_masterkey.sh; . $fnsfile_all; "
		. "NMIS_HOME=$home; NMIS_USER=nmis; $extra_env provision_master_key; } 2>$errpath";
	my $out = qx{bash -c '$cmd'};
	my $rc = $? >> 8;
	my $err = '';
	if (open(my $eh2, '<', $errpath)) {
		local $/;
		$err = <$eh2>;
		close $eh2;
	}
	return ($out, $err, $rc);
}

# (a) stale tmp + absent key: the cleanup runs and a real key is generated.
{
	my ($home, $keydir) = build_masterkey_sandbox();
	open(my $tf, '>', "$keydir/master.key.tmp.9999") or die "plant tmp: $!";
	print $tf "leftover from a crashed boot";
	close $tf;

	my ($out, $err, $rc) = provision_run(home => $home);
	is($rc, 0, "(a) stale tmp + absent key: provision_master_key exits 0");
	ok(!-e "$keydir/master.key.tmp.9999", "(a) the stale tmp file is gone");
	ok(-e "$keydir/master.key", "(a) a real key now exists");
	is(-s "$keydir/master.key", 257, "(a) the generated key is 256 chars plus a newline");
	my $mode_a = (stat("$keydir/master.key"))[2] & 07777;
	is(sprintf('%04o', $mode_a), '0440', "(a) the generated key is mode 0440");
	like($out, qr/Generated a master key/, "(a) reports the key was generated");
}

# (b) stale tmp + an EXISTING key: proves the cleanup is gated behind the
# fresh-key path and can never fire beside a live key.
{
	my ($home, $keydir) = build_masterkey_sandbox();
	my $existing = ('K' x 256) . "\n";
	open(my $kf, '>', "$keydir/master.key") or die "plant key: $!";
	print $kf $existing;
	close $kf;
	chmod 0440, "$keydir/master.key";
	open(my $tf, '>', "$keydir/master.key.tmp.9999") or die "plant tmp: $!";
	print $tf "leftover from a crashed boot";
	close $tf;

	my ($out, $err, $rc) = provision_run(home => $home);
	is($rc, 0, "(b) stale tmp + existing key: provision_master_key exits 0");
	open(my $kf2, '<', "$keydir/master.key") or die "read key: $!";
	my $after = do { local $/; <$kf2> };
	close $kf2;
	is($after, $existing, "(b) the existing key is byte-identical afterwards");
	ok(-e "$keydir/master.key.tmp.9999",
		"(b) the stale tmp file REMAINS (cleanup never fires beside a live key)");
}

# (c) an existing key owned by someone other than nmis:nmis. No root needed:
# the mismatch is real because the test runs as the host user, not nmis.
{
	my ($home, $keydir) = build_masterkey_sandbox();
	open(my $kf, '>', "$keydir/master.key") or die "plant key: $!";
	print $kf (('K' x 256) . "\n");
	close $kf;
	chmod 0440, "$keydir/master.key";

	my ($out, $err, $rc) = provision_run(home => $home);
	is($rc, 0, "(c) mis-owned existing key: provision_master_key still exits 0");
	unlike($out, qr/Generated a master key/, "(c) does not claim to generate an already-existing key");
	like($err, qr/exists but is owned/, "(c) stderr carries the ownership warning");
	like($err, qr/wanted 'nmis:nmis'/, "(c) the warning names the wanted owner");
	my $keyfile = "$keydir/master.key";
	like($err, qr/chown nmis:nmis \Q$keyfile\E && chmod 0440 \Q$keyfile\E/,
		"(c) the warning carries the exact chown/chmod fix command");
}

# (d) NMIS_MASTER_KEY_FILE set (PR 74 review Fix 2): skip provisioning
# entirely rather than generate a default-path key nobody will use.
{
	my ($home, $keydir) = build_masterkey_sandbox();
	my ($out, $err, $rc) = provision_run(
		home => $home,
		extra_env => 'NMIS_MASTER_KEY_FILE=/run/secrets/whatever;'
	);
	is($rc, 0, "(d) NMIS_MASTER_KEY_FILE set: provision_master_key exits 0");
	like($out, qr/skipping default master key provisioning/,
		"(d) reports that provisioning was skipped");
	opendir(my $dh, $keydir) or die "opendir: $!";
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
	closedir($dh);
	is_deeply(\@entries, [], "(d) creates nothing at the default key path");
}

done_testing();
