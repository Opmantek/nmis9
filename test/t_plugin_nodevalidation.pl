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

# Test NMISNG Node plugin NodeValidation features
#  uses nmisng object for convenience
#  creates (and removes) a mongo database called t_nmisg-<timestamp>
#  in whatever mongodb is configured in ../conf/

use strict;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Copy;
use Test::More;
use Data::Dumper;
use Test::Deep;

use NMISNG;
use NMISNG::Node;
use NMISNG::Log;
use NMISNG::Util;

my $C = NMISNG::Util::loadConfTable();

my $node_name1 = "node1";
my $node_name2 = "node2";
my $node_name3 = "node3";
my $node_name4 = "node4";
my $node_name5 = "node5";
my $node_name6 = "node6";
my $node_name7 = "node7";

# modify dbname to be time specific for this test
$C->{db_name} = "t_nmisng-" . time;

# log to stdout
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => 1 ));

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);
die "NMISNG object required" if ( !$nmisng );


# make sure validation plugin is in the right spot
my $bin = "$FindBin::Bin";
my $original_plugin = $bin."/../conf-default/validation_plugins/NodeValidation.pm";
my $enabled_plugin = $bin."/../conf-default/plugins/NodeValidation.pm";
BAIL_OUT("plugin already in use: $enabled_plugin, do not want to clobber it") if( -r $enabled_plugin);
my $other_enabled_plugin = $bin."/../conf/plugins/NodeValidation.pm";
BAIL_OUT("plugin already in use: $other_enabled_plugin, do not want to clobber it") if( -r $other_enabled_plugin);
copy($original_plugin, $enabled_plugin);


sub cleanup_db
{
	$nmisng->get_db()->drop();
	unlink $enabled_plugin;
}

is( -r $enabled_plugin, 1, "plugin is found and readable" );
# this will load the plugins, check to make sure the plugin runs before testing
my @plugins = $nmisng->plugins();
my $found_plugin = List::Util::any {/NodeValidation/} @plugins;
BAIL_OUT("plugin needs to successfully load") if( !$found_plugin);

my $node1 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
isnt( $node1, undef, "Node object returned when required parameters provided" );
is( $node1->is_new, 1, "New node is new" );
is( $node1->_dirty, 0, "New node with no config is not dirty" );
$node1->name($node_name1);
$node1->cluster_id(1);
$node1->configuration( {host => "1.2.3.4", host_backup => "10.2.3.4",
											 group => "somegroup",
											 netType => "default",
											 roleType => "default",
											threshold => 1, } );
# create node with no ci, should not be valid
# returns -number and error says can't be empty
cmp_deeply( [$node1->validate], [re(qr/^-\d/),re(qr/cannot be empty/)], "New node with no ci is not" );

# add ci value, should be valid and save
set_node_configuration_attrs( node => $node1, attrs => { ci => 'abc123'});
is( $node1->_dirty,1, "setting just ci means node is dirty" );

# node with unique ci is valid
cmp_deeply( [$node1->validate], [re(qr/^\d/),ignore], "New node with unique ci is valid" );

# save node
cmp_deeply( [$node1->save], [1, undef], "Node is valid, save is successful" );

# test that update with same value works
# set device ci to same value and save again, x, should be valid and save
set_node_configuration_attrs( node => $node1, attrs => { ci => 'abc123'});
cmp_deeply( [$node1->save], [2, undef], "Updating node with same ci, save is successful" );

set_node_configuration_attrs( node => $node1, attrs => { ci => ''});
cmp_deeply( [$node1->save], [-1, re(qr/cannot be empty/)], "Updating node with empty ci should not be successful" );

# add second node, first with non-unique ci, with uqinue host and host_backup
my $node2 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node2->name($node_name2);
$node2->cluster_id(1);
$node2->configuration( {host => "1.2.3.5", host_backup => "10.2.3.5",
											 group => "somegroup",
											 netType => "default",
											 roleType => "default",
											threshold => 1,
											ci => 'abc123' } );

# duplicate ci is not valid
cmp_deeply( [$node2->validate], [re(qr/^-\d/),re(qr/Another node is already usin.*$node_name1/)], "New node with duplicate ci is not valid" );
cmp_deeply( [$node2->save], [re(qr/^-\d/), ignore], "Node with duplicate ci does not save" );

# change ci on second node, this should make the node valid
set_node_configuration_attrs( node => $node2, attrs => { ci => 'abc124'});
cmp_deeply( [$node2->save], [1, undef], "Saving node with different ci, save is successful" ) or diag;


# update ci on second node to duplicate, this should not be valid
set_node_configuration_attrs( node => $node2, attrs => { ci => 'abc123'});
cmp_deeply( [$node2->validate], [re(qr/^-\d/),re(qr/Another node is already usin.*$node_name1/)], "Update node with duplicate ci is not valid" );
cmp_deeply( [$node2->save], [-1, ignore], "Saving node with different ci, save not successful" );

# update ci on second node to be unique but different, this should be valid
set_node_configuration_attrs( node => $node2, attrs => { ci => 'abc125'});
cmp_deeply( [$node2->save], [2, undef], "Saving node with different ci, save is successful" );


# make sure host values must be unique
# we already have two unique values, changing one to be a duplicate should be all that is needed
# update ci on second node to duplicate
set_node_configuration_attrs( node => $node2, attrs => { host => '1.2.3.4'});
my $configuration = $node2->configuration();
cmp_deeply( [$node2->validate], [re(qr/^-\d/),re(qr/Another node is already usin.*$node_name1/)], "Update node with duplicate host $configuration->{host} is not valid" );
cmp_deeply( [$node2->save], [-1, ignore], "Saving node with different host, save not successful" );

# update the host to be unique but the host_backup to be duplicate of node1 host, this should not be valid
set_node_configuration_attrs( node => $node2, attrs => { host => '1.2.3.3', host_backup => '1.2.3.4'});
cmp_deeply( [$node2->validate], [re(qr/^-\d/),re(qr/Another node is already usin.*$node_name1/)], "Update node with duplicate host $configuration->{host_backup} is not valid" );
cmp_deeply( [$node2->save], [-1, ignore], "Saving node with duplicate host_backup should fail" );


# update the host to be unique but the host_backup to be duplicate of node1 host_backup, this should not be valid
set_node_configuration_attrs( node => $node2, attrs => { host => '1.2.3.3', host_backup => '10.2.3.4'});
cmp_deeply( [$node2->validate], [re(qr/^-\d/),re(qr/Another node is already usin.*$node_name1/)], "Update node with duplicate host $configuration->{host_backup} is not valid" );
cmp_deeply( [$node2->save], [-1, ignore], "Saving node with duplicate host_backup should fail" );


# update the host and host_backup to be unique, this should be valid
set_node_configuration_attrs( node => $node2, attrs => { host => '1.2.3.3', host_backup => '10.2.3.3'});
cmp_deeply( [$node2->save], [2, undef], "Saving node with different host and backup host, save is successful" );


my $path = $node2->inventory_path(concept => "catchall", data => {}, path_keys => []);
my ($catchall_inventory, $error) =  $node2->inventory( concept => "catchall", path => $path, path_keys => [], create => 1 );
BAIL_OUT "catchall inventory could not be created" if( $error ) ;

my $catchall_data = $catchall_inventory->data_live();
$node2->update_host_addr( catchall_data => $catchall_data );
$node2->sync_catchall( cache => $catchall_inventory );
my ( $save_op, $save_error ) = $catchall_inventory->save( node => $node2 );
ok( $save_op > 0, "catchall save is successful");

# when everything is addresses the host_addr isn't set because we don't want the gui to show duplicates
($catchall_inventory, $error) =  $node2->inventory( concept => "catchall", path => $path, path_keys => [], create => 1 );
my $catchall_data = $catchall_inventory->data_live();
is( $catchall_data->{host_addr}, '', "host_addr is empty");
is( $catchall_data->{host_addr_backup}, '', "host_addr_backup is empty");

# Now we need to test the host_addr and host_addr_backup
# switch host to names and get ip addresses into host_addr and host_addr_backup
# force the catchall to update
set_node_configuration_attrs( node => $node2, attrs => { host => 'hostname2', host_backup => 'hostname2_backup'});
cmp_deeply( [$node2->save], [2, undef], "Saving node with different host and backup host, save is successful" );
set_catchall_attrs( node => $node2, attrs => { host_addr => "1.2.3.3", host_addr_backup => "10.2.3.3"});

# add third node:
# first have host clash on $node2 host_addr
# then clash on node2 host_addr_backup
# then save correctly
my $node3 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node3->name($node_name3);
$node3->cluster_id(1);
$node3->configuration( {					
						host => "1.2.3.3",
						host_backup => "10.2.3.7",
						group => "somegroup",
						netType => "default",
						roleType => "default",
						threshold => 1,
						ci => 'abc126' } );


cmp_deeply( [$node3->validate], [-1, re(qr/host_addr/)], "Validation failed for ".$node3->name );


set_node_configuration_attrs( node => $node3, attrs => { host => "1.2.3.7", host_backup => "10.2.3.3"});
cmp_deeply( [$node3->validate], [-1, re(qr/host_addr_backup/)], "Validation failed for ".$node3->name );
($catchall_inventory, $error) =  $node2->inventory( concept => "catchall", path => $path, path_keys => [], create => 1 );
my $catchall_data = $catchall_inventory->data_live();
is( $node3->configuration->{host_backup}, $catchall_data->{host_addr_backup}, "a clash should be happening");

# now all unique
set_node_configuration_attrs( node => $node3, attrs => { host => "1.2.3.7", host_backup => "10.2.3.7"});
cmp_deeply( [$node3->save], [1, undef], "Saving node with different backup host, save is successful" );

# make sure saving again with same values works
$node3->configuration($node3->configuration);
cmp_deeply( [$node3->save], [2, undef], "Saving node with different backup host, save is successful" );


# need to test case sensitivity

# test host backup being empty, we must not search for blank string, it will be found on anything
# that has no backup
my $node4 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node4->name($node_name4);
$node4->cluster_id(1);
$node4->configuration( {					
						host => "1.2.4.4",
						host_backup => "",
						group => "somegroup",
						netType => "default",
						roleType => "default",
						threshold => 1,
						ci => 'abc144' } );
cmp_deeply( [$node4->save], [1, undef], "Saving node with different backup host, save is successful" );

my $node5 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node5->name($node_name5);
$node5->cluster_id(1);
$node5->configuration( {					
						host => "1.2.4.5",
						host_backup => "",
						group => "somegroup",
						netType => "default",
						roleType => "default",
						threshold => 1,
						ci => 'abc145' } );
cmp_deeply( [$node5->save], [1, undef], "Saving node with different backup host, save is successful" );						

# test when hostname does not resolve so there is no ip in host_ip, it should not match blank entries
# this isn't working correctly, 
{	
	set_node_configuration_attrs( node => $node4, attrs => { host => "hostname4"});
	cmp_deeply( [$node4->save], [2, undef], "Saving node with different backup host, save is successful" );

	$catchall_inventory = sync_and_update_node_catchall( node => $node4 );	
	my $catchall_data = $catchall_inventory->data_live();
	is( $catchall_data->{host_addr}, "", "host_addr should be empty for names that cannot be resolved");
	is( $catchall_data->{host_addr_backup}, "", "host_addr_backup should be empty for names that cannot be resolved");

	set_node_configuration_attrs( node => $node5, attrs => { host => "hostname5"});
	cmp_deeply( [$node5->save], [2, undef], "Saving node with different backup host, save is successful" );

	$catchall_inventory = sync_and_update_node_catchall( node => $node5 );
	$catchall_data = $catchall_inventory->data_live(); 
	is( $catchall_data->{host_addr}, "", "host_addr should be empty for names that cannot be resolved");
	is( $catchall_data->{host_addr_backup}, "", "host_addr_backup should be empty for names that cannot be resolved");
	my ( $save_op, $save_error ) = $catchall_inventory->save( node => $node2 );
	ok( $save_op > 0, "catchall save is successful");
	# print "catchalldata".Dumper($catchall_data);
	
	set_node_configuration_attrs( node => $node5, attrs => { host => "hostname5"});
	cmp_deeply( [$node5->save], [2, undef], "Saving node with different backup host, save is successful" );
}

# test where 1st node have IP, 2nd node has name that resolves to IP
# so this is where what will be host_addr clashes with host
# 
my $node6 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node6->name($node_name6);
$node6->cluster_id(1);
$node6->configuration( {host => "1.2.3.6", host_backup => "10.2.3.6",
											 group => "somegroup",
											 netType => "default",
											 roleType => "default",
											threshold => 1,
											ci => 'testduphostip1' } );
cmp_deeply( [$node6->save], [1, undef], "Node6 valid should save" );

my $node7 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node7->name($node_name7);
$node7->cluster_id(1);
$node7->configuration( {host => "node7", host_backup => "node7backup",
											 group => "somegroup",
											 netType => "default",
											 roleType => "default",
											threshold => 1,
											ci => 'testduphostip2' } );
cmp_deeply( [$node7->save], [1, undef], "Node7 valid should save" );

# this won't work, we need a way to fudge the dns to make node7 resolve to 1.2.3.6
# set_catchall_attrs( node => $node7, attrs => { host_addr => $node6->configuration->{host} });

NodeValidation::set_test_ips("1.2.3.6","10.2.3.71");
set_node_configuration_attrs( node => $node7, attrs => { new_prop => "needsomethingtochagne"});
# cmp_deeply( [$node2->validate], [re(qr/^-\d/),re(qr/Another node is already usin.*$node_name1/)], "Update node with duplicate host $configuration->{host_backup} is not valid" );
cmp_deeply( [$node7->validate], [re(qr/^-\d/),re(qr/Another node is already using/)], "Node7 name now 'resolves' to another nodes host (ip) and should not be valid" );

NodeValidation::set_test_ips("1.2.3.7","10.2.3.6");
set_node_configuration_attrs( node => $node7, attrs => { new_prop => "needsomethingtochagne"});
cmp_deeply( [$node7->validate], [re(qr/^-\d/),re(qr/Another node is already using/)], "Node7 backup now 'resolves' to another nodes host (backupip) and should not be valid" );
NodeValidation::set_test_ips("","");
# no clashing ip's or names anymore
cmp_deeply( [$node7->save], [2, undef], "Saving node with unique names that do not resolve should work" );

sub set_node_configuration_attrs {
	my (%args) = @_;
	my ($node,$attrs) = @args{'node','attrs'};
	my $configuration = $node->configuration();	
	foreach my $key (keys %$attrs) {
		$configuration->{$key} = $attrs->{$key};
	}
	$node->configuration($configuration);
}

sub sync_and_update_node_catchall {
	my (%args) = @_;
	my ($node) = @args{'node'};
	my $path = $node->inventory_path(concept => "catchall", data => {}, path_keys => []);
	my ($catchall_inventory, $error) =  $node->inventory( concept => "catchall", path => $path, path_keys => [], create => 1 );
	BAIL_OUT "catchall inventory could not be created" if( $error ) ;
	my $catchall_data = $catchall_inventory->data_live();
	$node->update_host_addr( catchall_data => $catchall_data );
	# print "catchalldata".Dumper($catchall_data);
	$node->sync_catchall( cache => $catchall_inventory );
	my ( $save_op, $save_error ) = $catchall_inventory->save( node => $node2 );
	ok( $save_op > 0, "catchall save is successful");
	($catchall_inventory, $error) =  $node->inventory( concept => "catchall", path => $path, path_keys => [], create => 1 );
	return $catchall_inventory;
}

sub set_catchall_attrs {
	my (%args) = @_;
	my ($node,$attrs) = @args{'node','attrs'};
	($catchall_inventory, $error) =  $node2->inventory( concept => "catchall", path => $path, path_keys => [], create => 1 );
	$catchall_data = $catchall_inventory->data_live();
	foreach my $key (keys %$attrs) {
		$catchall_data->{$key} = $attrs->{$key};
	}
	( $save_op, $save_error ) = $catchall_inventory->save( node => $node2 );
	ok( $save_op > 0, "catchall save is successful");
}	


if (-t \*STDIN)
{
	print "enter to continue and cleanup: ";
	my $x = <STDIN>;
}
cleanup_db();
done_testing();
