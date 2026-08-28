# OMK-12827 Slice B — deliverable key management and wipe-proof crypto

- **Ticket:** OMK-12827 (blocks OMK-12695 / SEC-1 and OMK-12713 / SEC-2)
- **Epic:** OMK-12644
- **Date:** 2026-08-28
- **Author:** Mark Dueck
- **Scope of this slice:** `lib/NMISNG/Util.pm`, `lib/NMISNG/Node.pm`, `installer_hooks/`, `docker-dev/` (dev/CI entrypoint only), `conf-default/Config.nmis`, tests
- **Branch:** `sec/OMK-12827-slice-b` off `origin/nmis9_sec`, one pull request into `nmis9_sec`
- **Predecessor:** Slice A (PRs #65 and #44, merged). Spec: `2026-08-21-omk-12827-slice-a-design.md`

## Background

Slice A stopped the encryption control weakening itself: no self-disable, no
flag writes, fail closed without wiping on the missing-modules path. It left
four things open, plus two ticket items, plus one item this slice pulls
forward in amended form:

- **Item 2:** install-time crypto module detection and reporting.
- **Items 3 and 4:** the master key is never created at install. The installer
  creates `/usr/local/etc/opmantek/seed.txt` (which nothing reads) with core
  `rand()`, while the file NMIS reads, `/usr/local/etc/firstwave/master.key`,
  is created only lazily by `_make_seed`, which dies for non-root.
- **The residual wipe paths.** `encrypt` still returns `""` on a seed-open or
  cipher failure with the modules present, and `decrypt` still returns `""`
  on a cipher error, corrupt payload, or unreadable key. `Node::new`
  (`lib/NMISNG/Node.pm:111-182`) assigns those results straight back to the
  six device secrets and saves, unguarded. `cgi-bin/tables.pl:941` and
  `cgi-bin/config.pl:688` encrypt-then-persist operator-typed values.
- **Scenario 2:** a running-daemon crypto failure is invisible in the GUI.
- **The latent decrypt crash:** encryption disabled, modules missing, and a
  leftover `!!` value falls past the fail-closed branch into
  `_make_seed`/`Crypt::CBC->new` and dies.
- **Item 7, amended (decision 2 below):** the ticket asked for a
  `NMIS_MASTER_KEY` environment value. This slice replaces that with a
  configurable key **file** location. The ticket gets an amending comment
  when the PR opens.

## Goals

- A fresh install has a usable master key before any non-root process needs one.
- A missing or unreadable key, or missing modules, produces a logged, fail-closed
  error and a GUI-visible selftest failure. Never a `die`, never a wiped secret,
  never a flag write.
- `encrypt` and `decrypt` never return `""` for a value they were given.
- The key file location is configurable for sites with their own conventions.
- The two tests Slice A owed (positive round trip, item 8 behaviour) run in CI.

## Non-goals

- Production Docker compose wiring and entrypoint key provisioning (Slice C,
  now file-shaped: mount or volume covering the key path, entrypoint generates
  on first boot via `common_masterkey.sh`).
- The key ownership split (Slice E, item 5).
- Flipping `global_enable_password_encryption` (OMK-12695), and the
  security-hardening-register entry that belongs with that flip.
- Re-encrypting existing values when the key path changes.

## Locked decisions

1. **Contract hardening over per-caller guards.** `encrypt` and `decrypt`
   return their input unchanged on *every* failure path, never `""`:
   missing modules (both flag states), unreadable or absent key, seed-open
   failure, cipher error, corrupt payload. This extends Slice A's
   missing-modules decision to the whole failure surface, so every
   assign-and-save caller, present and future, is wipe-proof by construction.
   Rationale: the caller inventory found four persist-capable sites
   (`Node::new` both directions, `tables.pl:941`, `config.pl:688`,
   `verifyNMISEncryption`) and per-site guards would leave the hazard live in
   the API for the next caller. Read-only callers (Snmp, DB, Auth, mail,
   support tools) fail auth identically on a `!!` value as on `""`, so reads
   stay fail closed.
2. **File-only key, no `NMIS_MASTER_KEY` environment value.** An env var is
   inherited by every child process (`Util.pm` alone has 32 `system()` sites,
   plus plugins, notification backends, and operator-configured commands),
   appears in `docker inspect` and compose files, and has no permission model.
   A key file has none of those exposures, and the container problem item 7
   was solving is solved better by mounting the key path (zero runtime code)
   with the entrypoint generating on first boot. `admin/support.pl` was
   checked and does not capture the environment, keep it that way.
   The `_FILE` indirection convention (`NMIS_MASTER_KEY_FILE` as an env var)
   arrives for free because the path is a config key (decision 3), and a path
   is not a secret.
3. **Configurable path, fixed creation.** New config key `master_key_file`,
   default `/usr/local/etc/firstwave/master.key` in `conf-default/Config.nmis`.
   NMIS only ever *creates* a key at the shipped default path (`_make_seed`,
   the installer hook, the dev/CI entrypoint). A custom path is read-only to
   us: never created, never chowned or chmodded. Missing or unreadable means
   fail closed with an actionable error and a selftest failure. This kills the
   root-symlink-clobber attack (a config writer pointing the path at a
   symlink a root process would later follow on create) and keeps the
   never-rotate/never-relocate rule intact for the default path.
4. **The GUI alert is a selftest check.** `NMISNG::Util::selftest`
   (`Util.pm:2769`) gains one test: when encryption is enabled, run
   `testEncryption()` and report failure. `nmisd` already schedules selftest
   and the GUI banner already displays failures from `var/nmis_system/selftest.json`.
   One alert for the whole system. `Node::new` guard trips log errors but
   raise no per-node events (a fleet-wide crypto outage must not raise one
   event per node, and `Node::new` runs in every process including CGI).
5. **No hardening-register entry for this slice.** Nothing here tightens a
   shipped default with a delegated-functionality cost. The register entry
   ships with OMK-12695.

## Changes

### `lib/NMISNG/Util.pm`

1. **Failure contract.** Every failure path in `encrypt` and `decrypt`
   logs an actionable error and returns the input unchanged. `decrypt`
   currently strips the `!!` prefix and overwrites `$password` during
   processing, so it must retain the original input for the failure returns.
   The missing-modules branch in `decrypt` returns unchanged in *both* flag
   states, which fixes the latent crash (disabled + `!!` + missing modules
   currently falls through to `_make_seed`/`Crypt::CBC->new` and dies).
2. **Seed resolution helper.** One private helper used by `encrypt`,
   `decrypt`, and `verifyNMISEncryption`, replacing the three inline
   hardcoded-path reads. Resolution:
   - configured `master_key_file` (default when unset) readable → validate
     permissions, read it
   - file absent **and** path is the shipped default **and** process is root
     → `_make_seed` (unchanged), then read
   - anything else → return undef; the caller logs the path and fails closed
   Permission validation before use: reject a group- or world-writable key
   file outright (fail closed), warn loudly on a world-readable one
   (OMK-12696 `_config_perms_error` precedent). Warn when the configured path
   sits under `<nmis_base>` or `<nmis_conf>`, because `configbackup` would
   archive the key beside the config it protects.
   This removes the item-3 outage: a non-root process (Apache CGI, the
   daemon) touching a secret with no key present gets a logged failure
   instead of `_make_seed`'s `die`.
3. **Selftest check.** When `global_enable_password_encryption` is true,
   `selftest` runs `testEncryption()` and reports a failure entry (for
   example "Encryption self-test failed - secrets cannot be protected").
   The contract change makes `testEncryption` safe non-root: no key means
   `encrypt` fails closed and the self-test reports failure instead of dying.
4. **Comments.** The four "the installer does NOT create this file today"
   comments (`verifyNMISEncryption`, `decrypt`, `encrypt`, `_make_seed`)
   rewritten to describe the new reality: installer hook 21 creates the
   default-path key, `master_key_file` configures the location, custom paths
   are operator-provisioned.

Not touched: `decrypt`'s config self-migration write-backs (OMK-12709 relies
on them), `_make_seed`'s root check and ownership model (Slice E), and the
plaintext password backup `verifyNMISEncryption` writes to the default
directory during enable (pre-existing, root-only 0400, stays at the default
directory regardless of `master_key_file`).

### `lib/NMISNG/Node.pm`

**Write-path guard in `new`.** Encrypt branch: assign-and-dirty only when the
result starts `!!`. Decrypt branch: assign-and-dirty only when the result no
longer starts `!!`. A failed conversion leaves the stored value untouched,
skips the save for that field, and logs an error naming the node and field.
Belt-and-braces on top of decision 1: it prevents pointless saves and gives
per-node diagnostics.

### Installer

1. **New hook `installer_hooks/21-postcopy-encryption`.**
   - Module detection (item 2): `perl -e 'require ...'` for `Crypt::CBC`,
     `Crypt::Cipher::AES`, `Math::Random::Secure`. On any missing, a clear
     non-aborting report naming Debian (`libcrypt-cbc-perl libcryptx-perl
     libmath-random-secure-perl`) and RedHat (`perl-Crypt-CBC perl-CryptX
     perl-Math-Random-Secure`) packages, stating encryption of secrets cannot
     run until installed. Runs after `30-pre-dependencies` has attempted
     package installs, so it sees the final state. `echolog` output reaches
     the install log under `UNATTENDED`.
   - Key creation (items 3 and 4): default path only, only if absent,
     256-char `[A-Za-z0-9]` from `/dev/urandom` with rejection sampling
     (the `generate_random_password` approach), fallback to
     `Math::Random::Secure` (the `nmis_authkey_generate` pattern). Both
     failing reports and continues. xtrace suppressed around generation.
     `SIMULATE` reports and changes nothing (hook 11 is the model).
     Ownership `webgrp:nmis`, file `0440`, directory `0770`, matching
     `_make_seed`. An existing key is never touched. A custom configured
     path is never created or modified here.
2. **`installer_hooks/20-postcopy-user`** loses its encryption block: stop
   creating `/usr/local/etc/opmantek/seed.txt` (existing copies left alone,
   per ticket item 4). The hook returns to users and permissions only.
3. **`installer_hooks/common_masterkey.sh`** holds the generation and
   provisioning functions, shared with the Slice C production entrypoint so
   the two cannot drift (`common_authkey.sh` precedent).
4. **dev/CI entrypoint** (`docker-dev/`) provisions a default-path key at
   container start, readable by the `DEV_UID` test user. This unblocks the
   owed tests in CI. Dev-image-only behaviour, not production.

### `conf-default/Config.nmis`

New key `master_key_file`, default `/usr/local/etc/firstwave/master.key`,
with a comment stating the creation rule (custom paths are
operator-provisioned, changing the path never re-encrypts existing values).
Existing installs inherit the default through the conf-default layer.
`NMIS_MASTER_KEY_FILE` works through the existing env override mechanism.

## Behaviour contract

"enabled" means `global_enable_password_encryption` is true. In every row the
flag is never written and the stored value is never wiped.

| Function | Condition | Input | Return |
| --- | --- | --- | --- |
| `decrypt` | modules missing, either flag state | any | input unchanged (fixes the latent crash) |
| `decrypt` | key missing/unreadable/rejected | `!!` value | input unchanged, error logged |
| `decrypt` | cipher error or corrupt payload | `!!` value | input unchanged, error logged |
| `encrypt` | modules missing (enabled or force; disabled returns early today, unchanged) | plaintext | input unchanged |
| `encrypt` | enabled or force, key missing/unreadable/rejected | plaintext | input unchanged, error logged |
| `encrypt` | enabled or force, cipher error | plaintext | input unchanged, error logged |
| `encrypt` | any | `!!` value | input unchanged (Slice A item 8, unchanged) |
| `Node::new` | conversion failed either direction | six secrets | stored value untouched, no save, logged |
| `selftest` | enabled and `testEncryption` fails | n/a | failure entry in selftest.json, GUI banner |

## Security considerations of the configurable path

1. **Root symlink clobber via lazy creation:** killed by decision 3 (create
   at the shipped default path only, installer included).
2. **Key substitution / file-as-key oracle via config write:** whoever can
   write config can repoint the path. Not a new class (a config writer can
   already flip the flag off and let `Node::new` migrate secrets back to
   plaintext), but the path widens it slightly. Mitigations: permission
   validation before use, fail closed everywhere, config editing is
   admin-only under OMK-12707. Residual risk accepted and stated here.
3. **Key bundled into backups:** warn when the path sits under the NMIS tree.
   Warning, not refusal.
4. **Path changed after secrets exist:** old ciphertexts stop decrypting,
   fail closed, nothing wiped, reverting the path restores everything.
   Documented in the config comment.
5. During implementation, check whether `config.pl` has an existing mechanism
   to exclude specific keys from GUI editing. If one exists, exclude
   `master_key_file`. If not, do not invent one in this slice.

## Testing

New test files under `test/`. Fail-closed tests fail rather than skip.

1. **Fail-closed contract (gates in CI, no key needed).**
   `Test::Without::Module` forces the modules absent: `encrypt`/`decrypt`
   return input unchanged in both flag states, including disabled + `!!` +
   missing modules (no die). Flag byte-identical on disk after every call.
2. **Owed Slice A tests.** Positive round trip (encrypt → `!!` → decrypt →
   original) and item 8 behaviour (encrypt of `!!` while disabled returns it
   unchanged, writes nothing). Skip with a message on a keyless bare host,
   always run in the container (entrypoint provisions the key).
3. **Cipher-failure contract.** Valid key: decrypt of `!!` garbage and of a
   tampered payload returns input unchanged, never `""`.
4. **`Node::new` guard (mongo-backed).** Enabled + modules absent → stored
   secrets unchanged in Mongo. Disabled + undecryptable `!!` value →
   unchanged. Enabled + working crypto → secrets migrate to `!!` and
   round-trip through `decrypt`.
5. **Selftest.** Enabled + modules absent → crypto failure entry present.
   Enabled + working key → passes. Disabled → no crypto check.
6. **Seed helper.** Custom path missing → fail closed, nothing created.
   Group- or world-writable key file → rejected. Path under the NMIS tree →
   warns.
7. **Installer generation snippet** asserted for length and charset via `sh -c`
   in a portable test. The hook itself verified manually in the dev container
   (SIMULATE and real, fresh install and existing-key runs), documented in
   the PR.

## Security-fix gate

Credential-at-rest change, so before the pull request:

- Exhaustive sink inventory over every edited file.
- Drive every consumer of the changed contract: `tables.pl:941`,
  `config.pl:688`, `Node.pm` both branches, `Snmp`/`DB`/`Auth` read paths,
  `verifyNMISEncryption`, `testEncryption`.
- A non-Claude review (the `!review` Codex pass) as the merge gate. Codex
  caught the only Critical in this track so far.
- Human security pass before a release branch, per the author's stated gate.

## Branch and pull request

- `sec/OMK-12827-slice-b` off `origin/nmis9_sec`, one PR into `nmis9_sec`.
  The pieces are coupled (contract → guard → selftest → tests), one PR
  reviews better than fragments. Commits stay small and step-shaped.
- A push triggers CI. Never also API-trigger (single-runner collision).
- When the PR opens, comment on OMK-12827 recording the item-7 amendment:
  file-only, env value rejected (child-process inheritance, `docker inspect`,
  no permission model), configurable `master_key_file` added, creation fixed
  to the default path.

## Verification checklist

- A fresh install creates `master.key` at the default path before any
  non-root process needs it, and no longer creates `seed.txt`.
- Generated key material comes from `/dev/urandom`, never core `rand()`.
- An upgrade over an existing `master.key` leaves it byte-identical and
  previously encrypted values still decrypt.
- An offline install completes and reports missing packages by name.
- With encryption enabled and the modules or key unavailable: every crypto
  call fails closed, the flag is unchanged on disk, no stored secret changes,
  and the GUI selftest banner shows the failure.
- `encrypt` and `decrypt` never return `""` for a non-empty input.
- A custom `master_key_file` is honoured for reads and never created,
  chowned, or chmodded by any NMIS code path.

## Risks

- The contract change is visible to every caller, mitigated by the caller
  audit in the security-fix gate (the inventory found no caller relying on
  `""` failure returns; `testEncryption` detects failure by the missing `!!`
  prefix, which input-unchanged satisfies).
- Non-root processes no longer trigger lazy key creation. A pre-Slice-B
  upgrade that never had a key now fails closed (logged, selftest-visible)
  instead of dying, until root runs the installer hook, `enableEOS`, or any
  root process touches a secret. Strictly better than the current outage,
  called out for release notes.
- The dev-entrypoint key provisioning is dev-image behaviour that production
  must not inherit. Kept in `docker-dev/` only.
