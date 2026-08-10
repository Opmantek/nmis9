#!/usr/bin/perl
# OMK-12705: _hash_scheme tests. Ensures sha512 upgrade,
# external hashes not locked out, and $6$ hashes not rewritten on login.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use NMISNG::Auth;

# _hash_scheme names only the two weak forms. anything else crypt can verify
# is 'other' and must be left exactly as it is.
is(NMISNG::Auth::_hash_scheme(crypt('pw', 'ab')), 'des', '13-char output is des');
is(NMISNG::Auth::_hash_scheme('$apr1$abcdefgh$0123456789abcdefghijk.'), 'apr1', 'apr1 detected');
is(NMISNG::Auth::_hash_scheme('$6$rounds=1000$abc$def'), 'sha512', 'sha512 detected');
is(NMISNG::Auth::_hash_scheme('$2b$10$abcdefghijklmnopqrstuv'), 'other', 'bcrypt is other');
is(NMISNG::Auth::_hash_scheme('$5$abcdefgh$xyz'), 'other', 'sha256 is other');
is(NMISNG::Auth::_hash_scheme('$y$j9T$abc$def'), 'other', 'yescrypt is other');
is(NMISNG::Auth::_hash_scheme(''), 'other', 'an empty string is other');

# ---------------------------------------------------------------------------
# _file_verify behaviour
# ---------------------------------------------------------------------------

use File::Temp qw(tempdir);
use Crypt::PasswdMD5 qw(apache_md5_crypt);

# the real logAuth loads the global config and appends to the live auth log.
# capture instead, so tests stay isolated and can assert on what was logged.
my @logged;
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { push @logged, $_[0]; return undef; }; }

my $tdir = tempdir(CLEANUP => 1);
my $seq  = 0;

sub users_file
{
	my ($content) = @_;
	my $p = "$tdir/users" . (++$seq) . ".dat";
	open(my $f, '>', $p) or die $!;
	print $f $content;
	close $f;
	return $p;
}

sub stored
{
	my ($p, $user) = @_;
	open(my $f, '<', $p) or die $!;
	while (my $l = <$f>)
	{
		chomp $l;
		my ($u, $h) = split(/:/, $l, 2);
		return $h if (defined($u) && $u eq $user);
	}
	return undef;
}

sub auth { return NMISNG::Auth->new(conf => { auth_debug => 'false' }); }

# a DES password verifies, then upgrades, and keeps working
{
	my $des = crypt('secret12', 'ab');
	my $f   = users_file("other:keepme\nbob:$des\n");
	my $au  = auth();
	ok($au->_file_verify($f, 'bob', 'secret12'), 'a DES password verifies');
	like(stored($f, 'bob'), qr/^\$6\$rounds=100000\$/, 'and is upgraded to sha512');
	ok($au->_file_verify($f, 'bob', 'secret12'), 'a second login still works');
	is(stored($f, 'other'), 'keepme', 'the other entry is untouched');
}

# an apr1 password upgrades the same way
{
	my $f  = users_file('bob:' . apache_md5_crypt('secret12', 'abcdefgh') . "\n");
	my $au = auth();
	ok($au->_file_verify($f, 'bob', 'secret12'), 'an apr1 password verifies');
	like(stored($f, 'bob'), qr/^\$6\$rounds=100000\$/, 'and is upgraded to sha512');
}

# a wrong password never upgrades anything
{
	my $des = crypt('secret12', 'ab');
	my $f   = users_file("bob:$des\n");
	ok(!auth()->_file_verify($f, 'bob', 'WRONG'), 'a wrong password fails');
	is(stored($f, 'bob'), $des, 'and the stored hash is unchanged');
}

# regression guard: a hash written by an external htpasswd must keep working
# and must not be converted. bcrypt is not obviously weaker than sha512crypt.
{
	my $probe = crypt('x', '$2b$10$abcdefghijklmnopqrstuv');
	if (defined($probe) && $probe =~ /^\$2b\$/)
	{
		my $bc = crypt('secret12', '$2b$10$abcdefghijklmnopqrstuv');
		my $f  = users_file("bob:$bc\n");
		ok(auth()->_file_verify($f, 'bob', 'secret12'), 'a bcrypt password verifies');
		is(stored($f, 'bob'), $bc, 'and is left exactly as it was');
	}
	else
	{
		note 'skipping bcrypt passthrough: this platform crypt has no bcrypt';
	}
}

# a sha512 hash is never rewritten. without this, every login rewrites
# users.dat, which is churn under lock plus a needless re-hash.
{
	my $sha = NMISNG::Util::hash_password('secret12', 'sha512', 1000);
	my $f   = users_file("bob:$sha\n");
	ok(auth()->_file_verify($f, 'bob', 'secret12'), 'a sha512 password verifies');
	is(stored($f, 'bob'), $sha, 'and is not rewritten on login');
}

# a locked account never authenticates, whatever is submitted
for my $marker ('*', '!', '*0')
{
	my $f = users_file("bob:$marker\n");

	@logged = ();
	ok(!auth()->_file_verify($f, 'bob', 'anything'), "locked '$marker' rejects a password");
	ok(scalar(grep { /account bob is locked/ } @logged),
	   "locked '$marker' logs the lock, not a platform or mismatch reason");

	@logged = ();
	ok(!auth()->_file_verify($f, 'bob', $marker),    "locked '$marker' rejects itself");
	ok(scalar(grep { /account bob is locked/ } @logged),
	   "locked '$marker' still logs the lock when the submission matches the marker");

	is(stored($f, 'bob'), $marker, "locked '$marker' is not rewritten");
}

# plaintext never authenticates. there is no longer any configuration that
# could re-enable it, so this is unconditional rather than mode-dependent.
{
	my $f = users_file("bob:plainpass\n");
	ok(!auth()->_file_verify($f, 'bob', 'plainpass'),
	   'a stored plaintext password never authenticates');
}

# an unverifiable prefix is reported as a platform problem, not a mismatch
{
	my $f = users_file('bob:$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$aGFzaA' . "\n");
	@logged = ();
	ok(!auth()->_file_verify($f, 'bob', 'secret12'), 'an unverifiable hash fails');
	ok(scalar(grep { /not supported by this platform/ } @logged),
	   'and says the scheme is unsupported rather than reporting a mismatch');
}

# an empty submitted password is rejected
{
	my $f = users_file('bob:' . crypt('', 'ab') . "\n");
	ok(!auth()->_file_verify($f, 'bob', ''), 'an empty submitted password is rejected');
}

# a write failure must not fail the login. mode bits cannot stop root, and the
# container CI runs as root, so the hook-based case below is the one that covers
# this everywhere. this block keeps the real read-only file for everyone else.
SKIP: {
	skip('root ignores mode bits, so a read-only file cannot fail the write', 3)
		if ($> == 0);

	my $des = crypt('secret12', 'ab');
	my $f   = users_file("bob:$des\n");
	chmod(0444, $f);
	@logged = ();
	my $ok = auth()->_file_verify($f, 'bob', 'secret12');
	chmod(0644, $f);
	ok($ok, 'a read-only users.dat still lets the user log in');
	ok(scalar(grep { /could not upgrade/ } @logged), 'and the failure is logged as a warning');
	is(stored($f, 'bob'), $des, 'and the hash stays legacy for the next attempt');
}

# the same guarantee, injected through the writer hook so it holds as root too
{
	my $des = crypt('secret12', 'ab');
	my $f   = users_file("bob:$des\n");
	@logged = ();
	my $ok;
	{
		local $NMISNG::Util::_htpasswd_writer = sub { return "simulated write failure" };
		$ok = auth()->_file_verify($f, 'bob', 'secret12');
	}
	ok($ok, 'a failed write still lets the user log in');
	ok(scalar(grep { /could not upgrade/ } @logged), 'and the failure is logged as a warning');
	is(stored($f, 'bob'), $des, 'and the hash stays legacy for the next attempt');
}

# a hashing failure must not fail login either. this is what actually needs
# the eval around the upgrade: a write failure alone never dies.
{
	my $des = crypt('secret12', 'ab');
	my $f   = users_file("bob:$des\n");
	@logged = ();
	my $ok;
	{
		no warnings 'redefine';
		local *NMISNG::Util::hash_password = sub { die "simulated hashing failure\n" };
		$ok = auth()->_file_verify($f, 'bob', 'secret12');
	}
	ok($ok, 'a hash_password failure still lets the user log in');
	ok(scalar(grep { /simulated hashing failure/ } @logged), 'and the die text is logged');
	is(stored($f, 'bob'), $des, 'and the hash stays legacy for the next attempt');
}

# an unknown user is still rejected
{
	my $f = users_file("bob:" . crypt('secret12', 'ab') . "\n");
	ok(!auth()->_file_verify($f, 'nosuchuser', 'secret12'), 'an unknown user is rejected');
}

# an admin reset landing between verify and upgrade is not undone. hash_password
# runs after verify and before the writer takes the lock, so resetting from
# inside it reproduces the real interleaving.
{
	my $des   = crypt('secret12', 'ab');
	my $f     = users_file("bob:$des\n");
	my $reset = NMISNG::Util::hash_password('brandnew', 'sha512', 1000);
	my $real  = \&NMISNG::Util::hash_password;
	@logged = ();
	my $ok;
	{
		no warnings 'redefine';
		local *NMISNG::Util::hash_password = sub {
			open(my $x, '>', $f) or die $!; print $x "bob:$reset\n"; close $x;
			return $real->(@_);
		};
		$ok = auth()->_file_verify($f, 'bob', 'secret12');
	}
	ok($ok, 'the in-flight login still succeeds');
	is(stored($f, 'bob'), $reset, 'and the admin reset survives the upgrade');
	isnt(crypt('secret12', $reset), $reset, 'the old password no longer verifies');
	ok(scalar(grep { /could not upgrade the password hash for bob/ } @logged),
	   'and the skipped upgrade is logged');
}

# an admin delete landing in the same window does not resurrect the user
{
	my $des  = crypt('secret12', 'ab');
	my $f    = users_file("bob:$des\n");
	my $real = \&NMISNG::Util::hash_password;
	my $ok;
	{
		no warnings 'redefine';
		local *NMISNG::Util::hash_password = sub {
			open(my $x, '>', $f) or die $!; close $x;   # admin deleted the entry
			return $real->(@_);
		};
		$ok = auth()->_file_verify($f, 'bob', 'secret12');
	}
	ok($ok, 'the in-flight login still succeeds');
	is(stored($f, 'bob'), undef, 'but bob is not written back into the file');
}

done_testing();
