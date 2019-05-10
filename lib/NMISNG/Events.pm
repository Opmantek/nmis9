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

package NMISNG::Events;
use strict;

use Fcntl qw(:DEFAULT :flock);    # Imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Data::Dumper;

use NMISNG::Event;

our $VERSION = "1.0.0";

# NOTES:
# - event->{current} - true/false to active-0/1
# - category - current/historic to historic - 0/1
#  		category only used in event_to_filename

# params:
#  config - hash containing object
#  log - NMISNG::Log object to log to, required.
#  db - mongodb database object, optional.
#  drop_unwanted_indices - optional, default is 0.
sub new
{
	my ( $class, %args ) = @_;

	die "nmisng required" if ( ref( $args{nmisng} ) ne "NMISNG" );

	my $self = bless( {_nmisng => $args{nmisng},}, $class );

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );
	return $self;
}

# removes all current events for a node
# this is normally used after editing/deleting nodes to clean the slate and
# make sure there's no lingering phantom events
#
# note: logs if allowed to
# args: node obj, caller (for logging)
# return undef or error message
sub cleanNodeEvents
{
	my ( $self, $node, $caller ) = @_;
	my $C = $self->nmisng->config();
	return "Cannot clean events without node object: node=$node" if ( ref($node) ne 'NMISNG::Node' );

	my $events_config = NMISNG::Util::loadTable( dir => 'conf', name => 'Events' );

	# get all events that will be cleaned so we can log if needed
	my $eventsmodel = $self->get_events_model( filter => {node_uuid => $node->uuid, historic => 0} );
	if (my $failure = $eventsmodel->error)
	{
		return $failure;
	}
	if ( $eventsmodel->count > 0 )
	{
		my $expire_at = time + $C->{purge_event_after} // 86400;

		# update all records for this node to be inactive and expire
		my $dbres = NMISNG::DB::update(
			collection => $self->nmisng->events_collection(),
			query      => {node_uuid => $node->uuid},
			record     => {'$set' => {active => 0, historic => 1, expire_at => $expire_at}},
			freeform   => 1,
			multiple   => 1
		);
		return "failed to upsert event: $dbres->{error}" if ( !$dbres->{success} );

		foreach my $event ( @{$eventsmodel->data()} )
		{
			my $eventname = $event->{event};

			# log the deletion meta-event iff the original event had logging enabled
			# event logging: true unless overridden by event_config
			if (   !$eventname
				or ref( $events_config->{$eventname} ) ne "HASH"
				or !NMISNG::Util::getbool( $events_config->{$eventname}->{Log}, "invert" ) )
			{
				$self->logEvent(
					node_name => $node->name,
					event     => "$caller: deleted event: $eventname",
					level     => "Normal",
					element   => $event->{element} || '',
					details   => $event->{details} || ''
				);
			}
		}
	}
	return undef;
}

# convenience function to help create an event object
sub event
{
	my ( $self, %args ) = @_;
	$args{nmisng} = $self->nmisng;
	my $event = NMISNG::Event->new(%args);
	return $event;
}

# this adds one new event OR updates an existing stateless event
# this is a HIGHLEVEL function, doing all kinds of nmis-related stuff!
# to JUST create an event record, use eventUpdate() w/create_if_missing
#
# args: node, event, element (may be missing), level,
# details (may be missing), stateless (optional, default false),
# context (optional, just passed through)
#
# returns: undef if ok, error message otherwise
sub eventAdd
{
	my ( $self, %args ) = @_;

	my $node = $args{node};
	return "Cannot create event without node object: node=$node" if ( ref($node) ne 'NMISNG::Node' );
	$args{node_name} = $node->name;
	$args{node_uuid} = $node->uuid;
	my $event_obj = $self->event(%args);
	return $event_obj->save();
}

# deletes ONE event, does NOT (event-)log anything
# args: event (=record suitably filled in to find the record)
# the event is marked historic and inactive if keep_event_history is set
# returns undef if ok, error message otherwise
sub eventDelete
{
	my ( $self, %args ) = @_;
	my $event_args = $args{event};
	my $event      = $self->event(%$event_args);
	return $event->delete();
}

# this function checks if a particular event exists and is both active and non-historic
#
# args: node (object), event(name), element (element may be missing)
# returns 1 if found, 0/undef otherwise
sub eventExist
{
	my ( $self, $node, $event, $element ) = @_;

	# we only want non-historic events which are active
	# non-historic is default, but active is ignored by event::load!
	my $eventobj
		= $self->event( node_uuid => $node->uuid, event => $event, element => $element,
										historic => 0, active => 1 );
	return $eventobj->exists && $eventobj->active;
}

# gets the detailed event record for the given event
# args: node_uuid or NMISNG::Node object, event(name), element, inventory_id, active [0/1]
#   historic [0/1] defaults to 0 (as it used t0)
# returns hash { error => , event => }, error if >1 event is found (this is meant to load a single event)
sub eventLoad
{
	my ( $self, %args ) = @_;

	my $event = $self->event(%args);
	my $error = $event->load();

	return ( $error, $event );
}

# replaces the event data for one given EXISTING event
# or CREATES a new event with option create_if_missing
#
# args: event (=full record, for finding AND updating)
# create_if_missing (default false)
#
# anything except the _id can be changed, but think about it
# before doing this
#
# events lastupdate will be set
#
# returns undef if ok, error message otherwise
sub eventUpdate
{
	my ( $self, %args ) = @_;
	my $event_args = $args{event};
	my $event      = $self->event(%$event_args);
	# no need to force, but only use values we don't already have
	$event->load(only_take_missing => 1);
	return $event->save();
}

# looks up all events (for one node or all), filtering for active and historic possible
#
# args: filter hash, { can have node obj or node_uuid(optional, if not there all are loaded),
# 		active 1/0, historic 1/0 (defaults to 0), cluster_id (defaults to local)
#  as well as sort/skip/limit/fields_hash
# search args are parsed for regex:/iregex:
#
# returns: modeldata object (maybe empty, check ->error)
sub get_events_model
{
	my ( $self, %args ) = @_;
	my $C      = $self->nmisng->config();
	my $filter = $args{filter};
	my $q      = $args{query};

	my $node = $filter->{node};
	return NMISNG::ModelData->new(error => "give me a node object for node or use a different argument")
			if ( $node && ref($node) ne 'NMISNG::Node' );

	my $node_uuid = $filter->{node_uuid};
	$node_uuid = $node->uuid if ( !$node_uuid && $node );

	my %results = ();
	if ( !$q )
	{
		$q = NMISNG::DB::get_query(
			and_part => {
				_id          => $filter->{_id},
				node_uuid    => $node_uuid,
				cluster_id => $filter->{cluster_id} // $self->nmisng->config->{cluster_id},
				event        => $filter->{event},
				element      => $filter->{element},
				inventory_id => $filter->{inventory_id},
				stateless    => $filter->{stateless},
				active       => $filter->{active},
				historic     => $filter->{historic} // 0
			}
		);
	}

	my $cursor = NMISNG::DB::find(
		collection  => $self->nmisng->events_collection,
		query       => $q,
		sort        => $args{sort},
		limit       => $args{limit},
		skip        => $args{skip},
		fields_hash => $args{fields_hash},
	);
	my ( $model_data_object, $error, @all ) = ( undef, undef, () );

	if ($cursor)
	{
		@all = $cursor->all;
	}
	else
	{
		return NMISNG::ModelData->new(error => &NMISNG::DB::get_error_string);
	}

	# create modeldata object with instantiation info from caller
	return NMISNG::ModelData->new(
		nmisng     => $self->nmisng,
		class_name => 'NMISNG::Event',
		data       => \@all
	);
}

# write a record for a given event to the event log file
# args: node_name, event, element (may be missing), level, details (may be missing)
# fixme9: some callers pass in node_uuid, which is currently ignored
# logs errors
# returns: undef if ok, error message otherwise
sub logEvent
{
	my ( $self, %args ) = @_;

	my $node_name = $args{node_name};
	my $event     = $args{event};
	my $element   = $args{element};
	my $level     = $args{level};
	my $details   = $args{details};
	$details =~ s/,//g;    # strip any commas

	if ( !$node_name or !$event or !$level )
	{
		NMISNG::Util::logMsg(
			"ERROR logging event, required argument missing: node_name=$node_name, event=$event, level=$level");
		return "required argument missing: node_name=$node_name, event=$event, level=$level";
	}

	my $time = time();
	my $C    = NMISNG::Util::loadConfTable();

	my @problems;

	# MUST NOT NMISNG::Util::logMsg while holding that lock, as logmsg locks, too!
	sysopen( DATAFILE, "$C->{event_log}", O_WRONLY | O_APPEND | O_CREAT )
		or push( @problems, "Cannot open $C->{event_log}: $!" );
	flock( DATAFILE, LOCK_EX )
		or push( @problems, "Cannot lock $C->{event_log}: $!" );
	&NMISNG::Util::enter_critical;

	# it's possible we shouldn't write if we can't lock it...
	print DATAFILE "$time,$node_name,$event,$level,$element,$details\n";
	close(DATAFILE) or push( @problems, "Cannot close $C->{event_log}: $!" );
	&NMISNG::Util::leave_critical;
	NMISNG::Util::setFileProtDiag( file => $C->{event_log} );    # set file owner/permission, default: nmis, 0775

	if (@problems)
	{
		my $msg = join( "\n", @problems );
		NMISNG::Util::logMsg("ERROR $msg");
		return $msg;
	}
	return undef;
}

# return nmisng object for this object
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

1;
