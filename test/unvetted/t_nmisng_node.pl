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

use NMIS::UUID qw(getUUID);

use func qw(loadConfTable);
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
	uuid   => NMIS::UUID::getUUID(),
	nmisng => $nmisng
);
isnt( $node, undef, "Node object returned when required parameters provided" );

is( $node->is_new, 1, "New node is new" );
is( $node->_dirty, 0, "New node with no config is not dirty" );
cmp_deeply( [$node->save], [0, undef], "Node that is not dirty is not saved" );
is( $node->is_new, 1, "New node still is new" );

$node->configuration( {uuid => $node->uuid} );
is( $node->_dirty,   1, "New node some config set is dirty" );
cmp_deeply( [$node->validate], [-1,ignore], "New node with no name is not valid" );
cmp_deeply( [$node->save], [-1, ignore], "Node without name is not valid, so not saved" );
is( $node->_dirty, 1, "New node some config set that didn't save is still dirty" );
is( $node->is_new, 1, "New node is still new" );

$node->configuration( {name => $node_name, cluster_id => 1} );
is( $node->_dirty,   1, "New node some config set is dirty" );
cmp_deeply( [$node->validate], [1,undef], "New node with name is valid" );
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

# test overrides
cmp_deeply( $node->overrides, {}, "node with no overrides should return empty hashref" );
$node->overrides( {thing => "overridden"} );
is( $node->_dirty, 1, "node some overrides set is dirty" );
cmp_deeply( [$node->save], [2, undef], "Node is valid with overrides, so saved with update" );
is( $node->_dirty, 0, "node updated overrides isn't dirty" );

# test getting inventory
# one that doesn't exist should return nothing
my $concept   = 'sometype';
my $data      = {abc => "123"};
my $path_keys = ['abc'];
cmp_deeply( [$node->inventory()], [undef, ignore()], "No inventory should return undef" );
my ( $inventory, $error )
	= $node->inventory( concept => $concept, data => $data, path_keys => $path_keys, create => 1 );
isnt( $inventory, undef, "Inventory is created when it does not exist" ) or diag("Error creating inventory:$error");

# create a second inventory entry
my $inventory2_data = $inventory->data();
$inventory2_data->{abc} = "3445";
my ( $inventory2, $error2 )
	= $node->inventory( concept => $concept . "_new", data => $inventory2_data, path_keys => $path_keys, create => 1 );

# save, which should insert
my ( $op, $error ) = $inventory->save();
is( $op, 1, "Inventory saves with insert op and no error" ) or diag("Save returned error: $error");
isnt( $inventory->id, undef, "Inventory gets an id after it's saved" );
( $op, $error ) = $inventory2->save();
is( $op, 1, "Inventory2 saves with insert op and no error" ) or diag("Save returned error: $error, path:".join(",", @{ $inventory2->path()} ));

my $path = $node->inventory_path( concept => $concept, data => $data, path_keys => $path_keys );
# print "path:".Dumper($path);
# now look for the thing we saved using the proper path
# path_keys not required for either of these because create=>0, if it's possible we were going to create it
# then it might be required
( $inventory, $error ) = $node->inventory( concept => 'sometype', path => $path, create => 0 );
isnt( $inventory, undef, "Search for inventory using path found entry just added" )
	or diag("Inventory search returned error:$error");
isnt( $inventory->id, undef, "Inventory gets an id after it's saved" );

# and looking for the same thing by id should also return an inventory (although it won't have path_keys saved)
( $inventory, $error ) = $node->inventory( concept => 'sometype', _id => $inventory->id, create => 0 );
isnt( $inventory, undef, "Search for inventory using _id found entry just added" )
	or diag("Inventory search returned error:$error");

# get_inventory_ids
my $ids = $node->get_inventory_ids();
is( @$ids, 2, "getting all inventory ids should be 2" );
$ids = $node->get_inventory_ids( concept => $concept );
is( @$ids, 1, "getting by concept should be 1" );
is( $ids->[0], $inventory->id, "id of inventory should match what we have" );

cleanup_db();
done_testing();
