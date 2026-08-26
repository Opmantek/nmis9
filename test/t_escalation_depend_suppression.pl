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
# Behavioural test for the escalation dependency-suppression in
# NMISNG::process_escalations (OMK-12779 / defect BR-05).
#
# When a node's active event is being escalated, process_escalations skips the
# escalation ("next LABEL_ESC") if a node it depends on is currently down. That
# "is the depend node down" check must consider only an ACTIVE, non-historic
# Node Down. The buggy code used eventLoad(... active => 1) and suppressed on
# !$error, but Event::load discards the active filter (ignore_active), so it
# returned no error - and suppressed - for an inactive, or even absent, Node
# Down doc on the depend node. Notifications were wrongly suppressed.
#
# This test drives the real process_escalations end to end: a child node with
# an active event depends on a parent node, and we vary the parent's Node Down
# state. It observes the suppression decision via the debug line the dependency
# check logs ("... as depending on <parent>, which is reported as down"), which
# is the direct and only reliable signal of that decision.
#
#   - active   Node Down on the parent  -> escalation IS suppressed (correct)
#   - inactive Node Down on the parent  -> escalation is NOT suppressed (the fix)
#   - no       Node Down on the parent  -> escalation is NOT suppressed
#
# Mongo-backed like the rest of the suite; skips cleanly when no MongoDB is
# reachable, so it is safe on a bare host.
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

my $logfile = ( $ENV{TMPDIR} || "/tmp" ) . "/t_escalation_depend_suppression-$$.log";
my $nmisng;
END {
	eval { $nmisng->get_db()->drop() } if ($nmisng);
	unlink $logfile if ( -e $logfile );
}

my $C = eval { NMISNG::Util::loadConfTable() };
my $cfg_err = $@;
plan skip_all => "no NMIS config available (needs conf/): $cfg_err"
	if ( $cfg_err or ref($C) ne "HASH" or !%$C );
$C->{db_name} = "t_escalation_depend-$$-" . time;

# level 9 so the dependency check's debug2 line is written; a file we can read back
$nmisng = eval { NMISNG->new( config => $C, log => NMISNG::Log->new( level => 9, path => $logfile ) ) };
plan skip_all => "NMISNG/MongoDB not available: " . ($@ || "constructor returned undef")
	if ( !$nmisng );

my $probe = NMISNG::DB::count( collection => $nmisng->events_collection, query => {}, verbose => 1 );
plan skip_all => "MongoDB not reachable: " . ($probe->{error} // "unknown")
	if ( !$probe->{success} );

# ---------------------------------------------------------------------------
# A parent (depend target) node and a child node that depends on it. Both are
# local and active so the dependency check engages.
# ---------------------------------------------------------------------------
my $mknode = sub {
	my ( $name, %cfg ) = @_;
	my $n = $nmisng->node( uuid => NMISNG::Util::getUUID(), create => 1 );
	$n->name($name);
	$n->cluster_id( $C->{cluster_id} );
	$n->configuration({
		host => "127.0.0.1", group => "g", netType => "default",
		roleType => "default", threshold => 1, active => 1, %cfg,
	});
	$n->activated({ NMIS => 1 });
	my ( undef, $error ) = $n->save;
	die "failed to save node $name: $error\n" if ($error);
	return $n;
};

my $parent = $mknode->("parentnode");
my $child  = $mknode->("childnode", depend => ["parentnode"]);
my ( $puuid, $cuuid ) = ( $parent->uuid, $child->uuid );

my $add_event = sub {
	my (%f) = @_;
	NMISNG::DB::insert(
		collection => $nmisng->events_collection,
		record     => {
			cluster_id => $C->{cluster_id}, element => "", historic => 0,
			ack => 0, escalate => 0, notify => "", level => "Normal",
			startdate => time, lastupdate => time, %f,
		}
	);
};

# Run process_escalations with a chosen parent Node Down state, and report
# whether the dependency check suppressed the child's escalation. Reads only
# the log appended during this run, so scenarios don't bleed into each other.
my $suppressed = sub {
	my ($parent_active) = @_;    # undef = no parent event, else 0/1
	NMISNG::DB::remove( collection => $nmisng->events_collection, query => {} );
	# a fresh active event on the child so it enters escalation and reaches the depend check
	$add_event->( node_uuid => $cuuid, node_name => "childnode", event => "Node Down", active => 1 );
	$add_event->( node_uuid => $puuid, node_name => "parentnode", event => "Node Down", active => $parent_active )
		if ( defined $parent_active );

	my $offset = ( -s $logfile ) || 0;
	$nmisng->process_escalations();

	open my $r, "<", $logfile or die "cannot read $logfile: $!";
	seek( $r, $offset, 0 );
	local $/;
	my $new_log = <$r> // "";
	close $r;
	return ( $new_log =~ /as depending on parentnode/ ) ? 1 : 0;
};

ok(  $suppressed->(1),     "active Node Down on a depend node suppresses escalation (control)" );
ok( !$suppressed->(0),     "inactive Node Down on a depend node does NOT suppress escalation" );
ok( !$suppressed->(undef), "no Node Down on a depend node does NOT suppress escalation" );

done_testing();
