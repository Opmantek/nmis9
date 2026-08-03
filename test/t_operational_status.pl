#!/usr/bin/perl
# OMK-12605: operational event status documents.
# Verifies that code-raised events produce method=Operational status docs:
# the NMISNG::Status writer helpers (this file grows in later tasks to cover
# notify/checkEvent wiring, the Event->delete close hook, the
# compute_thresholds summary-loop handling and the dashnode integration).

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

use strict;
use File::Temp;
use Test::More;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::DB;
use NMISNG::Status;
use NMISNG::Event;
use NMISNG::Sys;
use Compat::NMIS;

use t;

Compat::NMIS::new_nmisng();
my $C = NMISNG::Util::loadConfTable();

$C->{db_name} = "t_operational_status_" . time;
my $tmpvar = File::Temp::tempdir( CLEANUP => 1 );
$C->{'<nmis_var>'} = $tmpvar;

my $logfile = $C->{'<nmis_logs>'} . "/t_operational_status.log";
my $logger  = NMISNG::Log->new( level => $C->{log_level}, path => $logfile );

my $nmisng = NMISNG->new( config => $C, log => $logger );

sub cleanup_db { $nmisng->get_db()->drop(); }

t::prime_nodes( nmisng => $nmisng, synth_nr => 1 );
my $nodes = $nmisng->get_nodes_model( sort => { node_name => 1 } );
if ( $nodes->count < 1 ) { cleanup_db(); plan skip_all => "cannot create test node"; }
my $node = $nodes->object(0);

my $S      = NMISNG::Sys->new( nmisng => $nmisng );
my $initok = $S->init( node => $node, snmp => 0, wmi => 0 );
if ( !$initok ) { cleanup_db(); plan skip_all => "Sys init failed"; }

# fetch (count, first doc) for the Operational doc of event+element on our node
sub opdoc
{
	my ( $event, $element ) = @_;
	my $md = $nmisng->get_status_model(
		filter => {
			method    => "Operational",
			event     => $event,
			element   => $element // '',
			node_uuid => $node->uuid
		}
	);
	return ( $md->count, $md->count ? $md->data->[0] : undef );
}

# ---------------------------------------------------------------------------
# Task 1: save_operational_status / close_operational_status unit behaviour
# ---------------------------------------------------------------------------
ok( defined &NMISNG::Status::save_operational_status,
	"save_operational_status exists" );
ok( defined &NMISNG::Status::close_operational_status,
	"close_operational_status exists" );

# error doc created with fields
my $err = NMISNG::Status::save_operational_status(
	nmisng  => $nmisng,
	node    => $node,
	event   => "OMK12605 Helper Event",
	element => '',
	status  => "error",
	level   => "Major",
	details => "helper raise",
);
ok( !$err, "helper save (error) returned no error" ) or diag($err);
my ( $cnt, $doc ) = opdoc("OMK12605 Helper Event");
is( $cnt, 1, "one Operational doc created" );
is( $doc->{status},  "error",        "doc status is error" );
is( $doc->{level},   "Major",        "doc level is Major" );
is( $doc->{details}, "helper raise", "doc details kept" );
is( $doc->{method},  "Operational",  "doc method is Operational" );

# same identity flips to ok, does not duplicate
NMISNG::Status::save_operational_status(
	nmisng  => $nmisng,
	node    => $node,
	event   => "OMK12605 Helper Event",
	element => '',
	status  => "ok",
	details => "helper clear",
);
( $cnt, $doc ) = opdoc("OMK12605 Helper Event");
is( $cnt, 1, "still exactly one doc after clear (upsert identity)" );
is( $doc->{status}, "ok",     "doc flipped to ok" );
is( $doc->{level},  "Normal", "ok doc level defaults to Normal" );

# gate: threshold/alert context and names write nothing
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 Thr Gate",
	status => "error", context => { type => "threshold" },
);
( $cnt ) = opdoc("OMK12605 Thr Gate");
is( $cnt, 0, "threshold context gated" );

NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "Proactive OMK12605 Gate",
	status => "error",
);
( $cnt ) = opdoc("Proactive OMK12605 Gate");
is( $cnt, 0, "Proactive name gated" );

NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "Alert: OMK12605 Gate",
	status => "error",
);
( $cnt ) = opdoc("Alert: OMK12605 Gate");
is( $cnt, 0, "Alert: name gated" );

# gate: stateless events write nothing (Node Reset matches non_stateful_events
# and has Stateful=false in Events.nmis)
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "Node Reset",
	status => "error",
);
( $cnt ) = opdoc("Node Reset");
is( $cnt, 0, "stateless event gated" );

# gate: TrackStatus=false writes nothing (injected events_config)
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 Untracked",
	status => "error",
	events_config => {
		"OMK12605 Untracked" =>
			{ Stateful => "true", Status => "true", TrackStatus => "false" }
	},
);
( $cnt ) = opdoc("OMK12605 Untracked");
is( $cnt, 0, "TrackStatus=false gated" );

# close_operational_status flips an existing doc, creates nothing otherwise
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 CloseHelper",
	status => "error", level => "Major", details => "to be closed",
);
NMISNG::Status::close_operational_status(
	nmisng => $nmisng, cluster_id => $node->cluster_id,
	node_uuid => $node->uuid, event => "OMK12605 CloseHelper", element => '',
);
( $cnt, $doc ) = opdoc("OMK12605 CloseHelper");
is( $cnt, 1, "close helper kept one doc" );
is( $doc->{status}, "ok", "close helper flipped doc to ok" );

NMISNG::Status::close_operational_status(
	nmisng => $nmisng, cluster_id => $node->cluster_id,
	node_uuid => $node->uuid, event => "OMK12605 NeverExisted", element => '',
);
( $cnt ) = opdoc("OMK12605 NeverExisted");
is( $cnt, 0, "close helper never creates docs" );

# ---------------------------------------------------------------------------
# Task 2: notify() writes error docs
# ---------------------------------------------------------------------------
Compat::NMIS::notify(
	sys     => $S,
	event   => "OMK12605 Notify Event",
	element => '',
	level   => "Major",
	details => "notify raise",
);
my ( $ncnt, $ndoc ) = opdoc("OMK12605 Notify Event");
is( $ncnt, 1, "notify created one Operational doc" );
is( $ndoc->{status},  "error", "notify doc status is error" );
is( $ndoc->{level},   "Major", "notify doc level is Major" );

# repeated notify while down refreshes, does not duplicate
Compat::NMIS::notify(
	sys     => $S,
	event   => "OMK12605 Notify Event",
	element => '',
	level   => "Major",
	details => "notify raise again",
);
( $ncnt, $ndoc ) = opdoc("OMK12605 Notify Event");
is( $ncnt, 1, "repeat notify kept one doc" );
is( $ndoc->{status}, "error", "repeat notify doc still error" );

# threshold-context notify writes no Operational doc
Compat::NMIS::notify(
	sys     => $S,
	event   => "OMK12605 Notify ThrEvent",
	element => '',
	level   => "Minor",
	details => "thr",
	context => { type => "threshold" },
);
( $ncnt ) = opdoc("OMK12605 Notify ThrEvent");
is( $ncnt, 0, "threshold-context notify gated" );

# stateless notify writes no Operational doc
Compat::NMIS::notify(
	sys     => $S,
	event   => "Node Reset",
	element => '',
	level   => "Warning",
	details => "boot check",
);
( $ncnt ) = opdoc("Node Reset");
is( $ncnt, 0, "stateless notify gated" );

# --- END OF TESTS ---
cleanup_db();
done_testing();
