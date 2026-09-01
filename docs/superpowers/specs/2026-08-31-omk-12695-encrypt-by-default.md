# OMK-12695 — encryption of secrets on by default (combined spec + plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Tonight-mode: three large tasks, one mid review, one final review, Codex `!review` as the PR merge gate.

- **Tickets folded:** OMK-12695 (SEC-1, Blocker), OMK-12713 (SEC-2), OMK-12927 (CLI restore), OMK-12928 (migration-write tests). Epic OMK-12644.
- **Branch:** `sec/OMK-12695-encrypt-by-default` off `origin/nmis9_sec` (14d4aeac). One PR.
- **Worktree:** `/home/md/claude-tmp/nmis9-wt-omk-12695`. Container `nmis9-12695-test` mounts it (mongo reachable; docker exec runs as root).
- **Predecessors:** OMK-12827 Slices A/B/C (all merged): fail-closed crypto, `master_key_file` + `_resolve_seed`, `Node::new` guard, selftest alert, install-time and container key provisioning.

## Spec

### What changes

1. **`bin/nmis-cli`**: restore the commented `disable-eos` / `enable-eos` / `is-eos-available` / `check-eos` dispatches (~lines 311-343), the act docs (~85-100) and help text (~2565-2585). All four Util helpers exist (`isEOSAvailable` 4260, `checkEOS` 4449, `enableEOS`, `disableEOS`). Root gating stays as written.
2. **`lib/NMISNG/Util.pm` warts, now reachable via the restored CLI:**
   - `verifyNMISEncryption` disabled branch: track fields that still carry `!!` after a decrypt attempt (decrypt returned them unchanged); when any remain, log an error naming the count and return 1, so `disableEOS` reports failure instead of "successfully disabled" over ciphertext it could not read.
   - Enabled branch: set `$changed` (and record into `%protected`) only when the encrypt result actually starts `!!` and differs from the stored value, so a crypto failure no longer triggers a pointless config rewrite and a plaintext `NMIS-<epoch>` backup that protects nothing.
   - **Migration-write hazard under env-managed keys (investigate + likely fix):** `decrypt`'s section/keyword up-migration calls `writeConfData`, which croaks when an env-managed property's stored value diverges from the effective one (the guard that bit `t_cgi_config_protected_keys.t` in CI). With encryption default-on, `NMISNG::DB`'s `decrypt(db_password,'database','db_password')` performs that up-migration on every first connect — in CI (which exports `NMIS_DB_*`) a croak here would kill every mongo-backed test and, worse, a production process whose env diverges. Verify the croak path; if reachable, wrap decrypt's two migration `writeConfData` calls (and `getConfDeep`) in `eval` with an error log: the migration is opportunistic, the decrypt result must still be returned. Add a regression test for exactly this (env-managed divergence + up-migration attempt → decrypt returns the plaintext, logs, does not die, config unchanged).
3. **The flip:** `'global_enable_password_encryption' => 'true'` in `conf-default/Config.nmis:60` AND `conf-default/docker/Config.nmis.docker:151`.
   - **Upgrade semantics (verified mechanics, state in register + PR):** every installed config carries an explicit `'false'`; `admin/updateconfig.pl` (hook 10) merges missing keys only, and the docker entrypoint copies `Config.nmis.docker` only when `conf/Config.nmis` is absent. The flip therefore applies to FRESH installs only; existing sites opt in with the restored `enable-eos`.
4. **Register entry** in `docs/security-hardening-register.md`, following the existing `### <ID> / OMK-<n> — title` format: `### SEC-1, SEC-2 / OMK-12695, OMK-12713 — device and config secrets encrypted at rest by default`. Cover: key changed with before/after values and both files; fresh-install scoping and why (upgrade merge mechanics); what operators lose (raw-config/mongo greps now show ciphertext; the master key becomes backup-critical material — name the drill: back up `/usr/local/etc/firstwave` / the `nmis_master_key` volume like `conf/`); recovery/way back (config-gated: `disable-eos` migrates back to plaintext; the flag alone without the CLI does not migrate); mitigation notes per the register's house style.
5. **Tests** (all wired into `ci/scripts/perl_tests.sh`):
   - `test/t_eos_cli.t`: dispatch reachability — running the real `bin/nmis-cli act=enable-eos` and `act=disable-eos` as a NON-root user (in-container: `su -s /bin/bash nmis -c ...`) prints the root-required refusal (proves the dispatch is live, RED against today's commented-out code); help text lists the acts.
   - `test/t_eos_functions.pl` (container, root): function-level enable/disable round trip with `shutdownAllDaemons`/`startAllDaemons` redefined to return 1 and the real `conf/Config.nmis` backed up and restored byte/mode/owner-identically (the CGI-test pattern): `enableEOS` → flag `'true'` in the file and every plaintext `PasswordFields.nmis` field present in the config now `!!`; `disableEOS` → back to plaintext, flag `'false'`. Root-gated with the `t_masterkey_provision.t` precedent (else-branch asserts the non-root refusal path).
   - `test/t_util_migration_writes.t` (OMK-12928): temp key via `NMIS_MASTER_KEY_FILE`; real-config backup/restore; up-migration: flag true (env), `decrypt('plainpw','email','mail_password')` returns the plaintext AND the config file now carries `!!` for that field; down-migration: flag false (separate process/file as needed), `decrypt($cipher,'email','mail_password')` returns plaintext AND the config carries the plaintext. Seed raw-local, drop env-managed keys (the established CI-trap pattern). Plus the env-managed-divergence regression from item 2.
   - `test/t_encrypt_by_default.t`: text assertions that BOTH shipped config files carry `'true'`; a layering assertion that a config context without local override resolves to enabled; at-rest proof reusing the node-guard harness shape WITHOUT forcing the flag env (only `NMIS_MASTER_KEY_FILE` for the key): a node saved with a plaintext community is `!!` in mongo after reload and round-trips (SEC-1); `decrypt` up-migration writes `!!` into the (backed-up) config for a `PasswordFields` entry (SEC-2).
   - **Suite triage:** full suite in the container. The flip changes the default for every test that never set the flag env — triage every new failure: fix tests that ASSUMED disabled-by-default by giving them an explicit `NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION=false` (when the test is about something else) or adapting assertions (when the new default is the point). Watch specifically for the `DB.pm` up-migration side effects on the worktree conf (a container-local key at the default path will be lazily created by root — acceptable inside the throwaway container, but the suite must end with `conf/Config.nmis` restored or consistently decryptable for later runs; document what you observe).

### Non-goals
- Slice E / OMK-12930 (ownership split), OMK-12926/12929 (separate branch), no change to the fail-closed contract, no register entries for the already-merged slices.

### Constraints (binding, all tasks)
- NO code path writes `global_enable_password_encryption` except `enableEOS`/`disableEOS`.
- `encrypt`/`decrypt` keep the input-unchanged failure contract; the migration-write eval (if added) must not change any return value.
- Never log or echo secrets or key material.
- Tests: fail don't skip, except root-gated sections following the `t_masterkey_provision.t` precedent; real-config tests restore bytes+mode+owner on every exit path.
- Commits: `sec: OMK-12695 - <what>` (or `sec: OMK-12927/12928 - ...` for those pieces). NEVER a Co-Authored-By trailer.
- Container tests: `docker exec nmis9-12695-test bash -c 'cd /usr/local/nmis9 && perl test/<file>'`; CI-like env via `-e NMIS_DB_AUTH_SOURCE=admin` where noted.

## Plan

### Task 1 — CLI restore, Util warts, migration hazard, and their tests
Files: `bin/nmis-cli`, `lib/NMISNG/Util.pm`, `test/t_eos_cli.t`, `test/t_eos_functions.pl`, `test/t_util_migration_writes.t`, `ci/scripts/perl_tests.sh`.
TDD: write the three test files first (t_eos_cli.t's dispatch cases RED against the commented code; the wart assertions RED against current Util; the env-divergence regression RED if the croak is confirmed reachable). Then: uncomment the dispatches/help verbatim (adjust only if a helper signature moved), apply the two wart fixes, investigate the writeConfData croak reachability from decrypt's migration and apply the eval wrap if confirmed (report the finding either way). All three tests green in container; also re-run `t_util_crypto_contract.t`, `t_util_crypto_disabled.t`, `t_util_verify_selftest_failclosed.t`, `t_node_secret_guard.pl` (nearby code). Three commits (CLI+its test; warts+their tests; migration tests+hazard fix).

### Task 2 — the flip, default-on tests, register entry, suite triage
Files: `conf-default/Config.nmis`, `conf-default/docker/Config.nmis.docker`, `docs/security-hardening-register.md`, `test/t_encrypt_by_default.t`, `ci/scripts/perl_tests.sh`, plus whatever tests the triage adapts.
TDD: t_encrypt_by_default.t RED first (files still 'false'). Flip both files, write the register entry per the house format (read two neighbouring entries first), wire the test, then the FULL suite in the container with `-e NMIS_DB_AUTH_SOURCE=admin` and triage per the spec. Every triage adaptation is its own small commit with the reason in the message. Known-environmental trio (two `NMIS_TEST_MONGO_URI` BAIL_OUTs + plugin-dir ownership) stays acceptable.

### Task 3 — gate and delivery
Sink/flag-write audits (`git grep` for flag assignments outside enableEOS/disableEOS; no secret in new output), push (CI auto-triggers), PR into `nmis9_sec` titled `sec: OMK-12695 - encryption of secrets on by default (folds OMK-12927, OMK-12928, OMK-12713)`, description covering: the flip + fresh-install-only semantics, the CLI restore, the wart fixes, the migration-hazard finding, the register entry, test evidence, and the follow-ups that remain (Slice E/OMK-12930, OMK-12926/12929 branch). `!review` posted. Jira: comments on OMK-12695, OMK-12713, OMK-12927, OMK-12928 pointing at the PR.
