#!/usr/bin/perl
#
# Tests for the file-permission / ownership "fix" logic touched by the
# scheduled permission_test (selftest) job, and the contrasting pidfile path.
#
# Background (verified against the source, see the guard subtests below):
#
#   * selftest() unconditionally force-fixes perms on conf (recursive),
#     var (TOP LEVEL ONLY, non-recursive) and models (top level) via
#     setFileProtDirectory(). Because the var pass is non-recursive it never
#     descends into var/nmis_system/, where nmisd.pid and nmisd_state.json live.
#
#   * nmisd_state.json gets normalised to nmis:nmis NOT by the permission test
#     but because nmisd writes it through writeHashtoFile(), which always calls
#     setFileProtDiag() (chown when root, chmod always).
#
#   * nmisd.pid is written by a dedicated path that only does chmod(0644) and
#     never calls setFileProtDiag()/chown, so it keeps the owner of whoever ran
#     nmisd. The shipped systemd unit has no User=, and nmisd does not drop
#     privileges, so under systemd that owner is root -> root:root.
#
# What runs where:
#   * The recursion-scope and writeHashtoFile subtests use an explicit conf
#     hash and exercise chmod only, so they run as any user.
#   * The audit (read-only) subtest needs a loadable NMIS config; it SKIPs if
#     loadConfTable() cannot run (e.g. as an unprivileged user).
#   * The real chown-to-nmis subtest SKIPs unless run as root with the nmis
#     user and group present.
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

use_ok('NMISNG::Util');

# current user/group, used to build a conf where ownership is already correct
# so the non-root branch of setFileProtDiag exercises chmod without chown.
my $myuid    = $<;
my $mylogin  = getpwuid($myuid);
my @groups   = split / /, $(;
my $mygid    = $groups[0];
my $mygroup  = getgrgid($mygid);

# minimal config, passed to the functions under test. setFileProtDiag() honours
# this (see the precedence fix at Util.pm:1193-1196); we use a distinctive
# os_fileperm (0640) so the assertions also guard against that bug returning --
# if the passed conf were ignored, the real config's perm would be applied and
# the exact-match checks would fail. nmis_group is the current user's own group
# so the non-root group/chown path is a no-op and only chmod is exercised.
sub test_conf
{
	my %over = @_;
	return {
		nmis_user       => $mylogin,
		nmis_group      => $mygroup,
		os_fileperm     => "0640",
		os_execperm     => "0770",
		nmis_executable => '\.pl$',
		'<nmis_base>'   => "/tmp",
		%over,
	};
}

my $mode = sub { (stat($_[0]))[2] & 07777 };

# ---------------------------------------------------------------------------
# 1. setFileProtDirectory recursion scope
#    Proves the var force-fix (recurse=0) touches only top-level files and
#    never descends into a subdir like nmis_system/ (where the pidfile lives).
# ---------------------------------------------------------------------------
subtest 'setFileProtDirectory respects the recurse flag (var is non-recursive)' => sub {
	local $ENV{CONTAINER} = 0;	# setFileProtDiag no-ops when CONTAINER=1

	my $dir = tempdir(CLEANUP => 1);
	my $topfile = "$dir/topfile";			# directly under the dir
	my $subdir  = "$dir/nmis_system";		# mimics var/nmis_system
	my $subfile = "$subdir/nmisd.pid";		# mimics the pidfile

	make_path($subdir);
	for my $f ($topfile, $subfile)
	{
		open(my $fh, ">", $f) or die "cannot create $f: $!";
		close($fh);
		chmod(0600, $f);
	}

	my $conf = test_conf();		# os_fileperm => 0640

	# non-recursive pass: only the top-level file should be corrected
	my @err = NMISNG::Util::setFileProtDirectory($dir, 0, $conf);
	diag("setFileProtDirectory(recurse=0) notes: @err") if (grep { defined } @err);

	is($mode->($topfile), 0640, 'top-level file corrected to conf os_fileperm (0640)');
	is($mode->($subfile), 0600,
	   'file in subdir left untouched -> pidfile under nmis_system is out of force-fix scope');

	# recursive pass: now the subdir file is corrected too
	@err = NMISNG::Util::setFileProtDirectory($dir, 1, $conf);
	diag("setFileProtDirectory(recurse=1) notes: @err") if (grep { defined } @err);

	is($mode->($subfile), 0640, 'subdir file corrected to conf os_fileperm once recursion is enabled');
};

# ---------------------------------------------------------------------------
# 2. writeHashtoFile normalises permissions via setFileProtDiag
#    This is why nmisd_state.json gets fixed: it is written this way.
# ---------------------------------------------------------------------------
subtest 'writeHashtoFile applies setFileProtDiag (perms normalised on write)' => sub {
	local $ENV{CONTAINER} = 0;

	my $dir  = tempdir(CLEANUP => 1);
	# getFileName() rewrites the extension, so ask it for the real target path
	my $file = "$dir/state.json";
	my $conf = test_conf();		# os_fileperm => 0640
	my $real = NMISNG::Util::getFileName(file => $file, json => 1, conf => $conf);

	# create the target with deliberately wrong perms first
	open(my $fh, ">", $real) or die "cannot create $real: $!";
	close($fh);
	chmod(0600, $real);

	my $err = NMISNG::Util::writeHashtoFile(
		file => $file, data => { hello => "world" }, json => 1, conf => $conf);
	is($err, undef, 'writeHashtoFile succeeded') or diag("error: $err");
	ok(-f $real, "state file exists after write ($real)");
	is($mode->($real), 0640, 'mode normalised to conf os_fileperm (0640)');
};

# ---------------------------------------------------------------------------
# 3. The audit (checkFile / checkDirectoryFiles) is READ-ONLY
#    It reports problems but must not change mode or ownership.
#    Needs a loadable config (checkFile calls loadConfTable internally).
# ---------------------------------------------------------------------------
subtest 'permission audit is read-only (checkFile/checkDirectoryFiles do not mutate)' => sub {
	my $conf = eval { NMISNG::Util::loadConfTable() };
	plan skip_all => "config not loadable as this user (need root/nmis): $@"
		if (!ref($conf) || $@);

	my $dir  = tempdir(CLEANUP => 1);
	my $file = "$dir/auditme";
	open(my $fh, ">", $file) or die "cannot create $file: $!";
	close($fh);
	chmod(0606, $file);				# deliberately odd perms

	my @before = (stat($file))[2, 4, 5];	# mode, uid, gid

	my ($fstatus, @fmsg) = NMISNG::Util::checkFile($file, strictperms => "false");
	ok(defined $fstatus, 'checkFile returns a status');

	my ($dstatus, @dmsg) =
		NMISNG::Util::checkDirectoryFiles($dir, recurse => "true", strictperms => "false");
	ok(defined $dstatus, 'checkDirectoryFiles returns a status');

	my @after = (stat($file))[2, 4, 5];
	is_deeply(\@after, \@before,
	          'file mode/uid/gid unchanged after audit -> audit does not fix');
};

# ---------------------------------------------------------------------------
# 4. Source-level guards: claims about the daemon main script and the unit
#    file that cannot be exercised by calling a function.
# ---------------------------------------------------------------------------
subtest 'source guards: pidfile path, privilege drop, unit file, selftest var pass' => sub {
	my $slurp = sub {
		my $p = shift;
		open(my $fh, "<", $p) or return undef;
		local $/; my $c = <$fh>; close($fh); return $c;
	};

	my $nmisd = $slurp->("$FindBin::Bin/../bin/nmisd");
	ok(defined $nmisd, 'read bin/nmisd');
	SKIP: {
		skip "bin/nmisd unreadable", 3 if !defined $nmisd;
		like($nmisd, qr/chmod\s*\(\s*0644/,
		     'pidfile is created with chmod 0644');
		# note: \b stops this matching $pidFileDir, which IS legitimately
		# protected (the directory, not the pidfile itself)
		unlike($nmisd, qr/setFileProtDiag\s*\(\s*file\s*=>\s*\$pidFile\b/,
		       'pidfile itself is never passed through setFileProtDiag (so never chowned)');
		unlike($nmisd, qr/\bsetuid\b/,
		       'nmisd does not call setuid -> keeps the user systemd started it as');
	}

	my $util = $slurp->("$FindBin::Bin/../lib/NMISNG/Util.pm");
	ok(defined $util, 'read lib/NMISNG/Util.pm');
	SKIP: {
		skip "Util.pm unreadable", 3 if !defined $util;
		like($util, qr/setFileProtDiag\(file\s*=>\s*\$file/,
		     'writeHashtoFile path calls setFileProtDiag on the written file');
		like($util, qr/setFileProtDirectory\(\$config->\{'<nmis_var>'\}\s*,\s*0\b/,
		     'selftest force-fixes var non-recursively (recurse arg = 0)');
		like($util, qr/permission_test: auditing/,
		     'selftest logs each audited directory so the affected paths are visible');
	}

	my $unit = $slurp->("$FindBin::Bin/../conf-default/init/nmis9d.service");
	ok(defined $unit, 'read conf-default/init/nmis9d.service');
	SKIP: {
		skip "unit file unreadable", 1 if !defined $unit;
		unlike($unit, qr/^\s*User\s*=/m,
		       'systemd unit has no User= -> nmisd runs as root -> pidfile root:root');
	}
};

# ---------------------------------------------------------------------------
# 5. Real chown to nmis:nmis (root only)
#    Verifies setFileProtDiag actually changes ownership, which is the
#    mechanism that flips nmisd_state.json to nmis:nmis on write.
# ---------------------------------------------------------------------------
subtest 'setFileProtDiag chowns to nmis:nmis (root only)' => sub {
	my $nmisuid = getpwnam("nmis");
	my $nmisgid = getgrnam("nmis");
	plan skip_all => "not root" if ($> != 0);
	plan skip_all => "nmis user/group not present"
		if (!defined $nmisuid || !defined $nmisgid);

	local $ENV{CONTAINER} = 0;
	my $dir  = tempdir(CLEANUP => 1);
	my $file = "$dir/ownme";
	open(my $fh, ">", $file) or die "cannot create $file: $!";
	close($fh);
	chown(0, 0, $file);				# start as root:root, like a fresh pidfile

	my $conf = {
		nmis_user => "nmis", nmis_group => "nmis",
		os_fileperm => "0660", os_execperm => "0770", nmis_executable => '\.pl$',
		'<nmis_base>' => "/tmp",
	};
	my $err = NMISNG::Util::setFileProtDiag(file => $file, conf => $conf);
	is($err, undef, 'setFileProtDiag succeeded') or diag("error: $err");

	my ($uid, $gid) = (stat($file))[4, 5];
	is($uid, $nmisuid, 'owner changed to nmis');
	is($gid, $nmisgid, 'group changed to nmis');
};

done_testing();
