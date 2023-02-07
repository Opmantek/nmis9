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

our $VERSION = "1.1.0";

use Clone;              # for copying data and other r/o sections
use Module::Load;       # for getting subclasses in instantiate
use Scalar::Util;       # for weaken
use Data::Dumper;
use Time::HiRes;
use Time::Moment;								# for ttl indices
use DateTime;										# ditto
use List::MoreUtils;    # for uniq
use Carp;
use File::Basename;							# for relocate_storage
use Test::Deep::NoTest;
use File::Copy;

use NMISNG::DB;
use NMISNG::Log;

###########
# Class/Package methods:
###########

our $nmisng = undef;
# based on the concept, decide which class to create - or return the fallback/default class
# args: concept
# returns: class name
sub get_inventory_class
{
	my ($concept) = @_;
	my %knownclasses = (
		'default'   => 'DefaultInventory',     # the fallback, must be present
		'service'   => "ServiceInventory",
		'interface' => 'InterfaceInventory',
			# ...
	);

	my $class = "NMISNG::Inventory::" . ( $knownclasses{$concept} // $knownclasses{default} );
	return $class;
}

# compute path from data and selection args.
# note: this is a generic class function, not object method!
#
# take data and a set of keys (path_keys, which index the provided data) and create
# a path out of them. This is a generic function that can work with any class;
# you just need to provide the params, this is why it exists here.
#
# DefaultInventory relies on this implementation to work, if your subclass does not need to do anything
# fancy (like morph/tranlate data in keys) then it should probably use this implementation
# args: cluster_id, node_uuid, concept, data, path_keys (all required), partial (optional, default: 0)
# returns error message or path arrayref if ok
sub make_path_from_keys
{
	my (%args) = @_;

	my $keys = $args{"path_keys"};
	if ( ref($keys) ne "ARRAY" )
	{
		$nmisng->log->fatal("make_path_from_keys cannot work without path_keys!");
		return "make_path_from_keys cannot work without path_keys!"
	}
	# this could be passed in as undef instead of being omitted, so don't use exists
	if ( defined($args{data}) && ref( $args{data} ) ne "HASH" )
	{
		$nmisng->log->fatal( "make_path_from_keys has invalid data argument: " . ref( $args{data} ));
		return "make_path_from_keys has invalid data argument: " . ref( $args{data} )
	}

	my @path;

	# to make the path globally unique
	for my $prefixelem ( "cluster_id", "node_uuid", "concept" )
	{
		if ( !$args{partial} && !defined( $args{$prefixelem} ) )
		{
			$nmisng->log->fatal("make_path_from_keys is missing $prefixelem argument!");
			return "make_path_from_keys is missing $prefixelem argument!";
		}
		push @path, $args{$prefixelem};
	}

	# now go through the given path_keys
	foreach my $pathelem (@$keys)
	{
		if ( !$args{partial} && !defined( $args{data}->{$pathelem} ) )
		{
			$nmisng->log->fatal(NMISNG::Log::trace() ."make_path_from_keys is missing $pathelem data!");
			return ("make_path_from_keys is missing $pathelem data!");
		}
		push @path, $args{data}->{$pathelem};
	}
	return \@path;
}

# (re)compute path from instance data - BUT also create path WITHOUT instance!
# note: MUST NOT be instance method, but a class function, ie. NO SELF!
# this is so that paths can be calculated without a whole object being created (which is handy for searching,
# used from Node.pm)
#
# subclasses MUST implement this.
#
# args: cluster_id, node_uuid, concept, data, (all required),
# path_keys (required for a simple class using make_path_from_keys); partial (optional)
#
# it should fill out the path value (arrayref),
# it MUST construct the path with cluster_id, node_uuid and concept as the first three elements,
# it should return an error message if it does not have enough data to create the path
# if partial is 1 then part of a path will be returned, which could be handy for searching (maybe?)
#
# returns error message or path array ref
sub make_path
{
	# make up for object deref invocation being passed in as first argument
	# expecting a hash which has even # of inputs
	shift if ( !( $#_ % 2 ) );

	die( __PACKAGE__ . "::make_path must be implemented by subclass!" );
}

# take a data structure same as what create_update_rrd accepts
# and convert it into values that time_data can use.
# args:
#  rrd_data - data sent to create_update_rrd, hashref, each entry holding a hash keys @{value,option}
#  target - where to put the parsed data
#  previous_pit - previous entry for this thing, note: could be looked up if we want, not done right now
#   expects the full pit, with data in subconcept hashes
#  subconcept - data stored in timed under subconcept hash so this is needed for the return value to
#    give the correct structure back for datasets, target is left alone, add_timed_data will put the
#    data where it should go
#    the uses this value to find the data previous data from the correct sub-hash
# NOTE: does not handle counter wrapping at this time
# returns hashref with keys defined for datasets that have values
sub parse_rrd_update_data
{
	my ( $rrd_data, $target, $previous_pit, $subconcept ) = @_;
	die "subconcept required" if( !$subconcept );

	my %key_meta;
	foreach my $key ( keys %$rrd_data )
	{
		my $key_raw = $key . "_raw";
		my $entry   = $rrd_data->{$key};
		if ( $entry->{option} eq 'nosave' ) { }
		elsif ( $entry->{option} =~ /^counter/ )
		{
			$target->{$key_raw} = $entry->{value};

			# autovivifies but no problem
			my $prev_value
				= ( $previous_pit->{success} && exists( $previous_pit->{data}{$subconcept}->{$key_raw} ) )
				? $previous_pit->{data}{$subconcept}->{$key_raw}
				: undef;
			$target->{$key} = ($prev_value) ? ( $entry->{value} - $prev_value ) : 0;
			# try and force to a number
			$target->{$key} += 0.0;

			# keep track of dataset
			$key_meta{$key} = 1;
		}
		else
		{
			# try and force to a number
			$target->{$key} = $entry->{value} + 0.0;
			$key_meta{$key} = 1;
		}
	}
	# all changes are done in place
	return { $subconcept => \%key_meta };
}

# used to turn 'headers' section in a model into the keys and descriptions
# for displaying the subconcept in a table (for instance)
# headers lists the data keys to be displayed but does not describe the column
# headers, which can be re-defined in the model section
# args - model_section - place in the model this is coming from, proto - snmp/wmi
#  where to look in the model for the data/descriptions
sub parse_model_subconcept_headers
{
	my ($model_section,$proto) = @_;
	my $retval = [];
	my $headers = [ split(/\s*,\s*/, $model_section->{headers}) ];
	foreach my $key (@$headers)
	{
		my $title = $key;
		if( defined($model_section->{$proto}{$key}) &&
			 defined($model_section->{$proto}{$key}{title}) )
		{
			$title = $model_section->{$proto}{$key}{title};
		}
		push @$retval, { $key => $title };
	}
	return $retval;
}

sub check_inventory_for_bad_things
{
	my ($nmisng,$min_size) = @_;
	$min_size //= 50;
	my @pipeline = (
		{ '$unwind' => '$dataset_info' },
		{	'$project' => {
			'_id' => 1,
			'node_uuid' => 1,
			'subconcept' => '$dataset_info.subconcept',
			'dataset_info_datsets_size' => { '$size' => '$dataset_info.datasets' }
		}},
		{	'$match' => {
			'dataset_info_datsets_size' => { '$gt' => $min_size }
		}}
	);
	my ($entries,$count,$error) = NMISNG::DB::aggregate(
		collection => $nmisng->inventory_collection,
		post_count_pipeline => \@pipeline,
	);
	return ($entries,$error);
}

# mark the object as changed to tell save() that something needs to be done
# each section is tracked for being dirty, if it's 1 it's dirty
#
# args: nothing or (0) or (N,section or reason)
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

	foreach my $key (keys %{$self->{_dirty}})
	{
		return 1 if ( $self->{_dirty}{$key} );
	}
	return 0;
}

# returns list of dirty components, may be empty
sub _whatisdirty
{
	my ($self) = @_;
	return grep($self->{_dirty}->{$_}, keys %{$self->{_dirty}});
}

# a simple setter/getter for the object's 'data' properties (and only these!)
# primarily meant for use by subclasses
# expects: name => fieldname, optional value => newvalue
# returns the old value for updates, current value for reads
sub _generic_getset
{
	my ($self,%args) = @_;

	die "cannot read option without name!\n" if (!exists $args{name});
	my $fieldname = $args{name};

	my $curval = $self->data()->{$fieldname};
	if (exists $args{value})
	{
		my $newvalue = $args{value};
		$self->dirty(1, "data")
				if ($self->data->{$fieldname} ne $newvalue);
		$self->data()->{$fieldname} = $newvalue;
	}
	return $curval;
}

###########
# Public:
###########

# create a new inventory manager object
# note: the object is always strictly associated with a node_uuid and a cluster_id
# this method is expected to be subclassed!
#
# params: concept (=class name, type of inventory),
#  nmisng (parent object), node_uuid, cluster_id - all required
# optional: id  (alias _id, the db _id of this thing if it's not new),
#  path (used if provided, not required, normally can be calculated on save),
#  data (used if provided, one of path or data needed at time of save)
#  enabled (1/0, "nmis does something with this inventory item"),
#  historic (not present or 0, or anything else),
#  storage (hash of subconcept name -> path to the rrd file for this thing, relative to database_root),
#  path_key (must be arrayref if present - used for simplest path computation, ie. with listed keys from data),
#  description (optional, if not given a descriptive text is synthesized)
sub new
{
	my ( $class, %args ) = @_;

	$nmisng = $args{nmisng};
	return undef if ( !$nmisng );    # check this early so we can use it to log

	for my $musthave (qw(concept cluster_id node_uuid))
	{
		if ( !defined $args{$musthave} )
		{
			$nmisng->log->fatal("Inventory object cannot be created without $musthave!");
			return undef;
		}
	}
    
	my $data = ($args{data} //= {});	# synthesise data as hash (if empty) for db consistency
	if ( defined($data) && ref($data) ne "HASH" )
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid data argument!");
		return undef;
	}
	if ( defined( $args{storage} ) && ref( $args{storage} ) ne "HASH" )
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid storage argument!");
		return undef;
	}
	if ( defined( $args{path_keys} ) && ref( $args{path_keys} ne "ARRAY" ) )
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid path_keys argument!");
		return undef;
	}

	# compat issue, we *may* get _id
	$args{id} //= $args{_id};
	
	# description? we don't want any logic to abuse that, but having some human-friendly bits are desirable
	if ( !defined $args{description} )
	{
		my $nodenames = $nmisng->get_node_names( uuid => $args{node_uuid} );
		my $thisnodename = $nodenames->[0] // "UNKNOWN";    # can that happen?
		$args{description} = "concept $args{concept} on node $thisnodename and server $args{cluster_id}";
		$args{description} .= " with index " . $data->{index} if ( defined( $data->{index} ) && $data->{index} );
	}

	# set default properties, then update with args
	my $self = bless(
		{   _enabled  => 1,
				_historic => 0,
				_dirty => {},
				_datasets => {},
				(   map { ( "_$_" => $args{$_} ) } (
							qw(concept node_uuid cluster_id data id nmisng
						path path_keys storage subconcepts description
            lastupdate)
						)
				)
		},
		$class);

	# enabled and historic: override defaults only if explicitely given
	for my $onlyifgiven (qw(enabled historic))
	{
		$self->{"_$onlyifgiven"} = ( $args{$onlyifgiven} ? 1 : 0 ) if ( exists $args{$onlyifgiven} );
	}

	# in the object datasets are stored optimally for adding/checking (hash of hashes)
	# in the db they are stored optimally for querying/aggregating (array of arrays)
	my $dataset_info = $args{dataset_info} // [];
	die "dataset_info must be an array" . Carp::longmess() if ( ref($dataset_info) ne 'ARRAY' );

	foreach my $entry (@$dataset_info)
	{
		my $subconcept          = $entry->{subconcept};
		my $subconcept_datasets = $entry->{datasets};

		# turn arrays into hashes here, we store as array in db because we can't do much with keys in mongo
		my %dataset_map = map { $_ => 1 } (@$subconcept_datasets);
		$self->dataset_info( subconcept => $subconcept, datasets => \%dataset_map );
	}

	my $data_info = $args{data_info} // [];
	die "data_info must be an array" . Carp::longmess() if ( ref($data_info) ne 'ARRAY' );
	$self->{_data_info} = {};
	foreach my $entry (@$data_info)
	{
		$self->data_info(%$entry);
	}
	# Fill the server name
	$self->{"_server_name"} = $self->{_nmisng}->get_server_name(cluster_id => $self->{_cluster_id});
	
	# not dirty at this time
	$self->_dirty(0);

	# keeping a copy of nmisng which could go away means it needs weakening
	Scalar::Util::weaken $self->{_nmisng} if ( !Scalar::Util::isweak( $self->{_nmisng} ) );
	return $self;
}


# this function adds one point-in-time data record for this concept instance
#
# PIT data can consist of two types of information, a 'derived_data' hash (might be deep, currently isn't),
# and a 'data' hash which MAY be deep if the caller controls datasets directly, or lets add_timed_data
# handle depth/structure via subconcept argument.
#
# note that the dataset info _in the inventory object_ is updated/extended from args given to this function.
#
# args: self (must have been saved, ie. have _id), data (hashref), derived_data (hashref),
# time (optional, defaults to now), delay_insert (optional, default no),
# subconcept OR datasets (exactly one is required)
# flush, internal only, used for saving delayed, does not allow modifying anything
#
# delay_insert - delay inserting until save is called - if it's never called it's not saved!
#   if data has already been queued for the time/concept/subconcept then new data provided will overwrite existing,
#   derived_data and data are treated separately, so data can be set one call and derived_data in another,
#   and per-subconcept data can be accumulated across calls as well.
#   delay/non-delay add's do not mix, if a delay call is followed by a non-delay, the non-delay will ignore
#   all existence of the delay'd data.
#
# subconcept/datasets - exactly one of these must be given!
#
# subconcept: must be string, SHOULD match one of the known subconcepts for this inventory;
#   if subconcept given, then data MUST be flat and add_timed_data arranges the
#   deep storage of data under this subconcept.
#   all keys in that data are automatically added to the inventory's dataset info.
#
# datasets: must be hash that represents ALL of the desired dataset info for this inventory,
#   ie. key subconceptA => { dsnameA => 1, dsnameB => 1 }, subconceptB => ....
#   in this case, data may be a deep hash. if you repeat calls with delay_save in that situation, the last
#   data/derived data wins. the inventory's datasets info is amended/extended from that dataset info.
#
#
# returns: undef or error message
#
# NOTE: inventory->save will call this function to saved "delayed_insert", the insert code below actually
#   calls inventory->save again, this seems like a possible bad thing. the reason it's working right now is
#   the second call to this function (from save) should not alter the datasets which is what triggers the save to be called
#  so it will never happen
# NOTE2: the data/derived data is not stored as is, it gets morphed from hash of hashes to array of hashes
#   data goes from subconcepts->{$} => { data=>{},derived_data=>{}}
#   to subconcepts => [{ subconcept=>$,data=>{},derived_data =>{}}]
sub add_timed_data
{
	my ( $self, %args ) = @_;

	return "cannot add timed data, invalid data argument!"
		if ( ref( $args{data} ) ne "HASH" );    # empty hash is acceptable
	return "cannot add timed data, invalid derived_data argument!"
		if ( ref( $args{derived_data} ) ne "HASH" );    # empty hash is acceptable
	my ( $data, $derived_data, $time, $delay_insert, $flush )
			= @args{'data', 'derived_data', 'time', 'delay_insert','flush'};

	# automatically take care of datasets
	# one of these two must be defined
	my ( $subconcept, $datasets ) = @args{'subconcept', 'datasets'};

	return "subconcept is required stack:" . Carp::longmess() if ( !$subconcept && !$flush);
	return "datasets must be hash if defined" . Carp::longmess()
			if ( $datasets && ref($datasets) ne 'HASH' && !$flush );
	# ttl: record time plus purge_timeddata_after seconds (default 7 days)
	$time ||= Time::HiRes::time;
	my $expire_at = $time + ($self->nmisng->config->{purge_timeddata_after} || 7*86400);

	# to make the db ttl expiration work this must be
	# an acceptable date type for the driver version
	$expire_at = Time::Moment->from_epoch($expire_at);

	# if the request is to delay, append to the existing queue (or make an empty hash), otherwise make a new record
	# cluster_id here is just handy, not necessarily required
	my $timedrecord = { time => $time, expire_at => $expire_at, cluster_id => $self->cluster_id };
	$timedrecord = $self->{_queued_pit} if( defined($self->{_queued_pit}) );
    $timedrecord->{node_uuid} = $self->node_uuid();
	my $node = $self->nmisng->node( filter => {uuid => $self->node_uuid()} );
	if ($node)
	{
		$timedrecord->{configuration}->{group} = $node->configuration()->{'group'};
	}
	
	# if datasets was not given (and not flushing) try and figure out what the datasets are
	if (!$datasets && !$flush)
	{
		# todo: verify that structure is not deep, if it is this 'auto' getting datasets breaks down
		$datasets->{$subconcept} = {map { $_ => 1 } ( keys %$data )};
	}

	my $datasets_modfied = 0;
	if( !$flush )
	{
		# loop through all provided datasets and make sure they merged into
		# the existing, keeping track if any modifications are actually made
		# if this is a flush there is no need to do this, should already be done
		foreach my $subc ( keys %$datasets )
		{
			my $new_datasets = $datasets->{$subc};
			my $existing_datasets = $self->dataset_info( subconcept => $subc );
			foreach my $key ( keys %$new_datasets )
			{
				if ( !defined( $existing_datasets->{$key} ) )
				{
					$existing_datasets->{$key} = 1;
					$datasets_modfied++;
				}
			}
			$self->dataset_info( subconcept => $subc, datasets => $existing_datasets )
				if ($datasets_modfied);
		}
		# now store the data per subconcept, appending to data, replacing subconcept if it existed
		# if flush is given we already have this, flush
		$timedrecord->{data}->{$subconcept} = $data;
		$timedrecord->{derived_data}->{$subconcept} = $derived_data;
	}

	if ( !$delay_insert || $flush )
	{
		return "cannot add timed data to unsaved inventory instance!"
			if ( $self->is_new );

		$timedrecord->{inventory_id} = $self->id;

		# re-arrange the data for better searching/mongo work, turn it into array entry for each subconcept that
		# holds the subconcept name along with it's data/derived_data
		my @subconcepts = ();
		foreach my $subconcept (keys %{$timedrecord->{data}})
		{
			push @subconcepts, {
				subconcept => $subconcept,
				data => $timedrecord->{data}{$subconcept},
				derived_data => $timedrecord->{derived_data}{$subconcept}
			};
		}
		$timedrecord->{subconcepts} = \@subconcepts;
		delete $timedrecord->{data};
		delete $timedrecord->{derived_data};

		my $dbres = NMISNG::DB::insert(
			collection => $self->nmisng->timed_concept_collection( concept => $self->concept() ),
			record     => $timedrecord
		);
		return "failed to insert record: $dbres->{error}" if ( !$dbres->{success} );

		$dbres = NMISNG::DB::update(
			collection => $self->nmisng->latest_data_collection(),
			query => { inventory_id => $self->id },
			record => $timedrecord,
			upsert => 1
		);
		return "failed to upsert data record: $dbres->{error}" if ( !$dbres->{success} );

		# if the datasets were modified they need to be saved, only if we're not flushing
		# which should only come from save (so don't start a recursive loop)
		$self->save() if (!$flush && $datasets_modfied);
	}
	else
	{
		# only queue a single record
		$self->{_queued_pit} = $timedrecord;
	}
	return undef;
}

# retrieve the one most recent timed data for this instance, this will come from the latest_data
#  unless specifically told to get "from_timed"
#(note: raw _id and inventory_id are not returned: not useful)
# args: from_timed - set 1 if you must have the data from the timed_* collection
# returns: hashref of success, error, time, data.
sub get_newest_timed_data
{
	my ($self,%args) = @_;
	my $from_timed = $args{from_timed} // 0;

	# inventory not saved certainly means no pit data, but  that's no error
	return {success => 1} if ( $self->is_new );

	my $cursor;
	if( $from_timed )
	{
		$cursor = NMISNG::DB::find(
			collection => $self->nmisng->timed_concept_collection( concept => $self->concept() ),
			query => NMISNG::DB::get_query( and_part => {inventory_id => $self->id}, no_regex => 1 ),
			limit => 1,
			sort        => {time => -1},
			fields_hash => {time => 1, subconcepts => 1}
		);
	}
	else
	{
		$cursor = NMISNG::DB::find(
			collection => $self->nmisng->latest_data_collection,
			query => NMISNG::DB::get_query( and_part => {inventory_id => $self->id}, no_regex => 1 ),
			fields_hash => {time => 1, subconcepts => 1}
		);
	}
	return {success => 0, error => NMISNG::DB::get_error_string} if ( !$cursor );

	my $reading = $cursor->next;
	# new driver doesn't offer cursor->count anymore...
	return {success => 1} if (!defined $reading);

	# data/derived data are stored for optimal searching (arrays of hashes),
	# turn them back into hashes (which are much handier for use in perl)
	# data goes from subconcepts => [{ subconcept=>$,data=>{},derived_data =>{}}]
	# to  data=>{$subconcept}{...},derived_data=>{$subconcept}{...}}
	foreach my $entry (@{$reading->{subconcepts}})
	{
		$reading->{data}{$entry->{subconcept}} = $entry->{data};
		$reading->{derived_data}{$entry->{subconcept}} = $entry->{derived_data};
	}

	return {success => 1, data => $reading->{data}, derived_data => $reading->{derived_data}, time => $reading->{time}};
}

# RO, returns cluster_id of this Inventory
sub cluster_id
{
	my ($self) = @_;
	return $self->{_cluster_id};
}

# RO, returns server_name of this Inventory
sub server_name
{
	my ($self) = @_;
	return $self->{_server_name};
}

# RO, returns concept of this Inventory
sub concept
{
	my ($self) = @_;
	return $self->{_concept};
}

# returns the current description, optionally sets a new one
# args: newdescription
# returns: description
sub description
{
	my ( $self, $newdescription ) = @_;
	if ( @_ == 2 )    # new value undef is ok, description is deletable
	{
		$self->_dirty(1,"description") if ($self->{_description} ne $newdescription);
		$self->{_description} = $newdescription;
	}
	return $self->{_description};
}

# enabled/disabled are set when an inventory is found on a device
# but the system or user has decided not to use/collect/manage it
# returns the enabled status, optionally sets a new status
# args: newstatus (will be forced to 0/1)
sub enabled
{
	my ( $self, $newstatus ) = @_;
	if ( @_ == 2 )    # set new value even if input is undef
	{
		$self->_dirty(1,"enabled") if ($self->{_enabled} != $newstatus);
		$self->{_enabled} = $newstatus ? 1 : 0;
	}
	return $self->{_enabled};
}

# historic is/should be set when an inventory was once found on a device
# but is no longer found on that device (but is still in the db!)
# returns the historic status (0/1)
#  optionally sets a new status
# args: newstatus (will be forced to 0/1)
sub historic
{
	my ( $self, $newstatus ) = @_;
	if ( @_ == 2 )    # set new value even if input is undef
	{
		$self->_dirty(1,"historic") if ($self->{_historic} != $newstatus);
		$self->{_historic} = $newstatus ? 1 : 0;
	}
	return $self->{_historic};
}

# RO, returns nmisng object that this inventory object is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# RO, returns node_uuid of the owning node
sub node_uuid
{
	my ($self) = @_;
	return $self->{_node_uuid};
}

# returns the storage structure, optionally replaces it (all of it)
# to modify: call first to get, modify the copy, then call with the updated copy to set
# args: optional new storage (hashref)
# returns: clone of storage info, logs on error
sub storage
{
	my ( $self, $newstorage ) = @_;
	if ( @_ == 2 )    # ie. even if undef
	{
		if ( defined($newstorage) && ref($newstorage) ne "HASH" )
		{
			$self->nmisng->log->error( "storage accessor called with invalid argument, type " . ref($newstorage) );
		}
		else
		{
			$self->_dirty(1,"storage") if (!eq_deeply($newstorage,$self->{_storage}));
			$self->{_storage} = Clone::clone($newstorage);

			# and update the subconcepts list
			my @newsubconcepts = List::MoreUtils::uniq(keys %{$self->{_storage}});
			# order is not relevant
			$self->_dirty(1,"subconcepts") if (!eq_deeply($self->{_subconcepts}, bag(@newsubconcepts)));
			$self->{_subconcepts} = \@newsubconcepts;
		}
	}
	return Clone::clone( $self->{_storage} );
}

# small r/o accessor to the list of unique subconcepts, as declared by the storage structure
# args: none
# returns: array ref (cloned, might be empty)
sub subconcepts
{
	my ($self) = @_;
	return defined( $self->{_subconcepts} ) ? Clone::clone( $self->{_subconcepts} ) : [];
}

# small accessor that looks up a storage subconcept
# and returns the requested storage type info for it
#
# args: subconcept (required), type (optional, default rrd)
# returns: undef or rhs of the type record (for rrd that's normally a path)
sub find_subconcept_type_storage
{
	my ( $self, %args ) = @_;
	my $type = $args{type} || 'rrd';
	my $subconcept = $args{subconcept};

	$self->nmisng->log->debug3("DEBUG find_subconcept_type_storage type=$type subconcept=$subconcept _storage: ". Dumper $self->{_storage});

	return undef
		if (
		   !$subconcept
		or ref( $self->{_storage} ) ne "HASH"
		or ref( $self->{_storage}->{$subconcept} ) ne "HASH"    # better than pure existence check
		or !exists( $self->{_storage}->{$subconcept}->{$type} )
		);

	return $self->{_storage}->{$subconcept}->{$type};           # no cloning needed until this becomes a deep structure
}

# small helper to update a storage subconcept
# note: this does update the inventory's storage object!
#
# args: subconcept (=name), type (optional, default rrd), data (= new value, undef to delete, anything else to update)
# returns: nothing
sub set_subconcept_type_storage
{
	my ( $self, %args ) = @_;
	my ( $subconcept, $type, $data ) = @args{"subconcept", "type", "data"};
	$type //= "rrd";

	# already empty, no-op.
	return if ( !defined( $self->{_storage} ) && !defined($data) );
	$self->{_storage} //= {};

	if ( defined $data )
	{
		$self->_dirty(1,"storage") if (!eq_deeply($data,$self->{_storage}->{$subconcept}->{$type}));
		$self->{_storage}->{$subconcept}->{$type} = $data;
	}
	else
	{
		delete $self->{_storage}->{$subconcept}->{$type};
		delete $self->{_storage}->{$subconcept}
		if ( !keys %{$self->{_storage}->{$subconcept}} );    # if nothing else left
		$self->_dirty(1,"storage");
	}

	# and update the subconcepts list
	my @newsubconcepts = List::MoreUtils::uniq(keys %{$self->{_storage}});
	# order is not relevant
	$self->_dirty(1,"subconcepts") if (!eq_deeply($self->{_subconcepts}, bag(@newsubconcepts)));
	$self->{_subconcepts} = \@newsubconcepts;

	return;
}

# returns the path keys list, optionally replaces it
# args: new path_keys (arrayref)
# returns: clone of path_keys
# note: not possible to delete path_keys.
sub path_keys
{
	my ( $self, $newvalue ) = @_;
	if ( defined($newvalue) && ref($newvalue) eq 'ARRAY' )
	{
		$self->_dirty(1,"path_keys") if (!eq_deeply($newvalue,$self->{_path_keys}));
		$self->{_path_keys} = Clone::clone($newvalue);
	}
	return Clone::clone( $self->{_path_keys} );
}

# returns a copy of the data component of this inventory object, optionally replaces data (all of it)
# (i.e. the parts possibly specific to this instance class)
#
# to change data: call first to get, modify the copy, then call with the updated copy to set
# args: optional data (hashref),
# returns: clone of data (normal) or ref of live data (in data_live mode); logs on error
sub data
{
	my ( $self, $newvalue ) = @_;

	if ( defined($newvalue) )
	{
		if (ref($newvalue) ne "HASH")
		{
			$self->nmisng->log->error( "data accessor called with invalid argument " . ref($newvalue) );
			return $self->{_live}? $self->data_live : Clone::clone($self->{_data});
		}

		if ( $self->{_live} )
		{
			my $live = $self->data_live;
			if ($newvalue != $live)		# same address means same object
			{
				# if newvalue is a different hash than live, then massage that:
				# must retain the original ref because others hold it...
				map { delete $live->{$_}; } (keys %$live);
				# ...but replace the values
				map { $live->{$_} = $newvalue->{$_}; } (keys %$newvalue);
			}
		}
		else
		{
			# park a copy of the original data for precise dirtyness detection, if not there yet
			$self->{_data_orig} //= Clone::clone($self->{_data});
			$self->_dirty(1,"data") if (!eq_deeply($self->{_data_orig}, $newvalue));
			$self->{_data} = Clone::clone($newvalue);
		}
	}

	# fixme9: in some instances this shortcut makes sense,
	# otherwise all places will need to learn to check liveness
	if ( $self->{_live} )
	{
		return $self->data_live();
	}
	else
	{
		return Clone::clone( $self->{_data} );
	}
}

# returns a ref to the data,
# ATTENTION: after doing this the object cannot be accessed via normal data function!
# this function should be used (much more) sparingly
#
# returns: direct ref for the data, logs on error
sub data_live
{
	my ($self) = @_;

	# mark...
	$self->{_live} = 1;
	# ..and park a copy of the original data for precise dirtyness detection, if not there yet
	$self->{_data_orig} //= Clone::clone($self->{_data});
	$self->_dirty(1,"data");			# assume the caller modifies the data; save() will find out what changed exactly

	return $self->{_data};
}

# set columns available for data by subconcept, enable/disable the visiblity of the subconcept
sub data_info
{
	my ( $self, %args ) = @_;
	my ( $subconcept, $enabled, $display_keys ) = @args{'subconcept', 'enabled', 'display_keys'};
	return "cannot get or set data_info, invalid subconcept argument:$subconcept!"
		if ( !$subconcept );    # must be something

	if (defined($enabled) || defined($display_keys))
	{
		my $newinfo = { enabled => $enabled, display_keys => Clone::clone($display_keys) // [] };
		$self->_dirty(1,"data_info") if (!eq_deeply($self->{_data_info}->{$subconcept}, $newinfo));
		$self->{_data_info}->{$subconcept} = $newinfo;
	}
	return Clone::clone($self->{_data_info}->{$subconcept});
}

# returns hashref of datasets defined for the specified subconcept or empty hash
# arguments: subconcept - string, [newvalue] - new dataset hashref for given subconcept
# right now dataset subconcepts are not hooked up to subconcept list
sub dataset_info
{
	my ( $self, %args ) = @_;
	my ( $subconcept, $datasets ) = @args{'subconcept', 'datasets'};

	return "cannot get or set dataset_info, invalid subconcept argument:$subconcept!"
		if ( !$subconcept );    # must be something

	if ( defined($datasets) )
	{
		return "cannot set datasets, invalid newvalue argument!"
				if ( ref($datasets) ne "HASH" );    # empty hash is acceptable

		$self->_dirty(1,"dataset_info") if (!eq_deeply($self->{_datasets}->{$subconcept},
																									 $datasets));
		$self->{_datasets}->{$subconcept} = $datasets;
	}
	return $self->{_datasets}->{$subconcept} // {};
}

# remove this inventory entry from the db, including all timed_data instances,
# as well as all rrd files
# args: keep_rrd (optional, default false)
#
# returns (success, message) or (0,error)
sub delete
{
	my ($self, %args) = @_;

	my $keeprrd = NMISNG::Util::getbool($args{keep_rrd});

	# not errors but message doesn't hurt
	return (1, "Inventory already deleted") if ($self->{_deleted});
	return (1, "Inventory has never been saved, nothing to delete") if ($self->is_new);

	# delete all timed instances of this one,
	# and anything from latest data
	for my $coll ($self->nmisng->timed_concept_collection( concept => $self->concept() ),
								$self->nmisng->latest_data_collection)
	{
		my $result = NMISNG::DB::remove(
			collection => $coll,
			query => NMISNG::DB::get_query( and_part => {inventory_id => $self->id}, no_regex => 1 ) );
		return (0, "Inventory instance removal from ".$coll->name." failed: ".$result->{error})
				if (!$result->{success});
		$self->nmisng->log->debug("deleted $result->{removed_records} from collection "
															.$coll->name." for inventory ".$self->id);
	}
	# ...the ditch any rrd files
	# note: supports storage type rrd only, for now
	if (!$keeprrd && ref($self->{_storage}) eq "HASH")
	{
		for my $subconcept (keys %{$self->{_storage}})
		{
			next if (ref($self->{_storage}->{$subconcept}) ne "HASH"
							 or !defined $self->{_storage}->{$subconcept}->{"rrd"});
			my $goner = $self->nmisng->config->{database_root} . $self->{_storage}->{$subconcept}->{"rrd"};
			if (-e $goner && !-d $goner) # exists but isn't a dir
			{
				$self->nmisng->log->debug("deleting file $goner for $subconcept of inventory ".$self->id);
				my $res = unlink($goner);
				return (0, "Failed to remove storage file $goner: $!") if (!$res);
			}
		}
	}

	# and finally the inventory itself
	my $result = NMISNG::DB::remove(
		collection => $self->nmisng->inventory_collection,
		query      => NMISNG::DB::get_query( and_part => {_id => $self->id()}, no_regex => 1 ),
		just_one   => 1 );
	return (0, "Inventory removal failed: $result->{error}") if (!$result->{success});

	$self->{_deleted} = 1; # mark in mem-copy as gone
	return (1, undef);
}

# handle node renaming wrt. rrd file names, and saves self
#
# inventories don't care about node names but nmis assumes a variety of
# things about where rrds go.
#
# note that this might be made more robust wrt. weird common-database structures,
# as the inventory instance doesn't have enough context to be perfect.
#
# args: current node name, new node name
# returns (success, message, list of old names) or (0, error message))
sub relocate_storage
{
	my ($self, %args) = @_;
	my ($curname,$newname) = @args{"current","new"};
	my $inventory = $args{inventory};

	return (0, "storage relocating requires current name argument") if (!$curname);
	return (0, "storage relocation requires new name argument")	if (!$newname);

	return (1, "no storage relocation required") if ($newname eq $curname
																									 or ref($self->{_storage}) ne "HASH"
																									 or !keys %{$self->{_storage}});

	my $dbroot = $self->nmisng->config->{'database_root'};
	
	# Needed to makeRRDname from database, if current path is corrupt
	my $S = NMISNG::Sys->new(nmisng => $self->nmisng);
	$S->init(node => $self->nmisng->node(name => $curname));

	# full sanity check FIRST - can the path fixup happen? does the current name match?
	my $safetomangle = Clone::clone($self->{_storage});
	# keep track of the errors
	my %error_keys;
	my (@oktorm, %done);
	for my $subconcept (keys %{$self->{_storage}})
	{
		next if (ref($self->{_storage}->{$subconcept}) ne "HASH"
						 or !defined $self->{_storage}->{$subconcept}->{"rrd"});

		my $existing = $self->{_storage}->{$subconcept}->{"rrd"}; # a relative path
		
		# If the file does not exist, we continue
		if (! -f "$dbroot/$existing")
		{
			$self->nmisng->log->info("file \"$existing\" does not exist");
			$error_keys{$subconcept} = 1;
			next;
		}

		# makeRRD name using the inventory and the index
		my $index = $self->data()->{index};
		my $newfile = $S->makeRRDname( type => $subconcept, relative => 1, index => $index, inventory => $inventory);
		if (!defined($newfile)) {
			$self->nmisng->log->error("Skipping $subconcept. Not able to make RRD name.");
			$error_keys{$subconcept} = 1;
			next;
		}
		
		$newfile =~ s/(^|\W|_)$curname($|\W|_)/$1$newname$2/i;
			
		# Make sure the file name is the same. Could change if is a duplicate, pe
		my $lastpath = $newfile;
		my $path2 = $existing;
		$lastpath =~ s{^.*/}{};
		$path2 =~ s{^.*/}{};
		$newfile =~ s/(^|\W|_)$lastpath/$1$path2/i;
		# Replace new file
		$safetomangle->{$subconcept}->{"rrd"} = $newfile;
		
		# There is a duplicate		
		if (-f "$dbroot/$newfile" && $existing ne $newfile) {
			$self->nmisng->log->info("Duplicate file $newfile");
			my $oldfile = "$dbroot/$newfile";
			my $duplicated = "$dbroot/$newfile.duplicate";
			if (!move $oldfile, $duplicated) {
				$self->nmisng->log->error("** File $dbroot/$newfile cannot be moved. Incorrect permissions.\n
										  Please relocate this file manually");
				$error_keys{$subconcept} = 1;
				next;
			}
		}
		elsif ($existing eq $newfile) # If the newfile is the same location, no relocation is required
		{
			$self->nmisng->log->info("file \"$existing\" equals, no relocation required");
			$error_keys{$subconcept} = 1;
			next;
		} 
		
		$self->nmisng->log->debug("planning to relocate \"$existing\" to \"$safetomangle->{$subconcept}->{rrd}\"");
	}

	# all checks survived, hardlink the files, update storage and save self
	for my $subconcept (keys %{$self->{_storage}})
	{
		next if (ref($self->{_storage}->{$subconcept}) ne "HASH"
						 or !defined $self->{_storage}->{$subconcept}->{"rrd"}
						 or exists($error_keys{$subconcept})
						 or !defined $safetomangle->{$subconcept}->{"rrd"});
		my $existing = $self->{_storage}->{$subconcept}->{"rrd"}; # a relative path

		my $new = $safetomangle->{$subconcept}->{"rrd"};

		next if ($done{$new});			# some rrds show up more than once...
		$done{$new} = 1;

		my $fullexisting = $self->nmisng->config->{'database_root'}.$existing;
		my $fullnew = $self->nmisng->config->{'database_root'}.$new;

		if (! -d (my $targetdir = dirname($fullnew)))
		{
			NMISNG::Util::createDir($targetdir);
		}
		if (!link($fullexisting, $fullnew))
		{
			return (0, "cannot link \"$fullexisting\" to \"$fullnew\": $!");
		}
		push @oktorm, $existing;
	}

	# update storage and save
	$self->{_storage} = $safetomangle;
	$self->_dirty(1,"storage");

	my ($op, $error) = $self->save;
	return (0, "failed to save updated inventory: $error")
			if ($op <= 0);

	return (1, '', @oktorm);
}

# get the id (_id), readonly
# save adjusts this so is_new returns properly
# may be undef if is_new
sub id
{
	my ($self) = @_;
	return $self->{_id};
}

# has this inventory object been deleted from the db
sub is_deleted
{
	my ($self) = @_;
	return ( $self->{_deleted} == 1 );
}

# returns 0/1 if the object is new or not.
# new means it is not yet in the database
sub is_new
{
	my ($self) = @_;

	my $has_id = $self->id();
	return ($has_id) ? 0 : 1;
}

sub lastupdate
{
	my ($self) = @_;
	return $self->{_lastupdate} if ( !$self->is_new );
	return;
}

# reload this object from db, handy for testing to make sure update has been successful
# args: none, just needs self's id
# returns: undef or error message
sub reload
{
	my ($self) = @_;

	if (!$self->is_new)
	{
		my $modeldata = $self->nmisng->get_inventory_model( _id => $self->id );
		if (my $error = $modeldata->error)
		{
			return "get inventory model failed: $error";
		}
		return "no inventory object with id " . $self->id . " in database!" if ( !$modeldata->count );
		my $newme = $modeldata->data()->[0];

		# some things are ro/no settergetter, path MUST be set directly, its accessor gets confused by id/is_new!
		for my $copyable (qw(cluster_id node_uuid concept path lastupdate))
		{
			$self->{"_$copyable"} = $newme->{$copyable};
		}

		# others are supposed to be settable via accessor
		for my $settable (qw(data storage historic enabled path_keys description))
		{
			$self->$settable( $newme->{$settable} );
		}
		$self->_dirty(0);						# all clean at this point

		# and any dirtyness decisions need to be based on what we (re)loaded from db
		# but that's only necessary if we were in data_live mode which persists across reload
		if ($self->{_live})
		{
			$self->{_data_orig} = Clone::clone($self->{_data});
			$self->_dirty(1,"data");
		}
		else
		{
			delete $self->{_data_orig};
		}
	}
	else
	{
		return "cannot reload unsaved inventory object!";
	}
	return undef;
}

# (re)make or get the path and return it
# args: recalculate - [0/1], optional (default 0)
# returns: arrayref, or error message
#
# new objects will recalculate their path on each call, specifiying recalculate makes no difference
# objects which are not new should already have a path and that value will be returned
# unless recalculate is specified.
# path is made by Class method corresponding to the this objects concept
# NOTE: the use of path keys below breaks convention,
sub path
{
	my ( $self, %args ) = @_;

	if ( !$self->is_new() && !$self->{_path} && !$args{recalculate} )
	{
		return "Saved inventory must already have a path!";
	}
	elsif ( !$self->is_new() && $self->{_path} && !$args{recalculate} )
	{
		return $self->{_path};
	}
	else
	{
		# make_path itself will ignore the first arg here, but finding the right subclass's
		# make_path does require it.
		my $newpath = $self->make_path(
			cluster_id => $self->cluster_id,
			node_uuid  => $self->node_uuid,
			concept    => $self->concept,
			path_keys  => $self->path_keys,    # possibly nonex, up to subclass to worry about
			data       => $self->data
				);
		# this produces error message or path array ref
		return "make_path failed: $newpath" if (ref($newpath) ne "ARRAY");

		# always store the path, it may be re-calculated next time but that's fine
		# if we don't store here recalculate/save won't work
		$self->_dirty(1,"path") if (!eq_deeply($self->{_path},$newpath));
		return $self->{_path} = $newpath;
	}
}

# save the inventory obj in the database, if this thing thinks it's new do an upsert
#  using the path to make sure we don't create duplicates, this will clobber whatever
#  is in the db if it does update instead of insert (but will grab that thigns id as well)
#
# args: lastupdate, (optional, defaults to now),
# note: lastupdate and expire_at currently not added to object but stored in db only
#
# the object's _id and _path are refreshed
# returns ($op,$error), op is 1 for insert, 2 for update/save,
# 3 for no updates required, 0 or negative on error;
#
# error is string if there was an error
sub save
{
	my ( $self, %args ) = @_;
	my $lastupdate = $args{lastupdate} // Time::HiRes::time;

	# first, check if what we have is saveable at all
	my ( $valid, $validation_error ) = $self->validate();
	return ( $valid, $validation_error ) if ( $valid <= 0 );

	#node_name and group name are cached on the record for faster inventory sorting in the other products,
	#maybe we should append with cached? as this data could be stale?
	my $node = $self->nmisng->node( filter => { uuid => $self->node_uuid } );
	my ($name, $group);
	if (ref($node) eq "NMISNG::Node")
	{
		$name = $node->name;
		$group = $node->configuration()->{'group'};
	}

	my ( $result, $op );

	my $record = {
		cluster_id => $self->cluster_id,
		server_name => $self->server_name,
		node_uuid  => $self->node_uuid,
		node_name  => $name,
		configuration => { group => $group },
		concept    => $self->concept(),
		path       => $self->path(),         # path is calculated but must be stored so it can be queried
		path_keys  => $self->path_keys(),    # could be empty, kept in db for selfcontainment and convenience

		description => $self->description(),
		data        => $self->data(),
		storage     => $self->storage(),
		subconcepts => $self->subconcepts(),

		enabled  => $self->enabled(),
		historic => $self->historic(),

		lastupdate => $lastupdate,
	};

	# if not historic: extend expire_at ttl off the current lastupdate
	if (!$self->historic)
	{
		# to make the db ttl expiration work this must be
		# an acceptable date type for the driver version
		my $pleasegoaway = $lastupdate + ($self->nmisng->config->{purge_inventory_after} || 14*86400);
		$pleasegoaway = Time::Moment->from_epoch($pleasegoaway);
		$record->{expire_at} = $pleasegoaway;
	}

	# numify anything in path
	my $path = $record->{path};

	for ( my $i = 0; $i < @$path; $i++ )
	{
		$path->[$i] = NMISNG::Util::numify( $path->[$i] );
	}

	# right now dataset subconcepts are not hooked up to subconcept list
	$record->{dataset_info} = [];
	foreach my $subconcept ( keys %{$self->{_datasets}} )
	{
		my @datasets = keys %{$self->dataset_info( subconcept => $subconcept )};
		push @{$record->{dataset_info}}, {subconcept => $subconcept, datasets => \@datasets};
	}

	# data_info gets changed like dataset_info for easier mongo work, store as array with
	# predictable keys
	$record->{data_info} = [];
	foreach my $subconcept ( keys %{$self->{_data_info}} )
	{
		my $subconcept_info = $self->data_info( subconcept => $subconcept );
		push( @{$record->{data_info}}, { %$subconcept_info, subconcept => $subconcept });
	}

	# if it's new upsert to try and make sure we're not making a duplicate
	if ( $self->is_new() || $args{force})
	{
		my ($q,$path) = (undef,$self->path());
		map { $q->{"path.$_"} = NMISNG::Util::numify( $path->[$_] ) } ( 0 .. $#$path );
		$result = NMISNG::DB::update(
			collection => $self->nmisng->inventory_collection,
			query      => $q,
			record     => $record,
			upsert     => 1,
			multiple   => 0
		);
		if( $result->{success} && $result->{upserted_id} )
		{
			# _id is set on insert, grab it so we know we're not new
			$self->{_id} = $result->{upserted_id};
			$op = 1;
		}
		elsif ($result->{success})
		{
			# we updated when trying to insert which means we thought we were new but were not,
			# we need to grab our id as the update will have changed the record to what we think it is
			# but not returned us an id
			$op = 2;
			my $find_result = NMISNG::DB::find(
				collection => $self->nmisng->inventory_collection,
				query      => $q,
				fields_hash => { _id => 1 }
			);
			if( $find_result )
			{
				my $entry = $find_result->next;
				$self->{_id} = $entry->{_id};
			}
			else
			{
				$self->nmisng->log->error("Inventory save of new inventory resulted in update. Find for _id failed after update with".NMISNG::DB::get_error_string() );
				$result->{success} = 0;
				$result->{error} = "Inventory save of new inventory resulted in update. Find for _id failed after update with".NMISNG::DB::get_error_string();
			}
		}
	}
	# not new, so we update it but try change as little as possible
	else
	{
		$record->{_id} = $self->id();

		my %updateargs  = (
			collection => $self->nmisng->inventory_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $record->{_id}},
																					 no_regex => 1 ),
			freeform => 1,
				);

		# what do we need to update?
		# most properties are easy, except for data where we  want to update individual properties,
		# which means the record must use 'data.X', which means the db module must not apply constraints
		$updateargs{constraints} = 0 if (grep($_ eq "data", $self->_whatisdirty));

		my (%setthese, %unsetthese);
		$setthese{"expire_at"} = $record->{expire_at} if (exists $record->{expire_at});

		$op = 3; # nothing to update
		for my $saveme ($self->_whatisdirty)
		{
			$op = 2;	# something 'real' to update
			$setthese{lastupdate} //= $lastupdate;

			if ($saveme eq "data")
			{
				# add new props, update changed props
				for my $propname (keys %{$record->{data}})
				{
					$setthese{"data.$propname"}
					= NMISNG::DB::constrain_record(record => $record->{data}->{$propname})
							if (!exists($self->{_data_orig}->{$propname}) # new
									or !eq_deeply($self->{_data_orig}->{$propname}, # changed; data.X should be shallow but BSTS
																$record->{data}->{$propname}));
				}
				# and remove props that have gone
				for my $maybegoner (keys %{$self->{_data_orig}})
				{
					$unsetthese{"data.$maybegoner"} = 1 if (!exists($record->{data}->{$maybegoner}));
				}
			}
			else
			{
				die "inventory dirty status inconsistent ".Dumper($self->{_dirty}, $record) . Carp::longmess()
						if (!exists $record->{$saveme});

				# we may have to constrain the bits ourselves
				$setthese{$saveme} = exists($updateargs{constraints})?
						NMISNG::DB::constrain_record(record => $record->{$saveme}) : $record->{$saveme};
			}
		}

		$updateargs{record} = {'$set' => \%setthese} if (keys %setthese);
		$updateargs{record}->{'$unset'} = \%unsetthese if (keys %unsetthese);

		$result = ($updateargs{record}? NMISNG::DB::update(%updateargs) : { success => 1});
	}

	# reset path to what was saved, probably the same but safe
	$self->{_path} = $record->{path} if ( $result->{success} );

	# save any queued time/pit data, not expecting many here so not very optimised
	if ( $result->{success} && defined($self->{_queued_pit}) )
	{
		my $pit_record = $self->{_queued_pit};
		# using ourself means id will be added (so new inventories will work, no save first required)
		# telling it to flush should bypass any special handling, allowing the data straight through
		my $error = $self->add_timed_data(flush => 1, %$pit_record);
		if ($error)
		{
			$result->{success} = 0;
			$result->{error} .= "Error saving time data: $error";
		}
		else
		{
			# clean up successful saves
			delete $self->{_queued_pit};
		}
	}

	if ( $result->{success} )
	{
		$self->{_lastupdate} = $lastupdate;
		$self->_dirty(0);						# all clean at this time...
		delete $self->{_data_orig};	# and up-to-date

		# ...but live mode persists across save, and ref holders will continue to change the data!
		# therefore data_orig must track what the db now holds
		if ($self->{_live})
		{
			$self->_dirty(1,"data");
			$self->{_data_orig} = Clone::clone($self->{_data});
		}
	}
	return ( $result->{success} ) ? ( $op, undef ) : ( undef, $result->{error} );
}


# returns (positive, nothing) if the inventory is valid,
# (negative or zero, error message) if it's no good
sub validate
{
	my ($self)  = @_;
	my $path    = $self->path();
	my $storage = $self->storage;

	# must have, alphabetical for now, make cheapest first later?
	return ( -1, "invalid cluster_id" )        if ( !$self->cluster_id );
	return ( -2, "invalid concept" )           if ( !$self->concept );
	return ( -3, "invalid data" )              if ( ref($self->data()) ne 'HASH' );
	return ( -4, "invalid path" )              if ( !$path || ref($path) ne 'ARRAY' || @$path < 1 );
	return ( -5, "invalid node_uuid" )         if ( !$self->node_uuid );
	return ( -6, "invalid storage structure" ) if ( defined($storage) && ref($storage) ne "HASH" );

	foreach my $entry (@$path)
	{
		return ( 6, "invalid, empty path entries not allowed" ) if ( !$entry );
	}

	return 1;
}

1;
