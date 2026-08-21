# OMK-12827 Slice A — stop the encryption control weakening itself

- **Ticket:** OMK-12827 (blocks OMK-12695 / SEC-1 and OMK-12713 / SEC-2)
- **Epic:** OMK-12644
- **Date:** 2026-08-21
- **Author:** Mark Dueck
- **Scope of this slice:** `lib/NMISNG/Util.pm` only
- **Branch:** `sec/OMK-12827-core` off `origin/nmis9_sec`, its own pull request into `nmis9_sec`
- **Related, not included here:** PR #44 on `sec/OMK-12827` carries item 5 (the `cgi-bin/tables.pl` change) and is reviewed and landed separately

## Background

OMK-12827 records nine fix items for the encryption subsystem. This slice takes the three that live entirely in `lib/NMISNG/Util.pm` and form the ticket's stated core defect. The ticket wording is that item 1 "is the core defect and everything else is secondary to it".

Today four branches across three functions react to a missing crypto module, or a failed self-test, by setting `global_enable_password_encryption` to `"false"` and writing the config back to disk. A single read from any process, on any path that touches a secret, can turn the control off and record that decision on disk. A separate latent path in `encrypt` can decrypt a stored value and write the cleartext back into the config.

## Goals

- The crypto layer must never write `global_enable_password_encryption`. On any path.
- The crypto layer must never rewrite a stored encrypted value to cleartext.
- When crypto genuinely cannot run, the affected value fails rather than the system silently downgrading.
- The operator is told what is wrong, and how to fix it, at the point they act, not only in a log file.

## Non-goals for this slice

- Creating the master key at install time (Slice B, items 3 and 4).
- Install-time module detection and reporting (Slice B, item 2).
- `NMIS_MASTER_KEY` and Docker key persistence (Slice C, items 6 and 7).
- Adding the crypto packages to the dev and CI image (Slice D). Done ahead of this slice, see Prerequisite below.
- The key ownership split (Slice E, item 5, mostly deferred already).
- Surfacing a running-daemon crypto failure in the GUI (scenario 2 below, first item of Slice B).

## Prerequisite, completed

The dev and CI image `crg.apkg.io/firstwavecloud/nmis-dev:latest` is built from `docker-dev/dockerfile-dev` and is the image nmis9 CI runs the suite in, via `docker-dev/compose-dev.yaml`. It previously carried none of the crypto modules. PR #61 into `nmis9_dev` added `libcrypt-cbc-perl`, `libcryptx-perl` and `libmath-random-secure-perl` via apt, and `Test::Without::Module` via cpanm. The `release-dev-image` custom pipeline rebuilt and pushed `nmis-dev:latest` on 2026-08-21. Verified against the pulled image, id `sha256:2587d2af…`, all four modules present. This is what lets Slice A's core tests run in CI.

## Locked decisions

1. **Fail closed without destroying data, never by dying.** `decrypt` returns the existing `""` sentinel for a value it cannot decrypt, a read failure that no caller persists. `encrypt` returns the value unchanged, never `""`, because a caller such as `NMISNG::Node::new` assigns `encrypt`'s result straight back to a stored secret and saves it, so `""` would wipe the credential. The value handed to `encrypt` is already plaintext at rest, so returning it unchanged adds no new exposure. Neither path rewrites the flag, and no new `die` is introduced. (The first version of this decision used `""` for both; review found `encrypt`-returns-`""` wipes node secrets through `Node::new`, so `encrypt` returns unchanged instead.)
2. **The loud, human-facing failure lives at the enable boundary.** `verifyNMISEncryption` runs only from `enableEOS` and `disableEOS`, which are root-only admin commands with an operator present that already print to the terminal. That is where we print an actionable message that names the missing packages. `testEncryption` already blocks `enableEOS` when the modules are missing, so the flag cannot be set true through that path.
3. **Scenario 2 is a Slice B follow-up.** If encryption was already on and the modules later disappear under a running daemon, Slice A keeps the system safe (fail closed, no self-disable, no credential wipe) but cannot raise a GUI alert from inside `Util.pm`. Surfacing that needs the `nmisng` and event wiring that lives outside this file.

## Changes

### Item 1 — remove the four self-disable branches

In each branch, delete the `writeConfData` call that sets the flag to `"false"` and the surrounding "Disabling encryption" logic. Keep and sharpen the error logging so it names the three packages (`Crypt::CBC`, `Crypt::Cipher::AES`, `Math::Random::Secure`).

- `verifyNMISEncryption`, module-missing branch, around `Util.pm:4494-4502`. Remove the flag write. Keep the failure return of `1` so `enableEOS` and `disableEOS` still report failure. Print an actionable message naming the packages, since this path has an operator watching.
- `verifyNMISEncryption`, `testEncryption` failure branch, around `Util.pm:4508-4518`. Remove the flag write. Keep the failure return of `1`.
- `decrypt`, module-missing branch, around `Util.pm:4739-4747`. Remove the flag write. See the behaviour table for the return value.
- `encrypt`, module-missing branch, around `Util.pm:4873-4880`. Remove the flag write. See the behaviour table for the return value.

### Item 8 — remove the latent cleartext write-back in `encrypt`

Remove the `!$encryption_enabled && !$force` sub-block inside the already-encrypted (`"!!"`) branch of `encrypt`, around `Util.pm:4898-4916`. That block decrypts a stored value and, when a section and keyword are passed, writes the cleartext back through `writeConfData`. After removal, an already-encrypted value handed to `encrypt` returns unchanged, and `encrypt` never emits cleartext for an encrypted input.

This block is unreachable today because no caller passes a section and keyword to `encrypt`. The removal also changes the return value for `encrypt("!!...", disabled, no force)` from the decrypted plaintext to the `"!!"` value unchanged. That is the safer contract, but it is a behaviour change, so implementation must audit every `encrypt` caller for reliance on the old down-migration return. The down-migration of stored secrets when encryption is disabled is `decrypt`'s job and is not touched here.

### Item 9 — fix the stale comments

Reword the comments that claim `installer_hooks/20-postcopy-user` creates `/usr/local/etc/firstwave/master.key`, at `Util.pm:4473`, `:4752`, `:4886`, and `:4964`. The installer does not create that file today. The comments should state the current reality and point at the Slice B work that will restore install-time creation.

## Behaviour contract

Behaviour when the crypto modules cannot load. "enabled" means `global_enable_password_encryption` is true. `$force` applies to `encrypt` only.

| Function | Condition | Input shape | Old return | New return | Flag write |
| --- | --- | --- | --- | --- | --- |
| `decrypt` | enabled | `"!!"` ciphertext | input, then flag set false | `""` | none |
| `decrypt` | enabled | plaintext | input, then flag set false | input unchanged | none |
| `decrypt` | disabled | any | unchanged from today | unchanged from today | none |
| `encrypt` | enabled or force | plaintext | input, then flag set false when enabled and not force | input unchanged | none |
| `encrypt` | enabled or force | `"!!"` ciphertext | input | input unchanged | none |
| `encrypt` | disabled and not force | any | passthrough or item 8 write-back | passthrough, no write-back | none |
| `verifyNMISEncryption` | enabled, modules missing | n/a | `1`, then flag set false | `1`, prints actionable message | none |
| `verifyNMISEncryption` | enabled, self-test fails | n/a | `1`, then flag set false | `1` | none |

In every row the on-disk value of `global_enable_password_encryption` is unchanged by the call.

`encrypt` returns the value unchanged rather than `""` for the plaintext case because `NMISNG::Node::new` (`lib/NMISNG/Node.pm:105-145`) assigns `encrypt`'s result straight back to each stored device secret and calls `save`, with no guard, so `""` would wipe the credential the first time a node loads with encryption enabled and the modules missing. That unguarded assign-and-save in `Node::new` is a fragility of its own, flagged as a follow-up for a later slice, since Slice A does not touch `Node.pm`.

## Explicitly not touched

- `decrypt`'s own write-back paths at `Util.pm:4770-4781` and `:4820-4834`. These are the config self-migration that OMK-12709 relies on.
- The shipped default of `global_enable_password_encryption`, which stays `false`. Flipping it is OMK-12695.
- Any file outside `lib/NMISNG/Util.pm`.

## Testing

The dev and CI image now carries `Crypt::CBC`, `Crypt::Cipher::AES`, `Math::Random::Secure` and `Test::Without::Module` (see Prerequisite). So the core tests gate in CI, and they no longer depend on the modules being absent.

New test file under `test/`, driving `NMISNG::Util` directly with a throwaway config that sets `global_enable_password_encryption` true through the `NMIS_*` config env override, so nothing on disk is changed.

### Fail-closed tests, the core of item 1, gate in CI

These use `Test::Without::Module` to force the crypto `require` to fail, so they drive the missing-modules branch on demand rather than relying on the environment. That branch returns before any seed is read, so no master key is needed. With encryption enabled and the modules forced absent:

- `decrypt` of a `"!!"` value returns `""`.
- `encrypt` of a plaintext value returns it unchanged, and never `""` (the property that guards the `Node::new` wipe).
- `verifyNMISEncryption` returns failure and its output names the three packages.
- `testEncryption` returns 0.
- After each call, the on-disk `global_enable_password_encryption` is byte-identical to before, and is still `true`.

Fail, never skip. If `Test::Without::Module` is not available, or the modules cannot be forced absent, the test fails with a clear message rather than skipping into a green result.

### Positive round trip and item 8, owed, blocked on a non-root seed

Both need the crypto modules present, which they now are, but both also reach `_make_seed`, which dies for a non-root process (`Util.pm:4971-4974`), and CI runs the suite as `DEV_UID`. So neither can run until a readable master key is provided without root. That is a seed-provisioning change outside `Util.pm`, either a key created for the test user by the dev entrypoint or image, or item 7's `NMIS_MASTER_KEY`. Both belong to Slice B or C.

So in Slice A:

- The positive round trip, a secret encrypts and decrypts back to itself, is an owed test tied to that seed work.
- Item 8's removal ships verified by code review, confirming no caller passes a section and keyword to `encrypt`, plus the caller audit in the security-fix gate. Its behavioural test, that `encrypt` of a `"!!"` value while encryption is disabled returns the value unchanged and writes no config, is owed on the same seed dependency.

Decision: keep Slice A tight. Item 8 is verified by code review and the caller audit, with its behavioural test and the positive round trip owed to Slice B or C, where the seed-provisioning work lives. No seed-provisioning enabler is added in this slice.

## Security-fix gate

This is a security change, so before the pull request:

- Adversarial sink review across every crypto path in `Util.pm`, and an audit of every `encrypt` and `decrypt` caller for reliance on the changed return values, in particular the item 8 down-migration return.
- A review by a different model, treated as the gate, since a same-model review shares the same blind spots.

## Branch and pull request

- Branch `sec/OMK-12827-core` off the current `origin/nmis9_sec`.
- One pull request into `nmis9_sec`.
- Independent of PR #44. That PR is `cgi-bin/tables.pl`, this is `lib/NMISNG/Util.pm`, so the two do not need to be reviewed together.

## Verification checklist, mirroring the ticket

- With encryption enabled and the modules unavailable, a `decrypt` call fails and `global_enable_password_encryption` is still `true` afterwards.
- No code path in `Util.pm` writes `global_enable_password_encryption`.
- `encrypt` never writes cleartext back into the config.
- The enable path reports the missing packages by name.

## Risks

- Removing the item 8 return of plaintext for a disabled `"!!"` input is a behaviour change. Mitigation is the caller audit in the security-fix gate.
- Returning `""` on a write path means a caller could persist `""` for a secret it failed to encrypt. This is a failed write, not a cleartext leak, and it only happens on a misconfigured system where the modules are absent while encryption is enabled, which `enableEOS` already prevents through `testEncryption`.
- There is a pre-existing latent crash if encryption is disabled, the modules are missing, and a leftover `"!!"` value reaches `decrypt`. It is out of scope for this slice and noted for a later one.

## Notes

- Security Hardening Register. This slice changes no shipped default. It does not flip the encryption default, that is OMK-12695. So no register entry is needed for Slice A. The register entry belongs with the slice or ticket that flips the default.
