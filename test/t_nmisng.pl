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

use Test::More;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;

my $C = NMISNG::Util::loadConfTable();

my $node_name = "node1";

# modify dbname to be time specific for this test
$C->{db_name} = "t_nmisng-" . time;

# log to stdout
my $logger = NMISNG::Log->new( level => 'debug' );

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);

isnt( $nmisng, undef, "NMISNG object successfully created" );

sub cleanup_db
{
	$nmisng->get_db()->drop();
}

# search for nodes, none should be found
my $modelData = $nmisng->get_nodes_model();
is( $modelData->count, 0, "No nodes should be found" );

my $md = $nmisng->get_nodes_model( "this.n.that"=>"forbidden",
																	 "sort"=> [42] );
isnt($md->error,undef, "error reporting in modeldata works");
diag("error indicator was: ".$md->error);

# find a non-existent node
my $node = $nmisng->node( uuid => NMISNG::Util::getUUID() );
is( $node, undef, "Node with UUID that doesn't exist isn't found" );

# create a new node
$node = $nmisng->node( uuid => NMISNG::Util::getUUID(), create => 1 );
isnt( $node, undef, "Node with new UUID is created" );

# these tests node.pm a little but is valid as if it's created it should be new and should save
# we want to know that here, also the save is needed to verify the rest of the tests, we need a node in
is( $node->is_new, 1, "Node which was created should be new");
$node->name($node_name);
$node->cluster_id("localhost");
$node->configuration( { host => "1.2.3.4",
												group => "somegroup",
												netType => "default",
												roleType => "default",
												threshold => 1,
											} );
my ($op,$error) = $node->save();

# verify save worked so we can expect load to work
is( $op, 1, "Valid Node should save via insert" ) or diag("Error saving node:$error");

# loading saved node
$node = $nmisng->node( uuid => $node->uuid );
isnt( $node, undef, "Node from uuid is found" );

# search for new node that was created
$modelData = $nmisng->get_nodes_model( uuid => $node->uuid );
is( $modelData->count,             1,          "One node should be found using uuid" );
is( $modelData->data()->[0]{name}, $node_name, "node found should have name set" );
is($modelData->error, undef, "no errors reported");

$modelData = $nmisng->get_nodes_model( name => $node->name );
is( $modelData->count, 1, "One node should be found using name" );
is($modelData->error, undef, "no errors reported");

($error, my $nodeobj) = $modelData->object(0);
is($error, undef, "modeldata object instantiator works");
is(ref($nodeobj), "NMISNG::Node", "modeldata  object instantiator provides correct object");
is($nodeobj->cluster_id, $node->cluster_id, "modeldata object contains the right stuff");

($error, my $nothing) = $modelData->object(42);
isnt($error,undef,"object instantiator reports invalid index arg");
is($nothing,undef, "object instantiator handles invalid index");

my $maybeall = $modelData->objects;
is($maybeall->{success},1,"objectS instantiator succeeds");
is($maybeall->{error},undef,"objectS instantiator reports no error");
is(ref($maybeall->{objects}),"ARRAY","objectS instantiator returns array of objects");
is(ref($maybeall->{objects}->[0]),"NMISNG::Node","objectS instantiator returns node obj");

# get node names
my $node_names = $nmisng->get_node_names();
is( scalar(@$node_names), 1,          "node names list number of nodes expected" );
is( $node_names->[0],     $node_name, "first node name is correct" );

# get node uuids
my $node_uuids = $nmisng->get_node_uuids();
is( scalar(@$node_uuids), 1,           "node uuid list has number of nodes expected" );
is( $node_uuids->[0],     $node->uuid, "first node uuid is correct" );

#TODO: test get_inventory_model

cleanup_db();
done_testing();
