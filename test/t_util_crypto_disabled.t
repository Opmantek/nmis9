#!/usr/bin/perl
# OMK-12827 Slice B: behaviour with encryption DISABLED, modules present, and
# a readable key. Covers the item 8 test owed since Slice A: encrypt of a
# '!!' value while disabled returns it unchanged and writes no config (the
# old code decrypted it and could write the cleartext back). Also proves the
# decrypt down-migration read path (OMK-12709 relies on it) still works, and
# that an undecryptable value fails closed.
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
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'false';
}

use Test::More;

BEGIN {
	for my $m (qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)) {
		eval "require $m; 1" or BAIL_OUT("$m is required for this test and is not installed: $@");
	}
}

use NMISNG::Util;

open(my $fh, '>', $keyfile) or die "cannot write $keyfile: $!";
print $fh ("K" x 256) . "\n";
close $fh;
chmod(0400, $keyfile);

my @writes;
{
	no warnings 'redefine';
	*NMISNG::Util::writeConfData = sub { push @writes, {@_}; return; };
}

my $secret = 'downMigrateMe7';
# force=1 encrypts regardless of the flag; that is how testEncryption works.
my $cipher = NMISNG::Util::encrypt($secret, '', '', 1);
like($cipher, qr/^!!/, "forced encrypt produces ciphertext while disabled");

# item 8 (owed since Slice A): encrypt of a '!!' value while disabled returns
# it unchanged and never emits cleartext or writes config.
@writes = ();
is(NMISNG::Util::encrypt($cipher), $cipher,
	"encrypt of a '!!' value while disabled returns it unchanged");
is(NMISNG::Util::encrypt($cipher, 'database', 'db_password'), $cipher,
	"even with section/keyword args (the removed write-back path)");
is(scalar(@writes), 0, "and attempted no config write");

# the down-migration READ path stays: decrypt of a '!!' value while disabled
# returns the plaintext (Node::new and verifyNMISEncryption rely on it).
is(NMISNG::Util::decrypt($cipher), $secret,
	"decrypt of a '!!' value while disabled returns the plaintext");

# an undecryptable value fails closed, unchanged.
is(NMISNG::Util::decrypt('!!garbagegarbage'), '!!garbagegarbage',
	"decrypt of an undecryptable value while disabled returns it unchanged");

is(scalar(@writes), 0, "no decrypt path attempted a config write (no section/keyword passed)");

done_testing();
