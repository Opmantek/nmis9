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

# Test nmis_util util to see if the performance is better than
# the use of the function in Compat
#  uses nmisng object for convenience

use strict;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Deep;
use Data::Dumper;

use NMISNG;
use NMISNG::Node;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::NetworkStatus;
use Compat::Timing;
use Compat::NMIS;

# log to stdout
my $logger = NMISNG::Log->new( level => 'debug' );
my $t = Compat::Timing->new();

my $nmisng = Compat::NMIS::new_nmisng;

my $group = 'Branches';
my $customer = '';
my $business = '';

my $network_status_result;
my $compatResult;

my $time;

# Measure performance using nmis_util new object
$time = $t->elapTime();
my $result = $nmisng->compute_metrics;
$time = $t->elapTime() - $time;
print $time. " compute metrics (Old code) End $time \n";

# sub $nmisng->compute_metrics2() does not exist:
#### Measure performance using Compat function
###$time = $t->elapTime();
###$result = $nmisng->compute_metrics2;
###$time = $t->elapTime() - $time;
###print $time. " compute metrics (New code) End $time \n";

done_testing();
