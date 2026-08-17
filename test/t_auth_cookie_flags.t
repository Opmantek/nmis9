#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#
# OMK-12700: the session cookie must carry SameSite, and Secure when the
# operator has explicitly enabled it. Both branches of generate_cookie are
# covered, including the explicit-value branch used by do_logout and by the
# CGISESSID cookie in loginout.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use CGI ();
use NMISNG::Auth;

# hermetic: the samesite fallback logs through logAuth, which would otherwise
# load the system config and write the auth log. Captured so the invalid-value
# cases can assert the rejection was recorded.
my @logged;
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { push @logged, "@_"; return undef; }; }

sub auth_with
{
	return NMISNG::Auth->new(conf => { auth_web_key => 'k', auth_debug => 'false', @_ });
}

# both branches of generate_cookie: the signed one, and the explicit-value one
sub both_branches
{
	my ($auth) = @_;
	return ( signed => $auth->generate_cookie(user_name => 'alice', expires => '+1h'),
					 value  => $auth->generate_cookie(user_name => 'alice', expires => 'now', value => '') );
}

# --- resolution: the helpers themselves --------------------------------------
is(auth_with()->_cookie_samesite, 'Lax', 'samesite defaults to Lax when unconfigured');
is(auth_with()->_cookie_secure, 0, 'secure defaults to off when unconfigured');

is(auth_with(auth_cookie_samesite => 'strict')->_cookie_samesite, 'Strict',
	 'samesite accepts strict and normalises the case');
is(auth_with(auth_cookie_samesite => '  LAX  ')->_cookie_samesite, 'Lax',
	 'samesite tolerates surrounding whitespace');

# the OMK-12700 escape hatch: "off" is the only way back to a cookie with no
# SameSite attribute at all, which is what shipped before this change. Blank
# still means Lax, so an install that never set the key stays protected.
{
	@logged = ();
	is(auth_with(auth_cookie_samesite => 'off')->_cookie_samesite, undef,
		 'samesite off resolves to no attribute');
	ok(!(grep { /auth_cookie_samesite/ } @logged),
		 'and off is a recognised value, so nothing is logged as invalid');

	my %cookies = both_branches(auth_with(auth_cookie_samesite => 'off'));
	for my $branch (sort keys %cookies)
	{
		unlike($cookies{$branch}, qr/SameSite/i,
			   "the $branch cookie carries no SameSite when it is switched off");
		like($cookies{$branch}, qr/HttpOnly/i,
			 "the $branch cookie still carries HttpOnly when SameSite is off");
	}
}

for my $token (qw(true t yes y 1 TRUE Yes T Y))
{
	@logged = ();
	is(auth_with(auth_cookie_secure => $token)->_cookie_secure, 1,
		 "secure is on for the true token \"$token\"");
	ok(!(grep { /auth_cookie_secure/ } @logged),
		 "a recognised true token \"$token\" logs no rejection");
}
for my $token ('false', 'f', 'no', 'n', '0', '', '   ')
{
	@logged = ();
	my $shown = $token =~ /\S/ ? "\"$token\"" : 'blank';
	is(auth_with(auth_cookie_secure => $token)->_cookie_secure, 0,
		 "secure stays off for the false token $shown");
	ok(!(grep { /auth_cookie_secure/ } @logged),
		 "a recognised false token $shown logs no rejection");
}

# getbool would read every one of these as true on its /^[yt1]/ prefix match,
# turning Secure on over plain http and locking every user out. They must be
# rejected AND logged, so a typo is visible rather than silently ignored.
for my $junk ('none', 'maybe', 'null', 'tls-later', 'yes when TLS lands', 'yellow')
{
	@logged = ();
	is(auth_with(auth_cookie_secure => $junk)->_cookie_secure, 0,
		 "unrecognised auth_cookie_secure \"$junk\" leaves Secure off");
	ok(scalar(grep { /auth_cookie_secure/ } @logged),
		 "unrecognised auth_cookie_secure \"$junk\" is logged, not dropped silently");
}

# None is rejected on purpose: CGI cannot emit it and opmojo writes this same
# cookie, so allowing it would let the two writers disagree.
for my $bad ('None', 'none', 'bogus', 'Lax; Secure')
{
	@logged = ();
	is(auth_with(auth_cookie_samesite => $bad)->_cookie_samesite, 'Lax',
		 "invalid samesite \"$bad\" falls back to Lax");
	ok(scalar(grep { /auth_cookie_samesite/ } @logged),
		 "invalid samesite \"$bad\" is logged, not dropped silently");
}

# an unset or blank value is not an operator error and must not log a rejection
for my $blank (undef, '', '   ')
{
	@logged = ();
	my $shown = defined $blank ? "\"$blank\"" : 'undef';
	is(auth_with(auth_cookie_samesite => $blank)->_cookie_samesite, 'Lax',
		 "blank samesite $shown defaults to Lax");
	ok(!(grep { /auth_cookie_samesite/ } @logged),
		 "blank samesite $shown logs no rejection");
}

# --- emission: what CGI::cookie actually puts on the wire --------------------
{
	my %c = both_branches(auth_with());
	for my $branch (sort keys %c)
	{
		like($c{$branch}, qr/;\s*HttpOnly\b/i, "$branch branch keeps HttpOnly");
		like($c{$branch}, qr/;\s*SameSite=Lax\b/, "$branch branch carries SameSite=Lax by default");
		unlike($c{$branch}, qr/;\s*secure\b/i, "$branch branch has no Secure by default");
	}
}

{
	my %c = both_branches(auth_with(auth_cookie_secure => 'true'));
	like($c{$_}, qr/;\s*secure\b/i, "$_ branch carries Secure when auth_cookie_secure is true")
			for sort keys %c;
}

{
	my %c = both_branches(auth_with(auth_cookie_samesite => 'strict'));
	like($c{$_}, qr/;\s*SameSite=Strict\b/, "$_ branch honours auth_cookie_samesite=strict")
			for sort keys %c;
}

# --- a CGI.pm too old for SameSite must not fail silently -------------------
# the drop changes no return value, so without this warning the CSRF half of
# OMK-12700 would simply not ship on those platforms and nothing would say so.
{
	@logged = ();
	local $NMISNG::Auth::samesite_drop_logged = 0;
	no warnings 'redefine';
	local *CGI::cookie = sub { return 'omk=x; path=/; HttpOnly' };

	my $c = auth_with()->generate_cookie(user_name => 'alice', expires => '+1h');
	unlike($c, qr/SameSite=/i, 'a CGI too old to know SameSite emits no attribute');
	ok(scalar(grep { /dropped SameSite/ } @logged),
		 'a dropped SameSite is logged, not swallowed');

	auth_with()->generate_cookie(user_name => 'alice', expires => '+1h');
	is(scalar(grep { /dropped SameSite/ } @logged), 1,
		 'the warning is logged once per process, not on every cookie');
}

# a CGI that does emit the attribute must stay quiet
{
	@logged = ();
	local $NMISNG::Auth::samesite_drop_logged = 0;
	my %c = both_branches(auth_with());
	like($c{$_}, qr/;\s*SameSite=Lax\b/, "$_ branch still emits SameSite here") for sort keys %c;
	ok(!(grep { /dropped SameSite/ } @logged),
		 'no warning when CGI emits the attribute');
}

# --- the flags are attribute-only: signing still round-trips -----------------
{
	my $auth = auth_with(auth_cookie_secure => 'true', auth_cookie_samesite => 'strict');
	my $set = $auth->generate_cookie(user_name => 'alice', expires => '+1h');
	my ($pair) = split /;\s*/, $set;					# "omk=<escaped value>"
	local $ENV{HTTP_COOKIE} = $pair;
	CGI::initialize_globals();
	is($auth->verify_id, 'alice', 'the cookie still verifies with Secure and SameSite set');
}

done_testing();
