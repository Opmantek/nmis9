#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#
# Regression tests for the retirement of the insecure 'nmis' cookie flavour.
# The 'nmis' flavour used a forgeable additive checksum (unpack '%32C*') that
# was also reused as the session id. It, its get_cookie_token routine and the
# auth_cookie_flavour config item are all gone; only the HMAC-signed 'omk'
# cookie scheme remains, and any leftover auth_cookie_flavour setting is inert.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use CGI ();
use NMISNG::Auth;

# keep the test hermetic: verify_id logs failures via NMISNG::Util::logAuth,
# which would otherwise load the system config and write the auth log.
{ no warnings 'redefine'; *NMISNG::Util::logAuth = sub { return undef; }; }

# the only cookie scheme now is omk: the cookie name carries the omk prefix
my $a_default = NMISNG::Auth->new(conf => { auth_web_key => 'k', auth_debug => 'false' });
like($a_default->get_cookie_name, qr/^omk/, 'cookie name uses the omk prefix');

# the flavour concept is gone from the object entirely
ok(!exists $a_default->{cookie_flavour}, 'no cookie_flavour field is stored on the object');

# the weak checksum generator is removed from the class entirely
ok(!NMISNG::Auth->can('get_cookie_token'), 'forgeable get_cookie_token is removed');

# a leftover auth_cookie_flavour setting is ignored, not honoured: still omk
my $a_stale = NMISNG::Auth->new(conf => { auth_cookie_flavour => 'nmis', auth_web_key => 'k', auth_debug => 'false' });
like($a_stale->get_cookie_name, qr/^omk/, 'stale auth_cookie_flavour setting is inert (still omk)');
ok(!exists $a_stale->{cookie_flavour}, 'stale auth_cookie_flavour does not create a cookie_flavour field');

# positive guarantees: verify_id must accept a genuine HMAC-signed omk cookie
# and reject anything that is not one - including the old forgeable format.
# verify_id reads the cookie from the CGI environment, so inject via HTTP_COOKIE.
my $cookie_name = $a_default->get_cookie_name;

# a cookie freshly minted by generate_cookie round-trips through verify_id
my $set_cookie = $a_default->generate_cookie(user_name => 'alice', expires => '+1h');
my ($name_value) = split /;\s*/, $set_cookie;      # "omk=<escaped value>"
$ENV{HTTP_COOKIE} = $name_value;
CGI::initialize_globals();
is($a_default->verify_id, 'alice', 'a valid HMAC-signed omk cookie round-trips through verify_id');

# an old-style 'username:checksum' value in the cookie slot is rejected: it has
# no HMAC signature, so the retired forgeable format can no longer authenticate
$ENV{HTTP_COOKIE} = "$cookie_name=admin:12345";
CGI::initialize_globals();
is($a_default->verify_id, '', 'forged legacy username:checksum cookie is rejected');

# tampering with a single byte of a valid cookie breaks the signature check
my $tampered = $name_value;
$tampered =~ s/(.)$/($1 eq 'a' ? 'b' : 'a')/e;
$ENV{HTTP_COOKIE} = $tampered;
CGI::initialize_globals();
is($a_default->verify_id, '', 'a cookie with a tampered signature is rejected');

# the same guarantees hold when auth_sso_domain is configured. the sso domain is
# factored into the cookie name (omk.<domain>), but signing and verification are
# keyed on auth_web_key, not the domain, so the round-trip and the rejection of a
# forged legacy value must be unchanged from the bare-omk case above.
my $a_sso = NMISNG::Auth->new(conf => { auth_sso_domain => 'example.com', auth_web_key => 'k', auth_debug => 'false' });
my $sso_name = $a_sso->get_cookie_name;
is($sso_name, 'omk.example.com', 'cookie name carries the sso domain when auth_sso_domain is set');

# a cookie minted under the sso cookie name round-trips through verify_id
my $sso_set = $a_sso->generate_cookie(user_name => 'alice', expires => '+1h');
my ($sso_name_value) = split /;\s*/, $sso_set;
$ENV{HTTP_COOKIE} = $sso_name_value;
CGI::initialize_globals();
is($a_sso->verify_id, 'alice', 'a valid HMAC-signed omk cookie round-trips under an sso domain');

# the retired forgeable format is still rejected under the sso cookie name
$ENV{HTTP_COOKIE} = "$sso_name=admin:12345";
CGI::initialize_globals();
is($a_sso->verify_id, '', 'forged legacy cookie is rejected under an sso domain');

done_testing;
