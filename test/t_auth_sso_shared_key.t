#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#
# Cross-server SSO regression test for the omk HMAC cookie scheme.
#
# Two NMIS servers that share the same auth_web_key and auth_sso_domain must be
# able to accept each other's auth cookies - that is what makes SSO work across a
# cluster. The omk cookie is signed with hmac_sha1(auth_web_key) over a payload
# of { auth_data => username, expires => ts } and carries nothing server-specific,
# so a valid cookie is portable between any servers that share the key.
#
# These tests also pin the trust boundary: the shared key is the ONLY thing that
# makes a cookie portable. A server with a different key must reject the cookie,
# and a server on a different sso domain gets a different cookie name (so the
# browser never presents this cookie to it in the first place).

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use CGI ();
use NMISNG::Auth;

# keep the test hermetic: verify_id logs via NMISNG::Util::logAuth, which would
# otherwise load the system config and write the auth log.
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { return undef; }; }

# present a Set-Cookie string to the CGI request environment (verify_id reads the
# cookie from there), then return the given server's verdict for it.
sub verify_with
{
	my ($server, $set_cookie) = @_;
	my ($name_value) = split /;\s*/, $set_cookie;   # drop "; domain=...; expires=..."
	$ENV{HTTP_COOKIE} = $name_value;
	CGI::initialize_globals();
	return $server->verify_id;
}

# two independently-constructed servers that share key + sso domain (a cluster)
my %shared = ( auth_web_key => 'a-strong-shared-secret',
			   auth_sso_domain => 'corp.example.com',
			   auth_debug => 'false' );
my $srvA = NMISNG::Auth->new(conf => { %shared });
my $srvB = NMISNG::Auth->new(conf => { %shared });

# both derive the same cookie name from the sso domain, so the browser sends the
# single cookie to both hosts under that domain
is($srvA->get_cookie_name, 'omk.corp.example.com', 'server A cookie name carries the sso domain');
is($srvB->get_cookie_name, $srvA->get_cookie_name,  'server B derives the same cookie name as A');

# the core SSO guarantee, both directions: a cookie minted on one server is
# accepted by the other
my $cookie_from_A = $srvA->generate_cookie(user_name => 'alice', expires => '+1h');
is(verify_with($srvB, $cookie_from_A), 'alice', 'server B accepts a cookie minted by server A (SSO works A->B)');

my $cookie_from_B = $srvB->generate_cookie(user_name => 'bob', expires => '+1h');
is(verify_with($srvA, $cookie_from_B), 'bob', 'server A accepts a cookie minted by server B (SSO works B->A)');

# trust boundary 1: the shared key is what makes the cookie portable. a server on
# the same sso domain but with a DIFFERENT key must reject the cookie.
my $srvC = NMISNG::Auth->new(conf => { auth_web_key => 'a-different-secret',
									   auth_sso_domain => 'corp.example.com',
									   auth_debug => 'false' });
is(verify_with($srvC, $cookie_from_A), '', 'a server with a different auth_web_key rejects the cookie');

# trust boundary 2: a server on a DIFFERENT sso domain gets a different cookie
# name, so the browser would not present this cookie to it in the first place.
my $srvD = NMISNG::Auth->new(conf => { %shared, auth_sso_domain => 'other.example.com' });
isnt($srvD->get_cookie_name, $srvA->get_cookie_name, 'a different sso domain yields a different cookie name');

# SECURITY CAVEAT (documented, not endorsed): if auth_web_key is not configured,
# both servers silently fall back to the same built-in default key, so their
# cookies are mutually portable with NO shared secret ever configured. This
# assertion pins the current behaviour; if the default is ever made fail-closed
# (recommended), this test must be updated deliberately rather than by accident.
my $srvNoKeyA = NMISNG::Auth->new(conf => { auth_sso_domain => 'corp.example.com', auth_debug => 'false' });
my $srvNoKeyB = NMISNG::Auth->new(conf => { auth_sso_domain => 'corp.example.com', auth_debug => 'false' });
my $cookie_default = $srvNoKeyA->generate_cookie(user_name => 'carol', expires => '+1h');
is(verify_with($srvNoKeyB, $cookie_default), 'carol',
	'CAVEAT: unconfigured auth_web_key falls back to the shared built-in default, cookies portable');

done_testing;
