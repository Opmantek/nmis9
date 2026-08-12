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
# Regression tests for the Proactive CPU duplicate-event bug:
# Two model sections (cpu, cpu_cpm) produce the same event name "Proactive CPU".
# cpu_cpm is indexed (element="cpu R0/0"), cpu is not (element="").
# When cpu reports Normal, checkEvent must NOT close the cpu_cpm event.
#
# Fix tested: Event::_query() now:
#   1. Includes inventory_id in the MongoDB query when set.
#   2. When element is empty, restricts to { '$in' => [undef, ''] } instead of
#      silently dropping the element filter (which would match any element).
#
# These two guards together ensure a non-indexed event can never close an indexed
# event that shares only the event name.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Test::More;
use Test::Deep;

use NMISNG;
use NMISNG::Event;
use NMISNG::Sys;
use NMISNG::Util;
use NMISNG::DB;
use Compat::NMIS;

Compat::NMIS::new_nmisng();

my $C = NMISNG::Util::loadConfTable();
$C->{event_log} = $C->{'<nmis_logs>'} . "/t_event_query_isolation.log";
unlink $C->{event_log};

my $logger = NMISNG::Log->new(
	level => $C->{log_level},
	path  => $C->{'<nmis_logs>'} . "/t_event_query_isolation.log",
);

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
	tests  => { events_test_collection => "events_test" },
);

my $nodes = $nmisng->get_nodes_model( sort => { node_name => 1 } );
plan skip_all => "Need at least one existing node to run" if $nodes->count < 1;

my $node = $nodes->object(0);
my $S    = NMISNG::Sys->new( nmisng => $nmisng );
$S->init( name => $node->name, snmp => 'false' );

# Unique event name per run so leftover docs from aborted runs don't interfere.
my $event_name   = "Proactive CPU Isolation Test $$";
my $elem_indexed = "cpu-indexed-$$";
diag("event_name: $event_name  element: $elem_indexed");

# Two distinct inventory ids: one for the indexed section (cpu_cpm),
# one for the non-indexed section (cpu).
my $inv_id_indexed = NMISNG::DB::make_oid();
my $inv_id_noindex = NMISNG::DB::make_oid();

# Clean up any leftovers.
NMISNG::DB::remove(
	collection => $nmisng->events_collection(),
	query      => { node_uuid => $node->uuid, event => $event_name },
);

# ---------------------------------------------------------------------------
# Group 1: _query() structure — verify the query is built correctly
# ---------------------------------------------------------------------------

{
	my $ev = NMISNG::Event->new(
		nmisng       => $nmisng,
		node_uuid    => $node->uuid,
		event        => $event_name,
		element      => $elem_indexed,
		inventory_id => $inv_id_indexed,
	);
	my $q = $ev->_query();

	ok( exists $q->{inventory_id},
		"_query: inventory_id key present in query when Event has one" );
	isnt( $q->{element}, undef,
		"_query: element key present when Event has a non-empty element" );
	is( $q->{element}, $elem_indexed,
		"_query: element value matches what was set on the Event" );
}

{
	my $ev = NMISNG::Event->new(
		nmisng    => $nmisng,
		node_uuid => $node->uuid,
		event     => $event_name,
		element   => "",
	);
	my $q = $ev->_query();

	ok( exists $q->{element},
		"_query: element key present even when element is empty string" );
	ok( ref( $q->{element} ) eq 'HASH',
		"_query: empty element produces a hash restriction, not a scalar" );
	ok( exists $q->{element}{'$in'},
		"_query: empty-element restriction uses \$in operator" );
	cmp_deeply(
		$q->{element}{'$in'},
		[ undef, '' ],
		"_query: \$in covers both undef (null/missing) and empty string"
	);
	ok( !exists $q->{inventory_id},
		"_query: inventory_id absent from query when not set on Event" );
}

# ---------------------------------------------------------------------------
# Group 2: Behavioural — non-indexed Normal must not close indexed Warning
# ---------------------------------------------------------------------------

# Step 1: indexed section (cpu_cpm) fires Warning → stored event with element+inventory_id.
Compat::NMIS::notify(
	sys          => $S,
	event        => $event_name,
	element      => $elem_indexed,
	level        => "Warning",
	details      => "Value=45 Threshold=40",
	inventory_id => $inv_id_indexed,
);

my $indexed_after_notify = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => $event_name,
	element   => $elem_indexed,
);
$indexed_after_notify->load();
ok( $indexed_after_notify->exists && $indexed_after_notify->active,
	"Behavioural: '$event_name' element='$elem_indexed' is active after notify()" );

# Step 2: non-indexed section (cpu) fires Normal with empty element and different
#         inventory_id — the bug scenario.  Before the fix this would close the
#         indexed event because _query() had no element filter.
Compat::NMIS::checkEvent(
	sys          => $S,
	event        => $event_name,
	element      => "",
	level        => "Normal",
	details      => "Value=0 Threshold=40",
	inventory_id => $inv_id_noindex,
);

my $indexed_after_noindex_check = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => $event_name,
	element   => $elem_indexed,
);
$indexed_after_noindex_check->load();
ok( $indexed_after_noindex_check->exists && $indexed_after_noindex_check->active,
	"Behavioural: checkEvent(element='') did NOT close '$event_name' element='$elem_indexed'" );

# ---------------------------------------------------------------------------
# Group 3: Sanity — the SAME event IS closed when element+inventory_id match
# ---------------------------------------------------------------------------

Compat::NMIS::checkEvent(
	sys          => $S,
	event        => $event_name,
	element      => $elem_indexed,
	level        => "Normal",
	details      => "Value=10 Threshold=40",
	inventory_id => $inv_id_indexed,
);

# check() renames the event to "$name Closed" and sets active=0 — look for that.
my $closed_ev = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "$event_name Closed",
	element   => $elem_indexed,
);
$closed_ev->load( ignore_active => 1 );
ok( $closed_ev->exists && !$closed_ev->active,
	"Sanity: same element + same inventory_id checkEvent() DOES close its own event (renamed to '$event_name Closed', active=0)" );

# Cleanup — remove both the original name and the "Closed" variant.
NMISNG::DB::remove(
	collection => $nmisng->events_collection(),
	query      => { node_uuid => $node->uuid, event => { '$in' => [ $event_name, "$event_name Closed" ] } },
);

done_testing();
