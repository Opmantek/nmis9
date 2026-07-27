# Operational Event Status Documents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Code-raised events (Node Down, Backup Host Down, Node Polling Failover, Interface Down, etc.) produce `method => "Operational"` status documents with a persistent `status: error|ok` field, flowing into the status collection, the dashnode JSON, and the status_summary health calculation, per the spec at `docs/superpowers/specs/2026-07-27-omk12605-operational-event-status-design.md`.

**Architecture:** A shared writer `NMISNG::Status::save_operational_status` is called from inside `Compat::NMIS::notify` (writes `error`) and `Compat::NMIS::checkEvent` (writes `ok`). Because NMIS calls these every poll cycle (not only on transitions), docs refresh like threshold docs with zero call-site changes. An update-only hook in `Event->delete` covers out-of-band closes. The `compute_thresholds` summary loop learns to skip-not-stamp Operational docs and to leave them out of the stale sweep.

**Tech Stack:** Perl 5, MongoDB (NMISNG::DB wrapper), Test::More, existing NMIS9 conventions.

## Global Constraints

- All work happens in worktree `/home/md/work/nmis9-omk-12605-operational-status` on branch `feature/OMK-12605-operational-status`. Run all commands from that directory.
- No new CPAN dependencies.
- Booleans via `NMISNG::Util::getbool`. Config files are Perl data structures (`.nmis`).
- The status method value is exactly `"Operational"`. The new Events.nmis flag is exactly `"TrackStatus"`.
- Tests are mongo-backed: they need `conf/` with a reachable MongoDB. If `conf/` is missing in the worktree, copy it: `cp -a /home/md/work/nmis9/conf conf` (it is gitignored, never commit it).
- Single-test run: `perl test/t_operational_status.pl` from the worktree root. Expected output ends with `ok`/`All tests successful` style TAP; any `not ok` line is a failure.
- Commit subjects start with `OMK-12605:`. NEVER add Co-Authored-By trailers.
- Line numbers cited below are valid at branch point `e50e2ba1`; always locate code by the quoted anchor text, not the number alone.

---

### Task 1: Status writer helpers and dashnode guard

**Files:**
- Modify: `lib/NMISNG/Status.pm` (add two package functions at the end, before `1;`; guard one line in `update_dashnode_data` ~line 281)
- Create: `test/t_operational_status.pl`

**Interfaces:**
- Produces: `NMISNG::Status::save_operational_status(%args)` — args: `nmisng` (NMISNG, required), `node` (NMISNG::Node, required), `event` (string, required), `element` (string, default `''`), `status` (`"error"|"ok"`, required), `level` (string, default `"Normal"`), `details` (string, default `''`), `context` (hashref, optional), `inventory_id` (optional), `events_config` (hashref, optional; loaded from the Events table when absent). Returns undef on success or skip, error string on save failure. Later tasks (2, 3) call this from `Compat::NMIS`.
- Produces: `NMISNG::Status::close_operational_status(%args)` — args: `nmisng`, `cluster_id`, `node_uuid`, `event`, `element`. Updates an existing Operational doc to ok, never creates. Returns nothing. Task 4 calls this from `Event->delete`.

- [ ] **Step 1: Ensure the worktree can run mongo-backed tests**

```bash
[ -d conf ] || cp -a /home/md/work/nmis9/conf conf
git check-ignore -q conf && echo "conf ignored OK"
```
Expected: `conf ignored OK`.

- [ ] **Step 2: Write the failing test file**

Create `test/t_operational_status.pl` with this exact content:

```perl
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

# --- END OF TESTS ---
cleanup_db();
done_testing();
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `perl test/t_operational_status.pl`
Expected: FAIL — `save_operational_status exists` and `close_operational_status exists` are `not ok` (functions undefined).

- [ ] **Step 4: Implement the helpers in `lib/NMISNG/Status.pm`**

Insert immediately before the final `1;` of the file:

```perl
# writes/refreshes the status document for a code-raised ("operational")
# event. called from Compat::NMIS::notify (status error) and
# Compat::NMIS::checkEvent (status ok) on every cycle. threshold and alert
# callers maintain their own status documents and are gated out here.
# args: nmisng, node (NMISNG::Node), event, element, status (error|ok),
#  level, details, context, inventory_id,
#  events_config (optional, avoids a reload when the caller has it)
# returns: undef on success or skip, error string on save failure
sub save_operational_status
{
	my (%args) = @_;
	my ( $nmisng, $node, $event, $element, $status, $level, $details, $context, $inventory_id )
		= @args{qw(nmisng node event element status level details context inventory_id)};

	return if ( ref($nmisng) ne "NMISNG" or !$node or !$event or !$status );

	# threshold and alert callers maintain their own status documents
	my $ctype = ( ref($context) eq "HASH" ) ? ( $context->{type} // '' ) : '';
	return if ( $ctype eq "threshold" or $ctype eq "alert" );
	return if ( $event =~ /^(Proactive|Alert: )/ );

	my $events_config = $args{events_config}
		// NMISNG::Util::loadTable( dir => 'conf', name => 'Events' );
	my $thisevent_control = $events_config->{$event}
		|| $events_config->{'Default'}
		|| { Log => "true", Notify => "true", Status => "true" };

	# stateless events have no ok/error state; same test notify performs
	my $C = $nmisng->config;
	my $is_stateless = ( $C->{non_stateful_events} !~ /$event/
		or NMISNG::Util::getbool( $thisevent_control->{Stateful} ) ) ? 0 : 1;
	return if ($is_stateless);

	# per-event write gate, on unless configured off
	return if ( defined( $thisevent_control->{TrackStatus} )
		and !NMISNG::Util::getbool( $thisevent_control->{TrackStatus} ) );

	my $status_obj = NMISNG::Status->new(
		nmisng     => $nmisng,
		cluster_id => $node->cluster_id,
		node_uuid  => $node->uuid,
		method     => "Operational",
		event      => $event,
		element    => $element // '',
		status     => $status,
		level      => $level // 'Normal',
		details    => $details // '',
		property   => '',
		index      => '',
		class      => '',
		section    => '',
		source     => '',
		value      => '',
		( defined($inventory_id) ? ( inventory_id => NMISNG::DB::make_oid($inventory_id) ) : () ),
	);
	my $error = $status_obj->save();
	$nmisng->log->error("save_operational_status failed for $event: $error")
		if ($error);
	return $error;
}

# flips an existing Operational status doc to ok when its event is closed
# outside notify/checkEvent (gui trap ack, api delete). update only, never
# create: up-events and traps never had a doc, so they stay inert.
# args: nmisng, cluster_id, node_uuid, event, element
# returns: nothing
sub close_operational_status
{
	my (%args) = @_;
	my ( $nmisng, $cluster_id, $node_uuid, $event, $element )
		= @args{qw(nmisng cluster_id node_uuid event element)};
	return if ( ref($nmisng) ne "NMISNG" or !$node_uuid or !$event );

	my $dbres = NMISNG::DB::update(
		collection => $nmisng->status_collection(),
		query      => NMISNG::DB::get_query(
			no_regex => 1,
			and_part => {
				cluster_id => $cluster_id,
				node_uuid  => $node_uuid,
				method     => "Operational",
				event      => $event,
				element    => $element // '',
			}
		),
		record => {
			'$set' => {
				status     => "ok",
				level      => "Normal",
				details    => "event closed",
				lastupdate => time
			}
		},
		freeform => 1,
	);
	$nmisng->log->error("close_operational_status failed for $event: $dbres->{error}")
		if ( !$dbres->{success} );
	return;
}
```

- [ ] **Step 5: Guard `update_dashnode_data` against missing inventory_id**

In `lib/NMISNG/Status.pm`, `sub update_dashnode_data` (~line 281), Operational docs may have no inventory_id and the unconditional `->hex` would die. Change:

```perl
		$data->{"inventory_id"} = $data->{"inventory_id"}->hex;
```

to:

```perl
		$data->{"inventory_id"} = $data->{"inventory_id"}->hex if ( ref( $data->{"inventory_id"} ) );
```

- [ ] **Step 6: Run the test, verify it passes**

Run: `perl test/t_operational_status.pl`
Expected: PASS, ~19 assertions, `Result: PASS` style TAP with no `not ok`.

- [ ] **Step 7: Commit**

```bash
git add lib/NMISNG/Status.pm test/t_operational_status.pl
git commit -m "OMK-12605: add operational status writer helpers to NMISNG::Status

save_operational_status upserts method=Operational docs for code-raised
events (gated on threshold/alert source, stateless events, TrackStatus).
close_operational_status flips existing docs to ok on out-of-band event
closure, update-only. Guard update_dashnode_data against docs without an
inventory_id."
```

---

### Task 2: Wire the error side into `Compat::NMIS::notify`

**Files:**
- Modify: `lib/Compat/NMIS.pm` (`sub notify`, ~line 2220; add one `use` near the top with the other `use NMISNG::*` lines)
- Modify: `test/t_operational_status.pl` (append tests before `# --- END OF TESTS ---`)

**Interfaces:**
- Consumes: `NMISNG::Status::save_operational_status(%args)` from Task 1.
- Produces: every `notify()` call for a stateful, non-threshold, non-alert event now writes/refreshes a `status => "error"` Operational doc. Tasks 3-5 rely on this behaviour.

- [ ] **Step 1: Append the failing tests**

Insert before the `# --- END OF TESTS ---` line in `test/t_operational_status.pl`:

```perl
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
```

- [ ] **Step 2: Run the test, verify the new assertions fail**

Run: `perl test/t_operational_status.pl`
Expected: FAIL — `notify created one Operational doc` is `not ok` (count 0). Task 1 assertions still pass.

- [ ] **Step 3: Implement the notify wiring**

In `lib/Compat/NMIS.pm`, first make sure the module is loaded: near the top with the other `use NMISNG::...` statements add (skip if already present):

```perl
use NMISNG::Status;
```

Then in `sub notify`, locate the end of the function:

```perl
	return $event_obj;
	$S->nmisng->log->debug2(sub {"Notify Finished"});
}
```

and insert the helper call immediately before `return $event_obj;`:

```perl
	# maintain the operational status doc for this event (OMK-12605);
	# threshold/alert/stateless/untracked events are gated inside the helper
	NMISNG::Status::save_operational_status(
		nmisng        => $S->nmisng,
		node          => $node,
		event         => $event_obj->event,
		element       => $event_obj->element,
		status        => "error",
		level         => $event_obj->level,
		details       => $event_obj->details,
		context       => $event_obj->context // $args{context},
		inventory_id  => $event_obj->inventory_id,
		events_config => $events_config,
	);

	return $event_obj;
```

Values come from `$event_obj` (not the raw args) so the already-exists branch reports the event's stored level/details, and the new-event branch reports the model-resolved level.

- [ ] **Step 4: Run the test, verify it passes**

Run: `perl test/t_operational_status.pl`
Expected: PASS, no `not ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/Compat/NMIS.pm test/t_operational_status.pl
git commit -m "OMK-12605: notify() writes method=Operational error status docs"
```

---

### Task 3: Wire the ok side into `checkEvent`, tag thresholdProcess's clear call

**Files:**
- Modify: `lib/Compat/NMIS.pm` (`sub checkEvent`, ~line 2188)
- Modify: `lib/NMISNG.pm` (`sub thresholdProcess` ~line 5322, the `Compat::NMIS::checkEvent(` call ~line 5340)
- Modify: `test/t_operational_status.pl` (append before `# --- END OF TESTS ---`)

**Interfaces:**
- Consumes: `NMISNG::Status::save_operational_status(%args)` from Task 1; error docs from Task 2.
- Produces: every `checkEvent()` call for an eligible event writes/refreshes a `status => "ok"` doc (including when no down event exists — this is how healthy nodes get their always-present entries). `thresholdProcess` passes `context => { type => "threshold" }` to `checkEvent` so custom-named threshold events are gated.

- [ ] **Step 1: Append the failing tests**

Insert before `# --- END OF TESTS ---`:

```perl
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
```

- [ ] **Step 2: Run the test, verify the new assertions fail**

Run: `perl test/t_operational_status.pl`
Expected: FAIL — `checkEvent flipped doc to ok` is `not ok` (doc still error).

- [ ] **Step 3: Implement the checkEvent wiring**

In `lib/Compat/NMIS.pm`, `sub checkEvent`, locate:

```perl
	$args{node_uuid} = $S->nmisng_node()->uuid;

	# create event with attributes we are looking for
```

and insert between those two:

```perl
	# maintain the operational status doc: the condition was assessed healthy
	# this cycle (OMK-12605); gates inside the helper
	NMISNG::Status::save_operational_status(
		nmisng  => $S->nmisng,
		node    => $S->nmisng_node,
		event   => $args{event},
		element => $args{element},
		status  => "ok",
		level   => "Normal",
		details => $args{details},
		context => $args{context},
	);
```

- [ ] **Step 4: Tag thresholdProcess's clear call**

In `lib/NMISNG.pm`, `sub thresholdProcess` (~line 5322), the Normal-level branch calls checkEvent (~line 5340):

```perl
			Compat::NMIS::checkEvent(
				sys          => $S,
				event        => $args{event},
				level        => $args{level},
				element      => $args{element},
				details      => $details,
				value        => $args{value},
				reset        => $args{reset},
				inventory_id => $args{inventory_id}
			);
```

Add the context argument so custom-named threshold events are gated too:

```perl
			Compat::NMIS::checkEvent(
				sys          => $S,
				event        => $args{event},
				level        => $args{level},
				element      => $args{element},
				details      => $details,
				value        => $args{value},
				reset        => $args{reset},
				inventory_id => $args{inventory_id},
				context      => { type => "threshold" }
			);
```

(`checkEvent` reads only the keys it knows; the new key is consumed by the helper call added in Step 3.)

- [ ] **Step 5: Run the test, verify it passes**

Run: `perl test/t_operational_status.pl`
Expected: PASS, no `not ok`.

- [ ] **Step 6: Commit**

```bash
git add lib/Compat/NMIS.pm lib/NMISNG.pm test/t_operational_status.pl
git commit -m "OMK-12605: checkEvent() writes method=Operational ok status docs

thresholdProcess tags its clear-side checkEvent call with
context type=threshold so custom-named threshold events are gated."
```

---

### Task 4: Out-of-band close hook in `Event->delete`

**Files:**
- Modify: `lib/NMISNG/Event.pm` (`sub delete`, ~line 514)
- Modify: `test/t_operational_status.pl` (append before `# --- END OF TESTS ---`)

**Interfaces:**
- Consumes: `NMISNG::Status::close_operational_status(%args)` from Task 1.
- Produces: any event closed via `Event->delete` (GUI TRAP ack, API delete, cleanup) flips its existing Operational doc to ok. No new interface for later tasks.

- [ ] **Step 1: Append the failing tests**

Insert before `# --- END OF TESTS ---`:

```perl
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
```

- [ ] **Step 2: Run the test, verify the new assertions fail**

Run: `perl test/t_operational_status.pl`
Expected: FAIL — `close hook flipped doc to ok` is `not ok` (doc still error).

- [ ] **Step 3: Implement the hook**

In `lib/NMISNG/Event.pm`, make sure the module is available: near the top with the other `use NMISNG::...` statements add (skip if already present):

```perl
use NMISNG::Status;
```

In `sub delete`, locate the tail:

```perl
	$self->nmisng->log->error($ret) if ($ret);
	return $ret;
}
```

and change it to:

```perl
	# event closed outside notify/checkEvent: flip its operational status
	# doc to ok if one exists (OMK-12605). update-only, so up-events and
	# traps (which never had a doc) stay inert.
	if ( !$ret )
	{
		NMISNG::Status::close_operational_status(
			nmisng     => $self->nmisng,
			cluster_id => $self->cluster_id // $self->nmisng->config->{cluster_id},
			node_uuid  => $self->node_uuid,
			event      => $self->event,
			element    => $self->element,
		);
	}

	$self->nmisng->log->error($ret) if ($ret);
	return $ret;
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `perl test/t_operational_status.pl`
Expected: PASS, no `not ok`.

- [ ] **Step 5: Guard against regressions in the event suite**

Run: `perl test/t_event.pl && perl test/t_duplicate_event.pl && perl test/t_event_cancelingevent_cycle.pl`
Expected: all PASS (these exercise `Event->delete` heavily; the hook must not disturb them). If a test needs an existing node and skips, that is acceptable — note it.

- [ ] **Step 6: Commit**

```bash
git add lib/NMISNG/Event.pm test/t_operational_status.pl
git commit -m "OMK-12605: Event->delete flips existing Operational status docs to ok"
```

---

### Task 5: Summary-loop handling in `compute_thresholds`

**Files:**
- Modify: `lib/NMISNG.pm` (`sub compute_thresholds`, the status loop ~lines 740-775, anchor: `Status Summary Ignoring`)
- Modify: `test/t_operational_status.pl` (append before `# --- END OF TESTS ---`)

**Interfaces:**
- Consumes: Operational docs from Tasks 1-3.
- Produces: Operational docs are exempt from the 500s stale sweep; `Status => 'false'` skips them from the count without stamping `"ignored"`. Threshold/Alert behaviour unchanged.

- [ ] **Step 1: Append the failing tests**

Insert before `# --- END OF TESTS ---`:

```perl
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
```

- [ ] **Step 2: Run the test, verify the new assertions fail**

Run: `perl test/t_operational_status.pl`
Expected: FAIL — `stale Operational doc survived the sweep` is `not ok` (current loop deletes any doc older than 500s), and the `no 'ignored' stamp` assertion fails (doc stamped `ignored`).

- [ ] **Step 3: Implement the loop changes**

In `lib/NMISNG.pm`, `sub compute_thresholds`, locate the loop body (anchor `Status Summary Ignoring`):

```perl
		# event control is as configured or all true.
		my $thisevent_control = $events_config->{$eventKey} || {Log => "true", Notify => "true", Status => "true"};

		# if this is an alert and it is older than 1 full poll cycle, delete it from status.
		# fixme: this logic is broken for variable polling
		if ( $status_obj->lastupdate < time - 500 )
		{
			$status_obj->delete();
		}
```

Insert between the `$thisevent_control` assignment and the stale-sweep `if`:

```perl
		# operational docs are maintained by the event write path (OMK-12605):
		# not swept here (slow-polled nodes would flap), and Status=false
		# means skip from the calculation, never stamp "ignored"
		if ( ( $status_obj->method // '' ) eq "Operational" )
		{
			next if ( not NMISNG::Util::getbool( $thisevent_control->{Status} ) );
			++$count;
			++$countOk if ( $status_obj->status eq "ok" );
			next;
		}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `perl test/t_operational_status.pl`
Expected: PASS, no `not ok`.

- [ ] **Step 5: Guard against regressions**

Run: `perl test/t_status.pl && perl test/t_polling.pl`
Expected: PASS (threshold/alert loop behaviour unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/NMISNG.pm test/t_operational_status.pl
git commit -m "OMK-12605: compute_thresholds skips-not-stamps Operational docs

Operational docs are exempt from the 500s stale sweep (their lifecycle
belongs to the per-cycle event write path) and Status=false excludes
them from status_summary without the 'ignored' stamp."
```

---

### Task 6: conf-default Events.nmis flags

**Files:**
- Modify: `conf-default/Events.nmis` (four entries)
- Modify: `test/t_operational_status.pl` (append before `# --- END OF TESTS ---`)

**Interfaces:**
- Consumes: flag semantics from Tasks 1 and 5.
- Produces: shipped defaults — Interface Down / Service Down / Service Degraded excluded from status_summary; Planned Outage Open gets no doc at all.

- [ ] **Step 1: Append the failing tests**

Insert before `# --- END OF TESTS ---`:

```perl
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
```

- [ ] **Step 2: Run the test, verify the new assertions fail**

Run: `perl test/t_operational_status.pl`
Expected: FAIL — the three `Status=false` assertions and the `TrackStatus` assertion are `not ok`.

- [ ] **Step 3: Edit `conf-default/Events.nmis`**

In the `'Interface Down'`, `'Service Down'`, and `'Service Degraded'` entries, change:

```perl
    'Status' => 'true',
```

to:

```perl
    'Status' => 'false',            # operational doc is written but does not affect status_summary
```

(three separate edits, one per entry — match each entry's existing indentation exactly).

In the `"Planned Outage Open"` entry (double-quoted style, ~line 556), after the line `"Status" => "false", ...` add:

```perl
    "TrackStatus" => "false",           # no status doc: an error entry for a planned window would mislead
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `perl test/t_operational_status.pl`
Expected: PASS, no `not ok`.

- [ ] **Step 5: Commit**

```bash
git add conf-default/Events.nmis test/t_operational_status.pl
git commit -m "OMK-12605: tune shipped Events.nmis flags for operational status docs

Interface Down and Service Down/Degraded ship Status=false so node
health is unchanged on upgrade; Planned Outage Open ships
TrackStatus=false so no doc is written for planned windows."
```

---

### Task 7: dashnode integration and the context-clear bugfix

**Files:**
- Modify: `lib/NMISNG/Node.pm` (`sub save_dashnode_data`, ~line 7209; the buggy line ~7222)
- Modify: `test/t_operational_status.pl` (append before `# --- END OF TESTS ---`)

**Interfaces:**
- Consumes: Operational docs and `Status::update_dashnode_data` (existing else-branch keys them `event--element`).
- Produces: dashnode JSON entries for operational events; `save_dashnode_data` actually clears `nmisng->{dashnode_context}` after saving.

- [ ] **Step 1: Append the failing tests**

Insert before `# --- END OF TESTS ---`:

```perl
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
my $dashdata = NMISNG::Util::readFiletoHash( file => $dashfile );
ok( exists $dashdata->{status}{"OMK12605 Dash Event--"},
	"dashnode file contains the operational entry" );
is( $dashdata->{status}{"OMK12605 Dash Event--"}{status}, "error",
	"file entry carries status error" );

# the bugfix: context must actually be cleared after save
ok( !defined $nmisng->{dashnode_context},
	"dashnode_context cleared after save (bugfix)" );
$C->{enable_dashnode_file} = 'false';
```

- [ ] **Step 2: Run the test, verify the new assertions fail**

Run: `perl test/t_operational_status.pl`
Expected: FAIL — `dashnode_context cleared after save (bugfix)` is `not ok`. The entry-shape assertions should already pass (they ride on existing `update_dashnode_data`); if they fail, stop and investigate before touching code.

- [ ] **Step 3: Fix the wrong-key delete**

In `lib/NMISNG/Node.pm`, `sub save_dashnode_data`, change:

```perl
		# clear context after save so it doesn't get reused incorrectly
		delete $self->nmisng->config->{dashnode_context};		
```

to:

```perl
		# clear context after save so it doesn't get reused incorrectly
		delete $self->nmisng->{dashnode_context};
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `perl test/t_operational_status.pl`
Expected: PASS, no `not ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Node.pm test/t_operational_status.pl
git commit -m "OMK-12605: dashnode integration test; fix dashnode_context never clearing

save_dashnode_data deleted config->{dashnode_context} instead of the
real nmisng->{dashnode_context}, so the context survived across saves."
```

---

### Task 8: CI wiring and final verification

**Files:**
- Modify: `ci/scripts/perl_tests.sh` (add one line to `working_tests`)

**Interfaces:**
- Consumes: the complete `test/t_operational_status.pl`.
- Produces: the test runs in the Test NMIS pipeline.

- [ ] **Step 1: Add the test to the CI list**

In `ci/scripts/perl_tests.sh`, in the `working_tests=(` array, after the line `    t_duplicate_event.pl`, add:

```bash
    t_operational_status.pl
```

- [ ] **Step 2: Run the full new test file one final time**

Run: `perl test/t_operational_status.pl`
Expected: PASS, roughly 50 assertions, no `not ok`, temp db dropped (verify no leftover: `mongosh --quiet --eval 'db.getMongo().getDBNames().filter(n => n.match(/^t_operational_status/))'` should print `[]`; adapt auth flags to the local mongo setup, or skip this check if mongosh is unavailable).

- [ ] **Step 3: Run the neighbouring suites once more**

Run: `perl test/t_status.pl && perl test/t_event.pl && perl test/t_duplicate_event.pl && perl test/t_nmisng_sys.pl`
Expected: PASS (or documented environment-dependent skips). Full-suite verification happens in the dev container per CLAUDE.md before the PR.

- [ ] **Step 4: Commit**

```bash
git add ci/scripts/perl_tests.sh
git commit -m "OMK-12605: run t_operational_status.pl in the Test NMIS pipeline"
```

---

## Out of scope for this plan (tracked on the ticket)

- Closing GitHub PR #183 with a note that `feature/OMK-12605-operational-status` supersedes it (human action).
- Migrating `thresholdProcess` and the alert writer onto `save_operational_status` (follow-up ticket per spec).
- Checking external consumers (opCharts/opEvents) for assumptions about status doc shapes (flagged in spec, needs access to those repos).
