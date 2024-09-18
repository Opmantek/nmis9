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
die "NMISNG object required" if ( !$nmisng );

sub cleanup_db
{
	$nmisng->get_db()->drop();
}

# create nodes in different ways
my $node = NMISNG::Node->new();
is( $node, undef, "No node created" );
$node = NMISNG::Node->new( nmisng => $nmisng );
is( $node, undef, "No node when UUID missing" );
$node = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
isnt( $node, undef, "Node object returned when required parameters provided" );

is( $node->is_new, 1, "New node is new" );
is( $node->_dirty, 0, "New node with no config is not dirty" );

$node->configuration( {setthis => "tosomething"} );
is( $node->_dirty,   1, "New node some config set is dirty" );
cmp_deeply( [$node->validate], [re(qr/^-\d/),ignore], "New node with no name is not valid" );
cmp_deeply( [$node->save], [re(qr/^-\d/), ignore], "Node without name is not valid, so not saved" );
is( $node->_dirty, 1, "New node some config set that didn't save is still dirty" );
is( $node->is_new, 1, "New node is still new" );

$node->cluster_id($nmisng->config->{cluster_id});
$node->name($node_name);
$node->configuration( {host => "1.2.3.4",
											 group => "somegroup",
											 netType => "default",
											 roleType => "default",
											threshold => 1, } );
is( $node->_dirty,   1, "New node some config set is dirty" );
cmp_deeply( [$node->validate], [1,undef], "New node with name is valid" )
		or diag("validate returned: ".Dumper($node->validate));
cmp_deeply( [$node->save], [1, undef], "Node name is valid, so saved with insert" );
is( $node->_dirty, 0, "New node that is saved is not dirty" );
is( $node->is_new, 0, "New node that is saved is no longer new" );

# now force an update instead of insert
my $configuration = $node->configuration();
$configuration->{host} = 'localhost';
$node->configuration($configuration);
is( $node->_dirty,   1, "node some config set is dirty" );
cmp_deeply( [$node->validate], [1,undef], "node with name is valid" );
cmp_deeply( [$node->save], [2, undef], "Node is valid, so saved with update" );
is( $node->_dirty, 0, "node updated config isn't dirty" );

# create a nonexistent node, but with args that indicate that it SHOULD be pre-existing
my $nonex = NMISNG::Node->new(uuid => NMISNG::Util::getUUID,
															nmisng => $nmisng,
															id => "424242");
is(ref($nonex),"NMISNG::Node", "node that's missing in the db is creatable");
is($nonex->is_new, 1, "nonexistent node is treated as new");
cmp_deeply($nonex->configuration, {}, "nonexistent node has empty configuration");
cmp_deeply($nonex->overrides, {}, "nonexistent node has empty overrides");
cmp_deeply($nonex->name, undef, "nonexistent node has no name");
cmp_deeply($nonex->cluster_id, undef, "nonexistent node has no cluster_id");


my $dbhandle = $nmisng->get_db;
my $nodescoll = $dbhandle->get_collection("nodes");

# test whether configuration deletion works
# first add a property, save, verify...
my $configplus = $node->configuration;
$configplus->{morituri} = "te salutant";
$node->configuration($configplus);
cmp_deeply( [$node->save], [2,undef], "config with extra properties was savable");
my $cursor = $nodescoll->find({name => $node->name});
my @all = $cursor->all;
is(@all, 1, "saved node is in the db");
my $plus = $all[0] // {};

cmp_deeply($plus->{configuration}, $configplus, "saved config data with extras is correct");

# then delete the property, save and compare
my $configminus = $node->configuration;
delete $configminus->{morituri};
$node->configuration($configminus);

cmp_deeply( [$node->save], [2,undef], "config with deleted properties was savable");
$cursor = $nodescoll->find({name => $node->name});
my $minus = $cursor->next // {};

cmp_deeply($minus->{configuration},
					 $configminus, "saved config data with deleted properties is correct");

# test overrides
cmp_deeply( $node->overrides, {}, "node with no overrides should return empty hashref" );
$node->overrides( {thing => "overridden"} );
is( $node->_dirty, 1, "node some overrides set is dirty" );
cmp_deeply( [$node->save], [2, undef], "Node is valid with overrides, so saved with update" )
		or diag("save reported: ".Dumper($node->save));
is( $node->_dirty, 0, "node updated overrides isn't dirty" );

# test getting inventory
# one that doesn't exist should return nothing
my $concept   = 'sometype';
my $data      = {abc => "123"};
my $path_keys = ['abc'];
# node save creates catchall so this shoudl return 1 now
# my ($ret1,$ret2) = $node->inventory();
# print "result of inventory".Dumper($ret1,$ret2)."\n";
# cmp_deeply( [$node->inventory()], [undef, ignore()], "No inventory should return undef" );
my ( $inventory, $error )
	= $node->inventory( concept => $concept, data => $data, path_keys => $path_keys, create => 1 );
isnt( $inventory, undef, "Inventory is created when it does not exist" ) or diag("Error creating inventory:$error");

# create a second inventory entry
my $inventory2_data = $inventory->data();
$inventory2_data->{abc} = "3445";
my ( $inventory2, $error2 )
	= $node->inventory( concept => $concept . "_new", data => $inventory2_data, path_keys => $path_keys, create => 1 );

# save, which should insert
( my $op, $error ) = $inventory->save( node => $node );
is( $op, 1, "Inventory saves with insert op and no error" ) or diag("Save returned error: $error");
isnt( $inventory->id, undef, "Inventory gets an id after it's saved" ) or diag($error);
( $op, $error ) = $inventory2->save( node => $node );
is( $op, 1, "Inventory2 saves with insert op and no error" ) or diag("Save returned error: $error, path:".join(",", @{ $inventory2->path()} ));

my $path = $node->inventory_path( concept => $concept, data => $data, path_keys => $path_keys );

# print "path:".Dumper($path);
# now look for the thing we saved using the proper path
# path_keys not required for either of these because create=>0, if it's possible we were going to create it
# then it might be required
( $inventory, $error ) = $node->inventory( concept => 'sometype', path => $path, create => 0, filter => { historic => undef } );
isnt( $inventory, undef, "Search for inventory using path found entry just added" )
	or diag("Inventory search returned error:$error");
isnt( $inventory->id, undef, "Inventory gets an id after it's saved" );

# and looking for the same thing by id should also return an inventory (although it won't have path_keys saved)
( $inventory, $error ) = $node->inventory( concept => 'sometype', _id => $inventory->id, create => 0 );
isnt( $inventory, undef, "Search for inventory using _id found entry just added" )
	or diag("Inventory search returned error:$error");

( my $modify_inventory, $error ) = $node->inventory( concept => 'sometype', path => $path, create => 0, filter => { historic => undef } );
$modify_inventory->historic(0);

( $inventory, $error ) = $node->inventory( concept => 'sometype', path => $path, create => 0, filter => { historic => 1 } );
is( $inventory, undef, "finding historic finds nothing" );

# this test needs to leave inentory for the next ones
( $inventory, $error ) = $node->inventory( concept => 'sometype', path => $path, create => 0, filter => { historic => 0 } );
isnt( $inventory->id, undef, "finding not historic finds the inventory" );

# get_inventory_ids
my $ids = $node->get_inventory_ids();
# automatically have one catchall made for us
is( @$ids, 3, "getting all inventory ids should be 3" );
$ids = $node->get_inventory_ids( concept => $concept );
is( @$ids, 1, "getting by concept should be 1" );
is( $ids->[0], $inventory->id, "id of inventory should match what we have" );

# get unique inventory concepts
my $concepts = $node->get_distinct_values( key => 'concept', collection => $nmisng->inventory_collection );
cmp_deeply( $concepts, bag($concept, $concept."_new","catchall"), 'distinct of concepts should return two' );

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
											threshold => 1, });
cmp_deeply([$numb->save], [1, undef], "numeric name'd node saved ok");


# that's us being precise...
my $res = $nmisng->get_nodes_model(name => NMISNG::DB::make_string("12345"));
is($res->count, 1,
	 "get_nodes_model finds numeric name if searched by forced string");

# default behaviour is to treat numeric string as number
# but get_nodes_model should be smart now
$res = $nmisng->get_nodes_model(name => "12345");
is($res->count, 1, "get_nodes_model finds numeric name if searched by numeric string");

$res = $nmisng->get_nodes_model(name => 12345);
is($res->count, 1, "get_nodes_model finds numeric name if searched by pure number");

$res = $nmisng->get_nodes_model(name => [ 12345, 6789, "test", "foobar" ]);
is($res->count, 1, "get_nodes_model finds numeric name if asked for list of names incl. pure number");

# get_query now enforces strininess of regex
$res = $nmisng->get_nodes_model(name => "regex:12345");
is($res->count, 1, "get_nodes_model does finds numeric name if asked by regex that could be interpreted as number");

$res = $nmisng->get_nodes_model(name => "regex:..3");
is($res->count, 1, "get_nodes_model does finds numeric name if asked by regex that is not number");

cmp_deeply($nmisng->get_node_names, bag("12345","node1"), "get_node_names finds numeric name'd node");

my $no_inventory = $numb->interface_by_ifDescr( "doesnotexist");
is( $no_inventory, undef, "interface_by_ifDescr returns undef when ifDescr is not found" );

my $index = 1;
my ( $intf_inventory, $error ) = $numb->inventory( concept => "interface", path_keys => [$index], create => 1 );
is($error, undef, "creating new interface inventory should work");

$intf_inventory->data( { "ifDescr" => "existsifDescr", "index" => $index } );
( my $op, $error ) = $intf_inventory->save( node => $numb );
is( $op, 1, "Inventory saves with insert op and no error" ) or diag("Save returned error: $error");
isnt( $intf_inventory->id, undef, "Inventory gets an id after it's saved" );

my $is_inventory = $numb->interface_by_ifDescr( "existsifDescr" );
is( $is_inventory->{data}{ifDescr}, "existsifDescr" , "interface_by_ifDescr finds interface inventory with ifDescr" ) or diag(Dumper($is_inventory));

if (-t \*STDIN)
{
	print "enter to continue and cleanup: ";
	my $x = <STDIN>;
}
cleanup_db();
done_testing();
