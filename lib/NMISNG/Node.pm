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
use List::Util;
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
			$newvalue->{$no_more_tf} = NMISNG::Util::getbool($newvalue->{$no_more_tf}) if( $newvalue->{$no_more_tf} );
		}

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
	return (0, "Failed to retrieve inventories: $result->{error}")
			if (!$result->{success});

	my $gimme = $result->{model_data}->objects;
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
	return $self->nmisng->events->eventUpdate(%args);
}

sub eventsClean
{
	my ($self, $caller) = @_;
	return $self->nmisng->events->cleanNodeEvents( $self, $caller );	
}

sub get_events_model
{
	my ( $self, %args ) = @_;
	# modify filter to make sure it's getting just events for this node
	$args{filter} //= {};;
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
	# fixme: add better error handling
	if ($result->{success} && $result->{model_data}->count)
	{
		return [ map { $_->{_id}->{value} } (@{$result->{model_data}->data()}) ];
	}
	else
	{
		return [];
	}
}

# wrapper around the global inventory model accessor
# which adds in the  current node's uuid and cluster id
# returns: hash ref with success, error, model_data
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
	my $filter = $args{filter};

	$filter->{cluster_id} = $self->cluster_id;
	$filter->{node_uuid} = $self->uuid;

	return $self->nmisng->get_distinct_values( collection => $collection, key => $key, filter => $filter );
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
	my $result = $self->nmisng->get_inventory_model(
		class_name => { "concept" => \&NMISNG::Inventory::get_inventory_class },
		sort => { _id => 1 },				# normally just one object -> no cost
		%args);
	return (undef, "failed to get inventory: $result->{error}")
			if (!$result->{success} && !$create);

	my $model_data = $result->{model_data};
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

# sub inventory_indices_by_subconcept
# {

# }

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
	my $inventory =  $self->inventory( concept => "catchall" );	
	my $info = ($inventory) ? $inventory->data : {};
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
	return (0, "Failed to retrieve inventories: $result->{error}")
			if (!$result->{success});

	my $gimme = $result->{model_data}->objects;
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
# returns tuple, ($sucess,$error_message),
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
		return (1,undef);
}

1;
