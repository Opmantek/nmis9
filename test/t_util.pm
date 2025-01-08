#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# Test NMISNG fuctions
# creates (and removes) a mongo database called t_nmisg-<timestamp>
#  in whatever mongodb is configured in ../conf/
use strict;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::Deep;
use Test::More;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
my ($sampleBytes,$resultBytes);
my ($sampleBits,$resultBits);

print("-------------TESTING Bytes------------\n");
# test case 1, 0 bytes
$sampleBytes = 0;
$resultBytes = NMISNG::Util::getDiskBytes($sampleBytes);
is( $resultBytes, "0 b", "0 bytes => 0 b" );

# test case 2, 0 bytes
$sampleBytes = 100;
$resultBytes = NMISNG::Util::getDiskBytes($sampleBytes);
is( $resultBytes, "100 b", "100 bytes => 100 b" );


# test case 3, 1024 bytes
$sampleBytes = 1024;
$resultBytes = NMISNG::Util::getDiskBytes($sampleBytes);
is( $resultBytes, "1 KB", "1024 bytes => 1 KB" );

# test case 4, 1048576 bytes
$sampleBytes = 1048576;
$resultBytes = NMISNG::Util::getDiskBytes($sampleBytes);
is( $resultBytes, "1 MB", "1048576 bytes => 1 KB" );


# test case 5, 2048576 bytes
$sampleBytes = 2048576;
$resultBytes = NMISNG::Util::getDiskBytes($sampleBytes);
is( $resultBytes, "1.95 MB", "2048576 bytes => 1.95 MB" );


# test case 6, 1073741824 bytes
$sampleBytes = 1073741824;
$resultBytes = NMISNG::Util::getDiskBytes($sampleBytes);
is( $resultBytes, "1 GB", "1073741824 bytes => 1 GB" );


# test case 7, 2073741824 bytes
$sampleBytes = 2073741824;
$resultBytes = NMISNG::Util::getDiskBytes($sampleBytes);
is( $resultBytes, "1.93 GB", "2073741824 bytes => 1.93 GB" );


print("-------------TESTING BITS------------\n");

# test case 1, 0 bits
$sampleBits = 0;
$resultBits = NMISNG::Util::getBits($sampleBits);
is( $resultBits, "0 b", "0 bits => 0 b" );

# test case 2, 100 bits
$sampleBits = 100;
$resultBits = NMISNG::Util::getBits($sampleBits);
is( $resultBits, "100 b", "100 bits => 100 b" );


# test case 3, 1000 bits
$sampleBits = 1000;
$resultBits = NMISNG::Util::getBits($sampleBits);
is( $resultBits, "1 Kb", "1000 bits => 1 Kb" );

# test case 4, 1000000 bits
$sampleBits = 1000000;
$resultBits = NMISNG::Util::getBits($sampleBits);
is( $resultBits, "1 Mb", "1000000 bits => 1 Mb" );


# test case 5, 2000000 bits
$sampleBits = 2000000;
$resultBits = NMISNG::Util::getBits($sampleBits);
is( $resultBits, "2 Mb", "2000000 bits => 2 MB" );


# test case 6, 1000000000 bits
$sampleBits = 1000000000;
$resultBits = NMISNG::Util::getBits($sampleBits);
is( $resultBits, "1 Gb", "1000000000 bits => 1 GB" );


# test case 7, 1500000000 bits
$sampleBits = 1500000000;
$resultBits = NMISNG::Util::getBits($sampleBits);
is( $resultBits, "1.5 Gb", "1500000000 bits => 1.5 GB" );


done_testing();