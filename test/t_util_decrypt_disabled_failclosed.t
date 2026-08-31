#!/usr/bin/perl
# OMK-12827 Slice B: the latent decrypt crash. With encryption DISABLED, the
# crypto modules missing, and a leftover '!!' value handed to decrypt, the
# pre-fix code fell through the missing-modules branch (which only returned
# for the enabled state) into _make_seed / Crypt::CBC->new and died.
# The fix: the missing-modules branch fails closed in both flag states,
# returning the input unchanged, never dying, never writing config.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

# encryption explicitly DISABLED (also the shipped default).
BEGIN { $ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'false'; }

use Test::More;

BEGIN {
	eval { require Test::Without::Module; Test::Without::Module->import(
		qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)); 1 }
		or BAIL_OUT("Test::Without::Module is required to run this test and is not installed: $@");
}

use NMISNG::Util;

ok(!eval { require Crypt::CBC; 1 }, "Crypt::CBC is forced absent for this test");

my $conf = NMISNG::Util::loadConfTable();
ok(!NMISNG::Util::getbool($conf->{global_enable_password_encryption}),
	"encryption is disabled in the effective config");

# Spy on writeConfData: record every call, perform no write.
my @writes;
{
	no warnings 'redefine';
	*NMISNG::Util::writeConfData = sub { push @writes, {@_}; return; };
}

# The crash case: leftover ciphertext, disabled, no modules. Must not die.
my $result = eval { NMISNG::Util::decrypt('!!leftoverciphertext') };
is($@, '', "decrypt of a '!!' value with encryption disabled and modules missing does not die");
is($result, '!!leftoverciphertext', "and returns the value unchanged (never '')");
is(scalar(@writes), 0, "and attempted no config write");

# The same call with section/keyword must not die or write either.
$result = eval { NMISNG::Util::decrypt('!!leftoverciphertext', 'database', 'db_password') };
is($@, '', "decrypt with section/keyword args does not die");
is($result, '!!leftoverciphertext', "and returns the value unchanged");
is(scalar(@writes), 0, "and attempted no config write");

done_testing();
