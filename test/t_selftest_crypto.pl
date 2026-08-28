#!/usr/bin/perl
# OMK-12827 Slice B: selftest carries the GUI alert for a running-daemon
# crypto failure. When encryption is enabled and testEncryption fails, the
# selftest details must contain a failed "Encryption of secrets" entry; when
# the crypto stack works, the entry passes. Other selftest entries are
# environment-dependent and are deliberately not asserted.
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
	eval { require Test::Without::Module; 1 }
		or BAIL_OUT("Test::Without::Module is required to run this test and is not installed: $@");
	for my $m (qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)) {
		eval "require $m; 1" or BAIL_OUT("$m is required for this test and is not installed: $@");
	}
}

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;

# Neutralise config writes for the whole process. With the encryption flag
# forced on, NMISNG::DB's decrypt(db_password, 'database', 'db_password')
# up-migration would otherwise re-encrypt the REAL conf/Config.nmis
# db_password with this test's ephemeral key, breaking Mongo auth for every
# later run (observed in Task 4). This test needs no config writes.
{
	no warnings 'redefine';
	*NMISNG::Util::writeConfData = sub { return; };
}

open(my $fh, '>', $keyfile) or die "cannot write $keyfile: $!";
print $fh ("S" x 256) . "\n";
close $fh;
chmod(0400, $keyfile);

my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_selftestcrypto-" . time;
my $logger = NMISNG::Log->new(level => 'warn');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

sub crypto_entry
{
	my ($tests) = @_;
	my ($entry) = grep { $_->[0] eq "Encryption of secrets" } @$tests;
	return $entry;
}

# --- working crypto: the entry exists and passes ---
my ($allok, $tests) = NMISNG::Util::selftest(nmisng => $nmisng, delay_is_ok => 1);
my $entry = crypto_entry($tests);
ok($entry, "selftest reports an 'Encryption of secrets' entry when encryption is enabled");
is($entry->[1], undef, "the entry passes with working crypto") if ($entry);

# --- broken crypto (modules hidden): the entry fails with a useful message ---
Test::Without::Module->import(qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure));
($allok, $tests) = NMISNG::Util::selftest(nmisng => $nmisng, delay_is_ok => 1);
$entry = crypto_entry($tests);
ok($entry, "the entry is still present with broken crypto");
like($entry->[1] // '', qr/self-test failed/,
	"and it reports the failure") if ($entry);
is($allok, 0, "selftest overall result is failure while crypto is broken");
Test::Without::Module->unimport(qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure));

# --- encryption disabled: no crypto entry at all (spec: disabled -> no check) ---
my %conf_disabled = %$C;
$conf_disabled{global_enable_password_encryption} = 'false';
my $nmisng_disabled = NMISNG->new(config => \%conf_disabled, log => $logger);
($allok, $tests) = NMISNG::Util::selftest(nmisng => $nmisng_disabled, delay_is_ok => 1);
is(crypto_entry($tests), undef, "no 'Encryption of secrets' entry while encryption is disabled");

$nmisng->get_db()->drop();
done_testing();
