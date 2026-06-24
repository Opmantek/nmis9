# collect_intf_data shared-load DB optimisation, and interface-function test coverage

Date: 2026-06-24
Branch: OMK-12375-worker-memory
Ticket context: SUPPORT-12368 / OMK-12375 (nmisd worker memory and Mongo IO on nmis4-ancf)

## Problem

On a heavily loaded NMIS box (1862 nodes, MongoDB co-hosted, ~85% iowait), the
collect path reads interface inventory from MongoDB far more than it needs to.
For a node with N interfaces, one collect cycle issues roughly:

- `collect` `Node.pm:9646`: 1 `get_inventory_ids` (ids only)
- `collect_intf_data` phase 1 `Node.pm:3916`: 1 bulk `find`, field-restricted when over 100 interfaces
- `collect_intf_data` phase 8 `Node.pm:4341`: one full `find` per collectable interface, i.e. **N queries**
- `compute_reachability` `Node.pm:6844`: 1 bulk `find` (already streamed via `next_object`)
- plugins via `ifinfo` `Node.pm:2858`: 1 bulk `find`, full fields, cached on the node

`$self->inventory(_id=>…)` always runs a fresh `get_inventory_model` (`Node.pm:989`),
with no cache shortcut. The field-restricted phase-1 read does not prevent the
phase-8 per-interface reloads, so the restricted read is the wasted half of a
double load and the dominant DB cost is the N per-interface queries in phase 8.

Measured on a synthetic 6000-interface node (real instance):
- restricted bulk read (phase 1): +14 MB RSS
- full bulk read (ifinfo-style): +28 MB RSS, 36.6 MB of data
- streamed `next_object` read: ~0 MB
- phase-8 per-interface loads: one object at a time, bounded memory, N DB round-trips

The memory and DB-load goals are in tension here. Reducing memory by keeping the
field restriction worsens the DB doubling. The agreed direction is the DB-load
fix: load the interface set once and reuse it. For nodes that run plugins (which
call `ifinfo`) the full set is already loaded once anyway, so the memory peak is
not made worse for that case.

## Scope

Staged. This spec covers:

1. **Deliverable A**: a reusable test harness and a full coverage suite for the
   interface collect/update functions, with golden baselines captured on the
   current (unchanged) code.
2. **Deliverable B**: the phase-1 to phase-8 reuse change inside
   `collect_intf_data`, gated behind Deliverable A.

Out of scope here (explicit follow-on): folding `ifinfo` and
`compute_reachability` into the same single load. It will be built on top of the
same test suite as a later change.

## Key correctness hazard

`save(update => 1)`, used by `update_intf_info` in phases 4/7, recomputes model
tags via `parse_model_for_tags` and writes them back into the object
(`Inventory.pm:1563-1567`, `1581-1585`), and assigns a possibly-new `_id`. For an
interface that changes during a collect:

- phase 4/7 creates/saves a fresh inventory with recomputed tags and a new `_id`
- phase 8 currently reloads fresh by `_id`, so it always sees the post-update state
- a naive load-once-reuse would hold the **stale phase-1 object** for that
  interface and lose the recomputed tags and the new `_id`

Phases 4/7 already refresh `if_data_map` and set a `_was_updated` marker
(`Node.pm:4110-4124`) but do **not** refresh the `if_inventory_map` objects built
in phase 1 (`Node.pm:3955`). The reuse design must close that gap.

A second, subtler hazard: phase 1 builds objects by hand with
`$class->new(%$maybeevil)` (`Node.pm:3955`), whereas phase 8 instantiates through
the standard `ModelData->objects` path. The two construction paths may not
produce identical objects, so reuse must be proven equivalent, not assumed.

## Design

### 1. Write-stream capture mechanism

Intercept at the write boundaries, following the pattern `t_polling.pl` already
uses, with no production code changes:

- DB writes: monkey-patch `NMISNG::DB::update`, `insert`, `remove` to push a
  normalised copy of each call (collection, query, record, flags) onto an ordered
  log, then call through to the real function.
- RRD writes: reuse `t_polling`'s existing `create_update_rrd` patch, which
  records the payload without doing IO.
- Events: capture via the event path (`Compat::NMIS::notify` / `eventAdd`).

The log is ordered, so order and multiplicity are compared, not only final
content. The final-state backstop is a dump of the node's inventory documents
after the collect. The `db_stats` counters are used only to assert the find-count
reduction, not as the content oracle (they carry no content or order).

### 2. Test harness architecture

Factor the mock setup out of `t_polling.pl` into a reusable helper,
`test/lib/IntfTestHarness.pm`, providing: temp Mongo DB, `Snmp::Mock` injection
from a walk fixture, the DB/RRD/event capture logs, and helpers to seed a node's
starting inventory and run one `collect`/`update` cycle. `t_polling.pl` is
refactored to use the same helper so it keeps working.

A small walk generator produces synthetic interface tables of a given size, so
cases can run at 5 interfaces (no cutback), 150 (over the 100 cutback), and a
large count to make the find-count win measurable. The existing
`snmpwalk_test.json` (~30 OIDs) is too small for this.

### 3. Coverage suite

`test/t_intf_collect.pl` exercising the branches in `collect_intf_data` and
`update_intf_info`, each asserting write-stream and final state:

1. Steady state, no change
2. New interface (in walk, not in inventory)
3. ifIndex change with stable ifDescr (reindex)
4. ifDescr change (path change, duplicate guard)
5. Interface removed (present in inventory, gone from walk) marked historic
6. Disabled or non-collect interface (not collected, not historic)
7. Historic interface, with and without `attempt_to_update_historic_interfaces`
8. Clashing ifIndex across two inventories
9. ifAdminStatus up/down transition triggering update
10. ifLastChange-based detection (model custom flag)
11. Non-SNMP node (early return)
12. `bulk_save` on and off
13. Over-100 interface count (cutback path today)

These run against current code first and their captured output becomes the
committed golden baseline.

### 4. Refactor mechanism and risk handling (phase-8 reuse)

- Phase 1: replace the restricted `$which_fields` load with a single full load,
  and build `%if_inventory_map` through the standard `ModelData->objects`
  instantiation rather than the hand-rolled `$class->new(%$maybeevil)` at
  `Node.pm:3955`, so a reused object is identical to a fresh phase-8 load.
- Phases 4/7: when `update_intf_info` produces `$maybenew`, store it into
  `if_inventory_map{$index}` so `_was_updated` interfaces carry the recomputed
  tags and correct `_id`.
- Phase 8: reuse `if_inventory_map{$index}` instead of `$self->inventory(_id=>…)`.
  If an entry is unexpectedly missing, fall back to the per-interface load and
  log a warning, so a logic gap degrades safely and visibly.

Memory effect of Deliverable B on its own: loading full fields in phase 1 raises
`collect_intf_data`'s own peak from roughly 14 MB to 28 MB for a 6000-interface
node, because the full set is now held in `if_inventory_map` for the function's
duration instead of one restricted record map. This is an accepted trade for the
DB-load win (1+N reads down to about 1). It becomes net-neutral only with the
follow-on, where `ifinfo` and `compute_reachability` reuse the same single load
that plugin nodes already pay for. Until then, the worker high-water on
plugin-less heavy nodes rises by that delta, which is bounded and reclaimed at
worker recycle.

Equivalence ("reuse equals reload") is proven by the section-1 write-stream diff
showing identical DB writes, RRD payloads, and events across every section-3
case, not asserted by inspection.

### 5. Error handling

- Missing `if_inventory_map` entry in phase 8: fall back to per-interface load,
  log a warning. Preserves current behaviour on any unforeseen gap.
- All existing error paths in `collect_intf_data` and `update_intf_info` are
  preserved unchanged.

## Sequencing and deliverables

- Deliverable A (committed first, no production change): harness helper, walk
  generator, and full `t_intf_collect.pl` coverage suite with golden baselines on
  current code.
- Deliverable B (gated behind A, separate commit): the phase-8 reuse change, which
  must leave every golden diff empty except the intended drop in interface `find`
  count, verified via `db_stats`.
- Follow-on (separate spec/plan): fold `ifinfo` and `compute_reachability` into
  the shared load.

## Success criteria

- Deliverable A: coverage suite passes on current code and records golden
  write-streams and final states for all 13 cases.
- Deliverable B: every section-3 case produces an identical write-stream and
  final state before and after the change, and the interface `find` count for a
  collect of an N-interface node drops from roughly `1 + N` to about `1`.

## Related, separately tracked

- D (already committed on this branch, `f1e88590`): defer `Mojo::UserAgent` load
  in `NMISNG::RPC`, ~7.5 MB per-worker baseline saving. No DB impact.
- Operational levers for the support ticket: reduce `nmisd_max_workers`, lower
  `nmisd_worker_max_cycles`, cap MongoDB WiredTiger cache.
- IO profiling: harvest `opstatus.stats.mongodb_stats`; add collection/call-site
  keying to `_start_time_and_count`; MongoDB profiler and OS-level split of
  Mongo vs RRD write IO.
