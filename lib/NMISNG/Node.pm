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

use Carp::Assert;
use Clone;    # for copying overrides out of the record
use Data::Dumper;

use NMISNG::DB;

# params:
#   uuid - required
#   collection - collection object from DB
#   config - system configuration hash
#   log - NMISNG::Log
sub new
{
	my ( $class, %args ) = @_;

	return if ( !$args{collection} );    #"collection required"
	return if ( !$args{uuid} );         #"uuid required"

	my $self = {
		_dirty     => {},
		_uuid      => $args{uuid},
		collection => $args{collection},
		config     => $args{config},
		log        => $args{log}
	};
	bless( $self, $class );
	return $self;
}

###########
# Private:
###########

# return the collection the node belongs in
# dies if requested and does not exist
sub _collection
{
	my ($self) = @_;
	die if ( !$self->{collection} );
	return $self->{collection};
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

# get/set the configuration for this node
# setting data means the configuration is dirty and will
#  be saved next time save is called, even if it is identical to what
#  is in the database
# getting will load the configuration if it's not already loaded
# params:
#  newvalue - if set will replace what is currently loaded for the config
#   and set the object to be dirty
# returns configuration hash
sub configuration
{
	my ( $self, $newvalue ) = @_;

	if ( defined($newvalue) )
	{
		$self->log->warn("NMISNG::Node::configuration given new config with uuid that does not match")
			if ( $newvalue->{uuid} && $newvalue->{uuid} ne $self->uuid );

		# UUID cannot be changed
		$newvalue->{uuid} = $self->uuid;

		$self->{_configuration} = $newvalue;
		$self->_dirty( 1, 'configuration' );
	}

	# if there is no config try and load it
	if ( !defined( $self->{_configuration} ) )
	{
		$self->load( load_configuration => 1 );
	}

	return $self->{_configuration};
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

# load data for this node from the database
# params:
#  options - hash, if not set or present all data for the node is loaded
#    load_overrides => 1 will load overrides
#    load_configuration => 1 will load overrides
# no return value
sub load
{
	my ( $self, %options ) = @_;
	my @options_keys = keys %options;
	my $no_options   = ( @options_keys == 0 );

	my $query = NMISNG::DB::get_query( and_part => {uuid => $self->uuid} );
	my $cursor = NMISNG::DB::find(
		collection => $self->_collection(),
		query      => $query
	);
	my $entry = $cursor->next;
	if ($entry)
	{

		if ( $no_options || $options{load_overrides} )
		{
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
			$self->load( load_overrides => 1 );
		}
	}
	return $self->{_overrides} // undef;
}

# Save object to DB if it is dirty
# returns 0 if no saving required, -1 if node is not valid, >0 if all good
# TODO: error checking just uses assert right now, we may want
#   a differnent way of doing this
sub save
{
	my ($self) = @_;

	return 0  if ( !$self->_dirty() );
	return -1 if ( !$self->validate() );

	my $result;

	my $entry = $self->configuration();
	$entry->{overrides} = $self->overrides();

	if ( $self->is_new() )
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->_collection,
			record     => $entry,
		);
		assert( $result->{success}, "Record inserted successfully" );
		$self->{_configuration}{_id} = $result->{id} if ( $result->{success} );

		$self->_dirty( 0, 'configuration' );
		$self->_dirty( 0, 'overrides' );
	}
	else
	{
		$result = NMISNG::DB::update(
			query  => NMISNG::DB::get_query( and_part => {uuid => $self->uuid} ),
			record => $entry
		);
		assert( $result->{success}, "Record updated successfully" );

		$self->_dirty( 0, 'configuration' );
		$self->_dirty( 0, 'overrides' );
	}
	return $result->{success};
}

# get the nodes UUID
sub uuid
{
	my ($self) = @_;
	return $self->{_uuid};
}

# returns 0/1 if the node is valid
sub validate
{
	my ($self) = @_;
	my $configuration = $self->configuration();

	return 0 if ( !$configuration->{name} );
	return 1;
}

1;
