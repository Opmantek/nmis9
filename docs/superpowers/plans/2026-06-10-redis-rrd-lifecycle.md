# Redis RRD Write Path + Push-Node Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a push (redis) node's collect reach the data/RRD pass by treating redis as a first-class polling source, surface a misconfigured push model as a `"Model File Invalid"` node event, and add the missing redis-to-RRD regression coverage.

**Architecture:** Add `redis` to `Sys::known_sources` so the existing generic per-source machinery (status flags, `collect_node_info` up/down + `last_poll_redis`, `disable_source`) handles it uniformly. Propagate `redis_error` in `getData` like the other sources. In `update_node_info`, where `"Model File Invalid"` is already raised/cleared at model load, also require a system-level redis section for push nodes. Close the test gap by capturing `create_update_rrd` calls instead of stubbing them silently.

**Tech Stack:** Perl, MongoDB via `NMISNG::DB`, `Test::More`, the existing `NMISNG::Sys::Engine::Redis`.

**Spec:** `docs/superpowers/specs/2026-06-10-redis-rrd-lifecycle-design.md`.

**Convention:** end each commit message with the trailer
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- **Modify** `lib/NMISNG/Sys.pm` — add `redis` to `known_sources` (135); copy `redis_error` in `getData` (1207).
- **Modify** `lib/NMISNG/Node.pm` — in `update_node_info`, after the model loads, raise/clear `"Model File Invalid"` for push nodes missing a system-level redis section (~2491-2499).
- **Create** `models-default/Model-TestRedisNoSys.nmis` — a push test model with a `systemHealth` redis section but **no** system-level redis section, for the model-error test.
- **Modify** `test/t_polling_redis.pl` — capture `create_update_rrd` calls; add known_sources/status assertions; add the model-error test; add the RRD-write regression.

---

## Task 1: redis is a known source

**Files:**
- Modify: `lib/NMISNG/Sys.pm:135`
- Test: `test/t_polling_redis.pl` (in the existing `SKIP:` block, after the Task 7 engine-presence assertion near line 328)

- [ ] **Step 1: Write the failing assertions**

In `test/t_polling_redis.pl`, find the existing line in the `SKIP:` block:

```perl
    ok((grep { $_->protocol_name eq 'redis' } @{$S->engines}),
       "redis engine present in Sys when wantredis + redis_enabled");
```

Immediately after it, add:

```perl
    ok((grep { $_ eq 'redis' } @{$S->known_sources}),
       "redis is in Sys::known_sources");
    is($S->status->{redis_enabled}, 1,
       "Sys::status surfaces redis_enabled=1 when the engine is active");
    ok(exists $S->status->{redis_error},
       "Sys::status surfaces a redis_error key (undef when no error)");
```

- [ ] **Step 2: Run, expect failure**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: the `known_sources` and `redis_enabled` assertions FAIL (redis absent from known_sources, so status never sets `redis_enabled`).

- [ ] **Step 3: Add redis to known_sources**

In `lib/NMISNG/Sys.pm:135`, change:

```perl
sub known_sources { return [qw(snmp wmi http)]; }
```

to:

```perl
sub known_sources { return [qw(snmp wmi http redis)]; }
```

- [ ] **Step 4: Run, expect pass**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: the three new assertions PASS (or SKIP cleanly only if MongoDB is unavailable).

- [ ] **Step 5: HTTP regression (no perturbation)**

Run: `cd /usr/local/nmis9 && perl test/t_polling_http.pl`
Expected: still passes. An snmp/wmi/http node has no redis engine, so `redis_enabled=0` and every per-source loop skips it.

- [ ] **Step 6: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys.pm test/t_polling_redis.pl
git commit -m "feat(redis): make redis a first-class known source

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: propagate redis_error in getData

**Files:**
- Modify: `lib/NMISNG/Sys.pm:1204-1207`
- Test: covered by Task 1's `redis_error` key assertion plus the regression in Task 5; this task is a one-line mirror with a syntax check.

- [ ] **Step 1: Add the redis_error copy**

In `lib/NMISNG/Sys.pm`, the `getData` method copies per-call status errors onto `$self`:

```perl
	$self->{error}      = $status->{error};
	$self->{wmi_error}  = $status->{wmi_error};
	$self->{snmp_error} = $status->{snmp_error};
	$self->{http_error} = $status->{http_error};
	$self->{skipped}    = $status->{skipped} // 0;
```

Add a `redis_error` line after the `http_error` line, so the block reads:

```perl
	$self->{error}      = $status->{error};
	$self->{wmi_error}  = $status->{wmi_error};
	$self->{snmp_error} = $status->{snmp_error};
	$self->{http_error} = $status->{http_error};
	$self->{redis_error} = $status->{redis_error};
	$self->{skipped}    = $status->{skipped} // 0;
```

- [ ] **Step 2: Syntax check**

Run: `cd /usr/local/nmis9 && perl -Ilib -c lib/NMISNG/Sys.pm`
Expected: `lib/NMISNG/Sys.pm syntax OK`.

- [ ] **Step 3: Full redis test still passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: passes (no regression).

- [ ] **Step 4: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys.pm
git commit -m "feat(redis): propagate redis_error from getData to Sys status

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: model error for push model missing a system-level redis section

**Files:**
- Create: `models-default/Model-TestRedisNoSys.nmis`
- Modify: `lib/NMISNG/Node.pm` (in `update_node_info`, the model-load `else` branch ~2491-2499)
- Test: `test/t_polling_redis.pl` (new block inside the `SKIP:` block, before `$ng->get_db()->drop();`)

- [ ] **Step 1: Create the no-system-section test model**

Create `models-default/Model-TestRedisNoSys.nmis`:

```perl
#
# Model-TestRedisNoSys.nmis - push (redis) test model that deliberately has NO
# system-level redis section, only a systemHealth section. Used by
# test/t_polling_redis.pl to verify the "Model File Invalid" model-error path.
# Not for real devices.
#
%hash = (
	'-common-' => {
		'class' => {
			'database' => { 'common-model' => 'database' }
		},
	},
	'system' => {
		'nodegraph' => 'health',
		'nodeModel' => 'TestRedisNoSys',
		'nodeType'  => 'generic',
	},
	'systemHealth' => {
		'sections' => 'sdwan_uplink',
		'sys' => {
			'sdwan_uplink' => {
				'indexed'   => 'wan_interface',
				'index_oid' => 'wan_interface',
				'headers'   => 'wan_interface,status,latency',
				'redis' => {
					'-common-'      => { 'concept' => 'sdwan_uplink', 'engine' => 'meraki', 'freshness' => 600 },
					'wan_interface' => { 'field' => 'wan_interface', 'title' => 'WAN interface' },
					'status'        => { 'field' => 'status', 'title' => 'Status' },
					'latency'       => { 'field' => 'latency_ms', 'title' => 'Latency (ms)' },
				},
			},
		},
	},
);
```

- [ ] **Step 2: Write the failing test**

In `test/t_polling_redis.pl`, inside the `SKIP:` block, immediately before the final `$ng->get_db()->drop();` line, add:

```perl
    # ---- Model error: push model with no system-level redis section ----
    {
        my @notified;
        no warnings 'redefine';
        # capture notify calls (the file's top-level stub is a no-op; override
        # it locally so we can see what event update_node_info raises).
        local *Compat::NMIS::notify = sub { push @notified, {@_}; return; };

        my $bad = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
        $bad->cluster_id($C->{cluster_id});
        $bad->name("t_redis_nosys_node");
        $bad->activated({ NMIS => 1 });
        $bad->configuration({
            host => "127.0.0.1", group => "TestGroup", netType => "default",
            roleType => "default", model => "TestRedisNoSys", collect => "true",
            ping => "false", nmisent_engine_type => "meraki",
        });
        $bad->save();
        $bad->update(force => 1);

        ok((grep { ($_->{event} // '') eq "Model File Invalid" } @notified),
           "push model with no system-level redis section raises Model File Invalid")
            or diag("notify events: ".join(",", map { $_->{event} // '?' } @notified));
    }
```

- [ ] **Step 3: Run, expect failure**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: the new assertion FAILS — `update_node_info` does not yet raise the event for a semantically-incomplete push model.

- [ ] **Step 4: Add the model-error check in update_node_info**

In `lib/NMISNG/Node.pm`, the `update_node_info` model-load adjudication currently reads:

```perl
				if( !$model_load_success ) {
					Compat::NMIS::notify(
						sys     => $S,
						event   => "Model File Invalid",
						details => "Model $catchall_data->{nodeModel} could not be loaded",
						context => {type => "node"},
						inventory_id => $catchall_inventory->{_id}{hex}
					);
				}
				else {
					Compat::NMIS::checkEvent(
						sys     => $S,
						event   => "Model File Invalid",
						level   => "Normal",						
						details => "Model $catchall_data->{nodeModel} loaded",
						inventory_id => $catchall_inventory->{_id}{hex}
					);
				}	
```

Replace the `else { ... }` branch with one that also validates the push-node requirement:

```perl
				else {
					# Model file loaded. For push (manages_own_inventory) nodes the
					# model MUST declare a system-level redis section, otherwise
					# loadInfo(class=>system) never succeeds and collect can never
					# reach the data/RRD pass. Treat a missing section as a model
					# error, surfaced through the same node event.
					my $push_active = grep { $_->is_active && $_->manages_own_inventory } @{$S->engines};
					my $has_system_redis = 0;
					my $sysblk = $S->{mdl}{system}{sys};
					if (ref $sysblk eq 'HASH') {
						for my $sec (values %$sysblk) {
							if (ref $sec eq 'HASH' && ref $sec->{redis} eq 'HASH') {
								$has_system_redis = 1;
								last;
							}
						}
					}

					if ($push_active && !$has_system_redis) {
						Compat::NMIS::notify(
							sys     => $S,
							event   => "Model File Invalid",
							details => "Model $catchall_data->{nodeModel} is push-sourced (redis) but declares no system-level redis section",
							context => {type => "node"},
							inventory_id => $catchall_inventory->{_id}{hex}
						);
					}
					else {
						Compat::NMIS::checkEvent(
							sys     => $S,
							event   => "Model File Invalid",
							level   => "Normal",						
							details => "Model $catchall_data->{nodeModel} loaded",
							inventory_id => $catchall_inventory->{_id}{hex}
						);
					}
				}	
```

- [ ] **Step 5: Run, expect pass**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: the model-error assertion PASSES. (The compliant `TestRedis` node elsewhere in the file must not raise it — it has a system-level redis section.)

- [ ] **Step 6: Syntax check + commit**

```bash
cd /usr/local/nmis9
perl -Ilib -c lib/NMISNG/Node.pm
git add lib/NMISNG/Node.pm models-default/Model-TestRedisNoSys.nmis test/t_polling_redis.pl
git commit -m "feat(redis): raise Model File Invalid when a push model lacks a system section

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: redis-to-RRD regression test

**Files:**
- Modify: `test/t_polling_redis.pl` (the top-of-file `create_update_rrd` stub, and the Task 11 e2e block)

This closes the coverage gap: prove `create_update_rrd` is actually called for redis-sourced systemHealth data. `last_update` is planted so the collect proceeds deterministically past the `!last_update` divert (the divert is intentionally unchanged by this work).

- [ ] **Step 1: Make the create_update_rrd stub record calls**

In `test/t_polling_redis.pl`, the top-of-file stub currently reads:

```perl
# Skip RRD I/O (RRD lib not linked here) — same approach as t_polling_http.pl.
{
    no warnings 'redefine';
    *NMISNG::Sys::create_update_rrd = sub {
        my ($self, %args) = @_;
        if (ref($args{inventory})) {
            my $type = $args{type} || 'unknown';
            $args{inventory}->set_subconcept_type_storage(
                subconcept => $type, type => 'rrd',
                data => "/nodes/$self->{name}/mock-$type.rrd"
            );
        }
        return 1;
    };
}
```

Replace it with a version that records each call into `@main::RRD_CALLS`:

```perl
# Skip RRD I/O (RRD lib not linked here) — same approach as t_polling_http.pl —
# but RECORD each call so a test can assert the RRD writer is actually invoked
# for redis-sourced data.
our @RRD_CALLS;
{
    no warnings 'redefine';
    *NMISNG::Sys::create_update_rrd = sub {
        my ($self, %args) = @_;
        push @main::RRD_CALLS, {
            type  => $args{type},
            index => $args{index},
            data  => { map { $_ => $args{data}{$_}{value} } keys %{ $args{data} // {} } },
        };
        if (ref($args{inventory})) {
            my $type = $args{type} || 'unknown';
            $args{inventory}->set_subconcept_type_storage(
                subconcept => $type, type => 'rrd',
                data => "/nodes/$self->{name}/mock-$type.rrd"
            );
        }
        return 1;
    };
}
```

- [ ] **Step 2: Add the failing assertion in the e2e block**

In `test/t_polling_redis.pl`, in the Task 11 e2e block, the first collect currently reads:

```perl
        {
            no warnings 'redefine';
            local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

            $rnode->collect(wantsnmp => 0, wantwmi => 0, wanthttp => 0, wantredis => 1, force => 1);

            my $ids = $rnode->get_inventory_ids(concept => 'sdwan_uplink', filter => { historic => 0 });
            ok(scalar(@$ids) == 2, "two sdwan_uplink rows after first collect")
                or diag("got ".scalar(@$ids));
```

Replace that opening through the `two sdwan_uplink rows` assertion with a version that plants `last_update` (so collect proceeds rather than diverting to update) and asserts the RRD write:

```perl
        {
            no warnings 'redefine';
            local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

            # Plant last_update so collect proceeds to the data/RRD pass instead
            # of diverting to update (the !last_update divert is intentionally
            # unchanged by this work; we are testing the proceed path).
            {
                my ($ci, $cierr) = $rnode->inventory(concept => "catchall");
                my $cd = $ci->data();
                $cd->{last_update} = time();
                $ci->data($cd);
                $ci->save(node => $rnode);
            }

            @main::RRD_CALLS = ();
            $rnode->collect(wantsnmp => 0, wantwmi => 0, wanthttp => 0, wantredis => 1, force => 1);

            my $ids = $rnode->get_inventory_ids(concept => 'sdwan_uplink', filter => { historic => 0 });
            ok(scalar(@$ids) == 2, "two sdwan_uplink rows after first collect")
                or diag("got ".scalar(@$ids));

            # The point of polling: redis data must reach the RRD writer.
            my @uplink_rrd = grep { ($_->{type} // '') eq 'sdwan_uplink' } @main::RRD_CALLS;
            ok(scalar(@uplink_rrd) >= 1,
               "create_update_rrd called for sdwan_uplink (redis -> RRD path)")
                or diag("RRD calls: ".join(",", map { ($_->{type}//'?')."[".($_->{index}//'')."]" } @main::RRD_CALLS));
            my %lat = map { ($_->{index} // '') => $_->{data}{latency} } @uplink_rrd;
            ok((defined $lat{wan1} && $lat{wan1} == 24),
               "wan1 latency (24) reached the RRD writer")
                or diag("wan1 latency at RRD writer: ".(defined $lat{wan1} ? $lat{wan1} : 'undef'));
```

(The rest of the e2e block — the wan2-drop reseed, the second collect, and the `one live sdwan_uplink row` assertion — stays unchanged. The block's closing braces are unchanged.)

- [ ] **Step 3: Run, confirm pass**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: the two new RRD assertions PASS (with Tasks 1-3 applied, a compliant `TestRedis` node whose collect proceeds writes `sdwan_uplink` RRD). If they FAIL, do NOT adjust the assertions — investigate whether collect is still diverting (check that `last_update` was planted and that `updatewasok` is true), and report.

- [ ] **Step 4: Commit**

```bash
cd /usr/local/nmis9
git add test/t_polling_redis.pl
git commit -m "test(redis): assert collect writes sdwan_uplink RRD (close the gap)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: full regression sweep

**Files:** none (verification only)

- [ ] **Step 1: Run the redis test**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: all assertions pass (or controlled SKIP for the MongoDB block).

- [ ] **Step 2: Run the regression set**

```bash
cd /usr/local/nmis9
perl test/t_polling_http.pl
perl test/t_polling.pl
perl test/t_sys.pl
```
Expected: each ends at its existing pass count, no new failures. The `known_sources` change and the `update_node_info` model-error branch must not perturb snmp/wmi/http nodes (no redis engine -> `redis_enabled=0`, `$push_active` false, so the new `else`-branch logic takes the existing `checkEvent` path).

- [ ] **Step 3: Syntax-check modified files**

```bash
cd /usr/local/nmis9
for f in lib/NMISNG/Sys.pm lib/NMISNG/Node.pm; do perl -Ilib -c "$f" || echo "SYNTAX FAIL: $f"; done
```
Expected: `syntax OK` for each.

- [ ] **Step 4: Commit any fixes**

If steps 1-3 needed fixes, commit them:

```bash
cd /usr/local/nmis9
git add -A
git commit -m "test(redis): regression fixes from RRD-lifecycle sweep

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage**
- Add `redis` to `known_sources` (spec §1) — Task 1.
- Propagate `redis_error` in `getData` (spec §2) — Task 2.
- `"Model File Invalid"` for push model missing a system-level redis section (spec §3) — Task 3.
- Reachability/events fall out of `known_sources` (spec §4) — covered by Task 1's change; asserted indirectly by the status surface and the unchanged regression suites.
- Accepted behaviour: first-collect divert unchanged (spec §5) — Task 4 plants `last_update` precisely because the divert is unchanged.
- Tests (spec testing section): status surface (Task 1), redis→RRD (Task 4), model error (Task 3), non-perturbation (Tasks 1/5).

**Notes for the implementer**
- The compliant `TestRedis` model already has a system-level redis section (`sdwan_health`), so it must NOT raise `"Model File Invalid"`. The no-system model is the new `TestRedisNoSys`.
- `Compat::NMIS::notify` is stubbed no-op at the top of the test file; Task 3 overrides it locally to capture the call. Don't remove the top-level stub — other parts of the file rely on it.
- The RRD write already works once collect proceeds past the divert; Task 4 plants `last_update` to make that deterministic rather than depending on a second update pass.

**Placeholder scan:** none. **Type/name consistency:** `known_sources`, `redis_enabled`, `redis_error`, `manages_own_inventory`, `@main::RRD_CALLS`, `"Model File Invalid"`, and the `system.sys.<section>.redis` shape are used identically across tasks.
