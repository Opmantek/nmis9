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
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************
#
# Task E1 reproduction test (feat/sdwan-polling):
#
# On a 2nd full Node Down -> Up cycle for the same (node,event,element),
# Event::check() converts the active "Node Down" doc in place into its "Up"
# companion with active(0), leaving it non-historic. The next Down-raise is
# supposed to be protected by Compat::NMIS::notify's CancelingEvent
# pre-cleanup (Events.nmis declares CancelingEvent => 'Node Up' for
# 'Node Down'), which should retire any leftover "Node Up" doc before the new
# Down is created. But that cleanup builds its lookup WITHOUT active => 0,
# and Event::_query defaults active => 1 when it isn't given, so the lookup
# never matches the interim active=0 Up doc and silently no-ops. The
# unique/partial index on (node_uuid,event,element,active) then collides
# when the 2nd Down doc is itself converted to Up, logging a "Duplicate
# event id" fatal and leaving the DB stuck with the event still Node-Down
# active, while an Up notification was already sent.
#
# This test raises/clears "Node Down" twice in a row for one node and
# asserts the DB ends up consistent after each step, with no orphaned
# interim doc and no "Duplicate event id" fatal logged.

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Carp;
use Test::More;
use Data::Dumper;

use NMISNG::Util;
use Compat::NMIS;

my %nvp = %{ NMISNG::Util::get_args_multi(@ARGV) };

# allow for instantiating a test collection in our $db for running tests
# in a hashkey named 'tests' passed as arg to Compat::NMIS::new_nmisng()
my $nmisng_args->{tests}{events_test_collection} = "events_test";
my $nmisng = Compat::NMIS::new_nmisng(%$nmisng_args);
my $C = $nmisng->config();

# the unique/partial index enforcing (node_uuid,event,element,active) for
# non-historic docs is normally created by bin/nmisd / bin/nmis-cli via
# ensure_indexes(); it is not created automatically for the ad hoc
# events_test collection the test suite uses. Create it here so this test
# exercises the same DB constraint production hits - without it the
# duplicate-key collision this test is about can't be observed at all.
my $ixerr = $nmisng->ensure_indexes();
is($ixerr, undef, "index setup for events_test collection succeeded") or diag($ixerr);

my $nodes = $nmisng->get_nodes_model(sort => {node_name => 1});
confess "I need at least 1 existing node to run" if ($nodes->count < 1);
my $node = $nodes->object(0);
diag("using node " . $node->name);

my $S = NMISNG::Sys->new;
$S->init(name => $node->name, snmp => 'false');

$node->eventsClean("t_event_cancelingevent_cycle");

my $element    = "";
my $event_name = "Node Down";

# count fatal-severity log calls so we can assert directly that the
# "Duplicate event id" fatal (Event.pm ~451) never fires, on top of the DB
# state checks below.
my $fatal_count = 0;
my @fatal_msgs;
{
	no warnings 'redefine';
	my $orig_fatal = \&NMISNG::Log::fatal;
	*NMISNG::Log::fatal = sub {
		$fatal_count++;
		push @fatal_msgs, $_[1] if (defined $_[1]);
		goto &$orig_fatal;
	};
}

sub current_events
{
	return $nmisng->events->get_events_model(
		filter => {
			node_uuid => $node->uuid,
			element   => $element,
			historic  => 0,
			cluster_id => $C->{cluster_id}
		}
	);
}

sub raise_down
{
	my ($cycle) = @_;
	Compat::NMIS::notify(
		sys     => $S,
		event   => $event_name,
		element => $element,
		details => "t_event_cancelingevent_cycle cycle $cycle down",
		level   => "Critical",
	);
}

sub clear_up
{
	my ($cycle) = @_;
	return Compat::NMIS::checkEvent(
		sys     => $S,
		event   => $event_name,
		level   => "Normal",
		element => $element,
		details => "t_event_cancelingevent_cycle cycle $cycle up",
	);
}

# --- cycle 1: first Down -> Up, this is what creates the "interim" Up doc ---
raise_down(1);
my $em = current_events();
is($em->error, undef, "cycle1 down: event lookup ok") or diag(Dumper($em->error));
is($em->count, 1, "cycle1 down: exactly one non-historic event exists");
is($em->data->[0]->{event}, "Node Down", "cycle1 down: event is Node Down");
is($em->data->[0]->{active}, 1, "cycle1 down: event is active");

clear_up(1);
$em = current_events();
is($em->error, undef, "cycle1 up: event lookup ok") or diag(Dumper($em->error));
is($em->count, 1, "cycle1 up: exactly one non-historic event exists (the interim Up doc)");
is($em->data->[0]->{event}, "Node Up", "cycle1 up: event converted to Node Up");
is($em->data->[0]->{active}, 0, "cycle1 up: event is inactive");
is($em->data->[0]->{historic}, 0,
   "cycle1 up: event is not yet historic - this is the interim doc the CancelingEvent cleanup must retire before cycle 2's Down");

# --- cycle 2: 2nd Down -> Up on the same node/event/element.
# Without the fix, the CancelingEvent cleanup silently fails to retire the
# interim doc left by cycle 1 (it looks for active=>1 by default, but the
# interim doc has active=>0), so raising Down here inserts a *second*,
# independent doc. Clearing it then hits the unique-index collision when
# that 2nd doc is itself converted to "Node Up" - the DB is left with the
# event stuck Node-Down-active plus the orphaned interim Up doc.
raise_down(2);
$em = current_events();
is($em->error, undef, "cycle2 down: event lookup ok") or diag(Dumper($em->error));
is($em->count, 1,
   "cycle2 down: CancelingEvent cleanup retired the interim Up doc, exactly one Down doc remains")
	or diag("events: " . Dumper($em->data));

clear_up(2);
$em = current_events();
is($em->error, undef, "cycle2 up: event lookup ok") or diag(Dumper($em->error));
is($em->count, 1, "cycle2 up: exactly one non-historic event remains (no orphaned duplicate)")
	or diag("events: " . Dumper($em->data));
SKIP: {
	skip "no event doc to inspect", 2 if (!$em->count);
	is($em->data->[0]->{event}, "Node Up", "cycle2 up: final state reflects the clear (Node Up), not stuck Down");
	is($em->data->[0]->{active}, 0, "cycle2 up: final state is inactive");
}

is($fatal_count, 0, "no 'Duplicate event id' fatal was logged across the 2 down/up cycles")
	or diag("fatal messages logged: " . Dumper(\@fatal_msgs));

done_testing();
