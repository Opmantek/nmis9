#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

#
use strict;
use Carp;
use Test::More;
use Test::Deep;
use Data::Dumper;

use NMISNG;
use NMISNG::Util;

use t;
use Compat::NMIS;
Compat::NMIS::new_nmisng;

my %nvp   = %{NMISNG::Util::get_args_multi(@ARGV)};
my $C     = NMISNG::Util::loadConfTable();
my $debug = $nvp{debug};

$C->{db_name} = "nmisng_t_status_".time;

my $logfile = $C->{'<nmis_logs>'} . "/t_status.log";
my $logger  = NMISNG::Log->new(
	level => $debug // $C->{log_level},
	path => ( $debug ? undef : $logfile ),
);

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);

sub cleanup_db
{
	$nmisng->get_db()->drop();
}

t::prime_nodes(nmisng => $nmisng, synth_nr => 2);
my $nodes = $nmisng->get_nodes_model( sort => {node_name => 1} );
confess "I need at least 1 existing node to run" if ( $nodes->count < 2 );

my $node_1 = $nodes->object(0);
my $node_2 = $nodes->object(1);
isnt( $node_1->uuid, $node_2->uuid, "node 1 and 2 have different uuids");
my %attrs = (
	cluster_id => $node_1->cluster_id,
	node_uuid => $node_1->uuid,
	type     => "interface",
	property => "util_in",
	event    => "Proactive Interface Input Utilisation",
	index    => 2,
	level    => "Normal",
	method => "Threshold",
	status   => "ok",
	element  => "eth0",
	value    => 0,
	class    => undef,
);

# make a new status entry, make sure it is created with the attributes expected, that it saves properly
# and that what we get back when loading it matches what we saved
my $status_obj = NMISNG::Status->new(	nmisng => $nmisng, %attrs );
cmp_deeply( $status_obj->{data}, \%attrs, "object has expected attributes");

my $save_result = $status_obj->save();
is( $save_result, undef, "Save worked");
is( $status_obj->{data}{lastupdate}, undef, "status_obj does not get an lastupdate value, it only goes into db");
is( $status_obj->{data}{_id}, undef, "status_obj does not get an _id, must be loaded from db to get that");

my $md = $nmisng->get_status_model( filter => { cluster_id => $node_1->cluster_id, node_uuid => $node_1->uuid });
is( $md->count, 1, "Status was saved into db");
my $status_obj_loaded = $md->object(0);
my $compare_attr = $status_obj_loaded->{data};
isnt( $compare_attr->{lastupdate}, undef, "status object got an lastupdate time and was saved");
delete $compare_attr->{lastupdate};
delete $compare_attr->{expire_at};
delete $compare_attr->{_id};
cmp_deeply( $status_obj->{data}, $compare_attr, "data from created object matches data from loaded object");

# make a second object that matches the first, when saved this should only update the existing object, not create a new one
my $status_obj2 = NMISNG::Status->new(	nmisng => $nmisng, %attrs );
my $save_result2 = $status_obj2->save();
is( $save_result2, undef, "Save worked");
is( $status_obj2->{data}{lastupdate}, undef, "status_obj2 does not get an lastupdate value, it only goes into db");
is( $status_obj2->{data}{_id}, undef, "status_obj2 does not get an _id, must be loaded from db to get that");

my $md2 = $nmisng->get_status_model( filter => { cluster_id => $node_1->cluster_id, node_uuid => $node_1->uuid });
is( $md2->count, 1, "Status was saved into db");
my $status_obj_loaded2 = $md2->object(0);
my $compare_attr2 = $status_obj_loaded2->{data};
delete $compare_attr2->{lastupdate};
delete $compare_attr2->{expire_at};
delete $compare_attr2->{_id};
cmp_deeply( $status_obj2->{data}, $compare_attr2);

# alert
my %alert_attrs = (
	cluster_id => $node_2->cluster_id,
	node_uuid => $node_2->uuid,
	status => "error",
	value => 59.45,
	name => "HighSwapUsage",
	event => "High Swap Usage",
	element => "Swap space",
	index => undef,
	level => "Critical",
	inventory_id => undef,
	type => "threshold-rising",
	method => "Alert",
	property => 'CVAR1=hrStorageSize;CVAR2=hrStorageUsed;$CVAR2 / $CVAR1 * 100'
);

my $status_obj3 = NMISNG::Status->new(	nmisng => $nmisng, %alert_attrs );
is( $status_obj3->is_alert, 1, "status_obj3 is an alert");
my $save_result3 = $status_obj3->save();
is( $save_result3, undef, "Save worked");


my $md3 = $nmisng->get_status_model( filter => { cluster_id => $node_1->cluster_id, node_uuid => $node_2->uuid });
is( $md3->count, 1, "Only 1 status entry for this node");

$md3 = $node_2->get_status_model();
is( $md3->count, 1, "Only 1 status entry for this node, using the nodes get_status_model");

my $md4 = $nmisng->get_status_model( filter => { cluster_id => $node_1->cluster_id });
is( $md4->count, 2, "2 status entries total");

is( $status_obj2->delete(), undef, "deleting status object successful");

$md4 = $nmisng->get_status_model( filter => { cluster_id => $node_1->cluster_id });
is( $md4->count, 1, "1 status entries total after deleting one");


if (-t \*STDIN)
{
	print "hit enter to stop the test: ";
	my $x = <STDIN>;
}
cleanup_db();
done_testing();
