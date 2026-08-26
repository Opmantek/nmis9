#!/usr/bin/perl
#
# OMK-12705: the users.dat password store, end to end within NMISNG::Util.
# Three concerns, one file because they share the same file format and setup:
#
#   1. generate_random_password and hash_password, the salt source and the
#      hasher that replace DES crypt.
#   2. set_htpasswd_entry, the single writer. It rewrites in place under a lock
#      so an unprivileged CGI write cannot change ownership, and so two
#      concurrent logins cannot lose each other's upgrade.
#   3. redact_htpasswd_files, which keeps hashes out of a support bundle,
#      including the users.dat.bak this branch introduced.
#
# NMISNG::Auth's verify and re-hash live in t_auth_password_rehash.t, and the
# admin CLI in t_nmis_cli_htpasswd.t. Both need setup this file does not.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::stat;                 # Util.pm imports this into its own namespace
use POSIX ();                   # only, so a test file must import it too
use Fcntl qw(:flock);           # LOCK_EX, for the held-lock test below
use NMISNG::Util;

my $dir = tempdir(CLEANUP => 1);

sub spew { my ($p, $c) = @_; open(my $f, '>', $p) or die $!; print $f $c; close $f; }
sub slurp { my ($p) = @_; open(my $f, '<', $p) or die $!; local $/; my $c = <$f>; close $f; return $c; }

# ---------------------------------------------------------------------------
# 1. generate_random_password and hash_password
# ---------------------------------------------------------------------------

{
	is(length(NMISNG::Util::generate_random_password()), 20, 'default length is 20');
	like(NMISNG::Util::generate_random_password(), qr/^[A-Za-z0-9]+$/, 'charset is [A-Za-z0-9]');
	is(length(NMISNG::Util::generate_random_password(16)), 16, 'explicit length honoured');
	is(length(NMISNG::Util::generate_random_password(1)), 1, 'length 1 honoured');

	# a bad length falls back to 20 rather than dying or returning empty
	is(length(NMISNG::Util::generate_random_password(0)), 20, 'length 0 falls back to 20');
	is(length(NMISNG::Util::generate_random_password(-5)), 20, 'negative length falls back to 20');
	is(length(NMISNG::Util::generate_random_password("abc")), 20, 'non-numeric length falls back to 20');

	my %seen;
	$seen{NMISNG::Util::generate_random_password(16)}++ for (1 .. 50);
	is(scalar(keys %seen), 50, '50 generated values are all distinct');

	# hash_password, sha512 is the default. rounds=1000 keeps the tests fast;
	# crypt(3) rejects anything below 1000 with the token *0.
	my $h = NMISNG::Util::hash_password('correct horse', undef, 1000);
	like($h, qr/^\$6\$rounds=1000\$/, 'sha512 is the default scheme');
	is(crypt('correct horse', $h), $h, 'the hash verifies through crypt');
	isnt(crypt('wrong horse', $h), $h, 'a wrong password does not verify');

	my ($salt) = $h =~ /^\$6\$rounds=1000\$([^\$]+)\$/;
	is(length($salt), 16, 'salt is 16 characters');
	like($salt, qr/^[A-Za-z0-9]+$/, 'salt charset is [A-Za-z0-9]');

	isnt(NMISNG::Util::hash_password('same', 'sha512', 1000),
		 NMISNG::Util::hash_password('same', 'sha512', 1000),
		 'the same password hashes differently each time');

	like(NMISNG::Util::hash_password('x'), qr/^\$6\$rounds=100000\$/,
		 'the default round count is 100000');

	# a round count below the crypt(3) floor must not yield the *0 failure token
	like(NMISNG::Util::hash_password('x', 'sha512', 100), qr/^\$6\$rounds=100000\$/,
		 'a round count below 1000 falls back to the default');

	# there is no write path for a scheme _file_verify would rewrite on login.
	# reading and classifying apr1 is Auth.pm's job and needs no writer here.
	ok(!eval { NMISNG::Util::hash_password('x', 'apr1'); 1 },
		 'apr1 is not a write scheme');

	ok(!eval { NMISNG::Util::hash_password(''); 1 },        'an empty plaintext dies');
	like($@, qr/no plaintext/,                              'and says why');
	ok(!eval { NMISNG::Util::hash_password(undef); 1 },     'an undef plaintext dies');
	ok(!eval { NMISNG::Util::hash_password('x', 'bcrypt'); 1 }, 'an unknown scheme dies');
	like($@, qr/unknown scheme/,                            'and names it');
}

# ---------------------------------------------------------------------------
# 2. set_htpasswd_entry
# ---------------------------------------------------------------------------

# replacing an entry leaves every other line untouched
{
	my $f = "$dir/replace.dat";
	spew($f, "alice:aaa\nbob:bbb\ncarol:ccc\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW'),
	   undef, 'replace returns undef on success');
	is(slurp($f), "alice:aaa\nbob:NEW\ncarol:ccc\n", 'only bob changed, order preserved');
}

# an absent user is appended
{
	my $f = "$dir/append.dat";
	spew($f, "alice:aaa\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'dave', hash => 'DDD'),
	   undef, 'append returns undef');
	is(slurp($f), "alice:aaa\ndave:DDD\n", 'dave appended after the existing line');
}

# delete removes the entry
{
	my $f = "$dir/delete.dat";
	spew($f, "alice:aaa\nbob:bbb\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => undef),
	   undef, 'delete returns undef');
	is(slurp($f), "alice:aaa\n", 'bob removed, alice kept');
}

# duplicates are collapsed, not preserved: a stale second line holding a weak
# hash would otherwise sit unreachable and become live if the first were removed
{
	my $f = "$dir/dupe.dat";
	spew($f, "bob:OLD1\nalice:aaa\nbob:OLD2\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW'),
	   undef, 'set over duplicates returns undef');
	is(slurp($f), "bob:NEW\nalice:aaa\n", 'first line rewritten, duplicate dropped');

	spew($f, "bob:OLD1\nalice:aaa\nbob:OLD2\n");
	NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => undef);
	is(slurp($f), "alice:aaa\n", 'delete removes every duplicate');
}

# mode is preserved, and the backup does not outlive a successful write: it
# would leave the pre-upgrade weak hash on disk. checked inside the hook,
# which runs while the .bak is still there.
{
	my $f = "$dir/mode.dat";
	spew($f, "bob:bbb\n");
	chmod(0640, $f);
	my ($bakmode, $bakcontent);
	my $real = \&NMISNG::Util::backupFile;
	no warnings 'redefine';
	local *NMISNG::Util::backupFile = sub {
		my %a = @_;
		my $r = $real->(@_);
		($bakmode, $bakcontent) = (sprintf("%04o", stat($a{backup})->mode & 07777),
			slurp($a{backup})) if (!$r);
		return $r;
	};
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW'),
	   undef, 'the write succeeds');
	is(sprintf("%04o", stat($f)->mode & 07777), '0640', 'file mode preserved');
	is($bakmode, '0640', 'the backup carried the same mode');
	is($bakcontent, "bob:bbb\n", 'and the pre-write content');
	ok(!-e "$f.bak", 'and it is removed once the write succeeded');
}

# bad input is rejected with an error string, never a die
{
	my $f = "$dir/reject.dat";
	spew($f, "bob:bbb\n");
	like(NMISNG::Util::set_htpasswd_entry(file => "$dir/nope.dat", user => 'b', hash => 'h'),
	     qr/cannot open/, 'a missing file returns an error string');
	like(NMISNG::Util::set_htpasswd_entry(file => $f, user => '', hash => 'h'),
	     qr/no user/, 'an empty user is rejected');
	like(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'a:b', hash => 'h'),
	     qr/colon or newline/, 'a colon in the user is rejected');
	like(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => "a\nb"),
	     qr/colon or newline/, 'a newline in the hash is rejected');
	is(slurp($f), "bob:bbb\n", 'a rejected call leaves the file untouched');
}

# a mid-write failure restores the original from the .bak. this is the whole
# reason the backup exists, so it needs a test rather than code inspection.
{
	my $f = "$dir/restore.dat";
	spew($f, "alice:aaa\nbob:bbb\n");
	chmod(0640, $f);

	# the stub MUST actually corrupt the file before failing. a stub that only
	# returns an error leaves the file intact, so the assertions below pass even
	# with the restore deleted - proven by mutation testing, it was vacuous.
	local $NMISNG::Util::_htpasswd_writer = sub {
		my ($fh) = @_;
		truncate($fh, 0);
		return "simulated disk full";
	};
	my $err = NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW');

	like($err, qr/simulated disk full/, 'a mid-write failure is reported');
	is(slurp($f), "alice:aaa\nbob:bbb\n", 'and the original content is restored');
	is(sprintf("%04o", stat($f)->mode & 07777), '0640', 'and the mode survives the restore');
	ok(-e "$f.bak", 'the backup survives a failed write, which is its whole point');
}

# a write that fails AFTER printing but BEFORE flushing leaves bytes in perl's
# buffer. if the restore runs before close, close flushes them back over it.
{
	my $f = "$dir/restore_buffered.dat";
	spew($f, "alice:aaa\nbob:bbb\n");

	local $NMISNG::Util::_htpasswd_writer = sub {
		my ($fh, $content, $file) = @_;
		seek($fh, 0, 0);
		truncate($fh, 0);
		print $fh "bob:CORRUPT\n";        # buffered, not yet on disk
		return "simulated flush failure";  # fail before flush
	};
	my $err = NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW');

	like($err, qr/simulated flush failure/, 'a buffered-write failure is reported');
	is(slurp($f), "alice:aaa\nbob:bbb\n",
	   'and the restore is not undone by the close-time flush');
}

# when the restore ALSO fails, say so: the file may be truncated and the caller
# needs to know it must recover from the .bak by hand.
{
	my $f = "$dir/restorefail.dat";
	spew($f, "bob:bbb\n");
	local $NMISNG::Util::_htpasswd_writer = sub { return "simulated write error" };
	# make the restore fail by removing the backup the moment it is written
	my $origbackup = \&NMISNG::Util::backupFile;
	my $calls = 0;
	no warnings 'redefine';
	local *NMISNG::Util::backupFile = sub {
		return $origbackup->(@_) if (++$calls == 1);   # first call: real backup
		return "simulated restore failure";            # second call: the restore
	};
	my $err = NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW');
	like($err, qr/simulated write error/,      'the original failure is reported');
	like($err, qr/simulated restore failure/,  'and so is the failed restore');
	like($err, qr/recover it from/,            'and the caller is told to recover from the .bak');
}

# concurrent writers must not lose updates. without the lock, the read-then-
# rewrite cycle drops entries written by a racing process.
{
	my $f = "$dir/concurrent.dat";
	spew($f, "seed:x\n");
	my @kids;
	for my $i (1 .. 8)
	{
		my $pid = fork();
		die "fork failed: $!" if (!defined $pid);
		if (!$pid)
		{
			# generous retries: this test must prove the LOCK works, not that the
			# production default budget happens to be big enough.
			NMISNG::Util::set_htpasswd_entry(file => $f, user => "u$i",
				hash => "h$i", retries => 40);
			POSIX::_exit(0);            # skip END blocks so Test::More stays quiet
		}
		push @kids, $pid;
	}
	waitpid($_, 0) for @kids;

	my $got = slurp($f);
	my @missing = grep { $got !~ /^u\Q$_\E:h\Q$_\E$/m } (1 .. 8);
	is_deeply(\@missing, [], 'eight concurrent writers all land, none lost');
	like($got, qr/^seed:x$/m, 'the pre-existing entry survives');
}

# retries is honoured: a small budget is refused while another process holds
# the lock. a pipe proves the child holds it first, so this cannot flake.
{
	my $f = "$dir/refuse.dat";
	spew($f, "bob:bbb\n");
	pipe(my $rd, my $wr) or die "pipe failed: $!";

	my $pid = fork();
	die "fork failed: $!" if (!defined $pid);
	if (!$pid)
	{
		close $rd;
		open(my $fh, "+<", $f) or POSIX::_exit(1);
		flock($fh, LOCK_EX) or POSIX::_exit(1);
		print $wr "L";
		close $wr;
		select(undef, undef, undef, 0.3);   # hold the lock briefly, then exit
		POSIX::_exit(0);
	}
	close $wr;
	my $signal;
	sysread($rd, $signal, 1);            # blocks until the child holds the lock
	close $rd;

	my $err = NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob',
		hash => 'NEW', retries => 1);
	like($err, qr/cannot lock/, 'a caller with retries => 1 is refused, not kept waiting');
	is(slurp($f), "bob:bbb\n", 'a refused call leaves the file untouched');

	waitpid($pid, 0);                    # child's sleep is bounded, so this cannot hang
}

# compare-and-swap: an entry that changed underneath us is not overwritten
{
	my $f = "$dir/cas_changed.dat";
	spew($f, "alice:aaa\nbob:RESET\n");
	my $err = NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob',
		expect => 'bbb', hash => 'UPGRADED');
	like($err, qr/changed while we were working/, 'a changed entry is refused');
	is(slurp($f), "alice:aaa\nbob:RESET\n", 'and the file is left alone');
	ok(!-e "$f.bak", 'and a refused write leaves no backup behind');
}

# compare-and-swap: a deleted entry is not resurrected
{
	my $f = "$dir/cas_gone.dat";
	spew($f, "alice:aaa\n");
	my $err = NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob',
		expect => 'bbb', hash => 'UPGRADED');
	like($err, qr/changed while we were working/, 'a deleted entry is refused');
	is(slurp($f), "alice:aaa\n", 'and bob is not re-appended');
}

# compare-and-swap: an unchanged entry still upgrades
{
	my $f = "$dir/cas_ok.dat";
	spew($f, "alice:aaa\nbob:bbb\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob',
		expect => 'bbb', hash => 'UPGRADED'), undef, 'an unchanged entry is upgraded');
	is(slurp($f), "alice:aaa\nbob:UPGRADED\n", 'and holds the new hash');
}

# without expect the write is unconditional, which set_password relies on
{
	my $f = "$dir/cas_absent.dat";
	spew($f, "bob:ANYTHING\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW'),
	   undef, 'no expect means unconditional');
	is(slurp($f), "bob:NEW\n", 'and the entry is replaced');
}

# the first duplicate is the one compared, matching what _file_verify verifies
{
	my $f = "$dir/cas_dup.dat";
	spew($f, "bob:bbb\nbob:STALE\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob',
		expect => 'bbb', hash => 'NEW'), undef, 'the first entry is the one compared');
	is(slurp($f), "bob:NEW\n", 'and the duplicate is still collapsed');
}

# an unusable first duplicate is skipped, so expect still matches what
# _file_verify authenticated against
{
	my $f = "$dir/cas_dup_unusable.dat";
	spew($f, "bob:\nbob:bbb\n");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob',
		expect => 'bbb', hash => 'NEW'), undef,
	   'an empty first duplicate does not fool the compare-and-swap');
	is(slurp($f), "bob:NEW\n", 'and the duplicate is collapsed');
}

# A1: the backup destination is unlinked before it is written. cp cannot
# overwrite a .bak another uid owns, so a stale one would block every write.
{
	my $f = "$dir/stalebak.dat";
	spew($f, "bob:bbb\n");
	spew("$f.bak", "STALE\n");
	my $existed = 1;
	my $real = \&NMISNG::Util::backupFile;
	no warnings 'redefine';
	local *NMISNG::Util::backupFile = sub {
		my %a = @_;
		$existed = (-e $a{backup}) ? 1 : 0;
		return $real->(@_);
	};
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW'),
	   undef, 'a stale backup does not block the write');
	is($existed, 0, 'the stale backup was gone before the new one was taken');
	is(slurp($f), "bob:NEW\n", 'and the write landed');
}

# the same case unmocked. unlink needs the directory's write bit, not the
# file's, so this is the real failure the unlink prevents.
SKIP: {
	skip "runs as root, where a 0400 backup is still writable", 2 if ($> == 0);
	my $f = "$dir/robak.dat";
	spew($f, "bob:bbb\n");
	spew("$f.bak", "STALE\n");
	chmod(0400, "$f.bak");
	is(NMISNG::Util::set_htpasswd_entry(file => $f, user => 'bob', hash => 'NEW'),
	   undef, 'a read-only stale backup does not block the write');
	is(slurp($f), "bob:NEW\n", 'and the write landed');
}

# ---------------------------------------------------------------------------
# 3. redact_htpasswd_files
# ---------------------------------------------------------------------------

my $seq = 0;

# a fresh conf/ holding a sha512 entry, a legacy DES entry and a .bak
sub bundle_conf
{
	my $c = "$dir/b" . (++$seq) . "/conf";
	make_path($c);
	spew("$c/users.dat", "nmis:\$6\$rounds=100000\$SALTSALTSALTSALT\$NEWHASHNEWHASH\n"
		. "bob:DESHASHDESHA\n");
	spew("$c/users.dat.bak", "nmis:DESHASHDESHA\n");
	return $c;
}

# both users.dat and its .bak lose every hash, and the usernames survive
{
	my $c = bundle_conf();
	is(NMISNG::Util::redact_htpasswd_files(dir => $c), undef, 'redaction reports no problem');
	unlike(slurp("$c/users.dat"), qr/NEWHASHNEWHASH|DESHASHDESHA/, 'users.dat holds no hash');
	unlike(slurp("$c/users.dat.bak"), qr/DESHASHDESHA/, 'the .bak holds no hash either');
	like(slurp("$c/users.dat"), qr/^nmis:_removed_$/m, 'the username survives');
	like(slurp("$c/users.dat"), qr/^bob:_removed_$/m,  'both entries are rewritten');
}

# an entry with an empty username is redacted too. the old regex needed a word
# character before the colon, so this line kept its hash.
{
	my $c = bundle_conf();
	spew("$c/users.dat", ":DESHASHDESHA\n");
	is(NMISNG::Util::redact_htpasswd_files(dir => $c), undef, 'an empty username is not an error');
	unlike(slurp("$c/users.dat"), qr/DESHASHDESHA/, 'and its hash is still removed');
}

# fail closed: a file that cannot be rewritten is removed, not shipped.
# mocked rather than chmod'ed, because CI runs as root.
{
	my $c = bundle_conf();
	my $err = do {
		no warnings 'redefine';
		local *NMISNG::Util::_redact_one_htpasswd = sub { return "simulated failure" };
		NMISNG::Util::redact_htpasswd_files(dir => $c);
	};
	like($err, qr/simulated failure/, 'the failure is reported to the caller');
	ok(!-e "$c/users.dat",     'the unredactable users.dat is gone from the bundle');
	ok(!-e "$c/users.dat.bak", 'and so is the unredactable .bak');
}

# the same case for real, as a non-root user
SKIP: {
	skip "runs as root, where an unreadable file is still readable", 2 if ($> == 0);
	my $c = bundle_conf();
	chmod(0000, "$c/users.dat");
	my $err = NMISNG::Util::redact_htpasswd_files(dir => $c);
	ok(defined($err), 'an unreadable users.dat is reported');
	ok(!-e "$c/users.dat", 'and removed rather than shipped unredacted');
}

# an empty conf directory is not an error
{
	my $c = "$dir/empty/conf";
	make_path($c);
	is(NMISNG::Util::redact_htpasswd_files(dir => $c), undef, 'no users.dat is fine');
}

# a missing dir argument is refused rather than silently doing nothing
{
	like(NMISNG::Util::redact_htpasswd_files(), qr/no dir given/, 'dir is required');
}

done_testing();
