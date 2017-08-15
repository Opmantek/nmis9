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

# Package giving access to nodes, etc.
# Two basic ways to grab info, via get*Model functions which return ModelData objects
# or directly via the object
package NMISNG;
our $VERSION = "9.0.0a";

use strict;

use Data::Dumper;
use Tie::IxHash;

use NMISNG::Util;
use NMISNG::Log;
use NMISNG::DB;
use NMISNG::ModelData;
use NMISNG::Node;

# params:
#  config - hash containing object
#  log - NMISNG::Log object to log to, required.
#  db - mongodb database object, optional.
#  drop_unwanted_indices - optional, default is 0.
sub new
{
	my ( $class, %args ) = @_;

	die "Config required" if ( ref( $args{config} ) ne "HASH" );
	die "Log required" if ( !$args{log} );

	my $self = bless(
		{   _config => $args{config},
			_db     => $args{db},
			_log    => $args{log},
		},
		$class
	);

	my $db = $args{db};
	if ( !$db )
	{
		# get the db setup ready, indices and all
		# nodes uses the SHARED COMMON database, NOT a module-specific one!
		my $conn = NMISNG::DB::get_db_connection( conf => $self->config );
		if ( !$conn )
		{
			my $errmsg = NMISNG::DB::get_error_string;
			$self->log->fatal("cannot connect to MongoDB: $errmsg" );
			die "cannot connect to MongoDB: $errmsg\n";
		}
		$db = $conn->get_database( $self->config->{db_name} );
	}
	# park the db handle for future use, note: this is NOT the connection handle!
	$self->{_db} = $db;

	# load and prime the statically defined collections
	for my $collname (qw(nodes inventory ip latest_data))
	{
		my $collhandle = NMISNG::DB::get_collection( db => $db, name => $collname );
		if (ref($collhandle) ne "MongoDB::Collection")
		{
			my $msg =  "Could not get collection $collname: " . NMISNG::DB::get_error_string ;
			$self->log->fatal($msg);
			die "Failed to get Collection $collname, msg: $msg\n";							# database errors on that level are not really recoverable
		}
		# tell mongodb to prefer numeric
		$collhandle = $collhandle->with_codec( prefer_numeric => 1 );

		# now prime the indices and park the collection handles in self - the coll accessors do that
		my $setfunction = "${collname}_collection";
		$self->$setfunction($collhandle, $args{drop_unwanted_indices});
	}

	return $self;
}

###########
# Private:
###########

# fixme: ip database structure doesn't match the rest of nmisng, doesn't really fit here! this should be in node.pm.

# this is a small (internal) helper that fetches and merges a node's
# secondary address records into a give node record
#
# args: noderecord (ref)
# returns: amended noderecord (still the same ref)
sub _mergeaddresses
{
	my ( $self, $noderecord ) = @_;

	if ($noderecord)
	{
		$noderecord->{"addresses"} ||= [];

		# find this node's ip addresses (if any)
		my $ipcursor = NMISNG::DB::find(
			collection  => $self->ip_collection,
			query       => {"node" => $noderecord->{_id}},
			fields_hash => {"_id" => 1}
		);
		while ( my $ipentry = $ipcursor->next )
		{
			my $address = $ipentry->{"_id"};

		   # at this point we're only interested in ip address entries, not temporary dns intermediaries or fqdn entries
			push @{$noderecord->{addresses}}, $address if ( $address =~ /^[a-fA-F0-9:.]+$/ );
		}
	}
	return $noderecord;
}

###########
# Public:
###########

# returns config hash
sub config
{
	my ($self) = @_;
	return $self->{_config};
}

# returns db
sub get_db
{
	my ($self) = @_;
	return $self->{_db};
}

# find all unique concep/subconcept pairs for the given path/filter
# filtering for active things possible (eg, enabled => 1, historic => 0)
# NOTE: INCOMPLETE, can't be done in aggregation right now, map/reduce or
#  perl are an option
sub get_inventory_available_concepts
{
	my ( $self, %args ) = @_;
	my $path;

	# start with a plain query; with _id that'll be enough already
	my %queryinputs = ();
	if ($args{filter})
	{
		map { $queryinputs{$_} = $args{filter}->{$_}; } (keys %{$args{filter}});
	}
	my $q = NMISNG::DB::get_query( and_part => \%queryinputs );

	# translate the path components into the lookup path
	if ( $args{path} || $args{node_uuid} || $args{cluster_id} || $args{concept} )
	{
		$path = $args{path} // [];

		# fill in starting args if given
		my $index = 0;
		foreach my $arg_name (qw(cluster_id node_uuid))
		{
			if ( $args{$arg_name} )
			{
				$path->[$index] = $args{$arg_name};
				delete $args{$arg_name};
			}
			$index++;
		}
		map { $q->{"path.$_"} = NMISNG::Util::numify( $path->[$_] ) if ( defined( $path->[$_] ) ) } ( 0 .. $#$path );
	}
	my @pipeline = ();
	# 	{ '$match' => $q },
	# 	{ '$unwind' => 'subconcepts' },
	# 	{ '$group' => {
	# 		'_id' : { 'concept': '$concept', 'subconcept': '$subconcepts' }
	# 	},
	# 	{ '$group' => {
	# 		'_id' : '$_id.$concept',
	# 		'concept' => '$_id.$concept',
	# 		'subconcepts' => { '$addToSet': '$_id.subconcept' }
	# 	}
	# );

	my ($entries,$count,$error) = NMISNG::DB::aggregate(
		collection => $self->inventory_collection,
		post_count_pipeline => \@pipeline,
	);

}

# note: should _id use args{id}? or _id?
# all arguments that are used in the beginning of the path will be put
# into the path for you, so specificying path[1,2] and cluster_id=>3 will chagne
# the path to path[3,2]
# arguments:
#.   path - array
#.   cluster_id,node_uuid,concept - will all be put into the path, overriding what is there
#. or _id, overriding all of the above
#
#. filter - hashref, will be added to the query
#.   [fields_hash] - which fields should be returned, if not provided the whole record is returned
# returns: model_data object
sub get_inventory_model
{
	my ( $self, %args ) = @_;

	NMISNG::Util::TODO("Figure out search options for get_inventory_model");

	my $q = $self->get_inventory_model_query( %args );

	my $model_data = [];
	if ( $args{paginate} )
	{
		# fudge up a dummy result to make it reflect the total number
		my $count = NMISNG::DB::count( collection => $self->_inventory_collection, query => $q );
		$model_data->[$count - 1] = {} if ($count);
	}
	# print "get_inventory_model: q:".Dumper($q);
	my $entries = NMISNG::DB::find(
		collection => $self->inventory_collection,
		query      => $q,
		sort       => $args{sort},
		limit      => $args{limit},
		skip       => $args{skip},
		fields_hash => $args{fields_hash},
	);

	my $index = 0;
	while ( my $entry = $entries->next )
	{
		$model_data->[$index++] = $entry;
	}

	my $model_data_object = NMISNG::ModelData->new( model_name => "inventory", data => $model_data );
	return $model_data_object;
}

# this does not need to be a member function, could be 'static'
sub get_inventory_model_query
{
	my ($self,%args) = @_;

	# start with a plain query; with _id that'll be enough already
	my %queryinputs = (	'_id' => $args{_id} );    # this is a bit inconsistent
	my $q = NMISNG::DB::get_query( and_part => \%queryinputs );
	my $path;

	# there is no point in adding any other filters if _id is specified
	if( !$args{_id} )
	{
		if ($args{filter} )
		{
			map { $queryinputs{$_} = $args{filter}->{$_}; } (keys %{$args{filter}});
		}
		$q = NMISNG::DB::get_query( and_part => \%queryinputs );

		# translate the path components into the lookup path
		if ( $args{path} || $args{node_uuid} || $args{cluster_id} || $args{concept} )
		{
			$path = $args{path} // [];

			# fill in starting args if given
			my $index = 0;
			foreach my $arg_name (qw(cluster_id node_uuid concept))
			{
				if ( $args{$arg_name} )
				{
					$path->[$index] = $args{$arg_name};
					delete $args{$arg_name};
				}
				$index++;
			}
			map { $q->{"path.$_"} = NMISNG::Util::numify( $path->[$_] ) if ( defined( $path->[$_] ) ) } ( 0 .. $#$path );
		}
	}
	return $q;
}

# returns selection of nodes, as array of hashes
# args: id, name, host, group for selection;
#
# returns: ModelData object, with the stuff under key "addresses" synthesized from the ip cache collection
#
# arg sort: mongo sort criteria
# arg limit: return only N records at the most
# arg skip: skip N records at the beginning. index N in the result set is at 0 in the response
# arg paginate: sets the pagination mode, in which case the result array is fudged up sparsely to
# arg filter: any other filters on the list of nodes required, hashref
# return 'complete' result elements without limit! - a dummy element is inserted at the 'complete' end,
# but only 0..limit are populated
sub get_nodes_model
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter};
	$filter->{'uuid'}  = $args{uuid};
	$filter->{'name'}  = $args{name};
	$filter->{'host'}  = $args{host};
	$filter->{'group'} = $args{group};

	my $q = NMISNG::DB::get_query( and_part => $filter );

	my $model_data = [];
	if ( $args{paginate} )
	{
		# fudge up a dummy result to make it reflect the total number
		my $count = NMISNG::DB::count( collection => $self->nodes_collection, query => $q );
		$model_data->[$count - 1] = {} if ($count);
	}

	my $entries = NMISNG::DB::find(
		collection => $self->nodes_collection,
		query      => $q,
		sort       => $args{sort},
		limit      => $args{limit},
		skip       => $args{skip}
	);

	my $index = 0;
	while ( my $entry = $entries->next )
	{
		$self->_mergeaddresses($entry);
		$model_data->[$index++] = $entry;
	}

	my $model_data_object = NMISNG::ModelData->new( model_name => "nodes", data => $model_data );
	return $model_data_object;
}

sub get_node_names
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model(%args);
	my $data       = $model_data->data();
	my @node_names = map { $_->{name} } @$data;
	return \@node_names;
}

sub get_node_uuids
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model(%args);
	my $data       = $model_data->data();
	my @uuids      = map { $_->{uuid} } @$data;
	return \@uuids;
}

# accessor for finding timed data for one (or more) inventory instances
# args: cluster_id, node_uuid, concept, path (to select one or more inventories)
#  optional historic and enabled (for filtering),
#  OR inventory_id (which overrules all of the above)
#  time, (for timed-data selection)
#  sort/skip/limit/paginate - FIXME sorts/skip/limit not supported if the selection spans more than one concept!
# returns: modeldata object or undef if error
sub get_timed_data_model
{
	my ($self, %args) = @_;

	# determine the inventory instances to look for
	my %concept2cand;
	# a particular single inventory? look it up, get its concept
	if ($args{inventory_id})
	{
		my $cursor = NMISNG::DB::find(collection => $self->inventory_collection,
																	query => NMISNG::DB::get_query(and_part => { _id => $args{inventory_id} }),
																	fields_hash =>  { concept => 1 });
		return undef if (!$cursor or $cursor->count != 1); # fixme: nosuch inventory should count as an error or not?
		my $inv = $cursor->next;
		$concept2cand{$inv->{concept}} = $args{inventory_id};
	}
	# any other selectors given? then find instances and create list of wanted ones per concept
	elsif (grep(defined($args{$_}), (qw(cluster_id node_uuid concept path historic enabled))))
	{
		# safe to copy undefs
		my %selectionargs = (map { ($_ => $args{$_}) } (qw(cluster_id node_uuid concept path)));
		# extra filters need to go under filter
		for my $maybe (qw(historic enabled))
		{
			$selectionargs{filter}->{$maybe} = $args{$maybe} if (exists $args{$maybe});
		}
		$selectionargs{fields_hash} = { _id => 1, concept => 1 }; # don't need anything else
		my $lotsamaybes = $self->get_inventory_model(%selectionargs);

		return undef if (!$lotsamaybes or !$lotsamaybes->count); # fixme: nosuch inventory should count as an error or not?
		for my $oneinv (@{$lotsamaybes->data})
		{
			$concept2cand{$oneinv->{concept}} ||= [];
			push @{$concept2cand{$oneinv->{concept}}}, $oneinv->{_id};
		}
	}
	# nope, global; so just go over each known concept
	else
	{
		my $allconcepts = NMISNG::DB::distinct(db => $self->get_db(),
																					 collection => ( $NMISNG::DB::new_driver?
																													 $self->inventory_collection
																													 : $self->inventory_collection->name ),
																					 key => "concept");
		return undef if (ref($allconcepts) ne "ARRAY" or !@$allconcepts); # fixme: no inventory at all is an error or not?
		for my $thisone (@$allconcepts)
		{
			$concept2cand{$thisone} = undef; # undef is not array ref and not string
		}
	}

	# more than one concept and thus collection? cannot sort/skip/limit/paginate
	# fixme: must report this as error, or at least ditch those args,
	# or possibly do sort+limit per concept and ditch skip and paginate?

	my @rawtimedata;
	# now figure out the appropriate collection for each of the concepts,
	# then query each of those for time data matching the candidate inventory instances
	for my $concept (keys %concept2cand)
	{
		my $timedcoll = $self->timed_concept_collection(concept => $concept);
		#fixme handle  error

		my $cursor = NMISNG::DB::find( collection => $timedcoll,
																	 # undef will mean unrestricted, one value will do equality lookup,
																	 # array will cause an $in check
																	 query => NMISNG::DB::get_query(and_part => { inventory_id => $concept2cand{$concept} }),
																	 sort => $args{sort},
																	 skip => $args{skip},
																	 limit => $args{limit} );
		while (my $tdata = $cursor->next)
		{
			push @rawtimedata, $tdata;
		}
	}
	return NMISNG::ModelData->new(model_name => "timed_data", data => \@rawtimedata);
}

# find all unique values for key from collection and filter provided
sub get_distinct_values
{
	my ($self, %args) = @_;
	my $collection = $args{collection};
	my $key = $args{key};
	my $filter = $args{filter};

	my $query = NMISNG::DB::get_query( and_part => $filter );
	my $values = NMISNG::DB::distinct(
		collection => $collection,
		key => $key,
		query => $query
	);
	return $values;
}

# helper to get/set inventory collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub inventory_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_inventory} = $newvalue;

		NMISNG::Util::TODO("NMISNG::new INDEXES - figure out what we need");

		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_inventory},
			drop_unwanted => $drop_unwanted,
			indices       => [
				[{"concept"     => 1, enabled => 1, historic => 1}, {unique => 0}],
				[{"lastupdate"  => 1}, {unique => 0}],
				[{"path"        => 1}, {unique => 0}],		# can't make this unique, index must be unique per array element for that
				[{"subconcepts" => 1}, {unique => 0}],
				[{"data_info"   => 1}, {unique => 0}],
				[ { expire_at => 1 }, { expireAfterSeconds => 0 } ],			# ttl index for auto-expiration
			] );
		$self->log->error("index setup failed for inventory: $err") if ($err);
	}
	return $self->{_db_inventory};
}

# helper to get/set ip collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub ip_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_ip} = $newvalue;

		NMISNG::Util::TODO("NMISNG::new INDEXES - figure out what we need");

		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_ip},
			drop_unwanted => $drop_unwanted,
				indices => [ [ { "node"=>1} ] ] ); # fixme will need something different
		$self->log->error("index setup failed for inventory: $err") if ($err);
	}
	return $self->{_db_inventory};
}

# helper to get/set latest_derived_data collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub latest_data_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_latest_data} = $newvalue;

		NMISNG::Util::TODO("NMISNG::new INDEXES - figure out what we need");

		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_latest_data},
			drop_unwanted => $drop_unwanted,
			indices       => [
				[{"inventory_id" => 1}, {unique => 1}],
				[ { expire_at => 1 }, { expireAfterSeconds => 0 } ],			# ttl index for auto-expiration
			] );
		$self->log->error("index setup failed for inventory: $err") if ($err);
	}
	return $self->{_db_latest_data};
}

# get an NMISNG::Node object given arguments that will make it unique
# the first node found matching all arguments is provided (if >1 is found)
# arg: create => 0/1, if 1 and node is not found a new one will be returned, it is
#   not persisted into the db until the object has it's save method called
sub node
{
	my ( $self, %args ) = @_;
	my $create = $args{create};
	delete $args{create};

	my $node;
	my $modeldata = $self->get_nodes_model(%args);
	if( $modeldata->count() > 1 )
	{
		$self->log->warn("Node request returned more than one node, returning nothing");
		return;
	}
	elsif ( $modeldata->count() == 1 )
	{
		my $model = $modeldata->data()->[0];
		$node = NMISNG::Node->new(
			_id    => $model->{_id},
			uuid   => $model->{uuid},
			nmisng => $self
		);
	}
	elsif ($create)
	{
		$node = NMISNG::Node->new(
			uuid   => $args{uuid},
			nmisng => $self
		);
	}

	return $node;
}

# helper to get/set nodes collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub nodes_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_nodes} = $newvalue;

		NMISNG::Util::TODO("NMISNG::new INDEXES - figure out what we need");

		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_nodes},
			drop_unwanted => $drop_unwanted,
			indices       => [[{"uuid" => 1}, {unique => 1}]]
				);
		$self->log->error("index setup failed for nodes: $err") if ($err);
	}
	return $self->{_db_nodes};
}

# returns this objects log object
sub log
{
	my ($self) = @_;
	return $self->{_log};
}

# helper to instantiate/get/update one of the dynamic collections
# for timed data, one per concept
# indices are set up on set or instantiate
#
# if no matching collection is cached, one is created and set up.
#
# args: concept (required), collection (optional new value), drop_unwanted (optional, ignored unless new value)
# returns: current collection for this concept, or undef on error (which is logged)
sub timed_concept_collection
{
	my ($self, %args) = @_;
	my ($conceptname, $newhandle, $drop_unwanted) = @args{"concept","collection","drop_unwanted"};

	if (!$conceptname)
	{
		$self->log->error("cannot get concept collection without concept argument!");
		return undef;
	}
	my $collname = lc($conceptname);
	$collname =~ s/[^a-z0-9]+//g;
	$collname = "timed_".substr($collname,0,64); # bsts; 120 byte max database.collname
	my $stashname = "_db_$collname";

	my $mustcheckindex;
	# use and cache the given handle?
	if (ref($newhandle) eq "MongoDB::Collection")
	{
		$self->{$stashname} = $newhandle;
		$mustcheckindex = 1;
	}
	# or create a new one on the go?
	elsif (!$self->{$stashname})
	{
		$self->{$stashname} = NMISNG::DB::get_collection( db => $self->get_db(),
																											name => $collname );
		if (ref($self->{$stashname}) ne "MongoDB::Collection")
		{
			$self->log->fatal("Could not get collection $collname: ".NMISNG::DB::get_error_string);
			return undef;
		}

		$mustcheckindex = 1;
	}

	if ($mustcheckindex)
	{
		# sole index is by time and inventory_id, compound
		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{$stashname},
			drop_unwanted => $drop_unwanted,
			indices       => [
				[ Tie::IxHash->new( "time" => 1, "inventory_id" => 1 ) ], # for global 'find last X readings for all instances'
				[ Tie::IxHash->new( "inventory_id" => 1, "time" => 1 ) ],	# for 'find last X readings for THIS instance'
				[ { expire_at => 1 }, { expireAfterSeconds => 0 } ],			# ttl index for auto-expiration
			] );
		$self->log->error("index setup failed for $collname: $err") if ($err);
	}

	return $self->{$stashname};
}

1;
