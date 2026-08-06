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
# Fix 11 (round 5): health_score_include_operational_events master gate
# ---------------------------------------------------------------------------
# Requested after the round 5 review flagged that health percentages change
# on upgrade for five events with no way to opt out. Defaults false (see
# Config.nmis) so an existing customer's health numbers don't move with
# nothing different in their network; a real error Operational doc must be
# completely excluded from the count while the gate is off, and a coexisting
# Threshold doc (unaffected by this gate) must still count normally.
ok( !NMISNG::Util::getbool( $C->{health_score_include_operational_events} ),
	"Fix 11: health_score_include_operational_events defaults false" );

NMISNG::DB::insert(
	collection => $nmisng->status_collection(),
	record => {
		cluster_id => $node->cluster_id, node_uuid => $node->uuid,
		element => '', property => '', index => '', class => '',
		section => '', source => '', value => '', method => "Threshold",
		event => "OMK12605 Gate Thr", property => "omk12605_gate_thr",
		# healthy (status ok): compute_thresholds only sets status_summary at
		# all when at least one counted doc is ok (count && countOk below,
		# NMISNG.pm ~819) - an all-error set never produces a percentage, so
		# this needs a healthy doc to exercise "was it counted" at all.
		level => "Normal", status => "ok", lastupdate => time,
	},
);
NMISNG::DB::insert(
	collection => $nmisng->status_collection(),
	record => {
		cluster_id => $node->cluster_id, node_uuid => $node->uuid,
		element => '', property => '', index => '', class => '',
		section => '', source => '', value => '', method => "Operational",
		event => "OMK12605 Gate Op",
		level => "Major", status => "error", lastupdate => time,
	},
);
$nmisng->compute_thresholds( sys => $S, running_independently => 0 );
my $gate_off_catchall = $S->inventory( concept => 'catchall' )->data;
ok( defined $gate_off_catchall->{status_summary},
	"Fix 11: status_summary still computed with the gate off (Threshold doc still counts)" );
cmp_ok( $gate_off_catchall->{status_summary}, '==', 100,
	"Fix 11: an error Operational doc does NOT drag status_summary down while the gate is off" );

# now turn it on: the same error doc, unchanged, must now count
$C->{health_score_include_operational_events} = 'true';
$nmisng->compute_thresholds( sys => $S, running_independently => 0 );
my $gate_on_catchall = $S->inventory( concept => 'catchall' )->data;
cmp_ok( $gate_on_catchall->{status_summary}, '<', 100,
	"Fix 11: the same error Operational doc DOES drag status_summary down once the gate is on" );
$C->{health_score_include_operational_events} = 'false';    # restore default for the rest of this file

# ---------------------------------------------------------------------------
# Task 5: compute_thresholds summary loop
# ---------------------------------------------------------------------------
# seed: a stale Threshold doc (must be swept) and a stale Operational doc
# (must survive), inserted directly so lastupdate can be in the past. The
# gate above is off by default, so this block turns it on to exercise the
# finer-grained per-event Status flag / exclude-list logic underneath it,
# same as before the gate existed.
$C->{health_score_include_operational_events} = 'true';
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
$C->{health_score_include_operational_events} = 'false';    # restore default

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

# (a) backup genuinely measured and failing (live data, not just the flag -
# round 3 blind review found the flag alone is no longer read at all) ->
# error doc, level/details read from the catchall, same piggyback mechanism
# as nodedown/nodedownlevel/nodedowndetails. backupdown is also set here to
# prove it's along for the ride, not the thing driving the decision.
#
# (a1) fallback sub-case: backup measured failing but the catchall doesn't
# have the backupdownlevel/backupdowndetails keys yet.
delete $catchall_data->{backupdownlevel};
delete $catchall_data->{backupdowndetails};
$catchall_data->{backupdown} = "true";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0, backup_loss => 100 );
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
seed_fresh_ping( loss => 0, backup_loss => 100 );
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
# Fix 10 (round 5): Node Polling Failover must also refresh every cycle for a
# ping-only multihomed node (SNMP disabled - the test node/$S here, snmp=>0
# from setup). Previously this event only ever got written by the SNMP-
# session-fallback code inside collect()/update(), which never runs at all
# without SNMP, and by the fping worker's own state machine on a transition
# only (bin/nmisd ~3041-3056) - so it went stale and never reached the
# dashnode file for exactly this node subset. host_backup is still
# configured on the test node at this point in the file.
# ---------------------------------------------------------------------------
ok( !$S->status->{snmp_enabled}, "Fix 10: test Sys has snmp disabled - the gap this fix closes" );

# clean slate: earlier blocks in this section already exercised pingable()
# with host_backup configured, so this event doc may already have been
# created as a side effect (correctly - that's this fix working). Remove it
# so every assertion below proves this path itself, not leftover state.
NMISNG::DB::remove(
	collection => $nmisng->status_collection(),
	query      => NMISNG::DB::get_query( and_part => {
		node_uuid => $node->uuid, method => "Operational", event => "Node Polling Failover" } ),
	just_one   => 0,
);
( my $precnt_failover ) = opdoc("Node Polling Failover");
is( $precnt_failover, 0, "Fix 10: no Node Polling Failover doc exists yet (clean slate)" );

# (a) primary down, backup up -> failed over, error doc
seed_fresh_ping( loss => 100, backup_loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $foverdowncnt, $foverdowndoc ) = opdoc("Node Polling Failover");
is( $foverdowncnt, 1, "Fix 10: a Node Polling Failover doc was created (primary down, backup up)" );
is( $foverdowndoc->{status}, "error", "Fix 10: ...status is error while failed over" );
ok( !$node->eventExist("Node Polling Failover"),
	"Fix 10: pingable()'s new branch never created a real event on its own" );

# (b) primary up -> back on the primary address, ok doc, same identity
seed_fresh_ping( loss => 0, backup_loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $foverokcnt, $foverokdoc ) = opdoc("Node Polling Failover");
is( $foverokcnt, 1, "Fix 10: still exactly one doc after recovery (upsert identity)" );
is( $foverokdoc->{status}, "ok", "Fix 10: ...flipped back to ok once the primary answers" );
is( "$foverokdoc->{_id}", "$foverdowndoc->{_id}", "Fix 10: same doc used throughout" );

# (c) total outage (both primary and backup down) -> NOT a "failover" state,
# that's Node Down's territory (bin/nmisd maps this to the plain node event,
# never raises Node Polling Failover for it) - the doc must be left alone,
# not asserted into either state.
seed_fresh_ping( loss => 100, backup_loss => 100 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $fovertotalcnt, $fovertotaldoc ) = opdoc("Node Polling Failover");
is( $fovertotalcnt, 1, "Fix 10: still exactly one doc after a total outage (no new write happened)" );
is( $fovertotaldoc->{status}, "ok",
	"Fix 10: doc is untouched by the total-outage cycle - still the last genuine reading (ok)" );
is( "$fovertotaldoc->{_id}", "$foverokdoc->{_id}", "Fix 10: same doc, not recreated or removed" );

# (d) an SNMP-enabled node must get NO write from pingable() here at all -
# that path is already covered every cycle by the existing SNMP-session
# code in collect()/update(), and writing from both places would race.
# Fresh doc identity (new element-less node's-worth of state isn't needed -
# reusing $S but flipping its cached snmp_enabled flag is enough to prove
# the guard).
$S->{snmp} = 1;
seed_fresh_ping( loss => 100, backup_loss => 0 );
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $foversnmpcnt, $foversnmpdoc ) = opdoc("Node Polling Failover");
is( $foversnmpcnt, 1, "Fix 10: still exactly one doc (no new write) once snmp_enabled is true" );
is( $foversnmpdoc->{status}, "ok",
	"Fix 10: doc still shows the last ping-only reading, untouched by this snmp-enabled cycle" );
$S->{snmp} = 0;    # restore for the rest of this file

# host_backup stays configured - Follow-up Task 3 just below still needs it
# (Fix 2a's own setup later in this file is what goes single-homed again).

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
# backup_loss is what drives the decision (round 3 blind review); backupdown
# is set alongside it only to prove it's not what's being read.
$nmisng->{dashnode_context} = { op => 'collect', data => { status => {} } };
delete $catchall_data->{backupdownlevel};
delete $catchall_data->{backupdowndetails};
$catchall_data->{backupdown} = "true";
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 0, backup_loss => 100 );
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

# --- Fix 2e (round 3): an unmeasured backup must not overwrite an existing
# doc with a false error, or a false ok ---
# Two independent reviews found that treating "no backup_loss in this cycle's
# ping record" the same as "backup confirmed down" produces a PERMANENT false
# error whenever the record simply wasn't written with backup data - not just
# for a brand-new node. This happens routinely: nmisd_fping_worker => false is
# a supported setting, the fping worker can fall behind or be unavailable, and
# pingable()'s OWN internal-ping ($mustping true) fallback never populates
# backup_loss at all. None of those describe the backup actually failing.
# The fix: skip the write entirely when backup_loss is undefined, leaving
# whatever the doc already correctly said, rather than asserting either
# state about a condition nothing measured this cycle.
$stuckdoc = ( opdoc("Backup Host Down") )[1];
is( $stuckdoc->{status}, "ok", "Fix 2e: precondition - Backup Host Down doc exists and is ok (from Fix 2d)" );
my $preexisting_backup_id = "$stuckdoc->{_id}";

seed_fresh_ping( loss => 0 );    # primary fine, no backup_loss key at all this cycle
my $unmeasured_backup_pingable = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
ok( $unmeasured_backup_pingable, "Fix 2e: pingable() still reports the node reachable" );

my ( $unmeasuredcnt, $unmeasureddoc ) = opdoc("Backup Host Down");
is( $unmeasuredcnt, 1, "Fix 2e: still exactly one Backup Host Down doc - no write happened, none was duplicated either" );
is( "$unmeasureddoc->{_id}", $preexisting_backup_id, "Fix 2e: same doc, untouched" );
is( $unmeasureddoc->{status}, "ok",
	"Fix 2e: Backup Host Down was NOT flipped to error just because this cycle had no backup measurement" );

# and the reverse: an existing ERROR doc must also survive an unmeasured
# cycle unchanged, not get silently cleared to ok either.
$catchall_data->{nodedown} = "true";    # unrelated to backup_loss; just makes the scenario realistic
$catchall_inv->save( node => $node, update => 1 );
seed_fresh_ping( loss => 100, backup_loss => 100 );    # genuinely down first
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( undef, $confirmeddowndoc ) = opdoc("Backup Host Down");
is( $confirmeddowndoc->{status}, "error", "Fix 2e: precondition - a genuinely-down doc exists" );

seed_fresh_ping( loss => 100 );    # still primary-dead, but backup_loss unmeasured this cycle
$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
my ( $stillerrcnt, $stillerrdoc ) = opdoc("Backup Host Down");
is( $stillerrcnt, 1, "Fix 2e: still exactly one doc after the unmeasured cycle" );
is( $stillerrdoc->{status}, "error",
	"Fix 2e: an existing error doc also survives an unmeasured cycle unchanged, not silently cleared" );
$catchall_data->{nodedown} = "false";
$catchall_inv->save( node => $node, update => 1 );

# --- Fix 2f (round 3): Backup Host Down must also refresh on the internal-
# ping ($mustping==true) fallback path, not just the fping-owned path ---
# A first blind-review round found Node Down was covered on both paths but
# Backup Host Down only on the fping-owned one - on a site where fping data
# is missing or stale (the code's own long-standing comment names "the case
# of a faulty fping worker"), an existing Backup Host Down entry would just
# stop refreshing and expire, and a node that never had one would never get
# one, on this path specifically. This exercises real synchronous pings
# (ext_ping), so it needs a real reachable and a real unreachable address,
# and a deliberately short timeout/retry count to keep it fast.
{
	my $saved_timeout = $C->{ping_timeout};
	my $saved_retries = $C->{ping_retries};
	$C->{ping_timeout} = 200;
	$C->{ping_retries} = 1;

	my $pcfg2 = $node->configuration;
	my $saved_host        = $pcfg2->{host};
	my $saved_host_backup = $pcfg2->{host_backup};
	$pcfg2->{host}        = "127.0.0.1";     # always answers
	$pcfg2->{host_backup} = "192.0.2.1";     # reserved, guaranteed never to answer
	$node->configuration($pcfg2);

	# force the internal-ping fallback: remove the node's cached "ping"
	# inventory entirely, so pingable() finds nothing fresh to trust and
	# falls back to ext_ping(), exactly like a missing/stale fping worker.
	NMISNG::DB::remove(
		collection => $nmisng->inventory_collection(),
		query      => NMISNG::DB::get_query( and_part => { node_uuid => $node->uuid, concept => "ping" } ),
		just_one   => 0,
	);
	# clean slate: remove any pre-existing Backup Host Down doc (from
	# earlier blocks above) so every assertion below genuinely proves this
	# path wrote/updated it, rather than passing by coincidence against
	# leftover state.
	NMISNG::DB::remove(
		collection => $nmisng->status_collection(),
		query      => NMISNG::DB::get_query( and_part => {
			node_uuid => $node->uuid, method => "Operational", event => "Backup Host Down" } ),
		just_one   => 0,
	);

	my $mustping_pingable = $node->pingable( sys => $S, catchall_inventory => $catchall_inv );
	ok( $mustping_pingable, "Fix 2f: pingable() reachable via the internal-ping fallback (primary answers)" );

	my ( $mustpingcnt, $mustpingdoc ) = opdoc("Backup Host Down");
	is( $mustpingcnt, 1, "Fix 2f: a Backup Host Down doc was created on the internal-ping path too" );
	is( $mustpingdoc->{status}, "error",
		"Fix 2f: Backup Host Down correctly reports error - primary answers, backup does not, on the fallback path" );

	# and the reverse: backup answers too -> ok, still on this same path.
	$pcfg2->{host_backup} = "127.0.0.1";     # both now answer
	$node->configuration($pcfg2);
	NMISNG::DB::remove(
		collection => $nmisng->inventory_collection(),
		query      => NMISNG::DB::get_query( and_part => { node_uuid => $node->uuid, concept => "ping" } ),
		just_one   => 0,
	);
	$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
	my ( undef, $mustpingokdoc ) = opdoc("Backup Host Down");
	is( $mustpingokdoc->{status}, "ok",
		"Fix 2f: Backup Host Down correctly reports ok when both addresses answer, on the fallback path" );

	# restore
	$pcfg2->{host}        = $saved_host;
	$pcfg2->{host_backup} = $saved_host_backup;
	$node->configuration($pcfg2);
	$C->{ping_timeout} = $saved_timeout;
	$C->{ping_retries} = $saved_retries;
	NMISNG::DB::remove(
		collection => $nmisng->inventory_collection(),
		query      => NMISNG::DB::get_query( and_part => { node_uuid => $node->uuid, concept => "ping" } ),
		just_one   => 0,
	);
}

# --- Fix 10b (round 5): Node Polling Failover must also refresh on the
# internal-ping ($mustping==true) fallback path, same reasoning as Fix 2f
# did for Backup Host Down - a site with fping disabled/behind/unavailable
# must not lose this refresh just because it's on the fallback path.
{
	my $saved_timeout = $C->{ping_timeout};
	my $saved_retries = $C->{ping_retries};
	$C->{ping_timeout} = 200;
	$C->{ping_retries} = 1;

	my $pcfg3 = $node->configuration;
	my $saved_host        = $pcfg3->{host};
	my $saved_host_backup = $pcfg3->{host_backup};
	$pcfg3->{host}        = "192.0.2.1";     # reserved, guaranteed never to answer - primary down
	$pcfg3->{host_backup} = "127.0.0.1";     # always answers - backup up
	$node->configuration($pcfg3);

	NMISNG::DB::remove(
		collection => $nmisng->inventory_collection(),
		query      => NMISNG::DB::get_query( and_part => { node_uuid => $node->uuid, concept => "ping" } ),
		just_one   => 0,
	);
	NMISNG::DB::remove(
		collection => $nmisng->status_collection(),
		query      => NMISNG::DB::get_query( and_part => {
			node_uuid => $node->uuid, method => "Operational", event => "Node Polling Failover" } ),
		just_one   => 0,
	);

	$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
	my ( $mustpingfovercnt, $mustpingfoverdoc ) = opdoc("Node Polling Failover");
	is( $mustpingfovercnt, 1, "Fix 10b: a Node Polling Failover doc was created on the internal-ping path too" );
	is( $mustpingfoverdoc->{status}, "error",
		"Fix 10b: correctly reports error - primary down, backup up, on the fallback path" );

	# and the reverse: primary answers too -> ok, still on this same path.
	$pcfg3->{host} = "127.0.0.1";    # both now answer
	$node->configuration($pcfg3);
	NMISNG::DB::remove(
		collection => $nmisng->inventory_collection(),
		query      => NMISNG::DB::get_query( and_part => { node_uuid => $node->uuid, concept => "ping" } ),
		just_one   => 0,
	);
	$node->pingable( sys => $S, catchall_inventory => $catchall_inv );
	my ( undef, $mustpingfoverokdoc ) = opdoc("Node Polling Failover");
	is( $mustpingfoverokdoc->{status}, "ok",
		"Fix 10b: correctly reports ok once the primary answers, on the fallback path" );

	# restore
	$pcfg3->{host}        = $saved_host;
	$pcfg3->{host_backup} = $saved_host_backup;
	$node->configuration($pcfg3);
	$C->{ping_timeout} = $saved_timeout;
	$C->{ping_retries} = $saved_retries;
	NMISNG::DB::remove(
		collection => $nmisng->inventory_collection(),
		query      => NMISNG::DB::get_query( and_part => { node_uuid => $node->uuid, concept => "ping" } ),
		just_one   => 0,
	);
}

# --- Fix 1a: Config.nmis status_summary_exclude_events ---
# Events.nmis is never auto-merged on upgrade, so its per-event Status flags
# cannot reach an existing install. This site-wide list is consulted in
# ADDITION to the per-event flag, and must behave identically: skip from the
# health calculation, never stamp "ignored".
my $saved_exclude = $C->{status_summary_exclude_events};
delete $C->{status_summary_exclude_events};
# the Fix 11 master gate defaults false (round 5) - this block tests the
# finer-grained exclude-list logic underneath it, so turn it on here.
$C->{health_score_include_operational_events} = 'true';

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
$C->{health_score_include_operational_events} = 'false';    # restore default

# --- Fix 1b (round 6): TrackStatus is the sole write gate now ---
# operational_status_untracked_events (a Config.nmis site-wide list) was
# removed once Events.nmis itself became installer-mergeable
# (installer_hooks/10-postcopy-confmerges) - TrackStatus now reliably
# reaches every site on its own, so there's no longer a separate list to
# duplicate its job. This proves the per-event Events.nmis flag alone
# gates the write correctly, in both directions.
my $events_config = NMISNG::Util::loadTable( dir => 'conf', name => 'Events', conf => $C );
$events_config->{"OMK12605 EventsUntracked"} = { Log => "true", Notify => "true", Status => "true", TrackStatus => "false" };

NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 EventsUntracked",
	status => "error", level => "Major", details => "must not be written",
	events_config => $events_config,
);
( $cnt ) = opdoc("OMK12605 EventsUntracked");
is( $cnt, 0, "Fix 1b: Events.nmis TrackStatus=false gates the write" );

# flip it to true: the same event now writes, proving the flag (not
# something else) was what gated it
$events_config->{"OMK12605 EventsUntracked"}{TrackStatus} = "true";
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 EventsUntracked",
	status => "error", level => "Major", details => "written once TrackStatus is true",
	events_config => $events_config,
);
( $cnt ) = opdoc("OMK12605 EventsUntracked");
is( $cnt, 1, "Fix 1b: the very same event writes once TrackStatus is true" );

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

# --- Fix 3b (round 3): notify()'s own copy of this same check, escaped too ---
# save_operational_status's copy was fixed above, but notify() has its own,
# separate stateless-check line with the same interpolation - the original
# both notify() and the helper's check are modelled on. If the die risk was
# real enough to fix in the helper, it's real in notify() too, since notify()
# is what raises an event in the first place, before the helper ever runs.
my $meta_name2 = "OMK12605 Unbalanced2 ( Paren";
eval {
	Compat::NMIS::notify(
		sys => $S, event => $meta_name2, element => '',
		level => "Major", details => "notify metachar raise",
	);
	1;
};
ok( !$@, "Fix 3b: notify() with an unbalanced regex metacharacter event name did not die" )
	or diag($@);
ok( $node->eventExist($meta_name2), "Fix 3b: ...and it created the event normally" );
my ( $mcnt2, $mdoc2 ) = opdoc($meta_name2);
is( $mcnt2, 1, "Fix 3b: ...and its Operational doc was written like any other event" );
is( $mdoc2->{status}, "error", "Fix 3b: metacharacter-named doc carries the right status" );

# --- Fix 3c (round 4): notify()'s node_configuration_events check, escaped too ---
# Round 3 fixed the stateless check above but missed a second, separate
# interpolation a few lines later in the same function: the config-logging
# gate that decides whether to write a node-configuration-change log entry.
# It's dormant on a stock install (log_node_configuration_events defaults
# off), but it's a supported flag, and once on, the same unbalanced-paren
# event name dies here too unless escaped.
my $saved_log_nce = $C->{log_node_configuration_events};
my $saved_nce     = $C->{node_configuration_events};
$C->{log_node_configuration_events} = "true";
$C->{node_configuration_events} = "Node Configuration Change";

my $meta_name3 = "OMK12605 Unbalanced3 ( Paren";
eval {
	Compat::NMIS::notify(
		sys => $S, event => $meta_name3, element => '',
		level => "Major", details => "notify metachar raise, config-log gate",
	);
	1;
};
ok( !$@, "Fix 3c: notify() with log_node_configuration_events on did not die on a metacharacter event name" )
	or diag($@);
ok( $node->eventExist($meta_name3), "Fix 3c: ...and it created the event normally" );

$C->{log_node_configuration_events} = $saved_log_nce;
$C->{node_configuration_events}     = $saved_nce;

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

# --- Fix 8 (round 5): the operational writer must not touch a same-named,
# same-element Threshold/Alert status doc ---
# Status->_query() previously omitted 'method' from the identity used to
# find-and-update a doc. get_query_part() drops empty-string fields
# entirely, and the Operational writer intentionally leaves property/index/
# class/section/source blank, so the query could collapse to just
# cluster_id/node_uuid/event(/element) - matching a Threshold or Alert doc
# that happens to share an event name on this node, and silently rewriting
# it into method=Operational, losing its threshold-specific fields. This
# seeds a real Threshold doc with that name/element, then writes an
# Operational doc with the identical name/element, and proves both survive
# as two independent documents rather than one being overwritten.
my $collision_common = {
	cluster_id => $node->cluster_id, node_uuid => $node->uuid,
	element => '', property => "omk12605_collision_prop", index => "5",
	class => "generic", section => "", source => "", value => "42",
	level => "Minor", status => "error", lastupdate => time,
};
NMISNG::DB::insert(
	collection => $nmisng->status_collection(),
	record => { %$collision_common, method => "Threshold", event => "OMK12605 Same Name" },
);
NMISNG::Status::save_operational_status(
	nmisng => $nmisng, node => $node, event => "OMK12605 Same Name",
	element => '', status => "error", level => "Major", details => "operational raise",
);

my $thr_md = $nmisng->get_status_model(
	filter => { method => "Threshold", event => "OMK12605 Same Name", node_uuid => $node->uuid } );
is( $thr_md->count, 1, "Fix 8: the pre-existing Threshold doc still exists" );
is( $thr_md->data->[0]{property}, "omk12605_collision_prop",
	"Fix 8: ...and its threshold-specific fields are untouched" );

my ( $opcnt, $opdoc2 ) = opdoc("OMK12605 Same Name");
is( $opcnt, 1, "Fix 8: ...and a separate Operational doc was created for the same event name" );
is( $opdoc2->{details}, "operational raise", "Fix 8: ...with its own details, not the threshold's" );

# --- Fix 9 (round 5): checkEvent() must not report "ok" when the event
# close itself didn't actually persist ---
# Event->check() can bail out without saving (the OMK-12622 case: a stale
# interim "Up" doc already occupies the unique (node_uuid,event,element,
# active) index slot, so converting the Down doc in place hits a duplicate
# key error and check() returns without persisting the close - the down
# event stays active in the db). checkEvent() used to write the Operational
# "ok" status doc unconditionally, before check() even ran, so this case
# produced a false "all clear" on the dashboard while the real event was
# still open. checkEvent() now runs check() first and only writes "ok" when
# it reports success. This reproduces the stuck case directly (manually
# planting the colliding interim doc, the same shape the CancelingEvent
# pre-cleanup elsewhere in notify() is meant to retire but deliberately
# isn't relevant here since this is a custom event name with no
# CancelingEvent configured) rather than relying on the two-cycle race,
# which t_event_cancelingevent_cycle.pl already proves is now avoided in
# the ordinary flow.
my $stuck_event  = "OMK12605 FauxKey Down";
my $stuck_upname = "OMK12605 FauxKey Up";    # check()'s own s/down/Up/i rename

# the unique (node_uuid,event,element,active) partial index that makes this
# scenario possible is normally created by bin/nmisd/bin/nmis-cli via
# ensure_indexes(); this ad hoc test database doesn't get it automatically
# (t_event_cancelingevent_cycle.pl hits the same requirement for the same
# reason) - without it, the duplicate-key collision below can't happen at all.
my $ixerr = $nmisng->ensure_indexes();
is( $ixerr, undef, "Fix 9: index setup for the events collection succeeded" ) or diag($ixerr);

Compat::NMIS::notify(
	sys => $S, event => $stuck_event, element => '',
	details => "stuck-case down raise", level => "Critical",
);
my ( $stuckcnt, $stuckdoc ) = opdoc($stuck_event);
is( $stuckcnt, 1, "Fix 9: stuck-case Down doc created" );
is( $stuckdoc->{status}, "error", "Fix 9: ...status is error" );

# plant the interim Up doc directly, occupying the unique index slot that
# check()'s in-place conversion of the Down doc is about to collide with
NMISNG::DB::insert(
	collection => $nmisng->events_collection(),
	record => {
		cluster_id => $node->cluster_id, node_uuid => $node->uuid,
		event => $stuck_upname, element => '', active => 0, historic => 0,
		startdate => time - 100, ack => 0, escalate => -1, notify => '',
		stateless => 0, level => "Normal", details => "planted interim doc",
	},
);

my $stuck_result = Compat::NMIS::checkEvent(
	sys => $S, event => $stuck_event, element => '',
	level => "Normal", details => "stuck-case clear attempt",
);
ok( !$stuck_result, "Fix 9: checkEvent() reports failure when the close hit the duplicate-key case" );

my $stillactive = $nmisng->events->get_events_model(
	filter => { node_uuid => $node->uuid, event => $stuck_event, element => '', active => 1, historic => 0 } );
is( $stillactive->count, 1, "Fix 9: the original Down event is still active - the close did not persist" );

( $stuckcnt, $stuckdoc ) = opdoc($stuck_event);
is( $stuckcnt, 1, "Fix 9: the Operational doc still exists" );
is( $stuckdoc->{status}, "error",
	"Fix 9: ...and it was NOT flipped to ok - no false all-clear for a still-active event" );

# contrast: the same clear, without a colliding interim doc, DOES persist
# and DOES flip the status - proving the reorder didn't break the ordinary path
my $clean_event = "OMK12605 CleanKey Down";
Compat::NMIS::notify(
	sys => $S, event => $clean_event, element => '',
	details => "clean-case down raise", level => "Critical",
);
my $clean_result = Compat::NMIS::checkEvent(
	sys => $S, event => $clean_event, element => '',
	level => "Normal", details => "clean-case clear",
);
ok( $clean_result, "Fix 9 contrast: checkEvent() reports success for an ordinary clear" );
my ( $cleancnt, $cleandoc ) = opdoc($clean_event);
is( $cleancnt, 1, "Fix 9 contrast: the Operational doc still exists" );
is( $cleandoc->{status}, "ok", "Fix 9 contrast: ...and it WAS flipped to ok" );

# leave the shared test node/catchall as we found them
$pcfg = $node->configuration;
$pcfg->{ping} = "false";
delete $pcfg->{host_backup};
$node->configuration($pcfg);

# --- END OF TESTS ---
cleanup_db();
done_testing();
