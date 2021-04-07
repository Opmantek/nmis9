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
our $VERSION = "9.2";

use strict;

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
use POSIX qw(:sys_wait_h :signal_h);
use Fcntl qw(:DEFAULT :flock :mode); # for flock
use Net::SNMP;									# for oid_lex_sort
use File::Temp;

use NMISNG::Util;
use NMISNG::DB;
use NMISNG::Inventory;
use NMISNG::Sapi;								# for collect_services()
use NMISNG::MIB;
use NMISNG::Sys;
use NMISNG::Notify;
use NMISNG::rrdfunc;

use Compat::IP;

# create a new node object
# params:
#   uuid - required
#   nmisng - NMISNG object, required ( for model loading, config and log)
#   id or _id - optional db id - if given, then the node is expected
#    to be pre-existing and its node data is loaded from db.
#    if that fails, the node is treated as new.
#
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
		uuid    => $args{uuid},
		collection => $args{nmisng}->nodes_collection()
	};
	bless( $self, $class );

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

	if ($self->{_id}) # === !is_new
	{
		# not loadable? then treat it as a new node
		undef $self->{_id} if (!$self->_load);
	}
	
	return $self;
}

###########
# Private:
###########

# fill in properties we want and expect
# args: hash ref (configuration)
# returns: same hash ref, modified elements
sub _defaults
{
	my ( $self, $configuration ) = @_;

	$configuration->{port} //= 161;
	$configuration->{max_msg_size} //= $self->nmisng->config->{snmp_max_msg_size};
	$configuration->{max_repetitions} //= 0;
	# and let's set the default polling policy if none was given
	$configuration->{polling_policy} ||= "default";

	return $configuration;
}

# mark the object as changed to tell save() that something needs to be done
# each section is tracked for being dirty, if it's 1 it's dirty
#
# args: nothing or (0) or (N,section)
#  nothing: no changes,
#  0: clear all dirty flags,
#  value+section: set/clear flag for that section
#
# returns: overall dirty 1/0
sub _dirty
{
	my ( $self, $newvalue, $whatsdirty ) = @_;

	# clear all dirty
	if (defined($newvalue)  && !$newvalue)
	{
		$self->{_dirty} = {};
		return 0;
	}
	elsif ( defined($newvalue) )
	{
		$self->{_dirty}->{$whatsdirty} = $newvalue;
		return 1 if ($newvalue);
	}

	my @keys = keys %{$self->{_dirty}};
	foreach my $key (@keys)
	{
		return 1 if ( $self->{_dirty}{$key} );
	}
	return 0;
}

# load data for this node from the database
# params: none
# returns: 1 if node data was loadable, 0 otherwise
sub _load
{
	my ($self) = @_;

	my $query = NMISNG::DB::get_query( and_part => { uuid => $self->uuid }, no_regex => 1 );
	my $cursor = NMISNG::DB::find(
		collection => $self->collection,
		query      => $query,
		limit => 1,									# there can't be more than one
	);

	my $entry;
	if ($cursor)
	{
		$entry = $cursor->next;
	}
	if ($entry)
	{
		# translate from db to our local names where needed,
		# and load the parts that we know about...
		$self->{_id} = $entry->{_id};
		$self->{_name} = $entry->{name};
		$self->{_cluster_id} = $entry->{cluster_id};

		$self->{_overrides} = {};
		# translate the overrides keys back; note that some other get_nodes_model callers
		# also need to know about this
		for my $uglykey (keys %{$entry->{overrides}})
		{
			# must handle compat/legacy load before correct structure in db
			my $nicekey = $uglykey =~ /^==([A-Za-z0-9+\/=]+)$/? Mojo::Util::b64_decode($1) : $uglykey;
			$self->{_overrides}->{$nicekey} = $entry->{overrides}->{$uglykey};
		}

		$self->{_configuration} = $entry->{configuration} // {}; # unlikely to be blank
		$self->{_activated} =
				(ref($entry->{activated}) eq "HASH"? # but fall back to old style active flag if needed
				 $entry->{activated} : { NMIS => (exists($self->{_configuration}->{active})?
																					$self->{_configuration}->{active} : 0)
				 });
		$self->{_addresses} = $entry->{addresses} if (ref($entry->{addresses}) eq "ARRAY");
		$self->{_aliases} = $entry->{aliases} if (ref($entry->{aliases}) eq "ARRAY");

		# ...but, for extensibility's sake, also load unknown extra stuff and drag it along
		my %unknown = map { ($_ => $entry->{$_}) } (grep(!/^(_id|uuid|name|cluster_id|overrides|configuration|activated|lastupdate|aliases|addresses)$/, keys %$entry));
		$self->{_unknown} = \%unknown;

		$self->_dirty(0);						# nothing is dirty at this point
	}
	else
	{
		$self->nmisng->log->warn("NMISNG::Node with uuid ".$self->uuid." seems nonexistent in the DB?");
	}
	return $entry? 1:0;
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

# get/set cluster_id for this node
# args: cluster_id (optional, must be single id)
#  if a new value is set, then the node will be
#  marked dirty and will require save()ing.
#
# returns: current/new cluster_id
#
# fixme9: for multipolling, cluster_id becoming an array, this will require reworking
sub cluster_id
{
	my ($self, $newvalue) = @_;
	if (defined $newvalue)
	{
		# warn about fiddlery, not initial setting
		$self->nmisng->log->warn("NMISNG::Node::cluster_id was set to new value $newvalue!")
				if ($self->{_cluster_id} && $newvalue ne $self->{_cluster_id});

		$self->_dirty(1, "cluster_id");
		$self->{_cluster_id} = $newvalue;
	}

	return $self->{_cluster_id};
}

# get-set accessor for node name
# args: node name, optional
#
# attention: only initial setting of the node name is supported,
# renaming is more complex and requires use of the rename() function
#
# returns: current node name
sub name
{
	my ($self, $newvalue) = @_;

	if (defined($newvalue) && !defined($self->{_name}))
	{
		$self->{_name} = $newvalue;
		$self->_dirty(1, "name");
	}
	return $self->{_name};
}

# getter-setter for unknown/extra data
# that we drag along from the database
#
# args: hashref of new unknown data
# returns: hashref of existing unknown
sub unknown
{
	my ($self, $newvalue) = @_;

	if (ref($newvalue) eq "HASH")
	{
		$self->{_unknown} = $newvalue;
		$self->_dirty(1, "unknown");
	}
	return Clone::clone($self->{_unknown} // {});
}

# getter-setter for aliases data,
# which must be array of hashes with inner key alias
#
# args: new aliases array ref, optional
# returns: arrayref of current aliases structure
sub aliases
{
	my ($self, $newaliases) = @_;
	if (ref($newaliases) eq "ARRAY")
	{
		$self->{_aliases}  = $newaliases;
		$self->_dirty(1, "aliases");
	}
	return Clone::clone($self->{_aliases} // []);
}

# getter-setter for addresses data,
# which must be array of hashes with inner key address
#
# args: new addresses array ref, optional
# returns: arrayref of current addresses structure
sub addresses
{
	my ($self, $newaddys) = @_;
	if (ref($newaddys) eq "ARRAY")
	{
		$self->{_addresses}  = $newaddys;
		$self->_dirty(1, "addresses");
	}
	return Clone::clone($self->{_addresses} // []);
}

# fill in properties we want and expect
# args: hash ref (configuration)
# returns: same hash ref, modified elements
sub is_remote
{
	my ( $self ) = @_;

	if ($self->nmisng->config->{"cluster_id"} ne $self->cluster_id())
	{
		return 1;
	} else {
		return 0;
	}
}

# get-set accessor for node activation status
# args: hashref (=new activation info, productname => 0/1),
#  if given, node object is marked dirty and needs saving
# returns: hashref with current activation state (cloned)
sub activated
{
	my ($self, $newstate) = @_;
	if (ref($newstate) eq "HASH")
	{
		$self->_dirty(1, "activated");
		$self->{_activated} = $newstate;
		# propagate to the old-style active flag for compat
		$self->{_configuration}->{active} = $newstate->{NMIS}? 1:0;
	}
	return Clone::clone($self->{_activated});
}

# get/set the configuration for this node
#
# setting data means the configuration is dirty and will
#  be saved next time save is called, even if it is identical to what
#  is in the database
#
# getting will load the configuration if it's not already loaded and return a copy so
#   any changes made will not affect this object until they are put back (set) using this function
#
# params:
#  newvalue - if set will replace what is currently loaded for the config
#   and set the object to be dirty
#
# returns: configuration hash(ref, cloned)
sub configuration
{
	my ( $self, $newvalue ) = @_;

	if (ref($newvalue) eq "HASH")
	{
		# convert true/false to 0/1
		foreach my $no_more_tf (qw(active calls collect ping rancid threshold webserver))
		{
			$newvalue->{$no_more_tf} = NMISNG::Util::getbool($newvalue->{$no_more_tf})
					if (defined($newvalue->{$no_more_tf}));
		}

		# make sure activated.nmis is set and mirrors the old-style active flag
		$self->{_activated}->{NMIS} = $newvalue->{active} if (defined($newvalue->{active}));
		$self->_dirty(1, "activated");

		# fill in other defaults
		$newvalue = $self->_defaults($newvalue);

		# convert commasep services and depend to real arrays
		for my $wantarray (qw(services depend))
		{
			if (defined $newvalue->{$wantarray}
					&& ref($newvalue->{$wantarray}) ne "ARRAY")
			{
				# but ditch empty values
				$newvalue->{$wantarray} = [ map { $_ eq ''? () : $_ } (split(/\s*,\s*/, $newvalue->{$wantarray})) ];
			}
		}

		$self->{_configuration} = $newvalue;
		$self->_dirty( 1, 'configuration' );
	}

	return $self->{_configuration}? Clone::clone( $self->{_configuration} ) : {};  # cover the new node case
}

# remove this node from the db and clean up all leftovers:
# queued jobs, node configuration, inventories, timed data, events, opstatus entries
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

	# first, deactivate the node if not inactive already
	my $curcfg = $self->configuration;
	if ($curcfg->{activated}->{NMIS})
	{
		$curcfg->{activated}->{NMIS} = $curcfg->{active} = 0;
		$self->configuration($curcfg);
		$self->save;
	}

	# then remove any queued jobs for this node, if not in-progess
	my $result = $self->nmisng->get_queue_model("args.uuid" => [ $self->uuid ]);
	if (my $error = $result->error)
	{
		return (0, "Failed to retrieve queued jobs: $error");
	}
	for my $jobdata (@{$result->data})
	{
		return (0, "Cannot delete node while $jobdata->{type} job (id $jobdata->{_id}) is active!")
				if ($jobdata->{in_progress} and $jobdata->{type} ne "delete_nodes");

		if (my $error = $self->nmisng->remove_queue(id => $jobdata->{_id}))
		{
			return (0, "Failed to remove queued job $jobdata->{_id}: $error");
		}
	}

	# get all the inventory objects for this node
	# tell them to delete themselves (and the rrd files)

	# get everything, historic or not - make it instantiatable
	# concept type is unknown/dynamic, so have it ask nmisng
	$result = $self->get_inventory_model(
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

	# however, NOT all rrds are properly inventory-backed!
	# eg. health/health.rrd, health/mib2ip.rrd, misc/NetFlowStats.rrd...
	# so use the filesystem - except this is messy as it cannot take a potential custom common_database
	# scheme into account (ie. rrds not under /nodes/$lowercasednode/)
	# but az doesn't know of any way to enumerate the non-inventory-backed oddball rrds
	if (!$keeprrd)
	{
		my @whichdirs = ($self->nmisng->config->{database_root}."/nodes/".($self->name)); # new case-sensitive
		push @whichdirs, ($self->nmisng->config->{database_root}."/nodes/".lc($self->name)) # legacy lowercased
				if ($self->name ne lc($self->name));

		my @errors;
		eval { File::Find::find(
						 {
							 wanted => sub
							 {
								 my $fn = $File::Find::name;
								 next if (!-f $fn);
								 unlink($fn) or push @errors, "$fn: $!";
							 },
							 follow => 1,
						 },
						 @whichdirs);
		};
		push @errors, $@ if ($@);
		return (0, "Failed to delete some RRDs: ".join(" ", @errors)) if (@errors);
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

	# delete all (ie. historic and active) events for this node, irretrievably and immediately
	# note that eventsClean() is trying other high-level, non-deletion-related stuff
	# events_model by default filters for filter historic = 0 :-/
	$result = $self->get_events_model(filter => { historic => [0,1]},
																		fields_hash => { _id => 1});
	if (my $error = $result->error)
	{
		return (0, "Failed to retrieve events: $error");
	}
	my @gonerids = map { $_->{_id} } (@{$result->data});
	$result = NMISNG::DB::remove(collection => $self->nmisng->events_collection,
															 query => NMISNG::DB::get_query( and_part => { _id => \@gonerids } ));
	return (0, "Failed to delete events: $result->{error}") if (!$result->{success});

	# opstatus entries for this node
	$result = $self->nmisng->get_opstatus_model("context.node_uuid" => $self->uuid); #
	if (my $error = $result->error)
	{
		return (0, "Failed to retrieve opstatus entries: $error");
	}
	@gonerids = map { $_->{_id} } (@{$result->data});
	$result = NMISNG::DB::remove(collection => $self->nmisng->opstatus_collection,
															 query => NMISNG::DB::get_query( and_part => { _id => \@gonerids } ));
	return (0, "Failed to delete opstatus entries: $result->{error}") if (!$result->{success});

 	# finally delete the node record itself
	$result = NMISNG::DB::remove(
		collection => $self->collection,
		query      => NMISNG::DB::get_query( and_part => { _id => $self->{_id} }, no_regex => 1),
		just_one   => 1 );
	return (0, "Node config removal failed: $result->{error}") if (!$result->{success});

	$self->nmisng->log->debug("deletion of node ".$self->name." complete");
	$self->{_deleted} = 1;
	return (1,undef);
}

# convenience function to help create an event object
# see NMISNG::Event::new for required/possible arguments
sub event
{
	my ( $self, %args ) = @_;
	# fixme9: for multipolling, cluster_id becoming an array, this will require more precision
	$args{node_uuid} = $self->uuid;
	$args{node_name} = $self->name;
	my $event = $self->nmisng->events->event( %args );
	return $event;
}

# convenience function for adding an event to this node
# see NMISNG::Events::eventAdd for arguments
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
	# fixme9: for multipolling, cluster_id becoming an array, this will require more precision
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
	# fixme9: for multipolling, cluster_id becoming an array, this will require more precision
	$args{node_uuid} = $self->uuid;
	return $self->nmisng->events->eventLoad( %args );
}

sub eventLog
{
	my ($self, %args) = @_;
	# fixme9: for multipolling, cluster_id becoming an array, this will require more precision
	$args{node_name} = $self->name;
	$args{node_uuid} = $self->uuid; # fixme9: logevent doesn't use uuid yet
	return $self->nmisng->events->logEvent(%args);
}

sub eventUpdate
{
	my ($self, %args) = @_;
	my $event = $args{event};
	# fixme9: for multipolling, cluster_id becoming an array, this will require more precision
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
# returns: modeldata object (always, may be empty - check ->error)
sub get_events_model
{
	my ( $self, %args ) = @_;
	# modify filter to make sure it's getting just events for this node
	# fixme9: for multipolling, cluster_id becoming an array, this will require more precision
	$args{filter} //= {};
	$args{filter}->{node_uuid} = $self->uuid;
	# We need to send this for getting nodes of the poller
	$args{filter}->{cluster_id} = $args{filter}->{cluster_id} // $self->cluster_id();
	return $self->nmisng->events->get_events_model( %args );
}

# get a list of id's for inventory related to this node,
# useful for iterating through all inventory
# filters/arguments:
#  cluster_id, node_uuid, concept
# returns: array ref (may be empty)
sub get_inventory_ids
{
	my ( $self, %args ) = @_;

	# what happens when an error happens here?
	$args{fields_hash} = {'_id' => 1};

	my $result = $self->get_inventory_model(%args);

	if (!$result->error && $result->count)
	{
		# mongodb::oid differs from bson::oids, value() accessor only for compat
		return [ map {
			$_->{_id}->can("hex")? $_->{_id}->hex : $_->{_id}->value }
						 (@{$result->data()}) ];
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
		$inventory = $class->new(%args); # this doesn't report errors!

		return (undef, "failed to instantiate $class object!") if (!$inventory);
	}

	return ($inventory, undef);
}

# No args
# Return an array of concepts for this node
sub inventory_concepts
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter};
	$args{cluster_id} = $self->cluster_id();
	$args{node_uuid}  = $self->uuid();

	my $q = $self->nmisng->get_inventory_model_query( %args );
	my $retval = ();

	# print "q".Dumper($q);
	# query parts that don't look at $datasets could run first if we need optimisation
	my @prepipeline = (
		{ '$match' => $q },
		{ '$group' =>
			{ '_id' => { "concept" => '$concept'}  # group by subconcepts
		}}
  );
  my ($entries,$count,$error) = NMISNG::DB::aggregate(
		collection => $self->nmisng->inventory_collection,
		pre_count_pipeline => \@prepipeline, #use either pipe, doesn't matter
		allowtempfiles => 1
	);
	foreach my $entry (@$entries)
	{
		push @$retval, $entry->{_id}{concept};

	}
	return ($error) ? $error : $retval;
}

# get all subconcepts and any dataset found within that subconcept
# returns hash keyed by subconcept which holds hashes { subconcept => $subconcept, datasets => [...], indexed => 0/1 }
# args: - filter, basically any filter that can be put on an inventory can be used
#  enough rope to hang yourself here.
# special case arg: subconcepts gets mapped into datasets.subconcepts
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

# retrieve r/o inventory concept by section
# NOTE: Consider this function only safe for use by a daemon process with explicit setting use_cache=>0
#	    UNLESS daemon otherwise accommodates this limitation by deleting the cache as and when needed
#		as the cache only expires on completed execution of the calling process and this can cause undesired stale cached sections to otherwise be returned:
#			there is no delete cache entry mechanism yet when cached entries becomes stale.
# Is this cacheing really necessary? YES: tested with opReports QoS and JCoS reports and mongod behaves FAR better on devbox with 6gb memory.
#	Cacheing tested for opReports QoS and JCoS reports, using setting use_cache=>1, via webservice opmantek.pl with only 2 workers
#		and each new report generation (4 consecutive tests of each report type) logged per node initially 'not using cache' which is what is desired. 
# args: section (required), use_cache (default 1)
sub retrieve_section
{
	my ($self, %args) = @_;
	my $section = $args{section};
	my $use_cache = $args{use_cache} // 1;

	if (!$section)
	{
		return undef;
	}

	# we kill this particular cached section if $use_cache=0
	my $cache_key = "return_this_${section}";
	if (! $use_cache)
	{
		$self->{_retrieve_section}->{$cache_key} = {};
	}
	# we still cache this particular cached section irrespective of $use_cache setting
	# this cache entry will be destroyed before use on next call by same executing process if also called then with $use_cache=0
	if( !defined($self->{_retrieve_section}->{$cache_key}->{$section}) )
	{
		$self->nmisng->log->debug9("$self->{_name}: retrieve_section('$section'): not using cache");

		$self->{_retrieve_section}->{$cache_key}->{$section} = {};
		my $ids = $self->get_inventory_ids( concept => $section,
											filter => { historic => 0 } );
		foreach my $id (@$ids)
		{
			my ( $inventory, $error ) = $self->inventory( _id => $id );
			if ( !$inventory )
			{
				$self->nmisng->log->error("$self->{_name}: retrieve_section('$section'): Failed to get inventory with id:$id, error:$error");
				next;
			}
			my $D = $inventory->data();
			my $index = $D->{index} // $id;
			if (! defined($index) or $index eq "")
			{
				$index = $id;
			}
			$self->{_retrieve_section}->{$cache_key}->{$section}->{$index} = $D;
		}
		# not applicable to $self->_load() or $%self->save(), so calling $self->dirty() is not necessary
		#$self->_dirty( 1, "retrieve_section" );
	}
	else
	{
		$self->nmisng->log->debug9("$self->{_name}: retrieve_section('$section'): using cache");
	}
	return ($self->{_retrieve_section}->{$cache_key}? Clone::clone($self->{_retrieve_section}->{$cache_key}) : {});
}

# small r/o accessor for node activation status
# args: none
# returns: 1 if node is configured to be active
sub is_active
{
	my ($self) = @_;

	# check the new-style 'activated.NMIS' flag first,
	# then the old-style 'active' configuration property
	return $self->{_activated}->{NMIS} if (ref($self->{_activated}) eq "HASH"
																				 and defined $self->{_activated}->{NMIS});

	return $self->{_configuration}?
			NMISNG::Util::getbool($self->{_configuration}->{active}) : 0;
}

# returns 0/1 if the object is new or not.
# new means it is not yet in the database
sub is_new
{
	my ($self) = @_;
	return (defined($self->{_id})) ? 0 : 1;
}

# this is the most official reporter of coarse node status
# returns: 1 for reachable, 0 for unreachable, -1 for degraded
#
# reason for looking for events (instead of wmidown/snmpdown markers):
# underlying events state can change asynchronously (eg. fping), and the per-node status from the node
# file cannot be guaranteed to be up to date if that happens.
#
# fixme9: catchall node info is now almost always up to date,
# so looking for events should no longer be necessary
#
# fixme9: should be ditched in favour of precise_status' 'overall' result
#
sub coarse_status
{
	my ($self, %args) = @_;

	my ($inventory, $error) =  $self->inventory( concept => "catchall" );
	my $old_data = ($inventory && !$error)? $inventory->data() : {};
	my $catchall_data = (defined($args{catchall_data}) && %{$args{catchall_data}}) ? $args{catchall_data} : $old_data;

	# 1 for reachable
	# 0 for unreachable
	# -1 for degraded
	my $status = 1;

	# note: only looks for active and non-historic events
	my $node_down = "Node Down";
	my $snmp_down = "SNMP Down";
	my $wmi_down_event = "WMI Down";
	my $failover_event = "Node Polling Failover";

	# ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if ( NMISNG::Util::getbool($catchall_data->{ping},"invert")
			 and ( $self->eventExist($snmp_down) or $self->eventExist( $wmi_down_event)) )
	{
		$status = 0;
	}
	# ping enabled, but unpingable -> down
	elsif ( $self->eventExist($node_down) )
	{
		$status = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi or failover'd -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( NMISNG::Util::getbool($catchall_data->{collect}) and
					( $self->eventExist($snmp_down)
						or $self->eventExist($wmi_down_event)
						or $self->eventExist($failover_event) ))
	{
		$status = -1;
	}
	# let NMIS use the status summary calculations
	elsif (
		NMISNG::Util::getbool($self->nmisng->config->{node_status_uses_status_summary})
		and defined $catchall_data->{status_summary}
		and defined $catchall_data->{status_updated}
		and $catchall_data->{status_summary} <= 99
		and $catchall_data->{status_updated} > time - 500
			)
	{
		$status = -1;
	}

	return $status;
}

# this is a more precise status reporter than coarse_status
#
# returns: hash of error (if dud args),
#  overall (-1 deg, 0 down, 1 up),
#  snmp_enabled (0,1), snmp_status (0,1,undef if unknown),
#  ping_enabled and ping_status (note: ping status is 1 if primary or backup address are up)
#  wmi_enabled and wmi_status,
#  failover_status (0 failover, 1 ok, undef if unknown/irrelevant)
#  failover_ping_status (0 backup host is down, 1 ok, undef if irrelevant)
#  primary_ping_status (0 primary host is down, 1 ok, undef if irrelevant
sub precise_status
{
	my ($self) = @_;

	my ($inventory,$error) = $self->inventory(concept => 'catchall');
	return ( error => "failed to instantiate catchall inventory: $error") if ($error);

	my $catchall_data = $inventory->data(); # r/o copy good enough

	# fixme9: should be changed to ignore events in favour of just the
	# inventory, once OMK-5961 is done

	# reason for looking for events (instead of wmidown/snmpdown markers):
	# underlying events state can change asynchronously (eg. fpingd), and the per-node status from the node
	# file cannot be guaranteed to be up to date if that happens.

	# HOWEVER the markers snmpdown and wmidown are present iff the source was enabled at the last collect,
	# and if collect was true as well.
	my %precise = ( overall => 1, # 1 reachable, 0 unreachable, -1 degraded
									snmp_enabled =>  defined($catchall_data->{snmpdown})||0,
									wmi_enabled => defined($catchall_data->{wmidown})||0,
									ping_enabled => NMISNG::Util::getbool($catchall_data->{ping}),
									snmp_status => undef,
									wmi_status => undef,
									ping_status => undef,
									failover_status => undef, # 1 ok, 0 in failover, undef if unknown/irrelevant
									failover_ping_status => undef, # 1 backup host is pingable, 0 not, undef unknown/irrelevant
									primary_ping_status => undef,
			);

	my $downexists = $self->eventExist("Node Down");
	my $failoverexists = $self->eventExist("Node Polling Failover");
	my $backupexists = $self->eventExist("Backup Host Down");

	$precise{ping_status} = ($downexists?0:1) if ($precise{ping_enabled}); # otherwise we don't care
	$precise{wmi_status} = ($self->eventExist("WMI Down")?0:1) if ($precise{wmi_enabled});
	$precise{snmp_status} = ($self->eventExist("SNMP Down")?0:1) if ($precise{snmp_enabled});

	if ($self->configuration->{host_backup})
	{
		$precise{failover_status} = $failoverexists? 0:1;
		 # the primary is dead if all are dead or if we failed-over
		$precise{primary_ping_status} = ($downexists || $failoverexists)? 0:1;
		# the secondary is dead if known to be dead or if all are dead
		$precise{failover_ping_status} = ($backupexists || $downexists)? 0:1;
	}

	# overall status: ping disabled -> the WORSE one of snmp and wmi states is authoritative
	if (!$precise{ping_enabled}
			and ( ($precise{wmi_enabled} and !$precise{wmi_status})
						or ($precise{snmp_enabled} and !$precise{snmp_status}) ))
	{
		$precise{overall} = 0;
	}
	# ping enabled, but unpingable -> unreachable
	elsif ($precise{ping_enabled} && !$precise{ping_status} )
	{
		$precise{overall} = 0;
	}
	# ping enabled, pingable but dead snmp or dead wmi or failover -> degraded
	# only applicable is collect eq true, handles SNMP Down incorrectness
	elsif ( ($precise{wmi_enabled} and !$precise{wmi_status})
					or ($precise{snmp_enabled} and !$precise{snmp_status})
					or (defined($precise{failover_status}) && !$precise{failover_status})
					or (defined($precise{failover_ping_status}) && !$precise{failover_ping_status})
			)
	{
		$precise{overall} = -1;
	}
	# let NMIS use the status summary calculations, if recently updated
	elsif ( NMISNG::Util::getbool($self->nmisng->config->{node_status_uses_status_summary})
					and defined $catchall_data->{status_summary}
					and defined $catchall_data->{status_updated}
					and $catchall_data->{status_summary} <= 99
					and $catchall_data->{status_updated} > time - 500 )
	{
		$precise{overall} = -1;
	}
	else
	{
		$precise{overall} = 1;
	}
	return %precise;
}


# return nmisng object this node is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# return collection object this node is using
# It can be a setter
# WARNING! It should be loaded after (_load)
sub collection
{
	my ( $self, $newcollection ) = @_;

	$self->{collection} = $newcollection
		if ( $newcollection );
		
	return $self->{collection};
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

	if (ref($newvalue) eq "HASH")
	{
		$self->{_overrides} = $newvalue;
		$self->_dirty( 1, 'overrides' );
	}

	return ($self->{_overrides}? Clone::clone($self->{_overrides}) : {}); # cover the new node case
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
	my $server = $args{server};

	return (0, "Invalid new_name argument") if (!$newname);

	# note: this function and sub validate must apply the same restrictions.
	# '/' is one of the few characters that absolutely cannot work as
	# node name (b/c of file and dir names)
	return (0, "new_name argument contains forbidden character '/'") if ($newname =~ m!/!);

	my $nodenamerule = $self->nmisng->config->{node_name_rule} || qr/^[a-zA-Z0-9_. -]+$/;
	return (0, "new node name does not match 'node_name_rule' regular expression")
			if ($newname !~ $nodenamerule);


	return (1, "new_name same as current, nothing to do")
			if ($newname eq $old);

	my $clash = $self->nmisng->get_nodes_model(name => $newname);
	return (0, "A node named \"$newname\" already exists!")
			if ($clash->count);

	$self->nmisng->log->debug("Starting to rename node $old to new name $newname");
	# find the node's var files and  hardlink them - do not delete anything yet!
	my @todelete;

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
		my ($ok, $error, @oktorm) = $invinstance->relocate_storage(current => $old, new => $newname, inventory => $invinstance);
		return (0, "Failed to relocate inventory storage ".$invinstance->id.": $error")
				if (!$ok);
		# informational
		$self->nmisng->log->debug2("relocation reported $error") if ($error);

		# relocate storage returns relative names
		my $dbroot = $self->nmisng->config->{'database_root'};
		push @todelete, map { "$dbroot/$_" } (@oktorm);
	}

	# then update ourself and save
	$self->{_name} = $newname;
	$self->_dirty(1, 'name');
	my ($ok, $error) = $self->save;
	return (0, "Failed to save node record: $error") if ($ok <= 0);

	# at that point it Would Be Good if other nodes that depend on this one were reconfigured, too
	my $needme = $self->nmisng->get_nodes_model(filter => { "configuration.depend" => $old })->objects;
	if (my $errmsg = $needme->{error})
	{
		$self->nmisng->log->error("failed to lookup dependency nodes: $errmsg");
	}
	else
	{
		for my $othernode (@{$needme->{objects}})
		{
			my $othercfg = $othernode->configuration;
			$othercfg->{depend} = [ map { $_ eq $old? $newname : $_ } (@{$othercfg->{depend}}) ];
			$othernode->configuration($othercfg);
			$othernode->save;
		}
	}

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

# Save the node object to DB if it is dirty - note: node, not inventories
# returns tuple, ($success,$error_message),
# 0 if no saving required
#-1 if node is not valid,
# >0 if all good
#
# TODO/fixme9: error checking just uses assert right now, we may want
#   a differnent way of doing this
sub save
{
	my ($self, %args) = @_;

	return ( -1, "node is incomplete, not saveable yet" )
			if ($self->is_new && !$self->_dirty);
	return ( 0,  undef )          if ( !$self->_dirty() );

	my ( $valid, $validation_error ) = $self->validate();
	return ( $valid, $validation_error ) if ( $valid <= 0 );

	# massage the overrides for db storage,
	# as they may have keys with dots which mongodb < 3.6 doesn't support
	# simplest workaround: mark up with ==, then base64-encoded key.
	# note: only outer keys are checked
	# note also: node_admin's export and a few others use the raw db, so need to know this
	my %dbsafeovers = map { "==".Mojo::Util::b64_encode($_,'') => $self->{_overrides}->{$_} } (keys %{$self->{_overrides}});

	my ($result, $op);
	my %entry = ( uuid => $self->{uuid},
								name => NMISNG::DB::make_string($self->{_name}), # must treat as string even if it looks like a number
								cluster_id => $self->{_cluster_id},
								lastupdate => time, # time of last save
								configuration => $self->{_configuration},
								overrides => \%dbsafeovers,
								activated => $self->{_activated},
								addresses => $self->{_addresses} // [],
								aliases => $self->{_aliases} // [],
			);

	map { $entry{$_} = $self->{_unknown}->{$_}; } (grep(!/^(_id|uuid|name|cluster_id|overrides|configuration|activated|lastupdate)$/, keys %{$self->{_unknown}}));

	if ($self->is_new())
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->collection,
			record     => \%entry,
		);
		assert( $result->{success}, "Record inserted successfully " );
		$self->{_id} = $result->{id} if ( $result->{success} );

		$self->_dirty(0); # all clean now
		$op = 1;
	}
	else
	{

		$result = NMISNG::DB::update(
			collection => $self->collection,
			query      => NMISNG::DB::get_query( and_part => {uuid => $self->uuid}, no_regex => 1 ),
			freeform   => 1,					# we need to replace the whole record
			record     => \%entry
				);
		assert( $result->{success}, "Record updated successfully" );

		$self->_dirty(0);
		$op = 2;
	}
	return ( $result->{success} ) ? ( $op, undef ) : ( -2, $result->{error} );
}

# get the node's id, ie. its UUID,
# which is globally unique (even with multipolling, where cluster_id is an array)
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

	return (-2, "node '".$self->{_name}."' requires cluster_id") if ( !$self->{_cluster_id} );
	return (-2, "node requires name") if ( !$self->{_name} );

	my $configuration = $self->configuration;
	for my $musthave (qw(host group))
	{
		return (-1, "node '".$self->{_name}."' requires $musthave property")
				if (!$configuration->{$musthave} ); # empty or zero is not ok
	}

	# note: this function and sub rename must apply the same restrictions.
	# '/' is one of the few characters that absolutely cannot work as
	# node name (b/c of file and dir names)
	return (-1, "node name '".$self->{_name}."' contains forbidden character '/'")
			if ($self->{_name} =~ m!/!);

	my $nodenamerule = $self->nmisng->config->{node_name_rule} || qr/^[a-zA-Z0-9_. -]+$/;
	return (-1, "node name '".$self->{_name}."' does not match 'node_name_rule' regular expression")
			if ($self->{_name} !~ $nodenamerule);


	return (-3, "given netType '".$configuration->{netType}."' is not a known type: '".$self->nmisng->config->{nettype_list}."'")
			if (!grep($configuration->{netType} eq $_,
								split(/\s*,\s*/, $self->nmisng->config->{nettype_list})));
	return (-3, "given roleType '".$configuration->{roleType}."' is not a known type: '".$self->nmisng->config->{roletype_list}."'")
			if (!grep($configuration->{roleType} eq $_,
								split(/\s*,\s*/, $self->nmisng->config->{roletype_list})));
	
	# Threshold not defined, set to true by default
	if (!defined($configuration->{threshold})) {
		$configuration->{threshold} = 1;
		$self->nmisng->log->info("Threshold not defined. Setting to true by default");
	}

	# if addresses/aliases are present, they must be arrays of hashes, each hash with correct
	# inner property and expires must make sense
	for (["addresses","address"], ["aliases","alias"])
	{
		my ($outer,$inner) = @$_;
		next if (!exists $self->{"_$outer"});

		return (-2, "node ".$self->{_name}.": invalid $outer structure - must be array")
				if (ref($self->{"_$outer"}) ne "ARRAY");
		for my $record (@{$self->{"_$outer"}})
		{
			return (-3, "node ".$self->{_name}.": invalid $outer structure - entries must be hashes" )
					if (ref($record) ne "HASH");
			# record must have an alias/address field, nonblank, and address field must be a legit address
			return (-4, "node ".$self->{_name}.": invalid $outer structure - entry has no $inner property" )
					if (!defined($record->{$inner}) or $record->{$inner} eq "");
			return (-5, "node ".$self->{_name}.": invalid $outer structure - entry has no $inner property" )
					if (!defined($record->{$inner}) or $record->{$inner} eq "");

			return (-6, "node ".$self->{_name}.": invalid $outer structure - address record with invalid address")
					if ($outer eq "addresses" and $record->{$inner} !~ /^([0-9\.]+|[0-9a-fA-F:]+)$/);

			# and expires must be missing altogether or numeric
			# note that we allow explicit undef for convenience, as attrib deletion doesn't work well - yet
			return (-7, "node ".$self->{_name}.": invalid $outer structure - invalid expires attribute")
					if (defined($record->{expires})
							&& $record->{expires} !~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/);
		}
	}

	return (1,undef);
}

# this function accesses fping results if conf'd and a/v, or runs a synchronous ping
# args: self, sys (required), time_marker (optional)
# returns: 1 if pingable, 0 otherwise
sub pingable
{
	my ($self, %args) = @_;

	my $S    = $args{sys};
	my $RI   = $S->reach;     # reach table

	my $time_marker = $args{time_marker} || time;
	my $catchall_data = $S->inventory(concept => 'catchall')->data_live();

	my ( $ping_min, $ping_avg, $ping_max, $ping_loss, $pingresult, $lastping );

	my $nodename = $self->name;
	my $uuid = $self->uuid;
	my $C = $self->nmisng->config;

	if ( NMISNG::Util::getbool($self->configuration->{ping}))
	{
		# use fastping-sourced info if available and not stale
		my $mustping = 1;
		my $staleafter = $C->{fastping_maxage} || 900; # no fping updates in 15min -> ignore

		my ($pinginv,$error) = $self->inventory(concept => "ping"); # not indexed, one per node

		if ($error)
		{
			$self->nmisng->log->error("Failed to instantiate ping inventory: $error");
		}
		elsif (!$pinginv)						# fping hasn't saved one yet
		{
			$self->nmisng->log->debug("No ping inventory available yet");
		}
		else
		{
			my $newestping = $pinginv->get_newest_timed_data;
			if (!$newestping->{success})
			{
				$self->nmisng->log->error("Failed to get newest timed data: $newestping->{error}");
			}
			else
			{
				# copy the fastping data...
				$lastping = $newestping->{time};

				# ...if not stale
				if ((time - $lastping) < $staleafter)
				{
					$ping_min = $newestping->{data}->{ping}->{min_rtt};
					$ping_avg = $newestping->{data}->{ping}->{avg_rtt};
					$ping_max = $newestping->{data}->{ping}->{max_rtt};
					$ping_loss = $newestping->{data}->{ping}->{loss};

					$self->nmisng->log->debug2("$uuid ($nodename = $newestping->{data}->{ip}) PINGability at $lastping min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");

					# ...and use the backup host data if the primary is unreachable
					if (defined($self->configuration->{host_backup})
							&& $self->configuration->{host_backup}
							&& $ping_loss == 100)
					{
						$ping_min = $newestping->{data}->{ping}->{backup_min_rtt};
						$ping_avg = $newestping->{data}->{ping}->{backup_avg_rtt};
						$ping_max = $newestping->{data}->{ping}->{backup_max_rtt};
						$ping_loss = $newestping->{data}->{ping}->{backup_loss};

						$self->nmisng->log->debug2("$uuid ($nodename = $newestping->{data}->{backup_ip}) PINGability at $lastping min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%");
					}
					$pingresult = ( $ping_loss < 100 ) ? 100 : 0;
				}
			}
		}
		$mustping = !defined($pingresult); # nothing or nothing fresh found?

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
					= $self->ext_ping( host => $host, packet => $packet, retries => $retries, timeout => $timeout );

			$pingresult = defined $ping_min ? 100 : 0;    # ping_min is undef if unreachable.
			$lastping = Time::HiRes::time;

			if (!$pingresult && (my $fallback = $self->configuration->{host_backup}))
			{
				$self->nmisng->log->info("Starting internal ping of ($nodename = backup address $fallback) with timeout=$timeout retries=$retries packet=$packet");
				( $ping_min, $ping_avg, $ping_max, $ping_loss) = $self->ext_ping(host => $fallback,
																																				 packet => $packet, retries => $retries,
																																				 timeout => $timeout );
				$pingresult = defined $ping_min ? 100 : 0;              # ping_min is undef if unreachable.
				$lastping = Time::HiRes::time;
			}
		}
		# at this point ping_{min,avg,max,loss}, lastping and pingresult are all set

		# in the fping case all up/down events are handled by it, otherwise we need to do that here
		# this includes the case of a faulty fping worker
		if ($mustping)
		{
			# save the statistics/results first
			my $timeddata = {
				min_rtt => $ping_min,
				avg_rtt => $ping_avg,
				max_rtt => $ping_max,
				loss => $ping_loss,
				ip => undef,						# we don't know that with extping
			};

			# get the node's ping inventory, and add timed data for it
			# timed data is only possible for a particular inventory.
			# but even with separate subconcepts, timed data cannot be saved 'incrementally'
			# result: the collect code and this fping code cannot safely share
			# the catchall inventory's timed data
			my ($pinginv,$error) = $self->inventory(concept => "ping", create => 1,
																							data => { }, path_keys => []); # not indexed, one per node
			if ($error or !$pinginv)
			{
				$self->nmisng->log->error("Failed to instantiate ping inventory: $error");
			}
			else
			{
				$pinginv->save if ($pinginv->is_new); # timed data only possible once inventory is in the db

				# this saves both timed data and the inventory
				my $error = $pinginv->add_timed_data(
					time => $lastping,
					data => $timeddata,
					derived_data => {},
					subconcept => "ping",
						);
				$self->nmisng->log->error("Failed to add ping timed data: $error") if ($error);
			}

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
					# note: up event is handled regardless of snmpdown/pingonly/snmponly
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
	}
	else
	{
		$self->nmisng->log->debug("($nodename) not configured for pinging");
		$RI->{pingresult} = $pingresult = 100;    # results for sub runReach
		$RI->{pingavg}    = 0;
		$RI->{pingloss}   = 0;
	}

	# cleanup, property deprecated, use get_newest_timed_data for concept ping
	delete $catchall_data->{last_ping} if exists $catchall_data->{last_ping};

	$self->nmisng->log->debug("Finished with exit="
														. ( $pingresult ? 1 : 0 )
														. ", nodedown=$catchall_data->{nodedown}" );

	return ( $pingresult ? 1 : 0 );
}

# tiny helper that makes the down type vs. event name relationship available
# args: none, returns: hash ref
sub handle_down_eventnames
{
	return {
		'snmp' => "SNMP Down",
		'wmi'  => "WMI Down",
		'node' => "Node Down",
		'failover' => "Node Polling Failover",
		'backup' => "Backup Host Down",
	};
}

# create event for node that has <something> down, or clear said event (and state)
# args: self, sys, type (all required), details (optional),
# up (optional, set to clear event, default is create)
#
# currently understands snmp, wmi, node (=the whole node),
#  failover (=primary down, switching to backup address),
#  backup (=the host_backup address is down)
#
# also updates <something>down flag in node info for snmp, wmi and node.
#
# returns: nothing
sub handle_down
{
	my ($self, %args) = @_;

	my ($S, $typeofdown, $details, $goingup) = @args{"sys", "type", "details", "up"};
	return if ( ref($S) ne "NMISNG::Sys" or $typeofdown !~ /^(snmp|wmi|node|failover|backup)$/ );

	$goingup = NMISNG::Util::getbool($goingup);
	my $eventname = &handle_down_eventnames->{$typeofdown};
	$details ||= "$typeofdown error";

	my $eventfunc = ( $goingup ? \&Compat::NMIS::checkEvent : \&Compat::NMIS::notify );
	&$eventfunc(
		sys     => $S,
		event   => $eventname,
		# use specific failover closing event name
		upevent => ($typeofdown eq "failover"? "Node Polling Failover Closed" : undef),
		details => $details,
		level   => ( $goingup ? 'Normal' : undef ),
		context => {type => $typeofdown },
		inventory_id => $S->inventory( concept => 'catchall' ),
			);

	# for these three we set a XYZdown marker in the catchall, in the most atomic fashion possible
	# (to minimise race conditions with other processes holding a catchall_live)
	if ($typeofdown =~ /^(snmp|wmi|node)$/)
	{
		my $catchall = $S->inventory(concept => 'catchall');
		my $quicklynow = $catchall->data;
		$quicklynow->{"${typeofdown}down"} = ($goingup ? 'false' : 'true');
		$catchall->data($quicklynow);
		$catchall->save;

		$self->nmisng->log->debug($self->name.": changed ${typeofdown}down state to ".$quicklynow->{"${typeofdown}down"});
	}

	return;
}

# sysUpTime under nodeinfo is a mess: not only is nmis overwriting it with
# in nonreversible format on the go,
# it's also used by and scribbled over in various places, and needs synthesizing
# from two separate properties in case of a wmi-only node.
#
# args:  catchall_data (should be live)
# returns: nothing, but attempts to bake sysUpTime and sysUpTimeSec catchall properties
# from whatever sys' nodeinfo structure contains.
sub makesysuptime
{
	my ($self, $catchall_data) = @_;

	return if (ref($catchall_data) ne "HASH");

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
# attention: this function disables all sys' sources that indicate any
# errors on loadnodeinfo()!
#
# fixme: this thing is an utter mess logic-wise and urgently needs a rewrite
sub update_node_info
{
	my ($self, %args) = @_;
	my $S    = $args{sys};

	my $RI   = $S->reach;          # reach table
	my $M    = $S->mdl;            # model table
	my $SNMP = $S->snmp;           # snmp object
	my $C    = $self->nmisng->config;

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();
	$RI->{snmpresult} = $RI->{wmiresult} = 0;

	my ($success, @problems);

	$self->nmisng->log->debug("Starting update_node_info");

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
		push @problems, $curstate->{error} if ($curstate->{error});

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
				$catchall_data->{sysObjectName} = NMISNG::MIB::oid2name($self->nmisng, $catchall_data->{sysObjectID} );
				$self->nmisng->log->debug2("sysObjectId=$catchall_data->{sysObjectID}, sysObjectName=$catchall_data->{sysObjectName}");
				$self->nmisng->log->debug2("sysDescr=$catchall_data->{sysDescr}");

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
				$self->nmisng->log->debug2("oid index $i, Vendor is $catchall_data->{nodeVendor}");
			}

			# iff snmp is a dud, look at some wmi properties
			elsif ( $catchall_data->{winbuild} && $catchall_data->{winosname} && $catchall_data->{winversion} )
			{
				$self->nmisng->log->debug2("winosname=$catchall_data->{winosname} winversion=$catchall_data->{winversion}");

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
				# fixme9: the auto-model decision should be made FIRST, before doing any loading
				# this function's logic needs a complete rewrite
				if ( $self->configuration->{model} eq 'automatic' || $self->configuration->{model} eq "" )
				{
					# get nodeModel based on nodeVendor and sysDescr (real or synthetic)
					$catchall_data->{nodeModel} = $S->selectNodeModel();    # select and save name in node info table
					$self->nmisng->log->debug2("selectNodeModel returned model=$catchall_data->{nodeModel}");

					$catchall_data->{nodeModel} ||= 'Default';              # fixme why default and not generic?
				}
				else
				{
					$catchall_data->{nodeModel} = $self->configuration->{model};
					$self->nmisng->log->debug2("node model=$catchall_data->{nodeModel} set by node config");
				}

				$self->nmisng->log->debug2("about to loadModel model=$catchall_data->{nodeModel}");
				$S->loadModel( model => "Model-$catchall_data->{nodeModel}" );

				# now we know more about the host, nodetype and model have been positively determined,
				# so we'll force-overwrite those values
				$S->copyModelCfgInfo( type => 'overwrite' );


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
					$self->makesysuptime($catchall_data);

					# pull / from VPN3002 system descr
					$catchall_data->{sysDescr} =~ s/\// /g;

					# collect DNS location info.
					$self->get_dns_location($catchall_data);

					# PIX failover test
					$self->checkPIX( sys => $S );

					$success = 1;    # done
				}
				else
				{
					$self->nmisng->log->error("loadNodeInfo with specific model failed!");
					# fixme9: why is this not terminal?
				}
			}
			else
			{
				$self->nmisng->log->error("could not retrieve sysDescr or winosname, cannot determine model for node ".$self->name."!");
			}
		}
		else                      # fixme unclear why this reaction to failed getnodeinfo?
		{
			# load the model prev found
			if ( $catchall_data->{nodeModel} ne '' )
			{
				my $maybeuseful = "Model-$catchall_data->{nodeModel}";
				$maybeuseful = "Model" if ($maybeuseful eq "Model-Model");
				$S->loadModel( model => $maybeuseful )
			}
		}
	}
	else
	{
		$self->nmisng->log->debug2("node $S->{name} is marked collect is 'false'");
		$success = 1;                # done
	}

	# get and apply any nodeconf override if such exists for this node
	my $overrides = $self->overrides // {};
	if ( $overrides->{sysLocation} )
	{
		$catchall_data->{sysLocation} = $overrides->{sysLocation};
		$self->nmisng->log->debug2("Manual update of sysLocation by nodeConf");
	}

	if ( $overrides->{sysContact} )
	{
		$catchall_data->{sysContact} = $overrides->{sysContact};
		$self->nmisng->log->debug2("Manual update of sysContact by nodeConf");
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
		# $curstate should be state as of last loadnodeinfo() op

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
		# get the current ip address if the host property was a name, ditto host_backup
		for (["host","host_addr"], ["host_backup", "host_addr_backup"])
		{
			my ($sourceprop, $targetprop) = @$_;
			my $sourceval = $self->configuration->{$sourceprop};
			my $ip;
			if ($self->configuration->{ip_protocol} eq 'IPv6')
			{
				$ip = NMISNG::Util::resolveDNStoAddrIPv6($sourceval);
			}
			else
			{
				$ip = NMISNG::Util::resolveDNStoAddr($sourceval);
			}

			if ($sourceval && ($ip))
			{
				$catchall_data->{$targetprop} = $ip; # cache and display
			}
			else
			{
				$catchall_data->{$targetprop} = '';
			}
		}
	}
	$self->nmisng->log->debug2( "update_node_info Finished "
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

	my $RI   = $S->reach;
	my $M    = $S->mdl;

	my $time_marker = $args{time_marker} || time;

	my $result;
	my $exit = 1;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	my $nodename = $self->name;

	$self->nmisng->log->debug("Starting Collect Node Info, node $nodename");

	# clear any node reset indication from the last run
  delete $catchall_data->{admin}->{node_was_reset};

	# capture previous states now for checking of this node
	my $sysObjectID  = $catchall_data->{sysObjectID};
	my $ifNumber     = $catchall_data->{ifNumber};
	my $sysUpTimeSec = $catchall_data->{sysUpTimeSec};
	my $sysUpTime    = $catchall_data->{sysUpTime};


	# this returns 0 iff none of the possible/configured sources worked, sets details
	my $loadsuccess = $S->loadInfo( class => 'system',
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
		# We need to update this time, next attempt will be since this time
		$catchall_data->{"last_poll_${source}_attempt"} = $time_marker;
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
			$self->nmisng->log->debug("($nodename) Device type/model changed $sysObjectID now $catchall_data->{sysObjectID}");
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
			$self->nmisng->log->debug("($nodename) Number of interfaces changed from $ifNumber now $catchall_data->{ifNumber}");
			$self->update_intf_info( sys => $S );  # get new interface table
		}

		my $interface_max_number = $self->nmisng->config->{interface_max_number} || 5000;
		if ( $ifNumber > $interface_max_number )
		{
			$self->nmisng->log->debug(
				"INFO ($catchall_data->{name}) has $ifNumber interfaces, no interface data will be collected, to collect interface data increase the configured interface_max_number $interface_max_number, we recommend to test thoroughly"
			);
		}

		# make a sysuptime from the newly loaded data for testing
		$self->makesysuptime($catchall_data);
		if ( defined $catchall_data->{snmpUpTime} )
		{
			# add processing for SNMP Uptime- handle just like sysUpTime
			$catchall_data->{snmpUpTimeSec}   = int( $catchall_data->{snmpUpTime} / 100 );
			$catchall_data->{snmpUpTime}      = NMISNG::Util::convUpTime( $catchall_data->{snmpUpTimeSec} );
		}

		$self->nmisng->log->debug2("sysUpTime: Old=$sysUpTime New=$catchall_data->{sysUpTime}");


		# has that node really been reset or has the uptime counter wrapped at 497 days and change?
		# sysUpTime is in 0.01s timeticks and 32 bit wide, so 497.1 days is all it can hold
		my $newuptime = $catchall_data->{sysUpTimeSec};
		if ($newuptime && $sysUpTimeSec > $newuptime)
		{
			if ($sysUpTimeSec >= 496*86400) # ie. old uptime value within one day of the rollover
			{
				$self->nmisng->log->info("Node $nodename: sysUpTime has wrapped after 497 days");
			}
			else
			{
				$self->nmisng->log->debug2("NODE RESET: Old sysUpTime=$sysUpTimeSec New sysUpTime=$newuptime");
				Compat::NMIS::notify(
					sys     => $S,
					event   => "Node Reset",
					details => "Old_sysUpTime=$sysUpTime New_sysUpTime=$newuptime",
					context => {type => "node"}
						);

				# now stash this info in the catchall object, to ensure we insert ONE set of U's into the rrds
				# so that no spikes appear in the graphs
				$catchall_data->{admin}->{node_was_reset}=1;
			}
		}

		# that's actually critical for other functions down the track
		$catchall_data->{last_poll}   = $time_marker;
		delete $catchall_data->{lastCollectPoll}; # replaced by last_poll

		# get and apply any nodeconf override if such exists for this node
		my $overrides = $self->overrides // {};

		# anything to override?
		if ( $overrides->{sysLocation} )
		{
			$catchall_data->{sysLocation} = $overrides->{sysLocation};
			$self->nmisng->log->debug2("Manual update of sysLocation by nodeConf");
		}
		if ( $overrides->{sysContact} )
		{
			$catchall_data->{sysContact} = $overrides->{sysContact};
			$self->nmisng->log->debug2("Manual update of sysContact by nodeConf");
		}

		if ( exists($overrides->{nodeType}) )
		{
			$catchall_data->{nodeType} = $overrides->{nodeType};
		}

		$self->checkPIX(sys => $S);    # check firewall if needed

		# conditional on model section to ensure backwards compatibility with different Juniper values.
		$self->handle_configuration_changes(sys => $S)
				if ( exists( $M->{system}{sys}{nodeConfiguration} )
						 or exists( $M->{system}{sys}{juniperConfiguration} ) );
	}
	else
	{
		$exit = 0;

		if (!$self->configuration->{ping} )
		{
			# ping was disabled, so sources wmi/snmp are the only thing that tells us about reachability
			# note: ping disabled != runping failed
			$catchall_data->{nodedown}  = 'true';
		}
	}

	$self->nmisng->log->debug("Finished with exit=$exit");
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

	$self->nmisng->log->debug("Starting collect_node_data, node $S->{name}");

	my $rrdData    = $S->getData( class => 'system',
																# fixme9 gone model => $model
			);
	my $howdiditgo = $S->status;
	my $anyerror   = $howdiditgo->{error} || $howdiditgo->{snmp_error} || $howdiditgo->{wmi_error};

	if ( !$anyerror )
	{
		my $previous_pit = $inventory->get_newest_timed_data();

		# Remove non existing subconcepts from catchall
		my %subconcepts;
		
		$self->process_alerts( sys => $S );
		foreach my $sect ( keys %{$rrdData} )
		{
			$subconcepts{$sect} = 1; # Remove non existing subconcepts from catchall
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
				$self->nmisng->log->debug2("rrdData, section=$sect, ds=$ds, value=$D->{$ds}{value}, option=$D->{$ds}{option}");
			}
			my $db = $S->create_update_rrd( inventory => $inventory, data => $D, type => $sect );
			if ($db)
			{
				my $target = {};
				NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, $sect );
				my $period = $self->nmisng->_threshold_period( subconcept => $sect );
				my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
																										 subconcept => $sect, start => $period, end => time);
				if (ref($stats) ne "HASH")
				{
					$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																	 .", subconcept $sect failed: $stats");
					$stats = {};
				}
				my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $sect,
																								time => $catchall_data->{last_poll}, delay_insert => 1 );
				$self->nmisng->log->error("timed data adding for ". $inventory->concept . " on node " .$self->name. " failed: $error") if ($error);
			}
		}
		# NO save on inventory because it's the catchall right now
		
		# Now, update non existent subconcepts/storage from inventory/catchall
		my $storage = $inventory->storage();
		
		foreach my $sub (@{$inventory->subconcepts()}) {
			if (!$subconcepts{$sub}) {
				if ($sub ne "health") {
					$self->nmisng->log->debug7("Subconcept not existing anymore. Removing: ". Dumper($storage->{$sub}));
					delete $storage->{$sub};
				}
			}
		}
		$inventory->storage($storage);
	}
	elsif ($howdiditgo->{skipped}) {}
	else
	{
		$self->nmisng->log->error("($catchall_data->{name}), collect_node_data encountered error $anyerror");
		$self->handle_down( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
			if ( $howdiditgo->{snmp_error} );
		$self->handle_down( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
				if ( $howdiditgo->{wmi_error} );
		return 0;
	}

	$self->nmisng->log->debug("Finished with collect_node_data");
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
		$self->nmisng->log->debug("Not performing update_intf_info for $nodename: SNMP not enabled for this node");
		return undef;                   # no interfaces collected, treat this as error
	}

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
				$self->nmisng->log->debug2("$nodename using ifTableLastChange for interface updates");
				$catchall_data->{ifTableLastChange} = $result;
			}
			elsif ( $catchall_data->{ifTableLastChange} != $result )
			{
				$self->nmisng->log->debug2(
					"$nodename ifTableLastChange has changed old=$catchall_data->{ifTableLastChange} new=$result"
				);
				$catchall_data->{ifTableLastChange} = $result;
			}
			else
			{
				$self->nmisng->log->debug2("$nodename ifTableLastChange NO change, skipping ");

				# returning 1 as we can do the rest of the updates.
				return 1;
			}
		}

		# else node may not have this variable so keep on doing in the hard way.

		$self->nmisng->log->debug2("Get Interface Info of node $nodename, model $catchall_data->{nodeModel}");

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
					# fixme9 unclear if terminal
					$self->nmisng->log->debug2( "SNMP Object Not Present ($nodename) on get interface index table: " . $SNMP->error );
				}

				# snmp failed
				else
				{
					$self->nmisng->log->error("($nodename) on get interface index table: " . $SNMP->error );
					$self->handle_down( sys => $S, type => "snmp", details => $SNMP->error );
				}

				$self->nmisng->log->debug2("Finished (snmp failure)");
				return 0;
			}
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
					$self->nmisng->log->debug2(
						"SKIP Interface ifType matched skipIfType ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType}"
					);
				}
				elsif ( defined $S->{mdl}{custom}{interface}{skipIfDescr}
					and $S->{mdl}{custom}{interface}{skipIfDescr} ne ""
					and $target->{ifDescr} =~ /$S->{mdl}{custom}{interface}{skipIfDescr}/ )
				{
					$keepInterface = 0;
					$self->nmisng->log->debug2(
						"SKIP Interface ifDescr matched skipIfDescr ifIndex=$index ifDescr=$target->{ifDescr} ifType=$target->{ifType}"
					);
				}

				if ( not $keepInterface )
				{
					delete $target_table->{$index};
					NMISNG::Util::TODO("Should this info be kept but marked disabled?");
				}
				else
				{
					$self->nmisng->log->debug("($nodename) ifadminstatus is empty for index=$index")
						if $target->{ifAdminStatus} eq "";
					$self->nmisng->log->debug2(
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
					$self->nmisng->log->debug2("Finished (stop polling on error)");
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
					$S->loadInfo(
						class  => 'port',
						index  => $index,
						port   => $port,
						table  => 'interface',
						target => $target
							);
				}
				else
				{
					my $port;
					if ( $target->{ifDescr} =~ /(\d{1,2})\D(\d{1,2})$/ )
					{                                                 # 0-0 Catalyst
						$port = $1 . '.' . $2;
					}
					$S->loadInfo(
						class  => 'port',
						index  => $index,
						port   => $port,
						table  => 'interface',
						target => $target
							);
				}
			}
		}

		if (    $singleInterface
			and defined $S->{mdl}{custom}{interface}{skipIpAddressTableOnSingle}
			and NMISNG::Util::getbool( $S->{mdl}{custom}{interface}{skipIpAddressTableOnSingle} ) )
		{
			$self->nmisng->log->debug2("Skipping Device IP Address Table because skipIpAddressTableOnSingle is false");
		}
		else
		{
			my $ifMaskTable;
			my %ifCnt;
			$self->nmisng->log->debug2("Getting Device IP Address Table");

			# IP-MIB v2 (IPv4 + IPv6)
			my $ipv6_source = undef;
			my $addrIfIndex = 'ipAddressIfIndex';
			my $addrPrefix = 'ipAddressPrefix';
			my $addrType = 'ipAddressType';
			my $ifAdEntTable = $SNMP->getindex($addrIfIndex);
			my $ipMibV2Available = (defined $ifAdEntTable);
			
			if (!$ipMibV2Available)
			{
				# IP-MIB v1 (IPv4 only)
				if ( $ifAdEntTable = $SNMP->getindex('ipAdEntIfIndex') )
				{
					$self->nmisng->log->debug2("IP-MIB v1");
					$ifMaskTable = $SNMP->getindex('ipAdEntNetMask');
					foreach my $addr ( Net::SNMP::oid_lex_sort( keys %{$ifAdEntTable} ) )
					{
						my $index = $ifAdEntTable->{$addr};
						next if ( $singleInterface and $intf_one ne $index );
						$ifCnt{$index} += 1;

						my $mask = "";
						$mask = $ifMaskTable->{$addr} if ($ifMaskTable);
						# this is not so good with ipv4 subnet mask
						#$mask = Compat::IP::netmask2prefix($mask);

						my $target = $target_table->{$index};
						# NOTE: inventory, breaks index convention here! not a big deal but it happens
						my $version;
						(   $target->{"ipSubnet$ifCnt{$index}"},
							$target->{"ipSubnetBits$ifCnt{$index}"},
							$version
						) = Compat::IP::ipSubnet( address => $addr, mask => $mask );

						$target->{"ipAdEntAddr$ifCnt{$index}"}    = $addr;
						$target->{"ipAdEntNetMask$ifCnt{$index}"} = $mask;
						$target->{"ipAdEntType$ifCnt{$index}"} = "ipv4";

						$self->nmisng->log->debug2("ipAdEntIfIndex ifIndex=$index, count=$ifCnt{$index} addr=$addr mask=$mask version=$version ipSubnet=".$target->{"ipSubnet$ifCnt{$index}"});
					}
				}

				# also try CISCO-IETF-IP-MIB (IPv6 only)
				$addrIfIndex = 'cIpAddressIfIndex';
				$addrPrefix = 'cIpAddressPrefix';
				$addrType = 'cIpAddressType';
				$ifAdEntTable = $SNMP->getindex($addrIfIndex);
			}

			# this will be IPv4 and IPv6 in the ipAddressIfIndex table, or CISCO-IETF-IP-MIB things.
			if ( $ifAdEntTable )
			{
				$ipv6_source = $ipMibV2Available ? "IP-MIB v2" : "CISCO-IETF-IP-MIB";
				$self->nmisng->log->debug2("IPv6 Source: $ipv6_source");
				$ifMaskTable = $SNMP->getindex($addrPrefix);
				my $ipAddressTypeTable = $SNMP->getindex($addrType);
				my $UNICAST = 1;
				foreach my $addr ( Net::SNMP::oid_lex_sort( keys %{$ifAdEntTable} ) )
				{
					my $index = $ifAdEntTable->{$addr};
					next if ( $singleInterface and $intf_one ne $index );

					if ($ipAddressTypeTable)
					{
						next if $ipAddressTypeTable->{$addr} != $UNICAST;
					}

					$ifCnt{$index} += 1;

					my $mask = "";
					$mask = $ifMaskTable->{$addr} if ($ifMaskTable);

					# the value represents ipAddressPrefixOrigin OID, we extract just 'prefix length' part from it
					if ( $mask ne "0.0" ) {
						$mask = (split '\.', $mask)[-1];
					}

					my $target = $target_table->{$index};
					my $ip = Compat::IP::oid2ip($addr);

					# TODO: check usages and make it IPv6 compatible if needed
					my $version;
					(   $target->{"ipSubnet$ifCnt{$index}"},
						$target->{"ipSubnetBits$ifCnt{$index}"},
						$version
					) = Compat::IP::ipSubnet( address => $ip, mask => $mask );

					# this is mask a single digit e.g. 24? convert to dotted notation
					if ( $version == 4 and $mask =~ /^\d+$/ ) {
						$mask = Compat::IP::ipBitsToMask(bits => $mask);
					}

					my $type = $version == 4 ? "ipv4" : "ipv6";
					$target->{"ipAdEntAddr$ifCnt{$index}"}    = $ip;
					$target->{"ipAdEntNetMask$ifCnt{$index}"} = $mask;
					$target->{"ipAdEntType$ifCnt{$index}"} = $type;

					$self->nmisng->log->debug2("$ipv6_source ifIndex=$index, count=$ifCnt{$index} addr=$addr ip=$ip mask=$mask version=$version ipSubnet=".$target->{"ipSubnet$ifCnt{$index}"});
				}
			}

			if ( !$ifAdEntTable )
			{
				$self->nmisng->log->debug2("ERROR getting Device Ip Address table");
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
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_nocollect_noDescription");
		}

		if ( defined $C->{global_collect_Description} and $C->{global_collect_Description} ne "" )
		{
			$qr_collect_ifAlias_gen = qr/($C->{global_collect_Description})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_collect_Description");
		}

		# is collection overridden globally, on or off? (on wins if both are set)
		if ( defined $C->{global_collect_ifDescr} and $C->{global_collect_ifDescr} ne '' )
		{
			$qr_collect_ifDescr_gen = qr/($C->{global_collect_ifDescr})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_collect_ifDescr");
		}
		elsif ( defined $C->{global_nocollect_ifDescr} and $C->{global_nocollect_ifDescr} ne "" )
		{
			$qr_no_collect_ifDescr_gen = qr/($C->{global_nocollect_ifDescr})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_nocollect_ifDescr");
		}

		if ( defined $C->{global_nocollect_Description} and $C->{global_nocollect_Description} ne "" )
		{
			$qr_no_collect_ifAlias_gen = qr/($C->{global_nocollect_Description})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_nocollect_Description");
		}

		if ( defined $C->{global_nocollect_ifType} and $C->{global_nocollect_ifType} ne "" )
		{
			$qr_no_collect_ifType_gen = qr/($C->{global_nocollect_ifType})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_nocollect_ifType");
		}

		if ( defined $C->{global_nocollect_ifOperStatus} and $C->{global_nocollect_ifOperStatus} ne "" )
		{
			$qr_no_collect_ifOperStatus_gen = qr/($C->{global_nocollect_ifOperStatus})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_nocollect_ifOperStatus");
		}

		if ( defined $C->{global_noevent_ifDescr} and $C->{global_noevent_ifDescr} ne "" )
		{
			$qr_no_event_ifDescr_gen = qr/($C->{global_noevent_ifDescr})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_noevent_ifDescr");
		}

		if ( defined $C->{global_noevent_Description} and $C->{global_noevent_Description} ne "" )
		{
			$qr_no_event_ifAlias_gen = qr/($C->{global_noevent_Description})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_noevent_Description");
		}

		if ( defined $C->{global_noevent_ifType} and $C->{global_noevent_ifType} ne "" )
		{
			$qr_no_event_ifType_gen = qr/($C->{global_noevent_ifType})/i;
			$self->nmisng->log->debug2("INFO Model overriden by Global Config for global_noevent_ifType");
		}

		my $intfTotal   = 0;
		my $intfCollect = 0;    # reset counters

		$self->nmisng->log->debug2("Checking interfaces for duplicate ifDescr");
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
				$self->nmisng->log->debug2("Interface ifDescr changed to $target->{ifDescr}");
			}
			else
			{
				$ifDescrIndx->{$target->{ifDescr}} = $i;
			}
		}
		$self->nmisng->log->debug2("Completed duplicate ifDescr processing");

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
					$target->{Description} = $thisintfover->{Description};
					$self->nmisng->log->debug2("Manual update of Description by nodeConf");
				}
				if ( $thisintfover->{display_name} )
				{
					$target->{display_name} = $thisintfover->{display_name};
					# no log/diag msg as  this comes ONLY from nodeconf, it's not overriding anything
				}

				for my $speedname (qw(ifSpeed ifSpeedIn ifSpeedOut))
				{
					if ( $thisintfover->{$speedname} )
					{
						$target->{"nc_$speedname"} = $target->{$speedname};    # save
						$target->{$speedname} = $thisintfover->{$speedname};
						$self->nmisng->log->debug2("Manual update of $speedname by nodeConf");
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
					$self->nmisng->log->debug2("Manual update of Collect by nodeConf");

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
					$self->nmisng->log->debug2("Manual update of Event by nodeConf");
				}

				if ( $thisintfover->{threshold} and $thisintfover->{ifDescr} eq $target->{ifDescr} )
				{
					$target->{nc_threshold} = $target->{threshold};
					$target->{threshold}    = $thisintfover->{threshold};
					$target->{nothreshold}  = "Manual update by nodeConf"
						if ( NMISNG::Util::getbool( $target->{threshold}, "invert" ) );    # reason
					$self->nmisng->log->debug2("Manual update of Threshold by nodeConf");
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


			# collect status
			if ( NMISNG::Util::getbool( $target->{collect} ) )
			{
				$self->nmisng->log->debug2("$target->{ifDescr} ifIndex $index, collect=true");
			}
			else
			{
				$self->nmisng->log->debug2("$target->{ifDescr} ifIndex $index, collect=false, $target->{nocollect}");

				# if collect is of then disable event and threshold (clearly not applicable)
				$target->{threshold} = 'false';
				$target->{event}     = 'false';
			}

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

				# We already have an inventory with that name, but different index
				if ($inventory->data->{index} && ($index != $inventory->data->{index})) {
					$self->nmisng->log->info("Checking inventory error. Index $index not the same ". $inventory->data->{index});
					
					# Get rid of the old data 
					my ($successdelete, $msg) = $inventory->delete(keep_rrd => );
					$self->nmisng->log->debug("Removed historic inventory was successfull") if ($successdelete);
					
					# And create new information
					( $inventory, my $error_message ) = $self->inventory(
							concept   => 'interface',
							path      => $path,
							create    => 1
					);
					$self->nmisng->log->error("Failed to create interface inventory, for duplicated ifDescr with historic index - error:$error_message") && next if ( !$inventory );
					$self->nmisng->log->debug("Created new inventory for ifIndex $index");
				}
				$inventory->data( $target );
				# regenerate the path, if this thing wasn't new the path may have changed, which is ok
				# for a new object this must happen AFTER data is set
				$inventory->path( recalculate => 1 );
				$path = $inventory->path; # no longer the same - path was partial, now it no longer is

				# changed to fix element being incorrect in threshold events.
				$inventory->description( $target->{ifDescr} || $target->{Description} );

				# Regenerate storage: If ifDescr has changed, we need this
				for ("interface", "pkts", "pkts_hc" )
				{
					if ($inventory->find_subconcept_type_storage(type => "rrd",
																				 subconcept      => $_,
																				 relative => 1 )) {
						my $dbname = $S->makeRRDname(type => $_,
																				 index     => $index,
																				 item      => $_,
																				 relative => 1 );
						$self->nmisng->log->debug2("Storage: ". Dumper($dbname));
						$inventory->set_subconcept_type_storage(type => "rrd",
																subconcept => $_,
																data => $dbname) if ($dbname);
					}
					
				}
				
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
				$self->nmisng->log->debug2( "saved ".join(',', @{$inventory->path})." op: $op");
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
				$self->nmisng->log->debug2(
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
								$self->nmisng->log->debug2(
									"rrd section $datatype, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit"
								);
								RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
							}
							else
							{
								$self->nmisng->log->debug2("rrd section $datatype, ds $dsname, current limit $curval is correct");
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
			$self->nmisng->log->debug("$nodename, found intfs alive: $result->{matched_nothistoric}, already historic: $result->{matched_historic}, marked alive: $result->{marked_nothistoric}, marked historic: $result->{marked_historic}");
		}

		$self->nmisng->log->debug2("Finished");
	}
	elsif ( $catchall_data->{ifNumber} > $interface_max_number )
	{
		$self->nmisng->log->debug2("Skipping, interface count $catchall_data->{ifNumber} exceeds configured maximum $interface_max_number");
	}
	else
	{
		$self->nmisng->log->debug2("Skipping, interfaces not defined in Model");
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
		$self->nmisng->log->debug2("Not performing getIntfData for $nodename: SNMP not enabled for this node");
		return 1;
	}

	$self->nmisng->log->debug2("Starting Interface get data for node $nodename");

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
	my $isValidTable = 0;
	my ($ifAdminTable, $ifOperTable);
	
	if (!$dontwanna_ifadminstatus)
	{
		# fixme: this cannot work for non-snmp nodes
		$self->nmisng->log->debug("Using ifAdminStatus and ifOperStatus for Interface Change Detection");
	
		# want both or we don't care
		$ifAdminTable = $S->snmp->getindex('ifAdminStatus');
		$ifOperTable = $S->snmp->getindex('ifOperStatus');
		if ($ifAdminTable && $ifOperTable)
		{
			# index == ifindex
			for my $index ( keys %{$ifAdminTable} )
			{
				$isValidTable = 1;
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
		$self->nmisng->log->debug2("Using ifLastChange for Interface Change Detection");

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
			$self->nmisng->log->debug("[$nodename]  _ifAdminStatus does not exist ");
			if ($isValidTable == 1) {
				# we have to track already dead ones (in if_data_map), but we don't work on them
				$self->nmisng->log->info("Interface $index, $thisif->{ifDescr} was removed!")
						if (!$thisif->{historic});
	
				delete $if_data_map{$index}; # nothing to do except mark it as historic at the end
			} else {
				$self->nmisng->log->debug("[$nodename] Interface table is not valid, cannot say if interface was removed");
			}
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

		$self->nmisng->log->debug("($S->{name}) no ifAdminStatus for index=$index present")
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
	$self->nmisng->log->debug2("Collecting Interface Data");

	for my $index (sort grep($if_data_map{$_}->{enabled} && !$if_data_map{$_}->{historic} && ($if_data_map{$_}->{collect} eq "true"),
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


		$self->nmisng->log->debug2(
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
				$self->nmisng->log->debug2("handling up/down, now admin=$thisif->{_ifAdminStatus}, oper=$thisif->{_ifOperStatus} was admin=$thisif->{ifAdminStatus}, oper=$thisif->{ifOperStatus}");

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
				$inventory_data->{ifLastChange} = NMISNG::Util::convUpTime(
					$inventory_data->{ifLastChangeSec}
					= int( $ifsection->{ifLastChange}{value} / 100 ) );
				$self->nmisng->log->debug2("last change for index $index time=$inventory_data->{ifLastChange}, timesec=$inventory_data->{ifLastChangeSec}");
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
			$self->nmisng->log->debug2( "updateRRD type=$sectionname index=$index", 2 );
			my $db = $S->create_update_rrd( data => $thissection,
																			type => $sectionname,
																			index => $index,
																			inventory => $inventory );
			if ($db)
			{
				# convert data into values we can use in pit (eg resolve counters)
				my $target = {};

				NMISNG::Inventory::parse_rrd_update_data($thissection, $target, $previous_pit, $sectionname);
				my $period = $self->nmisng->_threshold_period( subconcept => $sectionname );
				my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
																										 subconcept => $sectionname,
																										 start => $period, end => time);
				if (ref($stats) ne "HASH")
				{
					$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																		.", subconcept $sectionname failed: $stats");
					$stats = {};
				}
				# add data and stats
				my $error = $inventory->add_timed_data( data => $target, derived_data => $stats,
																								subconcept => $sectionname,
																								time => $catchall_data->{last_poll},
																								delay_insert => 1 );
				$self->nmisng->log->error("(".$self->name.") failed to add timed data for ". $inventory->concept .": $error")
						if ($error);
			}
		}

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

	$self->nmisng->log->debug("$nodename, collect_intf_data found intfs alive: $nuked->{matched_nothistoric}, already historic: $nuked->{matched_historic}, marked alive: $nuked->{marked_nothistoric}, marked historic: $nuked->{marked_historic}");

	$self->nmisng->log->debug2("Finished");
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


	# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
	# ditto if ifspeed is zero
	if ( $thisintf->{ifSpeed} == 4294967295 or $thisintf->{ifSpeed} == 0 )
	{
		$thisintf->{ifSpeed} = $thisintf->{ifHighSpeed};
		$thisintf->{ifSpeed} *= 1000000;
	}

	# final fallback in case SNMP agent is DODGY
	$thisintf->{ifSpeed} ||= 1000000000;


	# convert time integer from ticks to time string
	# fixme9: unsafe, non-idempotent, broken if function is called more than once, self-referential loopy
	# trashing of ifLastChange via ifLastChangeSec...
	$thisintf->{ifLastChange} = NMISNG::Util::convUpTime(
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
		$self->nmisng->log->debug2("Not performing PIX Failover check for $S->{name}: SNMP not enabled for this node");
		return 1;
	}

	my $SNMP = $S->snmp;
	my $result;

	$self->nmisng->log->debug2(&NMISNG::Log::trace() ."Starting");

	# PIX failover test
	# table has six values
	# [0] primary.cfwHardwareInformation, [1] secondary.cfwHardwareInformation
	# [2] primary.HardwareStatusValue, [3] secondary.HardwareStatusValue
	# [4] primary.HardwareStatusDetail, [5] secondary.HardwareStatusDetail
	# if HardwareStatusDetail is blank ( ne 'Failover Off' ) then
	# HardwareStatusValue will have 'active' or 'standby'

	return if ( $catchall_data->{nodeModel} ne "CiscoPIX" );

	$self->nmisng->log->debug2("checkPIX, Getting Cisco PIX Failover Status");
	if ($result = $SNMP->get(
				'cfwHardwareStatusValue.6',  'cfwHardwareStatusValue.7',
				'cfwHardwareStatusDetail.6', 'cfwHardwareStatusDetail.7'
			)
			)
	{
		$result = $SNMP->keys2name($result);    # convert oid in hash key to name

		my %xlat = ( 0 => "Failover Off",
								 3 => "Down",
								 9 => "Active",
								 10 => "Standby" );
		$result->{'cfwHardwareStatusValue.6'} = $xlat{ $result->{'cfwHardwareStatusValue.6'} } // "Unknown";

		$result->{'cfwHardwareStatusValue.7'} = $xlat{ $result->{'cfwHardwareStatusValue.7'} } // "Unknown";

		# fixme unclean access to internal structure
		# fixme also fails if we've switched to updating this node on the go!
		if ( !NMISNG::Util::getbool( $S->{update} ) )
		{
			if (   $result->{'cfwHardwareStatusValue.6'} ne $catchall_data->{pixPrimary}
						 or $result->{'cfwHardwareStatusValue.7'} ne $catchall_data->{pixSecondary} )
			{
				$self->nmisng->log->debug2("PIX failover occurred");

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
	}
	$self->nmisng->log->debug2(&NMIS::Log::trace() ."Finished");
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
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	$self->nmisng->log->debug2("Starting handle_configuration_changes");

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
		$self->nmisng->log->debug2(
			"checkNodeConfiguration configLastChanged=$configLastChanged, configLastViewed=$configLastViewed, bootConfigLastChanged=$bootConfigLastChanged, configLastChanged_prev=$configLastChanged_prev"
		);
	}
	else
	{
		$self->nmisng->log->debug2(
			"checkNodeConfiguration configLastChanged=$configLastChanged, configLastChanged_prev=$configLastChanged_prev"
		);
	}


	### If it is newer, someone changed it!
	if ( $configLastChanged > $configLastChanged_prev )
	{
		$catchall_data->{configChangeCount}++;

		Compat::NMIS::notify(
			sys     => $S,
			event   => "Node Configuration Change",
			element => "",
			details => "Changed at " . NMISNG::Util::convUpTime( $configLastChanged / 100 ),
			context => {type => "node"},
		);
		$self->nmisng->log->info("checkNodeConfiguration configuration change detected for $S->{name}, creating event");
	}

	#update previous values to be our current values
	for my $attr (@updatePrevValues)
	{
		if ( defined $catchall_data->{$attr} ne '' && $catchall_data->{$attr} ne '' )
		{
			$catchall_data->{"${attr}_prev"} = $catchall_data->{$attr};
		}
	}

	$self->nmisng->log->debug2("Finished");
	return;
}



# find location from dns LOC record if configured to try (loc_from_DNSloc)
# or fall back to syslocation if loc_from_sysLoc is set
# args: catchall_data (should be live)
# returns: 1 if if finds something, 0 otherwise
sub get_dns_location
{
	my ($self, $catchall_data) = @_;

	my $C = $self->nmisng->config;
	$self->nmisng->log->debug2(&NMISNG::Log::trace() ."Starting");

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
				$self->nmisng->log->debug2("Location set from DNS LOC, to $catchall_data->{loc_DNSloc}");
				return 1;
			}
		}
		else
		{
			# tag as warning but emit only if debug 2 or higher
			$self->nmisng->log->warn("DNS Loc query failed: $resolver->errorstring")
					if ($self->nmisng->log->is_level(2));
		}
	}

	# if no DNS based location information found or checked, then look at sysLocation
	if ( NMISNG::Util::getbool( $C->{loc_from_sysLoc}) and $catchall_data->{loc_DNSloc} eq "unknown" )
	{
		# longitude,latitude,altitude,location-text
		if ( $catchall_data->{sysLocation} =~ /$C->{loc_sysLoc_format}/ )
		{
			$catchall_data->{loc_DNSloc} = $catchall_data->{sysLocation};
			$self->nmisng->log->debug2("Location set from device sysLocation, to $catchall_data->{loc_DNSloc}");
			return 1;
		}
	}
	$self->nmisng->log->debug2(&NMISNG::Log::trace() . "Finished");
	return 0;
}

# retrieve system health index data from snmp/wmi, done during update
# args: self, sys
# returns: 1 if all present sections worked, 0 otherwise
# note: raises xyz down events if snmp or wmi are down
sub collect_systemhealth_info
{
	my ($self, %args) = @_;
	my $S    = $args{sys};    # object

	my $name = $self->name;
	my $C = $self->nmisng->config;

	my $SNMP = $S->snmp;
	my $M    = $S->mdl;           # node model table

	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	$self->nmisng->log->debug("Get systemHealth Info of node $name, model $catchall_data->{nodeModel}");

	if ( ref( $M->{systemHealth} ) ne "HASH" )
	{
		$self->nmisng->log->debug2("No class 'systemHealth' declared in Model.");
		return 0;
	}
	elsif ( !$S->status->{snmp_enabled} && !$S->status->{wmi_enabled} )
	{
		$self->nmisng->log->warn("cannot get systemHealth info, neither SNMP nor WMI enabled!");
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
			$self->nmisng->log->debug2("No index var found for $section, skipping");
			next;
		}

		# determine if this is an snmp- OR wmi-backed systemhealth section
		# combination of both cannot work, as there is only one index
		if ( exists( $thissection->{wmi} ) and exists( $thissection->{snmp} ) )
		{
			$self->nmisng->log->error("systemhealth: section=$section cannot have both sources WMI and SNMP enabled!");
			next;    # fixme: or is this completely terminal for this model?
		}

		if ( exists( $thissection->{wmi} ) )
		{
			$self->nmisng->log->debug2("systemhealth: section=$section, source WMI, index_var=$index_var");
			$header_info = NMISNG::Inventory::parse_model_subconcept_headers( $thissection, 'wmi' );

			my $wmiaccessor = $S->wmi;
			if ( !$wmiaccessor )
			{
				$self->nmisng->log->debug2("skipping section $section: source WMI but node $S->{name} not configured for WMI");
				next;
			}

			# model broken if it says 'indexed by X' but doesn't have a query section for 'X'
			if ( !exists( $thissection->{wmi}->{$index_var} ) )
			{
				$self->nmisng->log->error("Model section $section of $catchall_data->{nodeModel} is missing declaration for index_var $index_var!");
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
				$self->nmisng->log->error("Model section $section of $catchall_data->{nodeModel} is missing query or field for WMI variable  $index_var!");
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
				$self->nmisng->log->error("($S->{name}) failed to get index table for systemHealth $section of model $catchall_data->{nodeModel}: $error");
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
				$self->nmisng->log->debug2("section=$section index=$index_var, found value=$indexvalue");

				# allow disabling of collection for this instance,
				# based on regex match against the index value
				if (ref($thissection->{nocollect}) eq "HASH"
						&& defined($thissection->{nocollect}->{$index_var}))
				{
					# this supports both 'nocollect' => { 'first' => qr/somere/i, 'second' => 'plaintext' }
					my $rex = ref($thissection->{nocollect}->{$index_var}) eq "Regexp"?
							$thissection->{nocollect}->{$index_var} : qr/$thissection->{nocollect}->{$index_var}/;

					if ($indexvalue =~ $rex)
					{
						$self->nmisng->log->debug2("nocollect match for systemHealth section=$section key=$index_var value=$indexvalue - skipping");
						next;
					}
				}

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
						target  => $target
					)
					)
				{
					$self->nmisng->log->debug2("section=$section index=$indexvalue read and stored");

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
					$self->nmisng->log->debug2( "saved ".join(',', @$path)." op: $op");
					$self->nmisng->log->error(
						"Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
						if ($error);
				}
				else
				{
					my $error = $S->status->{wmi_error};
					$self->nmisng->log->error("($S->{name}) failed to get table for systemHealth $section of model $catchall_data->{nodeModel}: $error");
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
			$self->nmisng->log->debug2("systemHealth: section=$section, source SNMP, index_var=$index_var, index_snmp=$index_snmp");
			$header_info = NMISNG::Inventory::parse_model_subconcept_headers( $thissection, 'snmp' );
			my ( %healthIndexNum, $healthIndexTable );

			# first loop gets the index we want to use out of the oid
			# so we need to keep a map of index => target
			# potientially these two loops could be merged.
			my $targets = {};
			if ( $healthIndexTable = $SNMP->gettable($index_snmp) )
			{
				foreach my $oid ( Net::SNMP::oid_lex_sort( keys %{$healthIndexTable} ) )
				{
					my $index = $oid;
					if ( $oid =~ /$index_regex/ )
					{
						$index = $1;
					}
					my $indexvalue = $healthIndexNum{$index} = $index;
					$self->nmisng->log->debug2("section=$section index=$index is found, value=$indexvalue");

					# allow disabling of collection for this instance,
					# based on regex match against the index value
					if (ref($thissection->{nocollect}) eq "HASH"
							&& defined($thissection->{nocollect}->{$index_var}))
					{
						# this supports both 'nocollect' => { 'first' => qr/somere/i, 'second' => 'plaintext' }
						my $rex = ref($thissection->{nocollect}->{$index_var}) eq "Regexp"?
								$thissection->{nocollect}->{$index_var} : qr/$thissection->{nocollect}->{$index_var}/;

						if ($indexvalue =~ $rex)
						{
							$self->nmisng->log->debug2("nocollect match for systemHealth section=$section key=$index_var value=$indexvalue - skipping");
							next;
						}
					}

					$targets->{$index}{$index_var} = $indexvalue;
				}
			}
			else
			{
				if ( $SNMP->error =~ /is empty or does not exist/ )
				{
					$self->nmisng->log->debug2( "SNMP Object Not Present ($S->{name}) on get systemHealth $section index table: "
							. $SNMP->error );
				}
				else
				{
					$self->nmisng->log->error("($S->{name}) on get systemHealth $section index table of model $catchall_data->{nodeModel}: " . $SNMP->error );
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
						target  => $target
				))
				{
					$self->nmisng->log->debug2("section=$section index=$index read and stored");

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
					
					# Regenerate storage: If db name has changed, we need this
					$self->nmisng->log->debug("collect_systemhealth_info check storage $section");
					my $inv = $inventory->find_subconcept_type_storage(type => "rrd",
																		subconcept => $section );
					if ($inventory->find_subconcept_type_storage(type => "rrd",
																subconcept => $section )) {
							my $dbname = $S->makeRRDname(graphtype => $section,
														index     => $index,
														inventory      => $inventory,
														relative => 1);
							$self->nmisng->log->debug8("Storage: ". Dumper($dbname));
							$inventory->set_subconcept_type_storage(type => "rrd",
																	subconcept => $section,
																	data => $dbname) if ($dbname);
					}
					
					# the above will put data into inventory, so save
					my ( $op, $error ) = $inventory->save();
					$self->nmisng->log->debug2( "saved ".join(',', @$path)." op: $op");
					$self->nmisng->log->error(
						"Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
						if ($error);
				}
				else
				{
					my $error = $S->status->{snmp_error};
					$self->nmisng->log->error("($S->{name}) on get systemHealth $section index $index of model $catchall_data->{nodeModel}: $error");
					$self->handle_down(
						sys     => $S,
						type    => "snmp",
						details => "get systemHealth $section index $index: $error"
					);
				}
			}
		}
	}
		
	$self->nmisng->log->debug("Finished with collect_systemhealth_info");
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

	$self->nmisng->log->debug("Get systemHealth Data of node $name, model $catchall_data->{nodeModel}");

	if ( !exists( $M->{systemHealth} ) )
	{
		$self->nmisng->log->debug2("No class 'systemHealth' declared in Model");
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
				$self->nmisng->log->error("invalid data for section $section and index $index in model $catchall_data->{nodeModel}, cannot collect systemHealth data for this index!"
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
						$self->nmisng->log->debug2("updating node info $section $index $item: old "
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
					if ($db)
					{
						# convert data into values we can use in pit (eg resolve counters)
						my $target = {};
						NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, $sect);
						# get stats
						my $period = $self->nmisng->_threshold_period(subconcept => $sect);
						my $stats = Compat::NMIS::getSubconceptStats(sys => $S, inventory => $inventory,
																												 subconcept => $sect, start => $period, end => time);
						if (ref($stats) ne "HASH")
						{
							$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																				.", subconcept $sect failed: $stats");
							$stats = {};
						}
						my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $sect,
																									time => $catchall_data->{last_poll}, delay_insert => 1 );
						$self->nmisng->log->error("($name) failed to add timed data for ". $inventory->concept .": $error") if ($error);
					}
				}
				$self->nmisng->log->debug2("section=$section index=$index read and stored $count values");
				# technically the path shouldn't change during collect so for now don't recalculate path
				# put the new values into the inventory and save
				$inventory->data($data);
				$inventory->save();
			}
			# this allows us to prevent adding data when it wasn't collected (but not an error)
			elsif( $howdiditgo->{skipped} ) {}
			else
			{
				$self->nmisng->log->error("($name) collect_systemhealth_data for section $section and index $index encountered $anyerror");
				$self->handle_down( sys => $S, type => "snmp", details => $howdiditgo->{snmp_error} )
					if ( $howdiditgo->{snmp_error} );
				$self->handle_down( sys => $S, type => "wmi", details => $howdiditgo->{wmi_error} )
					if ( $howdiditgo->{wmi_error} );

				return 0;
			}
		}
	}
	$self->nmisng->log->debug("Finished with collect_systemhealth_data");
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
		$self->nmisng->log->debug2("no CBQoS collecting for node $name");
		return 1;
	}

	$self->nmisng->log->debug("Starting collect_cbqos for node $name");

	if ($isupdate)
	{
		$self->collect_cbqos_info( sys => $S );    # get indexes
	}
	elsif (!$self->collect_cbqos_data(sys => $S))
	{
		$self->collect_cbqos_info( sys => $S );    # (re)get indexes
		$self->collect_cbqos_data( sys => $S );    # and reget data
	}

	$self->nmisng->log->debug("Finished with collect_cbqos");
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
		$self->nmisng->log->debug2("Not performing getCBQoSwalk for $name: SNMP not enabled for this node");
		return 1;
	}

	my $SNMP = $S->snmp;
	my $C = $self->nmisng->config;

	$self->nmisng->log->debug2("start table scanning");

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
			$self->nmisng->log->debug2("CBQoS, scan interface $intf");
			$self->nmisng->log->warn("CBQoS ifIndex $intf found which is not in inventory") && next
				if( !defined($if_data_map{$intf}) );
			my $if_data = $if_data_map{$intf};

			# skip CBQoS if interface has collection disabled
			if ( $if_data->{historic} || !$if_data->{enabled} )
			{
				$self->nmisng->log->debug2("Skipping CBQoS, No collect on interface $if_data->{ifDescr} ifIndex=$intf");
				next;
			}

			my $answer = {};
			my %CMValues;

			# check direction of qos with node table
			( $answer->{'cbQosPolicyDirection'} ) = $SNMP->getarray("cbQosPolicyDirection.$PIndex");
			my $wanteddir = $self->configuration->{cbqos};
			$self->nmisng->log->debug2("direction in policy is $answer->{'cbQosPolicyDirection'}, node wants $wanteddir");

			if (( $answer->{'cbQosPolicyDirection'} == 1 and $wanteddir =~ /^(input|both)$/ )
				or ( $answer->{'cbQosPolicyDirection'} == 2 and $wanteddir =~ /^(output|true|both)$/ ) )
			{
				# interface found with QoS input or output configured

				my $direction = ( $answer->{'cbQosPolicyDirection'} == 1 ) ? "in" : "out";
				$self->nmisng->log->debug2("Interface $intf found, direction $direction, PolicyIndex $PIndex");

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
					$self->nmisng->log->debug2("look for object at $PIndex.$OIndex, type $answer->{'cbQosObjectsType'}");
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
							$self->nmisng->log->debug2("policymap - name is $answer->{'cbQosPolicyMapName'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
							);
						}
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 2 )
					{
						# it's a classmap, ask the name and the parent ID
						( $answer->{'cbQosCMName'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray( "cbQosCMName.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex" );
						$self->nmisng->log->debug2("classmap - name is $answer->{'cbQosCMName'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
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

							$self->nmisng->log->debug2("look for parent of ObjectsType $answer->{'cbQosObjectsType2'}");
							if ( $answer->{'cbQosObjectsType2'} eq 1 )
							{
								# it is a policymap name
								( $answer->{'cbQosName'}, $answer->{'cbQosParentObjectsIndex2'} )
									= $SNMP->getarray( "cbQosPolicyMapName.$answer->{'cbQosConfigIndex'}",
									"cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}" );
								$self->nmisng->log->debug2("parent policymap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}"
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
								$self->nmisng->log->debug2("parent classmap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}"
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
								$self->nmisng->log->debug2("skip - this class-map is part of a match statement");
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
						$self->nmisng->log->debug2("queueing - bandwidth $answer->{'cbQosQueueingCfgBandwidth'}, units $answer->{'cbQosQueueingCfgBandwidthUnits'},"
								. "rate $CMRate, parent ID $answer->{'cbQosParentObjectsIndex'}" );
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMCfgRate'} = $CMRate;
					}
					elsif ( $answer->{'cbQosObjectsType'} eq 6 )
					{
						# traffic shaping
						( $answer->{'cbQosTSCfgRate'}, $answer->{'cbQosParentObjectsIndex'} )
							= $SNMP->getarray( "cbQosTSCfgRate.$qosIndexTable->{$OIndex}",
							"cbQosParentObjectsIndex.$PIndex.$OIndex" );
						$self->nmisng->log->debug2("shaping - rate $answer->{'cbQosTSCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
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
						$self->nmisng->log->debug2("police - rate $answer->{'cbQosPoliceCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}"
						);
						$CMValues{"H" . $answer->{'cbQosParentObjectsIndex'}}{'CMPoliceCfgRate'}
							= $answer->{'cbQosPoliceCfgRate'};
					}

					$self->nmisng->log->debug6(Dumper($answer)) if ($self->nmisng->log->is_level(6));
				}

				if ( $answer->{'cbQosPolicyMapName'} eq "" )
				{
					$answer->{'cbQosPolicyMapName'} = 'default';
					$self->nmisng->log->debug2("policymap - name is blank, so setting to default");
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
				$self->nmisng->log->debug2("No collect requested in Node table");
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

			$self->nmisng->log->debug2(
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
									$self->nmisng->log->debug2(
										"rrd cbqos-$direction-$classname, ds $dsname, current limit $curval, desired limit $desiredval: adjusting limit"
											);
									RRDs::tune( $rrdfile, "--maximum", "$dsname:$desiredval" );
								}
								else
								{
									$self->nmisng->log->debug2("rrd cbqos-$direction-$classname, ds $dsname, current limit $curval is correct");
								}
							}
						}
						$inventory->data_info( subconcept => $classname, enabled => 0 );
					}

					my ( $op, $error ) = $inventory->save();
					$self->nmisng->log->debug2( "saved ".join(',', @$path)." op: $op");
					$self->nmisng->log->error( "Failed to save inventory:" . join( ",", @{$inventory->path} ) . " error:$error" )
							if ($error);
				}
			}
		}
	}
	else
	{
		$self->nmisng->log->debug2("no entries found in QoS table of node $name");
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
				$self->nmisng->log->debug2("no collect for interface $intf $direction ($CB->{'Interface'}{'Descr'}) by control ($S->{mdl}{system}{cbqos}{nocollect}) at Policymap $CB->{'PolicyMap'}{'Name'}"
				);
				next;
			}
			++$happy;

			my $PIndex = $CB->{'PolicyMap'}{'Index'};
			foreach my $key ( keys %{$CB->{'ClassMap'}} )
			{
				my $CMName = $CB->{'ClassMap'}{$key}{'Name'};
				my $OIndex = $CB->{'ClassMap'}{$key}{'Index'};
				$self->nmisng->log->debug2("Interface $intf, ClassMap $CMName, PolicyIndex $PIndex, ObjectsIndex $OIndex");
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
						$self->nmisng->log->warn("mismatch of indexes in getCBQoSdata, cannot collect data at this time");
						return;
					}

					# oke, store the data
					$self->nmisng->log->debug2("bytes transfered $D->{'PrePolicyByte'}{value}, bytes dropped $D->{'DropByte'}{value}");
					$self->nmisng->log->debug2("packets transfered $D->{'PrePolicyPkt'}{value}, packets dropped $D->{'DropPkt'}{value}");
					$self->nmisng->log->debug2("packets dropped no buffer $D->{'NoBufDropPkt'}{value}");


					# update RRD, rrd file info comes from inventory,
					# storage/subconcept: class name == subconcept
					my $db = $S->create_update_rrd( data  => $D,
																					type  => $CMName, # subconcept
#																					index => $intf,		# not needed
#																					item  => $CMName, # not needed
																					inventory => $inventory );
					if ( $db )
					{
						my $target = {};
						NMISNG::Inventory::parse_rrd_update_data( $D, $target, $previous_pit, $CMName );
						# get stats, subconcept here is too specific, so use concept name, which is what
						#  stats expects anyway
						my $period = $self->nmisng->_threshold_period( subconcept => $concept );
						# subconcept is completely variable, so we must tell the system where to find the stats
						my $stats = Compat::NMIS::getSubconceptStats( sys => $S, inventory => $inventory, subconcept => $CMName,
																													stats_section => $concept, start => $period, end => time );
						if (ref($stats) ne "HASH")
						{
							$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																		.", subconcept $CMName failed: $stats");
							$stats = {};
						}
						my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $CMName,
																										time => $catchall_data->{last_poll}, delay_insert => 1 );
						$self->nmisng->log->error("(".$self->name.") failed to add timed data for ". $inventory->concept .": $error") if ($error);
					}
				}
				else
				{
					$self->nmisng->log->error("($S->{name}) getCBQoSdata encountered $anyerror");
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
	my $nodemodel = $S->inventory( concept => 'catchall' )->data->{nodeModel};

	my $M    = $S->mdl;
	my $CA   = $S->alerts;
	return if (!defined $CA);

	my ($result, %Val,  %ValMeM, $hrCpuLoad);

	$self->nmisng->log->debug("Running Custom Alerts for node $name");
	foreach my $sect ( keys %{$CA} )
	{
		# get the inventory instances that are relevant for this section,
		# ie. only enabled and nonhistoric ones
		my $ids = $self->get_inventory_ids( concept => $sect, filter => { enabled => 1, historic => 0 } );
		$self->nmisng->log->debug2("Custom Alerts for $sect");
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
					$self->nmisng->log->debug2("control_result sect=$sect index=$index control_result=$control_result");
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
								$self->nmisng->log->error("CVAR$varnum references unknown object \"$decl\" in \""
										. $CA->{$sect}{$alrt}{$key}  ." of section $sect, alert $alrt, key $key, model $nodemodel" )
									if ( !exists $data->{$decl} );
							}
							elsif ( defined $varuse )                           # cvar use
							{
								$self->nmisng->log->error("CVAR$varuse used but not defined in test \""
										. $CA->{$sect}{$alrt}{$key} ." of section $sect, alert $alrt, key $key, model $nodemodel" )
									if ( !exists $CVAR[$varuse] );

								$rebuilt .= $CVAR[$varuse];                     # sub in the actual value
							}
							else                                                # shouldn't be reached, ever
							{
								$self->nmisng->log->error( "CVAR parsing failure for \"" .
																					 $CA->{$sect}{$alrt}{$key}
																					 . " of section $sect, alert $alrt, key $key, model $nodemodel");

								$rebuilt = $origexpr = '';
								last;
							}
						}
						$rebuilt .= $origexpr;    # and the non-CVAR-containing remainder.

						$$target = eval { eval $rebuilt; };
						$self->nmisng->log->debug2("substituted $key sect=$sect index=$index, orig=\""
								. $CA->{$sect}{$alrt}{$key}
								. "\", expr=\"$rebuilt\", result=$$target");
					}

					if ( $test_value =~ /^[\+-]?\d+\.\d+$/ )
					{
						$test_value = sprintf( "%.2f", $test_value );
					}

					my $level = $CA->{$sect}{$alrt}{level};

					# check the thresholds, in appropriate order
					# report normal if below level for warning (for threshold-rising, or above for threshold-falling)
					# debug-warn and ignore a level definition for 'Normal' - overdefined and buggy!
					# tag as warn, emit only if debug 2 or higher
					if ( $CA->{$sect}{$alrt}{type} =~ /^threshold/ )
					{
						$self->nmisng->log->warn("ignoring deprecated threshold level Normal for alert \"$alrt\"!")
								if ($self->nmisng->log->is_level(2) && defined($CA->{$sect}->{$alrt}->{threshold}->{'Normal'}));

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
							$self->nmisng->log->error("skipping unknown alert type \"$CA->{$sect}{$alrt}{type}\" of section $sect, alert $alrt  model $nodemodel!");
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
						$self->nmisng->log->debug2("alert result: test_value=$test_value test_result=$test_result level=$level");
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
					$alert->{source} = $CA->{$sect}{$alrt}{source};
					 
					push( @{$S->{alerts}}, $alert );
				}
			}
		}
	}

	$self->process_alerts( sys => $S );

	$self->nmisng->log->debug("Finished with handle_custom_alerts");
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
		$self->nmisng->log->debug(
			"Processing alert: event=Alert: $alert->{event}, level=$alert->{level}, element=$alert->{ds}, details=Test $alert->{test} evaluated with $alert->{value} was $alert->{test_result}"
		) if $alert->{test_result};

		$self->nmisng->log->debug4("Processing alert " . Dumper($alert));

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
			index    => $alert->{index},             #$args{index},
			level    => $tresult,
			status   => $statusResult,
			element  => $alert->{ds},
			section => $alert->{section},
			source => $alert->{source},
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

	$self->nmisng->log->debug2("Starting compute_reachability for node $name, type=$catchall_data->{nodeType}");

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
	$self->nmisng->log->debug2("availability using interface_availability_value_when_down=$C->{interface_availability_value_when_down} intAvailValueWhenDown=$intAvailValueWhenDown"
	);

	# Things which don't do collect get 100 for availability
	if ( $reach{availability} eq "" and !NMISNG::Util::getbool( $catchall_data->{collect} ) )
	{
		$reach{availability} = "100";
	}
	elsif ( $reach{availability} eq "" ) { $reach{availability} = $intAvailValueWhenDown; }

	my ( $outage, undef ) = NMISNG::Outage::outageCheck( node => $self, time => time() );
	$self->nmisng->log->debug2("Outage for $name is ". ($outage || "<none>"));

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

				$self->nmisng->log->debug2("Reach for Disk disk=$reach{disk} diskWeight=$diskWeight");
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

				$self->nmisng->log->debug2("Reach for Swap swap=$reach{swap} swapWeight=$swapWeight");
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

		$self->nmisng->log->debug2(
			"REACH Values: reachability=$reach{reachability} availability=$reach{availability} responsetime=$reach{responsetime}"
		);
		$self->nmisng->log->debug2("REACH Values: CPU reach=$reach{cpu} weight=$cpuWeight, MEM reach=$reach{mem} weight=$memWeight");

		if ( NMISNG::Util::getbool( $catchall_data->{collect} ) and defined $S->{mdl}{interface}{nocollect}{ifDescr} )
		{
			$self->nmisng->log->debug2("Getting Interface Utilisation Health");
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
					$self->nmisng->log->debug2("Faild to get_newest_timed_data for interface");
					next;
				}
				# stats data is derived, stored by subconcept
				my $util = $latest_ret->{derived_data}{interface};
				if ( $util->{inputUtil} eq 'NaN' or $util->{outputUtil} eq 'NaN' )
				{
					$self->nmisng->log->debug2("SummaryStats for interface=$index of node $name skipped because value is NaN");
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
					$self->nmisng->log->debug2(
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

		if ( lc $reach{health} eq 'nan' )
		{
			$self->nmisng->log->debug2("Calculation of health=$reach{health}");
			$self->nmisng->log->debug2("Values Calc. reachability=$reach{reachability} * $C->{weight_reachability}");
			$self->nmisng->log->debug2("Values Calc. intWeight=$intWeight * $C->{weight_int}");
			$self->nmisng->log->debug2("Values Calc. responseWeight=$responseWeight * $C->{weight_response}");
			$self->nmisng->log->debug2("Values Calc. availability=$reach{availability} * $C->{weight_availability}");
			$self->nmisng->log->debug2("Values Calc. cpuWeight=$cpuWeight * $C->{weight_cpu}");
			$self->nmisng->log->debug2("Values Calc. memWeight=$memWeight * $C->{weight_mem}");
			$self->nmisng->log->debug2("Values Calc. swapWeight=$swapWeight * $C->{weight_mem}");
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
		$self->nmisng->log->debug2("Node is Down using availability=$intAvailValueWhenDown");
		$reach{reachability} = 0;
		$reach{availability} = $intAvailValueWhenDown;
		$reach{responsetime} = "U";
		$reach{intfTotal}    = 'U';
		$reach{health}       = 0;
	}

	$self->nmisng->log->debug2("Reachability and Metric Stats Summary");
	$self->nmisng->log->debug2("collect=$catchall_data->{collect} (Node table)");
	$self->nmisng->log->debug2("ping=$pingresult (normalised)");
	$self->nmisng->log->debug2("cpuWeight=$cpuWeight (normalised)");
	$self->nmisng->log->debug2("memWeight=$memWeight (normalised)");
	$self->nmisng->log->debug2("swapWeight=$swapWeight (normalised)") if $swapWeight;
	$self->nmisng->log->debug2("intWeight=$intWeight (100 less the actual total interface utilisation)");
	$self->nmisng->log->debug2("diskWeight=$diskWeight");
	$self->nmisng->log->debug2("responseWeight=$responseWeight (normalised)");

$self->nmisng->log->debug2("Reachability KPI=$reachabilityHealth/$reachabilityMax");
$self->nmisng->log->debug2("Availability KPI=$availabilityHealth/$availabilityMax");
$self->nmisng->log->debug2("Response KPI=$responseHealth/$responseMax");
$self->nmisng->log->debug2("CPU KPI=$cpuHealth/$cpuMax");
$self->nmisng->log->debug2("MEM KPI=$memHealth/$memMax");
$self->nmisng->log->debug2("Int KPI=$intHealth/$intMax");
$self->nmisng->log->debug2("Disk KPI=$diskHealth/$diskMax") if $diskHealth;
$self->nmisng->log->debug2("SWAP KPI=$swapHealth/$swapMax") if $swapHealth;

$self->nmisng->log->debug2("total number of interfaces=$reach{intfTotal}");
$self->nmisng->log->debug2("total number of interfaces up=$reach{intfUp}");
$self->nmisng->log->debug2("total number of interfaces collected=$reach{intfCollect}");
$self->nmisng->log->debug2("total number of interfaces coll. up=$reach{intfColUp}");

	for $index ( sort keys %reach )
	{
		$self->nmisng->log->debug2("$index=$reach{$index}");
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
		if ($db)
		{
			my $pit = {};
			my $previous_pit = $catchall_data->get_newest_timed_data();
			NMISNG::Inventory::parse_rrd_update_data( \%reachVal, $pit, $previous_pit, "health" );
			my $stats = $self->compute_summary_stats(sys => $S, inventory => $catchall_inventory );
			my $error = $catchall_data->add_timed_data( data => $pit, derived_data => $stats, subconcept => "health",
																									time => $catchall_data->{last_poll}, delay_insert => 1 );
			$self->nmisng->log->error("($name) failed to add timed data for ". $catchall_data->concept .": $error") if ($error);
			# $inventory->data($data);
			$catchall_data->save();
		}
	}
	$self->nmisng->log->debug2("Finished");

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

	my $S = NMISNG::Sys->new(nmisng => $self->nmisng);    # create system object
	# loads old node info (unless force is active), and the DEFAULT(!) model (always!),
	# and primes the sys object for snmp/wmi ops

	if (!$S->init(node => $self,	update => 'true', force => $args{force}))
	{
		$self->unlock(lock => $lock);
		$self->nmisng->log->error("($name) init failed: " . $S->status->{error} );
		
		# Update last attempt
		my ($inventory, $error) =  $self->inventory( concept => "catchall" );
		
		my $old_data = $inventory->data();
		if ($old_data) {
			$old_data->{'last_update_attempt'} = Time::HiRes::time;
		
			$inventory->data($old_data);
			my ($save, $error2) = $inventory->save();
			
			$self->nmisng->log->warn("Update last poll for $name failed, $error2") if ($error2);
		} else {
			$self->nmisng->log->warn("Failed to get inventory for node $name failed, $error");
		}

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

	if (NMISNG::Util::getbool( $args{force} ) )
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
				$self->update_concepts(sys => $S) if defined $S->{mdl}{systemHealth};
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
	}
	else
	{
		push @problems, "Node is unreachable, cannot perform update.";
	}

	# don't let it make the rrd update, we want to add updatetime!
	my $reachdata = $self->compute_reachability(sys => $S,
																							delayupdate => 1);

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
				$self->nmisng->log->debug("Plugin $plugin indicated success");
			}
			elsif ( $status == 0 )
			{
				$self->nmisng->log->debug("Plugin $plugin indicated no changes");
			}
		}
	}

	my $updatetime = $updatetimer->elapTime();
	$self->nmisng->log->debug2("updatetime for $name was $updatetime");
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

	# update the coarse compat 'nodestatus' property, not multiple times
	my $coarse = $self->coarse_status;
	$catchall_data->{nodestatus} = $coarse < 0? "degraded" : $coarse? "reachable" : "unreachable";

	$catchall_inventory->save();
	if (my $issues = $self->unlock(lock => $lock))
	{
		$self->nmisng->log->error($issues);
	}
	$self->nmisng->log->debug("Finished with update");

	return @problems? { error => join(" ",@problems) } : { success => 1 };
}

# Called by update
# collect_systemhealth_info iterates over model data
# And marks as inactive the removed concepts
# But the concept that are in the inventory
# And were removed from the model, are not marked as historic
sub update_concepts
{
	my ($self, %args) = @_;
	my $S    = $args{sys};    # object

	my $name = $self->name;
	my $C = $self->nmisng->config;

	my $SNMP = $S->snmp;
	my $M    = $S->mdl;           # node model table

	my $inventory = $self->inventory_concepts();
	my %concepts;
	
	if ( ref( $M->{systemHealth} ) ne "HASH" )
	{
		$self->nmisng->log->debug2("No class 'systemHealth' declared in Model.");
		return 0;
	}
	elsif ( !$S->status->{snmp_enabled} && !$S->status->{wmi_enabled} )
	{
		$self->nmisng->log->warn("cannot get systemHealth info, neither SNMP nor WMI enabled!");
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
		$concepts{$section} = 1;
	}
	
	# Never set these to historic, processed separately
	$concepts{'interface'} = 1;
	$concepts{'catchall'} = 1;
	$concepts{'ping'} = 1;
	$concepts{'device_global'} = 1;
	$concepts{'device'} = 1;
	$concepts{'storage'} = 1;
	$concepts{'service'} = 1;
	
	my %inactive;
	
	foreach my $i (@$inventory) {
		if ($concepts{$i}) {
			$self->nmisng->log->debug8("Concept $i from inventory is defined in model");
		} else {
			# TODO: Activate this feature
			my @index = ();
			my $result = $self->bulk_update_inventory_historic(active_indices => \@index, concept => $i );
			$self->nmisng->log->info("Concept $i marked historic: ". Dumper($result));
		}
	}
	
	return 1;
	
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

	if (ref($standardstats) ne "HASH")
	{
		$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																		.", subconcept $section failed: $standardstats");
		$standardstats = {};
	}

	my $stats8  = Compat::NMIS::getSubconceptStats(
		sys => $S,
		inventory => $inventory,
		subconcept => $section,
		start => $metricsFirstPeriod,
		end => time );

	if (ref($stats8) ne "HASH")
	{
		$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																		.", subconcept $section failed: $stats8");
		$stats8 = {};
	}

	my $stats16 = Compat::NMIS::getSubconceptStats(
		sys => $S,
		inventory => $inventory,
		subconcept => $section,
		start => $metricsSecondPeriod,
		end => $metricsFirstPeriod ); # funny one, from -16h to -8h... has been that way for a while

	if (ref($stats16) ne "HASH")
	{
		$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
															.", subconcept $section failed: $stats16");
		$stats16 = {};
	}

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
		$self->nmisng->log->debug2("Not performing server collection for $name: SNMP not enabled for this node");
		return 1;
	}

	my $M    = $S->mdl;
	my $SNMP = $S->snmp;

	my ( $result, %Val, %ValMeM, $hrCpuLoad, $op, $error );

	$self->nmisng->log->debug("Starting server device/storage collection, node $S->{name}");

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
			$self->nmisng->log->debug2( "saved ".join(',', @$path)." op: $op");
		}

		$self->nmisng->log->error("Failed to save inventory, error_message:$error") if($error);

		foreach my $index ( keys %{$deviceIndex} )
		{
			# create a new target for each index
			my $device_target = {};
			if ( $S->loadInfo( class => 'device', index => $index,
												 target => $device_target ) )
			{
				my $D = $device_target;
				$self->nmisng->log->debug2("device Descr=$D->{hrDeviceDescr}, Type=$D->{hrDeviceType}");
				if ( $D->{hrDeviceType} eq '1.3.6.1.2.1.25.3.1.3' )
				{# hrDeviceProcessor
					( $hrCpuLoad, $D->{hrDeviceDescr} )
						= $SNMP->getarray( "hrProcessorLoad.${index}", "hrDeviceDescr.${index}" );
					$self->nmisng->log->debug2("CPU $index hrProcessorLoad=$hrCpuLoad hrDeviceDescr=$D->{hrDeviceDescr}");

					### 2012-12-20 keiths, adding Server CPU load to Health Calculations.
					push( @{$S->{reach}{cpuList}}, $hrCpuLoad );

					$device_target->{hrCpuLoad}
						= ( $hrCpuLoad =~ /noSuch/i ) ? $overall_target->{hrCpuLoad} : $hrCpuLoad;
					$self->nmisng->log->debug2("cpu Load=$overall_target->{hrCpuLoad}, Descr=$D->{hrDeviceDescr}");
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

					# create_update_rrd logs errors
					my $db = $S->create_update_rrd( data => $D, type => "hrsmpcpu",
																					index => $index, inventory => $inventory );

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
						my $stats = Compat::NMIS::getSubconceptStats(sys => $S,
																												 inventory => $inventory,
																												 subconcept => 'hrsmpcpu',
																												 start => $period, end => time);
						if (ref($stats) ne "HASH")
						{
							$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																		.", subconcept hrsmpcpu failed: $stats");
							$stats = {};
						}
						my $error = $inventory->add_timed_data( data => $target, derived_data => $stats,
																										subconcept => 'hrsmpcpu',
																										time => $catchall_data->{last_poll}, delay_insert => 1 );
						$self->nmisng->log->error("($name) failed to add timed data for ". $inventory->concept .": $error") if ($error);

						($op,$error) = $inventory->save();
						$self->nmisng->log->debug2( "saved ".join(',', @$path)." op: $op");
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
		$self->nmisng->log->debug2("Class=device not defined in model=$catchall_data->{nodeModel}");
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

				$self->nmisng->log->debug2(
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
						$self->nmisng->log->debug("Disk List updated with Util=$diskUtil Size=$D->{hrDiskSize}{value} Used=$D->{hrDiskUsed}{value}");
						push( @{$S->{reach}{diskList}}, $diskUtil );

						$storage_target->{hrStorageDescr} =~ s/,/ /g;    # lose any commas.
						if ( (my $db = $S->create_update_rrd( data => $D, type => $subconcept,
																									index => $index, inventory => $inventory) ) )
						{
							$storage_target->{hrStorageType}              = 'Fixed Disk';
							$storage_target->{hrStorageIndex}             = $index;
							$storage_target->{hrStorageGraph}             = "hrdisk";
							$disk_cnt++;
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

						if ( my $db = $S->create_update_rrd( data => $D, type => $subconcept, inventory => $inventory ) )
						{
							$storage_target->{hrStorageType}         = $storage_target->{hrStorageDescr};    # i.e. virtual memory or swap space
							$storage_target->{hrStorageGraph}        = $typename;
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
					if (ref($stats) ne "HASH")
					{
						$self->nmisng->log->warn("getSubconceptStats for node ".$self->name.", concept ".$inventory->concept
																			.", subconcept $subconcept failed: $stats");
						$stats = {};
					}
					my $error = $inventory->add_timed_data( data => $target, derived_data => $stats, subconcept => $subconcept,
																									time => $catchall_data->{last_poll}, delay_insert => 1 );
					$self->nmisng->log->error("failed to add timed data for ". $inventory->concept .": $error") if ($error);
					$inventory->data_info( subconcept => $subconcept, enabled => 0 );
				}

				# make sure the data is set and save
				$inventory->data( $storage_target );
				$inventory->description( $storage_target->{hrStorageDescr} )
					if( defined($storage_target->{hrStorageDescr}) && $storage_target->{hrStorageDescr});

				($op,$error) = $inventory->save();
				$self->nmisng->log->debug2( "saved ".join(',', @{$inventory->path})." op: $op");
				$self->nmisng->log->error("Failed to save storage inventory, op:$op, error_message:$error") if($error);
			}
			elsif( $oldstorage )
			{
				$self->nmisng->log->warn("failed to retrieve storage info for index=$index, $oldstorage->{hrStorageDescr}, continuing with OLD data!");
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
		$self->nmisng->log->debug2("Class=storage not defined in Model=$catchall_data->{nodeModel}");
	}

	### 2012-12-20 keiths, adding Server Disk Usage to Health Calculations.
	if ( defined $S->{reach}{diskList} and @{$S->{reach}{diskList}} )
	{
		#print Dumper $S->{reach}{diskList};
		$S->{reach}{disk} = Statistics::Lite::mean( @{$S->{reach}{diskList}} );
	}

	$self->nmisng->log->debug("Finished");
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

	$self->nmisng->log->debug("Starting services, node $name");
	# lets change our name for process runtime checking
	$0 = "nmisd worker services $name";

	my $S = NMISNG::Sys->new(nmisng => $self->nmisng);
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

	my ($cpu, $memory, %services);
	# services holds snmp-gathered service status, process name -> array of instances

	my $ST    = NMISNG::Util::loadTable(dir => "conf", name => "Services");
	my $timer = Compat::Timing->new;

	# do an snmp service poll first, regardless of whether any specific services being enabled or not

	my %snmpTable;
	# do we have snmp-based services and are we allowed to check them?
	# ie node active and collect on; if so, then do the snmp collection here
	if ( $snmp_allowed
			 and $self->is_active
			 and $self->configuration->{collect}
			 and ref($self->configuration->{services}) eq "ARRAY"
			 and grep( exists( $ST->{$_} ) && $ST->{$_}->{Service_Type} eq "service",
								 @{$self->configuration->{services}} )
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
					my $textoid = NMISNG::MIB::oid2name($self->nmisng, NMISNG::MIB::name2oid($self->nmisng, $var) . "." . $inst );
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
	my %desiredservices = map { ($_ => 1) } (ref($self->configuration->{services}) eq "ARRAY"?
																					 @{$self->configuration->{services}}: ());

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
				$res->debug(1) if $self->nmisng->log->is_level(4); # resolver debugging only with debug 4 and higher

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
							# programs exiting with 255 (e.g. perl die) should be considered down, not up
							if ($programexit < 0 || $programexit > 100)
							{
								$self->nmisng->log->error("service program $svc->{Program} terminated with unexpected exit code $programexit!");
								$programexit = 0;
							}
							$ret = $programexit;
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

		# check for custom graphs only in the models dir, not models-default
		if (opendir( D, $C->{'<nmis_models>'} ))
		{
			my @cands = grep( /^Graph-service-custom-$safeservice-[a-z0-9\._-]+\.nmis$/, readdir(D) );
			closedir(D);

			map { s/^Graph-(service-custom-[a-z0-9\._]+-[a-z0-9\._-]+)\.nmis$/$1/; } (@cands);
			$self->nmisng->log->debug2( "found custom graphs for service $service: " . join( " ", @cands ) ) if (@cands);

			push @servicegraphs, @cands;
		}

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

	my $S = NMISNG::Sys->new(nmisng => $self->nmisng);

	# if the init fails attempt an update operation instead
	if (!$S->init( node => $self,
									snmp => $wantsnmp,
									wmi => $wantwmi,
									policy => $self->configuration->{polling_policy},
			))
	{
		$self->nmisng->log->debug( "Sys init for $name failed: "
													. join( ", ", map { "$_=" . $S->status->{$_} } (qw(error snmp_error wmi_error)) ) );
		# Update last collect attempts
		my ($inventory, $error) =  $self->inventory( concept => "catchall" );
		
		my $old_data = $inventory->data();
		if ($old_data) {
				my $polltime = Time::HiRes::time;
				$old_data->{'last_poll_snmp_attempt'} = $polltime;
				$old_data->{'last_poll_wmi_attempt'} = $polltime;
				$old_data->{'last_poll_attempt'} = $polltime;
			
				$inventory->data($old_data);
				my ($save, $error2) = $inventory->save();
				
				$self->nmisng->log->warn("Update last poll for $name failed, $error2") if ($error2);
		} else {
				$self->nmisng->log->warn("Failed to get inventory for node $name failed, $error");
		}
		
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
	if (defined($wantsnmp)) {
		$catchall_data->{last_poll_snmp_attempt} = $args{starttime} // Time::HiRes::time;
	}
	if (defined($wantwmi)) {
		$catchall_data->{last_poll_wmi_attempt} = $args{starttime} // Time::HiRes::time;
	}
	
	$self->nmisng->log->debug( "node=$name "
														 . join( " ", map { "$_=" . $catchall_data->{$_} }
																		 (qw(group nodeType nodedown snmpdown wmidown)) ) );

	# update node info data, merge in the node's configuration (which was loaded by sys' init)
	$S->copyModelCfgInfo( type => 'all' );

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
		$catchall_inventory->save();
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
	} else {
		$self->nmisng->log->debug3("Node $name not pingable or no collect");
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
			$self->nmisng->log->debug("Plugin $plugin indicated success");
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

	# update the coarse compat 'nodestatus' property, not multiple times
	my $coarse = $self->coarse_status(catchall_data => $catchall_data);
	$catchall_data->{nodestatus} = $coarse < 0? "degraded" : $coarse? "reachable" : "unreachable";

	$catchall_inventory->save();
	if (my $issues = $self->unlock(lock => $lock))
	{
		$self->nmisng->log->error($issues);
	}

	$self->nmisng->log->debug("Finished");
	return { success => 1};
}

# ping host retrieve and return min, avg, max round trip time
# relying on finding a standard ping in PATH.
# Try to not be platform specific if at all possible.
#
sub ext_ping
{
	my ($self, %args) = @_;
	my($host, $length, $count, $timeout) = @args{"host","packet","retries","timeout"};

	my ($ping_output, $redirect_stderr, $pid, %pt, $alarm_exists);

	$timeout ||= 3;
	$count ||= 3;
	$length ||= 56;

	my $pingcmd = 'ping -4';
	my $ip_protocol = $self->configuration->{ip_protocol} || 'IPv4';
	if ($ip_protocol eq "IPv6")
	{
		$pingcmd = 'ping -6';
	}

	# List of known ping programs, key is lc(os)
	my %ping = (
		'mswin32' =>	"$pingcmd -l $length -n $count -w $timeout $host",
		'aix'	=>	"/etc/$pingcmd $host $length $count",
		'bsdos'	=>	"/bin/$pingcmd -s $length -c $count $host",
		'darwin' =>	"/sbin/$pingcmd -s $length -c $count $host",
		'freebsd' =>	"/sbin/$pingcmd -s $length -c $count $host",
		'hpux'	=>	"/etc/$pingcmd $host $length $count",
		'irix'	=>	"/usr/etc/$pingcmd -c $count -s $length $host",
		'linux'	=>	"/bin/$pingcmd -c $count -s $length $host",
		'suse'	=>	"/bin/$pingcmd -c $count -s $length -w $timeout $host",
		'netbsd' =>	"/sbin/$pingcmd -s $length -c $count $host",
		'openbsd' =>	"/sbin/$pingcmd -s $length -c $count $host",
		'os2' =>	"$pingcmd $host $length $count",
		'os/2' =>	"$pingcmd $host $length $count",
		'dec_osf'=>	"/sbin/$pingcmd -s $length -c $count $host",
		'solaris' =>	"/usr/sbin/$pingcmd -s $host $length $count",
		'sunos'	=>	"/usr/etc/$pingcmd -s $host $length $count",
			);

	# get kernel name for finding the appropriate ping cmd
	my $kernel = lc($self->nmisng->config->{os_kernelname} || $^O);

	unless (defined($ping{$kernel}))
	{
		$self->nmisng->log->fatal("ext_ping not yet configured for \"$kernel\"");
		die "ext_ping not yet configured for \"$kernel\"\n"; # fixme: should this really kill nmis?
	}

	# windows 95/98 does not support stderr redirection...
	# also OS/2 users reported problems with stderr redirection...
	$redirect_stderr = $kernel =~ /^(MSWin32|os2|OS\/2)$/i ? "" : "2>&1";

	# initialize return values
	$pt{loss} = 100;
	$pt{min} = $pt{avg} = $pt{max} = undef;
	$self->nmisng->log->debug4("ext_ping: $ping{$kernel}");

	# save and restore any previously set alarm,
	# but don't bother subtracting the time spent here
	my $remaining = alarm(0);
	eval
	{
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm ($timeout*$count);		# make sure alarm timer is ping count * ping timeout - assuming default ping wait is 1 sec.!

		# read and timeout ping() if it takes too long...
		unless ($pid = open(PING, "$ping{$kernel} $redirect_stderr |"))
		{
			die("\t ext_ping: FATAL: Can't open $ping{$kernel}: $!\n");
		}
		while (<PING>)
		{
			$ping_output .= $_;
		}
		alarm 0;
	};

	if ($@)
	{
		die unless $@ eq "alarm\n";	# propagate unexpected errors
		# timed out: kill child
		kill('TERM', $pid);
		close(PING);

		$self->nmisng->log->error("ext_ping hit timeout $timeout, assuming target $host is unreachable");
		# ... and set return values to dead values
		return($pt{min}, $pt{avg}, $pt{max}, $pt{loss});
	}
	# didn't time out, analyse ping output.
	close(PING);

	# restore previously running alarm
	alarm($remaining) if ($remaining);

	# try to find round trip times
	if ($ping_output =~ m@(?:round-trip|rtt)(?:\s+\(ms\))?\s+min/avg/max(?:/(?:m|std)-?dev)?\s+=\s+(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)@m) {
		$pt{min} = $1; $pt{avg} = $2; $pt{max} = $3;
		}
	elsif ($ping_output =~ m@^\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms,\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms,\s+\w+\s+=\s+(\d+(?:\.\d+)?)ms\s+$@m)
	{
		# this should catch most windows locales
		$pt{min} = $1; $pt{avg} = $3; $pt{max} = $2;
	}
	else
	{
		$self->nmisng->log->error("ext_ping could not parse ping rtt summary for $host!");
		$self->nmisng->log->debug3("output of the ping command $ping{$kernel} was: $ping_output");
	}

	# try to find packet loss
	if ($ping_output =~ m@(\d+)% packet loss$@m) {
		# Unix
		$pt{loss} = $1;
		}
		elsif ($ping_output =~ m@(\d+)% (?:packet )?loss,@m) {
		# RH9 and RH9 ES - ugh !
		$pt{loss} = $1;
		}
	elsif ($ping_output =~ m@\(perte\s+(\d+)%\),\s+$@m) {
		# Windows french locale
		$pt{loss} = $1;
		}
	elsif ($ping_output =~ m@\((\d+)%\s+(?:loss|perdidos)\),\s+$@m) {
		# Windows portugesee, spanish locale
		$pt{loss} = $1;
		}
	else
	{
		$self->nmisng->log->error("ext_ping could not parse ping loss summary for $host!");
		$self->nmisng->log->debug3("output of the ping command $ping{$kernel} was: $ping_output");
	}

	$self->nmisng->log->debug3("result returning min=$pt{min}, avg=$pt{avg}, max=$pt{max}, loss=$pt{loss}");

	return($pt{min}, $pt{avg}, $pt{max}, $pt{loss});
}


1;

=pod

=head1 node structure in db

_id (database id)
uuid (globally unique for this node, R/O)
name (display name)
cluster_id (the collecting/controlling server's cluster_id)
activated (hash of product, NMIS/opXYZ/... -> 0/1)
lastupdate (timestamp of last change in db, only written)
configuration (hash substructure)
overrides (hash substructure)
aliases (array of hashes substructure, not used by plain nmis itself)
addresses (array of hashes substructure, not used by plain nmis itself)

=cut
