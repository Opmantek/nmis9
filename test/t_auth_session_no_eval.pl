#!/usr/bin/perl
#
# t_auth_session_no_eval.pl - security regression tests for OMK-12812 (C1).
#
# NMISNG::Auth stored login sessions in the CGI::Session default serializer
# format, which is Perl source ("$D = {...};;$D"), and both session-enumeration
# loops recovered the hash with a string eval. Anything writable into the
# session directory therefore became Perl code executed by the reader. The
# directory ships group-writable (fixperms does chmod -R g+rw over <nmis_base>)
# and httpd is placed in the nmis group, and both loops are reachable from
# bin/nmis-cli (act=get-sessions, act=clean-sessions) which runs as root.
#
# These tests assert that session file content is treated as DATA, never
# executed, while the session counting and expiry-cleanup behaviour that the
# login path and nmis-cli depend on keeps working unchanged.
#
# Isolated by design: session_dir is injected as a File::Temp directory, so the
# real <nmis_var>/nmis_system/user_session is never read or written.
#
use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp ();
use File::Spec ();
use CGI::Session ();

use NMISNG::Auth;

# keep the test hermetic: the loops log via NMISNG::Util::logAuth, which would
# otherwise load the system config and write to the auth log. Captured, not
# discarded, so the diagnostics can be asserted on too.
our @LOGGED;
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { push @LOGGED, ($_[0] // ''); return undef; }; }

my $sessiondir = File::Temp->newdir("t_auth_session_no_eval_XXXXXX", TMPDIR => 1);
my $canary     = File::Spec->catfile("$sessiondir", "PWNED");

# auth_expire '+60min' is the shipped default, so a session stamped "now" is
# live and one stamped long ago is expired.
sub auth
{
	return NMISNG::Auth->new(conf => {
		session_dir  => "$sessiondir",
		auth_expire  => '+60min',
		auth_debug   => 'false',
		auth_require => 0,
	});
}

# write a session file in the real CGI::Session default-serializer format
sub plant
{
	my ($name, $body) = @_;
	my $path = File::Spec->catfile("$sessiondir", $name);
	open(my $fh, '>', $path) or die "cannot write $path: $!";
	print $fh '$D = ' . $body . ';;$D' . "\n";
	close($fh);
	return $path;
}

# a legitimate session, shaped exactly like the ones on a live system
sub legit
{
	my ($user, $atime) = @_;
	return "{'_SESSION_ATIME' => $atime,'_SESSION_CTIME' => $atime,"
		. "'_SESSION_ID' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',"
		. "'_SESSION_REMOTE_ADDR' => '127.0.0.1','auth' => 'htpasswd',"
		. "'groups' => ['all'],'priv' => 'administrator','privlevel' => '0',"
		. "'username' => '$user'}";
}

# a crafted session whose payload has a side effect if it is ever evaluated.
# "|| 1" keeps the expression truthy so a naive eval still yields a usable hash,
# which is what makes this dangerous rather than merely noisy.
sub payload
{
	my $t = time;
	return "{'username' => 'attacker','_SESSION_ATIME' => $t,"
		. "'pwn' => ((open(PWN, '>', '$canary') and close(PWN)) || 1)}";
}

sub clear_dir
{
	opendir(my $dh, "$sessiondir") or die $!;
	for my $f (readdir($dh)) {
		next if $f =~ /^\.\.?$/;
		unlink File::Spec->catfile("$sessiondir", $f);
	}
	closedir($dh);
	unlink $canary if -e $canary;
}

# ---------------------------------------------------------------------------
# the security assertions: session content must never be executed
# ---------------------------------------------------------------------------

subtest 'get_live_session_counter does not execute session file content' => sub {
	clear_dir();
	plant("cgisess_evil", payload());

	my ($err, $count) = auth()->get_live_session_counter(user => 'attacker');

	ok(!-e $canary, 'planted session payload was not executed');
	is($err, undef, 'no error returned');
};

subtest 'get_all_live_session_counter does not execute session file content' => sub {
	clear_dir();
	plant("cgisess_evil", payload());

	my $all = auth()->get_all_live_session_counter();

	ok(!-e $canary, 'planted session payload was not executed');
	ok(ref($all) eq 'HASH', 'a per-user counter hash is still returned');
};

subtest 'a malformed session file does not abort session enumeration' => sub {
	clear_dir();
	# unparseable content: the old code logged $@ through a bare logAuth() that
	# is not imported into NMISNG::Auth, so this died with
	# "Undefined subroutine &NMISNG::Auth::logAuth called".
	my $path = File::Spec->catfile("$sessiondir", "cgisess_malformed");
	open(my $fh, '>', $path) or die $!;
	print $fh "this is not perl at all {{{\n";
	close($fh);
	plant("cgisess_good", legit('alice', time));

	my $all = eval { auth()->get_all_live_session_counter() };
	my $died = $@;

	is($died, '', 'enumeration survived the malformed file');
	is(($all->{alice}->{sessions} // 0), 1, 'the valid session was still counted');
};

# ---------------------------------------------------------------------------
# negative and hostile input: the cases a best-effort parse can get wrong
# ---------------------------------------------------------------------------

# escape a string the way the serializer does, Data::Dumper with Useqq(0)
sub squote
{
	my $s = shift;
	$s =~ s/([\\'])/\\$1/g;
	return "'$s'";
}

# The property that makes the regex safe rather than lucky: the serializer escapes
# embedded quotes, so a decoy in a value cannot pose as a second username key.
subtest 'a decoy inside a legitimate username does not become the username' => sub {
	clear_dir();
	my $hostile = "x','username' => 'admin";
	my $path = plant("cgisess_decoy",
		"{'username' => " . squote($hostile) . ",'_SESSION_ATIME' => " . time . "}");

	my $got = auth()->read_session_fields($path);

	is((($got // {})->{username}), $hostile, 'the full original value is returned');
	isnt((($got // {})->{username}), 'admin', 'the decoy did not win');
};

subtest 'a session carrying no username yields nothing' => sub {
	clear_dir();
	my $path = plant("cgisess_nouser", "{'_SESSION_ATIME' => " . time . ",'priv' => 'guest'}");

	my $got = auth()->read_session_fields($path);

	is((($got // {})->{username}), undef, 'no username is invented');
};

subtest 'pure junk yields nothing rather than a partial guess' => sub {
	clear_dir();
	my $path = plant("cgisess_junk", "not perl, not a session, just bytes {{{");

	is(auth()->read_session_fields($path), undef, 'nothing is returned');
};

# Limitations, not desired behaviour. Neither is reachable today, since usernames
# arrive as strings and so serialise quoted, and CGI::Session always stamps an
# atime. Pinned so that if either changes, the consequence surfaces here first.
subtest 'known limitation: an unquoted numeric username is invisible' => sub {
	clear_dir();
	my $path = plant("cgisess_numeric", "{'username' => 1234,'_SESSION_ATIME' => " . time . "}");

	my $got = auth()->read_session_fields($path);

	is((($got // {})->{username}), undef,
		'an unquoted value is not matched, so the loops skip the file entirely');
};

subtest 'known limitation: a session with no atime parses with atime undef' => sub {
	clear_dir();
	my $path = plant("cgisess_noatime", "{'username' => 'alice','priv' => 'guest'}");

	my $got = auth()->read_session_fields($path);

	is((($got // {})->{username}),       'alice', 'the username is still recovered');
	is((($got // {})->{_SESSION_ATIME}), undef,   'the missing atime is reported as undef');
	# callers turn that into 0 via // 0 and unlink the file. Recorded, not endorsed.
};

# ---------------------------------------------------------------------------
# the load-bearing assumption: the parser must match what the serializer emits
# ---------------------------------------------------------------------------

# Every other test hand-writes the format via plant(), which pins our model of it
# rather than the format itself. Here CGI::Session writes the files, so an upgrade
# that changes quoting or spacing fails this subtest instead of silently breaking
# session counting in production. The values are the ones the serializer escapes.
subtest 'fields are recovered from files CGI::Session actually wrote' => sub {
	clear_dir();

	for my $user ('alice', "al'ice", 'bo\\b', "x','username' => 'admin",
								"new\nline", "tab\there", "\xe9tienne")
	{
		my $before  = time;
		my $session = CGI::Session->new(undef, undef, { Directory => "$sessiondir" });
		$session->param('username', $user);
		$session->flush();
		my $path = File::Spec->catfile("$sessiondir", "cgisess_" . $session->id);

		my $got = auth()->read_session_fields($path);
		my $label = join(",", map { ord } split(//, $user));

		is((($got // {})->{username}), $user, "username recovered exactly [$label]");
		cmp_ok((($got // {})->{_SESSION_ATIME} // -1), '>=', $before,
			"atime recovered as a live timestamp [$label]");
	}
};

# ---------------------------------------------------------------------------
# regression guards: the counting behaviour login and nmis-cli rely on
# ---------------------------------------------------------------------------

subtest 'live sessions are counted per user' => sub {
	clear_dir();
	my $now = time;
	plant("cgisess_a1", legit('alice', $now));
	plant("cgisess_a2", legit('alice', $now));
	plant("cgisess_b1", legit('bob',   $now));

	my ($err, $count) = auth()->get_live_session_counter(user => 'alice');
	is($count, 2, 'two live sessions counted for alice');

	(undef, $count) = auth()->get_live_session_counter(user => 'bob');
	is($count, 1, 'one live session counted for bob');

	(undef, $count) = auth()->get_live_session_counter(user => 'carol');
	is($count, 0, 'no sessions counted for a user with none');
};

subtest 'expired sessions are not counted and are cleaned up' => sub {
	clear_dir();
	my $stale = time - 7200;    # older than the +60min expiry
	my $old   = plant("cgisess_stale", legit('alice', $stale));
	plant("cgisess_live", legit('alice', time));

	my ($err, $count) = auth()->get_live_session_counter(user => 'alice');

	is($count, 1, 'only the live session is counted');
	ok(!-e $old, 'the expired session file was unlinked');
};

subtest 'remove_all unlinks every session for the given user' => sub {
	clear_dir();
	my $now = time;
	my $a1 = plant("cgisess_a1", legit('alice', $now));
	my $b1 = plant("cgisess_b1", legit('bob',   $now));

	auth()->get_live_session_counter(user => 'alice', remove_all => 1);

	ok(!-e $a1, "alice's session was removed");
	ok(-e $b1,  "bob's session was left alone");
};

subtest 'read_session_fields is callable as a method' => sub {
	clear_dir();
	my $now  = time;
	my $path = plant("cgisess_m1", legit('alice', $now));

	my $got = auth()->read_session_fields($path);

	is(($got // {})->{username},       'alice', 'username parsed on a method call');
	is(($got // {})->{_SESSION_ATIME}, $now,    '_SESSION_ATIME parsed on a method call');
};

# The read is capped so a planted oversized file cannot make a root process
# allocate arbitrary memory. See read_session_fields for why it refuses rather
# than parsing a truncated prefix.
subtest 'an implausibly large session file is refused, not slurped' => sub {
	clear_dir();
	@LOGGED = ();

	my $path = File::Spec->catfile("$sessiondir", "cgisess_huge");
	open(my $fh, '>', $path) or die $!;
	print $fh '$D = {';
	print $fh "'pad$_' => '" . ('x' x 1024) . "'," for (1 .. 128);
	print $fh "'username' => 'buried','_SESSION_ATIME' => " . time . "};;\$D\n";
	close($fh);
	cmp_ok(-s $path, '>', 131072, 'the planted file is well past the read cap');

	my $got = auth()->read_session_fields($path);

	is($got, undef, 'the oversized file yields no fields at all');
	ok(scalar(grep { /cgisess_huge/ } @LOGGED), 'the refusal was logged, naming the file');
};

subtest 'a normal-sized session file is still parsed after the cap was added' => sub {
	clear_dir();
	my $now  = time;
	my $path = plant("cgisess_small", legit('alice', $now));

	my $got = auth()->read_session_fields($path);

	is((($got // {})->{username}),       'alice', 'username still recovered');
	is((($got // {})->{_SESSION_ATIME}), $now,    'atime still recovered');
};

# A missing path, not chmod 000, because CI runs these under docker exec where root
# would read a mode-000 file anyway.
subtest 'an unreadable session file is reported, not silently skipped' => sub {
	clear_dir();
	@LOGGED = ();

	my $got = auth()->read_session_fields(File::Spec->catfile("$sessiondir", "cgisess_absent"));

	is($got, undef, 'no fields are returned for an unopenable file');
	ok(scalar(grep { /cgisess_absent/ } @LOGGED),
		'the failure was logged, naming the file');
};

# not_expired decides whether a session is counted or unlinked by the loops
# above, so its unit parsing is part of this behaviour. The unit alternation used
# to carry literal braces, which made '+1y' fall through as a bare string and
# numify to 1 second, expiring (and so deleting) every session.
subtest 'expiry units are all understood' => sub {
	my $auth = auth();
	my $touched = time - 600;    # session last used ten minutes ago

	is($auth->not_expired(time_exp => $touched, expires => '+30min'), 1, '+30min: live');
	is($auth->not_expired(time_exp => $touched, expires => '+5min'),  0, '+5min: expired');
	is($auth->not_expired(time_exp => $touched, expires => '+1h'),    1, '+1h: live');
	is($auth->not_expired(time_exp => $touched, expires => '+1d'),    1, '+1d: live');
	is($auth->not_expired(time_exp => $touched, expires => '+1w'),    1, '+1w: live');
	is($auth->not_expired(time_exp => $touched, expires => '+1M'),    1, '+1M: live');
	is($auth->not_expired(time_exp => $touched, expires => '+1y'),    1, '+1y: live');
	is($auth->not_expired(time_exp => $touched, expires => '+3600s'), 1, '+3600s: live');
	is($auth->not_expired(time_exp => $touched, expires => '+30s'),   0, '+30s: expired');
};

# generate_cookie keeps a second copy of the unit table, and an unknown unit there
# reaches func::parseDateTime, which does not exist in nmis9. So a missing unit
# breaks login outright rather than just mis-timing the cookie.
subtest 'generate_cookie handles every expiry unit without dying' => sub {
	my $auth = NMISNG::Auth->new(conf => {
		session_dir  => "$sessiondir",
		auth_web_key => 'a-unique-key-for-tests-9f3b',
		auth_debug   => 'false',
		auth_require => 0,
	});

	for my $unit (qw(+30min +1s +1m +1h +1d +1w +1M +1y)) {
		my $cookie = eval { $auth->generate_cookie(user_name => 'alice', expires => $unit) };
		is($@, '', "$unit: no exception");
		ok(defined($cookie) && $cookie ne '', "$unit: a cookie was produced");
	}
};

subtest 'a long expiry does not delete live sessions' => sub {
	clear_dir();
	my $kept = plant("cgisess_keep", legit('alice', time - 600));

	my ($err, $count) = NMISNG::Auth->new(conf => {
		session_dir  => "$sessiondir",
		auth_expire  => '+1y',
		auth_debug   => 'false',
		auth_require => 0,
	})->get_live_session_counter(user => 'alice');

	is($count, 1, 'the session is counted under a one-year expiry');
	ok(-e $kept, 'the session file was not unlinked');
};

subtest 'get_all_live_session_counter reports each user' => sub {
	clear_dir();
	my $now = time;
	plant("cgisess_a1", legit('alice', $now));
	plant("cgisess_a2", legit('alice', $now));
	plant("cgisess_b1", legit('bob',   $now));

	my $all = auth()->get_all_live_session_counter();

	is($all->{alice}->{sessions}, 2, 'alice has two live sessions');
	is($all->{bob}->{sessions},   1, 'bob has one live session');
};

done_testing();
