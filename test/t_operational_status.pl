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

# ---------------------------------------------------------------------------
# Task 3: checkEvent() writes ok docs
# ---------------------------------------------------------------------------
# flips the Task-2 error doc to ok, same doc (upsert identity)
my ( undef, $before_flip ) = opdoc("OMK12605 Notify Event");
Compat::NMIS::checkEvent(
	sys     => $S,
	event   => "OMK12605 Notify Event",
	element => '',
	level   => "Normal",
	details => "recovered",
);
my ( $ccnt, $cdoc ) = opdoc("OMK12605 Notify Event");
is( $ccnt, 1, "checkEvent kept exactly one doc" );
is( $cdoc->{status}, "ok",     "checkEvent flipped doc to ok" );
is( $cdoc->{level},  "Normal", "ok doc level is Normal" );
is( "$cdoc->{_id}", "$before_flip->{_id}", "same doc updated, not recreated" );

# healthy check with no prior event still creates an ok doc
Compat::NMIS::checkEvent(
	sys     => $S,
	event   => "OMK12605 Fresh Event",
	element => '',
	details => "all good",
);
( $ccnt, $cdoc ) = opdoc("OMK12605 Fresh Event");
is( $ccnt, 1, "checkEvent with no prior event created ok doc" );
is( $cdoc->{status}, "ok", "fresh doc status is ok" );

# threshold-context checkEvent writes nothing
Compat::NMIS::checkEvent(
	sys     => $S,
	event   => "OMK12605 ThrCheck Event",
	element => '',
	details => "thr ok",
	context => { type => "threshold" },
);
( $ccnt ) = opdoc("OMK12605 ThrCheck Event");
is( $ccnt, 0, "threshold-context checkEvent gated" );

# Proactive-named checkEvent writes nothing (fallback name gate)
Compat::NMIS::checkEvent(
	sys     => $S,
	event   => "Proactive OMK12605 Check",
	element => '',
	details => "thr ok",
);
( $ccnt ) = opdoc("Proactive OMK12605 Check");
is( $ccnt, 0, "Proactive-named checkEvent gated" );

# ---------------------------------------------------------------------------
# Task 4: Event->delete close hook
# ---------------------------------------------------------------------------
Compat::NMIS::notify(
	sys     => $S,
	event   => "OMK12605 CloseMe",
	element => '',
	level   => "Major",
	details => "will be closed out of band",
);
my ( $dcnt, $ddoc ) = opdoc("OMK12605 CloseMe");
is( $ddoc->{status}, "error", "doc is error before out-of-band close" );

my $closeme = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "OMK12605 CloseMe",
	element   => '',
);
$closeme->load();
ok( $closeme->exists(), "event exists before delete" );
my $delerr = $closeme->delete();
ok( !$delerr, "event delete succeeded" ) or diag($delerr);

( $dcnt, $ddoc ) = opdoc("OMK12605 CloseMe");
is( $dcnt, 1, "close hook kept one doc" );
is( $ddoc->{status},  "ok",           "close hook flipped doc to ok" );
is( $ddoc->{details}, "event closed", "close hook stamped details" );

# deleting an event that never had a doc creates nothing.
# "Node Reset" is stateless, so notify creates the event but no doc.
Compat::NMIS::notify(
	sys     => $S,
	event   => "Node Reset",
	element => '',
	level   => "Warning",
	details => "doc-less event for delete test",
);
my $docless = NMISNG::Event->new(
	nmisng    => $nmisng,
	node_uuid => $node->uuid,
	event     => "Node Reset",
	element   => '',
);
$docless->load();
ok( $docless->exists(), "doc-less event exists before delete" );
$docless->delete();
( $dcnt ) = opdoc("Node Reset");
is( $dcnt, 0, "delete of doc-less event created nothing" );

# ---------------------------------------------------------------------------
# Task 5: compute_thresholds summary loop
# ---------------------------------------------------------------------------
# seed: a stale Threshold doc (must be swept) and a stale Operational doc
# (must survive), inserted directly so lastupdate can be in the past.
my $common = {
	cluster_id => $node->cluster_id, node_uuid => $node->uuid,
	element => '', property => '', index => '', class => '',
	section => '', source => '', value => '',
	level => "Minor", status => "error", lastupdate => time - 600,
};
NMISNG::DB::insert(
	collection => $nmisng->status_collection(),
	record => { %$common, method => "Threshold", event => "OMK12605 Stale Thr",
		property => "omk12605_thr" },
);
NMISNG::DB::insert(
	collection => $nmisng->status_collection(),
	record => { %$common, method => "Operational", event => "OMK12605 Stale Op" },
);
# an Operational doc whose event has Status=false in shipped Events.nmis:
# must be skipped without the "ignored" stamp
NMISNG::DB::insert(
	collection => $nmisng->status_collection(),
	record => { %$common, method => "Operational", event => "Planned Outage Open",
		lastupdate => time },
);

$nmisng->compute_thresholds( sys => $S, running_independently => 0 );

my $md = $nmisng->get_status_model(
	filter => { event => "OMK12605 Stale Thr", node_uuid => $node->uuid } );
is( $md->count, 0, "stale Threshold doc swept" );

$md = $nmisng->get_status_model(
	filter => { event => "OMK12605 Stale Op", node_uuid => $node->uuid } );
is( $md->count, 1, "stale Operational doc survived the sweep" );

$md = $nmisng->get_status_model(
	filter => { event => "Planned Outage Open", node_uuid => $node->uuid } );
is( $md->count, 1, "Status=false Operational doc still present" );
is( $md->data->[0]{status}, "error",
	"Status=false Operational doc keeps error, no 'ignored' stamp" );

my $catchall = $S->inventory( concept => 'catchall' )->data;
ok( defined $catchall->{status_summary}, "status_summary was computed" );
cmp_ok( $catchall->{status_summary}, '<', 100,
	"error Operational doc dragged status_summary below 100" );

# ---------------------------------------------------------------------------
# Task 6: shipped conf-default/Events.nmis flags
# ---------------------------------------------------------------------------
my %shipped_events = do "$FindBin::Bin/../conf-default/Events.nmis";
for my $ev ( "Interface Down", "Service Down", "Service Degraded" )
{
	is( $shipped_events{$ev}{Status}, "false",
		"$ev ships with Status=false (written but not counted)" );
}
is( $shipped_events{"Planned Outage Open"}{TrackStatus}, "false",
	"Planned Outage Open ships with TrackStatus=false (no doc)" );

# ---------------------------------------------------------------------------
# Task 7: dashnode file integration and context-clear bugfix
# ---------------------------------------------------------------------------
$C->{enable_dashnode_file} = 'true';
$nmisng->{dashnode_context} = { op => 'collect', data => { status => {} } };

Compat::NMIS::notify(
	sys     => $S,
	event   => "OMK12605 Dash Event",
	element => '',
	level   => "Major",
	details => "dash raise",
);

my $dnstatus = $nmisng->{dashnode_context}{data}{status};
ok( exists $dnstatus->{"OMK12605 Dash Event--"},
	"dashnode context gained event--element key" );
is( $dnstatus->{"OMK12605 Dash Event--"}{method}, "Operational",
	"dashnode entry method is Operational" );
is( $dnstatus->{"OMK12605 Dash Event--"}{status}, "error",
	"dashnode entry status is error" );
ok( defined $dnstatus->{"OMK12605 Dash Event--"}{updated},
	"dashnode entry has updated field (threshold-entry shape)" );

ok( $node->save_dashnode_data(), "save_dashnode_data succeeded" );
my $dashfile = $C->{'<nmis_var>'} . "/" . $node->name . "-node.json";
ok( -r $dashfile, "dashnode file written" );
my $dashdata = NMISNG::Util::readFiletoHash( file => $dashfile, json => 1 );
ok( exists $dashdata->{status}{"OMK12605 Dash Event--"},
	"dashnode file contains the operational entry" );
is( $dashdata->{status}{"OMK12605 Dash Event--"}{status}, "error",
	"file entry carries status error" );

# the bugfix: context must actually be cleared after save
ok( !defined $nmisng->{dashnode_context},
	"dashnode_context cleared after save (bugfix)" );
$C->{enable_dashnode_file} = 'false';

# ---------------------------------------------------------------------------
# Follow-up Task 1 (2026-08-04 fping/dashboard follow-up): pingable() must
# refresh the Node Down operational status doc every collect() cycle when
# fping owns the up/down decision (fresh cached fping data, $mustping
# false) - not just when the fping worker itself raises/clears a transition.
# ---------------------------------------------------------------------------

# enable ping on the test node, and give it a live catchall to drive
# $catchall_data->{nodedown} directly, the same way handle_down does.
my $pcfg = $node->configuration;
$pcfg->{ping} = "true";
$node->configuration($pcfg);

my ( $catchall_inv, $cinv_err ) = $S->inventory( concept => "catchall" );
ok( !$cinv_err, "catchall inventory available for pingable test" ) or diag($cinv_err);
my $catchall_data = $catchall_inv->data_live();

# seeds a fresh "ping" inventory + timed-data record so pingable() finds
# fresh fping-cached data and takes the $mustping == false path - mirrors
# the shape pingable() itself writes when it owns the pinging (Node.pm
# ~2021-2052: concept "ping", model_class "nomodel", subconcept "ping").
#
# optional backup_loss: when given, the record also carries the backup_*
# fields the fping worker writes for a multihomed node (bin/nmisd ~2944-2954:
# backup_min_rtt/backup_avg_rtt/backup_max_rtt/backup_loss/backup_ip). This
# matters because pingable() only consults them when the PRIMARY reports
# loss=100 (Node.pm ~1968-1978), and an unreachable address has undef rtts.
# Without them a loss=100 seed on a host_backup-configured node describes
# "primary dead, backup fine", not a total outage.
sub seed_fresh_ping
{
	my (%args) = @_;
	my $loss        = $args{loss} // 0;
	my $backup_loss = $args{backup_loss};
	my $data = { min_rtt => 1, avg_rtt => 2, max_rtt => 3, loss => $loss,
		ip => $node->configuration->{host} };
	if ( defined $backup_loss )
	{
		my $backup_up = ( $backup_loss < 100 );
		$data->{backup_min_rtt} = $backup_up ? 4 : undef;
		$data->{backup_avg_rtt} = $backup_up ? 5 : undef;
		$data->{backup_max_rtt} = $backup_up ? 6 : undef;
		$data->{backup_loss}    = $backup_loss;
		$data->{backup_ip}      = $node->configuration->{host_backup};
	}
	my ( $pinginv, $pinginv_err ) = $node->inventory(
		concept => "ping", create => 1, model_class => "nomodel", protocol => 'ping',
		data => {}, path_keys => [] );
	die "ping inventory error: $pinginv_err" if ($pinginv_err);
	$pinginv->save( node => $node ) if ( $pinginv->is_new );
	my $timed_err = $pinginv->add_timed_data(
		time         => time,
		data         => $data,
		derived_data => {},
		subconcept   => "ping",
		node         => $node,
	);
	die "add_timed_data error: $timed_err" if ($timed_err);
}

# (c) never been down: no prior "Node Down" event anywhere for this node,
# nodedown false from the start -> pingable() must still create an ok doc
# on its very first call. No equivalent coverage existed anywhere before
# this, since it's exactly the gap this follow-up closes.
ok( !$node->eventExist("Node Down"), "no prior Node Down event exists yet" );
( my $precnt ) = opdoc("Node Down");
is( $precnt, 0, "no Node Down Operational doc exists yet either" );

$catchall_data->{nodedown} = "false";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );
my $pingable_up = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
ok( $pingable_up, "pingable() returned true for fresh loss=0 data" );

my ( $upcnt, $updoc ) = opdoc("Node Down");
is( $upcnt, 1, "pingable() created the Node Down doc on first (never-down) call" );
is( $updoc->{status}, "ok",     "never-down doc status is ok" );
is( $updoc->{level},  "Normal", "never-down doc level is Normal" );
ok( !$node->eventExist("Node Down"), "still no Node Down event - event ownership untouched" );

# repeat call, still up: refreshes the same doc, does not duplicate
sleep 1;    # ensure lastupdate advances so the refresh is observable
seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $upcnt2, $updoc2 ) = opdoc("Node Down");
is( $upcnt2, 1, "repeat up call kept exactly one doc (upsert identity)" );
is( "$updoc2->{_id}", "$updoc->{_id}", "same doc updated, not recreated" );
cmp_ok( $updoc2->{lastupdate}, '>=', $updoc->{lastupdate}, "lastupdate refreshed" );

# (a) nodedown true -> error doc, every cycle, still no event created here.
# level/details are read directly off the live catchall
# ($catchall_data->{nodedownlevel}/{nodedowndetails}), which handle_down
# piggybacks onto its own catchall save - no DB read from pingable() at all.
#
# (a1) fallback sub-case: nodedown true but the catchall doesn't have the
# nodedownlevel/nodedowndetails keys yet (e.g. a catchall saved before this
# change shipped, or nodedown flipped by something other than handle_down).
delete $catchall_data->{nodedownlevel};
delete $catchall_data->{nodedowndetails};
$catchall_data->{nodedown} = "true";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 100 );
my $pingable_down = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
ok( !$pingable_down, "pingable() returned false for fresh loss=100 data" );

my $expected_fallback_level = $C->{default_event_level} // "Major";
my ( $downcnt, $downdoc ) = opdoc("Node Down");
is( $downcnt, 1, "still exactly one Node Down doc while down (upsert identity)" );
is( $downdoc->{status}, "error", "doc status is error while nodedown=true" );
is( $downdoc->{level}, $expected_fallback_level,
	"no nodedownlevel on catchall -> doc falls back to default_event_level" );
is( $downdoc->{details}, "Ping failed",
	"no nodedowndetails on catchall -> doc falls back to 'Ping failed'" );
is( "$downdoc->{_id}", "$updoc->{_id}", "same doc flipped to error, not recreated" );
ok( !$node->eventExist("Node Down"),
	"pingable()'s new branch never created a Node Down event on its own" );

# (a2) direct-read sub-case: catchall carries nodedownlevel/nodedowndetails
# values that are deliberately different from the fallback defaults above -
# proves pingable() actually reads these two catchall keys, rather than the
# assertions above merely happening to match the fallback by coincidence.
$catchall_data->{nodedownlevel}   = "Critical";
$catchall_data->{nodedowndetails} = "seeded catchall detail, not the fallback string";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 100 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );

my ( $downcnt2, $downdoc2 ) = opdoc("Node Down");
is( $downcnt2, 1, "still exactly one Node Down doc (upsert identity)" );
is( $downdoc2->{level}, "Critical",
	"doc level came from catchall nodedownlevel, not the fallback" );
is( $downdoc2->{details}, "seeded catchall detail, not the fallback string",
	"doc details came from catchall nodedowndetails, not the fallback" );
is( "$downdoc2->{_id}", "$updoc->{_id}", "same doc, not recreated" );
ok( !$node->eventExist("Node Down"), "still no real event - purely a catchall-driven read" );

# (b) nodedown flips back to false -> doc refreshes back to ok
$catchall_data->{nodedown} = "false";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $backcnt, $backdoc ) = opdoc("Node Down");
is( $backcnt, 1, "still exactly one Node Down doc after clearing (upsert identity)" );
is( $backdoc->{status}, "ok", "doc flipped back to ok when nodedown=false" );
is( "$backdoc->{_id}", "$updoc->{_id}", "same doc used throughout" );

# ---------------------------------------------------------------------------
# End-to-end: drive the whole chain for real via handle_down() - the
# production write side of the OMK-12605 follow-up redesign. handle_down()
# calls notify(), which creates the real "Node Down" event, and piggybacks
# that event's resolved level/details onto the very same catchall save that
# already sets the nodedown flag (Node.pm ~2205-2219). pingable()'s
# $mustping==false branch must then read those same catchall values back out
# with zero extra DB access, and the two must agree.
# ---------------------------------------------------------------------------
ok( !$node->eventExist("Node Down"), "no real Node Down event before handle_down" );

$node->handle_down(
	sys                => $S,
	type               => "node",
	up                 => 0,
	details            => "real handle_down down test",
	catchall_inventory => $catchall_inv,
);
ok( $node->eventExist("Node Down"), "handle_down created the real Node Down event" );
ok( NMISNG::Util::getbool( $catchall_data->{nodedown} ), "handle_down set nodedown=true on the catchall" );
ok( defined $catchall_data->{nodedownlevel} && length( $catchall_data->{nodedownlevel} ),
	"handle_down piggybacked a non-empty nodedownlevel onto the catchall save" );
ok( defined $catchall_data->{nodedowndetails} && length( $catchall_data->{nodedowndetails} ),
	"handle_down piggybacked a non-empty nodedowndetails onto the catchall save" );

# what handle_down's own notify() call actually resolved, read independently
# via the event object (test-only verification, not part of the production
# read path) - proves the catchall keys are the SAME values notify() chose,
# not just "some" values.
my $real_event = $node->event( event => "Node Down", element => "" );
$real_event->load();
ok( $real_event->exists, "the real Node Down event is loadable" );
is( $catchall_data->{nodedownlevel}, $real_event->level,
	"catchall nodedownlevel matches the real event's level" );
is( $catchall_data->{nodedowndetails}, $real_event->details,
	"catchall nodedowndetails matches the real event's details" );

seed_fresh_ping( loss => 100 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $e2ecnt, $e2edoc ) = opdoc("Node Down");
is( $e2ecnt, 1, "end-to-end: still exactly one Node Down doc (upsert identity)" );
is( $e2edoc->{status}, "error", "end-to-end: doc status is error" );
is( $e2edoc->{level}, $catchall_data->{nodedownlevel},
	"end-to-end: doc level matches what handle_down piggybacked onto the catchall" );
is( $e2edoc->{details}, $catchall_data->{nodedowndetails},
	"end-to-end: doc details match what handle_down piggybacked onto the catchall" );

# clean up the real event so it doesn't leak into any later test in this file
$node->handle_down(
	sys                => $S,
	type               => "node",
	up                 => 1,
	details            => "real handle_down up test (cleanup)",
	catchall_inventory => $catchall_inv,
);

# ---------------------------------------------------------------------------
# Follow-up Task 2 (2026-08-04 fping/dashboard follow-up): pingable() must
# also refresh a "Backup Host Down" operational status doc every collect()
# cycle when fping owns the up/down decision - same discipline as Task 1's
# Node Down handling, but gated on the node being multihomed (host_backup
# configured). A node without host_backup must get NO status document for
# this event at all, ever - not ok, not error.
# ---------------------------------------------------------------------------

# (c) node has no host_backup configured (the shared test node's stock
# state). Even if something else sets backupdown=true on the catchall,
# pingable() must not create any "Backup Host Down" doc at all.
ok( !$node->configuration->{host_backup}, "test node has no host_backup configured yet" );
( my $precnt_backup ) = opdoc("Backup Host Down");
is( $precnt_backup, 0, "no Backup Host Down doc exists yet" );

$catchall_data->{backupdown} = "true";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
( my $nobackupcnt ) = opdoc("Backup Host Down");
is( $nobackupcnt, 0, "still no Backup Host Down doc without host_backup configured, even with backupdown=true" );
delete $catchall_data->{backupdown};

# now make the node multihomed for the rest of this section.
$pcfg = $node->configuration;
$pcfg->{host_backup} = "10.10.99.99";
$node->configuration($pcfg);
ok( $node->configuration->{host_backup}, "test node now has host_backup configured" );

# (a) backupdown true -> error doc, level/details read from the catchall,
# same piggyback mechanism as nodedown/nodedownlevel/nodedowndetails.
#
# (a1) fallback sub-case: backupdown true but the catchall doesn't have the
# backupdownlevel/backupdowndetails keys yet.
delete $catchall_data->{backupdownlevel};
delete $catchall_data->{backupdowndetails};
$catchall_data->{backupdown} = "true";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );

my $expected_backup_fallback_level = $C->{default_event_level} // "Major";
my ( $backupdowncnt, $backupdowndoc ) = opdoc("Backup Host Down");
is( $backupdowncnt, 1, "exactly one Backup Host Down doc created" );
is( $backupdowndoc->{status}, "error", "doc status is error while backupdown=true" );
is( $backupdowndoc->{level}, $expected_backup_fallback_level,
	"no backupdownlevel on catchall -> doc falls back to default_event_level" );
is( $backupdowndoc->{details}, "Backup ping failed",
	"no backupdowndetails on catchall -> doc falls back to 'Backup ping failed'" );
ok( !$node->eventExist("Backup Host Down"),
	"pingable()'s new branch never created a Backup Host Down event on its own" );

# (a2) direct-read sub-case: catchall carries backupdownlevel/backupdowndetails
# values deliberately different from the fallback defaults - proves pingable()
# actually reads these two catchall keys.
$catchall_data->{backupdownlevel}   = "Critical";
$catchall_data->{backupdowndetails} = "seeded backup catchall detail, not the fallback string";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );

my ( $backupdowncnt2, $backupdowndoc2 ) = opdoc("Backup Host Down");
is( $backupdowncnt2, 1, "still exactly one Backup Host Down doc (upsert identity)" );
is( $backupdowndoc2->{level}, "Critical",
	"doc level came from catchall backupdownlevel, not the fallback" );
is( $backupdowndoc2->{details}, "seeded backup catchall detail, not the fallback string",
	"doc details came from catchall backupdowndetails, not the fallback" );
is( "$backupdowndoc2->{_id}", "$backupdowndoc->{_id}", "same doc, not recreated" );

# (b) backup genuinely recovers (live data) -> doc refreshes back to ok.
# Also clears the flag, though it's no longer what the decision reads -
# see the Fix 2d block later in this file for proof of that specifically.
$catchall_data->{backupdown} = "false";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0, backup_loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $backupokcnt, $backupokdoc ) = opdoc("Backup Host Down");
is( $backupokcnt, 1, "still exactly one Backup Host Down doc after clearing (upsert identity)" );
is( $backupokdoc->{status}, "ok", "doc flipped back to ok when backupdown=false" );
is( "$backupokdoc->{_id}", "$backupdowndoc->{_id}", "same doc used throughout" );

# (d) end-to-end: drive handle_down(type => "backup", ...) for real, the
# production write side. handle_down() calls notify(), which creates the
# real "Backup Host Down" event and piggybacks that event's resolved
# level/details onto the same catchall save that sets the backupdown flag
# (Node.pm handle_down, the (snmp|wmi|node|backup) branch). pingable()'s
# $mustping==false branch must then read those same catchall values back out,
# and the two must agree - proving the piggyback plumbing actually works,
# not just the fallback path exercised above.
ok( !$node->eventExist("Backup Host Down"), "no real Backup Host Down event before handle_down" );

$node->handle_down(
	sys                => $S,
	type               => "backup",
	up                 => 0,
	details            => "real backup handle_down down test",
	catchall_inventory => $catchall_inv,
);
ok( $node->eventExist("Backup Host Down"), "handle_down created the real Backup Host Down event" );
ok( NMISNG::Util::getbool( $catchall_data->{backupdown} ), "handle_down set backupdown=true on the catchall" );
ok( defined $catchall_data->{backupdownlevel} && length( $catchall_data->{backupdownlevel} ),
	"handle_down piggybacked a non-empty backupdownlevel onto the catchall save" );
ok( defined $catchall_data->{backupdowndetails} && length( $catchall_data->{backupdowndetails} ),
	"handle_down piggybacked a non-empty backupdowndetails onto the catchall save" );

# what handle_down's own notify() call actually resolved, read independently
# via the event object - proves the catchall keys are the SAME values
# notify() chose, and (since this is a different event than Node Down) that
# the level travelling through is specific to this event, not a leftover
# from the Node Down test above.
my $real_backup_event = $node->event( event => "Backup Host Down", element => "" );
$real_backup_event->load();
ok( $real_backup_event->exists, "the real Backup Host Down event is loadable" );
is( $catchall_data->{backupdownlevel}, $real_backup_event->level,
	"catchall backupdownlevel matches the real event's level" );
is( $catchall_data->{backupdowndetails}, $real_backup_event->details,
	"catchall backupdowndetails matches the real event's details" );

seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $e2ebackupcnt, $e2ebackupdoc ) = opdoc("Backup Host Down");
is( $e2ebackupcnt, 1, "end-to-end: still exactly one Backup Host Down doc (upsert identity)" );
is( $e2ebackupdoc->{status}, "error", "end-to-end: doc status is error" );
is( $e2ebackupdoc->{level}, $catchall_data->{backupdownlevel},
	"end-to-end: doc level matches what handle_down piggybacked onto the catchall" );
is( $e2ebackupdoc->{details}, $catchall_data->{backupdowndetails},
	"end-to-end: doc details match what handle_down piggybacked onto the catchall" );

# clean up the real event so it doesn't leak into any later test in this file
$node->handle_down(
	sys                => $S,
	type               => "backup",
	up                 => 1,
	details            => "real backup handle_down up test (cleanup)",
	catchall_inventory => $catchall_inv,
);

# ---------------------------------------------------------------------------
# Follow-up Task 3 (2026-08-04 fping/dashboard follow-up): prove that
# pingable()'s Node Down / Backup Host Down writes (Follow-up Tasks 1-2
# above) actually reach the per-node dashboard JSON file. This is the same
# dashnode_context push mechanism Task 7 above already proved for a
# notify()-raised event (Status::save()'s call to update_dashnode_data,
# gated on enable_dashnode_file); no new wiring exists for this task,
# because pingable() runs inside collect()'s own process and calls the same
# NMISNG::Status::save_operational_status() -> Status->save() path. This is
# end-to-end proof that Tasks 1-2's direct writes flow through it too, the
# same way Interface Down/SNMP Down already do.
# ---------------------------------------------------------------------------
$C->{enable_dashnode_file} = 'true';
my $dashfile = $C->{'<nmis_var>'} . "/" . $node->name . "-node.json";

# --- Node Down: down case -> error entry, in-memory and on disk ---
# Use the real setup function collect()/update() actually call, instead of
# hand-seeding dashnode_context, so this test pins the real production
# contract: load_dashnode_data() -> pingable() -> save_dashnode_data(), in
# that order, inside collect() (lib/NMISNG/Node.pm:9643/9668/9924) and
# update() (lib/NMISNG/Node.pm:7355/7425/7617). force => 1 mirrors collect()
# on a forced run and skips reading any pre-existing dashboard file, giving
# the same fresh { status => {} } shape the hand-seed used to construct
# directly, but produced by the function under test rather than assumed.
$node->load_dashnode_data( op => 'collect', force => 1 );
delete $catchall_data->{nodedownlevel};
delete $catchall_data->{nodedowndetails};
$catchall_data->{nodedown} = "true";
$catchall_inv->save( node => $node, update => 1 );
# host_backup is still configured on the test node here, so a total outage
# needs BOTH addresses unreachable - that is the only state in which "Node
# Down" is genuinely true for a multihomed node (bin/nmisd maps exactly this
# state to the node event; primary-dead-backup-alive is Backup/failover, not
# Node Down). Before the blind-review fix that made $pingresult the up/down
# signal, this seed's ping data was simply never consulted and only the
# catchall flag decided, so backup_loss was irrelevant here.
seed_fresh_ping( loss => 100, backup_loss => 100 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );

my $dnstatus2 = $nmisng->{dashnode_context}{data}{status};
ok( exists $dnstatus2->{"Node Down--"},
	"Follow-up Task 3: dashnode context gained Node Down--element key" );
is( $dnstatus2->{"Node Down--"}{method}, "Operational",
	"Follow-up Task 3: dashnode Node Down entry method is Operational" );
is( $dnstatus2->{"Node Down--"}{status}, "error",
	"Follow-up Task 3: dashnode Node Down entry status is error" );

ok( $node->save_dashnode_data(), "Follow-up Task 3: save_dashnode_data succeeded (Node Down, down)" );
ok( -r $dashfile, "Follow-up Task 3: dashnode file written" );
my $dashdata2 = NMISNG::Util::readFiletoHash( file => $dashfile, json => 1 );
ok( exists $dashdata2->{status}{"Node Down--"},
	"Follow-up Task 3: dashnode file contains the Node Down entry" );
is( $dashdata2->{status}{"Node Down--"}{status}, "error",
	"Follow-up Task 3: file entry carries status error (Node Down, down)" );
ok( !defined $nmisng->{dashnode_context},
	"Follow-up Task 3: dashnode_context cleared after save" );

# --- Node Down: healthy case -> ok entry, in-memory and on disk ---
$nmisng->{dashnode_context} = { op => 'collect', data => { status => {} } };
$catchall_data->{nodedown} = "false";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );

my $dnstatus3 = $nmisng->{dashnode_context}{data}{status};
ok( exists $dnstatus3->{"Node Down--"},
	"Follow-up Task 3: dashnode context has Node Down--element key (healthy)" );
is( $dnstatus3->{"Node Down--"}{status}, "ok",
	"Follow-up Task 3: dashnode Node Down entry status is ok when nodedown=false" );

ok( $node->save_dashnode_data(), "Follow-up Task 3: save_dashnode_data succeeded (Node Down, healthy)" );
my $dashdata3 = NMISNG::Util::readFiletoHash( file => $dashfile, json => 1 );
is( $dashdata3->{status}{"Node Down--"}{status}, "ok",
	"Follow-up Task 3: file entry carries status ok (Node Down, healthy)" );

# --- Backup Host Down: down case -> error entry, in-memory and on disk ---
# (host_backup is still configured on the test node at this point in the file)
$nmisng->{dashnode_context} = { op => 'collect', data => { status => {} } };
delete $catchall_data->{backupdownlevel};
delete $catchall_data->{backupdowndetails};
$catchall_data->{backupdown} = "true";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );

my $dnstatus4 = $nmisng->{dashnode_context}{data}{status};
ok( exists $dnstatus4->{"Backup Host Down--"},
	"Follow-up Task 3: dashnode context gained Backup Host Down--element key" );
is( $dnstatus4->{"Backup Host Down--"}{method}, "Operational",
	"Follow-up Task 3: dashnode Backup Host Down entry method is Operational" );
is( $dnstatus4->{"Backup Host Down--"}{status}, "error",
	"Follow-up Task 3: dashnode Backup Host Down entry status is error" );

ok( $node->save_dashnode_data(), "Follow-up Task 3: save_dashnode_data succeeded (Backup Host Down, down)" );
my $dashdata4 = NMISNG::Util::readFiletoHash( file => $dashfile, json => 1 );
ok( exists $dashdata4->{status}{"Backup Host Down--"},
	"Follow-up Task 3: dashnode file contains the Backup Host Down entry" );
is( $dashdata4->{status}{"Backup Host Down--"}{status}, "error",
	"Follow-up Task 3: file entry carries status error (Backup Host Down, down)" );

# --- Backup Host Down: healthy case -> ok entry, in-memory and on disk ---
$nmisng->{dashnode_context} = { op => 'collect', data => { status => {} } };
$catchall_data->{backupdown} = "false";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0, backup_loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );

my $dnstatus5 = $nmisng->{dashnode_context}{data}{status};
is( $dnstatus5->{"Backup Host Down--"}{status}, "ok",
	"Follow-up Task 3: dashnode Backup Host Down entry status is ok when backupdown=false" );

ok( $node->save_dashnode_data(), "Follow-up Task 3: save_dashnode_data succeeded (Backup Host Down, healthy)" );
my $dashdata5 = NMISNG::Util::readFiletoHash( file => $dashfile, json => 1 );
is( $dashdata5->{status}{"Backup Host Down--"}{status}, "ok",
	"Follow-up Task 3: file entry carries status ok (Backup Host Down, healthy)" );

$C->{enable_dashnode_file} = 'false';

# ---------------------------------------------------------------------------
# Blind-review fix wave (2026-08-05): seven fixes found by two independent
# full-branch reviews. Each block below is named for the fix it pins.
# ---------------------------------------------------------------------------

# --- Fix 7: handle_down clears its piggybacked level/details on the way up ---
# The down path sets <type>downlevel/<type>downdetails on the catchall so
# pingable() can read them without a DB hit. Before this fix the up path left
# them behind, so a later outage whose notify() returned no usable event
# object would silently reuse the PREVIOUS outage's text instead of falling
# through to pingable()'s own generic fallback.
delete $catchall_data->{nodedownlevel};
delete $catchall_data->{nodedowndetails};
$node->handle_down(
	sys                => $S,
	type               => "node",
	up                 => 0,
	details            => "fix7 down: piggyback keys must appear",
	catchall_inventory => $catchall_inv,
);
ok( defined $catchall_data->{nodedownlevel} && length( $catchall_data->{nodedownlevel} ),
	"Fix 7: handle_down(down) set nodedownlevel on the catchall" );
ok( defined $catchall_data->{nodedowndetails} && length( $catchall_data->{nodedowndetails} ),
	"Fix 7: handle_down(down) set nodedowndetails on the catchall" );

$node->handle_down(
	sys                => $S,
	type               => "node",
	up                 => 1,
	details            => "fix7 up: piggyback keys must be cleared",
	catchall_inventory => $catchall_inv,
);
ok( !defined $catchall_data->{nodedownlevel},
	"Fix 7: handle_down(up) cleared nodedownlevel, no stale text left behind" );
ok( !defined $catchall_data->{nodedowndetails},
	"Fix 7: handle_down(up) cleared nodedowndetails, no stale text left behind" );
ok( !NMISNG::Util::getbool( $catchall_data->{nodedown} ),
	"Fix 7: handle_down(up) still clears the nodedown flag itself" );

# --- Fix 2a: a stale nodedown flag must not force a false "error" ---
# If a Node Down event is closed out of band (GUI ack, API delete, escalation)
# while nodedown stays 'true', nothing ever resets the flag. Reading the flag
# alone left the node reporting error forever, and actively fought the
# Event->delete close hook. $pingresult is recomputed from the cached fping
# data on every call and cannot drift like that.
$pcfg = $node->configuration;
delete $pcfg->{host_backup};    # single-homed for this scenario
$node->configuration($pcfg);
ok( !$node->eventExist("Node Down"),
	"Fix 2a: no active Node Down event, so the flag below is genuinely stale" );

$catchall_data->{nodedown} = "true";    # set directly, bypassing handle_down
delete $catchall_data->{nodedownlevel};
delete $catchall_data->{nodedowndetails};
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0 );           # ...but the node is actually answering
my $stale_pingable = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
ok( $stale_pingable, "Fix 2a: pingable() reports the node reachable (loss=0)" );

my ( $stalecnt, $staledoc ) = opdoc("Node Down");
is( $stalecnt, 1, "Fix 2a: exactly one Node Down doc (upsert identity)" );
is( $staledoc->{status}, "ok",
	"Fix 2a: stale nodedown=true does NOT produce a false error doc for a reachable node" );
is( $staledoc->{level}, "Normal", "Fix 2a: the ok doc's level is Normal" );
ok( NMISNG::Util::getbool( $catchall_data->{nodedown} ),
	"Fix 2a: the stale flag is still set - the fix is in how it is read, not a write that resets it" );

# --- Fix 2b: total outage must not report Backup Host Down as "ok" ---
# When both primary and backup are unreachable, bin/nmisd maps that state to
# plain "node" down (bin/nmisd ~3041-3046) and never sets backupdown at all,
# so trusting the flag alone reported a false "ok" for Backup Host Down during
# exactly the outage it exists to describe.
$pcfg = $node->configuration;
$pcfg->{host_backup} = "10.10.99.99";
$node->configuration($pcfg);
delete $catchall_data->{backupdown};            # never set by nmisd for this state
delete $catchall_data->{backupdownlevel};
delete $catchall_data->{backupdowndetails};
$catchall_data->{nodedown} = "true";            # what nmisd DOES set instead
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 100, backup_loss => 100 );    # both addresses dead
my $total_outage_pingable = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
ok( !$total_outage_pingable,
	"Fix 2b: pingable() false when neither primary nor backup answers" );
ok( !defined $catchall_data->{backupdown},
	"Fix 2b: backupdown was never set, exactly as bin/nmisd leaves it in a total outage" );

my ( $tbcnt, $tbdoc ) = opdoc("Backup Host Down");
is( $tbcnt, 1, "Fix 2b: exactly one Backup Host Down doc (upsert identity)" );
isnt( $tbdoc->{status}, "ok",
	"Fix 2b: Backup Host Down is NOT falsely ok while the backup address is unreachable" );
is( $tbdoc->{status}, "error",
	"Fix 2b: Backup Host Down reports error during a total outage, with no backupdown flag" );

my ( undef, $tndoc ) = opdoc("Node Down");
is( $tndoc->{status}, "error",
	"Fix 2b: Node Down also reports error in the same call (both addresses dead)" );

# --- Fix 2c: backup ping data not yet available must not read as "up" ---
# A just-added host_backup, or a sibling not yet pinged this cycle, has no
# backup_loss at all (not even a failing one) - undef < 100 is true, which
# would wrongly read as "backup responded" instead of "we don't know yet".
# Leaving $ping_loss at the primary's own (already-100) value when the
# backup hasn't been measured must report down, not guess up.
delete $catchall_data->{backupdown};
delete $catchall_data->{backupdownlevel};
delete $catchall_data->{backupdowndetails};
$catchall_data->{nodedown} = "true";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 100 );    # primary dead, no backup_loss key at all
my $unmeasured_pingable = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
ok( !$unmeasured_pingable,
	"Fix 2c: pingable() false when primary is dead and backup has no data yet" );

my ( undef, $unmeasured_ndoc ) = opdoc("Node Down");
isnt( $unmeasured_ndoc->{status}, "ok",
	"Fix 2c: Node Down is NOT falsely ok when backup data is simply missing" );
is( $unmeasured_ndoc->{status}, "error",
	"Fix 2c: Node Down reports error rather than guessing up from missing backup data" );

# --- Fix 2d: a stuck backupdown flag must not force a permanent false error ---
# Two independent reviews found the same bug class Fix 2a already closed for
# Node Down, reopened for Backup Host Down: if the backup's own event is
# closed out-of-band (GUI/API) rather than through handle_down()'s own up
# transition, backupdown never gets reset to 'false' - bin/nmisd's clear
# gate only runs when the event still exists and is active. Every
# subsequent cycle would then keep reporting error even after the backup
# genuinely recovered, fighting the Event->delete close hook. Backup Host
# Down must now be decided from live ping data ($backup_loss), the same
# way Node Down is decided from $pingresult - not from the flag at all.
$catchall_data->{backupdown}        = "true";    # stuck from a resolved, never-cleared outage
$catchall_data->{backupdownlevel}   = "Major";
$catchall_data->{backupdowndetails} = "stale text from the old outage";
$catchall_data->{nodedown}          = "false";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0, backup_loss => 0 );    # both addresses genuinely fine now
my $stuck_flag_pingable = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
ok( $stuck_flag_pingable, "Fix 2d: pingable() reports the node reachable" );
ok( NMISNG::Util::getbool( $catchall_data->{backupdown} ),
	"Fix 2d: the stale backupdown flag is still 'true' - proving the fix reads live data, not a write that resets the flag" );

my ( $stuckcnt, $stuckdoc ) = opdoc("Backup Host Down");
is( $stuckcnt, 1, "Fix 2d: exactly one Backup Host Down doc (upsert identity)" );
isnt( $stuckdoc->{status}, "error",
	"Fix 2d: Backup Host Down is NOT stuck at error because of the stale flag" );
is( $stuckdoc->{status}, "ok",
	"Fix 2d: Backup Host Down correctly reports ok once the backup is genuinely reachable again" );

# --- Fix 1a: Config.nmis status_summary_exclude_events ---
# Events.nmis is never auto-merged on upgrade, so its per-event Status flags
# cannot reach an existing install. This site-wide list is consulted in
# ADDITION to the per-event flag, and must behave identically: skip from the
# health calculation, never stamp "ignored".
my $saved_exclude = $C->{status_summary_exclude_events};
delete $C->{status_summary_exclude_events};

# compute_thresholds returns early for a down node (NMISNG.pm, "skip if node
# down"), and the Fix 2b block above deliberately left nodedown=true. Clear it
# first, or both runs below are silent no-ops reading a stale summary.
$catchall_data->{nodedown} = "false";
$catchall_inv->save( node => $node, update => 1 );
ok( !NMISNG::Util::getbool( $catchall_data->{nodedown} ),
	"Fix 1a: node marked up so compute_thresholds actually runs" );

# a synthetic Operational error doc with no Events.nmis entry of its own, so
# its per-event Status flag defaults to true and it counts normally
NMISNG::DB::insert(
	collection => $nmisng->status_collection(),
	record => { %$common, method => "Operational", event => "OMK12605 CfgExcluded",
		lastupdate => time },
);
$nmisng->compute_thresholds( sys => $S, running_independently => 0 );
my $summary_counted = $S->inventory( concept => 'catchall' )->data->{status_summary};

$C->{status_summary_exclude_events} = " OMK12605 CfgExcluded , OMK12605 Unused ";
$nmisng->compute_thresholds( sys => $S, running_independently => 0 );
my $summary_excluded = $S->inventory( concept => 'catchall' )->data->{status_summary};

cmp_ok( $summary_counted, '<', 100,
	"Fix 1a: with the event unlisted, its error doc drags status_summary below 100" );
cmp_ok( $summary_excluded, '>', $summary_counted,
	"Fix 1a: listing the event raised status_summary, so its error doc stopped counting" );
my $md_excl = $nmisng->get_status_model(
	filter => { event => "OMK12605 CfgExcluded", node_uuid => $node->uuid } );
is( $md_excl->count, 1, "Fix 1a: the excluded doc is still present, not deleted" );
is( $md_excl->data->[0]{status}, "error",
	"Fix 1a: excluded doc keeps its honest error, no 'ignored' stamp (same as Status=false)" );

if   ( defined $saved_exclude ) { $C->{status_summary_exclude_events} = $saved_exclude }
else                            { delete $C->{status_summary_exclude_events} }

# --- Fix 1b: Config.nmis operational_status_untracked_events ---
my $saved_untracked = $C->{operational_status_untracked_events};
$C->{operational_status_untracked_events} = " OMK12605 CfgUntracked , OMK12605 CfgUntracked2 ";

NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 CfgUntracked",
	status => "error", level => "Major", details => "must not be written",
);
( $cnt ) = opdoc("OMK12605 CfgUntracked");
is( $cnt, 0, "Fix 1b: config untracked-events list gated the write, same as TrackStatus=false" );

NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 CfgUntracked2",
	status => "error", level => "Major", details => "must not be written either",
);
( $cnt ) = opdoc("OMK12605 CfgUntracked2");
is( $cnt, 0, "Fix 1b: surrounding whitespace on list entries is trimmed before matching" );

# an event NOT on the list is unaffected
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 CfgTracked",
	status => "error", level => "Major", details => "written normally",
);
( $cnt ) = opdoc("OMK12605 CfgTracked");
is( $cnt, 1, "Fix 1b: an event absent from the list writes normally" );

# ...and the same event writes once taken off the list, proving the list gated it
delete $C->{operational_status_untracked_events};
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 CfgUntracked",
	status => "error", level => "Major", details => "written once off the list",
);
( $cnt ) = opdoc("OMK12605 CfgUntracked");
is( $cnt, 1, "Fix 1b: the very same event writes once removed from the list" );

if   ( defined $saved_untracked ) { $C->{operational_status_untracked_events} = $saved_untracked }
else                              { delete $C->{operational_status_untracked_events} }

# --- Fix 3: the event name is escaped before it reaches a regex ---
# save_operational_status interpolates the event name into the
# non_stateful_events match. This helper now runs on every checkEvent too,
# including a path where the name comes from custom alert data in the
# database, so an unbalanced metacharacter used to die and abort the poll.
my $meta_name = "OMK12605 Unbalanced ( Paren";
eval {
	NMISNG::Status::save_operational_status(
		nmisng => $nmisng, node => $node, event => $meta_name,
		status => "error", level => "Major", details => "metachar raise",
	);
	1;
};
ok( !$@, "Fix 3: an event name with an unbalanced regex metacharacter did not die" )
	or diag($@);
my ( $mcnt, $mdoc ) = opdoc($meta_name);
is( $mcnt, 1, "Fix 3: ...and its doc was written like any other event" );
is( $mdoc->{status}, "error", "Fix 3: metacharacter-named doc carries the right status" );

# and the stateless check still matches such a name LITERALLY, not as a pattern
my $saved_nonstateful = $C->{non_stateful_events};
$C->{non_stateful_events} = "$saved_nonstateful, OMK12605 (Meta) Event";
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 (Meta) Event",
	status => "error", level => "Major", details => "should be gated stateless",
);
( $cnt ) = opdoc("OMK12605 (Meta) Event");
is( $cnt, 0,
	"Fix 3: a metacharacter-named event listed in non_stateful_events is gated stateless (literal match)" );

$C->{non_stateful_events} = $saved_nonstateful;
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 (Meta) Event",
	status => "error", level => "Major", details => "not stateless any more",
);
( $cnt ) = opdoc("OMK12605 (Meta) Event");
is( $cnt, 1, "Fix 3: ...and it writes normally once off the stateless list" );

# --- Fix 4: the eval wrap turns an unexpected die into a returned error ---
# Reachable from a real caller now that checkEvent forwards $args{inventory_id}:
# NMISNG::DB::make_oid dies on anything that is not 12 packed bytes or 24 hex.
my $bad_err = eval {
	NMISNG::Status::save_operational_status(
		nmisng  => $nmisng, node => $node, event => "OMK12605 BadOid",
		status  => "error", level => "Major", details => "malformed inventory_id",
		inventory_id => "definitely-not-an-oid",
	);
};
ok( !$@, "Fix 4: a malformed inventory_id did not propagate a die to the caller" )
	or diag($@);
ok( defined $bad_err && $bad_err =~ /^save_operational_status died for OMK12605 BadOid/,
	"Fix 4: ...it came back as an error string instead" )
	or diag( defined $bad_err ? $bad_err : "(undef)" );
( $cnt ) = opdoc("OMK12605 BadOid");
is( $cnt, 0, "Fix 4: nothing was written when the save died" );

# success path is untouched by the wrap: same call without the bad id
my $good_err = NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 BadOid",
	status => "error", level => "Major", details => "valid this time",
);
ok( !$good_err, "Fix 4: the eval wrap is transparent on the success path" ) or diag($good_err);
( $cnt, $doc ) = opdoc("OMK12605 BadOid");
is( $cnt, 1, "Fix 4: ...and the doc is written normally" );
is( $doc->{details}, "valid this time", "Fix 4: ...with the expected content" );

# --- Fix 5: checkEvent forwards inventory_id to the helper ---
# notify's call always passed it; checkEvent's did not, so the field vanished
# from the doc on every flip to ok and reappeared on the flip back to error.
Compat::NMIS::checkEvent(
	sys          => $S,
	event        => "OMK12605 InvId Event",
	element      => '',
	details      => "healthy, with an inventory id",
	inventory_id => $catchall_inv->id,
);
my ( $icnt, $idoc ) = opdoc("OMK12605 InvId Event");
is( $icnt, 1, "Fix 5: checkEvent created the ok doc" );
is( $idoc->{status}, "ok", "Fix 5: ...with status ok" );
ok( defined $idoc->{inventory_id},
	"Fix 5: checkEvent's ok doc carries inventory_id (silently dropped before this fix)" );
is( "$idoc->{inventory_id}", "" . $catchall_inv->id,
	"Fix 5: ...and it matches the inventory_id the caller passed" );

# --- Fix 6: close_operational_status is a no-op on an already-ok doc ---
# On the ordinary clear path checkEvent writes an honest, specific details
# string, and escalation deletes the now-inactive event some time later. The
# Event->delete hook used to fire anyway and overwrite that with the generic
# "event closed".
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 OrdinaryClear",
	status => "error", level => "Major", details => "link flapped",
);
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 OrdinaryClear",
	status => "ok", level => "Normal", details => "ping ok after 3 retries",
);
NMISNG::Status::close_operational_status(
	nmisng => $nmisng, cluster_id => $node->cluster_id, node_uuid => $node->uuid,
	event  => "OMK12605 OrdinaryClear", element => '',
);
my ( $occnt, $ocdoc ) = opdoc("OMK12605 OrdinaryClear");
is( $occnt, 1, "Fix 6: still exactly one doc after the close hook ran" );
is( $ocdoc->{status}, "ok", "Fix 6: an already-ok doc stays ok" );
is( $ocdoc->{details}, "ping ok after 3 retries",
	"Fix 6: the close hook left the specific details string alone (no-op on an already-ok doc)" );

# contrast: a doc that IS still error is genuinely flipped and stamped
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 OutOfBandClear",
	status => "error", level => "Major", details => "still down when closed",
);
NMISNG::Status::close_operational_status(
	nmisng => $nmisng, cluster_id => $node->cluster_id, node_uuid => $node->uuid,
	event  => "OMK12605 OutOfBandClear", element => '',
);
my ( $obcnt, $obdoc ) = opdoc("OMK12605 OutOfBandClear");
is( $obcnt, 1, "Fix 6 contrast: still exactly one doc" );
is( $obdoc->{status}, "ok", "Fix 6 contrast: a still-error doc IS flipped to ok" );
is( $obdoc->{details}, "event closed",
	"Fix 6 contrast: ...and stamped with the generic close details" );

# leave the shared test node/catchall as we found them
$pcfg = $node->configuration;
$pcfg->{ping} = "false";
delete $pcfg->{host_backup};
$node->configuration($pcfg);

# --- END OF TESTS ---
cleanup_db();
done_testing();
