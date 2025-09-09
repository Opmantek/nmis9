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

# Test sys functions (only one ATM):
#   - test prep_extras_with_catchalls - copy_node_configuration_to_catchall_list config setting

use strict;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Deep;
use Data::Dumper;

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;

my $C = NMISNG::Util::loadConfTable();

my $node_name = "name";

# modify dbname to be time specific for this test
$C->{db_name} = "t_nmisng-" . time;

# log to stdout
my $logger = NMISNG::Log->new( level => 'debug' );

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);
die "NMISNG object required" if ( !$nmisng );

cleanup_db();
sub cleanup_db
{
	$nmisng->get_db()->drop();
}

# make tests easier
$nmisng->config->{nettype_list} = 'netType';
$nmisng->config->{roletype_list} = 'roleType';

my $node = NMISNG::Node->new(
	uuid   => NMISNG::Util::getUUID(),
	nmisng => $nmisng,
);

is( $node->is_new, 1, "New node is still new" );

$node->cluster_id($nmisng->config->{cluster_id});
$node->name($node_name);
$node->configuration( {host => "host",
											 group => "group",
											 netType => "netType",
											 roleType => "roleType",
											 model => "automatic",
											 custom1 => "custom1",
											 custom2 => "custom2",
											threshold => 1 } );
cmp_deeply( [$node->save], [1, undef], "Node name is valid, so saved with insert" );


my $S = NMISNG::Sys->new(nmisng => $node->nmisng);
my $initRet = $S->init( node => $node, snmp => 0, wmi => 0,policy => $node->configuration->{polling_policy} );
is ($initRet,1,"sys init successful");
BAIL_OUT("sys init required") if( $initRet != 1 );

my $catchall = $S->inventory( concept => 'catchall' );
my $catchall_data = $catchall->data_live();
isnt($catchall_data, undef, "catchall is defined");

# test prep_extras_with_catchalls - copy_node_configuration_to_catchall_list config setting
{
	# prep_extras_with_catchalls uses "live" data so we can prime it here
	my @catchall_keys = qw(name host group roleType nodeModel nodeType nodeVendor sysDescr sysObjectName location);
	$catchall_data->{$_} = $_ foreach( @catchall_keys);

	# just test the additional keys
	my $extras = {};
	$extras = $S->prep_extras_with_catchalls( extras => $extras );

	foreach my $key (@catchall_keys) {
		is( $extras->{$key}, $key, "key $key is set properly");
	}
	# remove keys added above the ones requested
	delete $extras->{$_} foreach (qw/node ifDescr ifType ifSpeed ifMaxOctets item index/);
	my @extras_keys = keys %$extras;
	cmp_deeply( \@catchall_keys, supersetof(@extras_keys), "keys in extras match catchall keys");

	# update catchall keys because it has new keys
	push @catchall_keys,("custom1","custom2");
	# add new custom properties, make sure both array and comma separated list
	foreach my $custom_keys_props ("custom1,custom2", ["custom1","custom2"]) {		
		$C->{copy_node_configuration_to_catchall_list} = $custom_keys_props;
		$node->sync_catchall(sys => $S, cache => $catchall);
		is( $catchall_data->{custom1}, "custom1", "additional custom1 property added");
		is( $catchall_data->{custom2}, "custom2", "additional custom2 property added");
		
		# now test to make sure they come through into the extras
		my $extras = {};
		$DB::single = 1;
		$extras = $S->prep_extras_with_catchalls( extras => $extras );
		foreach my $key (@catchall_keys) {
			is( $extras->{$key}, $key, "key $key is set properly");
		}
		# remove keys added above the ones requested
		delete $extras->{$_} foreach (qw/node ifDescr ifType ifSpeed ifMaxOctets item index/);
		my @extras_keys = keys %$extras;
		cmp_deeply( \@catchall_keys, supersetof(@extras_keys), "keys in extras match catchall keys");
	}
}

cleanup_db();
done_testing();