#!/usr/bin/perl
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify it under the
#  terms of the GNU General Public License as published by the Free Software
#  Foundation, either version 3 of the License, or (at your option) any later
#  version. See <http://www.gnu.org/licenses/>.
#
# *****************************************************************************
#
# Behavioural test for stateless-event handling in NMISNG::process_escalations
# (OMK-12780 / defect BR-06).
#
# process_escalations removes a stateless event once it is older than the
# dampening window. The removal called $event_obj->delete() but did NOT
# "next LABEL_ESC", so the loop kept running on the now-deleted object and the
# tail save(update => 1) - which targets the event by its still-present _id -
# re-inserted it active. Deleted stateless events reappeared.
#
# This test drives the real process_escalations end to end: it seeds one
# active, stateless event whose startdate is older than the dampening window,
# runs process_escalations, and asserts the event is actually gone afterwards
# rather than resurrected. The observable is the event's presence in the
# collection, so the test is independent of how the loop is structured.
#
# Mongo-backed like the rest of the suite; skips cleanly when no MongoDB is
# reachable, so it is safe on a bare host.
#
# RED before the fix: the event is deleted then resurrected (count stays 1).
# GREEN after: the event stays deleted (count 0).
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

use NMISNG;
use NMISNG::DB;
use NMISNG::Log;
use NMISNG::Util;

my $nmisng;
END { eval { $nmisng->get_db()->drop() } if ($nmisng); }

my $C = eval { NMISNG::Util::loadConfTable() };
my $cfg_err = $@;
plan skip_all => "no NMIS config available (needs conf/): $cfg_err"
	if ( $cfg_err or ref($C) ne "HASH" or !%$C );
$C->{db_name} = "t_stateless_event-$$-" . time;

$nmisng = eval { NMISNG->new( config => $C, log => NMISNG::Log->new( level => 'error' ) ) };
plan skip_all => "NMISNG/MongoDB not available: " . ($@ || "constructor returned undef")
	if ( !$nmisng );

my $probe = NMISNG::DB::count( collection => $nmisng->events_collection, query => {}, verbose => 1 );
plan skip_all => "MongoDB not reachable: " . ($probe->{error} // "unknown")
	if ( !$probe->{success} );

# a local, active node to own the event
my $node = $nmisng->node( uuid => NMISNG::Util::getUUID(), create => 1 );
$node->name("statelessnode");
$node->cluster_id( $C->{cluster_id} );
$node->configuration({
	host => "127.0.0.1", group => "g", netType => "default",
	roleType => "default", threshold => 1, active => 1,
});
$node->activated({ NMIS => 1 });
my ( undef, $saveerr ) = $node->save;
die "failed to save node: $saveerr\n" if ($saveerr);
my $uuid = $node->uuid;

# an active, stateless event whose startdate is older than the dampening window,
# so process_escalations should remove it
my $dampening = $C->{stateless_event_dampening} || 900;
NMISNG::DB::insert(
	collection => $nmisng->events_collection,
	record     => {
		cluster_id => $C->{cluster_id}, node_uuid => $uuid, node_name => "statelessnode",
		event => "Proactive Test Stateless", element => "", active => 1, historic => 0,
		ack => 0, stateless => 1, escalate => 0, notify => "", level => "Normal",
		startdate => time - $dampening - 100, lastupdate => time - $dampening - 100,
	}
);

my $q = { node_uuid => $uuid };
is( NMISNG::DB::count( collection => $nmisng->events_collection, query => $q, verbose => 1 )->{count},
	1, "the stateless event is present before process_escalations" );

$nmisng->process_escalations();

is( NMISNG::DB::count( collection => $nmisng->events_collection, query => $q, verbose => 1 )->{count},
	0, "a dampened stateless event stays deleted and is not resurrected" );

done_testing();
