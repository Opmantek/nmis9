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

# specifically test that nmis sets the nodeModel to something
# if the model value is empty ('')

use strict;
our $VERSION = "1.1.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Deep;
use Data::Dumper;

use NMISNG;
use NMISNG::DB;
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

# set the model to undef, don't save as that will change it
my $configuration = $numb->configuration();
$configuration->{model} = '';
$numb->configuration($configuration);
is( $numb->configuration->{model}, '', "model is empty");

# init the sys object, it should work
my $S = NMISNG::Sys->new(nmisng => $nmisng);    # create system object
my $init_success = $S->init(node => $numb, update => 1);
is( $init_success, 1, "init was successful");
