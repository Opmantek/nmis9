#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  This file is part of Network Management Information System ("NMIS").
#
# C2 / OMK-12687: the omk auth cookie is signed with auth_web_key. If that key
# is unset, empty, the shipped "Please Change Me!" placeholder, or the old
# hardcoded source fallback, anyone knowing it can forge a valid admin cookie.
# The fix refuses to sign or verify with any such key. These tests pin that.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use NMISNG::Auth;
use CGI ();
use Digest::SHA ();
use MIME::Base64 ();
use JSON::XS qw(encode_json);

my $OLD_FALLBACK = '5nJv80DvEr3N/921tdKLk+fCjGzOS5F9IqMFhugxVHIguRC8PJKN4f2JJgcATkhv';

# _auth_web_key must reject every insecure key by returning undef
my %insecure = (
	'unset'          => undef,
	'empty'          => '',
	'placeholder'    => 'Please Change Me!',
	'old fallback'   => $OLD_FALLBACK,
	'omk default 1'  => 'My new Opmantek Secret',
	'omk default 2'  => '42 new Opmantek Secrets',
	'table-config example' => 'thisismysecretkey',
	'change_me pref' => 'CHANGE_ME_abc123',
);
for my $label (sort keys %insecure)
{
	my %conf = (auth_debug => 'false');
	$conf{auth_web_key} = $insecure{$label} if defined $insecure{$label};
	my $au = NMISNG::Auth->new(conf => \%conf);
	is($au->_auth_web_key, undef, "insecure key rejected: $label");
}

# a unique key is accepted and returned verbatim
my $good = 'a-unique-per-site-secret-9f3c1e';
my $au_good = NMISNG::Auth->new(conf => { auth_web_key => $good, auth_debug => 'false' });
is($au_good->_auth_web_key, $good, 'a unique auth_web_key is accepted');

# generate_cookie must refuse (empty string) with the placeholder key, so no
# forgeable cookie is ever issued
my $au_bad = NMISNG::Auth->new(conf => { auth_web_key => 'Please Change Me!', auth_debug => 'false' });
is($au_bad->generate_cookie(user_name => 'admin'), '', 'no cookie issued when auth_web_key is the insecure default');

# with a good key a cookie is produced
my $cookie = $au_good->generate_cookie(user_name => 'admin');
ok($cookie ne '', 'a cookie is issued when auth_web_key is unique');

# forge an omk cookie signed with the insecure placeholder key
{
	my $au = NMISNG::Auth->new(conf => { auth_web_key => 'Please Change Me!', auth_debug => 'false' });
	my $payload = encode_json({ auth_data => 'admin', expires => time + 3600 });
	my $value   = MIME::Base64::encode_base64($payload, ''); $value =~ y/=/-/;
	my $forged  = "$value--" . Digest::SHA::hmac_sha1_hex($value, 'Please Change Me!');

	local $ENV{HTTP_COOKIE} = $au->get_cookie_name() . "=$forged";
	CGI::initialize_globals();
	is($au->verify_id, '', 'verify_id rejects a cookie signed with the insecure placeholder key');
}

# a cookie minted with a good key must round-trip through verify_id
{
	my $good = 'a-unique-per-site-secret-9f3c1e';
	my $au   = NMISNG::Auth->new(conf => { auth_web_key => $good, auth_debug => 'false' });
	my $cookie = $au->generate_cookie(user_name => 'admin');   # "name=value--sig; ..."
	my ($cval) = $cookie =~ /=([^;]+)/;
	local $ENV{HTTP_COOKIE} = $au->get_cookie_name() . "=$cval";
	CGI::initialize_globals();
	is($au->verify_id, 'admin', 'verify_id accepts a cookie signed with a unique key');
}

# a good-key cookie with a tampered (equal-length) signature must be rejected.
# This pins the constant-time _secure_compare reject path, which the accept-only
# round trip above does not exercise.
{
	my $good = 'a-unique-per-site-secret-9f3c1e';
	my $au   = NMISNG::Auth->new(conf => { auth_web_key => $good, auth_debug => 'false' });
	my $cookie = $au->generate_cookie(user_name => 'admin');
	my ($cval) = $cookie =~ /=([^;]+)/;
	my ($value, $sig) = split /--/, $cval, 2;
	my $last = chop $sig;                       # flip the last hex char so the
	$sig .= ($last eq '0' ? '1' : '0');         # signature differs but keeps length
	local $ENV{HTTP_COOKIE} = $au->get_cookie_name() . "=$value--$sig";
	CGI::initialize_globals();
	is($au->verify_id, '', 'verify_id rejects a good-key cookie with a tampered signature');
}

# an explicit cookie value (logout/login-page clear) must still be emitted even
# when the key is insecure, so stale cookies can be cleared while auth is off.
{
	my $au = NMISNG::Auth->new(conf => { auth_web_key => 'Please Change Me!', auth_debug => 'false' });
	isnt($au->generate_cookie(user_name => 'someone', expires => 'now', value => ''), '',
		'omk clear cookie (value => "") is emitted despite an insecure key');
	isnt($au->generate_cookie(user_name => 'remove', expires => 'now', value => 'remove'), '',
		'omk remove cookie (value => "remove") is emitted despite an insecure key');
	is($au->generate_cookie(user_name => 'admin'), '',
		'omk auth cookie (no explicit value) is still refused with an insecure key');
}

done_testing;
