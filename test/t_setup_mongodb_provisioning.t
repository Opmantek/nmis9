#!/usr/bin/perl
# OMK-12826: behavioural test for the admin-provisioning core of setup_mongodb.pl
# and the admin-credential-file helpers, driven directly by `require`ing the
# script (its modulino guard, `return 1 if caller()`, stops the main flow so the
# named subs are available). These run against a disposable NO-AUTH MongoDB - they
# need no local mongod and no `service mongod restart`, only the same
# NMIS_TEST_MONGO_URI fixture the CI Test step already provides.
#
# Covers:
#   1. ensure_admin_user on a server with no admin -> creates nmis9admin (root on
#      admin) with a generated password, and records it 0600 in the credential
#      file (NMIS_MONGO_ADMIN_PASSWORD_FILE).
#   2. a second call -> 'exists', no duplicate.
#   3. rollback: when the credential file cannot be written, the just-created
#      admin is dropped and 'error' is returned (never a stranded admin).
#   4. write_/read_mongo_admin_password_file round-trip, including a password with
#      internal whitespace.
#   5. mongo_admin_pwfile_writable is non-destructive: it never touches an
#      existing credential file.
#
# BAIL_OUT (red), never skip, when NMIS_TEST_MONGO_URI is unset: a missing
# precondition must fail the pipeline, not pass as a green skip.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

BEGIN {
	$ENV{NMIS_TEST_MONGO_URI}
		or BAIL_OUT("NMIS_TEST_MONGO_URI is unset - the CI Test step must provide a disposable mongo; refusing to skip a security regression test");
}

use File::Temp qw(tempdir);
use MongoDB;
use NMISNG::DB;

my $repo = "$FindBin::Bin/..";
my $uri  = $ENV{NMIS_TEST_MONGO_URI};
my ($dbserver, $dbport) = $uri =~ m{^mongodb://(?:[^@/]*@)?([^:/]+):(\d+)};
BAIL_OUT("could not parse host:port from NMIS_TEST_MONGO_URI=\"$uri\"") if (!$dbserver || !$dbport);

# point the credential file at a throwaway path for the whole test
my $tmp = tempdir("t_setup_prov_XXXXXX", TMPDIR => 1, CLEANUP => 1);
$ENV{NMIS_MONGO_ADMIN_PASSWORD_FILE} = "$tmp/mongodb-admin-password";

# load the script's subs without running it (modulino guard)
require "$repo/admin/setup_mongodb.pl";

my $conn = eval { MongoDB::MongoClient->new(host => $uri) };
BAIL_OUT("cannot connect to $uri: $@") if (!$conn);

sub admin_users {
	my $r = NMISNG::DB::run_command(db => $conn->get_database("admin"),
		command => { usersInfo => 1 });
	return (ref($r) eq 'HASH' && ref($r->{users}) eq 'ARRAY') ? @{$r->{users}} : ();
}
sub drop_admin {
	NMISNG::DB::run_command(db => $conn->get_database("admin"),
		command => { dropUser => "nmis9admin" });
}

# clean slate
drop_admin();

# ---------------------------------------------------------------------------
# 1. create
# ---------------------------------------------------------------------------
my ($status, $msg) = main::ensure_admin_user($conn, $dbserver, $dbport);
is($status, 'created', "ensure_admin_user creates an admin when none exists")
	or diag("msg: " . ($msg // '<undef>'));

my @admins = grep { $_->{user} eq 'nmis9admin' } admin_users();
is(scalar(@admins), 1, "nmis9admin exists in admin after create");
if (@admins) {
	ok((grep { $_->{role} eq 'root' && $_->{db} eq 'admin' } @{$admins[0]{roles}}),
		"nmis9admin holds root on admin");
}

my $pwfile = $ENV{NMIS_MONGO_ADMIN_PASSWORD_FILE};
ok(-f $pwfile, "credential file was written");
my $mode = (stat($pwfile))[2] & 07777;
is($mode, 0600, "credential file is mode 0600");
my ($fu, $fp) = main::read_mongo_admin_password_file();
is($fu, 'nmis9admin', "recorded username round-trips");
ok(defined($fp) && length($fp) == 64, "recorded password is the generated 64-hex value");

# ---------------------------------------------------------------------------
# 2. idempotent: a second call reports 'exists', does not duplicate
# ---------------------------------------------------------------------------
my ($status2) = main::ensure_admin_user($conn, $dbserver, $dbport);
is($status2, 'exists', "ensure_admin_user reports 'exists' when an admin already exists");
is(scalar(grep { $_->{user} eq 'nmis9admin' } admin_users()), 1,
	"still exactly one nmis9admin (no duplicate)");

# ---------------------------------------------------------------------------
# 3. rollback when the credential file cannot be written
# ---------------------------------------------------------------------------
drop_admin();
{
	local $ENV{NMIS_MONGO_ADMIN_PASSWORD_FILE} = "/etc/hostname/nope/mongodb-admin-password";
	my ($rstatus, $rmsg) = main::ensure_admin_user($conn, $dbserver, $dbport);
	is($rstatus, 'error', "ensure_admin_user returns 'error' when the file cannot be written");
	is(scalar(grep { $_->{user} eq 'nmis9admin' } admin_users()), 0,
		"the just-created admin was rolled back (dropped), not left stranded")
		or diag("rollback msg: " . ($rmsg // '<undef>'));
}

# ---------------------------------------------------------------------------
# 4. write/read round-trip, including internal whitespace
# ---------------------------------------------------------------------------
{
	my $wf = "$tmp/rt-cred";
	local $ENV{NMIS_MONGO_ADMIN_PASSWORD_FILE} = $wf;
	my $err = main::write_mongo_admin_password_file($wf, $dbserver, $dbport,
		"someadmin", "pass with spaces 123");
	is($err, undef, "write_mongo_admin_password_file succeeds");
	my ($u, $p) = main::read_mongo_admin_password_file();
	is($u, "someadmin", "username round-trips");
	is($p, "pass with spaces 123", "password with internal whitespace round-trips intact");
}

# ---------------------------------------------------------------------------
# 5. mongo_admin_pwfile_writable is non-destructive
# ---------------------------------------------------------------------------
{
	my $keep = "$tmp/keep-cred";
	open(my $fh, '>', $keep) or BAIL_OUT("cannot seed $keep: $!");
	print $fh "username: keepme\npassword: KEEPME123\n";
	close($fh);
	my $before = do { local (@ARGV,$/) = $keep; open(my $r,'<',$keep); <$r> };
	my $werr = main::mongo_admin_pwfile_writable($keep);
	is($werr, undef, "writable check passes for a writable path");
	my $after = do { local (@ARGV,$/) = $keep; open(my $r,'<',$keep); <$r> };
	is($after, $before, "writability check did NOT modify the existing credential file");
}

# tidy
drop_admin();

done_testing();
