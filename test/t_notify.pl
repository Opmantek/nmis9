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

use NMISNG::Util;
use Compat::NMIS;
use Compat::Timing;

my %nvp = %{ NMISNG::Util::get_args_multi(@ARGV) };

# Allow testing of proposed fix for Event Load():
if($nvp{TEST_PROPOSED_LOAD_FIX}){$NMISNG::Event::TEST_PROPOSED_LOAD_FIX=1;}

my $C = NMISNG::Util::loadConfTable();
$C->{debug} = $nvp{debug};

my $t = Compat::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";

# allow for instantiating a test collection in our $db for running tests
# in a hashkey named 'tests' passed as arg to Compat::NMIS::new_nmisng()
# by appending "_test_collection" to the subkey representing the NMISNG collection we want to test:
my $nmisng_args->{tests}{events_test_collection} = "events_test";
my $nmisng = Compat::NMIS::new_nmisng(%$nmisng_args);
$C = $nmisng->config();

# pingonly nodes are not good for this
my $nodes = $nmisng->get_nodes_model( filter => { "activated.NMIS" => 1,
												  "configuration.collect" => 1 },
												  sort => { node_name => 1 });

confess "I need at least 3 existing active nodes to run" if ($nodes->count < 3);
my $node_core = $nodes->object(0);
my $node_dist = $nodes->object(1); # fixme: need node with interfaces!
my $node_acc = $nodes->object(2);
diag("picked corenode ".$node_core->name
		 .", distnode ".$node_dist->name.", accnode ".$node_acc->name);

# chose an active (collected) interface to mark down,
# a nocollect one will make the counts not work
# as the events won't be raised
my $ret = $node_dist->get_inventory_model(
	filter => {concept => 'interface', enabled => 1},
	class_name => NMISNG::Inventory::get_inventory_class("interface") );

confess("I need at least one collected interface for "
				.$node_dist->name. " to run") if (!$ret->count);
my $chosen_intf = $ret->object(0);

# clear all events for nodes we are going to use
$node_core->eventsClean();

# for this test to pass, and purely in test environment where cluster_id is hardcoded in test/conf/Config.nmis,
#	we must provide our hardcoded test/conf/Config.nmis cluster_id
# alternatively, we would need to change NMISNG::Node::get_events_model()
#	to default to NMISNG::config->{cluster_id} rather than NMISNG::Node::cluster_id()
my $eventmodel = $node_core->get_events_model( filter => { historic => 0, cluster_id => $C->{cluster_id} });
is($eventmodel->error, undef, "events lookup doesn't fail");
is($eventmodel->count, 0, "node being tested starts with no events");

$node_dist->eventsClean();

# for this test to pass, and purely in test environment where cluster_id is hardcoded in test/conf/Config.nmis,
#	we must provide our hardcoded test/conf/Config.nmis cluster_id
# alternatively, we would need to change NMISNG::Node::get_events_model()
#	to default to NMISNG::config->{cluster_id} rather than NMISNG::Node::cluster_id()
$eventmodel = $node_dist->get_events_model( filter => { historic => 0, cluster_id => $C->{cluster_id} });
is($eventmodel->error, undef, "events lookup doesn't fail");
is($eventmodel->count, 0, "node being tested starts with no events");

$node_acc->eventsClean();

# for this test to pass, and purely in test environment where cluster_id is hardcoded in test/conf/Config.nmis,
#	we must provide our hardcoded test/conf/Config.nmis cluster_id
# alternatively, we would need to change NMISNG::Node::get_events_model()
#	to default to NMISNG::config->{cluster_id} rather than NMISNG::Node::cluster_id()
$eventmodel = $node_acc->get_events_model( filter => { historic => 0, cluster_id => $C->{cluster_id} });
is($eventmodel->error, undef, "events lookup doesn't fail");
is($eventmodel->count, 0, "node being tested starts with no events");

# make one node go down twice
nodeDown($node_dist->name,1);
nodeDown($node_dist->name,1);
intDown($node_dist->name,$chosen_intf,1);
nodeDown($node_acc->name,1);

# make one node flap, we need to make sure this re-uses the non-escalated event and not
# create a second one
nodeDown($node_core->name,1);
nodeUp($node_core->name,2);
nodeDown($node_core->name,3);

# do the same alert twice, should only log once
# FIXME: this cannot work on nodes that haven't been collected successfully, because getlogLevel requires
# a non-default model for the node (or notify will never log() the event, thus logged() will never be true)
my $alert_fixme = " ALERT_FIXME: this cannot work on nodes that haven't been collected successfully, because getlogLevel requires \n"
			      . "a non-default model for the node (or notify will never log() the event, thus logged() will never be true).\n";
alertStart($node_core->name,1,$alert_fixme);
alertStart($node_core->name,1,$alert_fixme);

# verify that we have created 4 new events that are all active
my $uuids = [$node_core->uuid,$node_dist->uuid,$node_acc->uuid];
# we must provide our hardcoded test/conf/Config.nmis cluster_id
my $events = $nmisng->events->get_events_model( filter => { node_uuid => $uuids, active => 1, cluster_id => $C->{cluster_id} });
is ($events->error,undef, "Event lookup succeeded");
is( $events->count, 5, "Count of events created is correct") or diag("wrong count".Dumper($events->data));

$nmisng->process_escalations;

print "\n############ Sleep now\n\n";
sleep 5;
print "\n############ AWAKE\n\n";

nodeUp($node_core->name,4);
nodeUp($node_dist->name,2);
intUp($node_dist->name,$chosen_intf,2);
nodeUp($node_acc->name,2);

alertEnd($node_core->name,2,$alert_fixme);

# we must provide our hardcoded test/conf/Config.nmis cluster_id
$events = $nmisng->events->get_events_model( filter => { node_uuid => $uuids, active => 0, historic => 0, cluster_id => $C->{cluster_id} });
is ($events->error,undef, "Event lookup succeeded");
is( $events->count, 5, "Count of events waiting for escalation is correct")  or diag("wrong count".Dumper($events->data));

# we must provide our hardcoded test/conf/Config.nmis cluster_id
$events = $nmisng->events->get_events_model( filter => { node_uuid => $uuids, active => 0, historic => 1, cluster_id => $C->{cluster_id} });
is ($events->error,undef, "Event lookup succeeded");

my $prescalate_count = $events->count;

$nmisng->process_escalations;

# we must provide our hardcoded test/conf/Config.nmis cluster_id
$events = $nmisng->events->get_events_model( filter => { node_uuid => $uuids, active => 0, historic => 1, cluster_id => $C->{cluster_id} });
is ($events->error,undef, "Event lookup succeeded");
my $process_escalations_fixme = " PROCESS_ESCALATIONS_FIXME: this test does not increment the count by 5 as the test intends.\n";
is( $events->count, $prescalate_count + 5, "Count of events that are now historic is correct$process_escalations_fixme");

print $t->elapTime(). " End\n";
print "\n";
print "*** ALERT_FIXME always causes 3 test failures and PROCESS_ESCALATIONS_FIXME causes 1 failure - expect 4 failures in total. ***\n\n";

print "This test was run with argument 'TEST_PROPOSED_LOAD_FIX=".($nvp{TEST_PROPOSED_LOAD_FIX}//0)."'\n";
print "This test will fail more tests with argument 'TEST_PROPOSED_LOAD_FIX=0:'\n";
done_testing();

sub nodeDown {
	my $node = shift;
	my $logged = shift;

	print $t->elapTime(). " nodeDown Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');

	print $t->elapTime(). " nodeDown(): Load Some Data\n";
	my $NI = $S->{info};
	my $catchall_inventory = $S->inventory( concept => 'catchall' );

	Compat::NMIS::notify(sys=>$S,event=>"Node Down",element=>"",details=>"Ping failed", inventory_id => $catchall_inventory->id);
	# call notify twice, make sure we don't get logged twice
	my $event = $nmisng->events->event( node_uuid => $S->nmisng_node->uuid, event=>"Node Down", element=>"");
	if( my $error = $event->load() )
	{
		print "ERRor:$error\n";
	}
	is( $event->logged, $logged, "event was logged once" ) if($logged);

	print $t->elapTime(). " nodeDown done\n";
}

sub nodeUp {
	my $node = shift;
	my $logged = shift;

	print $t->elapTime(). " nodeUp Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');

	print $t->elapTime(). " nodeUp(): Load Some Data\n";
	my $NI = $S->{info};
	my $catchall_inventory = $S->inventory( concept => 'catchall' );

	my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"Node Down",level=>"Normal",element=>"",details=>"Ping failed", inventory_id => $catchall_inventory->id);
	my $event = $nmisng->events->event( node_uuid => $S->nmisng_node->uuid, event=>"Node Down", element=>"");
	if( my $error = $event->load() )
	{
		print "ERRor:$error\n";
	}
	is( $event->logged, $logged, "event was logged once" ) if($logged);

	print "checkEvent Result: $result\n";

	print $t->elapTime(). " nodeUp done\n";
}

sub intDown {
	my $node = shift;
	my $chosen_intf = shift;

	print $t->elapTime(). " intDown Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');

	print $t->elapTime(). " intDown(): Load Some Data\n";

	Compat::NMIS::notify(sys=>$S,event=>"Interface Down",element=>$chosen_intf->ifDescr,details=>$chosen_intf->Description, inventory_id => $chosen_intf->id );

	print $t->elapTime(). " intDown done\n";
	return $chosen_intf;
}

sub intUp {
	my $node = shift;
	my $chosen_intf = shift;

	print $t->elapTime(). " intUp Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');

	print $t->elapTime(). " intUp(): Load Some Data\n";
	my $NI = $S->{info};

	my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"Interface Down",level=>"Normal",element=>$chosen_intf->ifDescr,details=>$chosen_intf->Description, inventory_id => $chosen_intf->id );
	print "checkEvent Result: $result\n";

	print $t->elapTime(). " intUp done\n";
}


sub alertStart {
	my $node = shift;
	my $logged = shift;
	my $fixme_msg = shift // "";

	print $t->elapTime(). " alertStart Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');

	print $t->elapTime(). " alertStart(): Load Some Data\n";
	my $NI = $S->{info};
	# alerts need level set
	Compat::NMIS::notify(sys=>$S,event=>"Alert: fake alert event",element=>"",details=>"t_notify.pl", level => "Warning");
	# call notify twice, make sure we don't get logged twice
	my $event = $nmisng->events->event( node_uuid => $S->nmisng_node->uuid, event=>"Alert: fake alert event", element=>"", level => "Warning");
	if( my $error = $event->load() )
	{
		print "Error:$error\n";
	}
	is( $event->logged, $logged, "event was logged once$fixme_msg" ) if($logged);

	print $t->elapTime(). " nodeDown done\n";
}

sub alertEnd {
	my $node = shift;
	my $logged = shift;
	my $fixme_msg = shift // "";

	print $t->elapTime(). " alertEnd Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');

	print $t->elapTime(). " alertEnd(): Load Some Data\n";
	my $NI = $S->{info};

	my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"Alert: fake alert event",element=>"",details=>"t_notify.pl");

	my $event = $nmisng->events->event( node_uuid => $S->nmisng_node->uuid, event=>"Alert: fake alert event", element=>"" );
	if( my $error = $event->load() )
	{
		print "Error:$error\n";
	}
	is( $event->logged, $logged, "event was logged once$fixme_msg" ) if($logged);

	print "checkEvent Result: $result\n";

	print $t->elapTime(). " alertEnd done\n";
}
