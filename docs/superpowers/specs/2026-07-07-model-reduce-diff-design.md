# Model reduce-to-override tool — design

- Date: 2026-07-07
- Branch: model-reduce-diff (rooted from origin/nmis9_dev)
- Status: approved design, ready for implementation planning

## Background and motivation

NMIS loads device models from `models-custom/`, falling back to `models-default/`.
When a site needs a small change to a shipped model, the common practice has been
to copy the whole default file into `models-custom/` and edit it. That full copy
then fully shadows the default, so two problems follow:

1. The customer ends up maintaining a large file to hold a few changes, which is
   hard to reason about.
2. Because the copy shadows the default completely, later NMIS upgrades that add
   sections to the default never reach that model. The copy silently freezes an
   old version.

NMIS already supports a lighter mechanism. `NMISNG::Sys::loadModel` auto-discovers
`Override-Model-<name>.nmis` and `Override-Common-<feature>.nmis` in `models-custom/`
and deep-merges them onto the base file loaded from `models-default/`. No config
change is needed. This tool automates converting a full copy into that small
override, but only when it can prove the result compiles to the same model.

## What already exists (research summary)

- No tool anywhere generates override files. The reduction is currently a manual
  process documented in `docs/model-loading.md` (run `compare_models.pl`, then
  hand-write each `Override-*.nmis`). An external web search found no equivalent.
- Reusable building blocks in the codebase:
  - `admin/diffconfigs.pl` — a genuine structure-level diff, but print-only, and
    its element-wise array handling is wrong for override semantics (see below).
  - `admin/compare_models.pl` — pairs custom files with default files.
  - `NMISNG::Util::writeHashtoFile` — the canonical `.nmis` writer (Data::Dumper
    format).
  - `NMISNG::Util::readFiletoHash` / `getModelFile` — the model readers.
  - `NMISNG::Sys::_mergeHash` — the exact merge the reduction must invert.
  - `test/t_model_overrides.pl` — a working, node-free, MongoDB-free way to drive
    the real loader against temporary model directories. The verification step
    reuses this setup directly.

## Constraints the design must respect

These come from reading `NMISNG::Sys::loadModel` and `_mergeHash`.

- The merge only adds keys or overwrites values. It has no delete verb. An
  override can never remove a key that the base defines.
- Arrays are replaced wholesale, not merged element by element.
- A hash cannot be merged over a scalar in the dest (base). If the base has a key
  as a hash and the override supplies a scalar for it, the merge fails.
- Override discovery covers only `Override-Model-<name>` and
  `Override-Common-<feature>` (plus a config-listed `global_model_overrides`).
  There is no override path for graph files.
- A full custom copy shadows the default, so only custom files that have a default
  counterpart are reduction candidates.
- The model cache tracks override mtimes in a sidecar and self-invalidates.
- The tool runs on a customer NMIS server. There is no git repository and no
  history of `models-default` available there. The original default version a
  copy was based on cannot be recovered at runtime.

## Goals

- Convert full custom copies to small overrides where the compiled model stays
  byte-identical, verified by the real loader.
- Remove copies that are already identical to the current default.
- Surface, without changing them, the copies that have drifted from a newer
  default (the upgrade-drift case), with enough detail to act on by hand.
- Be safe by default: read-only unless explicitly told to apply, back up before
  removing, never guess about intent.

## Non-goals

- No changes to NMIS core code.
- No override path for graph files.
- No automatic rebasing of drifted copies onto a newer default. That would
  require the original ancestor version (not available without git) or guessing
  which differences are the user's versus the upgrade's. Both are rejected.
- No 3-way / git-based ancestor recovery.

## Why byte-identical reduction sidesteps the intent question

For a byte-identical reduction it does not matter whether a difference came from
a user edit or from an upgrade. The override captures whatever makes the current
model differ from the default, and the compiled result reproduces the current
behaviour exactly. The only thing that ever blocks a byte-identical reduction is
a drop, because the merge cannot delete a key from the base. This is what lets
the tool avoid guessing.

## Components

- `admin/reduce_model.pl` — thin CLI. Parses arguments, resolves directories,
  orchestrates, prints the report, performs the apply step.
- `lib/NMISNG/ModelReduce.pm` — the testable logic:
  - `semantic_diff($default_hash, $custom_hash)` — returns a classified diff of
    added keys, changed leaves, replaced arrays, drops, and type conflicts.
  - `build_override($diff)` — builds the override hashref from the representable
    parts (adds, changed leaves, replaced arrays), or reports it cannot.
  - `classify($diff)` — returns `identical`, `reducible`, or `drift`.
  - `verify($model_name, $target_dirs, $proposed_state)` — drives the real
    `NMISNG::Sys::loadModel` in temporary directories both ways and deep-compares
    the merged models. Returns pass or fail with the differing paths.

Keeping the logic in a module lets `test/t_reduce_model.pl` unit-test the diff and
classification without running the CLI.

## Command-line arguments

Follows the `model_tool.pl` `key=value` style.

- `dir=` — target `models-custom` directory. Default: config-resolved
  `<nmis_models>`.
- `default_dir=` — default models directory. Default: config-resolved
  `<nmis_default_models>`.
- `model=` — limit the run to a single file (for example `Model-CiscoRouter`).
- `scratch=` — output directory for proposed and manual-start overrides in a
  dry run. Default: a timestamped directory under the system tmp path.
- `apply=1` — perform the destructive changes. Absent or `0` means dry run.
- `verbose=1` — include the full per-file diff detail in the report.

## Data flow

1. Resolve `dir` and `default_dir` from arguments or config.
2. Enumerate `*.nmis` in `dir`. Categorise by prefix and by whether a default
   counterpart exists.
3. For each `Model-*` or `Common-*` candidate with a default counterpart:
   a. Read both files to hashes with `readFiletoHash`.
   b. Compute the semantic diff and classify.
   c. `identical` — mark for removal.
   d. `reducible` — build the override, verify byte-identical with the real
      loader. On pass, mark for reduce. On fail, downgrade to a reported problem
      and keep the copy.
   e. `drift` — write a marked, unverified manual-start override to the scratch
      directory and record which upstream additions the copy is masking.
4. Produce the report. Always write manual-start overrides for drift files to the
   scratch directory, in both modes, since they are never applied. In a dry run,
   also write the proposed overrides for reducible files to the scratch directory
   so they can be inspected before an apply.
5. If `apply=1`, summarise, ask for confirmation, then for verified identical and
   reducible files only:
   - back up the copy to a timestamped backup directory,
   - write the override into `dir` (reducible files only),
   - remove the copy,
   - after all files, clear the affected model cache entries.
   Drift files are never touched by apply.

## Diff rules

- Walk both structures by key.
- Both values are hashes: recurse.
- Key present in custom only: an add. Representable.
- Key present in both, values differ, both scalars or arrays: a change.
  Representable. Arrays are treated atomically, so the whole custom array is
  carried.
- Key present in default only: a drop. Not representable. Marks the file as
  `drift`.
- Type conflict where the default value is a hash and the custom value is not:
  not representable. Marks the file as `drift` with a type-conflict note.

Note the difference from `admin/diffconfigs.pl`, which compares arrays element by
element. That logic is not reused, because the override merge replaces arrays
wholesale.

## Verification

Reuses the approach proven in `test/t_model_overrides.pl`.

1. Clone the live config. Repoint `<nmis_models>`, `<nmis_default_models>`, and
   `<nmis_var>` at temporary directories. Turn persistent model caching off for
   the check so nothing touches the live cache.
2. Build a minimal nmisng-like object that provides only a logger, as the test
   does.
3. Compile the model in the before state (copy present) and the after state
   (copy removed, proposed override present) by calling the real
   `NMISNG::Sys::loadModel`, then deep-compare the two merged `$sys->{mdl}`
   structures.
4. For a `Common-*` file, find every model that references it by scanning
   `-common-/class/*/common-model` across both directories, compile each in the
   before and after states, and require every one to match. If nothing references
   it, report it as unused and skip.

A file is eligible to change only if this check passes. If the diff classified a
file as reducible but the compile disagrees, the compile wins and the file is
kept and reported. This needs no git, no MongoDB, and no SNMP.

### Multiple files in one run

Each candidate is verified against the current on-disk state of every other file.
Because every accepted reduction leaves the compiled model unchanged, applying
several of them in sequence also leaves the compiled model unchanged, so per-file
verification is sound even when a run reduces both a `Common-*` file and a model
that references it. As a final guard, the apply step recompiles every affected
model once more after all changes are on disk and compares against a snapshot
taken before apply. Any mismatch stops the run and is reported, though the
per-file reasoning means this should never fire.

## Apply path and safety

- Dry run is the default. Nothing under `dir` changes without `apply=1`.
- Apply processes only verified identical and reducible files.
- Each removal is preceded by a successful backup to a timestamped directory
  (for example `<dir>/.reduce-backup-<timestamp>/`). A failed backup aborts that
  file.
- Overrides are written with `writeHashtoFile` and sorted keys for stable output.
- After all changes, the affected model cache entries are cleared so the next
  poll rebuilds cleanly.
- The apply step prints a summary of what it will change and asks for
  confirmation before the destructive part.

## Error handling

- Unparseable `.nmis` file: skip, report, never remove.
- Merge error during override build or verification: keep the copy, report.
- Verification mismatch: keep the copy, report the differing paths.
- Backup failure: do not remove that file.

## Expected behaviour on the dev-server sample

The sample from a dev server has 57 files: 26 graph (skipped, reported), 12
genuine custom Model/Common with no default (skipped), and 19 candidates. On the
current default the 19 split into:

- 6 identical (copy redundant, removed on apply),
- 6 reducible (override written, copy removed on apply),
- 7 drift (kept, reported; the drops are almost all the upstream
  `-common-/class/IP-FORWARD` addition, plus cbqos, lldp, systemHealth).

The tests assert this split and that every applied result compiles identically.

## Testing

- `test/t_reduce_model.pl`:
  - unit tests for `semantic_diff`, `classify`, and `build_override`,
  - integration tests over temporary default and custom directories, covering
    identical, pure-add, changed-leaf, array-replace, drop then drift,
    hash-to-scalar then drift, a Common referenced by more than one model, a
    graph skipped, and a no-default file skipped,
  - a fixture built from the dev-server sample that asserts the 6 / 6 / 7 split
    and that applied results compile identically.

## Documentation to update

- `CLAUDE.md` — add the tool to the `admin/` list.
- `docs/CLI_TOOLS.md` — add full arguments and examples.
- `docs/model-loading.md` — replace or extend the manual-process note with a
  pointer to the tool.

## Open assumptions

- The customer install has a working `conf/` so the config clone and the loader
  work. This holds on any real NMIS server.
- `mtime` is treated only as a soft hint in the report (a newer default suggests
  upgrade drift), never as an input to any decision, because copy and rsync
  operations do not preserve it reliably.
