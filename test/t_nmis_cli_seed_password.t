#!/usr/bin/perl
#
# OMK-12688: act=seed-htpasswd-password, folded into bin/nmis-cli from the
# standalone admin/set_admin_password.pl. Sets a random password only when the
# account is unconfigured, so it is safe on every install and container start.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Path ();
use POSIX ();
use Crypt::PasswdMD5 qw(apache_md5_crypt);
use NMISNG::Util;

# NMIS_* is merged into the config as layer 4, so an exported one on the
# developer or CI machine would change what these cases measure. Each run sets
# the two it actually wants.
delete @ENV{ grep { /^NMIS9?_/ } keys %ENV };

my $tool = "$FindBin::Bin/../bin/nmis-cli";
my $dir  = tempdir(CLEANUP => 1);

# audit_log resolves <nmis_logs> from the real config, so redirect it or every
# seeding case appends to the live audit.log.
my $logdir = "$dir/logs";
mkdir($logdir) or die "cannot create $logdir: $!";

# rotating a password must evict that account's sessions, so the runs need a
# throwaway session_dir. Auth resolves it as session_dir // <nmis_var>/nmis_system/user_session.
my $sessiondir = "$dir/sessions";
mkdir($sessiondir) or die "cannot create $sessiondir: $!";

# minimal CGI::Session file. read_session_fields only pulls username and
# _SESSION_ATIME out with a regex, so this is enough to be counted and evicted.
sub make_session
{
	my ($id, $user, $atime) = @_;
	$atime //= time;
	open(my $f, '>', "$sessiondir/cgisess_$id") or die "write session $id: $!";
	print $f "\$D = {'_SESSION_ID' => '$id','username' => '$user','_SESSION_ATIME' => '$atime'};";
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
my %HOME = map { $_ => make_home($_) } qw(run run_pwfile run_env);
my %HOME_USED;

sub spew { my ($p, $c) = @_; open(my $f, '>', $p) or die $!; print $f $c; close $f; }
sub slurp { my ($p) = @_; open(my $f, '<', $p) or die $!; local $/; my $c = <$f>; close $f; return $c; }

# fork and exec with no shell, folding STDERR into the pipe. Models the CONTAINER
# caller: password via the environment, and no opt-in to generating one.
sub run_env
{
	my ($extra, $pwfile, @a) = @_;
	$HOME_USED{run_env} = 1;
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		open(STDERR, '>&', \*STDOUT);
		$ENV{NMIS_nmis_logs}             = $logdir;
		$ENV{NMIS_session_dir}           = $sessiondir;
		$ENV{NMIS_INITIAL_PASSWORD_FILE} = $pwfile;
		$ENV{$_} = $extra->{$_} for (keys %$extra);
		exec($tool, "act=seed-htpasswd-password", "dir=$HOME{run_env}", @a)
			or POSIX::_exit(127);
	}
	local $/;
	my $out = <$p> // '';
	close $p;
	return ($? >> 8, $out);
}

# throwaway pwfile so the real /usr/local/etc/firstwave one is never touched.
sub run
{
	my @a = @_;
	$HOME_USED{run} = 1;
	my $pwdir = tempdir(CLEANUP => 1);
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		open(STDERR, '>&', \*STDOUT);
		$ENV{NMIS_nmis_logs}             = $logdir;
		$ENV{NMIS_session_dir}           = $sessiondir;
		$ENV{NMIS_INITIAL_PASSWORD_FILE} = "$pwdir/nmis-initial-password";
		# this and run_pwfile model the INSTALLER caller, which opts in
		exec($tool, "act=seed-htpasswd-password", "dir=$HOME{run}",
			"generate-password=t", @a) or POSIX::_exit(127);
	}
	local $/;
	my $out = <$p> // '';
	close $p;
	return ($? >> 8, $out);
}

# run with an explicit pwfile path so its contents and mode can be inspected
sub run_pwfile
{
	my ($pwfile, @a) = @_;
	$HOME_USED{run_pwfile} = 1;
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		open(STDERR, '>&', \*STDOUT);
		$ENV{NMIS_nmis_logs}             = $logdir;
		$ENV{NMIS_session_dir}           = $sessiondir;
		$ENV{NMIS_INITIAL_PASSWORD_FILE} = $pwfile;
		# installer caller, so it opts into generating. See run() above.
		exec($tool, "act=seed-htpasswd-password", "dir=$HOME{run_pwfile}",
			"generate-password=t", @a) or POSIX::_exit(127);
	}
	local $/;
	my $out = <$p> // '';
	close $p;
	return ($? >> 8, $out);
}

sub nmis_hash
{
	my ($p) = @_;
	my ($h) = slurp($p) =~ /^nmis:(.*)$/m;
	return $h;
}

# what conf-default/users.dat ships. nmis-cli replaces this on sight, with no
# caller-supplied context, which is what removed the old seed=t|f flag.
# t_seed_decision.t pins the same string in both the shipped file and nmis-cli.
my $MARKER = '*NMIS-UNSEEDED*';

ok(-x $tool, 'nmis-cli is executable');

# 1. fresh install: the shipped unseeded marker is replaced, no flag needed
{
	my $f = "$dir/seed.dat";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run("user=nmis", "file=$f");
	is($rc, 0, 'shipped marker: exit 0');
	like(nmis_hash($f), qr/^\$6\$rounds=100000\$/, 'a sha512 hash was written');
	isnt(crypt("nm1888", nmis_hash($f)), nmis_hash($f), 'nm1888 does not verify');
}

# 2. missing file: created, with an nmis line
{
	my $f = "$dir/missing.dat";
	unlink $f;
	my ($rc, $out) = run("user=nmis", "file=$f");
	is($rc, 0, 'missing file: exit 0');
	ok(-f $f, 'missing file: created');
	like(nmis_hash($f), qr/^\$6\$rounds=100000\$/, 'missing file: sha512 hash written');
}

# 3. other users are preserved
{
	my $f = "$dir/others.dat";
	spew($f, "alice:aaa\nnmis:$MARKER\nbob:bbb\n");
	my ($rc) = run("user=nmis", "file=$f");
	is($rc, 0, 'other users: exit 0');
	like(slurp($f), qr/^alice:aaa$/m, 'alice survives');
	like(slurp($f), qr/^bob:bbb$/m,   'bob survives');
}

# 4. idempotent: a real password is never touched
{
	my $f = "$dir/real.dat";
	my $existing = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:$existing\n");
	my ($rc, $out) = run("user=nmis", "file=$f");
	is($rc, 0, 'real password: exit 0');
	is(nmis_hash($f), $existing, 'real password: left alone');
}

# 5. a lock that is not the shipped marker is an operator lockdown, and stays
{
	my $f = "$dir/locked.dat";
	spew($f, "nmis:!\n");
	my ($rc, $out) = run("user=nmis", "file=$f");
	is($rc, 0, 'operator lock: exit 0');
	is(nmis_hash($f), '!', 'operator lock: NOT re-enabled');
}

# 6. the shipped nm1888 default is rotated (upgrade)
{
	my $f = "$dir/default.dat";
	spew($f, "nmis:SG65RBEiLjd5U\n");    # DES crypt('nm1888','SG'), shipped for years
	my ($rc) = run("user=nmis", "file=$f");
	is($rc, 0, 'nm1888, no seed: exit 0');
	like(nmis_hash($f), qr/^\$6\$rounds=100000\$/, 'nm1888, no seed: rotated');
	isnt(crypt("nm1888", nmis_hash($f)), nmis_hash($f), 'nm1888 no longer verifies');
}

# 7. an apr1-salted variant of the default is rotated too
{
	my $f = "$dir/variant.dat";
	my $variant = apache_md5_crypt("nm1888", "xyz98765");
	spew($f, "nmis:$variant\n");
	my ($rc) = run("user=nmis", "file=$f");
	is($rc, 0, 'apr1 nm1888 variant: exit 0');
	isnt(nmis_hash($f), $variant, 'apr1 nm1888 variant: rotated away');
}

# 8. duplicate nmis lines: the first usable one decides, matching Auth
{
	my $f = "$dir/dup.dat";
	my $custom = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:\nnmis:$custom\n");    # empty hash first, real one second
	my ($rc) = run("user=nmis", "file=$f");
	is($rc, 0, 'empty-first duplicate: exit 0');
	like(slurp($f), qr/\Q$custom\E/, 'empty-first duplicate: the real hash survives');
}

# 9. user= is required
{
	my ($rc, $out) = run("file=$dir/seed.dat");
	isnt($rc, 0, 'missing user= is an error');
	like($out, qr/needs user=/, 'and says so');
}

# 10. the pwfile is written 0600 and holds a password that actually verifies
{
	my $f  = "$dir/pw.dat";
	my $pw = "$dir/pwfile-10";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_pwfile($pw, "user=nmis", "file=$f");
	is($rc, 0, 'pwfile: exit 0');
	ok(-f $pw, 'pwfile: written');
	is(sprintf("%04o", (stat($pw))[2] & 07777), '0600', 'pwfile: mode 0600');
	my ($saved) = slurp($pw) =~ /^password:\s*(\S+)$/m;
	ok(defined($saved) && length($saved) >= 12, 'pwfile: holds a password');
	is(crypt($saved, nmis_hash($f)), nmis_hash($f), 'pwfile: the password verifies');
	unlike($out, qr/\Q$saved\E/, 'pwfile: the plaintext is not printed by default');
	like($out, qr/\Q$pw\E/, 'pwfile: the location is printed instead');
}

# 11. reveal=show prints the plaintext, and it matches the pwfile
{
	my $f  = "$dir/show.dat";
	my $pw = "$dir/pwfile-11";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_pwfile($pw, "user=nmis", "file=$f", "reveal=show");
	is($rc, 0, 'reveal=show: exit 0');
	my ($saved) = slurp($pw) =~ /^password:\s*(\S+)$/m;
	like($out, qr/\Q$saved\E/, 'reveal=show: prints the same password it saved');
}

# 12. reveal=none keeps the plaintext out of the output entirely
{
	my $f  = "$dir/none.dat";
	my $pw = "$dir/pwfile-12";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_pwfile($pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'reveal=none: exit 0');
	my ($saved) = slurp($pw) =~ /^password:\s*(\S+)$/m;
	unlike($out, qr/\Q$saved\E/, 'reveal=none: the plaintext is never printed');
}

# 13. an existing loose-mode pwfile is tightened before the plaintext lands in it
{
	my $f  = "$dir/loose.dat";
	my $pw = "$dir/pwfile-13";
	spew($f, "nmis:$MARKER\n");
	spew($pw, "stale\n");
	chmod(0644, $pw) or die "chmod failed: $!";
	my ($rc) = run_pwfile($pw, "user=nmis", "file=$f");
	is($rc, 0, 'loose pwfile: exit 0');
	is(sprintf("%04o", (stat($pw))[2] & 07777), '0600', 'loose pwfile: tightened to 0600');
}

# 14. recoverability guard: an unwritable pwfile plus reveal=none must not
# install a password nobody can retrieve. the store is left exactly as it was.
{
	my $f = "$dir/guard.dat";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_pwfile("/proc/cannot/write/here", "user=nmis", "file=$f",
		"reveal=none");
	isnt($rc, 0, 'guard: fails closed');
	is(nmis_hash($f), $MARKER, 'guard: the store is untouched');
	like($out, qr/refusing to install an unrecoverable password/, 'guard: says why');
}

# 15. the same failure WITHOUT reveal=none falls back to printing the password
{
	my $f = "$dir/fallback.dat";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_pwfile("/proc/cannot/write/here", "user=nmis", "file=$f");
	is($rc, 0, 'fallback: exit 0');
	my ($shown) = $out =~ /^\s*password:\s*(\S+)$/m;
	ok(defined($shown), 'fallback: the password is printed');
	is(crypt($shown, nmis_hash($f)), nmis_hash($f), 'fallback: and it verifies');
}

# 16. the shipped conf-default/users.dat carries no usable password
{
	my $shipped = "$FindBin::Bin/../conf-default/users.dat";
	ok(-e $shipped, 'shipped conf-default/users.dat exists');
	my ($h) = slurp($shipped) =~ /^nmis:(.*)$/m;
	ok(defined($h), 'shipped file has an nmis line');
	like($h, qr/^[*!]/, 'shipped nmis account is locked, no usable hash');
	is($h, $MARKER, 'shipped nmis account carries the unseeded marker');
	isnt(crypt("nm1888", $h), $h, 'shipped file: nm1888 does not verify (crypt)');
	isnt(apache_md5_crypt("nm1888", $h), $h, 'shipped file: nm1888 does not verify (apr1)');
}

# 17. a stale default FIRST and a custom hash second: Auth would authenticate
# the stale one, so the store counts as unconfigured and rotates.
{
	my $f = "$dir/dup-default-first.dat";
	my $custom = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:SG65RBEiLjd5U\nnmis:$custom\n");
	my ($rc) = run("user=nmis", "file=$f");
	is($rc, 0, 'dup default-first: exit 0');
	my @lines = grep { /^nmis:/ } split(/\n/, slurp($f));
	is(scalar(@lines), 1, 'dup default-first: collapsed to a single nmis line');
	like(nmis_hash($f), qr/^\$6\$rounds=100000\$/, 'dup default-first: rotated');
	isnt(crypt("nm1888", nmis_hash($f)), nmis_hash($f), 'dup default-first: nm1888 gone');
}

# 18. a custom hash FIRST and a stale default second: Auth authenticates the
# custom one, so the store is configured and is left alone.
{
	my $f = "$dir/dup-custom-first.dat";
	my $custom = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:$custom\nnmis:SG65RBEiLjd5U\n");
	my $before = slurp($f);
	my ($rc) = run("user=nmis", "file=$f");
	is($rc, 0, 'dup custom-first: exit 0');
	is(slurp($f), $before, 'dup custom-first: usable store left completely alone');
}

# 19. a bare '*' lock survives, and no other line is disturbed
{
	my $f = "$dir/lock-star.dat";
	spew($f, "alice:aaa\nnmis:*\n");
	my $before = slurp($f);
	my ($rc, $out) = run("user=nmis", "file=$f");
	is($rc, 0, "locked '*': exit 0");
	is(slurp($f), $before, "locked '*': file unchanged, alice preserved");
	unlike($out, qr/password/i, "locked '*': no password banner printed");
}

# 20. nothing re-enables an operator lock. only the exact marker is seeded, so
# an unrecognised extra argument cannot change that. seed=t is used here because
# an in-development flag briefly did unlock a lock, and must not come back.
for my $lock ('*', '!')
{
	my $f  = "$dir/lock-extra-arg.dat";
	my $pw = "$dir/pwfile-20";
	unlink $pw;
	spew($f, "nmis:$lock\n");
	my ($rc) = run_pwfile($pw, "user=nmis", "file=$f", "seed=t");
	is($rc, 0, "operator lock '$lock' with an extra seed=t: exit 0");
	is(nmis_hash($f), $lock, "operator lock '$lock' with an extra seed=t: still locked");
	ok(!-e $pw, "operator lock '$lock' with an extra seed=t: no password saved");
}

# 21. no invocation may touch the real initial-password file
{
	my $live = "/usr/local/etc/firstwave/nmis-initial-password";
	ok(!-e $live || (stat($live))[9] < $^T,
		'the live initial-password file was not written by this test run');
}

# 22. a failed store write is propagated as a non-zero exit and the store is
# left alone. the mid-write/.bak-restore path itself belongs to
# NMISNG::Util::set_htpasswd_entry and is covered by t_htpasswd_store.t via its
# $_htpasswd_writer seam; what matters here is that nmis-cli does not swallow
# the error. RLIMIT_FSIZE cannot be used: set_htpasswd_entry rewrites the file
# in place, and the limit does not bite on a file already over it at open time.
SKIP: {
	skip "root ignores file permissions", 2 if ($> == 0);
	my $f  = "$dir/writefail.dat";
	my $pw = "$dir/pwfile-22";
	spew($f, "alice:aaa\nnmis:$MARKER\n");
	chmod(0444, $f) or die "chmod failed: $!";
	my ($rc, $out) = run_pwfile($pw, "user=nmis", "file=$f", "reveal=none");
	isnt($rc, 0, 'unwritable store: fails closed');
	is(slurp($f), "alice:aaa\nnmis:$MARKER\n", 'unwritable store: left exactly as it was');
	chmod(0644, $f);
}

# 23. reveal= is validated. the old --no-reveal/--show-password pair needed a
# precedence rule; a single enum makes the conflict unrepresentable instead.
{
	my $f = "$dir/badreveal.dat";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run("user=nmis", "file=$f", "reveal=maybe");
	isnt($rc, 0, 'reveal=maybe is rejected');
	like($out, qr/reveal= must be auto, show or none/, 'and says what is allowed');
	is(nmis_hash($f), $MARKER, 'a rejected reveal= writes nothing');
}

# 24. only the exact marker counts. a near miss is an unrecognised hash and is
# left alone, so nothing an operator writes can be mistaken for the shipped seed.
for my $near ('*NMIS-UNSEEDED', 'NMIS-UNSEEDED*', '*nmis-unseeded*', '**NMIS-UNSEEDED*')
{
	my $f = "$dir/near-marker.dat";
	spew($f, "nmis:$near\n");
	my ($rc) = run("user=nmis", "file=$f");
	is($rc, 0, "near-miss marker '$near': exit 0");
	is(nmis_hash($f), $near, "near-miss marker '$near': left alone");
}

# 25. the seeding is audited, and neither the password nor the hash is recorded
{
	my $f  = "$dir/audit.dat";
	my $pw = "$dir/pwfile-25";
	spew($f, "nmis:$MARKER\n");
	my ($rc) = run_pwfile($pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'audited seeding: exit 0');
	my $log = slurp("$logdir/audit.log");
	like($log, qr/\tseeded htpasswd password\t\Q$f\E\tnmis-cli\tset a random password for user nmis/,
		'the seeding is audited');
	my ($saved) = slurp($pw) =~ /^password:\s*(\S+)$/m;
	unlike($log, qr/\Q$saved\E/, 'the password is not in the audit log');
	unlike($log, qr/\Q${\ nmis_hash($f) }\E/, 'nor is the hash');
}

# 26. a run that changes nothing writes no pwfile. otherwise an idempotent call
# would clobber a recorded password with one that was never installed.
{
	my $f  = "$dir/noop.dat";
	my $pw = "$dir/pwfile-26";
	my $existing = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:$existing\n");
	my ($rc) = run_pwfile($pw, "user=nmis", "file=$f");
	is($rc, 0, 'no-op run: exit 0');
	ok(!-e $pw, 'no-op run: no initial-password file written');
	is(nmis_hash($f), $existing, 'no-op run: the store is untouched');
}

# 27. _first_usable_hash skips a malformed first duplicate, so the CAS must too,
# or the rotation aborts on every run with a wrong "changed underneath us".
for my $bad ("nmis:", "nmis")
{
	my $f = "$dir/dup-malformed.dat";
	spew($f, "$bad\nnmis:SG65RBEiLjd5U\n");
	my ($rc, $out) = run("user=nmis", "file=$f");
	is($rc, 0, "malformed first line '$bad': exit 0");
	unlike($out, qr/changed while we were working/,
		"malformed first line '$bad': no spurious concurrency error");
	my @lines = grep { /^nmis/ } split(/\n/, slurp($f));
	is(scalar(@lines), 1, "malformed first line '$bad': collapsed to one line");
	like(nmis_hash($f), qr/^\$6\$rounds=100000\$/,
		"malformed first line '$bad': the stale default was rotated");
}

# 28. the pwfile is unlinked, never followed: a planted symlink must lose
# neither its target's contents nor its mode (CWE-59).
{
	my $f      = "$dir/symlink.dat";
	my $target = "$dir/symlink-target";
	my $pw     = "$dir/pwfile-28";
	spew($f, "nmis:$MARKER\n");
	spew($target, "KEEP\n");
	chmod(0644, $target) or die "chmod failed: $!";
	symlink($target, $pw) or die "symlink failed: $!";
	my ($rc) = run_pwfile($pw, "user=nmis", "file=$f");
	is($rc, 0, 'planted pwfile symlink: exit 0');
	is(slurp($target), "KEEP\n", 'the symlink target is not written through');
	is(sprintf("%04o", (stat($target))[2] & 07777), '0644',
		'and the target mode is not changed');
	ok(!-l $pw, 'the symlink itself is replaced by a real file');
	like(slurp($pw), qr/^password:\s*\S+$/m, 'which holds the new password');
}

# 29. the child must not write into the checkout it runs from. loadConfTable
# mkpaths its config dir and persists a missing cluster_id, so without dir= the
# runs above create conf/Config.nmis in the tree, which dockerfile's COPY . then
# bakes into an image. Asserted positively, because a live install legitimately
# has its own conf/ and absence there proves nothing.

# 30. rotating a password evicts that account's live sessions. Without this a
# session established with the old password keeps working, which is exactly the
# case a rotation exists to end (OWASP ASVS V3.3.3, Session Management Cheat
# Sheet: the session must not survive a credential change).
{
	my $f  = "$dir/evict.dat";
	my $pw = "$dir/pwfile-30";
	spew($f, "nmis:$MARKER\n");
	my $nmis_sess  = make_session("evict_nmis",  "nmis");
	my $other_sess = make_session("evict_alice", "alice");
	my ($rc) = run_pwfile($pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'seeding with live sessions: exit 0');
	ok(!-e $nmis_sess,  "the seeded account's session is evicted");
	ok(-e $other_sess,  "another account's session is left alone");
}

# 31. a run that changes nothing must not evict anything either. otherwise every
# idempotent call on an upgrade would log the admin out for no reason.
{
	my $f  = "$dir/noevict.dat";
	my $pw = "$dir/pwfile-31";
	my $existing = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:$existing\n");
	my $nmis_sess = make_session("noevict_nmis", "nmis");
	my ($rc) = run_pwfile($pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'no-op seeding with live sessions: exit 0');
	ok(-e $nmis_sess, 'a no-op run evicts nothing');
}

# --- container path: the admin password is supplied, not invented ----------
# An invented one lands in a file the container's own nmisd cannot read or
# remove, so supplying it removes the problem rather than working around it.

# 32. a supplied password is used, and no file is written: nothing to retrieve.
{
	my $f  = "$dir/envseed.dat";
	my $pw = "$dir/pwfile-32";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_env({NMIS9_ADMIN_PASSWORD => 'SuppliedByOperator1'},
		$pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'supplied password: exit 0');
	is(crypt('SuppliedByOperator1', nmis_hash($f)), nmis_hash($f),
		'supplied password: it is the password that was set');
	ok(!-e $pw, 'supplied password: no initial-password file is written');
	unlike($out, qr/SuppliedByOperator1/, 'supplied password: never echoed');
}

# 33. still idempotent, or every container restart would reset the password.
{
	my $f  = "$dir/envnoop.dat";
	my $pw = "$dir/pwfile-33";
	my $existing = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:$existing\n");
	my ($rc) = run_env({NMIS9_ADMIN_PASSWORD => 'SuppliedByOperator1'},
		$pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'supplied password, configured store: exit 0');
	is(nmis_hash($f), $existing, 'supplied password, configured store: left alone');
}

# 34. generate-password=f: refuse rather than invent one nobody can retrieve.
{
	my $f  = "$dir/envrequire.dat";
	my $pw = "$dir/pwfile-34";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_env({}, $pw, "user=nmis", "file=$f", "reveal=none",
		"generate-password=f");
	isnt($rc, 0, 'generate-password=f with nothing supplied: fails closed');
	is(nmis_hash($f), $MARKER, 'generate-password=f with nothing supplied: store untouched');
	ok(!-e $pw, 'generate-password=f with nothing supplied: no file written');
	like($out, qr/NMIS9_ADMIN_PASSWORD/, 'generate-password=f: names the variable to set');
}

# 35. it only bites when a password is actually needed, so a configured store
# still starts cleanly with nothing supplied.
{
	my $f  = "$dir/envrequire-noop.dat";
	my $pw = "$dir/pwfile-35";
	my $existing = crypt('customsecret', '$6$rounds=100000$abcdefghijklmnop');
	spew($f, "nmis:$existing\n");
	my ($rc) = run_env({}, $pw, "user=nmis", "file=$f", "reveal=none",
		"generate-password=f");
	is($rc, 0, 'generate-password=f, configured store: exit 0');
	is(nmis_hash($f), $existing, 'generate-password=f, configured store: left alone');
}

# 36. the name must stay outside the NMIS_ namespace: _apply_env_overrides maps
# NMIS_<KEY> onto config key lc(<KEY>), exposing the plaintext. Driven through
# the SHIPPED loader, not a copy of its regex: a retyped pattern would still
# pass if _apply_env_overrides later broadened to ^NMIS9?_ and started leaking.
{
	my $pid = open(my $p, '-|');
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		delete @ENV{ grep { /^NMIS9?_/ } keys %ENV };
		$ENV{NMIS9_ADMIN_PASSWORD}      = 'ShouldNotLeak1';
		$ENV{NMIS9_ADMIN_PASSWORD_FILE} = '/should/not/leak';
		# a control that DOES use the NMIS_ form, so "no leak" cannot pass just
		# because the overrides never ran at all
		$ENV{NMIS_sentinel_key} = 'sentinel-value';
		my $c = NMISNG::Util::loadConfTable(dir => "$HOME{run_env}/conf");
		my @leaked = grep { defined($c->{$_}) && !ref($c->{$_})
				&& $c->{$_} =~ /ShouldNotLeak1|should\/not\/leak/ } keys %$c;
		print "sentinel=".($c->{sentinel_key} // '')."\n";
		print "leaked=".join(",", sort @leaked)."\n";
		POSIX::_exit(0);
	}
	local $/;
	my $out = <$p> // '';
	close $p;
	like($out, qr/^sentinel=sentinel-value$/m,
		'the loader really does apply NMIS_ overrides, so the check below means something');
	like($out, qr/^leaked=$/m,
		'NMIS9_ADMIN_PASSWORD(_FILE) create no config key, so the plaintext stays out of config');
}

# 37. the _FILE form, so the secret can live in a docker secret rather than the
# environment. Same convention as the postgres, mysql and mongo images.
{
	my $f   = "$dir/envfile.dat";
	my $pw  = "$dir/pwfile-37";
	my $sec = "$dir/secret-37";
	spew($f, "nmis:$MARKER\n");
	spew($sec, "FromASecretFile1\n");    # trailing newline is normal in such files
	my ($rc) = run_env({NMIS9_ADMIN_PASSWORD_FILE => $sec},
		$pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, '_FILE form: exit 0');
	is(crypt('FromASecretFile1', nmis_hash($f)), nmis_hash($f),
		'_FILE form: the file contents are the password, newline stripped');
	ok(!-e $pw, '_FILE form: no initial-password file is written');
}

# 37a. the _FILE read is O_NOFOLLOW, matching the pwfile write in case 28. It
# runs as root against an operator-named path, so a planted symlink must fail
# rather than redirect the read. Without this, a revert to a plain open() passes
# the whole suite.
{
	my $f      = "$dir/envsymlink.dat";
	my $pw     = "$dir/pwfile-37a";
	my $target = "$dir/secret-37a-target";
	my $link   = "$dir/secret-37a-link";
	spew($f, "nmis:$MARKER\n");
	spew($target, "PlantedSecret1\n");
	symlink($target, $link) or die "symlink failed: $!";
	my ($rc, $out) = run_env({NMIS9_ADMIN_PASSWORD_FILE => $link},
		$pw, "user=nmis", "file=$f", "reveal=none");
	isnt($rc, 0, 'symlinked _FILE: refused');
	is(nmis_hash($f), $MARKER, 'symlinked _FILE: the store is untouched');
	isnt(crypt('PlantedSecret1', nmis_hash($f)), nmis_hash($f),
		'symlinked _FILE: the symlink target was never used as the password');
	ok(!-e $pw, 'symlinked _FILE: no initial-password file written');
	like($out, qr/cannot read NMIS9_ADMIN_PASSWORD_FILE/,
		'symlinked _FILE: says which variable it could not read');
}

# 38. both forms set is an ambiguity, not a precedence puzzle. Say so.
{
	my $f   = "$dir/envboth.dat";
	my $pw  = "$dir/pwfile-38";
	my $sec = "$dir/secret-38";
	spew($f, "nmis:$MARKER\n");
	spew($sec, "FromTheFile1\n");
	my ($rc, $out) = run_env({NMIS9_ADMIN_PASSWORD => 'FromTheEnv1',
			NMIS9_ADMIN_PASSWORD_FILE => $sec},
		$pw, "user=nmis", "file=$f", "reveal=none");
	isnt($rc, 0, 'both forms set: rejected');
	is(nmis_hash($f), $MARKER, 'both forms set: store untouched');
	like($out, qr/both/i, 'both forms set: says why');
}

# 39. empty is "not supplied": the shipped .env carries the key with no value,
# so this must fail closed rather than seed an empty password.
{
	my $f  = "$dir/envempty.dat";
	my $pw = "$dir/pwfile-39";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_env({NMIS9_ADMIN_PASSWORD => ''},
		$pw, "user=nmis", "file=$f", "reveal=none", "generate-password=f");
	isnt($rc, 0, 'empty value: treated as not supplied, fails closed');
	is(nmis_hash($f), $MARKER, 'empty value: store untouched');
}

# 40. an empty _FILE is an error rather than an empty password
{
	my $f   = "$dir/envemptyfile.dat";
	my $pw  = "$dir/pwfile-40";
	my $sec = "$dir/secret-40";
	spew($f, "nmis:$MARKER\n");
	spew($sec, "");
	my ($rc, $out) = run_env({NMIS9_ADMIN_PASSWORD_FILE => $sec},
		$pw, "user=nmis", "file=$f", "reveal=none");
	isnt($rc, 0, 'empty _FILE: rejected');
	is(nmis_hash($f), $MARKER, 'empty _FILE: store untouched');
	like($out, qr/empty/i, 'empty _FILE: says why');
}

# 41. a supplied password rotates nm1888 too, not just the marker. Without this
# the container upgrade path falls through to inventing one.
{
	my $f  = "$dir/envnm1888.dat";
	my $pw = "$dir/pwfile-41";
	spew($f, "nmis:SG65RBEiLjd5U\n");
	my ($rc) = run_env({NMIS9_ADMIN_PASSWORD => 'ReplacesTheDefault1'},
		$pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'supplied password over nm1888: exit 0');
	is(crypt('ReplacesTheDefault1', nmis_hash($f)), nmis_hash($f),
		'supplied password over nm1888: rotated to the supplied one');
	ok(!-e $pw, 'supplied password over nm1888: no initial-password file');
}

# 42. the container wiring, each load-bearing: without the flag a container
# invents a password again, without the mapping .env never reaches the CLI.
{
	my %wiring = (
		"docker-entrypoint.sh"                 => [qr/generate-password=f/],
		"docker-dev/docker-entrypoint-dev.sh"  => [qr/generate-password=f/],
		# BOTH forms, or the _FILE docker-secret path the README recommends never
		# reaches the container and generate-password=f then refuses to start.
		"compose.yaml"                => [qr/NMIS9_ADMIN_PASSWORD:/, qr/NMIS9_ADMIN_PASSWORD_FILE:/],
		"docker-dev/compose-dev.yaml" => [qr/NMIS9_ADMIN_PASSWORD:/, qr/NMIS9_ADMIN_PASSWORD_FILE:/],
	);
	for my $rel (sort keys %wiring)
	{
		my $path = "$FindBin::Bin/../$rel";
		SKIP: {
			my @want = @{$wiring{$rel}};
			skip "$rel not present", scalar(@want) unless -f $path;
			my $body = slurp($path);
			like($body, $_, "$rel carries the container password wiring: $_") for (@want);
		}
	}
}

# 43. the shipped .env must never carry a value: it would be the same known
# password everywhere. The dev stack is allowed one, like MONGODB_PASSWORD.
{
	my $env = "$FindBin::Bin/../.env";
	SKIP: {
		skip ".env not present", 2 unless -f $env;
		my $body = slurp($env);
		like($body, qr/^NMIS_ADMIN_PASSWORD=\s*$/m,
			'the shipped .env carries the key');
		unlike($body, qr/^NMIS_ADMIN_PASSWORD=\S/m,
			'and ships it EMPTY, so there is no default password to leave in place');
	}
}

# 44. the container must not receive the password under an NMIS_ name.
# _apply_env_overrides maps NMIS_<KEY> onto config key lc(<KEY>) and can add new
# keys, so NMIS_ADMIN_PASSWORD in a service environment would put the plaintext
# into the config surface. The .env variable of that name is fine: compose
# substitution happens on the host and never enters the container.
{
	for my $rel ("compose.yaml", "docker-dev/compose-dev.yaml")
	{
		my $path = "$FindBin::Bin/../$rel";
		SKIP: {
			skip "$rel not present", 1 unless -f $path;
			unlike(slurp($path), qr/^\s*NMIS_ADMIN_PASSWORD\s*:/m,
				"$rel does not pass the password in under an NMIS_ name");
		}
	}
}

# 45. no session directory at all is not an error and must not warn. A fresh
# install takes this path, and eviction there could not find anything anyway.
{
	my $f  = "$dir/nosessdir.dat";
	my $pw = "$dir/pwfile-45";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_env({NMIS_session_dir => "$dir/does-not-exist",
			NMIS9_ADMIN_PASSWORD => 'Whatever1'},
		$pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'missing session dir: exit 0');
	unlike($out, qr/WARNING|Checking/, 'missing session dir: silent, no scan announced');
}

# 46. an empty session directory is skipped without announcing anything either
{
	my $f     = "$dir/emptysess.dat";
	my $pw    = "$dir/pwfile-46";
	my $empty = "$dir/sessions-empty";
	mkdir($empty) or die "cannot create $empty: $!";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_env({NMIS_session_dir => $empty,
			NMIS9_ADMIN_PASSWORD => 'Whatever1'},
		$pw, "user=nmis", "file=$f", "reveal=none");
	is($rc, 0, 'empty session dir: exit 0');
	unlike($out, qr/Checking/, 'empty session dir: nothing announced');
}

# 47. nmisd must expire stale session files on a schedule. Nothing did, so the
# directory grew without bound and every eviction got slower forever. This is
# structural: nmisd cannot be run here.
{
	my $nmisd = "$FindBin::Bin/../bin/nmisd";
	SKIP: {
		skip "bin/nmisd not present", 2 unless -f $nmisd;
		my $body = slurp($nmisd);
		like($body, qr/get_all_live_session_counter/,
			'nmisd expires stale session files from the purge job');
		like($body, qr/_count_session_files/,
			'and counts them so the log says how many went');
	}
}

# 48. the DEFAULT is fail-closed. A caller that says nothing gets a refusal, not
# an invented password. Inventing one is only safe where something can retrieve
# and later remove the file, which the caller knows and this does not, so the
# unsafe direction has to be the one you opt into. The two installer call sites
# pass generate-password=t; a fifth caller that forgets stops loudly instead of
# quietly stashing a password nothing can read.
{
	my $f  = "$dir/defaultclosed.dat";
	my $pw = "$dir/pwfile-48";
	spew($f, "nmis:$MARKER\n");
	my ($rc, $out) = run_env({}, $pw, "user=nmis", "file=$f", "reveal=none");
	isnt($rc, 0, 'no flag at all: refuses rather than inventing a password');
	is(nmis_hash($f), $MARKER, 'no flag at all: store untouched');
	ok(!-e $pw, 'no flag at all: no file written');
	like($out, qr/generate-password=t/,
		'no flag at all: says how to opt into generating one');
}

# 49. the installer opts in explicitly, so a host install is unchanged.
{
	my $hook = "$FindBin::Bin/../installer_hooks/05-postcopy-configfiles";
	SKIP: {
		skip "installer hook not present", 1 unless -f $hook;
		my @optin = (slurp($hook) =~ /generate-password=t/g);
		is(scalar(@optin), 2,
			'both installer call sites opt into generating a password');
	}
}

# PER exec site, not one assertion for all of them: each helper has its own home,
# so a single misbehaving site cannot hide behind a well-behaved one.
for my $site (sort keys %HOME_USED)
{
	ok(-e "$HOME{$site}/conf/Config.nmis" || -e "$HOME{$site}/conf/Config.json",
		"$site wrote its config into its own temp home, not the checkout");
}
# and every helper this file defines must actually have been exercised, or the
# loop above would silently cover fewer sites than it appears to.
is(scalar(keys %HOME_USED), scalar(keys %HOME),
	'every exec site defined here was exercised, so the guard covers them all');

done_testing;
