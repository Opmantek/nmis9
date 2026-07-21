#!/usr/bin/perl
#
# Hermetic tests for NMISNG::Util::writeHashtoFile atomic write behaviour.
#
# Runs without a configured conf/ or MongoDB: it passes an explicit config
# hashref and sets CONTAINER=1 so setFileProtDiag skips ownership/permission
# enforcement (no nmis user or root required).
#
use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::RealBin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use NMISNG::Util;

# skip ownership/permission enforcement so the test is environment-independent
local $ENV{CONTAINER} = "1";

my $dir = tempdir(CLEANUP => 1);

# minimal config: no json, so files use the .nmis (perl) format
my $conf = {
	use_json        => 'false',
	use_json_pretty => 'false',
	nmis_user       => 'nmis',
	nmis_group      => 'nmis',
};

# ---------------------------------------------------------------------------
# happy path: .nmis round-trip (regression guard for the flush/fsync additions)
# ---------------------------------------------------------------------------
my $file = "$dir/atomic";
my $data = { system => { name => 'node1', location => 'DC1' } };

my $err = NMISNG::Util::writeHashtoFile(file => $file, data => $data, conf => $conf);
is($err, undef, "write succeeds");
ok(-s "$file.nmis", "target file is non-empty");

my $back = NMISNG::Util::readFiletoHash(file => $file, conf => $conf);
is(ref($back), 'HASH', "read back returns a hash");
is($back->{system}{name}, 'node1', "data round-trips");

# ---------------------------------------------------------------------------
# empty-temp-file guard: a serializer that reports success but writes nothing
# must NOT overwrite the existing good file
# ---------------------------------------------------------------------------
my $good_size = -s "$file.nmis";

{
	# seam: force an error-free write that produces zero bytes
	local $NMISNG::Util::_data_writer = sub { return undef; };

	my $err2 = NMISNG::Util::writeHashtoFile(
		file => $file,
		data => { system => { name => 'should_not_land' } },
		conf => $conf,
	);
	ok(defined $err2, "empty write is rejected with an error");
	like($err2, qr/empty/i, "error explains the temp file was empty");
}

# original must be intact
ok(-s "$file.nmis", "original file still present after rejected write");
is(-s "$file.nmis", $good_size, "original file size unchanged");

my $back2 = NMISNG::Util::readFiletoHash(file => $file, conf => $conf);
is($back2->{system}{name}, 'node1', "original data preserved after rejected write");

# no leftover temp files
my @tmp = glob("$dir/*.tmp.*");
is(scalar @tmp, 0, "temp file cleaned up after rejected write");

done_testing();
