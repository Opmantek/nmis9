# Per-node latest_data prefetch (batch-by-node) — design

Date: 2026-06-25
Branch: OMK-12375-worker-memory (implementation branch chosen at planning time)
Ticket context: SUPPORT-12368 / OMK-12375 (nmisd MongoDB I/O on nmis4-ancf)
Status: design for review

## Problem

During one collect of a node with N interfaces, `latest_data` is read once per interface
(`get_newest_timed_data`, lib/NMISNG/Inventory.pm:695) to fetch the previous point-in-time
reading needed for counter-delta/rate computation. Measured (dev stack, instrumented
NMISNG::DB::find): collect_intf_data issues exactly 1 `latest_data` find per interface
(N=50 -> 50, N=150 -> 150). Other concepts (catchall, cbqos, systemHealth, ping) add more of
the same shape across ~16 call sites. Each find is an indexed unique point lookup
(`latest_data` has `{inventory_id:1}` UNIQUE, verified live) — so the cost is not a missing
index, it is the COUNT of serial round-trips (~0.4 ms each: network + driver + BSON decode).
For a 1000-interface node that is ~1000 latest_data finds ~= ~400 ms per collect, every cycle.

`latest_data` also already carries a `{node_uuid:1}` index (verified live), so all of a node's
latest_data can be fetched in ONE query with no new index. This design does exactly that and
serves the per-interface reads from an in-memory buffer.

This is the "Idea 1 / latest_data half" of research-9 (.superpowers/sdd/research-9-livedata-finds.md);
events are a separate follow-on (different process writer, multi-event-type — out of scope here).

## Scope

In: the `latest_data` reads via `get_newest_timed_data` (the `from_timed == 0` path only) for the
node currently being collected/updated, replaced by one batch find per cycle + an in-memory buffer
with write-through.

Out (documented follow-ons): events prefetch; the per-node `latest_data` storage reorg
(research-9 Idea 3); the `from_timed == 1` path (reads the timed_<concept> history, not latest_data).

## Design

### The buffer
A per-cycle buffer on the nmisng object (the only object every Inventory can reach via
`$self->nmisng`, since Inventory holds no node backref — only weak `_nmisng` + `_node_uuid` + `id`):

    $nmisng->{_pit_prefetch} = { <node_uuid> => { <inventory_id_str> => <raw_latest_doc> } }

- `<inventory_id_str>`: the inventory `_id` rendered through ONE shared stringification helper,
  applied identically when building the buffer (from each found doc's `inventory_id`) and when
  looking up `$self->id` on read. Use the same logic get_inventory_ids already uses
  (Node.pm:887: `->hex` if the OID supports it, else `->value`) so MongoDB::OID vs BSON::OID
  differences cannot cause a key mismatch (which would silently turn every hit into a miss).
- `<raw_latest_doc>`: the raw `latest_data` document shape `{ time => ..., subconcepts => [ ... ] }`
  — exactly what the `latest_data` find returns and what `get_newest_timed_data` already knows how
  to transform (Inventory.pm:732-738). Storing raw keeps ONE transform path: hits and live cursor
  results go through the same code.

### Lifecycle
- **Prefetch trigger** — at the top of `Node::collect` and `Node::update`, when the kill switch is
  on, issue one `find(latest_data, {node_uuid => $node->uuid}, fields={inventory_id, time, subconcepts})`,
  build `{inventory_id_str => raw_doc}`, and store it under the node_uuid key (OVERWRITING any prior
  entry for that node_uuid).
- **Teardown (mandatory, memory-critical)** — the trigger creates an `NMISNG::Guard`
  (lib/NMISNG/Guard.pm; its DESTROY runs a stored coderef) whose coderef does
  `delete $nmisng->{_pit_prefetch}{$node_uuid}`. The guard is a lexical in `collect`/`update`, so
  teardown fires on normal return AND on die/exception. This caps the worker high-water mark at ONE
  node's readings: without teardown, a worker keyed-by-node_uuid would accumulate a buffer for every
  distinct node it polls across its ~100 cycles, and Perl never returns that memory to the OS.
  Overwrite-at-entry is defence-in-depth (a re-poll refreshes before any read) but is NOT the memory
  control — teardown is.
- **Kill switch** — config flag `pit_prefetch_enabled` (default true). When false the trigger is
  skipped, the buffer is never populated, every read falls through to a live find, and write-through
  is a no-op => byte-for-byte current behaviour. The flag is read once at trigger time.

### Read path — `get_newest_timed_data` (Inventory.pm:695)
For the `from_timed == 0` (latest_data) path only:
1. If `$nmisng->{_pit_prefetch}{$self->node_uuid}` exists (buffer active for this node):
   - hit (`$self->id` present): take the raw doc, apply the existing transform (732-738), return
     `{success=>1, data, derived_data, time}` — identical to a live result.
   - miss: fall back to a live `find` (a new inventory with no reading yet, or any gap). Completeness
     is never assumed, so the worst case equals today's behaviour for that one inventory.
2. If no buffer for this node (reports, GUI, webservice, the threshold job before any collect, any
   non-prefetched caller): live find, exactly as now.
The `from_timed == 1` path is unchanged (it queries timed_<concept>, not latest_data).

### Write-through — at `add_timed_data` (Inventory.pm:~631-687)
Whenever `add_timed_data` builds a new timed record `$timedrecord` for an inventory, and a buffer is
active for `$self->node_uuid`, set
`buffer{node_uuid}{$self->id_str} = { time => $timedrecord->{time}, subconcepts => $timedrecord->{subconcepts} }`.
This happens in BOTH the flush/upsert branch (the collect path, line ~668) and the queued branch
(line ~684), so the buffer always reflects the most recently computed reading regardless of the bulk
write path. The write-through is in-memory and immediate — independent of whether the DB upsert is
bulked and flushed later. Buffer absent => no-op.

## Why it is correct

- **The read-after-write (thresholds):** `collect_intf_data:4449` reads each interface's previous
  reading BEFORE that interface's `save` (so before write-through updates the buffer) => it gets the
  previous value. `compute_thresholds` (collect:9707, via applyThresholdToInventory ->
  get_newest_timed_data, NMISNG.pm:224) runs AFTER the interface was saved => the buffer holds the
  current reading via write-through. Both correct, order-independent. This mirrors the behaviour
  already verified for the bulk-save path: end_bulk (collect_intf_data:4526, synchronous
  `$bulk->execute`) commits latest_data before thresholds (9707) read it, so thresholds read current
  data whether bulk is on or off. The prefetch's write-through preserves exactly that guarantee in
  memory.
- **No cross-interface contamination:** each interface reads/writes its own inventory_id key; a later
  interface in the loop still reads its own (un-saved) previous value.
- **Cross-node safety:** keyed by node_uuid; node A's buffer can never serve node B (and cross-node
  readers — cdpTable, lldpTable, Outage — operate on a different node_uuid, so they miss A's buffer
  and live-load correctly).
- **Lifetime:** the buffer exists only between the trigger and the guard teardown within one
  collect/update; overwrite-at-entry makes a skipped teardown non-corrupting, and the guaranteed
  teardown makes it non-accumulating.
- **Miss safety:** a miss is a live find, never a fabricated "no data", so a partial/empty buffer can
  never cause a spurious counter reset.

## What this does NOT change

- No write is added, removed, reordered, or rebatched. RRD writes, event writes, the `latest_data`
  upsert/timed inserts, and the immediate inventory-record write are all untouched.
- The `from_timed == 1` history reads, the inventory-record reads, events, and thresholds' own logic
  are untouched.
- With the flag off, behaviour is identical to today.

## Memory

Buffer = one node's latest_data readings at a time (raw `{time, subconcepts}` docs, ~the same bytes
the N live finds would have transferred anyway, now held together briefly). Teardown frees them back
to Perl's arenas before the next node is prefetched, so the per-worker high-water rises by at most one
node's readings — bounded and explicitly reclaimed, never accumulated across the worker's job
sequence. For a 2000-interface node that is ~2000 small docs, transient.

## Testing

Gate with the existing golden write-stream harness (test/t_intf_collect.pl, test/lib/IntfTestHarness.pm):
1. **No behaviour change:** with prefetch ON, every existing golden case produces a byte-identical
   write-stream (DB writes, RRD payloads, events) and final inventory state.
2. **I/O reduction:** seed `latest_data` for the node's interfaces (a previous reading per interface),
   then assert via SHOW_DBSTATS that `latest_data` finds drop from N to 1 across the collect.
3. **Read equivalence (unit):** with a seeded `latest_data`, assert `get_newest_timed_data` returns
   the SAME structure from a buffer hit as from a live find (drive both, deep-compare).
4. **Write-through / read-after-write:** assert that after an interface is saved in-cycle, a
   subsequent `get_newest_timed_data` for it returns the NEW reading (what thresholds would read), not
   the prefetched previous one.
5. **Teardown:** assert `$nmisng->{_pit_prefetch}` has no entry for the node after collect/update
   returns, and that it is also cleared when collect/update dies mid-cycle (guard fires on exception).
6. **Miss -> fallback:** an interface with no prior `latest_data` returns the same `{success=>1}` (no
   data) via the buffer-miss live-fallback path as it does today.
7. **Flag off:** with `pit_prefetch_enabled` false, no prefetch find is issued, write-through is a
   no-op, and the write-stream + find counts match today's behaviour exactly.

## Success criteria

- Every golden case byte-identical with prefetch on (criterion 1) — the behaviour-preserving gate.
- `latest_data` find count for an N-interface collect drops from ~N to ~1 (criterion 2).
- Buffer empty after every cycle, including on exception (criterion 5).
- Flag-off path identical to today (criterion 7).

## Follow-ons (out of scope, recorded)

- Events batch-by-node prefetch (research-9 Idea 1, events half): higher risk — a separate escalation
  process also writes events, and there are many event types; needs its own design.
- Per-node `latest_data` storage reorg (research-9 Idea 3): one doc per node, collapsing the N
  latest_data WRITES too; bounded by the 16 MB document limit at extreme interface counts.

## Touch points (load-bearing)

- lib/NMISNG/Inventory.pm:695-739 (get_newest_timed_data — read path + transform), :631-687
  (add_timed_data — write-through), :668 (latest_data upsert), :684 (queued path), :815 (nmisng accessor)
- lib/NMISNG/Node.pm:9427 (Node::collect — prefetch trigger + guard), Node::update (trigger + guard),
  :4449 (per-interface previous read), :4526 (end_bulk flush), :9707 (compute_thresholds)
- lib/NMISNG.pm:224 (applyThresholdToInventory reads latest_data after the flush),
  latest_data_collection accessor, the {node_uuid:1} index (:1522)
- lib/NMISNG/Guard.pm (the DESTROY-runs-coderef guard for teardown)
- config: pit_prefetch_enabled (new flag, default true)
- test/t_intf_collect.pl, test/lib/IntfTestHarness.pm (golden + SHOW_DBSTATS gate)
