# MongoDB scoped-user change (OMK-12826 / OMK-12709) — developer upgrade notes

This explains what changes for a developer or operator when this work lands, what
happens on a pull to a running system, and how the Docker and Makefile paths
behave. It covers the scoped MongoDB user, the dropped default password, the
fresh-install admin provisioning, and the forgotten-password recovery command.

## What changed

NMIS no longer uses the shared MongoDB root identity and no longer ships a working
default database password.

- NMIS gets its own scoped user `nmis9RW`, owner of the `nmisng` database only,
  never root, authenticated through a new `db_auth_source` config key.
- The old shared `opUserRW` / `op42flow42` identity is left untouched. NMIS no
  longer creates, rotates, or grants root to it.
- `conf-default` ships a placeholder password. `setup_mongodb.pl` generates a
  random one when the effective value is still a shipped default.
- On a fresh host with a no-auth MongoDB, `setup_mongodb.pl` provisions a separate
  admin user (`nmis9admin`) with a generated password, records it root-only in
  `/usr/local/etc/firstwave/mongodb-admin-password`, and enables authentication.
- New recovery command for a forgotten admin password,
  `setup_mongodb.pl resetadminpw=1`.
- `lib/NMISNG/DB.pm` now requires the 2.x MongoDB Perl driver.

## A plain `git pull` on a running system

Nothing changes at runtime from the pull alone, with one exception.

- `conf/` is gitignored, so a pull does not touch `conf/Config.nmis`. Existing
  site settings are safe. A system on `opUserRW` / `op42flow42` keeps
  authenticating exactly as before, because its `conf/Config.nmis` still says so
  and `db_auth_source` is absent, so the driver keeps defaulting to `admin`, which
  is the old behaviour.
- The one exception is the driver floor. If a bare-host system has only a 1.x
  MongoDB Perl driver, NMIS will fail at load after the pull, because
  `lib/NMISNG/DB.pm` now does `use MongoDB 2.0.0`. The dev container already
  carries a 2.x driver, so container users are unaffected. A 1.x driver cannot
  talk to MongoDB 7.0 in any case. Tracked for the installer as OMK-12924.

The migration to the scoped user happens only when `setup_mongodb.pl` actually
runs, not on a pull.

## Do you lose your Mongo settings if you use the defaults?

No. Nothing is removed. The config is migrated forward the next time
`setup_mongodb.pl` runs.

- Against a config still using the old defaults, setup maps `db_username` from
  `opUserRW` (or empty) to `nmis9RW`, creates that scoped user in `nmisng`, writes
  `db_username=nmis9RW` and `db_auth_source=nmisng` into `conf/Config.nmis`, and
  generates a random `db_password` because `op42flow42` is a shipped default.
- The old `opUserRW` user is left in place in MongoDB. The migration is additive,
  not a delete.
- Re-running is idempotent and never touches `opUserRW`.

So a bare-host system loses nothing on a pull. It migrates to the scoped user only
when you next run the installer or run `admin/setup_mongodb.pl` by hand.

## NMIS Docker

The dev entrypoint runs `setup_mongodb.pl` on every container start, so a
docker-dev system migrates on its next `up`.

- `docker-dev/.env-dev` and the compose files are tracked, so a pull updates them.
  A system that customised `.env-dev` locally will need to merge.
- The compose files run NMIS as `nmis9RW`, keep the admin credential separate from
  the app credential, and give the app its own password. In dev, `.env-dev` ships
  two fixed working values, `MONGODB_PASSWORD=nmis9devMongoRW` for the mongo
  root/admin and a new `MONGODB_APP_PASSWORD=nmis9devAppRW` for the scoped app
  user.
- A fresh dev stack, meaning a new mongo volume, comes up turnkey with these
  values.
- Watch this on an existing dev mongo volume. `MONGO_INITDB` only sets the root
  password on an empty volume, so an existing volume still holds whatever root
  password it had at first start. The entrypoint's setup authenticates as admin
  using `MONGODB_PASSWORD` from `.env-dev`, so if that value differs from the
  volume's actual root password, admin auth fails. The fix is to recreate the dev
  mongo volume or align the existing root password with `.env-dev`.

## Makefile (Docker lifecycle)

The Makefile drives the two compose stacks.

- `make dev-up`, `make dev-down`, `make dev-logs` run the dev stack
  (`docker-dev/compose-dev.yaml` with `docker-dev/.env-dev`).
- `make prod-setup` generates two distinct strong passwords into
  `conf-default/docker/.env`, one for the mongo root/admin (`MONGODB_PASSWORD`)
  and one for the scoped app user (`MONGODB_APP_PASSWORD`). Run it once before the
  first production start.
- `make prod-up` refuses to start until both passwords are set to non-default
  values (it shares the deny-set check from
  `installer_hooks/common_dbpassword.sh`), then brings up
  `conf-default/docker/compose.yaml`.
- `make prod-down`, `make prod-logs` stop and follow the production stack.

## Forgotten admin password recovery

`admin/setup_mongodb.pl resetadminpw=1` resets a forgotten MongoDB admin password
on a local, standalone server, run as root. MongoDB has no in-place reset for a
forgotten credential, so the only supported mechanism is to restart mongod without
access control, change the password, then re-enable authentication. This command
does that safely.

- It refuses on a remote server, a non-root caller, or a replica set.
- For the brief window it pins mongod to loopback and restores the original
  binding afterwards, so a network-bound server is not exposed while
  unauthenticated.
- The new password comes from `newpasswordfile=<path>` (a file, so the secret
  never reaches argv or logs), else an interactive prompt, else it is generated.
  Add `resetconfirm=1` to proceed unattended.
- Authentication is always re-enabled, even if the reset fails partway.

## Related tickets

- OMK-12826, OMK-12709: this work.
- OMK-12923: the other OMK products giving up the shared `opUserRW` on their side.
- OMK-12924: the installer forcing a 2.x MongoDB Perl driver on every OS.
- Full record of tightened defaults: `docs/security-hardening-register.md` (H13).
