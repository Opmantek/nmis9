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

# Inventory Class

package NMISNG::Inventory;
use strict;

our $VERSION = "1.0.0";

use NMISNG::DB;

# based on the concept decide which class to create
# path is made every time it is requested, caching can be done later, I don't think it will
#  be called so often that caching will be necessary
sub get_inventory_class
{
	my ($concept) = @_;
	my $class = 'DefaultInventory';
	$concept = lc($concept);
	if ( $concept eq 'service' )
	{
		$class = 'ServiceInventory';
	}
	elsif ( $concept eq 'NeedsToBeMade' )
	{
		$class = 'MakeMeYouLazyBum';
	}

	$class = "NMISNG::Inventory::" . $class;
	return $class;
}

# params:
#.  cluster_id - server/cluster info
#   concept - type of inventory
#.  data - hash of data for this thing, whatever is required
#   id - the _id of this thing if it's not new
#   node_uuid - node this inventory is for
#   nmisng - NMISNG object, parent, config/log as well as model loading
sub new
{
	my ( $class, %args ) = @_;

	return if ( !$args{nmisng} );    #"nmisng required"

	my $self = {
		_cluster_id => $args{cluster_id} // 'getcurrentclusteridfromconfig',
		_concept    => $args{concept},
		_data       => $args{data},
		_id => $args{id} // $args{_id},    # this has to be possible in order to create new ones
		_node_uuid => $args{node_uuid},
		_nmisng    => $args{nmisng}		
	};
	bless( $self, $class );
	return $self;
}

###########
# Private:
###########

###########
# Protected:
###########

# subclasses should implement this, it is not a member function, it's a class one
# this is so that paths can be calculated without a whole object being created
# (which is handy for searching)
# it should fill out the path value
# it hsould return undef if it does not have enough data to create the path
# if partial is 1 then part of a path will be returned, which could be handy for searching
sub make_path
{
	my (%args) = @_;
	return;
}

###########
# Public:
###########
sub cluster_id
{
	my ($self) = @_;
	return $self->{_cluster_id};
}

sub concept
{
	my ($self) = @_;
	return $self->{_concept};
}

sub data
{
	my ($self) = @_;
	return $self->{_data};
}

# get the id (_id), readonly
# save adjusts this so is_new returns properly
sub id
{
	my ($self) = @_;
	return $self->{_id};
}

# returns 0/1 if the object is new or not.
# new means it is not yet in the aabase
sub is_new
{
	my ($self) = @_;

	my $configuration = $self->configuration();

	# print "id".Dumper($configuration);
	my $has_id = $self->id();
	return ($has_id) ? 0 : 1;
}

sub load
{
	my ( $self, %options ) = @_;
}

# return nmisng object this node is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

sub node_uuid
{
	my ($self) = @_;
	return $self->{_node_uuid};
}

# make the path and return it
# path is made by Class method
sub path
{
	my ($self) = @_;
	my $class = ref($self);
	my $path = $class->make_path( data => $self->data(), partial => 0 );
	$self->nmisng->log->error("Path must be an array") if ( ref($path) ne "ARRAY" );
	return $path;
}

# provide lastupdate time if desired
sub save
{
	my ( $self, $lastupdate ) = @_;

	return -1 if ( !$self->validate() );

	my $result;
	my $op;


	# path is calculated but must be stored so it can be queried
	my $record = {
		cluster_id => $self->cluster_id(),
		concept    => $self->concept(),
		data       => $self->data(),
		node_uuid  => $self->node_uuid(),
		path       => $self->path(),
		lastupdate => $lastupdate // time
	};

	if ( $self->is_new() )
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->nmisng->inventory_collection,
			record     => $record,
		);
		$self->{_id} = $result->{id} if ( $result->{success} );

		$op = 1;
	}
	else
	{
		$result = NMISNG::DB::update(
			collection => $self->nmisng->inventory_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $record->{_id}} ),
			record     => $record
		);

		$op = 2;
	}
	return ( $result->{success} ) ? ( $op, undef ) : ( undef, $result->{error} );
}

# returns 0/1 if the node is valid
sub validate
{
	my ($self) = @_;

	# must have, alphabetical for now, make cheapest first later?
	return 0 if ( !$self->cluster_id );
	return 0 if ( !$self->concept );
	return 0 if ( !ref( $self->data() ) ne 'ARRAY' );
	return 0 if ( !$self->path || @{$self->path} < 1 );
	return 0 if ( !$self->node_uuid );

	return 1;
}

1;
