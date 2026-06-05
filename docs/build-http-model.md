# Generating a starter HTTP model

`admin/build_http_model.pl` reads a Prometheus `/metrics` endpoint
and emits a starter `Common-Linux-HTTP-<App>.nmis` plus matching
`Graph-*.nmis` files. Use it to skip the busy work when adding a
new application's metrics; expect to spend ~30 minutes editing the
output before installing.

## Usage

```bash
admin/build_http_model.pl \
    url=http://host:port/metrics \
    name=MyApp \
    [auth_bearer=$TOKEN] \
    [out=tmp/scaffold-MyApp-<ts>] \
    [endpoint=myapp_exporter] \
    [prefix_depth=2]
```

Required:
- `url` -- absolute URL of the metrics endpoint.
- `name` -- short name for the application; used in the model
  filename and graphtype prefixes (`Common-Linux-HTTP-MyApp.nmis`,
  `MyApp-Connections`, etc.).

Optional:
- `auth_bearer=<token>` -- sent as `Authorization: Bearer <token>`.
  No other auth schemes in v1.
- `out=<dir>` -- output directory. Defaults to
  `tmp/scaffold-<name>-<YYYYMMDD-HHMMSS>/` under the NMIS root.
- `endpoint=<name>` -- the `http_endpoints` entry name nodes will
  configure to point at the exporter. Defaults to
  `<name>_exporter` (lowercased).
- `prefix_depth=N` -- how many underscore-separated tokens to use
  when grouping metrics into sections. Default 2 (so
  `mongodb_connections_*` and `mongodb_dbstats_*` become two
  separate sections). Increase for finer-grained sections,
  decrease to lump more metrics together.

## What gets generated

```
tmp/scaffold-<name>-<ts>/
├── Common-Linux-HTTP-<name>.nmis         # the model file
├── Graph-<name>-<Section>.nmis           # one per section (multiple)
└── README.md                              # TODO list
```

The Common file contains:

- `database/type` -- maps each topic / section to an RRD path.
- `system.rrd` -- one entry per scalar group (no labels, or stable
  single-value labels).
- `system.nodegraph` -- comma-separated list of every graphtype
  registered, so they appear as inline thumbnails on the node
  page.
- `systemHealth.sys` + `systemHealth.rrd` -- one entry per indexed
  group (metrics with high-cardinality labels). The tool picks the
  label with highest cardinality as the suggested `indexed` and
  TODO-comments alternative labels for operator review.

The Graph files are minimal but valid: `heading`, `title`,
`vlabel`, and `option.standard` / `option.small` blocks with DEFs
+ AREA/LINE/GPRINT for up to 6 DS. Extra DS still land in the
RRD; they just don't appear on the auto-generated graph -- split
the section into multiple Graph files by hand if you need them
plotted.

## TODO list

The README in the output directory enumerates every TODO the tool
deferred to you. Common categories:

1. **Friendly titles** -- the tool tries to derive titles from
   `# HELP` text; if HELP is absent or terse, the title is blank
   and you should supply one.
2. **Indexed-label confirmation** -- when multiple labels have
   similar cardinality, the tool flags the section so you can
   decide whether to switch to composite indexing
   (`indexed => ['label1', 'label2']`).
3. **Threshold values** -- not inferred. Add a `threshold` and/or
   `alerts` block in the Common file once you know what "bad"
   means for the metric.
4. **DS-name truncations** -- RRD limits DS names to 19 chars.
   The tool truncates and dedups; the README records what got
   shortened so you can rename for clarity.
5. **Histograms / summaries** -- detected by `_bucket{le=...}`
   and `{quantile=...}` patterns. Listed as a counter section
   with a TODO explaining your three options:
   - keep all `_bucket` items + graph the rate (noisy but
     complete);
   - drop `_bucket`, graph `rate(_sum) / rate(_count)` for
     average latency;
   - compute percentiles in a plugin
     (`rate(_bucket) / rate(_count)` style). Out of scope for
     the auto-scaffold.

## After editing

1. Move the Common + Graph files into `models-default/` (if
   shipping with NMIS) or `models-custom/` (if site-specific).
2. Wire the Common file into a node's model via the
   `-common-.class` block. See `docs/Model-Reference.md` section
   19 ("Wiring a Common file into an existing model on a single
   node") for the standard pattern.
3. Add the `http_endpoints` entry on each target node:
   ```json
   { "name": "myapp_exporter",
     "scheme": "http",
     "host": "<host>",
     "port": <port>,
     "auth": { "type": "none" } }
   ```
4. Restart `nmisd` (or wait for the model cache to refresh) and
   run a collect cycle. Confirm RRDs appear under
   `nmis_var/nodes/<node>/health/`.

## Limits

- v1 supports only `Bearer` token auth. Basic auth, mTLS, OAuth
  flows are not handled -- run the tool against a publicly
  accessible exporter or a port-forwarded local copy.
- Composite indexing (`indexed => [...]`) is never auto-emitted;
  the tool flags candidates and leaves the choice to you.
- Histogram quantile computation is not generated.
- Threshold inference is not attempted.
- Generated files are NOT auto-installed. Output goes to `tmp/`
  so you review before copying into `models-*/`.
