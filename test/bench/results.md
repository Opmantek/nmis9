# Collect-performance benchmark results

Cumulative layers on `perf-bench` (baseline = origin/nmis9_dev @158e2c34, includes nodeobj).
Metrics per collect: `finds` is the total MongoDB find-op count across all collections (not events-only); `db_ops` is all MongoDB ops; wall-clock is
median of 5 runs (ms); RSS peak and delta in KB; opcounters delta (q=query/find, u=update,
i=insert, d=delete). Live = realnode188 (varies with host); mock = deterministic real capture.

Interpretation note: `opcounters` is server-instance-wide on the shared mongo (rough
cross-check, noisy — other clients' ops in the same window are counted too); wall-clock is
affected by shared-mongo load; `db_ops` (in-process, deterministic on the mock node) is the
authoritative per-collect metric.

| layer | sha | node | mode | finds | db_ops | wall_ms | rss_peak | rss_delta | opcounters |
|-------|-----|------|------|-------|--------|---------|----------|-----------|------------|
| L0-baseline | ae9e0f1a | realnode188 | live | 285 | 474 | 454 | 158972 | 588 | q=285 u=135 i=54 d=0 |
| L0-baseline | ae9e0f1a | mocknode | mock | 108 | 142 | 141 | 163544 | 1280 | q=108 u=27 i=7 d=0 |
| L1-omk12677 | 153565ad | realnode188 | live | 210 | 391 | 423 | 159032 | 552 | q=210 u=127 i=54 d=0 |
| L1-omk12677 | 153565ad | mocknode | mock | 73 | 107 | 128 | 163380 | 1280 | q=73 u=27 i=7 d=0 |
| L2-omk12668 | 4a23453e | realnode188 | live | 120 | 306 | 387 | 159280 | 508 | q=120 u=132 i=54 d=0 |
| L2-omk12668 | 4a23453e | mocknode | mock | 53 | 87 | 116 | 163612 | 1352 | q=53 u=27 i=7 d=0 |
| L3-omk12669 | 96cea53f | realnode188 | live | 88 | 275 | 375 | 159832 | 740 | q=88 u=133 i=54 d=0 |
| L3-omk12669 | 96cea53f | mocknode | mock | 21 | 55 | 105 | 163840 | 1496 | q=21 u=27 i=7 d=0 |

## Findings

Three stacked collect optimizations cut per-collect MongoDB reads by about 81% on the
deterministic mock node (108 to 21 finds) and about 69% on the live node (285 to 88), with
each layer's drop attributable to one optimization and a small, roughly constant memory cost.

Per layer, on the mock node (the deterministic anchor):

- L1 OMK-12677 event-prefetch: events-collection finds 43 to 8, total 108 to 73. The per-node
  event buffer serves the in-cycle existence checks that previously hit the DB per interface.
- L2 OMK-12668 latest-data-prefetch: latest_data finds 21 to 1, total 73 to 53. The per-node
  latest_data buffer collapses the per-inventory reads to one batch load.
- L3 OMK-12669 collect-intf-shared-load: inventory finds 17 to 11 and nodes finds 26 to 0,
  total 53 to 21. Sharing the loaded node object across interfaces removes the per-interface
  node re-reads entirely and cuts repeated inventory reads.
- L4 OMK-12673 collect-services: SKIPPED. The branch is plan-only (commits bfccf980 plan and
  3ce238b3 spec, zero lib/bin changes), so there is nothing to measure. It is not counted.

Reads versus memory (the trade-off the benchmark set out to show): as reads fell 81%, mock RSS
peak crept from 163544 to 163840 KB (about +300 KB) and the per-collect RSS delta rose from
1280 to 1496 KB. The prefetch caches trade a small, roughly constant memory increase for a
large read reduction, so the net is strongly positive on this node's scale.

Wall-clock (mock, noisy context metric) fell 141 to 105 ms as reads dropped. The mock
opcounters `query` count tracks `finds` exactly (108 to 21), which confirms the in-process
`db_ops` count and indicates the shared mongo was quiet during the runs.

Layer interactions: the three optimizations compose cleanly. Each layer's targeted collection
dropped as expected while the prior layers' drops held (events stayed at 8 and latest_data at 1
through L3), so no optimization undermined another. The L2 merge required conflict resolution
in `lib/NMISNG.pm` (both prefetch buffers in the `new` hash) and `lib/NMISNG/Node.pm` (both
collect/update triggers); it was resolved to keep both, and the measurements confirm both
buffers stayed active afterward. L1 and L3 merged clean.

Live versus mock: the mock node is the anchor and is identical across runs; the live node
varies with the host's changing interface set but shows the same downward trend, so it
corroborates the mock deltas on real, changing data.

To extend this over time: merge a new branch onto `perf-bench`, run
`test/bench/run_layer.sh <label>`, and commit the appended row and a new tag. The mock capture
keeps the input identical, so a future row is directly comparable to these.
