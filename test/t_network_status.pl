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
our $VERSION = "1.0.1";

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
my $network_status = NMISNG::NetworkStatus->new( nmisng => $nmisng );

my $group = 'Branches';
my $customer = '';
my $business = '';

my $network_status_result;
my $compatResult;

my $time;

# Measure performance using nmis_util new object
$time = $t->elapTime();
$network_status_result = $network_status->overallNodeStatus( group => $group, customer => $customer, business => $business );
$time = $t->elapTime() - $time;
print $time. " overallNodeStatus End \n";

# Measure performance using Compat function
$time = $t->elapTime();
$compatResult = Compat::NMIS::overallNodeStatus( group => $group, customer => $customer, business => $business );
$time = $t->elapTime() - $time;
print $time. " Compat overallNodeStatus End \n";

# Compare if results are the same
cmp_deeply($network_status_result, $compatResult, "overallNodeStatus has expected attributes");

#Try the Node Table function
$time = $t->elapTime();
$network_status_result = $network_status->get_nt();
$time = $t->elapTime() - $time;
print $time. " get Node table End \n";

# Measure performance using Compat function
$time = $t->elapTime();
$compatResult = Compat::NMIS::loadNodeTable();
$time = $t->elapTime() - $time;
print $time. " Compat get Node table End \n";

# Compare if results are the same
cmp_deeply( $network_status_result, $compatResult, "loadNodeTable has expected attributes");

# Measure performance using nmis_util new object
$time = $t->elapTime();
my @a = (1..9);
for(@a){
    $network_status_result = $network_status->getGroupSummary();
}
$time = $t->elapTime() - $time;
print $time. " getGroupSummary End \n";

# Measure performance using Compat function
$time = $t->elapTime();
@a = (1..9);
for(@a){
    $compatResult = Compat::NMIS::getGroupSummary();
}
$time = $t->elapTime() - $time;
print $time. " Compat getGroupSummary End \n";

# Compare if results are the same
cmp_deeply( $network_status_result, $compatResult, "getGroupSummary has expected attributes");

# Measure performance using nmis_util new object
$time = $t->elapTime();
$network_status_result = $network_status->getGroupSummary(group => "West_Region_309");
$time = $t->elapTime() - $time;
print $time. " getGroupSummary End \n";

# Measure performance using Compat function
$time = $t->elapTime();
$compatResult = Compat::NMIS::getGroupSummary(group => "West_Region_309");
$time = $t->elapTime() - $time;
print $time. " Compat getGroupSummary End \n";
# Compare if results are the same
cmp_deeply( $network_status_result, $compatResult, "getGroupSummary has expected attributes");
#
# Measure performance using nmis_util new object
$time = $t->elapTime();
$network_status_result = $network_status->overallNodeStatus();
$time = $t->elapTime() - $time;
print $time. " overallNodeStatus End \n";

# Measure performance using Compat function
$time = $t->elapTime();
$compatResult = Compat::NMIS::overallNodeStatus();
$time = $t->elapTime() - $time;
print $time. " Compat overallNodeStatus End \n";
# Compare if results are the same
cmp_deeply( $network_status_result, $compatResult, "overallNodeStatus has expected attributes");

my $status       = Compat::NMIS::statusNumber( $network_status_result );
my $status2       = Compat::NMIS::statusNumber( $compatResult );
# Compare if results are the same
cmp_deeply( $network_status_result, $compatResult, "statusNumber has expected attributes");

my $C       = NMISNG::Util::loadConfTable();
my $C2       =  $network_status->{_nmisng}->config;
# Compare if results are the same
cmp_deeply( $C, $C2, "Configuration has expected attributes");

my $NT = $network_status->get_nt();
my $NT2 = Compat::NMIS::loadNodeTable();
# Compare if results are the same
cmp_deeply( $NT, $NT2, "Node table has expected attributes");

done_testing();
