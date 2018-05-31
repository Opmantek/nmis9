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
# note: every node must have a UUID, this object will not divine one for you

package NMISNG::Node;
use strict;

our $VERSION = "1.1.0";

use Module::Load 'none';
use Carp::Assert;
use Carp;
use Clone;
use List::Util 1.33;
use Data::Dumper;
use Time::HiRes;
use Net::DNS;
use Statistics::Lite;
use URI::Escape;
use POSIX qw(:sys_wait_h);
use Fcntl qw(:DEFAULT :flock :mode); # for flock
use Net::SNMP;									# for oid_lex_sort

use NMISNG::Util;
use NMISNG::DB;
use NMISNG::Inventory;
use NMISNG::Sapi;								# for collect_services()
use NMISNG::MIB;
use NMISNG::Sys;
use NMISNG::Ping;
use NMISNG::Notify;
use NMISNG::rrdfunc;

use Compat::IP;


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

# fill in properties we want and expect
sub _defaults
{
	my ( $self,$configuration ) = @_;
	$configuration->{port} //= 161;
	$configuration->{max_msg_size} //= $self->nmisng->config->{snmp_max_msg_size};
	$configuration->{max_repetitions} //= 0;

	return $configuration;
}

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

#
# bulk set records to be historic which match this node and are
# not in the array of active_indices (or active_ids) provided
#
# also updates records which are in the active_indices/active_ids
# list to not be historic
# please note: this cannot and does NOT extend the expire_at ttl for active records!
#
# args: active_indices (optional), arrayref of active indices,
#   which can work if and  only if the concept uses 'index'!
# active_ids (optional), arrayref of inventory ids (mongo oids or strings),
#   note that you can pass in either active_indices OR active_ids
#   but not both
# concept (optional, if not given all inventory entries for node will be
#   marked historic (useful for update force=1)
#
# returns: hashref with number of records marked historic and nothistoric
sub bulk_update_inventory_historic
{
	my ($self,%args) = @_;
	my ($active_indices, $active_ids, $concept) = @args{'active_indices','active_ids','concept'};

	return { error => "invalid input, active_indices must be an array!" }
			if ($active_indices && ref($active_indices) ne "ARRAY");
	return { error => "invalid input, active_ids must be an array!" }
			if ($active_ids && ref($active_ids) ne "ARRAY");
	return { error => "invalid input, cannot handle both active_ids and active_indices!" }
		if ($active_ids and $active_indices);

	my $retval = {};

	# not a huge fan of hard coding these, not sure there is much of a better way
	my $q = {
		'path.0'  => $self->cluster_id,
		'path.1'  => $self->uuid,
	};
	$q->{'path.2'} = $concept if( $concept );

	# get_query currently doesn't support $nin, only $in
	if ($active_ids)
	{
		$q->{'_id'} = { '$nin' => [ map { NMISNG::DB::make_oid($_) } (@$active_ids) ] };
	}
	else
	{
		$q->{'data.index'} = {'$nin' => $active_indices};
	}

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

	# if we have a list of active anythings, unset historic on them
	if( $active_indices  or $active_ids)
	{
		# invert the selection
		if ($active_ids)
		{
			# cheaper than rerunning the potential oid making
			$q->{_id}->{'$in'} = $q->{_id}->{'$nin'};
			delete $q->{_id}->{'$nin'};
		}
		else
		{
			$q->{'data.index'} = {'$in' => $active_indices};
		}
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
		# and an existing _id must be retained or the is_new logic fails
		$newvalue->{_id} = $self->{_configuration}->{_id};

		# convert true/false to 0/1
		foreach my $no_more_tf (qw(active calls collect ping rancid threshold webserver))
		{
			$newvalue->{$no_more_tf} = NMISNG::Util::getbool($newvalue->{$no_more_tf})
					if (defined($newvalue->{$no_more_tf}));
		}

		# make sure activated.nmis is also set and that it mirrors the old-style active flag
		$newvalue->{activated}->{nmis} = $newvalue->{active};

		# and let's set the defuault polling policy if none was given
		$newvalue->{polling_policy} ||= "default";

		# fill in defaults
		$newvalue = $self->_defaults($newvalue);

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

# remove this node from the db and clean up all leftovers:
# node configuration, inventories, timed data,
# -node and -view files.
# args: keep_rrd (default false)
# returns (success, message) or (0, error)
sub delete
{
	my ($self,%args) = @_;

	my $keeprrd = NMISNG::Util::getbool($args{keep_rrd});

	# not errors but message doesn't hurt
	return (1, "Node already deleted") if ($self->{_deleted});
	return (1, "Node has never been saved, nothing to delete") if ($self->is_new);

	$self->nmisng->log->debug("starting to delete node ".$self->name);

	# get all the inventory objects for this node
	# tell them to delete themselves (and the rrd files)

	# get everything, historic or not - make it instantiatable
	# concept type is unknown/dynamic, so have it ask nmisng
	my $result = $self->get_inventory_model(
		class_name => { 'concept' => \&NMISNG::Inventory::get_inventory_class } );
	if (my $error = $result->error)
	{
		return (0, "Failed to retrieve inventories: $error");
	}

	my $gimme = $result->objects;
	return (0, "Failed to instantiate inventory: $gimme->{error}")
			if (!$gimme->{success});
	for my $invinstance (@{$gimme->{objects}})
	{
		$self->nmisng->log->debug("deleting inventory instance "
															.$invinstance->id
															.", concept ".$invinstance->concept
															.", description \"".$invinstance->description.'"');
		my ($ok, $error) = $invinstance->delete(keep_rrd => $keeprrd);
		return (0, "Failed to delete inventory ".$invinstance->id.": $error")
				if (!$ok);
	}

	# delete all status entries as well
	$result = $self->get_status_model();		
	if (my $error = $result->error)
	{
		return (0, "Failed to retrieve status': $error");
	}

	$gimme = $result->objects;
	return (0, "Failed to instantiate status: $gimme->{error}")
			if (!$gimme->{success});
	for my $instance (@{$gimme->{objects}})
	{
		$self->nmisng->log->debug("deleting status instance ".$instance->id);
		my ($ok, $error) = $instance->delete();
		return (0, "Failed to delete status ".$instance->id.": $error")
				if (!$ok);
	}

	# node and view files, if present - failure is not error-worthy
	for my $goner (map { $self->nmisng->config->{'<nmis_var>'}
											 .lc($self->name)."-$_.json" } ('node','view'))
	{
		next if (!-f $goner);
		$self->nmisng->log->debug("deleting file $goner");
		unlink($goner) if (-f $goner);
	}

	# delete any open events, failure undetectable *sigh* and not error-worthy
	$self->eventsClean("NMISNG::Node"); # fixme9: we don't have any useful caller

 	# finally delete the node record itself
	$result = NMISNG::DB::remove(
		collection => $self->nmisng->nodes_collection,
		query      => NMISNG::DB::get_query( and_part => { _id => $self->{_id} } ),
		just_one   => 1 );
	return (0, "Node config removal failed: $result->{error}") if (!$result->{success});

	$self->nmisng->log->debug("deletion of node ".$self->name." complete");
	$self->{_deleted} = 1;
	return (1,undef);
}

# convenience function to help create an event object
sub event
{
	my ( $self, %args ) = @_;
	$args{node_uuid} = $self->uuid;
	$args{node_name} = $self->name;
	my $event = $self->nmisng->events->event( %args );
	return $event;
}

# convenience function for adding an event to this node
#
sub eventAdd
{
	my ($self, %args) = @_;
	$args{node} = $self;
	return $self->nmisng->events->eventAdd(%args);
}

sub eventDelete
{
	my ($self, %args) = @_;
	my $event = $args{event};
	$event->{node_uuid} = $self->uuid;
	# just make sure this isn't passed in
	delete $event->{node};
	$args{event} = $event;

	return $self->nmisng->events->eventDelete(event => $event);
}

sub eventExist
{
	my ($self, $event, $element) = @_;
	return $self->nmisng->events->eventExist($self,$event,$element);
}

sub eventLoad
{
	my ($self, %args) = @_;
	$args{node_uuid} = $self->uuid;
	return $self->nmisng->events->eventLoad( %args );
}

sub eventLog
{
	my ($self, %args) = @_;
	$args{node_name} = $self->name;
	$args{node_uuid} = $self->uuid;
	return $self->nmisng->events->logEvent(%args);
}

sub eventUpdate
{
	my ($self, %args) = @_;
	my $event = $args{event};
	$event->{node_uuid} = $self->uuid;
	$args{event} = $event;
	return $self->nmisng->events->eventUpdate(%args);
}

sub eventsClean
{
	my ($self, $caller) = @_;
	return $self->nmisng->events->cleanNodeEvents( $self, $caller );
}

# fixme: args should be documented here!
# returns: modeldata object (always, mabe empty - check ->error)
sub get_events_model
{
	my ( $self, %args ) = @_;
	# modify filter to make sure it's getting just events for this node
	$args{filter} //= {};
	$args{filter}->{node_uuid} = $self->uuid;
	return $self->nmisng->events->get_events_model( %args );
}

# get a list of id's for inventory related to this node,
# useful for iterating through all inventory
# filters/arguments:
#  cluster_id,node_uuid,concept
# returns: array ref (may be empty)
sub get_inventory_ids
{
	my ( $self, %args ) = @_;

	# what happens when an error happens here?
	$args{fields_hash} = {'_id' => 1};

	my $result = $self->get_inventory_model(%args);

	if (!$result->error && $result->count)
	{
		return [ map { $_->{_id}->{value} } (@{$result->data()}) ];
	}
	else
	{
		return [];
	}
}

# wrapper around the global inventory model accessor
# which adds in the  current node's uuid and cluster id
# returns: modeldata object (may be empty, do check ->error)
sub get_inventory_model
{
	my ( $self, %args ) = @_;
	$args{cluster_id} = $self->cluster_id;
	$args{node_uuid}  = $self->uuid();

	my $result = $self->nmisng->get_inventory_model(%args);
	return $result;
}

# find all unique values for key from collection and filter provided
# makes sure unique values are for this node
sub get_distinct_values
{
	my ($self, %args) = @_;
	my $collection = $args{collection};
	my $key = $args{key};
	my $filter = $args{filter} // {};

	$filter->{cluster_id} = $self->cluster_id;
	$filter->{node_uuid} = $self->uuid;

	return $self->nmisng->get_distinct_values( collection => $collection, key => $key, filter => $filter );
}

# wrapper around the global status model accessor
# which adds in the  current node's uuid and cluster id
# returns: modeldata object (may be empty, do check ->error)
sub get_status_model
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter} // {};

	$filter->{cluster_id} = $self->cluster_id;
	$filter->{node_uuid} = $self->uuid;
	$args{filter} = $filter;

	my $result = $self->nmisng->get_status_model(%args);
	return $result;
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
# OR (undef,undef) if the inventory doesn't exist but create wasn't specified
sub inventory
{
	my ( $self, %args ) = @_;

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

	# tell get_inventory_model enough to instantiate object later
	my $model_data = $self->nmisng->get_inventory_model(
		class_name => { "concept" => \&NMISNG::Inventory::get_inventory_class },
		sort => { _id => 1 },				# normally just one object -> no cost
		%args);

	if ((my $error = $model_data->error) && !$create)
	{
		return (undef, "failed to get inventory: $error");
	}

	if ( $model_data->count() > 0 )
	{
		my $bestchoice = 0;

		if($model_data->count() > 1)
		{
			# sort above ensures that we return the same 'first' object every time,
			# even in that clash/duplicate case
			$self->nmisng->log->warn("Inventory search returned more than one value, using the first!".Dumper(\%args));

			# HOWEVER, if we can we'll return the first non-historic object
			# as the most useful of all bad choices
			my $rawdata = $model_data->data; # inefficient is fine here
			$bestchoice = List::Util::first { !$rawdata->[$_]->{historic} } (0..$#{$rawdata});
		}

		# instantiate as object, please
		(my $error, $inventory) = $model_data->object($bestchoice // 0);
		return (undef, "instantiation failed: $error") if ($error);
	}
	elsif ($create)
	{
		# concept must be supplied, for now, "leftovers" may end up being a concept,
		$class = NMISNG::Inventory::get_inventory_class( $args{concept} );
		$self->nmisng->log->debug("Creating Inventory for concept: $args{concept}, class:$class");
		$self->nmisng->log->error("Creating Inventory without concept") if ( !$args{concept} );

		$args{nmisng} = $self->nmisng;
		Module::Load::load $class;
		$inventory = $class->new(%args);
	}

	return ($inventory, undef);
}

# get all subconcepts and any dataset found within that subconcept
# returns hash keyed by subconcept which holds hashes { subconcept => $subconcept, datasets => [...], indexed => 0/1 }
# args: - filter, basically any filter that can be put on an inventory can be used
#  enough rope to hang yourself here.  special case arg: subconcepts gets mapped into datasets.subconcepts
sub inventory_datasets_by_subconcept
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter};
	$args{cluster_id} = $self->cluster_id();
	$args{node_uuid}  = $self->uuid();

	if( $filter->{subconcepts} )
	{
		$filter->{'dataset_info.subconcept'} = $filter->{subconcepts};
		delete $filter->{subconcepts};
	}

	my $q = $self->nmisng->get_inventory_model_query( %args );
	my $retval = {};

	# print "q".Dumper($q);
	# query parts that don't look at $datasets could run first if we need optimisation
	my @prepipeline = (
		{ '$unwind' => '$dataset_info' },
		{ '$match' => $q },
		{ '$unwind' => '$dataset_info.datasets' },
		{ '$group' =>
			{ '_id' => { "subconcept" => '$dataset_info.subconcept'},  # group by subconcepts
			'datasets' => { '$addToSet' => '$dataset_info.datasets'}, # accumulate all unique datasets
			'indexed' => { '$max' => '$data.index' }, # if this != null then it's indexed
			# rarely this is needed, if so it shoudl be consistent across all models
			# cbqos so far the only place
			'concept' => { '$first' => '$concept' }
		}}
  );
  my ($entries,$count,$error) = NMISNG::DB::aggregate(
		collection => $self->nmisng->inventory_collection,
		pre_count_pipeline => \@prepipeline, #use either pipe, doesn't matter
		allowtempfiles => 1
	);
	foreach my $entry (@$entries)
	{
		$entry->{indexed} = ( $entry->{indexed} ) ? 1 : 0;
		$entry->{subconcept} = $entry->{_id}{subconcept};
		delete $entry->{_id};
		$retval->{ $entry->{subconcept} } = $entry;

	}
	return ($error) ? $error : $retval;
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

# small r/o accessor for node activation status
# args: none
# returns: 1 if node is configured to be active
sub is_active
{
	my ($self) = @_;

	my $curcfg = $self->configuration;

	# check the new-style 'activated.nmis' flag first, then the old-style 'active' property
	return $curcfg->{activated}->{nmis} if (ref($curcfg->{activated}) eq "HASH"
																					and defined $curcfg->{activated}->{nmis});
	return NMISNG::Util::getbool($curcfg->{active});
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

# return bool (0/1) if node is down in catchall/info section
sub is_nodedown
{
	my ($self) = @_;
	my ($inventory,$error) =  $self->inventory( concept => "catchall" );
	my $info = ($inventory && !$error) ? $inventory->data : {};
	return NMISNG::Util::getbool( $info->{nodedown} );
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

# ro-accessor for node name
# renaming is more complex and requires use of the rename() function
sub name
{
	my ($self) = @_;
	return $self->configuration()->{name};
}

# return nmisng object this node is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
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

# this utility function renames a node and all its files,
# and deletes the node's events (cannot be renamed sensibly)
#
# function doesn't have to do anything about inventories, because
# these are linked by node's uuid which is invariant
# args: new_name, optional originator (for events)
# returns: (success, message) or (0, error message)
sub rename
{
	my ($self, %args) = @_;
	my $newname = $args{new_name};
	my $old = $self->name;

	return (0, "Invalid new_name argument") if (!$newname);

	# note: if sub validate is changed to be stricter wrt node name, then this needs to be changed as well!
	# '/' is one of the few characters that absolutely cannot work as node name (b/c of file and dir names)
	return (0, "new_name argument contains forbidden character '/'") if ($newname =~ m!/!);

	return (1, "new_name same as current, nothing to do")
			if ($newname eq $old);

	my $clash = $self->nmisng->get_nodes_model(name => $newname);
	return (0, "A node named \"$newname\" already exists!")
			if ($clash->count);

	$self->nmisng->log->debug("Starting to rename node $old to new name $newname");
	# find the node's var files and  hardlink them - do not delete anything yet!
	my @todelete;

	my $vardir = $self->nmisng->config->{'<nmis_var>'};
	opendir(D, $vardir) or return(1, "cannot read dir $vardir: $!");
	for my $fn (readdir(D))
	{
		if ($fn =~ /^$old-(node|view)\.(\S+)$/i)
		{
			my ($component,$ext) = ($1,$2);
			my $newfn = lc("$newname-$component.$ext");
			push @todelete, "$vardir/$fn";
			$self->nmisng->log->debug("Renaming/linking var/$fn to $newfn");
			link("$vardir/$fn", "$vardir/$newfn") or
					return(0, "cannot hardlink $fn to $newfn: $!");
		}
	}
	closedir(D);

	# find all the node's inventory instances, tell them to hardlink their rrds
	# get everything, historic or not - make it instantiatable
	# concept type is unknown/dynamic, so have it ask nmisng
	my $result = $self->get_inventory_model(
		class_name => { 'concept' => \&NMISNG::Inventory::get_inventory_class } );
	if (my $error = $result->error)
	{
		return (0, "Failed to retrieve inventories: $error");
	}

	my $gimme = $result->objects;
	return (0, "Failed to instantiate inventory: $gimme->{error}")
			if (!$gimme->{success});
	for my $invinstance (@{$gimme->{objects}})
	{
		$self->nmisng->log->debug("relocating rrds for inventory instance "
															.$invinstance->id
															.", concept ".$invinstance->concept
															.", description \"".$invinstance->description.'"');
		my ($ok, $error, @oktorm) = $invinstance->relocate_storage(current => $old,
																															 new => $newname);
		return (0, "Failed to relocate inventory storage ".$invinstance->id.": $error")
				if (!$ok);
		# informational
		$self->nmisng->log->debug2("relocation reported $error") if ($error);

		# relocate storage returns relative names
		my $dbroot = $self->nmisng->config->{'database_root'};
		push @todelete, map { "$dbroot/$_" } (@oktorm);
	}

	# then update ourself and save
	$self->{_configuration}->{name} = $newname;
	$self->_dirty(1, 'configuration');
	my ($ok, $error) = $self->save;
	return (0, "Failed to save node record: $error") if ($ok <= 0);

	# and finally deal with the no longer required old links
	for my $fn (@todelete)
	{
		next if (!defined $fn);
		my $relfn = File::Spec->abs2rel($fn, $self->nmisng->config->{'<nmis_base>'});
		$self->nmisng->log->debug("Deleting file $relfn, no longer required");
		unlink($fn);
	}

	# now clear all events for old node
	$self->nmisng->log->debug("Removing events for old node");
	$self->eventsClean( $args{originator} ); # fixme9: we don't have any useful caller

	$self->nmisng->log->debug("Successfully renamed node $old to $newname");
	return (1,undef);
}

# Save object to DB if it is dirty
# returns tuple, ($success,$error_message),
# 0 if no saving required
#-1 if node is not valid,
# >0 if all good
#
# TODO: error checking just uses assert right now, we may want
#   a differnent way of doing this
sub save
{
	my ($self) = @_;

	return ( -1, "node is incomplete, not saveable yet" )
			if ($self->is_new && !$self->_dirty);
	return ( 0,  undef )          if ( !$self->_dirty() );

	my ( $valid, $validation_error ) = $self->validate();
	return ( $valid, $validation_error ) if ( $valid <= 0 );

	my $result;
	my $op;

	my $entry = $self->configuration();
	$entry->{overrides} = $self->overrides();

	# make 100% certain we've got the uuid correct
	$entry->{uuid} = $self->uuid;

	# need the time it was last saved
	$entry->{lastupdate} = time;

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
			freeform   => 1,					# we need to replace the whole record
			record     => $entry
				);
		assert( $result->{success}, "Record updated successfully" );

		$self->_dirty( 0, 'configuration' );
		$self->_dirty( 0, 'overrides' );
		$op = 2;
	}
	return ( $result->{success} ) ? ( $op, undef ) : ( -2, $result->{error} );
}


# get the nodes id (which is its UUID)
sub uuid
{
	my ($self) = @_;
	return $self->{uuid};
}

# returns (1,nothing) if the node configuration is valid,
# (negative or 0, explanation) otherwise
sub validate
{
	my ($self) = @_;
	my $configuration = $self->configuration();

	return (-2, "node requires cluster_id") if ( !$configuration->{cluster_id} );
	for my $musthave (qw(name host group))
	{
		return (-1, "node requires $musthave property") if (!$configuration->{$musthave} ); # empty or zero is not ok
	}

	# note: if ths is changed to be stricter, then sub rename needs to be changed as well!
	# '/' is one of the few characters that absolutely cannot work as node name (b/c of file and dir names)
	return (-1, "node name contains forbidden character '/'") if ($configuration->{name} =~ m!/!);

	return (-3, "given netType is not a known type")
			if (!grep($configuration->{netType} eq $_,
								split(/\s*,\s*/, $self->nmisng->config->{nettype_list})));
	return (-3, "given roleType is not a known type")
			if (!grep($configuration->{roleType} eq $_,
								split(/\s*,\s*/, $self->nmisng->config->{roletype_list})));
	return( -3, "threshold must be set to something") if( !defined($configuration->{threshold}) );

	return (1,undef);
}


# this function accesses fping results if conf'd and a/v, or runs a synchronous ping
# args: self, sys (required), time_marker (optional)
# returns: 1 if pingable, 0 otherwise
sub pingable
{
	my ($self, %args) = @_;

	my $S    = $args{sys};
	my $V    = $S->view;      # node view data
	my $RI   = $S->reach;     # reach table

	my $time_marker = $args{time_marker} || time;
	my $catchall_data = $S->inventory(concept => 'catchall')->data_live();

	my ( $ping_min, $ping_avg, $ping_max, $ping_loss, $pingresult, $lastping );

	# preset view of node status - fixme9 get rid of
	$V->{system}{status_value} = 'unknown';
	$V->{system}{status_title} = 'Node Status';
	$V->{system}{status_color} = '#0F0';

	my $nodename = $self->name;
	my $C = $self->nmisng->config;

	if ( NMISNG::Util::getbool($self->configuration->{ping}))
	{
		# use fastping info if available and not stale
		my $mustping = 1;
		my $staleafter = $C->{fastping_maxage} || 900; # no fping updates in 15min -> ignore
		my $PT = NMISNG::Util::loadTable(dir=>'var',name=>'nmis-fping'); # cached until mtime changes

		if (ref($PT) eq "HASH")										 # any data available?
		{
			# for multihomed nodes there are two records to check, keyed uuid:N
			my $uuid = $self->uuid;
			my @tocheck = (defined $self->configuration->{host_backup}?
										 grep($_ =~ /^$uuid:\d$/, keys %$PT) : $uuid);
			for my $onekey (@tocheck)
			{
				if (ref($PT->{$onekey}) eq "HASH"
						&& (time - $PT->{$onekey}->{lastping}) < $staleafter)
				{
					# copy the fastping data...
					($ping_min, $ping_avg, $ping_max, $ping_loss, $lastping) = @{$PT->{$onekey}}{"min","avg","max","loss","lastping"};
					$pingresult = ( $ping_loss < 100 ) ? 100 : 0;
					$self->nmisng->log->debug2("$uuid ($nodename = $PT->{$onekey}->{ip}) PINGability min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
					# ...but also try the fallback if the primary is unreachable
					last if ($pingresult);
				}
			}
			$mustping = !defined($pingresult); # nothing or nothing fresh found?
		}

		# fallback to synchronous/internal pinging
		if ($mustping)
		{
			# and warn about that, if not in type=update
			$self->nmisng->log->info("($nodename) using internal ping system, no or oudated fping information")
					if (!NMISNG::Util::getbool($S->{update})); # fixme: unclean access to internal property

			my $retries = $C->{ping_retries} ? $C->{ping_retries} : 3;
			my $timeout = $C->{ping_timeout} ? $C->{ping_timeout} : 300;
			my $packet  = $C->{ping_packet}  ? $C->{ping_packet}  : 56;
			my $host = $self->configuration->{host};          # ip name/adress of node

			$self->nmisng->log->debug("Starting internal ping of ($nodename = $host) with timeout=$timeout retries=$retries packet=$packet");

			( $ping_min, $ping_avg, $ping_max, $ping_loss )
					= NMISNG::Ping::ext_ping( $host, $packet, $retries, $timeout );
			$pingresult = defined $ping_min ? 100 : 0;    # ping_min is undef if unreachable.
			$lastping = Time::HiRes::time;

			if (!$pingresult && (my $fallback = $self->configuration->{host_backup}))
			{
				$self->nmisng->log->info("Starting internal ping of ($nodename = backup address $fallback) with timeout=$timeout retries=$retries packet=$packet");
				( $ping_min, $ping_avg, $ping_max, $ping_loss) = NMISNG::Ping::ext_ping($fallback,
																																								$packet, $retries, $timeout );
				$pingresult = defined $ping_min ? 100 : 0;              # ping_min is undef if unreachable.
				$lastping = Time::HiRes::time;
			}
		}
		# at this point ping_{min,avg,max,loss}, lastping and pingresult are all set

		# in the fping case all up/down events are handled by it, otherwise we need to do that here
		# this includes the case of a faulty fping worker
		if ($mustping)
		{
			if ($pingresult)
			{
				# up
				# are the nodedown status and event db out of sync?
				if ( not NMISNG::Util::getbool( $catchall_data->{nodedown} )
						 and $self->eventExist( "Node Down" ) )
				{
					my $result = Compat::NMIS::checkEvent(
						sys     => $S,
						event   => "Node Down",
						level   => "Normal",
						element => "",
						details => "Ping failed"
							);
					$self->nmisng->log->warn("Fixing Event DB error: $nodename, Event DB says Node Down but nodedown said not.");
				}
				else
				{
					# note: up event is handled regardless of snmpdown/pingonly/snmponly, which the
					# frontend Compat::NMIS::nodeStatus() takes proper care of.
					$self->nmisng->log->debug("$nodename is PINGABLE min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
					$self->handle_down(
						sys     => $S,
						type    => "node",
						up      => 1,
						details => "Ping avg=$ping_avg loss=$ping_loss%"
							);
				}
			}
			else
			{
				# down - log if not already down
				$self->nmisng->log->error("($nodename) ping failed")
						if ( !NMISNG::Util::getbool( $catchall_data->{nodedown} ) );
				$self->handle_down( sys => $S, type => "node", details => "Ping failed" );
			}
		}

		$RI->{pingavg}    = $ping_avg;     # results for sub runReach
		$RI->{pingresult} = $pingresult;
		$RI->{pingloss}   = $ping_loss;

		# a bit of info for web page - fixme9: view is updated
		# only when polling, not by fping -> view info will be slightly stale
		$V->{system}{lastPing_value} = NMISNG::Util::returnDateStamp($lastping);
		$V->{system}{lastPing_title} = 'Last Ping';
	}
	else
	{
		$self->nmisng->log->debug("($nodename) not configured for pinging");
		$RI->{pingresult} = $pingresult = 100;    # results for sub runReach
		$RI->{pingavg}    = 0;
		$RI->{pingloss}   = 0;
	}

	if ($pingresult)
	{
		$V->{system}{status_value} = 'reachable' if ( NMISNG::Util::getbool( $self->configuration->{ping} ) );
		$V->{system}{status_color} = '#0F0';
		$catchall_data->{nodedown}    = 'false';
	}
	else
	{
		$V->{system}{status_value} = 'unreachable';
		$V->{system}{status_color} = 'red';
		$catchall_data->{nodedown}    = 'true';

		# workaround for opCharts not using right data
		$catchall_data->{nodestatus} = 'unreachable';
	}

	$self->nmisng->log->debug("Finished with exit="
														. ( $pingresult ? 1 : 0 )
														. ", nodedown=$catchall_data->{nodedown} nodestatus=$catchall_data->{nodestatus}" );

	return ( $pingresult ? 1 : 0 );
}


# create event for node that has <something> down, or clear said event (and state)
# args: self, sys, type (all required), details (optional),
# up (optional, set to clear event, default is create)
#
# currently understands snmp, wmi, node (=the whole node)
# also updates <something>down flag in node info
#
# returns: nothing
sub handle_down
{
	my ($self, %args) = @_;

	my ($S, $typeofdown, $details, $goingup) = @args{"sys", "type", "details", "up"};
	return if ( ref($S) ne "NMISNG::Sys" or $typeofdown !~ /^(snmp|wmi|node)$/ );
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	$goingup = NMISNG::Util::getbool($goingup);

	my %eventnames = (
		'snmp' => "SNMP Down",
		'wmi'  => "WMI Down",
		'node' => "Node Down"
	);
	my $eventname = $eventnames{$typeofdown};
	$details ||= "$typeofdown error";

	my $eventfunc = ( $goingup ? \&Compat::NMIS::checkEvent : \&Compat::NMIS::notify );
	&$eventfunc(
		sys     => $S,
		event   => $eventname,
		element => '',
		details => $details,
		level   => ( $goingup ? 'Normal' : undef ),
		context => {type => "node"},
		inventory_id => $S->inventory( concept => 'catchall' )
	);

	$catchall_data->{"${typeofdown}down"} = $goingup ? 'false' : 'true';

	return;
}

# sysUpTime under nodeinfo is a mess: not only is nmis overwriting it with
# in nonreversible format on the go,
# it's also used by and scribbled over in various places, and needs synthesizing
# from two separate properties in case of a wmi-only node.
#
# args: self
# returns: nothing, but attempts to bake sysUpTime and sysUpTimeSec catchall properties
# from whatever sys' nodeinfo structure contains.
sub makesysuptime
{
	my ($self) = @_;

	my ($inv,$error) = $self->inventory( concept => 'catchall' );
	return if (!$inv or $error);
	my $catchall_data = $inv->data_live();
	return if ( !$catchall_data );

	# if this is wmi, we need to make a sysuptime first. these are seconds
	# who should own sysUpTime, this needs to only happen if SNMP not available OMK-3223
	#if ($catchall_data->{wintime} && $catchall_data->{winboottime})
	#{
	#	$catchall_data->{sysUpTime} = 100 * ($catchall_data->{wintime}-$catchall_data->{winboottime});
	#}

	# pre-mangling it's a number, maybe fractional, in 1/100s ticks
	# post-manging it is text, and we can't do a damn thing anymore
	if ( defined( $catchall_data->{sysUpTime} ) && $catchall_data->{sysUpTime} =~ /^\d+(\.\d*)?$/ )
	{
		$catchall_data->{sysUpTimeSec} = int( $catchall_data->{sysUpTime} / 100 );              # save away
		$catchall_data->{sysUpTime}    = NMISNG::Util::convUpTime( $catchall_data->{sysUpTimeSec} );    # seconds into text
	}
	return;
}


# gets node info by snmp/wmi, run during update type operations
# also determines node model if it can
#
# args: self, sys
# returns: hashref, keys success (1 if _something_ worked,, 0 if all a/v collection mechanisms failed),
# error (arrayref of error messages, may be present even if success is 1)
#
# attention: this deletes the interface info if other steps successful
# attention: this function disables all sys' sources that indicate any errors on loadnodeNMISNG::Util::info()!
#
# fixme: this thing is an utter mess logic-wise and urgently needs a rewrite
sub update_node_info
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $RI   = $S->reach;          # reach table
	my $V    = $S->view;           # web view
	my $M    = $S->mdl;            # model table
	my $SNMP = $S->snmp;           # snmp object
	my $C    = $self->nmisng->config;

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	$RI->{snmpresult} = $RI->{wmiresult} = 0;

	my ($success, @problems);

	NMISNG::Util::info("Starting");

	# fixme: unclean access to internal property,
	# fixme also fails if we've switched to updating this node on the go!
	if ( NMISNG::Util::getbool( $S->{update} )
		and !NMISNG::Util::getbool( $self->configuration->{collect} ) )    # rebuild
	{
		delete $V->{interface};
	}

	my $oldstate = $S->status;                    # what did we start with for snmp_enabled, wmi_enabled?
	my $curstate;

	# if collect is off, only nodeconf overrides are loaded
	if ( NMISNG::Util::getbool( $self->configuration->{collect} ) )
	{
		# get basic node info by snmp or wmi: sysDescr, sysObjectID, sysUpTime etc

		# this is normally with the DEFAULT model from Model.nmis
		# fixme: not true if switched to update op on the go!
		my $firstloadok = $S->loadNodeInfo();

		# source that hasn't worked? disable immediately
		$curstate = $S->status;
		for my $source (qw(snmp wmi))
		{
			if ( $curstate->{"${source}_error"} )
			{
				$S->disable_source($source);

				# copy over the error so that we can figure out that this source is indeed down,
				# not just disabled from the get-go
				$oldstate->{"${source}_error"} = $curstate->{"${source}_error"};

				push @problems, $curstate->{"${source}_error"};
			}
		}

		if ($firstloadok)
		{
			# snmp: continue processing if at least a couple of entries are valid.
			if ( $catchall_data->{sysDescr} and $catchall_data->{sysObjectID} )
			{
				my $enterpriseTable = Compat::NMIS::loadEnterpriseTable();

				# if the vendors product oid file is loaded, this will give product name.
				$catchall_data->{sysObjectName} = NMISNG::MIB::oid2name( $catchall_data->{sysObjectID} );

				NMISNG::Util::info("sysObjectId=$catchall_data->{sysObjectID}, sysObjectName=$catchall_data->{sysObjectName}");
				NMISNG::Util::info("sysDescr=$catchall_data->{sysDescr}");

				# Decide on vendor name.
				my @x = split( /\./, $catchall_data->{sysObjectID} );
				my $i = $x[6];

				# Special handling for devices with bad sysObjectID, e.g. Trango
				if ( not $i )
				{
					$i = $catchall_data->{sysObjectID};
				}

				if ( $enterpriseTable->{$i}{Enterprise} ne "" )
				{
					$catchall_data->{nodeVendor} = $enterpriseTable->{$i}{Enterprise};
				}
				else
				{
					$catchall_data->{nodeVendor} = "Universal";
				}
				NMISNG::Util::dbg("oid index $i, Vendor is $catchall_data->{nodeVendor}");
			}

			# iff snmp is a dud, look at some wmi properties
			elsif ( $catchall_data->{winbuild} && $catchall_data->{winosname} && $catchall_data->{winversion} )
			{
				NMISNG::Util::info("winosname=$catchall_data->{winosname} winversion=$catchall_data->{winversion}");

				# synthesize something compatible with what win boxes spit out via snmp:
				# i'm too lazy to also wmi-poll Manufacturer and strip off the 'corporation'
				$catchall_data->{nodeVendor} = "Microsoft";

				# the winosname is not the same/enough
				$catchall_data->{sysDescr}
					= $catchall_data->{winosname} . " Windows Version " . $catchall_data->{winversion};
				$catchall_data->{sysName} = $catchall_data->{winsysname};
			}

			# but if neither worked, do not continue processing anything model-related!
			if ( $catchall_data->{sysDescr} or !$catchall_data->{nodeVendor} )
			{
				# fixme: the auto-model decision should be made FIRST, before doing any loadNMISNG::Util::info(),
				# this function's logic needs a complete rewrite
				if ( $self->configuration->{model} eq 'automatic' || $self->configuration->{model} eq "" )
				{
					# get nodeModel based on nodeVendor and sysDescr (real or synthetic)
					$catchall_data->{nodeModel} = $S->selectNodeModel();    # select and save name in node info table
					NMISNG::Util::info("selectNodeModel returned model=$catchall_data->{nodeModel}");

					$catchall_data->{nodeModel} ||= 'Default';              # fixme why default and not generic?
				}
				else
				{
					$catchall_data->{nodeModel} = $self->configuration->{model};
					NMISNG::Util::info("node model=$catchall_data->{nodeModel} set by node config");
				}

				NMISNG::Util::dbg("about to loadModel model=$catchall_data->{nodeModel}");
				$S->loadModel( model => "Model-$catchall_data->{nodeModel}" );

				# now we know more about the host, nodetype and model have been positively determined,
				# so we'll force-overwrite those values
				$S->copyModelCfgInfo( type => 'overwrite' );

				# add web page info
				delete $V->{system} if NMISNG::Util::getbool( $S->{update} );    # rebuild; fixme unclean access to internal property

				$V->{system}{status_value}  = 'reachable';
				$V->{system}{status_title}  = 'Node Status';
				$V->{system}{status_color}  = '#0F0';
				$V->{system}{sysName_value} = $catchall_data->{sysName};
				$V->{system}{sysName_title} = 'System Name';

				$V->{system}{sysObjectName_value}   = $catchall_data->{sysObjectName};
				$V->{system}{sysObjectName_title}   = 'Object Name';
				$V->{system}{nodeVendor_value}      = $catchall_data->{nodeVendor};
				$V->{system}{nodeVendor_title}      = 'Vendor';
				$V->{system}{group_value}           = $catchall_data->{group};
				$V->{system}{group_title}           = 'Group';
				$V->{system}{customer_value}        = $catchall_data->{customer};
				$V->{system}{customer_title}        = 'Customer';
				$V->{system}{location_value}        = $catchall_data->{location};
				$V->{system}{location_title}        = 'Location';
				$V->{system}{businessService_value} = $catchall_data->{businessService};
				$V->{system}{businessService_title} = 'Business Service';
				$V->{system}{serviceStatus_value}   = $catchall_data->{serviceStatus};
				$V->{system}{serviceStatus_title}   = 'Service Status';
				$V->{system}{notes_value}           = $catchall_data->{notes};
				$V->{system}{notes_title}           = 'Notes';

				# make sure any required data from network_viewNode_field_list gets added.
				my @viewNodeFields = split( ",", $C->{network_viewNode_field_list} );
				foreach my $field (@viewNodeFields)
				{
					if ( defined $catchall_data->{$field}
						and
						( not defined $V->{system}{"${field}_value"} or not defined $V->{system}{"${field}_title"} ) )
					{
						$V->{system}{"${field}_title"} = $field;
						$V->{system}{"${field}_value"} = $catchall_data->{$field};
					}
				}

				# update node info table a second time, but now with the actually desired model
				# fixme: see logic problem above, should not have to do both
				my $secondloadok = $S->loadNodeInfo();

				# source that hasn't worked? disable immediately
				$curstate = $S->status;
				for my $source (qw(snmp wmi))
				{
					if ( $curstate->{"${source}_error"} )
					{
						$S->disable_source($source);
						push @problems, $curstate->{"${source}_error"};
					}
				}

				if ($secondloadok)
				{
					# sysuptime is only a/v if snmp, with wmi we have synthesize it as wintime-winboottime
					# it's also mangled on the go
					$self->makesysuptime;
					$V->{system}{sysUpTime_value} = $catchall_data->{sysUpTime};

					# fixme9 cannot work!
					$catchall_data->{server} = $C->{server_name};

					# pull / from VPN3002 system descr
					$catchall_data->{sysDescr} =~ s/\// /g;

					# collect DNS location info.
					$self->get_dns_location;

					# PIX failover test
					$self->checkPIX( sys => $S );

					$success = 1;    # done
				}
				else
				{
					NMISNG::Util::logMsg("ERROR loadNodeInfo with specific model failed!");
					# fixme9: why is this not terminal?
				}
			}
			else
			{
				NMISNG::Util::info("ERROR could retrieve sysDescr or winosname, cannot determine model!");
			}
		}
		else                      # fixme unclear why this reaction to failed getnodeinfo?
		{
			# load the model prev found
			$S->loadModel( model => "Model-$catchall_data->{nodeModel}" )
					if ( $catchall_data->{nodeModel} ne '' );
		}
	}
	else
	{
		NMISNG::Util::dbg("node $S->{name} is marked collect is 'false'");
		$success = 1;                # done
	}

	# get and apply any nodeconf override if such exists for this node
	my $overrides = $self->overrides // {};
	if ( $overrides->{sysLocation} )
	{
		$catchall_data->{sysLocation} = $V->{system}{sysLocation_value} = $overrides->{sysLocation};
		NMISNG::Util::info("Manual update of sysLocation by nodeConf");
	}

	if ( $overrides->{sysContact} )
	{
		$catchall_data->{sysContact} = $V->{system}{sysContact_value} = $overrides->{sysContact};
		NMISNG::Util::dbg("Manual update of sysContact by nodeConf");
	}

	if ( $overrides->{nodeType} )
	{
		$catchall_data->{nodeType} = $overrides->{nodeType};
	}
	else
	{
		delete $catchall_data->{nodeType};
	}

	# process the overall results, set node states etc.
	for my $source (qw(snmp wmi))
	{
		# $curstate should be state as of last loadNMISNG::Util::info() op

		# we can call a source ok iff we started with it enabled, still enabled,
		# and the (second) loadnodeinfo didn't turn up any trouble for this source
		if (   $oldstate->{"${source}_enabled"}
			&& $curstate->{"${source}_enabled"}
			&& !$curstate->{"${source}_error"} )
		{
			$RI->{"${source}result"} = 100;
			my $sourcename = uc($source);

			# happy, clear previous source down flag and event (if any)
			$self->handle_down( sys => $S, type => $source, up => 1, details => "$sourcename ok" );
		}

		# or fire down event if it was enabled but didn't work
		# ie. if it's no longer enabled and has an error saved in oldstate or a new one
		elsif ($oldstate->{"${source}_enabled"}
			&& !$curstate->{"${source}_enabled"}
			&& ( $oldstate->{"${source}_error"} || $curstate->{"${source}_error"} ) )
		{
			$self->handle_down(
				sys     => $S,
				type    => $source,
				details => $curstate->{"${source}_error"} || $oldstate->{"${source}_error"}
			);
		}
	}

	if ($success)
	{
		# add web page info
		$V->{system}{timezone_value}  = $catchall_data->{timezone};
		$V->{system}{timezone_title}  = 'Time Zone';
		$V->{system}{nodeModel_value} = $catchall_data->{nodeModel};
		$V->{system}{nodeModel_title} = 'Model';
		$V->{system}{nodeType_value}  = $catchall_data->{nodeType};
		$V->{system}{nodeType_title}  = 'Type';
		$V->{system}{roleType_value}  = $catchall_data->{roleType};
		$V->{system}{roleType_title}  = 'Role';
		$V->{system}{netType_value}   = $catchall_data->{netType};
		$V->{system}{netType_title}   = 'Net';

		# get the current ip address if the host property was a name, ditto host_backup
		for (["host","host_addr","IP Address"], ["host_backup", "host_addr_backup", "Backup IP Address"])
		{
			my ($sourceprop, $targetprop, $title) = @$_;
			$V->{system}->{"${targetprop}_title"} = $title;

			my $sourceval = $self->configuration->{$sourceprop};
			if ($sourceval && (my $addr = NMISNG::Util::resolveDNStoAddr($sourceval)))
			{
				$catchall_data->{$targetprop} = $V->{system}{"${targetprop}_value"} = $addr; # cache and display
				$V->{system}{"${targetprop}_value"} .= " ($sourceval)" if ($addr ne $sourceval);
			}
			else
			{
				$catchall_data->{$targetprop} = '';
				$V->{system}{"${targetprop}_value"} = $sourceval; # ...but give network.pl something to show
			}
		}
	}
	else
	{
		# node status info web page
		$V->{system}{status_title} = 'Node Status';
		if ( NMISNG::Util::getbool( $self->configuration->{ping} ) )
		{
			$V->{system}{status_value} = 'degraded';
			$V->{system}{status_color} = '#FFFF00';
		}
		else
		{
			$V->{system}{status_value} = 'unreachable';
			$V->{system}{status_color} = 'red';
		}
	}

	NMISNG::Util::info( "Finished "
			. join( " ", map { "$_=" . $catchall_data->{$_} } (qw(nodedown snmpdown wmidown)) ) );

	return { success => $success, error => \@problems };
}

# collect and updates the node info and node view structures, during collect type operation
# this is run ONLY for collect, and if runping succeeded, and if the node is marked for collect
# fixme: what good is this as a function? details are lost, exit 1/0 is not really enough
#
# args: sys, time_marker (optional, default: now)
# returns: (1 if node is up, and at least one source worked for retrieval; 0 if node is down/to be skipped etc.
sub collect_node_info
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $V    = $S->view;
	my $RI   = $S->reach;
	my $M    = $S->mdl;

	my $time_marker = $args{time_marker} || time;

	my $result;
	my $exit = 1;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $nodename = $self->name;

	NMISNG::Util::info("Starting Collect Node Info, node $nodename");

	# clear any node reset indication from the last run
  delete $catchall_data->{admin}->{node_was_reset};

	# save what we need now for check of this node
	my $sysObjectID  = $catchall_data->{sysObjectID};
	my $ifNumber     = $catchall_data->{ifNumber};
	my $sysUpTimeSec = $catchall_data->{sysUpTimeSec};
	my $sysUpTime    = $catchall_data->{sysUpTime};

	# this returns 0 iff none of the possible/configured sources worked, sets details
	my $loadsuccess = $S->loadInfo( class => 'system',
																	# fixme9 gone model => $model,
																	target => $catchall_data );

	# polling policy needs saving regardless of success/failure
	$catchall_data->{last_polling_policy} = $self->configuration->{polling_policy} || 'default';

	# handle dead sources, raise appropriate events
	my $curstate = $S->status;
	for my $source (qw(snmp wmi))
	{
		if ($curstate->{"${source}_enabled"})
		{
			# ok if enabled and no errors
			if (!$curstate->{"${source}_error"} )
			{
				my $sourcename = uc($source);
				$RI->{"${source}result"} = 100;
				$self->handle_down(sys => $S, type => $source, up => 1, details => "$sourcename ok" );

				# record a _successful_ collect for the different sources,
				# the collect now-or-later logic needs that, not just attempted at time x
				$catchall_data->{"last_poll_$source"} = $time_marker;
			}
			else
			{
				$self->handle_down( sys => $S, type => $source, details => $curstate->{"${source}_error"} );
				$RI->{"${source}result"} = 0;
			}
		}
		# we don't care about nonenabled sources, sys won't touch them nor set errors, RI stays whatever it was
	}

	if ($loadsuccess)
	{
		# do some checks, and perform only an update-type op if they don't work out
		# however, ensure this is not attempted if snmp wasn't configured or didn't work anyway
		if (   $S->status->{snmp_enabled}
			&& !$S->status->{snmp_error}
			&& $sysObjectID ne $catchall_data->{sysObjectID} )
		{
			# fixme9: why not a complete update()?
			NMISNG::Util::logMsg("INFO ($nodename) Device type/model changed $sysObjectID now $catchall_data->{sysObjectID}");
			my $result = $self->update_node_info( sys => $S );

			# fixme9: errors must be passed back to caller!
			return 1 if ($result->{success});
			$self->nmisng->log->error("update_node_info failed: ".join(" ",$result->{error}))
					if (ref($result->{error}) eq "ARRAY" && @{$result->{error}});
		}

		# if ifNumber has changed, then likely an interface has been added or removed.

		# a new control to minimise when interfaces are added,
		# if disabled {custom}{interface}{ifNumber} eq "false" then don't run update_intf_info when intf changes
		my $doIfNumberCheck = (
			exists( $S->{mdl}->{custom} ) && exists( $S->{mdl}->{custom}->{interface} )    # do not autovivify
			&& !NMISNG::Util::getbool( $S->{mdl}->{custom}->{interface}->{ifNumber} )
				);

		if ( $doIfNumberCheck and $ifNumber != $catchall_data->{ifNumber} )
		{
			NMISNG::Util::logMsg(
				"INFO ($nodename) Number of interfaces changed from $ifNumber now $catchall_data->{ifNumber}");
			$self->update_intf_info( sys => $S );  # get new interface table
		}

		my $interface_max_number = $self->nmisng->config->{interface_max_number} || 5000;
		if ( $ifNumber > $interface_max_number )
		{
			NMISNG::Util::info(
				"INFO ($catchall_data->{name}) has $ifNumber interfaces, no interface data will be collected, to collect interface data increase the configured interface_max_number $interface_max_number, we recommend to test thoroughly"
			);
		}

		# make a sysuptime from the newly loaded data for testing
		$self->makesysuptime;
		if ( defined $catchall_data->{snmpUpTime} )
		{
			# add processing for SNMP Uptime- handle just like sysUpTime
			$catchall_data->{snmpUpTimeSec}   = int( $catchall_data->{snmpUpTime} / 100 );
			$catchall_data->{snmpUpTime}      = NMISNG::Util::convUpTime( $catchall_data->{snmpUpTimeSec} );
			$V->{system}{snmpUpTime_value} = $catchall_data->{snmpUpTime};
			$V->{system}{snmpUpTime_title} = 'SNMP Uptime';
		}

		NMISNG::Util::info("sysUpTime: Old=$sysUpTime New=$catchall_data->{sysUpTime}");
		if ( $catchall_data->{sysUpTimeSec} && $sysUpTimeSec > $catchall_data->{sysUpTimeSec} )
		{
			NMISNG::Util::info("NODE RESET: Old sysUpTime=$sysUpTimeSec New sysUpTime=$catchall_data->{sysUpTimeSec}");
			Compat::NMIS::notify(
				sys     => $S,
				event   => "Node Reset",
				element => "",
				details => "Old_sysUpTime=$sysUpTime New_sysUpTime=$catchall_data->{sysUpTime}",
				context => {type => "node"}
			);

			# now stash this info in the catchall object, to ensure we insert ONE set of U's into the rrds
			# so that no spikes appear in the graphs
			$catchall_data->{admin}->{node_was_reset}=1;
		}

		$V->{system}{sysUpTime_value} = $catchall_data->{sysUpTime};
		$V->{system}{sysUpTime_title} = 'Uptime';

		# that's actually critical for other functions down the track
		$catchall_data->{last_poll}   = $time_marker;
		delete $catchall_data->{lastCollectPoll}; # replaced by last_poll

		# get and apply any nodeconf override if such exists for this node
		my $overrides = $self->overrides // {};

		# anything to override?
		if ( $overrides->{sysLocation} )
		{
			$catchall_data->{sysLocation} = $V->{system}{sysLocation_value} = $overrides->{sysLocation};
			NMISNG::Util::info("Manual update of sysLocation by nodeConf");
		}
		if ( $overrides->{sysContact} )
		{
			$catchall_data->{sysContact} = $V->{system}{sysContact_value} = $overrides->{sysContact};
			NMISNG::Util::info("Manual update of sysContact by nodeConf");
		}

		if ( exists($overrides->{nodeType}) )
		{
			$catchall_data->{nodeType} = $overrides->{nodeType};
		}

		$self->checkPIX(sys => $S);    # check firewall if needed

		$V->{system}{status_value} = 'reachable';    # sort-of, at least one source worked
		$V->{system}{status_color} = '#0F0';

		# conditional on model section to ensure backwards compatibility with different Juniper values.
		$self->handle_configuration_changes(sys => $S)
				if ( exists( $M->{system}{sys}{nodeConfiguration} )
						 or exists( $M->{system}{sys}{juniperConfiguration} ) );
	}
	else
	{
		$exit = 0;

		if ( $self->configuration->{ping} )
		{
			# ping was ok but wmi and snmp were not
			$V->{system}{status_value} = 'degraded';
			$V->{system}{status_color} = '#FFFF00';
		}
		else
		{
			# ping was disabled, so sources wmi/snmp are the only thing that tells us about reachability
			# note: ping disabled != runping failed
			$V->{system}{status_value} = 'unreachable';
			$V->{system}{status_color} = 'red';
		}
	}

	NMISNG::Util::info("Finished with exit=$exit");
	return $exit;
}

# collect node data values by snmp/wmi, store in RRD (and some values in reach table)
# also causes alert processing
#
# args: sys
# returns: 1 if all successful, 0 if everything failed
sub collect_node_data
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $inventory = $S->inventory( concept => 'catchall' );
	my $catchall_data = $inventory->data_live();

	NMISNG::Util::info("Starting Node get data, node $S->{name}");

	my $rrdData    = $S->getData( class => 'system',
																# fixme9 gone model => $model
			);
	my $howdiditgo = $S->status;
	my $anyerror   = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

	if ( !$anyerror )
	{
		my $previous_pit = $inventory->get_newest_timed_data();

		$self->process_alerts( sys => $S );
		foreach my $sect ( keys %{$rrdData} )
		{
			my $D = $rrdData->{$sect};
			# massage some nodehealth values
			if ($sect eq "nodehealth")
			{
				# take care of negative values from 6509 MSCF
				if ( exists $D->{bufferElHit} and $D->{bufferElHit}{value} < 0 )
				{
					$D->{bufferElHit}{value} = sprintf( "%u", $D->{bufferElHit}{value} );
				}

				### 2012-12-13 keiths, fixed this so it would assign!
				### 2013-04-17 keiths, fixed an autovivification problem!
				if ( exists $D->{avgBusy5} or exists $D->{avgBusy1} )
				{
					$S->reach->{cpu} = ( $D->{avgBusy5}{value} ne "" ) ? $D->{avgBusy5}{value} : $D->{avgBusy1}{value};
				}
				if ( exists $D->{MemoryUsedPROC} )
				{
					$S->reach->{memused} = $D->{MemoryUsedPROC}{value};
				}
				if ( exists $D->{MemoryFreePROC} )
				{
					$S->reach->{memfree} = $D->{MemoryFreePROC}{value};
				}
			}

			foreach my $ds ( keys %{$D} )
			{
				NMISNG::Util::dbg( "rrdData, section=$sect, ds=$ds, value=$D->{$ds}{value}, option=$D->{$ds}{option}", 2 );
			}
			my $db = $S->create_update_rrd( inventory => $inventory, data => $D, type => $sect );
			if ( !$db )
			{
				NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
			}
			else
			{
				my $target = {};
				NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, $sect );
				my $period = $self->nmisng->_threshold_period( subconcept => $sect );
				my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
																										 subconcept => $sect, start => $period, end => time);
				$stats //= {};
				my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $sect,
																								time => $catchall_data->{last_poll}, delay_insert => 1 );
				NMISNG::Util::logMsg("ERROR: timed data adding for ". $inventory->concept ." failed: $error") if ($error);
			}
		}
		# NO save on inventory because it's the catchall right now
	}
	elsif ($howdiditgo->{skipped}) {}
	else
	{
		NMISNG::Util::logMsg("ERROR ($catchall_data->{name}) on getNodeData, $anyerror");
		$self->handle_down( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
			if ( $howdiditgo->{snmp_error} );
		$self->handle_down( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
				if ( $howdiditgo->{wmi_error} );
		return 0;
	}

	NMISNG::Util::info("Finished");
	return 1;
}



# collect the Interface configuration from SNMP, done during update operation
# fixme: this function works ONLY if snmp is enabled for the node!
#
# args: self, sys (required), index - optional ifindex. if present only this interface is updated.
# returns, no index given: 1 if happy, 0 otherwise
# returns, with index given: the inventory object for this interface if happy, undef otherwise
sub update_intf_info
{
	my ($self, %args)     = @_;
	my $S        = $args{sys};      # object
	my $intf_one = $args{index};    # index for single interface update

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	my $C = $self->nmisng->config;

	my $nodename = $self->name;
	if ( !$S->status->{snmp_enabled} )
	{
		NMISNG::Util::info("Not performing update_intf_info for $nodename: SNMP not enabled for this node");
		return undef;                   # no interfaces collected, treat this as error
	}

	my $V    = $S->view;
	my $M    = $S->mdl;             # node model table
	my $SNMP = $S->snmp;

	my $singleInterface = (defined $intf_one and $intf_one ne "");
	my $inventory;
	my $overrides = $self->overrides;

	my $interface_max_number = $C->{interface_max_number} ? $C->{interface_max_number} : 5000;
	my $nocollect_interface_down_days
		= $C->{global_nocollect_interface_down_days} ? $C->{global_nocollect_interface_down_days} : 30;

	my $target_table = {};

	# fixme: hardcoded section name 'standard'
	if ( defined $S->{mdl}{interface}{sys}{standard}
			 and $catchall_data->{ifNumber} <= $interface_max_number )
	{
		# Check if the ifTableLastChange has changed.  If it has not changed, the
		# interface table has had no interfaces added or removed, no need to go any further.
		if ( not $singleInterface
				 and NMISNG::Util::getbool( $S->{mdl}{custom}{interface}{ifTableLastChange} )
				 and my $result = $SNMP->get("ifTableLastChange.0") )
		{
			$result = $result->{"1.3.6.1.2.1.31.1.5.0"};
			if ( defined $result and not defined $catchall_data->{ifTableLastChange} )
			{
				NMISNG::Util::info("$nodename using ifTableLastChange for interface updates");
				$catchall_data->{ifTableLastChange} = $result;
			}
			elsif ( $catchall_data->{ifTableLastChange} != $result )
			{
				NMISNG::Util::info(
					"$nodename ifTableLastChange has changed old=$catchall_data->{ifTableLastChange} new=$result"
				);
				$catchall_data->{ifTableLastChange} = $result;
			}
			else
			{
				NMISNG::Util::info("$nodename ifTableLastChange NO change, skipping ");

				# returning 1 as we can do the rest of the updates.
				return 1;
			}
		}

		# else node may not have this variable so keep on doing in the hard way.

		NMISNG::Util::info("Starting");
		NMISNG::Util::info("Get Interface Info of node $nodename, model $catchall_data->{nodeModel}");

		# load interface types (IANA). number => name
		my $IFT = NMISNG::Util::loadTable(dir => "conf", name => "ifTypes");

		# get interface Index table
		my (@ifIndexNum,  $ifIndexTable, %activeones);

		if ($singleInterface)
		{
			push( @ifIndexNum, $intf_one );
		}
		else
		{
			if ( $ifIndexTable = $SNMP->gettable('ifIndex') )
			{
				foreach my $oid ( Net::SNMP::oid_lex_sort( keys %{$ifIndexTable} ) )
				{
					# to handle stupid devices with ifIndexes which are 64 bit integers
					if ( $ifIndexTable->{$oid} < 0 )
					{
						$ifIndexTable->{$oid} = unpack( "I", pack( "i", $ifIndexTable->{$oid} ) );
					}
					push @ifIndexNum, $ifIndexTable->{$oid};
				}
			}
			else
			{
				if ( $SNMP->error =~ /is empty or does not exist/ )
				{
					NMISNG::Util::info( "SNMP Object Not Present ($nodename) on get interface index table: " . $SNMP->error );
				}

				# snmp failed
				else
				{
					NMISNG::Util::logMsg( "ERROR ($nodename) on get interface index table: " . $SNMP->error );
					$self->handle_down( sys => $S, type => "snmp", details => $SNMP->error );
				}

				NMISNG::Util::info("Finished (snmp failure)");
				return 0;
			}
			delete $V->{interface};    # rebuild interface view table
		}

		# Loop to get interface information; keep the ifIndexs we care about.
		my @ifIndexNumManage;
		foreach my $index (@ifIndexNum)
		{
			next if ( $singleInterface and $intf_one ne $index );    # only one interface

			$target_table->{$index} = {};
			my $target = $target_table->{$index};

			# returns 0 iff there was an snmp or wmi failure
			# however, noSuchInstance is NOT detected!
			if ($S->loadInfo(
					class  => 'interface',
					index  => $index,
					target => $target
				)
				)
			{
				# we were given a removed interface's index -> complain about it and return 0
				if ($target->{ifDescr} eq "noSuchInstance"
						or $target->{ifType} eq "noSuchInstance")
				{
					$self->nmisng->log->error("Cannot retrieve interface $index: snmp reports nonexistent");
					return undef;
				}

				# note: nodeconf overrides are NOT applied at this point!
				$self->checkIntfInfo( sys => $S, index => $index, iftype => $IFT, target => $target );

				my $keepInterface = 1;
				if (    defined $S->{mdl}{custom}{interface}{skipIfType}
					and $S->{mdl}{custom}{interface}{skipIfType} ne ""
					and $target->{ifType} =~ /$S->{mdl}{custom}{interface}{skipIfType}/ )
				{
					$keepInterface = 0;
					NMISNG::Util::info(
						"SKIP Interface ifType matched skipIfType ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType}"
					);
				}
				elsif ( defined $S->{mdl}{custom}{interface}{skipIfDescr}
					and $S->{mdl}{custom}{interface}{skipIfDescr} ne ""
					and $target->{ifDescr} =~ /$S->{mdl}{custom}{interface}{skipIfDescr}/ )
				{
					$keepInterface = 0;
					NMISNG::Util::info(
						"SKIP Interface ifDescr matched skipIfDescr ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType}"
					);
				}

				if ( not $keepInterface )
				{
					# not easy.
					foreach my $key ( keys %$target )
					{
						if ( exists $V->{interface}{"${index}_${key}_title"} )
						{
							delete $V->{interface}{"${index}_${key}_title"};
						}
						if ( exists $V->{interface}{"${index}_${key}_value"} )
						{
							delete $V->{interface}{"${index}_${key}_value"};
						}
					}

					# easy!
					delete $target_table->{$index};
					NMISNG::Util::TODO("Should this info be kept but marked disabled?");
				}
				else
				{
					NMISNG::Util::logMsg("INFO ($nodename) ifadminstatus is empty for index=$index")
						if $target->{ifAdminStatus} eq "";
					NMISNG::Util::info(
						"ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType} ifAdminStatus=$target->{ifAdminStatus} ifOperStatus=$target->{ifOperStatus} ifSpeed=$target->{ifSpeed}"
					);
					push( @ifIndexNumManage, $index );
				}
			}
			else
			{
				# snmp failed
				$self->handle_down( sys => $S, type => "snmp", details => $S->status->{snmp_error} );

				if ( NMISNG::Util::getbool( $C->{snmp_stop_polling_on_error} ) )
				{
					NMISNG::Util::info("Finished (stop polling on error)");
					return 0;
				}
			}
		}

		# copy the new list back.
		@ifIndexNum       = @ifIndexNumManage;
		@ifIndexNumManage = ();

		# port information optional
		if ( $M->{port} ne "" )
		{
			foreach my $index (@ifIndexNum)
			{
				next if ( $singleInterface and $intf_one ne $index );
				my $target = $target_table->{$index};

				# get the VLAN info: table is indexed by port.portnumber
				if ( $target->{ifDescr} =~ /\d{1,2}\/(\d{1,2})$/i )
				{    # FastEthernet0/1
					my $port = '1.' . $1;
					if ( $target->{ifDescr} =~ /(\d{1,2})\/\d{1,2}\/(\d{1,2})$/i )
					{    # FastEthernet1/0/0
						$port = $1 . '.' . $2;
					}
					if ($S->loadInfo(
							class  => 'port',
							index  => $index,
							port   => $port,
							table  => 'interface',
							target => $target
						)
						)
					{
						#
						last if $target->{vlanPortVlan} eq "";    # model does not support CISCO-STACK-MIB
						$V->{interface}{"${index}_portAdminSpeed_value"}
							= NMISNG::Util::convertIfSpeed( $target->{portAdminSpeed} );
						NMISNG::Util::dbg("get VLAN details: index=$index, ifDescr=$target->{ifDescr}");
						NMISNG::Util::dbg("portNumber: $port, VLan: $target->{vlanPortVlan}, AdminSpeed: $target->{portAdminSpeed}" );
					}
				}
				else
				{
					my $port;
					if ( $target->{ifDescr} =~ /(\d{1,2})\D(\d{1,2})$/ )
					{                                                 # 0-0 Catalyst
						$port = $1 . '.' . $2;
					}
					if ($S->loadInfo(
							class  => 'port',
							index  => $index,
							port   => $port,
							table  => 'interface',
							target => $target
						)
						)
					{
						#
						last if $target->{vlanPortVlan} eq "";    # model does not support CISCO-STACK-MIB
						$V->{interface}{"${index}_portAdminSpeed_value"}
							= NMISNG::Util::convertIfSpeed( $target->{portAdminSpeed} );
						NMISNG::Util::dbg("get VLAN details: index=$index, ifDescr=$target->{ifDescr}");
						NMISNG::Util::dbg("portNumber: $port, VLan: $target->{vlanPortVlan}, AdminSpeed: $target->{portAdminSpeed}" );
					}
				}
			}
		}

		if (    $singleInterface
			and defined $S->{mdl}{custom}{interface}{skipIpAddressTableOnSingle}
			and NMISNG::Util::getbool( $S->{mdl}{custom}{interface}{skipIpAddressTableOnSingle} ) )
		{
			NMISNG::Util::info("Skipping Device IP Address Table because skipIpAddressTableOnSingle is false");
		}
		else
		{
			my $ifAdEntTable;
			my $ifMaskTable;
			my %ifCnt;
			NMISNG::Util::info("Getting Device IP Address Table");
			if ( $ifAdEntTable = $SNMP->getindex('ipAdEntIfIndex') )
			{
				if ( $ifMaskTable = $SNMP->getindex('ipAdEntNetMask') )
				{
					foreach my $addr ( keys %{$ifAdEntTable} )
					{
						my $index = $ifAdEntTable->{$addr};
						next if ( $singleInterface and $intf_one ne $index );
						$ifCnt{$index} += 1;
						my $target = $target_table->{$index};
						NMISNG::Util::info("ifIndex=$ifAdEntTable->{$addr}, addr=$addr  mask=$ifMaskTable->{$addr}");
						$target->{"ipAdEntAddr$ifCnt{$index}"}    = $addr;
						$target->{"ipAdEntNetMask$ifCnt{$index}"} = $ifMaskTable->{$addr};

						# NOTE: inventory, breaks index convention here! not a big deal but it happens
						(   $target_table->{$ifAdEntTable->{$addr}}{"ipSubnet$ifCnt{$index}"},
							$target_table->{$ifAdEntTable->{$addr}}{"ipSubnetBits$ifCnt{$index}"}
						) = Compat::IP::ipSubnet( address => $addr, mask => $ifMaskTable->{$addr} );
						$V->{interface}{"$ifAdEntTable->{$addr}_ipAdEntAddr$ifCnt{$index}_title"} = 'IP address / mask';
						$V->{interface}{"$ifAdEntTable->{$addr}_ipAdEntAddr$ifCnt{$index}_value"}
							= "$addr / $ifMaskTable->{$addr}";
					}
				}
				else
				{
					NMISNG::Util::dbg("ERROR getting Device Ip Address table");
				}
			}
			else
			{
				NMISNG::Util::dbg("ERROR getting Device Ip Address table");
			}
		}

		# pre compile regex
		my $qr_no_collect_ifDescr_gen      = qr/($S->{mdl}{interface}{nocollect}{ifDescr})/i;
		my $qr_no_collect_ifType_gen       = qr/($S->{mdl}{interface}{nocollect}{ifType})/i;
		my $qr_no_collect_ifAlias_gen      = qr/($S->{mdl}{interface}{nocollect}{Description})/i;
		my $qr_no_collect_ifOperStatus_gen = qr/($S->{mdl}{interface}{nocollect}{ifOperStatus})/i;

		### 2012-03-14 keiths, collecting override based on interface description.
		my $qr_collect_ifAlias_gen = 0;
		$qr_collect_ifAlias_gen = qr/($S->{mdl}{interface}{collect}{Description})/
			if $S->{mdl}{interface}{collect}{Description};
		my $qr_collect_ifDescr_gen = 0;    # undef would be a match-always regex!
		$qr_collect_ifDescr_gen = qr/($S->{mdl}->{interface}->{collect}->{ifDescr})/i
			if ( $S->{mdl}->{interface}->{collect}->{ifDescr} );

		my $qr_no_event_ifAlias_gen = qr/($S->{mdl}{interface}{noevent}{Description})/i;
		my $qr_no_event_ifDescr_gen = qr/($S->{mdl}{interface}{noevent}{ifDescr})/i;
		my $qr_no_event_ifType_gen  = qr/($S->{mdl}{interface}{noevent}{ifType})/i;

		my $noDescription = $M->{interface}{nocollect}{noDescription};

		### 2013-03-05 keiths, global collect policy override from Config!
		if ( defined $C->{global_nocollect_noDescription} and $C->{global_nocollect_noDescription} ne "" )
		{
			$noDescription = $C->{global_nocollect_noDescription};
			NMISNG::Util::info("INFO Model overriden by Global Config for global_nocollect_noDescription");
		}

		if ( defined $C->{global_collect_Description} and $C->{global_collect_Description} ne "" )
		{
			$qr_collect_ifAlias_gen = qr/($C->{global_collect_Description})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_collect_Description");
		}

		# is collection overridden globally, on or off? (on wins if both are set)
		if ( defined $C->{global_collect_ifDescr} and $C->{global_collect_ifDescr} ne '' )
		{
			$qr_collect_ifDescr_gen = qr/($C->{global_collect_ifDescr})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_collect_ifDescr");
		}
		elsif ( defined $C->{global_nocollect_ifDescr} and $C->{global_nocollect_ifDescr} ne "" )
		{
			$qr_no_collect_ifDescr_gen = qr/($C->{global_nocollect_ifDescr})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_nocollect_ifDescr");
		}

		if ( defined $C->{global_nocollect_Description} and $C->{global_nocollect_Description} ne "" )
		{
			$qr_no_collect_ifAlias_gen = qr/($C->{global_nocollect_Description})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_nocollect_Description");
		}

		if ( defined $C->{global_nocollect_ifType} and $C->{global_nocollect_ifType} ne "" )
		{
			$qr_no_collect_ifType_gen = qr/($C->{global_nocollect_ifType})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_nocollect_ifType");
		}

		if ( defined $C->{global_nocollect_ifOperStatus} and $C->{global_nocollect_ifOperStatus} ne "" )
		{
			$qr_no_collect_ifOperStatus_gen = qr/($C->{global_nocollect_ifOperStatus})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_nocollect_ifOperStatus");
		}

		if ( defined $C->{global_noevent_ifDescr} and $C->{global_noevent_ifDescr} ne "" )
		{
			$qr_no_event_ifDescr_gen = qr/($C->{global_noevent_ifDescr})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_noevent_ifDescr");
		}

		if ( defined $C->{global_noevent_Description} and $C->{global_noevent_Description} ne "" )
		{
			$qr_no_event_ifAlias_gen = qr/($C->{global_noevent_Description})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_noevent_Description");
		}

		if ( defined $C->{global_noevent_ifType} and $C->{global_noevent_ifType} ne "" )
		{
			$qr_no_event_ifType_gen = qr/($C->{global_noevent_ifType})/i;
			NMISNG::Util::info("INFO Model overriden by Global Config for global_noevent_ifType");
		}

		my $intfTotal   = 0;
		my $intfCollect = 0;    # reset counters

		NMISNG::Util::info("Checking interfaces for duplicate ifDescr");
		my $ifDescrIndx;
		foreach my $i (@ifIndexNum)
		{
			my $target = $target_table->{$i};

			# fixme9: this cannot work. interface inventories are STRICTLY identified by ifdescr,
			# which must be unique and correspond to what the device reports.
			# ifdescr massaging like this means the new inventory is instantly lost, cannot be found
			# when collecting interface data

			# ifDescr must always be filled
			$target->{ifDescr} ||= $i;
			# ifDescr is duplicated?
			if ( exists $ifDescrIndx->{$target->{ifDescr}} and $ifDescrIndx->{$target->{ifDescr}} ne "" )
			{
				$target->{ifDescr} .= "-$i";                  # add index to string
				$V->{interface}{"${i}_ifDescr_value"} = $target->{ifDescr};    # update
				NMISNG::Util::info("Interface ifDescr changed to $target->{ifDescr}");
			}
			else
			{
				$ifDescrIndx->{$target->{ifDescr}} = $i;
			}
		}
		NMISNG::Util::info("Completed duplicate ifDescr processing");

		foreach my $index (@ifIndexNum)
		{
			next if ( $singleInterface and $intf_one ne $index );
			my $target = $target_table->{$index};

			my $ifDescr = $target->{ifDescr};
			$intfTotal++;

			# count total number of real interfaces
			if (    $target->{ifType} !~ /$qr_no_collect_ifType_gen/
				and $target->{ifDescr} !~ /$qr_no_collect_ifDescr_gen/ )
			{
				$target->{real} = 'true';
			}

			### add in anything we find from nodeConf - allows manual updating of interface variables
			### warning - will overwrite what we got from the device - be warned !!!
			if ( ref( $overrides->{$ifDescr} ) eq "HASH" )
			{
				my $thisintfover = $overrides->{$ifDescr};

				if ( $thisintfover->{Description} )
				{
					$target->{nc_Description} = $target->{Description};                         # save
					$target->{Description}    = $V->{interface}{"${index}_Description_value"}
						= $thisintfover->{Description};
					NMISNG::Util::info("Manual update of Description by nodeConf");
				}
				if ( $thisintfover->{display_name} )
				{
					$target->{display_name} = $V->{interface}->{"${index}_display_name_value"}
						= $thisintfover->{display_name};
					$V->{interface}->{"${index}_display_name_title"} = "Display Name";

					# no log/diag msg as  this comes ONLY from nodeconf, it's not overriding anything
				}

				for my $speedname (qw(ifSpeed ifSpeedIn ifSpeedOut))
				{
					if ( $thisintfover->{$speedname} )
					{
						$target->{"nc_$speedname"} = $target->{$speedname};    # save
						$target->{$speedname} = $thisintfover->{$speedname};

						### 2012-10-09 keiths, fixing ifSpeed to be shortened when using nodeConf
						$V->{interface}{"${index}_${speedname}_value"} = NMISNG::Util::convertIfSpeed( $target->{$speedname} );
						NMISNG::Util::info("Manual update of $speedname by nodeConf");
					}
				}

				if ( $thisintfover->{setlimits} && $thisintfover->{setlimits} =~ /^(normal|strict|off)$/ )
				{
					$target->{setlimits} = $thisintfover->{setlimits};
				}
			}

			# set default for the speed  limit enforcement
			$target->{setlimits} ||= 'normal';

			# set default for collect, event and threshold: on, possibly overridden later
			$target->{collect}   = "true";
			$target->{event}     = "true";
			$target->{threshold} = "true";
			$target->{nocollect} = "Collecting: Collection Policy";
		  #
		  #Decide if the interface is one that we can do stats on or not based on Description and ifType and AdminStatus
		  # If the interface is admin down no statistics
			### 2012-03-14 keiths, collecting override based on interface description.
			if (    $qr_collect_ifAlias_gen
				and $target->{Description} =~ /$qr_collect_ifAlias_gen/i )
			{
				$target->{collect}   = "true";
				$target->{nocollect} = "Collecting: found $1 in Description";    # reason
			}
			elsif ( $qr_collect_ifDescr_gen
				and $target->{ifDescr} =~ /$qr_collect_ifDescr_gen/i )
			{
				$target->{collect}   = "true";
				$target->{nocollect} = "Collecting: found $1 in ifDescr";
			}
			elsif ( $target->{ifAdminStatus} =~ /down|testing|null/ )
			{
				$target->{collect}   = "false";
				$target->{event}     = "false";
				$target->{nocollect} = "ifAdminStatus eq down|testing|null";     # reason
				$target->{noevent}   = "ifAdminStatus eq down|testing|null";     # reason
			}
			elsif ( $target->{ifDescr} =~ /$qr_no_collect_ifDescr_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in ifDescr";    # reason
			}
			elsif ( $target->{ifType} =~ /$qr_no_collect_ifType_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in ifType";     # reason
			}
			elsif ( $target->{Description} =~ /$qr_no_collect_ifAlias_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in Description";    # reason
			}
			elsif ( $target->{Description} eq "" and $noDescription eq 'true' )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: no Description (ifAlias)";    # reason
			}
			elsif ( $target->{ifOperStatus} =~ /$qr_no_collect_ifOperStatus_gen/i )
			{
				$target->{collect}   = "false";
				$target->{nocollect} = "Not Collecting: found $1 in ifOperStatus";    # reason
			}

			# if the interface has been down for too many days to be in use now.
			elsif ( $target->{ifAdminStatus} =~ /up/
				and $target->{ifOperStatus} =~ /down/
				and ( $catchall_data->{sysUpTimeSec} - $target->{ifLastChangeSec} ) / 86400
				> $nocollect_interface_down_days )
			{
				$target->{collect} = "false";
				$target->{nocollect}
					= "Not Collecting: interface down for more than $nocollect_interface_down_days days";    # reason
			}

			# send events ?
			if ( $target->{Description} =~ /$qr_no_event_ifAlias_gen/i )
			{
				$target->{event}   = "false";
				$target->{noevent} = "found $1 in ifAlias";                                                  # reason
			}
			elsif ( $target->{ifType} =~ /$qr_no_event_ifType_gen/i )
			{
				$target->{event}   = "false";
				$target->{noevent} = "found $1 in ifType";                                                   # reason
			}
			elsif ( $target->{ifDescr} =~ /$qr_no_event_ifDescr_gen/i )
			{
				$target->{event}   = "false";
				$target->{noevent} = "found $1 in ifDescr";                                                  # reason
			}

			# convert interface name
			$target->{interface} = NMISNG::Util::convertIfName( $target->{ifDescr} );
			$target->{ifIndex}   = $index;

			# modify by node Config ?
			if ( ref( $overrides->{$ifDescr} ) eq "HASH" )
			{
				my $thisintfover = $overrides->{$ifDescr};

				if ( $thisintfover->{collect}
						 # fixme9: this is stupid. the override is already keyed by this ifdescr...why copy and check AGAIN?
						 and $thisintfover->{ifDescr} eq $target->{ifDescr} )

				{
					$target->{nc_collect} = $target->{collect};
					$target->{collect}    = $thisintfover->{collect};
					NMISNG::Util::info("Manual update of Collect by nodeConf");

					### 2014-04-28 keiths, fixing info for GUI
					if ( NMISNG::Util::getbool( $target->{collect}, "invert" ) )
					{
						$target->{nocollect} = "Not Collecting: Manual update by nodeConf";
					}
					else
					{
						$target->{nocollect} = "Collecting: Manual update by nodeConf";
					}
				}

				if ( $thisintfover->{event} and $thisintfover->{ifDescr} eq $target->{ifDescr} )
				{
					$target->{nc_event} = $target->{event};
					$target->{event}    = $thisintfover->{event};
					$target->{noevent}  = "Manual update by nodeConf"
						if ( NMISNG::Util::getbool( $target->{event}, "invert" ) );    # reason
					NMISNG::Util::info("Manual update of Event by nodeConf");
				}

				if ( $thisintfover->{threshold} and $thisintfover->{ifDescr} eq $target->{ifDescr} )
				{
					$target->{nc_threshold} = $target->{threshold};
					$target->{threshold}    = $thisintfover->{threshold};
					$target->{nothreshold}  = "Manual update by nodeConf"
						if ( NMISNG::Util::getbool( $target->{threshold}, "invert" ) );    # reason
					NMISNG::Util::info("Manual update of Threshold by nodeConf");
				}
			}

			# number of interfaces collected with collect and event on
			$intfCollect++ if ( NMISNG::Util::getbool( $target->{collect} )
				&& NMISNG::Util::getbool( $target->{event} ) );

			# save values only iff all interfaces are updated
			if (not $singleInterface)
			{
				$catchall_data->{intfTotal}   = $intfTotal;
				$catchall_data->{intfCollect} = $intfCollect;
			}

			# prepare values for web page
			$V->{interface}{"${index}_event_value"} = $target->{event};
			$V->{interface}{"${index}_event_title"} = 'Event on';

			$V->{interface}{"${index}_threshold_value"}
				= !NMISNG::Util::getbool( $self->configuration->{threshold} ) ? 'false' : $target->{threshold};
			$V->{interface}{"${index}_threshold_title"} = 'Threshold on';

			$V->{interface}{"${index}_collect_value"} = $target->{collect};
			$V->{interface}{"${index}_collect_title"} = 'Collect on';

			$V->{interface}{"${index}_nocollect_value"} = $target->{nocollect};
			$V->{interface}{"${index}_nocollect_title"} = 'Reason';

			# collect status
			if ( NMISNG::Util::getbool( $target->{collect} ) )
			{
				NMISNG::Util::info("$target->{ifDescr} ifIndex $index, collect=true");
			}
			else
			{
				NMISNG::Util::info("$target->{ifDescr} ifIndex $index, collect=false, $target->{nocollect}");

				# if  collect is of then disable event and threshold (clearly not applicable)
				$target->{threshold} = $V->{interface}{"${index}_threshold_value"} = 'false';
				$target->{event}     = $V->{interface}{"${index}_event_value"}     = 'false';
			}

			# get color depending of state
			# NMISNG - TODO: trying to get the color from something not in the db, problem, causing warning
			$V->{interface}{"${index}_ifAdminStatus_color"} = Compat::NMIS::getAdminColor( sys => $S, index => $index, data => $target );
			$V->{interface}{"${index}_ifOperStatus_color"} = Compat::NMIS::getOperColor( sys => $S, index => $index, data => $target );

			# index number of interface
			$V->{interface}{"${index}_ifIndex_value"} = $index;
			$V->{interface}{"${index}_ifIndex_title"} = 'ifIndex';

			# at this point every thing is ready for the rrd speed limit enforcement
			my $desiredlimit = $target->{setlimits};

			# write if inventory data now. the speed limit/checking code requires the entries to exist in order
			# to correctly find them in parseString/etc
			#
			# get the inventory object for this, path_keys required as we don't know what type it will be
			# if interface descriptions change for existing interfaces, then we MUST NOT create duplicates
			# so, only the ifdescr may go into the path calculation logic, NOT ifindex
			my $pathdata = Clone::clone($target);
			delete $pathdata->{index};
			my $path = $self->inventory_path( concept => 'interface', data => $pathdata, partial => 1 );
			my $inventory_id;
			if( ref($path) eq 'ARRAY')
			{
				( $inventory, my $error_message ) = $self->inventory(
					concept   => 'interface',
					path      => $path,
					create    => 1
				);
				$self->nmisng->log->error("Failed to create interface inventory, error:$error_message") && next if ( !$inventory );

				$inventory->data( $target );
				# regenerate the path, if this thing wasn't new the path may have changed, which is ok
				# for a new object this must happen AFTER data is set
				$inventory->path( recalculate => 1 );
				$path = $inventory->path; # no longer the same - path was partial, now it no longer is
				$inventory->description( $target->{Description} || $target->{ifDescr} );

				# historic is only set when the index/_id is in the db but not found in the device, we are looping
				# through things found on the device so it's not historic
				$inventory->historic(0);

				# if collect is off then this interface is disabled
				$inventory->enabled(1);
				if ( NMISNG::Util::getbool( $target->{collect}, "invert" ) )
				{
					$inventory->enabled(0);
				}
				# enable interfaces for viewing, no columns, someoneelse can define that
				# disable pkts, for now, no idea
				$inventory->data_info( subconcept => 'interface', enabled => 1 );
				$inventory->data_info( subconcept => 'pkts_hc', enabled => 0 );
				$inventory->data_info( subconcept => 'pkts', enabled => 0 );
				my ( $op, $error ) = $inventory->save();
				NMISNG::Util::info( "saved ".join(',', @{$inventory->path})." op: $op");
				$self->nmisng->log->error( "Failed to save inventory:"
																	 . join( ",", @{$inventory->path} ) . " error:$error" )
						if ($error);

				# mark as nonhistoric so that we can ditch the actually historic ones...
				$activeones{$inventory->id} = 1;
				$inventory_id = $inventory->id;
			}
			else
			{
				$self->nmisng->log->error("Failed to create path for inventory, error:$path");
			}

			# interface now up or down, check and set or clear outstanding event.
			if ( NMISNG::Util::getbool( $target->{collect} )
				and $target->{ifAdminStatus} =~ /up|ok/
				and $target->{ifOperStatus} !~ /up|ok|dormant/ )
			{
				if ( NMISNG::Util::getbool( $target->{event} ) )
				{
					Compat::NMIS::notify(
						sys     => $S,
						event   => "Interface Down",
						element => $target->{ifDescr},
						details => $target->{Description},
						context => {type => "interface"},
						inventory_id => $inventory_id
					);
				}
			}
			else
			{
				Compat::NMIS::checkEvent(
					sys     => $S,
					event   => "Interface Down",
					level   => "Normal",
					element => $target->{ifDescr},
					details => $target->{Description},
					inventory_id => $inventory_id
				);
			}

			# the following don't modify $target so no extra saving required

			# no limit or dud limit or dud speed or non-collected interface?
			if (   $desiredlimit
				&& $desiredlimit =~ /^(normal|strict|off)$/
				&& $target->{ifSpeed}
				&& NMISNG::Util::getbool( $target->{collect} ) )
			{
				NMISNG::Util::info(
					"performing rrd speed limit tuning for $ifDescr, limit enforcement: $desiredlimit, interface speed is "
						. NMISNG::Util::convertIfSpeed( $target->{ifSpeed} )
						. " ($target->{ifSpeed})" );

			# speed is in bits/sec, normal limit: 2*reported speed (in bytes), strict: exactly reported speed (in bytes)
				my $maxbytes
					= $desiredlimit eq "off"    ? "U"
					: $desiredlimit eq "normal" ? int( $target->{ifSpeed} / 4 )
					:                             int( $target->{ifSpeed} / 8 );
				my $maxpkts = $maxbytes eq "U" ? "U" : int( $maxbytes / 50 );    # this is a dodgy heuristic

				for (
					["interface", qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets)/],
					[   "pkts",
						qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/
					],
					[   "pkts_hc",
						qr/(ifInOctets|ifHCInOctets|ifOutOctets|ifHCOutOctets|ifInUcastPkts|ifInNUcastPkts|ifInDiscards|ifInErrors|ifOutUcastPkts|ifOutNUcastPkts|ifOutDiscards|ifOutErrors)/
					],
					)
				{
					my ( $datatype, $dsregex ) = @$_;

					# rrd file exists and readable?
					if ( -r ( my $rrdfile = $S->makeRRDname( graphtype => $datatype,
																									 index => $index,
																									 inventory => $inventory ) ) )
					{
						my $fileinfo = RRDs::info($rrdfile);
						for my $matching ( grep /^ds\[.+\]\.max$/, keys %$fileinfo )
						{
							# only touch relevant and known datasets
							next if ( $matching !~ /($dsregex)/ );
							my $dsname = $1;

							my $curval = $fileinfo->{$matching};
							$curval = "U" if ( !defined $curval or $curval eq "" );

							# the pkts, discards, errors DS are packet based; the octets ones are bytes
							my $desiredval = $dsname =~ /octets/i ? $maxbytes : $maxpkts;

							if ( $curval ne $desiredval )
							{
								NMISNG::Util::info(
									"rrd section $datatype, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit"
								);
								RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
							}
							else
							{
								NMISNG::Util::info("rrd section $datatype, ds $dsname, current limit $curval is correct");
							}
						}
					}
				}
			}
		}

		# if checking more than one intf, mark any unknown interfaces as historic
		# has to happen by inventory id, ifindex can and does change
		if (!$singleInterface)
		{
			my $result = $self->bulk_update_inventory_historic( active_ids => [keys %activeones],
																													concept => 'interface' );
			$self->nmisng->log->error("bulk update historic failed: $result->{error}") if ($result->{error});
			NMISNG::Util::logMsg("$nodename, found intfs alive: $result->{matched_nothistoric}, already historic: $result->{matched_historic}, marked alive: $result->{marked_nothistoric}, marked historic: $result->{marked_historic}");
		}

		NMISNG::Util::info("Finished");
	}
	elsif ( $catchall_data->{ifNumber} > $interface_max_number )
	{
		NMISNG::Util::info("Skipping, interface count $catchall_data->{ifNumber} exceeds configured maximum $interface_max_number");
	}
	else
	{
		NMISNG::Util::info("Skipping, interfaces not defined in Model");
	}

	return ($singleInterface? $inventory: 1);
}

# collect performance data for all known interfaces for this node
# this has to handle mogrifying interfaces, ie. reordered/added/removed/transitioned
#
# fixme: this function currently does not work for wmi-only nodes!
# args: sys, modeldebug (default false)
# returns: 1 if ok
sub collect_intf_data
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $nodename = $self->name;
	# get any nodeconf overrides if such exists for this node
	my $overrides = $self->overrides;

	if ( !$S->status->{snmp_enabled} )
	{
		NMISNG::Util::info("Not performing getIntfData for $nodename: SNMP not enabled for this node");
		return 1;
	}

	NMISNG::Util::info("Starting Interface get data for node $nodename");

	# adminstatus only uses 1..3 , operstatus can have all 1..7.
	my %knownadminstates = ( 1 => 'up',
													 2 => 'down',
													 3 => 'testing',
													 4 => 'unknown',
													 5 => 'dormant',
													 6 => 'notPresent',
													 7 => 'lowerLayerDown' );

	# this is a multi-stage process by necessity:
	# 1. get the inventory information for all interfaces (index->ifdescr and others)
	# 2. collect 'cheap' snmp data and stash it locally (strictly by index)
	# 3. determine which interfaces have shifted indices or have transitioned
	# 	 or been changed/added/removed, and need update_intf_info() done on them
	# 4. do update_intf_info for these to determine their true new nature,
	# 	 and reorganise the inventories accordingly
	# 5. get the non-cheap modelled data for the interfaces that we know are collectable
	# 6. determine interface index vs. ifdescr mismatches, ie. reordered interfaces
	# 	 note: ifdescr is NOT necessarily just the raw snmp ifdescr! must run through getData=model logic!
	# 7. perform stage 4 for any interfaces that have become collectable because of 6.
	#
	# 8. work with the stashed modelleed snmp data, send it to rrd, the inventories etc.
	# 9. mark any leftover present-but-unwanted inventories as historic (by inventory id!)

	# 1. get the interface inventories for this node, but only the bits we need (so far)
	my $result = $self->get_inventory_model(
		'concept' => 'interface',
		fields_hash => {
			'_id' => 1,
			'data.collect' => 1,
			'data.ifAdminStatus' => 1,
			'data.ifOperStatus' => 1,
			'data.ifDescr' => 1,
			'data.ifIndex' => 1,
			'data.ifLastChangeSec' => 1, # ifLastChange is textual and NO GOOD
			'data.real' => 1,
			'enabled' => 1,
			'historic' => 1
		} );
	if (my $error = $result->error)
	{
		$self->nmisng->log->error("get inventory model failed: $error");
		return undef;
	}

	my (%if_data_map, %leftovers);	# leftovers: 1 is presumed dead, 0 is ok

	# create a map of the inventory state,
	# by ifindex so we can look them up easily, clone _id into data to make things easier
	# note that ifdescr is treated as invariant, NOT ifindex.
	# note also: this includes disabled and historic interfaces, too, IFF their ifIndex is nonclashing
	# make sure non-historic ones are tackled before historic stuff!
	for my $maybeevil (sort { $a->{historic} cmp $b->{historic} } @{$result->data()})
	{
		$leftovers{ $maybeevil->{_id} } = 1; # everything goes here, clash or noclash

		my $thisindex = $maybeevil->{data}->{ifIndex};
		if (exists $if_data_map{$thisindex} )
		{
			$self->nmisng->log->warn("clashing inventories for interface index $thisindex!");
			next;
		}

		# move these over into data for simplicity
		for my $thing (qw(_id enabled historic))
		{
			$maybeevil->{data}->{$thing} = $maybeevil->{$thing};
		}
		$if_data_map{ $thisindex } = $maybeevil->{data};
	}

	# 2a. get the ifadminstatus, ifoperstatus and iflastchange tables
	# and add them to our knowledge

	# default for ifAdminStatus-based detection is ON. only off if explicitely set to false.
	my $dontwanna_ifadminstatus = (ref($S->{mdl}->{custom}) eq "HASH"    # don't autovivify
																 and ref($S->{mdl}->{custom}->{interface} ) eq "HASH"
																 # and explicitely set to false
																 and NMISNG::Util::getbool( $S->{mdl}->{custom}->{interface}->{ifAdminStatus}, "invert"));
	if (!$dontwanna_ifadminstatus)
	{
		# fixme: this cannot work for non-snmp nodes
		$self->nmisng->log->info("Using ifAdminStatus and ifOperStatus for Interface Change Detection");

		# want both or we don't care
		my $ifAdminTable = $S->snmp->getindex('ifAdminStatus');
		my $ifOperTable = $S->snmp->getindex('ifOperStatus');
		if ($ifAdminTable && $ifOperTable)
		{
			# index == ifindex
			for my $index ( keys %{$ifAdminTable} )
			{
				# save the textual info; inventory has the same content, but names without _
				$if_data_map{$index}->{_ifAdminStatus} = $knownadminstates{ $ifAdminTable->{$index} };
				$if_data_map{$index}->{_ifOperStatus} =  $knownadminstates{ $ifOperTable->{$index} };
			}
		}
	}
	# default for ifLastChange-based detection is OFF
	if ((ref( $S->{mdl}{custom} ) eq "HASH"
			and ref( $S->{mdl}{custom}{interface} ) eq "HASH"
			and NMISNG::Util::getbool( $S->{mdl}{custom}{interface}{ifLastChange} ) ))
	{
		# fixme: this cannot work for non-snmp node
		NMISNG::Util::info("Using ifLastChange for Interface Change Detection");

		# iflastchange is in 1/100s ticks
		if ( my $ifLastChangeTable = $S->snmp->getindex('ifLastChange') )
		{
			for my $index (keys %$ifLastChangeTable)
			{
				$if_data_map{$index}->{_ifLastChangeSec} = int($ifLastChangeTable->{$index} / 100);
			}
		}
	}

	# 3. who needs updating based on what we know so far?
	for my $index (sort keys %if_data_map)
	{
		my $thisif = $if_data_map{$index};

		# fixme what about not collectable? then _ifAdminStatus isn't a/v....

		# new interface, no inventory yet?
		if (!$thisif->{_id})
		{
			$self->nmisng->log->info("Interface $index is new, needs update");
			$thisif->{_needs_update} = 1;
			next;
		}
		# removed interface? skippy!
		elsif (!exists $thisif->{_ifAdminStatus})
		{
			# we have to track already dead ones (in if_data_map), but we don't work on them
			$self->nmisng->log->info("Interface $index, $thisif->{ifDescr} was removed!")
					if (!$thisif->{historic});

			delete $if_data_map{$index}; # nothing to do except mark it as historic at the end
			next;
		}
		# disabled interface? skippy, too, but mark as nonhistoric
		elsif (defined($thisif->{enabled}) && !$thisif->{enabled}) # ie. don't skip if enabled is unknown
		{
			$leftovers{$thisif->{_id}} = 0; # it's disabled but it's NOT a historic leftover!
			next;
		}

		# admin status changed in a relevant transition?
		my $curstatus = $thisif->{ifAdminStatus};
		my $newstate = $thisif->{_ifAdminStatus};

		NMISNG::Util::logMsg("INFO ($S->{name}) no ifAdminStatus for index=$index currently present")
				if (!defined $curstatus);

		# relevant transition === entering or leaving up state
		if ((defined $newstate and $newstate eq "up")
				xor (defined $curstatus and $curstatus eq "up"))
		{
			$self->nmisng->log->info("Interface $index, admin status changed from $curstatus to $newstate, needs update");
			$thisif->{_needs_update} = 1;
			next;
		}

		# or has ifLastChange changed? not enabled by default, must check if it's been loaded
		if ( defined($thisif->{_ifLastChangeSec}) # we've consulted snmp for it
				 and ( !defined($thisif->{ifLastChangeSec}) # and we had none before
							 or $thisif->{ifLastChangeSec} != $thisif->{_ifLastChangeSec}) ) # or the old value is different
		{
			$self->nmisng->log->info("Interface index $index, needs update because of ifLastChange $thisif->{_ifLastChangeSec}s"
												 . ($thisif->{ifLastChangeSec}? ", was $thisif->{ifLastChangeSec}"
														: ", new interface"));
			$thisif->{_needs_update} = 1;
			# no next, this is the last cheap test
		}
	}

	# 4. perform update_intf_info for the interfaces that need it
	for my $needsmust (grep($if_data_map{$_}->{_needs_update}, keys %if_data_map))
	{
		# all done by index, so far
		my $thisif = $if_data_map{$needsmust};
		$self->nmisng->log->debug("Performing phase 1 update_intf_info for index $needsmust");

		# this returns an inventory object (or undef on error/nonexistent)...
		my $maybenew = $self->update_intf_info( sys => $S, index => $needsmust);
		if (!defined $maybenew)
		{
			$self->nmisng->log->warn("Interface index $needsmust was removed while trying to update");
			delete $if_data_map{$needsmust}; # nothing to do except mark it as historic at the end
			next;
		}
		# ...which MAY be different from the one we've got in the if_data_map
		if (!defined $thisif->{_id} or $maybenew->id ne $thisif->{_id})
		{
			$self->nmisng->log->debug2("Interface index $needsmust "
																 .(defined($thisif->{_id})? "has changed substantially" : "is new")
																 . " and has a new inventory");

			# update the if_data_map. index is the same, contents may differ; must keep relevant stuff!
			$if_data_map{$needsmust} = { %{$maybenew->data},
																	 _id => $maybenew->id,
																	 _was_updated => 1, # mark as 'update_intf_info done'
																	 # if this is a new inventory then it lacks both enabled and historic...
																	 enabled  => $maybenew->{enabled} // 1,
																	 historic => $maybenew->{historic} // 0,
																	 _ifAdminStatus => $maybenew->data->{ifAdminStatus},
																	 _ifOperStatus => $maybenew->data->{ifOperStatus},
			};
		}
		else
		{
			# just mark this interface as updated
			$if_data_map{$needsmust}->{_was_updated} = 1;
			delete $if_data_map{$needsmust}->{_needs_update};
		}
	}

	# 5. collect modelled data for enabled, nonhistoric, collectable interfaces
	# and stash it as we don't necessarily know the final inventory target yet
	NMISNG::Util::info("Collecting Interface Data");
	for my $index (sort grep($if_data_map{$_}->{enabled} && !$if_data_map{$_}->{historic},
													 keys %if_data_map))
	{
		my $thisif = $if_data_map{$index};

		# only collect on interfaces that are defined, with collection turned on globally,
		# also don't bother with ones without ifdescr
		if ( !defined $thisif->{ifDescr}
				 or $thisif->{ifDescr} eq "" ) # note: 0 would be acceptable
		{
			$self->nmisng->log->debug("NOT collecting: ifIndex=$index: no description");
			next;
		}

		# returns undef if no good
		my $rrdData = $S->getData( class => 'interface', index => $index,
				# fixme9: gone											 model => $model
				);
		my $howdiditgo =$thisif->{_rrd_status} = $S->status;

		# any errors?
		if (my $anyerror  = $howdiditgo->{error}
				|| $howdiditgo->{snmp_error}
				|| $howdiditgo->{wmi_error})
		{
			$self->nmisng->log->error("$nodename failed to get interface data for ifIndex=$index: $anyerror");
		}

		# 5a. a certain amount of data massaging is required before we can make use of the rrd data,
		# ie. moving of HC octet counters
		# that's because the 'special handling for manual interface discovery' needs the ifoctet counters...

		# getdata returns a weird structure: section top, then $index underneath
		for my $datasection (keys %$rrdData)
		{
			my $thisone = $rrdData->{$datasection}->{$index};

			# if HC counters exist then MOVE values to the non-HC names
			if (ref($thisone->{ifHCInOctets}) eq "HASH")
			{
				$self->nmisng->log->debug("processing HC counters for index $index");
				for ( ["ifHCInOctets", "ifInOctets"], ["ifHCOutOctets", "ifOutOctets"] )
				{
					my ($source, $dest) = @$_;

					if ( $thisone->{$source}->{value} =~ /^\d+$/ )
					{
						$thisone->{$dest}->{value}  = $thisone->{$source}->{value};
						$thisone->{$dest}->{option} = $thisone->{$source}->{option};
					}
					delete $thisone->{$source};
				}
			}
			# ...and MOVE these over as well
			if ( $datasection eq 'pkts' or $datasection eq 'pkts_hc' )
			{
				my $debugdone = 0;
				for ( ["ifHCInUcastPkts",  "ifInUcastPkts"],
							["ifHCOutUcastPkts", "ifOutUcastPkts"],
							["ifHCInMcastPkts",  "ifInMcastPkts"],
							["ifHCOutMcastPkts", "ifOutMcastPkts"],
							["ifHCInBcastPkts",  "ifInBcastPkts"],
							["ifHCOutBcastPkts", "ifOutBcastPkts"], )
				{
					my ( $source, $dest ) = @$_;

					if ( $thisone->{$source}->{value} =~ /^\d+$/ )
					{
						$self->nmisng->log->debug("process HC counters of $datasection for $index")
								if ( !$debugdone++ );
						$thisone->{$dest}->{value}  = $thisone->{$source}->{value};
						$thisone->{$dest}->{option} = $thisone->{$source}->{option};
					}
					delete $thisone->{$source};
				}
			}
		}

		# stash the data for this index
		$thisif->{_rrd_data} = $rrdData;
	}

	# 6. figure out if any other interfaces need an update, based on the snmp information now available
	# this covers reordered interfaces (interface index is not invariant, ifdescr is treated as invariant)
	# new interfaces should have been handled in 4.
	for my $index (keys %if_data_map)
	{
		my $thisif = $if_data_map{$index};

		next if (!$thisif->{enabled} # we track historic/disabled ones but don't work on them...
						 or $thisif->{historic}
						 or !$thisif->{_rrd_data} # no rrd data collectable -> cannot do anything
						 or ref($thisif->{_rrd_data}->{interface}) ne "HASH"
						 or $thisif->{_was_updated}); # or if the interface was updated already...

		my $intfsection = $thisif->{_rrd_data}->{interface}->{$index};

		my $newifdescr = NMISNG::Util::rmBadChars( $intfsection->{ifDescr}->{value} );
		if ($newifdescr ne $thisif->{ifDescr})
		{
			$self->nmisng->log->info("Interface $index, ifDescr changed from $thisif->{ifDescr} to $newifdescr, needs update");
			$thisif->{_needs_update} = 1;
			next;
		}

		# now check the interface operational status for transition, if there are counters
		# and if the adminstatus check isn't disabled
		if (!$dontwanna_ifadminstatus
				&& $intfsection->{ifInOctets} ne ''
				&& $intfsection->{ifOutOctets} ne '')
		{
			my $prevstatus = $thisif->{ifOperStatus}; # that's inventory
			my $newstatus = $thisif->{_ifOperStatus}; # that's snmp-sourced

			# relevant transition === entering or leaving up state
			if (($newstatus eq 'down' and $prevstatus =~ /^(up|ok)$/)
					or ($newstatus !~ /^(up|ok|dormant)$/))
			{
				$self->nmisng->log->info("Interface $index, oper status changed from $prevstatus to $newstatus, needs update");
				$thisif->{_needs_update} = 1;
			}
		}
	}

	# 7. redo the update_intf_info exercise from 4. for these other interfaces in need of help
	# these 'other' interfaces should not be totally new ones, those should have been covered in 4.
	for my $needsmust (grep($if_data_map{$_}->{_needs_update}, keys %if_data_map))
	{
		# all done by index, so far
		my $thisif = $if_data_map{$needsmust};
		$self->nmisng->log->debug("Performing phase 2 update_intf_info for index $needsmust");

		assert(!$thisif->{_was_updated}, "should update_intf_info() index $needsmust at most once!");

		# this returns an inventory object (or undef if removed/error)...
		my $maybenew = $self->update_intf_info( sys => $S, index => $needsmust);
		if (!defined $maybenew)
		{
			$self->nmisng->log->warn("Interface index $needsmust was removed while trying to update");
			delete $if_data_map{$needsmust}; # nothing to do except mark it as historic at the end
			next;
		}
		# ...which MAY be different from the one we've got in the if_data_map
		if ($maybenew->id ne $thisif->{_id})
		{
			$self->nmisng->log->debug2("Interface index $needsmust has changed substantially and has a new inventory");

			# update the if_data_map. index is the same, contents may differ
			# we must keep the relevant already collected stuff, especially the rrd data!
			$if_data_map{$needsmust} = { %{$maybenew->data},
																	 _id => $maybenew->id,
																	 _was_updated => 1, # mark as 'update_intf_info done'
																	 # a new inventory may be lacking both enabled and historic
																	 enabled  => $maybenew->{enabled} // 1,
																	 historic => $maybenew->{historic} // 0,
																	 #
																	 _ifAdminStatus => $maybenew->data->{ifAdminStatus},
																	 _ifOperStatus => $maybenew->data->{ifOperStatus},
																	 _rrd_data => $thisif->{_rrd_data}, # keep
																	 _rrd_status => $thisif->{_rrd_status} , # keep
			};
		}
		else
		{
			# just mark this interface as updated
			$if_data_map{$needsmust}->{_was_updated} = 1;
			delete $if_data_map{$needsmust}->{_needs_update};
		}
	}

	# 8. do something with the stashed rrd data; now if_data_map should have
	# the correct inventory id attached for every single interface
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live(); # live, no saving needed
	my $V    = $S->view;
	my $RI   = $S->reach;
	$RI->{intfUp} = $RI->{intfColUp} = 0;

	# work on enabled and nonhistoric
	for my $index (sort grep($if_data_map{$_}->{enabled}
													 && !$if_data_map{$_}->{historic}, keys %if_data_map))
	{
		my $thisif = $if_data_map{$index};

		# instantiate inventory
		my ($inventory, $error_message) = $self->inventory( _id => $thisif->{_id} );
		if (!$inventory)
		{
			$self->nmisng->log->error("Failed to get interface inventory, _id: $thisif->{_id}: $error_message");
			next;
		}
		$leftovers{$inventory->id} = 0; # clearly an interface we're handling, so not dead

		# r/o, superset of what if_data_map carries, except for _rrd_data
		my $inventory_data = $inventory->data;

		my $alsoindex = $inventory_data->{ifIndex};
		assert($index eq $alsoindex, "Interface inventory _id: $thisif->{_id} invalid, says ifindex is $alsoindex but current is $index");


		NMISNG::Util::info(
			"$inventory_data->{ifDescr}: ifIndex=$inventory_data->{ifIndex}, was: OperStatus=$inventory_data->{ifOperStatus}, ifAdminStatus=$inventory_data->{ifAdminStatus}, Collect=$inventory_data->{collect}"
				);


		# was an interface section collectable? certain amounts of massaging required
		if (ref(my $ifsection = ref($thisif->{_rrd_data}->{interface}) eq "HASH"?
						$thisif->{_rrd_data}->{interface}->{$index} : undef) eq "HASH")
		{
			# update the CURRENT oper and adminstates from snmp-sourced goodies
			# these are already textualised
			$thisif->{_ifAdminStatus} = $ifsection->{ifAdminStatus}{value};
			$thisif->{_ifOperStatus} = $ifsection->{ifOperStatus}{value};

			# special handling for manual interface discovery which does not use update_intf_info
			if ($dontwanna_ifadminstatus)
			{
				# ifAdminStatus is from inventory, _ifAdminStatus is from snmp, model etc.
				NMISNG::Util::dbg("handling up/down, now admin=$thisif->{_ifAdminStatus}, oper=$thisif->{_ifOperStatus} was admin=$thisif->{ifAdminStatus}, oper=$thisif->{ifOperStatus}" );

				# interface now up or down, check and set or clear outstanding event.
				# fixme not quite correct logic, checkevent happens if ifadminstatus is not up/ok...
				if ($thisif->{_ifAdminStatus} =~ /^(up|ok)$/
						and $thisif->{_ifOperStatus} !~ /^(up|ok|dormant)$/ )
				{
					if ( NMISNG::Util::getbool( $inventory_data->{event} ) )
					{
						Compat::NMIS::notify(
							sys     => $S,
							event   => "Interface Down",
							element => $inventory_data->{ifDescr},
							details => $inventory_data->{Description},
							context => {type => "interface"},
							inventory_id => $inventory->id
						);

					}
				}
				else
				{
					Compat::NMIS::checkEvent(
						sys     => $S,
						event   => "Interface Down",
						level   => "Normal",
						element => $inventory_data->{ifDescr},
						details => $inventory_data->{Description},
						inventory_id => $inventory->id
					);
				}

				# synthetic
				$V->{interface}{"${index}_ifAdminStatus_color"} = Compat::NMIS::getAdminColor(
					collect       => $inventory_data->{collect},
					ifAdminStatus => $thisif->{_ifAdminStatus},
					ifOperStatus  => $thisif->{_ifOperStatus} );
				$V->{interface}{"${index}_ifOperStatus_color"} = Compat::NMIS::getOperColor(
					collect       => $inventory_data->{collect},
					ifAdminStatus => $thisif->{_ifAdminStatus},
					ifOperStatus  => $thisif->{_ifOperStatus} );

				$V->{interface}{"${index}_ifAdminStatus_value"} = $thisif->{_ifAdminStatus};
				$V->{interface}{"${index}_ifOperStatus_value"}  = $thisif->{_ifOperStatus};
			}

			# and update the inventory with state, for saving later
			$inventory_data->{ifAdminStatus} = $if_data_map{$index}->{_ifAdminStatus};
			$inventory_data->{ifOperStatus} = $if_data_map{$index}->{_ifOperStatus};

			# other interface section things
			# cannot store text in rrd, don't need the ifadminstatus
			delete $ifsection->{ifDescr};
			delete $ifsection->{ifAdminStatus};

			# convert time 1/100s tics to uptime string, but also save the seconds
			if (ref($ifsection->{ifLastChange}) eq "HASH"
					&& defined($ifsection->{ifLastChange}->{value}))
			{
				$V->{interface}{"${index}_ifLastChange_value"}
				= $inventory_data->{ifLastChange}
				= NMISNG::Util::convUpTime(
					$inventory_data->{ifLastChangeSec}
					= int( $ifsection->{ifLastChange}{value} / 100 ) );
				NMISNG::Util::dbg("last change for index $index time=$inventory_data->{ifLastChange}, timesec=$inventory_data->{ifLastChangeSec}");
			}
			delete $ifsection->{ifLastChange};

			# accumulate total number of non-virtual interfaces that are up
			$RI->{intfUp}++ if ($thisif->{_ifOperStatus} eq "up"
													and NMISNG::Util::getbool($thisif->{real}));
			++$RI->{intfTotal};

			# Calculate numeric Operational Status
			my $operStatus = ( $thisif->{_ifOperStatus} =~ /up|ok|dormant/ ) ? 100 : 0;
			$ifsection->{ifOperStatus}->{value} = $operStatus;    # can only store numeric value in rrd

			# While updating start calculating the total availability of the node, depends on events set
			my $opstatus = NMISNG::Util::getbool( $inventory_data->{event} ) ? $operStatus : 100;
			$RI->{operStatus} = $RI->{operStatus} + $opstatus;
			++$RI->{operCount};

			# count total number of collected interfaces up ( if events are set on)
			++$RI->{intfColUp} if ($opstatus && NMISNG::Util::getbool($inventory_data->{event}));
		} # end of the interface section special stuff

		my $previous_pit = $inventory->get_newest_timed_data(); # one needed for the pit updates,

		# now walk all rrd data sections and send them off to rrd
		for my $sectionname (sort keys %{$thisif->{_rrd_data}})
		{
			my $thissection = $thisif->{_rrd_data}->{$sectionname}->{$index};
			if ($self->nmisng->log->is_level(2))
			{
				for my $ds (keys %{$thissection})
				{
					$self->nmisng->log->debug2( "rrdData section $sectionname, ds $ds, value=$thissection->{$ds}->{value}, option=$thissection->{$ds}->{option}");
				}
			}

			# RRD Database update and remember filename
			NMISNG::Util::info( "updateRRD type=$sectionname index=$index", 2 );
			my $db = $S->create_update_rrd( data => $thissection,
																			type => $sectionname,
																			index => $index,
																			inventory => $inventory );
			if ( !$db )
			{
				NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
			}
			else
			{
				# convert data into values we can use in pit (eg resolve counters)
				my $target = {};

				NMISNG::Inventory::parse_rrd_update_data($thissection, $target, $previous_pit, $sectionname);
				my $period = $self->nmisng->_threshold_period( subconcept => $sectionname );
				my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
																										 subconcept => $sectionname,
																										 start => $period, end => time);
				# add data and stats
				$stats //= {};
				my $error = $inventory->add_timed_data( data => $target, derived_data => $stats,
																								subconcept => $sectionname,
																								time => $catchall_data->{last_poll},
																								delay_insert => 1 );
				NMISNG::Util::logMsg("ERROR: timed data adding for ". $inventory->concept ." failed: $error")
						if ($error);
			}
		}

		# can't re-use stats here because these run on default 6h, normal stats run on 15m
		my $period = $self->nmisng->config->{interface_util_period} || "-6 hours";    # bsts plus backwards compat
		my $interface_util_stats = Compat::NMIS::getSubconceptStats(sys => $S,
																																inventory => $inventory,
																																subconcept => 'interface',
																																start => $period,
																																end => time);

		$V->{interface}{"${index}_operAvail_value"} = $interface_util_stats->{availability} // 'N/A';
		$V->{interface}{"${index}_totalUtil_value"} = $interface_util_stats->{totalUtil} // 'N/A'; # comment to fix my editor highlighting not finding /
		$V->{interface}{"${index}_operAvail_color"} = Compat::NMIS::colorHighGood( $interface_util_stats->{availability} );
		$V->{interface}{"${index}_totalUtil_color"} = Compat::NMIS::colorLowGood( $interface_util_stats->{totalUtil} );

		### 2012-08-14 keiths, logic here to verify an event exists and the interface is up.
		### this was causing events to be cleared when interfaces were collect true, oper=down, admin=up
		if ( $self->eventExist( "Interface Down", $inventory_data->{ifDescr} )
				 and $inventory_data->{ifOperStatus} =~ /up|ok|dormant/ )
		{
			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "Interface Down",
				level   => "Normal",
				element => $inventory_data->{ifDescr},
				details => $inventory_data->{Description},
				inventory_id => $inventory->id
			);
		}

		# header info of web page
		$V->{interface}{"${index}_operAvail_title"} = 'Intf. Avail.';
		$V->{interface}{"${index}_totalUtil_title"} = $self->nmisng->config->{interface_util_label} || 'Util. 6hrs';    # backwards compat

		# check escalation if event is on
		if ( NMISNG::Util::getbool($inventory_data->{event}))
		{

			my $escalate = 'none';
			my ($error,$erec) = $self->eventLoad(
				event => "Interface Down",
				element => $inventory_data->{ifDescr},
				# don't pass this in yet because if we do it will try and filter and may not be set so worn't work
				# inventory_id => $inventory->id,
				active => 1
			);
			if( !$error && $erec )
			{
				$escalate = $erec->{escalate} if ( $erec and defined( $erec->{escalate} ) );
			}
			$V->{interface}{"${index}_escalate_title"} = 'Esc.';
			$V->{interface}{"${index}_escalate_value"} = $escalate;
		}

		# don't recalculate path, that should happen in update, any place where we find
		# the interface has changed enough runs update code anyway. I believe not doing this is correct
		$inventory->data( $inventory_data );
		$inventory->historic(0);
		$inventory->enabled(1);

		my ($op, $error) = $inventory->save();
		$self->nmisng->log->error("failed to save inventory for $nodename, interface $inventory_data->{ifDescr}: $error")
				if ($op <= 0);

	}

	# handle accumulated alerts
	$self->process_alerts( sys => $S );

	# done walking the interfaces, now mark as historic what is known unwanted
	# leftovers holds all observed inventoies, 1 is dead 0 is good
	my @keep;
	for my $invid (keys %leftovers)
	{
		if ($leftovers{$invid})
		{
			# note that leftovers contain already marked historic ones, so that debug isn't super-useful
			$self->nmisng->log->debug3("$nodename, (re)marking inventory $invid as historic");
		}
		else
		{
			push @keep, $invid;
		}
	}

	my $nuked = $self->bulk_update_inventory_historic(
		active_ids => \@keep, concept => 'interface' );
	$self->nmisng->log->error("bulk update historic failed: $nuked->{error}") if ($nuked->{error});

	NMISNG::Util::logMsg("$nodename, found intfs alive: $nuked->{matched_nothistoric}, already historic: $nuked->{matched_historic}, marked alive: $nuked->{marked_nothistoric}, marked historic: $nuked->{marked_historic}");

	NMISNG::Util::info("Finished");
	return 1;
}

# this functions adjusts some values for an interface
# args: self, sys, index, iftype, target (all required)
# returns: nothing
sub checkIntfInfo
{
	my ($self,%args) = @_;

	my $S          = $args{sys};
	my $index      = $args{index};
	my $ifTypeDefs = $args{iftype};

	my $target = $args{target};
	my $V      = $S->view;

	my $thisintf = $target;
	if ( $thisintf->{ifDescr} eq "" ) { $thisintf->{ifDescr} = "null"; }

	# remove bad chars from interface descriptions
	$thisintf->{ifDescr}     = NMISNG::Util::rmBadChars( $thisintf->{ifDescr} );
	$thisintf->{Description} = NMISNG::Util::rmBadChars( $thisintf->{Description} );

	# Try to set the ifType to be something meaningful!!!!
	if ( exists $ifTypeDefs->{$thisintf->{ifType}}{ifType} )
	{
		$thisintf->{ifType} = $ifTypeDefs->{$thisintf->{ifType}}{ifType};
	}

	# Just check if it is an Frame Relay sub-interface
	if ( ( $thisintf->{ifType} eq "frameRelay" and $thisintf->{ifDescr} =~ /\./ ) )
	{
		$thisintf->{ifType} = "frameRelay-subinterface";
	}
	$V->{interface}{"${index}_ifType_value"} = $thisintf->{ifType};

	# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
	# ditto if ifspeed is zero
	if ( $thisintf->{ifSpeed} == 4294967295 or $thisintf->{ifSpeed} == 0 )
	{
		$thisintf->{ifSpeed} = $thisintf->{ifHighSpeed};
		$thisintf->{ifSpeed} *= 1000000;
	}

	# final fallback in case SNMP agent is DODGY
	$thisintf->{ifSpeed} ||= 1000000000;

	$V->{interface}{"${index}_ifSpeed_value"} = NMISNG::Util::convertIfSpeed( $thisintf->{ifSpeed} );

	# convert time integer from ticks to time string
	# fixme9: unsafe, non-idempotent, broken if function is called more than once, self-referential loopy
	# trashing of ifLastChange via ifLastChangeSec...
	$V->{interface}{"${index}_ifLastChange_value"}
	= $thisintf->{ifLastChange} = NMISNG::Util::convUpTime(
		$thisintf->{ifLastChangeSec} = int( $thisintf->{ifLastChange} / 100 ) );
}

# this function performs some data massaging for PIX firewall devices
# args: sys
# returns: nothing
# fixme: this function does not work for wmi-only nodes
sub checkPIX
{
	my ($self, %args) = @_;
	my $S    = $args{sys};
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	if ( !$S->status->{snmp_enabled} )
	{
		NMISNG::Util::info("Not performing PIX Failover check for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $V    = $S->view;
	my $SNMP = $S->snmp;
	my $result;

	NMISNG::Util::dbg("Starting");

	# PIX failover test
	# table has six values
	# [0] primary.cfwHardwareInformation, [1] secondary.cfwHardwareInformation
	# [2] primary.HardwareStatusValue, [3] secondary.HardwareStatusValue
	# [4] primary.HardwareStatusDetail, [5] secondary.HardwareStatusDetail
	# if HardwareStatusDetail is blank ( ne 'Failover Off' ) then
	# HardwareStatusValue will have 'active' or 'standby'

	if ( $catchall_data->{nodeModel} eq "CiscoPIX" )
	{
		NMISNG::Util::dbg("checkPIX, Getting Cisco PIX Failover Status");
		if ($result = $SNMP->get(
				'cfwHardwareStatusValue.6',  'cfwHardwareStatusValue.7',
				'cfwHardwareStatusDetail.6', 'cfwHardwareStatusDetail.7'
			)
			)
		{
			$result = $SNMP->keys2name($result);    # convert oid in hash key to name

			if ( $result->{'cfwHardwareStatusDetail.6'} ne 'Failover Off' )
			{
				if ( $result->{'cfwHardwareStatusValue.6'} == 0 )
				{
					$result->{'cfwHardwareStatusValue.6'} = "Failover Off";
				}
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 3 ) { $result->{'cfwHardwareStatusValue.6'} = "Down"; }
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 9 )
				{
					$result->{'cfwHardwareStatusValue.6'} = "Active";
				}
				elsif ( $result->{'cfwHardwareStatusValue.6'} == 10 )
				{
					$result->{'cfwHardwareStatusValue.6'} = "Standby";
				}
				else { $result->{'cfwHardwareStatusValue.6'} = "Unknown"; }

				if ( $result->{'cfwHardwareStatusValue.7'} == 0 )
				{
					$result->{'cfwHardwareStatusValue.7'} = "Failover Off";
				}
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 3 ) { $result->{'cfwHardwareStatusValue.7'} = "Down"; }
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 9 )
				{
					$result->{'cfwHardwareStatusValue.7'} = "Active";
				}
				elsif ( $result->{'cfwHardwareStatusValue.7'} == 10 )
				{
					$result->{'cfwHardwareStatusValue.7'} = "Standby";
				}
				else { $result->{'cfwHardwareStatusValue.7'} = "Unknown"; }

				# fixme unclean access to internal structure
				# fixme also fails if we've switched to updating this node on the go!
				if ( !NMISNG::Util::getbool( $S->{update} ) )
				{
					if (   $result->{'cfwHardwareStatusValue.6'} ne $catchall_data->{pixPrimary}
						or $result->{'cfwHardwareStatusValue.7'} ne $catchall_data->{pixSecondary} )
					{
						NMISNG::Util::dbg("PIX failover occurred");

						# As this is not stateful, alarm not sent to state table in sub eventAdd
						Compat::NMIS::notify(
							sys     => $S,
							event   => "Node Failover",
							element => 'PIX',
							details =>
								"Primary now: $catchall_data->{pixPrimary}  Secondary now: $catchall_data->{pixSecondary}"
						);
					}
				}
				$catchall_data->{pixPrimary}   = $result->{'cfwHardwareStatusValue.6'};    # remember
				$catchall_data->{pixSecondary} = $result->{'cfwHardwareStatusValue.7'};

				$V->{system}{firewall_title} = "Failover Status";
				$V->{system}{firewall_value} = "Pri: $catchall_data->{pixPrimary} Sec: $catchall_data->{pixSecondary}";
				if (    $catchall_data->{pixPrimary} =~ /Failover Off|Active/i
					and $catchall_data->{pixSecondary} =~ /Failover Off|Standby/i )
				{
					$V->{system}{firewall_color} = "#00BB00";                           #normal
				}
				else
				{
					$V->{system}{firewall_color} = "#FFDD00";                           #warning

				}
			}
			else
			{
				$V->{system}{firewall_title} = "Failover Status";
				$V->{system}{firewall_value} = "Failover off";
			}
		}
	}
	NMISNG::Util::dbg("Finished");
	return 1;
}



# this function handles nodes with configuration save timestamps
# i.e. try to figure out if the config of a device has been saved or not,
# sends node config change event if one detected, updates the view a little
#
# args: sys
# returns: nothing
sub handle_configuration_changes
{
	my ($self, %args) = @_;

	my $S    = $args{sys};
	my $V    = $S->view;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	NMISNG::Util::info("Starting");

	my @updatePrevValues = qw ( configLastChanged configLastSaved bootConfigLastChanged );

	# create previous values if they don't exist
	for my $attr (@updatePrevValues)
	{
		if (   defined( $catchall_data->{$attr} )
			&& $catchall_data->{$attr} ne ''
			&& !defined( $catchall_data->{"${attr}_prev"} ) )
		{
			$catchall_data->{"${attr}_prev"} = $catchall_data->{$attr};
		}
	}

	my $configLastChanged = $catchall_data->{configLastChanged} if defined $catchall_data->{configLastChanged};
	my $configLastViewed  = $catchall_data->{configLastSaved}   if defined $catchall_data->{configLastSaved};
	my $bootConfigLastChanged = $catchall_data->{bootConfigLastChanged}
		if defined $catchall_data->{bootConfigLastChanged};
	my $configLastChanged_prev = $catchall_data->{configLastChanged_prev}
		if defined $catchall_data->{configLastChanged_prev};

	if ( defined $configLastViewed && defined $bootConfigLastChanged )
	{
		NMISNG::Util::info(
			"checkNodeConfiguration configLastChanged=$configLastChanged, configLastViewed=$configLastViewed, bootConfigLastChanged=$bootConfigLastChanged, configLastChanged_prev=$configLastChanged_prev"
		);
	}
	else
	{
		NMISNG::Util::info(
			"checkNodeConfiguration configLastChanged=$configLastChanged, configLastChanged_prev=$configLastChanged_prev"
		);
	}

	# check if config is saved:
	$V->{system}{configLastChanged_value} = NMISNG::Util::convUpTime( $configLastChanged / 100 ) if defined $configLastChanged;
	$V->{system}{configLastSaved_value}   = NMISNG::Util::convUpTime( $configLastViewed / 100 )  if defined $configLastViewed;
	$V->{system}{bootConfigLastChanged_value} = NMISNG::Util::convUpTime( $bootConfigLastChanged / 100 )
		if defined $bootConfigLastChanged;

	### Cisco Node Configuration Change Only
	if ( defined $configLastChanged && defined $bootConfigLastChanged )
	{
		$V->{system}{configurationState_title} = 'Configuration State'
;
		### when the router reboots bootConfigLastChanged = 0 and configLastChanged
		# is about 2 seconds, which are the changes made by booting.
		if ( $configLastChanged > $bootConfigLastChanged and $configLastChanged > 5000 )
		{
			$V->{system}{"configurationState_value"} = "Config Not Saved in NVRAM";
			$V->{system}{"configurationState_color"} = "#FFDD00";                     #warning
			NMISNG::Util::info("checkNodeConfiguration, config not saved, $configLastChanged > $bootConfigLastChanged");
		}
		elsif ( $bootConfigLastChanged == 0 and $configLastChanged <= 5000 )
		{
			$V->{system}{"configurationState_value"} = "Config Not Changed Since Boot";
			$V->{system}{"configurationState_color"} = "#00BB00";                         #normal
			NMISNG::Util::info("checkNodeConfiguration, config not changed, $configLastChanged $bootConfigLastChanged");
		}
		else
		{
			$V->{system}{"configurationState_value"} = "Config Saved in NVRAM";
			$V->{system}{"configurationState_color"} = "#00BB00";                         #normal
		}
	}

	### If it is newer, someone changed it!
	if ( $configLastChanged > $configLastChanged_prev )
	{
		$catchall_data->{configChangeCount}++;
		$V->{system}{configChangeCount_value} = $catchall_data->{configChangeCount};
		$V->{system}{configChangeCount_title} = "Configuration change count";

		Compat::NMIS::notify(
			sys     => $S,
			event   => "Node Configuration Change",
			element => "",
			details => "Changed at " . $V->{system}{configLastChanged_value},
			context => {type => "node"},
		);
		NMISNG::Util::logMsg("checkNodeConfiguration configuration change detected on $S->{name}, creating event");
	}

	#update previous values to be out current values
	for my $attr (@updatePrevValues)
	{
		if ( defined $catchall_data->{$attr} ne '' && $catchall_data->{$attr} ne '' )
		{
			$catchall_data->{"${attr}_prev"} = $catchall_data->{$attr};
		}
	}

	NMISNG::Util::info("Finished");
	return;
}



# find location from dns LOC record if configured to try (loc_from_DNSloc)
# or fall back to syslocation if loc_from_sysLoc is set
# args: none
# returns: 1 if if finds something, 0 otherwise
sub get_dns_location
{
	my ($self, %args) = @_;

	my ($inv,$error) = $self->inventory( concept => 'catchall' );
	return 0 if (!$inv or $error);
	my $catchall_data = $inv->data_live();
	my $C = $self->nmisng->config;

	NMISNG::Util::dbg("Starting");

	# collect DNS location info. Update this info every update pass.
	$catchall_data->{loc_DNSloc} = "unknown";

	my $tmphostname = $catchall_data->{host};
	if ( NMISNG::Util::getbool( $C->{loc_from_DNSloc} ))
	{
		my @dnsnames = ($tmphostname =~ /^(\d+\.\d+\.\d+\.\d+|[0-9a-fA-F:])+$/)?
				NMISNG::Util::resolve_dns_address($tmphostname) : $tmphostname;

		# look up loc for hostname
		my $resolver = Net::DNS::Resolver->new;
		if (my $query = $resolver->query($dnsnames[0],"LOC"))
		{
			foreach my $rr ( $query->answer )
			{
				next if ($rr->type ne "LOC");

				my ($lat,$lon) = $rr->latlon;
				$catchall_data->{loc_DNSloc} = $lat . "," . $lon . "," . $rr->altitude;
				NMISNG::Util::dbg("Location set from DNS LOC, to $catchall_data->{loc_DNSloc}");
				return 1;
			}
		}
		else
		{
			NMISNG::Util::dbg("ERROR, DNS Loc query failed: $resolver->errorstring");
		}
	}

	# if no DNS based location information found or checked, then look at sysLocation
	if ( NMISNG::Util::getbool( $C->{loc_from_sysLoc}) and $catchall_data->{loc_DNSloc} eq "unknown" )
	{
		# longitude,latitude,altitude,location-text
		if ( $catchall_data->{sysLocation} =~ /$C->{loc_sysLoc_format}/ )
		{
			$catchall_data->{loc_DNSloc} = $catchall_data->{sysLocation};
			NMISNG::Util::dbg("Location set from device sysLocation, to $catchall_data->{loc_DNSloc}");
			return 1;
		}
	}
	NMISNG::Util::dbg("Finished");
	return 0;
}

# retrieve system health index data from snmp, done during update
# args: self, sys
# returns: 1 if all present sections worked, 0 otherwise
# note: raises xyz down events if snmp or wmi are down
sub collect_systemhealth_info
{
	my ($self, %args) = @_;
	my $S    = $args{sys};    # object

	my $name = $self->name;
	my $C = $self->nmisng->config;

	my $V; # view object, loaded if and when needed
	my $SNMP = $S->snmp;
	my $M    = $S->mdl;           # node model table

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	NMISNG::Util::info("Starting");
	NMISNG::Util::info("Get systemHealth Info of node $name, model $catchall_data->{nodeModel}");

	if ( ref( $M->{systemHealth} ) ne "HASH" )
	{
		NMISNG::Util::dbg("No class 'systemHealth' declared in Model.");
		return 0;
	}
	elsif ( !$S->status->{snmp_enabled} && !$S->status->{wmi_enabled} )
	{
		NMISNG::Util::logMsg("ERROR: cannot get systemHealth info, neither SNMP nor WMI enabled!");
		return 0;
	}

	# get the default (sub)sections from config, model can override
	my @healthSections = split(
		",",
		(   defined( $M->{systemHealth}{sections} )
			? $M->{systemHealth}{sections}
				: $C->{model_health_sections}
		)
			);
	for my $section (@healthSections)
	{
		next
				if ( !exists( $M->{systemHealth}->{sys}->{$section} ) ); # if the config provides list but the model doesn't

		my $thissection = $M->{systemHealth}->{sys}->{$section};

		# all systemhealth sections must be indexed by something
		# this holds the name, snmp or wmi
		my $index_var;

		# or if you want to use a raw oid instead: use 'index_oid' => '1.3.6.1.4.1.2021.13.15.1.1.1',
		my $index_snmp;

		# and for obscure SNMP Indexes a more generous snmp index regex can be given:
		# in the systemHealth section of the model 'index_regex' => '\.(\d+\.\d+\.\d+)$',
		# attention: FIRST capture group must return the index part
		my $index_regex = '\.(\d+)$';

		$index_var = $index_snmp = $thissection->{indexed};
		$index_regex = $thissection->{index_regex} if ( exists( $thissection->{index_regex} ) );
		$index_snmp  = $thissection->{index_oid}   if ( exists( $thissection->{index_oid} ) );
		my ($header_info,$description);

		if ( !defined($index_var) or $index_var eq '' )
		{
			NMISNG::Util::dbg("No index var found for $section, skipping");
			next;
		}

		# determine if this is an snmp- OR wmi-backed systemhealth section
		# combination of both cannot work, as there is only one index
		if ( exists( $thissection->{wmi} ) and exists( $thissection->{snmp} ) )
		{
			NMISNG::Util::logMsg("ERROR, systemhealth: section=$section cannot have both sources WMI and SNMP enabled!");
			NMISNG::Util::info("ERROR, systemhealth: section=$section cannot have both sources WMI and SNMP enabled!");
			next;    # fixme: or is this completely terminal for this model?
		}

		if ( exists( $thissection->{wmi} ) )
		{
			NMISNG::Util::info("systemhealth: section=$section, source WMI, index_var=$index_var");
			$header_info = NMISNG::Inventory::parse_model_subconcept_headers( $thissection, 'wmi' );

			my $wmiaccessor = $S->wmi;
			if ( !$wmiaccessor )
			{
				NMISNG::Util::info("skipping section $section: source WMI but node $S->{name} not configured for WMI");
				next;
			}

			# model broken if it says 'indexed by X' but doesn't have a query section for 'X'
			if ( !exists( $thissection->{wmi}->{$index_var} ) )
			{
				NMISNG::Util::logMsg("ERROR: Model section $section is missing declaration for index_var $index_var!");
				next;
			}

			my $wmisection   = $thissection->{wmi};          # the whole section, might contain more than just the index
			my $indexsection = $wmisection->{$index_var};    # the subsection for the index var

			# query can come from -common- or from the index var's own section
			my $query = (
				exists( $indexsection->{query} ) ? $indexsection->{query}
				: ( ref( $wmisection->{"-common-"} ) eq "HASH"
						&& exists( $wmisection->{"-common-"}->{query} ) ) ? $wmisection->{"-common-"}->{query}
				: undef
					);
			if ( !$query or !$indexsection->{field} )
			{
				NMISNG::Util::logMsg("ERROR: Model section $section is missing query or field for WMI variable  $index_var!");
				next;
			}

			# wmi gettable could give us both the indices and the data, but here we want only the different index values
			my ( $error, $fields, $meta ) = $wmiaccessor->gettable(
				wql    => $query,
				index  => $index_var,
				fields => [$index_var]
			);

			if ($error)
			{
				NMISNG::Util::logMsg("ERROR ($S->{name}) failed to get index table for systemHealth $section: $error");
				$self->handle_down(
					sys     => $S,
					type    => "wmi",
					details => "failed to get index table for systemHealth $section: $error"
				);
				next;
			}

			# we need to ditch no longer existent stuff by marking it historic, and for that we
			# keep track of the live inventory items
			my @active_indices = keys %$fields;
			my $res = $self->bulk_update_inventory_historic(
				active_indices => \@active_indices,
				concept => $section );
			$self->nmisng->log->error("bulk update historic failed: $res->{error}") if ($res->{error});


			# fixme: meta might tell us that the indexing didn't work with the given field, if so we should bail out
			for my $indexvalue ( @active_indices )
			{
				NMISNG::Util::dbg("section=$section index=$index_var, found value=$indexvalue");

				# save the seen index value
				my $target = {$index_var => $indexvalue};

				# then get all data for this indexvalue
				# Inventory note: for now Sys will populate the nodeinfo section it cares about
				# afer successful load we'll delete it. in the future loadinfo should maybe be passed
				# the location we want the data to go
				if ($S->loadInfo(
						class   => 'systemHealth',
						section => $section,
						index   => $indexvalue,
						table   => $section,
#fixme9 gone						model   => $model,
						target  => $target
					)
					)
				{
					NMISNG::Util::info("section=$section index=$indexvalue read and stored");

					# $index_var is correct but the loading side in S->inventory doesn't know what the key will be in data
					# so use 'index' for now.
					# loadInfo always sets {index}
					# my $path_keys = [$index_var];
					my $path_keys = ['index'];
					my $path = $self->inventory_path( concept => $section, data => $target, path_keys => $path_keys );
					my ( $inventory, $error_message ) = $self->inventory(
						concept   => $section,
						path      => $path,
						path_keys => $path_keys,
						create    => 1
					);
					$self->nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );
					# regenerate the path, if this thing wasn't new the path may have changed, which is ok
					$inventory->path( recalculate => 1 );
					$inventory->data($target);
					$inventory->historic(0);
					$inventory->enabled(1);

					# set which columns should be displayed
					$inventory->data_info(
						subconcept => $section,
						enabled => 1,
						display_keys => $header_info
					);
					if( @$header_info > 0 )
					{
						my @keys = keys (%{$header_info->[0]});
						# use first key in headers to get description
						$description = $target->{ $keys[0] };
						$inventory->description( $description ) if($description);
					}
					# the above will put data into inventory, so save
					my ( $op, $error ) = $inventory->save();
					NMISNG::Util::info( "saved ".join(',', @$path)." op: $op");
					$self->nmisng->log->error(
						"Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
						if ($error);
				}
				else
				{
					my $error = $S->status->{wmi_error};
					NMISNG::Util::logMsg("ERROR ($S->{name}) failed to get table for systemHealth $section: $error");
					$self->handle_down(
						sys     => $S,
						type    => "wmi",
						details => "failed to get table for systemHealth $section: $error"
					);
					next;
				}
			}
		}
		else
		{
			NMISNG::Util::info("systemHealth: section=$section, source SNMP, index_var=$index_var, index_snmp=$index_snmp");
			$header_info = NMISNG::Inventory::parse_model_subconcept_headers( $thissection, 'snmp' );
			my ( %healthIndexNum, $healthIndexTable );

			# first loop gets the index we want to use out of the oid
			# so we need to keep a map of index => target
			# potientially these two loops could be merged.
			my $targets = {};
			if ( $healthIndexTable = $SNMP->gettable($index_snmp) )
			{
				# NMISNG::Util::dbg("systemHealth: table is ".Dumper($healthIndexTable) );
				foreach my $oid ( Net::SNMP::oid_lex_sort( keys %{$healthIndexTable} ) )
				{
					my $index = $oid;
					if ( $oid =~ /$index_regex/ )
					{
						$index = $1;
					}
					$healthIndexNum{$index} = $index;
					NMISNG::Util::dbg("section=$section index=$index is found, value=$healthIndexTable->{$oid}");
					$targets->{$index}{$index_var} = $healthIndexTable->{$oid};
				}
			}
			else
			{
				if ( $SNMP->error =~ /is empty or does not exist/ )
				{
					NMISNG::Util::info( "SNMP Object Not Present ($S->{name}) on get systemHealth $section index table: "
							. $SNMP->error );
				}
				else
				{
					NMISNG::Util::logMsg( "ERROR ($S->{name}) on get systemHealth $section index table: " . $SNMP->error );
					$self->handle_down(
						sys     => $S,
						type    => "snmp",
						details => "get systemHealth $section index table: " . $SNMP->error
					);
				}
			}

			# mark historic records
			my @active_indices = (sort keys %healthIndexNum);
			my $result = $self->bulk_update_inventory_historic(
				active_indices => \@active_indices, concept => $section );
			$self->nmisng->log->error("bulk update historic failed: $result->{error}") if ($result->{error});

			# Loop to get information, will be stored in {info}{$section} table
			foreach my $index ( @active_indices )
			{
				my $target = $targets->{$index};
				# we pass loadInfo a hash to fill in, then put that into the inventory data
				if( $S->loadInfo(
						class   => 'systemHealth',
						section => $section,
						index   => $index,
						table   => $section,
# fixme9 gone						model   => $model,
						target  => $target
				))
				{
					NMISNG::Util::info("section=$section index=$index read and stored");

					# get the inventory object for this, path_keys required as we don't know what type it will be
					NMISNG::Util::TODO("Do we use index or the healthIndextTable value that the loop above grabbed?");

					# $index_var is correct but the loading side in S->inventory doesn't know what the key will be in data
					# so use 'index' for now.
					# loadInfo always sets {index}, which is potentially the oid part and not the value of the oid, eg. how fanStatus works

					my $path_keys = ['index'];
					my $path = $self->inventory_path( concept => $section, data => $target, path_keys => $path_keys );

					# NOTE: systemHealth requires {index} => $index to be set, it
					my ( $inventory, $error_message ) = $self->inventory(
						concept   => $section,
						path      => $path,
						path_keys => $path_keys,
						create    => 1
					);
					$self->nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );
					# regenerate the path, if this thing wasn't new the path may have changed, which is ok
					$inventory->path( recalculate => 1 );
					$inventory->data($target);
					$inventory->historic(0);
					$inventory->enabled(1);

					# set which columns should be displayed
					$inventory->data_info(
						subconcept => $section,
						enabled => 1,
						display_keys => $header_info
					);
					if( @$header_info > 0 )
					{
						my @keys = keys (%{$header_info->[0]});
						# use first key in headers to get description
						$description = $target->{ $keys[0] };
						$inventory->description( $description ) if($description);
					}

					# the above will put data into inventory, so save
					my ( $op, $error ) = $inventory->save();
					NMISNG::Util::info( "saved ".join(',', @$path)." op: $op");
					$self->nmisng->log->error(
						"Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
						if ($error);
				}
				else
				{
					my $error = $S->status->{snmp_error};
					NMISNG::Util::logMsg("ERROR ($S->{name}) on get systemHealth $section index $index: $error");
					$self->handle_down(
						sys     => $S,
						type    => "snmp",
						details => "get systemHealth $section index $index: $error"
					);
				}
			}
		}
	}
	NMISNG::Util::info("Finished");
	return 1;
}

# collects system health data for rrd, and updates relevant rrd database files
# args: self, sys (both required)
# returns: 1 if all ok, 0 otherwise
sub collect_systemhealth_data
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $name = $self->name;

	my $M  = $S->mdl;         # node model table
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	NMISNG::Util::info("Starting");
	NMISNG::Util::info("Get systemHealth Data of node $name, model $catchall_data->{nodeModel}");

	if ( !exists( $M->{systemHealth} ) )
	{
		NMISNG::Util::dbg("No class 'systemHealth' declared in Model");
		return 1;    # nothing there means all ok
	}

	# config sets default sections, model overrides
	my @healthSections = split( ",", defined( $M->{systemHealth}{sections} )
		? $M->{systemHealth}{sections}
		: $self->nmisng->config->{model_health_sections} );

	for my $section (@healthSections)
	{
		my $ids = $self->get_inventory_ids( concept => $section, filter => { enabled => 1, historic => 0 } );

		# node doesn't have info for this section, so no indices so no fetch,
		# may be no update yet or unsupported section for this model anyway
		# OR only sys section but no rrd (e.g. addresstable)
		next
			if ( @$ids < 1
			or !exists( $M->{systemHealth}->{rrd} )
			or ref( $M->{systemHealth}->{rrd}->{$section} ) ne "HASH" );

		my $thissection = $M->{systemHealth}{sys}{$section};
		my $index_var   = $thissection->{indexed};

		# that's instance index value
		foreach my $id (@$ids)
		{
			my ( $inventory, $error ) = $self->inventory( _id => $id );
			$self->nmisng->log->error("Failed to get inventory with id:$id, error:$error") && next if ( !$inventory );

			my $data = $inventory->data();

			# sanity check the data
			if (   ref($data) ne "HASH"
				or !keys %$data
				or !exists( $data->{index} ) )
			{
				my $index = $data->{index} // 'noindex';
				NMISNG::Util::logMsg(
					"ERROR invalid data for section $section and index $index, cannot collect systemHealth data for this index!"
				);
				NMISNG::Util::info(
					"ERROR invalid data for section $section and index $index, cannot collect systemHealth data for this index!"
				);

				# clean it up as well, it's utterly broken as it is.
				$inventory->delete();
				next;
			}

			# value should be in $index_var, loadInfo also puts it in {index} so fall back to that
			my $index = $data->{index};

			my $rrdData = $S->getData( class => 'systemHealth', section => $section, index => $index,
																 # fixme9 gone debug => $model
					);
			my $howdiditgo = $S->status;

			my $anyerror = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

			# were there any errors?
			if ( !$anyerror && !$howdiditgo->{skipped} )
			{
				my $previous_pit = $inventory->get_newest_timed_data();
				my $count = 0;
				foreach my $sect ( keys %{$rrdData} )
				{
					my $D = $rrdData->{$sect}->{$index};

					# update retrieved values in node info, too, not just the rrd database
					for my $item ( keys %$D )
					{
						++$count;
						NMISNG::Util::dbg(      "updating node info $section $index $item: old "
								. $data->{$item}
								. " new $D->{$item}{value}" );
						$data->{$item} = $D->{$item}{value};
					}

					# RRD Database update and remember filename;
					# also feed in the section data for filename expansion
					my $db = $S->create_update_rrd( data   => $D,
																					type   => $sect,
																					index  => $index,
																					extras => $data,
																					inventory => $inventory );
					if ( !$db )
					{
						NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
					}
					else
					{
						# convert data into values we can use in pit (eg resolve counters)
						my $target = {};
						NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, $sect);
						# get stats
						my $period = $self->nmisng->_threshold_period(subconcept => $sect);
						my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
																												 subconcept => $sect, start => $period, end => time);
						$stats //= {};
						my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $sect,
																									time => $catchall_data->{last_poll}, delay_insert => 1 );
						NMISNG::Util::logMsg("ERROR: timed data adding for ". $inventory->concept ." failed: $error") if ($error);
					}
				}
				NMISNG::Util::info("section=$section index=$index read and stored $count values");
				# technically the path shouldn't change during collect so for now don't recalculate path
				# put the new values into the inventory and save
				$inventory->data($data);
				$inventory->save();
			}
			# this allows us to prevent adding data when it wasn't collected (but not an error)
			elsif( $howdiditgo->{skipped} ) {}
			else
			{
				NMISNG::Util::logMsg("ERROR ($name) on collect_systemhealth_data, $section, $index, $anyerror");
				NMISNG::Util::info("ERROR ($name) on collect_systemhealth_data, $section, $index, $anyerror");
				$self->handle_down( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
					if ( $howdiditgo->{snmp_error} );
				$self->handle_down( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
					if ( $howdiditgo->{wmi_error} );

				return 0;
			}
		}
	}
	NMISNG::Util::info("Finished");
	return 1;
}

### Class Based Qos handling
# this wrapper function performs both type=update and type=collect ops
# args: self, sys, update (optional)
# returns: 1 - fixme why no error handling?
sub collect_cbqos
{
	my ($self, %args) = @_;
	my ($S,$isupdate)    = @args{"sys","update"};

	my $name = $self->name;
	if ( $self->configuration->{cbqos} !~ /^(true|input|output|both)$/ )
	{
		NMISNG::Util::info("no CBQoS collecting for node $name");
		return 1;
	}

	NMISNG::Util::info("Starting for node $name");

	if ($isupdate)
	{
		$self->collect_cbqos_info( sys => $S );    # get indexes
	}
	elsif (!$self->collect_cbqos_data(sys => $S))
	{
		$self->collect_cbqos_info( sys => $S );    # (re)get indexes
		$self->collect_cbqos_data( sys => $S );    # and reget data
	}

	NMISNG::Util::info("Finished");
	return 1;
}

# collect cbqos overview/index data from snmp, during update operation
# fixme: this function does not work for wmi-only nodes
# args: self, sys
# returns: 1  - fixme why no error handling?
sub collect_cbqos_info
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $name = $self->name;
	if ( !$S->status->{snmp_enabled} )
	{
		NMISNG::Util::info("Not performing getCBQoSwalk for $name: SNMP not enabled for this node");
		return 1;
	}

	my $SNMP = $S->snmp;
	my $C = $self->nmisng->config;

	NMISNG::Util::info("start table scanning");

	# get the qos interface indexes and objects from the snmp table
	if ( my $ifIndexTable = $SNMP->getindex('cbQosIfIndex') )
	{
		my $result = $self->get_inventory_model(
			'concept' => 'interface',
			fields_hash => {
				'_id' => 1,
				'data.collect' => 1,
				'data.ifAdminStatus' => 1,
				'data.ifDescr' => 1,
				'data.ifIndex' => 1,
				'data.ifSpeed' => 1,
				'data.ifSpeedIn' => 1,
				'data.ifSpeedOut' => 1,
				'data.setlimits' => 1,
				'enabled' => 1,
				'historic' => 1
			}
				);

		if (my $error = $result->error)
		{
			$self->nmisng->log->error("get inventory model failed: $error");
			next;
		}

		# create a map by ifindex so we can look them up easily, flatten _id into data to make things easier
		my $data = $result->data();
		my %if_data_map = map
			{
				$_->{data}{_id} = $_->{_id};
				$_->{data}{enabled} = $_->{enabled};
				$_->{data}{historic} = $_->{historic};
				$_->{data}{ifIndex} => $_->{data};
			}
			(@$data);

		my %cbQosTable;
		foreach my $PIndex ( keys %{$ifIndexTable} )
		{
			my $intf = $ifIndexTable->{$PIndex};    # the interface number from the snmp qos table
			NMISNG::Util::info("CBQoS, scan interface $intf");
			$self->nmisng->log->warn("CBQoS ifIndex $intf found which is not in inventory") && next
				if( !defined($if_data_map{$intf}) );
			my $if_data = $if_data_map{$intf};

			# skip CBQoS if interface has collection disabled
			if ( $if_data->{historic} || !$if_data->{enabled} )
			{
				NMISNG::Util::dbg("Skipping CBQoS, No collect on interface $if_data->{ifDescr} ifIndex=$intf");
				next;
			}

			my $answer = {};
			my %CMValues;

			# check direction of qos with node table
			( $answer->{'cbQosPolicyDirection'} ) = $SNMP->getarray("cbQosPolicyDirection.$PIndex");
			my $wanteddir = $self->configuration->{cbqos};
			NMISNG::Util::dbg("direction in policy is $answer->{'cbQosPolicyDirection'}, node wants $wanteddir");

			if (( $answer->{'cbQosPolicyDirection'} == 1 and $wanteddir =~ /^(input|both)$/ )
				or ( $answer->{'cbQosPolicyDirection'} == 2 and $wanteddir =~ /^(output|true|both)$/ ) )
			{
				# interface found with QoS input or output configured

				my $direction = ( $answer->{'cbQosPolicyDirection'} == 1 ) ? "in" : "out";
				NMISNG::Util::info("Interface $intf found, direction $direction, PolicyIndex $PIndex");

				my $ifSpeedIn    = $if_data->{ifSpeedIn}  ? $if_data->{ifSpeedIn}  : $if_data->{ifSpeed};
				my $ifSpeedOut   = $if_data->{ifSpeedOut} ? $if_data->{ifSpeedOut} : $if_data->{ifSpeed};
				my $inoutIfSpeed = $direction eq "in"       ? $ifSpeedIn               : $ifSpeedOut;

				# get the policy config table for this interface
				my $qosIndexTable = $SNMP->getindex("cbQosConfigIndex.$PIndex");
				$self->nmisng->log->debug5("qos index table $PIndex: ".Dumper ($qosIndexTable));

				# the OID will be 1.3.6.1.4.1.9.9.166.1.5.1.1.2.$PIndex.$OIndex = Gauge
			BLOCK2:
				foreach my $OIndex ( keys %{$qosIndexTable} )
				{
					# look for the Object type for each
					( $answer->{'cbQosObjectsType'} ) = $SNMP->getarray("cbQosObjectsType.$PIndex.$OIndex");
					NMISNG::Util::dbg("look for object at $PIndex.$OIndex, type $answer->{'cbQosObjectsType'}");
					if ( $answer->{'cbQosObjectsType'} eq 1 )
					{
						# it's a policy-map object, is it the primairy
						( $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray("cbQosParentObjectsIndex.$PIndex.$OIndex");
						if ( $answer->{'cbQosParentObjectsIndex'} eq 0 )
						{
							# this is the primairy policy-map object, get the name
							( $answer->{'cbQosPolicyMapName'} )
								= $SNMP->getarray("cbQosPolicyMapName.$qosIndexTable->{$OIndex}");
							NMISNG::Util::dbg("policymap - name is $answer->{'cbQosPolicyMapName'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
							);
						}
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 2 )
					{
						# it's a classmap, ask the name and the parent ID
						( $answer->{'cbQosCMName'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray( "cbQosCMName.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex" );
						NMISNG::Util::dbg("classmap - name is $answer->{'cbQosCMName'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
						);

						$answer->{'cbQosParentObjectsIndex2'} = $answer->{'cbQosParentObjectsIndex'};
						my $cnt = 0;

						while ( !NMISNG::Util::getbool( $C->{'cbqos_cm_collect_all'}, "invert" )
							and $answer->{'cbQosParentObjectsIndex2'} ne 0
							and $answer->{'cbQosParentObjectsIndex2'} ne $PIndex
							and $cnt++ lt 5 )
						{
							( $answer->{'cbQosConfigIndex'} )
									= $SNMP->getarray("cbQosConfigIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");

							$self->nmisng->log->debug6("cbQosConfigIndex: ".Dumper($answer->{'cbQosConfigIndex'}))
									if ($self->nmisng->log->is_level(6));

							# it is not the first level, get the parent names
							( $answer->{'cbQosObjectsType2'} )
									= $SNMP->getarray("cbQosObjectsType.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
							$self->nmisng->log->debug6("cbQosObjectsType2: ".Dumper($answer->{'cbQosObjectsType2'}));

							NMISNG::Util::dbg("look for parent of ObjectsType $answer->{'cbQosObjectsType2'}");
							if ( $answer->{'cbQosObjectsType2'} eq 1 )
							{
								# it is a policymap name
								( $answer->{'cbQosName'}, $answer->{'cbQosParentObjectsIndex2'} )
									= $SNMP->getarray( "cbQosPolicyMapName.$answer->{'cbQosConfigIndex'}",
									"cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}" );
								NMISNG::Util::dbg("parent policymap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}"
								);

								if ($self->nmisng->log->is_level(6))
								{
									$self->nmisng->log->debug6("cbQosName: ".Dumper($answer->{'cbQosName'}));
									$self->nmisng->log->debug6("cbQosParentObjectsIndex2: "
																						 .Dumper($answer->{'cbQosParentObjectsIndex2'}));
								}

							}
							elsif ( $answer->{'cbQosObjectsType2'} eq 2 )
							{
								# it is a classmap name
								( $answer->{'cbQosName'}, $answer->{'cbQosParentObjectsIndex2'} )
										= $SNMP->getarray( "cbQosCMName.$answer->{'cbQosConfigIndex'}",
																			 "cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}" );
								NMISNG::Util::dbg("parent classmap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}"
										);


								if ($self->nmisng->log->is_level(6))
								{
									$self->nmisng->log->debug6("cbQosName: ".Dumper($answer->{'cbQosName'}));
									$self->nmisng->log->debug6("cbQosParentObjectsIndex2: "
																						 .Dumper($answer->{'cbQosParentObjectsIndex2'}));
								}
							}
							elsif ( $answer->{'cbQosObjectsType2'} eq 3 )
							{
								NMISNG::Util::dbg("skip - this class-map is part of a match statement");
								next BLOCK2;    # skip this class-map, is part of a match statement
							}

							# concatenate names
							if ( $answer->{'cbQosParentObjectsIndex2'} ne 0 )
							{
								$answer->{'cbQosCMName'} = "$answer->{'cbQosName'}--$answer->{'cbQosCMName'}";
							}
						}

						# collect all levels of classmaps or only the first level
						if ( !NMISNG::Util::getbool( $C->{'cbqos_cm_collect_all'}, "invert" )
							or $answer->{'cbQosParentObjectsIndex'} eq $PIndex )
						{
							#
							$CMValues{"H" . $OIndex}{'CMName'}  = $answer->{'cbQosCMName'};
							$CMValues{"H" . $OIndex}{'CMIndex'} = $OIndex;
						}
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 4 )
					{
						my $CMRate;

						# it's a queueing object, look for the bandwidth
						(   $answer->{'cbQosQueueingCfgBandwidth'},
							$answer->{'cbQosQueueingCfgBandwidthUnits'},
							$answer->{'cbQosParentObjectsIndex'}
							)
							= $SNMP->getarray(
							"cbQosQueueingCfgBandwidth.$qosIndexTable->{$OIndex}",
							"cbQosQueueingCfgBandwidthUnits.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex"
							);
						if ( $answer->{'cbQosQueueingCfgBandwidthUnits'} eq 1 )
						{
							$CMRate = $answer->{'cbQosQueueingCfgBandwidth'} * 1000;
						}
						elsif ($answer->{'cbQosQueueingCfgBandwidthUnits'} eq 2
							or $answer->{'cbQosQueueingCfgBandwidthUnits'} eq 3 )
						{
							$CMRate = $answer->{'cbQosQueueingCfgBandwidth'} * $inoutIfSpeed / 100;
						}
						if ( $CMRate eq 0 ) { $CMRate = "undef"; }
						NMISNG::Util::dbg("queueing - bandwidth $answer->{'cbQosQueueingCfgBandwidth'}, units $answer->{'cbQosQueueingCfgBandwidthUnits'},"
								. "rate $CMRate, parent ID $answer->{'cbQosParentObjectsIndex'}" );
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMCfgRate'} = $CMRate;
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 6 )
					{
						# traffic shaping
						( $answer->{'cbQosTSCfgRate'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray( "cbQosTSCfgRate.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex" );
						NMISNG::Util::dbg("shaping - rate $answer->{'cbQosTSCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
						);
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMTSCfgRate'}
							= $answer->{'cbQosPoliceCfgRate'};

					}
					elsif ( $answer->{'cbQosObjectsType'} eq 7 )
					{
						# police
						( $answer->{'cbQosPoliceCfgRate'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray(
							"cbQosPoliceCfgRate.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex"
							);
						NMISNG::Util::dbg("police - rate $answer->{'cbQosPoliceCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
						);
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMPoliceCfgRate'}
							= $answer->{'cbQosPoliceCfgRate'};
					}

					$self->nmisng->log->debug6(Dumper($answer)) if ($self->nmisng->log->is_level(6));
				}

				if ( $answer->{'cbQosPolicyMapName'} eq "" )
				{
					$answer->{'cbQosPolicyMapName'} = 'default';
					NMISNG::Util::dbg("policymap - name is blank, so setting to default");
				}
				# putting this also in ifDescr so it's easier to programatically find in nodes.pl
				$cbQosTable{$intf}{$direction}{'ifDescr'} = $if_data->{'ifDescr'};
				$cbQosTable{$intf}{$direction}{'Interface'}{'Descr'} = $if_data->{'ifDescr'};
				$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'}  = $answer->{'cbQosPolicyMapName'};
				$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Index'} = $PIndex;

				# combine CM name and bandwidth
				foreach my $index ( keys %CMValues )
				{
					# check if CM name does exist
					if ( exists $CMValues{$index}{'CMName'} )
					{

						$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Name'}  = $CMValues{$index}{'CMName'};
						$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Index'} = $CMValues{$index}{'CMIndex'};

						# lets print the just type
						if ( exists $CMValues{$index}{'CMCfgRate'} )
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'}
								= $CMValues{$index}{'CMCfgRate'};
						}
						elsif ( exists $CMValues{$index}{'CMTSCfgRate'} )
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Traffic shaping";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'}
								= $CMValues{$index}{'CMTSCfgRate'};
						}
						elsif ( exists $CMValues{$index}{'CMPoliceCfgRate'} )
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Police";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'}
								= $CMValues{$index}{'CMPoliceCfgRate'};
						}
						else
						{
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth";
							$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = "undef";
						}

					}
					else
					{

					}
				}
			}
			else
			{
				NMISNG::Util::dbg("No collect requested in Node table");
			}
		}

		# Finished with SNMP QoS info collection, store inventory info and tune any existing rrds

		# that's an ifindex
		for my $index ( keys %cbQosTable )
		{
			my $thisqosinfo = $cbQosTable{$index};

			# we rely on index to be there for the path key (right now)
			my $if_data = $if_data_map{$index};

			# don't care about interfaces w/o descr or no speed or uncollected or invalid limit config
			next if ( ref( $if_data_map{$index} ) ne "HASH"
								or !$if_data->{ifSpeed}
								or $if_data->{setlimits} !~ /^(normal|strict|off)$/
								or !NMISNG::Util::getbool( $if_data->{collect} ) );

			my $thisintf     = $if_data;
			my $desiredlimit = $thisintf->{setlimits};

			NMISNG::Util::info(
				"performing rrd speed limit tuning for cbqos on $thisintf->{ifDescr}, limit enforcement: $desiredlimit, interface speed is "
				. NMISNG::Util::convertIfSpeed( $thisintf->{ifSpeed} )
				. " ($thisintf->{ifSpeed})" );

			# speed is in bits/sec, normal limit: 2*reported speed (in bytes), strict: exactly reported speed (in bytes)
			my $maxbytes
					= $desiredlimit eq "off"    ? "U"
					: $desiredlimit eq "normal" ? int( $thisintf->{ifSpeed} / 4 )
					:                             int( $thisintf->{ifSpeed} / 8 );
			my $maxpkts = $maxbytes eq "U" ? "U" : int( $maxbytes / 50 );    # this is a dodgy heuristic

			for my $direction (qw(in out))
			{
				# save the QoS Data, do it before tuning so inventory can be found when looking for name
				my $data = $thisqosinfo->{$direction};
				$data->{index} = $index;

				# create inventory entry, data is not changed below so do it here,
				# add index entry for now, may want to modify this later, or create a specialised Inventory class
				my $path_keys = ['index'];    # for now use this, loadInfo guarnatees it will exist
				my $path = $self->inventory_path( concept => "cbqos-$direction",
																					data => $data, path_keys => $path_keys );

				# only add if we have data, which we may not have in both directions, at this time
				# i can't see a better way to find out when to skip and setting it to be disabled
				# does not seem correct as the cbqos info isn't there
				if( ref($path) eq 'ARRAY' && defined($data->{ClassMap}))
				{
					my ( $inventory, $error_message ) = $self->inventory(
						concept   => "cbqos-$direction",
						path      => $path,
						path_keys => $path_keys,
						create    => 1
							);

					$self->nmisng->log->error("Failed to create inventory, error:$error_message") && next if ( !$inventory );

					# regenerate the path, if this thing wasn't new the path may have changed, which is ok
					$inventory->path( recalculate => 1 );
					$inventory->description("$if_data->{ifDescr} - CBQoS $direction");
					$inventory->data($data);
					$inventory->historic(0);
					$inventory->enabled(1);

					# remove all unwanted storage info - classes that are gone
					my $knownones = $inventory->storage;
					my %keepthese = map { ($_->{Name} => 1)	} (values %{$data->{ClassMap}});
					for my $maybegone (keys %$knownones)
					{
						next if ($keepthese{$maybegone});
						$inventory->set_subconcept_type_storage(type => "rrd",
																										subconcept => $maybegone,
																										data => undef);
					}

					# set up the subconcept/storage infrastructure: one subconcept and rrd file per class (name)
					for my $class (keys %{$data->{ClassMap}})
					{
						my $classname = $data->{ClassMap}->{$class}->{Name};
						my $dbname = $S->makeRRDname(type => "cbqos-$direction",
																				 index     => $index,
																				 item      => $classname,
																				 relative => 1 );

						$inventory->set_subconcept_type_storage(type => "rrd",
																										subconcept => $classname,
																										data => $dbname);

						# does the rrd file already exist?
						if (-f (my $rrdfile =  $C->{database_root}."/".$dbname))
						{
							my $fileinfo = RRDs::info($rrdfile);
							for my $matching ( grep /^ds\[.+\]\.max$/, keys %$fileinfo )
							{
								next if ( $matching
											 !~ /ds\[(PrePolicyByte|DropByte|PostPolicyByte|PrePolicyPkt|DropPkt|NoBufDropPkt)\]\.max/
										);
								my $dsname = $1;
								my $curval = $fileinfo->{$matching};

								# all DS but the byte ones are packet based
								my $desiredval = $dsname =~ /byte/i ? $maxbytes : $maxpkts;

								if ( $curval ne $desiredval )
								{
									NMISNG::Util::info(
										"rrd cbqos-$direction-$classname, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit"
											);
									RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
								}
								else
								{
									NMISNG::Util::info("rrd cbqos-$direction-$classname, ds $dsname, current limit $curval is correct");
								}
							}
						}
						$inventory->data_info( subconcept => $classname, enabled => 0 );
					}

					my ( $op, $error ) = $inventory->save();
					NMISNG::Util::info( "saved ".join(',', @$path)." op: $op");
					$self->nmisng->log->error( "Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
							if ($error);
				}
			}
		}
	}
	else
	{
		NMISNG::Util::dbg("no entries found in QoS table of node $name");
	}
	return 1;
}

# this function performs a collect-type operation for cbqos
# note that while this function could theoretically work with wmi,
# the priming/update function getCBQoSwalk doesn't.
#
# args: self, sys
# returns: 1 if successful, 0 otherwise
sub collect_cbqos_data
{
	my ($self, %args)  = @_;
	my $S     = $args{sys};

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	my $happy;
	foreach my $direction ( "in", "out" )
	{
		my $concept = "cbqos-$direction";
		my $ids = $self->get_inventory_ids(concept => $concept,
																			 filter => { enabled => 1, historic => 0 });

		# oke, we have get now the PolicyIndex and ObjectsIndex directly
		foreach my $id ( @$ids )
		{
			my ($inventory,$error_message) = $self->inventory( _id => $id );
			$self->nmisng->log->error("Failed to get inventory for id:$id, concept:$concept, error_message:$error_message")
					&& next if(!$inventory);

			my $data = $inventory->data();
			# for now ifIndex is stored in the index attribute
			my $intf = $data->{index};
			my $CB = $data;
			my $previous_pit = $inventory->get_newest_timed_data();

			next if ( !exists $CB->{'PolicyMap'}{'Name'} );

			# check if Policymap name contains no collect info
			if ( $CB->{'PolicyMap'}{'Name'} =~ /$S->{mdl}{system}{cbqos}{nocollect}/i )
			{
				NMISNG::Util::dbg("no collect for interface $intf $direction ($CB->{'Interface'}{'Descr'}) by control ($S->{mdl}{system}{cbqos}{nocollect}) at Policymap $CB->{'PolicyMap'}{'Name'}"
				);
				next;
			}
			++$happy;

			my $PIndex = $CB->{'PolicyMap'}{'Index'};
			foreach my $key ( keys %{$CB->{'ClassMap'}} )
			{
				my $CMName = $CB->{'ClassMap'}{$key}{'Name'};
				my $OIndex = $CB->{'ClassMap'}{$key}{'Index'};
				NMISNG::Util::info("Interface $intf, ClassMap $CMName, PolicyIndex $PIndex, ObjectsIndex $OIndex");
				my $subconcept = $CMName;

				# get the number of bytes/packets transfered and dropped
				my $port = "$PIndex.$OIndex";

				my $rrdData
					= $S->getData( class => $concept, index => $intf, port => $port,
												 # fixme9: gone model => $model
					);
				my $howdiditgo = $S->status;
				my $anyerror = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

				# were there any errors?
				if ( !$anyerror )
				{
					$self->process_alerts(sys => $S);
					my $D = $rrdData->{$concept}{$intf};

					if ( $D->{'PrePolicyByte'} eq "noSuchInstance" )
					{
						NMISNG::Util::logMsg("ERROR mismatch of indexes in getCBQoSdata, run walk");
						return;
					}

					# oke, store the data
					NMISNG::Util::dbg("bytes transfered $D->{'PrePolicyByte'}{value}, bytes dropped $D->{'DropByte'}{value}");
					NMISNG::Util::dbg("packets transfered $D->{'PrePolicyPkt'}{value}, packets dropped $D->{'DropPkt'}{value}");
					NMISNG::Util::dbg("packets dropped no buffer $D->{'NoBufDropPkt'}{value}");


					# update RRD, rrd file info comes from inventory,
					# storage/subconcept: class name == subconcept
					my $db = $S->create_update_rrd( data  => $D,
																					type  => $CMName, # subconcept
#																					index => $intf,		# not needed
#																					item  => $CMName, # not needed
																					inventory => $inventory );
					if ( !$db )
					{
						NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
					}
					else
					{
						my $target = {};
						NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, $CMName );
						# get stats, subconcept here is too specific, so use concept name, which is what
						#  stats expects anyway
						my $period = $self->nmisng->_threshold_period( subconcept => $concept );
						# subconcept is completely variable, so we must tell the system where to find the stats
						my $stats = Compat::NMIS::getSubconceptStats( sys => $S, inventory => $inventory, subconcept => $CMName,
																													stats_section => $concept, start => $period, end => time );
						$stats //= {};
						my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $CMName,
																										time => $catchall_data->{last_poll}, delay_insert => 1 );
						NMISNG::Util::logMsg("ERROR: timed data adding for ". $inventory->concept ." failed: $error") if ($error);
					}
				}
				else
				{
					NMISNG::Util::logMsg("ERROR ($S->{name}) on getCBQoSdata, $anyerror");
					$self->handle_down( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
						if ( $howdiditgo->{snmp_error} );
					$self->handle_down( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
							if ( $howdiditgo->{wmi_error} );

					return 0;
				}
			}
			# saving is required bacause create_update_rrd can change inventory, setting data not done because
			# it's not changed
			$inventory->save();
		}
	}
	return $happy? 1 : 0;
}

# this function finds and handles custom alerts for this node,
# and runs process_alerts when any are found.
# args: self, sys
# returns: nothing
#
# fixme: the CVARn evaluation function should be integrated into and handled by sys::parseString
# fixme: this function works ONLY for indexed/systemhealth sections!
sub handle_custom_alerts
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $name = $self->name;

	my $M    = $S->mdl;
	my $CA   = $S->alerts;
	return if (!defined $CA);

	my ($result, %Val,  %ValMeM, $hrCpuLoad);

	NMISNG::Util::info("Running Custom Alerts for node $name");
	foreach my $sect ( keys %{$CA} )
	{
		# get the inventory instances that are relevant for this section,
		# ie. only enabled and nonhistoric ones
		my $ids = $self->get_inventory_ids( concept => $sect, filter => { enabled => 1, historic => 0 } );
		NMISNG::Util::info("Custom Alerts for $sect");
		foreach my $id ( @$ids )
		{
			my ($inventory,$error_message) = $self->inventory( _id => $id );
			$self->nmisng->log->error("Failed to get inventory, concept:$sect, _id:$id, error_message:$error_message") && next
					if(!$inventory);
			my $data = $inventory->data();
			my $index = $data->{index};
			foreach my $alrt ( keys %{$CA->{$sect}} )
			{
				if ( defined( $CA->{$sect}{$alrt}{control} ) and $CA->{$sect}{$alrt}{control} ne '' )
				{
					my $control_result = $S->parseString(
						string => "($CA->{$sect}{$alrt}{control}) ? 1:0",
						index  => $index,
						type   => $sect,
						sect   => $sect,
						extras => $data, # <- this isn't really needed, it's going to look this up for cvars anyway
						eval => 1
					);
					NMISNG::Util::dbg("control_result sect=$sect index=$index control_result=$control_result");
					next if not $control_result;
				}

				# perform CVARn substitution for these two types of ops
				NMISNG::Util::TODO("Why can't this run through parseString?");
				if ( $CA->{$sect}{$alrt}{type} =~ /^(test$|threshold)/ )
				{
					my ( $test, $value, $alert, $test_value, $test_result );

					# do this for test and value
					for my $thingie ( ['test', \$test_result], ['value', \$test_value] )
					{
						my ( $key, $target ) = @$thingie;

						my $origexpr = $CA->{$sect}{$alrt}{$key};
						my ( $rebuilt, @CVAR );

						# rip apart expression, rebuild it with var substitutions
						while ( $origexpr =~ s/^(.*?)(CVAR(\d)=(\w+);|\$CVAR(\d))// )
						{
							$rebuilt .= $1;    # the unmatched, non-cvar stuff at the begin
							my ( $varnum, $decl, $varuse ) = ( $3, $4, $5 );    # $2 is the whole |-group

							if ( defined $varnum )                              # cvar declaration
							{
								$CVAR[$varnum] = $data->{$decl};
								NMISNG::Util::logMsg(   "ERROR: CVAR$varnum references unknown object \"$decl\" in \""
										. $CA->{$sect}{$alrt}{$key}
										. '"' )
									if ( !exists $data->{$decl} );
							}
							elsif ( defined $varuse )                           # cvar use
							{
								NMISNG::Util::logMsg(   "ERROR: CVAR$varuse used but not defined in test \""
										. $CA->{$sect}{$alrt}{$key}
										. '"' )
									if ( !exists $CVAR[$varuse] );

								$rebuilt .= $CVAR[$varuse];                     # sub in the actual value
							}
							else                                                # shouldn't be reached, ever
							{
								NMISNG::Util::logMsg( "ERROR: CVAR parsing failure for \"" . $CA->{$sect}{$alrt}{$key} . '"' );
								$rebuilt = $origexpr = '';
								last;
							}
						}
						$rebuilt .= $origexpr;    # and the non-CVAR-containing remainder.

						$$target = eval { eval $rebuilt; };
						NMISNG::Util::dbg("substituted $key sect=$sect index=$index, orig=\""
								. $CA->{$sect}{$alrt}{$key}
								. "\", expr=\"$rebuilt\", result=$$target",
							2
						);
					}

					if ( $test_value =~ /^[\+-]?\d+\.\d+$/ )
					{
						$test_value = sprintf( "%.2f", $test_value );
					}

					my $level = $CA->{$sect}{$alrt}{level};

					# check the thresholds, in appropriate order
					# report normal if below level for warning (for threshold-rising, or above for threshold-falling)
					# debug-warn and ignore a level definition for 'Normal' - overdefined and buggy!
					if ( $CA->{$sect}{$alrt}{type} =~ /^threshold/ )
					{
						NMISNG::Util::dbg("Warning: ignoring deprecated threshold level Normal for alert \"$alrt\"!")
								if (defined($CA->{$sect}->{$alrt}->{threshold}->{'Normal'}));

						my @matches;
						# to disable particular levels, set their value to the same as the desired one
						# comparison code looks for all matches and picks the worst/highest severity match
						if ( $CA->{$sect}{$alrt}{type} eq "threshold-rising" )
						{
							# from not-bad to very-bad, for skipping skippable levels
							@matches = grep( $test_value >= $CA->{$sect}->{$alrt}->{threshold}->{$_},
															 (qw(Warning Minor Major Critical Fatal)));
						}
						elsif ( $CA->{$sect}{$alrt}{type} eq "threshold-falling" )
						{
							# from not-bad to very bad, again, same rationale
							@matches = grep($test_value <= $CA->{$sect}->{$alrt}->{threshold}->{$_},
															(qw(Warning Minor Major Critical Fatal)));
						}
						else
						{
							NMISNG::Util::logMsg("ERROR: skipping unknown alert type \"$CA->{$sect}{$alrt}{type}\"!");
							next;
						}

						# no matches for above threshold (for rising)? then "Normal"
						# ditto for matches below threshold (for falling)
						if (!@matches)
						{
							$level = "Normal";
							$test_result = 0;
						}
						else
						{
							$level = $matches[-1]; # we want the highest severity/worst matching one
							$test_result = 1;
						}
						NMISNG::Util::info("alert result: test_value=$test_value test_result=$test_result level=$level",2);
					}

					# and now save the result, for both tests and thresholds (source of level is the only difference)
					$alert->{type}  = $CA->{$sect}{$alrt}{type};    # threshold or test or whatever
					$alert->{test}  = $CA->{$sect}{$alrt}{value};
					$alert->{name}  = $S->{name};                   # node name, not much good here
					$alert->{unit}  = $CA->{$sect}{$alrt}{unit};
					$alert->{event} = $CA->{$sect}{$alrt}{event};
					$alert->{level} = $level;
					$alert->{ds}          = $data->{ $CA->{$sect}{$alrt}{element} };
					$alert->{test_result} = $test_result;
					$alert->{value}       = $test_value;

					# also ensure that section, index and alertkey are known for the event context
					$alert->{section} = $sect;
					$alert->{alert}   = $alrt;                      # the key, good enough
					$alert->{index}   = $index;

					push( @{$S->{alerts}}, $alert );
				}
			}
		}
	}

	$self->process_alerts( sys => $S );

	NMISNG::Util::info("Finished");
}


# this function walks the list of 'parked' alerts in a sys object,
# and creates up or down events where applicable
# sys::getvalues() populates the parked alerts section, this consumes them (but writes back
# into sys' info->status)
# args: self, sys
# returns: nothing
sub process_alerts
{
	my ($self, %args)   = @_;
	my $S      = $args{sys};
	confess("missing sys argument!") if (ref($S) ne "NMISNG::Sys");

	my $alerts = $S->{alerts};
	foreach my $alert ( @{$alerts} )
	{
		NMISNG::Util::info(
			"Processing alert: event=Alert: $alert->{event}, level=$alert->{level}, element=$alert->{ds}, details=Test $alert->{test} evaluated with $alert->{value} was $alert->{test_result}"
		) if $alert->{test_result};

		NMISNG::Util::dbg( "Processing alert " . Dumper($alert), 4 );

		my $tresult      = $alert->{test_result} ? $alert->{level} : "Normal";
		my $statusResult = $tresult eq "Normal"  ? "ok"            : "error";

		my $details = "$alert->{type} evaluated with $alert->{value} $alert->{unit} as $tresult";
		if ( $alert->{test_result} )
		{
			Compat::NMIS::notify(
				sys     => $S,
				event   => "Alert: " . $alert->{event},
				level   => $alert->{level},
				element => $alert->{ds},                  # vital part of context, too
				details => $details,
				inventory_id => $alert->{inventory_id},
				context => {
					type    => "alert",
					source  => $alert->{source},
					section => $alert->{section},
					name    => $alert->{alert},
					index   => $alert->{index},
				}
			);
		}
		else
		{
			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "Alert: " . $alert->{event},
				level   => $alert->{level},
				element => $alert->{ds},
				details => $details,
				inventory_id => $alert->{inventory_id}
			);
		}

		### save the Alert result into the Status thingy
		my $status_obj = NMISNG::Status->new(
			nmisng   => $self->nmisng,
			cluster_id => $self->cluster_id,
			node_uuid => $self->uuid,
			method   => "Alert",
			type     => $alert->{type},
			property => $alert->{test},
			event    => $alert->{event},
			index    => undef,             #$args{index},
			level    => $tresult,
			status   => $statusResult,
			element  => $alert->{ds},
			# name does not exist for simple alerts, let's synthesize it from ds
      name => $alert->{alert} || $alert->{ds},
			value    => $alert->{value},
			inventory_id => $alert->{inventory_id}
		);
		my $save_error = $status_obj->save();
		if( $save_error )
		{
			$self->log->error("Failed to save status alert object, error:".$save_error);
		}
	}
}

# fixme: unclear what this little helper actually does
sub _weightResponseTime
{
	my $rt             = shift;
	my $responseWeight = 0;

	if ( $rt eq "" )
	{
		$rt             = "U";
		$responseWeight = 0;
	}
	elsif ( $rt !~ /^[0-9]/ )
	{
		$rt             = "U";
		$responseWeight = 0;
	}
	elsif ( $rt == 0 )
	{
		$rt             = 1;
		$responseWeight = 100;
	}
	elsif ( $rt >= 1500 ) { $responseWeight = 0; }
	elsif ( $rt >= 1000 ) { $responseWeight = 10; }
	elsif ( $rt >= 900 )  { $responseWeight = 20; }
	elsif ( $rt >= 800 )  { $responseWeight = 30; }
	elsif ( $rt >= 700 )  { $responseWeight = 40; }
	elsif ( $rt >= 600 )  { $responseWeight = 50; }
	elsif ( $rt >= 500 )  { $responseWeight = 60; }
	elsif ( $rt >= 400 )  { $responseWeight = 70; }
	elsif ( $rt >= 300 )  { $responseWeight = 80; }
	elsif ( $rt >= 200 )  { $responseWeight = 90; }
	elsif ( $rt >= 0 )    { $responseWeight = 100; }
	return ( $rt, $responseWeight );
}


# computes various node health metrics from info in sys
# optionally! updates rrd
# args: self, sys, delayupdate (default: 0),
# if delayupdate is set, this DOES NOT update
# the type 'health' rrd (to be done later, with total polltime)
#
# returns: reachability data (hashref)
sub compute_reachability
{
	my ($self, %args) = @_;
	my $S = $args{sys};                      # system object
	my $donotupdaterrd = $args{delayupdate};

	my $name = $self->name;
	my $C = $self->nmisng->config;

	my $RI = $S->reach;                                   # reach info
	my $catchall_inventory = $S->inventory( concept => 'catchall' );
	my $catchall_data = $catchall_inventory->data_live();

	my $cpuWeight;
	my $diskWeight;
	my $memWeight;
	my $swapWeight = 0;
	my $responseWeight;
	my $interfaceWeight;
	my $intf;
	my $inputUtil;
	my $outputUtil;
	my $totalUtil;
	my $reportStats;
	my @tmparray;
	my @tmpsplit;
	my %util;
	my $intcount;
	my $intsummary;
	my $intWeight;
	my $index;

	my $reachabilityHealth = 0;
	my $availabilityHealth = 0;
	my $responseHealth     = 0;
	my $cpuHealth          = 0;

	my $memHealth  = 0;
	my $intHealth  = 0;
	my $swapHealth = 0;
	my $diskHealth = 0;

	my $reachabilityMax = 100 * $C->{weight_reachability};
	my $availabilityMax = 100 * $C->{weight_availability};
	my $responseMax     = 100 * $C->{weight_response};
	my $cpuMax          = 100 * $C->{weight_cpu};
	my $memMax          = 100 * $C->{weight_mem};
	my $intMax          = 100 * $C->{weight_int};

	my $swapMax = 0;
	my $diskMax = 0;

	my %reach;

	NMISNG::Util::info("Starting node $name, type=$catchall_data->{nodeType}");

	# Math hackery to convert Foundry CPU memory usage into appropriate values
	$RI->{memused} = ( $RI->{memused} - $RI->{memfree} ) if $catchall_data->{nodeModel} =~ /FoundrySwitch/;

	if ( $catchall_data->{nodeModel} =~ /Riverstone/ )
	{
		# Math hackery to convert Riverstone CPU memory usage into appropriate values
		$RI->{memfree} = ( $RI->{memfree} - $RI->{memused} );
		$RI->{memused} = $RI->{memused} * 16;
		$RI->{memfree} = $RI->{memfree} * 16;
	}

	if ( $RI->{memfree} == 0 or $RI->{memused} == 0 )
	{
		$RI->{mem} = 100;
	}
	else
	{
		#'hrSwapMemFree' => 4074844160,
		#'hrSwapMemUsed' => 220114944,
		my $mainMemWeight = 1;
		my $extraMem      = 0;

		if (    defined $RI->{hrSwapMemFree}
			and defined $RI->{hrSwapMemUsed}
			and $RI->{hrSwapMemFree}
			and $RI->{hrSwapMemUsed} )
		{
			$RI->{swap} = ( $RI->{hrSwapMemFree} * 100 ) / ( $RI->{hrSwapMemUsed} + $RI->{hrSwapMemFree} );
		}
		else
		{
			$RI->{swap} = 0;
		}

		# calculate mem
		if ( $RI->{memfree} > 0 and $RI->{memused} > 0 )
		{
			$RI->{mem} = ( $RI->{memfree} * 100 ) / ( $RI->{memused} + $RI->{memfree} );
		}
		else
		{
			$RI->{mem} = "U";
		}
	}

	# copy stashed results (produced by runPing and getnodeinfo)
	my $pingresult = $RI->{pingresult};
	$reach{responsetime} = $RI->{pingavg};
	$reach{loss}         = $RI->{pingloss};

	my $snmpresult = $RI->{snmpresult};

	$reach{cpu} = $RI->{cpu};
	$reach{mem} = $RI->{mem};
	if ( $RI->{swap} )
	{
		$reach{swap} = $RI->{swap};
	}
	$reach{disk} = 0;
	if ( defined $RI->{disk} and $RI->{disk} > 0 )
	{
		$reach{disk} = $RI->{disk};
	}
	$reach{operStatus} = $RI->{operStatus};
	$reach{operCount}  = $RI->{operCount};

	# number of interfaces
	$reach{intfTotal}   = $catchall_data->{intfTotal} eq 0 ? 'U' : $catchall_data->{intfTotal};    # from run update
	$reach{intfCollect} = $catchall_data->{intfCollect};                                        # from run update
	$reach{intfUp}      = $RI->{intfUp} ne '' ? $RI->{intfUp} : 0;                           # from run collect
	$reach{intfColUp}   = $RI->{intfColUp};                                                  # from run collect

# new option to set the interface availability to 0 (zero) when node is Down, default is "U" config interface_availability_value_when_down
	my $intAvailValueWhenDown
		= defined $C->{interface_availability_value_when_down} ? $C->{interface_availability_value_when_down} : "U";
	NMISNG::Util::dbg("availability using interface_availability_value_when_down=$C->{interface_availability_value_when_down} intAvailValueWhenDown=$intAvailValueWhenDown"
	);

	# Things which don't do collect get 100 for availability
	if ( $reach{availability} eq "" and !NMISNG::Util::getbool( $catchall_data->{collect} ) )
	{
		$reach{availability} = "100";
	}
	elsif ( $reach{availability} eq "" ) { $reach{availability} = $intAvailValueWhenDown; }

	my ( $outage, undef ) = NMISNG::Outage::outageCheck( node => $self, time => time() );
	NMISNG::Util::dbg("Outage for $name is ". ($outage || "<none>"));

	$reach{outage} = $outage eq "current"? 1 : 0;
	# raise a planned outage event, or close it
	if ($outage eq "current")
	{
		Compat::NMIS::notify(sys=>$S,
												 event=> "Planned Outage Open",
												 level => "Warning",
												 element => "",
												 details=> "",                          # filled in by notify
												 context => { type => "node" },
												 inventory_id => $catchall_inventory->id );

	}
	else
	{
		Compat::NMIS::checkEvent(sys=>$S, event=>"Planned Outage Open",
														 level=> "Normal",
														 element=> "",
														 details=> "",
														 inventory_id => $catchall_inventory->id );
	}

	# Health should actually reflect a combination of these values
	# ie if response time is high health should be decremented.
	if ( $pingresult == 100 and $snmpresult == 100 )
	{

		$reach{reachability} = 100;
		if ( $reach{operCount} > 0 )
		{
			$reach{availability} = sprintf( "%.2f", $reach{operStatus} / $reach{operCount} );
		}

		if ( $reach{reachability} > 100 ) { $reach{reachability} = 100; }
		( $reach{responsetime}, $responseWeight ) = _weightResponseTime( $reach{responsetime} );

		if ( NMISNG::Util::getbool( $catchall_data->{collect} ) and $reach{cpu} ne "" )
		{
			if    ( $reach{cpu} <= 10 )  { $cpuWeight = 100; }
			elsif ( $reach{cpu} <= 20 )  { $cpuWeight = 90; }
			elsif ( $reach{cpu} <= 30 )  { $cpuWeight = 80; }
			elsif ( $reach{cpu} <= 40 )  { $cpuWeight = 70; }
			elsif ( $reach{cpu} <= 50 )  { $cpuWeight = 60; }
			elsif ( $reach{cpu} <= 60 )  { $cpuWeight = 50; }
			elsif ( $reach{cpu} <= 70 )  { $cpuWeight = 35; }
			elsif ( $reach{cpu} <= 80 )  { $cpuWeight = 20; }
			elsif ( $reach{cpu} <= 90 )  { $cpuWeight = 10; }
			elsif ( $reach{cpu} <= 100 ) { $cpuWeight = 1; }

			if ( $reach{disk} )
			{
				if    ( $reach{disk} <= 10 )  { $diskWeight = 100; }
				elsif ( $reach{disk} <= 20 )  { $diskWeight = 90; }
				elsif ( $reach{disk} <= 30 )  { $diskWeight = 80; }
				elsif ( $reach{disk} <= 40 )  { $diskWeight = 70; }
				elsif ( $reach{disk} <= 50 )  { $diskWeight = 60; }
				elsif ( $reach{disk} <= 60 )  { $diskWeight = 50; }
				elsif ( $reach{disk} <= 70 )  { $diskWeight = 35; }
				elsif ( $reach{disk} <= 80 )  { $diskWeight = 20; }
				elsif ( $reach{disk} <= 90 )  { $diskWeight = 10; }
				elsif ( $reach{disk} <= 100 ) { $diskWeight = 1; }

				NMISNG::Util::dbg("Reach for Disk disk=$reach{disk} diskWeight=$diskWeight");
			}

			# Very aggressive swap weighting, 11% swap is pretty healthy.
			if ( $reach{swap} )
			{
				if    ( $reach{swap} >= 95 ) { $swapWeight = 100; }
				elsif ( $reach{swap} >= 89 ) { $swapWeight = 95; }
				elsif ( $reach{swap} >= 70 ) { $swapWeight = 90; }
				elsif ( $reach{swap} >= 50 ) { $swapWeight = 70; }
				elsif ( $reach{swap} >= 30 ) { $swapWeight = 50; }
				elsif ( $reach{swap} >= 10 ) { $swapWeight = 30; }
				elsif ( $reach{swap} >= 0 )  { $swapWeight = 1; }

				NMISNG::Util::dbg("Reach for Swap swap=$reach{swap} swapWeight=$swapWeight");
			}

			if    ( $reach{mem} >= 40 ) { $memWeight = 100; }
			elsif ( $reach{mem} >= 35 ) { $memWeight = 90; }
			elsif ( $reach{mem} >= 30 ) { $memWeight = 80; }
			elsif ( $reach{mem} >= 25 ) { $memWeight = 70; }
			elsif ( $reach{mem} >= 20 ) { $memWeight = 60; }
			elsif ( $reach{mem} >= 15 ) { $memWeight = 50; }
			elsif ( $reach{mem} >= 10 ) { $memWeight = 40; }
			elsif ( $reach{mem} >= 5 )  { $memWeight = 25; }
			elsif ( $reach{mem} >= 0 )  { $memWeight = 1; }
		}
		elsif ( NMISNG::Util::getbool( $catchall_data->{collect} ) and $catchall_data->{nodeModel} eq "Generic" )
		{
			$cpuWeight = 100;
			$memWeight = 100;
			### ehg 16 sep 2002 also make interface aavilability 100% - I dont care about generic switches interface health !
			$reach{availability} = 100;
		}
		else
		{
			$cpuWeight = 100;
			$memWeight = 100;
			### 2012-12-13 keiths, removed this stoopid line as availability was allways 100%
			### $reach{availability} = 100;
		}

		# Added little fix for when no interfaces are collected.
		if ( $reach{availability} !~ /\d+/ )
		{
			$reach{availability} = "100";
		}

		# Makes 3Com memory health weighting always 100, and CPU, and Interface availibility
		if ( $catchall_data->{nodeModel} =~ /SSII 3Com/i )
		{
			$cpuWeight           = 100;
			$memWeight           = 100;
			$reach{availability} = 100;

		}

		# Makes CatalystIOS memory health weighting always 100.
		# Add Baystack and Accelar
		if ( $catchall_data->{nodeModel} =~ /CatalystIOS|Accelar|BayStack|Redback|FoundrySwitch|Riverstone/i )
		{
			$memWeight = 100;
		}

		NMISNG::Util::info(
			"REACH Values: reachability=$reach{reachability} availability=$reach{availability} responsetime=$reach{responsetime}"
		);
		NMISNG::Util::info("REACH Values: CPU reach=$reach{cpu} weight=$cpuWeight, MEM reach=$reach{mem} weight=$memWeight");

		if ( NMISNG::Util::getbool( $catchall_data->{collect} ) and defined $S->{mdl}{interface}{nocollect}{ifDescr} )
		{
			NMISNG::Util::dbg("Getting Interface Utilisation Health");
			$intcount   = 0;
			$intsummary = 0;
			my $ids = $self->get_inventory_ids( concept => 'interface', filter => { enabled => 1, historic => 0 } );

			# get all collected interfaces
			foreach my $id (@$ids)
			{
				my ($intf_inventory,$error) = $self->inventory( _id => $id );
				# stats have already been run on the interface, just look them up
				my $latest_ret = $intf_inventory->get_newest_timed_data();
				if( !$latest_ret->{success} )
				{
					NMISNG::Util::dbg("Faild to get_newest_timed_data for interface");
					next;
				}
				# stats data is derived, stored by subconcept
				my $util = $latest_ret->{derived_data}{interface};
				if ( $util->{inputUtil} eq 'NaN' or $util->{outputUtil} eq 'NaN' )
				{
					NMISNG::Util::dbg("SummaryStats for interface=$index of node $name skipped because value is NaN");
					next;
				}

				# lets make the interface metric the largest of input or output
				my $intUtil = $util->{inputUtil};
				if ( $intUtil < $util->{outputUtil} )
				{
					$intUtil = $util->{outputUtil};
				}

				# only add interfaces with utilisation above metric_int_utilisation_above configuration option
				if ( $intUtil > $C->{'metric_int_utilisation_above'} or $C->{'metric_int_utilisation_above'} eq "" )
				{
					$intsummary = $intsummary + ( 100 - $intUtil );
					++$intcount;
					NMISNG::Util::info(
						"Intf Summary util=$intUtil in=$util->{inputUtil} out=$util->{outputUtil} intsumm=$intsummary count=$intcount"
					);
				}

			}    # FOR LOOP
			if ( $intsummary != 0 )
			{
				$intWeight = sprintf( "%.2f", $intsummary / $intcount );
			}
			else
			{
				$intWeight = "NaN";
			}
		}
		else
		{
			$intWeight = 100;
		}

		# if the interfaces are unhealthy and lost stats, whack a 100 in there
		if ( $intWeight eq "NaN" or $intWeight > 100 ) { $intWeight = 100; }

		# Would be cool to collect some interface utilisation bits here.
		# Maybe thresholds are the best way to handle that though.  That
		# would pickup the peaks better.

		# keeping the health values for storing in the RRD
		$reachabilityHealth = ( $reach{reachability} * $C->{weight_reachability} );
		$availabilityHealth = ( $reach{availability} * $C->{weight_availability} );
		$responseHealth     = ( $responseWeight * $C->{weight_response} );
		$cpuHealth          = ( $cpuWeight * $C->{weight_cpu} );
		$memHealth          = ( $memWeight * $C->{weight_mem} );
		$intHealth          = ( $intWeight * $C->{weight_int} );
		$swapHealth         = 0;
		$diskHealth         = 0;

		# the minimum value for health should always be 1
		$reachabilityHealth = 1 if $reachabilityHealth < 1;
		$availabilityHealth = 1 if $availabilityHealth < 1;
		$responseHealth     = 1 if $responseHealth < 1;
		$cpuHealth          = 1 if $cpuHealth < 1;

		# overload the int and mem with swap and disk
		if ( $reach{swap} )
		{
			$memHealth  = ( $memWeight * $C->{weight_mem} ) / 2;
			$swapHealth = ( $swapWeight * $C->{weight_mem} ) / 2;
			$memMax     = 100 * $C->{weight_mem} / 2;
			$swapMax    = 100 * $C->{weight_mem} / 2;

			# the minimum value for health should always be 1
			$memHealth  = 1 if $memHealth < 1;
			$swapHealth = 1 if $swapHealth < 1;
		}

		if ( $reach{disk} )
		{
			$intHealth  = ( $intWeight *  ( $C->{weight_int} / 2 ) );
			$diskHealth = ( $diskWeight * ( $C->{weight_int} / 2 ) );
			$intMax     = 100 * $C->{weight_int} / 2;
			$diskMax    = 100 * $C->{weight_int} / 2;

			# the minimum value for health should always be 1
			$intHealth  = 1 if $intHealth < 1;
			$diskHealth = 1 if $diskHealth < 1;
		}

		# Health is made up of a weighted values:
		### AS 16 Mar 02, implemented weights in nmis.conf
		$reach{health}
			= (   $reachabilityHealth
				+ $availabilityHealth
				+ $responseHealth
				+ $cpuHealth
				+ $memHealth
				+ $intHealth
				+ $diskHealth
				+ $swapHealth );

		NMISNG::Util::info("Calculation of health=$reach{health}");
		if ( lc $reach{health} eq 'nan' )
		{
			NMISNG::Util::dbg("Values Calc. reachability=$reach{reachability} * $C->{weight_reachability}");
			NMISNG::Util::dbg("Values Calc. intWeight=$intWeight * $C->{weight_int}");
			NMISNG::Util::dbg("Values Calc. responseWeight=$responseWeight * $C->{weight_response}");
			NMISNG::Util::dbg("Values Calc. availability=$reach{availability} * $C->{weight_availability}");
			NMISNG::Util::dbg("Values Calc. cpuWeight=$cpuWeight * $C->{weight_cpu}");
			NMISNG::Util::dbg("Values Calc. memWeight=$memWeight * $C->{weight_mem}");
			NMISNG::Util::dbg("Values Calc. swapWeight=$swapWeight * $C->{weight_mem}");
		}
	}

	# the node is collect=false and was pingable
	elsif ( !NMISNG::Util::getbool( $catchall_data->{collect} ) and $pingresult == 100 )
	{
		$reach{reachability} = 100;
		$reach{availability} = 100;
		$reach{intfTotal}    = 'U';
		( $reach{responsetime}, $responseWeight ) = _weightResponseTime( $reach{responsetime} );
		$reach{health} = ( $reach{reachability} * 0.9 ) + ( $responseWeight * 0.1 );
	}

	# there is a current outage for this node
	elsif ( ( $pingresult == 0 or $snmpresult == 0 ) and $outage eq 'current' )
	{
		$reach{reachability} = "U";
		$reach{availability} = "U";
		$reach{intfTotal}    = 'U';
		$reach{responsetime} = "U";
		$reach{health}       = "U";
		$reach{loss}         = "U";
	}

	# ping is working but SNMP is Down
	elsif ( $pingresult == 100 and $snmpresult == 0 )
	{
		$reach{reachability} = 80;                       # correct ? is up and degraded
		$reach{availability} = $intAvailValueWhenDown;
		$reach{intfTotal}    = 'U';
		$reach{health}       = "U";
	}

	# node is Down
	else
	{
		NMISNG::Util::dbg("Node is Down using availability=$intAvailValueWhenDown");
		$reach{reachability} = 0;
		$reach{availability} = $intAvailValueWhenDown;
		$reach{responsetime} = "U";
		$reach{intfTotal}    = 'U';
		$reach{health}       = 0;
	}

	NMISNG::Util::dbg("Reachability and Metric Stats Summary");
	NMISNG::Util::dbg("collect=$catchall_data->{collect} (Node table)");
	NMISNG::Util::dbg("ping=$pingresult (normalised)");
	NMISNG::Util::dbg("cpuWeight=$cpuWeight (normalised)");
	NMISNG::Util::dbg("memWeight=$memWeight (normalised)");
	NMISNG::Util::dbg("swapWeight=$swapWeight (normalised)") if $swapWeight;
	NMISNG::Util::dbg("intWeight=$intWeight (100 less the actual total interface utilisation)");
	NMISNG::Util::dbg("diskWeight=$diskWeight");
	NMISNG::Util::dbg("responseWeight=$responseWeight (normalised)");

	NMISNG::Util::info("Reachability KPI=$reachabilityHealth/$reachabilityMax");
	NMISNG::Util::info("Availability KPI=$availabilityHealth/$availabilityMax");
	NMISNG::Util::info("Response KPI=$responseHealth/$responseMax");
	NMISNG::Util::info("CPU KPI=$cpuHealth/$cpuMax");
	NMISNG::Util::info("MEM KPI=$memHealth/$memMax");
	NMISNG::Util::info("Int KPI=$intHealth/$intMax");
	NMISNG::Util::info("Disk KPI=$diskHealth/$diskMax") if $diskHealth;
	NMISNG::Util::info("SWAP KPI=$swapHealth/$swapMax") if $swapHealth;

	NMISNG::Util::info("total number of interfaces=$reach{intfTotal}");
	NMISNG::Util::info("total number of interfaces up=$reach{intfUp}");
	NMISNG::Util::info("total number of interfaces collected=$reach{intfCollect}");
	NMISNG::Util::info("total number of interfaces coll. up=$reach{intfColUp}");

	for $index ( sort keys %reach )
	{
		NMISNG::Util::dbg("$index=$reach{$index}");
	}

	$reach{health} = ( $reach{health} > 100 ) ? 100 : $reach{health};

		# massaged result with rrd metadata
	my %reachVal;
	$reachVal{outage} =  { value => $reach{outage},
												 option => "gauge,0:1" };
	$reachVal{reachability}{value} = $reach{reachability};
	$reachVal{availability}{value} = $reach{availability};
	$reachVal{responsetime}{value} = $reach{responsetime};
	$reachVal{health}{value}       = $reach{health};

	$reachVal{reachabilityHealth}{value} = $reachabilityHealth;
	$reachVal{availabilityHealth}{value} = $availabilityHealth;
	$reachVal{responseHealth}{value}     = $responseHealth;
	$reachVal{cpuHealth}{value}          = $cpuHealth;
	$reachVal{memHealth}{value}          = $memHealth;
	$reachVal{intHealth}{value}          = $intHealth;
	$reachVal{diskHealth}{value}         = $diskHealth;
	$reachVal{swapHealth}{value}         = $swapHealth;

	$reachVal{loss}{value}          = $reach{loss};
	$reachVal{intfTotal}{value}     = $reach{intfTotal};
	$reachVal{intfUp}{value}        = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfUp};
	$reachVal{intfCollect}{value}   = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfCollect};
	$reachVal{intfColUp}{value}     = $reach{intfTotal} eq 'U' ? 'U' : $reach{intfColUp};
	$reachVal{reachability}{option} = "gauge,0:100";
	$reachVal{availability}{option} = "gauge,0:100";
	### 2014-03-18 keiths, setting maximum responsetime to 30 seconds.
	$reachVal{responsetime}{option} = "gauge,0:30000";
	$reachVal{health}{option}       = "gauge,0:100";

	$reachVal{reachabilityHealth}{option} = "gauge,0:100";
	$reachVal{availabilityHealth}{option} = "gauge,0:100";
	$reachVal{responseHealth}{option}     = "gauge,0:100";
	$reachVal{cpuHealth}{option}          = "gauge,0:100";
	$reachVal{memHealth}{option}          = "gauge,0:100";
	$reachVal{intHealth}{option}          = "gauge,0:100";
	$reachVal{diskHealth}{option}         = "gauge,0:100";
	$reachVal{swapHealth}{option}         = "gauge,0:100";

	$reachVal{loss}{option}        = "gauge,0:100";
	$reachVal{intfTotal}{option}   = "gauge,0:U";
	$reachVal{intfUp}{option}      = "gauge,0:U";
	$reachVal{intfCollect}{option} = "gauge,0:U";
	$reachVal{intfColUp}{option}   = "gauge,0:U";

	# update the rrd or leave it to a caller?
	if ( !$donotupdaterrd )
	{
		# goes into catchall/general
		my $db = $S->create_update_rrd( data => \%reachVal, type => "health", inventory => $catchall_data );    # database name is normally 'reach'
		if ( !$db )
		{
			NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
		}
		else
		{
			my $pit = {};
			my $previous_pit = $catchall_data->get_newest_timed_data();
			NMISNG::Inventory::parse_rrd_update_data( \%reachVal, $pit, $previous_pit, "health" );
			my $stats = $self->compute_summary_stats(sys => $S, inventory => $catchall_inventory );
			my $error = $catchall_data->add_timed_data( data => $pit, derived_data => $stats, subconcept => "health",
																									time => $catchall_data->{last_poll}, delay_insert => 1 );
			NMISNG::Util::logMsg("ERROR: timed data adding for ". $catchall_data->concept ." failed: $error") if ($error);
			# $inventory->data($data);
			$catchall_data->save();
		}
	}
	NMISNG::Util::info("Finished");

	return \%reachVal;
}

# perform update operation for this one node
# args: self, optional force, optional starttime (default now),
# lock (optional, a live lock structure, if collect() decides to switch to update() on the go)
# returns: hashref, keys success/error/locked
#  success 0 + locked 1 is for early bail-out due to node lock
sub update
{
	my ($self, %args) = @_;

	my $name = $self->name;
	my $updatetimer = Compat::Timing->new;
	my $C = $self->nmisng->config;

	$self->nmisng->log->debug("Starting update, node $name");
	$0 = "nmisd worker update $name";

	my @problems;

	# continue with the held lock, regardless of type announcement (but update it)
	# or try to lock the node (announcing what for)
	$self->nmisng->log->debug2("Getting lock for node $name");
	my $lock = $self->lock(type => 'update', lock => $args{lock});

	return { error => "failed to lock node: $lock->{error}" } if ($lock->{error}); # a fault, not a lock held
	# somebody else holds the lock for any reason?
	if ($lock->{conflict})
	{
		# note that an active collect lock is NOT considered an error when polling frequently
		my $severity = ($lock->{type} eq "collect")? "info":"warn";

		$self->nmisng->log->$severity("skipping update for node $name: active $lock->{type} lock held by $lock->{conflict}");
		return { error => "$lock->{type} lock exists for node $name", locked => 1 };
	}

	my $S = NMISNG::Sys->new;    # create system object
	# loads old node NMISNG::Util::info (unless force is active), and the DEFAULT(!) model (always!),
	# and primes the sys object for snmp/wmi ops

	if (!$S->init(node => $self,	update => 'true', force => $args{force}))
	{
		$self->unlock(lock => $lock);
		$self->nmisng->log->error("($name) init failed: " . $S->status->{error} );
		return { error => "Sys init failed: ".$S->status->{error} };
	}

	# this is the first time catchall is accessed, handle error here, all others will assume it works
	my $catchall_inventory = $S->inventory(concept => 'catchall');
	if(!$catchall_inventory)
	{
		$self->unlock(lock => $lock);
		$self->nmisng->log->fatal("Failed to load catchall inventory for node $name");
		return { error => "Failed to load catchall inventory for node $name" };
	}

	# catchall uses 'live' data which is a direct reference to the data because it's too easy to
	# end up with stale/wrong data with all the functions using it
	my $catchall_data = $catchall_inventory->data_live();

	# record that we are trying an update; last_update records only successfully completed updates...
	$catchall_data->{last_update_attempt} = $args{starttime} // Time::HiRes::time;

	$self->nmisng->log->debug("node=$name "
			. join( " ",
							( map { "$_=" . $catchall_data->{$_} } (qw(group nodeType nodedown snmpdown wmidown)) ),
							( map { "$_=" . $S->status->{$_} } (qw(snmp_enabled wmi_enabled)) ) )
			);

	# this uses the node config loaded by init, and updates the node info table
	# (model and nodetype set only if missing)
	$S->copyModelCfgInfo( type => 'all' );

	# look for any current outages with options.nostats set,
	# and set a marker in catchall so that updaterrd writes nothing but 'U'
	my $outageres = NMISNG::Outage::check_outages(node => $self, time => time);
	if (!$outageres->{success})
	{
		$self->nmisng->log->error("Failed to check outage status for $name: $outageres->{error}");
	}
	else
	{
		$catchall_data->{admin}->{outage_nostats} = ( List::Util::any { ref($_->{options}) eq "HASH"
																																				&& $_->{options}->{nostats} }
																									@{$outageres->{current}} )? 1 : 0;
	}

	if ( !NMISNG::Util::getbool( $args{force} ) )
	{
		$S->readNodeView;    # from prev. run, but only if force isn't active
	}
	else
	{
		# make all things for this node historic, they can bring them back if they want
		my $result = $self->bulk_update_inventory_historic();
		$self->nmisng->log->error("bulk update historic failed: $result->{error}") if ($result->{error});
	}

	# prime default values, overridden if we can find anything better
	$catchall_data->{nodeModel} ||= 'Generic';
	$catchall_data->{nodeType}  ||= 'generic';


	# if reachable then we can update the model and get rid of the default we got from init above
	# fixme: not true unless node is ALSO marked as collect, or getnodeinfo will not do anything model-related
	if ($self->pingable(sys => $S))
	{
		# snmp-enabled node? then try to open a session (and test it)
		if ( $S->status->{snmp_enabled} )
		{
			my $candosnmp = $S->open(
				timeout      => $C->{snmp_timeout},
				retries      => $C->{snmp_retries},
				max_msg_size => $C->{snmp_max_msg_size},

				# how many oids/pdus per bulk request, or let net::snmp guess a value
				max_repetitions => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

				# how many oids per simple get request (for getarray), or default (no guessing)
				oidpkt => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || 10,
					);

			# failed altogether?
			if (!$candosnmp or $S->status->{snmp_error} )
			{
				$self->nmisng->log->error("SNMP session open to $name failed: " . $S->status->{snmp_error} );
				$S->disable_source("snmp");
				$self->handle_down(sys => $S, type => "snmp", details => $S->status->{snmp_error});
			}
			# or did we have to fall back to the backup address for this node?
			elsif ($candosnmp && $S->status->{fallback})
			{
				Compat::NMIS::notify(sys => $S,
														 event => "Node Polling Failover",
														 element => undef,
														 details => ("SNMP Session switched to backup address \"".
																				 $self->configuration->{host_backup}.'"'),
														 context => { type => "node" });
			}
			# or are we using the primary address?
			elsif ($candosnmp)
			{
				Compat::NMIS::checkEvent(sys => $S,
																 event => "Node Polling Failover",
																 upevent => "Node Polling Failover Closed", # please log it with this name
																 element => undef,
																 level => "Normal",
																 details => ("SNMP Session using primary address \"".
																						 $self->configuration->{host}. '"'));
			}
			$self->handle_down(sys => $S, type => "snmp", up => 1, details => "snmp ok")
					if ($candosnmp);
		}

		# this will try all enabled sources, 0 only if none worked
		# it also disables sys sources that don't work!
		my $result = $self->update_node_info(sys => $S);

		@problems = @{$result->{error}} if (ref($result->{error}) eq "ARRAY"
																		 && @{$result->{error}}); # (partial) success doesn't mean no errors reported

		if ($result->{success})			# something worked, not necessarily everything though!
		{
			# update_node_info will have deleted the interface info, need to rebuild from scratch
			if ( NMISNG::Util::getbool( $self->configuration->{collect} ) )
			{
				if ($self->update_intf_info(sys => $S))
				{
					$self->nmisng->log->debug("node=$name role=$catchall_data->{roleType} type=$catchall_data->{nodeType} vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}");

					# fixme9 doesn't exist if ($model)
					if (0)
					{
						print
							"MODEL $name: role=$catchall_data->{roleType} type=$catchall_data->{nodeType} sysObjectID=$catchall_data->{sysObjectID} sysObjectName=$catchall_data->{sysObjectName}\n";
						print "MODEL $name: sysDescr=$catchall_data->{sysDescr}\n";
						print
							"MODEL $name: vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}\n";
					}
				}

				# fixme: why no error handling for any of these?
				$self->collect_systemhealth_info(sys => $S) if defined $S->{mdl}{systemHealth};
				$self->collect_cbqos(sys => $S, update => 1);
			}
			else
			{
				$self->nmisng->log->debug("node is set to collect=false, not collecting any info");
			}
			$catchall_data->{last_update} = $args{starttime} // Time::HiRes::time;
			# we updated something, so outside of dead node demotion grace period
			delete $catchall_data->{demote_grace};
		}
		else
		{
			$self->nmisng->log->error("update_node_info failed completely: ".join(" ",@problems));
		}
		$S->close;    # close snmp session if one is open

		# last_update timestamp is not known to update_node_info, so we update that here...
		my $V = $S->view;
		$V->{system}{lastUpdate_value} = NMISNG::Util::returnDateStamp($catchall_data->{last_update});
		$V->{system}{lastUpdate_title} = 'Last Update';
	}
	else
	{
		push @problems, "Node is unreachable, cannot perform update.";
	}

	my $reachdata = $self->compute_reachability(sys => $S,
																							delayupdate => 1); # don't let it make the rrd update, we want to add updatetime!
	$S->writeNodeView;                                # save node view info in file var/$NI->{name}-view.xxxx
	$S->writeNodeInfo();

	if (!@problems)
	{
		# done with the standard work, now run any plugins that offer update_plugin()
		for my $plugin ($self->nmisng->plugins)
		{
			my $funcname = $plugin->can("update_plugin");
			next if ( !$funcname );

			$self->nmisng->log->debug("Running update plugin $plugin with node $name");
			my ( $status, @errors );
			my $prevprefix = $self->nmisng->log->logprefix;
			$self->nmisng->log->logprefix("$plugin\[$$\] ");
			eval { ( $status, @errors ) = &$funcname( node => $name,
																								sys => $S,
																								config => $C,
																								nmisng => $self->nmisng, ); };
			$self->nmisng->log->logprefix($prevprefix);
			if ( $status >= 2 or $status < 0 or $@ )
			{
				$self->nmisng->log->error("Plugin $plugin failed to run: $@") if ($@);
				for my $err (@errors)
				{
					$self->nmisng->log->error("Plugin $plugin: $err");
				}
			}
			elsif ( $status == 1 )    # changes were made, need to re-save the view and info files
			{
				$self->nmisng->log->debug("Plugin $plugin indicated success, updating node and view files");
				$S->writeNodeView;
			}
			elsif ( $status == 0 )
			{
				$self->nmisng->log->debug("Plugin $plugin indicated no changes");
			}
		}
	}

	my $updatetime = $updatetimer->elapTime();
	NMISNG::Util::info("updatetime for $name was $updatetime");
	$reachdata->{updatetime} = {value => $updatetime, option => "gauge,0:U," . ( 86400 * 3 )};

	# parrot the previous reading's poll time
	my $prevval = "U";
	if ( my $rrdfilename = $S->makeRRDname( graphtype => "health" ) )
	{
		my $infohash = RRDs::info($rrdfilename);
		$prevval = $infohash->{'ds[polltime].last_ds'} if ( defined $infohash->{'ds[polltime].last_ds'} );
	}
	$reachdata->{polltime} = {value => $prevval, option => "gauge,0:U,"};
	if (!$S->create_update_rrd(data=> $reachdata, type=>"health",inventory=>$catchall_inventory))
	{
		$self->nmisng->log->error("updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
	}

	my $pit = {};
	my $previous_pit = $catchall_inventory->get_newest_timed_data();
	NMISNG::Inventory::parse_rrd_update_data( $reachdata, $pit, $previous_pit, 'health' );
	my $stats = $self->compute_summary_stats(sys => $S, inventory => $catchall_inventory );
	my $error = $catchall_inventory->add_timed_data( data => $pit, derived_data => $stats, subconcept => 'health',
																									time => $catchall_data->{last_poll}, delay_insert => 1 );
	$self->nmisng->log->error("timed data adding for health failed: $error") if ($error);

	$S->close;

	$catchall_inventory->save();
	if (my $issues = $self->unlock(lock => $lock))
	{
		$self->nmisng->log->error($issues);
	}
	NMISNG::Util::info("Finished");

	return @problems? { error => join(" ",@problems) } : { success => 1 };
}

# calculate the summary8 and summary16 data like it used to be, this will be stored in the db as
# derived data
#
# fixme9: in the future this can be removed, summary8/16 should be calculatable from the PIT data, there
#  really is no need to do this. aggregations or something should be able to pull this off.
#  HOWEVER, the standard-or'-15 min' thresholds STILL need to be computed w/o 8/16 prefix!
#
# args: self, sys, inventory
# returns: stats hash ref
sub compute_summary_stats
{
	my ($self, %args) = (@_);
	my $S = $args{sys};
	my $inventory = $args{inventory};

	my $C = $self->nmisng->config;

	my $section = 'health';

	# compute standard one, first/-8h and second/-16h backwards-compat data,
	# standard stuff is not compat-tag-prefixed, the other two are
	my $standard_period =  $self->nmisng->_threshold_period( subconcept => $section );
	my $metricsFirstPeriod  = $C->{'metric_comparison_first_period'} // "-8 hours";
	my $metricsSecondPeriod	= $C->{'metric_comparison_second_period'} // "-16 hours";

	my $standardstats  = Compat::NMIS::getSubconceptStats(
		sys => $S,
		inventory => $inventory,
		subconcept => $section,
		start => $standard_period,
		end => time );

	my $stats8  = Compat::NMIS::getSubconceptStats(
		sys => $S,
		inventory => $inventory,
		subconcept => $section,
		start => $metricsFirstPeriod,
		end => time );

	my $stats16 = Compat::NMIS::getSubconceptStats(
		sys => $S,
		inventory => $inventory,
		subconcept => $section,
		start => $metricsSecondPeriod,
		end => $metricsFirstPeriod ); # funny one, from -16h to -8h... has been that way for a while

	# map all stats into one package for derived, don't know if we want to keep it this way
	my %allstats = (%$standardstats);
	map { $allstats{'08_'.$_} = $stats8->{$_} } (keys %$stats8);
	map { $allstats{'16_'.$_} = $stats8->{$_} } (keys %$stats16);
	return \%allstats;
}


# this function performs data collection (and rrd storage) for server-type concepts,
# e.g. storage
# args: self, sys
# returns: 1 if ok, 0 otherwise
# fixme: this function does not work for wmi-only nodes!
sub collect_server_data
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $name = $self->name;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	if ( !$S->status->{snmp_enabled} )
	{
		NMISNG::Util::info("Not performing server collection for $name: SNMP not enabled for this node");
		return 1;
	}

	my $M    = $S->mdl;
	my $SNMP = $S->snmp;

	my ( $result, %Val, %ValMeM, $hrCpuLoad, $op, $error );

	NMISNG::Util::info("Starting server device/storage collection, node $S->{name}");

	# clean up node file
	NMISNG::Util::TODO("fixme9 Need a cleanup/historic checker");

	# get cpu info
	if ( ref( $M->{device} ) eq "HASH" && keys %{$M->{device}} )
	{
		# this will put hrCpuLoad into the device_global concept
		# NOTE: should really be PIT!!!
		my $overall_target = {};
		my $deviceIndex = $SNMP->getindex('hrDeviceIndex');
		# doesn't use device global here, it's only an inventory concept right now
		$S->loadInfo( class => 'device',
									# fixme9 gone model => $model,
									target => $overall_target );    # get cpu load without index

		my $path = $self->inventory_path( concept => 'device_global',
																			path_keys => [], data => $overall_target );
		my ($inventory,$error_message) = $self->inventory(
			concept => 'device_global',
			path => $path,
			path_keys => [],
			create => 1
		);
		$self->nmisng->log->error("Failed to get inventory for device_global, error_message:$error_message")
				if(!$inventory);
		# create is set so we should have an inventory here
		if($inventory)
		{
			# not sure why supplying the data above does not work, needs a test!
			$inventory->data( $overall_target );
			$inventory->historic(0);
			$inventory->enabled(1);
			# disable for now
			$inventory->data_info( subconcept => 'device_global', enabled => 0 );
			($op,$error) = $inventory->save();
			NMISNG::Util::info( "saved ".join(',', @$path)." op: $op");
		}

		$self->nmisng->log->error("Failed to save inventory, error_message:$error") if($error);

		foreach my $index ( keys %{$deviceIndex} )
		{
			# create a new target for each index
			my $device_target = {};
			if ( $S->loadInfo( class => 'device', index => $index,
												 # fixme9 gone model => $model,
												 target => $device_target ) )
			{
				my $D = $device_target;
				NMISNG::Util::info("device Descr=$D->{hrDeviceDescr}, Type=$D->{hrDeviceType}");
				if ( $D->{hrDeviceType} eq '1.3.6.1.2.1.25.3.1.3' )
				{# hrDeviceProcessor
					( $hrCpuLoad, $D->{hrDeviceDescr} )
						= $SNMP->getarray( "hrProcessorLoad.${index}", "hrDeviceDescr.${index}" );
					NMISNG::Util::dbg("CPU $index hrProcessorLoad=$hrCpuLoad hrDeviceDescr=$D->{hrDeviceDescr}");

					### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
					push( @{$S->{reach}{cpuList}}, $hrCpuLoad );

					$device_target->{hrCpuLoad}
						= ( $hrCpuLoad =~ /noSuch/i ) ? $overall_target->{hrCpuLoad} : $hrCpuLoad;
					NMISNG::Util::info("cpu Load=$overall_target->{hrCpuLoad}, Descr=$D->{hrDeviceDescr}");
					my $D = {};
					$D->{hrCpuLoad}{value} = $device_target->{hrCpuLoad} || 0;

					# lookup/create inventory before create_update_rrd so it can be passed in
					my $path = $self->inventory_path( concept => 'device', path_keys => ['index'], data => $device_target );
					($inventory,$error_message) = $self->inventory(
						concept => 'device',
						path => $path,
						path_keys => ['index'],
						create => 1
					);
					$self->nmisng->log->error("Failed to get inventory, error_message:$error_message") if(!$inventory);

					if (! ( my $db = $S->create_update_rrd( data => $D, type => "hrsmpcpu",
																									index => $index, inventory => $inventory ) ) )
					{
						NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
					}

					# save after create_update_rrd so that new storage information is also saved
					# again, create is set, chances of no inventory very low
					if($inventory)
					{
						$inventory->data($device_target);
						$inventory->description( $device_target->{hrDeviceDescr} ) if( $device_target->{hrDeviceDescr} );
						$inventory->historic(0);
						$inventory->enabled(1);
						$inventory->data_info( subconcept => 'hrsmpcpu', enabled => 0 );

						my $previous_pit = $inventory->get_newest_timed_data();
						# shouldn't need to save twice but this all could be optimise
						my $target = {};
						NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, 'hrsmpcpu' );
						# get stats
						my $period = $self->nmisng->_threshold_period(subconcept => 'hrsmpcpu');
						my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
							subconcept => 'hrsmpcpu', start => $period, end => time);
						$stats //= {};
						my $error = $inventory->add_timed_data( data => $target, derived_data => $stats,
																										subconcept => 'hrsmpcpu',
																										time => $catchall_data->{last_poll}, delay_insert => 1 );
						NMISNG::Util::logMsg("ERROR: timed data adding for ". $inventory->concept ." failed: $error") if ($error);

						($op,$error) = $inventory->save();
						NMISNG::Util::info( "saved ".join(',', @$path)." op: $op");
					}
					$self->nmisng->log->error("Failed to save inventory, error_message:$error") if($error);
				}
				else
				{
					# don't log this error if not found because it probably doesn't exist
					$inventory = $S->inventory( concept => 'device', index => $index, nolog => 1);
					# if this thing already exists in the database, then disable it, historic is not correct
					# because it is still being reported on the device
					if($inventory)
					{
						$inventory->enabled(0);
						$inventory->save();
					}
				}
			}
		}
		NMISNG::Util::TODO("Need to clean up device/devices here and mark unused historic");
	}
	else
	{
		NMISNG::Util::dbg("Class=device not defined in model=$catchall_data->{nodeModel}");
	}

	### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
	if ( ref( $S->{reach}{cpuList} ) and @{$S->{reach}{cpuList}} )
	{
		$S->{reach}{cpu} = Statistics::Lite::mean( @{$S->{reach}{cpuList}} );
	}

	if ( $M->{storage} ne '' )
	{
		my $disk_cnt             = 1;
		my $storageIndex         = $SNMP->getindex('hrStorageIndex');
		my $hrFSMountPoint       = undef;
		my $hrFSRemoteMountPoint = undef;
		my $fileSystemTable      = undef;

		foreach my $index ( keys %{$storageIndex} )
		{
			# look for existing data for this as 'fallback'
			my $oldstorage;
			my $inventory = $S->inventory( concept => 'storage', index => $index, nolog => 1);
			$oldstorage = $inventory->data() if($inventory);
			my $storage_target = {};

			# this saves any retrieved info in the target
			my $wasloadable = $S->loadInfo(
				class  => 'storage',
				index  => $index,
# fixme9 gone				model  => $model,
				target => $storage_target
			);
			if ( $wasloadable )
			{
				# create_update_rrd needs an inventory object so create one, we know that index exists now so we have what is needed to
				# create/search for the path
				if( !$inventory )
				{
					my $path = $self->inventory_path( concept => 'storage',
																						path_keys => ['index'],
																						data => $storage_target );
					($inventory,$error) = $self->inventory(
						concept => 'storage',
						path => $path,
						path_keys => ['index'],
						create => 1
					);
					if (!$inventory)
					{
						$self->nmisng->log->error("Failed to get storage inventory, error_message:$error");
						next;
					}
				}

				my $D; #used to be %Val
				my $subconcept; # this will be filled in with the subconcept found

				### 2017-02-13 keiths, handling larger disk sizes by converting to an unsigned integer
				$storage_target->{hrStorageSize} = unpack( "I", pack( "i", $storage_target->{hrStorageSize} ) );
				$storage_target->{hrStorageUsed} = unpack( "I", pack( "i", $storage_target->{hrStorageUsed} ) );

				NMISNG::Util::info(
					"storage $storage_target->{hrStorageDescr} Type=$storage_target->{hrStorageType}, Size=$storage_target->{hrStorageSize}, Used=$storage_target->{hrStorageUsed}, Units=$storage_target->{hrStorageUnits}"
				);

				$inventory->historic(0); # it still exists
				$inventory->enabled(1);	# and it seems wanted - maybe not...

				# unwanted? nocollect regex matches or has zero size (matches windows cd, floppy)
				if (($M->{storage}{nocollect}{Description} ne ''
						 and $storage_target->{hrStorageDescr} =~ /$M->{storage}{nocollect}{Description}/
						)
						or $storage_target->{hrStorageSize} <= 0
						)
				{
					$inventory->enabled(0);
				}
				else
				{
					if ($storage_target->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.4'        # hrStorageFixedDisk
							or $storage_target->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.10'    # hrStorageNetworkDisk
							)
					{
						$subconcept = 'hrdisk';
						my $hrStorageType = $storage_target->{hrStorageType};
						$D->{hrDiskSize}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageSize};
						$D->{hrDiskUsed}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageUsed};

						### 2012-12-20 keiths, adding Server Disk to Health Calculations.
						my $diskUtil = $D->{hrDiskUsed}{value} / $D->{hrDiskSize}{value} * 100;
						NMISNG::Util::dbg("Disk List updated with Util=$diskUtil Size=$D->{hrDiskSize}{value} Used=$D->{hrDiskUsed}{value}",
															1);
						push( @{$S->{reach}{diskList}}, $diskUtil );

						$storage_target->{hrStorageDescr} =~ s/,/ /g;    # lose any commas.
						if ( ( my $db = $S->create_update_rrd( data => $D, type => $subconcept,
																									 index => $index, inventory => $inventory ) ) )
						{
							$storage_target->{hrStorageType}              = 'Fixed Disk';
							$storage_target->{hrStorageIndex}             = $index;
							$storage_target->{hrStorageGraph}             = "hrdisk";
							$disk_cnt++;
						}
						else
						{
							NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
						}

						if ( $hrStorageType eq '1.3.6.1.2.1.25.2.1.10' )
						{
							# only get this snmp once if we need to, and created an named index.
							if ( not defined $fileSystemTable )
							{
								$hrFSMountPoint       = $SNMP->getindex('hrFSMountPoint');
								$hrFSRemoteMountPoint = $SNMP->getindex('hrFSRemoteMountPoint');
								foreach my $fsIndex ( keys %$hrFSMountPoint )
								{
									my $mp = $hrFSMountPoint->{$fsIndex};
									$fileSystemTable->{$mp} = $hrFSRemoteMountPoint->{$fsIndex};
								}
							}

							$storage_target->{hrStorageType}        = 'Network Disk';
							$storage_target->{hrFSRemoteMountPoint} = $fileSystemTable->{$storage_target->{hrStorageDescr}};
						}

					}
					### VMware shows Real Memory as HOST-RESOURCES-MIB::hrStorageType.7 = OID: HOST-RESOURCES-MIB::hrStorageTypes.20
					elsif ($storage_target->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.2'
								 or $storage_target->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.20' )
					{
						# Memory
						$subconcept = 'hrmem';
						$D->{hrMemSize}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageSize};
						$D->{hrMemUsed}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageUsed};

						$S->{reach}{memfree} = $D->{hrMemSize}{value} - $D->{hrMemUsed}{value};
						$S->{reach}{memused} = $D->{hrMemUsed}{value};

						if ( ( my $db = $S->create_update_rrd( data => $D, type => $subconcept, inventory => $inventory ) ) )
						{
							$storage_target->{hrStorageType}     = 'Memory';
							$storage_target->{hrStorageGraph}    = "hrmem";
						}
						else
						{
							NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
						}
					}

					# in net-snmp, virtualmemory is used as type for both swap and 'virtual memory' (=phys + swap)
					elsif ( $storage_target->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.3' )
					{    # VirtualMemory
						my ( $itemname, $typename )
								= ( $storage_target->{hrStorageDescr} =~ /Swap/i ) ? (qw(hrSwapMem hrswapmem)) : (qw(hrVMem hrvmem));
						$subconcept = $typename;

						$D->{$itemname . "Size"}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageSize};
						$D->{$itemname . "Used"}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageUsed};

						### 2014-08-07 keiths, adding Other Memory to Health Calculations.
						$S->{reach}{$itemname . "Free"}
							= $D->{$itemname . "Size"}{value} - $D->{$itemname . "Used"}{value};
						$S->{reach}{$itemname . "Used"} = $D->{$itemname . "Used"}{value};

						#print Dumper $S->{reach};

						if ( my $db = $S->create_update_rrd( data => $D, type => $subconcept, inventory => $inventory ) )
						{
							$storage_target->{hrStorageType}         = $storage_target->{hrStorageDescr};    # i.e. virtual memory or swap space
							$storage_target->{hrStorageGraph}        = $typename;
						}
						else
						{
							NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
						}
					}

					# also collect mem buffers and cached mem if present
					# these are marked as storagetype hrStorageOther but the descr is usable
					elsif (
						$storage_target->{hrStorageType} eq '1.3.6.1.2.1.25.2.1.1'    # StorageOther
						and $storage_target->{hrStorageDescr} =~ /^(Memory buffers|Cached memory)$/i
							)
					{
						my ( $itemname, $typename )
								= ( $storage_target->{hrStorageDescr} =~ /^Memory buffers$/i )
							? (qw(hrBufMem hrbufmem))
							: (qw(hrCacheMem hrcachemem));
						$subconcept = $typename;

						# for buffers the total size isn't overly useful (net-snmp reports total phsymem),
						# for cached mem net-snmp reports total size == used cache mem
						$D->{$itemname . "Size"}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageSize};
						$D->{$itemname . "Used"}{value} = $storage_target->{hrStorageUnits} * $storage_target->{hrStorageUsed};

						if ( my $db = $S->create_update_rrd( data => $D, type => $subconcept, inventory => $inventory ) )
						{
							$storage_target->{hrStorageType}         = 'Other Memory';
							$storage_target->{hrStorageGraph}        = $typename;
						}
						else
						{
							NMISNG::Util::logMsg( "ERROR updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
						}
					}
					# storage type not recognized?
					else
					{
						$inventory->enabled(0);
					}
				}

				# if a subconcept wasn't assigned don't bother with timed data, subconcept is required
				if( $subconcept )
				{
					my $target = {};
					my $previous_pit = $inventory->get_newest_timed_data();

					NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, $subconcept );
					# get stats
					my $period = $self->nmisng->_threshold_period(subconcept => $subconcept);
					my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
						subconcept => $subconcept, start => $period, end => time);
					$stats //= {};
					my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $subconcept,
																									time => $catchall_data->{last_poll}, delay_insert => 1 );
					NMISNG::Util::logMsg("ERROR: timed data adding for ". $inventory->concept ." failed: $error") if ($error);
					$inventory->data_info( subconcept => $subconcept, enabled => 0 );
				}

				# make sure the data is set and save
				$inventory->data( $storage_target );
				$inventory->description( $storage_target->{hrStorageDescr} )
					if( defined($storage_target->{hrStorageDescr}) && $storage_target->{hrStorageDescr});

				($op,$error) = $inventory->save();
				NMISNG::Util::info( "saved ".join(',', @{$inventory->path})." op: $op");
				$self->nmisng->log->error("Failed to save storage inventory, op:$op, error_message:$error") if($error);
			}
			elsif( $oldstorage )
			{
				NMISNG::Util::logMsg("ERROR failed to retrieve storage info for index=$index, $oldstorage->{hrStorageDescr}, continuing with OLD data!");
				if( $inventory )
				{
					$inventory->historic(1);
					$inventory->save();
				}
				# nothing needs to be done here, storage target is the data from last time so it's already in db
				# maybe mark it historic?
			}
		}
	}
	else
	{
		NMISNG::Util::dbg("Class=storage not defined in Model=$catchall_data->{nodeModel}");
	}

	### 2012-12-20 keiths, adding Server Disk Usage to Health Calculations.
	if ( defined $S->{reach}{diskList} and @{$S->{reach}{diskList}} )
	{
		#print Dumper $S->{reach}{diskList};
		$S->{reach}{disk} = Statistics::Lite::mean( @{$S->{reach}{diskList}} );
	}

	NMISNG::Util::info("Finished");
}


# this function handles standalone service-polling for a node,
# ie. when triggered OUTSIDE and INDEPENDENT of a collect operation
# consequentially it does not cover snmp-based services!
# args: self, optional force, optional services (list of names)
#  if force is 1: collects all possible services
#  if services arg is present: collects only the listed services
# returns: hashref, keys success/error
sub services
{
	my ($self, %args) = @_;
	my $preselected = $args{services};

	my $name = $self->name;

	NMISNG::Util::info("================================");
	NMISNG::Util::info("Starting services, node $name");
	# lets change our name for process runtime checking
	$0 = "nmisd worker services $name";

	my $S = NMISNG::Sys->new;
	if (!$S->init( node => $self, force => $args{force} ))
	{
		return { error => "Sys init failed: ".$S->status->{error} };
	}

	my $catchall_inventory = $S->inventory(concept => 'catchall');
	if(!$catchall_inventory)
	{
		$self->nmisng->log->fatal("Failed to load catchall inventory for node $name");
		return { error => "Failed to load catchall inventory for node $name" };
	}
	# catchall uses 'live' data which is a direct reference to the data because it's too easy to
	# end up with stale/wrong data with all the functions using it
	my $catchall_data = $catchall_inventory->data_live();

	# look for any current outages with options.nostats set,
	# and set a marker in catchall so that updaterrd writes nothing but 'U'
	my $outageres = NMISNG::Outage::check_outages(node => $self, time => time);
	if (!$outageres->{success})
	{
		$self->nmisng->log->error("Failed to check outage status for $name: $outageres->{error}");
	}
	else
	{
		$catchall_data->{admin}->{outage_nostats} = ( List::Util::any { ref($_->{options}) eq "HASH"
																																				&& $_->{options}->{nostats} }
																									@{$outageres->{current}}) ? 1:0;
	}
	$self->collect_services( sys => $S, snmp => 0,
													 force => $args{force},
													 services => $preselected );
	return { success => 1 };
}

# this function collects all service data for this node
# called either as part of a collect or standalone/independent from services().
#
# args: self, sys object, optional snmp (true/false),
#  optional force (default 0), services (list of preselected services to collect)
#  if force is 1: all possible services are collected
#  if services is present: these services are collected (if due)
#
# returns: nothing
#
# attention: when run with snmp false then snmp-based services are NOT checked!
# fixme: this function does not support service definitions from wmi!
sub collect_services
{
	my ($self, %args) = @_;
	my $S    = $args{sys};
	my $preselected = $args{services};

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	# don't attempt anything silly if this is a wmi-only node
	my $snmp_allowed = NMISNG::Util::getbool( $args{snmp} ) && $S->status->{snmp_enabled};

	my $node = $self->name;
	my $C = $self->nmisng->config;
	$self->nmisng->log->debug("Starting Services collection, node=$node nodeType=$catchall_data->{nodeType}");

	my ($cpu, $memory, $V, %services);
	# services holds snmp-gathered service status, process name -> array of instances

	my $ST    = NMISNG::Util::loadTable(dir => "conf", name => "Services");
	my $timer = Compat::Timing->new;

	# do an snmp service poll first, regardless of whether any specific services being enabled or not

	my %snmpTable;
	# do we have snmp-based services and are we allowed to check them?
	# ie node active and collect on; if so, then do the snmp collection here
	if ( $snmp_allowed
			 and  $self->configuration->{active}
			 and $self->configuration->{collect}
			 and grep( exists( $ST->{$_} ) && $ST->{$_}->{Service_Type} eq "service",
								 split( /,/, $self->configuration->{services} ) )
			)
	{
		$self->nmisng->log->debug2("node $node has SNMP services to check");
		my $SNMP = $S->snmp;

		# get the process parameters by column, allowing efficient bulk requests
		# but possibly running into bad agents at times, which gettable/getindex
		# compensates for by backing off and retrying.
		for my $var (
			qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunStatus
			hrSWRunType hrSWRunPerfCPU hrSWRunPerfMem)
			)
		{
			if ( my $hrIndextable = $SNMP->getindex($var) )
			{
				foreach my $inst ( keys %{$hrIndextable} )
				{
					my $value   = $hrIndextable->{$inst};
					my $textoid = NMISNG::MIB::oid2name( NMISNG::MIB::name2oid($var) . "." . $inst );
					$value = snmp2date($value) if ( $textoid =~ /date\./i );
					( $textoid, $inst ) = split /\./, $textoid, 2;
					$snmpTable{$textoid}{$inst} = $value;
					$self->nmisng->log->debug3( "Indextable=$inst textoid=$textoid value=$value");
				}
			}

			# SNMP failed, so mark SNMP down so code below handles results properly
			else
			{
				$self->nmisng->log->error("$node SNMP failed while collecting SNMP Service Data: ".$SNMP->error);
				$self->handle_down( sys => $S, type => "snmp",
														details => "get SNMP Service Data: " . $SNMP->error);
				$snmp_allowed = 0;
				last;
			}
		}

		# are we still good to continue?
		# don't do anything with the (incomplete and unusable) snmp data if snmp failed just now
		if ($snmp_allowed)
		{
			# prepare service list for all observed services, but ditch 'invalid' == zombies
			for my $pid ( keys %{$snmpTable{hrSWRunName}} )
			{
				my %instance = ( pid => $pid, # cleaner/more useful
												 map { ($_ => $snmpTable{$_}->{$pid}) }
												 (qw(hrSWRunName hrSWRunPath hrSWRunParameters hrSWRunPerfCPU hrSWRunPerfMem)) );
				$instance{hrSWRunType} = ( '', 'unknown', 'operatingSystem',
																	 'deviceDriver', 'application' )[ $snmpTable{hrSWRunType}->{$pid}];
				$instance{hrSWRunStatus} = ( '', 'running', 'runnable',
																		 'notRunnable', 'invalid' )[ $snmpTable{hrSWRunStatus}->{$pid}];
				if ($instance{hrSWRunStatus} eq "invalid")
				{
					$self->nmisng->log->debug4("skipping process in state 'invalid': ".
																		 Data::Dumper->new([\%instance])->Terse(1)->Indent(0)->Pair("=")->Dump);
					next;
				}

				# key by process name, keep array of instances
				$services{ $instance{hrSWRunName} } //= [];
				push @{$services{ $instance{hrSWRunName} }}, \%instance;
				$self->nmisng->log->debug4("Found process: ".Data::Dumper->new([\%instance])->Terse(1)->Indent(0)->Pair("=")->Dump);
			}

			# keep all processes for display, not rrd - park this as timed-data
			# for 'snmp_services' - fixme rename the concept?
			my $procinv_path = $self->inventory_path(concept => "snmp_services", path_keys => [], data => {});
			die "failed to create path for snmp_services: $procinv_path\n" if (!ref($procinv_path));
			my ( $processinventory, $error)  = $self->inventory( concept => "snmp_services",
																													 path => $procinv_path,
																													 path_keys => [],
																													 create => 1);
			die "failed to create or load inventory for snmp_services: $error\n" if (!$processinventory);
			# i think disabled here makes sense
			$processinventory->data_info( subconcept => 'snmp_services', enabled => 0 );
			(my $op, $error) = $processinventory->save();
			die "failed to save inventory for snmp_services: $error\n" if ($error);
			$error = $processinventory->add_timed_data(data => \%services, derived_data => {},
																								 subconcept => 'snmp_services');
			$self->nmisng->log->error("snmp_services timed data saving failed: $error") if ($error);

			# now clear events that applied to processes that no longer exist
			my $eventsmodel = $self->get_events_model( filter => { event => 'regex:process memory' } );
			if (my $error = $eventsmodel->error)
			{
				$self->nmisng->log->error("snmp_services error getting events: $error");
			}
			for my $thisevent ( @{$eventsmodel->data} )
			{
			  # fixme NMIS-73: this should be tied to both the element format
				# and a to-be-added 'service' field of the event
			  # until then we trigger on the element format plus event name
				# fixme9: nothing raises these events - if and when that changes, event needs to contain process name plus pid, separately
				if ( $thisevent->{element} =~ /^(\S.+):(\d+)$/)
				{
					my ($processname, $pid)  = ($1,$2);
					if (ref($services{$processname}) ne "ARRAY" or none { $_->{pid} == $pid } (@{$services{$processname}}))
					{
						$self->nmisng->log->debug("clearing event $thisevent->{event} for node $thisevent->{node_name}: process $processname (pid $pid) no longer exists");

						Compat::NMIS::checkEvent(
							sys     => $S,
							event   => $thisevent->{event},
							level   => $thisevent->{level},
							element => $thisevent->{element},
							details => $thisevent->{details},
							inventory_id => $processinventory->id
								);
					}
				}
			}
		}
	}

	# find and mark as historic any services no longer configured for this host
	# all possible services are desired at this point
	my %desiredservices = map { ($_ => 1) } (split /,/, $self->configuration->{services});

	my $result = $self->get_inventory_model(concept => "service",
																					filter => { historic => 0 },
																					fields_hash => { "data.service" => 1,
																													 _id => 1, });
	if (my $error = $result->error)
	{
		$self->nmisng->log->error("failed to get service inventory: $error");
	}
	elsif ($result->count)
	{
		my %oldservice = map { ($_->{data}->{service} => $_->{_id}) } (@{$result->data});
		for my $maybedead (keys %oldservice)
		{
			next if ($desiredservices{$maybedead});
			$self->nmisng->log->debug2("marking as historic inventory record for service $maybedead");
			my ( $invobj, $error) = $self->inventory(_id => $oldservice{$maybedead});

			die "cannot instantiate inventory object: $error\n" if ($error or !ref($invobj));
			$invobj->historic(1);
			$error = $invobj->save();
			$self->nmisng->log->error("failed to save historic inventory object for service $maybedead: $error") if ($error);
		}
	}

	# explicit list of services passed in? then these only, modulo period
	if (ref($preselected) eq "ARRAY")
	{
		%desiredservices  = map { ($_ => 1) } (@$preselected);
	}

	# specific services to be tested are saved in a list - these are rrd-collected, too.
	# note that this also covers the snmp-based services
	for my $service (sort keys %desiredservices)
	{
		my $thisservice = $ST->{$service};

		# check for invalid service table data
		next if ( !$service
							or $service =~ m!^n\/a$!i
							or $thisservice->{Service_Type} =~ m!^n\/a$!i );

		my ($name, $servicename, $servicetype)
				= @{$thisservice}{"Name","Service_Name","Service_Type"};

		# are we supposed to run this service now?
		# load the service inventory, most recent point-in-time data and check the last run time
		my $inventorydata = {
			service     => $service, # == key in Services.nmis, primary identifier
			description => $thisservice->{Description},
			display_name => $name, # logic-free, no idea why/how that can differ from $service
			node => $node, # backwards-compat
			# note that backwards-compat uuid property is added automatically
		};

		my $path_keys = [ 'service' ];
		my $path = $self->inventory_path( concept => 'service',
																			data => $inventorydata,
																			path_keys => $path_keys );
		die "failed to create path for service: $path\n" if (!ref($path));

		my ($inventory, $error) = $self->inventory(
			concept => "service",
			path => $path,
			path_keys => $path_keys,
			create  => 1,
		);
		die "failed to create or load inventory for $service: $error\n" if (!$inventory);

		# when was this service checked last?
		my $lastrun = ref($inventory->data) eq "HASH"
				&& $inventory->data->{last_run}? $inventory->data->{last_run} : 0;

		my $serviceinterval = $thisservice->{Poll_Interval} || 300;                       # 5min
		my $msg = "Service $service on $node (interval \"$serviceinterval\") last ran at "
			. NMISNG::Util::returnDateStamp($lastrun) . ", ";
		if ( $serviceinterval =~ /^\s*(\d+(\.\d+)?)([mhd])$/ )
		{
			my ( $rawvalue, $unit ) = ( $1, $3 );
			$serviceinterval = $rawvalue * ( $unit eq 'm' ? 60 : $unit eq 'h' ? 3600 : 86400 );
		}

		# we don't run the service exactly at the same time in the collect cycle,
		# so allow up to 10% underrun
		# note that force overrules the timing policy
		if ( !$args{force}
				 && $lastrun
				 && ( ( time - $lastrun ) < $serviceinterval * 0.9 ) )
		{
			$msg .= "skipping this time.";
			$self->nmisng->log->debug($msg);
			next;
		}
		else
		{
			$msg .= "must be checked this time.";
			$self->nmisng->log->debug($msg);
		}

		# make sure that the rrd heartbeat is suitable for the service interval!
		my $serviceheartbeat = ( $serviceinterval * 3 ) || 300 * 3;

		# make sure this gets reinitialized for every service!
		my $gotMemCpu = 0;
		my (%Val, %status);

		# log that we're checking (or why not)
		$self->nmisng->log->debug(($servicetype eq "service" && !$snmp_allowed)? "Not checking name=$name, no SNMP available"
															: "Checking service_type=$servicetype name=$name service_name=$servicename" );


		my $ret = 0; # 0 means bad, service down
		# record the service response time, more precisely the time it takes us testing the service
		$timer->resetTime;
		my $responsetime;    # blank the responsetime

		# DNS: lookup whatever Service_name contains (fqdn or ip address),
		# nameserver being the host in question
		if ( $servicetype eq "dns" )
		{
			my $lookfor = $servicename;
			if ( !$lookfor )
			{
				$self->nmisng->log->error("($node) Service_name for service=$service must contain an FQDN or IP address");
				$status{status_text} = "Service misconfigured: Service_name must be a FQDN or IP address";
				$ret = 0;
			}
			else
			{
				my $res = Net::DNS::Resolver->new;
				$res->nameserver( $catchall_data->{host} );
				$res->udp_timeout(10);    # don't waste more than 10s on dud dns
				$res->usevc(0);           # force to udp (default)
				$res->debug(1) if $C->{debug} > 3;    # set this to 1 for debug

				my $packet = $res->search($lookfor);  # resolver figures out what to look for
				if ( !defined $packet )
				{
					$ret = 0;
					$self->nmisng->log->error("Unable to lookup $lookfor on DNS server $catchall_data->{host}");
				}
				else
				{
					$ret = 1;
					$self->nmisng->log->debug3("DNS data for $lookfor from $catchall_data->{host} was " . $packet->string );
				}
			}
		}
		# now the 'port' service checks, which rely on nmap
		# - tcp would be easy enough to do with a plain connect, but udp accessible-or-closed needs extra smarts
		elsif ( $servicetype eq "port" )
		{
			$msg = '';
			if ($thisservice->{Port} !~ /^(tcp|udp):\d+$/i)
			{
				$self->nmisng->log->error("$node misconfigured: Port for service=$service must be tcp:<port> or udp:<port>!");
				$status{status_text} = "Service misconfigured: Port must be tcp:<port> or udp:<port>!";
				$ret = 0;
			}
			else
			{
				my ( $scan, $port ) = split ':', $thisservice->{Port};

				my $nmap = (
					$scan =~ /^udp$/i
					? "nmap -sU --host_timeout 3000 -p $port -oG - $catchall_data->{host}"
					: "nmap -sT --host_timeout 3000 -p $port -oG - $catchall_data->{host}"
						);

				# fork and read from pipe
				my $pid = open( NMAP, "$nmap 2>&1 |" );
				if ( !defined $pid )
				{
					my $errmsg = "ERROR, Cannot fork to execute nmap: $!";
					$self->nmisng->log->error($errmsg);
				}
				while (<NMAP>)
				{
					$msg .= $_;    # this retains the newlines
				}
				close(NMAP);
				my $exitcode = $?;

				# if the pipe close doesn't wait until the child is gone (which it may do...)
				# then wait and collect explicitely
				if ( waitpid( $pid, 0 ) == $pid )
				{
					$exitcode = $?;
				}
				if ($exitcode)
				{
					$self->nmisng->log->error( "NMAP ($nmap) returned exitcode " . ( $exitcode >> 8 ) . " (raw $exitcode)" );
				}
				if ( $msg =~ /Ports: $port\/open/ )
				{
					$ret = 1;
					$self->nmisng->log->debug("NMAP reported success for port $port: $msg");
				}
				else
				{
					$ret = 0;
					$self->nmisng->log->debug("NMAP reported failure for port $port: $msg");
				}
			}
		}
		# now the snmp services - but only if snmp is on and if it did work.
		elsif ( $servicetype eq "service"
						and $self->configuration->{collect})
		{
			# snmp not allowed also includes the case of snmp having failed just now
			# in which case we cannot and must not say anything about this service
			next if (!$snmp_allowed);

			my $wantedprocname = $servicename;
			my $parametercheck = $thisservice->{Service_Parameters};

			if ( !$wantedprocname and !$parametercheck )
			{
				$self->nmisng->log->error("($node) service=$service Service_Name and Service_Parameters are empty!");
				$status{status_text} = "Service misconfigured: Service_Name and Service_Parameters are empty!";
				$ret = 0;
			}
			else
			{
				# one of the two blank is ok
				$wantedprocname ||= ".*";
				$parametercheck ||= ".*";

				# lets check the service status from snmp for matching process(es)
				# it's common to have multiple processes with the same name on a system,
				# heuristic: one or more living processes -> service is ok,
				# no living ones -> down.
				# living in terms of host-resources mib = runnable or running;
				# interpretation of notrunnable is not clear.
				# invalid is for (short-lived) zombies, which should be ignored.

				# we check: the process name, against regex from Service_Name definition,
				# AND the process path + parameters, against regex from Service_Parameters

				# services list is keyed by name, values are lists of process instances
				my @matchingprocs = grep($_->{hrSWRunName} =~ /^$wantedprocname$/
																 && "$_->{hrSWRunPath} $_->{hrSWRunParameters}" =~ /$parametercheck/, (map { @$_} (values %services)));
				my @livingprocs = grep($_->{hrSWRunStatus} =~ /^(running|runnable)$/i, @matchingprocs);

				$self->nmisng->log->debug("collect_services: found "
																	. scalar(@matchingprocs)
																	. " total and "
																	. scalar(@livingprocs)
																	. " live processes for process '$wantedprocname', parameters '$parametercheck', live processes: "
																	. join( " ", map { "$_->{hrSWRunName}:$_->{pid}" } (@livingprocs) ));

				if ( !@livingprocs )
				{
					$ret       = 0;
					$cpu       = 0;
					$memory    = 0;
					$gotMemCpu = 1;

					$self->nmisng->log->info("service $name is down, "
																	 . ( @matchingprocs? "only non-running processes" : "no matching processes" ));
				}
				else
				{
					# return the average values for cpu and mem
					$ret       = 1;
					$gotMemCpu = 1;

					# cpu is in centiseconds, and a running counter. rrdtool wants integers for counters.
					# memory is in kb, and a gauge.
					$cpu = int( Statistics::Lite::mean( map { $_->{hrSWRunPerfCPU} } (@livingprocs) ) );
					$memory = Statistics::Lite::mean( map { $_->{hrSWRunPerfMem} } (@livingprocs) );

					$self->nmisng->log->info("service $name is up, " . scalar(@livingprocs) . " running process(es)");
				}
			}
		}

		# now the sapi 'scripts' (similar to expect scripts)
		elsif ( $servicetype eq "script" )
		{
			# OMK-3237, use sensible and non-clashing config source:
			# now service_name sets the script file name, temporarily falling back to $service
			my $scriptfn = $C->{script_root}."/". ($servicename || $service);
			# try conf/scripts, fallback to conf-default/scripts
			$scriptfn = $C->{script_root_default}. "/". ($servicename || $service) if (!-e  $scriptfn);
			if (!open(F, $scriptfn))
			{
				my $cause = $!;
				$self->nmisng->log->error("can't open script file $scriptfn for $service: $cause");
				$status{status_text} = "Service misconfigured: cannot open script file $scriptfn: $cause";
				$ret = 0;
			}
			else
			{
				my $scripttext = join( "", <F> );
				close(F);

				my $timeout = ( $thisservice->{Max_Runtime} > 0 ) ? $thisservice->{Max_Runtime} : 3;

				( $ret, $msg ) = NMISNG::Sapi::sapi( $catchall_data->{host}, $thisservice->{Port}, $scripttext, $timeout );
				$self->nmisng->log->debug("Results of $service is $ret, msg is $msg");
			}
		}

		# 'real' scripts, or more precisely external programs
		# which also covers nagios plugins - https://nagios-plugins.org/doc/guidelines.html
		elsif ( $servicetype =~ /^(program|nagios-plugin)$/ )
		{
			$ret = 0;
			my $svc = $thisservice;
			if ( !$svc->{Program} or !-x $svc->{Program} )
			{
        $self->nmisng->log->error("($node) misconfigured: no working Program to run for service $service!");
				$status{status_text} = "Service misconfigured: no working Program to run!";
			}
			else
			{
				# exit codes and output handling differ
				my $flavour_nagios = ( $svc->{Service_Type} eq "nagios-plugin" );

				# check the arguments (if given), substitute node.XYZ values
				my $finalargs;
				if ( $svc->{Args} )
				{
					$finalargs = $svc->{Args};

					# don't touch anything AFTER a node.xyz, and only subst if node.xyz is the first/only thing,
					# or if there's a nonword char before node.xyz.
					$finalargs =~ s/(^|\W)(node\.([a-zA-Z0-9_-]+))/$1$catchall_data->{$3}/g;
					$self->nmisng->log->debug3("external program args were $svc->{Args}, now $finalargs");
				}

				my $programexit = 0;

				# save and restore any previously running alarm,
				# but don't bother subtracting the time spent here
				my $remaining = alarm(0);
				$self->nmisng->log->debug3("saving running alarm, $remaining seconds remaining");
				my $pid;

				# good enough, no atomic open required, removed after eval
				my $stderrsink = File::Temp::mktemp(File::Spec->tmpdir()."/nmis.XXXXXX");
				eval
				{
					my @responses;
					my $svcruntime = defined( $svc->{Max_Runtime} ) && $svc->{Max_Runtime} > 0 ? $svc->{Max_Runtime} : 0;

					local $SIG{ALRM} = sub { die "alarm\n"; };
					alarm($svcruntime) if ($svcruntime);    # setup execution timeout

					# run given program with given arguments and possibly read from it
					# program is disconnected from stdin; stderr goes into a tmpfile and is collected separately for diagnostics
					$self->nmisng->log->debug2("running external program '$svc->{Program} $finalargs', "
																		 . ( NMISNG::Util::getbool( $svc->{Collect_Output} ) ? "collecting" : "ignoring" )
																		 . " output" );
					$pid = open( PRG, "$svc->{Program} $finalargs </dev/null 2>$stderrsink |" );
					if ( !$pid )
					{
						alarm(0) if ($svcruntime);       # cancel any timeout
						$self->nmisng->log->error("cannot start service program $svc->{Program}: $!");
					}
					else
					{
						@responses = <PRG>;              # always check for output but discard it if not required
						close PRG;
						$programexit = $?;
						alarm(0) if ($svcruntime);       # cancel any timeout

						$self->nmisng->log->debug("service $service exit code is " . ( $programexit >> 8 ) );

						# consume and warn about any stderr-output
						if ( -f $stderrsink && -s $stderrsink )
						{
							open( UNWANTED, $stderrsink );
							my $badstuff = join( "", <UNWANTED> );
							chomp($badstuff);
							$self->nmisng->log->warn("Service program $svc->{Program} returned unexpected error output: \"$badstuff\"");
							close(UNWANTED);
						}

						if ( NMISNG::Util::getbool( $svc->{Collect_Output} ) )
						{
							# nagios has two modes of output *sigh*, |-as-newline separator and real newlines
							# https://nagios-plugins.org/doc/guidelines.html#PLUGOUTPUT
							if ($flavour_nagios)
							{
								# ditch any whitespace around the |
								my @expandedresponses = map { split /\s*\|\s*/ } (@responses);

								@responses = ( $expandedresponses[0] );    # start with the first line, as is
								# in addition to the | mode, any subsequent lines can carry any number of
								# 'performance measurements', which are hard to parse out thanks to a fairly lousy format
								for my $perfline ( @expandedresponses[1 .. $#expandedresponses] )
								{
									while ( $perfline =~ /([^=]+=\S+)\s*/g )
									{
										push @responses, $1;
									}
								}
							}

							# now determine how to save the values in question
							for my $idx ( 0 .. $#responses )
							{
								my $response = $responses[$idx];
								chomp $response;

								# the first line is special; it sets the textual status
								if ( $idx == 0 )
								{
									$self->nmisng->log->debug("service status text is \"$response\"");
									$status{status_text} = $response;
									next;
								}

								# normal expectation: values reported are unit-less, ready for final use
								# expectation not guaranteed by nagios
								my ( $k, $v ) = split( /=/, $response, 2 );
								my $rescaledv;

								if ($flavour_nagios)
								{
									# some nagios plugins report multiple metrics, e.g. the check_disk one
									# but the format for passing performance data is pretty ugly
									# https://nagios-plugins.org/doc/guidelines.html#AEN200

									$k = $1 if ( $k =~ /^'(.+)'$/ );    # nagios wants single quotes if a key has spaces

									# a plugin can report levels for warning and crit thresholds
									# and also optionally report possible min and max values;
									my ( $value_with_unit, $lwarn, $lcrit, $lmin, $lmax ) = split( /;/, $v, 5 );

									# any of those could be set to zero
									if ( defined $lwarn or defined $lcrit or defined $lmin or defined $lmax )
									{
										# note that putting this in status, ie. timed_data, isn't quite perfect
										# could go into inventory BUT might change on every poll, hence hard to track in inventory
										$status{limits}->{$k} = {
											warning  => $lwarn,
											critical => $lcrit,
											min      => $lmin,
											max      => $lmax
										};
									}

									# units: s,us,ms = seconds, % percentage, B,KB,MB,TB bytes, c a counter
									if ( $value_with_unit =~ /^([0-9\.]+)(s|ms|us|%|B|KB|MB|GB|TB|c)$/ )
									{
										my ( $numericval, $unit ) = ( $1, $2 );
										$self->nmisng->log->debug2("performance data for label '$k': raw value '$value_with_unit'");

										# imperfect storage location, pit vs inventory
										$status{units}->{$k} = $unit;    # keep track of the input unit
										$v = $numericval;

										# massage the value into a number for rrd
										my %factors = (
											'ms' => 1e-3,
											'us' => 1e-6,
											'KB' => 1e3,
											'MB' => 1e6,
											'GB' => 1e9,
											'TB' => 1e12
												);                                           # decimal here
										$rescaledv = $v * $factors{$unit} if ( defined $factors{$unit} );
									}
								}
								$self->nmisng->log->debug( "collected response '$k' value '$v'"
																					 . ( defined $rescaledv ? " rescaled '$rescaledv'" : "" ) );

								# for rrd storage, but only numeric values can be stored!
								# k needs sanitizing for rrd: only a-z0-9_ allowed
								my $rrdsafekey = $k;
								$rrdsafekey =~ s/[^a-zA-Z0-9_]/_/g;
								$rrdsafekey = substr( $rrdsafekey, 0, 19 );
								$Val{$rrdsafekey} = {
									value => defined($rescaledv) ? $rescaledv : $v,
									option => "GAUGE,U:U,$serviceheartbeat"
								};

								# record the relationship between extra readings and the DS names they're stored under
								# imperfect storage location, pit vs inventory
								$status{ds}->{$k} = $rrdsafekey;

								if ( $k eq "responsetime" )    # response time is handled specially
								{
									$responsetime = NMISNG::Util::numify($v);
								}
								else
								{
									$status{extra}->{$k} = NMISNG::Util::numify($v);
								}

							}
						}
					}
				};
				unlink($stderrsink);

				if ( $@ and $@ eq "alarm\n" )
				{
					kill('TERM', $pid);    # get rid of the service tester, it ran over time...
					$self->nmisng->log->error("service program $svc->{Program} exceeded Max_Runtime of $svc->{Max_Runtime}s, terminated.");
					$ret = 0;
					kill( "KILL", $pid );
				}
				else
				{
					# now translate the exit code into a service value (0 dead .. 100 perfect)
					# if the external program died abnormally we treat this as 0=dead.
					if ( WIFEXITED($programexit) )
					{
						$programexit = WEXITSTATUS($programexit);
						$self->nmisng->log->debug("external program terminated with exit code $programexit");

						# nagios knows four states: 0 ok, 1 warning, 2 critical, 3 unknown
						# we'll map those to 100, 50 and 0 for everything else.
						if ($flavour_nagios)
						{
							$ret = $programexit == 0 ? 100 : $programexit == 1 ? 50 : 0;
						}
						else
						{
							$ret = $programexit > 100 ? 100 : $programexit;
						}
					}
					else
					{
						$self->nmisng->log->warn("service program $svc->{Program} terminated abnormally!");
						$ret = 0;
					}
				}
				alarm($remaining) if ($remaining);    # restore previously running alarm
				$self->nmisng->log->debug3("restored alarm, $remaining seconds remaining");
			}
		}    # end of program/nagios-plugin service type
		else
		{
			# no recognised service type found
			$self->nmisng->log->error("skipping service \"$service\", invalid service type!");
			next;    # just do the next one - no alarms
		}

		# let external programs set the responsetime if so desired
		$responsetime = $timer->elapTime if ( !defined $responsetime );
		$status{responsetime} = NMISNG::Util::numify($responsetime);
		my $thisrun = time;

		# external programs return 0..100 directly, rest has 0..1
		my $serviceValue = ( $servicetype =~ /^(program|nagios-plugin)$/ ) ? $ret : $ret * 100;
		$status{status} = NMISNG::Util::numify($serviceValue);

		# sys::init does not automatically read the node view, but we clearly need it now
		if (!$V)
		{
			$S->readNodeView;
			$V = $S->view;
		}

		$V->{system}{"${service}_title"} = "Service $name";
		$V->{system}{"${service}_value"} = $serviceValue == 100 ? 'running' : $serviceValue > 0 ? "degraded" : 'down';
		$V->{system}{"${service}_color"} = $serviceValue == 100 ? 'white' : $serviceValue > 0 ? "orange" : 'red';

		$V->{system}{"${service}_responsetime"} = $responsetime;
		$V->{system}{"${service}_cpumem"} = $gotMemCpu ? 'true' : 'false';

		# now points to the per-service detail view. note: no widget info a/v at this time!
		delete $V->{system}->{"${service}_gurl"};
		$V->{system}{"${service}_url"}
			= "$C->{'<cgi_url_base>'}/services.pl?conf=$C->{conf}&act=details&node="
			. uri_escape($node)
			. "&service="
			. uri_escape($service);

		# let's raise or clear service events based on the status
		if ( $serviceValue == 100 )    # service is fully up
		{
			$self->nmisng->log->debug("$servicetype $name is available ($serviceValue)");

			# all perfect, so we need to clear both degraded and down events
			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "Service Down",
				level   => "Normal",
				element => $name,
				details => ( $status{status_text} || "" ),
				inventory_id => $inventory->id
			);

			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "Service Degraded",
				level   => "Warning",
				element => $name,
				details => ( $status{status_text} || "" ),
				inventory_id => $inventory->id
			);
		}
		elsif ( $serviceValue > 0 )    # service is up but degraded
		{
			$self->nmisng->log->debug("$servicetype $name is degraded ($serviceValue)");

			# is this change towards the better or the worse?
			# we clear the down (if one exists) as it's not totally dead anymore...
			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "Service Down",
				level   => "Fatal",
				element => $name,
				details => ( $status{status_text} || "" ),
				inventory_id => $inventory->id
			);

			# ...and create a degraded
			Compat::NMIS::notify(
				sys     => $S,
				event   => "Service Degraded",
				level   => "Warning",
				element => $name,
				details => ( $status{status_text} || "" ),
				context => {type => "service"},
				inventory_id => $inventory->id
			);
		}
		else    # Service is down
		{
			$self->nmisng->log->debug("$servicetype $name is down");

			# clear the degraded event
			# but don't just eventDelete, so that no state engines downstream of nmis get confused!
			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "Service Degraded",
				level   => "Warning",
				element => $name,
				details => ( $status{status_text} || "" ),
				inventory_id => $inventory->id
			);

			# and now create a down event
			Compat::NMIS::notify(
				sys     => $S,
				event   => "Service Down",
				level   => "Fatal",
				element => $name,
				details => ( $status{status_text} || "" ),
				context => {type => "service"},
				inventory_id => $inventory->id
			);
		}

		# figure out which graphs to offer
		# every service has these; cpu+mem optional, and totally custom extra are possible, too.
		my @servicegraphs = (qw(service service-response));

		# save result for availability history - one rrd file per service per node
		$Val{service} = {
			value  => $serviceValue,
			option => "GAUGE,0:100,$serviceheartbeat"
		};

		$cpu = -$cpu if ( $cpu < 0 );
		$Val{responsetime} = {
			value  => $responsetime,                  # might be a NOP
			option => "GAUGE,0:U,$serviceheartbeat"
		};
		if ($gotMemCpu)
		{
			$Val{cpu} = {
				value  => $cpu,
				option => "COUNTER,U:U,$serviceheartbeat"
			};
			$Val{memory} = {
				value  => $memory,
				option => "GAUGE,U:U,$serviceheartbeat"
			};

			# cpu is a counter, need to get the delta(counters)/period from rrd
			$status{memory} = NMISNG::Util::numify($memory);

			# fixme: should we omit the responsetime graph for snmp-based services??
			# it doesn't say too much about the service itself...
			push @servicegraphs, (qw(service-mem service-cpu));
		}

		my $fullpath = $S->create_update_rrd( data => \%Val,
																					type => "service",
																					item => $service,
																					inventory => $inventory );
		$self->nmisng->log->error("updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() ) if (!$fullpath);

		# known/available graphs go into storage, as subconcept => rrd => fn
		# rrd file for this should now be present and a/v, we want relative path,
		# not $fullpath as returned by create_update_rrd...
		my $dbname = $inventory->find_subconcept_type_storage(subconcept => "service",
																													type => "rrd");

		# check what custom graphs exist for this service
		# file naming scheme: Graph-service-custom-<servicename>-<sometag>.nmis,
		# and servicename gets lowercased and reduced to [a-z0-9\._]
		# note: this schema is known here, and in cgi-bin/services.pl
		my $safeservice = lc($service);
		$safeservice =~ s/[^a-z0-9\._]//g;

		opendir( D, $C->{'<nmis_models>'} ) or die "cannot open models dir: $!\n";
		my @cands = grep( /^Graph-service-custom-$safeservice-[a-z0-9\._-]+\.nmis$/, readdir(D) );
		closedir(D);

		map { s/^Graph-(service-custom-[a-z0-9\._]+-[a-z0-9\._-]+)\.nmis$/$1/; } (@cands);
		$self->nmisng->log->debug2( "found custom graphs for service $service: " . join( " ", @cands ) ) if (@cands);

		push @servicegraphs, @cands;

		# now record the right storage subconcept-to-filename set in the inventory
		my $knownones = $inventory->storage; # there's at least the main subconcept 'service'
		for my $maybegone (keys %$knownones)
		{
			next if ($maybegone eq "service" # that must remain
							 or grep($_ eq $maybegone, @servicegraphs)); # or a known one
			# ditch
			$inventory->set_subconcept_type_storage(type => "rrd", subconcept => $maybegone, data => undef);
		}
		for my $maybenew (@servicegraphs)
		{
			# add or update
			$inventory->set_subconcept_type_storage(type => "rrd", subconcept => $maybenew, data => $dbname);
		}

		if ($gotMemCpu)
		{
			# cpu is a counter! need to pull the most recent cpu value from timed data, and compute the delta(counters)/period
			# to do that we need to either query rrd (inefficient) or store both cpu_raw and cpu (cooked, average centiseconds per real second)
			my $newest = $inventory->get_newest_timed_data();

			# autovivifies but no problem
			my $prevcounter = ($newest->{success} && exists($newest->{data}->{service}->{cpu_raw}))? $newest->{data}->{service}->{cpu_raw} : 0;

			$status{cpu_raw} = $cpu;	# the counter
			# never done or done just now? zero
			$status{cpu} = ($lastrun && $thisrun != $lastrun)? (($cpu - $prevcounter) / ($thisrun - $lastrun)) : 0;
		}

		# update the inventory data, use what was created above
		# add in last_run
		$inventorydata->{last_run} = $thisrun;
		$inventory->data($inventorydata);
		$inventory->enabled(1);
		$inventory->historic(0);

		# TODO: enable this? needs to know some things to show potentially
		$inventory->data_info( subconcept => 'service', enabled => 0 );
		( my $op, $error ) = $inventory->save();
		$self->nmisng->log->error("service status saving inventory failed: $error") if ($error);

		# and add a new point-in-time record for this service
		# must provide datasets info as status info is pretty deep
		my %dspresent = (status => 1,  responsetime => 1 ); # standard
		# optional semi-standard
		for my $maybe (qw(memory cpu))
		{
			$dspresent{$maybe} = 1  if (exists $status{$maybe});
		}

		# extras collected from a program
		map { $dspresent{$_} =1 } (values %{$status{ds}})
				if (ref($status{ds}) eq "HASH");

		$error = $inventory->add_timed_data(data => \%status,
																				derived_data => {},
																				time => NMISNG::Util::numify($thisrun),
																				datasets => { "service" => \%dspresent },
																				subconcept => "service" );
		$self->nmisng->log->error("service timed data saving failed: $error") if ($error);
	}

	# if we made changes, we have to update the node view file
	$S->writeNodeView if ($V);

	$self->nmisng->log->debug("Finished");
}

# acquire a lock for this node, mark it with the given type
# args: type (required),
# lock (optional, must be held and live; if given the lock's type is updated)
#
# returns: hashref, error/conflict/type/handle
# error is set on fault, conflict holds pid of other holder IFF conflicting,
# type is set from conflict or arg, handle is the open fh, file
#
# note: mostly irrelevant, nmisd workers normally don't start jobs if clashing
sub lock
{
	my ($self, %args) = @_;
	my $lock = $args{lock} // {};

	my $config = $self->nmisng->config;
	my $fn = $lock->{file} = $config->{'<nmis_var>'}."/".$self->name.".lock";
	$lock->{type} = $args{type};

	# create if not present yet
	if (!-f $fn)
	{
		open(F, ">$fn") or return { error => "Failed to create lock file $fn: $!" };
		close(F);

		# ignore any problems with the perms, that's just to appease the selftest
		NMISNG::Util::setFileProtDiag(file => $fn,
																	username => $config->{nmis_user},
																	groupname => $config->{nmis_group},
																	permission => $config->{os_fileperm});
	}

	# open if not already open
	my $fhandle = $lock->{handle};
	if (!defined $fhandle)
	{
		if (!open($fhandle, "+<", $fn))
		{
			return { error => "Failed to open lock file $fn: $!" };
		}
		$lock->{handle} = $fhandle;

		# lock if not given an already open lock to adjust, but don't block
		if (!flock($fhandle, LOCK_EX|LOCK_NB))
		{
			my ($pid,$op) = split(/\s+/, <$fhandle>);
			close($fhandle);
			return { conflict => ($pid || -1), type => ($op || "N/A") };
		}
	}

	# write out our stuff - may upgrade the lock's type
	seek($fhandle,0,0);
	print $fhandle "$$ $lock->{type}\n";
	truncate($fhandle, tell($fhandle));
	$fhandle->autoflush;

	return $lock;
}

# unlock an existing lock and cleans up the lockfile afterwards
# args: lock
# returns: undef if ok, error otherwise
sub unlock
{
	my ($self, %args) = @_;
	my $lock = $args{lock};

	return "Invalid lock structure!" if (ref($lock) ne "HASH" or !$lock->{file}
																			 or !$lock->{handle});
	my @unhappies;
	if (!flock($lock->{handle}, LOCK_UN))
	{
		push (@unhappies, "failed to unlock $lock->{file}: $!"); # but continue...
	}
	close($lock->{handle})
			or (push @unhappies, "failed to close $lock->{handle} for $lock->{file}: $!");
	unlink($lock->{file}) or (push @unhappies, "failed to unlink $lock->{file}: $!");
	return @unhappies? join("\n", @unhappies) : undef;
}


# perform collect operation for this one node
# args: self, wantsnmp and wantwmi (both required),
#  starttime (optional, default: now),
#  force (optiona, default 0)
#
# returns: hashref, keys success/error/locked,
#  success 0 + locked 1 is for early bail-out due to collect/update lock
sub collect
{
	my ($self, %args) = @_;
	my ($wantsnmp, $wantwmi,$force) = @args{"wantsnmp","wantwmi","force"};

	my $name = $self->name;
	my $pollTimer = Compat::Timing->new;
	my $C = $self->nmisng->config;

	$self->nmisng->log->debug("Starting collect, node $name, want SNMP: ".($wantsnmp?"yes":"no")
														.", want WMI: ".($wantwmi?"yes":"no"));
	$0 = "nmisd worker collect $name";

	# try to lock the node (announcing what for)
	$self->nmisng->log->debug2("Getting lock for node $name");
	my $lock = $self->lock(type => 'collect');
	return { error => "failed to lock node: $lock->{error}" } if ($lock->{error}); # a fault, not a lock

	# somebody else holds the lock for any reason?
	if ($lock->{conflict})
	{
		# note that update lock is NOT considered an error when we're polling frequently
		my $severity = ($lock->{type} eq "update")? "info":"warn";

		$self->nmisng->log->$severity("skipping collect for node $name: active $lock->{type} lock held by $lock->{conflict}");
		return { error => "$lock->{type} lock exists for node $name", locked => 1 };
	}

	my $S = NMISNG::Sys->new;

	# if the init fails attempt an update operation instead
	if (!$S->init( node => $self,
									snmp => $wantsnmp,
									wmi => $wantwmi,
									policy => $self->configuration->{polling_policy},
			))
	{
		$self->nmisng->log->debug( "Sys init for $name failed: "
													. join( ", ", map { "$_=" . $S->status->{$_} } (qw(error snmp_error wmi_error)) ) );

		$self->nmisng->log->warn("Sys init for node $name failed, switching to update operation instead");
		my $res = $self->update(lock => $lock); # 'upgrade' the one lock we currently hold
		# collect will have to wait until a next run...but do clean the lock up now
		return $res;
	}

	my $catchall_inventory = $S->inventory( concept => 'catchall' );
	my $catchall_data = $catchall_inventory->data_live();

	# record that we are trying a collect/poll;
	# last_poll (and last_poll_wmi/snmp) only record successfully completed operations
	$catchall_data->{last_poll_attempt} = $args{starttime} // Time::HiRes::time;


	$self->nmisng->log->debug( "node=$name "
														 . join( " ", map { "$_=" . $catchall_data->{$_} }
																		 (qw(group nodeType nodedown snmpdown wmidown)) ) );

	# update node info data, merge in the node's configuration (which was loaded by sys' init)
	$S->copyModelCfgInfo( type => 'all' );
	$S->readNodeView;    # s->init does NOT load that, but we need it as we're overwriting some view info

	# look for any current outages with options.nostats set,
	# and set a marker in nodeinfo so that updaterrd writes nothing but 'U'
	my $outageres = NMISNG::Outage::check_outages(node => $self, time => time);
	if (!$outageres->{success})
	{
		$self->nmisng->log->error("Failed to check outage status for $name: $outageres->{error}");
	}
	else
	{
		$catchall_data->{admin}->{outage_nostats} = ( List::Util::any { ref($_->{options}) eq "HASH"
																																				&& $_->{options}->{nostats} }
																									@{$outageres->{current}} ) ? 1 : 0;
	}

	# run an update INSTEAD if no update poll time is known
	if ( !exists( $catchall_data->{last_update} ) or !$catchall_data->{last_update} )
	{
		$self->nmisng->log->warn("'last update' time not known for $name, switching to update operation instead");
		my $res = $self->update(lock => $lock); # tell update to reuse/upgrade the one lock already held
		# collect will have to wait until a next run...
		return $res;
	}

	$self->nmisng->log->debug("node=$catchall_data->{name} role=$catchall_data->{roleType} type=$catchall_data->{nodeType} vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}");

	# are we meant to and able to talk to the node?
	if ($self->pingable(sys => $S) && $self->configuration->{collect})
	{
		# snmp-enabled node? then try to open a session (and test it)
		if ($S->status->{snmp_enabled})
		{
			my $candosnmp = $S->open(
				timeout      => $C->{snmp_timeout},
				retries      => $C->{snmp_retries},
				max_msg_size => $C->{snmp_max_msg_size},

				# how many oids/pdus per bulk request, or let net::snmp guess a value
				max_repetitions => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || undef,

				# how many oids per simple get request for getarray, or default (no guessing)
				oidpkt => $catchall_data->{max_repetitions} || $C->{snmp_max_repetitions} || 10, );


			# failed altogether?
			if (!$candosnmp or $S->status->{snmp_error})
			{
				$self->nmisng->log->error("SNMP session open to $name failed: " . $S->status->{snmp_error} );
				$S->disable_source("snmp");
				$self->handle_down(sys => $S, type => "snmp", details => $S->status->{snmp_error});
			}
			# or did we have to fall back to the backup address for this node?
			elsif ($candosnmp && $S->status->{fallback})
			{
				Compat::NMIS::notify(sys => $S,
														 event => "Node Polling Failover",
														 element => undef,
														 details => ("SNMP Session switched to backup address \""
																				 . $self->configuration->{host_backup}.'"'),
														 context => { type => "node" });
			}
			# or are we using the primary address?
			elsif ($candosnmp)
			{
				Compat::NMIS::checkEvent(sys => $S,
																 event => "Node Polling Failover",
																 upevent => "Node Polling Failover Closed", # please log it thusly
																 element => undef,
																 level => "Normal",
																 details => ("SNMP Session using primary address \"".
																						 $self->configuration->{host}.'"'), );
			}
			$self->handle_down(sys => $S, type => "snmp", up => 1, details => "snmp ok")
					if ($candosnmp);
		}

		# returns 1 if one or more sources have worked,
		# also updates snmp/wmi down states in nodeinfo/catchall
		# and sets the relevant last_poll_xyz markers
		my $updatewasok = $self->collect_node_info(sys=>$S, time_marker => $args{starttime} // Time::HiRes::time);
		my $curstate = $S->status;  # collect_node_info does NOT disable faulty sources!

		# was snmp ok? should we bail out? note that this is interpreted to apply
		# to ALL sources being down simultaneously, NOT just snmp.
		# otherwise a wmi-only node would never be polled.
		# fixme: likely needs companion wmi_stop_polling_on_error, and both criteria would
		# need to be satisfied for stopping
		if (    NMISNG::Util::getbool( $C->{snmp_stop_polling_on_error} )
						and NMISNG::Util::getbool( $catchall_data->{snmpdown} )
						and NMISNG::Util::getbool( $catchall_data->{wmidown} ) )
		{
			$self->nmisng->log->info(
				"Polling stopped for $catchall_data->{name} because SNMP and WMI had errors, snmpdown=$catchall_data->{snmpdown} wmidown=$catchall_data->{wmidown}"
					);
		}
		elsif ($updatewasok)    # at least some info was retrieved by wmi or snmp
		{
			# fixme9 gone in nmis9			if ( $model or $nvp{info} )
			if (0)
			{
				print
						"MODEL $S->{name}: role=$catchall_data->{roleType} type=$catchall_data->{nodeType} sysObjectID=$catchall_data->{sysObjectID} sysObjectName=$catchall_data->{sysObjectName}\n";
				print "MODEL $S->{name}: sysDescr=$catchall_data->{sysDescr}\n";
				print
						"MODEL $S->{name}: vendor=$catchall_data->{nodeVendor} model=$catchall_data->{nodeModel} interfaces=$catchall_data->{ifNumber}\n";
			}

			# at this point we need to tell sys that dead sources are to be ignored
			for my $source (qw(snmp wmi))
			{
				if ( $curstate->{"${source}_error"} )
				{
					$S->disable_source($source);
				}
			}
			# remember when the collect poll last completed (doesn't mean successfully!),
			# this isn't saved  until later so set it early so functions can use it
			$catchall_data->{last_poll} = $args{starttime} // Time::HiRes::time;
			# we polled something, so outside of dead node demotion grace period
			delete $catchall_data->{demote_grace};

			# fixme: why no error handling for any of these?

			# get node data and store in rrd
			$self->collect_node_data(sys => $S);
			# get intf data and store in rrd
			my $ids = $self->get_inventory_ids( concept => 'interface' );
			$self->collect_intf_data(sys => $S) if( @$ids > 0);

			$self->collect_systemhealth_data(sys => $S);
			$self->collect_cbqos(sys => $S, update => 0);

			$self->collect_server_data( sys => $S );

			# Custom Alerts, includes process_alerts
			$self->handle_custom_alerts(sys => $S);
		}
		else
		{
			my $msg = "updateNodeInfo for $name failed: "
				. join( ", ", map { "$_=" . $S->status->{$_} } (qw(error snmp_error wmi_error)) );
			$self->nmisng->log->error($msg);
		}
	}

	# Need to poll services under all circumstances, i.e. if no ping, or node down or set to no collect
	# but try snmp services only if snmp is actually ok
	$self->collect_services( sys => $S,
													 snmp => NMISNG::Util::getbool( $catchall_data->{snmpdown} ) ? 'false' : 'true',
													 force => $force );

	# don't let that function perform the rrd update, we want to add the polltime to it!
	my $reachdata = $self->compute_reachability( sys => $S, delayupdate => 1 );

	# compute thresholds with the node, if configured to do so
	if ( NMISNG::Util::getbool($C->{global_threshold}) && # any thresholds whatsoever?
			 NMISNG::Util::getbool( $C->{threshold_poll_node} ) ) # and computed as part of collect or not?
	{
		$self->nmisng->compute_thresholds(sys => $S, running_independently => 0);
	}

	# add some timing info for the gui
	my $V = $S->view;
	$V->{system}{lastCollect_value} = NMISNG::Util::returnDateStamp($catchall_data->{last_poll});
	$V->{system}{lastCollect_title} = 'Last Collect';

	$S->writeNodeView;
	$S->writeNodeInfo();

	# done with the standard work, now run any plugins that offer collect_plugin()
	for my $plugin ($self->nmisng->plugins)
	{
		my $funcname = $plugin->can("collect_plugin");
		next if ( !$funcname );

		$self->nmisng->log->debug("Running collect plugin $plugin with node $name");
		my ( $status, @errors );
		my $prevprefix = $self->nmisng->log->logprefix;
		$self->nmisng->log->logprefix("$plugin\[$$\] ");
		eval { ( $status, @errors ) = &$funcname( node => $name,
																							sys => $S,
																							config => $C,
																							nmisng => $self->nmisng ); };
		$self->nmisng->log->logprefix($prevprefix);
		if ( $status >= 2 or $status < 0 or $@ )
		{
			$self->nmisng->log->error("Plugin $plugin failed to run: $@") if ($@);
			for my $err (@errors)
			{
				$self->nmisng->log->error("Plugin $plugin: $err");
			}
		}
		elsif ( $status == 1 )    # changes were made, need to re-save the view and info files
		{
			$self->nmisng->log->debug("Plugin $plugin indicated success, updating node and view files");
			$S->writeNodeView;
		}
		elsif ( $status == 0 )
		{
			$self->nmisng->log->debug("Plugin $plugin indicated no changes");
		}
	}
	my $polltime = $pollTimer->elapTime();
	$self->nmisng->log->debug("polltime for $name was $polltime");
	$reachdata->{polltime} = {value => $polltime, option => "gauge,0:U"};

	# parrot the previous reading's update time
	my $prevval = "U";
	if ( my $rrdfilename = $S->makeRRDname( graphtype => "health" ) )
	{
		my $infohash = RRDs::info($rrdfilename);
		$prevval = $infohash->{'ds[updatetime].last_ds'} if ( defined $infohash->{'ds[updatetime].last_ds'} );
	}
	$reachdata->{updatetime} = {value => $prevval, option => "gauge,0:U," . ( 86400 * 3 )};
	if (!$S->create_update_rrd(data=> $reachdata, type=>"health",inventory=>$catchall_inventory))
	{
		$self->nmisng->log->error("updateRRD failed: " . NMISNG::rrdfunc::getRRDerror() );
	}

	my $pit = {};
	my $previous_pit = $catchall_inventory->get_newest_timed_data();
	NMISNG::Inventory::parse_rrd_update_data( $reachdata, $pit, $previous_pit, 'health' );

	my $stats = $self->compute_summary_stats(sys => $S, inventory => $catchall_inventory );
	my $error = $catchall_inventory->add_timed_data( data => $pit, derived_data => $stats, subconcept => 'health',
																					time => $catchall_data->{last_poll}, delay_insert => 1 );
	$self->nmisng->log->error("timed data adding for health failed: $error") if ($error);

	$S->close;
	$catchall_inventory->save();
	if (my $issues = $self->unlock(lock => $lock))
	{
		$self->nmisng->log->error($issues);
	}

	$self->nmisng->log->debug("Finished");
	return { success => 1};
}

1;
