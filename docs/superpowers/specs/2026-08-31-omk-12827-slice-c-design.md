# OMK-12827 Slice C — the master key survives container recreate

- **Ticket:** OMK-12827 items 6 and 7 (item 7 as amended: file-only, no env value)
- **Epic:** OMK-12644
- **Date:** 2026-08-31
- **Author:** Mark Dueck
- **Scope of this slice:** `compose.yaml`, `conf-default/docker/compose.yaml`, `docker-entrypoint.sh`, tests. Nothing under `lib/` changes.
- **Branch:** `sec/OMK-12827-slice-c` off `origin/nmis9_sec` (post Slice B merge, 8e2b8f54), one pull request into `nmis9_sec`
- **Predecessors:** Slice A (PRs #65/#44), Slice B (PR #73). Specs beside this one.

## Background

The master key lives at `/usr/local/etc/firstwave/master.key`. No shipped
compose file mounts anything covering `/usr/local/etc`, so in a container the
key sits in the writable layer: it survives stop/start but is destroyed by
`--force-recreate`, `compose down`, or an image update, while `conf/` (a named
volume) survives. With encryption enabled that is data loss: a config full of
`!!` values and no key able to read them (ticket item 6). Slice B removed the
old plan's `NMIS_MASTER_KEY` env value (item 7 amendment) and made everything
fail closed, so today the loss is recoverable-if-you-kept-the-key rather than
corrupting, but the key still does not survive.

Slice B also built every piece this slice reuses: `common_masterkey.sh`
(generation, atomic provisioning, ownership postcondition, `nmis_masterkey_owner_ok`),
the `master_key_file` config key with the `NMIS_MASTER_KEY_FILE` path
override, and the dev entrypoint's `provision_master_key` as the model. The
production entrypoint already generates `auth_web_key` at boot because
"containers never run installer_hooks" — the master key follows the same
pattern.

## Goals

- A fresh container install gets a key on first boot with zero configuration,
  and that key survives `--force-recreate`, `compose down`/`up`, and image
  updates.
- An existing key is never touched (the never-rotate rule holds through every
  container lifecycle event).
- The pre-Slice-C upgrade hazard (key stranded in the writable layer while a
  fresh volume gets a new key) is called out loudly at boot and in the docs.
- Operator-supplied keys stay possible and get documented, not built:
  compose `secrets:` plus `NMIS_MASTER_KEY_FILE=/run/secrets/<name>` works
  since Slice B.

## Non-goals

- The dev compose (`docker-dev/`): dev containers self-provision on every
  boot by design and the test suite provisions its own temp keys; no volume.
- The key ownership split (Slice E), the encryption default flip (OMK-12695),
  and the enable-eos CLI restore (OMK-12927).
- Any change to `lib/` or `installer_hooks/`.
- Migration automation that copies a writable-layer key into the volume (the
  population with encryption enabled pre-Slice-C is ~zero; docs + boot
  warning + the existing fail-closed/selftest backstops are the support).

## Locked decisions

1. **Named volume over bind mount or secret.** `nmis_master_key` mapped to
   the directory `/usr/local/etc/firstwave` in both shipped compose files.
   A named volume survives recreate exactly like `conf/` does, needs no host
   path convention, and mounting the directory (not the file) lets the
   entrypoint create the key inside it on first boot. The docker-secret
   route stays an operator option via `NMIS_MASTER_KEY_FILE`, documented in
   the compose comments; it is not the default because it breaks zero-config
   first boot and plain-compose secrets are bind-mounted files anyway.
2. **First-boot generation in the production entrypoint**, using
   `common_masterkey.sh` verbatim (`nmis_masterkey_provision www-data`), the
   same code path as the installer hook and the dev entrypoint, so the three
   consumers cannot drift. Every step is guarded: provisioning failure warns
   and continues (the runtime fails closed and the selftest banner reports),
   it never kills the entrypoint under `set -e`.
3. **Boot warning for the swapped-key case.** When THIS boot created a fresh
   key (the file was absent before provisioning) and `conf/Config.nmis`
   already contains `'!!` values, the entrypoint prints a loud warning: the
   values were encrypted under a previous key, the new key cannot read them,
   and recovery is restoring the previous `master.key` into the volume. The
   check is a small named shell function so it is testable in isolation.
   Limitation, documented in the warning code: the config grep is the cheap
   proxy; encrypted node secrets in Mongo are not visible from shell at boot
   and surface through the "Encryption of secrets" selftest banner instead.

## Changes

### Both compose files (`compose.yaml`, `conf-default/docker/compose.yaml`)

- `nmis_master_key:/usr/local/etc/firstwave` added to the nmis service's
  volume list and to the top-level `volumes:` block.
- Comment block covering: what the volume holds, that destroying it makes
  values encrypted under its key permanently undecryptable (so it must be
  backed up like `conf/`), and the operator-supplied alternative
  (`secrets:` + `NMIS_MASTER_KEY_FILE=/run/secrets/<name>`, leaving the
  generated key unused).
- The two files are siblings, not copies; each gets the edit in its own
  idiom.

### `docker-entrypoint.sh`

- `provision_master_key()`: source `${NMIS_HOME}/installer_hooks/common_masterkey.sh`
  (warn and return 0 if missing), record whether the key file exists before
  provisioning, call `nmis_masterkey_provision www-data`, warn on failure.
  Mirrors the dev entrypoint minus the `DEV_UID` chown. All failure paths
  warn, none exit.
- `master_key_swap_warning()`: when the key was freshly created this boot and
  `conf/Config.nmis` contains a `'!!` value, print the multi-line warning
  with the recovery instruction. Separate function for testability.
- Called from `run()` after `setup` (conf exists) and before `setup_db`.
  Ordering matters: `setup_mongodb.pl` decrypts `db_password` and, since
  Slice B, refuses to run when a `!!` value cannot be decrypted — in the
  swapped-key case the boot warning prints immediately before that refusal,
  so the operator sees the why next to the stop.

### Side effect, documented not changed

`verifyNMISEncryption`'s root-only `0400` plaintext backup files
(`NMIS-<epoch>`, written into the same directory during enable-eos runs) now
persist in the volume instead of the writable layer. Noted in the compose
comment; the enable path is currently unreachable anyway (OMK-12927).

## Testing

1. **Compose content** (new `test/t_compose_master_key.t`, portable): both
   compose files map `nmis_master_key` to `/usr/local/etc/firstwave` on the
   nmis service and declare the named volume. Text-level assertions in the
   style of the existing compose-content tests.
2. **Entrypoint wiring** (same file or sibling): source assertions that
   `run()` calls `provision_master_key`, that `provision_master_key` calls
   `nmis_masterkey_provision`, and that `master_key_swap_warning` is invoked
   after provisioning.
3. **Swap-warning behaviour**: drive `master_key_swap_warning` directly via
   `sh -c` with overridden variables (the `t_masterkey_provision.t` pattern):
   fresh-key flag + a config containing `'!!` → warning text on stderr;
   fresh-key + clean config → silent; existing-key boot + `'!!` config →
   silent.
4. **Container smoke, manual, recorded in the PR**: with the dev image and a
   throwaway named volume, boot the production entrypoint far enough to
   provision (or drive `provision_master_key` standalone in a container with
   the volume mounted): key created `0440 www-data:nmis`; destroy and
   recreate the container with the same volume: key byte-identical; recreate
   with a fresh volume and a `!!`-bearing config: warning printed. Two
   containers on two fresh volumes generate two different keys (the
   no-image-baked-key property).
   Full-entrypoint boots run in CI/production imagery, not from this repo's
   dev container, so the smoke drives the functions with the real volume
   mechanics rather than the whole daemon stack.
5. Drive-by, same PR: `test/t_setup_mongodb_shell.t`'s header comment updated
   (it needs container modules since PR #73) with a legible BAIL_OUT guard on
   its requires.
6. All new tests wired into `ci/scripts/perl_tests.sh`.

## Security-fix gate

Same gate as Slices A and B: sink inventory over the edited files (key
material must never reach compose logs, `docker inspect`, or the entrypoint's
stdout — provisioning already guarantees the value never leaves the
function), drive the changed boot paths, and the `!review` automation on the
PR with the Codex pass treated as the working gate. No hardening-register
entry: a new named volume is additive, no shipped default tightens.

## Verification checklist (mirrors ticket item 6)

- Fresh `compose up`: key exists in the volume, `0440 www-data:nmis`.
- `docker compose down && up`, `--force-recreate`, and an image update all
  leave the key byte-identical.
- A pre-existing key in the volume is never modified by any boot.
- Fresh volume + config carrying `!!` values: boot warning names the swap and
  the recovery; `setup_mongodb.pl` refuses with its own FATAL right after.
- `NMIS_MASTER_KEY_FILE` pointed at a mounted secret is honoured and the
  generated key is ignored (already covered by Slice B seed-resolution tests;
  smoke only).

## Risks

- Compose-file edits must not break existing stacks: adding a volume to a
  running deployment changes nothing until recreate, at which point the fresh
  volume starts empty — that IS the swapped-key upgrade case for the near-zero
  population with encryption already on, handled by the boot warning and docs.
- Docker named volumes copy the image's directory content on first use. The
  production dockerfile does not create `/usr/local/etc/firstwave` (verified:
  no installer hooks run at build, nothing references the path), so the
  volume starts empty and every install generates its own key. If a future
  image build ever baked a key there, the copy-on-first-use would hand ONE
  shared key to every deployment. Guard: a comment at the volume declaration
  naming this rule, and the manual smoke's "two fresh volumes yield two
  different keys" check.
- The nmis image must contain `installer_hooks/common_masterkey.sh` (it ships
  the whole tree, as the dev image does); the entrypoint's missing-lib branch
  warns rather than fails if a stale image lacks it.
