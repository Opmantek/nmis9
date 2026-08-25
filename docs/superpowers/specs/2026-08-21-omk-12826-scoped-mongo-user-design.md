# OMK-12709 + OMK-12826 — a scoped Mongo user for NMIS, via authSource

- **Tickets:** OMK-12826 (shared root identity, `db_password` is also the admin credential) and OMK-12709 (shipped default Mongo password `op42flow42`).
- **Epic:** OMK-12644.
- **Date:** 2026-08-21.
- **Author:** Mark Dueck.
- **Branch:** `sec/OMK-12826-scoped-mongo-user`, base `origin/nmis9_sec`, one pull request into `nmis9_sec`.

## Background

`opUserRW` is not NMIS's user. It is one MongoDB identity shared by NMIS and every other OMK product on the host, on the same server, with the same shipped default password, differing only by database (`nmisng` versus `omk_shared`). Each product ships a `setup_mongodb.pl` that writes its own config's password onto that account, so the products fight over it and the last installer wins. That is why the shipped default is load-bearing and was never changed. On top of that, `setup_mongodb.pl` grants `opUserRW` the `root` role in `admin` and re-grants it every run, and the NMIS runtime authenticates against `admin` (the driver default) so every poll and every CGI page runs as a MongoDB superuser.

Verified in code on this branch:
- `admin/setup_mongodb.pl:282` creates `opUserRW` in `admin` with `root`, re-granted at `:292` every run. It also creates a same-named `dbOwner` user in `nmisng` at `:328`, which the runtime never uses.
- `lib/NMISNG/DB.pm:1032-1057` builds the client args with `username`/`password` but no `db_name`/authSource, so the driver authenticates against `admin`.
- `conf-default/Config.nmis` ships `db_username => 'opUserRW'` and `db_password => 'op42flow42'`.

The original OMK-12709 fix, "generate a random `db_password`", was rejected because rotating the shared credential breaks the other OMK apps. The pivot, agreed with Mark, is that NMIS gets its own scoped user so its password is NMIS-owned and rotatable, and the runtime is downscoped from `root` to `dbOwner` on `nmisng` only.

## Goals

- The NMIS runtime authenticates as a user scoped to the `nmisng` database, never as `root`.
- NMIS owns its runtime credential, so its password is generated per install and can be rotated without touching any other OMK product.
- NMIS stops managing `opUserRW`. It never rotates it, never re-grants `root`, so it can neither be broken by nor break the other OMK apps at runtime.
- The administrative credential used to provision users is separate from the credential the app runs with.
- An install still carrying a shipped default password is reported on every path.

## Non-goals for this change

- Changing the OMK apps (opmojo4 and the rest) to stop sharing `opUserRW`. That spans repositories and is tracked separately.
- Removing `opUserRW` from the host. It stays for the OMK apps and as the default setup-time admin credential.
- Encryption of `db_password` at rest. That is the OMK-12695 / OMK-12827 track. This change writes `db_password` as plaintext, which `decrypt` self-migrates when encryption is later enabled.
- Giving NMIS its own admin-capable identity so setup no longer needs `opUserRW` at all. Recorded as a follow-up. The irreducible bootstrap point is discussed below.

## Locked decisions

1. **New NMIS app user, `opUserRW` kept as the admin bootstrap.** Create `nmisng.<nmisuser>` with `dbOwner` on `nmisng` and a generated password. The running app authenticates as this user against `nmisng` (authSource). `opUserRW` is used by `setup_mongodb.pl` only, to create and refresh that user, and is otherwise left untouched.
2. **The admin credential is separate from the app credential.** `db_username`/`db_password` hold the scoped app account. The admin credential comes from a separate source (see below), so the two can differ.
3. **The authSource switch is phased, not a flag day.** `db_auth_source` absent or empty means authenticate against `admin`, which is today's behaviour. The behaviour changes only after `setup_mongodb.pl` provisions the new user and writes both the new credential and `db_auth_source` into `conf/`. A failed setup never leaves a running install unable to authenticate.
4. **The default-password check is detect-only.** It warns, it never rotates. Reuses the already-written `installer_hooks/common_dbpassword.sh`, reframed for this change.
5. **One branch and pull request** into `nmis9_sec`, implemented as a multi-task plan.

## The new user

- Default `db_username` becomes `nmis9RW` (a name distinct from `opUserRW`; usernames are not secret). Configurable.
- `db_password` is generated per install by `setup_mongodb.pl` and written to `conf/Config.nmis`. `conf-default/Config.nmis` ships a recognizable non-working placeholder, never a valid default.
- The user is created in the `nmisng` database with role `dbOwner` on `nmisng` only, never `root`.
- `dbOwner` on `nmisng` has full access to all existing collections in that database regardless of which identity created them, so no data becomes unreadable after the switch.

## Config changes (`conf-default/Config.nmis`)

- `db_username => 'nmis9RW'`.
- `db_password => '<placeholder>'` (non-working, recognized by the default-password check).
- add `db_auth_source => 'nmisng'`.

`conf-default/` ships these for fresh installs. Existing installs keep their `conf/Config.nmis` untouched until `setup_mongodb.pl` runs, which is what makes the rollout phased.

## Runtime change (`lib/NMISNG/DB.pm`)

In `get_db_connection`, when `$CONF->{db_auth_source}` is set and non-empty, add `db_name => $CONF->{db_auth_source}` to the client args (the driver's authSource). When absent or empty, add nothing, so the driver keeps defaulting to `admin`. The legacy 1.x path already authenticates against `('admin', $db_name)` in turn, so it stays compatible. This is the only runtime code change.

## Setup change (`admin/setup_mongodb.pl`)

- Obtain the **admin** credential from a source separate from `db_username`/`db_password`: the existing interactive prompt (already present at lines 190-243), plus `NMIS_DB_ADMIN_USERNAME` / `NMIS_DB_ADMIN_PASSWORD` for unattended runs, defaulting to `opUserRW` and the current admin password. On a fresh, auth-off Mongo the localhost exception applies and no admin auth is needed to create the first users.
- Authenticate as that admin credential.
- Create or refresh `nmisng.<nmisuser>` (`dbOwner` on `nmisng`). Generate its password using the `/dev/urandom` then `Math::Random::Secure` pattern already used by `common_authkey.sh`. Write the generated password and `db_auth_source=nmisng` and the username into `conf/Config.nmis` via `admin/patch_config.pl`.
- Remove every operation on `opUserRW`: no `createUser`, no `updateUser`, no `grantRolesToUser`, no `root`. Delete the admin-db user block at lines 269-306 that manages `opUserRW`, and the `root` grant.
- If the admin authentication fails, fail loudly and do not touch `conf/`, so a running install stays on its current working credential.
- The `installer_hooks/24-postcopy-setup-mongodb` decline branch must state plainly that database setup is now mandatory.

## Default-password detection (`installer_hooks/common_dbpassword.sh`)

Reuse the existing helper, with its premise updated. It was written for a world where `db_password` was the shared `opUserRW` secret that must never be rotated. Under this change `db_password` is NMIS's own scoped-user secret, generated at setup, so:
- `setup_mongodb.pl` now GENERATES the password, which is the primary fix for OMK-12709.
- The helper drops to a secondary safety net: on every install and container boot, warn when the effective `db_password` is still a shipped default (`op42flow42`, `example`, `password`). It still never rotates.
- Update the helper's header comments so they no longer say "the supported fix is a per-product user, not a rotation" as though rotation is impossible. Under this change NMIS does set its own generated password on its own user.

## Docker and CI path

The dev and CI container authenticates via env, not the config file. `docker-dev/compose-dev.yaml` runs Mongo with `--auth` and passes `NMIS_DB_USERNAME`/`NMIS_DB_PASSWORD`/`NMIS_DB_SERVER` to the `nmis` service, which `_apply_env_overrides` maps onto the config keys. Today it injects the Mongo root user (`root`/`example`).

Under this change the container should provision and use the scoped user:
- `setup_db()` in the entrypoint runs `setup_mongodb.pl`, which, given an admin credential (the compose root user via `NMIS_DB_ADMIN_*`), creates `nmis9RW` and writes the config.
- The `nmis` service env supplies `NMIS_DB_AUTH_SOURCE=nmisng` (mapped to `db_auth_source`) and the scoped app credential, rather than the root user, for the running app.
- The compose root user stays as the admin/bootstrap credential only.

## What each ticket gets

- OMK-12826 defect 1 (runtime as root): fixed. Runtime is `dbOwner` on `nmisng` via authSource.
- OMK-12826 defect 2 (shared identity): fixed for NMIS. NMIS runs as its own user and stops managing `opUserRW`.
- OMK-12826 defect 3 (`db_password` is both app and admin credential): fixed. The app credential is the scoped user, the admin credential is separate.
- OMK-12826 defect 4 (separate the admin credential): done.
- OMK-12826 suggestion 5 (OMK apps side): out of scope, cross-repo follow-up.
- OMK-12709 (shipped default password): fixed. The scoped user gets a generated password, plus the detect-only warning.

## Upgrade path

1. Existing install runs with `opUserRW` against `admin`, `conf/Config.nmis` has no `db_auth_source`. It keeps working unchanged.
2. Operator upgrades and `setup_mongodb.pl` runs. It authenticates as the admin credential (prompted or env, default `opUserRW`), creates `nmis9RW` in `nmisng` with a generated password, and writes `db_username`, `db_password` and `db_auth_source=nmisng` into `conf/Config.nmis`.
3. Daemons restart as part of the upgrade and pick up the new config, authenticating as `nmis9RW` against `nmisng`.
4. `opUserRW` is left exactly as it was. The OMK apps are unaffected.

If step 2 cannot authenticate as admin (for example the OMK apps rotated `opUserRW`), setup reports it and leaves `conf/` unchanged, so the install stays on its current working credential and the operator supplies the current admin password on the next run.

## Testing

- `setup_mongodb.pl` unit or behavioural coverage for: creating the scoped user with `dbOwner` and not `root`, generating and writing the password and `db_auth_source`, and performing no operation on `opUserRW`. Drive against a disposable Mongo in the container.
- `DB.pm` coverage that `db_auth_source` when set adds the `db_name` client arg, and when absent does not (so legacy installs are unchanged).
- `common_dbpassword.sh` coverage for the classify verdicts, mirroring the `common_authkey.sh` tests.
- Verification points from the tickets: host `mongosh` as the app user cannot read `omk_shared` or run `serverStatus`; `usersInfo` shows the NMIS user scoped to `nmisng` with no `root`; re-running `setup_mongodb.pl` does not re-grant `root` and does not touch `opUserRW`.
- Container tests need a Mongo, so they live with the Mongo-backed suite, not the bare unit set.

## Risks

- Locking an operator out of their database if `conf/` and the actual Mongo user drift. Mitigated by the phased `db_auth_source` default and by setup never writing `conf/` unless it successfully created the matching user.
- Fresh-install versus upgrade bootstrap. Fresh installs create users under the localhost exception. Upgrades use the supplied admin credential.
- Getting the Docker env right, since the container path is env-driven and separate from the config file.
- An operator who set a deliberate non-default password must not be nagged. The default set is kept to values actually shipped.

## Out of scope, recorded as follow-ups

- NMIS's own admin-capable identity so setup does not need `opUserRW`. The first creation still needs a privileged bootstrap, so the dependency moves rather than disappears.
- The OMK apps giving up the shared identity on their side.
- Encryption of `db_password` at rest (OMK-12695 / OMK-12827 track).

## Security Hardening Register

This change tightens shipped defaults (`db_username`, `db_password`, the new `db_auth_source`, and dropping the `root` grant), so it needs an entry in `docs/security-hardening-register.md` before the pull request, per the project's maintenance rule. The entry records the keys changed, before and after values, why, the delegated functionality affected, and mitigation or upgrade notes.
