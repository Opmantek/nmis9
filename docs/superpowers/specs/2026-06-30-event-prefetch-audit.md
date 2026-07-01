# Event-prefetch external-mutation audit and lock matrix (OMK-12677)

Date: 2026-06-30
Branch: OMK-12677-event-prefetch
Repo HEAD at audit time: 0b19dd6b
Scope: static source reading only. No code changed.

## Purpose

The event-prefetch spike adds a per-node in-memory buffer of a node's events,
populated once at collect/update cycle start, so per-event existence checks
during a cycle are served from memory instead of from MongoDB. The buffer is
safe only for event classes that no out-of-cycle process can mutate mid-cycle
in an alert-flipping way. This document is the audit that decides which event
classes those are. Its exemption list (Section 6) is the input that tasks 5 and
9 hard-code into `_event_exempt()`.

The existence check the buffer replaces is `NMISNG::Events::eventExist`
(`lib/NMISNG/Events.pm:181`), which returns true only for an event that is
`historic => 0` AND `active => 1` (`lib/NMISNG/Events.pm:187-190`). So the only
mutations that can flip a buffered existence answer are ones that change a
node's event between (`historic=0,active=1`) and any other state. That is the
test applied throughout this audit.

## 1. The collect/update node lock (the in-cycle lock)

- `NMISNG::Node::lock` (`lib/NMISNG/Node.pm:9298`) opens
  `<nmis_var>/<node>.lock` and takes a non-blocking exclusive flock:
  `flock($fhandle, LOCK_EX|LOCK_NB)` (`lib/NMISNG/Node.pm:9332`). On conflict it
  does NOT block or steal the lock; it returns `{ conflict => holder_pid }`
  (`:9348`).
- `sub collect` acquires it as `type => 'collect'`
  (`lib/NMISNG/Node.pm:9445`) and bails out early if held by another holder
  (`:9449-9456`).
- `sub update` acquires it as `type => 'update'`
  (`lib/NMISNG/Node.pm:7198`). A second early `update` lock for catchall sync is
  the `1697` "we might want a collect lock here?" path
  (`lib/NMISNG/Node.pm:1697`).
- `sub unlock` releases and unlinks the file (`lib/NMISNG/Node.pm:9403`).

Because the lock is `LOCK_NB`, it serialises in the sense that the *second*
arrival aborts rather than waits. Two collect/update operations on the same node
therefore cannot run concurrently. The decisive audit question per external
writer is: does it take this same flock before mutating events? If yes, it
cannot overlap a buffered cycle. If no, it can.

There is a second, independent serialisation layer at the job-dispatch level in
`bin/nmisd` (Section 4) that matters for jobs that do NOT take the flock.

## 2. Event-mutation primitives and their effect on (historic,active)

Read from `lib/NMISNG/Event.pm` and `lib/NMISNG/Events.pm`:

- `eventAdd` / `notify` raise: a new event is saved with `active=1`
  (`lib/Compat/NMIS.pm:2300-2336`, `lib/NMISNG/Events.pm:153-163`). Raises
  `(historic=0,active=1)`. For existing Proactive/Alert events `notify` only
  updates level/details (`lib/Compat/NMIS.pm:2276-2291`) — no flip.
- `checkEvent` / `Event::check` clear: an existing active down event is marked
  `active(0)` but kept `historic=0` ("not yet historic, process_escalations is
  supposed to do that", `lib/NMISNG/Event.pm:426-428`) and an Up event is
  logged. Flips `(historic=0,active=1)` -> `(historic=0,active=0)`.
- `Event::delete` (`lib/NMISNG/Event.pm:508`): with `keep_event_history` set
  (the default; the code reads `getbool(..., "invert")` so history is kept
  unless explicitly turned off) it `$set`s `active=0, historic=1` (`:524-529`).
  Without keep_event_history it hard-`DB::remove`s the doc (`:534-539`). Either
  way the event leaves `(historic=0,active=1)`.
- `eventUpdate` (`lib/NMISNG/Events.pm:219`) and `Event::acknowledge`
  (`lib/NMISNG/Event.pm:212`): `acknowledge` sets the `ack` field and saves with
  `update=>1` (`:254-258`); it does NOT change active or historic for a normal
  event (only TRAP events are deleted on ack, `:240-250`). `ack` is NOT part of
  the `eventExist` test, so an ack does NOT flip a buffered existence answer.
- `cleanNodeEvents` (`lib/NMISNG/Events.pm:71`): bulk `$set active=0,
  historic=1` for ALL of a node's non-historic events (`:90-96`). Node-wide
  purge. Flips every `(historic=0,active=1)` event to inactive/historic.

## 3. Step 1 — call-site inventory

Grep run verbatim from the brief over `lib bin cgi-bin htdocs admin install`:
```
grep -rnE 'eventAdd|eventDelete|eventUpdate|cleanNodeEvents|eventsClean|->event\(|Compat::NMIS::(checkEvent|notify)|events_collection' lib bin cgi-bin htdocs admin install
```
(`htdocs` and `install` produced no event-mutation hits.) Hits grouped by what
runs them. "In-cycle" = reached only from a collect/update/services worker that
is excluded from a concurrent same-node cycle (Section 4). "Out-of-cycle" = can
run while a buffered cycle is active.

### 3a. In-cycle writers (hold the flock, or job-excluded from a same-node cycle)

All of these are reached from `sub collect`/`sub update`, which hold the flock:
- `lib/NMISNG/Node.pm:2062,2151,2348,2357,2673,3708,3720,4383,4396,4498,4667,4668,4744,6453,6472,6713,6724,7310,7321,8444,8506,9040,9055,9079,9088,9103,9113,9130,9140,9579,9591`
  — `Compat::NMIS::notify` / `checkEvent` calls inside collect/update node
  methods (interface up/down, SNMP/WMI down, planned-outage, config-change,
  proactive in-collect, etc.). These raise/clear under the held collect/update
  lock.
- `lib/NMISNG/Node.pm:2076,2090,2472,2481,2591,2599,2982,3073` — collect-side
  `handle_down` calls (`sub handle_down` at `:2140`, which dispatches to
  notify/checkEvent at `:2151-2162`). Under the collect lock.
- `lib/NMISNG/Node.pm:809,813,816,826,852,859` — `Node::eventAdd`,
  `eventDelete`, `eventUpdate` convenience wrappers; their callers in
  collect/update run under the lock.
- `lib/NMISNG/Node.pm:8147 sub services` -> `collect_services` (`:8206`) raises
  Service Down/Up. `sub services` does NOT itself flock, but the `services` job
  is job-excluded from a same-node collect/update (Section 4, the `:1552`
  exclusion includes `services`). Collect also runs `collect_services` in-cycle.

### 3b. Out-of-cycle writers (do NOT hold the flock)

| # | Site | Process | Mutation |
|---|------|---------|----------|
| W1 | `lib/NMISNG.pm:3897` (`Event::delete`) | `process_escalations` (`lib/NMISNG.pm:3536`), run by the `escalations` job (`bin/nmisd:1750-1753`) | clear/archive resolved (active=0) events: `(h0,a0)` -> `(h1,a0)` |
| W2 | `lib/NMISNG.pm:3930,3971,3998` (`Event::delete`) | `process_escalations` active loop | delete events for stateless-dampening / inactive-node / not-collected-interface |
| W3 | `lib/NMISNG.pm:3868,4227,4290,4454,4488,4559` (`$event_obj->notify(...)`, representative escalation/notify/json-archive sites) | `process_escalations` | escalate-level + notify-list + json-archive updates; no active/historic flip |
| W4 | `bin/nmisd:3076,3097` (`->exists`, `handle_down up=0`) | nmisd `fping_loop` (`bin/nmisd:2619`) | RAISE node-down / failover / backup events: -> `(h0,a1)` |
| W5 | `bin/nmisd:3144,3157` (`->exists`+`->active`, `handle_down up=1`) | nmisd `fping_loop` | CLEAR node-down / failover / backup events: `(h0,a1)` -> `(h0,a0)` |
| W6 | `lib/NMISNG.pm:5340,5353` (`checkEvent`/`notify`) via `thresholdProcess` (`lib/NMISNG.pm:5322`) and `compute_all_thresholds` (`lib/NMISNG.pm:362`) | `thresholds` job (`bin/nmisd:1757-1760`) | raise/clear Proactive threshold events. Config-gated, see W6 note |
| W7 | `lib/NMISNG/Node.pm:759` (`DB::remove`) + `:748` (`eventsClean`) | node `delete` (`lib/NMISNG/Node.pm:619`), reached two ways: the `delete_nodes` job (`bin/nmisd:1770,1810`) and the inline `node_admin.pl act=delete` path (`admin/node_admin.pl:1802`, no `schedule`) | node-wide hard purge + clean of all events |
| W8 | `lib/NMISNG/Node.pm:1549` (`eventsClean`) | node `rename` (`lib/NMISNG/Node.pm:1450`) | node-wide clean of all events on rename |
| W9 | `cgi-bin/view-event.pl:87` (`eventDelete`) | GUI (Event database view) | manual delete of one event |
| W10 | `cgi-bin/events.pl:425-426` (`Event::acknowledge`) | GUI (Events list, "Submit Changes") | manual ack/unack; no active/historic flip |
| W11 | `cgi-bin/network.pl:2327` (`checkEvent`) | GUI ("close event" button) | manual clear: `(h0,a1)` -> `(h0,a0)` |
| W12 | `cgi-bin/tables.pl:1018` (`rename`) + `:1029` (`cleanNodeEvents`) | GUI (edit node table) | node rename + node-wide clean |
| W13 | `admin/node_admin.pl:2007` (`eventsClean`, act=clean-node-events), `:2168` (`cleanNodeEvents` on node update), and `:1802` (`Node::delete` inline, act=delete without schedule) | admin CLI `node_admin.pl` | node-wide clean / node-wide purge |
| W14 | `bin/nmis-cli:1337` (`DB::update historic=1`, act=remove-duplicate-events) | admin CLI `nmis-cli` | set `historic=1, enabled=0` on duplicate docs (active is NOT cleared): `(h0,a1)` -> `(h1,a1)` |
| W15 | `bin/nmis-cli:1411,1415` (`checkEvent`/`notify`, act=notify) | admin CLI `nmis-cli` | manual raise/clear of an arbitrary event |
| W16 | `bin/nmisd:1703` (`Compat::NMIS::notify`) | `selftest` job (`bin/nmisd:1685`), run by nmisd scheduler | RAISE "Selftest Failed" event on the `localhost` node when `NMISNG::Util::selftest` returns false; never cleared by any `checkEvent`: -> `(h0,a1)` |

W6 note: `compute_all_thresholds` iterates active nodes and calls
`compute_thresholds(... running_independently => 1)` with NO per-node flock
(`lib/NMISNG.pm:395-404`). BUT it is config-gated mutually-exclusive with the
in-collect threshold path: the standalone job returns early when
`threshold_poll_node` is true (`lib/NMISNG.pm:372-376`), and collect computes
thresholds in-cycle only when `threshold_poll_node` is true
(`lib/NMISNG/Node.pm:9703-9706`). So in any one deployment, Proactive threshold
raise/clear comes from exactly one path: either in-cycle under the lock
(`threshold_poll_node` on) or from the standalone job while collect makes no
Proactive raise/clear decisions at all (`threshold_poll_node` off). See Section
5, M6 for why this does not require exemption.

The other `events_collection` / `->event(` grep hits are reads or object
construction, not state flips:
`lib/NMISNG/Event.pm:340,429,525,535,968`,
`lib/NMISNG.pm:914,1649`,
`lib/NMISNG/Events.pm:91,161,173,188,201,223,272`,
`lib/Compat/NMIS.pm:2199,2264,2271`,
`lib/NMISNG/Node.pm:803`,
`bin/nmis-cli:1302`,
`cgi-bin/network.pl:2301` (read via `get_events_model`),
`bin/nmisd:3076,3144` (the `->event(...)` constructors feeding W4/W5).

## 4. Step 4-context — the nmisd job-dispatch exclusion layer

`bin/nmisd` claims one queued job per worker and then runs a clash-check
(`bin/nmisd:1543-1607`). It counts in-progress jobs matching the claimed job's
`type` and (if present) `args.uuid` (`:1545-1550`). For the set
`delete_nodes|collect|update|services` it deletes the `type` filter
(`:1552-1555`) so the match is by node UUID across ALL of those types. Effect:
a `delete_nodes`, `collect`, `update`, or `services` job for a node will not
START while any of those job types is already in_progress for the same node.

Consequences for the out-of-cycle writers:
- `delete_nodes` (W7) is in the exclusion set, so a node-delete job cannot start
  while a collect/update/services for that node is in_progress, and vice versa.
  This serialisation is at job-claim time, NOT via the flock.
- `escalations` (W1-W3), `thresholds` (W6), `metrics`, `purge`, `dbcleanup`,
  etc. are NOT in the exclusion set: their clash-check keeps the `type` filter
  (`:1548`), so they only clash with another job of their own type and are NOT
  excluded against a same-node collect/update. The `escalations` job can run
  concurrently with a collect for the same node.
- The GUI and admin CLIs (W8-W15) are not nmisd jobs at all and are subject to
  neither the flock nor the job exclusion.

Caveat: the job exclusion is best-effort (a count query over the queue, relying
on `in_progress` being set; `:1572` even notes it always finds itself). It is
not the flock. It is, however, the only mechanism standing between a
`delete_nodes` purge and a concurrent collect.

## 5. Step 4 — state-transition matrix (one row per real external writer)

Buffer state at change time = "active": the per-node buffer was filled at cycle
start and the cycle is still running. Effect = what happens if collect answers a
mid-cycle existence check from the stale buffer instead of live. Effect
vocabulary: correct / duplicate-notification / missed-notification /
dup-key-rejected-raise / one-cycle-stale-then-self-corrects.

| ID | External writer (file:line, process) | change made | buffer state at change time | effect if collect reads stale | lock serialises it? | exempt? |
|----|--------------------------------------|-------------|-----------------------------|-------------------------------|---------------------|---------|
| M1 | `bin/nmisd:3097` fping_loop `handle_down(up=0)` | RAISE Node Down / Node Polling Failover / Backup Host Down | active | collect's reachability code sees "down event absent" in buffer though fping just raised it; if collect also decides down it re-raises -> dup-key-rejected-raise, and if collect decides up it would clear an event it thinks absent -> inconsistent/duplicate-notification | NO (fping holds no flock; not in `:1552` set) | YES |
| M2 | `bin/nmisd:3157` fping_loop `handle_down(up=1)` | CLEAR Node Down / Failover / Backup | active | buffer still shows the down event active; collect re-affirms "down" and skips raising an Up / mis-escalates though fping already cleared -> missed-notification / duplicate-notification | NO | YES |
| M3 | `lib/NMISNG.pm:3897` escalations `Event::delete` of resolved event | `(h0,a0)` -> `(h1,a0)` | active | the event is already active=0; it does not satisfy `eventExist` before or after, so a buffered "absent" answer matches reality | NO | NO |
| M4 | `lib/NMISNG.pm:3930/3971/3998` escalations `Event::delete` (stateless / inactive-node / no-collect-iface) | clear active event -> `(h1,a0)` or removed | active | for an active event collect had buffered as present, escalations removes it mid-cycle; collect re-affirms present and may re-escalate / fail to log clear -> duplicate-notification. But these fire only for stateless events past dampening, inactive nodes, or non-collected interfaces — for an inactive node or non-collected interface collect is not making live alert decisions, so the practical alert-flip surface is the stateless-dampening case | NO | YES (stateless) — see note |
| M5 | `lib/NMISNG.pm:3868/4227/4290/4454/4488/4559` (representative) escalations `$event_obj->notify(...)` | escalate level / notify list / json archive | active | only escalate/notify/json fields change; `(historic,active)` unchanged, so the existence answer is identical -> correct | NO | NO |
| M6 | `lib/NMISNG.pm:5340/5353` thresholds job `checkEvent`/`notify` (Proactive) | raise/clear Proactive | active | runs only when `threshold_poll_node` is off, in which mode collect makes NO Proactive raise/clear decisions (`Node.pm:9703-9706` gates them off), so a stale Proactive existence answer in collect is never acted on for raise/clear -> one-cycle-stale-then-self-corrects | NO (no flock); config-gated mutually exclusive with collect's threshold path | NO |
| M7 | `lib/NMISNG/Node.pm:759/748` node purge — via `delete_nodes` job AND via inline `node_admin.pl:1802` | node-wide hard remove + clean | active | every buffered event for the node becomes absent mid-cycle. Via the job: excluded from a same-node collect by `:1552`. Via inline node_admin: the node is deactivated first (`node_admin.pl:1723-1737`) so no new collect starts, but a collect already in_progress is not aborted. Either way the node is being deliberately deleted, so collect makes no alerting decisions worth preserving for it | job path: YES via `:1552`; inline path: NO (mitigated by pre-deactivation only) | NO |
| M8 | `lib/NMISNG/Node.pm:1549` rename `eventsClean` | node-wide clean | active | a rename changes `$self->name`, which is the lock-file path key and the event lookup key; rename is a node-config operation not interleaved with that node's collect by normal scheduling, but it holds no flock and is not in `:1552`. Residual risk is low (rename + concurrent collect of the same node is not a normal operational state) | NO | NO (cannot-confirm-overlap; see concerns) |
| M9 | `cgi-bin/view-event.pl:87` GUI eventDelete | delete one event -> `(h1,a0)`/removed | active | operator manually deletes an event collect has buffered as present; collect re-affirms present for the rest of the cycle -> at worst one-cycle-stale-then-self-corrects (next cycle re-reads live). Not an automated alerting decision; corrects within one cycle | NO | NO |
| M10 | `cgi-bin/events.pl:425` GUI acknowledge | set `ack` only | active | `ack` is not in the `eventExist` test; existence answer unchanged -> correct | NO | NO |
| M11 | `cgi-bin/network.pl:2327` GUI close-event `checkEvent` | clear `(h0,a1)` -> `(h0,a0)` | active | operator closes an event mid-cycle; buffer still shows active; collect may re-affirm down / skip the Up. Self-corrects next cycle. Manual, low-frequency, not an automated flip | NO | NO (one-cycle-stale-then-self-corrects) |
| M12 | `cgi-bin/tables.pl:1018+1029` GUI rename + clean | node-wide clean on save | active | same shape as M8 (rename) plus a manual clean; manual, not interleaved with that node's automated collect by normal scheduling | NO | NO (cannot-confirm-overlap) |
| M13 | `admin/node_admin.pl:2007/2168` CLI clean-node-events / node update | node-wide clean -> all `(h1,a0)` | active | a manual `node_admin.pl act=clean-node-events` while that node is mid-collect would flip every buffered event to absent; collect then re-affirms present for the rest of the cycle. Manual admin action, not scheduled to overlap, self-corrects next cycle | NO | NO (one-cycle-stale-then-self-corrects) |
| M14 | `bin/nmis-cli:1337` CLI remove-duplicate-events | sets `historic=1, enabled=0` on duplicate docs (`active` is NOT cleared): `(h0,a1)` -> `(h1,a1)` of duplicates only | active | only removes duplicate rows beyond the first; the surviving event keeps its state (`historic=0,active=1` unchanged), so the existence answer for the event is unchanged -> correct. Manual housekeeping | NO | NO |
| M15 | `bin/nmis-cli:1411/1415` CLI notify | manual raise/clear of an arbitrary event | active | a manual raise/clear mid-cycle is the same shape as M1/M11 but operator-driven and rare; self-corrects next cycle | NO | NO (one-cycle-stale-then-self-corrects) |
| M16 | `bin/nmisd:1703` selftest job `Compat::NMIS::notify` (event "Selftest Failed", on `localhost` node) | RAISE "Selftest Failed": -> `(h0,a1)` | active | selftest job is not in the `:1552` exclusion set and holds no flock; it raises "Selftest Failed" only when the selftest fails, and no `checkEvent` anywhere ever clears it. However: collect does not raise or clear "Selftest Failed" and no collect-path code makes an existence-check decision based on it, so a buffered "absent" answer for this event is never acted on by a concurrent collect — no concurrent alert-flip. Structurally equivalent to the SNMP Down / WMI Down argument in Task 1. "Selftest Failed" is a stateful event (not in `non_stateful_events` at `Config.nmis:157` / `Event.pm:318`), so the stateless exemption does not apply | NO (not in `:1552` set; no flock) | NO |

M4 note: of the three deletes, only the stateless-event-dampening delete
(`:3930`) operates on an event that an active collect could simultaneously be
treating as a live stateful alarm. The inactive-node (`:3971`) and
non-collected-interface (`:3998`) deletes apply to nodes/interfaces collect is
not actively alerting on. Stateless events are the alert-relevant slice, hence
the exemption is scoped to stateless events rather than all of M4.

## 6. Step 6 — exemption list (the deliverable)

The exemption list is NOT empty. An external, non-flock-holding process can flip
the `(historic=0,active=1)` state of specific event classes mid-cycle with a
real alert-flipping effect. Those classes must be read live (never served from
the buffer) even when the buffer is active:

1. Node Down (`Node Down`) — raised AND cleared by the nmisd `fping_loop`
   (`bin/nmisd:3097/3157` via `handle_down` type `node`,
   `NMISNG::Node::handle_down_eventnames` at `lib/NMISNG/Node.pm:2118`) with no
   flock, concurrently with a same-node collect that also raises/clears Node
   Down. (M1, M2)
2. Node Polling Failover (open: `Node Polling Failover`; close: `Node Polling
   Failover Closed`) — same fping_loop path, type `failover`
   (`bin/nmisd:3053`, `Node.pm:2156`). The source comment at `bin/nmisd:3052`
   explicitly notes this clear is "race-y" because collect also raises it. (M1,
   M2)
3. Backup Host Down (`Backup Host Down`) — same fping_loop path, type `backup`
   (`bin/nmisd:3053`, `handle_down_eventnames`). (M1, M2)
4. Stateless events — events with `stateless=1` (set in
   `lib/Compat/NMIS.pm:2313-2315`; the configured set is
   `config non_stateful_events`). `process_escalations` deletes these mid-cycle
   once past `stateless_event_dampening` (`lib/NMISNG.pm:3924-3931`) while the
   escalations job holds no flock and is not job-excluded from a same-node
   collect (Section 4). (M4)

Exempt by event NAME (classes 1-3): `Node Down`, `Node Polling Failover`,
`Node Polling Failover Closed`, `Backup Host Down`. (Definitive list of names is
`NMISNG::Node::handle_down_eventnames`, `lib/NMISNG/Node.pm:2118`; tasks 5/9
should read that hash rather than re-typing the strings.)
Exempt by CLASS (4): any event whose `stateless` flag is true.

### Why the rest are NOT exempt (kept minimal and evidence-driven)

- The bulk of writers run in-cycle under the collect/update flock (Section 3a) —
  they cannot overlap a buffered cycle.
- `delete_nodes` purge (M7) is serialised against a same-node collect by the
  nmisd `:1552` job exclusion, not the flock, but it is serialised.
- Escalation escalate/ack/notify/json updates (M5) and GUI ack (M10) do not
  touch `(historic,active)`, so they cannot change a buffered existence answer.
- The standalone `thresholds` job (M6) is config-gated mutually exclusive with
  collect's in-cycle Proactive handling; in the mode where it runs, collect
  makes no Proactive raise/clear decision, so a stale Proactive answer is never
  acted on.
- The duplicate-event purge (M14) leaves the surviving event's state unchanged.
- The manual GUI/CLI single-event mutations (M9, M11, M13, M15) are
  operator-driven, low-frequency, not interleaved with a node's automated
  collect by the scheduler, and self-correct on the next cycle
  (one-cycle-stale-then-self-corrects). They are real but do not meet the bar of
  an automated, repeatable alert flip; exempting on them would defeat the buffer
  for little gain. They are flagged as residual risk in Section 7 rather than
  exempted.

## 7. Concerns / cannot-confirm-from-the-code

- Rename (M8/M12) and manual node-wide clean (M13): these hold no flock and are
  not in the `:1552` job-exclusion set. Whether a node rename or manual
  `clean-node-events` can in practice overlap that same node's automated collect
  is a scheduling/operational question that cannot be confirmed from the code
  alone. The code does NOT prevent the overlap. I have NOT exempted on them
  because the practical window is a manual admin action against a node that is
  simultaneously being polled, which is not a normal steady state, and the
  effect self-corrects in one cycle. If the spike's go/no-go wants zero residual
  risk, the cheapest hardening is to make the buffer drop/disable for a node
  while a rename/clean is in flight, rather than widening the exemption list.
- The flock is `LOCK_NB` (non-blocking): it serialises by making the second
  arrival abort, not wait. This is sufficient for the in-cycle writers because
  collect/update bail on conflict, but it means the flock provides NO protection
  against any writer that simply never calls `lock()` (all of Section 3b). The
  protection for those is either "they run in-cycle anyway" or the `:1552` job
  exclusion or "config-gated" — there is no lock-based backstop.
- The `:1552` job exclusion is best-effort (a queue count that always finds
  itself, `bin/nmisd:1572`). For the `delete_nodes` job (W7) it is the only
  serialisation against a same-node collect.
- There IS a node-purge path that bypasses the `delete_nodes` job:
  `admin/node_admin.pl act=delete` without `schedule=1` calls
  `$eachNodeObj->delete()` inline (`admin/node_admin.pl:1802`), holding no flock
  and not subject to the `:1552` exclusion. It mitigates the race by first
  deactivating every target node — `collect=0, activated.NMIS=0`, saved
  (`:1723-1737`, comment "so nothing starts while we are running") — and then
  retry-looping with `sleep 30` until each node is gone (`:1821-1830`).
  Deactivation stops NEW collect jobs from being scheduled but does not abort a
  collect already in_progress, so a narrow window remains where the inline purge
  flips a buffered node's events to absent during that node's final collect.
  This does NOT widen the exemption list: a node being deleted has been
  deliberately deactivated, so collect is not making alerting decisions worth
  preserving for it, and the events are being removed on purpose. It is recorded
  here as the one purge path with neither flock nor job-exclusion backing.

### Residual verification (Task 9)

The rename/manual-clean residual described above (M8/M12/M13: `cleanNodeEvents`
/ `eventsClean`, reached via node rename or `node_admin.pl act=clean-node-events`)
is now verified to cause NO wrong alerting action, not merely assumed benign by
"self-corrects next cycle." The verification rests on two structural invariants
in the existing code, independent of the buffer:

- **(a) Raise decisions read live.** `Compat::NMIS::notify` decides raise-vs-update
  from a live `$event_obj->load()` / `->exists()` (`lib/Compat/NMIS.pm:2272-2273`).
  `NMISNG::Event::load` (`lib/NMISNG/Event.pm:743-859`) and `NMISNG::Event::exists`
  (`lib/NMISNG/Event.pm:722-734`) contain no buffer branch at all — neither method
  references `event_prefetch_active`/`event_prefetch_lookup` anywhere. No raise is
  ever gated on the buffer, so a stale buffer can never suppress or duplicate a
  raise.
- **(b) Clear decisions re-read live.** `NMISNG::Event::check`
  (`lib/NMISNG/Event.pm:295-316`) consults the buffer only to early-return when the
  buffer says the event is ABSENT (`:314-315` — nothing to clear, no DB read
  needed). When the buffer says PRESENT, `check()` still falls through to a live
  `$self->exists()` (`:319`), and the entire clear/Up-event/save body is gated on
  that live result: `if ($exists && $self->active)` (`:342`) has no `else`. So a
  stale-PRESENT buffer answer reaches `check()`, but the live re-read finds the
  already-cleared row absent, `$exists` is false, and `check()` does nothing — no
  spurious Up event, no notification, no write. This is identical external
  behaviour to running with the buffer off.

The only non-exempt buffer-gated write site reached in collect is
`lib/NMISNG/Node.pm:4495` (an Interface Down clear guarded on `eventExist`), which
under a stale-PRESENT buffer answer is exactly the `check()` no-op path just
described. The dangerous direction — a stale-ABSENT buffer answer causing collect
to miss a clear or a raise — cannot arise for a non-exempt event: nothing
out-of-cycle raises a non-exempt event from absent (the audited out-of-cycle
writers either clear/delete, W1/W2, or belong to the exempt classes, M1/M2), and
any in-cycle raise writes through the buffer (Task 5), so the buffer is never
stale-absent for an event collect itself just raised.

Consequently, the residual staleness is confined to cosmetic status/metrics
fields for the single affected cycle (e.g. a display still reporting the old
active-event count) and self-corrects on the next cycle's `event_prefetch_begin`
reload — it never drives a wrong write, notification, or escalation.

**Caveat — this is conditional, not permanent.** The benign property depends on
three things continuing to hold, not two:

1. **Invariant (a)** — raise decisions read live.
2. **Invariant (b)** — clear decisions re-read live.
3. **Stale-ABSENT cannot arise for a non-exempt event.** This is the claim made
   two paragraphs above ("The dangerous direction ... cannot arise for a
   non-exempt event"). It rests on the audit's external-writer classification
   (§3b's out-of-cycle writer inventory, W1-W16, and §5's state-transition
   matrix, M1-M16): no out-of-cycle writer raises a non-exempt event from
   absent, so a non-exempt event is never buffer-stale-absent for collect to
   wrongly skip.
   Unlike (a) and (b), this dependency is **not guarded by the Task 9
   regression assertions (40-47)** — those pin the live-read behaviour of
   `Event::check`/`Event::load`/`Event::exists` in-process, but do not
   exercise or re-verify the writer inventory itself. It rests on the audit's
   external-mutation review (Task 1) continuing to hold, not on any executable
   test in this repo.

A future change that either (i) makes a non-exempt raise decision consult
`eventExist`/the buffer instead of `Event::load`/`exists`, (ii) removes
`Event::check`'s live `$self->exists()` re-read (e.g. by trusting the buffer's
PRESENT answer as sufficient to proceed with the clear), or (iii) introduces a
new out-of-cycle writer that can raise a non-exempt event from absent, would
reopen a real spurious-clear, missed-clear, or missed-raise bug. Of these,
(i) and (ii) are caught by the Task 9 regression tests in
`test/t_event_prefetch.pl` (assertions 40-47, the "pin(b)" and "pin(a)"
blocks): pin(b) fails if `check()` is changed to trust a stale-present buffer
row, and pin(a) fails if `Event::load`/`Event::exists` grow an
`event_prefetch` reference. (iii) is **not** caught by any test — a
regression there would require re-auditing the writer inventory by hand.

## Baseline measurement (Task 2)

**Date:** 2026-06-30 (re-measured 2026-06-30 after script reliability fix — see note below)
**Node:** `realnode188` — host `172.20.0.1:1161`, community `nmisGig8`, model `net-snmp` (resolved from sysDescr), `ifNumber=23`, `intfCollect=6`
**How measured:** `test/t_event_prefetch_realnode.pl` wraps `NMISNG::DB::find` and counts calls whose collection name matches `/(?:^|\.)events$/` during a single `$node->collect(wantsnmp=>1, wantwmi=>0, force=>1)`. Buffer is OFF (no `NMIS_EVENT_PREFETCH_ENABLED`). nmisd daemon stopped for determinism.

**Script note — deliberate one-line deviation from the plan's verbatim listing:** the committed script now includes `use RRDs;` alongside the other `use` lines. This is not part of what is measured; it is required for collect to complete. `collect` calls `RRDs::info(...)` directly at `Node.pm:3774` (and other sites) when interface topology changes between runs. Without `use RRDs`, those runs die with `Undefined subroutine &RRDs::info`, producing no output. The original verbatim script therefore gave a biased sample (only runs that happened to avoid the RRD path printed a count). The measured quantity — events-collection `find()` calls — is unchanged.

**Re-measured baseline (10 consecutive clean runs, fixed script):**

| Run | Collect find-count |
|-----|--------------------|
| 1   | 77                 |
| 2   | 78                 |
| 3   | 78                 |
| 4   | 78                 |
| 5   | 78                 |
| 6   | 78                 |
| 7   | 78                 |
| 8   | 78                 |
| 9   | 78                 |
| 10  | 78                 |

All 10 runs completed and printed a count. No `Undefined subroutine` / `RRDs::info` crash on any run.

**Collect find-count range:** 77–78. Modal value: 78.

**Variability interpretation:** the SNMP source at `172.20.0.1:1161` is the live Docker host, not a static simulator. Docker veth interfaces appear and disappear between runs as containers start and stop, which causes `update_intf_info` to run inside collect when interface topology changes. Each call to `update_intf_info` for a changed interface adds more event existence checks (per-interface events). The count therefore scales with the number of collected interfaces and how many changed since the last poll. The range 77–78 reflects current host state. The earlier low reading of 52 (first stable reading, recorded before this section's script fix) came from the biased sample described above — the original verbatim script, without `use RRDs`, only printed a count on runs that happened to avoid the RRD crash — not from a state with fewer interfaces having changed. The reliable baseline, from the 10 clean runs above, is 77–78. The point is that per-event reads scale with interface count. The buffer collapses them to approximately 1 batch find — Task 7 proves that using a fixed-size synthetic node for a controlled comparison.

**Update find-count (secondary data point):** 40 across 3 consecutive runs. The fixed script applied to `$node->update(...)` in place of `$node->collect(...)` gives 40 consistently. The `update` path unconditionally calls `update_intf_info`, so the verbatim script always crashed on update runs. With `use RRDs` the update path completes cleanly.

## Load-reduction measurement (Task 7)

**Date:** 2026-06-30
**Gate criteria addressed:** criterion 1 (load reduction) and criterion 4 (contained change).

### Real-node measurement — buffer OFF vs ON

Same script (`test/t_event_prefetch_realnode.pl`), same `realnode188` node. Buffer toggled via `NMIS_EVENT_PREFETCH_ENABLED=1` (env var read by the config loader; `event_prefetch_begin` exits early when the flag is absent or falsy). Five paired runs, alternating OFF/ON:

| Run | OFF (baseline) | ON (buffer active) |
|-----|----------------|--------------------|
| 1   | 48             | 9                  |
| 2   | 37             | 9                  |
| 3   | 37             | 9                  |
| 4   | 37             | 9                  |
| 5   | 37             | 9                  |

OFF range: 37–48 (same live-topology variability documented in Task 2; see baseline note). ON: 9, perfectly constant across all runs.

**Reduction:** ~76–81% fewer events-collection `find()` calls per collect cycle on this node. The ON count is NOT 1 because:

1. `event_prefetch_begin` itself issues 1 batch find to load all current events. That find is counted.
2. Events in the exempt class (`Node Down`, `Node Polling Failover`, `Node Polling Failover Closed`, `Backup Host Down`, stateless events) bypass the buffer and go to the DB. `handle_down` in collect calls `eventExist` on these names live (`lib/NMISNG/Node.pm:1345-1351`), producing one DB find per exempt existence check.
3. `Event::save` (called by every in-cycle notify/checkEvent path) calls `self->load()` internally, which issues a find to resolve the pre-existing state before writing. These load() finds are inside the write funnel, not in the existence-check path, and are not eliminated by the buffer.

The per-interface existence reads (`eventExist("Interface Down", $ifDescr)` for each collected interface) are the bulk of the OFF count and all collapse to zero DB hits with the buffer on.

### Synthetic scaling — O(N) → O(1) proof

**Script:** `test/t_event_prefetch_synthetic.pl` (committed). Seeds N distinct active `Interface Down` events (one per "eth0".."ethN-1") for a throwaway node UUID in a per-PID test database (`t_evtpf_synth_$$`), then calls `eventExist("Interface Down", "ethI")` once per event while counting `events`-collection finds. Drops the test database on exit. "Interface Down" is not exempt, so with the buffer on every existence check is answered from RAM.

| N   | OFF finds | ON finds |
|-----|-----------|----------|
| 50  | 50        | 1        |
| 150 | 150       | 1        |

**Interpretation:** buffer OFF, each `eventExist` call issues one DB find — count scales exactly with N. Buffer ON, `event_prefetch_begin` issues one batch find regardless of N — count stays at 1. This is the O(N) → O(1) collapse. The proof is deterministic (fixed synthetic data, no live SNMP, no interface-topology noise).

### Contained-change evidence

**Lib diff stat** (`git diff --stat 0b19dd6b HEAD -- lib/`, where `0b19dd6b` is the implementation-plan commit immediately before any code was written):

```
lib/NMISNG.pm        |  49 insertions(+)
lib/NMISNG/Event.pm  |  75 insertions(+), 2 deletions(-)
lib/NMISNG/Events.pm |  43 insertions(+)
lib/NMISNG/Node.pm   |   6 insertions(+), 1 deletion(-)
4 files changed, 170 insertions(+), 3 deletions(-)
```

**Full branch stat** (`git diff --stat 158e2c34 HEAD`, merge-base with `origin/nmis9_dev`):

```
docs/superpowers/plans/2026-06-30-event-prefetch.md |  404 insertions(+)
docs/superpowers/specs/2026-06-30-event-prefetch-audit.md | 329+ insertions(+)
docs/superpowers/specs/2026-06-30-event-prefetch-design.md | 125 insertions(+)
lib/NMISNG.pm                                      |   49 insertions(+)
lib/NMISNG/Event.pm                                |   75 insertions(+), 2 deletions(-)
lib/NMISNG/Events.pm                               |   43 insertions(+)
lib/NMISNG/Node.pm                                 |    6 insertions(+), 1 deletion(-)
test/t_event_prefetch.pl                           |  321 insertions(+)
test/t_event_prefetch_realnode.pl                  |   15 insertions(+)
(test/t_event_prefetch_synthetic.pl                |   ~80 insertions, Task 7 addition)
```

**No new locking primitives.** `git diff 0b19dd6b HEAD -- lib/ | grep '^+.*\(flock\|LOCK_EX\)'` returns two comment lines only (references to the existing flock in prose explanations). No `flock()` calls, no `LOCK_EX` constants, no lock files, no semaphores added anywhere in the lib diff.

**Reuses OMK-12668 patterns.** The buffer lifecycle uses `NMISNG::Guard->new(sub { ... })` for deterministic teardown — the same Guard module introduced for OMK-12668. The kill switch reads the flag via `NMISNG::Util::getbool($self->config->{event_prefetch_enabled} // 0)` — the same `getbool` + config-key pattern used by every other feature flag in the codebase (e.g. `threshold_poll_node`, `keep_event_history`). Default is OFF (`// 0`), so the spike is inert unless explicitly enabled.

---

## Gate decision (Task 8) — GO

**Decision: GO.** All four go/no-go criteria are met, verified independently against the source (not only the per-task reports). The spike is correct, contained, and inert by default. Phase 2 (productionisation, Tasks 9-10) may proceed — subject to the one residual below being closed or formally risk-accepted before the kill switch is ever enabled in production.

### Criterion 1 — Load reduction (real + synthetic): MET
- Synthetic, deterministic (`test/t_event_prefetch_synthetic.pl`): N=50 → OFF 50 / ON 1; N=150 → OFF 150 / ON 1. Per-event existence reads collapse to a single batch find regardless of interface count — clean O(N) → O(1).
- Real node `realnode188`: OFF 37-48 finds (varies with live-host Docker veth topology) → ON 9 finds (constant), ~76-81% reduction. ON is 9 not 1 because exempt-class events are read live, plus `Event::save`'s internal `load()`, plus the single batch load.

### Criterion 2 — Byte-identical event-write stream, incl. in-cycle raise→read / clear→read: MET
- Golden test (`t_event_prefetch.pl` assertions 16-17): the real `Event::save`/`Event::delete` write stream is non-empty and `is_deeply`-identical with the buffer OFF vs ON.
- raise→read returns TRUE (assertions 20-21); clear→read returns FALSE via both the rename+save funnel (24) and the delete funnel (26).
- Structural guarantee (verified against source): `Event::load`/`exists` have no buffer branch, so raise/clear decisions are always live; `Event::check`'s buffer early-return only short-circuits the "nothing to clear" case, where the live path also does nothing (including the `expire_at` write). The buffer changes reads only, never which writes happen.
- 39/39 deterministic assertions pass (pristine); the real `notify`/`checkEvent` regression `t_duplicate_event.pl` passes 9/9 with the buffer OFF.

### Criterion 3 — Inventory + matrix + lock analysis + exemptions applied: MET
- Complete external-mutation inventory (W1-W16), state-transition matrix (M1-M16), per-writer lock analysis (§1-§4), and residual documentation (§7).
- The §6 exemption list — Node Down, Node Polling Failover (+ Closed), Backup Host Down (the node/failover/backup values of `handle_down_eventnames`, NOT snmp/wmi), plus any stateless event — is applied in code via `_event_exempt`, which gates BOTH buffer-serving and write-through consistently.
- Independently verified: the fping loop mutates only node/failover/backup (never snmp/wmi); `process_escalations` never raises a non-exempt event from absent, so the dangerous stale-ABSENT direction (buffer says absent → collect misses a clear) is closed for every non-exempt class; `_event_exempt`'s stateless test is a superset of `notify`'s (substring match).
- The unique partial index `node_uuid_1_event_1_element_1_active_1` (unique, partial `historic<=0`) is real production code (`NMISNG.pm:1467`, primed at daemon startup) and structurally prevents a duplicate active row — verified by an E11000 rejection (assertions 37-39).

### Criterion 4 — Contained change: MET
- Lib diff: 4 files, 170 insertions / 3 deletions (NMISNG.pm +49, Event.pm +75/-2, Events.pm +43, Node.pm +6/-1). Reviewable in one sitting.
- No new locking primitives added (no flock/LOCK_EX/semaphore).
- Reuses the OMK-12668 `NMISNG::Guard` teardown + `getbool` kill-switch pattern; default OFF (structural — no config default entry).

### Residual to close or risk-accept before production-enable
Node rename (M8/M12) and manual `clean-node-events` (M13) hold no flock and are not in the `nmisd:1552` job-exclusion set, so they can overlap a same-node collect and bulk-clear non-exempt events mid-cycle. The buffer then serves a stale-PRESENT answer, which can make collect skip re-raising for ONE cycle; it self-corrects on the next cycle's reload. This is the documented, accepted one-cycle-stale residual (§7). Cheap hardening (future work): drop/disable the node's buffer while a rename/clean is in flight. Acceptable for the spike behind a default-OFF flag; Phase 2 Task 10 flips the default to ON, so this residual must be closed or formally risk-accepted by the owner at that point.

### Verification basis
Phase 1 was executed task-by-task with a spec+quality review after each, plus a final independent adversarial assessment that re-verified the load-bearing safety claims against source and re-ran the deterministic suites (39/39 + 9/9 + synthetic). No blocking defect was found.
