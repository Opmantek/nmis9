#!/usr/bin/perl
# OMK-12826: installer_hooks/24-postcopy-setup-mongodb must propagate a failed
# setup_mongodb.pl as a non-zero hook exit. DB setup is now MANDATORY, and the
# installer's run_hooks aborts the install on a non-zero hook (see `installer`
# around the run_hooks sub). A hook that logs the failure but still `exit 0`s
# completes the install as successful while NMIS cannot authenticate.
#
# Drives the REAL hook (copied at run time) with stubbed installer helpers, so
# SCRIPTPATH resolves to the stub dir and the hook sources our minimal
# common_functions.sh / common_dbpassword.sh instead of the installer's. The
# stub setup_mongodb.pl exits with a chosen code; we assert the hook's own exit.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Test::More;

my $hook = "$FindBin::Bin/../installer_hooks/24-postcopy-setup-mongodb";
ok(-f $hook, "the real hook exists at $hook") or BAIL_OUT("hook not found");

# Run the hook against a throwaway TARGETDIR whose admin/setup_mongodb.pl is a
# stub that exits with $setup_rc. Returns the hook's own exit code.
sub run_hook_with_setup_rc
{
	my ($setup_rc) = @_;
	my $dir = tempdir(CLEANUP => 1);

	# minimal installer helpers the hook sources by SCRIPTPATH
	open(my $cf, '>', "$dir/common_functions.sh") or die "common_functions.sh: $!";
	print $cf <<'EOF';
input_yn() { return 0; }          # always answer "yes, run the helper"
logmsg()      { echo "logmsg: $*"; }
echolog()     { echo "echolog: $*"; }
printBanner() { echo "== $* =="; }
EOF
	close($cf);

	open(my $cd, '>', "$dir/common_dbpassword.sh") or die "common_dbpassword.sh: $!";
	print $cd <<'EOF';
nmis_dbpassword_classify() { NMIS_DBPASSWORD_USER=""; return 0; }  # nothing to warn about
nmis_dbpassword_advice()   { echo "advice: $*"; }
EOF
	close($cd);

	# stub the MANDATORY setup helper with a controllable exit code
	mkdir("$dir/admin") or die "mkdir admin: $!";
	open(my $sm, '>', "$dir/admin/setup_mongodb.pl") or die "setup_mongodb.pl: $!";
	print $sm "#!/bin/sh\necho 'stub setup_mongodb.pl'\nexit $setup_rc\n";
	close($sm);
	chmod(0755, "$dir/admin/setup_mongodb.pl") or die "chmod: $!";

	# copy the real hook in beside the stubs so SCRIPTPATH=${0%/*} finds them
	copy($hook, "$dir/24-postcopy-setup-mongodb") or die "copy hook: $!";
	chmod(0755, "$dir/24-postcopy-setup-mongodb") or die "chmod hook: $!";

	system("TARGETDIR='$dir' /bin/sh '$dir/24-postcopy-setup-mongodb' >/dev/null 2>&1");
	return $? >> 8;
}

is(run_hook_with_setup_rc(0), 0,
	"hook exits 0 when setup_mongodb.pl succeeds");

isnt(run_hook_with_setup_rc(3), 0,
	"hook exits non-zero when the MANDATORY setup_mongodb.pl fails");

done_testing();
