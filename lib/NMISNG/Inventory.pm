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

use Data::Dumper;

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
#   concept - type of inventory
#   data - hash of data for this thing, whatever is required, must include cluster_id and node_uuid
#   id - the _id of this thing if it's not new
#   nmisng - NMISNG object, parent, config/log as well as model loading
#   path_keys - keys from data used to make the path, this does not include things that are automatically adde
#    this isn't necessarily needed if make_path is overridden
sub new
{
	my ( $class, %args ) = @_;

	my $data = $args{data};
	return if ( !$args{nmisng} );          #required"
	return if ( !$data->{cluster_id} );    # required"
	return if ( !$data->{node_uuid} );     # required"

	my $self = {
		_concept   => $args{concept},
		_data      => $args{data},
		_id        => $args{id} // $args{_id},    # this has to be possible in order to create new ones from modeldata
		_nmisng    => $args{nmisng},
		_path_keys => $args{path_keys},
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

# keys default is here so tests can work
sub make_path_from_keys
{
	my (%args)        = @_;
	my $concept       = $args{concept};
	my $data_original = $args{data};
	my $keys = $args{path_keys} // [];
	my $partial = $args{partial};

	return if ( ref($keys) ne 'ARRAY' );

	my $path;

	# copy data so we can put concept into it
	my $data = {%$data_original};
	$data->{concept} = $concept;

	unshift @$keys, 'cluster_id', 'node_uuid', 'concept';
	foreach my $key (@$keys)
	{
		return if ( !$partial && !defined( $data->{$key} ) );
		push @$path, $data->{$key};
	}
	return $path;
}

# subclasses should implement this, it is not a member function, it's a class one
# this is so that paths can be calculated without a whole object being created
# (which is handy for searching)
# it should fill out the path value
# it should use this implementation as it's 'base' path and add to it
# it should return undef if it does not have enough data to create the path
# if partial is 1 then part of a path will be returned, which could be handy for searching (maybe?)
# param - data, hash holding place to find keys
# param - keys, array holding keys from data to put into the path
sub make_path
{
	# make up for object deref invocation being passed in as first argument
	# expecting a hash which has even # of inputs
	shift if(! ($#_ % 2) );
	my (%args) = @_;
	
	return make_path_from_keys(%args);
}

###########
# Public:
###########

# TODO!!!
sub add_pit
{
	my ($self) = @_;

	# take time, data, add in this _inventory_id and then save it
	# saving is assumed
	# can't add to unsaved inventory, or it autosaves
}

sub cluster_id
{
	my ($self) = @_;
	return $self->data()->{cluster_id};
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
	return $self->data()->{node_uuid};
}

# make the path and return it
# path is made by Class method
sub path
{
	my ( $self ) = @_;

	# make_path will ignore the first arg here
	# so calling it on self is safe, we are aiming to call the 
	# subclasses make_path (or ours if not overloaded)
	my $path  = $self->make_path(
		concept   => $self->concept,
		data      => $self->data,
		partial   => 0,
		path_keys => $self->{_path_keys}
	);

	$self->nmisng->log->error("Path must be an array") if ( ref($path) ne "ARRAY" );
	return $path;
}

# provide lastupdate time if desired
# lastupdate is currently not added to object but is stored in db
sub save
{
	my ( $self, $lastupdate ) = @_;
	$lastupdate //= time;

	my ( $valid, $validation_error ) = $self->validate();
	return ( -1, $validation_error ) if ( !$valid );

	my $result;
	my $op;

	# path is calculated but must be stored so it can be queried
	my $record = {
		concept => $self->concept(),
		data    => $self->data(),
		path    => $self->path(),
		lastupdate => $lastupdate
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

	# TODO: set lastupdate into object?
	return ( $result->{success} ) ? ( $op, undef ) : ( undef, $result->{error} );
}

# returns 0/1 if the node is valid
sub validate
{
	my ($self) = @_;

	my $path = $self->path();

	# must have, alphabetical for now, make cheapest first later?
	return ( 0, "invalid cluster_id" ) if ( !$self->cluster_id );
	return ( 0, "invalid concept" )    if ( !$self->concept );
	return ( 0, "invalid data" )       if ( ref( $self->data() ) ne 'HASH' );
	return ( 0, "invalid path" )       if ( !$path || @$path < 1 );
	return ( 0, "invalid node_uuid" )  if ( !$self->node_uuid );

	return 1;
}

1;
