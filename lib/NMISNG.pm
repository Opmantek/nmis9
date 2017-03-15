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
use strict;

our $VERSION = "9.0.0";

use Data::Dumper;

use NMISNG::Util;
use NMISNG::Log;
use NMISNG::DB;
use NMISNG::ModelData;
use NMISNG::Node;

# params:
#  config - hash containing object
#  [debug] - 0/1 should debug be on, defaults to 0, TODO: is this required? can log not do this?
#  log - NMISNG::Log object to log to
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
			$self->log( "fatal", "cannot connect to MongoDB: $errmsg" );
			die "cannot connect to MongoDB: $errmsg\n";
		}
		$db = $conn->get_database( $self->config->{db_name} );
	}

	my $nodecoll = NMISNG::DB::get_collection( db => $db, name => "nodes" );
	$self->log( "fatal", "Could not get collection nodes: " . NMISNG::DB::get_error_string ) if ( !$nodecoll );
	my $ipcoll = NMISNG::DB::get_collection( db => $db, name => "ip" );
	$self->log( "fatal", "Could not get collection ip: " . NMISNG::DB::get_error_string ) if ( !$ipcoll );

	NMISNG::Util::TODO("figure out how indices will work");
	my $err = NMISNG::DB::ensure_index(
		collection    => $nodecoll,
		drop_unwanted => $args{drop_unwanted_indices},
		indices       => [[{"uuid" => 1}, {unique => 1}]]
	);

	# now park the db handles in the object
	$self->{_db}      = $db;
	$self->{db_nodes} = $nodecoll;
	$self->{db_ip}    = $ipcoll;

	return $self;
}

###########
# Private:
###########

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
			collection  => $self->{db_ip},
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

# Internal helper to return nodes collection
sub _nodes_collection
{
	my ($self) = @_;
	return $self->{db_nodes};
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
	if ( $modeldata->count() > 0 )
	{
		my $model = $modeldata->data()->[0];
		$node = NMISNG::Node->new(
			uuid       => $model->{uuid},
			collection => $self->_nodes_collection,
			config     => $self->config,
			log        => $self->log
		);
	}
	elsif ($create)
	{
		$node = NMISNG::Node->new(
			uuid       => $args{uuid},
			collection => $self->_nodes_collection,
			config     => $self->config,
			log        => $self->log
		);
	}

	return $node;
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
# return 'complete' result elements without limit! - a dummy element is inserted at the 'complete' end,
# but only 0..limit are populated
sub get_nodes_model
{
	my ( $self, %args ) = @_;

	# no_auto_oid needed as nodes collection uses straight node name as _id
	my $q = NMISNG::DB::get_query(
		and_part => {
			'uuid'  => $args{uuid},
			'name'  => $args{name},
			'host'  => $args{host},
			'group' => $args{group}
		}
	);

	my $model_data = [];
	if ( $args{paginate} )
	{

		# fudge up a dummy result to make it reflect the total number
		my $count = NMISNG::DB::count( collection => $self->{db_nodes}, query => $q );
		$model_data->[$count - 1] = {} if ($count);
	}

	my $entries = NMISNG::DB::find(
		collection => $self->{db_nodes},
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

	my $model_data_object = NMISNG::ModelData->new( modelName => "nodes", data => $model_data );
	return $model_data_object;
}

sub get_node_names
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model(%args);
	my $data = $model_data->data();
	my @node_names = map { $_->{name} } @$data;
	return \@node_names;
}

sub get_node_uuids
{
	my ( $self, %args ) = @_;
	my $model_data = $self->get_nodes_model(%args);
	my $data = $model_data->data();
	my @uuids = map { $_->{uuid} } @$data;
	return \@uuids;
}

# returns this objects log object
sub log
{
	my ($self) = @_;
	return $self->{_log};
}

1;
