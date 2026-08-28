#!/usr/bin/perl
# OMK-12826 (resetadminpw recovery): the admin-password reset must REFUSE the
# unsafe preconditions before it ever touches MongoDB or mongod.conf - a remote
# db_server, and (implicitly) a missing local mongod.conf. These refusal paths
# need no running MongoDB and no root, so they are driven here as a subprocess of
# the real script (same pattern as t_setup_mongodb_scoped_user.t). The full reset
# success path needs a local service-managed mongod and is exercised by the
# out-of-repo install automation, not here.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

my $repo = "$FindBin::Bin/..";
my $script = "$repo/admin/setup_mongodb.pl";
ok(-f $script, "setup_mongodb.pl exists") or BAIL_OUT("script not found");

# Build a throwaway conf dir pointing at a REMOTE db_server, so the reset takes
# the remote-refusal branch. A remote server never reaches the auth-toggle code,
# so no MongoDB is contacted.
sub run_reset_remote
{
	my $dir = tempdir(CLEANUP => 1);
	mkdir("$dir/conf") or die "mkdir: $!";
	copy("$repo/conf-default/Config.nmis", "$dir/conf/Config.nmis")
		or die "copy Config.nmis: $!";
	system($^X, "$repo/admin/patch_config.pl", "$dir/conf/Config.nmis",
		"/database/db_server=mongo.example.invalid", "/database/db_port=27017") == 0
		or die "seed patch_config failed";

	# scrub NMIS_DB_* so the ambient CI admin identity cannot redirect the conf
	local %ENV = %ENV;
	delete @ENV{ grep { /^NMIS_DB_/ } keys %ENV };

	my $err = gensym;
	my $pid = open3(my $in, my $out, $err,
		$^X, $script, "dir=$dir/conf", "resetadminpw=1", "auto=true", "resetconfirm=1");
	close($in);
	my $o = do { local $/; <$out> } // '';
	my $e = do { local $/; <$err> } // '';
	waitpid($pid, 0);
	return ($? >> 8, "$o$e");
}

my ($rc, $output) = run_reset_remote();

isnt($rc, 0, "resetadminpw exits non-zero for a remote db_server")
	or diag("output:\n$output");
like($output, qr/only supported for a LOCAL MongoDB/i,
	"and says the reset is local-only")
	or diag("output:\n$output");
# it must refuse BEFORE any auth toggle: a remote server is never restarted
unlike($output, qr/authentication\s+DISABLED/i,
	"it refuses before disabling authentication (no no-auth window opened)");

done_testing();
