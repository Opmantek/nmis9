# NMIS9 Redis polling engine, design

**Date**, 5 June 2026
**Branch**, feat/sdwan-polling
**Scope**, NMIS9 (Perl) side only. The nmisent Go daemon, the opmojo4 polling-spec API, and the reconciler property changes live in the matching nmisent-side document.
**Contract**, the shared contract (Contract version 1.0) is the source of truth for Redis key shapes, payload shape, completion-hash semantics, the polling-spec API, and the `nmisent_*` node properties. This document does not restate it. Where this design says "per the contract", read that document.

## Goal

Add a Redis polling engine to NMIS9 that consumes data pushed into Redis by the nmisent Go daemon, runs the existing engine-agnostic systemHealth inventory lifecycle at collect time, schedules collects from the completion hash with a polling-interval fallback, and ships a reference Meraki model. The work follows the HTTP engine that already landed on this branch as its template.

## Verified starting points

These were checked against the code before this design was written.

- Engine base class `lib/NMISNG/Sys/Engine.pm` defines the method contract the Redis engine implements: `protocol_name` (abstract), `section_keys` (default `[protocol_name]`), `is_active` (abstract), `build_queries` (abstract), `execute_queries` (abstract), `discover_indexes` (abstract, returns `($error, \@active_indices, \%targets)`), `classify_error` (default undef), and the session defaults `has_session`=0 (88), `open_session`=1 (93), `close_session`=undef (97). WMI already runs on those session defaults.
- `discover_indexes` in `Engine/HTTP.pm` returns `(undef, \@candidates, \%targets)` (HTTP.pm:622-623), with each target carrying `index_var`, `index_value`, and per-component keys for composite indexes.
- Engines are instantiated and registered in `Sys::init`, pushed onto `$self->{_engines}` and stored on a per-source slot (Sys.pm:740-766 for SNMP, WMI, HTTP).
- `collect_systemhealth_info` (Node.pm:4973-5300) is today called only from `update` (Node.pm:7355). `collect` calls only `collect_systemhealth_data` (Node.pm:9612). `sub collect` starts at Node.pm:9375.
- The systemHealth lifecycle already classifies engine errors and soft-skips `not_present` sections without touching inventory (Node.pm:5142-5189), then marks historic via `bulk_update_inventory_historic` (Node.pm:440-506) at Node.pm:5196.
- The HTTP flavour threads through six layers: `find_due_nodes` (NMISNG.pm intervals at 1743, `http_enabled` gate at 2109-2114, flavour assignments at 1948/2025/2084/2139, `last_poll_http_attempt` read at 1913), `nmisd` scheduler (729) and worker (2417), `Node::collect` destructure (9379) and `Sys::init` pass (9444), and `Sys::init` parse (416), `have_http_settings` derive (680), engine instantiation (755-766).
- `http_enabled` is derived, not operator-set. `_normalize` sets it from the presence of `http_endpoints` (Node.pm:237-238). The same file normalizes `snmp_enabled` and `wmi_enabled` from credential presence (231-234).
- Redis is new to this codebase. The Perl `Redis` client (v1.999) is installed on this host but is declared in no install manifest. `nmisent` appears nowhere in the tree, so the `nmisent_*` properties are net-new on the nmisent side.

## Resolved decisions

### 1. HGETDEL stays in find_due_nodes

Per redis-enabled node, each scheduler tick runs `HGETDEL nmisent:poll-complete {uuid}`. A returned entry marks the node due for collect and carries the entry's `run_id` forward. No entry means the node falls back to the interval check (`last_poll_redis_attempt` plus the policy interval). The `run_id` threads through the job queue as a value alongside the `wantredis` boolean, by way of `flavours{uuid}{redis_run_id}`, then job args, the worker, `Node::collect`, `Sys::init`, and finally the engine, where it drives the consistency check defined in the contract.

Accepted trade-off, because the destructive read happens at schedule time and the collect runs later in a worker, a consumed entry whose collect is dropped (worker backlog, `nmisd` restart, stale node lock) is lost. The 300s polling cycle writes a fresh entry and the prompt path resumes, and the fallback path plus freshness checks catch sustained loss. This matches the at-most-once delivery the contract describes.

### 2. redis_enabled derives from nmisent_engine_type

`_normalize` sets `redis_enabled = (defined nmisent_engine_type) ? 1 : 0`, mirroring the `http_enabled` derivation at Node.pm:237. `find_due_nodes` reads the plain boolean off node config and never loads the model. Hand-created test nodes set `nmisent_engine_type` manually. This keeps the model file as the place that declares concepts, and node config as the place that says whether this node is push-polled at all.

### 3. Empty-data semantics need no new lifecycle code

The two contract cases map onto the existing lifecycle through the engine alone.

- **Absent concept key**, the engine's `discover_indexes` returns an error and `classify_error` returns `not_present`. Node.pm:5154-5158 logs at debug and skips the section. Existing inventory is untouched.
- **Concept key present with `"data": []`**, the engine returns `(undef, [], {})`. `bulk_update_inventory_historic` at Node.pm:5196 receives an empty active list and marks every existing entry for the concept historic.

The Redis engine must draw exactly this line and nothing else changes in `collect_systemhealth_info`.

### 4. New per-concept staleness event

When a key is present and parses but `now - collected_at_epoch > freshness_s`, the engine raises a dedicated event keyed by node and concept, not the node-level `handle_down` source-down path. The event clears on the next fresh read for that concept. This keeps one stale concept from marking the whole node's Redis source down while other concepts are fresh.

### 5. Trait named manages_own_inventory

`Engine.pm` gains `sub manages_own_inventory { return 0; }`. The Redis engine returns 1, as will a future streaming engine. SNMP, WMI, and HTTP inherit 0 and keep reconciling inventory in `update`. The name avoids collision with the nmisent discovery reconciler.

## Defaults adopted for the smaller items

- **RRD non-monotonic skip logs at debug**, not warn. Out-of-order arrival after a daemon retry is expected under this contract.
- **Redis connection comes from the environment first.** The deploy already exports `NMIS_REDIS_SERVER`, `NMIS_REDIS_PORT`, and `NMIS_REDIS_PASSWORD`. The engine resolves the connection in this order, environment variable, then an optional `redis_server` / `redis_port` / `redis_password` block in `Config.nmis`, then a `localhost:6379` default. The contract pins a single shared instance, so per-node config is ruled out. One process-level connection, opened lazily, sessionless per the base-class defaults. Note this is env-first, which diverges from the Mongo pattern (DB.pm reads `db_server` from `Config.nmis`, with env bridged into config at container provisioning). If Redis should match Mongo exactly, drop the env-first step and add only the `Config.nmis` block. The `Config.nmis` password, if used, can run through the same `NMISNG::Util::decrypt` path as `db_password`. The env password is plaintext.
- **The Redis Perl client becomes a declared dependency** in the install manifest. It is present on this host but undeclared.

## Left open for build time

- **Meraki field names** for `sdwan_uplink` and `sdwan_health` are a joint decision with the nmisent side. The contract pins the shape, not the names.
- **`loadInfo` truthiness for identity-only push sections**. Confirm during build that `loadInfo` returns truthy for a section whose only Redis item is the index. The `index_function` bypass at the gate (Node.pm:5224) is the fallback.
- **Confirm the nmisent M5 reconciler ships `nmisent_discovery_id`, `nmisent_identity_key`, `nmisent_engine_type`.** If any are missing, an additive reconciler change lands on the nmisent side.

## Build sequence, file by file

1. **`lib/NMISNG/Sys/Engine.pm`**, add `sub manages_own_inventory { return 0; }`.

2. **`lib/NMISNG/Sys/Engine/Redis.pm`** (new), inherit `NMISNG::Sys::Engine`. Implement `protocol_name` (`"redis"`), `section_keys` (`['redis']`), `is_active`, `manages_own_inventory` (1), `build_queries`, `execute_queries`, `discover_indexes` (composite-index parity with HTTP.pm:453-623), and `classify_error` (connection-refused to `no_session`, missing key to `not_present`). Keys follow the contract template `nmisent:metrics:{uuid}:{concept}`. The model `redis` block names fields, the engine joins field names against the payload `data` block. Implement the freshness check and the per-concept staleness event here, and the `run_id` consistency check when an expected `run_id` is supplied. Use the sessionless defaults.

3. **`lib/NMISNG/Node.pm`**, in `sub collect`, before the `collect_systemhealth_data` call at 9612, call `collect_systemhealth_info` when any active engine returns true for `manages_own_inventory`. Destructure `wantredis` and the expected `run_id` near 9379, write `last_poll_redis_attempt` when `wantredis`, pass `redis => $wantredis` and the `run_id` to `Sys::init` near 9444. In `_normalize` near 237, derive `redis_enabled` from `nmisent_engine_type`. Gate update scheduling so push-only nodes (no SNMP, WMI, HTTP, ping false) schedule no update.

4. **`lib/NMISNG/Sys.pm`**, in `init`, parse `wantredis` via `getbool` near 416, derive `have_redis_settings` from `redis_enabled` near 680, instantiate `Engine::Redis` and push onto `_engines` and store on `$self->{redis}` near 755-766. Thread the expected `run_id` to the engine.

5. **`lib/NMISNG.pm`**, in `find_due_nodes`, add `redis` to `%intervals` defaults (300s) at 1743, compute `$nextredis` gated on `redis_enabled`, set `flavours{uuid}{redis}` in the new-node, policy-change, demoted, and steady-state branches (1948, 2025, 2084, 2139), read and write `last_poll_redis_attempt` alongside `last_poll_http_attempt` (1913). Add the completion-path `HGETDEL` and carry `run_id` as `flavours{uuid}{redis_run_id}`.

6. **`bin/nmisd`**, copy `wantredis` and `redis_run_id` into job args near 729, read them back in the worker near 2417.

7. **`conf-default/Polling-Policy.nmis`**, add a `redis` interval per policy, default 300s.

8. **`conf-default/Config.nmis`**, add an optional `redis_server` / `redis_port` / `redis_password` block as the override layer below the `NMIS_REDIS_*` environment variables. The engine reads env first, this second, `localhost:6379` last.

9. **Catchall**, add `last_poll_redis_attempt`, `last_poll_redis`, and `last_poll_redis_run_id`.

10. **`models-default/Model-CiscoMerakiCloud.nmis`** (or Common-* files following the Linux-HTTP pattern), declare `sdwan_uplink` (indexed by `wan_interface`) and `sdwan_health` (scalar) via `redis` source blocks, with a `-common-` block declaring `concept` and `engine`, and per-variable `field` mappings. Document the `redis` block shape for future models.

11. **Install manifest**, declare the `Redis` Perl client dependency.

12. **`ci/scripts/perl_tests.sh`**, add the new Redis tests to the `working_tests` array so CI runs them. `t_sys.pl`, `t_polling.pl`, and `t_polling_http.pl` are already in that array and must stay green.

## Verification

- **`test/t_polling_redis.pl`** (new), patterned on `test/t_polling_http.pl`. Assert `find_due_nodes` sets the `redis` flavour when due and `redis_enabled`, and not otherwise. Assert `build_queries` and `execute_queries` populate `%todos` against a stubbed Redis. Assert `discover_indexes` handles a composite-index case.
- **Push-source reconcile test**. Seed Redis with two indices, run a collect via the engine path, assert two inventory entries created and timed data written. Drop one index, run again, assert it is marked historic and the survivor still collects. This exercises the `manages_own_inventory`-gated collect-time `collect_systemhealth_info` path that a future streaming engine reuses.
- **Empty-data cases**. Assert absent concept key leaves inventory untouched, and `"data": []` marks all entries historic. These are contract test cases 5 and 6.
- **Staleness event**. Seed a key older than `freshness_s`, assert the per-concept event is raised, then a fresh key clears it.
- **End-to-end**. With hand-seeded Redis plus a completion-hash entry, run a single-node collect via `bin/nmis-cli`, assert RRD creation and inventory timed-data writes, and that a stale `_meta.run_id` is skipped.
- **Regression**. Run `perl test/t_polling_http.pl`, `perl test/t_polling.pl`, and `perl test/t_sys.pl`, plus core node tests. Confirm the `wantredis` thread and the collect-time reconcile do not perturb SNMP, WMI, or HTTP, which still reconcile in update because their trait is 0. Register the new tests in `ci/scripts/perl_tests.sh`.

## Joint test cases

The contract lists 18 cross-side test cases. The NMIS9 side owns the reader behaviour in cases 3 through 12, 14, 16, and 18. The verification above covers the engine-level subset that NMIS9 can test without the Go daemon. Cases needing both sides run against the M9 daemon or hand-seeded Redis.
