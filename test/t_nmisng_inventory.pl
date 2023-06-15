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
my $nodeuuid = NMISNG::Util::getUUID();
my $cluster_id = NMISNG::Util::getUUID();

# this will make a dodgy node object, unsaveable until populated further...
my $newnode = $nmisng->node(create => 1, uuid => $nodeuuid);
isnt($newnode, undef, "node creation works");
my ($success, $msg) = $newnode->save;
cmp_ok($success, "<", 0, "incomplete node is reported unsaveable");
like($msg, qr/incomplete/, "error message for unsaveable is useful");

# ...which is done here
$newnode->name($node_name);
$newnode->cluster_id($cluster_id);
$newnode->configuration({  host => "1.2.3.4",
													 group => "somegroup",
													 netType => "default",
													 roleType => "default",
													 threshold => '1',
												});
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
( my $op, $error ) = $first_inventory->save;
cmp_deeply( $op, 1, "Save first entry so update has to find correct record") or diag("Save returned error: $error");
cmp_deeply( $first_inventory->data, $first_data, "First record has correct data");

isnt($first_inventory->description,undef,"inventory automatically gets a description");
my $newdesc = $first_inventory->description("changed!");
is($newdesc, $first_inventory->{_description}, "description can be changed");

# save/insert/is_new
is( $inventory->is_new, 1, "unsaved inventory should be new" );
( $op, $error ) = $inventory->save();
is( $op, 1, "Valid inventory is saved via insert" ) or diag("Save returned error: $error");
is( $inventory->is_new, 0, "saved inventory should not be new" );
isnt( $inventory->id, undef, "Inventory gets an id after it's saved");

# breaking the _id and saving (simulating race condition where this thing wasn't found
# by two things running at the same time and both try and insert them
# eg - test update in insert via upsert
$inventory->{_id} = undef;
is( $inventory->is_new, 1, "meddled with inventory thinks it's new again" );
( $op, $error ) = $inventory->save();
is( $op, 2, "inventory is saved via update even though new" ) or diag("Save returned error: $error");
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

# add a new subcocept with rrd and filename
$wantedstorage->{new_subconcept} = { rrd => 'dbfilename' };
$inventory->set_subconcept_type_storage( subconcept => 'new_subconcept', type => 'rrd', data => 'dbfilename' );

# make sure it makes it into storage and subconcept lists
$curval = $inventory->storage($wantedstorage);
cmp_deeply($curval, $wantedstorage, "set_subconcept_type_storage updates storage");
cmp_deeply($inventory->subconcepts, bag(keys %$wantedstorage), "set_subconcept_type_storage updates subconcepts");

# make sure datasets setter/getter is working
# datasets track PIT keys, notthing else right now, use subconcepts for fun
my $datasets = { $concept => { key1 => 1 } };
$inventory->dataset_info( subconcept => $concept, datasets => $datasets->{$concept} );

$inventory->data_info( subconcept => $concept, enabled => 1, display_keys => ['keyedby'] );
cmp_deeply( $inventory->data_info( subconcept => $concept ), { enabled => 1, display_keys => ['keyedby'] }, "set/get dataset info works");

# save/update
( $op, $error ) = $inventory->save();
is( $op, 2, "Valid non-new inventory should be updated when saved" ) or diag("Save returned error: $error");
isnt( $inventory->id, undef, "Inventory gets an id after it's saved");

# check the db contents, too
my $db = $nmisng->get_db;
my $invcoll = $nmisng->inventory_collection;
my $q = {_id => $inventory->id};
is($invcoll->count($q), 1, "db has saved inventory record"); # no more cursor->count
my $cursor = $invcoll->find($q);
my $dbrec = $cursor->next;

cmp_deeply($dbrec, { _id => ignore(),
										 lastupdate => ignore(),
										 expire_at => ignore(),
										 subconcepts => bag(@{$inventory->subconcepts}),
										 dataset_info =>  [ { subconcept => $concept, datasets => [ 'key1' ] } ], #modified by inventory to be array
										 data_info => [ { subconcept => $concept, enabled => 1, display_keys => ['keyedby']} ],
										 (map { $_ => $inventory->$_ } (qw(cluster_id node_uuid concept data storage path path_keys enabled historic description))) },
					 "db record matches original inventory") or diag(Dumper($dbrec));

# force reloading itself to make sure data was updated
$inventory->reload();
cmp_deeply( $inventory->data, $data_copy, "data was updated" );

# make sure instantiated object has same contents as original - static case first
my $modeldata = NMISNG::ModelData->new( data => [$dbrec], nmisng => $nmisng,
																				class_name => "NMISNG::Inventory::DefaultInventory" );
($error, my $instantiated) = $modeldata->object(0);
is($error,undef,"modeldata object accessor instantiated object ok");

my $inventory_invariant = Clone::clone($inventory);
$inventory_invariant->{_subconcepts} = bag(@{$inventory->{_subconcepts}});
$inventory_invariant->{_nmisng} = ignore();
$inventory_invariant->{_dirty} = ignore();

cmp_deeply( $instantiated, $inventory_invariant, "whole structure of instantiated object matches original");

cmp_deeply( $instantiated->data, $inventory->data, "instantiated inventory has correct data" );
cmp_deeply( $instantiated->subconcepts, bag(@{$inventory->subconcepts}), "instantiated inventory has correct subconcepts" );
cmp_deeply( $instantiated->dataset_info, $inventory->dataset_info, "instantiated inventory has correct datasets" );
cmp_deeply( $instantiated->data_info(subconcept => $concept), $inventory->data_info(subconcept => $concept), "instantiated inventory has correct data_info" );

# instantiate with callback
my $moredyn = NMISNG::ModelData->new( data => [$dbrec], nmisng => $nmisng,
																			class_name => { "concept" => \&NMISNG::Inventory::get_inventory_class } );
($error, my $dyninst) = $moredyn->object(0);
is($error,undef, "modeldata object with dynamic class name ok");
is(ref($dyninst),"NMISNG::Inventory::DefaultInventory","result has correct class");
cmp_deeply($dyninst,$instantiated,"dynamically instantiated matches original object");


# set, reset, check historic, enabled accessors
 $raw = $inventory->{_enabled};
$curval = $inventory->enabled();
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
my $first_derived = { 'itwasthen' => 'first entry' };
$error = $tictac->add_timed_data(data => $first, derived_data => $first_derived, subconcept => $concept );
is($error, undef, "adding timed data to tictac worked") or diag($error);
my $first_datasets = $tictac->dataset_info( subconcept => $concept );
cmp_deeply( $first_datasets, { 'itisnow' => 1 }, 'adding time data automatically adds dataset info for subconcept' );

my $now = Time::HiRes::time;
my $second =  { "itisnow2" => "second entry" };
my $second_derived = { 'itwasthen' => 'second entry' };
$error = $tictac->add_timed_data(data => $second, time => $now, derived_data => $second_derived, datasets => { $concept => { 'itisnow2' => 1 }}, subconcept => $concept );
is($error, undef, "adding timed data to tictac worked again") or diag($error);

my $second_datasets = $tictac->dataset_info( subconcept => $concept );
cmp_deeply( $second_datasets, { 'itisnow' => 1, 'itisnow2' => 1 }, 'adding time data automatically adds dataset info for subconcept' );

$res = $tictac->get_newest_timed_data();
isnt($res,undef,"get newest timed data works");
cmp_deeply($res, { success => 1, time => $now,  data => { $concept => $second }, derived_data => { $concept => $second_derived } }, "get newest returns the expected data");

# add a third for this concept
my $third = { "itisnow" => "third", "itisnow3" => "forth" };
my $third_derived = { 'itwasthen' => 'third entry' };
$error = $tictac->add_timed_data(data => $third, time => $now + 0.1, derived_data => $third_derived, subconcept => $concept."3");
is($error, undef, "adding timed data to tictac worked again") or diag($error);

my $third_datasets = $tictac->dataset_info( subconcept => $concept."3" );
cmp_deeply( $third_datasets, { 'itisnow' => 1, 'itisnow3' => 1 }, 'adding time data automatically adds dataset info for subconcept' );


my $alltics = $nmisng->get_timed_data_model(cluster_id => $cluster_id, node_uuid => $newnode->uuid, concept => "tictac");
is($alltics->error, undef, "timed data model has reported success");
my $allticsdata = $alltics->data;
# note: qr on time doesn't work, competing bag match elems then match nothing at all
cmp_deeply($allticsdata, bag({_id => ignore(), expire_at => ignore(), time => ignore(),
															inventory_id => ignore(), cluster_id => ignore(),
															subconcepts => [{ subconcept => $concept, data => $first, derived_data => $first_derived }], inventory_id => $tictac->id },
														 {_id => ignore(), expire_at => ignore(), time => ignore(),
															inventory_id => ignore(), cluster_id => ignore(),
															subconcepts => [{ subconcept => $concept,     data => $second, derived_data => $second_derived}], inventory_id => $tictac->id },
														 {_id => ignore(), expire_at => ignore(), time => ignore(),
															inventory_id => ignore(), cluster_id => ignore(),
															subconcepts => [{ subconcept => $concept."3", data => $third, derived_data => $third_derived }], inventory_id => $tictac->id }
),
					 "get_timed_data_model(concept) returns all timed data entries") or diag(Dumper($allticsdata));

# give me the  two most recent ones
my $duo = $nmisng->get_timed_data_model(cluster_id => $cluster_id, node_uuid => $newnode->uuid,
																				concept => "tictac", limit => 2 , sort => { time => -1 });
is($duo->error, undef, "timed data model has reported success");
cmp_deeply($duo->data, [ { _id => ignore(), 'time' => re(qr/^\d+(\.\d+)?$/), inventory_id => $tictac->id,
													 cluster_id => $tictac->cluster_id,
													 subconcepts => [{ subconcept => $concept."3", data => $third, derived_data => $third_derived }], expire_at => ignore },
												 { _id => ignore(), 'time' => re(qr/^\d+(\.\d+)?$/), inventory_id => $tictac->id,
													 cluster_id => $tictac->cluster_id,
													 subconcepts => [{ subconcept => $concept, data => $second, derived_data => $second_derived }], expire_at => ignore }],
					 "get_timed_data_model(cluster+node+concept,limit,sort) returns desired timed data") or diag(Dumper($duo->data));

# and another concept
(my $cuckoo, $error) = $newnode->inventory(create => 1, concept => "cuckoo",
																					 path_keys => ['keyedby'],
																					 data => { "keyedby" => "fourty2" ,
																										 "not" => "tictac" });
$cuckoo->save;
$error = $cuckoo->add_timed_data(data => { "dingdong" => "it works" }, derived_data => {}, time => Time::HiRes::time, subconcept => $concept);
is($error, undef, "adding timed data to tictac worked again") or diag($error);
$error = $cuckoo->add_timed_data(data => { "seconds" => "please" }, derived_data => {}, time => Time::HiRes::time + 0.1, subconcept => $concept);
is($error, undef, "adding timed data to tictac worked again") or diag($error);
$error = $cuckoo->add_timed_data(data => { "full" => "done" }, derived_data => {}, time => Time::HiRes::time + 0.1, subconcept => $concept);
is($error, undef, "adding timed data to tictac worked again") or diag($error);

# now ask for "gimme the latest timed data for this node", i.e. across all concepts
my $latestonly = $nmisng->get_timed_data_model(cluster_id => $cluster_id, node_uuid => $newnode->uuid,
																							 sort => { time => -1 }, limit => 1);
is($latestonly->error, undef, "timed data model has reported success");

cmp_deeply($latestonly->data, bag({inventory_id => $cuckoo->id, subconcepts => [{ subconcept => $concept, data => {full=>"done"}, derived_data => ignore()}], time => ignore(), _id => ignore(), expire_at => ignore, cluster_id => ignore,},
																	{inventory_id => $tictac->id, subconcepts => [{ subconcept => $concept."3", data => $third, derived_data => ignore() }], time => ignore(), _id => ignore(), expire_at => ignore, cluster_id => ignore  },),
					 "get_timed_data_model(cluster+node,limit=1,sort=-time) returns the latest timed data for this node") or diag(Dumper($latestonly->data));


# check the save-just-what-is-needed logic
my $one = NMISNG::Inventory::DefaultInventory->new(
	nmisng    => $nmisng,
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,
	concept   => "minisave",
	data      => { "one" => 1, "two" => 2},
	enabled => 1, historic => 0,
	path_keys => []
		);
($op,my $err) = $one->save;
is($op, 1, "minisave savable") or diag("error was: $err");
my @dirty= $one->_whatisdirty;
cmp_deeply(\@dirty, [], "freshly saved inv is not dirty");

$one->reload;
@dirty= $one->_whatisdirty;
cmp_deeply(\@dirty, [], "freshly reloaded inv is not dirty");

for (
	[ "description" => "new desc" ],
	[ "storage" => { "onething" => { "rrd" => "one.rrd" },
									 "otherthing" => { "rrd" => "other.rrd" }}],
	[ "path_keys" => [ "two", "one" ]],
	[ "data" => { %{$one->data}, three => "4567" }],
	[ "data" => { one => 1, two => 2, fourty42 => 'nonex' }],
	[ "enabled" => 0 ],
	[ "historic" => 1 ],
			)
{
	my ($what,$value) = @{$_};

	my $whatisit = $one->$what($value);
	cmp_deeply($whatisit, $value, "setting $what reported back correct data");
	($op, $error) = $one->save;
	is($op, 2, "new $what meant save needed") or diag("error was: $error");

	my ($expire_old,$expire_new);
	if (!$one->historic)					# expire_at updates happen only if not historic
	{
		my $cursor = NMISNG::DB::find(collection => $nmisng->inventory_collection,
																	query => { _id => $one->id },
																	fields_hash => { expire_at => 1 });
		$expire_old = $cursor? $cursor->next->{expire_at} : undef;
		isnt($expire_old, undef, "expire_at is set for nonhistoric");

		sleep(0.1);									# make sure a bit of time elapses
	}

	$one->$what($one->$what);
	($op, $error) = $one->save;
	is($op, 3, "unchanged $what meant no save") or diag("error was: $error");

	if (!$one->historic)
	{
		my $cursor = NMISNG::DB::find(collection => $nmisng->inventory_collection,
																	query => { _id => $one->id },
																	fields_hash => { expire_at => 1 });
		$expire_new = $cursor? $cursor->next->{expire_at} : undef;
		isnt($expire_new, undef, "expire_at is set for nonhistoric");

		if (ref($expire_new)  and ref($expire_old))
		{
			cmp_ok($expire_new->compare($expire_old),">",0,"no save still updates expire_at")
					or diag("old: ".$expire_old->strftime("%s%6f")." new: ".$expire_new->strftime("%s%6f"));
		}
	}
	$one->reload;
}

# these don't parrot back and want arg lists
for ([ "data_info" => [ "subconcept" => "subbie", 'enabled' => 1 ]],
		 [ "data_info" => [ "subconcept" => "another", 'enabled' => 0, display_keys=>["huhu"] ]],
		 # does both storage and subconcept
		 [ 'set_subconcept_type_storage' => [ subconcept => "numbernine",
																					data => "foobarbaz.rrd" ]],
		 [ "dataset_info" => [ "subconcept" => "subway",
													 "datasets" => {
														 "subway" => { "sandwich" => "meh" }}]]
		)
{
	my ($what,$arglist) = @$_;

	$one->$what(@$arglist);
	($op, $error) = $one->save;
	is($op, 2, "new $what meant save needed") or diag("error was: $error");

	$one->$what(@$arglist);
	($op, $error) = $one->save;
	is($op, 3, "unchanged $what meant no save") or diag("error was: $error");

	$one->reload;
}

# and now for data, which should actually *just* change the toplevel keys we're changing
# make two objects, change them async, compare db contents
$one = NMISNG::Inventory::DefaultInventory->new(
	nmisng    => $nmisng,
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,
	concept   => "selectivesave",
	data      => { one => 2, three => 4, five => 6 },
	enabled => 1, historic => 0,
	path_keys => []
		);
$one->save;

my $two = NMISNG::Inventory::DefaultInventory->new(
	nmisng    => $nmisng,
	cluster_id => $cluster_id,
	node_uuid => $nodeuuid,
	concept   => "selectivesave",
	data      => { one => 2, three => 4, five => 6 },
	enabled => 1, historic => 0,
	path_keys => [],
	id => $one->id,
		);
$two->reload;

# setting order not relevant...
my %deltaone = (one => 1, two => 2, eight => "zoom"); # one changed, two added, three and five removed, eight added
my %deltatwo = (one => 2, three => 4, nine => "nintynine");  # nine added, five removed; one, three unchanged
# ...and the saving order isn't either, in the particular case only;
# as leavinng three unchanged vs. deleting three doesn't interfere - the change, deletion, wins.
my %expected = ( one => 1, two => 2, eight => "zoom", nine => "nintynine" );

$one->data(\%deltaone);
cmp_deeply($one->data, \%deltaone, "setting one works, data is correct");
$two->data( \%deltatwo);
cmp_deeply($two->data, \%deltatwo, "setting two works, data is correct");

$two->save;
$one->save;
cmp_deeply($one->data, \%deltaone, "data in one is as expected post-save"); # i.e. they're still split-horizon
cmp_deeply($two->data, \%deltatwo, "data in two is as expected post-save");

$one->reload; # now reload from db
$two->reload;
cmp_deeply($one->data,$two->data, "concurrent changes didn't clobber data");
cmp_deeply($one->data, \%expected, "concurrent changes caused expected data");

# now a conflicting change, LAST save wins as it overwrites the one conflicting property
# one changed, nine removed, first and second added
%deltaone = ( one => "yes", two => 2, eight => "zoom", "first" => "wins" );
%deltatwo = ( one => "no", two => 2, eight => "zoom", nine => "nintynine" , "second" => "wins");
%expected = ( one => "no", two => 2, eight => "zoom", "first" => "wins" , "second" => "wins");
$one->data(\%deltaone); $two->data(\%deltatwo); # order irrelevant
$one->save; $two->save;					# order critical; second save overwrites
$one->reload; $two->reload;
cmp_deeply($two->data, \%expected, "conflicting data change, last save wins");
cmp_deeply($one->data, \%expected, "conflicting data change, last save wins, first agrees");

# now a mix of data_live and normal, non-conflicting
%deltatwo = ( one => "no", two => 2, eight => "zoom", "first" => "wins" , "second" => "loses");
%expected = ( one => "no", two => undef, eight => "zoom",
							"first" => "wins" , "second" => "loses",
							"winner" => "live");
$two->data(\%deltatwo);

my $liveone = $one->data_live;
$liveone->{two} = undef;
$liveone->{winner} = "live";

$one->save; $two->save;
# verify that either save doesn't interfere with the data_live one
cmp_deeply($one->data, { one => "no", two => undef, eight => "zoom",
												 "first" => "wins" , "second" => "wins", "winner" => "live"},
					 "saved data_live doesn't interfere with saved non-live before reload"); ;
$one->reload; $two->reload;

cmp_deeply($two->data, \%expected, "non-live coexists with data_live");
cmp_deeply($one->data, \%expected, "data_live coexists with non-live");

# now two independent data_live accesses
my $livetwo= $two->data_live;
$livetwo->{three} = "new";
$livetwo->{winner} = "interference";

$liveone->{four} = "alsonew";
$liveone->{winner} = "save order counts";

%expected = ( one => "no", two => undef, eight => "zoom",
							"first" => "wins" , "second" => "loses",
							"winner" => "interference",
							"three" => "new",
							"four" => "alsonew" );

$one->save; $two->save;
$one->reload; $two->reload;

cmp_deeply($one->data, \%expected, "first data_live has correct data");
cmp_deeply($two->data, \%expected, "second data_live also has correct data");

# now verify that data() works with data_live and a new argument, ie. REPLACING all data
%expected = ( foo => "bar", "really" => "nice"  );
my $newdata = \%expected;
$one->data($newdata);
$one->save; $one->reload;

cmp_deeply($one->data, \%expected, "data(new info) works in data_live mode and replaces all of data");


# and ALSO verify that data() works with data_live and the existing argument,
# just as the pattern 'use data() to get current, mod it somewhat, use data() to update' recommends
my $doesntsmelllive = $one->data; # but is live!
$doesntsmelllive->{x} = "y";
$doesntsmelllive->{foo} = "bar and diddly";

%expected = ( x => "y", foo => "bar and diddly", really => "nice" );
$one->data($doesntsmelllive);
$one->save; $one->reload;

cmp_deeply($one->data, \%expected, "data(existing live data) works in data_live mode and replaces all of data");


if (-t \*STDIN)
{
	print "hit enter to stop the test: ";
	my $x = <STDIN>;
}
cleanup_db();
done_testing();
