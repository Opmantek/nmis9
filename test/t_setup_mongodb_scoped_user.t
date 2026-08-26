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
#   1. nmisng.nmis9RW exists with role dbOwner on nmisng, and no user anywhere
#      holds root.
#   2. the conf now has db_username=nmis9RW, a 64-hex-char db_password, and
#      db_auth_source=nmisng.
#   3. opUserRW in admin was not created or modified by the run (before/after
#      snapshot compared).
#
# Requires a real, disposable MongoDB (auth optional; the fixture below copes
# with either). BAIL_OUT, never skip, if none is configured: a silent skip
# would hide a real regression in CI.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

BEGIN {
	$ENV{NMIS_TEST_MONGO_URI}
		or BAIL_OUT("set NMIS_TEST_MONGO_URI to a disposable mongo admin URI to run this test");
}

use File::Temp qw(tempdir);
use File::Copy;
use IPC::Open3;
use Symbol qw(gensym);

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
# ---------------------------------------------------------------------------
my ($rc, $out, $err) = run_cmd($^X, "$repo_root/admin/setup_mongodb.pl",
	"dir=$conf_dir", "preseed=$preseed_file");

unlink($mongod_conf) if ($created_mongod_conf_stub);

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

done_testing();
