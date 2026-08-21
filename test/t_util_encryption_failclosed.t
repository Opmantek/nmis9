#!/usr/bin/perl
#
# OMK-12827 Slice A: NMISNG::Util's encryption control must never disable itself
# and must fail closed when the crypto modules are unavailable.
#
# With encryption enabled and Crypt::CBC/Crypt::Cipher::AES/Math::Random::Secure
# forced absent, the old code logged, set global_enable_password_encryption to
# "false", wrote the config back, and returned the input. The fix: never write
# the flag, and return "" for a value that cannot be produced.
#
# The flag is set via the NMIS_* env override (in memory, layer 4), so nothing
# on disk changes. writeConfData is replaced by a spy, so the test proves no
# config write is even attempted and touches no files. Crypt modules are forced
# absent with Test::Without::Module, so the branch is exercised on any host.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Must be set before any config load so loadConfTable sees encryption enabled.
BEGIN { $ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true'; }

use Test::More;

# Fail, never skip. If we cannot force the modules absent, the regression cannot
# be exercised and the suite must go red, not quietly green.
BEGIN {
	eval { require Test::Without::Module; Test::Without::Module->import(
		qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)); 1 }
		or BAIL_OUT("Test::Without::Module is required to run this test and is not installed: $@");
}

use NMISNG::Util;
use NMISNG::Log;

# Sanity: the modules really are hidden now.
ok(!eval { require Crypt::CBC; 1 }, "Crypt::CBC is forced absent for this test");

# Confirm the code sees encryption as enabled through the env override.
my $conf = NMISNG::Util::loadConfTable();
ok(NMISNG::Util::getbool($conf->{global_enable_password_encryption}),
	"encryption is enabled in the effective config (via NMIS_* override)");

# Spy on writeConfData: record every call, perform no write.
my @writes;
{
	no warnings 'redefine';
	*NMISNG::Util::writeConfData = sub { push @writes, {@_}; return; };
}

my $logger = NMISNG::Log->new(level => 'info', path => undef);

# --- decrypt ---
@writes = ();
is(NMISNG::Util::decrypt('!!deadbeefciphertext'), "",
	"decrypt of a '!!' value returns '' when crypto is unavailable");
is(scalar(@writes), 0, "decrypt attempted no config write");

@writes = ();
is(NMISNG::Util::decrypt('plainvalue'), 'plainvalue',
	"decrypt of a non-encrypted value passes it through unchanged");
is(scalar(@writes), 0, "decrypt of plaintext attempted no config write");

# --- encrypt ---
@writes = ();
is(NMISNG::Util::encrypt('secretplaintext'), "",
	"encrypt of a plaintext value returns '' when crypto is unavailable");
is(scalar(@writes), 0, "encrypt attempted no config write");

@writes = ();
is(NMISNG::Util::encrypt('!!alreadyencrypted'), '!!alreadyencrypted',
	"encrypt of a '!!' value returns it unchanged, never cleartext");
is(scalar(@writes), 0, "encrypt of a '!!' value attempted no config write");

# --- testEncryption ---
is(NMISNG::Util::testEncryption(), 0,
	"testEncryption reports failure when crypto is unavailable");

# --- verifyNMISEncryption: reports failure, writes nothing, names packages ---
@writes = ();
my $out = '';
{
	local *STDOUT;
	open(STDOUT, '>', \$out) or die "cannot capture STDOUT: $!";
	my $rc = NMISNG::Util::verifyNMISEncryption(log => $logger);
	is($rc, 1, "verifyNMISEncryption reports failure (returns 1) when crypto is unavailable");
}
is(scalar(@writes), 0, "verifyNMISEncryption attempted no config write");
like($out, qr/Crypt::CBC/, "verifyNMISEncryption prints an operator message naming the crypto modules");
like($out, qr/libcrypt-cbc-perl/, "verifyNMISEncryption names the OS packages to install");

done_testing();
