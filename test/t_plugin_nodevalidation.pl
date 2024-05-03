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

my $node_name = "node0";
my $node_name1 = "node1";
my $node_name2 = "node2";

# modify dbname to be time specific for this test
$C->{db_name} = "t_nmisng-" . time;

# log to stdout
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
                                                                 debug => 1 ));

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);
die "NMISNG object required" if ( !$nmisng );


# make sure validation plugin is in the right spot
my $bin = "$FindBin::Bin";
my $original_plugin = $bin."/../conf-default/validation_plugins/NodeValidation.pm";
my $enabled_plugin = $bin."/../conf-default/plugins/NodeValidation.pm";
BAIL_OUT("plugin already there, do not want to clobber it") if( -r $enabled_plugin);
copy($original_plugin, $enabled_plugin);

sub cleanup_db
{
	$nmisng->get_db()->drop();
	unlink $enabled_plugin;
}

is( -r $enabled_plugin, 1, "plugin is found and readable" );

# create node with no device_ci
my $node = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
isnt( $node, undef, "Node object returned when required parameters provided" );
is( $node->is_new, 1, "New node is new" );
is( $node->_dirty, 0, "New node with no config is not dirty" );
$node->name($node_name);
$node->cluster_id(1);
$node->configuration( {host => "1.2.3.4",
											 group => "somegroup",
											 netType => "default",
											 roleType => "default",
											threshold => 1, } );

# returns -number and error says can't be empty
cmp_deeply( [$node->validate], [re(qr/^-\d/),re(qr/cannot be empty/)], "New node with no device_ci is not" );

# add ci value
my $configuration = $node->configuration();
$configuration->{device_ci} = 'abc123';
$node->configuration($configuration);
is( $node->_dirty,1, "setting just device_ci means node is dirty" );

# node with unique device_ci is valid
cmp_deeply( [$node->validate], [re(qr/^\d/),ignore], "New node with unique device_ci is valid" );

# save node
cmp_deeply( [$node->save], [1, undef], "Node is valid, save is successful" );

# set device ci to same value and save again
my $configuration = $node->configuration();
$configuration->{device_ci} = 'abc123';
$node->configuration($configuration);
cmp_deeply( [$node->save], [2, undef], "Updating node with same device_ci, save is successful" );

# add second node:
my $node2 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node2->name($node_name1);
$node2->cluster_id(1);
$node2->configuration( {host => "1.2.3.5",
											 group => "somegroup",
											 netType => "default",
											 roleType => "default",
											threshold => 1,
											device_ci => 'abc123' } );

# duplicate device_ci is not valid
cmp_deeply( [$node2->validate], [re(qr/^-\d/),$node_name], "New node with duplicate device_ci is not valid" );
cmp_deeply( [$node2->save], [re(qr/^-\d/), ignore], "Node with duplicate device_ci does not save" );

# change device_ci on second node
my $configuration = $node2->configuration();
$configuration->{device_ci} = 'abc124';
$node2->configuration($configuration);
cmp_deeply( [$node2->save], [1, undef], "Saving node with different device_ci, save is successful" ) or diag;


# update device_ci on second node to duplicate
my $configuration = $node2->configuration();
$configuration->{device_ci} = 'abc123';
$node2->configuration($configuration);
cmp_deeply( [$node2->validate], [re(qr/^-\d/),$node_name], "Update node with duplicate device_ci is not valid" );
cmp_deeply( [$node2->save], [-1, ignore], "Saving node with different device_ci, save not successful" );

# update device_ci on second node to be unique but different
my $configuration = $node2->configuration();
$configuration->{device_ci} = 'abc125';
$node2->configuration($configuration);
cmp_deeply( [$node2->save], [2, undef], "Saving node with different device_ci, save is successful" );


# make sure host values must be unique
# we already have two unique values, changing one to be a duplicate should be all that is needed
# update device_ci on second node to duplicate
my $configuration = $node2->configuration();
$configuration->{host} = '1.2.3.4';
$node2->configuration($configuration);
cmp_deeply( [$node2->validate], [re(qr/^-\d/),$node_name], "Update node with duplicate host is not valid" );
cmp_deeply( [$node2->save], [-1, ignore], "Saving node with different host, save not successful" );

# update device_ci on second node to be unique but different
my $configuration = $node2->configuration();
$configuration->{host} = '1.2.3.3';
$configuration->{host_backup} = '1.2.3.4';
$node2->configuration($configuration);
cmp_deeply( [$node2->save], [2, undef], "Saving node with different host and backup host, save is successful" );


my $path = $node2->inventory_path(concept => "catchall", data => {}, path_keys => []);
my ($catchall_inventory, $error) =  $node2->inventory( concept => "catchall", path => $path, path_keys => [], create => 1 );
if( !$error ) 
{
	my $catchall_data = $catchall_inventory->data_live();	
	$node2->sync_catchall( cache => $catchall_inventory );
	$catchall_inventory->save();
}

# add third node:
my $node3 = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);
$node3->name($node_name2);
$node3->cluster_id(1);
$node3->configuration( {					
						host => "1.2.3.7",
						host_backup => "1.2.3.4",
						group => "somegroup",
						netType => "default",
						roleType => "default",
						threshold => 1,
						device_ci => 'abc126' } );


cmp_deeply( [$node3->validate], [-1, re(qr/monitoring address is already present/)], "Validation failed for ".$node3->name );

my $configuration = $node3->configuration();

## change the configuration of backup host.
$configuration->{host_backup} = '1.2.3.8';

$node3->configuration($configuration);

cmp_deeply( [$node3->save], [1, undef], "Saving node with different backup host, save is successful" );






if (-t \*STDIN)
{
	print "enter to continue and cleanup: ";
	my $x = <STDIN>;
}
cleanup_db();
done_testing();
