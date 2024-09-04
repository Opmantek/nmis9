#!/usr/bin/perl
#
#  Copyright (C) Firstwave Limited (www.firstwave.com)
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

# some basic testing of the ModelData object, making sure iterator functions are
# working as expexted

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

#
use strict;
use warnings;

use Carp;
use Test::More;
use Test::Deep;
use Data::Dumper;
use Try::Tiny;

use NMISNG;
use NMISNG::Util;
use NMISNG::ModelData;

use t;

my $C = NMISNG::Util::loadConfTable();
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

# make sure error works
my $errormd = NMISNG::ModelData->new(
    nmisng => $nmisng,
    error  => "you have a problem!"
);
is( $errormd->error, "you have a problem!", "the error state returns an error");

my $total_count = 10;
t::prime_nodes(nmisng => $nmisng, synth_nr => $total_count);
my $md = $nmisng->get_nodes_model( sort => {node_name => 1} );

is( $md->error, undef, "no error");
is( $md->count, $total_count, "count");

my $count_check = 0;
# check next value using cursor
while( my $nodedata = $md->next_value ) {
    is( ref($nodedata), "HASH", "next value returns hash");
    $count_check++;
}
is( $count_check, $total_count, "next_value returning correct count");
$DB::single = 1;
my $has_next = $md->has_next();
is( $has_next, 0, "does not has next value");

# check next object using cursor
$md = $nmisng->get_nodes_model( sort => {node_name => 1} );
while( my $nodeobj = $md->next_object ) {
    is( ref($nodeobj), "NMISNG::Node", "next value returns Node object");
}
my $has_next = $md->has_next();
is( $has_next, 0, "does not has next value");

# access data first to make sure that works
$md = $nmisng->get_nodes_model( sort => {node_name => 1} );
is( $md->error, undef, "no error");
my $data = $md->data();
my $has_next = $md->has_next();
is( $has_next, 1, "has next value");
my $next = $md->next_value();
is( @$data, $total_count, "data returns them all");
is( ref($next), "HASH", "next_value still returns first thing");

# access next, then data should fail
$md = $nmisng->get_nodes_model( sort => {node_name => 1} );
is( $md->error, undef, "no error");
my $has_next = $md->has_next();
is( $has_next, 1, "has next value");
my $next = $md->next_value();
my $has_error;
try {
    my $data = $md->data();
} catch {
    $has_error = $_;
};
isnt($has_error,undef,"using iterator and then data should fail");

# access next, then count should fail
$md = $nmisng->get_nodes_model( sort => {node_name => 1} );
is( $md->error, undef, "no error");
my $next = $md->next_value();
my $has_error;
try {
    my $data = $md->count();
} catch {
    $has_error = $_;
};
isnt($has_error,undef,"using iterator and then count should fail");


# test getting all objects
$md = $nmisng->get_nodes_model( sort => {node_name => 1} );
is( $md->error, undef, "no error");
my $all_objects_ret = $md->objects();
is( $all_objects_ret->{success}, 1, "objects was success");
is( @{$all_objects_ret->{objects}},$total_count, "objects returns total count");


if (-t \*STDIN)
{
	print "enter to continue and cleanup: ";
	my $x = <STDIN>;
}

cleanup_db();
done_testing();
