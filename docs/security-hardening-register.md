# Security hardening register

A living record of changes made to the shipped defaults during the OMK-12644
hardening epic: what changed, why, what delegated-administration functionality
it affects, and mitigation options to investigate (not yet implemented) that
would restore the intent without reopening the hole.

This file has two jobs:

1. Institutional memory — so we know later why a default was tightened and what
   a customer loses by it.
2. Source data for a future user-facing hardening tool (see
   [Hardening tool concept](#hardening-tool-concept)) that would let operators
   choose a posture and see, per change, what it protects against and what it
   costs.

## Design context: why delegation and escalation are the same grant today

NMIS authorization is **table-granular** and **privilege-linear**:

- A user maps to one privilege in `PrivMap.nmis` → a numeric level 0–5
  (administrator=0, manager=1, engineer=2, operator/guest higher).
- The `Access.nmis` matrix grants each named right to a set of levels.
- Write rights are per-table (`Table_<name>_rw`); the write path in
  `cgi-bin/tables.pl` writes whatever table the request names once the single
  matching right passes.

There is no field-level authorization, no "may not exceed own privilege"
constraint, and no tenant boundary. The default `manager` account also has
`groups => 'all'` (`conf-default/Users.nmis`), so a "manager" is not scoped to a
tenant — it sees every group.

The consequence: the delegated capabilities the roles were given double as
escalation or RCE primitives.

- "Manager may onboard users" = full write to the `Users` table = create an
  account with `privilege => administrator`, or raise their own. Nothing checks
  the privilege being assigned.
- "Engineer may tune config" = full write to the `Config` table, which holds
  `auth_web_key` (cookie signing), DB credentials and all `auth_*` settings next
  to operational keys. Setting a known `auth_web_key` lets you forge admin
  cookies (ties to C2 / OMK-12687).

So the hardening changes below do not remove *working* safe features. They
remove features that were never safely bounded. Restoring them means adding the
constraints that were missing, not reverting the default.

---

## Changes from former defaults

### H11 / OMK-12707 — sensitive table writes restricted to administrator

**Files:** `conf-default/Access.nmis`, `conf-default/Config.nmis`,
`lib/NMISNG/Auth.pm`, `cgi-bin/tables.pl`, `admin/harden_access_table.pl`,
`installer_hooks/10-postcopy-confmerges`

**What changed**

| Right (table)            | Before (levels)      | After | Who lost write        |
|--------------------------|----------------------|-------|-----------------------|
| `table_users_rw` (Users) | 0, 1                 | 0     | manager               |
| `table_privmap_rw` (PrivMap) | 0, 1             | 0     | manager               |
| `table_access_rw` (Access)   | 0, 1, 2          | 0     | manager, engineer     |
| `table_config_rw` (Config)   | 0, 1, 2          | 0     | manager, engineer     |
| `table_tables_rw` (Tables)   | 0, 1, 2          | 0     | manager, engineer     |

`table_authldapprivs_rw` (AuthLdapPrivs) was already admin-only; unchanged.
`table_services_rw` (Services) is also forced admin-only by the code guard
below — its default grant is tightened separately in PR #11, so it is not in
the table above and this change only adds it to the guard. Services is included
because a service definition can carry a service-check `Program` that executes
(see C7 / OMK-12692), so writing it is a command surface.
`table_logs_rw` (Logs) joined the same guard later, under OMK-12823; see that
entry below for why.

Plus code enforcement independent of the matrix: `CheckAccessCmd` and
`CheckButton` deny these rights to any non-admin regardless of what the
live `Access.nmis` says (needed because an upgraded install keeps its old,
permissive `conf/Access.nmis`). A deny-by-default `TableRegistered()` allowlist
was added to the table editor.

**Why:** each of these tables feeds back into authentication or authorization,
so any write is equivalent to becoming admin. `Tables` is the master registry
that defines which tables the editor exposes and their key structure — an admin
task, and an integrity lever, so it joined the set. Confirmed vuln per the ticket.

**The matrix change alone does not protect existing installs.** `Access` is
loaded from the live `conf/Access.nmis` only (`loadGenericTable` →
`loadTable(dir=>conf)`; `conf-default` is a fallback used only when the live file
is missing — `Util.pm:1395`). Any real install already has a live
`conf/Access.nmis`, so the `conf-default` edit reaches fresh installs only. On
every existing install the code guard is what actually enforces this. That is
why the guard exists, and also why it needs the opt-out below.

**Delivering the corrected matrix to existing installs.** The guard enforces
the policy on an upgrade, but the live `conf/Access.nmis` keeps its old
permissive values, so the matrix and the enforcement disagree and the matrix
reads as if managers still hold these rights.
`admin/harden_access_table.pl` closes that gap. It takes the guarded rights
from `NMISNG::Auth::admin_only_rights()` and the target values from
`conf-default/Access.nmis`, and reports by default. Only `--apply` writes, and
it backs the live table up to `conf/Access.nmis.prepatch` first, keeping an
existing `.prepatch` rather than overwriting it because the installer retries a
failed command six times. It re-reads the file afterwards to confirm every
value landed, and does nothing at all when `auth_lock_sensitive_tables` is off,
since the operator has then chosen matrix-driven behaviour and the matrix is
load-bearing. `installer_hooks/10-postcopy-confmerges` runs it with `--apply`
on every upgrade, after `05-postcopy-configfiles` has merged in any newly
shipped rights. A fresh install never reaches it: that hook exits early on
`CLEANSLATE`, and a fresh install has no `conf/Access.nmis` at all, reading the
already-corrected `conf-default` directly.

**One-shot record, `access_table_hardened`** (config, default empty). Set to
`true` once the corrections have been applied. On every later run the script
exits before opening any file, so a deliberate operator re-grant is never
undone by a subsequent upgrade. Note what this does and does not do: it
protects your edit to the matrix, not the enforcement. The code guard still
denies a re-granted right, so restoring a delegation this way only takes effect
in combination with the `auth_lock_sensitive_tables` opt-out below.

To run the correction again, clear the key or pass `--force`. A value written
by an earlier release, a comma-separated list of the rights it had corrected,
also counts as set. **A right added to the guard in a later release is not
picked up on an install that already carries the flag**, so any future
hardening that extends `%admin_only_rights` has to clear
`access_table_hardened` in its own installer hook, or tell operators to run
`--force`.

**Operator opt-out — `auth_lock_sensitive_tables`** (config, default `true`).
The guard is gated by this flag. Default (or any value that is not an exact
false token) keeps it enforced; setting it to an exact false token
(`false`/`no`/`0`, any case, surrounding whitespace allowed) makes the
guarded rights defer to the Access matrix again — i.e. restores the pre-fix
behaviour. This is the supported way for a customer who needs "the old way" to
get it back, without a source edit. It is deliberately coarse and blunt:
flipping it re-opens every guarded right at once, including the never-safe ones
(editing the Access matrix itself, and Config while it still holds
`auth_web_key`). It is an informed "I accept the risk" switch, not the safe way
to restore delegation — for that see the mitigation notes below. The match is
exact by design: a malformed value such as `none` or `null` keeps the guard on
rather than silently unlocking (getbool's prefix match is deliberately not
used). Fail-secure (absent, empty or malformed → enforced) so an upgraded
install is locked by default. `conf-default/Config.nmis:auth_lock_sensitive_tables`,
enforced in `NMISNG::Auth::_lock_sensitive_tables`.

**Delegated functionality lost**

- **Manager can no longer add/edit/remove user accounts.** This is the real
  loss — the "onboard a new employee or customer" workflow the role was built
  for. Recoverable bluntly via the opt-out flag, or safely via the constrained
  onboarding path in the mitigation notes.
- **Manager can no longer edit PrivMap** (privilege→level definitions). Little
  everyday value; this is an admin function. Low loss.
- **Manager and engineer can no longer edit the Access matrix.** Meta-authorization;
  editing it is self-evidently escalation. Low loss.
- **Manager and engineer can no longer edit global Config.** Mixed loss: removes
  a genuine operational-tuning capability (thresholds, polling, mail, display)
  *and* the escalation vector, with no separation between them.
- **Manager and engineer can no longer edit the Tables registry.** Defining
  which tables the editor exposes is an admin task; low everyday loss.

**Mitigations to investigate (not implemented)**

- *Users / delegated onboarding:* a constrained user-management path (separate
  from the raw table editor) that server-side enforces: (a) may only assign a
  privilege ≤ the actor's own level; (b) may not edit the `privilege`/`groups`
  fields outside an allowlist; (c) may not edit the actor's own account; (d)
  scopes new accounts to the actor's own group(s)/tenant. That restores
  onboarding without self-escalation.
- *Config / operational tuning:* field-level authorization on Config — an
  allowlist of operationally-safe sections editable by engineer (thresholds,
  polling, mail, display) and a denylist of security keys (`auth_web_key`,
  `db_*`, `auth_*`, LDAP secrets) that stay admin-only. Enforce in
  `doEditConfig`/`edit_config`, not just at the table grant. Alternative: move
  security keys out of the GUI-editable surface entirely.
- *Access matrix / PrivMap:* keep admin-only. Per-tenant role customization
  would be a larger redesign (per-tenant matrices), out of scope here.

### H12 / OMK-12708 — MongoDB no longer published on every interface

**Files:** `compose.yaml`, `conf-default/docker/compose.yaml`,
`docker-dev/compose-dev.yaml`, `conf-default/docker/mongo/mongod.conf`, `.env`,
`conf-default/docker/.env`, `docker-dev/.env-dev`

**What changed**

| Setting | Before | After |
|---------|--------|-------|
| Compose port publish (all three files) | `"27017:27017"` (every interface) | `"${MONGODB_BIND_ADDR:-127.0.0.1}:${MONGODB_HOST_PORT:-27017}:${MONGODB_PORT:-27017}"` |
| `mongod.conf` `net.bindIp` | `0.0.0.0` | `localhost,mongo` |
| `mongod` command line | no `--port` | `--port ${MONGODB_PORT:-27017}`, overriding `mongod.conf` |
| `NMIS_DB_SERVER` (all three files) | hardcoded `mongo` | `${MONGODB_SERVER:-mongo}` |
| `NMIS_DB_PORT` | passed by `compose.yaml` only, from a variable only `.env` defined | `${MONGODB_PORT:-27017}` in all three files |
| `MONGODB_BIND_ADDR` (new) | did not exist | `127.0.0.1` in all three env files |
| `MONGODB_HOST_PORT` (new) | did not exist | `27017` in all three env files |
| `MONGODB_SERVER` (new) | did not exist | `mongo` in all three env files |
| `MONGODB_PORT` (new) | did not exist | `27017` in all three env files |
| `NMIS_DB_PORT` in `.env` | `27017` | removed, superseded by `MONGODB_PORT` |

**Host side and container side are deliberately separate variables.**
`MONGODB_BIND_ADDR` and `MONGODB_HOST_PORT` control only where the port is
published on the host. `MONGODB_SERVER` and `MONGODB_PORT` control how the app
reaches Mongo across `nmis_net`, and are fed to it as `NMIS_DB_SERVER` and
`NMIS_DB_PORT`, since NMIS overrides any config key from `NMIS_<KEY>` in the
environment (`NMISNG::Util::_apply_env_overrides`). Wiring `NMIS_DB_PORT` to `MONGODB_HOST_PORT` would
be a defect: a non-default host port would leave the app dialling a port mongod
is not listening on inside the network. The test asserts that mistake is not
made, in both directions.

`MONGODB_PORT` is the single source of truth for the container port and moves
four things at once: `mongod --port`, the container side of the published
mapping, the mongo healthcheck, and `NMIS_DB_PORT`. Before this, nothing tied the
app's `db_port` to the port mongod actually used.

**Not a hardening change, recorded only so this entry's variable list is not
misleading.** The same pass made the remaining host-visible settings
configurable, so more than one stack can run on a host:
`NMIS_CONTAINER_NAME`, `MONGO_CONTAINER_NAME`, `NMIS_BIND_ADDR`,
`NMIS_HTTP_PORT`, `NMIS_SNMP_PORT`, `NMIS_IMAGE` and `MONGO_IMAGE`, plus
`COMPOSE_PROJECT_NAME` for volume and network isolation. Each env file ships
only the variables its own compose reads: `conf-default/docker/.env` omits the
container-name and SNMP variables, because the compose beside it pins no
container names and publishes no SNMP port. **Every default is today's value,
so no shipped default changed and nothing here tightens anything.** In particular the web UI and SNMP listener still publish on
`0.0.0.0`, deliberately: narrowing the web tier belongs with H14 and H15
(OMK-12710, OMK-12711), and doing it here would have buried a second
behavioural change inside a database-exposure fix.

**Why:** Docker publishes ports by writing its own NAT rules, which are
evaluated *before* the host firewall. A port published on every interface is
therefore reachable even on a host whose iptables or ufw policy denies it, so
the shipped default put the database holding device data and stored credentials
directly on the network. Auth was enabled (`--auth`), so the exposure was gated
on credentials, which is exactly why this pairs with H13 (OMK-12709) and the
shipped default database password.

**Deliberate deviation from the ticket.** The ticket asked for mongod `bindIp`
`127.0.0.1`. That would break every Docker deployment. Only one `mongod.conf`
ships and it is the *container's*; the nmis container reaches the database at
`mongo:27017` across the compose network, so a loopback-only mongod is
unreachable to it. `localhost,mongo` instead binds loopback plus the container's
own address on `nmis_net` — Docker's embedded DNS resolves the service name to
that address, and mongod re-resolves at every start, so a changed container
address is picked up automatically. Verified in an isolated stack: listeners are
`127.0.0.1` and the bridge address with no `0.0.0.0`, the app container
connects, and it survives restart and recreate.

**Known sharp edge, already covered.** If the name fails to resolve at startup
(a plausible race with embedded DNS on a cold boot) mongod starts anyway bound
to loopback only, and logs nothing that names the problem. The shipped mongo
healthcheck connects to `mongo:27017`, so it exercises the network listener
rather than loopback: a loopback-only mongod fails it with `ECONNREFUSED` and
exit 1, verified. So the failure surfaces as an unhealthy container rather than
a silent outage. Do not "simplify" that healthcheck to `localhost`.

**Functionality lost**

- **Remote hosts can no longer reach the database.** Anything that connected to
  `<host>:27017` from another machine stops working: an external backup job, a
  BI or reporting tool, `mongosh` from an admin's laptop, or a remote poller in
  a multi-server layout. This is the intended loss, and it is the one most
  likely to surface as an upgrade complaint.
- **Host-local access is retained**, so backups, `mongosh` on the box, and
  host-side single-test runs that connect to `127.0.0.1:27017` all keep working.
  Publishing was narrowed rather than removed for exactly this reason.
- **Nothing is lost inside the compose stack.** The app has always reached Mongo
  over `nmis_net` by service name, not via the published port.

**Do not read the above as "unreachable" on Docker Engine older than 28.0.0.**
Publishing to `127.0.0.1` is not a complete boundary on those engines. Docker's
port-publishing documentation states, twice, that "In releases older than
28.0.0, hosts within the same L2 segment (for example, hosts connected to the
same network switch) can reach ports published to localhost" (moby/moby#45610,
<https://docs.docker.com/engine/network/port-publishing/>). This repository sets
no engine version floor, so on an older engine a residual same-segment exposure
survives this change while the rest of this entry reads as though H12 were fully
closed. A site on an engine below 28.0.0 should upgrade the engine, or firewall
27017 at the network, and should not treat the loopback publish as sufficient on
its own. Worth revisiting if a minimum engine version is ever declared.

**Recovery for a site that genuinely needs remote access:** set
`MONGODB_BIND_ADDR` to a specific address in the env file, and firewall that
address at the network rather than trusting the host firewall, because Docker's
NAT rules will still bypass it. `0.0.0.0` restores the old exposed behaviour and
is documented in `.env` as something not to use. `MONGODB_HOST_PORT` also allows
moving Mongo off the well-known port, or running two stacks on one host.

**Mitigations to investigate (not implemented)**

- *Remote access done properly:* TLS on the Mongo listener plus certificate
  auth, so a multi-server deployment does not depend on an unencrypted port
  being open. Related to the transport work in H14 (OMK-12710).
- *Defence in depth on the app port:* the nmis container still publishes `8080`
  on every interface. Deliberately out of scope here, since it is the web tier
  and belongs with H14/H15 (OMK-12710, OMK-12711), but it is the same class of
  mistake and should not be forgotten.
- *Credential strength:* this change reduces the exposure but the shipped
  default database password is what makes it dangerous. Tracked as H13
  (OMK-12709).

---

### H12 / OMK-12697 — plugin loader permission guard

**Files:** `lib/NMISNG.pm`, `lib/NMISNG/Util.pm`, `bin/nmis-cli`,
`conf-default/plugins/README`, `test/t_plugin_loader_guard.t`,
`ci/scripts/perl_tests.sh`

**What changed**

Before this change, NMIS loaded plugin files from `conf/plugins/` and
`conf-default/plugins/` unconditionally — any file writable by the nmis
group (mode 0660 or 0770) was loaded and executed as root via `require`.

After this change, the plugin loader rejects any plugin directory or file
that is group- or world-writable, owned by a UID other than root or
`nmis_user`, or a symlink. `nmis-cli act=fixperms` now tightens plugin
directories to configured `nmis_user:nmis_group go-w` after the existing broad fixperms passes.

| Check | Before | After |
|-------|--------|-------|
| Plugin dir mode | not checked | rejected if `& 022` |
| Plugin file mode | not checked | rejected if `& 022` |
| Plugin file owner | not checked | rejected if not root or nmis_user |
| Symlinked plugin | loaded | rejected |
| fixperms covers plugins | no | yes (`chown nmis_user:nmis_group`, `chmod go-w`) |

**Why:** a group-writable plugin directory allows any process running as
the nmis group to plant or replace a `.pm` file that executes as root at
the next collect/update cycle. The ticket's exact scenario was
`conf/plugins/` at mode 0770 — shipped default before OMK-12697.

**Scope and boundary:** this guard matches the trust model of `lib/` after
`fixperms` (nmis-owned, not group-writable). It does not cover the broader
code tree (`lib/`, `bin/`); root-owns-all-code hardening for the full
installation is a deferred follow-up — a tracking ticket must be raised and
its ID added here before this PR merges.

**Migration for existing installs:**
Installer-based upgrades run `fixperms` automatically via
`installer_hooks/99-postcopy-fixperms` and self-heal. Git-pull or
image-based deployments must run the following as root after updating:

```
/usr/local/nmis9/bin/nmis-cli act=fixperms
```

This resolves the correct owner and group from `Config.nmis` (`nmis_user`
and `nmis_group`) and covers both configured plugin roots (`plugin_root`
and `plugin_root_default`). The rejection log message names the affected
directory and this command. There is deliberately no config off-switch for
this guard. To disable all plugins, set `plugins_enabled => 0` in
`Config.nmis`.

**Functionality affected:** any plugin file or directory that does not
meet the trust criteria is silently skipped (logged at error level). No
plugins are disabled on a correctly permissioned install.

---

### H4 / OMK-12699 — anti-CSRF token and POST-only enforcement on the CGI GUI

**Files:** `lib/NMISNG/Auth.pm`, every mutating script under `cgi-bin/`,
`menu/js/commonv8.js`, `conf-default/Config.nmis`,
`conf-default/docker/Config.nmis.docker`, `conf-default/Table-Config.nmis`

**What changed**

| Setting | Before | After |
|---------|--------|-------|
| Write acts under `cgi-bin` | reachable by GET, no token | POST only, and a valid `csrf_token` required |
| Unknown or missing act | ran whatever the script dispatched | classified as a write, so refused unless it POSTs with a token |
| `tools.pl?act=tool_system_collect` | GET ran the support-archive job | GET renders a confirmation, `tool_system_docollect` POSTs the job |
| `menu.pl` window state | raw JSON body, dispatched on the body existing | `act=menu_window_state` with the payload in `windowdata` |
| `auth_csrf_enforce` (new) | did not exist | `true` |

**Why:** every state-changing action was a GET with no unguessable value in it,
so any page an authenticated operator visited could drive one with an `<img>`
tag or an auto-submitting form. The token is a stateless HMAC over the
authenticated username and an expiry, keyed with the existing `auth_web_key`,
so it needs no server-side session store and cannot be minted for another user.

**Delegated functionality affected.** Anything that drove a write act by URL.
In practice that means customer automation holding a session cookie and calling
`cgi-bin` directly, and any bookmark or saved link that pointed at a write act.
Both break on upgrade. Read acts, which are the overwhelming majority of the
GUI, are untouched and still work by GET with no token.

**Escape hatch: `auth_csrf_enforce`, default `true`.** Setting it to an explicit
false token (`false`, `f`, `no`, `n`, `0`) makes the guard stand aside for the
whole install. This exists for exactly one situation, an operator who finds
their automation broken by the upgrade and needs it working again while they fix
it. Turning it off is logged to the auth log for every write act the guard then
stands aside for, naming the act and the script, so a silently disabled guard is
not possible. The check sits after the read classification, so a disabled guard
does not log on ordinary page loads. Anything other than a recognised false
token leaves enforcement on, deliberately spelled out rather than passed to
`getbool`, so a value like `falsey` cannot switch the guard off by prefix match.

**Two carve-outs are not configurable, by design.** The guard stands aside off
the CGI path, since a command-line invocation has no browser and no session to
ride, matching what OMK-12686 did for the ISINDEX guard. It also stands aside
when `auth_require` is off, because such an install never calls `loginout`, has
no user to bind a token to and no session cookie for an attacker to use. Without
that second carve-out an install with authentication disabled would lose every
GUI write on upgrade, with no token obtainable to fix it.

**Known gap, a stale browser cache breaks window-state saves quietly.** A cached
pre-upgrade `commonv8.js` still posts the raw JSON body that `menu.pl` no longer
dispatches on, so the upgraded server refuses the save with a 403, and
`postWindowState` has no error handling to surface it. Window layout silently
stops persisting until the browser picks up the new script.
`nmis_common` (`conf-default/Config.nmis`) carries no cache-busting version
parameter, so there is nothing to force that refresh. It self-heals on the next
cache expiry or a hard reload, and it affects only the saved window layout, so
this ships as a release note rather than a fix. Adding a version parameter to
the script include is the real fix and is not implemented.

**Mitigation to investigate.** Nothing here narrows the escape hatch to a
subset of acts or a subset of clients. An install that needs tokenless writes
for one automated caller has to disable the guard for every caller. A per-act or
per-source allowance would be better and is not implemented.

### H5 / OMK-12700 — SameSite and Secure on the session cookie

**Files:** `lib/NMISNG/Auth.pm`, `conf-default/Config.nmis`,
`conf-default/docker/Config.nmis.docker`, `conf-default/Table-Config.nmis`

**What changed**

| Setting | Before | After |
|---------|--------|-------|
| Session cookie `SameSite` | no attribute | `Lax` |
| `auth_cookie_samesite` (new) | did not exist | `Lax` |
| `auth_cookie_secure` (new) | did not exist | `false` |

**Why:** `SameSite=Lax` stops the session cookie riding along on cross-site
POSTs, which is the transport the CSRF work in H4 defends against. It is the
browser-side half of the same fix, and useful on its own for any write path that
predates or outlives the token.

**Delegated functionality affected.** A cross-site POST that previously carried
the session cookie no longer does. Anything embedding the NMIS GUI in a frame on
another origin and posting into it is affected. `Secure` is off by default and
only takes effect when an operator turns it on, so plain-HTTP installs are
untouched.

**Escape hatch: `auth_cookie_samesite = off`.** That is the only way back to a
cookie with no `SameSite` attribute, which is what shipped before. Blank and
unset still resolve to `Lax`, so an install that never set the key keeps the
protection rather than silently losing it to an empty value in a config file.
`None` is rejected rather than emitted: `CGI::Cookie` cannot produce it, and
opmojo writes this same cookie, so accepting it would leave the two disagreeing
about the cookie they share. An operator who genuinely needs `None` has to use
`off` and set the attribute at the web server.

**Known gap.** An old `CGI.pm` drops an unrecognised `-samesite` silently, so the
cookie ships without the attribute and nothing appears to be wrong. This is
detected and logged once per process rather than left invisible, but it is not
fixed here, and the only fix is upgrading `CGI.pm`.

---

### H16 / OMK-12688 — the shipped administrator credential is no longer usable

**Files:** `conf-default/users.dat`, `bin/nmis-cli`,
`installer_hooks/05-postcopy-configfiles`, `docker-entrypoint.sh`,
`docker-dev/docker-entrypoint-dev.sh`, `test/t_cgi_endpoints.sh`

**What changed**

| Thing | Before | After |
|-------|--------|-------|
| `conf-default/users.dat` `nmis` entry | `nmis:SG65RBEiLjd5U`, a live DES crypt of the published password `nm1888` | `nmis:*NMIS-UNSEEDED*`, a locked marker `crypt()` cannot produce, so nothing verifies against it |
| Password on a fresh install | none set, the shipped hash *was* the login | random 20 characters from `/dev/urandom`, stored as sha512 crypt at 100000 rounds |
| Where the first password comes from | published in the docs | `/usr/local/etc/firstwave/nmis-initial-password`, 0600 and root-owned, or printed once on an interactive console |
| Setting a password | external `htpasswd` only, NMIS had no write path into the store | `bin/nmis-cli act=set-htpasswd-password`, plus `act=seed-htpasswd-password` for installers |

`conf-default/Users.nmis` is unchanged. The `nmis` account still exists and is
still `administrator` across all groups. Only its credential changed.

**Why:** the shipped hash was a working password that has been public for years,
and `installer_hooks/05-postcopy-configfiles` copied `users.dat` verbatim into
live `conf/` on every fresh install. `dockerfile:159-161` copies the same file
into the image. Nothing anywhere forced a change. That is anonymous
administrator access on any default install. The hashing helpers it now uses
(`generate_random_password`, `hash_password`) come from OMK-12705.

**The seeding is idempotent, which is what makes it safe to call everywhere.**
`act=seed-htpasswd-password` runs at installer hook 05, on upgrade, and on every
container start. It classifies the stored entry first:

| Stored `nmis` hash | What happens |
|--------------------|--------------|
| absent, or empty   | random password set |
| exactly `*NMIS-UNSEEDED*`, the shipped marker | random password set |
| verifies `nm1888` (des or apr1) | rotated |
| any other lock (`*` or `!`) | left locked |
| any other hash     | left alone |

The classification is the same in all three callers, so none of them passes any
context. A lock is ambiguous in principle, the shipped seed on a fresh install
against a deliberate operator lockdown on an existing site, and the marker is
what resolves it. Anything else beginning `*` or `!` is somebody's lockdown and
is never re-enabled. This replaced an earlier `seed=t|f` flag that made each
caller declare which situation it was in.

**Delegated functionality lost:** there is no longer a first login anyone can
know in advance. Scripted provisioning, demo images, documentation and CI that
authenticated as `nmis`/`nm1888` must now read the initial-password file or set
a password explicitly. `test/t_cgi_endpoints.sh` was changed for exactly this
and now fails with a clear message instead of using a hardcoded password.

**Recovery — how an operator gets in**

- Interactive install: the password is printed once at the end of the install.
- Unattended host install: read it from
  `/usr/local/etc/firstwave/nmis-initial-password`.
- Containers: there is nothing to read. They never invent a password and never
  create that file, so the password is the one you supplied through
  `NMIS_ADMIN_PASSWORD`. If you have lost it, reset with
  `docker exec <container> /usr/local/nmis9/bin/nmis-cli act=set-htpasswd-password user=nmis`.
- The path is overridable with `NMIS_INITIAL_PASSWORD_FILE`.
- Lost it, or want a different one:
  `bin/nmis-cli act=set-htpasswd-password user=nmis`. This works inside the
  container too, where `htpasswd` (`apache2-utils`) is not installed.
- **Record it promptly. The file is removed automatically**, see below.

**Containers never invent a password, so they never create the file.** The
operator supplies it, `NMIS9_ADMIN_PASSWORD` or `NMIS9_ADMIN_PASSWORD_FILE` in
the service environment, fed from `NMIS_ADMIN_PASSWORD` in `.env`. Both
entrypoints pass `generate-password=f`, so if a password has to be set and none
was supplied the container refuses to start rather than inventing one.

That is not a preference, it is forced by the privilege model.
`nmis_frontend` in `docker-entrypoint.sh` `su`'s nmisd to `${NMIS_USER}`, while
an invented password has to be recorded in a root-owned 0600 file inside a
root-owned 0700 directory. The container's own nmisd could neither read that
file nor remove it once it was spent, so the file would be created and then
never retired for the life of the container. Supplying the password removes the
file from the container story altogether, which is a better answer than adding a
privileged process to clean up after one.

Three details keep this from becoming a new `nm1888`:

- The shipped `.env` carries the key **empty**. A value there would be the same
  known password on every deployment, which is the hole this whole entry closes.
  `test/t_nmis_cli_seed_password.t` asserts it stays empty.
- The container-side name deliberately avoids the `NMIS_` prefix.
  `_apply_env_overrides` maps `NMIS_<KEY>` onto config key `lc(<KEY>)` and can
  add new keys, so `NMIS_ADMIN_PASSWORD` would put the plaintext into the config
  surface. The `.env` variable may use that name because compose substitution
  happens on the host and never enters the container.
- The `_FILE` form is supported, the same convention the postgres, mysql and
  mongo images use, so the secret can live in a docker secret rather than in the
  environment and in `docker inspect`.

The password is read from the environment rather than argv, so it does not
appear in `ps` or `docker top`, and a supplied password is never written to the
initial-password file or echoed, because the operator already has it.

**On host installs the file is still created, and retires itself once it is no
longer needed.** `bin/nmis-cli act=discard-initial-password` removes it once
*any* user has logged into the GUI. `bin/nmisd` runs it from the hourly purge
job, so the file disappears within an hour of the first login. nmisd is root
there, its systemd unit sets no `User=`.

The GUI cannot do this itself. The file is 0600 and root-owned in a root-owned
directory, and the web server runs as `apache` or `www-data`. Rather than grant
the web user a way to remove it, which would mean a writable root config
directory or a sudo rule, the unprivileged side keeps doing what it already did
and root notices afterwards. `NMISNG::Auth::update_last_login` already records
every successful login in `users_login.json`, so **no GUI-side code changed**.

Any user counts, not just `nmis`. An LDAP or SSO site never logs in as the local
`nmis` account, and a provisioned admin account can exist without an `nmis`
login ever happening, so keying on `nmis` alone would strand the file forever on
exactly the deployments most likely to be long-lived.

The comparison is against the file's mtime rather than "has anyone ever logged
in", so re-seeding is not immediately undone by a login that predates it.

**Known limits, accepted deliberately**

- If nobody ever logs into the GUI, the file stays indefinitely. There is no age
  cap. This is interim: the structural fix is forcing a password change at first
  login, which makes the contents worthless rather than merely short-lived, and
  is tracked separately below.
- A file relocated with `NMIS_INITIAL_PASSWORD_FILE` is never retired. nmisd
  only knows the default path. Relocating it makes the file yours to manage.
- The trigger is authenticated activity, not a fresh login.
  `NMISNG::Auth::update_last_login` has a single caller, below the branch that
  handles both the username and password path and the `# check cookie` path, so
  an idle tab auto-refreshing on `page_refresh_time` or `widget_refresh_time`
  stamps `users_login.json` too. Consequence: on an upgrade that rotates a
  still-shipped `nm1888` default, somebody else's open session can retire the
  new file before the operator reads it. Recovery is
  `act=set-htpasswd-password` as root. This is currently masked, because the
  same upgrade rotates an unset `auth_web_key` at
  `installer_hooks/11-postcopy-authkey` and invalidates every cookie, but that
  masking is incidental and expires: on later upgrades the key is already
  unique, the hook changes nothing, and sessions survive. Keying on session
  creation rather than activity is the fix. **Tracked as OMK-12854**, which also
  records the five conditions this needs (host install, upgrade, an unconfigured
  `nmis` entry, another user's live session, and the window before the key
  rotates) and the two alignments that were rejected. Containers cannot hit it at
  all, because they never create the file.
- `users_login.json` is owned and written by the web user, so root is acting on
  untrusted input. The blast radius is bounded: the path unlinked is fixed and
  never derived from that file, nothing in it is executed, and every value is
  rejected unless it is a plain timestamp. A compromised web process could cause
  the password file to be deleted early, which costs the operator a recorded
  convenience and gains the attacker nothing.
- Removal is a plain `unlink`, with no attempt to overwrite the contents first.
  Anyone able to read freed disk blocks could have read a 0600 root-owned file
  directly, so scrubbing would defend against nobody and would imply a guarantee
  that journaling, copy-on-write and SSD wear levelling cannot deliver.

**Why the shipped marker is `*NMIS-UNSEEDED*` and not a bare `*`:** the seeder
has to tell a never-seeded account from one an operator locked, and a bare `*`
is both. Docker makes this concrete. It pre-fills a new named volume from the
image content at the mount path (`dockerfile:159-162` copies the file into
`${NMIS_HOME}/conf/`, `dockerfile:167` declares that path a `VOLUME`), so a
fresh volume already holds the shipped store. While the default was briefly a
bare `nmis:*` during this work, an operator who locked the account by writing the
same thing looked exactly like a fresh volume and had their lock replaced with a
working password on the next start. Never seeding a lock was not an option
either, because it would leave every fresh container with an administrator
account nobody can log into.

A marker no operator would type removes the ambiguity outright, and
`bin/nmis-cli::_is_shipped_seed` matches it exactly rather than by prefix. Both
`nmis:*` and `nmis:!` are still locks everywhere it matters, `lib/NMISNG/Auth.pm`
and `bin/nmis-cli` both test `/^[*!]/`, so `*NMIS-UNSEEDED*` cannot be
authenticated against either.

The invariant this rests on is that `conf-default/users.dat` holds exactly the
marker `bin/nmis-cli` looks for. `test/t_seed_decision.t` asserts both halves,
so changing one without the other fails the suite rather than silently reopening
the gap.

**Superseded within this work, never released:** an earlier revision had the
callers derive a `seed=t|f` argument in shell, `install` unconditionally `t`,
`upgrade` from whether `conf/users.dat` already existed, `container` by comparing
`conf/users.dat` byte for byte against `conf-default/users.dat`. The marker makes
the file self-describing, so the flag, `nmis_seed_decide`, and the ordering
constraint that the upgrade check had to run above the noclobber `cp` are all
gone. That emptied `installer_hooks/common_seedpw.sh` down to `nmis_seed_reveal`
with one caller, so it was inlined into `installer_hooks/05-postcopy-configfiles`
and the file removed.

Recorded because the reasoning is worth keeping, not because anything has to
migrate. `seed=` never reached a release, so no caller or runbook refers to it,
and `nmis-cli` drops the unrecognised key silently rather than erroring. Against
that earlier revision two behaviours are tighter. A store holding the marker
alongside other users is now seeded, where the whole-file comparison did not
recognise it and left the account permanently unusable. And nothing re-enables an
operator lock any more, where `seed=t` did.

**Mitigations to investigate (not implemented)**

- *Force a change at first login:* nothing expires the seeded password or
  requires rotation. `act=discard-initial-password` narrows this but does not
  close it. The plaintext file now goes away once somebody logs in, so the
  common case is bounded, but two gaps remain. An install nobody ever logs into
  keeps the file indefinitely, and more importantly the seeded password itself
  stays valid forever whether or not the file survives. Forcing a change at
  first login is the fix that makes the recorded password worthless rather than
  merely short-lived, and it is the reason no age cap was added here.
- *Directory mode:* `make_path` applies `mode => 0700` only to a directory it
  creates. A pre-existing, looser `/usr/local/etc/firstwave` keeps its own mode.
  The file itself is 0600, so what leaks is the filename, not the password. This
  is deliberate, not an oversight.
- *Seed classification:* it lives once, in `bin/nmis-cli::seed_htpasswd_password`,
  and every caller invokes it with no context beyond `reveal=`. Nothing
  outstanding, listed so the next person changing the seeding behaviour knows
  there is one place to change.
- *`reveal=` derivation:* it lives inline at the top of
  `installer_hooks/05-postcopy-configfiles`, the only caller that derives one.
  Both entrypoints hardcode `reveal=none`. `test/t_seed_decision.t` lifts the
  block out of the hook and runs it, rather than restating the logic, so the
  hook stays the single source.

### H17 / OMK-12824 — session-cached privileges bound to the authenticated user

**Files:** `lib/NMISNG/Auth.pm`, `test/t_auth_session_privs.t`,
`ci/scripts/perl_tests.sh`

**What changed**

| Behaviour | Before | After |
|---------|--------|-------|
| privileges cached in a session file | trusted from whatever session the request named | trusted only when the session names the authenticated user and carries an `auth_web_key` HMAC that NMIS wrote |
| `privlevel` | taken from the session file | always re-derived from `PrivMap` |
| `CGISESSID` as a request parameter | accepted in `SetUser` and `do_logout` | ignored, cookie only |
| `do_logout` session delete | gated on `max_sessions_enabled`, which ships `false` | always, and only the logged-in user's own session |
| `generate_session` | `CGI::Session->new(undef, undef, ...)`, which adopts the session the request's `CGISESSID` names | mints a fresh id regardless of the request |
| `groups` session param | written, never read | no longer written |

**Why:** `SetUser` took the username from the HMAC-signed auth cookie and the
privileges from a session file the caller nominated, and never checked the two
named the same user. Any authenticated low-privilege user who supplied a session
id whose `priv` was `administrator` ran that request as an administrator, under
their own username, so the audit trail stayed honest while authorisation was
broken.

Ownership alone was not enough to fix it. Because the per-request writeback is
ungated (below), one escalated request rewrote the victim's session to name the
attacker, leaving a file that a username-only check would trust forever. The
same is true of a file planted by anyone who can write to `session_dir`, which
is OMK-12811. Hence the signature: it does not attest that a privilege is
correct, it attests that NMIS derived it, and NMIS only derives privileges from
Users, PrivMap or LDAP.

**This was default-on, not conditional.** Three gates on `max_sessions_enabled`
exist and two are commented out, at `Auth.pm:2051` and `:2150`, so sessions
are created on every login and rewritten on every authenticated request whatever
the setting says. Only the `do_logout` gate was live, and
`conf-default/Config.nmis:331` ships `'max_sessions_enabled' => 'false'`, so
logout deleted nothing and privilege-bearing files accumulated. The cached path
was therefore the normal path on a stock install, not an edge case.

**Delegated functionality affected.** `CGISESSID` passed as a URL or form
parameter stops working. Nothing in nmis9 or opmojo ever passed it, and the only
in-repo mentions are `Auth.pm`'s own accessor and four test files, but an
out-of-repo integration cannot be ruled out from the code. Logout now deletes the
server-side session file on installs that leave `max_sessions_enabled` at
`false`, which is the intended semantic and affects nothing that reads those
files.

An authenticated client that presents the auth cookie but never returns
`CGISESSID`, such as scripted `cgi-bin` access, now gets a freshly minted session
file per request, where the previous `load(undef, undef, ...)` produced an empty
session that never reached disk. Each file is bounded by `auth_expire` and removed
by the hourly `nmisd` purge, so this is churn in `session_dir` rather than growth,
but `session_dir` is the group-writable directory this entry already flags as the
remaining denial-of-service surface.

**No migration.** Sessions written before this change carry no signature, so the
first request on each falls through to `_GetPrivs` once and the writeback
re-signs the file. For an LDAP-authorised install that is one directory lookup
per existing session, once. Nothing is purged, and the hourly `nmisd` job
already expires stale files.

**Interaction with H16 / OMK-12688.** Session eviction on password change,
`bin/nmis-cli:1887`, and the hourly purge, `bin/nmisd:1763`, both identify whose
session a file is by its `username` field. Before this change the per-request
writeback let an authenticated user rewrite that field on a file they named, so
binding the writeback also protects eviction.

**The signed layout is pinned by a test, not by a convention.** Each field is
signed as `name=value`, so adding, removing, renaming or reordering one changes the
signed bytes by itself. The parts are joined on NUL without escaping the separator
or the `=`, so that guarantee holds for separator-free values, which is every value
NMIS derives from Users, PrivMap or LDAP; a value containing a literal NUL followed
by another field's name could still alias a boundary. Length-prefixing or escaping
would remove the class, and is worth doing whenever the layout next changes, since
that already forces a one-time re-sign. That also means a layout change expires every seal on disk without
anyone having to mark a version, which costs one privilege recomputation per live
session and is invisible to users. `test/t_auth_session_privs.t` case 22 holds a
golden digest over a fixed session and key, so such a change fails a test rather
than passing unnoticed.

An earlier revision of this work carried a `nmis9-session-privs-v1` constant as the
first signed part, for domain separation and versioning. It was removed. The
`name=value` encoding does the versioning job without it, and the domain job was
never reachable: a privileges string always contains a NUL and the CSRF string at
`Auth.pm:487` never does, while the auth cookie MAC is `hmac_sha1_hex` and fails
`_secure_compare` on length. A constant whose comment overstates what it defends is
worse than no constant.

**Known gap.** The cache is kept rather than removed, because `_GetPrivs` calls
`_get_ldap_privs` for LDAP-authorised installs and removing the cache would put a
directory round trip on every CGI request. `session_dir` also stays
group-writable until OMK-12811, so someone who can write there can still delete
or truncate other people's sessions, which is a denial of service. Neither is
load-bearing for privilege forgery any more.

---

### OMK-12823 — the log viewer is confined to the nmis log directory

**Files:** `cgi-bin/logs.pl`, `lib/NMISNG/Util.pm`, `conf-default/Logs.nmis`,
`conf-default/Access.nmis`, `conf-default/Config.nmis`

**What changed**

| Setting | Before | After |
|---------|--------|-------|
| File named by a `Logs` entry | any path on the box | must resolve inside `<nmis_logs>`, with symlinks followed (`NMISNG::Util::confine_path_to_dir`) |
| Shipped `Messages`, `Apache_Access_Log`, `Apache_Error_Log` | `/var/log/messages`, `/var/log/httpd/access_log`, `/var/log/httpd/error_log` | removed |
| Access rights `messages`, `apache_access_log`, `apache_error_log` | granted | removed |
| `table_logs_rw` (write the Logs table) | levels 0, 1 | 0, plus the `%admin_only_rights` code guard |

**Why:** `table_logs_rw` was level1, so a manager could add or edit a `Logs`
entry. `logs.pl` kept `logFileName` verbatim whenever it contained a `/`, then
read and displayed the file, gated only by `CheckAccess($logName)` where
`logName` came from the same manager-written entry. A manager could point an
entry at `conf/Config.nmis` and read `auth_web_key`, or at any file the web
server user can read. That is the same secret disclosure H11 closes for the
Config table, reached through a sibling table and CGI. The fix sits at the sink,
so it holds regardless of who planted the path, an administrator included.

**Delegated functionality affected.** Adding a log from outside `<nmis_logs>` is
no longer possible at any privilege level, administrator included, so viewing the
system and Apache logs through NMIS is gone. There is no opt-out: to see an OS
log in NMIS again, forward or copy it into `<nmis_logs>`. Curating the list at
all is now an administrator task, see the table grant below. Refused entries
list as `UA`, with the reason in the web server error log. Symlinking an outside
file into the log directory does not restore it, because the check resolves the
target rather than the name.

**Upgrades.** An install that already has a `conf/Logs.nmis` keeps its own copy
of the three removed entries, and they now list as `UA`. Only fresh installs
pick up the trimmed default. Existing rows are not re-checked against anything
but the confinement, so a `logName`/`logFileName` pairing a manager altered
before the upgrade survives it; the code guard stops further edits, it does not
undo past ones.

**The table grant is now admin-only too.** The confinement alone closes the file
read, so the grant was initially left at level1 to keep the curation capability
above. That leaves the residual below reachable by any manager, so the grant was
tightened as well: `conf-default/Access.nmis` sets `level1` to `0`, and
`table_logs_rw` joins `%admin_only_rights` in `NMISNG::Auth`, which is what
enforces it on an upgraded install whose live `conf/Access.nmis` still grants it
(same reasoning as H11). OMK-12707 considered and declined this change, rightly,
because it is redundant with the confinement for the *file read*. It is not
redundant for the authorization binding, which is a separate defect and the
reason it is done here. The cost is that a manager can no longer curate the
viewer's log list at all, not even from inside `<nmis_logs>`. There is no
narrower grant available, because the table editor authorizes per table rather
than per field.

**Known gaps.**

- `logName` is chosen in the same entry as the file, so the per-log
  `CheckAccess($logName)` check can be aimed at a right the writer already holds
  in order to reach another log inside the directory. The binding is still wrong:
  the check reads the entry's name while the content comes from the entry's file.
  With `table_logs_rw` admin-only the only writer is an administrator, who holds
  every log right anyway, so what remains is an administrator being able to
  expose a restricted in-directory log (`auth.log`, say) to lower-privileged
  users by repointing an entry whose name-right they do hold. Same standing as
  the `os_cmd_read_file_reverse` residual below. The real fix is a `logs.pl`
  authorization review that binds the required right to the resolved file rather
  than to the entry's name. **Investigate.**
- `loadLogFile` still assembles its read command as a string and runs it through
  a shell (`open (DATA, "$readLogFile |")`). Both filenames reaching that string
  are now confined, the entry's own and the rotations the glob finds beside it,
  but `os_cmd_read_file_reverse` from the Config table is still interpolated
  verbatim. H11 restricts that key to administrators. **Investigate** a
  list-form open.

---

### H13 / OMK-12826 / OMK-12709 — MongoDB app account is no longer the shared root identity

**Files:** `conf-default/Config.nmis`, `conf-default/Table-Config.nmis`,
`admin/setup_mongodb.pl`, `lib/NMISNG/DB.pm`,
`installer_hooks/common_dbpassword.sh`,
`installer_hooks/24-postcopy-setup-mongodb`, `docker-dev/compose-dev.yaml`,
`docker-dev/.env-dev`, `conf-default/docker/compose.yaml`,
`conf-default/docker/.env`, the root `compose.yaml` and `.env`, `Makefile`

**What changed**

| Key | Before | After |
|-----|--------|-------|
| `db_username` | `opUserRW` | `nmis9RW` |
| `db_password` | `op42flow42` (a live, working shipped default) | `CHANGE_ME_RUN_setup_mongodb` (a placeholder; `setup_mongodb.pl` generates a random 64-hex password when the effective value is still a shipped default) |
| `db_auth_source` (new) | did not exist | `nmisng`, written by `setup_mongodb.pl` once it provisions the scoped user; absent otherwise, so the driver keeps defaulting to `admin` on an install that has not migrated (phased, matching the authSource work in OMK-12826 Tasks 2/3) |
| `opUserRW` on `admin` | created/rotated by `setup_mongodb.pl`, granted `root` | untouched: `setup_mongodb.pl` no longer creates, rotates, or grants it anything |
| container app password | shared `${MONGODB_PASSWORD}` with the mongo root/admin identity in every compose file | its own `${MONGODB_APP_PASSWORD}`, distinct from the root/admin secret, in all three compose files, so reading the app config or env no longer yields the root password |
| root `compose.yaml` app identity | ran NMIS as the mongo root identity (`NMIS_DB_USERNAME=${MONGODB_USERNAME}`, no authSource, no admin split) | scoped `nmis9RW` with `db_auth_source=nmisng` and a separate `NMIS_DB_ADMIN_*` bootstrap pair, matching `conf-default/docker/compose.yaml` (plus the `service_healthy` startup gate) |

`setup_mongodb.pl` now authenticates its bootstrap connection with a separate
admin credential (`NMIS_DB_ADMIN_USERNAME`/`NMIS_DB_ADMIN_PASSWORD`, falling
back to the interactive prompt, defaulting to `opUserRW`), and provisions
`nmis9RW` as a `dbOwner` of `nmisng` only — no `admin`-database role, no
`root`. `db_password` is written back to `conf/Config.nmis` only when
`setup_mongodb.pl` generated it; an operator- or env-supplied password is
honoured for the created user but never persisted to disk. When it does write,
it persists the generated `db_password` first and then `db_username` and
`db_auth_source` in a single (atomic) `patch_config.pl` call, so a mid-sequence
write failure never leaves the config naming `nmis9RW` with a stale password and
the install marked migrated.

Three follow-on fixes ship in the same change (review of the initial commit):

- **Fresh no-auth server: provision a per-install admin, then enable auth.**
  Enabling auth closes MongoDB's localhost exception, so an administrative user
  must exist first or nobody can manage the server. NMIS provisions only the
  scoped `nmis9RW` (no `admin`/`root` role), so on a fresh no-auth local server
  `setup_mongodb.pl` now creates a separate admin, `nmis9admin` (role `root` on
  `admin`), with a *generated* password, records it root-only in
  `/usr/local/etc/firstwave/mongodb-admin-password` (0600, overridable via
  `NMIS_MONGO_ADMIN_PASSWORD_FILE`), and only then enables auth. This is NOT the
  old shared-identity behaviour: the account is per-install and its password is
  random, never the shipped default, and it is never written into the app config
  (`conf/Config.nmis` holds only the scoped `nmis9RW` credentials). If the
  generated password cannot be recorded the just-created admin is dropped and
  auth is left off, so an admin with an unrecoverable password is never left
  behind (`ensure_admin_user`, using `NMISNG::DB::has_admin_capable_user` to
  detect an existing admin). An existing admin is reused, not duplicated. A site
  that deliberately runs Mongo without authentication keeps its config-gated way
  back: decline the prompt interactively, or preseed `116b "no"`, and setup
  leaves auth off (that decline is a success; an auth-enable the operator *asked*
  for but that fails now exits non-zero so installer hook 24 aborts).
- **The admin credential file is also a credential *source*, not just a record.**
  When auth is already on, `setup_mongodb.pl` resolves the admin/bootstrap
  credential in order: `NMIS_DB_ADMIN_USERNAME`/`NMIS_DB_ADMIN_PASSWORD`, then the
  `mongodb-admin-password` file (parsed for its `username:`/`password:` lines),
  then the interactive prompt, then the legacy default. So a NMIS re-run on an
  authenticated server picks up the `nmis9admin` credential it recorded without
  re-typing, instead of no-op'ing. This also defines the cross-product handoff
  convention: another OMK product installed after NMIS on the same host can read
  the same file (0600, so root only) to authenticate and provision its own scoped
  user, rather than relying on a shared known-default password. The file being a
  dependency for later installs is the trade-off for dropping the shared default;
  a site that installs only NMIS can still record-and-delete it. **Open
  cross-product item:** OMK/opmojo `setup_mongodb.pl` must adopt this same file
  convention (and the separate-admin model) for a fresh NMIS-first multi-product
  install to be turnkey; that is not verified here and belongs to the epic-wide
  work, not this NMIS change.
- **Forgotten-admin-password recovery (`resetadminpw=1`).** Because NMIS now owns
  the admin credential, `setup_mongodb.pl resetadminpw=1` gives an operator a
  supported way to reset a forgotten one without hunting for the procedure
  elsewhere. MongoDB has no in-place reset for a forgotten password (the localhost
  exception only applies when *no* users exist), so the only supported mechanism is
  to restart mongod with `security.authorization: disabled`, run `updateUser`, then
  re-enable auth and restart - which is what this does (`reset_admin_password`,
  `set_mongo_authorization`). It is standalone/local/root only: it refuses on a
  remote server, a non-root caller, or a replica set (whose keyfile internal auth
  this does not disable). Auth is re-enabled even if the reset fails partway, so a
  failure never leaves the server permanently unauthenticated; the new password is
  verified by logging in with it. It is recorded in the credential file, and the
  file's writability is proved (non-destructively - a temp file beside the target,
  never the target itself) after the confirmation gate but BEFORE MongoDB is
  touched, so a recovery run never changes the server password and then fails to
  record a generated one, and an aborted/declined run makes no filesystem change. New
  password source: `newpasswordfile=<path>` (a file, so the secret never reaches
  argv/`ps`/`/proc/cmdline`/logs), else an interactive prompt, else generated; a
  bare `newpassword=` on the command line is refused with a warning. Unattended
  runs require `resetconfirm=1` to acknowledge the brief window. For that window
  mongod is pinned to `net.bindIp=127.0.0.1` and the original binding is restored
  afterwards, so a normally network-bound server is not exposed while
  unauthenticated. Accepted residual: after `updateUser` succeeds the record write
  only warns-and-continues if it fails (a disk-full / O_EXCL race in the narrow
  window between the passing pre-flight probe and the write); dying there would be
  worse than warning, so it is a conscious choice, not an open bug. NOT part of
  OMK-12826 - added opportunistically while this area was open.
- **The legacy (<2.0) MongoDB driver is no longer supported.** `lib/NMISNG/DB.pm`
  now requires the 2.x driver (`use MongoDB 2.0.0`) and fails at load otherwise, so
  the old run-time `authenticate()` loop (which hardcoded `('admin', $db_name)` and
  would not reach a scoped user living only in `nmisng`) is removed rather than
  fixed. On the 2.x driver authentication is done at connection creation from the
  authSource client arg (`_auth_source_args`), which is the path the scoped user
  actually uses. The 1.x driver cannot talk to the shipped MongoDB 7.0 anyway.
  Residual: `installer_hooks/30-pre-dependencies` still installs the distro
  `libmongodb-perl` (1.x on older distros) with no forced upgrade to 2.x, so an
  upgraded host retaining a 1.x driver would fail at load with no clear message.
  Near-zero population (1.x cannot reach MongoDB 7.0); tracked as **OMK-12924**.
- **Installer hook 24 now fails on a failed mandatory setup.** It captures
  `setup_mongodb.pl`'s exit code and returns non-zero, so `run_hooks` aborts the
  install rather than completing it as successful while NMIS cannot authenticate.
  The container path already fails hard because `docker-entrypoint.sh` runs under
  `set -e`.

**Why:** `opUserRW` was one MongoDB identity with the `root` role, shared by
NMIS and every other OMK product on the host, all authenticating with the
same shipped default password (`op42flow42`). Anyone who read the published
default, or a config file from any one OMK product, had root on every OMK
product's database on that host. Rotating that shared identity from NMIS
alone would have broken the other products immediately (and their next
install would rotate it back and break NMIS), so the supported fix is a
per-product scoped user rather than a rotation of the shared one. The
detect-only warning in `installer_hooks/common_dbpassword.sh` (OMK-12709)
makes the exposure visible on an un-migrated install without touching
`db_password` itself, since this hook must never rotate or block.

**Delegated functionality affected.** A site that relied on the shared
`opUserRW`/`root` identity to let one MongoDB login administer the databases
of several OMK products now needs the per-product scoped-user setup for
each; there is no single shared credential to fall back to. The MongoDB
administrative/bootstrap credential is now supplied separately from the
app's own credential (`NMIS_DB_ADMIN_USERNAME`/`NMIS_DB_ADMIN_PASSWORD` in
the Docker path, or the interactive prompt on a host install), so a caller
that only ever set `db_username`/`db_password` and expected it to double as
the admin login must now supply the admin pair too.

**Upgrade note.** An existing install migrates automatically the next time
`admin/setup_mongodb.pl` is run: it maps `db_username eq 'opUserRW'` (or
empty) to `nmis9RW`, provisions that user, and generates a password only if
the effective one is still a shipped default. `opUserRW` itself is left
exactly as it was, so the migration is additive rather than destructive.
`db_auth_source` is phased in the same run: it is only written once the
scoped user is provisioned, so an install that has not yet run setup keeps
authenticating against `admin` with no config change required.

**Two distinct passwords in the container path.** Every compose file now feeds
the scoped app user its own `${MONGODB_APP_PASSWORD}`, separate from the mongo
root/admin `${MONGODB_PASSWORD}`. In production, `make prod-setup` generates both
as distinct random values into `conf-default/docker/.env`, and `make prod-up`
refuses to start while either is still empty or a known default (the deny-set is
shared from `installer_hooks/common_dbpassword.sh`, not just a `CHANGE_ME`
check). The root `compose.yaml`/`.env` (not driven by the Makefile) ship both
empty for the operator to fill with distinct strong values before first start.

**`docker-dev/.env-dev` ships working credentials, deliberately.** Unlike
`conf-default/docker/.env` (which ships the `CHANGE_ME_run_make_prod-setup`
placeholders and refuses to start until `make prod-setup` replaces them, see the
root `Makefile`), the dev compose env fixes `MONGODB_PASSWORD=nmis9devMongoRW`
(root/admin) and `MONGODB_APP_PASSWORD=nmis9devAppRW` (scoped app) so the stack
comes up without an extra setup step. This is not a hardening gap: `MONGODB_BIND_ADDR`
defaults to `127.0.0.1` in that file (H12 / OMK-12708), so the Mongo it
authenticates is not reachable off the host, and the values are not secrets. Both
must stay off `setup_mongodb.pl`'s deny-set (`''`, `example`, `password`,
`op42flow42`, `CHANGE_ME*`), or setup would generate a random password for
`nmis9RW` while the app keeps authenticating with the fixed one.

**Mitigations to investigate (not implemented)**

- *TLS/certificate auth for the admin bootstrap connection:* the admin
  credential still travels as a plaintext env var or interactive prompt for
  that one bootstrap connection. Related to the transport work in H14
  (OMK-12710).
- *Per-product credential rotation tooling:* nothing here gives an operator a
  supported way to rotate `nmis9RW`'s password after initial provisioning
  short of re-running `setup_mongodb.pl` with a new `db_password` already in
  place. Worth a dedicated rotation path if this comes up in practice.

---

### SEC-1, SEC-2 / OMK-12695, OMK-12713 — device and config secrets encrypted at rest by default

**Files:** `conf-default/Config.nmis`,
`conf-default/docker/Config.nmis.docker`

**What changed**

| Key | Before | After |
|-----|--------|-------|
| `global_enable_password_encryption` in `conf-default/Config.nmis` | `'false'` | `'true'` |
| `global_enable_password_encryption` in `conf-default/docker/Config.nmis.docker` | `'false'` | `'true'` |

Nothing else moves. The machinery this switches on is already shipped and
already tested (OMK-12827 Slices A to C, fail-closed crypto, `master_key_file`
resolution, the `NMISNG::Node::new` write guard, the install-time and
container master-key provisioning). This entry is the flip of the two shipped
defaults and nothing more.

With the flag on, two classes of secret change form on disk:

- **SEC-1, device credentials.** `NMISNG::Node::new` converts a node's
  `community`, `authpassword`, `privpassword`, `authkey`, `privkey` and
  `wmipassword` to `!!`-prefixed ciphertext the first time the node is loaded,
  and saves. The node object then carries the stored ciphertext, and
  `NMISNG::Snmp` decrypts each credential at the point it builds the session.
- **SEC-2, config secrets.** `NMISNG::Util::decrypt`, when it is handed a
  section and a keyword, brings the stored form of that field in
  `conf/Config.nmis` into line with the current setting. Every
  `PasswordFields.nmis` entry therefore moves to `!!` as it is used, starting
  with `db_password` on the first database connect of every process.

**Why:** until now a shipped NMIS stored every device credential and every
config secret as cleartext, in `conf/Config.nmis` (mode 0660, group `nmis`, so
readable by the web tier and by any local account in that group) and in the
`nodes` collection in MongoDB. Any read of a config file, a support archive, a
MongoDB dump or a filesystem backup yielded working SNMP, WMI and mail
credentials for the whole estate. The encryption existed and was off, so the
protection was available to every site that knew to look for it and to no site
that did not. The default is the only part of that a release can fix.

**Fresh installs only, and the mechanics that make it so.** An existing install
does not start encrypting on upgrade, on any of the three delivery paths.

- *Host install.* `installer_hooks/10-postcopy-confmerges` runs
  `admin/updateconfig.pl conf-default/Config.nmis conf/Config.nmis`, which adds
  only the entries the live config is missing and never overwrites one it
  already has. `global_enable_password_encryption` has shipped in
  `conf-default/Config.nmis` since January 2022, so an installed site's
  `conf/Config.nmis` already carries its own explicit copy, put there by an
  earlier upgrade's merge or by the GUI Config editor. The merge skips it and
  the site stays disabled. The narrow exception is a site whose
  `conf/Config.nmis` has no such entry at all, which would have the new `'true'`
  merged in and would begin encrypting lazily. That is the correct outcome and
  it is safe (already-plaintext values are read as-is and up-migrate as they are
  touched), but it is an upgrade that changes behaviour without the operator
  asking, so it belongs in the release note.
- *Production container.* The image bakes
  `conf-default/docker/Config.nmis.docker` to `conf/Config.nmis` at build time
  and `conf/` is a named volume. A named volume copies image content only on
  first use, so a fresh deployment gets the flipped config and a deployment
  whose `nmis_conf_data` volume is already populated keeps the config it has.
- *Dev container.* `docker-dev/docker-entrypoint-dev.sh` copies
  `Config.nmis.docker` to `conf/Config.nmis` only when that file is absent.

An existing site opts in with `bin/nmis-cli act=enable-eos` (root), restored by
OMK-12927. That converts every protected config field and every node secret in
one pass, rather than lazily.

**Delegated functionality affected.** Nobody loses a permission here. What
changes is that secrets stop being readable by anyone holding the data.

- Reading a credential out of `conf/Config.nmis`, out of a MongoDB dump or out
  of the `nodes` collection now yields `!!` ciphertext. Any runbook, script,
  monitoring check or config diff that scraped a secret from a file stops
  working, and there is no CLI that prints one back (`act=decrypt-password`
  stays deliberately unrestored, see OMK-12927).
- Config and node data stop being portable on their own. Copying a node
  document or a config file to another install, or restoring a backup onto a
  rebuilt host, produces unusable credentials unless the same master key goes
  with it. Two installs cannot share encrypted values without sharing the key.
- A support archive from an encrypted install carries ciphertext Firstwave
  cannot read. That is the point, and it is also a diagnosis cost. Credential
  problems now have to be reproduced on the customer's side.
- If the crypto modules are absent, encryption fails closed rather than
  silently degrading. Values stay plaintext, errors are logged per field and
  the selftest banner reports it. `installer_hooks/21-postcopy-encryption`
  warns at install time and names the packages. So a fresh install on a host
  without `Crypt::CBC`, `Crypt::Cipher::AES` and `Math::Random::Secure` ships
  with the flag on and nothing encrypted, which is visible but is not what the
  operator will assume from the setting.

**The master key becomes backup-critical material.** This is the operational
change that matters most, and it is new for every fresh install as of this
flip. The key is one line of 256 characters. Everything encrypted under it is
permanently unreadable without it. Reads fail closed, so a lost key does not
destroy data, it just makes those values unusable until they are re-entered by
hand for every node and every config secret.

The drill:

1. *Host install.* The key is `/usr/local/etc/firstwave/master.key`, created by
   `installer_hooks/21-postcopy-encryption` as `<webuser>:nmis` mode 0440. Back
   up that file with the same care and the same schedule as `conf/`, and keep
   it with the backup it belongs to. A backup of `conf/` and MongoDB without
   the key is not restorable.
2. *Container.* The key lives in the `nmis_master_key` volume mounted at
   `/usr/local/etc/firstwave`. Back up that volume alongside `nmis_conf_data`.
   Destroying it is the same as losing the key. Before removing a container,
   `docker cp <container>:/usr/local/etc/firstwave/master.key .`. The entrypoint
   warns loudly when it has generated a fresh key on a boot whose
   `conf/Config.nmis` already contains `!!` values, which is exactly the shape
   of a lost-volume accident.
3. *Restore order.* The key goes back first, or with `conf/` and the MongoDB
   dump, never after. A restore that brings back data and not the key looks
   successful and then fails at every SNMP poll.
4. *Never rotate or relocate an existing key.* There is no re-key path (see the
   mitigations below). Replacing a key makes every value already encrypted
   under the old one undecryptable.
5. *An operator-supplied key* is honoured instead of the generated one via
   `master_key_file` in the config or `NMIS_MASTER_KEY_FILE` in the
   environment. NMIS only ever creates a key at the shipped default path, so a
   custom location is provisioned and backed up by the operator.

**The way back is config-gated, and the flag alone is not it.**
`bin/nmis-cli act=disable-eos` (root) is the supported reversal. It walks every
`PasswordFields.nmis` entry and every node secret, writes each back in
plaintext, sets the flag to `'false'`, and, since OMK-12927, reports failure and
names the fields when any `!!` value could not be decrypted rather than claiming
success over ciphertext it cannot read.

Hand-editing the flag to `'false'` is not equivalent and should not be
documented as the way back. It converts nothing at the moment it is done.
Stored values move back to plaintext only lazily, a node at a time as each is
loaded and a config field at a time as each is passed through `decrypt` with its
section and keyword, and only for as long as the master key is still readable.
An install left in that state is half-converted, indefinitely, with no report of
what did or did not come back. The same applies in reverse: turning the flag on
by hand on an existing install encrypts new writes but leaves the existing
plaintext until something touches it, where `act=enable-eos` sweeps the lot in
one pass (and writes a root-only `NMIS-<epoch>` plaintext copy of every
protected secret into `/usr/local/etc/firstwave` first, see the mitigations).

**Mitigations to investigate (not implemented)**

- *No key rotation.* There is no supported way to re-key an install. The only
  route is `disable-eos` followed by `enable-eos`, which puts every secret back
  on disk in cleartext in between, on a host where the previous key may still be
  present. A `rotate-eos` that reads with the old key and writes with the new,
  without a plaintext intermediate, is the right shape and does not exist.
- *The `NMIS-<epoch>` plaintext dump is never cleaned up.* `enable-eos` writes a
  root-only cleartext copy of every protected secret into
  `/usr/local/etc/firstwave` before converting, and nothing expires or removes
  it. That directory is also where the master key lives and, in the container,
  is the volume operators are now told to back up. A backup of it therefore
  carries both the key and a cleartext copy of everything the key protects.
  Expiry, an opt-out, or a different location for the dump all want
  investigating.
- *Backing up the master key is documentation, not tooling.* Nothing in
  `admin/support.pl` or in any shipped backup path knows the key exists. The
  drill above depends entirely on the operator having read it. A backup
  pre-flight that refuses, or at least warns, when `conf/` is being archived
  without the key would make the dependency visible.
- *No first-boot confirmation that encryption actually took.* The install hook
  warns about missing modules and the runtime selftest raises an alert, but
  neither answers "are this install's secrets encrypted right now". An operator
  reading `global_enable_password_encryption => 'true'` will assume they are. A
  status act reporting how many protected fields and node secrets are currently
  `!!`, and how many are not, would close that gap.

---

## Open threads to investigate (epic-wide, not tied to one change)

These came up while reviewing OMK-12707 and are recorded so they are not lost.
None are implemented.

- **Command surfaces reachable by delegated roles → RCE with that privilege.**
  This is the pattern behind "RCE with the correct privileges." Candidates:
  - `Toolset` table (`table_toolset_rw`, level 1) maps GUI buttons to functions
    in `cgi-bin/tools.pl`, which does run system commands. **Investigate**
    whether a non-admin writing Toolset can point a button at an arbitrary
    command/`func`, or whether `tools.pl` allowlists its dispatch. If exploitable:
    make Toolset admin-only, or constrain the values.
  - `Escalations` table (`table_escalations_rw`, levels 1/2) maps events to
    notify targets/backends. The direct command-injection notify paths (C5/C6)
    are separate, already-closed tickets; the residual question is whether
    writing Escalations itself reaches a program-exec path. **Investigate.**
  - Service-check `Program` running through a shell as root (C7 / OMK-12692) —
    already tracked; noted here because it is the "drop privileges on the exec
    path" half of the same problem.
- **Log viewer authorization (`cgi-bin/logs.pl`).** The arbitrary file read found
  in the OMK-12707 review is closed, see the OMK-12823 entry under
  [Changes from former defaults](#changes-from-former-defaults). Its two
  residuals are recorded there and neither is implemented, the
  `CheckAccess($logName)` binding (admin-reachable only, since `table_logs_rw`
  is now admin-only) and the shell pipe in `loadLogFile`.
- **Multi-tenancy is not actually enforced by the role model.** Default
  `manager` has `groups => 'all'`. To be "fully multi-tenanted", a manager needs
  to be "admin *within a tenant*" — a tenant/group boundary enforced on every
  read and write — rather than "global admin minus a few tables". Strategic item,
  not a patch.
- **`disableEOS` writes the flag to disk before it verifies.** The down-migration
  sweep sets `global_enable_password_encryption` to `'false'` first and only
  then walks the fields. When a `!!` value cannot be decrypted the run now
  reports failure and names the survivors (OMK-12927 wart A), but the flag on
  disk is already off while ciphertext remains in the file. The install is
  half-converted and reads take the disabled path over values that still need
  the key. The fix is to verify first and write the flag only on a clean sweep.
  Pre-existing ordering, out of scope for OMK-12695. **Ticket to follow.**
- **`act=enable-eos` exits 1 on SUCCESS.** `enableEOS`/`disableEOS` return 1 for
  success, and the restored dispatch does `exit($rc)`, so the shell sees a
  failure when the act worked (`act=check-eos` is the same: exit 1 means
  enabled). This is the historical contract and the restored help text
  documents it, so OMK-12927 restored it verbatim rather than silently
  inverting it. It is a scripting hazard: any installer, runbook or wrapper
  that tests the exit status reads a successful enable as a failure. Changing
  it is a breaking change for whatever already shells out to these acts.
  **Ticket to follow.**
- **`Auth->new` defaults `privlevel => 0` (fail-open).** The OMK-12707 guard
  denies unless `privlevel == 0`, so an Auth object never initialised by login
  would be treated as admin. Verified not reachable on any current web write
  path, but a deny-by-default seed (e.g. 5) would harden against future callers.

---

## Hardening tool concept

Not scoped, not a requirement for any current ticket. Captured so the register
above is built in a shape that can feed it.

Idea: a guided, reversible config-hardening tool the operator can engage with.

- Presents each shipped-default → hardened-default change, in plain language:
  what it protects against, and what functionality it affects (both drawn from
  this register).
- Lets the operator pick a posture — e.g. "locked down" vs "delegated
  administration enabled" — and shows the concrete Access/Config changes each
  posture applies before applying them.
- Each change is individually toggleable and revertible, with the risk of
  reverting stated.
- Because it reads from this register, keeping the register current is what
  keeps the tool honest. Every entry here should carry enough structure
  (change, rationale, functionality impact, revert risk) to render a tool row.

---

## Maintenance

When a hardening change tightens a shipped default, add an entry under
[Changes from former defaults](#changes-from-former-defaults) with: the right(s)
or key(s) changed, before/after, why, the delegated functionality affected, and
mitigation options to investigate. Keep mitigation notes as *investigation*
until a ticket implements them, then link the ticket.
