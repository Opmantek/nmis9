#!/usr/bin/perl
# OMK-12827 Slice B (PR 73 review Important 4): behavioural coverage for
# nmis_masterkey_provision - idempotence (an existing key stays
# byte-identical), SIMULATE creates nothing, noclobber refuses a
# pre-planted tmp file, and the created key has the right shape and mode.
use strict;
use warnings;
use FindBin;
use File::Temp;
use Test::More;

my $lib = "$FindBin::Bin/../installer_hooks/common_masterkey.sh";
ok(-f $lib, "common_masterkey.sh exists") or BAIL_OUT("$lib missing");
my $tempdir = File::Temp::tempdir(CLEANUP => 1);

sub provision
{
	my (%opt) = @_;
	my $env = $opt{simulate} ? "SIMULATE=1 " : "";
	my $pre = $opt{pre} // '';
	my $owner = $opt{owner} // 'root';
	return system("sh -c '$env . $lib; NMIS_MASTERKEY_DEFAULT_DIR=$tempdir/keys; NMIS_MASTERKEY_DEFAULT_FILE=\$NMIS_MASTERKEY_DEFAULT_DIR/master.key; $pre nmis_masterkey_provision $owner' >/dev/null 2>&1") >> 8;
}
my $keyfile = "$tempdir/keys/master.key";

# SIMULATE creates nothing
is(provision(simulate => 1), 0, "SIMULATE run returns success");
ok(!-e $keyfile, "SIMULATE created no key file");

# real run creates a well-formed key
is(provision(), 0, "provision creates a key");
ok(-f $keyfile, "key file exists");
my $mode = (stat($keyfile))[2] & 07777;
is($mode, 0440, "key file mode is 0440");
open(my $fh, '<', $keyfile) or die $!;
my $key1 = <$fh>; close $fh; chomp $key1;
ok($key1 =~ /^[A-Za-z0-9]{256}$/, "key is 256 chars of [A-Za-z0-9]");
my @leftover = glob("$tempdir/keys/*.tmp.*");
is(scalar(@leftover), 0, "no tmp remnant after a successful run");

# idempotence: second run leaves the key byte-identical
is(provision(), 0, "second provision run returns success");
open($fh, '<', $keyfile) or die $!;
my $key2 = <$fh>; close $fh; chomp $key2;
ok($key1 eq $key2, "an existing key is left byte-identical");

# noclobber: a pre-planted file at the tmp name blocks the write
unlink($keyfile);
is(provision(pre => 'touch "$NMIS_MASTERKEY_DEFAULT_FILE.tmp.$$";'), 1,
	"a pre-planted tmp file makes provisioning fail instead of writing through it");
ok(!-e $keyfile, "and no key file was created");

# --- postcondition: a failed chown must fail provisioning (root only;
# non-root callers cannot chown and keep the tolerant behaviour) ---
unlink($keyfile);
if ($> == 0) {
	my $rc = provision(owner => 'no_such_user_omk12827');
	is($rc, 1, "provisioning fails when the requested owner cannot be applied");
	ok(-f $keyfile, "the created key file is left in place for diagnosis");
	unlink($keyfile);
} else {
	ok(provision() == 0, "non-root provisioning stays tolerant (cannot chown)");
	unlink($keyfile);
}

# ---------------------------------------------------------------------------
# nmis_masterkey_owner_ok (PR 73 round-3 Important 1): the ownership check
# shared between hook 21's existing-key branch and this file's own
# postcondition above. Extracted so there is exactly one stat compare to get
# right, and so it has direct test coverage - reverting the inline copy that
# used to live in the hook would trip nothing before this.
# ---------------------------------------------------------------------------

sub owner_ok
{
	my (%opt) = @_;
	my $owner = $opt{owner};
	my $file  = $opt{file} // $keyfile;
	my $out = `sh -c '. $lib; NMIS_MASTERKEY_DEFAULT_FILE="$file"; nmis_masterkey_owner_ok "\$1"' _ "$owner" 2>/dev/null`;
	my $rc = $? >> 8;
	return ($rc, $out);
}

# healthy / misowned: both driven off one real key and its REAL owner:group,
# read back with stat rather than assumed. This test runs as both root and
# non-root (root in the dev container, a developer's own uid on a bare host),
# and the two runs land on a different actual owner:
#  - root: nmis_masterkey_provision chowns the key to "root:nmis" (postcondition
#    verified above), so the actual group really is "nmis" -> rc 0 is expected.
#  - non-root: the provision postcondition is root-scoped and skips its chown
#    attempts, so the key keeps the caller's uid and primary group, which is
#    essentially never "nmis" -> rc 1 is expected.
# Rather than special-case on $>, the expectation is derived from the actual
# owner:group stat reports, so the assertion is correct either way.
{
	unlink($keyfile) if -e $keyfile;
	is(provision(), 0, "provision creates a key to check ownership of");
	ok(-f $keyfile, "key file exists for ownership checks");

	my @st = stat($keyfile) or die "cannot stat $keyfile: $!";
	my $actual_user  = getpwuid($st[4]) // $st[4];
	my $actual_group = getgrgid($st[5]) // $st[5];
	my $actual_owner = "$actual_user:$actual_group";

	my ($rc, $out) = owner_ok(owner => $actual_user);
	chomp $out;
	is($out, $actual_owner,
		"nmis_masterkey_owner_ok prints the actual owner:group on stdout");
	my $expected_rc = ($actual_group eq 'nmis') ? 0 : 1;
	is($rc, $expected_rc,
		"rc is $expected_rc when the actual owner:group is '$actual_owner' and wanted is '$actual_user:nmis'");
}

# misowned: a wanted-owner that cannot possibly match this key -> rc 1, and
# stdout still carries the real owner:group (the caller's message needs it).
{
	my ($rc, $out) = owner_ok(owner => 'no_such_user_omk12827');
	is($rc, 1, "an owner that cannot match the key's real owner is rc 1");
	chomp $out;
	like($out, qr/^[^:]+:[^:]+$/, "stdout still carries owner:group on mismatch");
}
unlink($keyfile);

# missing file: nmis_masterkey_owner_ok must not assume the file exists.
{
	my $missing = "$tempdir/keys/does-not-exist.key";
	my ($rc, $out) = owner_ok(owner => 'root', file => $missing);
	is($rc, 2, "an unstattable file returns rc 2");
	is($out, '', "and prints nothing on stdout");
}

# wiring: hook 21's existing-key branch must call the shared function, not a
# reintroduced inline stat compare - same source-assert pattern as
# test/t_setup_mongodb_shell.t's static subtests.
{
	my $hook = "$FindBin::Bin/../installer_hooks/21-postcopy-encryption";
	open(my $fh, '<', $hook) or die "cannot open $hook: $!";
	my $hook_content = do { local $/; <$fh> };
	close $fh;

	my ($existing_key_branch) =
		$hook_content =~ /if \[ -e "\$NMIS_MASTERKEY_DEFAULT_FILE" \]; then(.*?)\nelif/s;
	ok(defined $existing_key_branch, "found hook 21's existing-key ('-e') branch")
		or diag("could not locate the -e branch in $hook");
	like($existing_key_branch // '', qr/\bnmis_masterkey_owner_ok\b/,
		"hook 21's existing-key branch calls the shared nmis_masterkey_owner_ok check");
}

done_testing();
