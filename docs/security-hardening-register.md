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

**Files:** `conf-default/Access.nmis`, `lib/NMISNG/Auth.pm`, `cgi-bin/tables.pl`

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

Plus code enforcement independent of the matrix: `CheckAccessCmd` and
`CheckButton` deny these seven rights to any non-admin regardless of what the
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

**Operator opt-out — `auth_lock_sensitive_tables`** (config, default `true`).
The guard is gated by this flag. Default (or any value that is not an exact
false token) keeps it enforced; setting it to an exact false token
(`false`/`no`/`0`, any case, surrounding whitespace allowed) makes the seven
guarded rights defer to the Access matrix again — i.e. restores the pre-fix
behaviour. This is the supported way for a customer who needs "the old way" to
get it back, without a source edit. It is deliberately coarse and blunt:
flipping it re-opens all seven rights at once, including the never-safe ones
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
- **Multi-tenancy is not actually enforced by the role model.** Default
  `manager` has `groups => 'all'`. To be "fully multi-tenanted", a manager needs
  to be "admin *within a tenant*" — a tenant/group boundary enforced on every
  read and write — rather than "global admin minus a few tables". Strategic item,
  not a patch.
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
