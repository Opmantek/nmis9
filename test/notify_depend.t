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

# Test attempts to make sure the depend setting in a nodes configuration is working
# one node1 depend => node2 means that if node1 and node2 both go down escalations
# should only run for node2.
# this test does this: node_dist & node_acc depend on node_core
#   node_extra depend on node_dist

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

#
use strict;
use Carp;
use Test::More;
use Test::Deep;
use Data::Dumper;

use t;
use NMISNG::Util;
use Compat::NMIS;
use Compat::Timing;

my %nvp = %{ NMISNG::Util::get_args_multi(@ARGV) };

# Allow testing of proposed fix for Event Load():
if($nvp{TEST_PROPOSED_LOAD_FIX}){$NMISNG::Event::TEST_PROPOSED_LOAD_FIX=1;}

my $dir = my $testdirprefix="$FindBin::Bin/../conf";
my $C = NMISNG::Util::loadConfTable( dir => $dir );
$C->{debug} = $nvp{debug};
my $debug = $nvp{debug};
$C->{db_name} = "nmisng_notify_depend_t_".time;

my $logfile = $C->{'<nmis_logs>'} . "/notify_depend.log";
my $logger  = NMISNG::Log->new(
	level => $debug // $C->{log_level},
	path => ( $debug ? undef : $logfile ),
);

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);

my $EST = NMISNG::Util::loadTable( dir => "conf", name => "Escalations", conf => $C );
my $escalation_backup = $EST->{default_default_default_default__}{Level0};
my $esc0_notify = "email:contact1";
$EST->{default_default_default_default__}{Level0} = $esc0_notify;
if( NMISNG::Util::writeTable(dir=>'conf',name=>"Escalations", data=>$EST) ) {
	print "Failed to adjust Escalations table!\n";
}

my $t = Compat::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";

# allow for instantiating a test collection in our $db for running tests
# in a hashkey named 'tests' passed as arg to Compat::NMIS::new_nmisng()
# by appending "_test_collection" to the subkey representing the NMISNG collection we want to test:
$C = $nmisng->config();

t::prime_nodes(nmisng => $nmisng, synth_nr => 4);

# pingonly nodes are not good for this
my $nodes = $nmisng->get_nodes_model( filter => { "activated.NMIS" => 1,
												  "configuration.collect" => 1 },
												  sort => { node_name => 1 });

cleanup() && confess "I need at least 3 existing active nodes to run" if ($nodes->count < 3);
my $node_core = $nodes->object(0);
my $node_dist = $nodes->object(1);
my $node_acc = $nodes->object(2);
my $node_extra = $nodes->object(3);
diag("picked corenode ".$node_core->name
		 .", distnode ".$node_dist->name.", accnode ".$node_acc->name);

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
nodeDown($node_core->name,1);
nodeDown($node_dist->name,1);
nodeDown($node_acc->name,1);

# verify that we have created 4 new events that are all active
my $uuids = [$node_core->uuid,$node_dist->uuid,$node_acc->uuid];
# we must provide our hardcoded test/conf/Config.nmis cluster_id
my $events = $nmisng->events->get_events_model( filter => { node_uuid => $uuids, active => 1, cluster_id => $C->{cluster_id} });
is ($events->error,undef, "Event lookup succeeded");
is( $events->count, 3, "Count of events created is correct") or diag("wrong count".Dumper($events->data));

$nmisng->process_escalations;

# check to make sure events created and they are all escalating/notifying
foreach my $uuid (@$uuids) 
{
	my $event = $nmisng->events->event( node_uuid => $uuid, event=>"Node Down", element=>"");
	if( my $error = $event->load() )
	{
		print "ERRor:$error\n";
	}
	is( $event->escalate(), 0, "event at escalation 0" );
	is( $event->notify(), $esc0_notify, "event has correct notification" );
}

# now bring all nodes up and clean up for another try with depend values
nodeUp($node_core->name,0);
nodeUp($node_dist->name,0);
nodeUp($node_acc->name,0);

$node_core->eventsClean();
$node_dist->eventsClean();
$node_acc->eventsClean();

$nmisng->process_escalations;

# setup two nodes to be depend
my $depend_nodes = [$node_dist,$node_acc,$node_extra];
foreach my $depend_node (@$depend_nodes)
{
	# my $node = $nmisng->node( uuid => $uuid )
	my $configuration = $depend_node->configuration();
	$configuration->{depend} = [$node_core->name];
	$configuration->{depend} = [$node_dist->name] if( $depend_node eq $node_extra); # node extra depend on something else
	$depend_node->configuration($configuration);
	my ($success,$error_msg) = $depend_node->save();
	ok($success > 0, "node configuration updated:".$depend_node->name()) or diag(Dumper($error_msg));
}


# now bring the nodes down, we should only get 1 event that has notify escalation
nodeDown($node_core->name,1);
nodeDown($node_dist->name,1);
nodeDown($node_acc->name,1);
nodeDown($node_extra->name,1);

$nmisng->process_escalations;

# make sure core node has correct event
my $event = $nmisng->events->event( node_uuid => $node_core->uuid(), event=>"Node Down", element=>"");
if( my $error = $event->load() )
{
	print "ERRor:$error\n";
}
is( $event->escalate(), 0, "event at escalation 0" );
is( $event->notify(), $esc0_notify, "event has correct notification" );

# depend nodes should have event with -1 escalation (default) and no notify
foreach my $depend_node (@$depend_nodes) 
{
	my $event = $nmisng->events->event( node_uuid => $depend_node->uuid(), event=>"Node Down", element=>"");
	if( my $error = $event->load() )
	{
		print "ERRor:$error\n";
	}
	is( $event->escalate(), -1, "event at escalation -1" ) or diag(Dumper($depend_node->configuration(),$event->data()));
	is( $event->notify(), "", "event has correct notification" );
}

cleanup();
done_testing();

sub nodeDown {
	my $node = shift;
	my $logged = shift;

	print $t->elapTime(). " nodeDown Create System $node\n";
	my $S = NMISNG::Sys->new; # create system object
	$S->init(name=>$node,snmp=>'false');

	print $t->elapTime(). " nodeDown(): Load Some Data\n";
	my $NI = $S->{info};

	Compat::NMIS::notify(sys=>$S,event=>"Node Down",element=>"",details=>"Ping failed");
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

	my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"Node Down",level=>"Normal",element=>"",details=>"Ping failed");
	my $event = $nmisng->events->event( node_uuid => $S->nmisng_node->uuid, event=>"Node Down", element=>"");
	if( my $error = $event->load() )
	{
		print "ERRor:$error\n";
	}
	is( $event->logged, $logged, "event was logged once" ) if($logged);

	print "checkEvent Result: $result\n";

	print $t->elapTime(). " nodeUp done\n";
}

sub cleanup
{
	if (-t \*STDIN)
	{
		print "hit enter to stop the test: ";
		my $x = <STDIN>;
	}

	$EST->{default_default_default_default__}{Level0} = $escalation_backup;
	if( NMISNG::Util::writeTable(dir=>'conf',name=>"Escalations", data=>$EST) ) {
		print "Failed to clean up Escalations table!\n";
	}

	print "Cleaning up database\n";
	$nmisng->get_db()->drop();
}
