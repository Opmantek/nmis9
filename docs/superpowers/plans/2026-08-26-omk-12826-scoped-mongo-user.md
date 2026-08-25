# OMK-12826 + OMK-12709 Scoped Mongo User Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give NMIS its own `nmisng`-scoped Mongo user (dbOwner, generated password) authenticated via authSource, so the runtime is no longer MongoDB root and no longer shares `opUserRW`, closing OMK-12826 and OMK-12709.

**Architecture:** A phased switch. `DB.pm` gains an authSource client arg driven by a new `db_auth_source` config key that is empty by default (legacy behaviour) and only set once `setup_mongodb.pl` provisions the scoped user and writes the new credential into `conf/`. `setup_mongodb.pl` stops managing `opUserRW`, uses a separate admin credential to bootstrap, and generates the app password. A detect-only helper warns when an install is still on a shipped default.

**Tech Stack:** Perl 5, MongoDB Perl driver, `NMISNG::DB`, `NMISNG::Util`, `admin/patch_config.pl`, POSIX shell (installer hooks), `Test::More`, Docker Compose.

**Spec:** `docs/superpowers/specs/2026-08-21-omk-12826-scoped-mongo-user-design.md`.

## Global Constraints

- The runtime must never authenticate as MongoDB `root`. It authenticates as a user scoped to `nmisng` via authSource.
- NMIS must never `createUser`, `updateUser`, or `grantRolesToUser` on `opUserRW`, and never grant the `root` role to anyone.
- `db_password` is generated per install and must never ship as a working default. `conf-default` ships a non-working placeholder recognized by the default-password check.
- authSource is phased: `db_auth_source` absent or empty means authenticate against `admin` (today's behaviour). `conf-default` ships it set to `nmisng`. `setup_mongodb.pl` writes it into `conf/` only when it has successfully provisioned the scoped user. A failed setup never rewrites `conf/`.
- Default app username is `nmis9RW`. On upgrade, an existing `db_username` of `opUserRW` migrates to `nmis9RW`; any other existing value is kept.
- The admin/bootstrap credential is separate from `db_username`/`db_password`: `NMIS_DB_ADMIN_USERNAME` / `NMIS_DB_ADMIN_PASSWORD` env, else the existing interactive prompt, defaulting to `opUserRW` and the current admin password.
- The default-password check is detect-only. It never rotates a password.
- Password generation reuses the `/dev/urandom` then `Math::Random::Secure` fallback pattern from `installer_hooks/common_authkey.sh` (`nmis_authkey_generate`).
- One branch and pull request into `nmis9_sec`. A `docs/security-hardening-register.md` entry is required before the PR.
- Tests run in the container `nmis9-12826-test` (to be created, worktree mounted at `/usr/local/nmis9`). Shell and pure-Perl tests need no Mongo. The setup test needs a disposable Mongo.

## File Structure

- `installer_hooks/common_dbpassword.sh` — create. Detect-only classifier for a shipped-default `db_password`. Sourced by the installer hook and the entrypoints.
- `test/t_common_dbpassword.t` — create. Drives the helper's shell functions.
- `lib/NMISNG/DB.pm` — modify. Add the authSource client arg via a small pure helper.
- `test/t_db_auth_source.t` — create. Unit-tests the authSource decision without Mongo.
- `conf-default/Config.nmis` — modify. `db_username`, `db_password` placeholder, `db_auth_source`.
- `conf-default/docker/Config.nmis.docker` — modify. `db_auth_source`.
- `admin/setup_mongodb.pl` — modify. Separate admin credential, provision the scoped user, generate + write the password and authSource, stop managing `opUserRW`, never grant root.
- `test/t_setup_mongodb_scoped_user.t` — create. Mongo-backed behavioural test.
- `docker-dev/compose-dev.yaml`, `docker-dev/.env-dev` — modify. Provision and use the scoped user + authSource; keep the root user as admin bootstrap.
- `installer_hooks/24-postcopy-setup-mongodb` — modify. Mandatory-setup message; wire the default-password warning.
- `ci/scripts/perl_tests.sh` — modify. Register the new tests.
- `docs/security-hardening-register.md` — modify. Add the entry.

---

### Task 1: Detect-only default-password helper

**Files:**
- Create: `installer_hooks/common_dbpassword.sh`
- Create: `test/t_common_dbpassword.t`
- Modify: `ci/scripts/perl_tests.sh`

**Interfaces:**
- Produces: shell functions `nmis_dbpassword_is_insecure <password>` (returns 0 if a shipped default or empty), `nmis_dbpassword_classify <basedir>` (sets `NMIS_DBPASSWORD_USER`, `NMIS_DBPASSWORD_FROM_ENV`; returns 0 not-default, 1 default-from-env, 2 default-from-file, 3 unknown), `nmis_dbpassword_advice <username>` (prints the warning).

- [ ] **Step 1: Create the helper**

Copy the file from the earlier work at `/home/md/claude-tmp/nmis9-wt-omk-12709/installer_hooks/common_dbpassword.sh` into `installer_hooks/common_dbpassword.sh`. It is complete and correct as written (POSIX sh, no side effects at source time, `is_insecure`/`classify`/`advice`). Then make two wording updates, because this change adds the per-product path the file said did not exist:

In `nmis_dbpassword_advice`, replace the last three `WARNING:` lines with:
```sh
	echo "WARNING: Do NOT hand-edit db_password to a new value: on an un-migrated install"
	echo "WARNING: this MongoDB user is shared with the other OMK products on this host."
	echo "WARNING: Run 'admin/setup_mongodb.pl' to migrate NMIS to its own scoped database"
	echo "WARNING: user with a generated password (OMK-12709, OMK-12826)."
```

Leave the header comment's explanation of why rotation is unsafe in place, since it is still true for an un-migrated install, but append one line after the `API` block:
```sh
# After setup_mongodb.pl has migrated NMIS to its own scoped user, db_password is
# no longer a shipped default, so classify returns 0 and this helper stays quiet.
```

- [ ] **Step 2: Write the failing test**

Create `test/t_common_dbpassword.t`:
```perl
#!/usr/bin/perl
# OMK-12709: the detect-only default-password classifier.
use strict; use warnings;
use FindBin;
use Test::More;

my $helper = "$FindBin::Bin/../installer_hooks/common_dbpassword.sh";
ok(-f $helper, "common_dbpassword.sh exists");

# Drive the shell functions through /bin/sh, the interpreter the installer uses.
sub sh_is_insecure {
	my ($pw) = @_;
	my $q = $pw; $q =~ s/'/'\\''/g;
	my $rc = system("/bin/sh", "-c", ". '$helper'; nmis_dbpassword_is_insecure '$q'");
	return $rc == 0 ? 1 : 0;   # function returns 0 (shell true) when insecure
}

ok(sh_is_insecure('op42flow42'),  "the shipped default op42flow42 is insecure");
ok(sh_is_insecure('example'),     "the docker default example is insecure");
ok(sh_is_insecure('password'),    "password is insecure");
ok(sh_is_insecure(''),            "empty is insecure");
ok(!sh_is_insecure('a-real-generated-9f3c2a1b'), "a generated value is not flagged");

# advice mentions the migration path and the username
my $advice = qx{/bin/sh -c ". '$helper'; nmis_dbpassword_advice 'opUserRW'"};
like($advice, qr/opUserRW/, "advice names the user");
like($advice, qr/setup_mongodb\.pl/, "advice points at the migration tool");
unlike($advice, qr/simply edit|just change/i, "advice does not tell them to just edit db_password");

done_testing();
```

- [ ] **Step 3: Run it to verify RED then GREEN**

Run: `docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && /usr/bin/prove -v test/t_common_dbpassword.t"`
Before Step 1's advice edit the `unlike(...simply edit...)` assertion fails; after the edits all pass. If the helper file is missing the first `ok` fails.

- [ ] **Step 4: Register the test**

In `ci/scripts/perl_tests.sh`, add `t_common_dbpassword.t` to the `working_tests` array.

- [ ] **Step 5: Commit**

```bash
git add installer_hooks/common_dbpassword.sh test/t_common_dbpassword.t ci/scripts/perl_tests.sh
git commit -m "sec: OMK-12709 add detect-only shipped-default db_password check"
```

---

### Task 2: DB.pm authSource support

**Files:**
- Modify: `lib/NMISNG/DB.pm` (`get_db_connection`, around lines 1020-1057)
- Create: `test/t_db_auth_source.t`
- Modify: `ci/scripts/perl_tests.sh`

**Interfaces:**
- Produces: `NMISNG::DB::_auth_source_args($CONF)` returning a list `(db_name => <source>)` when `$CONF->{db_auth_source}` is set and non-empty, otherwise an empty list. `get_db_connection` splices that list into its MongoClient args.

- [ ] **Step 1: Write the failing test**

Create `test/t_db_auth_source.t`:
```perl
#!/usr/bin/perl
# OMK-12826: DB.pm authenticates against db_auth_source when set (authSource),
# and keeps the driver default (admin) when it is absent, so legacy installs are
# unchanged. Pure unit test of the arg-building helper; no Mongo needed.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::DB;

is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => 'nmisng' }) ],
	[ db_name => 'nmisng' ],
	"sets db_name => nmisng when db_auth_source is set");

is_deeply([ NMISNG::DB::_auth_source_args({ db_auth_source => '' }) ], [],
	"empty db_auth_source adds nothing (legacy: driver defaults to admin)");

is_deeply([ NMISNG::DB::_auth_source_args({}) ], [],
	"absent db_auth_source adds nothing (legacy)");

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

Run: `docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && /usr/bin/prove -v test/t_db_auth_source.t"`
Expected: FAIL, `_auth_source_args` not defined.

- [ ] **Step 3: Add the helper and use it**

In `lib/NMISNG/DB.pm`, add near the other package subs:
```perl
# OMK-12826: the MongoDB auth source (the db the user's credential lives in).
# When db_auth_source is set the runtime authenticates against it (the driver's
# db_name attribute / authSource). When empty or absent the driver defaults to
# 'admin', which is the pre-OMK-12826 behaviour, so legacy installs are unchanged.
sub _auth_source_args
{
	my ($CONF) = @_;
	my $src = $CONF->{db_auth_source};
	return () unless (defined($src) && $src ne '');
	return (db_name => $src);
}
```
Then, inside `get_db_connection`, add the arg to `@clientargs` (right after the `username`/`password`/`connect_timeout_ms` block, around line 1048):
```perl
		_auth_source_args($CONF),
```

- [ ] **Step 4: Run it to verify it passes**

Run: `docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && /usr/bin/prove -v test/t_db_auth_source.t"`
Expected: PASS. Also `docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && perl -Ilib -c lib/NMISNG/DB.pm"` → syntax OK.

- [ ] **Step 5: Register and commit**

Add `t_db_auth_source.t` to `ci/scripts/perl_tests.sh`.
```bash
git add lib/NMISNG/DB.pm test/t_db_auth_source.t ci/scripts/perl_tests.sh
git commit -m "sec: OMK-12826 authenticate against db_auth_source when set"
```

---

### Task 3: Config defaults

**Files:**
- Modify: `conf-default/Config.nmis` (database block, lines 2-10)
- Modify: `conf-default/docker/Config.nmis.docker` (database block)

**Interfaces:**
- Produces: shipped defaults `db_username => 'nmis9RW'`, `db_password => 'CHANGE_ME_RUN_setup_mongodb'`, `db_auth_source => 'nmisng'`. The placeholder must satisfy `nmis_dbpassword_is_insecure` from Task 1 (its `CHANGE_ME*` case matches).

- [ ] **Step 1: Edit `conf-default/Config.nmis`**

In the `'database'` block change:
```perl
	'db_password' => 'CHANGE_ME_RUN_setup_mongodb',
	'db_username' => 'nmis9RW',
	'db_auth_source' => 'nmisng',
```
(Keep `db_name`, `db_port`, `db_server`, `db_query_timeout`, `db_never_remove_indices` as they are.)

- [ ] **Step 2: Edit `conf-default/docker/Config.nmis.docker`**

In its `'database'` block add:
```perl
    'db_auth_source' => 'nmisng',
```
(The docker config sets no `db_username`/`db_password`; those arrive via `NMIS_DB_*` env. Task 5 sets the env.)

- [ ] **Step 3: Verify the placeholder is recognized and configs still load**

Run:
```bash
docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && /bin/sh -c '. installer_hooks/common_dbpassword.sh; nmis_dbpassword_is_insecure CHANGE_ME_RUN_setup_mongodb'; echo rc=\$?"
docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && perl -Ilib -e 'use NMISNG::Util; my \$c = NMISNG::Util::readFiletoHash(file=>\"conf-default/Config.nmis\"); die qq(bad) unless ref \$c; print \"loads ok\n\"'"
```
Expected: `rc=0` (placeholder recognized as insecure) and `loads ok`.

- [ ] **Step 4: Commit**

```bash
git add conf-default/Config.nmis conf-default/docker/Config.nmis.docker
git commit -m "sec: OMK-12826 ship scoped db_username, placeholder db_password, db_auth_source"
```

---

### Task 4: setup_mongodb.pl provisions the scoped user

**Files:**
- Modify: `admin/setup_mongodb.pl` (admin-credential resolution ~184-243; the `opUserRW` admin block 269-306; the nmisng user block 308-352)
- Create: `test/t_setup_mongodb_scoped_user.t`
- Modify: `ci/scripts/perl_tests.sh`

**Interfaces:**
- Consumes: config `db_username`, `db_password`, `db_name`, `db_auth_source`; env `NMIS_DB_ADMIN_USERNAME`, `NMIS_DB_ADMIN_PASSWORD`; `admin/patch_config.pl <configfile> "/database/<key>=<value>"`.
- Produces: after a run, `nmisng.<target_app_user>` exists with role `dbOwner` on `nmisng`; `conf/Config.nmis` holds that username, a generated password, and `db_auth_source=nmisng`; `opUserRW` is untouched and no user holds a newly-granted `root`.

- [ ] **Step 1: Resolve the admin credential separately from the app credential**

Replace the current admin-credential lines (`$adminuser = $conf->{db_username}` at 184 and `$adminpwd = NMISNG::Util::decrypt($conf->{db_password}...)` at 187) with a resolution that prefers env, then prompt, then defaults to `opUserRW`:
```perl
# OMK-12826: the admin/bootstrap credential is SEPARATE from the app credential.
# db_username/db_password now hold NMIS's own scoped app account, so setup must
# not use them to authenticate as admin. Prefer env for unattended installs,
# else the interactive prompt below, else default to the legacy shared admin.
my $adminuser = $ENV{NMIS_DB_ADMIN_USERNAME} // 'opUserRW';
my $adminpwd  = $ENV{NMIS_DB_ADMIN_PASSWORD}
	// NMISNG::Util::decrypt($conf->{db_password}, 'database', 'db_password');
```
Keep the existing interactive prompt block (190-243) but have it default to `$adminuser`/`$adminpwd` as resolved above rather than to `$conf->{db_username}`/`db_password`. (The prompt already exists; only its default source changes.)

- [ ] **Step 2: Remove all management of `opUserRW`**

Delete the admin-db user block that creates/grants/updates `opUserRW` (lines 269-306, from `my $userlist = ... "usersInfo" ... user => $adminuser, db => "admin"` through the matching `else { ... updateUser ... }`). NMIS no longer creates or rotates the admin account. It only authenticates as it (Step 1) to bootstrap.

- [ ] **Step 3: Provision the scoped app user with a generated password**

Replace the nmisng user block (308-352) with logic that (a) picks the target app username, migrating `opUserRW` to `nmis9RW`, (b) generates a password, (c) creates or updates that user with `dbOwner`, and (d) writes the credential and authSource into `conf/`:
```perl
# OMK-12826/OMK-12709: NMIS's own scoped app user in the nmisng database.
my $dbname   = $conf->{db_name} // 'nmisng';
my $dbhandle = $conn->get_database($dbname);

# Target app username: migrate the shared opUserRW to nmis9RW; keep any other
# existing choice (a site may already have a custom scoped user).
my $target_user = ($conf->{db_username} // 'opUserRW');
$target_user = 'nmis9RW' if ($target_user eq 'opUserRW' || $target_user eq '');

# App password. Honour an operator- or env-supplied value; generate one only
# when the effective value is a shipped default or the ship placeholder. This
# keeps the docker/env path (which supplies NMIS_DB_PASSWORD) and a real install
# (which ships a placeholder) both correct, and never overwrites a deliberate
# password. The default set mirrors installer_hooks/common_dbpassword.sh.
my $curpw = NMISNG::Util::decrypt($conf->{db_password}, 'database', 'db_password') // '';
my $is_default = ($curpw eq '' || $curpw eq 'op42flow42' || $curpw eq 'example'
	|| $curpw eq 'password' || $curpw =~ /^CHANGE_ME/);
my $genpw = $curpw;
my $generated = 0;
if ($is_default)
{
	# Prefer the kernel CSPRNG, fall back to Math::Random::Secure, as
	# nmis_authkey_generate does. 32 bytes as 64 hex chars.
	$genpw = '';
	if (open(my $ur, '<:raw', '/dev/urandom')) {
		my $b; $genpw = unpack('H*', $b) if (read($ur, $b, 32) == 32);
		close($ur);
	}
	if (length($genpw) != 64) {
		eval { require Math::Random::Secure;
		       $genpw = join('', map { sprintf('%08x', Math::Random::Secure::irand()) } 1..8); 1 } or $genpw = '';
	}
	die "ERROR: could not generate a database password (need /dev/urandom or Math::Random::Secure)\n"
		if (length($genpw) != 64);
	$generated = 1;
}

my $userlist = NMISNG::DB::run_command(db => $dbhandle,
	command => { "usersInfo" => { user => $target_user, db => $dbname } });
if (!$userlist or !$userlist->{users} or !@{$userlist->{users}})
{
	print "INFO: creating scoped user $target_user in $dbname (dbOwner)\n";
	my $r = NMISNG::DB::run_command(db => $dbhandle,
		command => Tie::IxHash->new("createUser" => $target_user, "pwd" => $genpw,
			"roles" => [ { role => 'dbOwner', db => $dbname } ]));
	die "creating $target_user failed: " . (ref($r) eq 'HASH' ? $r->{errmsg} : $r) . "\n"
		if (ref($r) ne 'HASH' || !$r->{ok});
}
else
{
	print "INFO: updating scoped user $target_user in $dbname (dbOwner, new password)\n";
	my $r1 = NMISNG::DB::run_command(db => $dbhandle,
		command => Tie::IxHash->new("updateUser" => $target_user, "pwd" => $genpw,
			"roles" => [ { role => 'dbOwner', db => $dbname } ]));
	die "updating $target_user failed: " . (ref($r1) eq 'HASH' ? $r1->{errmsg} : $r1) . "\n"
		if (ref($r1) ne 'HASH' || !$r1->{ok});
}

# Only now that the user exists, switch the live config over. patch_config.pl
# writes conf/Config.nmis. A failed provisioning above dies before this point,
# so a broken run never leaves the config pointing at a user that was not made.
my $cfgfile = $conf->{configfile};
my @writes = ("/database/db_username=$target_user", "/database/db_auth_source=$dbname");
# Persist db_password only when we generated it. An operator/env-supplied value
# is honoured for the user above but not written to disk, so an env-only secret
# does not get persisted into conf/Config.nmis.
push @writes, "/database/db_password=$genpw" if ($generated);
for my $kv (@writes)
{
	system($conf->{'<nmis_base>'} . "/admin/patch_config.pl", $cfgfile, $kv) == 0
		or die "ERROR: failed to write $kv to $cfgfile\n";
}
$genpw = "x" x 64; undef $genpw;
print "INFO: NMIS is now configured to use scoped user $target_user in $dbname.\n";
```

- [ ] **Step 4: Write the Mongo-backed behavioural test**

Create `test/t_setup_mongodb_scoped_user.t`. It stands up a disposable mongo (see Step 5 for how it is provided), runs `setup_mongodb.pl` against a throwaway conf, and asserts the outcome. Because it needs Mongo, guard it to skip loudly (BAIL_OUT) only if no `NMIS_TEST_MONGO_URI` is provided, and run it in the setup harness of Step 5:
```perl
#!/usr/bin/perl
# OMK-12826/OMK-12709: setup_mongodb.pl provisions a scoped nmisng user, never
# touches opUserRW, never grants root, and writes a generated password + authSource.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
BEGIN { $ENV{NMIS_TEST_MONGO_URI} or BAIL_OUT("set NMIS_TEST_MONGO_URI to a disposable mongo admin URI to run this test"); }
# ... connect as admin, run setup_mongodb.pl auto=1 against a temp conf dir whose
# Config.nmis starts with db_username=opUserRW, then assert via usersInfo:
#   * nmisng.nmis9RW exists with role dbOwner on nmisng and NOT root
#   * the temp Config.nmis now has db_username=nmis9RW, a 64-char db_password, db_auth_source=nmisng
#   * opUserRW in admin was not created or modified by the run (compare before/after)
done_testing();
```
The full body is completed against the harness in Step 5; the assertions above are the contract.

- [ ] **Step 5: Run it against a disposable mongo**

Provide a throwaway mongo for the test and run it:
```bash
docker run -d --name nmis9-12826-mongo --network container:nmis9-12826-test mongo:7.0 --noauth
docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && NMIS_TEST_MONGO_URI=mongodb://localhost:27017 /usr/bin/prove -v test/t_setup_mongodb_scoped_user.t"
docker rm -f nmis9-12826-mongo
```
Expected: PASS. (If networking a sidecar mongo proves awkward in this environment, report it — the assertions are the contract and the reviewer/CI can run them where a Mongo is reachable.)

- [ ] **Step 6: Register and commit**

Add `t_setup_mongodb_scoped_user.t` to `ci/scripts/perl_tests.sh`.
```bash
git add admin/setup_mongodb.pl test/t_setup_mongodb_scoped_user.t ci/scripts/perl_tests.sh
git commit -m "sec: OMK-12826 provision a scoped nmisng user, stop managing opUserRW and root"
```

---

### Task 5: Docker path, installer hook wiring, and hardening register

**Files:**
- Modify: `docker-dev/compose-dev.yaml`, `docker-dev/.env-dev`
- Modify: `installer_hooks/24-postcopy-setup-mongodb`
- Modify: `docs/security-hardening-register.md`

**Interfaces:**
- Consumes: env keys `NMIS_DB_ADMIN_USERNAME`/`NMIS_DB_ADMIN_PASSWORD` (Task 4), `NMIS_DB_AUTH_SOURCE` (maps to `db_auth_source` via `_apply_env_overrides`), the helper functions from Task 1.

- [ ] **Step 1: Docker compose and env**

In `docker-dev/compose-dev.yaml`, under the `nmis` service `environment:`, add:
```yaml
      NMIS_DB_ADMIN_USERNAME: ${MONGODB_USERNAME}
      NMIS_DB_ADMIN_PASSWORD: ${MONGODB_PASSWORD}
      NMIS_DB_AUTH_SOURCE: nmisng
```
and change the app credential the container runs with so it is the scoped user, not the mongo root user. Set:
```yaml
      NMIS_DB_USERNAME: nmis9RW
```
Leave `NMIS_DB_PASSWORD` supplied for the app account. The entrypoint's `setup_db` runs `setup_mongodb.pl`, which authenticates as admin (the compose root user via the new admin env) and creates `nmis9RW` with the effective `NMIS_DB_PASSWORD` value, because Task 4 honours a supplied, non-default password rather than generating one. So the user's password and the app's runtime password match with no conflict, and setup does not write that env-supplied secret into `conf/`.

- [ ] **Step 2: Wire the default-password warning into the installer hook**

Read `installer_hooks/24-postcopy-setup-mongodb`. Add, near the top after it resolves the install base dir, a sourced call to the Task 1 helper that warns but does not block:
```sh
. "$NMIS_BASE/installer_hooks/common_dbpassword.sh"
nmis_dbpassword_classify "$NMIS_BASE" && rc=0 || rc=$?
if [ "$rc" = 1 ] || [ "$rc" = 2 ]; then
	nmis_dbpassword_advice "$NMIS_DBPASSWORD_USER"
fi
```
(Use the hook's existing variable for the base dir; `$NMIS_BASE` here is illustrative.) Also make the decline branch of the setup prompt state plainly that database setup is now mandatory for NMIS to authenticate, rather than optional.

- [ ] **Step 3: Add the hardening register entry**

Append an entry to `docs/security-hardening-register.md` following the file's existing format, recording: the keys changed (`db_username` opUserRW → nmis9RW; `db_password` op42flow42 → generated/placeholder; new `db_auth_source` = nmisng; the dropped `root` grant and the stopped `opUserRW` management); why (shared root identity, shared default password); the delegated functionality affected (a site relying on the shared `opUserRW`/root identity across OMK apps now needs the per-product setup, and the admin credential is supplied separately); and the upgrade note (setup migrates on next run; `opUserRW` untouched). Follow the file's own `## Maintenance` section for the exact field layout.

- [ ] **Step 4: Verify and commit**

Run `docker exec nmis9-12826-test bash -c "cd /usr/local/nmis9 && /bin/sh -n installer_hooks/24-postcopy-setup-mongodb && /bin/sh -n installer_hooks/common_dbpassword.sh"` → no syntax errors.
```bash
git add docker-dev/compose-dev.yaml docker-dev/.env-dev installer_hooks/24-postcopy-setup-mongodb docs/security-hardening-register.md
git commit -m "sec: OMK-12826 docker env, installer default-password warning, hardening register"
```

---

## Security-fix gate, before the pull request

- [ ] Adversarial review of the auth changes: confirm no path grants `root`, no path touches `opUserRW`, and a failed setup never rewrites `conf/`.
- [ ] A review by a different model, treated as the gate.
- [ ] Full suite green in the container, including the Mongo-backed setup test where a Mongo is reachable.

## Self-review notes

- Spec coverage: authSource (Task 2), scoped user + generated password + stop root/opUserRW + admin split (Task 4), config defaults (Task 3), default-password detection (Task 1), docker + installer + register (Task 5), upgrade path (Task 4 migration logic + phased authSource default in Tasks 2/3).
- The setup test (Task 4) is the one part that genuinely needs Mongo; its assertions are the contract and it is guarded to fail loudly rather than skip silently. Its full body is completed against the Step 5 harness, which is the one place the plan cannot pre-write exact code because the sidecar-Mongo networking must be confirmed in the environment.
- The docker app-password path is resolved: setup honours the env-supplied `NMIS_DB_PASSWORD` (non-default) for both the created user and runtime, so there is no generated-versus-env conflict.
