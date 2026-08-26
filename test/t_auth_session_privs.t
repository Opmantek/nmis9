#!/usr/bin/perl
#
# OMK-12824: SetUser took the username from the signed auth cookie and the
# privileges from a caller-nominated session file, and never checked the two
# named the same user. These pin the binding: a session must be owned by the
# authenticated user AND carry privileges NMIS itself signed.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use CGI ();
use CGI::Session;
use NMISNG::Auth;

# an exported NMIS_* would land in the config as layer 4 and could change
# auth_expire or auth_web_key under us
delete @ENV{ grep { /^NMIS9?_/ } keys %ENV };

# logAuth would load the system config and write the real auth log; capture
# instead, so the SECURITY lines can be asserted on
our @LOGGED;
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { push @LOGGED, "@_"; return undef; }; }

# Auth.pm calls Compat::NMIS::loadGenericTable but never imports it, so the
# fall-through path cannot run without this stub. No config and no MongoDB.
our @TABLE_CALLS;
our %TABLES = (
	Users => {
		alice   => { user => 'alice',   privilege => 'administrator', groups => 'all' },
		mallory => { user => 'mallory', privilege => 'operator',      groups => 'Branch' },
	},
	PrivMap => {
		administrator => { level => 0 },
		operator      => { level => 4 },
	},
);
{
	no warnings 'once';
	*Compat::NMIS::loadGenericTable = sub { push @TABLE_CALLS, $_[0]; return $TABLES{ $_[0] } || {}; };
}

my $KEY     = 'omk-12824-test-key-9f2c';    # unique, so key_is_insecure passes
my $dir     = tempdir(CLEANUP => 1);
my $sessdir = "$dir/user_session";
mkdir($sessdir) or die "cannot create $sessdir: $!";

sub new_auth
{
	my (%over) = @_;
	return NMISNG::Auth->new(conf => {
		session_dir            => $sessdir,
		auth_web_key           => $KEY,
		auth_expire            => '+30min',
		auth_debug             => 'false',
		auth_default_privilege => '',
		auth_default_groups    => '',
		%over,
	});
}

# a session as NMIS writes one: params set, then signed
sub make_session
{
	my ($auth, %f) = @_;
	# CGI::Session->new adopts the session the request names, so mint from a
	# request that names none, else two calls in a row return one file
	local $ENV{HTTP_COOKIE} = '';
	CGI::initialize_globals();
	my $session = CGI::Session->new(undef, undef, { Directory => $sessdir });
	$session->param($_, $f{$_}) for (keys %f);
	my $sig = $auth->_session_privs_signature($session);
	$session->param('privs_sig', $sig) if (defined $sig);
	$session->flush();
	return $session;
}

# put the auth cookie for $user, and optionally a session id, into the request
sub set_request
{
	my ($auth, $user, $sid, %opt) = @_;
	my $cookie = $auth->generate_cookie(user_name => $user);
	my ($cval) = $cookie =~ /^[^=]+=([^;]+)/;
	my @jar = ($auth->get_cookie_name() . "=$cval");
	push @jar, $auth->get_session_cookie_name() . "=$sid" if (defined $sid);
	$ENV{HTTP_COOKIE}    = join("; ", @jar);
	$ENV{REQUEST_METHOD} = 'GET';
	$ENV{QUERY_STRING}   = $opt{query} // '';
	CGI::initialize_globals();
	return;
}

# a stub session with a fixed id, so the golden digest below is deterministic
{
	package FakeSession;
	sub new   { my ($class, %f) = @_; return bless({ %f }, $class); }
	sub id    { return $_[0]->{_id}; }
	sub param { my ($self, $k) = @_; return $self->{$k}; }
}

my $au = new_auth();

# 1. the digest is stable, and covers what it claims to cover
my $s1 = make_session($au, username => 'alice', priv => 'administrator',
	privlevel => 0, rawgroups => 'all', auth => 'htpasswd');
my $sig1 = $au->_session_privs_signature($s1);
like($sig1, qr/^[a-f0-9]{64}$/, 'signature is sha256 hex');
is($au->_session_privs_signature($s1), $sig1, 'signature is stable for unchanged fields');
ok($au->_session_privs_trusted($s1), 'a session NMIS signed is trusted');

# 2. editing any signed field breaks it
for my $field (qw(username priv privlevel rawgroups auth dn))
{
	my $s = make_session($au, username => 'mallory', priv => 'operator',
		privlevel => 4, rawgroups => 'Branch', auth => 'htpasswd');
	$s->param($field, 'tampered');
	ok(!$au->_session_privs_trusted($s), "tampering with $field breaks the signature");
}

# 3. a signature cannot be lifted from another session or another user, because
# the session id and the username are inside it
{
	my $other = make_session($au, username => 'alice', priv => 'administrator',
		privlevel => 0, rawgroups => 'all', auth => 'htpasswd');
	isnt($au->_session_privs_signature($other), $sig1,
		'the same fields in a different session sign differently');

	my $lifted = make_session($au, username => 'mallory', priv => 'administrator',
		privlevel => 0, rawgroups => 'all', auth => 'htpasswd');
	$lifted->param('privs_sig', $sig1);              # alice's signature, mallory's file
	ok(!$au->_session_privs_trusted($lifted), "another session's signature does not carry over");
}

# 4. an insecure auth_web_key signs nothing and trusts nothing
{
	my $weak = new_auth(auth_web_key => 'CHANGE_ME_NOW');
	is($weak->_session_privs_signature($s1), undef, 'no signature with an insecure key');
	ok(!$weak->_session_privs_trusted($s1), 'nothing is trusted with an insecure key');
}

# 5. ownership: the session must name the user we ask about
{
	my $alice = make_session($au, username => 'alice', priv => 'administrator',
		privlevel => 0, rawgroups => 'all');
	set_request($au, 'mallory', $alice->id);
	@LOGGED = ();
	is($au->_load_owned_session(user => 'mallory'), undef, "alice's session is not mallory's");
	ok(scalar(grep { /SECURITY/ && /not owned by/ } @LOGGED), 'a real ownership mismatch is logged as SECURITY');

	set_request($au, 'alice', $alice->id);
	my $got = $au->_load_owned_session(user => 'alice');
	ok($got, 'the owner gets their own session');
	is($got->id, $alice->id, 'and it is the one the cookie named');

	# the username is stored unnormalised, so the comparison is case-insensitive
	set_request($au, 'Alice', $alice->id);
	ok($au->_load_owned_session(user => 'Alice'), 'ownership comparison is case-insensitive');
}

# 6. the session id comes from the cookie alone
{
	my $alice = make_session($au, username => 'alice', priv => 'administrator',
		privlevel => 0, rawgroups => 'all');
	my $name = $au->get_session_cookie_name();
	set_request($au, 'alice', undef, query => "$name=" . $alice->id);
	is($au->_load_owned_session(user => 'alice'), undef, 'a session id in the query string is ignored');
}

# 7. a malformed id is refused before any load
{
	for my $bad ('../../etc/passwd', 'ZZZZ', '', 'a' x 31, 'a' x 33)
	{
		set_request($au, 'alice', $bad);
		is($au->_load_owned_session(user => 'alice'), undef, "malformed session id refused: '$bad'");
	}
}

# 8. a file that names nobody, and an id with no file, are owned by nobody and
# are not logged as attacks
{
	my $empty = CGI::Session->new(undef, undef, { Directory => $sessdir });
	$empty->param('priv', 'administrator');       # no username at all
	$empty->flush();
	set_request($au, 'alice', $empty->id);
	@LOGGED = ();
	is($au->_load_owned_session(user => 'alice'), undef, 'a session naming no user is owned by nobody');

	set_request($au, 'alice', 'f' x 32);
	is($au->_load_owned_session(user => 'alice'), undef, 'an id with no file on disk loads nothing');
	is(scalar(grep { /SECURITY/ } @LOGGED), 0, 'neither case is logged as a SECURITY event');
}

# 9. no owner, no session
{
	set_request($au, 'alice', undef);
	is($au->_load_owned_session(user => ''), undef, 'an empty owner never matches');
	is($au->_load_owned_session(), undef, 'a missing owner never matches');
}

# 10. the writer signs what it writes, and leaves no unsigned copy of the groups
{
	my $w = new_auth();
	$w->{user} = 'alice'; $w->{auth} = 'htpasswd'; $w->{dn} = undef;
	$w->{priv} = 'administrator'; $w->{privlevel} = 0; $w->{rawgroups} = 'all';

	my $session = CGI::Session->new(undef, undef, { Directory => $sessdir });
	$session->param('groups', ['all', 'network']);      # the dead field, as written today
	ok($w->_store_session_privs($session), 'the writer reports success');
	is($session->param('username'), 'alice', 'username is stored');
	is($session->param('priv'), 'administrator', 'priv is stored');
	is($session->param('groups'), undef, 'the unread groups field is cleared, not left unsigned');
	ok($w->_session_privs_trusted($session), 'what the writer wrote is trusted on read');
}

# 11. with an insecure key the writer stores no signature, so nothing is trusted
{
	my $w = new_auth(auth_web_key => 'CHANGE_ME_NOW');
	$w->{user} = 'alice'; $w->{priv} = 'administrator'; $w->{privlevel} = 0;
	my $session = CGI::Session->new(undef, undef, { Directory => $sessdir });
	$session->param('privs_sig', 'a stale signature from a better key');
	$w->_store_session_privs($session);
	is($session->param('privs_sig'), undef, 'a stale signature is cleared, never left in place');
	ok(!$w->_session_privs_trusted($session), 'and the session is not trusted');
}

# 12. the attack: mallory's own cookie plus alice's session id must not escalate
{
	my $alice = make_session($au, username => 'alice', priv => 'administrator',
		privlevel => 0, rawgroups => 'all', auth => 'htpasswd');
	set_request($au, 'mallory', $alice->id);
	@LOGGED = ();
	my $a = new_auth();
	ok($a->SetUser('mallory'), 'SetUser still succeeds, it does not refuse the request');
	is($a->{priv}, 'operator', 'privilege comes from the Users table, not the session');
	is($a->{privlevel}, 4, 'and so does the level');
	# SetGroups replaces the arrayref it pushed "network" onto, so a plain group
	# list ends up as itself. Asserting observed behaviour, not intended behaviour.
	is_deeply($a->{groups}, ['Branch'], 'groups are not forged either');
	ok(!$a->{all_groups_allowed}, "and alice's all-groups flag is not inherited");
	ok(scalar(grep { /SECURITY/ } @LOGGED), 'the attempt is logged');
}

# 13. the owner still gets the cached path, so no LDAP round trip is reintroduced
{
	my $m = make_session($au, username => 'mallory', priv => 'operator',
		privlevel => 4, rawgroups => 'Branch', auth => 'ldap');
	set_request($au, 'mallory', $m->id);
	@TABLE_CALLS = ();
	my $a = new_auth();
	ok($a->SetUser('mallory'), 'the owner is set up from the cache');
	is($a->{priv}, 'operator', 'cached privilege is used');
	is($a->{auth}, 'ldap', 'cached auth method is restored');
	is_deeply([sort @TABLE_CALLS], ['PrivMap'], 'only PrivMap is read, the Users table is not');
}

# 14. an unsigned or tampered session falls through instead of being trusted
{
	my $legacy = CGI::Session->new(undef, undef, { Directory => $sessdir });
	$legacy->param(username => 'mallory', priv => 'administrator', privlevel => 0,
		rawgroups => 'all');                      # pre-fix file, no privs_sig
	$legacy->flush();
	set_request($au, 'mallory', $legacy->id);
	my $a = new_auth();
	$a->SetUser('mallory');
	is($a->{priv}, 'operator', 'an unsigned session does not escalate');

	my $poisoned = make_session($au, username => 'mallory', priv => 'operator',
		privlevel => 4, rawgroups => 'Branch');
	$poisoned->param('priv', 'administrator');    # edited after signing
	$poisoned->param('privlevel', 0);
	$poisoned->flush();
	set_request($au, 'mallory', $poisoned->id);
	$a = new_auth();
	$a->SetUser('mallory');
	is($a->{priv}, 'operator', 'a session edited after signing does not escalate');
}

# 15. privlevel is re-derived, so a PrivMap edit is not pinned by the signature
{
	my $m = make_session($au, username => 'mallory', priv => 'operator',
		privlevel => 4, rawgroups => 'Branch');
	set_request($au, 'mallory', $m->id);
	local $TABLES{PrivMap}{operator}{level} = 2;
	my $a = new_auth();
	$a->SetUser('mallory');
	is($a->{privlevel}, 2, 'the level follows PrivMap, not the signed number');

	# a priv that PrivMap no longer knows discards the cache entirely
	my $gone = make_session($au, username => 'mallory', priv => 'retired-role',
		privlevel => 0, rawgroups => 'all');
	set_request($au, 'mallory', $gone->id);
	$a = new_auth();
	$a->SetUser('mallory');
	is($a->{priv}, 'operator', 'a priv missing from PrivMap falls through to _GetPrivs');
}

# 16. no regression: a request with no session at all behaves as _GetPrivs says
{
	set_request($au, 'alice', undef);
	my $a = new_auth();
	ok($a->SetUser('alice'), 'a user with no session is still set up');
	is($a->{priv}, 'administrator', 'from the Users table');
	is($a->{privlevel}, 0, 'with the PrivMap level');

	# and the cookie must name the same user as the argument. mallory's session is
	# live and correctly signed, so only the equality check stops alice borrowing it
	my $ms = make_session($au, username => 'mallory', priv => 'operator',
		privlevel => 4, rawgroups => 'Branch');
	set_request($au, 'mallory', $ms->id);
	$a = new_auth();
	$a->SetUser('alice');
	is($a->{priv}, 'administrator', "alice does not inherit mallory's cached privileges");
	is($a->{privlevel}, 0, 'and keeps her own level');
}

# 17. the writeback composition: a session that is not ours is never the one
# written to, and a fresh one is minted instead
{
	my $alice = make_session($au, username => 'alice', priv => 'administrator',
		privlevel => 0, rawgroups => 'all');
	my $before = $alice->param('priv');

	my $a = new_auth();
	$a->{user} = 'mallory'; $a->{priv} = 'operator'; $a->{privlevel} = 4;
	$a->{rawgroups} = 'Branch';
	set_request($au, 'mallory', $alice->id);

	my $target = $a->_writeback_session(user => $a->{user});
	$a->_store_session_privs($target);
	$target->flush();

	isnt($target->id, $alice->id, "the write goes to a fresh session, not alice's");

	my $reread = CGI::Session->load(undef, $alice->id, { Directory => $sessdir });
	is($reread->param('username'), 'alice', "alice's session still names alice");
	is($reread->param('priv'), $before, "and still holds her own privilege");
	ok($au->_session_privs_trusted($reread), "and her signature is intact");
}

# 18. our own session is reused rather than replaced, which is the normal path
{
	my $m = make_session($au, username => 'mallory', priv => 'operator',
		privlevel => 4, rawgroups => 'Branch');
	my $a = new_auth();
	$a->{user} = 'mallory'; $a->{priv} = 'operator'; $a->{privlevel} = 4;
	$a->{rawgroups} = 'Branch';
	set_request($au, 'mallory', $m->id);

	my $target = $a->_writeback_session(user => $a->{user});
	is($target->id, $m->id, 'the caller keeps the session it already had');
}

# 19. generate_session must not adopt the session the request names, or the
# fallback above would hand back the session ownership just refused
{
	my $alice = make_session($au, username => 'alice', priv => 'administrator',
		privlevel => 0, rawgroups => 'all');
	set_request($au, 'mallory', $alice->id);
	my $minted = $au->generate_session(user_name => 'mallory');
	isnt($minted->id, $alice->id, 'a minted session does not take the requested id');
	is($minted->param('username'), 'mallory', 'and it names the user it was minted for');
	is($minted->param('priv'), undef, "and carries none of alice's privileges");
}

# 20. logout deletes its own session and nobody else's, whatever
# max_sessions_enabled says
{
	my $alice   = make_session($au, username => 'alice', priv => 'administrator',
		privlevel => 0, rawgroups => 'all');
	my $mallory = make_session($au, username => 'mallory', priv => 'operator',
		privlevel => 4, rawgroups => 'Branch');

	# mallory logs out while naming alice's session
	my $a = new_auth(max_sessions_enabled => 'false');
	$a->{user} = 'mallory';
	set_request($au, 'mallory', $alice->id);
	my $victim = $a->_load_owned_session(user => $a->{user});
	is($victim, undef, "mallory cannot reach alice's session to delete it");
	# -f is a named unary op and binds tighter than ".", so the path needs parens
	ok(-f("$sessdir/cgisess_" . $alice->id), "so alice's session file survives");

	# and her own logout does delete, with the setting off
	set_request($au, 'mallory', $mallory->id);
	my $own = $a->_load_owned_session(user => $a->{user});
	ok($own, 'her own session is reachable');
	$own->delete(); $own->flush();
	ok(!-f("$sessdir/cgisess_" . $mallory->id), 'and it is deleted even with max_sessions_enabled false');
}

# 21. the gate itself is gone from do_logout
{
	open(my $fh, '<', "$FindBin::Bin/../lib/NMISNG/Auth.pm") or die "cannot read Auth.pm: $!";
	my $src = do { local $/; <$fh> };
	close $fh;
	my ($logout) = $src =~ /\nsub do_logout \{(.*?)\n\}\n/s;
	ok(defined $logout, 'do_logout is found in the source');
	# the sigil matters: the comment explaining the removal names the setting
	unlike($logout, qr/\$max_sessions_enabled/, 'do_logout no longer gates the delete on max_sessions_enabled');
	unlike($logout, qr/\$cgi->param\(/, 'do_logout no longer accepts a session id from a request parameter');
	like($logout, qr/_load_owned_session/, 'do_logout goes through the ownership check');

	# a POST form field reaches CGI through STDIN, which is awkward to fake; this
	# pins the stronger property, that param() is never consulted for the id at all
	unlike($src, qr/param\(\s*\$self->get_session_cookie_name/,
		'no call site takes the session id from a request parameter');
}

# 22. the signed layout is a contract with every session already on disk. Field
# names travel with the values, so adding, removing, renaming or reordering one
# changes these bytes by itself. If this digest changes, every seal on disk is
# invalidated: harmless, they fall through to _GetPrivs and get re-signed, but it
# should be a decision rather than a surprise.
{
	my $fixed = FakeSession->new(_id => '0' x 32, username => 'Alice',
		priv => 'operator', privlevel => 4, rawgroups => 'c1', auth => 'htpasswd',
		dn => undef);
	is($au->_session_privs_signature($fixed),
		'208113077f97ad49e2bb251d23541cc0ecb396e78a28c445fe4de0279b363a07',
		'signed layout is unchanged (every existing seal expires if this changes)');
}

# 23. a value moved between two adjacent fields must not sign the same, which is
# what the field names guarantee even if a future builder drops empty fields
{
	my %base = (_id => '1' x 32, username => 'mallory', priv => 'operator',
		privlevel => 4, dn => undef);
	my $groupless = FakeSession->new(%base, rawgroups => '',    auth => 'all');
	my $grouped   = FakeSession->new(%base, rawgroups => 'all', auth => '');
	isnt($au->_session_privs_signature($groupless), $au->_session_privs_signature($grouped),
		'moving a value into rawgroups changes the signature');

	# an absent field and an empty one are the same thing here, deliberately, so a
	# session that never had a dn and one whose dn is "" verify identically
	my $absent = FakeSession->new(%base, rawgroups => 'c1', auth => 'htpasswd');
	my $empty  = FakeSession->new(%base, rawgroups => 'c1', auth => 'htpasswd', dn => '');
	is($au->_session_privs_signature($absent), $au->_session_privs_signature($empty),
		'undef and empty sign the same, so no session is invalidated by the difference');
}

# 24. loginout prints headers and exits, so its call sites cannot be driven in
# process here. Pin them structurally, as case 21 does for do_logout: a revert of
# the writeback or of either writer would otherwise pass this whole suite.
{
	open(my $fh, '<', "$FindBin::Bin/../lib/NMISNG/Auth.pm") or die "cannot read Auth.pm: $!";
	my $src = do { local $/; <$fh> };
	close $fh;
	my ($body) = $src =~ /\nsub loginout \{(.*?)\nsub /s;
	ok(defined $body, 'loginout is found in the source');

	like($body, qr/_writeback_session/, 'loginout picks its session through _writeback_session');
	unlike($body, qr/CGI::Session->load\(\s*undef\s*,\s*undef/,
		'loginout no longer loads a session by whatever id the request names');
	is(scalar(() = $body =~ /_store_session_privs/g), 2,
		'both writer sites go through _store_session_privs');
	unlike($body, qr/\$session->param\(\s*'(?:priv|privlevel|rawgroups|username)'/,
		'no writer site sets a privilege field directly, so none can go unsigned');
}

done_testing();
