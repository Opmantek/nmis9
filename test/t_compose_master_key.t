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
while ($provbody =~ /if\s*\[\s*"\$MASTERKEY_WAS_ABSENT"\s+-eq\s+1\s*\];\s*then(.*?)^\s*fi/msg) {
	if ($1 =~ /master_key_swap_warning/) {
		$swap_in_branch = 1;
		last;
	}
}
ok($swap_in_branch, "the swap warning call sits inside a fresh-key branch");

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
	my ($confcontent) = @_;
	open(my $cf, '>', "$tempdir/conf/Config.nmis") or die "write conf: $!";
	print $cf $confcontent;
	close $cf;
	my $out = qx{bash -c 'set -e; . $fnfile; NMIS_HOME=$tempdir; master_key_swap_warning' 2>&1};
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

done_testing();
