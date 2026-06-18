# Redis/SD-WAN Node Reachability — Design Spec

Date: 2026-06-18
Status: design (approved in brainstorming; pending spec review)
Scope: sub-project 1 of the broader "redis health into NMIS status" effort.

## Goal

Give cloud-managed redis push nodes (Meraki SD-WAN, HPE GreenLake, Aruba Instant AP) a trustworthy `nodestatus` of reachable or unreachable, driven by the device status nmisent delivers over Redis, gated by nmisent producer liveness so a producer outage cannot flap the whole fleet. Reuse the existing NMIS `Node Down` / `coarse_status` path rather than inventing a new status concept.

This sub-project deliberately delivers reachable/unreachable only. Degraded, per-device staleness driving down, physical-port availability, and the HTTP `coarse_status` generalisation are separate later cycles (see Out of Scope).

## Background

These nodes run with `ping=0`, so `pingable` forces `pingresult=100` and never raises `Node Down`. Today nothing else drives their status, so they always read reachable. NMIS computes `nodestatus` in code (`coarse_status`, `Node.pm`), not from models, normally from ICMP and SNMP/WMI, none of which apply to cloud-managed nodes.

Verified nmisent data reality (from the 2026-06-18 nmisent data-mapping research):
- Each node type carries a node-level `status` field: Meraki `sdwan_health.status`, GreenLake `device_health.status`, Aruba `wifi_ap_health.status`. The values are raw vendor enums in three vocabularies.
- nmisent publishes a Prometheus endpoint on `:9464` with `nmisent_poll_last_success_epoch{engine}` (present) and `nmisent_poll_interval_seconds{engine}` (to be added). There is no Redis heartbeat key.
- Redis keys carry `_meta.collected_at_epoch` and a TTL of `max(600s, 2x poll_interval)`.

## Decisions and rationale

- **Status normalisation lives on the NMIS side**, as a per-engine raw-to-canonical map. The raw vendor string stays stored in inventory for display; NMIS derives a canonical value for the status logic. Rationale: NMIS keeps all the original information and decides locally, rather than being handed a value that hides a state it has never seen.
- **Canonical set is `up` / `down` / `degraded` / `unknown`. No new values for now.** Meraki `alerting` and `dormant` map to `degraded`.
- **`unknown` never asserts reachable.** Any unrecognised vendor value, and any indeterminate producer state, holds the node. A novel vendor state can never masquerade as healthy.
- **Reachability rides the existing `Node Down` path.** Canonical `down` calls `handle_down(type => 'node')`, `up` clears it, and `coarse_status` already turns `Node Down` into reachable/unreachable. No change to `coarse_status` for redis.
- **Producer liveness is modelled as an HTTP node, not a Service.** The nmisent `:9464` endpoint is polled by the existing HTTP engine via a `Common-nmisent.nmis` model, indexed by `{engine}`. The producer-down event is a threshold on that node. This reuses HTTP modelling, thresholds, graphs, and events, and makes the producer observable.
- **The per-device suppression gate reads the producer node's inventory directly** at device-collect time and computes the producer age live. No second store, no timing race.
- **Degraded status is deferred** to the thresholds sub-project. v1 handles only `up` and `down`. A degraded-class status holds (shows reachable) until that work lands.

## Architecture and components

Four independently testable units.

### A. Status normalisation map (new, standalone)

A pure function `canonical_status(engine, raw_status)` returning `up` / `down` / `degraded` / `unknown`. Per-engine table, case-insensitive match, `unknown` for anything unrecognised. No NMIS state and no I/O.

Note on engine keying: Aruba Instant APs use the `hpe_greenlake` engine but a different status vocabulary than GreenLake switches. The `hpe_greenlake` map is therefore the union of both vocabularies. The canonical values do not collide, so a single per-engine union map is unambiguous.

Status map:

| engine | raw value (case-insensitive) | canonical |
|---|---|---|
| meraki | online | up |
| meraki | offline | down |
| meraki | alerting | degraded |
| meraki | dormant | degraded |
| hpe_greenlake | ONLINE | up |
| hpe_greenlake | UP | up |
| hpe_greenlake | OFFLINE | down |
| any | anything not listed above | unknown |

### B. nmisent producer model (new: `Common-nmisent.nmis` plus a provisioned HTTP node)

An HTTP model that polls `:9464`, with a concept indexed by the `{engine}` label. Per engine it collects `nmisent_poll_last_success_epoch`, `nmisent_poll_interval_seconds`, and `nmisent_poll_partial_total` into inventory and RRD. A threshold or alert on poll age (`now - last_success_epoch > 2x interval`) raises and clears the one central producer event per engine, on this node. The nmisent instance is provisioned as a single HTTP node using this model.

### C. Producer-freshness lookup (new, small helper)

`producer_state(engine)` returns exactly one of:
- `up` — producer node found, row for the engine found, `age <= 2x interval`.
- `stale` — found, but `age > 2x interval`.
- `unknown` — indeterminate: the config pointer is unset, the producer node is not found, there is no inventory row for the engine, or `last_success_epoch` or `interval` is missing.

`age` is computed at call time from the stored `last_success_epoch`. The producer node is identified by a global config pointer (one nmisent per deployment). The `unknown` path emits a deduplicated misconfiguration signal (a logged warning always, plus a single config event), kept distinct from the `stale` operational alarm because the remediation differs: `stale` means fix nmisent, `unknown` means the producer node or its config pointer is not set up.

### D. Gated reachability step (change, in the redis device collect path)

After the device's node-level health concept payload is loaded:
1. Derive canonical status via A from the raw `status` field, if a payload is present.
2. Call `producer_state(engine)` via C.
3. The gate is open only when `producer_state == up` and the device payload is fresh (reusing the engine's existing freshness check).
4. Apply per the truth table below. `coarse_status` converts `Node Down` presence into `nodestatus`; no change there.

The node-level health concept is the scalar health concept declared in the model's `system.sys` block (Meraki `sdwan_health`, GreenLake `device_health`, Aruba `wifi_ap_health`). Per-uplink and per-radio `status` are sub-component signals, not node reachability, and are out of scope.

## Data flow

Producer poll (the nmisent HTTP node, on its own cadence):
1. NMIS collects the nmisent node via the HTTP engine.
2. Label discovery on `{engine}` yields one inventory row per engine.
3. Per engine it stores `last_success_epoch`, `interval`, `partial_total`.
4. The age threshold raises or clears the central producer event per engine on this node.

Redis device collect (the gated reachability step):
1. Load the device's node-level health concept payload through the redis engine.
2. The engine's existing freshness check classifies the payload fresh or stale.
3. If present, derive canonical status via A.
4. `producer_state(engine)` via C.
5. Gate and act per the truth table.
6. `coarse_status` reports reachable/unreachable from `Node Down`.

Timing notes:
- The device computes `age` live from the stored `last_success_epoch`, so it detects a stalled producer before the producer node's own threshold fires, and it is robust to the two cadences differing.
- If NMIS stops polling the producer node itself, `last_success_epoch` freezes, `age` grows, devices see `stale` and hold. That is the correct fail-safe.
- `ping=0` means `pingable` never raises `Node Down`, so the status path is the only writer of `Node Down` for these nodes. No conflict.

## Gate truth table

| producer_state | device payload | canonical status | action |
|---|---|---|---|
| up | fresh | down | raise Node Down (nodestatus unreachable) |
| up | fresh | up | clear Node Down (nodestatus reachable) |
| up | fresh | degraded | hold, no change (deferred to thresholds sub-project) |
| up | fresh | unknown | hold, no change, log the unrecognised raw value |
| up | stale | any | hold; Redis Data Stale already surfaces the device |
| up | absent | none | hold (went-dark limitation, below) |
| stale | any | any | hold; producer event raised on the producer node |
| unknown | any | any | hold; misconfiguration event raised |

`up` clears `Node Down` through the existing clear path, which is a no-op when no event exists, so a first poll of a healthy node is safe.

## Error handling and edge cases

- **Unrecognised vendor status:** `unknown`, hold, log engine plus raw value so the map can be extended.
- **First poll, no prior state:** clear path is a no-op when no event exists; `down` raises; `unknown`/`degraded` leave the default reachable. No special-casing.
- **nmisent interval gauge not present yet:** the producer row lacks `interval`, so `producer_state` is `unknown`, the gate holds, and the misconfiguration signal fires. The feature is inert but safe until the dependency lands, and the same holds if the producer node is not provisioned yet.
- **Node Down escalation:** reuses the exact machinery SNMP nodes use, including escalation and notification. The clear path runs on the next open-gate `up`.

## Known limitations (explicit, by decision)

- **Went-dark device.** If a device's Redis key is absent or expired while the producer is healthy, there is no `status` to read, so v1 holds the node's last state and does not mark it down. A device that was reachable and then stops reporting entirely stays reachable. Detecting this is per-device staleness-to-down, a scoped follow-on. This behaviour is intentional in v1.
- **Degraded is not surfaced in v1.** A degraded-class status (`alerting`, `dormant`) shows reachable until the thresholds sub-project lands.

## Out of scope (separate later cycles)

- Degraded-from-status and degraded-from-metrics (model thresholds and alerts feeding `status_summary`).
- Per-device staleness driving `Node Down` (the went-dark case).
- Physical ethernet port availability and Interface Down from physical ports (a true data gap).
- Generalising `coarse_status`/`precise_status` for HTTP per-source-down.

## Dependencies

- The HTTP engine (present on this branch).
- nmisent exposing `nmisent_poll_interval_seconds{engine}` on `:9464`. Until then `producer_state` is `unknown` and the gate holds (fail-safe).
- The nmisent producer node provisioned with `Common-nmisent.nmis`, and a global config pointer naming it.
- NMIS reaching nmisent `:9464` in the deployment topology.

## Testing strategy

- **A. Status map:** every known mapping for all three vocabularies, case-insensitivity, `unknown` for unrecognised values, the union behaviour under `hpe_greenlake`.
- **B. nmisent producer model:** model loads and validates; HTTP `{engine}` label discovery yields one row per engine against a fixture metrics body; the age threshold raises when `age > 2x interval` and clears when fresh. Reuses the existing HTTP engine test harness.
- **C. `producer_state`:** the tri-state directly, including each `unknown` trigger separately (config unset, node missing, engine row missing, interval missing), that `unknown` emits the misconfiguration signal once, and that it is distinct from `stale`.
- **D. Gated reachability** (in `t_polling_redis.pl`, reusing the fixture model and fake Redis client): the full truth table, plus that `ping=0` never raises `Node Down` on its own.
- **Live validation:** a forced collect on Q2KN (Meraki, live feed). Seed `status=offline` and confirm `nodestatus` goes unreachable, then `online` clears it; age the producer row past `2x interval` and confirm the device is suppressed. HPE and Aruba are structural-only until they have live feeds.
- **Regression:** `t_polling`, `t_polling_http`, `t_sys` unchanged.

## Open items

None blocking. The two earlier opens are resolved: the producer age threshold derives from the nmisent-exposed interval (`2x interval`), and the 500s `status_summary` window does not apply to this sub-project because reachability rides `Node Down` directly, not `status_summary`.
