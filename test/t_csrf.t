#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#
# OMK-12699: anti-CSRF token and POST enforcement for the NMIS9 CGI surface.
#
# Follows the t_isindex_guard.t shape, so most subtests run with no MongoDB and
# no live server. See docs/security-hardening-register.md, entries H4 and H5.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use Digest::SHA ();
use File::Basename ();
use NMISNG::Auth;

use constant TESTKEY => 'a-unique-test-key';

# forge a genuinely signed token for an arbitrary user and expiry. Lets the
# expiry and cross-user cases be built without waiting. Goes through the
# production formatter rather than retyping it, so a change to the wire format
# cannot leave these cases passing while no longer testing what they claim.
sub forge
{
	my ($user, $expiry, $key) = @_;
	return NMISNG::Auth::_csrf_format($user, $expiry, $key // TESTKEY);
}

# keep the test hermetic: the auth paths log through NMISNG::Util::logAuth,
# which would otherwise load the system config and write the auth log.
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { return undef; }; }

sub auth_for
{
	my ($user, %conf) = @_;
	my $au = NMISNG::Auth->new(conf => { auth_web_key => TESTKEY,
										 auth_debug   => 'false',
										 %conf });
	$au->{user} = $user;
	return $au;
}

# a freshly minted token verifies for the session that minted it
{
	my $au    = auth_for('alice');
	my $token = $au->mint_csrf_token;
	ok($token, 'mint_csrf_token returns a token');
	ok($au->verify_csrf($token), 'a freshly minted token verifies for the same user');
}

# the control for every forge()-built case below: a forged token that has not
# expired must verify. Without it, a forge() that had drifted from production
# would make the rejection cases pass for the wrong reason.
{
	my $au = auth_for('alice');
	ok($au->verify_csrf(forge('alice', time + 3600)),
	   'forge builds a token the shipped verifier accepts');
}

# an expired token is rejected, even though its signature is genuine
{
	my $au = auth_for('alice');
	ok(!$au->verify_csrf(forge('alice', time - 1)),
	   'an expired token is rejected despite a valid signature');
}

# an install that cannot sign cookies safely must not mint or accept tokens
# either. Same fail-closed contract _auth_web_key already imposes on cookies.
for my $bad ('', 'CHANGE_ME_of_course')
{
	my $label = $bad eq '' ? 'unset' : 'a CHANGE_ME placeholder';
	my $au    = auth_for('alice', auth_web_key => $bad);
	is($au->mint_csrf_token, '', "mint returns empty when auth_web_key is $label");
	ok(!$au->verify_csrf(forge('alice', time + 3600, $bad)),
	   "verify fails closed when auth_web_key is $label");
}

# the token lives exactly as long as the session that owns it. auth_expire is
# reused rather than introducing a second lifetime knob to keep in step.
{
	my $au = auth_for('alice', auth_expire => '+15min');
	my ($expiry) = $au->mint_csrf_token =~ /^(\d+)--/;
	my $lifetime = $expiry - time;
	cmp_ok($lifetime, '<=', 15 * 60, 'token lifetime honours auth_expire, upper bound');
	cmp_ok($lifetime, '>',  14 * 60, 'token lifetime honours auth_expire, lower bound');
}

# an unset auth_expire falls back to the same +60min generate_cookie uses
{
	my $au = auth_for('alice');
	my ($expiry) = $au->mint_csrf_token =~ /^(\d+)--/;
	cmp_ok($expiry - time, '>', 59 * 60, 'an unset auth_expire defaults to +60min');
}

# a session with no authenticated user must not mint a usable token. Otherwise
# two unauthenticated sessions agree on the same empty-user MAC and the token
# stops binding anything.
{
	my $au = auth_for(undef);
	is($au->mint_csrf_token, '', 'mint returns empty with no authenticated user');
	ok(!$au->verify_csrf(forge('', time + 3600)),
	   'verify rejects a token bound to no user');
}

# THE property the whole control rests on: a token minted inside one session does
# not validate inside another, because verify recomputes over the currently
# authenticated user. Holds by construction, so this is a characterisation guard
# rather than a case that drove code.
{
	my $mallory = auth_for('mallory');
	my $token   = $mallory->mint_csrf_token;
	my $alice   = auth_for('alice');
	ok(!$alice->verify_csrf($token),
	   "a token minted in mallory's session does not validate in alice's");
	ok($mallory->verify_csrf($token),
	   'and still validates in the session that minted it');
}

# tampered, truncated and malformed tokens are all rejected
{
	my $au    = auth_for('alice');
	my $token = $au->mint_csrf_token;

	(my $flipped = $token) =~ s/(.)$/($1 eq 'a' ? 'b' : 'a')/e;
	ok(!$au->verify_csrf($flipped), 'a token with one flipped signature byte is rejected');

	(my $truncated = $token) =~ s/.{8}$//;
	ok(!$au->verify_csrf($truncated), 'a truncated token is rejected');

	ok(!$au->verify_csrf(undef),     'an undefined token is rejected');
	ok(!$au->verify_csrf(''),        'an empty token is rejected');
	ok(!$au->verify_csrf('garbage'), 'a malformed token is rejected');

	# the expiry is inside the MAC, so it cannot be pushed out by editing the token
	my ($expiry, $sig) = $token =~ /^(\d+)--(.+)$/;
	ok(!$au->verify_csrf(($expiry + 86400) . "--$sig"),
	   'the expiry cannot be extended without breaking the signature');
}

# a token signed with a different key does not validate
{
	my $au = auth_for('alice');
	ok(!$au->verify_csrf(forge('alice', time + 3600, 'some-other-key')),
	   'a token signed with another key is rejected');
}

# every CGI runs incoming values through filter_params, which entity-encodes
# them (OMK-12723). The token has to survive that untouched or it never verifies.
{
	my $au    = auth_for('alice');
	my $token = $au->mint_csrf_token;
	like($token, qr/^\d+--[0-9a-f]{64}$/, 'the token is digits, hex and a -- separator');
	my $filtered = NMISNG::Util::filter_params({ csrf_token => $token });
	is($filtered->{csrf_token}, $token, 'and survives filter_params unchanged');
}

# csrf_hidden_field hands callers a ready-made input, so no CGI has to know the
# field name or the token format
{
	my $au    = auth_for('alice');
	my $field = $au->csrf_hidden_field;
	like($field, qr/type="hidden"/,     'csrf_hidden_field renders a hidden input');
	like($field, qr/name="csrf_token"/, 'and names it csrf_token');
	my ($value) = $field =~ /value="([^"]+)"/;
	ok($au->verify_csrf($value), 'and carries a token that verifies');
}

# with an unusable key there is no token to embed, so the field is omitted
# rather than rendered empty. A blank value would look like a token and fail
# verification for a reason nobody could read off the page.
{
	my $au = auth_for('alice', auth_web_key => '');
	is($au->csrf_hidden_field, '', 'no hidden field is rendered when the key is unusable');
}

#----------------------------------
# enforce_csrf: the guard each mutating CGI calls before its dispatch chain
#----------------------------------

# run enforce_csrf inside a faked CGI environment, capturing anything it prints
# so a 403 body does not leak into the TAP stream.
sub enforce
{
	my ($au, $Q, %env) = @_;

	local %ENV = (%ENV,
				  GATEWAY_INTERFACE => 'CGI/1.1',
				  SCRIPT_NAME       => '/cgi-bin/tables.pl',
				  REQUEST_METHOD    => 'GET',
				  %env);

	my $out = '';
	open(my $saved, '>&', \*STDOUT) or die "cannot save STDOUT: $!";
	close(STDOUT);
	open(STDOUT, '>', \$out) or die "cannot capture STDOUT: $!";
	my $ok = eval { $au->enforce_csrf($Q) };
	my $err = $@;
	close(STDOUT);
	open(STDOUT, '>&', $saved) or die "cannot restore STDOUT: $!";
	close($saved);
	die $err if $err;

	return ($ok, $out);
}

# a read act is waved through, and must not need a token or a POST
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, { act => 'config_table_view' });
	ok($ok, 'a read act passes by GET with no token');
}

# a write act by GET is refused: this is the img-tag attack
{
	my $au = auth_for('alice');
	my ($ok, $out) = enforce($au, { act => 'config_table_dodelete' });
	ok(!$ok, 'a write act by GET is refused');
	like($out, qr/403/, 'and a 403 is sent');
}

# a write act by POST but with no token is refused: this is the auto-submitting
# cross-site form, which POST-only alone would not stop
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, { act => 'config_table_dodelete' },
					   REQUEST_METHOD => 'POST');
	ok(!$ok, 'a write act by POST with no token is refused');
}

# a write act by POST carrying a valid token is allowed
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, { act        => 'config_table_dodelete',
							  csrf_token => $au->mint_csrf_token },
					   REQUEST_METHOD => 'POST');
	ok($ok, 'a write act by POST with a valid token is allowed');
}

# the POST-only control on its own. Every other GET refusal here also lacks a
# token, so the token check would mask a missing method check; this case is the
# only one that fails if the POST requirement is dropped.
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, { act        => 'config_table_dodelete',
							  csrf_token => $au->mint_csrf_token },
					   REQUEST_METHOD => 'GET');
	ok(!$ok, 'a write act by GET is refused even with a valid token');
}

# the attack itself, at the enforcement layer: a token minted in the attacker's
# own logged-in session, replayed against the victim's
{
	my $mallory = auth_for('mallory');
	my $stolen  = $mallory->mint_csrf_token;
	my $alice   = auth_for('alice');
	my ($ok) = enforce($alice, { act => 'config_table_dodelete', csrf_token => $stolen },
					   REQUEST_METHOD => 'POST');
	ok(!$ok, "a token minted in the attacker's session is refused in the victim's");
}

# an act nobody registered is treated as a write, so a new act fails closed
# rather than shipping unprotected
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, { act => 'config_table_brand_new' });
	ok(!$ok, 'an unregistered act is refused, not waved through');
}

# an unknown script is likewise unlisted, so everything on it fails closed
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, { act => 'anything' }, SCRIPT_NAME => '/cgi-bin/brand_new.pl');
	ok(!$ok, 'an unregistered script fails closed');
}

# an install with auth_require off never calls loginout, so there is no session
# cookie, no user to bind a token to and nothing for an attacker to ride. The
# guard must stand aside: refusing would leave such an install unable to write
# anything through the GUI, because no token can be minted there either.
{
	my $au = auth_for(undef, auth_require => 0);
	is($au->mint_csrf_token, '', 'no token can be minted when auth is not required');
	my ($ok) = enforce($au, { act => 'config_table_doadd' }, REQUEST_METHOD => 'POST');
	ok($ok, 'the guard stands aside when authentication is not required');
}

# the OMK-12699 escape hatch. An install driving write acts from automation with
# a session cookie and no token breaks on upgrade, and this is the way back.
# Only an explicit false token turns it off, and the refusal to enforce is
# logged, so a disabled guard is visible rather than silent.
{
	my @logged;
	no warnings 'redefine';
	local *NMISNG::Util::logAuth = sub { push @logged, "@_"; return undef; };

	for my $off (qw(false f no n 0))
	{
		@logged = ();
		my $au = auth_for('alice', auth_csrf_enforce => $off);
		my ($ok) = enforce($au, { act => 'config_table_dodelete' });
		ok($ok, "enforcement is off for the false token \"$off\"");
		ok((grep { /auth_csrf_enforce/ } @logged),
		   "and turning it off for \"$off\" is logged");
	}

	# anything else keeps the guard on, including the near-misses that a prefix
	# match would swallow
	for my $on ('true', '', '   ', 'nope', 'falsey', 'no_thanks')
	{
		my $shown = $on =~ /\S/ ? "\"$on\"" : 'blank';
		my $au = auth_for('alice', auth_csrf_enforce => $on);
		my ($ok) = enforce($au, { act => 'config_table_dodelete' });
		ok(!$ok, "enforcement stays on for $shown");
	}

	# a disabled hatch must not log on reads, or every page load writes a SECURITY
	# line. The check sits after the read classification to keep that true.
	@logged = ();
	my $au = auth_for('alice', auth_csrf_enforce => 'false');
	my ($ok) = enforce($au, { act => 'config_table_menu' });
	ok($ok, 'a read still passes with enforcement off');
	ok(!(grep { /auth_csrf_enforce/ } @logged),
	   'and a disabled guard does not log on a read');
}

# command-line invocation has no browser and no session, so the guard stands
# aside. Same carve-out the ISINDEX guard uses.
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, { act => 'config_table_dodelete' }, GATEWAY_INTERFACE => '');
	ok($ok, 'the guard no-ops off the CGI path');
}

# a missing act must not be mistaken for a read
{
	my $au = auth_for('alice');
	my ($ok) = enforce($au, {});
	ok(!$ok, 'a request with no act at all is refused');
}

#----------------------------------
# registry completeness. The table lives in Auth.pm, away from the dispatch
# chains it describes, so this is what stops it drifting. The registry is
# load-bearing rather than a nicety, per docs/security-hardening-register.md H4.
#----------------------------------
{
	my (@missing, %seen_script);
	for my $path (sort glob("$FindBin::Bin/../cgi-bin/*.pl"))
	{
		my $script = File::Basename::basename($path);
		open(my $fh, '<', $path) or die "cannot read $path: $!";
		my $src = do { local $/; <$fh> };
		close $fh;

		# the dispatch chain is the top-level code before the first sub. Scoping
		# to it matters: inside the handlers, $Q->{act} =~ /delete/ is a substring
		# test telling config_table_delete from config_table_dodelete, not an act.
		my ($chain) = $src =~ /^(.*?)^sub /ms;
		$chain //= $src;

		# both dispatch spellings appear in the tree. ip.pl and tools.pl use the
		# regex form, so matching only eq would miss them entirely.
		my %acts;
		$acts{$1} = 1 while ($chain =~ /\$Q->\{act\}\s*eq\s*['"]([a-zA-Z0-9_]+)['"]/g);
		$acts{$1} = 1 while ($chain =~ m{\$Q->\{act\}\s*=~\s*/\^?([a-zA-Z0-9_]+)}g);
		$seen_script{$script} = 1 if (keys %acts);

		push @missing, "$script:$_"
			for grep { !exists $NMISNG::Auth::CSRF_ACT_CLASS{$script}->{$_} } sort keys %acts;
	}
	is_deeply(\@missing, [], 'every act in every dispatch chain is classified')
		or diag("unclassified acts: " . join(', ', @missing));

	# guards the scoping above: if a chain ever moves below the first sub, its acts
	# would silently vanish from the scan and this test would pass while blind.
	my @unseen = sort grep { !$seen_script{$_} } keys %NMISNG::Auth::CSRF_ACT_CLASS;
	is_deeply(\@unseen, [], 'every registered script had its dispatch chain found')
		or diag("registered but no chain located: " . join(', ', @unseen));
}

#----------------------------------
# enforcement placement. Every script owning a write act must call the guard,
# before its dispatch chain, with nothing rewriting the act in between. That
# last clause is the node.pl forceAct trap: a guard placed ahead of an act
# rewrite classifies the wrong act and waves the real one through.
#----------------------------------
{
	my @write_scripts = sort grep {
		grep { $_ eq 'write' } values %{ $NMISNG::Auth::CSRF_ACT_CLASS{$_} }
	} keys %NMISNG::Auth::CSRF_ACT_CLASS;

	is(scalar @write_scripts, 12, 'twelve scripts own a write act');

	for my $script (@write_scripts)
	{
		my $path = "$FindBin::Bin/../cgi-bin/$script";
		open(my $fh, '<', $path) or die "cannot read $path: $!";
		my $src = do { local $/; <$fh> };
		close $fh;

		my ($chain) = $src =~ /^(.*?)^sub /ms;
		$chain //= $src;

		my $guard_at = index($chain, 'enforce_csrf');
		ok($guard_at >= 0, "$script calls enforce_csrf");
		next if ($guard_at < 0);

		my $dispatch_at = ($chain =~ /\$Q->\{act\}\s*(?:eq|=~)/) ? $-[0] : -1;
		cmp_ok($dispatch_at, '>', $guard_at,
			   "$script guards before its dispatch chain");

		my $between = substr($chain, $guard_at, $dispatch_at - $guard_at);
		unlike($between, qr/\$Q->\{act\}\s*=(?![=~])/,
			   "$script does not rewrite the act after guarding");
	}
}

# every form carrying an act must carry a token too. Applied to all act-bearing
# forms rather than only the write ones, because tables.pl builds its act at
# runtime ($action, "config_table_$func") and a static write check would miss it.
{
	my @write_scripts = sort grep {
		grep { $_ eq 'write' } values %{ $NMISNG::Auth::CSRF_ACT_CLASS{$_} }
	} keys %NMISNG::Auth::CSRF_ACT_CLASS;

	for my $script (@write_scripts)
	{
		my $path = "$FindBin::Bin/../cgi-bin/$script";
		open(my $fh, '<', $path) or die "cannot read $path: $!";
		my $src = do { local $/; <$fh> };
		close $fh;

		my $forms  = () = $src =~ /hidden\(\s*-override\s*=>\s*1,\s*-name\s*=>\s*"act"/g;
		next if (!$forms);
		my $tokens = () = $src =~ /csrf_hidden_field/g;
		is($tokens, $forms, "$script: all $forms act-bearing forms carry a csrf token field");
	}
}

# no write act may be reachable from an <a href>. A link is a GET, and a GET
# carries no token, so any such link is either dead on arrival or a hole. This
# is the guard that caught outages.pl:246 and both network.pl links.
{
	my @offenders;
	for my $path (sort glob("$FindBin::Bin/../cgi-bin/*.pl"))
	{
		my $script = File::Basename::basename($path);
		open(my $fh, '<', $path) or die "cannot read $path: $!";
		my @lines = <$fh>;
		close $fh;

		for my $i (0 .. $#lines)
		{
			next if ($lines[$i] !~ /href/i);
			while ($lines[$i] =~ /act=([a-zA-Z0-9_]+)/g)
			{
				my $class = ($NMISNG::Auth::CSRF_ACT_CLASS{$script} || {})->{$1};
				push @offenders, "$script:" . ($i + 1) . ": $1"
					if (defined $class and $class eq 'write');
			}
		}
	}
	is_deeply(\@offenders, [], 'no write act is reachable from an <a href>')
		or diag("write acts behind links:\n  " . join("\n  ", @offenders));
}

done_testing;
