#!/usr/bin/perl
#
# OMK-12705: htpasswd password administration, folded into bin/nmis-cli
# (formerly the standalone admin/user_admin.pl) as act=set-htpasswd-password,
# act=list-htpasswd and act=delete-htpasswd-user.
#
# These actions dispatch before nmis-cli opens its database connection, so the
# tests need a working config but no reachable database.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Path ();
use POSIX ();
use Crypt::PasswdMD5 ();    # an apr1 fixture for the LEGACY label case
use NMISNG::Util;

# NMIS_* is merged into the config as layer 4, so an exported one on the
# developer or CI machine would change what these cases measure.
delete @ENV{ grep { /^NMIS_/ } keys %ENV };

my $tool = "$FindBin::Bin/../bin/nmis-cli";
my $dir  = tempdir(CLEANUP => 1);

# audit_log resolves <nmis_logs> from the real config, so without this every
# set_password and delete case appends to the live audit.log.
my $logdir = "$dir/logs";
mkdir($logdir) or die "cannot create $logdir: $!";

# changing a password must evict that account's sessions, so the children need a
# throwaway session_dir. Auth resolves it as session_dir // <nmis_var>/nmis_system/user_session.
my $sessiondir = "$dir/sessions";
mkdir($sessiondir) or die "cannot create $sessiondir: $!";

# minimal CGI::Session file. read_session_fields only pulls username and
# _SESSION_ATIME out with a regex, so this is enough to be counted and evicted.
sub make_session
{
	my ($id, $user) = @_;
	open(my $f, '>', "$sessiondir/cgisess_$id") or die "write session $id: $!";
	print $f "\$D = {'_SESSION_ID' => '$id','username' => '$user','_SESSION_ATIME' => '".time."'};";
	close $f;
	return "$sessiondir/cgisess_$id";
}

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
my %HOME = map { $_ => make_home($_) } qw(run nodb);
my %HOME_USED;

sub spew { my ($p, $c) = @_; open(my $f, '>', $p) or die $!; print $f $c; close $f; }
sub slurp { my ($p) = @_; open(my $f, '<', $p) or die $!; local $/; my $c = <$f>; close $f; return $c; }
# fork and exec with no shell, and fold STDERR into the pipe because the tool
# reports usage and operational errors there.
sub run
{
	my @a  = @_;
	$HOME_USED{run} = 1;
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		open(STDERR, '>&', \*STDOUT);
		$ENV{NMIS_nmis_logs}   = $logdir;   # keep audit_log out of the live log
		$ENV{NMIS_session_dir} = $sessiondir;
		# "or" rather than a following statement: perl warns "statement unlikely
		# to be reached" after exec under use warnings, and that noise lands in CI.
		exec($tool, "dir=$HOME{run}", @a) or POSIX::_exit(127);
	}
	local $/;
	my $out = <$p> // '';
	close $p;
	return ($? >> 8, $out);
}

ok(-x $tool, 'nmis-cli is executable');

# set-htpasswd-password writes a sha512 hash that verifies
{
	my $f = "$dir/set.dat";
	spew($f, "alice:aaa\n");
	my ($rc, $out) = run("act=set-htpasswd-password", "user=bob", "password=secret12", "file=$f");
	is($rc, 0, 'set-htpasswd-password exits 0');
	my ($hash) = slurp($f) =~ /^bob:(.+)$/m;
	like($hash, qr/^\$6\$rounds=100000\$/, 'the stored hash is sha512');
	is(crypt('secret12', $hash), $hash, 'and verifies against the password');
	like(slurp($f), qr/^alice:aaa$/m, 'the other entry survives');
	# this covers the success message, NOT terminal no-echo: password= was given
	# on the command line so the prompt never ran. no-echo needs a tty.
	unlike($out, qr/secret12/, 'the password is not repeated back in the output');
}

# set-htpasswd-password overwrites an existing password, unlike the 12688 seeder
{
	my $f = "$dir/over.dat";
	spew($f, "bob:EXISTING\n");
	my ($rc) = run("act=set-htpasswd-password", "user=bob", "password=new12345", "file=$f");
	is($rc, 0, 'overwriting an existing password exits 0');
	my ($hash) = slurp($f) =~ /^bob:(.+)$/m;
	is(crypt('new12345', $hash), $hash, 'the new password is in place');
}

# list-htpasswd reports the scheme and never a hash
{
	my $f = "$dir/list.dat";
	my $des = crypt('x', 'ab');
	my $sha = NMISNG::Util::hash_password('x', 'sha512', 1000);
	spew($f, "olduser:$des\nnewuser:$sha\nlocked:*\n");
	my ($rc, $out) = run("act=list-htpasswd", "file=$f");
	is($rc, 0, 'list-htpasswd exits 0');
	like($out, qr/olduser\s+des \(LEGACY\)/, 'a DES entry is flagged LEGACY');
	like($out, qr/newuser\s+sha512/,         'a sha512 entry is named sha512');
	like($out, qr/locked\s+locked/,          'a locked entry is reported as locked');
	unlike($out, qr/\Q$des\E/, 'the DES hash is not printed');
	unlike($out, qr/\Q$sha\E/, 'the sha512 hash is not printed');
}

# list-htpasswd flags apr1 as legacy too
{
	my $f = "$dir/list2.dat";
	# a literal fixture: hash_password cannot produce apr1, by design
	spew($f, 'a:' . Crypt::PasswdMD5::apache_md5_crypt('x', 'abcdefgh') . "\nb:\n");
	my ($rc, $out) = run("act=list-htpasswd", "file=$f");
	is($rc, 0, 'list-htpasswd exits 0');
	like($out, qr/^a\s+apr1 \(LEGACY\)/m, 'an apr1 entry is flagged LEGACY');
	like($out, qr/^b\s+none/m,            'an empty hash is reported as none');
}

# delete-htpasswd-user removes the entry, and says so honestly when there was
# nothing to remove
{
	my $f = "$dir/del.dat";
	spew($f, "alice:aaa\nbob:bbb\n");
	my ($rc, $out) = run("act=delete-htpasswd-user", "user=bob", "file=$f");
	is($rc, 0, 'delete-htpasswd-user exits 0');
	is(slurp($f), "alice:aaa\n", 'bob removed, alice kept');
	like($out, qr/Removed user bob/, 'and reports the removal');

	# deleting an absent user must not claim it removed something
	($rc, $out) = run("act=delete-htpasswd-user", "user=ghost", "file=$f");
	is($rc, 0, 'deleting an absent user exits 0');
	like($out, qr/not present/, 'and says it was not present rather than claiming a removal');
	is(slurp($f), "alice:aaa\n", 'and changed nothing');
}

# usage errors are rejected, not guessed at
{
	my $f = "$dir/usage.dat";
	spew($f, "bob:bbb\n");
	my ($rc, $out) = run("act=set-htpasswd-password", "file=$f");
	is($rc, 1, 'set-htpasswd-password without a user exits 1');
	like($out, qr/user/i, 'and says a user is required');

	# nmis-cli's own dispatch, not the htpasswd action: an unrecognised act must
	# be rejected, never silently treated as a no-op. nmis-cli's "Unrecognized
	# action" catch-all exits 255, but that sits after the database connection,
	# which this suite deliberately runs without (the htpasswd actions dispatch
	# before it), so an unknown act dies earlier at the connect instead of
	# reaching the 255 handler. Assert only the invariant that holds either way:
	# a non-zero exit, i.e. the act was not silently accepted.
	($rc, $out) = run("act=nonsense", "file=$f");
	isnt($rc, 0, 'an unknown act is rejected, not silently accepted');

	($rc, $out) = run("act=set-htpasswd-password", "user=bob", "password=x", "file=$dir/nope.dat");
	is($rc, 2, 'a missing password file exits 2, an operational failure');
	ok(!-e "$dir/nope.dat", 'and did NOT silently create it');
	is(slurp($f), "bob:bbb\n", 'and no other file was touched');
}

# --version and --help work without a config
{
	my ($rc, $out) = run("--version");
	is($rc, 0, '--version exits 0');
	like($out, qr/version=/, 'and prints a version');

	($rc, $out) = run("--help");
	is($rc, 0, '--help exits 0');
	like($out, qr/act=set-htpasswd-password/, 'and lists the verb');
	like($out, qr/Users\.nmis/, 'and says privileges live in Users.nmis');
}

# the change is audited into the configured log, and neither the password nor
# the hash is recorded
{
	my $f = "$dir/audit.dat";
	spew($f, "alice:aaa\n");
	my ($rc) = run("act=set-htpasswd-password", "user=bob", "password=audited1", "file=$f");
	is($rc, 0, 'set-htpasswd-password exits 0');
	my $log = slurp("$logdir/audit.log");
	like($log, qr/\tset htpasswd password\t\Q$f\E\tnmis-cli\tset password for user bob/,
	     'the audit line names the operation, the file and the user');
	unlike($log, qr/audited1/, 'the password is not in the audit log');
	my ($hash) = slurp($f) =~ /^bob:(.+)$/m;
	unlike($log, qr/\Q$hash\E/, 'nor is the hash');
}

# a delete is audited too
{
	my $f = "$dir/auditdel.dat";
	spew($f, "bob:bbb\n");
	my ($rc) = run("act=delete-htpasswd-user", "user=bob", "file=$f");
	is($rc, 0, 'delete-htpasswd-user exits 0');
	like(slurp("$logdir/audit.log"),
	     qr/\tdeleted htpasswd user\t\Q$f\E\tnmis-cli\tremoved user bob/,
	     'the delete is audited');
}

# the audit log lives in the tempdir, not wherever the real config points
{
	ok(-f "$logdir/audit.log", 'the audit log was written inside the tempdir');
}

# the htpasswd actions must not need a database: the installer seeds a password
# at hook 05, and mongodb is not set up until hook 24.
{
	my $f = "$dir/nodb.dat";
	spew($f, "alice:aaa\n");
	$HOME_USED{nodb} = 1;
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		open(STDERR, '>&', \*STDOUT);
		$ENV{NMIS_nmis_logs} = $logdir;
		$ENV{NMIS_db_port}   = '39999';    # nothing listens here
		exec($tool, "dir=$HOME{nodb}", "act=list-htpasswd", "file=$f")
			or POSIX::_exit(127);
	}
	local $/;
	my $out = <$p> // '';
	close $p;
	my $rc = $? >> 8;
	is($rc, 0, 'list-htpasswd exits 0 with mongodb unreachable');
	like($out, qr/^alice\s+/m, 'and still lists the entry');
	unlike($out, qr/cannot connect to MongoDB/, 'no database connection was attempted');
}

# the children must not write into the checkout they run from. loadConfTable
# persists a missing cluster_id, so without dir= the runs above leave a
# generated conf/Config.nmis in the tree. Either extension counts, for the
# reason given at the end of t_nmis_cli_seed_password.t.
# PER exec site: each helper has its own home, so one misbehaving site cannot
# hide behind a well-behaved one.
for my $site (sort keys %HOME_USED)
{
	ok(-e "$HOME{$site}/conf/Config.nmis" || -e "$HOME{$site}/conf/Config.json",
		"$site wrote its config into its own temp home, not the checkout");
}
is(scalar(keys %HOME_USED), scalar(keys %HOME),
	'every exec site defined here was exercised');

# set-htpasswd-password is what an admin runs when they suspect a credential is
# compromised, so a session opened with the old password must not survive it
# (OWASP ASVS V3.3.3). Scoped to that account: nobody else's password changed.
{
	my $f = "$dir/evict.dat";
	spew($f, "nmis:x\nalice:y\n");
	my $nmis_sess  = make_session("set_nmis",  "nmis");
	my $other_sess = make_session("set_alice", "alice");
	my ($rc) = run("act=set-htpasswd-password", "user=nmis", "password=BrandNewSecret1",
		"file=$f");
	is($rc, 0, 'set-htpasswd-password with live sessions: exit 0');
	ok(!-e $nmis_sess, "set-htpasswd-password evicts that account's sessions");
	ok(-e $other_sess, "set-htpasswd-password leaves other accounts alone");
}

done_testing();
