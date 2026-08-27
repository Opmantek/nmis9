# Fping/dashboard follow-up implementation plan (OMK-12605)

> **Status:** proposed, not yet implemented. Unlike the original 8-task plan this follows, the exact test code below has not been pre-validated against a running implementation — it describes the intended shape and coverage, not verified-correct TAP output. Treat the "Testing" notes as the required coverage, and work out the literal assertions during implementation the same way the original plan's author did before this plan was written.

**Goal:** Node Down and Backup Host Down status documents refresh every `collect()` cycle (not just on fping transitions) and reach the per-node dashboard JSON file, matching the behavior every other event in the base OMK-12605 work already has. Per `docs/superpowers/specs/2026-08-04-omk12605-fping-dashboard-followup-design.md`.

**Architecture:** Inside `pingable()` (`lib/NMISNG/Node.pm`), add an `else` paired with the existing `if ($mustping) { ...handle_down... }` block (lines 2018-2092 as of this plan's anchor commit). When fping owns the up/down decision (`$mustping` false), the event itself is left untouched — but the operational status document is refreshed directly via `NMISNG::Status::save_operational_status`/`close_operational_status`, using data `pingable()` already has in scope. Because this write happens inside `collect()`, the existing `dashnode_context` push mechanism picks it up for free — no change to `bin/nmisd`, no new database query.

## Global Constraints

- Work happens directly on `feature/OMK-12605-operational-status`, no worktree, no container — same setup as the original 8 tasks.
- Booleans via `NMISNG::Util::getbool`.
- Call `NMISNG::Status::save_operational_status`/`close_operational_status` directly — never the full `notify()`/`checkEvent()` — from inside this new step. Event creation/clearing/logging/escalation remain the fping worker's exclusive responsibility; this step must never create or mutate an event record.
- Tests are mongo-backed, same conventions as `test/t_operational_status.pl` (throwaway `t_operational_status_<epoch>` database).
- Commit subjects start with `OMK-12605:`. Never add Co-Authored-By trailers.
- Anchor commit: `f94e4b2d` (tip of the base 8-task work). Locate code by quoted anchor text, not line numbers alone — this plan hasn't been rebased against anything yet, but the same discipline applies since implementation may take more than one sitting.

---

### Task 1: Per-cycle Node Down status refresh

**Files:**
- Modify: `lib/NMISNG/Node.pm` (`sub pingable`, the `if ($mustping)` block at ~line 2018)
- Modify: a test file exercising `pingable()` with `$mustping` false (either extend `test/t_operational_status.pl` or add a dedicated test — decide during implementation based on how much `Sys`/fping-inventory scaffolding the existing test file already has for simulating fresh cached ping data)

**Interfaces:**
- No new public function. The new code is a private step inside `pingable()`.
- Behavior: when `$mustping` is false and `$catchall_data->{nodedown}` is `true`, a `method: Operational` status document for `event: "Node Down"` gets written/refreshed with `status: error`. When `nodedown` is `false`, the document gets refreshed with `status: ok`. Either way, the write happens on every `pingable()` call where `$mustping` is false — not just on a change.

- [ ] **Step 1: Write the failing test**

  Construct a scenario where `pingable()` runs with fresh cached fping data (`$mustping` false) and the catchall's `nodedown` flag already set — assert that after calling `pingable()`, a `method: Operational`, `event: "Node Down"` status document exists with the expected `status`, and that calling it again (state unchanged) refreshes `lastupdate` without duplicating the document (same upsert-identity check pattern already used throughout `test/t_operational_status.pl`). Cover both `nodedown: true` → `error` and `nodedown: false` → `ok`, including the "never been down" case (no prior event, `nodedown` false from the start) producing an `ok` document on the very first call — this is the case that has no equivalent test anywhere yet, since it's exactly the gap this plan closes.

- [ ] **Step 2: Confirm the test fails for the right reason** — no such document should exist yet, since nothing currently writes one from this path.

- [ ] **Step 3: Implement the `else` branch**

  In `lib/NMISNG/Node.pm`, `sub pingable`, locate the closing brace of the existing `if ($mustping) { ... }` block (the one containing the `handle_down` calls, ending around line 2092), and add:

  ```perl
  else
  {
      # fping owns the up/down decision on this cycle; the event itself is
      # untouched (that stays fping's job), but the status document still
      # needs to refresh every cycle regardless of transitions (OMK-12605
      # follow-up). Direct helper calls only, never notify/checkEvent, so
      # event ownership never conflicts with the fping worker.
      NMISNG::Status::save_operational_status(
          nmisng => $self->nmisng,
          node   => $self,
          event  => "Node Down",
          status => NMISNG::Util::getbool($catchall_data->{nodedown}) ? "error" : "ok",
          level  => NMISNG::Util::getbool($catchall_data->{nodedown}) ? undef : "Normal",
      );
  }
  ```

  Note: this sketch omits `details`/`level` refinement for the error case — work out what `level` an fping-detected-but-not-locally-processed Node Down should carry (likely read from the existing event's stored level, similar to how `notify`'s already-exists branch sources values from `$event_obj` rather than raw args) during implementation, rather than hardcoding a guess here. Add `use NMISNG::Status;` near the top of the file if not already present (check first — Task 2/3 of the base work may have already added a `use NMISNG::Status` elsewhere in a different file, not this one).

- [ ] **Step 4: Confirm the test passes.**

- [ ] **Step 5: Guard against regressions** — run `perl test/t_operational_status.pl`, `perl test/t_polling.pl`, and any existing test exercising `pingable()` directly, to confirm the new `else` branch doesn't disturb the `$mustping` true path or the reach-table/RRD values computed right after this block (lines 2094-2096, which run unconditionally and must stay untouched).

- [ ] **Step 6: Commit**

  ```
  git commit -m "OMK-12605: refresh Node Down status doc every collect cycle when fping owns detection"
  ```

---

### Task 2: Per-cycle Backup Host Down status refresh

**Superseded:** the design below (reading `bin/nmisd`'s state derivation directly and tracking a new `$used_backup` variable off the primary/backup ping-result selection) was replaced during implementation — the actual implementation instead reuses Task 1's catchall-flag mechanism, extending `handle_down`'s flag-writing regex to include `backup` so a `backupdown` flag gets piggybacked the same way `nodedown` already is. See the design spec's "Proposed solution" section and commits `6f85fd23`/`c47c6915` for what actually shipped. The original text below is left in place, unedited, so a future reader can see both what was originally planned and what actually happened.

**Files:**
- Modify: `lib/NMISNG/Node.pm` (`sub pingable`, the primary/backup data-selection logic at ~lines 1966-1977, plus the same `else` branch added in Task 1)
- Modify: the same test file as Task 1

**Interfaces:**
- New tracking variable (name TBD during implementation, e.g. `$used_backup`) set alongside the existing overwrite of `$ping_min`/`$ping_avg`/`$ping_max`/`$ping_loss` at lines 1971-1977, since that code currently overwrites those values in place without recording that a switch happened.
- Behavior: when `$mustping` is false and the node is multihomed (`host_backup` configured) and this cycle's cached data indicates use of the backup host, a `method: Operational`, `event: "Backup Host Down"` document gets written/refreshed. Exact status-value mapping (does "using backup successfully" mean `ok` or does it mean something else, and what does "Backup Host Down" mean when the *backup itself* is also unreachable) needs to be pinned down against the existing event semantics in `bin/nmisd`'s `@toclear`/raise logic (`bin/nmisd:3090-3164`) before writing the test — this plan flags the ambiguity rather than guessing at it, since asserting the wrong mapping would be worse than leaving it for implementation to resolve against the existing state machine.

- [ ] **Step 1: Read `bin/nmisd`'s existing backup/failover state derivation first** (the `is_primary`/`has_sibling`/`@toclear` logic around `bin/nmisd:3105-3164`), to confirm exactly which primary/backup ping-result combination maps to `Backup Host Down` being `error` vs `ok`, before writing any test assertions.

- [ ] **Step 2: Write the failing test**, covering: node using primary (event should read `ok` or not exist, per the confirmed mapping), node failed over to backup successfully (per confirmed mapping), and — if it's a real reachable state — backup itself also unreachable.

- [ ] **Step 3: Confirm the test fails for the right reason.**

- [ ] **Step 4: Add the tracking variable and the status write**, following the same direct-helper-call pattern as Task 1 (`save_operational_status`/`close_operational_status`, never `notify`/`checkEvent`).

- [ ] **Step 5: Confirm the test passes.**

- [ ] **Step 6: Guard against regressions**, same suites as Task 1's Step 5.

- [ ] **Step 7: Commit**

  ```
  git commit -m "OMK-12605: refresh Backup Host Down status doc every collect cycle when fping owns detection"
  ```

---

### Task 3: Dashboard-file integration verification and CI wiring

**Files:**
- Modify: the test file used in Tasks 1-2 (add a dashboard-file assertion, same pattern as the base work's Task 7 — set `enable_dashnode_file`, seed `dashnode_context`, call `pingable()` with `$mustping` false and `nodedown` true, assert the dashboard-file entry for `Node Down` exists with the correct shape)
- Modify: `ci/scripts/perl_tests.sh` only if a new dedicated test file was created in Tasks 1-2 rather than extending `test/t_operational_status.pl` (if extended, it's already wired in from the base work's Task 8)

**Interfaces:**
- Consumes: Tasks 1-2's writes; the existing `Status::update_dashnode_data` push mechanism (unchanged, base work).
- Produces: end-to-end proof that a status write from inside `pingable()`'s new branch reaches the dashboard file the same way Interface Down and SNMP Down already do.

- [ ] **Step 1: Write the failing test** proving the dashboard-file entry appears for Node Down (and Backup Host Down) after a `pingable()` call with `$mustping` false, mirroring the base work's Task 7 test shape (`event--element` key, `method: Operational`, correct `status`).

- [ ] **Step 2: Confirm it fails, then passes** once Tasks 1-2 are in place (this task may end up being folded into Tasks 1-2's own test steps rather than staying separate, depending on how the test file is structured by then — decide during implementation).

- [ ] **Step 3: Full regression pass** — `perl test/t_operational_status.pl`, `perl test/t_polling.pl`, `perl test/t_status.pl`, `perl test/t_event.pl`, plus anything else exercising `pingable()` or `collect()`'s reach/RRD computation, since this plan touches a function every single poll cycle runs through.

- [ ] **Step 4: Wire into CI** if a new test file was created (add to `ci/scripts/perl_tests.sh`'s `working_tests` array, same pattern as the base work's Task 8).

- [ ] **Step 5: Commit**

  ```
  git commit -m "OMK-12605: verify Node Down/Backup Host Down reach the dashnode file via the per-cycle refresh"
  ```

---

## Out of scope for this plan (tracked separately)

- The `services`-as-standalone-job dashboard-visibility gap (same underlying pattern, not customer-facing today, needs its own confirmation before a fix is warranted).
- The Events.nmis upgrade-propagation issue (installer/deployment question, unrelated code path, needs its own separate decision).
- Full whole-branch review and PR process — same discipline as the base 8 tasks: task-scoped review after each task here, then one final review before this is merged into the operational-status branch.
