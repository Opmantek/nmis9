#!/usr/bin/perl
# OMK-12826/OMK-12709: setup_mongodb.pl provisions a scoped nmisng user, never
# touches opUserRW, never grants root, and writes a generated password +
# authSource.
#
# Behavioural: runs the real admin/setup_mongodb.pl (as a subprocess, auto
# mode) against the disposable Mongo named by NMIS_TEST_MONGO_URI, pointed at
# a throwaway conf dir seeded with the legacy db_username=opUserRW, and then
# asserts against the Mongo server and the resulting conf file:
#
#   1. nmisng.nmis9RW exists with role dbOwner on nmisng, and nmis9RW itself
#      holds no root role (this asserts only about nmis9RW, not "every user").
#   2. the conf now has db_username=nmis9RW, a 64-hex-char db_password, and
#      db_auth_source=nmisng.
#   3. opUserRW in admin was not created or modified by the run (before/after
#      snapshot compared).
#   4. a re-run against the now-migrated conf is idempotent and does not error
#      (already-migrated upgrade path, OMK-12826).
#   5. when admin.opUserRW is seeded BEFORE the run, it survives with the SAME
#      roles -- the central "NMIS never touches opUserRW" guard, proven by
#      presence, not only by absence.
#
# Requires a real, disposable MongoDB. The CI Test step provides one (a throwaway
# no-auth mongo plus NMIS_TEST_MONGO_URI, see bitbucket-pipelines.yml), so this
# test runs for real in CI. BAIL_OUT - never skip_all - when the URI is unset: a
# missing precondition must make the pipeline RED, not pass as a green NOTESTS
# skip that silently stops testing the security fix. A BAIL_OUT here does NOT
# abort the whole suite: ci/scripts/perl_tests.sh runs each file in its own
# `prove` under `if ! ...`, so a bail is caught per-file and marks only this file
# failed (exit 255). The bail is in a BEGIN before the MongoDB/NMISNG::DB use
# lines below, so it stays clean even where those modules are not installed.
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
use File::Copy;
use IPC::Open3;
use Symbol qw(gensym);
use Tie::IxHash;

use MongoDB;
use NMISNG::DB;

my $repo_root = "$FindBin::Bin/..";
my $mongo_uri = $ENV{NMIS_TEST_MONGO_URI};

# ---------------------------------------------------------------------------
# Parse host/port out of the URI. setup_mongodb.pl wants discrete db_server/
# db_port config values, not a URI.
# ---------------------------------------------------------------------------
my ($dbserver, $dbport) = $mongo_uri =~ m{^mongodb://(?:[^@/]*@)?([^:/]+):(\d+)};
BAIL_OUT("could not parse host:port out of NMIS_TEST_MONGO_URI=\"$mongo_uri\"")
	if (!$dbserver || !$dbport);

# ---------------------------------------------------------------------------
# Connect once for assertions (and for the before/after opUserRW snapshot).
# ---------------------------------------------------------------------------
my $conn = eval { MongoDB::MongoClient->new(host => $mongo_uri) };
BAIL_OUT("could not connect to NMIS_TEST_MONGO_URI=\"$mongo_uri\": $@") if (!$conn);

sub users_info
{
	my ($dbname, $username) = @_;
	my $r = NMISNG::DB::run_command(
		db      => $conn->get_database($dbname),
		command => { "usersInfo" => { user => $username, db => $dbname } });
	# flatten to a list: callers assign into "my @x = users_info(...)" and
	# need the actual user documents, not a 1-element list holding one arrayref
	return @{ (ref($r) eq "HASH" && ref($r->{users}) eq "ARRAY") ? $r->{users} : [] };
}

my @before_opuserrw = users_info("admin", "opUserRW");

# ---------------------------------------------------------------------------
# Throwaway conf dir: conf-default supplies the macro/default layer,
# conf/Config.nmis is the mutable "site" layer setup_mongodb.pl reads and
# patches. Both start as a copy of the real conf-default/Config.nmis (which
# already ships the scoped-user defaults from OMK-12826); only the local
# layer is then patched to the legacy opUserRW values, to exercise the
# migration path.
# ---------------------------------------------------------------------------
my $tmproot = tempdir("t_setup_mongodb_scoped_user_XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $default_dir = "$tmproot/conf-default";
my $conf_dir     = "$tmproot/conf";
mkdir($default_dir) or BAIL_OUT("mkdir $default_dir: $!");
mkdir($conf_dir)     or BAIL_OUT("mkdir $conf_dir: $!");

copy("$repo_root/conf-default/Config.nmis", "$default_dir/Config.nmis")
	or BAIL_OUT("copy conf-default/Config.nmis: $!");
copy("$repo_root/conf-default/Config.nmis", "$conf_dir/Config.nmis")
	or BAIL_OUT("copy conf-default/Config.nmis into throwaway conf dir: $!");

my $configfile = "$conf_dir/Config.nmis";

sub run_cmd
{
	my (@cmd) = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, @cmd);
	close($in);
	my $stdout = do { local $/; <$out> } // '';
	my $stderr = do { local $/; <$err> } // '';
	waitpid($pid, 0);
	my $rc = $?;
	return ($rc, $stdout, $stderr);
}

my ($prc, $pout, $perr) = run_cmd($^X, "$repo_root/admin/patch_config.pl", $configfile,
	"/database/db_username=opUserRW",
	"/database/db_password=op42flow42",
	"/database/db_server=$dbserver",
	"/database/db_port=$dbport");
is($prc, 0, "seeded throwaway conf with legacy db_username=opUserRW")
	or diag("patch_config.pl stdout:\n$pout\nstderr:\n$perr");

# ---------------------------------------------------------------------------
# setup_mongodb.pl dies if /etc/mongod.conf is missing, purely because it
# assumes a local mongod install to offer to configure -- unrelated to the
# provisioning logic under test here. If this environment has no mongod
# install (as our disposable Mongo does not), stub the file just enough to
# satisfy the existence check, and preseed the two prompts that would
# otherwise try to mutate it (enable auth, install a logrotate config) to
# "no", so this test never touches host service state even when a REAL
# /etc/mongod.conf already exists in the environment it runs in.
# ---------------------------------------------------------------------------
my $mongod_conf = "/etc/mongod.conf";
my $created_mongod_conf_stub = 0;
if ($dbserver eq "localhost" || $dbserver eq "127.0.0.1")
{
	if (!-e $mongod_conf)
	{
		if (open(my $fh, '>', $mongod_conf))
		{
			print $fh "# stub created by t_setup_mongodb_scoped_user.t\n";
			close($fh);
			$created_mongod_conf_stub = 1;
		}
		else
		{
			diag("could not create stub $mongod_conf ($!); setup_mongodb.pl may die on its existence check");
		}
	}
}

my $preseed_file = "$tmproot/preseed.txt";
open(my $pfh, '>', $preseed_file) or BAIL_OUT("cannot write $preseed_file: $!");
# 116b: "add authorization: enabled to mongod.conf?"  -- decline, don't mutate it
# 399a: "add a logrotate script?"                     -- decline, don't mutate the host
print $pfh qq(116b "no"\n399a "no"\n);
close($pfh);

# ---------------------------------------------------------------------------
# Run the real script.
#
# Scrub NMIS_DB_* from the child's environment for every setup invocation: in a
# real dev container those are set and, via loadConfTable layer 4, would override
# the throwaway conf -- pointing setup at the LIVE mongo and skipping the
# opUserRW->nmis9RW migration path we are here to exercise. NMIS_TEST_MONGO_URI
# is not an NMIS_DB_* var, so the disposable-mongo fixture is preserved.
# ---------------------------------------------------------------------------
sub run_setup
{
	my ($cdir) = @_;
	local %ENV = %ENV;
	delete @ENV{ grep { /^NMIS_DB_/ } keys %ENV };
	return run_cmd($^X, "$repo_root/admin/setup_mongodb.pl",
		"dir=$cdir", "preseed=$preseed_file");
}

my ($rc, $out, $err) = run_setup($conf_dir);

is($rc, 0, "setup_mongodb.pl exits 0")
	or diag("setup_mongodb.pl stdout:\n$out\nstderr:\n$err");

# ---------------------------------------------------------------------------
# 1. nmisng.nmis9RW exists with dbOwner on nmisng, and holds no root role.
# ---------------------------------------------------------------------------
my @nmis9rw = users_info("nmisng", "nmis9RW");
is(scalar(@nmis9rw), 1, "nmisng.nmis9RW exists after the run")
	or diag("setup_mongodb.pl stdout:\n$out\nstderr:\n$err");

if (@nmis9rw)
{
	my @roles = @{ $nmis9rw[0]->{roles} || [] };
	ok((grep { $_->{role} eq 'dbOwner' && $_->{db} eq 'nmisng' } @roles),
		"nmis9RW holds dbOwner on nmisng");
	ok(!(grep { $_->{role} eq 'root' } @roles),
		"nmis9RW does NOT hold root");
}

# ---------------------------------------------------------------------------
# 2. the conf now has db_username=nmis9RW, a 64-hex-char db_password, and
#    db_auth_source=nmisng.
# ---------------------------------------------------------------------------
my $after_conf = slurp_conf($configfile);
like($after_conf, qr/'db_username'\s*=>\s*'nmis9RW'/, "conf db_username migrated to nmis9RW");
like($after_conf, qr/'db_auth_source'\s*=>\s*'nmisng'/, "conf db_auth_source written as nmisng");

my ($written_pw) = $after_conf =~ /'db_password'\s*=>\s*'([0-9a-f]*)'/;
ok(defined($written_pw) && length($written_pw) == 64,
	"conf db_password is a 64-hex-char generated value")
	or diag("db_password in conf did not match: " . (defined($written_pw) ? "\"$written_pw\"" : "<not found>"));

sub slurp_conf
{
	my ($path) = @_;
	open(my $fh, '<', $path) or BAIL_OUT("cannot read $path: $!");
	local $/;
	my $content = <$fh>;
	close($fh);
	return $content;
}

# ---------------------------------------------------------------------------
# 3. opUserRW in admin was not created or modified by the run.
# ---------------------------------------------------------------------------
my @after_opuserrw = users_info("admin", "opUserRW");
is(scalar(@before_opuserrw), 0, "opUserRW did not exist before the run (fresh disposable Mongo)");
is(scalar(@after_opuserrw), 0, "opUserRW was not created by the run");
is_deeply(\@after_opuserrw, \@before_opuserrw,
	"opUserRW in admin is byte-for-byte unchanged by the run (before/after)");

# ---------------------------------------------------------------------------
# 4. already-migrated re-run: running setup again against the now-migrated conf
#    (db_auth_source is set, db_password holds the app secret) must be a clean
#    no-op, not an error. Regression guard for the misleading "could not
#    determine server version" death on an unattended re-run.
# ---------------------------------------------------------------------------
my ($rc2, $out2, $err2) = run_setup($conf_dir);
is($rc2, 0, "setup_mongodb.pl re-run against the migrated conf exits 0 (idempotent)")
	or diag("re-run stdout:\n$out2\nstderr:\n$err2");

my $after_conf2 = slurp_conf($configfile);
like($after_conf2, qr/'db_username'\s*=>\s*'nmis9RW'/, "re-run leaves db_username=nmis9RW");
like($after_conf2, qr/'db_auth_source'\s*=>\s*'nmisng'/, "re-run leaves db_auth_source=nmisng");

# ---------------------------------------------------------------------------
# 5. seeded opUserRW survives untouched. Prove the "NMIS never touches opUserRW"
#    guarantee by PRESENCE, not only absence: create admin.opUserRW with known
#    roles before a run, then assert it still exists with the SAME roles
#    afterwards (not deleted, not re-roled).
# ---------------------------------------------------------------------------
{
	my $admindb = $conn->get_database("admin");

	# start from a known state: drop our fixture user if a prior aborted run left it
	if (users_info("admin", "opUserRW"))
	{
		NMISNG::DB::run_command(db => $admindb, command => { "dropUser" => "opUserRW" });
	}

	my $seed_roles = [ { role => 'readWrite', db => 'seeded_probe_db' } ];
	my $cr = NMISNG::DB::run_command(db => $admindb,
		command => Tie::IxHash->new(
			"createUser" => "opUserRW",
			"pwd"        => "seeded-known-password-not-the-app-secret",
			"roles"      => $seed_roles));
	ok((ref($cr) eq 'HASH' && $cr->{ok}), "seeded admin.opUserRW fixture created")
		or diag("createUser opUserRW: " . (ref($cr) eq 'HASH' ? ($cr->{errmsg} // '') : $cr));

	my @seeded_before = users_info("admin", "opUserRW");
	is(scalar(@seeded_before), 1, "seeded opUserRW exists before the run");
	my $roles_before = @seeded_before
		? [ sort { "$a->{db}.$a->{role}" cmp "$b->{db}.$b->{role}" } @{ $seeded_before[0]->{roles} || [] } ]
		: [];

	# fresh throwaway conf dir seeded with the legacy opUserRW values
	my $conf_dir2 = "$tmproot/conf2";
	mkdir($conf_dir2) or BAIL_OUT("mkdir $conf_dir2: $!");
	copy("$repo_root/conf-default/Config.nmis", "$conf_dir2/Config.nmis")
		or BAIL_OUT("copy Config.nmis into conf2: $!");
	my $configfile2 = "$conf_dir2/Config.nmis";
	my ($sprc, $spout, $sperr) = run_cmd($^X, "$repo_root/admin/patch_config.pl", $configfile2,
		"/database/db_username=opUserRW",
		"/database/db_password=op42flow42",
		"/database/db_server=$dbserver",
		"/database/db_port=$dbport");
	is($sprc, 0, "seeded conf2 with legacy db_username=opUserRW")
		or diag("patch_config stdout:\n$spout\nstderr:\n$sperr");

	my ($rc3, $out3, $err3) = run_setup($conf_dir2);
	is($rc3, 0, "setup_mongodb.pl exits 0 with a pre-existing admin.opUserRW")
		or diag("stdout:\n$out3\nstderr:\n$err3");

	my @seeded_after = users_info("admin", "opUserRW");
	is(scalar(@seeded_after), 1, "seeded opUserRW STILL exists after the run (not deleted)");
	my $roles_after = @seeded_after
		? [ sort { "$a->{db}.$a->{role}" cmp "$b->{db}.$b->{role}" } @{ $seeded_after[0]->{roles} || [] } ]
		: [];
	is_deeply($roles_after, $roles_before,
		"seeded opUserRW roles are unchanged by the run (not re-roled)");

	# the migrated app user still landed correctly in conf2
	my $after_conf3 = slurp_conf($configfile2);
	like($after_conf3, qr/'db_username'\s*=>\s*'nmis9RW'/, "conf2 db_username migrated to nmis9RW");

	# tidy our fixture user out of the disposable Mongo
	NMISNG::DB::run_command(db => $admindb, command => { "dropUser" => "opUserRW" });
}

unlink($mongod_conf) if ($created_mongod_conf_stub);

done_testing();
