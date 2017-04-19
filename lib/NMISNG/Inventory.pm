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

use Clone;											# for copying data and other r/o sections
use Scalar::Util;								# for weaken
use Data::Dumper;
use Time::HiRes;
use Carp;

use NMISNG::DB;

# based on the concept, decide which class to create - or return the fallback/default class
# args: concept
# returns: class name
sub get_inventory_class
{
	my ($concept) = @_;
	my %knownclasses = (
		'default'       => 'DefaultInventory',    # the fallback, must be present
		'service'       => "ServiceInventory",
		# ...
	);

	my $class = "NMISNG::Inventory::" . ( $knownclasses{$concept} // $knownclasses{default} );
	return $class;
}

# create a new inventory manager object
# note: the object is always strictly associated with a node_uuid and a cluster_id
# this method is expected to be subclassed!
#
# params: concept (=class name, type of inventory),
#  nmisng (parent object), node_uuid, cluster_id,
#  data - all required
# optional: id  (alias _id, the db _id of this thing if it's not new),
#  path (used if provided, not required, normally can be calculated on save),
#  enabled (1/0, "nmis does something with this inventory item"),
#  historic (not present or 0, or anything else),
#  storage (hash of subconcept name -> path to the rrd file for this thing, relative to database_root),
#  path_key (must be arrayref if present - used for simplest path computation, ie. with listed keys from data),
#  description (optional, if not given a descriptive text is synthesized)
sub new
{
	my ( $class, %args ) = @_;

	my $nmisng = $args{nmisng};
	return undef if ( !$nmisng );   # check this early so we can use it to log

	for my $musthave (qw(concept cluster_id node_uuid))
	{
		if (!defined $args{$musthave})
		{
			$nmisng->log->fatal("Inventory object cannot be created without $musthave!");
			return undef;
		}
	}

	my $data = $args{data};
	if (ref($data) ne "HASH")
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid data argument!");
		return undef;
	}
	if (defined($args{storage}) && ref($args{storage}) ne "HASH")
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid storage argument!");
		return undef;
	}
	if (defined($args{path_keys}) && ref($args{path_keys} ne "ARRAY"))
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid path_keys argument!");
		return undef;
	}

	# compat issue, we *may* get _id
	$args{id} //= $args{_id};
	# description? we don't want any logic to abuse that, but having some human-friendly bits are desirable
	if (!defined $args{description})
	{
		my $nodenames = $nmisng->get_node_names(uuid => $args{node_uuid});
		my $thisnodename = $nodenames->[0] // "UNKNOWN"; # can that happen?
		$args{description} = "concept $args{concept} on node $thisnodename and server $args{cluster_id}";
	}

	# set default properties, then update with args
	my $self = bless( { 
		_enabled => 1,
		_historic => 0, 
		( map { ("_$_" => $args{$_}) } (qw(concept node_uuid cluster_id data id nmisng
path path_keys storage description)))
 										}, $class);
	# enabled and historic: override defaults only if explicitely given
	for my $onlyifgiven (qw(enabled historic))
	{
		$self->{"_$onlyifgiven"} = ($args{$onlyifgiven}?1:0) if (exists $args{$onlyifgiven});
	}
	
	# in addition to these, there's also on-demand _deleted
	Scalar::Util::weaken $self->{_nmisng} if ( !Scalar::Util::isweak( $self->{_nmisng} ) );
	return $self;
}

###########
# Private:
###########

###########
# Protected:
###########

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
	return "make_path_from_keys cannot work without path_keys!"
			if (ref($keys) ne "ARRAY");
	return "make_path_from_keys has invalid data argument: ".ref($args{data})
			if (exists($args{data}) && ref($args{data}) ne "HASH");

	my @path;
	# to make the path globally unique
	for my $prefixelem ("cluster_id","node_uuid","concept")
	{
		if (!$args{partial} && !defined($args{$prefixelem}))
		{
			return "make_path_from_keys is missing $prefixelem argument!";
		}
		push @path, $args{$prefixelem};
	}
	# now go through the given path_keys
	foreach my $pathelem (@$keys)
	{
		if (!$args{partial} && !defined($args{data}->{$pathelem}))
		{
			return("make_path_from_keys is missing $pathelem data!");
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

	die(__PACKAGE__."::make_path must be implemented by subclass!");
}

###########
# Public:
###########

# add one point-in-time data record for this concept instance
# args: self (must have been saved, ie. have _id), data (hashref), time (optional, defaults to now)
# returns: undef or error message
sub add_timed_data
{
	my ($self,%args) = @_;

	return "cannot add timed data to unsaved inventory instance!"
			if ($self->is_new);
	return "cannod add timed data, invalid data argument!"
			if (ref($args{data}) ne "HASH"); # empty hash is acceptable

	my $timedrecord = { inventory_id => $self->id,
											time => $args{time} // Time::HiRes::time,
											data => $args{data} };
	my $dbres = NMISNG::DB::insert(
		collection => $self->nmisng->timed_concept_collection(concept => $self->concept()),
		record => $timedrecord );
	return "failed to insert record: $dbres->{error}" if (!$dbres->{success});
	return undef;
}

# retrieve the one most recent timed data for this instance
#(note: raw _id and inventory_id are not returned: not useful)
# args: none
# returns: hashref of success, error, time, data.
sub get_newest_timed_data
{
	my ($self) = @_;

	# inventory not saved certainly means no pit data, but  that's no error
	return { success => 1 } if ($self->is_new);
		
	my $cursor = NMISNG::DB::find(
		collection => $self->nmisng->timed_concept_collection(concept => $self->concept()),
		query => NMISNG::DB::get_query(and_part => { inventory_id => $self->id }),
		limit => 1,
		sort => { time => -1 },
		fields_hash => { time => 1, data => 1 });
	return { success => 0, error => NMISNG::DB::get_error_string } if (!$cursor);
	return { success => 1 } if (!$cursor->count);

	my $reading = $cursor->next;
	return { success => 1, data => $reading->{data}, time  => $reading->{time} };
}

# RO, returns nmisng object that this inventory object is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# RO, returns cluster_id of this Inventory
sub cluster_id
{
	my ($self) = @_;
	return $self->{_cluster_id};
}

# RO, returns concept of this Inventory
sub concept
{
	my ($self) = @_;
	return $self->{_concept};
}

# RO, returns node_uuid of the owning node
sub node_uuid
{
	my ($self) = @_;
	return $self->{_node_uuid};
}

# enabled/disabled are set when an inventory is found on a device 
# but the system or user has decided not to use/collect/manage it
# returns the enabled status, optionally sets a new status
# args: newstatus (will be forced to 0/1)
sub enabled
{
	my ($self,$newstatus) = @_;
	if (@_ == 2)	# set new value even if input is undef
	{
		$self->{_enabled} = $newstatus?1:0;
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
	my ($self,$newstatus) = @_;
	if (@_ == 2)	# set new value even if input is undef
	{
		$self->{_historic} = $newstatus?1:0;
	}
	return $self->{_historic};
}

# returns the current description, optionally sets a new one
# args: newdescription
# returns: description
sub description
{
	my ($self,$newdescription) = @_;
	if (@_ == 2)									# new value undef is ok, description is deletable
	{
		$self->{_description} = $newdescription;
	}
	return $self->{_description};
}

# returns the storage structure, optionally replaces it (all of it)
# to modify: call first to get, modify the copy, then call with the updated copy to set
# args: optional new storage info (hashref)
# returns: clone of storage info, logs on error
sub storage
{
	my ($self, $newstorage) = @_;
	if (@_ == 2)									# ie. even if undef
	{
		if (defined($newstorage) && ref($newstorage) ne "HASH")
		{
			$self->nmisng->log->error("storage accessor called with invalid argument, type ".ref($newstorage));
		}
		else
		{
			$self->{_storage} = Clone::clone( $newstorage );
		}
	}
	return Clone::clone($self->{_storage});
}

# small accessor that looks up a storage subconcept
# and returns the requested storage type info for it
#
# args: subconcept (required), type (optional, default rrd)
# returns: undef or rhs of the type record (for rrd that's normally a path)
sub find_subconcept_type_storage
{
	my ($self, %args) = @_;
	my $type = $args{type} || 'rrd';
	my $subconcept = $args{subconcept};
	return undef if (!$subconcept
									 or ref($self->{_storage}) ne "HASH"
									 or ref($self->{_storage}->{$subconcept}) ne "HASH" # better than pure existence check
									 or !exists($self->{_storage}->{$subconcept}->{$type}));

	return $self->{_storage}->{$subconcept}->{$type}; # no cloning needed until this becomes a deep structure
}

# small helper to update a storage subconcept
# note: this does update the inventory's storage object!
#
# args: subconcept (=name), type (optional, default rrd), data (= new value, undef to delete, anything else to update)
# returns: nothing
sub set_subconcept_type_storage
{
	my ($self, %args) = @_;
	my ($subconcept,$type,$data)= @args{"subconcept","type","data"};
	$type //= "rrd";

	# already empty, no-op.
	return if (!defined($self->{_storage}) && !defined($data));
	$self->{_storage} //= {};

	if (defined $data)
	{
		$self->{_storage}->{$subconcept}->{$type} = $data;
	}
	else
	{
		delete $self->{_storage}->{$subconcept}->{$type};
		delete $self->{_storage}->{$subconcept}
		if (!keys %{$self->{_storage}->{$subconcept}}); # if nothing else left
	}
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
		$self->{_path_keys} = Clone::clone( $newvalue );
	}
	return Clone::clone($self->{_path_keys});
}

# returns a copy of the data component of this inventory object, optionally replaces data (all of it)
# (i.e. the parts possibly specific to this instance class)
#
# to change data: call first to get, modify the copy, then call with the updated copy to set
# args: optional data (hashref),
# returns: clone of data, logs on error
sub data
{
	my ( $self, $newvalue ) = @_;

	if( $self->{_live} )
	{
		# in some instances this makes sense or all places will need to learn to check live, that might make sense
		# not sure right now so this has been added
		return $self->data_live();
	}

	if ( defined($newvalue) )
	{

		if( $self->{_live} )
		{
			$self->nmisng->log->fatal("Accessing/saving data to this inventory, concept:".$self->concept." is not allowed because it's live\n".Carp::longmess());
		}
		else
		{
			if (ref($newvalue) ne "HASH")
			{
				$self->nmisng->log->error("data accessor called with invalid argument ".ref($newvalue));
			}
			else
			{
				$self->{_data} = Clone::clone( $newvalue );
			}
		}
	}
	return Clone::clone( $self->{_data} );
}

# returns a ref to the data, after doing this the object cannot be accessed via normal data function
# returns: clone of data, logs on error
sub data_live
{
	my ( $self ) = @_;

	$self->{_live} = 1;

	return $self->{_data};
}

# remove this inventory entry from the db
# can't delete if its new, or if it's already been deleted or if it doesn't have an id
#  (which is_new checks but not a bad idea to double check)
sub delete
{
	my ($self) = @_;

	if ( !$self->is_new && !$self->{_deleted} && $self->id() )
	{
		my $result = NMISNG::DB::remove(
			collection => $self->nmisng->inventory_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $self->id()} ),
			just_one   => 1
		);
		$self->{_deleted} = 1 if ( $result->{success} );
		return ( $result->{success}, $result->{error} );
	}
	else
	{
		return ( undef, "Inventory did not meet criteria for deleting" );
	}
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
# new means it is not yet in the aabase
sub is_new
{
	my ($self) = @_;

	my $has_id = $self->id();
	return ($has_id) ? 0 : 1;
}

# reload this object from db, handy for testing to make sure update has been successful
# args: none, just needs self's id
# returns: undef or error message
sub reload
{
	my ($self) = @_;

	if ( !$self->is_new )
	{
		my $modeldata = $self->nmisng->get_inventory_model( _id => $self->id );
		return "no inventory object with id ".$self->id." in database!" if (!$modeldata->count);
		my $newme = $modeldata->data()->[0];

		# some things are ro/no settergetter, path MUST be set directly, its accessor gets confused by id/is_new!
		for my $copyable (qw(cluster_id node_uuid concept path lastupdate))
		{
			$self->{"_$copyable"} = $newme->{$copyable};
		}
		# others are supposed to be settable via accessor
		for my $settable (qw(data storage historic enabled path_keys description))
		{
			$self->$settable($newme->{$settable});
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
# returns: arrayref
#
# new objects will recalculate their path on each call, specifiying recalculate makes no difference
# objects which are not new should already have a path and that value will be returned
# unless recalculate is specified.
# path is made by Class method corresponding to the this objects concept
# NOTE: the use of path keys below breaks convention,
sub path
{
	my ( $self, %args ) = @_;

	my $path;
	if ( !$self->is_new() && !$self->{_path} && !$args{recalculate} )
	{
		$self->nmisng->log->error("Saved inventory should already have a path!");
	}
	elsif ( !$self->is_new() && $self->{_path} && !$args{recalculate} )
	{
		$path = $self->{_path};
	}
	else
	{
		# make_path itself will ignore the first arg here, but finding the right subclass's
		# make_path does require it.
		$path = $self->make_path(cluster_id => $self->cluster_id,
														 node_uuid => $self->node_uuid,
														 concept => $self->concept,
														 path_keys => $self->path_keys, # possibly nonex, up to subclass to worry about
														 data => $self->data);

		# always store the path, it may be re-calculated next time but that's fine
		# if we don't store here recalculate/save won't work
		$self->{_path} = $path;
	}
	$self->nmisng->log->error("Path must be an array!") if ( ref($path) ne "ARRAY" );

	return $path;
}

# save the inventory obj in the database
# args: lastupdate, optional, defaults to now
#
# note: lastupdate is currently not added to object but is stored in db only
# the object's _id and _path are refreshed
# returns ($op,$error), op is 1 for insert, 2 for save, error is string if there was an error
sub save
{
	my ( $self, %args ) = @_;
	my $lastupdate = $args{lastupdate} // time;

	my ( $valid, $validation_error ) = $self->validate();
	return ( $valid, $validation_error ) if ( !$valid );

	my ($result, $op);


	my $record = {
		cluster_id => $self->cluster_id,
		node_uuid => $self->node_uuid,
		concept    => $self->concept(),
		path       => $self->path(), 	# path is calculated but must be stored so it can be queried
		path_keys => $self->path_keys(), # could be empty, kept in db for selfcontainment and convenience

		description =>  $self->description(),
		data       => $self->data(),
		storage => $self->storage(),

		enabled => $self->enabled(),
		historic => $self->historic(),

		lastupdate => $lastupdate,
	};

	# numify anything in path
	my $path = $record->{path};

	for(my $i = 0; $i < @$path; $i++)
	{
		$path->[$i] = NMISNG::Util::numify($path->[$i])
	}

	if ( $self->is_new() )
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->nmisng->inventory_collection,
			record     => $record,
		);
		$op = 1;

		# _id is set on insert, grab it so we know we're not new
		$self->{_id} = $result->{id} if ( $result->{success} );
	}
	else
	{
		$record->{_id} = $self->id();
		$result = NMISNG::DB::update(
			collection => $self->nmisng->inventory_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $record->{_id}} ),
			record     => $record
		);
		$op = 2;
	}

	# reset path to what was saved, probably the same but safe
	$self->{_path} = $record->{path} if ( $result->{success} );

	# TODO: set lastupdate into object?
	return ( $result->{success} ) ? ( $op, undef ) : ( undef, $result->{error} );
}

# returns 0/1 if the node is valid
sub validate
{
	my ($self) = @_;
	my $path = $self->path();
	my $storage = $self->storage;

	# must have, alphabetical for now, make cheapest first later?
	return ( -1, "invalid cluster_id" ) if ( !$self->cluster_id );
	return ( -2, "invalid concept" )    if ( !$self->concept );
	return ( -3, "invalid data" )       if ( ref( $self->data() ) ne 'HASH' );
	return ( -4, "invalid path" )       if ( !$path || @$path < 1 );
	return ( -5, "invalid node_uuid" )  if ( !$self->node_uuid );
	return (-6, "invalid storage structure") if  (defined($storage) && ref($storage) ne "HASH");

	foreach my $entry (@$path)
	{
		return ( 6, "invalid, empty path entries not allowed" ) if ( !$entry );
	}

	return 1;
}

1;
