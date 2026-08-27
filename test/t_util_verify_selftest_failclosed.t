#!/usr/bin/perl
# OMK-12827 Slice A: verifyNMISEncryption's self-test-failure branch must NOT
# disable encryption. It must report failure (return 1), print an operator
# message, and never write global_enable_password_encryption.
#
# Runs with the crypto modules PRESENT so verifyNMISEncryption passes its
# require check and reaches the testEncryption gate, then stubs testEncryption
# to fail so the branch is exercised without a broken crypto stack or a master
# key. writeConfData is spied, so nothing is written to disk.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
BEGIN { $ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true'; }
use Test::More;

# This test needs the crypto modules PRESENT (the opposite of
# t_util_encryption_failclosed.t). If absent, verifyNMISEncryption returns at
# the module-missing branch before reaching testEncryption and the branch under
# test is unreachable. Fail loudly rather than skip into a false green.
BEGIN {
    for my $m (qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure)) {
        eval "require $m; 1" or BAIL_OUT("$m is required for this test and is not installed: $@");
    }
}

use NMISNG::Util;
use NMISNG::Log;

my $conf = NMISNG::Util::loadConfTable();
ok(NMISNG::Util::getbool($conf->{global_enable_password_encryption}),
    "encryption is enabled via the NMIS_* env override");

# Force the self-test to fail, without a broken crypto stack or a seed file.
{ no warnings 'redefine'; *NMISNG::Util::testEncryption = sub { 0 }; }

# Spy on writeConfData: record calls, write nothing.
my @writes;
{ no warnings 'redefine'; *NMISNG::Util::writeConfData = sub { push @writes, {@_}; return; }; }

my $logger = NMISNG::Log->new(level => 'info', path => undef);
my $out = '';
my $rc;
{
    local *STDOUT;
    open(STDOUT, '>', \$out) or die "cannot capture STDOUT: $!";
    $rc = NMISNG::Util::verifyNMISEncryption(log => $logger);
}
is($rc, 1, "verifyNMISEncryption reports failure (returns 1) when the self-test fails");
is(scalar(@writes), 0, "the self-test-failure branch writes no config (flag not disabled)");
like($out, qr/NOT been changed/, "prints an operator message stating encryption was not changed");

done_testing();
