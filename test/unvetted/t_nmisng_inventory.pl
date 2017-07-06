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

# Test NMISNG Inventory base functions, but doing it on DefaultInventory as the path
# functions need to have a bit of definition before they are useful
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
use NMISNG::Inventory::DefaultInventory;

use Compat::UUID;

use func qw(loadConfTable);
my $C = NMISNG::Util::loadConfTable();

# modify dbname to be time specific for this test
$C->{db_name} = "t_nmisng-" . time;

# log to stderr
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

# make a node first
my $node_name = "node1";
my $nodeuuid = Compat::UUID::getUUID();
my $cluster_id = 1;

# this will make a dodgy node object, unsaveable until populated further...
my $newnode = $nmisng->node(create => 1, uuid => $nodeuuid);
isnt($newnode, undef, "node creation works");
my ($success, $msg) = $newnode->save;
cmp_ok($success, "<", 0, "incomplete node is reported unsaveable");
like($msg, qr/incomplete/, "error message for unsaveable is useful");

# ...which is done here
$newnode->configuration({name => $node_name, cluster_id => $cluster_id });
($success, $msg) = $newnode->save;
cmp_ok($success, ">", 0, "node saving works") or diag("save error was: $msg");

# new inventory - invalid
my $inventory = NMISNG::Inventory::DefaultInventory->new();
is( $inventory, undef, "No Inventory Created" );

my $concept = "testconcept";
my $data = { key1 => 'value1', key2 => 'value2'};

# new, minimal
$inventory = NMISNG::Inventory::DefaultInventory->new(
	nmisng    => $nmisng,
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,
	concept   => $concept,
	data      => $data,
	path_keys => ['key1']
);
isnt( $inventory, undef, "Inventory Created if minimal paramters provided" );

# make_path_from_keys
my $path = NMISNG::Inventory::make_path_from_keys(
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,
	concept   => $concept,

	data      => $data,
	path_keys => ['key1'],
	partial   => 0
		);

my @expect_path = ( $cluster_id, $nodeuuid, $concept, $data->{key1});

cmp_deeply( $path, \@expect_path, "make_path_from_keys adds expected keys along with cluster/node" );
my $error = NMISNG::Inventory::make_path_from_keys(
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,
	concept   => $concept,
	data      => $data,
	path_keys => ['bad_key'],
	partial   => 0
);
isnt( ref($error), "ARRAY",
			'make_path_from_keys returns error when keys are not found and partial not set' );
like($error, qr/is missing/, 'make_path_from_keys returns useful error message');

my $partial = NMISNG::Inventory::make_path_from_keys(
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,
	concept   => $concept,
	data      => $data,
	path_keys => ['bad_key', 'key2'],
	partial   => 1
);
my @partial_path = ( $cluster_id, $nodeuuid, $concept, undef, $data->{key2});
cmp_deeply( $partial, \@partial_path, 'make_path_from_keys returns partial path when set' );

# data
cmp_deeply( $inventory->data(), $data, "Data is what we gave it" );
my $data_copy = $inventory->data();
$data_copy->{key1} = "throwaway";
cmp_deeply( $inventory->data(), $data,
	"Changing value on requested data does not change object because we get a copy" );
$inventory->data($data_copy);
cmp_deeply( $inventory->data(), $data_copy, "Setting new data value works and returns the new data" );

# set data back so path is again correct
$inventory->data($data);

# path
cmp_deeply( $inventory->path, $path, "path and make_path should return the same info before save" )
		or diag(Dumper($inventory->path, $path));

my $first_data = { key1 => 'value3', key2 => 'value4'};
my $first_inventory = NMISNG::Inventory::DefaultInventory->new(
	nmisng    => $nmisng,
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,

	concept   => $concept,
	data      => $first_data,
	path_keys => ['key1']
);
cmp_deeply( [$first_inventory->save], [1,undef], "Save first entry so update has to find correct record");
cmp_deeply( $first_inventory->data, $first_data, "First record has correct data");

isnt($first_inventory->description,undef,"inventory automatically gets a description");
my $newdesc = $first_inventory->description("changed!");
is($newdesc, $first_inventory->{_description}, "description can be changed");

# save/insert/is_new
is( $inventory->is_new, 1, "unsaved inventory should be new" );
my ( $op, $error ) = $inventory->save();
is( $op, 1, "Valid inventory is saved via insert" ) or diag("Save returned error: $error");
is( $inventory->is_new, 0, "saved inventory should not be new" );
isnt( $inventory->id, undef, "Inventory gets an id after it's saved");

# path again
# after save path should not change without a parameter telling it to change
$inventory->data($data_copy);    #change data path is based on
cmp_deeply( $inventory->path, $path, "path after save should not be recalculated unless told to" );
$path->[-1] = "throwaway";
cmp_deeply( $inventory->path( recalculate => 1 ), $path, "forcing path recalculate should change the path" );

# change data again also
$data_copy = $inventory->data();
$data_copy->{extrathing} = "extravalue";
$inventory->data( $data_copy );

# verify storage accessor: get, set, reset
my $wantedstorage = { "subconcept1" => "rrd1", "subconcept42" => "rrd42" };
is($inventory->storage([qw(something bad)]), undef, "storage accessor doesn't accept array");

my $raw = $inventory->{_storage};
my $curval = $inventory->storage();
cmp_deeply($curval, $raw, "storage accessor returns actual content");
$curval = $inventory->storage($wantedstorage);
isnt($curval, undef, "storage accessor accepts hash");
cmp_deeply($curval, $wantedstorage, "storage accessor returns desired value");
cmp_deeply($curval, $inventory->{_storage}, "storage accessor did set desired value");
cmp_deeply($inventory->subconcepts, bag(keys %$wantedstorage), "storage accessor updates subconcepts");
$curval = $inventory->storage(undef);
cmp_deeply($curval, {}, "storage accessor can undef storage");
cmp_deeply($inventory->subconcepts,[],"undef storage empties subconcepts");

$curval = $inventory->storage($wantedstorage);

# save/update
( $op, $error ) = $inventory->save();
is( $op, 2, "Valid non-new inventory should be updated when saved" ) or diag("Save returned error: $error");
isnt( $inventory->id, undef, "Inventory gets an id after it's saved");

# check the db contents, too
my $db = $nmisng->get_db;
my $invcoll = $nmisng->inventory_collection;
my $cursor = $invcoll->find({_id => $inventory->id});
is($cursor->count, 1, "db has saved inventory record");
my $dbrec = $cursor->next;
cmp_deeply($dbrec, { _id => ignore(),
										 lastupdate => ignore(),
										 subconcepts => bag(@{$inventory->subconcepts}),
										 (map { $_ => $inventory->$_ } (qw(cluster_id node_uuid concept data storage path path_keys enabled historic description))) },
					 "db record matches original inventory") or diag(Dumper($dbrec));

# force reloading itself to make sure data was updated
$inventory->reload();
cmp_deeply( $inventory->data, $data_copy, "data was updated" );


# set, reset, check historic, enabled accessors
my $raw = $inventory->{_enabled};
my $curval = $inventory->enabled();
is($curval, $raw, "enabled accessor returns present value");
$curval = $inventory->enabled(1);
is($curval, $inventory->{_enabled}, "enabled accessor can update value");
$curval = $inventory->enabled(undef);
is($curval, $inventory->{_enabled}, "enabled accessor can undef value");

$raw = $inventory->{_historic};
$curval = $inventory->historic();
is($curval, $raw, "historic accessor returns present value");
$curval = $inventory->historic(42);
is($curval, $inventory->{_historic}, "historic accessor can update value");
$curval = $inventory->historic(undef);
is($curval, $inventory->{_historic}, "historic accessor can undef value");

#lastly change data on first entry and make sure it's updated
$first_data->{extrathing1} = "extravalue1";
$first_inventory->data($first_data);
$first_inventory->save();
cmp_deeply( $first_inventory->data, $first_data, "first inventory data was updated" );

($op,$error) = $first_inventory->delete();
is( $op, 1, "Deleting inventory was a success") or diag("Delete returned error:$error");
is( $first_inventory->is_deleted, 1, "first_inventory knows it has been deleted");

# timed data: nothing there?
my $res = $inventory->get_newest_timed_data;
cmp_deeply($res, { success => 1 }, "get newest returns ok-but-empty for concept without timed data");

# create another inventory object, save it and add point-in-time data
(my $tictac, $error) = $newnode->inventory(create => 1, concept => "tictac",
																					 path_keys => ['keyedby'],
																					 data => { "keyedby" => "fourty2" ,
																										 "something" => "else" });
is($error, undef, "creation of tictac inventory worked");
($op, $error) = $tictac->save;
is($op, 1, "tictac concept was saved") or diag("error message was: $error");
cmp_deeply($tictac->storage,undef, "inventory w/o storage is properly represented");
cmp_deeply($tictac->subconcepts, [], "inventory w/o storage has empty subconcepts list");

my $first =  { "itisnow" => "first entry" };
$error = $tictac->add_timed_data(data => $first);
is($error, undef, "adding timed data to tictac worked");

my $now = Time::HiRes::time;
my $second =  { "itisnow" => "second entry" };
$tictac->add_timed_data(data => $second, time => $now);
is($error, undef, "adding timed data to tictac worked again");

$res = $tictac->get_newest_timed_data();
isnt($res,undef,"get newest timed data works");
cmp_deeply($res, { success => 1, time => $now,  data => $second }, "get newest returns the expected data");

# add a third for this concept
my $third = { "itisnow" => "third" };
$tictac->add_timed_data(data => $third, time => $now + 0.1);

my $alltics = $nmisng->get_timed_data_model(cluster_id => $cluster_id, node_uuid => $newnode->uuid, concept => "tictac");
my $allticsdata = $alltics->data;
# note: qr on time doesn't work, competing bag match elems then match nothing at all
cmp_deeply($allticsdata, bag({_id => ignore(), time => ignore(), data => $first, inventory_id => $tictac->id, },
														 {_id => ignore(), time => ignore(), data => $second, inventory_id => $tictac->id, },
														 {_id => ignore(), time => ignore(), data => $third , inventory_id => $tictac->id,}
),
					 "get_timed_data_model(concept) returns all timed data entries") or diag(Dumper($allticsdata));

# give me the  two most recent ones
my $duo = $nmisng->get_timed_data_model(cluster_id => $cluster_id, node_uuid => $newnode->uuid,
																				concept => "tictac", limit => 2 , sort => { time => -1 });
cmp_deeply($duo->data, [ { _id => ignore(), 'time' => re(qr/^\d+(\.\d+)?$/), inventory_id => $tictac->id, data => $third },
												{ _id => ignore(), 'time' => re(qr/^\d+(\.\d+)?$/), inventory_id => $tictac->id, data => $second }, ],
					 "get_timed_data_model(cluster+node+concept,limit,sort) returns desired timed data") or diag(Dumper($duo->data));

# and another concept
(my $cuckoo, $error) = $newnode->inventory(create => 1, concept => "cuckoo",
																					 path_keys => ['keyedby'],
																					 data => { "keyedby" => "fourty2" ,
																										 "not" => "tictac" });
$cuckoo->save;
$cuckoo->add_timed_data(data => { "dingdong" => "it works" }, time => Time::HiRes::time);
$cuckoo->add_timed_data(data => { "seconds" => "please" }, time => Time::HiRes::time + 0.1);
$cuckoo->add_timed_data(data => { "full" => "done" }, time => Time::HiRes::time + 0.1);


# now ask for "gimme the latest timed data for this node", i.e. across all concepts
my $latestonly = $nmisng->get_timed_data_model(cluster_id => $cluster_id, node_uuid => $newnode->uuid,
																							 sort => { time => -1 }, limit => 1);
cmp_deeply($latestonly->data, bag({inventory_id => $cuckoo->id, data => { full=>"done" }, time => ignore(), _id => ignore() },
																	{inventory_id => $tictac->id, data => $third, time => ignore(), _id => ignore() },),
					 "get_timed_data_model(cluster+node,limit=1,sort=-time) returns the latest timed data for this node") or diag(Dumper($latestonly->data));


# fixme check database contents for these two, cached db etc

if (-t \*STDIN)
{
	print "hit enter to stop the test: ";
	my $x = <STDIN>;
}
cleanup_db();
done_testing();
