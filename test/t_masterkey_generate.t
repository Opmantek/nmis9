#!/usr/bin/perl
# OMK-12827 Slice B: the installer's master key generation must produce a
# 256-character [A-Za-z0-9] key from a CSPRNG, differing between calls.
# Drives the real shell function from installer_hooks/common_masterkey.sh.
use strict;
use warnings;
use FindBin;
use Test::More;

my $lib = "$FindBin::Bin/../installer_hooks/common_masterkey.sh";
ok(-f $lib, "common_masterkey.sh exists") or BAIL_OUT("$lib missing");

sub generate
{
	my $out = `sh -c '. $lib; nmis_masterkey_generate' 2>/dev/null`;
	return $out;
}

my $key1 = generate();
is(length($key1), 256, "generated key is exactly 256 characters");
like($key1, qr/^[A-Za-z0-9]{256}$/, "key charset is [A-Za-z0-9] only");

my $key2 = generate();
isnt($key1, $key2, "two generated keys differ");

done_testing();
