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

`table_authldapprivs_rw` (AuthLdapPrivs) was already admin-only; unchanged.

Plus code enforcement independent of the matrix: `CheckAccessCmd` and
`CheckButton` now deny these five rights to any non-admin regardless of what the
live `Access.nmis` says (needed because an upgraded install keeps its old,
permissive `conf/Access.nmis`). A deny-by-default `TableRegistered()` allowlist
was added to the table editor.

**Why:** each of these tables feeds back into authentication or authorization,
so any write is equivalent to becoming admin. Confirmed vuln per the ticket.

**Delegated functionality lost**

- **Manager can no longer add/edit/remove user accounts.** This is the real
  loss — the "onboard a new employee or customer" workflow the role was built
  for. Currently unrecoverable without the constraints in the mitigation notes.
- **Manager can no longer edit PrivMap** (privilege→level definitions). Little
  everyday value; this is an admin function. Low loss.
- **Manager and engineer can no longer edit the Access matrix.** Meta-authorization;
  editing it is self-evidently escalation. Low loss.
- **Manager and engineer can no longer edit global Config.** Mixed loss: removes
  a genuine operational-tuning capability (thresholds, polling, mail, display)
  *and* the escalation vector, with no separation between them.

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
- **`table_tables_rw` (Tables registry) is still writable by manager/engineer.**
  Does not defeat the OMK-12707 fix (the admin-only guard keys on rights, and
  writes use the request's table name, not the registry). But letting non-admins
  rewrite the master table registry is an integrity concern. Separate ticket.
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
