#!/usr/bin/perl
#
# OMK-12705: htpasswd password administration, folded into bin/nmis-cli
# (formerly the standalone admin/user_admin.pl) as act=set-htpasswd-password,
# act=list-htpasswd and act=delete-htpasswd-user.
#
# Unlike the former standalone tool, nmis-cli loads a full NMIS config and
# opens a MongoDB connection before dispatching any action, so these tests
# need a working config and a reachable database, same as the rest of the
# suite.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use POSIX ();
use Crypt::PasswdMD5 ();    # an apr1 fixture for the LEGACY label case
use NMISNG::Util;

my $tool = "$FindBin::Bin/../bin/nmis-cli";
my $dir  = tempdir(CLEANUP => 1);

# audit_log resolves <nmis_logs> from the real config, so without this every
# set_password and delete case appends to the live audit.log.
my $logdir = "$dir/logs";
mkdir($logdir) or die "cannot create $logdir: $!";

sub spew { my ($p, $c) = @_; open(my $f, '>', $p) or die $!; print $f $c; close $f; }
sub slurp { my ($p) = @_; open(my $f, '<', $p) or die $!; local $/; my $c = <$f>; close $f; return $c; }
# fork and exec with no shell, and fold STDERR into the pipe because the tool
# reports usage and operational errors there.
sub run
{
	my @a  = @_;
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		open(STDERR, '>&', \*STDOUT);
		$ENV{NMIS_nmis_logs} = $logdir;   # keep audit_log out of the live log
		# "or" rather than a following statement: perl warns "statement unlikely
		# to be reached" after exec under use warnings, and that noise lands in CI.
		exec($tool, @a) or POSIX::_exit(127);
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

	# nmis-cli's own dispatch, not the htpasswd action: an unrecognised act
	# exits 255 (its established convention), not the 1 the old standalone
	# tool used.
	($rc, $out) = run("act=nonsense", "file=$f");
	is($rc, 255, 'an unknown act exits 255');

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

done_testing();
