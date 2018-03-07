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

package NMISNG::Event;
use strict;

use Carp;
use Data::Dumper;
use Test::Deep::NoTest;

our $VERSION = "1.0.0";

# params: all properties desired in the node, minimum is
#  either _id or  node_name,event,[element] are required to
#  have a minimal object which can load/look for itself
# note: this used to specifiy all the attributes in the event
# but there are places that put data into the event willy/nilly
# custom_data has been added to set this

# sys not required as argument but can't be left in the args
# here is a list of the known attributes, these will be givent getter/setters, everything else is 'custom_data'
my %known_attrs = (
	_id            => 1,
	ack            => 1,
	active         => 1,
	cluster_id     => 1,
	context        => 1,
	details        => 1,
	element        => 1,
	escalate       => 1,
	event_previous => 1,
	expire_at      => 1,
	historic       => 1,
	inventory_id   => 1,
	lastupdate     => 1,
	level          => 1,
	logged         => 1,
	node_name      => 1,
	node_uuid      => 1,
	notify         => 1,
	startdate      => 1,
	stateless      => 1,
	user           => 1
);

sub new
{
	my ( $class, %args ) = @_;
	confess "nmisng required" if ( ref( $args{nmisng} ) ne "NMISNG" );

	# need enough data to find this in the db, if we don't have that complain
	if ( !$args{_id} && ( !$args{node_uuid} && !$args{event} ) )
	{
		confess
			"not enough info to create an event, id:$args{_id}, node_uuid:$args{node_uuid}, event:$args{event},element:$args{element}";
	}

	my ( $nmisng, $S ) = @args{'nmisng', 'sys'};
	delete $args{nmisng};
	delete $args{sys};

	# note: defautls are not set here, they are done on save so that loading with only_take_missing doesn't get taken
	#   by values that were set for you
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
# if filter_active => 0 then don't add "active" to the filter
sub _query
{
	my ( $self, $filter_active ) = @_;
	my $q;

	if ( $self->{data}{_id} )
	{
		$q = NMISNG::DB::get_query( and_part => {_id => $self->{data}{_id}} );
	}
	elsif ( !$q )
	{
		$q = NMISNG::DB::get_query(
			and_part => {
				node_uuid => $self->{data}{node_uuid},
				element   => $self->{data}{element},

				# can't use inventory for querying until it's uniform everywhere
				# inventory_id => $self->{data}{inventory_id},
				active   => $self->{data}{active}   // 1,
				historic => $self->{data}{historic} // 0
			}
		);
		delete $q->{active} if ( !$filter_active );

		# find the event value in either event or event_previous (so that Up/Down events can find each other)
		$q = {'$and' => [$q, {'$or' => [{event => $self->{data}{event}}, {event_previous => $self->{data}{event}},]}]};
	}

	return $q;
}

## this function (un)acknowledges an existing event
# if configured to it also (event-)logs the activity
#
# args: node, event, element, level, details, ack, user;
# returns: undef if ok, error message otherwise
# quick way of acking the event, saved immediately
sub acknowledge
{
	my ( $self, %args ) = @_;
	my $ack  = $args{ack};
	my $user = $args{user};

	my $events_config = NMISNG::Util::loadTable( dir => 'conf', name => 'Events' );

	# just in case someone decided to give us true/false
	$ack = NMISNG::Util::getbool($ack);

	# event control for logging:  as configured or default true, ie. only off if explicitely configured off.
	my $wantlog = (
		       !$events_config
			or !$events_config->{$self->event}
			or !getbool( $events_config->{$self->event}->{Log}, "invert" )
	) ? 1 : 0;

	# events are only acknowledgeable while they are current (ie. not in the process of
	# being deleted)!
	if ( my $error = $self->load() )
	{
		NMISNG::Util::logMsg( "ERROR cannot find event id:" . $self->_id );
		return "cannot find event id:" . $self->_id;
	}
	return if ( !$self->active );

	### if a TRAP type event, then trash when ack. event record will be in event log if required
	if ( $ack and !$self->ack and $self->event eq "TRAP" )
	{
		if ( my $error = $self->delete() )
		{
			NMISNG::Util::logMsg("ERROR: $error");
		}
		$self->log(
			event => "deleted event: " . $self->event,
			level => "Normal",
		) if ($wantlog);
	}
	else    # a 'normal' event
	{
		# nothing to do if requested ack and saved ack the same...
		if ( $ack != $self->ack )
		{
			$self->ack($ack);
			$self->user($user);
			if ( my $error = $self->save( update => 1 ) )
			{
				NMISNG::Util::logMsg("ERROR: $error");
			}

			$self->log(
				level   => "Normal",
				details => "acknowledge=$ack ($user)"
			) if $wantlog;
		}
	}
	return;
}

# Check event is called after determining that something is back up!
# Check event checks if the given event exists - so the object should have
# properties for the down event
# if it exists it deletes it from the event state table/log
#
# and then calls notify with a new Up event including the time of the outage
# args: a LIVE sys object for the node
#  details and level are optional, if provided override what is in the event
#
# returns: nothing
sub check
{
	my ( $self, %args ) = @_;
	my $S = $args{sys};

	# cause this thing to load itself with
	my $exists = $self->exists();

	my $nmisng = $self->nmisng;

	my $details = $args{details} // $self->details;
	my $level   = $args{level}   // $self->level;

	my ( $log, $syslog );

	my $C = $self->nmisng->config;

	# events.nmis controls which events are active/logging/notifying
	# cannot use loadGenericTable as that checks and clashes with db_events_sql
	my $events_config = NMISNG::Util::loadTable( dir => 'conf', name => 'Events' );
	my $thisevent_control = $events_config->{$self->event} || {Log => "true", Notify => "true", Status => "true"};

	# set defaults just in case any are blank.
	$C->{'non_stateful_events'}               ||= 'Node Configuration Change, Node Reset';
	$C->{'threshold_falling_reset_dampening'} ||= 1.1;
	$C->{'threshold_rising_reset_dampening'}  ||= 0.9;

# it would be nice to have every entry have an inventory_id, but that's not happening right now
# $self->nmisng->log->debug("check got element:".$self->element." but no inventory id") if ( $self->element && !$self->inventory_id );

	# check if the event exists and load its details
	if ( $exists && $self->active )
	{
		# a down event exists, so log an UP and delete the original event
		my $new_event;

		# cmpute the event period for logging
		my $outage = NMISNG::Util::convertSecsHours( time() - $self->startdate );

		# Just log an up event now.
		if ( $self->event eq "Node Down" )
		{
			$new_event = "Node Up";
		}
		elsif ( $self->event eq "Interface Down" )
		{
			$new_event = "Interface Up";
		}
		elsif ( $self->event eq "RPS Fail" )
		{
			$new_event = "RPS Up";
		}
		elsif ( $self->event =~ /Proactive/ )
		{
			my ( $value, $reset ) = @args{"value", "reset"};
			if ( defined $value and defined $reset )
			{
				# but only if we have cleared the threshold by 10%
				# for thresholds where high = good (default 1.1)
				# for thresholds where low = good (default 0.9)
				my $cutoff = $reset * (
					  $value >= $reset
					? $C->{'threshold_falling_reset_dampening'}
					: $C->{'threshold_rising_reset_dampening'}
				);

				if ( $value >= $reset && $value <= $cutoff )
				{
					NMISNG::Util::info(
						"Proactive Event value $value too low for dampening limit $cutoff. Not closing.");
					return;
				}
				elsif ( $value < $reset && $value >= $cutoff )
				{
					NMISNG::Util::info(
						"Proactive Event value $value too high for dampening limit $cutoff. Not closing.");
					return;
				}
			}
			$new_event = $self->event . " Closed";
		}
		elsif ( $self->event =~ /^Alert/ )
		{
			# A custom alert is being cleared.
			$new_event = $self->event . " Closed";
		}
		elsif ( $self->event =~ /down/i )
		{
			$new_event =~ s/down/Up/i;
		}
		elsif ( $self->event =~ /\Wopen($|\W)/i )
		{
			$new_event =~ s/(\W)open($|\W)/$1Closed$2/i;
		}

		# event was renamed/inverted/massaged, need to get the right control record
		# this is likely not needed
		$thisevent_control = $events_config->{$new_event} || {Log => "true", Notify => "true", Status => "true"};

		$details .= ( $details ? " " : "" ) . "Time=$outage";

		( $level, $log, $syslog ) = $self->getLogLevel( sys => $S, event => $new_event, level => 'Normal' );

		my ( $otg, $outageinfo ) = NMISNG::Outage::outageCheck( node => $S->nmisng_node, time => time() );
		if ( $otg eq 'current' )
		{
			$details .= ( $details ? " " : "" ) . "outage_current=true change=$outageinfo->{change_id}";
		}

		# tell this event that it's no longer active (but not yet historic, runEscalate does that)
		$self->active(0);    # next processing by escalation routine
		$self->event($new_event);
		$self->details($details);
		$self->level($level);

		NMISNG::Util::dbg( "event node_name="
				. $self->node_name
				. ", event="
				. $self->event
				. ", element="
				. $self->element
				. " marked for UP notify and delete" );
		if ( NMISNG::Util::getbool($log) and NMISNG::Util::getbool( $thisevent_control->{Log} ) )
		{
			$self->log();
		}

		if ( my $error = $self->save() )
		{
			NMISNG::Util::logMsg("ERROR $error");
			confess $error;
		}

		# Syslog must be explicitly enabled in the config and will escalation is not being used.
		if (    NMISNG::Util::getbool( $C->{syslog_events} )
			and NMISNG::Util::getbool($syslog)
			and NMISNG::Util::getbool( $thisevent_control->{Log} )
			and !NMISNG::Util::getbool( $C->{syslog_use_escalation} ) )
		{
			NMISNG::Notify::sendSyslog(
				server_string => $C->{syslog_server},
				facility      => $C->{syslog_facility},
				nmis_host     => $C->{server_name},
				time          => time(),
				node          => $S->{name},
				event         => $new_event,
				level         => $level,
				element       => $self->element,
				details       => $details
			);
		}
	}
}

sub custom_data
{
	my ( $self, $key, $newvalue ) = @_;
	my $current = $self->{data}{$key};
	if ( @_ == 3 )
	{
		$self->{data}{$key} = $newvalue;
	}
	return $current;
}

# a way to access the internal data, this should not be used if possible
# it's here so existing code that's expecting a node to be a hash can have it's hash
sub data
{
	my ($self) = @_;
	return $self->{data};
}

# this will either delete the event or mark it as historic and set the expire_at
#
sub delete
{
	my ($self) = @_;

	my $ret;
	my $q = $self->_query();
	if ( !NMISNG::Util::getbool( $self->nmisng->config->{"keep_event_history"}, "invert" ) )
	{
		# mark it inactive/historic, and make it go away eventually
		my $expire_at = $self->nmisng->config->{purge_event_after} // 86400;
		$expire_at = Time::Moment->from_epoch( time + $expire_at );

		$self->historic(1);
		$self->expire_at($expire_at);

		# update the single record, save could be used here, should it?
		my $dbres = NMISNG::DB::update(
			collection => $self->nmisng->events_collection(),
			query      => $q,
			record     => {'$set' => {active => 0, historic => 1, expire_at => $expire_at, lastupdate => time}},
			freeform   => 1
		);
		$ret = "event deactivate failed: $dbres->{error}" if ( !$dbres->{success} );
	}
	else
	{
		my $result = NMISNG::DB::remove(
			collection => $self->nmisng->events_collection,
			query      => $q,
			just_one   => 1
		);
		$ret = "event delete failed: $result->{error}" if ( !$result->{success} );
	}
	$self->nmisng->log->error($ret) if ($ret);
	return $ret;
}

# get the log level for the provided event/level, if not provided it
# will use the internal event/level. this odesn't makea lot of sense
# right now but it's a little helpful during transitioning to event obj
sub getLogLevel
{
	my ( $self, %args ) = @_;
	my ( $S, $event, $level ) = @args{'sys', 'event', 'level'};
	confess "i need a sys" if ( !$S );
	my $M = $S->mdl;
	my $catchall_data = $S->inventory( concept => 'catchall' )->data_live();

	$event //= $self->event;
	$level //= $self->level;

	my $mdl_level;
	my $log    = 'true';
	my $syslog = 'true';
	my $pol_event;

	my $role = $catchall_data->{roleType} || 'access';
	my $type = $catchall_data->{nodeType} || 'router';

	# Get the event policy and the rest is easy.
	if ( $event !~ /^Proactive|^Alert/i )
	{
		# proactive does already level defined
		if ( $event =~ /down/i and $event !~ /SNMP|Node|Interface|Service/i )
		{
			$pol_event = "Generic Down";
		}
		elsif ( $event =~ /up/i and $event !~ /SNMP|Node|Interface|Service/i )
		{
			$pol_event = "Generic Up";
		}
		else { $pol_event = $event; }

		# get the level and log from Model of this node
		if ( $mdl_level = $M->{event}{event}{lc $pol_event}{lc $role}{level} )
		{
			$log    = $M->{event}{event}{lc $pol_event}{lc $role}{logging};
			$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog}
				if ( $M->{event}{event}{lc $pol_event}{lc $role}{syslog} ne "" );
		}
		elsif ( $mdl_level = $M->{event}{event}{default}{lc $role}{level} )
		{
			$log    = $M->{event}{event}{default}{lc $role}{logging};
			$syslog = $M->{event}{event}{default}{lc $role}{syslog}
				if ( $M->{event}{event}{default}{lc $role}{syslog} ne "" );
		}
		else
		{
			$mdl_level = 'Major';

			# not found, use default
			NMISNG::Util::logMsg(
				"node=$catchall_data->{name}, event=$event, role=$role not found in class=event of model=$catchall_data->{nodeModel}"
			);
		}
	}
	elsif ( $event =~ /^Alert/i )
	{
		# Level set by custom!
		### 2013-03-08 keiths, adding policy based logging for Alerts.
		# We don't get the level but we can get the logging policy.
		$pol_event = "Alert";
		if ( $log = $M->{event}{event}{lc $pol_event}{lc $role}{logging} )
		{
			$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog}
				if ( $M->{event}{event}{lc $pol_event}{lc $role}{syslog} ne "" );
		}
	}
	else
	{
		### 2012-03-02 keiths, adding policy based logging for Proactive.
		# We don't get the level but we can get the logging policy.
		$pol_event = "Proactive";
		if ( $log = $M->{event}{event}{lc $pol_event}{lc $role}{logging} )
		{
			$syslog = $M->{event}{event}{lc $pol_event}{lc $role}{syslog}
				if ( $M->{event}{event}{lc $pol_event}{lc $role}{syslog} ne "" );
		}
	}

	# overwrite the level argument if it wasn't set AND if the models reported something useful
	if ( $mdl_level && !defined $level )
	{
		$level = $mdl_level;
	}
	return ( $level, $log, $syslog );
}

# convenience getter for id, returns _id, _id allows setting/getting
sub id
{
	my ($self) = @_;
	return $self->{data}{_id} // undef;
}

# is this thing an alert? there should be a better way to do this, alerts
# should tell us that we are an alert
sub is_alert
{
	my ($self) = @_;
	return ( $self->event =~ /Alert:/i );
}

# returns 0/1 if the object is new or not.
# new means it is not yet in the database
# TODO: potentially this thing should call load first or keep a load
# flag around, as the data may not be loaded which means _id may be
# in the db
sub is_new
{
	my ($self) = @_;
	my $has_id = $self->{data}{_id} // undef;
	return ($has_id) ? 0 : 1;
}

# is this thing proactive? there should be a better way to do this, it
# should tell us that we are proactive
# also note, the nmis code does this in several ways, this is the least
# specific way the check is done
sub is_proactive
{
	my ($self) = @_;
	return ( $self->event =~ /proactive/i );
}

# set/get the name of the event
sub event
{
	my ( $self, $newvalue ) = @_;
	my $current = $self->{data}{event};
	if ( @_ == 2 )
	{
		$self->{data}{event_previous} = $current if ( $newvalue ne $current );
		$self->{data}{event} = $newvalue;
	}
	return $current;
}

# returns if this event exists in the db
# uses whatever data is currently in the object to try
# and load from the db, if found an _id should be loaded which means it exists
sub exists
{
	my ($self) = @_;
	my $exists = 0;
	$self->load();
	$exists = 1 if ( !$self->is_new );
	return $exists;
}

# using existing attributes attempt to load the event from the db
# it only does this if the event has not been loaded before or forced
# args: force - ignore idea that we're already loaded and do it,
#  only_take_missing - when loaded only valued that don't already exist will be
#   brought into the object
# returns undef on success, error message
# currently tracks if it has loaded itself
sub load
{
	my ( $self, %args ) = @_;
	my $force             = $args{force};
	my $only_take_missing = $args{only_take_missing};

	# undef if we are not new and are not forced to check
	return if ( $self->loaded && !$force );

	# don't add active to filter, we want !historic but don't care about active because if one
	# exists that is inactive (but not historic) we want to make that active again if threshold
	# has not run
	my $events_ret = $self->nmisng->events->get_events_model( query => $self->_query(0) );
	my ( $event_in_db, $error, $model_data ) = ( undef, $events_ret->{error}, $events_ret->{model_data} );

	if ( !$error && $model_data->count == 1 )
	{
		$event_in_db = $model_data->data->[0];

		# set our new attributes, if found in db _id is already set
		# keep some copies as well so we can figure out state if we need to
		$self->{_data_from_db}     = {%$event_in_db};
		$self->{_data_before_load} = {%{$self->{data}}};

		foreach my $key ( keys %$event_in_db )
		{
			if ( !$only_take_missing || !defined( $self->$key() ) )
			{
				# use setter/getter if it's defined, otherwise it's 'custom_data'
				if ( defined( $known_attrs{$key} ) )
				{
					$self->$key( $event_in_db->{$key} );
				}
				else
				{
					$self->custom_data( $key, $event_in_db->{$key} );
				}
			}
		}
		$self->loaded(1);
	}
	elsif ( !$error && $model_data->count > 1 )
	{
		# error, this function is for a single event, finding >1 is an issue
		$error = "more than one event found when a single event was expected, ids:"
			. join( ",", map { $_->{_id} } @{$model_data->data} );
	}

	return $error;
}

sub loaded
{
	my ( $self, $newvalue ) = @_;
	my $current = $self->{_loaded};
	if ( @_ == 2 )
	{
		$self->{_loaded} = $newvalue;
	}
	return $current;
}

# log this event to the event log, any arugments provided will override what is in this object
# internally track if we've been logged, this is not saved, perhaps it's useful? one issue:
# event can be logged without using the object
sub log
{
	my ( $self, %args ) = @_;
	$self->logged( $self->logged() + 1 );
	return $self->nmisng->events->logEvent(
		node_name => $args{node_name} // $self->node_name,
		event     => $args{event}     // $self->event,
		element   => $args{element}   // $self->element,
		level     => $args{level}     // $self->level,
		details   => $args{details}   // $self->details
	);
}

# return nmisng object for this object
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# save this thing, will be created in db if it does
# not already exist
# args: update -> set to 1 when the event is just being updated, not trying
#. to do anything like add an event, save(update=>1) == eventUpdate,
#. save(update=>0) == eventAdd
# returns undef on success, error otherwise
sub save
{
	my ( $self,  %args )  = @_;
	my ( $valid, $error ) = $self->validate();
	return $error if ( !$valid );

	# set update when you want to skip the logic that came from eventAdd
	my $update = $args{update};

	# we must load to find out if this thing exists, if the first load of this object
	# is happening this late we assume that the caller does not want to clobber all the
	# attributes that are now set so only take on the missing ones, this seems like the
	# least
	$self->load( only_take_missing => 1 );
	my $exists = $self->exists();

	# is this an already EXISTING stateless event?
	# they will reset after the dampening time, default dampen of 15 minutes.
	if ( !$update )
	{
		if ( $exists && $self->stateless )
		{
			my $stateless_event_dampening = $self->nmisng->config->{stateless_event_dampening} || 900;

			# if the stateless time is greater than the dampening time, reset the escalate.
			if ( time() > $self->startdate + $stateless_event_dampening )
			{
				$self->active(1);
				$self->historic(0);
				$self->startdate(time);
				$self->escalate(-1);
				$self->ack(0);

				# $self->context( ||= $args{context});
				my ( $node_name, $event, $level, $element, $details )
					= @{$self->{data}}{'node_name', 'event', 'level', 'element', 'details'};
				NMISNG::Util::dbg(
					"event stateless, node=$node_name, event=$event, level=$level, element=$element, details=$details");
			}
		}

		# before we log, check the state if there is an event and if it's current
		elsif ( $exists && $self->active && $self->was_active )
		{
			my ( $node_name, $event, $level, $element, $details )
				= @{$self->{data}}{'node_name', 'event', 'level', 'element', 'details'};
			NMISNG::Util::dbg(
				"event exists, node=$node_name, event=$event, level=$level, element=$element, details=$details");
			NMISNG::Util::logMsg(
				"ERROR cannot add event=$event, node=$node_name: already exists, is current and not stateless!");
			$error = "cannot add event: already exists, is current and not stateless!";
		}
		else
		{
			# doesn't exist or isn't current
			# fixme: existing but not current isn't cleanly handled here
			# set defaults
			$self->{data}{active}    //= 1;
			$self->{data}{historic}  //= 0;
			$self->{data}{startdate} //= time;
			$self->{data}{ack}       //= 0;
			$self->{data}{escalate}  //= -1;

			# Does this really need to be "" ?
			$self->{data}{notify}    //= "";
			$self->{data}{stateless} //= 0;

			# set clusterid
			$self->{data}{cluster_id} = $self->nmisng->config->{cluster_id};
			$self->{data}{logged} //= 0;
		}
	}

	if ( !$error )
	{
		$self->{_lastupdate} = time;
		my $q = $self->_query;

		# this will update/insert a single record

		# don't try and update the id and don't let it be there to be set to undef either
		my %data = %{$self->data};
		delete $data{_id};

		my $dbres = NMISNG::DB::update(
			collection => $self->nmisng->events_collection(),
			query      => $q,
			record     => \%data,
			upsert     => 1
		);

		$error = $dbres->{error} if ( !$dbres->{success} );
		if ( $dbres->{upserted_id} )
		{
			$self->{data}{_id} = $dbres->{upserted_id};
			$self->nmisng->log->debug1(
				"Created new event $data{event} $dbres->{upserted_id} for node $data{node_name}");
		}

		# now that we've updated the db, update what we think is in the db
		$self->{_data_from_db} = {%data};
	}
	return $error;
}

# returns (1,nothing) if the node configuration is valid,
# (negative or 0, explanation) otherwise
sub validate
{
	my ($self) = @_;

	# return (-2, "node requires cluster_id") if ( !$self->{cluster_id} );
	# for my $musthave (qw(name host group))
	# {
	# 	return (-1, "node requires $musthave property") if (!$configuration->{$musthave} ); # empty or zero is not ok
	# }

	# # note: if ths is changed to be stricter, then sub rename needs to be changed as well!
	# # '/' is one of the few characters that absolutely cannot work as node name (b/c of file and dir names)
	# return (-1, "node name contains forbidden character '/'") if ($configuration->{name} =~ m!/!);

	# return (-3, "given netType is not a known type")
	# 		if (!grep($configuration->{netType} eq $_,
	# 							split(/\s*,\s*/, $self->nmisng->config->{nettype_list})));
	# return (-3, "given roleType is not a known type")
	# 		if (!grep($configuration->{roleType} eq $_,
	# 							split(/\s*,\s*/, $self->nmisng->config->{roletype_list})));
	return ( 1, undef );
}

# tries to figure out if this event was active, only good from the last
# save point, only used in one spot, when event down, then up, then back down
# without ever having an escalate run
sub was_active
{
	my ($self) = @_;
	return $self->{_data_from_db}{active} if ( $self->exists );
	return;
}

1;
