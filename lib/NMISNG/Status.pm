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

# event class, create with attributes needed to look up an existing object and call
# load to get the event from the db or create with all attributes for a new event
# and call save.

package NMISNG::Status;
use strict;

use Carp;
use Data::Dumper;
use Test::Deep::NoTest;

our $VERSION = "1.0.0";

# params: all properties desired in the status
# here is a list of the known attributes, these will be givent getter/setters, everything else is 'custom_data'
my %known_attrs = (
	_id => 1,
	cluster_id => 1,
	node_uuid => 1,
	element => 1,
	event => 1,
	index => 1,
	inventory_id => 1,
	level => 1,
	method => 1,
	name => 1,
	property => 1,
	status => 1,
	type => 1,	
	value => 1,
	class => 1,
	lastupdate => 1
);

sub new
{
	my ( $class, %args ) = @_;
	confess "nmisng required" if ( ref( $args{nmisng} ) ne "NMISNG" );
	confess "cluster_id required" if ( !$args{cluster_id} );

	my ( $nmisng ) = @args{'nmisng'};
	delete $args{nmisng};
	
	my $self = bless(
		{   _nmisng => $nmisng,
			data    => \%args
		},
		$class
	);

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );
	return $self;
}

# quick get/setters for plain attributes
# having setters for these isn't really necessary
for my $name ( keys %known_attrs )
{
	no strict 'refs';
	*$name = sub {
		my $self = shift;
		return (
			  @_
			? $self->_generic_getset( name => $name, value => shift )
			: $self->_generic_getset( name => $name )
		);
		}
}

# a simple setter/getter for the object,
# usable by subclasses
# expects: name => fieldname, optional value => newvalue
# returns the old value for updates, current value for reads
sub _generic_getset
{
	my ( $self, %args ) = @_;

	die "cannot read option without name!\n" if ( !exists $args{name} );
	my $fieldname = $args{name};

	my $curval = $self->{data}{$fieldname};
	if ( exists $args{value} )
	{
		my $newvalue = $args{value};
		$self->{data}{$fieldname} = $newvalue;
	}
	return $curval;
}

# filter/query to find this thing, just a hash
# if we have an id look for it using that (because we may want
# to update active/historic/etc), if we don't have an _id we have
# to use what we are given because this is probably a new object
# searching for it's data in the db
sub _query
{
	my ( $self ) = @_;
	my $q;

	if ( $self->{data}{_id} )
	{
		$q = NMISNG::DB::get_query( and_part => {_id => $self->{data}{_id}} );
	}
	elsif ( !$q )
	{
		$q = NMISNG::DB::get_query(
			and_part => {
				cluster_id => $self->{data}{cluster_id},
				node_uuid => $self->{data}{node_uuid},
				event => $self->{data}{event},
				element => $self->{data}{element},
				property => $self->{data}{property},
				index => $self->{data}{index},
				class => $self->{data}{class}
			}
		);
	}

	return $q;
}


# this will either delete the event or mark it as historic and set the expire_at
#
sub delete
{
	my ($self) = @_;

	return "Cannot delete a status entry that is already deleted" if( $self->{_deleted} );

	my $res = NMISNG::DB::remove(
		collection => $self->nmisng->status_collection,
		query      => $self->_query(),
		just_one => 1
	);
	
	return "Deleting of status entry failed: $res->{error}"
		if ( !$res->{success} );
	return "Deletion failed: no matching status entry found" if ( !$res->{removed_records} );

	$self->{_deleted} = 1;
	return undef;	
}

# is this thing an alert? there should be a better way to do this, alerts
# should tell us that we are an alert
sub is_alert
{
	my ($self) = @_;
	return ( $self->method eq 'Alert' )
}

# return nmisng object for this object
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# save this thing, will be created in db if it does
# not already exist
# returns undef on success, error otherwise
sub save
{
	my ( $self,  %args )  = @_;
	my ( $valid, $error ) = $self->validate();
	return $error if ( !$valid );

	# don't try and update the id and don't let it be there to be set to undef either
	my %data = %{$self->{data}};
	delete $data{_id};

	my $expire_at = $self->nmisng->config->{purge_status_after} // 86400;
	$expire_at = Time::Moment->from_epoch( time + $expire_at );
	$data{expire_at} = $expire_at;
	$data{lastupdate} = time;

	my $q = $self->_query();

	my $dbres = NMISNG::DB::update(
		collection => $self->nmisng->status_collection(),
		query      => $q,
		record     => \%data,
		upsert     => 1
	);

	$error = $dbres->{error} if ( !$dbres->{success} );
	# don't attach the id, in insert case we get it but if this is an
	# update we do not get it, to be consistent don't set it in either case
	# if the object was loaded with _id it will have it, if not it won't
	# if ( $dbres->{upserted_id} )
	# {
	# 	$self->{data}{_id} = $dbres->{upserted_id};
	# 	$self->nmisng->log->debug1(
	# 		"Created new status $data{event} $dbres->{upserted_id} for node $data{node_name}");
	# }

	return $error;
}

sub updated
{
	my ($self) = @_;
	die "this has been changed to lastupdate";	
}

# returns (1,nothing) if the node configuration is valid,
# (negative or 0, explanation) otherwise
sub validate
{
	my ($self) = @_;
	return ( 1, undef );
}

1;
