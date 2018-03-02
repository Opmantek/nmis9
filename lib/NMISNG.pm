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
use File::Find;
use File::Spec;
use boolean;
use Fcntl qw(:DEFAULT :flock :mode); # this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Errno qw(EAGAIN ESRCH EPERM);
use Mojo::File;									# slurp and spurt
use JSON::XS;

use NMISNG::DB;
use NMISNG::Events;
use NMISNG::Log;
use NMISNG::ModelData;
use NMISNG::Node;
use NMISNG::Util;

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
	for my $collname (qw(nodes events inventory latest_data queue opstatus))
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

		# figure out if index dropping is allowed for a given collection (by name)
		# needs to be disabled for collections that are shared across products
		$args{drop_unwanted_indices} = 0
				if ($args{drop_unwanted_indices}
						and ref($self->{_config}->{db_never_remove_indices}) eq "ARRAY"
						and grep($_ eq $collname, @{$self->{_config}->{db_never_remove_indices}}));

		# now prime the indices and park the collection handles in self - the coll accessors do that
		my $setfunction = "${collname}_collection";
		$self->$setfunction($collhandle, $args{drop_unwanted_indices});
	}

	return $self;
}

###########
# Private:
###########


###########
# Public:
###########

# returns config hash
sub config
{
	my ($self) = @_;
	return $self->{_config};
}

# returns mongodb db handle - note this is NOT the connection handle!
# (nmisng::db::connection_of_db() can provide the conn handle)
sub get_db
{
	my ($self) = @_;
	return $self->{_db};
}

# return the events object
sub events
{
	my ($self) = @_;
	return NMISNG::Events->new( nmisng => $self );
}

# helper to get/set event collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub events_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_events} = $newvalue;

		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_events},
			drop_unwanted => $drop_unwanted,
			indices       => [
				# needed for joins
				[ [node_uuid => 1]],
				[ {lastupdate  => 1}, {unique => 0}],
				[ [node_uuid=>1,event=>1,element=>1,historic=>1,startdate=>1], {unique => 1}],
				# [ [node_uuid=>1,event=>1,element=>1,active=>1], {unique => 1}],
				[ { expire_at => 1 }, { expireAfterSeconds => 0 } ],			# ttl index for auto-expiration
			] );
		$self->log->error("index setup failed for inventory: $err") if ($err);
	}
	return $self->{_db_events};
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
#.   [fields_hash] - which fields should be returned, if not provided the
#    whole record is returned
#.   sort/skip/limit - adjusts the query
#
# returns: hash ref with success, error, model_data object
sub get_inventory_model
{
	my ( $self, %args ) = @_;

	NMISNG::Util::TODO("Figure out search options for get_inventory_model");

	my $q = $self->get_inventory_model_query( %args );
	# print "query:".Dumper($q);
	my $entries = NMISNG::DB::find(
		collection => $self->inventory_collection,
		query      => $q,
		sort       => $args{sort},
		limit      => $args{limit},
		skip       => $args{skip},
		fields_hash => $args{fields_hash},
			);

	return { error => "find failed: ".NMISNG::DB::get_error_string } if (!defined $entries);

	my @all;
	while ( my $entry = $entries->next )
	{
		push @all, $entry;
	}

	# create modeldata object with instantiation info from caller
	my $model_data_object = NMISNG::ModelData->new( nmisng => $self,
																									class_name => $args{class_name},
																									data => \@all );
	return { success => 1, error => undef, model_data => $model_data_object };
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

# returns latest data
# arg: filter - kvp's of filters to be applied
sub get_latest_data_model
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter};
	my $fields_hash = $args{fields_hash};

	my $q = NMISNG::DB::get_query( and_part => $filter );

	my $entries = [];
	my $query_count;
	if ( $args{count} )
	{
		$query_count = NMISNG::DB::count( collection => $self->latest_data_collection, query => $q );
	}
	my $cursor = NMISNG::DB::find(
		collection => $self->latest_data_collection,
		query      => $q,
		fields_hash => $fields_hash,
		sort       => $args{sort},
		limit      => $args{limit},
		skip       => $args{skip}
	);

	while ( my $entry = $cursor->next )
	{
		push @$entries, $entry;
	}
	my $model_data_object = NMISNG::ModelData->new( nmisng => $self,
																									data => $entries,
																									query_count => $query_count,
																									sort       => $args{sort},
																									limit      => $args{limit},
																									skip       => $args{skip} );
	return $model_data_object;
}

# returns selection of nodes
# args: id, name, host, group, and filter (=hash) for selection
#
# note: if id/name/host/group and filter are given, then
#the filter properties override id/name/host/group!
#
# arg sort: mongo sort criteria
# arg limit: return only N records at the most
# arg skip: skip N records at the beginning. index N in the result set is at 0 in the response
# arg paginate: not supported, should be implemented at different level, sort/skip/limit does happen here
# arg count:
# arg filter: any other filters on the list of nodes required, hashref
# arg fields_hash: hash of fields that should be grabbed for each node record, whole thing for each if not provided
# return 'complete' result elements without limit! - a dummy element is inserted at the 'complete' end,
# but only 0..limit are populated
#
# returns: ModelData object
sub get_nodes_model
{
	my ( $self, %args ) = @_;
	my $filter = $args{filter};

	# copy convenience/shortcut arguments iff the filter
	# hasn't already set them - the filter wins
	for my $shortie (qw(uuid name host group))
	{
		$filter->{$shortie} = $args{$shortie}
		if (exists($args{$shortie}) and !exists($filter->{$shortie}));
	}
	my $fields_hash = $args{fields_hash};

	my $q = NMISNG::DB::get_query( and_part => $filter );

	my $model_data = [];
	my $query_count;

	if ( $args{count} )
	{
		my $res = NMISNG::DB::count( collection => $self->nodes_collection,
																 query => $q,
																 verbose => 1);
		return NMISNG::ModelData->new(nmisng => $self, error => "Count failed: $res->{error}")
				if (!$res->{success});
		$query_count = $res->count;
	}

	# if you want only a count but no data, set both count to 1 and limit to 0
	if (!($args{count} && defined $args{limit} && $args{limit} == 0))
	{
		my $cursor = NMISNG::DB::find(
			collection => $self->nodes_collection,
			query      => $q,
			fields_hash => $fields_hash,
			sort       => $args{sort},
			limit      => $args{limit},
			skip       => $args{skip}
				);

		return NMISNG::ModelData->new(nmisng => $self, error => "Find failed: ".NMISNG::DB::get_error_string)
				if (!defined $cursor);

		@$model_data = $cursor->all;
	}

	my $model_data_object = NMISNG::ModelData->new( class_name => "NMISNG::Node",
																									nmisng => $self,
																									data => $model_data,
																									query_count => $query_count,
																									sort       => $args{sort},
																									limit      => $args{limit},
																									skip       => $args{skip} );
	return $model_data_object;
}

sub get_node_names
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model(%args, fields_hash => { name => 1 } );
	my $data       = $model_data->data();
	my @node_names = map { $_->{name} } @$data;
	return \@node_names;
}

sub get_node_uuids
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model(%args, fields_hash => { uuid => 1 });
	my $data       = $model_data->data();
	my @uuids      = map { $_->{uuid} } @$data;
	return \@uuids;
}

# accessor for finding timed data for one (or more) inventory instances
# args: cluster_id, node_uuid, concept, path (to select one or more inventories)
#  optional historic and enabled (for filtering),
#  OR inventory_id (which overrules all of the above)
#  time, (for timed-data selection)
#  sort/skip/limit - FIXME sorts/skip/limit not supported if the selection spans more than one concept!
# returns: modeldata object or undef if error (and error is logged)
# fixme: better error reporting would be good
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
		if (!$cursor)
		{
			$self->log->error("Failed to retrieve inventory $args{inventory_id}: "
												.NMISNG::DB::get_error_string);
			return undef;
		}
		my $inv = $cursor->next;
		if (!defined $inv)
		{
			$self->log->error("inventory $args{inventory_id} does not exist!");
			return undef;;
		}

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
		my $result = $self->get_inventory_model(%selectionargs);
		if (!$result->{success})
		{
			$self->log->error("get inventory model failed: $result->{error}");
			return undef;
		}
		my $lotsamaybes = $result->{model_data};
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

	# more than one concept and thus collection? cannot sort/skip/limit
	# fixme: must report this as error, or at least ditch those args,
	# or possibly do sort+limit per concept and ditch skip?

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

	# no object instantiation expected or possible for timed data
	return NMISNG::ModelData->new(data => \@rawtimedata);
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

# group nodes by specified group, then summarise their reachability and health as well as get total count
# per group as well as nodedown and nodedegraded status
# args: group_by - the field, include_nodes - 1/0, if set return value changes to array with hash, one hash
#  entry for the grouped data and another for the nodes included in the groups, this is added for backwards
#  compat with how nmis group data worked in 8
# If no group_by is given all nodes will be used and put into a single group, this is required to get overall
# status
sub grouped_node_summary
{
	my ($self,%args) = @_;

	my $group_by = $args{group_by} // []; #'data.group'
	my $include_nodes = $args{include_nodes} // 0;
	my $filters = $args{filters};

	# can't have dots in the output group _id values, replace with _
	# also make a hash to project the group by values into the group stage
	my (%groupby_hash,%groupproject_hash);
	if( @$group_by > 0 )
	{
		foreach my $entry (@$group_by)
		{
			my $value = $entry;
			my $key = $entry;
			$key =~ s/\./_/g;
			$groupby_hash{$key} = '$'.$value;
			$groupproject_hash{$value} = 1;
		}
	}
	else
	{
		$groupby_hash{empty_group} = '$empty_group';
	}

	my $q = NMISNG::DB::get_query( and_part => $filters );
	my @pipe = (
		{ '$match'  => { 'concept' => 'catchall' } },
		{ '$lookup' => { 'from' => 'nodes', 'localField' => 'node_uuid', 'foreignField' => 'uuid', 'as' => 'node_config'}},
		{ '$unwind' => { 'path' => '$node_config', 'preserveNullAndEmptyArrays' => boolean::false }},
		{ '$match'  => { 'node_config.active' => 1 } },
		{ '$lookup' => { 'from' => 'latest_data', 'localField' => '_id', 'foreignField' => 'inventory_id', 'as' => 'latest_data'}},
		{ '$unwind' => { 'path' => '$latest_data', 'preserveNullAndEmptyArrays' => true }},
		{ '$unwind' => { 'path' => '$latest_data.subconcepts', 'preserveNullAndEmptyArrays' => boolean::true } },
		{ '$match'  => { 'latest_data.subconcepts.subconcept' => 'health', %$q }}
	);
	my $node_project =
			{ '$project' => {
				'_id' => 1,
				'name' => '$data.name',
				'uuid' => '$data.uuid',
				'down' => { '$cond' => { 'if' => { '$eq' => ['$data.nodedown','true'] }, 'then' => 1, 'else' => 0 } },
				'degraded' => { '$cond' => { 'if' => { '$eq' => ['$data.nodestatus','degraded'] }, 'then' => 1, 'else' => 0 } },
				'reachable' => '$latest_data.subconcepts.data.reachability',
				'08_reachable' => '$latest_data.subconcepts.derived_data.08_reachable',
				'16_reachable' => '$latest_data.subconcepts.derived_data.16_reachable',
				'health' => '$latest_data.subconcepts.data.health',
				'08_health' => '$latest_data.subconcepts.derived_data.08_health',
				'16_health' => '$latest_data.subconcepts.derived_data.16_health',
				'available' => '$latest_data.subconcepts.data.available',
				'08_available' => '$latest_data.subconcepts.derived_data.08_available',
				'16_available' => '$latest_data.subconcepts.derived_data.16_available',
				'08_response' => '$latest_data.subconcepts.derived_data.08_response',
				'16_response' => '$latest_data.subconcepts.derived_data.16_response',
				# add in all the things network.pl is expecting:
				'nodedown' => '$data.nodedown',
				'nodestatus' => '$data.nodestatus',
				'netType' => '$data.netType',
				'nodeType' => '$data.nodeType',
				'response' => '$latest_data.subconcepts.data.responsetime',
				'roleType' => '$data.roleType',
				'ping' => '$data.ping',
				'sysLocation' => '$data.sysLocation',
				%groupproject_hash
		}};
	my $final_group =
		{ '$group' => {
				'_id' => \%groupby_hash,
				'count' => {'$sum' => 1 },
				'countdown' => { '$sum' => '$down'},
				'countdegraded' => { '$sum' => '$degraded'},
				'reachable_avg' => { '$avg' => '$reachability'},
				'08_reachable_avg' => { '$avg' => '$08_reachable'},
				'16_reachable_avg' => { '$avg' => '$16_reachable'},
				'health_avg' => { '$avg' => '$health'},
				'08_health_avg' => { '$avg' => '$08_health'},
				'16_health_avg' => { '$avg' => '$16_health'},
				'available_avg' => { '$avg' => '$available'},
				'08_available_avg' => { '$avg' => '$08_available'},
				'16_available_avg' => { '$avg' => '$16_available'},
				'08_response_avg' => { '$avg' => '$08_response'},
				'16_response_avg' => { '$avg' => '$16_response'}
		}};
	if( $include_nodes )
	{
		push @pipe, { '$facet' => {
			node_data => [$node_project],
			grouped_data => [ $node_project,$final_group ]
		}};
	}
	else
	{
		push @pipe, $node_project;
		push @pipe, $final_group;
	}
	# print "pipe:".Dumper(\@pipe);
	my ($entries,$count,$error) = NMISNG::DB::aggregate(
		collection => $self->inventory_collection(),
		pre_count_pipeline => \@pipe,
		count => 0,
	);
	return ($entries,$count,$error);
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
				# replaces path, makes path.0,path.1... lookups work on index
				[ ["path.0" => 1,"path.1" => 1,"path.2" => 1,"path.3" => 1], {unique => 0}],
				# needed for joins
				[ [node_uuid => 1]],
				[ [concept => 1, enabled => 1, historic => 1], {unique => 0}],
				[{"lastupdate"  => 1}, {unique => 0}],
				[{"subconcepts" => 1}, {unique => 0}],
				[{"data_info.subconcept"   => 1}, {unique => 0}],
				# unfortunately we need a custom extra index for concept == interface, to find nodes by ip address
				[ ["data.ip.ipAdEntAddr" => 1 ], { unique => 0 } ],
				[ { expire_at => 1 }, { expireAfterSeconds => 0 } ],			# ttl index for auto-expiration
			] );
		$self->log->error("index setup failed for inventory: $err") if ($err);
	}
	return $self->{_db_inventory};
}

# helper to get/set queue collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub queue_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_queue} = $newvalue;

		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_queue},
			drop_unwanted => $drop_unwanted,
			indices       => [
				# need to search/sort by time, priority and in_progress
				[ [ "time" => 1, "priority" => 1, "in_progress" => 1 ]]
			] );
		$self->log->error("index setup failed for queue: $err") if ($err);
	}
	return $self->{_db_queue};
}

# helper to get/set opstatus collection, primes the indices on set
# args: new collection handle, optional drop - unwanted indices are dropped if this is 1
# returns: current collection handle
sub opstatus_collection
{
	my ( $self, $newvalue, $drop_unwanted ) = @_;
	if ( ref($newvalue) eq "MongoDB::Collection" )
	{
		$self->{_db_opstatus} = $newvalue;

		my $err = NMISNG::DB::ensure_index(
			collection    => $self->{_db_opstatus},
			drop_unwanted => $drop_unwanted,
			indices       => [
				# opstatus: searchable by when, by status (good/bad), by activity, context and type
				# not included: details and stats
				[ { "time" => -1 } ],
				[ { "status" => 1 } ],
				[ { "activity" => 1 } ],
				[ { "context" => 1 } ],
				[ { "type" => 1 } ],
			] );
		$self->log->error("index setup failed for opstatus: $err") if ($err);
	}
	return $self->{_db_opstatus};
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

# get or create an NMISNG::Node object from the given arguments (that should make it unique)
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
		my @names = map { $_->{name} } @{$modeldata->data()};
		$self->log->debug("Node request returned more than one node, args".Dumper(\%args));
		$self->log->warn("Node request returned more than one node, returning nothing, names:".join(",", @names));
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
			indices       => [
				[{"uuid" => 1}, {unique => 1}],
				[{"name" => 1}, {unique => 0}]
			]);
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

# job queue handling functions follow
# queued jobs have time (=actual ts for when the work should be done),
# a type marker ("collect", "update", "threshold" etc),
# a priority between 0..1 incl.
# a hash of args (= anything required to handle the job),
# an in_progress marker (=ts when this job was started, 0 if not started yet)
# and an optional status subhash with info about the operation while being in_progress (e.g. pid)

# this function adds or updates a queued job entry
# if _id is present, the matching record is updated (but see atomic);
# otherwise a new record is created
#
# args: jobdata (= hash of all required queuing info, required),
# atomic (optional, hash of further clauses for selection)
#
# if atomic is present, then _id AND the atomic clauses are used as update query.
# atomic is not relevant for insertion of new records.
#
# returns: (undef,id) or error message
sub update_queue
{
	my ($self, %args) = @_;
	my ($jobdata,$atomic) = @args{"jobdata","atomic"};

	return "Cannot update queue entry without valid jobdata argument!" if (ref($jobdata) ne "HASH"
																																				 or !keys %$jobdata
																																				 or !$jobdata->{type}
																																				 # 0 is ok, absence is not
																																				 or !defined($jobdata->{priority})
																																				 or !$jobdata->{time}
																																				 # 0 is ok, absence is not
																																				 or !defined($jobdata->{in_progress})
  );

	# verify that the type of activity is one of the schedulable ones
	return "Unrecognised job type \"$jobdata->{type}\"!"
			if ($jobdata->{type} !~ /^(collect|update|services|threshold|escalate|configbackup|purge|dbcleanup)$/);


	my $jobid = $jobdata->{_id};
	delete $jobdata->{_id};
	my $isnew = !$jobid;
	if (!$jobid)
	{
		my $res = NMISNG::DB::insert( collection => $self->queue_collection,
																	record => $jobdata);
		return "Insertion of queue entry failed: $res->{error}" if (!$res->{success});
		$jobdata->{_id} = $jobid = $res->{id};
	}
	else
	{
		# extend the query with atomic-operation enforcement clauses if any are given
		my %qargs = ( _id => $jobid );
		if (ref($atomic) eq "HASH" && keys %$atomic)
		{
			map { $qargs{$_} = $atomic->{$_}; } (keys %$atomic);
		}

		my $res = NMISNG::DB::Update( collection => $self->queue_collection,
																	query => NMISNG::DB::get_query(and_part => \%qargs),
																	record => $jobdata );
		$jobdata->{_id} = $jobid;			# put it back!
		return "Update of queue entry failed: $res->{error}" if (!$res->{success});
		return "No matching object!" if (!$res->{updated_records});
	}
	return (undef, $jobid);
}

# removes a given job queue entry
# args: id (required)
# returns: undef or error message
sub remove_queue
{
	my ($self, %args) = @_;
	my $id = $args{id};

	return "Cannot remove queue entry without id argument!" if (!$id);

	my $res = NMISNG::DB::remove(collection => $self->queue_collection,
															 query => NMISNG::DB::get_query( and_part => { "_id" => $id }) );
	return "Deleting of queue entry failed: $res->{error}"
			if (!$res->{success});
	return "Deletion failed: no matching queue entry found" if (!$res->{removed_records});

	return undef;
}

# looks up queued jobs and returns modeldata object of the result
# args: id OR selection clauses (all optional)
# also sort/skip/limit/count - all optional
#  if count is given, then a pre-skip-limit query count is computed
#
# returns: modeldata object
sub get_queue_model
{
	my ($self, %args) = @_;

	my $wantedid = $args{id}; delete $args{id}; # _id vs id
	my %extras;
	map { if (exists($args{$_}))
				{ $extras{$_} = $args{$_}; delete $args{$_}; } } (qw(sort skip limit count));

	my $q = NMISNG::DB::get_query(and_part => { '_id' => $wantedid, %args });

	my $querycount;
	if ($extras{count})
	{
		my $res = NMISNG::DB::count(collection => $self->queue_collection,
																query => $q,
																verbose => 1);
		return NMISNG::ModelData->new(nmisng => $self, error => "Count failed: $res->{error}")
				if (!$res->{success});
		$querycount = $res->count;
	}

	# now perform the actual retrieval, with skip, limit and sort passed in
	my $cursor = NMISNG::DB::find( collection => $self->queue_collection,
																 query => $q,
																 sort => $extras{sort},
																 limit => $extras{limit},
																 skip => $extras{skip} );

	return NMISNG::ModelData->new(nmisng => $self,
																error => "Find failed: ".NMISNG::DB::get_error_string)
			if (!defined $cursor);
	my @data = $cursor->all;

	# asking for nonexistent id is treated as failure
	return NMISNG::ModelData->new(nmisng => $self, error => "No matching queue entry!")
			if (!@data && $wantedid);

	return NMISNG::ModelData->new(nmisng => $self,
																query_count => $querycount,
																data => \@data,
																sort => $extras{sort},
																limit => $extras{limit},
																skip => $extras{skip} );

}


# this is a maintenance command for removing old,
# broken or unwanted files
#
# args: self, simulate (default: false, if true only reports what it would do)
# returns: hashref, success/error and info (info is array ref)
sub purge_old_files
{
	my ($self, %args) = @_;
	my %nukem;

	my $simulate = NMISNG::Util::getbool( $args{simulate} );
	my $C = $self->config;
	my @info;

	push @info, "Starting to look for purgable files"
			.($simulate? ", in simulation mode":"");

	# config option, extension, where to look...
	my @purgatory = (
		{   ext          => qr/\.rrd$/,
			minage       => $C->{purge_rrd_after} || 30 * 86400,
			location     => $C->{database_root},
			also_empties => 1,
			description  => "Old RRD files",
		},
		{   ext          => qr/\.(tgz|tar\.gz)$/,
			minage       => $C->{purge_backup_after} || 30 * 86400,
			location     => $C->{'<nmis_backups>'},
			also_empties => 1,
			description  => "Old Backup files",
		},
		{
			# old nmis state files - legacy .nmis under var
			minage => $C->{purge_state_after} || 30 * 86400,
			ext => qr/\.nmis$/,
			location     => $C->{'<nmis_var>'},
			also_empties => 1,
			description  => "Legacy .nmis files",
		},
		{
			# old nmis state files - json files but only directly in var,
			# or in network or in service_status
			minage => $C->{purge_state_after} || 30 * 86400,
			location     => $C->{'<nmis_var>'},
			path         => qr!^$C->{'<nmis_var>'}/*(network|service_status)?/*[^/]+\.json$!,
			also_empties => 1,
			description  => "Old JSON state files",
		},
		{
			# old nmis state files - json files under nmis_system,
			# except auth_failure files
			minage => $C->{purge_state_after} || 30 * 86400,
			location     => $C->{'<nmis_var>'} . "/nmis_system",
			notpath      => qr!^$C->{'<nmis_var>'}/nmis_system/auth_failures/!,
			ext          => qr/\.json$/,
			also_empties => 1,
			description  => "Old internal JSON state files",
		},
		{
			# broken empty json files - don't nuke them immediately, they may be tempfiles!
			minage       => 3600,                       # 60 minutes seems a safe upper limit for tempfiles
			ext          => qr/\.json$/,
			location     => $C->{'<nmis_var>'},
			only_empties => 1,
			description  => "Empty JSON state files",
		},
		{   minage => $C->{purge_event_after} || 30 * 86400,
			path => qr!events/.+?/history/.+\.json$!,
			also_empties => 1,
			location     => $C->{'<nmis_var>'} . "/events",
			description  => "Old event history files",
		},
		{
			minage => $C->{purge_jsonlog_after} || 30 * 86400,
			also_empties => 1,
			ext          => qr/\.json/,
			location     => $C->{json_logs},
			description  => "Old JSON log files",
		},

		{
			minage => $C->{purge_jsonlog_after} || 30*86400,
			also_empties => 1,
			ext => qr/\.json/,
			location => $C->{config_logs},
			description => "Old node configuration JSON log files",
		},

		{
			minage => $C->{purge_reports_after} || 365*86400,
			also_empties => 0,
			ext => qr/\.html$/,
			location => $C->{report_root},
			description => "Very old report files",
		},

	);

	for my $rule (@purgatory)
	{
		next if ($rule->{minage} <= 0);	# purging can be disabled by setting the minage to -1
		my $olderthan = time - $rule->{minage};
		next if ( !$rule->{location} );
		push @info, "checking dir $rule->{location} for $rule->{description}";

		File::Find::find(
			{
				wanted => sub {
					my $localname = $_;

					# don't need it at the moment my $dir = $File::Find::dir;
					my $fn   = $File::Find::name;
					my @stat = stat($fn);

					next
							if (
								!S_ISREG( $stat[2] )    # not a file
								or ( $rule->{ext}     and $localname !~ $rule->{ext} )    # not a matching ext
								or ( $rule->{path}    and $fn !~ $rule->{path} )          # not a matching path
								or ( $rule->{notpath} and $fn =~ $rule->{notpath} )
							);                                                        # or an excluded path

					# also_empties: purge by age or empty, versus only_empties: only purge empties
					if ( $rule->{only_empties} )
					{
						next if ( $stat[7] );                                     # size
					}
					else
					{
						next
								if (
									( $stat[7] or !$rule->{also_empties} )                # zero size allowed if empties is off
									and ( $stat[9] >= $olderthan )
								);                                                    # younger than the cutoff?
					}
					$nukem{$fn} = $rule->{description};
				},
				follow => 1,
			},
			$rule->{location}
		);
	}

	for my $fn ( sort keys %nukem )
	{
		my $shortfn = File::Spec->abs2rel( $fn, $C->{'<nmis_base>'} );
		if ($simulate)
		{
			push @info, "purge: rule '$nukem{$fn}' matches $shortfn";
		}
		else
		{
			push @info, "removing $shortfn (rule '$nukem{$fn}')";
			unlink($fn) or return { error => "Failed to unlink $fn: $!", info => \@info };
		}
	}
	push @info, "Purging complete";
	return { success => 1, info => \@info };
}

# this is a maintenance command for removing invalid database material
# (old stuff is automatically done via TTL index on expire_at)
#
# args: self,  simulate (default: false, if true only returns what it would do)
# returns: hashref, success/error and info (array ref)
sub dbcleanup
{
	my ($self, %args) = @_;

	my $simulate = NMISNG::Util::getbool( $args{simulate} );
	# we want to remove:
	# all inventory entries whose node is gone,
 	# and all timed data whose inventory is gone.
	# note that for timed orphans we have no cluster_id;

	my @info;
	push @info, "Starting Database cleanup";

	# first find ditchable inventories
	push @info, "Looking for orphaned inventory records";

	my $invcoll = $self->inventory_collection;
	my ($goners, undef, $error) = NMISNG::DB::aggregate(
		collection => $invcoll,
		pre_count_pipeline => undef,
		count => undef,
		allowtempfiles => 1,
		post_count_pipeline => [
			# link inventory to parent node
			{ '$lookup' => { from => "nodes",
											 localField => "node_uuid",
											 foreignField => "uuid",
											 as =>  "parent"} },
			# then select the ones without parent
			{ '$match' => { parent => { '$size' => 0 } } },
			# then give me just the inventory ids
			{ '$project'  => { '_id' =>  1 } }]);

	if ($error)
	{
		return { error => "inventory aggregation failed: $error",
						 info => \@info };
	}
	my @ditchables =  map { $_->{_id} } (@$goners);

	# second, remove those - possibly orphaning stuff that we should pick up
	if (!@ditchables)
	{
		push @info, "No orphaned inventory records detected.";
	}
	elsif ($simulate)
	{
		push @info, "Cleanup would remove "
				.scalar(@ditchables). " orphaned inventory records, but not in simulation mode.";
	}
	else
	{
		my $res = NMISNG::DB::remove(collection => $invcoll,
																 query => NMISNG::DB::get_query(
																	 and_part => { _id => \@ditchables }));
		if (!$res->{success})
		{
			return { error =>  "failed to remove inventory instances: $res->{error}",
							 info => \@info };
		}
		push @info, "Removed $res->{removed_records} orphaned inventory records.";
	}

	# third, determine what concepts exist, get their timed data collections
	# and verify those against the inventory - plus the latest_data look-aside-cache
	my $conceptnames = NMISNG::DB::distinct(collection => $self->inventory_collection,
																					key => "concept");
	if (ref($conceptnames) ne "ARRAY")
	{
		return { error => "failed to determine distinct concepts!",
						 info => \@info };
	}
	for my $concept ("latest_data", @$conceptnames)
	{
		my $timedcoll = $concept eq "latest_data"?
				$self->latest_data_collection :
				$self->timed_concept_collection(concept => $concept);
		next  if (!$timedcoll);		# timed_concept_collection already logs, ditto latest_data_collection

		my $collname = $timedcoll->name;

		push @info, "Looking for orphaned timed records for $concept";

		my ($goners, undef, $error) = NMISNG::DB::aggregate(
			collection => $timedcoll,
			pre_count_pipeline => undef,
			count => undef,
			allowtempfiles => 1,
			post_count_pipeline => [
				# link to inventory parent
				{ '$lookup' => { from => $invcoll->name,
											 localField => "inventory_id",
												 foreignField => "_id",
												 as =>  "parent"} },
				# then select the ones without parent
				{ '$match' => { parent => { '$size' => 0 } } },
				# then give me just the inventory ids
				{ '$project'  => { '_id' =>  1 } }]);
		if ($error)
		{
			return { error => "$collname aggregation failed: $error",
							 info => \@info };
		}

		my @ditchables = map { $_->{_id} } (@$goners);
		if (!@ditchables)
		{
			push @info, "No orphaned $concept records detected.";
		}
		elsif ($simulate)
		{
			push @info, "cleanup would remove ".scalar(@ditchables)
					. " orphaned timed $concept records, but not in simulation mode.";
		}
		else
		{
			my $res = NMISNG::DB::remove(collection => $timedcoll,
																	 query => NMISNG::DB::get_query(
																	 and_part => { _id => \@ditchables }));
			if (!$res->{success})
			{
				return { error => "failed to remove $collname instances: $res->{error}",
								 info => \@info };
			}
			push @info, "removed $res->{removed_records} orphaned timed records for $concept.";
		}
	}

	push @info, "Database cleanup complete";

	return { success => 1, info => \@info};
}


# maintenance function that captures and dumps relevant configuration data
# args: self
# returns: hashref with success/error, and file (=path to resulting file)
sub config_backup
{
	my ($self, %args) = @_;
	my $C = $self->config;

	my $backupdir = $C->{'<nmis_backups>'};
	if (!-d $backupdir)
	{
		mkdir($backupdir,0700) or return { error => "Cannot create $backupdir: $!" };
	}

	return { error => "Cannot write to directory $backupdir, check permissions!" }
	if (!-w $backupdir);
	return { error => "Cannot access directory $backupdir, check permissions!" }
	if (!-r $backupdir or !-x $backupdir);

	# now let's take a new backup...
	my $backupprefix = "nmis-config-backup-";
	my $backupfilename = "$backupdir/$backupprefix".POSIX::strftime("%Y-%m-%d-%H%M",localtime).".tar";

	# ...of a dump of all node configuration (from the database), which we stash temporarily in conf
	my $nodes = $self->get_nodes_model();
	my $nodedumpfile = $C->{'<nmis_conf>'}."/all_nodes.json";
	if (!$nodes->error && @{$nodes->data})
	{
		# ensure that the output is indeed valid json, utf-8 encoded
		Mojo::File->new($nodedumpfile)->spurt(
			JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode($nodes->data) );
	}

	# ...and of _custom_ models and configuration files (and the default ones for good measure)
	my @relativepaths = (map { File::Spec->abs2rel($_, $C->{'<nmis_base>'}) }
											 ($C->{'<nmis_models>'},
												$C->{'<nmis_default_models>'},
												$C->{'<nmis_conf>'},
												$C->{'<nmis_conf_default>'} ));

	my $status = system("tar","-cf",$backupfilename,
											"-C", $C->{'<nmis_base>'},
											@relativepaths);
	if ($status == -1)
	{
		return  { error => "Failed to execute tar!" };
	}
	elsif ($status & 127)
	{
		return { error => "Backup failed, tar killed with signal ".($status & 127) };
	}
	elsif ($status >> 8)
	{
		return { error => "Backup failed, tar exited with exit code ".($status >> 8) };
	}

	# ...and the various cron files
	my $td = File::Temp::tempdir(CLEANUP => 1);

	mkdir("$td/cron",0755) or return { error => "Cannot create $td/cron: $! " };
	system("cp -a /etc/cron* $td/cron/ 2>/dev/null");
	system("crontab -l -u root > $td/cron/root_crontab 2>/dev/null");
	system("crontab -l -u nmis > $td/cron/nmis_crontab 2>/dev/null");

	$status = system("tar","-C",$td, "-rf",$backupfilename,"cron");
	if ($status == -1)
	{
		File::Temp::cleanup;
		return { error => "Failed to execute tar!" };
	}
	elsif ($status & 127)
	{
		File::Temp::cleanup;
		return { error => "Backup failed, tar killed with signal ".($status & 127) };
	}
	elsif ($status >> 8)
	{
		File::Temp::cleanup;
		return { error => "Backup failed, tar exited with exit code ".($status >> 8) };
	}
	File::Temp::cleanup;

	$status = system("gzip",$backupfilename);
	if ($status >> 8)
	{
		return { error => "Backup failed, gzip exited with exit code ".($status >> 8) };
	}

	unlink $nodedumpfile if (-f $nodedumpfile);
	return  { success => 1, file => "$backupfilename.gz" };
}

# poll/update-type action which updates the Links.nmis configuration(?) file
# args: self
# returns: nothing
sub update_links
{
	my ($self, %args) = @_;

	my $C = $self->config;

	if ( NMISNG::Util::getbool( $C->{disable_interfaces_summary} ) )
	{
		NMISNG::Util::logMsg("update_links disabled because disable_interfaces_summary=$C->{disable_interfaces_summary}");
		return;
	}
	my (%subnets, $II, %catchall);

	NMISNG::Util::dbg("Start");
	if ( !( $II = Compat::NMIS::loadInterfaceInfo() ) )
	{
		NMISNG::Util::logMsg("ERROR reading all interface info");
		return;
	}

	my $links = NMISNG::Util::loadTable( dir => 'conf', name => 'Links' ) // {};

	my $link_ifTypes = $C->{link_ifTypes} || '.';
	my $qr_link_ifTypes = qr/$link_ifTypes/i;

	NMISNG::Util::dbg("Collecting Interface Linkage Information");
	foreach my $intHash ( sort keys %{$II} )
	{
		my $cnt = 1;
		my $thisintf = $II->{$intHash};

		while (defined(my $subnet = $thisintf->{"ipSubnet$cnt"}) )
		{
			my $ipAddr = $thisintf->{"ipAdEntAddr$cnt"};

			if ($ipAddr ne ""
					and $ipAddr ne "0.0.0.0"
					and $ipAddr !~ /^127/
					and NMISNG::Util::getbool($thisintf->{collect})
					and $thisintf->{ifType} =~ /$qr_link_ifTypes/ )
			{
				my $neednode = $thisintf->{node};
				if (!$catchall{$neednode})
				{
					my $nodeobj = $self->node(name => $neednode);
					die "No node named $neednode exists!\n" if (!$nodeobj); # fixme9: better option?

					my ($inventory,$error) = $nodeobj->inventory(concept => "catchall");
					die "Failed to retrieve $neednode inventory: $error\n" if ($error);
					$catchall{$neednode} = ref($inventory)? $inventory->data : {};
				}

				if (!exists $subnets{$subnet}->{subnet} )
				{
					$subnets{$subnet}{subnet}      = $subnet;
					$subnets{$subnet}{address1}    = $ipAddr;
					$subnets{$subnet}{count}       = 1;
					$subnets{$subnet}{description} = $thisintf->{Description};
					$subnets{$subnet}{mask}        = $thisintf->{"ipAdEntNetMask$cnt"};
					$subnets{$subnet}{ifSpeed}     = $thisintf->{ifSpeed};
					$subnets{$subnet}{ifType}      = $thisintf->{ifType};
					$subnets{$subnet}{net1}        = $catchall{$neednode}->{netType};
					$subnets{$subnet}{role1}       = $catchall{$neednode}->{roleType};
					$subnets{$subnet}{node1}       = $thisintf->{node};
					$subnets{$subnet}{ifDescr1}    = $thisintf->{ifDescr};
					$subnets{$subnet}{ifIndex1}    = $thisintf->{ifIndex};
				}
				else
				{
					++$subnets{$subnet}{count};

					if (!defined $subnets{$subnet}{description})
					{    # use node2 description if node1 description did not exist.
						$subnets{$subnet}{description} = $thisintf->{Description};
					}
					$subnets{$subnet}{net2}     = $catchall{$neednode}->{netType};
					$subnets{$subnet}{role2}    = $catchall{$neednode}->{roleType};
					$subnets{$subnet}{node2}    = $thisintf->{node};
					$subnets{$subnet}{ifDescr2} = $thisintf->{ifDescr};
					$subnets{$subnet}{ifIndex2} = $thisintf->{ifIndex};
				}
			}
			if ( $C->{debug} > 2 )
			{
					NMISNG::Util::dbg("found subnet: ".
														Data::Dumper->new([$subnets{$subnet}])->Terse(1)->Indent(0)->Pair("=")->Dump);
			}
			$cnt++;
		}
	}

	NMISNG::Util::dbg("Generating Links datastructure");
	foreach my $subnet ( sort keys %subnets )
	{
		my $thisnet = $subnets{$subnet};
		next if ( $thisnet->{count} != 2 ); # ignore networks that are attached to only one node

		# skip subnet for same node-interface in link table
		next if (grep {
			$links->{$_}->{node1} eq $thisnet->{node1}
			and $links->{$_}->{ifIndex1} eq $thisnet->{ifIndex1}
						 } (keys %{$links}));

		my $thislink = ($links->{$subnet} //= {});

		# form a key - use subnet as the unique key, same as read in, so will update any links with new information
		if ( defined $thisnet->{description}
				 and $thisnet->{description} ne 'noSuchObject'
				 and $thisnet->{description} ne "" )
		{
			$thislink->{link} = $thisnet->{description};
		}
		else
		{
			# label the link as the subnet if no description
			$thislink->{link} = $subnet;
		}
		$thislink->{subnet}  = $thisnet->{subnet};
		$thislink->{mask}    = $thisnet->{mask};
		$thislink->{ifSpeed} = $thisnet->{ifSpeed};
		$thislink->{ifType}  = $thisnet->{ifType};

		# define direction based on wan-lan and core-distribution-access
		# selection weights cover the most well-known types
		# fixme: this is pretty ugly and doesn't use $C->{severity_by_roletype}
		my %netweight = ( wan => 1, lan => 2, _ => 3, );
		my %roleweight = ( core => 1, distribution => 2, _ => 3, access => 4 );

		my $netweight1
				= defined( $netweight{$thisnet->{net1}} )
				? $netweight{$thisnet->{net1}}
		: $netweight{"_"};
		my $netweight2
				= defined( $netweight{$thisnet->{net2}} )
				? $netweight{$thisnet->{net2}}
		: $netweight{"_"};

		my $roleweight1
				= defined( $roleweight{$thisnet->{role1}} )
				? $roleweight{$thisnet->{role1}}
		: $roleweight{"_"};
		my $roleweight2
				= defined( $roleweight{$thisnet->{role2}} )
				? $roleweight{$thisnet->{role2}}
		: $roleweight{"_"};

		my $k
				= ( ( $netweight1 == $netweight2 && $roleweight1 > $roleweight2 ) || $netweight1 > $netweight2 )
				? 2
				: 1;

		$thislink->{net}  = $thisnet->{"net$k"};
		$thislink->{role} = $thisnet->{"role$k"};

		$thislink->{node1}      = $thisnet->{"node$k"};
		$thislink->{interface1} = $thisnet->{"ifDescr$k"};
		$thislink->{ifIndex1}   = $thisnet->{"ifIndex$k"};

		$k = $k == 1 ? 2 : 1;
		$thislink->{node2}      = $thisnet->{"node$k"};
		$thislink->{interface2} = $thisnet->{"ifDescr$k"};
		$thislink->{ifIndex2}   = $thisnet->{"ifIndex$k"};

		# dont overwrite any manually configured dependancies.
		if ( !exists $thislink->{depend} ) { $thislink->{depend} = "N/A" }

		NMISNG::Util::dbg("Adding link $thislink->{link} for $subnet to links");
	}

	NMISNG::Util::writeTable( dir => 'conf', name => 'Links', data => $links );
	NMISNG::Util::logMsg("Check table Links and update link names and other entries");

	NMISNG::Util::dbg("Finished");
}


1;
