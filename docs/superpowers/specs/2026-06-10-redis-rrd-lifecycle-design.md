# Redis Polling: RRD Write Path and Push-Node Lifecycle — Design

**Date**, 10 June 2026
**Branch**, feat/sdwan-polling
**Status**, design for review
**Relates to**, `docs/superpowers/specs/2026-06-05-nmis9-redis-polling-design.md` (the Redis engine) and the shared nmisent contract.

## Problem

A push (redis) node's data lands in MongoDB inventory but never in RRD. Observed end to end in the nmisent test (discovery to reconciler to redis to nmis9 collect): inventory rows appear, RRD files do not.

### Root cause (verified against the code)

The RRD write for systemHealth runs in `Node::collect_systemhealth_data`, which lives inside the collect "data block". That block is gated twice:

1. **Early divert.** `Node::collect` runs an update INSTEAD and returns when `last_update` is unknown (Node.pm:9507-9512, `if ($pingable and !last_update)`). A freshly created node has no `last_update`, so its first collect diverts to update. Update writes inventory (`collect_systemhealth_info`, Node.pm:7363) but never calls `collect_systemhealth_data`, so no RRD.
2. **Data-block gate.** Once past the divert, the data block is gated on `elsif ($updatewasok)` (Node.pm:9597), where `$updatewasok = collect_node_info(...)` (9580). `collect_node_info` returns true from `$loadsuccess = $S->loadInfo(class => 'system', ...)` (2713, 2758). For a push node that succeeds only if the model declares a system-level redis section that returns data.

Instrumented reproduction confirmed the sequence: a fresh node's first collect diverted to update (`collect_node_info` never called, only node-level `health` RRD written by the reachability path); a second collect (after `last_update` was set) ran the full data block and wrote `sdwan_uplink` RRD correctly. So when collect actually proceeds, the RRD path already works. The failure is the gating, plus a coverage blind spot.

### Coverage blind spot

`test/t_polling_redis.pl` and `test/t_polling_http.pl` both stub `NMISNG::Sys::create_update_rrd` to a silent no-op and never assert it was called. So the redis-to-RRD (and http-to-RRD) write path has no test, which is why this shipped unnoticed.

## Goal

Make a push node's collect reach the data/RRD pass reliably, by treating redis as a first-class polling source through the same `status`/`loadInfo`/source machinery that snmp, wmi, and http already use, rather than adding redis-only branches. Keep the `update` pass in the loop. Add the missing RRD-write coverage.

## Decisions (from brainstorming)

1. **Rework the push-node lifecycle**, not a one-line gate patch, so all source types share one path (fewer special cases, fewer bugs).
2. **Keep update in the loop.** Update still establishes catchall and `nodeModel`, reconciles inventory, and stamps `last_update`. Collect is fixed to proceed and write RRD.
3. **Rely on update to clear the early divert.** Leave the `!last_update` divert (9508) as is. The first collect before a successful update still diverts; the next collect proceeds. This one-cycle-plus delay on a brand-new node is accepted.
4. **Treat redis as a known source** so reachability, `updatewasok`, and per-source events are decided uniformly.
5. **A push model that lacks a system-level redis section is a model error**, surfaced through the existing `"Model File Invalid"` node event.

## Design

### 1. Add `redis` to `Sys::known_sources`

`lib/NMISNG/Sys.pm:135` currently reads `sub known_sources { return [qw(snmp wmi http)]; }`. Add `redis`. This is the codebase's sanctioned extension point. The comment at Node.pm:6660-6661 states it explicitly, "adding a future engine to Sys::known_sources makes it participate here automatically."

Effects, all through existing generic loops:
- `Sys::status` surfaces `redis_enabled` and `redis_error` (the loop at Sys.pm:281-284 sets `${source}_enabled = $self->{$source} ? 1 : 0` and `${source}_error`). The redis engine ref is stored at `$self->{redis}` in `Sys::init`, so `redis_enabled` becomes 1 when the engine is active.
- `collect_node_info`'s per-source loop (Node.pm:2728) marks the redis source up via `handle_down(up => 1)`, stamps `last_poll_redis`, and sets the reachability result, exactly as it does for http.
- The `disable_source` loop (Node.pm:9601) and the other `known_sources` consumers include redis.

Nodes without a redis engine are unaffected, `$self->{redis}` is unset, so `redis_enabled = 0` and every per-source loop skips it.

### 2. Propagate `redis_error` in `getData`

`Sys::getData` copies `wmi_error`, `snmp_error`, and `http_error` from the per-call status onto `$self` (Sys.pm:1204-1207) but not `redis_error`. Add `$self->{redis_error} = $status->{redis_error};` so a redis fetch error reaches `Sys::status` and the generic error handling the same way the other sources do.

### 3. Missing system-level redis section is a model error

`updatewasok` is true for a push node only when `loadInfo(class => 'system')` reads redis data, which requires the model to declare a redis source in the system class (`system.sys.<section>.redis`, for example `sdwan_health`). The reference `Model-CiscoMerakiSDWAN` already complies.

If a redis-enabled node's loaded model has no redis block in the system class, that is a misconfigured model for a push node. At the model-load adjudication point where `"Model File Invalid"` is already raised and cleared (Node.pm:2482-2499), add a check for this condition and raise the same event:

```perl
Compat::NMIS::notify(
    sys     => $S,
    event   => "Model File Invalid",
    details => "Model $nodeModel is push-sourced (redis) but declares no system-level redis section",
    context => {type => "node"},
    inventory_id => $catchall_inventory->{_id}{hex},
);
```

When the model is valid (a system-level redis section is present, or the node is not push-sourced), the existing `checkEvent` for `"Model File Invalid"` clears it. Operators see the same node event they already watch for other model faults, and `updatewasok` stays false for the misconfigured node until it is fixed.

The check is for a `manages_own_inventory` engine being active while `$self->{mdl}{system}{sys}` contains no subsection with a `redis` key. The exact insertion line is pinned in the implementation plan.

### 4. Reachability and events

No redis-specific event code. With redis in `known_sources`, `collect_node_info` raises and clears the redis source up/down state through `handle_down` (the same path http uses), stamps `last_poll_redis` on success, and the node's reachability reflects the redis source. Per-concept staleness events (the existing `"Redis Data Stale"` event from the engine) are unchanged.

### 5. Accepted behaviour

- The first collect on a brand-new push node, before a successful update has set `last_update`, diverts to update and writes no systemHealth RRD that cycle. The following collect writes RRD. This is the chosen trade-off, not a defect.
- A node with no redis engine is untouched by every change here.

## Testing

- **Unit, status surface.** With an active redis engine, `Sys::status` returns `redis_enabled => 1` and a `redis_error` key. A non-redis node returns `redis_enabled => 0`.
- **Regression, redis to RRD (the missing test).** A push node with a system-level redis section, after an update has set `last_update`, runs `collect` and writes `sdwan_uplink` RRD. Assert by capturing `create_update_rrd` calls (record the call and its `type`/`index`/values) rather than stubbing it to a silent no-op. Confirm the latency value from the payload reaches the writer.
- **Model error.** A redis-enabled node whose model declares no system-level redis section raises the `"Model File Invalid"` node event, and its collect does not proceed to the data block (`updatewasok` false). A model with the section present clears the event.
- **Reachability.** After a successful redis collect, catchall shows `last_poll_redis` advanced and the redis source marked up.
- **Non-perturbation.** `test/t_polling_http.pl`, `test/t_polling.pl`, and `test/t_sys.pl` pass unchanged. Adding redis to `known_sources` must not alter snmp/wmi/http-only nodes, since those have no redis engine.

## Out of scope

- Removing the `update` pass for push nodes (rejected, update stays in the loop).
- Eliminating the first-collect divert (accepted as a one-cycle delay).
- Reworking the http error handling that this design does not touch (for example the `$anyerror` check at Node.pm:5417 that omits http and redis), unless a test shows it blocks the redis RRD write.

## References

- `lib/NMISNG/Sys.pm:135` (`known_sources`), :281-284 (status loop), :1204-1207 (`getData` error copy), :755-766 (redis engine wired in `init`).
- `lib/NMISNG/Node.pm:9507-9512` (early divert), :9580/:9597 (`updatewasok` gate), :2713/:2758 (`loadInfo` success), :2728 (per-source loop), :2482-2499 (`"Model File Invalid"` raise/clear), :6660-6661 (known_sources extension comment).
- `lib/NMISNG/Sys/Engine/Redis.pm` (the engine, `manages_own_inventory => 1`).
- `models-default/Model-CiscoMerakiSDWAN.nmis` (reference push model with a system-level redis section).

## Implementation note — root cause refined (10 June 2026)

Systematic debugging during implementation refined the root cause, and one
earlier conclusion in this spec was wrong. Recorded here for honesty.

- **Corrected escalation.** An interim claim that "update can never collect the
  system section for a push node, so RRD never writes" was a false alarm from a
  flawed one-off probe. Clean instrumented probes showed that, with redis data
  present before update, the full flow works: update collects the `standard`
  section, `nodeModel` settles, `last_update` is set, and collect writes RRD.

- **The actual root cause of "inventory yes, RRD no".** `update_node_info` only
  set `nodeModel` from an explicit node-config model **inside** the `firstloadok`
  branch. A push node whose first `loadInfo` collected nothing (data not arrived
  yet) skipped that branch, so `nodeModel` fell back to `Generic`; collect then
  loaded the wrong model and wrote no RRD. The fix: honor a non-`automatic`
  config model regardless of `firstloadok`. This also made the model-error check
  correct (it now inspects the configured model, not a fallback).

- **Model-error event is symmetric.** `"Model File Invalid"` is raised when a
  push model lacks a system-level redis section and cleared when present — on
  both the `firstloadok` success path and the `!firstloadok` branch — so a
  corrected model clears the event even before its first data arrives.

- **Scope delivered.** The four spec items (redis in `known_sources`,
  `redis_error` in `getData`, the `"Model File Invalid"` model error, and the
  redis→RRD regression test) all landed, plus the explicit-model fix above which
  was the actual resolver of the reported symptom. Tests run collect without
  `force`, matching routine scheduled polling.
