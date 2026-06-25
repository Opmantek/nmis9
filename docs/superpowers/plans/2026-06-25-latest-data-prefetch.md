# Per-node latest_data prefetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the N per-interface `latest_data` finds per collect/update with one `find({node_uuid})` into a per-cycle in-memory buffer, with write-through and guaranteed teardown.

**Architecture:** A buffer on the per-worker NMISNG object, keyed `node_uuid -> inventory_id_str -> {time, subconcepts}`. `Node::collect`/`Node::update` populate it for the node via one find and hold an `NMISNG::Guard` lexical that deletes the node's entry on scope exit (teardown fires on return AND exception). `Inventory::get_newest_timed_data` (latest_data path) serves from the buffer (cloning on read so callers can never mutate it), falling back to a live find on a miss or when no buffer is active. `Inventory::add_timed_data` writes the new reading through to the buffer so same-cycle readers (thresholds) see current data. A config kill switch makes flag-off byte-for-byte the current behaviour.

**Tech Stack:** Perl 5.36, MongoDB (NMISNG::DB), Test::More, the docker dev stack (`omk12375-nmis`/`omk12375-mongo`), the golden harness (`test/t_intf_collect.pl`, `test/lib/IntfTestHarness.pm`).

## Global Constraints

- No behaviour change with the kill switch ON beyond the intended `latest_data` find-count drop; gated by the golden write-stream harness (byte-identical write-stream + final state).
- Kill switch `pit_prefetch_enabled` config flag, **default ON** (`$config->{pit_prefetch_enabled} // 1`).
- No `Co-Authored-By` trailer on any commit.
- Scope is `latest_data` only (the `from_timed == 0` path). The `from_timed == 1` (timed_<concept> history) path, events, and the inventory-record write are untouched.
- Buffer keyed by node_uuid; cross-node reads must miss (a different node's buffer never serves).
- Inventory `_id` stringified through ONE shared helper on both store and lookup (MongoDB::OID `->value` vs BSON::OID `->hex`) so a key mismatch can never silently turn hits into misses.
- Cached reads return an independent clone (no ref shared with the buffer) — the buffer holds shared refs, every read clones out.
- Run Perl in the container: `docker exec omk12375-nmis perl /usr/local/nmis9/test/<file>`. Edits in the worktree are live in the container.
- Spec: `docs/superpowers/specs/2026-06-25-latest-data-prefetch-design.md`.

---

## File Structure

- Modify `lib/NMISNG.pm`: add `_pit_prefetch => {}` to `new()`; add `_pit_oid_str` (package sub) + `pit_prefetch_begin`/`pit_prefetch_lookup`/`pit_prefetch_store` methods. **Responsibility:** owns the buffer and its lifecycle.
- Modify `lib/NMISNG/Inventory.pm`: `get_newest_timed_data` read consult (clone-on-read); `add_timed_data` write-through. **Responsibility:** read/write the buffer through the owner.
- Modify `lib/NMISNG/Node.pm`: `collect` + `update` prefetch trigger + guard lexical. **Responsibility:** scope the buffer to one cycle.
- Create `test/t_pit_prefetch.pl`: unit + integration tests for the buffer, read path, write-through, find-count, teardown, flag-off.
- Use existing `test/t_intf_collect.pl` (+ `test/lib/IntfTestHarness.pm`) as the golden gate, run with prefetch on.

---

## Task 1: NMISNG buffer primitives + kill switch

**Files:**
- Modify: `lib/NMISNG.pm` (the `new()` bless hash; add methods before the final `1;`)
- Test: `test/t_pit_prefetch.pl`

**Interfaces:**
- Produces:
  - `NMISNG::_pit_oid_str($oid)` -> string. `undef`->`''`; blessed OID -> `->hex` if it `can('hex')` else `->value`; plain scalar -> itself.
  - `$nmisng->pit_prefetch_begin(node_uuid => $uuid)` -> `NMISNG::Guard` object, or `undef` if `node_uuid` missing or `pit_prefetch_enabled` is false. Side effect: sets `$nmisng->{_pit_prefetch}{$uuid}` to `{ inv_id_str => {time,subconcepts} }` loaded from `latest_data` (overwriting any prior entry). The returned guard's DESTROY deletes that key.
  - `$nmisng->pit_prefetch_lookup($node_uuid, $oid)` -> the raw `{time,subconcepts}` doc on hit, else `undef` (miss OR no buffer active for that node).
  - `$nmisng->pit_prefetch_store($node_uuid, $oid, $doc)` -> stores `$doc` under the stringified `$oid`; no-op if no buffer active for that node.

- [ ] **Step 1: Write the failing test**

Create `test/t_pit_prefetch.pl`:
```perl
#!/usr/bin/perl
# Tests for the per-node latest_data prefetch buffer (OMK-12375).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/lib"; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG; use NMISNG::Util; use NMISNG::Log; use NMISNG::DB;

my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_pitpf-$$";
my $nmisng = NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>'error'));

# --- _pit_oid_str consistency ---
{
  package FakeHexOid; sub new { bless {h=>$_[1]}, $_[0] } sub hex { $_[0]{h} } sub can { $_[1] eq 'hex' ? \&hex : undef }
}
is(NMISNG::_pit_oid_str(undef), '', "_pit_oid_str undef -> ''");
is(NMISNG::_pit_oid_str("abc"), "abc", "_pit_oid_str scalar -> itself");
is(NMISNG::_pit_oid_str(FakeHexOid->new("deadbeef")), "deadbeef", "_pit_oid_str uses ->hex when available");

# --- store / lookup roundtrip; no-buffer returns undef ---
is($nmisng->pit_prefetch_lookup("nodeA","oid1"), undef, "lookup with no buffer -> undef");
$nmisng->pit_prefetch_store("nodeA","oid1",{time=>10, subconcepts=>[]});  # no-op, no buffer yet
is($nmisng->pit_prefetch_lookup("nodeA","oid1"), undef, "store is a no-op when no buffer active");

# manually open a buffer to test store/lookup primitives
$nmisng->{_pit_prefetch}{"nodeA"} = {};
$nmisng->pit_prefetch_store("nodeA","oid1",{time=>10, subconcepts=>[{subconcept=>"interface",data=>{x=>1}}]});
my $got = $nmisng->pit_prefetch_lookup("nodeA","oid1");
is($got->{time}, 10, "lookup returns stored doc");
is($nmisng->pit_prefetch_lookup("nodeA","missing"), undef, "lookup miss -> undef");
is($nmisng->pit_prefetch_lookup("nodeB","oid1"), undef, "cross-node lookup -> undef");
delete $nmisng->{_pit_prefetch}{"nodeA"};

# --- begin loads from latest_data, guard tears down ---
my $node_uuid = "11111111-2222-3333-4444-555555555555";
my $oid = NMISNG::DB::make_oid();   # a real OID of the driver's type
NMISNG::DB::insert(collection => $nmisng->latest_data_collection,
  record => { inventory_id => $oid, node_uuid => $node_uuid, time => 99,
              subconcepts => [{subconcept=>"interface", data=>{ifInOctets=>5}, derived_data=>{}}] });
{
  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $node_uuid);
  isa_ok($guard, "NMISNG::Guard", "begin returns a guard");
  ok(exists $nmisng->{_pit_prefetch}{$node_uuid}, "buffer populated for node");
  my $hit = $nmisng->pit_prefetch_lookup($node_uuid, $oid);
  is($hit->{time}, 99, "begin loaded the seeded latest_data reading");
}
ok(!exists $nmisng->{_pit_prefetch}{$node_uuid}, "guard teardown removed the node buffer");

# --- kill switch: flag off => undef, no buffer ---
$nmisng->config->{pit_prefetch_enabled} = 0;
my $g2 = $nmisng->pit_prefetch_begin(node_uuid => $node_uuid);
is($g2, undef, "begin returns undef when pit_prefetch_enabled is false");
ok(!exists $nmisng->{_pit_prefetch}{$node_uuid}, "no buffer created when disabled");
$nmisng->config->{pit_prefetch_enabled} = 1;

$nmisng->get_db()->drop();
done_testing;
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_pit_prefetch.pl`
Expected: FAIL — `Undefined subroutine &NMISNG::_pit_oid_str` / `Can't locate object method "pit_prefetch_begin"`.

- [ ] **Step 3: Add the buffer field to NMISNG::new**

In `lib/NMISNG.pm`, in the `bless({ ... })` hash in `new()`, add the field next to `_plugins => undef,`:
```perl
			_plugins => undef,            # sub plugins populates that on the go
			_pit_prefetch => {},          # per-cycle latest_data prefetch buffer (OMK-12375): node_uuid -> {inv_id_str -> {time,subconcepts}}
```

- [ ] **Step 4: Add the primitives (before the final `1;` in lib/NMISNG.pm)**

```perl
# OMK-12375 per-node latest_data prefetch buffer.
# Stringify an inventory _id the SAME way get_inventory_ids does (Node.pm), so the
# buffer key from a loaded doc and the key from $inventory->id always agree regardless
# of MongoDB::OID (->value) vs BSON::OID (->hex).
sub _pit_oid_str
{
	my ($oid) = @_;
	return '' if (!defined $oid);
	return "$oid" if (!ref $oid);
	return $oid->can('hex') ? $oid->hex : $oid->value;
}

# Populate the prefetch buffer for one node with a single latest_data find, and return
# an NMISNG::Guard that deletes the node's buffer entry on scope exit (the memory cap).
# Returns undef (no buffer, no guard) when disabled by config or given no node_uuid.
sub pit_prefetch_begin
{
	my ($self, %args) = @_;
	my $node_uuid = $args{node_uuid};
	return undef if (!$node_uuid);
	return undef if (!($self->config->{pit_prefetch_enabled} // 1));   # kill switch, default on

	my $cursor = NMISNG::DB::find(
		collection  => $self->latest_data_collection,
		query       => NMISNG::DB::get_query( and_part => { node_uuid => $node_uuid }, no_regex => 1 ),
		fields_hash => { inventory_id => 1, time => 1, subconcepts => 1 },
	);
	my %byid;
	if ($cursor)
	{
		while (my $doc = $cursor->next)
		{
			$byid{ _pit_oid_str($doc->{inventory_id}) } = { time => $doc->{time}, subconcepts => $doc->{subconcepts} };
		}
	}
	$self->{_pit_prefetch}{$node_uuid} = \%byid;   # overwrite-at-entry

	return NMISNG::Guard->new(sub { delete $self->{_pit_prefetch}{$node_uuid}; });
}

# Look up one inventory's prefetched reading. Returns the raw {time,subconcepts} doc on a
# hit, or undef on a miss OR when no buffer is active for this node (caller live-loads on undef).
sub pit_prefetch_lookup
{
	my ($self, $node_uuid, $oid) = @_;
	my $buf = $self->{_pit_prefetch}{$node_uuid};
	return undef if (!$buf);
	return $buf->{ _pit_oid_str($oid) };
}

# Write a freshly computed reading through to the buffer so same-cycle readers see it.
# No-op when no buffer is active for this node.
sub pit_prefetch_store
{
	my ($self, $node_uuid, $oid, $doc) = @_;
	my $buf = $self->{_pit_prefetch}{$node_uuid};
	return if (!$buf);
	$buf->{ _pit_oid_str($oid) } = $doc;
}
```
`NMISNG::Guard` and `NMISNG::DB` are already loaded by NMISNG.pm (used elsewhere in the file). `NMISNG::DB::make_oid` exists (DB.pm:1377) and returns a BSON::OID with both `->hex` and `->value`, so `_pit_oid_str` uses `->hex` for it — the same branch `$inv->id` (also BSON::OID) takes, so store and lookup keys agree.

- [ ] **Step 5: Run to verify it passes**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_pit_prefetch.pl`
Expected: PASS, all assertions, pristine output.

- [ ] **Step 6: Commit**

```bash
git add lib/NMISNG.pm test/t_pit_prefetch.pl
git commit -m "OMK-12375. Add per-node latest_data prefetch buffer primitives + kill switch."
```

---

## Task 2: get_newest_timed_data serves from the buffer (read path)

**Files:**
- Modify: `lib/NMISNG/Inventory.pm:695-739` (`get_newest_timed_data`)
- Test: `test/t_pit_prefetch.pl` (append)

**Interfaces:**
- Consumes: `$self->nmisng->pit_prefetch_lookup($node_uuid, $oid)` (Task 1).
- Produces: `get_newest_timed_data` returns the identical structure whether served from the buffer (cloned) or a live find; `from_timed == 1` always bypasses the buffer.

- [ ] **Step 1: Write the failing test (append to test/t_pit_prefetch.pl, before `$nmisng->get_db()->drop()`)**

```perl
# --- read path: buffer hit returns SAME structure as a live find ---
{
  my $ruuid = "aaaa1111-0000-0000-0000-000000000001";
  my $node = $nmisng->node(uuid=>$ruuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_read");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1}); $node->save();
  my $path = $node->inventory_path(concept=>"interface", data=>{ifDescr=>"e0"}, path_keys=>["ifDescr"]);
  my ($inv) = $node->inventory(concept=>"interface", path=>$path, path_keys=>["ifDescr"], model_class=>"interface", create=>1);
  $inv->data({index=>1, ifIndex=>1, ifDescr=>"e0"}); $inv->save(node=>$node);
  # write one real latest_data reading via the normal pit path
  $inv->add_timed_data(data=>{interface=>{ifInOctets=>100}}, derived_data=>{interface=>{ifInUtil=>10}},
                       subconcepts=>["interface"], time=>1234, flush=>1, node=>$node);

  my $live = $inv->get_newest_timed_data();          # no buffer -> live find
  ok($live->{success}, "live read ok");
  is($live->{data}{interface}{ifInOctets}, 100, "live read has data");

  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $ruuid);
  my $cached = $inv->get_newest_timed_data();        # buffer active -> served from buffer
  is_deeply($cached, $live, "buffer hit returns identical structure to live find");

  # mutating the returned cached structure must NOT corrupt the buffer (clone-on-read)
  $cached->{data}{interface}{ifInOctets} = -1;
  my $again = $inv->get_newest_timed_data();
  is($again->{data}{interface}{ifInOctets}, 100, "buffer entry unaffected by caller mutation (clone-on-read)");

  # from_timed bypasses the buffer (reads timed_<concept>)
  my $ft = $inv->get_newest_timed_data(from_timed => 1);
  ok($ft->{success}, "from_timed read still works (bypasses buffer)");
  undef $guard;
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_pit_prefetch.pl`
Expected: FAIL on "buffer hit returns identical structure" (get_newest_timed_data ignores the buffer; the cached read still hits the DB and the mutation/clone assertion is meaningless yet).

- [ ] **Step 3: Edit get_newest_timed_data to compute `$reading` from buffer-or-cursor, then share the existing transform**

Replace the body of `get_newest_timed_data` (Inventory.pm:695-739) with:
```perl
sub get_newest_timed_data
{
	my ($self,%args) = @_;
	my $from_timed = $args{from_timed} // 0;

	# inventory not saved certainly means no pit data, but  that's no error
	return {success => 1} if ( $self->is_new );

	my $reading;
	if( $from_timed )
	{
		my $cursor = NMISNG::DB::find(
			collection => $self->nmisng->timed_concept_collection( concept => $self->concept() ),
			query => NMISNG::DB::get_query( and_part => {inventory_id => $self->id}, no_regex => 1 ),
			limit => 1,
			sort        => {time => -1},
			fields_hash => {time => 1, subconcepts => 1}
		);
		return {success => 0, error => NMISNG::DB::get_error_string} if ( !$cursor );
		$reading = $cursor->next;
	}
	else
	{
		# OMK-12375: serve the previous reading from the per-cycle prefetch buffer if active.
		# Clone so the caller can never mutate the shared buffer entry.
		my $cached = $self->nmisng->pit_prefetch_lookup( $self->node_uuid, $self->id );
		if ($cached)
		{
			$reading = Clone::clone($cached);
		}
		else
		{
			my $cursor = NMISNG::DB::find(
				collection => $self->nmisng->latest_data_collection,
				query => NMISNG::DB::get_query( and_part => {inventory_id => $self->id}, no_regex => 1 ),
				fields_hash => {time => 1, subconcepts => 1}
			);
			return {success => 0, error => NMISNG::DB::get_error_string} if ( !$cursor );
			$reading = $cursor->next;
		}
	}

	# new driver doesn't offer cursor->count anymore...
	return {success => 1} if (!defined $reading);

	# data/derived data are stored for optimal searching (arrays of hashes),
	# turn them back into hashes (which are much handier for use in perl)
	foreach my $entry (@{$reading->{subconcepts}})
	{
		$reading->{data}{$entry->{subconcept}} = $entry->{data};
		$reading->{derived_data}{$entry->{subconcept}} = $entry->{derived_data};
	}

	return {success => 1, data => $reading->{data}, derived_data => $reading->{derived_data}, time => $reading->{time}};
}
```
(The transform + final return are byte-identical to the original; only the source of `$reading` changed. `Clone` is already imported at `Inventory.pm:39`.)

- [ ] **Step 4: Run to verify it passes**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_pit_prefetch.pl`
Expected: PASS, including the `is_deeply(cached, live)` equivalence and the clone-on-read mutation guard.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Inventory.pm test/t_pit_prefetch.pl
git commit -m "OMK-12375. get_newest_timed_data serves the previous reading from the prefetch buffer (clone-on-read)."
```

---

## Task 3: add_timed_data write-through

**Files:**
- Modify: `lib/NMISNG/Inventory.pm` (`add_timed_data`, just after the `subconcepts` array is built, ~line 643)
- Test: `test/t_pit_prefetch.pl` (append)

**Interfaces:**
- Consumes: `$self->nmisng->pit_prefetch_store($node_uuid, $oid, $doc)` (Task 1).
- Produces: after a flush-path `add_timed_data`, the buffer entry for that inventory reflects the new reading (so a later same-cycle `get_newest_timed_data` returns current, not previous).

- [ ] **Step 1: Write the failing test (append, before drop)**

```perl
# --- write-through: read-after-write returns the NEW reading (thresholds case) ---
{
  my $wuuid = "bbbb2222-0000-0000-0000-000000000002";
  my $node = $nmisng->node(uuid=>$wuuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_write");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1}); $node->save();
  my $path = $node->inventory_path(concept=>"interface", data=>{ifDescr=>"e1"}, path_keys=>["ifDescr"]);
  my ($inv) = $node->inventory(concept=>"interface", path=>$path, path_keys=>["ifDescr"], model_class=>"interface", create=>1);
  $inv->data({index=>1, ifIndex=>1, ifDescr=>"e1"}); $inv->save(node=>$node);
  # add_timed_data API: singular subconcept scalar + data = that subconcept's metrics hash
  # (NOT a plural subconcepts array, NOT data keyed by subconcept), no flush for a direct write.
  $inv->add_timed_data(data=>{ifInOctets=>100}, derived_data=>{},
                       subconcept=>"interface", time=>1000, node=>$node);  # previous

  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $wuuid);
  is($inv->get_newest_timed_data->{data}{interface}{ifInOctets}, 100, "buffer holds previous before write-through");

  # new reading this cycle -> write-through must update the buffer in memory
  $inv->add_timed_data(data=>{ifInOctets=>250}, derived_data=>{},
                       subconcept=>"interface", time=>2000, node=>$node);
  is($inv->get_newest_timed_data->{data}{interface}{ifInOctets}, 250, "buffer reflects new reading after write-through (read-after-write)");
  is($inv->get_newest_timed_data->{time}, 2000, "write-through updated the time too");
  undef $guard;
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_pit_prefetch.pl`
Expected: FAIL — the second read still returns 100 (the prefetched previous), because there is no write-through yet.

- [ ] **Step 3: Add the write-through in add_timed_data**

In `lib/NMISNG/Inventory.pm`, immediately after the line that builds the subconcepts array and deletes the hash forms (the block ending `delete $timedrecord->{derived_data};`, ~line 643), add:
```perl
		# OMK-12375 write-through: keep the per-cycle prefetch buffer current so a later
		# same-cycle reader (e.g. thresholds) sees this reading, not the prefetched previous one.
		# No-op when no buffer is active. Stored shape matches the latest_data find projection.
		$self->nmisng->pit_prefetch_store( $self->node_uuid, $self->id,
			{ time => $timedrecord->{time}, subconcepts => $timedrecord->{subconcepts} } );
```
(This is on the flush/upsert path that `save(... bulk_save ...)` uses, which is the only path collect/update take. The queued `else` branch is not on the collect/update hot path; a reader there simply misses the buffer and live-loads — correct.)

- [ ] **Step 4: Run to verify it passes**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_pit_prefetch.pl`
Expected: PASS — read-after-write returns 250 and time 2000.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Inventory.pm test/t_pit_prefetch.pl
git commit -m "OMK-12375. add_timed_data writes the new reading through to the prefetch buffer."
```

---

## Task 4: Wire the trigger into collect/update + golden gate + find-count + teardown

**Files:**
- Modify: `lib/NMISNG/Node.pm` (`collect` and `update`, just after the node lock is acquired)
- Test: `test/t_pit_prefetch.pl` (append integration assertions), `test/t_intf_collect.pl` (run as-is with prefetch on)

**Interfaces:**
- Consumes: `$self->nmisng->pit_prefetch_begin(node_uuid => $self->uuid)` (Task 1); the read/write-through (Tasks 2,3).

- [ ] **Step 1: Confirm the golden baseline is green before wiring**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS, all 14 (or current count) golden cases. (Prefetch not yet triggered in collect, so unchanged.)

- [ ] **Step 2: Add the trigger + guard to Node::collect**

In `lib/NMISNG/Node.pm` `sub collect`, after the node lock is successfully acquired (after the `$lock->{conflict}` handling block, before the first data-collection sub-call), add:
```perl
	# OMK-12375: prefetch this node's latest_data once; $pit_guard tears the buffer down
	# on scope exit (normal return OR exception), capping the worker memory high-water.
	my $pit_guard = $self->nmisng->pit_prefetch_begin(node_uuid => $self->uuid);
```
The `my $pit_guard` lexical must live to the end of `collect` (do not place it inside an inner block).

- [ ] **Step 3: Add the same trigger + guard to Node::update**

In `lib/NMISNG/Node.pm` `sub update`, after the lock is held/updated (before the first data-collection work), add the identical two lines:
```perl
	# OMK-12375: prefetch this node's latest_data once; guard tears down on scope exit.
	my $pit_guard = $self->nmisng->pit_prefetch_begin(node_uuid => $self->uuid);
```

- [ ] **Step 4: Run the golden gate (the behaviour-preservation check)**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_intf_collect.pl`
Expected: PASS, all golden cases **byte-identical** (no golden re-recorded). If any case diffs, STOP and investigate — the prefetch changed observable behaviour; do not re-record.

- [ ] **Step 5: Write the integration assertions (append to test/t_pit_prefetch.pl, before drop)**

```perl
# --- integration: find-count drop, teardown, teardown-on-exception ---
use NMISNG::Sys; use NMISNG::Snmp::Mock; use IntfTestHarness;
{
  my $iuuid = "cccc3333-0000-0000-0000-000000000003";
  my $node = $nmisng->node(uuid=>$iuuid, create=>1);
  $node->cluster_id($C->{cluster_id}); $node->name("pf_int");
  $node->configuration({host=>"127.0.0.1",group=>"NMIS9",active=>1,collect=>1,model=>"Generic"}); $node->save();
  my $N = 20;
  for my $i (1..$N) {
    my $p=$node->inventory_path(concept=>"interface",data=>{ifDescr=>"if$i"},path_keys=>["ifDescr"]);
    my ($inv)=$node->inventory(concept=>"interface",path=>$p,path_keys=>["ifDescr"],model_class=>"interface",create=>1);
    $inv->data({index=>$i,ifIndex=>$i,ifDescr=>"if$i",collect=>"true",real=>"true"});
    $inv->data_info(subconcept=>"interface",enabled=>1); $inv->enabled(1); $inv->historic(0); $inv->save(node=>$node);
    # seed a previous latest_data reading per interface (steady-state)
    # add_timed_data API: singular subconcept scalar + data = metrics hash, no flush.
    $inv->add_timed_data(data=>{ifInOctets=>$i}, derived_data=>{},
                         subconcept=>"interface", time=>1, node=>$node);
  }
  my $cp=$node->inventory_path(concept=>"catchall",data=>{},path_keys=>[]);
  my ($ca)=$node->inventory(concept=>"catchall",model_class=>"system",path=>$cp,path_keys=>[],create=>1);
  $ca->data_live->{ifNumber}=$N; $ca->save(node=>$node);

  # count latest_data finds during collect_intf_data, prefetch ON
  my @lf; { no warnings 'redefine'; my $orig=\&NMISNG::DB::find;
    *NMISNG::DB::find = sub { my %a=@_; my $n=(ref($a{collection})&&$a{collection}->can("name"))?$a{collection}->name:"$a{collection}"; push @lf,1 if $n=~/latest_data/; return $orig->(@_); }; }
  my $S=NMISNG::Sys->new(nmisng=>$nmisng);
  $S->init(node=>$node,snmp=>1,wmi=>0,catchall_inventory=>$ca);
  $S->{snmp}=NMISNG::Snmp::Mock->new(nmisng=>$nmisng,name=>$node->name,walk_data=>IntfTestHarness::generate_interface_walk(count=>$N));
  $S->{snmp}{session}=1;
  my $guard = $nmisng->pit_prefetch_begin(node_uuid => $iuuid);   # 1 latest_data find here
  @lf=();
  $node->collect_intf_data(sys=>$S, catchall_inventory=>$ca);
  ok(scalar(@lf) <= 1, "with prefetch, collect_intf_data issues <=1 latest_data find for $N interfaces (got ".scalar(@lf).")");
  undef $guard;
  ok(!exists $nmisng->{_pit_prefetch}{$iuuid}, "buffer torn down after cycle");

  # teardown on exception
  eval { my $g = $nmisng->pit_prefetch_begin(node_uuid => $iuuid); die "boom\n"; };
  ok(!exists $nmisng->{_pit_prefetch}{$iuuid}, "buffer torn down even when scope exits via die");
}
$nmisng->get_db()->drop();
done_testing;
```

- [ ] **Step 6: Run the integration assertions + the full prefetch test**

Run: `docker exec omk12375-nmis perl /usr/local/nmis9/test/t_pit_prefetch.pl`
Expected: PASS — `<=1 latest_data find` for 20 interfaces (down from ~20), buffer torn down on return and on die.

- [ ] **Step 7: Flag-off regression (kill switch)**

Run: `docker exec -e NMIS_PIT_OFF=1 omk12375-nmis perl -e 'print "covered by golden+flag test\n"'` is not how config flips; instead verify by temporarily setting the flag in a one-off:
Run: `docker exec omk12375-nmis perl -I/usr/local/nmis9/lib -e '
use NMISNG; use NMISNG::Util; use NMISNG::Log;
my $C=NMISNG::Util::loadConfTable(); $C->{pit_prefetch_enabled}=0; $C->{db_name}="t_pitoff-$$";
my $n=NMISNG->new(config=>$C, log=>NMISNG::Log->new(level=>"error"));
print( (defined $n->pit_prefetch_begin(node_uuid=>"x") ? "FAIL: got guard\n" : "ok: flag-off yields no buffer\n") );
$n->get_db()->drop();'`
Expected: `ok: flag-off yields no buffer`.

- [ ] **Step 8: Broader regression**

Run:
```bash
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_polling.pl
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_nmisng_node.pl
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_nmisng_inventory.pl
docker exec omk12375-nmis perl /usr/local/nmis9/test/t_model_data.pl
```
Expected: PASS (or the same pre-existing skips/failures as a clean `origin/nmis9_dev` checkout).

- [ ] **Step 9: Commit**

```bash
git add lib/NMISNG/Node.pm test/t_pit_prefetch.pl
git commit -m "OMK-12375. Trigger latest_data prefetch in collect/update with guard teardown; golden + find-count gate."
```

---

## Self-Review

**Spec coverage:**
- Buffer on nmisng keyed node_uuid->inventory_id (spec Design/The buffer): Task 1.
- Prefetch trigger + overwrite-at-entry (spec Lifecycle): Task 4 Steps 2-3 + Task 1 `begin`.
- Mandatory Guard teardown, fires on exception (spec Lifecycle/Memory): Task 1 `begin` returns Guard; Task 4 Step 5 asserts teardown on return AND die.
- Kill switch default-on (spec Kill switch / Global Constraint): Task 1 (`// 1`), tested Task 1 Step 1 + Task 4 Step 7.
- Read path: buffer hit (clone), miss->live, buffer-absent->live, from_timed bypass (spec Read path): Task 2.
- Write-through at add_timed_data (spec Write-through): Task 3.
- Read-after-write correctness for thresholds (spec Why it is correct): Task 3 test.
- Cross-node safety (spec): Task 1 test (`pit_prefetch_lookup("nodeB",...)` undef).
- I/O reduction N->1 (spec Testing 2): Task 4 Step 5/6.
- No behaviour change / golden gate (spec Testing 1): Task 4 Step 4.
- inventory_id stringify consistency (spec Global Constraint): Task 1 `_pit_oid_str` + its test.

**Placeholder scan:** Step 4-of-Task-1 notes a conditional fallback if `NMISNG::DB::make_oid` is absent — that is a real verify-then-branch with both branches specified (use make_oid, else obtain an OID from a created inventory), not a content gap. Task 4 Step 1 says "all 14 (or current count)" — the exact count is whatever `t_intf_collect.pl` reports at run time; the assertion is "all pass, none re-recorded," which is concrete. No code step lacks code.

**Type consistency:** `_pit_oid_str`, `pit_prefetch_begin/lookup/store`, `{_pit_prefetch}{$node_uuid}{$inv_id_str}`, `{time,subconcepts}` doc shape, `$self->node_uuid`/`$self->id` (Inventory), `$self->uuid` (Node), and `pit_prefetch_enabled` are used identically across Tasks 1-4. `make_oid`, `$inv->id`, and loaded latest_data `inventory_id` are all BSON::OID, so `_pit_oid_str` resolves them identically via `->hex`.
