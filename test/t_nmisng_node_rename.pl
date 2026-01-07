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

# Test NMISNG Node functions
#  uses nmisng object for convenience
#  creates (and removes) a mongo database called t_nmisg-<timestamp>
#  in whatever mongodb is configured in ../conf/

use strict;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Deep;
use Data::Dumper;

use NMISNG;
use NMISNG::Node;
use NMISNG::Log;
use NMISNG::Util;
use Compat::NMIS;
use RRDs;
my $C = NMISNG::Util::loadConfTable();

# modify dbname to be time specific for this test
$C->{db_name} = "t_nmisng-" . time;

# log to stdout
my $logger = NMISNG::Log->new( level => 'debug' );

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);
die "NMISNG object required" if ( !$nmisng );

sub cleanup_db
{
	$nmisng->get_db()->drop();
}

# create a node with a numeric name, check that it ends up as string in the db
# OMK-6160
my $numb = NMISNG::Node->new(nmisng => $nmisng, uuid => NMISNG::Util::getUUID);
isnt($numb, undef, "Node object creatable");
$numb->name(12345);
$numb->cluster_id($nmisng->config->{cluster_id});
$numb->configuration({host => "2.3.4.5",
											group => "somegroup",
											netType => "default",
											roleType => "default",
											threshold => 1,
											model => 'automatic' });
cmp_deeply([$numb->save], [1, undef], "numeric name'd node saved ok");


# that's us being precise...
my $res = $nmisng->get_nodes_model(name => NMISNG::DB::make_string("12345"));
is($res->count, 1,
	 "get_nodes_model finds numeric name if searched by forced string");

$numb->collect(wantsnmp => 1);
$numb->rename( "name" => "12345", "new_name" => "12345_renamed");
my ( $catchall_inventory, $error ) = $numb->get_inventory_model( node_uuid => $numb->uuid(),concept => "catchall",fields_hash => {node_name => 1 , storage => 1});
my $data = $catchall_inventory->data();
is( $data->[0]->{storage}->{health}->{rrd}, '/nodes/12345_renamed/health/reach.rrd' , "Node re-named successfully with RRD paths.");

if (-t \*STDIN)
{
	print "enter to continue and cleanup: ";
	my $x = <STDIN>;
}
cleanup_db();
done_testing();
