# Operational event status documents (OMK-12605)

Date: 2026-07-27
Ticket: OMK-12605 (Telmex, billable)
Supersedes: branch `feature/OMK-12605` (GitHub PR #183, unmerged)
Status: design approved in brainstorming, pending implementation plan

## Background

NMIS9 keeps two related but distinct records:

- **Events** record that a condition occurred. They are created by
  `Compat::NMIS::notify`, closed by `Compat::NMIS::checkEvent`, and become
  historic after clearing.
- **Status documents** (`NMISNG::Status`, mongo `status` collection) describe
  the current state of a monitored property. Each doc carries
  `status => "ok"|"error"`, is upserted every poll cycle, and feeds the
  `status_summary` health percentage and the per-node dashnode JSON file.

Only two writers create status documents today: `thresholdProcess`
(`lib/NMISNG.pm`, `method => "Threshold"`) and the model alert processing
(`lib/NMISNG/Node.pm`, `method => "Alert"`). Code-raised events such as Node
Down, SNMP Down, Interface Down, Backup Host Down, and Node Polling Failover
never produce a status document.

The codebase shows this is an incomplete port rather than a deliberate
exclusion:

- `conf-default/Events.nmis` declares `'Status' => 'true'` on nearly every
  event, including all code-raised ones. That flag's only consumer is the
  status-summary loop, which never sees those events because no writer exists.
  The flag has been dead config for them since NMIS9 shipped.
- `Status::update_dashnode_data` already contains an `else` branch that keys
  entries for methods other than Threshold and Alert (`event--element`).
- `NMISNG::Status` is schema-loose and validates docs without threshold
  fields.

Telmex (OMK-12605) asked for Backup Host Down and Node Polling Failover in
the dashnode file. The `feature/OMK-12605` branch did this by copying raw
event documents into the dashnode status hash at the end of collect/update.
Telmex then clarified they want persistent entries with a `status: error|ok`
field for all operational and threshold events, in one consistent shape.
Threshold entries already behave exactly that way. This design gives
code-raised events the same treatment through the same machinery, replacing
the branch.

## Goals

1. Code-raised events produce ordinary status documents so they appear in the
   status collection, the dashnode JSON, and the GUI status view in the same
   shape as threshold entries.
2. Entries persist and flip between `error` and `ok` rather than appearing
   and disappearing.
3. Per-event site control over both writing and health-calculation impact.
4. No change to node health numbers on upgrade with default config.
5. A single write path that threshold and alert writers can migrate onto
   later.

## Non-goals

- Migrating `thresholdProcess` and the alert writer onto the new helper
  (designed for, not done here).
- Real-time status updates between polls. Nothing consumes them.
- An end-of-collect reconciliation pass. Considered and dropped, see
  Accepted limitations.

## Design

### Write points

The status write happens inside the two uniform event functions in
`Compat::NMIS`:

- **`notify`** calls the helper with `status => "error"` and the event's
  level, details, element, context, and inventory_id. This includes the
  short-circuit path where the event already exists, so an ongoing outage
  refreshes its doc every poll.
- **`checkEvent`** calls the helper with `status => "ok"` and
  `level => "Normal"`. This includes the path where no down event exists,
  which is the common healthy case.

No call sites change. This works because NMIS calls these functions every
cycle, not only on transitions: `handle_down(... up => 1)` fires on every
successful poll, `checkEvent(Interface Down)` on every collect of a healthy
interface, and `notify` repeats while a condition persists. Docs therefore
refresh each cycle exactly like threshold docs, and a healthy node acquires
its ok entries from the first collect (Node Down always, SNMP/WMI Down when
that source is enabled, Backup Host Down and Node Polling Failover when
`host_backup` is configured).

### The helper

New class method `NMISNG::Status::save_operational_status`, taking nmisng,
node, event name, element, status,
level, details, context, and inventory_id. It:

1. Applies the gates below and returns without writing when any gate fails.
2. Builds an `NMISNG::Status` doc with `method => "Operational"` and saves
   it (upsert via the existing `_query` identity, TTL refreshed via
   `purge_status_after` like every other status doc).

Its argument list is chosen so `thresholdProcess` and the alert writer can
later call the same helper with `method => "Threshold"|"Alert"` and their
extra fields, completing the normalisation as a follow-up.

### Gates (checked in the helper)

1. **Threshold and alert sources are skipped.** They write their own docs.
   Detection: `context->{type}` is `threshold` or `alert`. `notify` already
   receives it from both writers. `thresholdProcess`'s `checkEvent` call
   gains `context => {type => "threshold"}` (one added argument, so
   custom-named threshold events are caught too). The established name
   pattern (`/^Proactive|^Alert: /`) stays as a fallback for `checkEvent`
   calls without context, which covers the alert clear path.
2. **Stateless events are skipped.** A one-shot notification has no ok/error
   state. Uses the same stateless determination `notify` already performs
   (config `non_stateful_events` regex plus the Events.nmis `Stateful`
   flag).
3. **`TrackStatus => 'false'` is skipped.** New optional per-event flag in
   Events.nmis, default true. See Controls.

### Data model

Ordinary `NMISNG::Status` documents:

| Field | Value |
|---|---|
| method | `"Operational"` |
| event | event name, e.g. `"Node Down"` |
| element | event element or empty string (node-level) |
| status | `"error"` while active, `"ok"` when clear |
| level | event level while active, `"Normal"` when ok |
| details | from the notify/checkEvent call |
| inventory_id | when the event carries one |
| property, index, class, section, source | empty string, held constant so the upsert identity is stable |

Dashnode file entries flow through the existing
`Status::update_dashnode_data` else-branch, key `event--element`, and have
the same shape as threshold entries. Status docs are written regardless of
`enable_dashnode_file`. The file is a view, not the store.

### Controls: two flags, two meanings

- **`Status` (existing, unchanged meaning):** "may this doc affect
  status_summary". Its one consumer stays the summary loop. For
  `method => "Operational"` docs the loop treats false as skip: the doc is
  not counted and is NOT stamped `"ignored"`, so it keeps its honest
  error/ok. Threshold and Alert docs keep today's stamping behaviour
  untouched.
- **`TrackStatus` (new, optional):** "should a status doc be written for
  this event at all". Producer-side gate, default true for stateful events.

Both combinations are meaningful. `TrackStatus=true, Status=false` gives an
entry that is visible with error/ok but never degrades the node.

### conf-default/Events.nmis changes

- `'Status' => 'false'` on Interface Down, Service Down, Service Degraded.
  Rationale: these do not affect node state today, and counting them would
  mark nodes degraded on upgrade. Sites that want that behaviour flip the
  flag. All other events keep `Status => 'true'`, which is a no-op change
  for node state: Node Down, SNMP Down, WMI Down already drive node state
  through `coarse_status`/`precise_status` before status_summary is
  consulted, and Backup Host Down / Node Polling Failover counting makes
  `coarse_status` agree with what `precise_status` already reports.
- `'TrackStatus' => 'false'` on Planned Outage Open. An `"error"` doc for a
  deliberate maintenance window would mislead. (Selftest Failed needs no
  entry: it is stateless, so gate 2 already excludes it.)

### Summary-loop changes (`compute_thresholds`, `lib/NMISNG.pm` ~740-775)

For docs with `method => "Operational"`:

1. The stale sweep (`lastupdate < time - 500` delete) leaves them alone.
   Their lifecycle is owned by the per-cycle write cadence and the TTL, and
   slow-polled nodes would otherwise flap.
2. `Status => 'false'` skips them without the `"ignored"` stamp (see
   Controls).

Threshold and Alert doc handling is byte-for-byte unchanged.

### Bugfix in touched code

`save_dashnode_data` (`lib/NMISNG/Node.pm`) deletes
`$self->nmisng->config->{dashnode_context}` instead of
`$self->nmisng->{dashnode_context}`, so the "clear context after save" step
has never worked. Fix the key.

### Removed

- `_populate_event_status_in_dashnode` and its two call sites (only ever
  existed on the superseded `feature/OMK-12605` branch).
- `test/test_dashnode_event_status.pl` and its `ci/scripts/perl_tests.sh`
  entry (same branch).
- GitHub PR #183 is closed in favour of this work, with a note on the
  ticket.

## Accepted limitations

Recorded deliberately, all consequences of choosing write-through over an
end-of-collect reconciliation pass:

1. **Manually injected events decay instead of flipping.** An event raised
   by hand (`nmis-cli act=notify`) that nothing reassesses writes one
   `error` doc. If an operator closes the event out-of-band, the doc stays
   `error` until the TTL (`purge_status_after`, default 24h) removes it.
   Events that NMIS itself assesses self-correct within one poll cycle.
2. **Always-present entries thin during long outages.** While a node is
   fully down, collect short-circuits, so its SNMP Down doc stops refreshing
   and TTLs out after a day. Arguably correct: SNMP state is unknown while
   the node is unreachable.
3. **Dashnode file entries outlive their docs.** The file accumulates keys
   (existing behaviour, thresholds included). Once a doc TTLs out, the file
   entry stays frozen at its last written status. For the Telmex use case
   this approximates "entries never disappear".

## Testing

New mongo-backed `test/t_operational_status.pl` in the existing test style,
wired into `ci/scripts/perl_tests.sh`. Cases:

1. `notify` for a stateful operational event creates a
   `method => "Operational"` doc with `status => "error"` and the event's
   level and details.
2. `checkEvent` flips the same doc to `status => "ok"`, level Normal, same
   `_id` (upsert identity held).
3. `checkEvent` with no prior down event still writes an ok doc (roster
   emergence on healthy nodes).
4. `notify` with threshold context and with an `Alert: ...` name writes no
   Operational doc.
5. Stateless events (per `non_stateful_events` and `Stateful => 'false'`)
   write no doc.
6. `TrackStatus => 'false'` writes no doc.
7. Summary loop: Operational doc with `Status => 'true'` counts, with
   `Status => 'false'` is skipped and keeps error/ok (no `"ignored"`
   stamp), Threshold docs still get stamped as today.
8. Stale sweep deletes an old Threshold doc but leaves an equally old
   Operational doc.
9. With `enable_dashnode_file` on, the dashnode JSON gains
   `event--element` entries in the same shape as threshold entries.
10. `save_dashnode_data` clears `nmisng->{dashnode_context}` after save.

## What this answers for Telmex

- Persistent per-event entries with a real `status: error|ok` field, in the
  same shape as the threshold entries they already parse, for all
  operational events uniformly. Their 21 July suggestion of a separate
  `event` hash is unnecessary: one consistent `status` section covers both.
- Their three technical questions: entries disappeared because NMIS9 had no
  writer connecting events to status documents (the config for it existed,
  the code did not), there is no design barrier, and the fix makes events
  behave like the thresholds they already consume.
- Per-event control (`TrackStatus`, `Status`) lets them include exactly the
  events they care about, including ones we ship disabled by default.

## Decision log

| Decision | Choice | Why |
|---|---|---|
| Relationship to `feature/OMK-12605` | Replace | Raw event dumps mismatch status shape, which caused the customer confusion |
| Mechanism | Write-through in notify/checkEvent | Calls already fire every cycle, so docs refresh like threshold docs with zero call-site changes. handle_down already unifies up/down for the five node-level events |
| End-of-collect reconciliation | Dropped | Its remaining value (out-of-band closes, file pruning) is edge-case only, see Accepted limitations |
| method value | `"Operational"` | "Event" was misleading (thresholds and alerts raise events too), and the term matches the language already used with the customer |
| Health metric impact | Honour `Status` flag, skip-don't-stamp, tuned conf-default | Zero out-of-box change, per-event knob, honest error/ok preserved |
| Write gate | New `TrackStatus` flag | `Status` must keep its single meaning for threshold/alert docs, and one flag can't express "visible but not counted" |
| Threshold/alert migration | Later, helper designed for it | Smallest blast radius for a customer-shippable change |
