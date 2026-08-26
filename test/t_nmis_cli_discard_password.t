#!/usr/bin/perl
#
# OMK-12688: act=discard-initial-password. Removes the initial-password file
# once anyone has logged into the GUI, so a plaintext admin password does not
# outlive its purpose. nmisd runs this from its hourly purge job.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Path ();
use POSIX ();
use JSON::XS;

# NMIS_* is merged into the config as layer 4, so an exported one on the
# developer or CI machine would change what these cases measure.
delete @ENV{ grep { /^NMIS_/ } keys %ENV };

my $tool = "$FindBin::Bin/../bin/nmis-cli";
my $dir  = tempdir(CLEANUP => 1);

# audit_log resolves <nmis_logs> from the real config, so redirect it or every
# case appends to the live audit.log.
my $logdir = "$dir/logs";
mkdir($logdir) or die "cannot create $logdir: $!";

# where users_login.json lives for these runs. Auth.pm resolves this as
# last_login_dir // <nmis_var>/nmis_system, and NMIS_last_login_dir overrides it.
my $logindir = "$dir/logins";
mkdir($logindir) or die "cannot create $logindir: $!";

# One temp NMIS home per exec site. Without one, loadConfTable resolves conf/
# relative to bin/nmis-cli and persists a generated cluster_id into the checkout.
# Per site rather than shared, so the guard at the end can tell WHICH site
# misbehaved instead of passing as long as any one of them did.
my $CONFSRC = "$FindBin::Bin/../conf-default/Config.nmis";
sub make_home
{
	my ($name) = @_;
	my $home = "$dir/home-$name";
	File::Path::make_path("$home/conf", "$home/conf-default", "$home/logs", "$home/var");
	# the defaults layer must be the real conf-default/Config.nmis with <nmis_base>
	# retargeted: a stub without it makes loadConfTable die in its own cluster_id
	# write-back and every case then fails for the wrong reason.
	open(my $in, '<', $CONFSRC) or die "read $CONFSRC: $!";
	open(my $out, '>', "$home/conf-default/Config.nmis") or die "write $home: $!";
	# die on zero rewrites: a silent miss leaves <nmis_base> on the checkout.
	my $rewrites = 0;
	while (my $line = <$in>)
	{
		$rewrites += ($line =~ s/'<nmis_base>'(\s*=>\s*)'[^']*'/'<nmis_base>'$1'$home'/);
		print $out $line;
	}
	close $in;
	close $out;
	die "no <nmis_base> line rewritten in $CONFSRC, refusing to run against the checkout\n"
		if (!$rewrites);
	return $home;
}
my %HOME = map { $_ => make_home($_) } qw(run);
my %HOME_USED;

sub spew { my ($p, $c) = @_; open(my $f, '>', $p) or die $!; print $f $c; close $f; }
sub slurp { my ($p) = @_; open(my $f, '<', $p) or die $!; local $/; my $c = <$f>; close $f; return $c; }

# the pwfile as the seeder writes it, then stamped to a known mtime so the
# before/after comparisons are deterministic rather than racing the clock.
my $BASE = time() - 3600;

sub make_pwfile
{
	my ($path, $user, $password) = @_;
	$user     //= 'nmis';
	$password //= 'SomeGeneratedPassword1';
	spew($path, <<"FILE");
NMIS initial administrator login
username: $user
password: $password

Delete this file once you have recorded the password.
FILE
	utime($BASE, $BASE, $path) or die "utime $path: $!";
	return $path;
}

sub make_logins
{
	my (%logins) = @_;
	spew("$logindir/users_login.json", JSON::XS->new->encode(\%logins));
}

# fork and exec with no shell, folding STDERR into the pipe
sub run
{
	my ($pwfile, @a) = @_;
	$HOME_USED{run} = 1;
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		open(STDERR, '>&', \*STDOUT);
		$ENV{NMIS_nmis_logs}             = $logdir;
		$ENV{NMIS_last_login_dir}        = $logindir;
		$ENV{NMIS_INITIAL_PASSWORD_FILE} = $pwfile;
		exec($tool, "act=discard-initial-password", "dir=$HOME{run}", @a)
			or POSIX::_exit(127);
	}
	local $/;
	my $out = <$p> // '';
	close $p;
	return ($? >> 8, $out);
}

ok(-x $tool, 'nmis-cli is executable');

# 1. any user's login after the file was written retires it. deliberately not
# the nmis user: an LDAP or SSO site never logs in as nmis, and a provisioned
# admin account exists without an nmis login ever happening.
{
	my $pw = "$dir/pw-1";
	make_pwfile($pw);
	make_logins(alice => $BASE + 60);
	my ($rc, $out) = run($pw);
	is($rc, 0, 'login after the pwfile was written: exit 0');
	ok(!-e $pw, 'login after the pwfile was written: the file is removed');
}

# 2. a login that predates the file is not evidence anyone has seen it. this is
# the re-seed case: seed, log in, re-seed, and the old login must not retire the
# new file.
{
	my $pw = "$dir/pw-2";
	make_pwfile($pw);
	make_logins(alice => $BASE - 60);
	my ($rc) = run($pw);
	is($rc, 0, 'login predating the pwfile: exit 0');
	ok(-e $pw, 'login predating the pwfile: the file is kept');
}

# 3. no login file at all means nobody has ever logged in
{
	my $pw = "$dir/pw-3";
	make_pwfile($pw);
	unlink("$logindir/users_login.json");
	my ($rc) = run($pw);
	is($rc, 0, 'no login file: exit 0');
	ok(-e $pw, 'no login file: the file is kept');
}

# 4. boundary: a login at exactly the pwfile mtime counts as after it
{
	my $pw = "$dir/pw-4";
	make_pwfile($pw);
	make_logins(alice => $BASE);
	my ($rc) = run($pw);
	is($rc, 0, 'login exactly at the mtime: exit 0');
	ok(!-e $pw, 'login exactly at the mtime: the file is removed');
}

# 5. an unreadable login file must not be read as "nobody logged in" OR as
# "somebody did". fail closed, keep the file, say so.
{
	my $pw = "$dir/pw-5";
	make_pwfile($pw);
	spew("$logindir/users_login.json", "{not valid json");
	my ($rc, $out) = run($pw);
	isnt($rc, 0, 'corrupt login file: fails closed');
	ok(-e $pw, 'corrupt login file: the file is kept');
	like($out, qr/cannot read|cannot parse/i, 'corrupt login file: says why');
}

# 6. the removal is audited, naming the login that triggered it, and neither the
# password nor the file's contents end up in the log.
{
	my $pw = "$dir/pw-6";
	make_pwfile($pw, 'nmis', 'TopSecretGenerated9');
	make_logins(alice => $BASE + 60);
	my ($rc) = run($pw);
	is($rc, 0, 'audited removal: exit 0');
	# read defensively: a missing audit.log must fail the assertions below
	# rather than die here and abort the whole run.
	my $log = (-e "$logdir/audit.log") ? slurp("$logdir/audit.log") : '';
	like($log, qr/discarded initial password/, 'the removal is audited');
	like($log, qr/alice/, 'the audit names the login that triggered it');
	unlike($log, qr/TopSecretGenerated9/, 'the password is not in the audit log');
}

# 7. nothing to do is not an error. nmisd calls this every purge cycle forever.
{
	my $pw = "$dir/pw-7-absent";
	unlink $pw;
	make_logins(alice => $BASE + 60);
	my ($rc, $out) = run($pw);
	is($rc, 0, 'no pwfile: exit 0');
	is($out, '', 'no pwfile: silent');
}

# 8. users_login.json is owned and written by the web user, so its values are
# untrusted. anything that is not a plain timestamp must not decide this.
{
	my $pw = "$dir/pw-8";
	make_pwfile($pw);
	make_logins(alice => "not-a-timestamp", bob => {nested => 1}, carol => undef);
	my ($rc) = run($pw);
	is($rc, 0, 'junk login values: exit 0');
	ok(-e $pw, 'junk login values: none of them retire the file');
}

# 9. an empty login map is nobody having logged in
{
	my $pw = "$dir/pw-9";
	make_pwfile($pw);
	make_logins();
	my ($rc) = run($pw);
	is($rc, 0, 'empty login map: exit 0');
	ok(-e $pw, 'empty login map: the file is kept');
}

# 10. a symlink planted at the pwfile path must cost the link, never the target
# (CWE-59), matching how the seeder writes the file. the target is stamped older
# than the login so the reaper actually acts, otherwise this proves nothing.
{
	my $pw     = "$dir/pw-10";
	my $target = "$dir/pw-10-target";
	spew($target, "KEEP\n");
	utime($BASE - 120, $BASE - 120, $target) or die "utime failed: $!";
	chmod(0644, $target) or die "chmod failed: $!";
	symlink($target, $pw) or die "symlink failed: $!";
	make_logins(alice => $BASE + 60);
	my ($rc) = run($pw);
	is($rc, 0, 'planted symlink: exit 0');
	ok(!-l $pw, 'planted symlink: the link itself is removed');
	is(slurp($target), "KEEP\n", 'planted symlink: the target contents survive');
	is(sprintf("%04o", (stat($target))[2] & 07777), '0644',
		'planted symlink: the target mode is untouched');
}

# 11. nmisd must keep calling this. The action is useless on its own: nothing
# else runs as root at the right moment, so losing the wiring silently reverts
# the whole feature. nmisd cannot be run here, so assert it structurally.
{
	my $nmisd = "$FindBin::Bin/../bin/nmisd";
	SKIP: {
		skip "bin/nmisd not present", 2 unless -f $nmisd;
		my $body = slurp($nmisd);
		like($body, qr/act=discard-initial-password/,
			'nmisd invokes the discard action');
		like($body, qr/nmis-initial-password/,
			'nmisd stats the file before forking');
	}
}

# 12. users_login.json is web-writable, and the triggering username goes into the
# root-owned audit log. a newline in it must not forge a second record: audit.log
# is one tab-delimited line per event and readers split on newlines.
{
	my $pw = "$dir/pw-12";
	make_pwfile($pw);
	unlink("$logdir/audit.log");
	make_logins("alice\n[FORGED]\tnmis\tforged entry\tinjected\tby a username"
		=> $BASE + 60);
	my ($rc) = run($pw);
	is($rc, 0, 'newline in username: exit 0');
	my $log = (-e "$logdir/audit.log") ? slurp("$logdir/audit.log") : '';
	my @records = grep { /\S/ && !/^#/ } split(/\n/, $log);
	is(scalar(@records), 1, 'newline in username: exactly one audit record written');
	unlike($log, qr/^\[FORGED\]/m, 'newline in username: no forged record');
}

# 13. the children must not write into the checkout they run from. loadConfTable
# mkpaths its config dir and persists a missing cluster_id, so without dir= these
# runs create conf/Config.nmis in the tree. Asserted positively: a live install
# legitimately has its own conf/, so absence there would prove nothing.
# Either extension counts, getFileName flips to .json when the path holds a 'var'
# component and use_json is on.
for my $site (sort keys %HOME_USED)
{
	ok(-e "$HOME{$site}/conf/Config.nmis" || -e "$HOME{$site}/conf/Config.json",
		"$site wrote its config into its own temp home, not the checkout");
}
is(scalar(keys %HOME_USED), scalar(keys %HOME),
	'every exec site defined here was exercised');

done_testing;
