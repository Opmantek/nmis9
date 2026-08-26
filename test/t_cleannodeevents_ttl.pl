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
# Behavioural test for NMISNG::Events::cleanNodeEvents (OMK-12781 / defect BR-07).
#
# When a node is edited or deleted, cleanNodeEvents closes its active events and
# gives them an expire_at so the Mongo TTL index eventually removes them. Three
# defects broke that:
#   1. expire_at was written as an epoch INT; the TTL index only deletes BSON
#      date values, so the events never expired (unbounded growth).
#   2. the update query was {node_uuid} with no historic filter, so it also
#      overwrote the (valid) expire_at on already-historic events.
#   3. `time + $C->{purge_event_after} // 86400` parses as
#      `(time + ...) // 86400`, so the 86400 fallback was dead - with
#      purge_event_after unset, expire_at became ~now instead of ~now + 1 day.
#
# This test drives the real cleanNodeEvents and reads the events back from Mongo:
#   - a cleaned event's expire_at is a BSON date (not a plain int)
#   - a pre-existing historic event's valid expire_at is left untouched
#   - with purge_event_after unset, the 86400 fallback applies
#
# Mongo-backed like the rest of the suite; skips cleanly when no MongoDB is
# reachable, so it is safe on a bare host.
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Time::Moment;

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
$C->{db_name} = "t_cleannodeevents-$$-" . time;

$nmisng = eval { NMISNG->new( config => $C, log => NMISNG::Log->new( level => 'error' ) ) };
plan skip_all => "NMISNG/MongoDB not available: " . ($@ || "constructor returned undef")
	if ( !$nmisng );

my $probe = NMISNG::DB::count( collection => $nmisng->events_collection, query => {}, verbose => 1 );
plan skip_all => "MongoDB not reachable: " . ($probe->{error} // "unknown")
	if ( !$probe->{success} );

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
my $mknode = sub {
	my ($name) = @_;
	my $n = $nmisng->node( uuid => NMISNG::Util::getUUID(), create => 1 );
	$n->name($name);
	$n->cluster_id( $C->{cluster_id} );
	$n->configuration({
		host => "127.0.0.1", group => "g", netType => "default",
		roleType => "default", threshold => 1, active => 1,
	});
	$n->activated({ NMIS => 1 });
	my ( undef, $err ) = $n->save;
	die "failed to save node $name: $err\n" if ($err);
	return $n;
};

my $add_event = sub {
	my (%f) = @_;
	NMISNG::DB::insert(
		collection => $nmisng->events_collection,
		record     => {
			cluster_id => $C->{cluster_id}, element => "", ack => 0,
			level => "Normal", startdate => time, lastupdate => time, %f,
		}
	);
};

my $get_event = sub {
	my ($tag) = @_;
	my $cursor = NMISNG::DB::find( collection => $nmisng->events_collection, query => { t_tag => $tag } );
	return $cursor ? $cursor->next : undef;
};

# expire_at reads back as a BSON::Time (date) when set correctly, or a plain
# scalar (epoch int) when set wrongly. Extract the epoch either way.
my $epoch_of = sub {
	my ($ea) = @_;
	return undef if ( !defined $ea );
	return ( ref($ea) && $ea->can('epoch') ) ? $ea->epoch : $ea;
};

# ---------------------------------------------------------------------------
# Scenario A: purge_event_after set. Covers the date-type and historic-scope bugs.
# ---------------------------------------------------------------------------
$nmisng->config->{purge_event_after} = 3600;
my $now  = time;
my $nodeA = $mknode->("cleannodeA");
my $uuidA = $nodeA->uuid;

# an active event that should be cleaned
$add_event->( t_tag => "E1", node_uuid => $uuidA, node_name => "cleannodeA",
	event => "Interface Down", active => 1, historic => 0 );
# an already-historic event with a valid far-future expire_at that must survive
my $farfuture = Time::Moment->from_epoch( $now + 30 * 86400 );
$add_event->( t_tag => "E2", node_uuid => $uuidA, node_name => "cleannodeA",
	event => "Old Historic", active => 0, historic => 1, expire_at => $farfuture );

$nmisng->events->cleanNodeEvents( $nodeA, "t_br07" );

my $e1 = $get_event->("E1");
ok( $e1, "the active event is still present after cleanNodeEvents" );
is( $e1->{historic}, 1, "the cleaned event is marked historic" );
ok( ref( $e1->{expire_at} ) && $e1->{expire_at}->can('epoch'),
	"cleaned event expire_at is a BSON date the TTL index can delete, not an epoch int" )
	or diag( "expire_at ref was: '" . ( ref( $e1->{expire_at} ) || '(plain scalar)' ) . "'" );

my $e2ep = $epoch_of->( $get_event->("E2")->{expire_at} );
ok( defined $e2ep && abs( $e2ep - ( $now + 30 * 86400 ) ) < 120,
	"a pre-existing historic event's valid expire_at is not overwritten" )
	or diag( "E2 expire_at epoch was: " . ( defined $e2ep ? $e2ep : 'undef' ) . ", expected ~" . ( $now + 30 * 86400 ) );

# ---------------------------------------------------------------------------
# Scenario B: purge_event_after unset. Covers the dead-fallback precedence bug.
# ---------------------------------------------------------------------------
delete $nmisng->config->{purge_event_after};
my $now2  = time;
my $nodeB = $mknode->("cleannodeB");
$add_event->( t_tag => "E3", node_uuid => $nodeB->uuid, node_name => "cleannodeB",
	event => "Interface Down", active => 1, historic => 0 );

$nmisng->events->cleanNodeEvents( $nodeB, "t_br07" );

my $e3ep = $epoch_of->( $get_event->("E3")->{expire_at} );
ok( defined $e3ep && $e3ep >= $now2 + 86400 - 300,
	"with purge_event_after unset, the 86400 fallback applies (expire_at ~ now + 1 day)" )
	or diag( "E3 expire_at epoch was: " . ( defined $e3ep ? $e3ep : 'undef' ) . ", now $now2, expected >= " . ( $now2 + 86400 - 300 ) );

done_testing();
