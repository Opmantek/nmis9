# Cumulative collect-performance benchmark — design

Date: 2026-07-01
Branch: `perf-bench` (worktree `/home/md/work/nmis9-perf-bench`), cut from `origin/nmis9_dev`
Status: design, approved in brainstorming

## Goal

Build a repeatable system that measures how a stack of collect-performance branches
affects NMIS over time. Start from the baseline, add each branch one at a time, and record
a row of measurements at every step, so each merge's effect is attributable and the
combined effect is visible. The system must be re-runnable when future branches land, and
the merges must be fully undoable without touching the real branches or `nmis9_dev`.

## Baseline and layers

Baseline is `origin/nmis9_dev` at `158e2c34`, which is the `Plugin nodeobj param (#184)`
commit. nodeobj is therefore part of the baseline and present in every layer. It is not
measured as a separate layer (it is already merged into `nmis9_dev`). If a later decision
wants nodeobj's own contribution isolated, the baseline can move one commit earlier and
nodeobj become layer 0, but that is out of scope here.

Cumulative layers, measured in this order:

- L0 — baseline (`origin/nmis9_dev`, includes nodeobj)
- L1 — + OMK-12677 event-prefetch (per-node event buffer)
- L2 — + OMK-12668 latest-data-prefetch (per-node latest_data prefetch)
- L3 — + OMK-12669 collect-intf-shared-load (shared interface object load)
- L4 — + OMK-12673 collect-services-optimisation (collect_services detail level)

OMK-12668 and OMK-12669 predate the nodeobj commit, so merging them onto the
nodeobj-bearing base combines both. OMK-12673 already contains nodeobj. Before L4 is
measured, confirm OMK-12673 carries real code and not only an implementation-plan commit.
If it is plan-only, record that L4 was skipped and why, rather than adding an empty layer.

## Metrics recorded per layer

Measured for each of the two nodes (below):

- Per-collection MongoDB operation counts during one collect, split by operation (find,
  update, insert, remove, count, aggregate) and by collection (events, latest_data,
  inventory, nodes, and any others touched). Deterministic for a fixed input, so this is
  the primary attributable metric.
- Collect wall-clock time, median of N = 5 measured runs plus min and max.
- Process resident memory (RSS), peak during the collect and delta from before it. Captures
  the memory cost of the prefetch and caching layers.
- MongoDB server-side opcounters, the delta across the collect
  (`serverStatus.opcounters`). A cross-check on the in-process counts and a view of
  server-side load the in-process count cannot see.

Deterministic counts (on the mock node) need one run to record and a second to confirm
stability. Noisy metrics (wall-clock, RSS) use the N = 5 runs.

## The two SNMP sources

1. Real net-snmp node — `realnode188`, polling the live net-snmp host at `172.20.0.1:1161`,
   community `nmisGig8`, model net-snmp. The host's interface set changes as docker
   containers start and stop, so its collect is not reproducible. Reported as a median with
   a min-max range and a variability note. It is the live reality check.
2. Mock node — a deterministic clone of the real host. We snmpwalk the live host once and
   convert the walk into the flat `OID -> value` JSON the in-tree mock consumes, then a node
   on the net-snmp model collects through `NMISNG::Snmp::Mock` loaded with that capture.
   Same real device data, same model, but fixed and replayed, so its collect is
   reproducible across runs and over time. This is the anchor for clean per-layer deltas.

The mock (`test/lib/NMISNG/Snmp/Mock.pm`, `test/lib/NMISNG/WMI/Mock.pm`) is already in
`nmis9_dev`, so it is present at every layer. `test/t_polling.pl` shows the injection
pattern: create a `Sys`, set `$S->{snmp}` to the mock, call `$S->open()`. Because a full
`$node->collect()` builds its own `Sys` and opens its own session, the benchmark runner
substitutes the mock at that open point (a monkey-patch of the `Sys` SNMP-open path,
mirroring the same pattern) so the whole collect pipeline and the prefetch buffers run
against the captured data. The exact patch point is pinned in the plan.

## Capturing the real host into the mock format

The mock consumes a flat JSON object of numeric-OID strings to values (keys beginning with
`_` are comments and ignored). The capture step:

- `snmpwalk -v2c -c nmisGig8 -On 172.20.0.1:1161 .1` over the subtrees the net-snmp model
  reads (system, interfaces `1.3.6.1.2.1.2` and `1.3.6.1.2.1.31`, ip, and the rest of
  MIB-2 the model touches).
- Convert each `.<oid> = <TYPE>: <value>` line to `"<oid without leading dot>": "<value>"`,
  handling the SNMP types net-snmp prints (STRING unquoted, INTEGER/Counter/Gauge as the
  number, Timeticks as the parenthesised tick count, IpAddress as the dotted quad,
  Hex-STRING preserved, OID as the OID string).
- Store the result as a committed fixture `test/bench/testdata/realnode_capture.json`.

The capture is taken once and frozen. Because it is real net-snmp data with the host's full
interface set, the mock node is both at-scale and deterministic, which resolves the
small-device limitation of the existing `snmpwalk_test.json`. Re-capturing is a documented,
deliberate action (a new fixture), not something that happens on every run.

## Components

Each unit has one purpose and a defined interface.

- `test/bench/capture_host.pl` — the capture unit. Input: host, port, community. Runs the
  walk, converts it, writes `test/bench/testdata/realnode_capture.json`. Idempotent: refuses
  to overwrite unless asked, so the frozen capture is stable.
- `test/bench/collect_bench.pl` — the measurement unit. Input: a node name, a mode
  (`live` or `mock`), and N. It wraps the `NMISNG::DB` operation functions to count calls by
  collection and operation, reads `serverStatus.opcounters` before and after, records RSS,
  and runs `$node->collect(force=>1)` once as a discarded warm-up then N measured times. In
  `mock` mode it also installs `NMISNG::Snmp::Mock` (loaded from the capture) into the
  collect path. It prints one structured JSON result to stdout. It changes no schema and
  holds no state between runs.
- `test/bench/run_layer.sh` — the orchestration unit. Input: a layer label. Runs
  `collect_bench.pl` for the real node (`live`) and the mock node (`mock`) inside the
  benchmark container, parses the two JSON results, and appends one row per node to the
  results log. It knows nothing about how a collect is measured.
- `test/bench/setup_nodes.pl` — the fixture unit. Creates `realnode188` (live) and the mock
  node (net-snmp model) in the benchmark database and brings each to a steady state.
  Idempotent.
- `test/bench/results.md` — the record. An appendable markdown table, one row per layer per
  node, plus a short findings narrative that grows as layers are added. This is the
  deliverable the user reads.

## Environment

A fresh isolated dev container mounts the `perf-bench` worktree at `/usr/local/nmis9`, on
the same docker network as the live net-snmp host gateway, with its own MongoDB database (a
distinct `db_name`, the same isolation the event-prefetch spike used). The background nmisd
daemon is stopped so nothing collects concurrently. No snmpsim is needed: the live node
polls the real host, and the mock node replays the captured JSON in-process. Before each
layer is measured, both nodes are brought to a steady state (an update then a collect), and
the same steps run identically at every layer.

## Integration and undo

- `perf-bench` is cut from `origin/nmis9_dev` and is never merged into `nmis9_dev`.
- The runner units, the capture, this design, and an empty results log are committed as the
  branch base, tagged `bench-base`.
- Each layer is produced by merging that layer's optimization branch into `perf-bench`,
  running the layer, appending the results row, and committing. Each layer is tagged
  (`bench-L1-omk12677`, `bench-L2-omk12668`, and so on).
- Undo one layer: reset the branch to the previous layer's tag and re-run from there. Undo
  everything: delete the `perf-bench` branch and worktree. Because the branch is never merged
  upstream, discarding it leaves the real branches and `nmis9_dev` untouched.
- The reusable parts (runner units, capture, results log) live at `bench-base`, so they
  survive an undo of the merge layers.
- Merge conflicts are expected where two branches touch the same collect or NMISNG code.
  Each is resolved at merge time to preserve both optimizations, and the resolution is noted
  in the layer's commit message and in the results log so the measured code is documented.

## Reproducibility and adding future branches

To add a branch later: merge it onto `perf-bench` (or a fresh branch cut from the current
tip), run `run_layer.sh <label>`, and commit the appended results row and a new tag. The
mock node's capture keeps the input identical to earlier runs, so a new row is directly
comparable to the existing ones. If the live host has drifted, the live-node row is still
recorded with its variability note, and the mock-node row carries the controlled comparison.

## Run sequence now

1. Stand up the benchmark container, capture the real host, set up both nodes, commit the
   base, tag `bench-base`.
2. Measure L0 (baseline) for both nodes, append rows.
3. For each of L1..L4: merge the branch, resolve conflicts, bring nodes to steady state, run
   the layer, append rows, commit, tag.
4. Write the combined findings narrative in the results log: which layer moved which metric,
   the cumulative effect, and any memory-versus-reads trade-off observed.

## Error handling and edge cases

- A collect that errors or times out produces no valid measurement. The runner reports the
  failure and the layer row records it rather than a fabricated number.
- OMK-12673 plan-only: skip L4 with a recorded reason.
- Live-host drift between layers changes live-node counts. Documented per row. The mock node
  is the controlled comparison, so drift does not invalidate the deltas.
- A merge conflict that cannot be resolved to preserve both optimizations is recorded, and
  that layer is measured with the resolution actually applied, described in the row.
- SNMP types the converter does not recognise are recorded verbatim and flagged, so the
  capture never silently drops or mangles an OID.

## Testing the runner itself

The runner is validated before it is trusted: on the baseline, the events-collection find
count it reports for the mock node must match the figure the event-prefetch spike measured
for the same flag state, and turning the event-prefetch flag on at L1 must show the
events-collection reads drop by the amount that spike recorded. If the runner cannot
reproduce a known number, the runner is wrong and is fixed before any layer is trusted.

## Out of scope

- The memory-footprint branches (OMK-12375, SUPPORT-12368) are not layers here. Memory is
  measured as a metric, but those branches are not merged.
- No change is proposed to `nmis9_dev` or to any optimization branch. This is a measurement
  system only.
