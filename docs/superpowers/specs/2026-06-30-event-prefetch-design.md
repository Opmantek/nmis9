# Event prefetch (OMK-12677) — design

Date: 2026-06-30
Branch: OMK-12677-event-prefetch (off nmis9_dev, base 158e2c34)
Status: design approved, feasibility spike not yet started
Related work: latest_data per-node prefetch (OMK-12668), collect_intf_data shared-load (OMK-12669), and this team's earlier events-optimisation note.

## Goal

Reduce the per-cycle reads of the `events` collection during a node collect and update by prefetching the node's current events once at cycle start and serving the `eventExist` / `checkEvent` existence-and-state checks from memory, instead of one indexed find per check.

This is the third and hardest of the per-interface read levers. It proceeds only behind a feasibility spike with a hard go/no-go gate. If the spike fails any gate criterion, OMK-12677 is closed as "not low-risk enough" and the audit produced by the spike is the artifact that explains why.

## Why this is the next lever, and why it is the hardest

A collect issues many event-existence checks per node: roughly nine node-level checks in `compute_reachability` (Node Down, SNMP Down, WMI Down, failover, and so on), two per collected interface (`eventExist("Interface Down", ifDescr)` then `checkEvent`), and one per proactive threshold per element. On the measured net-snmp node `realnode188` this was about 52 `events`-collection finds per collect. Each is an indexed point lookup, and the total grows with interface and threshold count.

The batch primitive that makes a prefetch possible already exists: `get_events_model(filter => { node_uuid, historic => 0 })` (`Events.pm:237`) returns all of a node's current events in one find. `eventExist` (`Events.pm:181`) loads by `node_uuid + event + element + historic` and checks `active` in Perl afterwards (the code even notes "active is ignored by event::load"), so a snapshot keyed by `(event, element)` holding the node's `historic <= 0` rows has everything the read side needs.

The difficulty is not reading, it is staying correct. latest_data was append-only: read the previous reading, write the new one, write-through was enough. Events are read-modify-write with deletes, many times per cycle, and by more than one process:
- `checkEvent` (`Compat::NMIS.pm:2188`) loads an event then conditionally clears it.
- `eventAdd` (`Events.pm:153`) raises an event (an upsert the unique partial index makes idempotent).
- `eventDelete` (`Events.pm:169`) clears an event.
- `eventUpdate` (`Events.pm:219`) replaces an event record.
- `cleanNodeEvents` (`Events.pm:71`, via `Node.pm:862` `eventsClean`, plus a direct `NMISNG::DB::remove` on the events collection at `Node.pm:759`) purges a node's events.

A stale snapshot here does not produce a slightly-wrong graph point the way latest_data would. It can produce a missed or duplicate alert. That is the bar this work has to clear.

## Approach

Mirror the latest_data per-node prefetch that shipped and was reviewed under OMK-12668. Reusing the proven, reviewed pattern is a deliberate choice that serves gate criterion #4 (contained change).

- A per-node in-memory buffer on the `NMISNG` object, keyed `node_uuid -> (event, element) -> event row`, holding the node's `historic <= 0` rows.
- Populated once at cycle start by a single `get_events_model(filter => { node_uuid, historic => 0 })`.
- Served for the read side: `eventExist` and `checkEvent`'s load.
- Write-through on `eventAdd` / `eventDelete` / `eventUpdate` so a later same-cycle read sees the just-raised, just-cleared, or just-updated state. The delete case (clear removes the in-memory row) is the new behaviour versus latest_data.
- Write-through runs only after the underlying DB write reports success, so a failed write leaves the buffer at the last committed state (the lesson from the OMK-12668 review).
- Teardown via `NMISNG::Guard` on normal return and on exception, capping the per-worker memory high-water mark.
- A default-on kill switch `event_prefetch_enabled`, parsed with `NMISNG::Util::getbool` (so `false`/`0` disable it), read once in the begin method. With it off, behaviour and counts are identical to today.
- Event classes the audit shows are mutated externally without holding the node lock are exempted and served live, the same move the latest_data work made for ping (written out of process by fastping).

## Go/no-go gate (all four must hold, else no-go)

1. **Load reduction (the evidence).** On `realnode188` the per-cycle `events`-find count drops from about 52 to a small constant (the one batch `get_events_model` plus any deliberately-exempted live reads), and a synthetic high-event node shows the per-event reads collapse to about one batch find regardless of count. Measured by collection with stack attribution, the way OMK-12668/12669 were measured.

2. **Behaviour-preserving (the hard gate).** A golden event-write-stream test proves the `eventAdd` / `eventDelete` / `eventUpdate` calls and their arguments are byte-identical with the buffer on versus off, across both collect and update, including the in-cycle raise→read and clear→read sequences where a later read in the same cycle must see the just-changed state.

3. **Bounded, documented cross-process window.** A complete inventory of every place an event changes outside collect/update, what each one changes, and a state-transition matrix of the effect by the buffer state at change time, together with the lock analysis (which external writers are serialised by the node lock and which leave a residual window). The residual is documented and explicitly accepted, not silent.

4. **Contained, understandable change.** The diff stays small and local: it reuses the latest_data Guard and kill-switch pattern, adds no new locking primitives, and is reviewable in one sitting. If making it correct requires wide or deep changes, that is a no-go on its own.

## Phase 1 — the feasibility spike

Ordered so the cheapest disqualifiers run first.

### 1a. External-mutation audit and lock matrix (done first — the linchpin)

Enumerate every caller of `eventAdd` / `eventDelete` / `eventUpdate` / `cleanNodeEvents` / `checkEvent` / `notify` across `lib`, `bin` (the nmisd daemon and escalation), `cgi-bin` and `htdocs` (the GUI), and `admin` (node admin and tools). For each writer that runs outside a collect/update, record:
- what it changes (raise, clear, ack, escalate-update, or node-wide purge), and
- whether it holds the `<node>.lock` flock that collect and update take (`Node.pm:9304`+, `LOCK_EX`).

Resolve the `eventsClean` / `cleanNodeEvents` purge: where it is triggered (the calls at `Node.pm:748` and `Node.pm:1549`, the latter carrying a `fixme9: we don't have any useful caller` comment), and whether it can run while a collect holds the lock.

Output is the state-transition matrix. Shape (cells filled from the audited writers):

| External change (other process) | buffer had it active | buffer had it absent/cleared | lock closes the window? |
|---|---|---|---|
| clears event X (GUI / escalation) | worker may re-clear X, possible duplicate "up" notify, DB already cleared so near no-op, self-corrects next cycle | no effect, both agree absent | per-writer: yes if it takes `<node>.lock` |
| raises event X | worker reads "absent", a raise is rejected by the unique partial index (caught), no duplicate row | consistent, no raise | per-writer |
| ack / escalate-update X | worker acts on a stale ack/escalate field for one cycle | not applicable | per-writer |
| purge all (`eventsClean`) | worker re-handles cleared events for one cycle (widest window) | not applicable | per-writer |

The filled matrix names which writers the lock serialises (window closed) and which leave a residual, and therefore which event classes, if any, must be exempted and served live. That documented residual is what satisfies criterion #3.

### 1b. Load measurement (the evidence)

Recreate `realnode188` in this worktree's stack (node_admin create, then a dev-tools update to pick the net-snmp model, then a collect to reach steady state). Count `events`-collection finds per collect and per update with the buffer off versus on, by collection with stack attribution (the `t_realnode_nodefinds.pl` method). Add a synthetic node with N interfaces each carrying an active event to show the per-event reads collapse to about one batch find. Target: `realnode188` about 52 to a small constant, synthetic shows linear scaling.

### 1c. Coherence prototype and correctness tests

A minimal prototype of the buffer behind the kill switch: `begin` / `lookup` / `store-with-delete`, serving `eventExist` and `checkEvent`'s load, with write-through on add/delete/update. Tests:
- Golden event-write-stream: capture the `eventAdd` / `eventDelete` / `eventUpdate` calls and arguments during a collect and an update, buffer off versus on, assert byte-identical, including in-cycle raise→read and clear→read.
- Adversarial cross-process: simulate an external write mid-cycle by writing directly to the events collection (bypassing the buffer), then assert the matrix's documented outcome holds (lock-prevented, exempted-and-read-live, or accepted residual).
- The `active`-ignored-by-load quirk and the unique partial index dup-key path are both covered.

### 1d. Contained-change check (criterion #4)

Record the prototype's blast radius: files touched, diff size, no new locking primitives, reuse of the latest_data Guard and kill-switch pattern. If correctness demanded wide or deep changes, that is a no-go on its own.

### The gate

All four criteria green proceeds to Phase 2. Any red closes OMK-12677, keeping the audit and matrix as the explaining artifact.

## Phase 2 — implementation (only if the gate passes)

Productionize the prototype, touching the same small set the spike used:
- `lib/NMISNG.pm` — buffer primitives, `event_prefetch_begin` and teardown, the kill switch.
- `lib/NMISNG/Events.pm` — `eventExist` / `eventLoad` served from the buffer, write-through hooks in `eventAdd` / `eventDelete` / `eventUpdate`.
- `lib/Compat/NMIS.pm` — `checkEvent`, which loads then conditionally clears, so both a buffer read and a write-through.
- `lib/NMISNG/Node.pm` — the lexical `Guard` trigger in `collect` and `update`, the same site as the latest_data trigger.
- Exemptions per the audit (classes served live).
- `test/t_event_prefetch.pl` (the suite) and `test/t_event_prefetch_realnode.pl` (the measurement).

## Data flow and safety

`begin` does one find and snapshots the node's current events. Reads are served from the snapshot. Writes go to the DB and then write-through to the snapshot only after the DB write reports success: a raise adds or replaces the row, a clear removes it, an update updates it. The `Guard` frees the snapshot at cycle end and on exception. Kill switch off means identical behaviour to today. Exempted event classes are always read live.

## Testing

Golden write-stream equivalence (buffer on versus off, collect and update); in-cycle raise→read and clear→read; adversarial cross-process writes matching the matrix; kill-switch off equals today; teardown on return and on exception; and the by-collection load measurement on the real and synthetic nodes.

## Risks the spike must resolve

- Which external writers share `<node>.lock`, and therefore the true size of the residual window.
- The exact triggers of `eventsClean` / `cleanNodeEvents` and whether they can run mid-collect.
- Whether `checkEvent`'s read-then-clear can be cleanly expressed as a buffer read plus a write-through.
- Whether the contained-change bar (#4) survives the exemptions the audit requires.

## References (nmis9_dev)

- `lib/NMISNG/Events.pm`: `cleanNodeEvents` 71, `eventAdd` 153, `eventDelete` 169, `eventExist` 181, `eventUpdate` 219, `get_events_model` 237.
- `lib/Compat/NMIS.pm`: `checkEvent` 2188, `notify` 2220.
- `lib/NMISNG/Node.pm`: `eventAdd` 809, `eventDelete` 816, `eventUpdate` 852, `eventsClean` 862, `eventsClean` calls 748 and 1549, direct events remove 759, the node lock 9304+, `lock(type => update)` 7198 and the 1697 "collect lock?" comment.
- `lib/NMISNG.pm`: events indexes 1464 (non-unique `node_uuid,event,element,historic`) and 1465 (unique partial on `historic <= 0`).
- Pattern to mirror: the OMK-12668 latest_data prefetch (buffer primitives, Guard teardown, getbool kill switch, write-through-after-commit, ping exemption).
