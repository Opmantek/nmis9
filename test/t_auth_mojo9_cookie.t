#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#
# Regression tests for OMK-12902: nmis9 shares one signed session cookie with
# the OMK apps (opmojo4), which use Mojolicious's own signed_cookie. Mojolicious
# changed the MAC at 9.0:
#
#   Mojolicious 8.x : HMAC-SHA1   over  the value alone         (the "mojo8" form)
#   Mojolicious 9.x : HMAC-SHA256 over  "name=value"           (the "mojo9" form)
#
# nmis9 used to speak only the 8.x form, so NMIS<->OMK SSO would break silently
# the day opmojo4 moved to Mojolicious 9.x. The fix makes verify_id accept BOTH
# forms unconditionally (auto-detected from the signature the cookie carries),
# and lets generate_cookie choose the outbound form via auth_sso_cookie_format
# (default 'mojo8', so nothing on the wire changes until an operator opts in).
#
# These tests pin: the exact bytes each sign form emits, that verify accepts
# both forms regardless of the sign setting, that a cookie hand-built the way
# each Mojolicious version would build it is accepted (the real interop
# contract), and that every near-miss forgery - wrong algorithm, wrong MAC
# input, wrong key, wrong cookie name, tampered value/signature, expired - is
# still rejected.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use CGI ();
use MIME::Base64;
use Digest::SHA;
use JSON::XS;
use NMISNG::Auth;

# keep the test hermetic: verify_id and generate_cookie log via
# NMISNG::Util::logAuth, which would otherwise load the system config and write
# the auth log.
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { return undef; }; }

my $KEY    = 'a-strong-shared-secret';
my $DOMAIN = 'example.com';
my $NAME   = "omk.$DOMAIN";     # the cookie name both products derive from the sso domain

# auth objects differing only in how they SIGN. All three VERIFY identically
# (both forms), which is the core of the fix.
my $sign8   = NMISNG::Auth->new(conf => { auth_web_key => $KEY, auth_sso_domain => $DOMAIN,
										  auth_sso_cookie_format => 'mojo8', auth_debug => 'false' });
my $sign9   = NMISNG::Auth->new(conf => { auth_web_key => $KEY, auth_sso_domain => $DOMAIN,
										  auth_sso_cookie_format => 'mojo9', auth_debug => 'false' });
my $default = NMISNG::Auth->new(conf => { auth_web_key => $KEY, auth_sso_domain => $DOMAIN,
										  auth_debug => 'false' });     # no format key at all
my $signbad = NMISNG::Auth->new(conf => { auth_web_key => $KEY, auth_sso_domain => $DOMAIN,
										  auth_sso_cookie_format => 'mojo42', auth_debug => 'false' });

is($sign8->get_cookie_name, $NAME, 'cookie name is derived from the sso domain as expected');

# ---- reference MAC helpers: exactly what each Mojolicious version computes ----
sub b64value  { my $v = encode_base64(encode_json($_[0]), ''); $v =~ y/=/-/; return $v; }
sub mac_sha1  { Digest::SHA::hmac_sha1_hex($_[0], $KEY); }                 # mojo8: over value
sub mac_sha256{ Digest::SHA::hmac_sha256_hex("$_[0]=$_[1]", $KEY); }       # mojo9: over "name=value"

# present a raw "value--signature" wire string under $name to the CGI request
# environment, escaping it through CGI::cookie the same way the read path
# unescapes it, so base64 '+' and '/' survive the round trip.
sub inject
{
	my ($name, $wire) = @_;
	my $set = CGI::cookie({ -name => $name, -value => $wire });
	my ($nv) = split /;\s*/, $set;
	$ENV{HTTP_COOKIE} = $nv;
	CGI::initialize_globals();
}

# pull the (value, signature) a given auth object emitted, decoded through the
# same CGI unescape the verify path uses.
sub minted_value_sig
{
	my ($auth, $set_cookie) = @_;
	my ($nv) = split /;\s*/, $set_cookie;
	$ENV{HTTP_COOKIE} = $nv;
	CGI::initialize_globals();
	my $raw = CGI::cookie($auth->get_cookie_name);
	my $sig = ($raw =~ s/--([^\-]+)$//) ? $1 : undef;
	return ($raw, $sig);
}

my $future = { auth_data => 'alice', expires => time + 3600 };
my $past   = { auth_data => 'alice', expires => time - 3600 };

# =====================================================================
# 1. The sign form is exactly what auth_sso_cookie_format selects.
# =====================================================================
{
	my ($v8, $s8) = minted_value_sig($sign8, $sign8->generate_cookie(user_name => 'alice', expires => '+1h'));
	is($s8, mac_sha1($v8),          'mojo8 sign emits HMAC-SHA1 over the value');
	isnt($s8, mac_sha256($NAME,$v8),'mojo8 sign is NOT the sha256 "name=value" form');

	my ($vd, $sd) = minted_value_sig($default, $default->generate_cookie(user_name => 'alice', expires => '+1h'));
	is($sd, mac_sha1($vd), 'default (no auth_sso_cookie_format) signs in the mojo8 form');

	my ($v9, $s9) = minted_value_sig($sign9, $sign9->generate_cookie(user_name => 'alice', expires => '+1h'));
	is($s9, mac_sha256($NAME,$v9), 'mojo9 sign emits HMAC-SHA256 over "name=value"');
	isnt($s9, mac_sha1($v9),       'mojo9 sign is NOT the sha1 value-only form');
	is(length($s9), 64,            'mojo9 signature is a sha256 hex digest (64 chars)');
	is(length($s8), 40,            'mojo8 signature is a sha1 hex digest (40 chars)');

	my ($vb, $sb) = minted_value_sig($signbad, $signbad->generate_cookie(user_name => 'alice', expires => '+1h'));
	is($sb, mac_sha1($vb), 'an unrecognised auth_sso_cookie_format falls back to the safe mojo8 form');
}

# =====================================================================
# 2. verify_id accepts BOTH forms, whatever this server signs with.
# =====================================================================
{
	my $c8 = $sign8->generate_cookie(user_name => 'alice', expires => '+1h');
	my $c9 = $sign9->generate_cookie(user_name => 'bob',   expires => '+1h');

	for my $srv ([sign8=>$sign8], [sign9=>$sign9], [default=>$default])
	{
		my ($label, $auth) = @$srv;
		inject($NAME, join '--', minted_value_sig($sign8, $c8));
		is($auth->verify_id, 'alice', "$label verifies a mojo8-signed cookie");
		inject($NAME, join '--', minted_value_sig($sign9, $c9));
		is($auth->verify_id, 'bob',   "$label verifies a mojo9-signed cookie");
	}
}

# =====================================================================
# 3. The real interop contract: a cookie hand-built the way each
#    Mojolicious version builds it is accepted.
# =====================================================================
{
	my $v = b64value($future);

	inject($NAME, "$v--" . mac_sha1($v));
	is($default->verify_id, 'alice', 'a Mojolicious 8.x style cookie (sha1 over value) is accepted');

	inject($NAME, "$v--" . mac_sha256($NAME, $v));
	is($default->verify_id, 'alice', 'a Mojolicious 9.x style cookie (sha256 over "name=value") is accepted');
}

# =====================================================================
# 4. Adversarial: near-miss forgeries that mix algorithm, input or name
#    must all be rejected.
# =====================================================================
{
	my $v = b64value($future);

	# right algorithm for 9.x (sha256) but signed over the value ALONE, not "name=value"
	inject($NAME, "$v--" . Digest::SHA::hmac_sha256_hex($v, $KEY));
	is($default->verify_id, '', 'sha256 computed over the value alone (wrong MAC input) is rejected');

	# 8.x algorithm (sha1) but signed over "name=value" instead of the value
	inject($NAME, "$v--" . Digest::SHA::hmac_sha1_hex("$NAME=$v", $KEY));
	is($default->verify_id, '', 'sha1 computed over "name=value" (wrong MAC input) is rejected');

	# correct 9.x construction but bound to a DIFFERENT cookie name: proves the
	# name is part of the MAC. Present it under the name the browser would send
	# (so it is fetched), but sign it as if the name were something else.
	inject($NAME, "$v--" . Digest::SHA::hmac_sha256_hex("omk.other.example.com=$v", $KEY));
	is($default->verify_id, '', 'a mojo9 cookie signed under a different name is rejected (name is bound into the MAC)');
}

# =====================================================================
# 5. Adversarial: wrong key, tampering, expiry - for the new sha256 path.
# =====================================================================
{
	my $v = b64value($future);

	# a valid mojo9 cookie signed with a DIFFERENT key must be rejected
	inject($NAME, "$v--" . Digest::SHA::hmac_sha256_hex("$NAME=$v", 'a-different-secret'));
	is($default->verify_id, '', 'a mojo9 cookie signed with the wrong key is rejected');

	# tamper one byte of the value: signature no longer matches
	my $tv = $v; $tv =~ s/(.)$/($1 eq 'a' ? 'b' : 'a')/e;
	inject($NAME, "$tv--" . mac_sha256($NAME, $v));
	is($default->verify_id, '', 'a mojo9 cookie with a tampered value is rejected');

	# tamper one byte of the signature
	my $ts = mac_sha256($NAME, $v); $ts =~ s/(.)$/($1 eq 'a' ? 'b' : 'a')/e;
	inject($NAME, "$v--$ts");
	is($default->verify_id, '', 'a mojo9 cookie with a tampered signature is rejected');

	# a perfectly-signed mojo9 cookie that has expired is still refused: the
	# signature is valid but expiry is enforced after the MAC check
	my $ev = b64value($past);
	inject($NAME, "$ev--" . mac_sha256($NAME, $ev));
	is($default->verify_id, '', 'a validly-signed mojo9 cookie that has expired is rejected');
}

# =====================================================================
# 6. Independent upgrade works: a mojo9-signing NMIS and a mojo8-signing
#    NMIS accept each other's cookies (the overlap window the fix buys).
# =====================================================================
{
	my $from9 = $sign9->generate_cookie(user_name => 'carol', expires => '+1h');
	inject($NAME, join '--', minted_value_sig($sign9, $from9));
	is($sign8->verify_id, 'carol', 'a mojo8-configured server accepts a mojo9-signed cookie (overlap window)');

	my $from8 = $sign8->generate_cookie(user_name => 'dave', expires => '+1h');
	inject($NAME, join '--', minted_value_sig($sign8, $from8));
	is($sign9->verify_id, 'dave', 'a mojo9-configured server accepts a mojo8-signed cookie (overlap window)');
}

done_testing;
