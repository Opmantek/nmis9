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

	my $nmisng = $args{'nmisng'};
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

	# no regex specials as we want this thing and only this thing
	if ( $self->{data}{_id} )
	{
		$q = NMISNG::DB::get_query( and_part => {_id => $self->{data}{_id}}, no_regex => 1);
	}
	elsif ( !$q )
	{
		$q = NMISNG::DB::get_query(
			no_regex => 1,
			and_part => {
				cluster_id => $self->{data}{cluster_id},
				node_uuid => $self->{data}{node_uuid},
				# OMK-12605 blind-review round 5: method was missing from this
				# identity. get_query_part() drops empty-string fields (like
				# the property/index/class/section/source below, which the
				# Operational writer intentionally leaves blank) entirely, so
				# without method this query could collapse to just
				# cluster_id/node_uuid/event(/element) and match a Threshold
				# or Alert document that happens to share an event name -
				# every writer (Threshold, Alert, Operational) always sets a
				# real, non-empty method, so adding it here only ever
				# tightens matching, never loosens it.
				method => $self->{data}{method},
				event => $self->{data}{event},
				element => $self->{data}{element},
				property => $self->{data}{property},
				index => $self->{data}{index},
				class => $self->{data}{class},
				index => $self->{data}{index},
				section => $self->{data}->{section},
				source => $self->{data}->{source}
			}
		);
	}

	return $q;
}


# deletes this status instance from the database
# returns (1, message) or (0,error)
sub delete
{
	my ($self) = @_;

	# not error but message doesn't hurt
	return (1, "Status entry already deleted") if ($self->{_deleted});

	my $res = NMISNG::DB::remove(
		collection => $self->nmisng->status_collection,
		query      => $self->_query(),
		just_one => 1
	);

	return (0, "Deleting of status entry failed: $res->{error}")
		if ( !$res->{success} );
	return (0, "Deletion failed: no matching status entry found") if ( !$res->{removed_records} );

	$self->{_deleted} = 1;
	return (1, undef);
}

# convenience function, makes api similar to inventory
# NOTE: id will only be there if this thing was loaded from db, a saved
# or updated object which came from 'new' won't get it on save/update
sub id
{
	my ($self) = @_;
	return $self->{data}{_id};
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
	$self->update_dashnode_data(record => \%data);

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

# update dashnode data structure if enabled
# args: record - the record being saved
# modifies: $self->nmisng->{dashnode_context}{data}
# no-ops in a process that never called load_dashnode_data (the fping
# worker, standalone services/thresholds jobs) - otherwise this would grow
# an in-memory hash forever in a long-lived process that never flushes it.
sub update_dashnode_data {
	my ($self, %args) = @_;
	my $record = $args{record};
	if( NMISNG::Util::getbool($self->nmisng->config->{enable_dashnode_file})
			&& defined($self->nmisng->{dashnode_context})
			&& defined($self->nmisng->{dashnode_context}{data}) ) {
		my $data = { %$record }; # take a copy because we're modifying the data		
		if( $data->{index} == ""){
			$data->{index} = 0;
		}
		my $key;
		if( $data->{method} eq "Threshold" ) {
			$key = $data->{property} . "--" . $data->{index};
		}
		elsif( $data->{method} eq "Alert" ) {
			$key = $data->{event} . "--" . $data->{element};
		}
		else {
			$key = $data->{event} . "--" . $data->{element};
		}

		# QoS status key needs more uniqueness for dashnode so add in inventory id
		# (NMIS8 had the ClassMap key but we don't have that in this event)
		if( $data->{property} =~ /^qos_/ ) {
			$key .= "--".$data->{"inventory_id"}->hex;
		}

		$data->{"updated"} = $data->{"lastupdate"};
		# $data->{"class"} //= "";
		# $data->{"element"} //= "";
		$data->{"level_select"} //= "default";
		$data->{"inventory_id"} = $data->{"inventory_id"}->hex if ( ref( $data->{"inventory_id"} ) );
		$data->{expire_at} = $data->{expire_at}->to_string;
		delete $data->{lastupdate};
		# delete $data->{inventory_id};
		# delete $data->{expire_at};
		# delete $data->{cluster_id};
		# delete $data->{node_uuid};

		$self->nmisng->{dashnode_context}{data}{status}{$key} = $data;
	}
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

# writes/refreshes the status document for a code-raised ("operational")
# event. called from Compat::NMIS::notify (status error) and
# Compat::NMIS::checkEvent (status ok) on every cycle. threshold and alert
# callers maintain their own status documents and are gated out here.
# args: nmisng, node (NMISNG::Node), event, element, status (error|ok),
#  level, details, context, inventory_id,
#  events_config (optional, avoids a reload when the caller has it)
# returns: undef on success or skip, error string on save failure
sub save_operational_status
{
	my (%args) = @_;
	my ( $nmisng, $node, $event, $element, $status, $level, $details, $context, $inventory_id )
		= @args{qw(nmisng node event element status level details context inventory_id)};

	return if ( ref($nmisng) ne "NMISNG" or !$node or !$event or !$status );

	# threshold and alert callers maintain their own status documents
	my $ctype = ( ref($context) eq "HASH" ) ? ( $context->{type} // '' ) : '';
	return if ( $ctype eq "threshold" or $ctype eq "alert" );
	return if ( $event =~ /^(Proactive|Alert: )/ );

	my $events_config = $args{events_config}
		// NMISNG::Util::loadTable( dir => 'conf', name => 'Events' );
	my $thisevent_control = $events_config->{$event}
		|| $events_config->{'Default'}
		|| { Log => "true", Notify => "true", Status => "true" };

	# stateless events have no ok/error state; same test notify performs
	my $C = $nmisng->config;
	# \Q..\E: the event name is data, not a pattern. this helper runs on every
	# notify/checkEvent call including ones whose event name comes from custom
	# alert data in the database, so an unbalanced metacharacter would
	# otherwise die and abort the whole poll cycle for that node.
	my $is_stateless = ( $C->{non_stateful_events} !~ /\Q$event\E/
		or NMISNG::Util::getbool( $thisevent_control->{Stateful} ) ) ? 0 : 1;
	return if ($is_stateless);

	# per-event write gate: off only if this event's Events.nmis entry says
	# so. Events.nmis is now installer-merged (installer_hooks/10-postcopy-
	# confmerges), so this one flag reliably reaches existing sites too -
	# no separate Config.nmis list needed.
	return if ( defined( $thisevent_control->{TrackStatus} )
		and !NMISNG::Util::getbool( $thisevent_control->{TrackStatus} ) );

	# defensive wrap: this runs on the busiest path in the product (every
	# notify/checkEvent, every node, every cycle), so an unexpected die from
	# anything below (Status->new's confess on a missing cluster_id,
	# make_oid on a malformed inventory_id) is caught and reported rather
	# than aborting the caller's poll.
	my $error;
	eval
	{
		my $status_obj = NMISNG::Status->new(
			nmisng     => $nmisng,
			cluster_id => $node->cluster_id,
			node_uuid  => $node->uuid,
			method     => "Operational",
			event      => $event,
			element    => $element // '',
			status     => $status,
			level      => $level // 'Normal',
			details    => $details // '',
			property   => '',
			index      => '',
			class      => '',
			section    => '',
			source     => '',
			value      => '',
			( defined($inventory_id) ? ( inventory_id => NMISNG::DB::make_oid($inventory_id) ) : () ),
		);
		$error = $status_obj->save();
	};
	$error = "save_operational_status died for $event: $@" if ($@);
	$nmisng->log->error("save_operational_status failed for $event: $error")
		if ($error);
	return $error;
}

# flips an existing Operational status doc to ok when its event is closed
# outside notify/checkEvent (gui trap ack, api delete). update only, never
# create: up-events and traps never had a doc, so they stay inert.
# args: nmisng, cluster_id, node_uuid, event, element
# returns: nothing
sub close_operational_status
{
	my (%args) = @_;
	my ( $nmisng, $cluster_id, $node_uuid, $event, $element )
		= @args{qw(nmisng cluster_id node_uuid event element)};
	return if ( ref($nmisng) ne "NMISNG" or !$node_uuid or !$event );

	my $dbres = NMISNG::DB::update(
		collection => $nmisng->status_collection(),
		query      => NMISNG::DB::get_query(
			no_regex => 1,
			and_part => {
				cluster_id => $cluster_id,
				node_uuid  => $node_uuid,
				method     => "Operational",
				event      => $event,
				element    => $element // '',
				# only act when this hook is genuinely the thing flipping an
				# error doc to ok (the real out-of-band case). On the ordinary
				# clear path checkEvent has already written an honest, more
				# specific details string moments earlier, and the doc is
				# already ok - matching nothing here leaves that intact rather
				# than overwriting it with the generic "event closed".
				status     => "error",
			}
		),
		record => {
			'$set' => {
				status     => "ok",
				level      => "Normal",
				details    => "event closed",
				lastupdate => time
			}
		},
		freeform => 1,
	);
	$nmisng->log->error("close_operational_status failed for $event: $dbres->{error}")
		if ( !$dbres->{success} );
	return;
}

1;
