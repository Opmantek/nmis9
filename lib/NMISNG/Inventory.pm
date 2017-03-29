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
# Base class which specific Inventory implementions should inherit from
# Provides basic structure and saving

package NMISNG::Inventory;
use strict;

our $VERSION = "1.0.0";

use Clone;    # for copying data section
use Data::Dumper;

use NMISNG::DB;

# based on the concept, decide which class to create
# - or return the fallback/default class
# path is made every time it is requested, caching can be done later, I don't think it will
#  be called so often that caching will be necessary
sub get_inventory_class
{
	my ($concept) = @_;
	my %knownclasses = ( 'default' => 'DefaultInventory', # the fallback
											 'service' => "ServiceInventory",
											 "NeedsToBeMade" => "MakeMeYouLazyBum",
			);

	my $class =  "NMISNG::Inventory::" . ($knownclasses{$concept} // $knownclasses{default});
	return $class;
}

# params:
#   concept - type of inventory
#   data - hash of data for this thing, whatever is required, must include cluster_id and node_uuid
#   id - the _id of this thing if it's not new
#   nmisng - NMISNG object, parent, config/log as well as model loading
#   path - used if provided, not required, can be calculated on save if enough info is present,
#     basically required for existing inventory objects
sub new
{
	my ( $class, %args ) = @_;

	my $nmisng = $args{nmisng};
	return if ( !$nmisng );    # check this so we can use it to log

	my $data = $args{data};
	$nmisng->log->error("DefaultInventory cannot be created without cluster_id") && return
		if ( !$data->{cluster_id} );    # required"
	$nmisng->log->error("DefaultInventory cannot be created without node_uuid") && return
		if ( !$data->{node_uuid} );     # required"

	my $self = {
		_concept => $args{concept},
		_data    => $args{data},
		_id      => $args{id} // $args{_id},    # this has to be possible in order to create new ones from modeldata
		_nmisng  => $args{nmisng},
		_path    => $args{path},
	};
	bless( $self, $class );

	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

	return $self;
}

###########
# Private:
###########

###########
# Protected:
###########

# take data and a set of keys (path_keys, which index the provided data) and create
# a path out of them.  This is a generic function that can work with any class
# it just needs to provide the params, this is why it exists here. DefaultInventory
# relies on this implementation to work, if your subclass does not need to do anything
# fancy (like morph/tranlate data in keys) then it should probably use this implementation
sub make_path_from_keys
{
	my (%args)        = @_;
	my $concept       = $args{concept};
	my $data_original = $args{data};
	my $keys_original = $args{path_keys} // [];
	my $partial = $args{partial};

	return if ( ref($keys_original) ne 'ARRAY' );

	my $path = [];

	# deep copy data so we can put concept into it
	my $data = Clone::clone($data_original);
	$data->{concept} = $concept;

	# copy keys (because user may pass in same ref several times) and add prereqs
	# shallow ok here
	my $keys = [@$keys_original];
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
# it should return undef if it does not have enough data to create the path
# if partial is 1 then part of a path will be returned, which could be handy for searching (maybe?)
# param - data, hash holding place to build path from
sub make_path
{
	# make up for object deref invocation being passed in as first argument
	# expecting a hash which has even # of inputs
	shift if ( !( $#_ % 2 ) );
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

# RO, returns cluster_id of this Inventory
sub cluster_id
{
	my ($self) = @_;
	return $self->data()->{cluster_id};
}

# RO, returns concept of this Inventory
sub concept
{
	my ($self) = @_;
	return $self->{_concept};
}

# returns a copy of the data
# to change data call and set a new value
sub data
{
	my ( $self, $newvalue ) = @_;
	if ( defined($newvalue) )
	{
		$self->{_data} = $newvalue;
	}
	return Clone::clone( $self->{_data} );
}

# get the id (_id), readonly
# save adjusts this so is_new returns properly
# may be undef if is_new
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

# return nmisng object this node is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# return this Inventories node uuid
sub node_uuid
{
	my ($self) = @_;
	return $self->data()->{node_uuid};
}

# make or get the path and return it
# new objects will recalculate their path on each call, specifiying recalculate makes no difference
# objects which are not new should already have a path and that value will be returned
# unless recalculate is specified.
# param recalculate - [0/1]
# path is made by Class method corresponding to the this objects concept
# NOTE: the use of path keys below breaks convention,
sub path
{
	my ( $self, %args ) = @_;

	my $path;
	if ( !$self->is_new() && !$self->{_path} && !$args{recalculate} )
	{
		$self->nmisng->log->error("Saved inventory should already have a path");
	}
	elsif ( !$self->is_new() && $self->{_path} && !$args{recalculate} )
	{
		$path = $self->{_path};
	}
	else
	{
		# make_path will ignore the first arg here
		# so calling it on self is safe, we are aiming to call the
		# subclasses make_path (or ours if not overloaded)
		$args{concept} = $self->concept();
		$args{data}    = $self->data();

		$path = $self->make_path(%args);

		# always store the path, it may be re-calculated next time but that's fine
		# if we don't store here recalculate/save won't work
		$self->{_path} = $path;

	}
	$self->nmisng->log->error("Path must be an array") if ( ref($path) ne "ARRAY" );
	return $path;
}

# provide lastupdate time if desired
# lastupdate is currently not added to object but is stored in db
# returns ($op,$error), op is 1 for insert, 2 for save, error is string if there was an error
# on save _id and _path are refreshed, lastupdate is set to save time if not supplied
sub save
{
	my ( $self, %args ) = @_;
	my $lastupdate = $args{lastupdate} // time;

	my ( $valid, $validation_error ) = $self->validate();
	return ( -1, $validation_error ) if ( !$valid );

	my $result;
	my $op;

	# path is calculated but must be stored so it can be queried
	my $record = {
		concept    => $self->concept(),
		data       => $self->data(),
		path       => $self->path(),
		lastupdate => $lastupdate
	};

	if ( $self->is_new() )
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->nmisng->inventory_collection,
			record     => $record,
		);
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

	# refresh some values on success
	if ( $result->{success} )
	{
		$self->{_id}   = $result->{id};
		$self->{_path} = $record->{path};
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
