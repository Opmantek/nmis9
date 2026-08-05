# OMK-12605 follow-up: fping-owned events don't refresh or reach the dashboard file

Date: 2026-08-04
Ticket: OMK-12605 (follow-up to the operational event status documents work)
Status: proposed, pending team review — no implementation yet

## Summary

The operational status document work (8 tasks, already implemented and reviewed) delivers correctly for every event that's checked directly inside a node's own `collect()`/`update()` cycle: Interface Down, SNMP Down, WMI Down, Service Down, custom model alerts, and Node Polling Failover. Two specific events — **Node Down** and **Backup Host Down** — are handled by a separate background process (the fping worker) that only acts on state *transitions*, not on every cycle. That mismatch causes two concrete problems, both traced to actual code during a final whole-branch review, not theoretical. Backup Host Down is one of the two events this entire ticket exists to expose in the dashboard file — so this follow-up is not a polish item, it's a gap in the ticket's core deliverable.

This document describes both problems, why they happen, and the fix proposed to close them. Nothing has been implemented yet — this is for team review before that work starts.

## Background

NMIS9 writes MongoDB "status" documents (`ok`/`error`, refreshed every poll) for threshold checks and model alerts, but historically never for ordinary code-raised events like Node Down or Interface Down. The base OMK-12605 work added a third writer (`method: Operational`) by hooking into `notify()` (raises/refreshes an `error` doc) and `checkEvent()` (raises/refreshes an `ok` doc) — the two functions that already handle event bookkeeping everywhere in the codebase. Because most callers of `notify`/`checkEvent` run every single poll cycle regardless of whether anything changed, the status documents refresh automatically, with no changes needed at any call site.

That assumption — "these functions get called every cycle" — was true before this ticket too, in the sense that nothing needed it to be true. `notify`/`checkEvent`'s original job, before this ticket, was purely event bookkeeping: create or update an event record, decide severity, decide whether to log or escalate. The new status-document feature rides on top of that existing call pattern rather than replacing it — and it holds everywhere that pattern was already "call every cycle regardless." It does not hold in the one place that pattern was never built that way.

## The two problems

### Problem 1: Node Down and Backup Host Down don't refresh, and a never-down node gets no entry at all

Node Down, Backup Host Down, and the failover event are raised by a *separate background process*, the fping worker (`bin/nmisd`), not by `collect()`. That worker is deliberately fast and lightweight — it exists so an outage is detected within about a minute, instead of waiting for the next full (heavier, less frequent) SNMP poll cycle. To do that cheaply, it only calls `notify`/`checkEvent` when the state actually **changes**:

- Raising: `bin/nmisd:3090`, `if (!$event->exists || $down_status_in_catchall ne 'true')`
- Clearing: `bin/nmisd:3147`, `if ($event->exists && $event->active)`

Both are transition gates, not per-cycle checks. This is correct and deliberate for the fping worker's actual job — nobody wants a "Node Down" event logged and escalated again every minute while an outage continues. The gap is that the new status-document feature was built assuming this call pattern behaves the same way everywhere `notify`/`checkEvent` are used, and it doesn't.

Consequences, verified directly against the code:

- **While a condition persists, its status document is never refreshed.** Written once at the moment of transition, then untouched until the condition clears. These documents are correctly exempt from the routine 500-second staleness sweep (Task 5 of the base work), but still subject to the normal 24-hour expiry. A node down, or running on backup, for longer than 24 hours has its status document silently expire, even though the condition is still real.
- **A node that has never once gone down never gets an entry at all.** The "clear" branch only runs when there's an existing active event to clear (`bin/nmisd:3147`). A permanently healthy node never has one, so `checkEvent` is never called for it, so no `ok` document is ever created — unlike every other event type in this feature, where a healthy check produces an `ok` entry from its first poll.

**Node Polling Failover is not affected.** It's raised directly inside `collect()` itself (`lib/NMISNG/Node.pm:9631` and `:9643`), on every cycle, with no transition gate — same pattern as Interface Down and SNMP Down. Verified directly. So one of the two events named in the original customer request already works correctly; only Backup Host Down (and, more broadly, Node Down) has this refresh gap.

**Correction — note on `bin/nmisd`'s interaction with Backup Host Down, added during the final whole-plan review.** The paragraph above, and the raising/clearing gate description just before it, are accurate for Node Down and for Backup Host Down's *code path*. But a whole-plan review traced `bin/nmisd`'s raise gate (`bin/nmisd:3084-3090`: `if (!$event->exists || $down_status_in_catchall ne 'true')`, where `$down_status_in_catchall = $catchall_data->{"${whatevent}down"}`) specifically for the backup case, and found that before this follow-up plan, nothing ever wrote a `backupdown` catchall flag at all — the flag-writing regex in `handle_down` only covered `snmp|wmi|node`. That means `$down_status_in_catchall` was always `undef` for Backup Host Down, and in Perl `undef ne 'true'` is always true — so the raise gate was **always open**, and `bin/nmisd` was calling `notify()` for Backup Host Down on every single fping cycle while a backup was down, not just on transition, contrary to how the gate is described working above.

Two practical implications follow from this, both re-verified directly against the code:

1. `bin/nmisd`'s *code* is genuinely untouched by this follow-up (still true, see "What stays untouched" below) — but its *runtime behavior* for the backup path does change as a side effect of Task 2 populating `backupdown` correctly. Once that flag is written, the raise gate starts closing after the first down cycle, matching how Node Down already behaved, instead of staying permanently open. This is a beneficial side effect — it stops needless per-cycle event re-raising/re-logging for a condition that hasn't changed — not a regression. It should be stated plainly rather than left implied by "nothing changes here."
2. This also means the *refresh-cadence* half of Problem 1, as originally written above, did not actually apply to Backup Host Down's down-state the way described — its status document (once such a thing existed) would already have been refreshing every fping cycle, just via this latent gate-always-open quirk, not by design. The two things that genuinely still needed fixing for Backup Host Down were: (a) a permanently healthy node never getting an `ok` entry at all (the gate only opens when something needs raising, never fires for "nothing to raise" — this part of Problem 1 is unaffected by the correction above and still applies in full), and (b) the dashboard-file visibility gap (Problem 2). Both remain correctly diagnosed and are the real reasons this event needed the fix.

### Problem 2: dashboard-file visibility is broader than just fping — it's a structural gap, not an fping-specific one

The per-node dashboard file is only ever assembled and written by `collect()`/`update()`, using a "push" model: each keeps a scratch in-memory structure (`dashnode_context`) alive for the duration of one call, and any status-document save that happens *while that structure exists* gets automatically mirrored into it. At the end of the call, that structure is flushed to the JSON file.

The fping worker is a **different operating system process**, and its throwaway `$nmisng` object was never set up through `load_dashnode_data`, so it has no `dashnode_context` to be mirrored into. The write to MongoDB still succeeds — it's a correct, real document — the file simply has no way of learning it happened.

This turns out not to be unique to fping. Checked directly: **`services` can also run as its own independently-scheduled job** (`lib/NMISNG/Node.pm:8199`, `sub services`), completely separate from a `collect()` run, and it never calls `load_dashnode_data`/`save_dashnode_data` either. So Service Down/Service Degraded can hit this same visibility gap on any site that schedules services checks on their own cadence rather than folded into `collect()`. The difference: `collect_services()` itself re-evaluates and calls `checkEvent`/`notify` fresh every time it runs regardless of schedule (`lib/NMISNG/Node.pm:9126-9199`), so services never has Problem 1's refresh/staleness issue — only this visibility gap, and only when scheduled standalone. This document's fix targets the fping case specifically, since that's the customer-facing gap; the services case is noted here as a structurally identical, separately-triggered instance worth its own follow-up if it's confirmed to occur in practice.

## Proposed solution

Extend `collect()`'s existing per-cycle work, rather than changing the fping worker or adding a new database read at file-write time.

### Why not modify the fping worker, and why not query the database at write time

Two alternatives were considered and set aside:

1. **Decouple the fping worker's status write from its transition gate**, so it refreshes MongoDB every cycle regardless of state change. This would fix the refresh/staleness half of Problem 1, but does nothing for Problem 2 — the write still happens in a process with no `dashnode_context`, so the file still never sees it.
2. **Query MongoDB for current status at the moment the dashboard file is written**, replacing the in-memory push with a direct read. This would fix Problem 2 in general, but adds a new database read to every `collect()`/`update()` call — and the dashboard file has a standing resource constraint from the original requirements: **dashnode file read/write must stay under 10% of overall resource use.** Adding a new per-cycle query for this is exactly the kind of cost that constraint was meant to guard against, and it's avoidable.

### The actual proposal: give `collect()` what it needs, using data it already has

`collect()` already reads everything required to know the current node/backup state, every cycle, regardless of whether the fping worker owns the down/up decision:

- **Node Down**: the catchall already carries a `nodedown` flag, kept current by `handle_down` (`lib/NMISNG/Node.pm:2166-2176`) whichever process last updated it. `collect()` can read this flag directly — no new query, no new computation.
- **Backup Host Down**: `pingable()` already reads the cached fping ping data every cycle regardless of who owns the decision, and already determines whether it's using the primary or the backup host's numbers, as part of its existing logic (`lib/NMISNG/Node.pm:1966-1977`). That's exactly the signal needed — it's already sitting in memory during `collect()`'s normal run, at zero extra cost.

The fix: inside `collect()`'s existing per-cycle pass, add a step that writes/refreshes the operational status document for these events using this already-available data, independent of whatever the fping worker decides to do with the actual event (raise, clear, log, escalate) on its own faster schedule. Because this write happens *inside* `collect()`, the existing `dashnode_context` push mechanism (already built by the base OMK-12605 work) picks it up automatically — the same mechanism Interface Down and SNMP Down already rely on. No change to `bin/nmisd`. No new database query.

**Precise anchor:** `pingable()` (`lib/NMISNG/Node.pm:1911-2114`) has a block shaped `if ($mustping) { ...calls handle_down... }` at lines 2018-2092 — this only runs when fping's cached data is missing or stale (`collect()` falls back to pinging and owning events itself in that case). When `$mustping` is false — fping owns the decision, the normal case — that block currently does nothing at all for events or status. The fix is a paired `else` alongside it: when fping owns the decision, don't touch the event, but still refresh the status document from data already in scope (`$catchall_data->{nodedown}`, already a live reference via `data_live()` at line 1920; and, for Backup Host Down, the primary-vs-backup values already read at lines 1966-1977, which will need a small new tracking variable — the existing code overwrites `$ping_loss` etc. in place when it switches to backup numbers, without recording *that it switched*, so a boolean like `$used_backup` needs to be set alongside that overwrite for the new step to read).

**What the new step calls:** `NMISNG::Status::save_operational_status`/`close_operational_status` directly — *not* the full `notify()`/`checkEvent()`. Those can create or rename event records, which must stay the fping worker's exclusive responsibility; the status-document helpers only ever touch the status collection, so `collect()` and the fping worker can run independently on their own schedules without ever conflicting over event ownership.

### What stays untouched

- The fping worker's transition-gated event raising/clearing, logging, and escalation — unchanged. Outage detection stays on its fast, roughly one-minute cadence.
- The dashboard file's existing push-based assembly mechanism — unchanged. This fix uses it, rather than replacing it with a pull.

### The one honest trade-off

Status-document freshness for these two events now follows `collect()`'s cadence (typically a few minutes) rather than fping's faster cadence (roughly a minute). The actual up/down *decision*, logging, and escalation are unaffected by this — they remain exactly as fast as they are today. A document refreshing every few minutes is far inside the 24-hour TTL window that was the original concern, so this doesn't reopen the staleness problem; it just means the document's timestamp granularity matches `collect()`'s cycle rather than fping's.

### Why this is sufficient

- Refresh: solved — `collect()` writes the current true state every time it runs, regardless of whether a transition happened.
- Never-down node with no entry: solved — the same per-cycle write creates the `ok` entry from the node's first `collect()` cycle, the same way Interface Down already works.
- Dashboard-file visibility: solved — the write happens inside the same process that already owns `dashnode_context`, so it's picked up for free.
- Resource budget: respected — no new database *reads* beyond what `collect()` already does each cycle (verified: no new queries appear anywhere in the diff). This does add one status-document upsert *write* per node per collect cycle (two for multihomed nodes, since Node Down and Backup Host Down are separate writes) — a marginal, expected cost inherent to the feature, comparable to what threshold/interface status docs already cost, not a problem the resource-budget constraint above was aimed at. The original "no new reads or writes" phrasing overstated this; corrected here during the final whole-plan review.

## Explicitly out of scope for this document

- **The `services`-as-standalone-job visibility gap** noted above. Same underlying pattern, but not customer-facing today the way Backup Host Down is, and deserves its own confirmation of whether any site actually schedules it that way before committing to a fix.
- **The separate Events.nmis upgrade-propagation issue**, a second Critical finding from the same final review: the config defaults added in the base work (`Status => false` on a few events) can't reach a customer who already has their own `conf/Events.nmis`, because the install/upgrade tooling only auto-merges `Config.nmis` — every other config file is diffed for manual review, never auto-applied. That's an installer/deployment question, unrelated to the code paths discussed here, and needs its own separate decision.

## Next steps

Pending team review of this document. Once agreed, the next step is the same process used for the original 8 tasks: update the design spec, write a task-by-task implementation plan with the exact test-first steps, and implement each task with its own review before a final whole-branch review — no code changes happen before that review completes.
