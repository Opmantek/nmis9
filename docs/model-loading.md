# NMIS9 Model Loading

A device model tells NMIS what to poll on a given kind of equipment, how to interpret the results, and how to render them. Models are composed of one main `Model-*.nmis` file plus zero or more shared `Common-*.nmis` files, optionally customized by `Override-*.nmis` files. This document describes how those files are discovered, merged, cached, and consumed at runtime.

## Directory Layout

Two directories hold model files. Both are configured as macros in `conf-default/Config.nmis`:

| Macro | Default path | Purpose |
|---|---|---|
| `<nmis_default_models>` | `<nmis_base>/models-default` | Shipped with NMIS. Never modified by users -- overwritten on upgrade. |
| `<nmis_models>` | `<nmis_base>/models-custom` | Site-specific customizations. Users own this. Searched first. |

When a model file is requested by name, `models-custom/` wins on conflict; `models-default/` is the fallback. The override files described below are looked up only in `models-custom/`.

## File Types

| Filename pattern | Role | Lookup |
|---|---|---|
| `Model-<name>.nmis` | Top-level model for one device type. References Common files via the `-common-` section. | both dirs |
| `Common-<feature>.nmis` | Reusable section (e.g. CPU, memory, interfaces). Referenced by one or more Model files. | both dirs |
| `Override-Model-<name>.nmis` | Partial overlay of `Model-<name>.nmis`. Auto-discovered. | `models-custom/` only |
| `Override-Common-<feature>.nmis` | Partial overlay of `Common-<feature>.nmis`. Auto-discovered. | `models-custom/` only |
| `Override-<entry>.nmis` | Global overlay applied to every model. Registered in the `global_model_overrides` config setting. | both dirs |
| `Graph-<type>.nmis` | RRD graph definitions. Loaded separately by the graphing code, not by `loadModel`. | both dirs |

`.nmis` files are Perl source containing a single top-level `%hash = (...)` assignment. They are loaded with `eval` via `NMISNG::Util::readFiletoHash` / `loadTable`.

## Merge Order

When a model is loaded, files are merged in this order. Later wins on key conflicts:

1. `Model-<name>.nmis`
2. `Override-Model-<name>.nmis` (scoped, optional)
3. For each Common in the model's `-common-` section, in alphabetical class order:
   - a. `Common-<feature>.nmis`
   - b. `Override-Common-<feature>.nmis` (scoped, optional)
4. For each entry in `global_model_overrides`: `Override-<entry>.nmis` (global, optional)

Step 4 always merges last and therefore has the highest precedence. Use scoped overrides (`Override-Model-*`, `Override-Common-*`) when you want to customize a single file; use global overrides (`global_model_overrides`) when you want a customization that applies across every model on the system.

The merge itself is a recursive deep merge: nested hashes combine, and source values overwrite destination values for any non-hash leaf. Type conflicts (a key that is a hash on one side and a non-hash on the other) abort the load with an error.

## The Override Mechanism

The point of override files is to let users customize part of a model without taking ownership of the whole file. An override only needs to contain the keys it wants to change; everything else is inherited from the base file.

### Scoped overrides (auto-discovered)

`Override-Model-<name>.nmis` is auto-applied whenever `Model-<name>.nmis` is loaded. `Override-Common-<feature>.nmis` is auto-applied whenever `Common-<feature>.nmis` is included in the merged model. No config registration is required -- the existence of the file in `models-custom/` is the trigger. To stop applying an override, delete the file.

These are the right tool when the customization is specific to one model or one Common.

### Global overrides (`global_model_overrides`)

An array config setting that names override files applied to every model load:

```perl
'global_model_overrides' => [ 'company-defaults', 'rrd-tuning' ],
```

This loads `Override-company-defaults.nmis` and `Override-rrd-tuning.nmis` and merges each on top of every model. Lookup uses the same precedence as ordinary model files (`models-custom/` first, then `models-default/`).

These are the right tool when the customization is cross-cutting -- e.g. retuning RRD step sizes or replacing a default that should differ everywhere on the site.

## Caching

Loaded models are cached as JSON in `<nmis_var>/nmis_system/model_cache/`. Two files are written per model:

| File | Contents |
|---|---|
| `<modelname>.json` | The fully-merged model hash. This is what `$self->{mdl}` becomes on a cache hit. |
| `<modelname>.json.meta.json` | Sidecar metadata: `{ applied_overrides => [ { path, mtime }, ... ] }`. Used only by the cache freshness check. |

The cached model hash is a pure model -- it contains exactly the merged Model + Common + override data, with no metadata sentinels. Code that walks `$self->{mdl}` can treat every top-level value as a section hashref.

### Freshness check

On a cache hit, the cached model is verified against the current state of disk. If any of the following is true, the cache is considered stale and the model is reloaded from source:

- `Config.nmis` was modified more recently than the cache file.
- `Model-<name>.nmis` or any referenced `Common-<feature>.nmis` was modified more recently than the cache file.
- Any file listed in `global_model_overrides` was modified more recently than the cache file.
- **The sidecar is missing, unreadable, or doesn't contain a valid `applied_overrides` arrayref.** This is the strong invariant: without trustworthy metadata about what was applied last time, the cache cannot be trusted.
- A scoped override file (`Override-Model-<name>.nmis` or `Override-Common-<feature>.nmis`) appeared, was edited, or was deleted relative to what the sidecar recorded.

Reloading from source rewrites both files atomically.

The first run after deploying this code reloads every model once (no sidecars exist yet); steady-state polling reads from cache.

## Pre-processing

Before the merged model is written to cache, `loadModel` performs a small cleanup pass:

- Any SNMP `oid` that starts with `.` has the leading dot stripped (some MIBs include it, but `Net::SNMP` rejects it).

Other code that consumes the model (for example `Sys::loadInfo`) does its own normalization and does not modify the cached structure.

## Model Policy

After the model is loaded (whether from cache or from source), an optional **model policy** can amend the result for a specific node. The policy file is `conf/Model-Policy.nmis`. Each rule has an `IF` clause matching against `node.*` or `config.*` properties; the first matching rule applies.

```perl
%hash = (
  10 => {
    IF => { 'node.name' => ['edge-1','edge-2'] },
    systemHealth => {
      cdp  => 'true',          # add to systemHealth.sections if absent
      lldp => 'false',         # remove from systemHealth.sections if present
    },
  },
);
```

The supported amendment is currently a `systemHealth.sections` add/remove list -- the code is hardcoded to only act on `systemHealth` and notes "the only supported setting so far".

The policy is applied **after** the cache write, so it does not pollute the cached model. The cache reflects the un-policied merged result, and policy is re-applied on every load.

## Overrides vs. Model Policy

Both mechanisms can change a loaded model, but they answer different questions:

| | Override files | Model Policy |
|---|---|---|
| What it changes | Any key, anywhere in the merged model hash | Only `systemHealth.sections` (which subconcepts are active) |
| Scope | All nodes that load this model | Per-node, gated by `IF` rules against `node.*` / `config.*` |
| Trigger | File presence (scoped) or config list (global) | Rules in `conf/Model-Policy.nmis`, evaluated each load |
| Cached? | Yes -- baked into the cached merged model | No -- re-applied on every load |
| Answers | "What is the right way to model device type X?" | "For this specific node, which of those concepts should be active?" |

**Use overrides when** you need to change the data definitions: tweak a threshold name, swap an OID, add a section the shipped Common file doesn't know about, fix a typo in vendor data. The change is true for every node of that type.

**Use Model Policy when** the answer depends on the node: turn off `mplsVpnVrf` monitoring on edge nodes, enable `cdp` only in a specific location, etc. The model itself is unchanged; only the active section list shifts per-node.

The mechanisms are complementary. You cannot do per-node selection with overrides (they apply at model-load time, before per-node context is available), and you cannot change OIDs, thresholds, or sub-section structure with policy (it only manipulates the section list).

## Public API

All functions are in `NMISNG::Sys` (`lib/NMISNG/Sys.pm`) and `NMISNG::Util` (`lib/NMISNG/Util.pm`).

### `NMISNG::Sys::loadModel(model => $name)`

Loads, merges, and caches the named model into `$self->{mdl}`. `$name` is the full filename without extension (e.g. `Model-CiscoRouter`). Returns 1 on success, 0 on failure (and sets `$self->{error}`).

### `NMISNG::Util::getModelFile(model => $name, conf => $C, only_mtime => $bool)`

Locates a model file by name, searching `<nmis_models>` first, then `<nmis_default_models>`. Returns a hashref:

- `success` -- 1 if found and parsed, 0 otherwise
- `data` -- parsed hash (omitted if `only_mtime`)
- `mtime` -- file modification time
- `is_custom` -- 1 if the file came from `<nmis_models>`
- `error` -- error message on failure

### `NMISNG::Util::getDir(dir => "models" | "default_models", conf => $C)`

Resolves the symbolic directory name to a filesystem path.

## File Format

`.nmis` files contain Perl assigning to a top-level `%hash`:

```perl
%hash = (
  'system' => {
    'nodeVendor' => 'Cisco',
    'nodeType'   => 'router',
  },
  '-common-' => {
    'class' => {
      'cpu'    => { 'common-model' => 'Cisco-cpu' },
      'memory' => { 'common-model' => 'Cisco-memory' },
    },
  },
  'systemHealth' => {
    'sys' => { ... },
    'rrd' => { ... },
  },
);
```

The `-common-` section names which Common files to merge in. Override files use the same format and only need to contain the keys they want to change.

## Customization Recipe

The general pattern is: figure out the dotted path from the top of the merged model down to the leaf you want to change, then mirror that path in an override file containing only the keys you want to change. Save it under `models-custom/` with the matching `Override-` prefix. Reload -- the override is auto-discovered, the cache invalidates, and the new value wins.

To remove the customization, delete the file. The cache invalidates again on the next load.

### Example 1: change an alert threshold in a Model file

`models-default/Model-net-snmp.nmis` defines an alert that fires when system process count exceeds 375:

```perl
'system' => {
  'sys' => {
    'alerts' => {
      'snmp' => {
        'hrSystemProcesses' => {
          'oid'   => 'hrSystemProcesses',
          'title' => 'System Processes',
          'alert' => {
            'test'  => '$r > 375',
            'event' => 'High Number of System Processes',
            'unit'  => 'processes',
            'level' => 'Warning',
          },
        },
      },
    },
  },
},
```

To raise the threshold to 1000 -- and only that one field -- create `models-custom/Override-Model-net-snmp.nmis`:

```perl
%hash = (
  'system' => {
    'sys' => {
      'alerts' => {
        'snmp' => {
          'hrSystemProcesses' => {
            'alert' => {
              'test' => '$r > 1000',
            },
          },
        },
      },
    },
  },
);
```

Everything else (`event`, `unit`, `level`, `oid`, `title`, every other alert, the rest of the model) is inherited from the base file because the override file doesn't mention it. The merge only overwrites keys present in the override.

### Example 2: change multiple fields in the same alert

To loosen the threshold AND escalate the severity, expand the same override file:

```perl
%hash = (
  'system' => {
    'sys' => {
      'alerts' => {
        'snmp' => {
          'hrSystemProcesses' => {
            'alert' => {
              'test'  => '$r > 1000',
              'level' => 'Critical',
              'event' => 'Process Count Exceeded Critical Threshold',
            },
          },
        },
      },
    },
  },
);
```

Sibling keys (`unit`) are still inherited. You can change as many keys as you like in a single override file -- the deep merge handles each leaf independently.

### Example 3: override two unrelated alerts at once

The same override file can touch any number of paths. To also raise the TCP connection alert:

```perl
%hash = (
  'system' => {
    'sys' => {
      'alerts' => {
        'snmp' => {
          'hrSystemProcesses' => {
            'alert' => { 'test' => '$r > 1000' },
          },
          'tcpCurrEstab' => {
            'alert' => { 'test' => '$r > 500' },
          },
        },
      },
    },
  },
);
```

### Example 4: effectively disabling an alert

The override merge **overwrites** keys but does not **delete** them -- there is no way to remove an alert via override. The closest equivalent is to give the test an expression that never matches:

```perl
%hash = (
  'system' => {
    'sys' => {
      'alerts' => {
        'snmp' => {
          'hrSystemProcesses' => {
            'alert' => { 'test' => '0' },   # always false
          },
        },
      },
    },
  },
);
```

If you need to genuinely add or remove monitored sub-concepts on a per-node basis, that is a job for **Model Policy** (see above), not for an override.

### Knowing whether to use Model- or Common-

When the path you want to change is defined directly inside a `Model-*.nmis` file, use `Override-Model-<name>.nmis`. When it is defined inside a `Common-*.nmis` file (often shared across many models), use `Override-Common-<feature>.nmis` so the change applies wherever that Common is included.

Quick way to find out: `grep -l '<key-or-string>' models-default/Model-*.nmis models-default/Common-*.nmis`. Whichever file contains the leaf you want to change tells you the override flavour to use.

## Debugging Overrides

When an override doesn't behave the way you expected, the question is almost always "what does the merged model actually look like after my override was applied?" Several tools answer that.

### 1. Inspect the compiled (cached) model JSON

After a model loads from source, the fully-merged result is written to:

```
<nmis_var>/nmis_system/model_cache/<modelname>.json
<nmis_var>/nmis_system/model_cache/<modelname>.json.meta.json
```

The first file is the merged model -- the same hash that becomes `$self->{mdl}` at runtime. The second is the sidecar listing which scoped overrides were applied (and at what mtime). Pretty-print and grep them:

```bash
jq . /usr/local/nmis9/var/nmis_system/model_cache/Model-net-snmp.json | less
jq . /usr/local/nmis9/var/nmis_system/model_cache/Model-net-snmp.json.meta.json
```

Confirming the sidecar lists your override file proves it was discovered and merged. Confirming a value at the expected path in the model JSON proves the merge produced what you wanted.

If you change an override and want to force a reload, simply `touch` the override file; the next model load will see the newer mtime and rebuild. To wipe caches across the board, `rm -rf <nmis_var>/nmis_system/model_cache/*` -- the next load rebuilds everything from source.

### 2. `test/dev-tools.pl act=model`

For the runtime view (cache or source, whichever is current, plus any per-node Model Policy applied), use the dev-tool:

```bash
perl /usr/local/nmis9/test/dev-tools.pl act=model node=<nodename>
```

It calls `NMISNG::Sys->init(name => ...)` and `Data::Dumper`s the result of `$S->mdl()`. This is the merged hash exactly as the polling code will see it for that specific node, so any per-node Model-Policy amendments are also reflected.

Useful for distinguishing "the override merged correctly but policy is changing things" from "the override didn't merge at all".

### 3. `admin/model_tool.pl`

A model validator and discovery helper. Three modes that are useful here:

```bash
# Validate every shipped model and any custom overrides for syntax errors
perl /usr/local/nmis9/admin/model_tool.pl check=true errors=true

# Validate against the JSON schema (checks structure, not just syntax)
perl /usr/local/nmis9/admin/model_tool.pl check=true schema=true errors=true

# Walk every local node and try to load its model (catches merge failures
# that only manifest for specific node configurations)
perl /usr/local/nmis9/admin/model_tool.pl nodes=true
```

Schema validation will catch override files that introduce keys at illegal paths (e.g. typos in the merge structure), which can otherwise silently merge into a place no consumer reads from.

### 4. `admin/compare_models.pl`

Diff `models-custom/` against `models-default/`:

```bash
perl /usr/local/nmis9/admin/compare_models.pl /usr/local/nmis9/models-custom /usr/local/nmis9/models-default
```

Useful when migrating from the old "copy the whole file" style of customization: it shows exactly which files in `models-custom/` differ from shipped, which makes it easy to convert each one into a much smaller `Override-*.nmis`.

### 5. Bypass the cache

If you suspect the cache is masking a problem, two options:

- Wipe the cache directory: `rm -rf <nmis_var>/nmis_system/model_cache/*`
- Or set `cache_models => 0` in `conf/Config.nmis` to disable caching entirely. Models then re-merge on every load. Slower for production, fine for short debugging sessions.

### 6. Run with debug logging

`loadModel` emits debug messages that name each Common and Override file it merges, in order. Run any CLI command with a debug level high enough to surface them:

```bash
perl /usr/local/nmis9/bin/nmis-cli act=run-reports period=day type=health debug=2
```

Or invoke `dev-tools.pl act=model debug=3 node=<nodename>` to see the load decisions for a single node.

Look for lines mentioning `Override-`, `(from cache)`, `(from source)`, `stale`, and `merged`. Combined with the cached JSON inspection above, this is usually enough to pinpoint a misbehaving override.

### 7. Use the test harness as a sandbox

`test/t_model_overrides.pl` builds a fresh model + Common + override under a temporary directory and confirms the merge. The same pattern is the cleanest way to validate a tricky override before deploying it: write a tiny driver that copies the relevant base files into a temp directory, drops your candidate override next to them, points `<nmis_models>` / `<nmis_default_models>` at the temp dirs, calls `NMISNG::Sys::loadModel`, and prints the result. Nothing on the live system changes.

## Testing

Override loading and cache freshness are tested in `test/t_model_overrides.pl`. The test runs entirely against temporary `models-default/`, `models-custom/`, and `var/` directories, so it does not perturb a running NMIS install on the same host. It does not need MongoDB. Run with:

```bash
perl test/t_model_overrides.pl
```

Broader regressions for `loadModel` are exercised by `test/t_sys.pl`, `test/t_polling.pl`, and `test/t_nmisng.pl`.
