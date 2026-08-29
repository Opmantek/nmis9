#!/usr/bin/perl
# OMK-12827 Slice B: the full encrypt/decrypt failure contract with the crypto
# modules PRESENT. Every failure (key missing, key rejected on permissions,
# cipher error, corrupt payload) returns the input unchanged, never "".
# Also the positive round trip owed since Slice A: with a readable key and
# encryption enabled, a secret encrypts to '!!...' and decrypts back.
#
# The key lives at a custom path (temp dir) via NMIS_MASTER_KEY_FILE, so the
# test needs no root, no container, and never touches the default path.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp;

my ($tempdir, $keyfile);
BEGIN {
	$tempdir = File::Temp::tempdir(CLEANUP => 1);
	$keyfile = "$tempdir/master.key";
	$ENV{NMIS_MASTER_KEY_FILE} = $keyfile;
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true';
}

use Test::More;

BEGIN {
	for my $m (qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)) {
		eval "require $m; 1" or BAIL_OUT("$m is required for this test and is not installed: $@");
	}
}

use NMISNG::Util;

sub write_key
{
	open(my $fh, '>', $keyfile) or die "cannot write $keyfile: $!";
	print $fh ("A" x 64) . ("b" x 64) . ("9" x 64) . ("Z" x 64) . "\n";
	close $fh;
	chmod(0400, $keyfile);
}

# Spy on writeConfData: record every call, perform no write.
my @writes;
{
	no warnings 'redefine';
	*NMISNG::Util::writeConfData = sub { push @writes, {@_}; return; };
}

my $secret = 'mySecret99';

# --- phase 1: no key yet. encrypt/decrypt fail closed, key NOT created ---
is(NMISNG::Util::encrypt($secret), $secret,
	"encrypt with no key returns the plaintext unchanged (never '')");
is(NMISNG::Util::decrypt('!!feedfacecafe'), '!!feedfacecafe',
	"decrypt with no key returns the ciphertext unchanged (never '')");
ok(!-e $keyfile, "the custom key file was never created by encrypt/decrypt");

# --- phase 2: key present. the round trip owed since Slice A ---
write_key();
my $cipher = NMISNG::Util::encrypt($secret);
like($cipher, qr/^!!/, "encrypt produces a '!!' ciphertext with a readable key");
isnt($cipher, $secret, "ciphertext differs from the plaintext");
is(NMISNG::Util::decrypt($cipher), $secret,
	"decrypt returns the original secret (positive round trip)");
is(NMISNG::Util::encrypt($cipher), $cipher,
	"encrypt of an already-encrypted value returns it unchanged");

# --- phase 3: cipher failures return input unchanged ---
is(NMISNG::Util::decrypt('!!nothexatall-not-even-close'), '!!nothexatall-not-even-close',
	"decrypt of undecryptable garbage returns it unchanged (never '')");

# tamper with real ciphertext: flip its first hex digit
my $payload  = substr($cipher, 2);
my $flipped  = (substr($payload, 0, 1) eq 'a' ? 'b' : 'a') . substr($payload, 1);
my $tampered = '!!' . $flipped;
is(NMISNG::Util::decrypt($tampered), $tampered,
	"decrypt of a tampered payload returns it unchanged (never '')");

# corrupt payloads that decrypt "successfully" but carry a broken length
# prefix must also come back unchanged - never '' or undef (review finding:
# a payload of exactly three digits, or a 000 prefix, or shorter than its
# own prefix, previously returned '' / undef). Also (PR #73 review Critical
# 1): a declared length exceeding the remaining bytes ('005abc', 3 short of
# the 5 the prefix promises) or trailing bytes beyond the declared length
# ('003abcdef') must not silently return the mismatched substring ('abc').
{
	open(my $kfh, '<', $keyfile) or die "cannot read $keyfile: $!";
	my $seed = <$kfh>;
	close $kfh;
	chomp($seed);
	my $handle = Crypt::CBC->new(-key => $seed, -cipher => 'Cipher::AES', -pbkdf => 'pbkdf2');
	for my $raw ('123', '12', '000abc', '005abc', '003abcdef') {
		my $evil = '!!' . $handle->encrypt_hex($raw);
		my $got;
		my @warnings;
		{
			local $SIG{__WARN__} = sub { push @warnings, @_; };
			$got = NMISNG::Util::decrypt($evil);
		}
		is($got, $evil, "decrypt of a corrupt-prefix payload ('$raw') returns the input unchanged");
		is(scalar(@warnings), 0, "and emits no runtime warnings") or diag(@warnings);
	}
}

# --- phase 4: bad key permissions are refused, fail closed ---
chmod(0660, $keyfile);
is(NMISNG::Util::encrypt($secret), $secret,
	"encrypt refuses a group-writable key and returns the plaintext unchanged");
is(NMISNG::Util::decrypt($cipher), $cipher,
	"decrypt refuses a group-writable key and returns the ciphertext unchanged");

# --- phase 5: perms fixed, works again; then key removed, fail closed ---
chmod(0400, $keyfile);
is(NMISNG::Util::decrypt($cipher), $secret, "round trip works again after chmod");
unlink($keyfile);
is(NMISNG::Util::decrypt($cipher), $cipher,
	"decrypt with the key deleted returns the ciphertext unchanged");
ok(!-e $keyfile, "the custom key file was not recreated");

is(scalar(@writes), 0, "no code path attempted a config write");

done_testing();
