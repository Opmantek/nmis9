#!/usr/bin/perl
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
# *****************************************************************************
#
# OMK-12622: Verify that notify() cleans up stale resolved (active=0) "Interface Up"
# events before creating a new "Interface Down", preventing duplicate Up events.
#
# Root cause:
#   check() renames "Interface Down, active=1" to "Interface Up, active=0" when an
#   outage clears. If escalation has not run, that "Interface Up, active=0" document
#   stays in the collection with historic=0, occupying a unique index slot.
#   When the next outage clears (check() runs again), MongoDB returns a duplicate key
#   error because the unique index on (node_uuid, event, element, active) already has
#   that slot filled. The save of active=0 silently fails, the event stays active=1
#   in the DB, and the next poll logs a second Interface Up.
#
# Fix:
#   notify() now loads the CancelingEvent with ignore_active => 1 so it finds and
#   deletes active=0 stale docs before creating the new Interface Down.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Test::More;

use NMISNG;
use NMISNG::Event;
use NMISNG::Util;
use NMISNG::DB;
use Compat::NMIS;

Compat::NMIS::new_nmisng();

my $C = NMISNG::Util::loadConfTable();
$C->{event_log} = $C->{'<nmis_logs>'} . "/t_duplicate_event.log";
unlink $C->{event_log};

my $logger = NMISNG::Log->new(
	level => $C->{log_level},
	path  => $C->{'<nmis_logs>'} . "/t_duplicate_event.log",
);

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
	tests  => { events_test_collection => "events_test" },
);

my $nodes = $nmisng->get_nodes_model( sort => { node_name => 1 } );
plan skip_all => "Need at least one existing node to run" if $nodes->count < 1;

my $node = $nodes->object(0);

# Pass the test nmisng so that $S->nmisng_node->event(...) inside notify()
# writes to events_test rather than the production events collection.
my $S = NMISNG::Sys->new( nmisng => $nmisng );
$S->init( name => $node->name, snmp => 'false' );

# The unique index on (node_uuid, event, element, active) for non-historic events
# is normally created by nmisd at startup via ensure_indexes(). Add it here so the
# duplicate key conflict can actually occur in the test collection.
NMISNG::DB::ensure_index(
	collection => $nmisng->events_collection(),
	indices    => [
		[
			[ node_uuid => 1, event => 1, element => 1, active => 1 ],
			{ unique => 1, partialFilterExpression => { historic => { '$lte' => 0 } } }
		],
	]
);

# Unique element name per run to avoid leftover collisions.
my $intf = "MultiGE-omk12622-$$";

# Clean up any leftovers from a previous aborted run.
NMISNG::DB::remove(
	collection => $nmisng->events_collection(),
	query      => { node_uuid => $node->uuid, element => $intf },
);

# ---------------------------------------------------------------------------
# Outage 1: create and resolve
# notify() creates "Interface Down, active=1".
# check() resolves it to "Interface Up, active=0, historic=0" — escalation has
# not run so the document stays in the collection with historic=0.
# ---------------------------------------------------------------------------

Compat::NMIS::notify(
	sys     => $S,
	event   => "Interface Down",
	element => $intf,
	level   => "Major",
	details => "outage 1",
);

my $down1 = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "Interface Down",
	element   => $intf,
);
$down1->load();
ok( $down1->exists() && $down1->active, "outage-1: Interface Down is active in DB" );

# Resolve outage 1 — leaves stale "Interface Up, active=0, historic=0" in the collection.
$down1->check( sys => $S );

# Verify the stale doc. Must use ignore_active => 1 because the default query
# filters for active=1 and would miss the active=0 resolved event.
my $stale = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "Interface Up",
	element   => $intf,
);
$stale->load( ignore_active => 1 );
ok( $stale->exists(),    "stale Interface Up doc is in DB after outage-1 resolves" );
is( $stale->active,  0, "stale doc is inactive (active=0)" );
is( $stale->historic, 0, "stale doc is not yet historic (escalation hasn't run)" );

# ---------------------------------------------------------------------------
# Outage 2: notify() must delete the stale doc (the fix under test).
# Without the fix, the stale active=0 doc stays and the unique index blocks
# the next check(), causing a duplicate Interface Up on the following poll.
# ---------------------------------------------------------------------------

Compat::NMIS::notify(
	sys     => $S,
	event   => "Interface Down",
	element => $intf,
	level   => "Major",
	details => "outage 2",
);

# Core assertion: the stale "Interface Up, active=0" was deleted by notify().
my $check_stale = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "Interface Up",
	element   => $intf,
);
$check_stale->load( ignore_active => 1 );
ok( !$check_stale->exists(),
	"OMK-12622: notify() removed stale Interface Up, active=0 before creating new down" );

# The new Interface Down should be active.
my $down2 = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "Interface Down",
	element   => $intf,
);
$down2->load();
ok( $down2->exists() && $down2->active, "outage-2: new Interface Down is active in DB" );

# ---------------------------------------------------------------------------
# Resolve outage 2: with the stale doc gone, check() can save active=0
# without hitting a duplicate key error.
# ---------------------------------------------------------------------------

$down2->check( sys => $S );

# Outcome assertion: check() renames the "Interface Down" doc to "Interface Up"
# and saves it as active=0. Without the fix the save() silently fails (duplicate
# key error) and the document stays in the collection as active=1 "Interface Down".
my $resolved = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "Interface Up",    # check() renames the doc, not creates a new one
	element   => $intf,
);
$resolved->load( ignore_active => 1 );
ok( $resolved->exists(), "outage-2 resolved doc exists as Interface Up in DB" );
is( $resolved->active, 0,
	"OMK-12622: outage-2 saved as active=0 — no duplicate key error occurred" );

# Subsequent poll: no active Interface Down remains, so check() is not called
# again and no duplicate Interface Up is logged.
my $next_poll = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "Interface Down",
	element   => $intf,
);
$next_poll->load();    # default query: active=1
ok( !$next_poll->exists(),
	"OMK-12622: no active Interface Down on next poll — duplicate Interface Up cannot occur" );

# Cleanup
NMISNG::DB::remove(
	collection => $nmisng->events_collection(),
	query      => { node_uuid => $node->uuid, element => $intf },
);

done_testing();
