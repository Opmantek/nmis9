# Importing a Grafana dashboard

`admin/import_grafana_dashboard.pl` reads a Grafana dashboard JSON
file and translates Prometheus-datasource panels into starter
NMIS9 model files. Use it when you already have a curated Grafana
dashboard for an application and want the equivalent NMIS graphs
without rewriting queries by hand.

PromQL → NMIS is a partial translation; the simple cases work
cleanly, the rest get listed as TODOs for manual conversion. See
"What translates" below.

## Usage

```bash
admin/import_grafana_dashboard.pl \
    file=path/to/dashboard.json \
    name=MyApp \
    [out=tmp/grafana-MyApp-<ts>] \
    [endpoint=myapp_exporter]
```

Required:
- `file` -- path to the dashboard JSON. Either the raw API export
  (`{panels:[...]}`) or the legacy/wrapped form
  (`{dashboard:{...}}`) is accepted.
- `name` -- short name for the application. Used in the model
  filename, graphtype prefixes, and (by default) the endpoint
  name.

Optional:
- `out=<dir>` -- output directory. Defaults to
  `tmp/grafana-<name>-<YYYYMMDD-HHMMSS>/`.
- `endpoint=<name>` -- the `http_endpoints` entry name nodes will
  configure to point at the exporter. Defaults to
  `<name>_exporter` (lowercased).

## What translates (and what doesn't)

The tool's PromQL grammar in v1 is deliberately narrow:

| Grafana target | NMIS translation |
| --- | --- |
| `mongodb_up` | scalar gauge DS |
| `mongodb_up{state="active"}` | gauge DS with `match_labels` |
| `rate(http_requests_total[5m])` | counter DS (RRD computes the rate) |
| `irate(...)` / `increase(...)` | same as rate |
| `mongodb_up{instance="$node"}` | the `instance="$node"` filter is dropped silently (NMIS scopes per node already) |

These are TODO-listed verbatim, never auto-translated:

- `sum by (label) (rate(...))` and other aggregations.
- `histogram_quantile(...)`.
- Arithmetic between metrics (`a / b`).
- Label operators other than `=` (`!=`, `=~`, `!~` -- the engine
  matches by exact equality only).
- Non-Prometheus datasources (MySQL, InfluxDB, Loki, ...).
- Non-graph panel types (text, alertlist, news).

The README in the output directory enumerates every dropped panel
or expression so you can convert them by hand.

## Output

```
tmp/grafana-<name>-<ts>/
├── Common-Linux-HTTP-<name>.nmis        # the model file
├── Graph-<name>-<Section>.nmis          # one per translated panel
└── README.md                             # TODO list
```

For panels whose `legendFormat` interpolates a label
(`legendFormat: "{{collection}}"`), the tool scaffolds a
**systemHealth indexed section** with `indexed => 'collection'`.
Confirm this matches your intent -- composite indexing
(`indexed => ['db', 'collection']`) is never auto-emitted; flag
it manually if multiple labels vary.

## Smoke test with a real dashboard

The unit-test suite (`test/t_import_grafana_dashboard.pl`) uses
hand-crafted fixtures under `test/fixtures/grafana/` that exercise
the supported PromQL subset and shape variations.

For an end-to-end check against a real dashboard, drop the
exported JSON into `test/fixtures/grafana/real/<name>.json` (or
anywhere else, this directory is just convention) and run:

```bash
admin/import_grafana_dashboard.pl \
    file=test/fixtures/grafana/real/<name>.json \
    name=Smoke
```

Inspect the generated Common file's structure and the README's
TODO list. Both should round-trip through `do FILE` cleanly --
if the Common file has a Perl syntax error, that's a bug. Email
the input dashboard if you hit it.

## After editing

Same workflow as `build_http_model.pl`:

1. Move the Common + Graph files into `models-default/` (if
   shipping with NMIS) or `models-custom/` (if site-specific).
2. Wire the Common file into a node's model. See
   `docs/Model-Reference.md`, section 19, "Wiring a Common file
   into an existing model on a single node".
3. Add the `http_endpoints` entry on each target node:
   ```json
   { "name": "myapp_exporter",
     "scheme": "http",
     "host": "<host>",
     "port": <port>,
     "auth": { "type": "none" } }
   ```
4. Restart `nmisd` and run a collect cycle.

## Limits

- v1 grammar described above. Aggregating PromQL is the most
  requested follow-up; deferred until a real use case lands.
- Threshold import from Grafana panel `thresholds` is not
  implemented (different shape: Grafana = per-DS scalar bounds,
  NMIS = `model_data` expressions in alerts/threshold blocks).
- Visual fidelity is not a goal -- stat / gauge panels become
  time-series graphs.
- Dashboard layout (rows, grid coordinates) is dropped.
