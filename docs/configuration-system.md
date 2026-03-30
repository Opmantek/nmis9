# NMIS9 Configuration System

The configuration system uses layered loading with source tracking. Config files use a two-level Perl hash format (`%hash = (section => {key => value, ...}, ...)`). At runtime, the two-level structure is flattened into a single hash with macro expansion for path references.

## Layers

Config is loaded in this order. Each layer can override values from previous layers.

### Layer 0: Hardcoded

Set directly in `loadConfTable` after all file/env layers merge. Cannot be overridden.

- `conf` = `"Config"`
- `auth_require` = `1`
- `hide_groups` = `[]` (if not already set)
- `debug` / `info` (parsed from command-line args)

If `cluster_id` is missing after all layers, a UUID is generated and written to `conf/Config.nmis`.

### Layer 1: Defaults (`conf-default/Config.nmis`)

Shipped with NMIS. Contains every config key with its default value. Never modified by users -- overwritten on upgrade. Establishes the full set of known keys.

### Layer 2: Local config (`conf/Config.nmis`)

Site-specific overrides. Only needs to contain keys that differ from defaults. Full merge -- can add new keys and override existing ones. This is the file the GUI and CLI write to.

`writeConfData` automatically filters out values that match defaults, so only actual overrides are persisted. If the file becomes empty (all values match defaults), it is backed up and removed.

### Layer 3: Fragments (`conf/conf.d/*.nmis`)

Managed by external tools (configuration management, orchestration, master servers). Loaded in sorted filename order for deterministic merging.

**Override-only** -- can only change keys that already exist in layers 1-2, not add new ones. NMIS never writes to these files. Attempting to modify a conf.d-managed key through the GUI or `writeConfData` returns an error.

### Layer 4: Environment variables (`NMIS_*`)

Runtime overrides via `NMIS_`-prefixed environment variables. Can override existing keys or add new ones.

**Key resolution:** `NMIS_DB_SERVER` tries `db_server` first, then `<db_server>`. So `NMIS_NMIS_BASE` maps to `<nmis_base>`, and `NMIS_CGI_URL_BASE` maps to `<cgi_url_base>`.

Like conf.d, these are read-only from NMIS's perspective -- `writeConfData` rejects changes to ENV-managed keys. An override of a default (layer 1) value is silent; overriding a local or conf.d value logs a warning.

## Exclusive Keys

The properties `cluster_id`, `server_name`, and `nmis_host` may only be defined in **one** non-default source (across layers 2, 3, and 4). If already claimed by an earlier source, later definitions are warned and ignored. Layer 1 defaults do not count for this check.

## Macro Expansion

After all layers are merged, `replace_macros()` runs once. Values containing `<key_name>` are expanded by looking up `<key_name>` or `key_name` in the config. For example, `<nmis_conf>/users.dat` becomes `/usr/local/nmis9/conf/users.dat`.

Macro expansion only affects the runtime flat cache. The raw layer data (used for writing back to files) preserves the original macro references.

## Caching

Config is loaded once per process and cached. Subsequent calls to `loadConfTable` return the cached result immediately.

To force a reload (e.g. after writing config):

```perl
$NMISNG::Util::_config_cache_invalid = 1;
my $C = NMISNG::Util::loadConfTable();
```

`writeConfData` sets this flag automatically after a successful write.

## Change Notification

When `writeConfData` writes config, it also writes a timestamp to `<nmis_var>/nmis_system/config_changed`. Other processes can poll `NMISNG::Util::configChanged( conf=> $C )` to detect that config has changed on disk since they loaded it.

## Public API

All functions are in `NMISNG::Util` (`lib/NMISNG/Util.pm`).

### `loadConfTable(%args)`

Loads and returns the effective config as a flat hashref (keys flattened from two-level structure, macros expanded).

- `dir` -- config directory (default: `$FindBin::RealBin/../conf`)
- `debug` -- debug level override
- Returns: hashref

### `getConfigSources(%args)`

Returns source tracking for config keys.

- No args: returns `{ key => { source => $file, layer => $n, section => $name }, ... }`
- `key => "db_server"`: returns just that key's source info hashref

### `getConfigDefaults()`

Returns the layer 1 defaults as a two-level hashref `{ section => { key => value } }`.

### `getConfDeep(%args)`

Returns the effective config as a two-level hashref with raw (pre-macro) values. Used by `writeConfData` and the config GUI.

- No args: merges all layers (1-4), suitable for display and round-tripping through `writeConfData`
- `only_local => 1`: returns only layer 2 (local config) keys

Returns: `($deep_hashref, $configfile_path)`

### `writeConfData(%args)`

Writes config to `conf/Config.nmis` with automatic filtering:

- Layer 3/4 managed keys: error if value changed, silently skipped if unchanged
- Keys matching layer 1 defaults: silently skipped
- Empty result: backs up and removes the config file

Also invalidates the in-process cache and writes a change notification marker.

- `data` -- two-level hashref to write
- Returns: `undef` on success, error message string on failure

### `stripDefaults()`

Compares local config (layer 2) against defaults (layer 1). Returns the stripped data and a list of removals.

Returns: `($stripped_hashref, \@removals)` where each removal is `{ section, key, value }`

### `configChanged(conf => $C)`

Returns true if the config change marker on disk is newer than when this process loaded config. Requires the loaded config hashref (`$C` from `loadConfTable`). Processes can poll this to decide whether to restart.

## CLI Actions

### `bin/nmis-cli act=show-config`

Displays all config keys grouped by section, with source info.

- `section=database` -- filter to one section
- `key=db_server` -- show one key

### `bin/nmis-cli act=strip-config-defaults`

Removes default-matching values from `conf/Config.nmis`. Prompts for confirmation unless `quiet=true`.

### `bin/nmis-cli act=restore-config`

Restores `conf/Config.nmis` from the `.bak` backup created by `writeConfData`. Prompts unless `quiet=true`.

## Config File Format

All `.nmis` config files use the same two-level Perl hash format:

```perl
%hash = (
  'section_name' => {
    'key1' => 'value1',
    'key2' => 'value2',
  },
  'another_section' => {
    'key3' => 'value3',
  },
);
```

## Testing

Tests are in `test/t_nmis_config.pl`. They use a temp directory for all config writes (protecting the live system) and in-process cache invalidation (no subprocesses). Run with:

```bash
perl test/t_nmis_config.pl
```
