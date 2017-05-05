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

# Node class, use for access/manipulation of single node
# every node must have a UUID, this object will not devine one for you

package NMISNG::Node;
use strict;

our $VERSION = "1.0.0";

use Module::Load 'none';
use Carp::Assert;
use Clone;    # for copying overrides out of the record
use Data::Dumper;

use NMISNG::DB;
use NMISNG::Inventory;

# create a new node object
# params:
#   uuid - required
#   nmisng - NMISNG object, required ( for model loading, config and log)
#   id or _id - optional db id
# note: you must call one of the accessors to update the object before it can be saved!
sub new
{
	my ( $class, %args ) = @_;

	return if ( !$args{nmisng} );    #"collection nmisng"
	return if ( !$args{uuid} );      #"uuid required"

	my $self = {
		_dirty  => {},
		_nmisng => $args{nmisng},
		_id     => $args{_id} // $args{id} // undef,
		uuid    => $args{uuid}
	};
	bless( $self, $class );

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

	return $self;
}

###########
# Private:
###########

# tell the object that it's been changed so if save is
# called something needs to be done
# each section is tracked for being dirty, if it's 1 it's dirty
sub _dirty
{
	my ( $self, $newvalue, $whatsdirty ) = @_;

	if ( defined($newvalue) )
	{
		$self->{_dirty}{$whatsdirty} = $newvalue;
	}

	my @keys = keys %{$self->{_dirty}};
	foreach my $key (@keys)
	{
		return 1 if ( $self->{_dirty}{$key} );
	}
	return 0;
}

###########
# Public:
###########

# bulk set records to be historic which match this node and are not in the array of active_indices provided
# also updates records which are in the active_indices list to not be historic
# args: active_indices (optional, see concept), arrayref of active ids, concept (optional, if not given all inventory entries for node will be
#  marked historic (useful for update force=1)
# returns: hashref with number of records marked historic and nothistoric
sub bulk_update_inventory_historic
{
	my ($self,%args) = @_;
	my ($active_indices,$concept) = @args{'active_indices','concept'};
	return "invalid input,active_indices must be an array!" if ($active_indices && ref($active_indices) ne "ARRAY");
	my $retval = {};
	
	# not a huge fan of hard coding these, not sure there is much of a better way 
	my $q = {
		'path.0'  => $self->cluster_id,
		'path.1'  => $self->uuid,
	};
	$q->{'path.2'} = $concept if( $concept );

	# get_query currently doesn't support $nin, only $in
	$q->{'data.index'} = {'$nin' => $active_indices} if($active_indices);

	# mark historic where not in list
	my $result = NMISNG::DB::update(
		collection => $self->nmisng->inventory_collection,
		freeform => 1,
		multiple => 1,
		query => $q,
		record => { '$set' => { 'historic' => 1 } }
	);
	$retval->{marked_historic} = $result->{updated_records};
	$retval->{matched_historic} = $result->{matched_records};
	# if we have a list unset historic
	if( $active_indices )
	{
		$q->{'data.index'} = {'$in' => $active_indices} if($active_indices);
		$result = NMISNG::DB::update(
			collection => $self->nmisng->inventory_collection,
			freeform => 1,
			multiple => 1,
			query => $q,
			record => { '$set' => { 'historic' => 0 } }
		);
		$retval->{marked_nothistoric} = $result->{updated_records};
		$retval->{matched_nothistoric} = $result->{matched_records};
	}
	return $retval;
}

sub cluster_id
{
	my ($self) = @_;
	my $configuration = $self->configuration();
	return $configuration->{cluster_id};
}

# get/set the configuration for this node
# setting data means the configuration is dirty and will
#  be saved next time save is called, even if it is identical to what
#  is in the database
# getting will load the configuration if it's not already loaded and return a copy so
#   any changes made will not affect this object until they are put back (set) using this function
# params:
#  newvalue - if set will replace what is currently loaded for the config
#   and set the object to be dirty
# returns configuration hash
sub configuration
{
	my ( $self, $newvalue ) = @_;

	if ( defined($newvalue) )
	{
		$self->nmisng->log->warn("NMISNG::Node::configuration given new config with uuid that does not match")
			if ( $newvalue->{uuid} && $newvalue->{uuid} ne $self->uuid );

		# UUID cannot be changed
		$newvalue->{uuid} = $self->uuid;

		$self->{_configuration} = $newvalue;
		$self->_dirty( 1, 'configuration' );
	}

	# if there is no config try and load it
	if ( !defined( $self->{_configuration} ) )
	{
		$self->load_part( load_configuration => 1 );
	}

	return Clone::clone( $self->{_configuration} );
}

# get a list of id's for inventory related to this node,
# useful for iterating through all inventory
# filters/arguments:
#  cluster_id,node_uuid,concept
# needs to always return array, not sure if it currently does
sub get_inventory_ids
{
	my ( $self, %args ) = @_;

	# what happens when an error happens here?
	$args{fields_hash} = {'_id' => 1};

	my $model_data = $self->get_inventory_model(%args);

	my $data = $model_data->data();
	my @ids = map { $_->{_id}{value} } @$data;
	return \@ids;
}

sub get_inventory_model
{
	my ( $self, %args ) = @_;
	$args{cluster_id} = $self->cluster_id;
	$args{node_uuid}  = $self->uuid();

	my $model_data = $self->nmisng->get_inventory_model(%args);

	return $model_data;
}

# find or create inventory object based on arguments
# object returned will have base class NMISNG::Inventory but will be a
# subclass of it specific to its concept; if no specific implementation is found
# the DefaultInventory class will be used/returned.
# if searching by path then it needs to be passed in, caller will know what type of
# inventory class they want so they can call the appropriate make_path function
# args: 
#    any args that can be used for finding an inventory model, 
#  if none is found then:
#    concept, data, path path_keys, create - 0/1 
#    (possibly not path_keys but whatever path info is needed for that specific inventory type)
# returns: (inventory object, undef) or (undef, error message)
sub inventory
{
	my ( $self, %args ) = @_;

	# before trying anything make sure we are ok
	my ($valid,$invalid_message) = $self->validate();
	return ( undef, "Node Invalid:".$invalid_message ) if ( !$valid );

	my $create = $args{create};
	delete $args{create};
	my ( $inventory, $class ) = ( undef, undef );

	# force these arguments to be for this node
	my $data = $args{data};
	$args{cluster_id} = $self->cluster_id();
	$args{node_uuid}  = $self->uuid();

	# fix the search to this node
	my $path = $args{path} // [];

	# it sucks hard coding this to 1, please find a better way
	$path->[1] = $self->uuid;

	# what happens when an error happens here?
	my $model_data = $self->nmisng->get_inventory_model(%args);
	if ( $model_data->count() > 0 )
	{
		$self->nmisng->log->warn("Inventory search returned more than one value, using the first!".Dumper(\%args))
			if($model_data->count() > 1);
		my $model = $model_data->data()->[0];
		$class = NMISNG::Inventory::get_inventory_class( $model->{concept} );

		# use the model as arguments because everything is in the right place
		$model->{nmisng} = $self->nmisng;

		# some Inventory classes require extra params, assume they have been passed in and need to go to new
		map { $model->{$_} = $args{$_} if ( !defined( $model->{$_} ) ) } keys %args;

		Module::Load::load $class;
		$inventory = $class->new(%$model);
	}
	elsif ($create)
	{
		# concept must be supplied, for now, "leftovers" may end up being a concept,
		$self->nmisng->log->debug("Creating Inventory for concept: $args{concept}");
		$self->nmisng->log->error("Creating Inventory without concept") if ( !$args{concept} );
		$class = NMISNG::Inventory::get_inventory_class( $args{concept} );

		$args{nmisng} = $self->nmisng;
		Module::Load::load $class;
		$inventory = $class->new(%args);

	}

	return ( $inventory, undef );
}

# create the correct path for an inventory item, calling the make_path
# method on the class that relates to the specified concept
# args must contain concept and data, along with any other info required
# to make that path (probably path_keys)
sub inventory_path
{
	my ( $self, %args ) = @_;

	my $concept = $args{concept};
	my $data    = $args{data};
	$args{cluster_id} = $self->cluster_id();
	$args{node_uuid}  = $self->uuid();

	# ask the correct class to make the inventory
	my $class = NMISNG::Inventory::get_inventory_class($concept);

	Module::Load::load $class;
	my $path = $class->make_path(%args);
	return $path;
}

# returns 0/1 if the object is new or not.
# new means it is not yet in the database
sub is_new
{
	my ($self) = @_;

	my $configuration = $self->configuration();

	# print "id".Dumper($configuration);
	my $has_id = ( defined($configuration) && defined( $configuration->{_id} ) );
	return ($has_id) ? 0 : 1;
}

# load data for this node from the database, named load_part because the module Module::Load has load which clashes
# and i don't know how else to resolve the issue
# params:
#  options - hash, if not set or present all data for the node is loaded
#    load_overrides => 1 will load overrides
#    load_configuration => 1 will load overrides
# no return value
sub load_part
{
	my ( $self, %options ) = @_;
	my @options_keys = keys %options;
	my $no_options   = ( @options_keys == 0 );

	my $query = NMISNG::DB::get_query( and_part => {uuid => $self->uuid} );
	my $cursor = NMISNG::DB::find(
		collection => $self->nmisng->nodes_collection(),
		query      => $query
	);
	my $entry = $cursor->next;
	if ($entry)
	{

		if ( $no_options || $options{load_overrides} )
		{
			# return an empty hash if it's not defined
			$entry->{overrides} //= {};
			$self->{_overrides} = Clone::clone( $entry->{overrides} );
			$self->_dirty( 0, 'overrides' );
		}
		delete $entry->{overrides};

		if ( $no_options || $options{load_configuration} )
		{
			# everything else is the configuration
			$self->{_configuration} = $entry;
			$self->_dirty( 0, 'configuration' );
		}
	}
}

# get/set the overrides for this node
# setting data means the overrides is dirty and will
#  be saved next time save is called, even if it is identical to what
#  is in the database
# getting will load the overrides if it's not already loaded
# params:
#  newvalue - if set will replace what is currently loaded for the overrides
#   and set the object to be dirty
# returns overrides hash
sub overrides
{
	my ( $self, $newvalue ) = @_;
	if ( defined($newvalue) )
	{
		$self->{_overrides} = $newvalue;
		$self->_dirty( 1, 'overrides' );
	}

	# if there is no config try and load it
	if ( !defined( $self->{_overrides} ) )
	{
		if ( !$self->is_new && $self->uuid )
		{
			$self->load_part( load_overrides => 1 );
		}
	}

	# loading will set this to an empty hash if it's not defined
	return $self->{_overrides};
}

# Save object to DB if it is dirty
# returns tuple, 0 if no saving required ($sucess,$error_message), -1 if node is not valid, >0 if all good
# TODO: error checking just uses assert right now, we may want
#   a differnent way of doing this
sub save
{
	my ($self) = @_;

	return ( -1, "node is incomplete, not saveable yet" )
			if ($self->is_new && !$self->_dirty);
	return ( 0,  undef )          if ( !$self->_dirty() );

	my ( $valid, $validation_error ) = $self->validate();
	return ( $valid, $validation_error ) if ( $valid < 1 );

	my $result;
	my $op;

	my $entry = $self->configuration();
	$entry->{overrides} = $self->overrides();

	# make 100% certain we've got the uuid correct
	$entry->{uuid} = $self->uuid;

	if ( $self->is_new() )
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->nmisng->nodes_collection(),
			record     => $entry,
		);
		assert( $result->{success}, "Record inserted successfully" );
		$self->{_configuration}{_id} = $result->{id} if ( $result->{success} );

		$self->_dirty( 0, 'configuration' );
		$self->_dirty( 0, 'overrides' );
		$op = 1;
	}
	else
	{
		$result = NMISNG::DB::update(
			collection => $self->nmisng->nodes_collection(),
			query      => NMISNG::DB::get_query( and_part => {uuid => $self->uuid} ),
			record     => $entry
		);
		assert( $result->{success}, "Record updated successfully" );

		$self->_dirty( 0, 'configuration' );
		$self->_dirty( 0, 'overrides' );
		$op = 2;
	}
	return ( $result->{success} ) ? ( $op, undef ) : ( -2, $result->{error} );
}

# return nmisng object this node is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# get the nodes id (which is it's UUID)
sub uuid
{
	my ($self) = @_;
	return $self->{uuid};
}

# returns 0/1 if the node is valid
sub validate
{
	my ($self) = @_;
	my $configuration = $self->configuration();

	return (-1, "node requires name") if ( !$configuration->{name} );
	return (-2, "node requires cluster_id") if ( !$configuration->{cluster_id} );
	return (1,undef);
}

1;
