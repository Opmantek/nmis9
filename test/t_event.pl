#!/usr/bin/perl
#
## $Id: t_summary.pl,v 1.1 2012/01/06 07:09:38 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

#
use strict;
use Carp;
use Test::More;
use Test::Deep;
use Data::Dumper;

use NMISNG;
use NMISNG::Util;

use Compat::NMIS;
Compat::NMIS::new_nmisng;

my %nvp   = %{NMISNG::Util::get_args_multi(@ARGV)};

# Allow testing of proposed fix for Event Load():
if($nvp{TEST_PROPOSED_LOAD_FIX}){$NMISNG::Event::TEST_PROPOSED_LOAD_FIX=1;}

my $C     = NMISNG::Util::loadConfTable();
my $debug = $nvp{debug};

my $logfile = $C->{'<nmis_logs>'} . "/t_event.log";
my $logger  = NMISNG::Log->new(
	level => $debug // $C->{log_level},
	path => ( $debug ? undef : $logfile ),
);

# allow for instantiating a test collection in our $db for running tests
# in a hashkey named 'tests' passed as arg to NMISNG->new()
# by appending "_test_collection" to the subkey representing the NMISNG collection we want to test:
my $nmisng_args->{tests}{events_test_collection} = "events_test";
my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
	tests  => $nmisng_args->{tests},
);

my $nodes = $nmisng->get_nodes_model( sort => {node_name => 1} );

# Code Node
confess "I need at least 3 existing nodes to run" if ( $nodes->count < 3 );
my $node_core = $nodes->object(0);
my $node_dist = $nodes->object(1);
my $node_acc  = $nodes->object(2);

my $S = NMISNG::Sys->new();
$S->init(name => $node_core->name, snmp => 'false');

$node_core->eventsClean("t_event");
# for this test to pass, and purely in test environment where cluster_id is hardcoded in test/conf/Config.nmis,
#	we must provide our hardcoded test/conf/Config.nmis cluster_id
# alternatively, we would need to change NMISNG::Node::get_events_model()
#	to default to NMISNG::config->{cluster_id} rather than NMISNG::Node::cluster_id()
my $eventmodel = $node_core->get_events_model( filter => { historic => 0, cluster_id => $C->{cluster_id} });
is($eventmodel->error, undef, "events lookup doesn't fail");
is($eventmodel->count, 0, "node being tested starts with no events");

my $event_val1 = 'Node Down';
my $event_val2 = 'Node Up';
my $event1 = NMISNG::Event->new( nmisng => $nmisng, node_uuid => $node_core->uuid, event => $event_val1, context => "test");
is( $event1->event, $event_val1, "object has correct event value" ) or diag( $event1->event );
isnt( $event1, undef, "Able to create node object using sane arguments" );
is( $event1->id,     undef, "New object has no id" );
is( $event1->is_new, 1,     "New object thinks it's new" );
is( $event1->event, $event_val1, "object has correct event value" ) or diag( $event1->event );
is( $event1->load(),   undef, "attempt to load the event from db does not cause an error" );
is( $event1->exists, 0,     "event does not exist in db" );

# save
# OMK-6462
# calling $event1->validate() before $event1->save() is redundant as $event1->save() does call $event1->validate()
#	and returns an error caught in that test on being found invalid
my $error = $event1->save();
is( $error, undef, "saving event works and returns no error" ) or diag(Dumper($error));
# calling $event1->validate() after $event1->save() is redundant as $event1->save() does call $event1->validate()
#	and returns an error caught in that test on being found invalid
# however, to be safe ...
( my $valid, $error ) = $event1->validate();
is( $valid, 1, "event is valid" );
is( $event1->active,   1, "event is active" );
is( $event1->historic, 0, "event is not historic" );

# verify that save as worked
my $id = $event1->id();
isnt( $id, undef, "saved event has id" );
is( $event1->is_new, 0, "event is no longer new" );
is( $event1->exists, 1, "event now reports it's existence" );

# we must provide our hardcoded test/conf/Config.nmis cluster_id
$eventmodel = $nmisng->events->get_events_model( filter => { _id => $id, cluster_id => $C->{cluster_id} } );
is( $eventmodel->error, undef, "getting model returns no error" ) or diag( Dumper( $eventmodel->error ) );
is( $eventmodel->count(),            1,   "after event is deleted it can't be found any more" );
is( $eventmodel->data()->[0]->{_id}, $id, "id matches" );

# test changing the event value
is( $event1->event($event_val2), $event_val1, "calling and setting event returns old value");
is( $event1->event, $event_val2, "setting new event value actually does its job");
is( $event1->event_previous, $event_val1, "setting new event value makes old value previous value");
$event1->event($event_val1);

# test updating
$error = $event1->save();
isnt( $error, undef, "updating event that is stateless should not work" );
$event1->stateless(1);
$error = $event1->save();
is( $error, undef, "updating event that is not stateless should work" ) or diag(Dumper($error));
# verify updating works
my $event2 = NMISNG::Event->new( nmisng => $nmisng, node_uuid => $node_core->uuid, event => $event_val2, context => "test load");
is( $event2->load(only_take_missing => 1), undef, "loading event with previous event value still finds the event");
# This test is silly.
#is( $event2->id, $id, "loaded event should be the same event");
is( $event2->context, "test load", "when only_take_missing is set existing values should not be overwritten");
is( $event2->event, $event_val2, "when only_take_missing is set existing values should not be overwritten");
is( $event2->load(force => 1, only_take_missing => 0), undef, "loading event with force and not only_take_missing brings in all values");
# This test is silly.
#cmp_deeply($event2->{data},$event1->{data}, "two event objects data should be identical");

# test acknowledge and check event, this could use more, no proactive or alert checks at all
my $event3 = NMISNG::Event->new( nmisng => $nmisng, node_uuid => $node_core->uuid, event => $event_val1 );
is( $event3->acknowledge( ack => 1, user => 'testuser' ), undef, "acknowledge returns no error");
is( $event3->logged, 1, "event got logged");
is( $event3->ack, 1, "event is now acknowledged");
is( $event3->user, 'testuser', 'acknowledge set the user');
$event3->check(sys => $S);
isnt( $event3->event, $event_val1, "event value should go from down->up");
isnt( $event3->active, 1, "event should now be inactive");
is( $event3->level, 'Normal', "event should now be at normal level");
is( $event3->logged, 2, "event got logged again");

# custom_data
$event3->custom_data('custom_key', 'value');
is( $event3->custom_data('custom_key'), 'value', 'custom_data returns value set');

# level and previous_level saved
$error = $event3->save();
is( $error, undef, "saving event works and returns no error" ) or diag(Dumper($error));
# returning 'previous_level' when setting 'level' mimics behaviour for 'sub event' from which 'sub level' derives:
#		this behavior for 'sub level' has no functional purpose as yet.
is( $event3->level('Major'), 'Normal', "calling and setting event level returns previous_value");
is( $event3->level, 'Major', "event should now be at major level");
is( $event3->level_previous, 'Normal', "event should now be at normal previous_level");
$event3->stateless(0);
$error = $event3->save(update => 1);
is( $error, undef, "updating event that is not stateless should work with 'update => 1'" ) or diag(Dumper($error));

# level and previous_level load
$event2->event($event3->event);
is( $event2->load(force => 1, only_take_missing => 0), undef, "loading event with force and not only_take_missing brings in all values");
# This test is silly.
#cmp_deeply($event3->{data},$event2->{data}, "two event objects data should be identical");

# delete, which should set historic flag
$C->{"keep_event_history"} = 'true';
is( $event1->delete(), undef, "deleting event with history sets it to be historic" );
is( $event1->historic, 1, "event is now historic" );
# force a reload to ensure that the historic flag made it to the db
$event1->load(1);
is( $event1->historic, 1, "event is still historic" );

$C->{"keep_event_history"} = 'false';
is( $event1->delete(), undef, "deleting event with no history removes it completely and error free" );

# we must provide our hardcoded test/conf/Config.nmis cluster_id
$eventmodel = $nmisng->events->get_events_model( filter => { _id => $id, cluster_id => $C->{cluster_id} } );
is( $eventmodel->error, undef, "getting model returns no error" ) or diag( Dumper( $eventmodel->error ) );
is( $eventmodel->count(), 0, "after event is deleted it can't be found any more" );

# Validate function getLogLevel
my ( $level, $log, $syslog );
my $event_val4 = 'Proactive';
my $event4 = NMISNG::Event->new( nmisng => $nmisng, node_uuid => $node_core->uuid, event => $event_val4, context => "test");
my ( $level, $log, $syslog ) = $event4->getLogLevel(sys => $S, event => $event4, level => "Major");

print "\n";
print "This test was run with argument 'TEST_PROPOSED_LOAD_FIX=".($nvp{TEST_PROPOSED_LOAD_FIX}//0)."'\n";
print "This test will only pass all tests with argument 'TEST_PROPOSED_LOAD_FIX=1:'\n";
done_testing();
