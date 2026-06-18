# Redis/SD-WAN Node Reachability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive `nodestatus` reachable/unreachable for cloud-managed redis push nodes (Meraki, HPE GreenLake, Aruba) from the device-reported status nmisent delivers, gated by nmisent producer liveness so a producer outage cannot flap the fleet.

**Architecture:** A pure per-engine status map turns the raw vendor status into a canonical value. The nmisent `:9464` Prometheus endpoint is modelled as an ordinary HTTP node (one inventory row per engine). A plugin on that node raises a per-engine producer-stale event. During a redis device collect, a producer-gated step maps the canonical status onto the existing `handle_down(type => 'node')` path, which `coarse_status` already turns into reachable/unreachable.

**Tech Stack:** Perl, the existing NMISNG HTTP and Redis engines, NMIS `.nmis` models and plugins, MongoDB via `NMISNG::DB`, `Test::More`.

**Spec:** `docs/superpowers/specs/2026-06-18-redis-reachability-design.md`.

## Global Constraints

- Branch: `feat/sdwan-polling`.
- Commit messages: no `Co-Authored-By` trailer.
- Perl: do not use the `unless` keyword; use a negated `if`.
- Test models stay standalone fixtures (do not point tests at product models).
- Canonical status values are exactly `up`, `down`, `degraded`, `unknown`. `unknown` must never assert reachable.
- Producer-stale threshold: `now - last_success_epoch > 2 * interval`.
- This sub-project delivers reachable/unreachable only. `degraded` holds (no nodestatus change). Absent device data holds (the documented went-dark case).

---

## Task 1: Status normalisation map

**Files:**
- Create: `lib/NMISNG/Sys/Engine/Redis/Status.pm`
- Test: `test/t_redis_status.pl`

**Interfaces:**
- Produces: `NMISNG::Sys::Engine::Redis::Status::canonical($engine, $raw)` returning one of `'up'|'down'|'degraded'|'unknown'`. Pure, no I/O.

- [ ] **Step 1: Write the failing test**

Create `test/t_redis_status.pl`:

```perl
#!/usr/bin/perl
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use NMISNG::Sys::Engine::Redis::Status;

my $c = \&NMISNG::Sys::Engine::Redis::Status::canonical;

is($c->('meraki','online'),   'up',       'meraki online -> up');
is($c->('meraki','offline'),  'down',     'meraki offline -> down');
is($c->('meraki','alerting'), 'degraded', 'meraki alerting -> degraded');
is($c->('meraki','dormant'),  'degraded', 'meraki dormant -> degraded');
is($c->('hpe_greenlake','ONLINE'),  'up',   'greenlake ONLINE -> up');
is($c->('hpe_greenlake','UP'),      'up',   'greenlake/aruba UP -> up (union)');
is($c->('hpe_greenlake','OFFLINE'), 'down', 'greenlake OFFLINE -> down');
is($c->('MERAKI','Online'),  'up',      'engine and value are case-insensitive');
is($c->('meraki','wedged'),  'unknown', 'unrecognised value -> unknown');
is($c->('newvendor','online'),'unknown','unknown engine -> unknown');
is($c->('meraki',undef),     'unknown', 'undef raw -> unknown');
is($c->(undef,'online'),     'unknown', 'undef engine -> unknown');

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_redis_status.pl`
Expected: FAIL, `Can't locate NMISNG/Sys/Engine/Redis/Status.pm`.

- [ ] **Step 3: Write the module**

Create `lib/NMISNG/Sys/Engine/Redis/Status.pm`:

```perl
#
# NMISNG::Sys::Engine::Redis::Status - raw vendor status to canonical status.
# Pure, no NMIS state, no I/O. The raw vendor string is stored elsewhere for
# display; this only derives the value the reachability logic acts on.
# 'unknown' is returned for anything unrecognised and must never be treated
# as reachable by callers. Aruba APs use the hpe_greenlake engine with a
# different vocabulary than GreenLake switches, so hpe_greenlake is the union
# of both; the canonical values do not collide.
#
package NMISNG::Sys::Engine::Redis::Status;
use strict;
use warnings;
our $VERSION = "1.0.0";

my %MAP = (
	'meraki' => {
		'online'   => 'up',
		'offline'  => 'down',
		'alerting' => 'degraded',
		'dormant'  => 'degraded',
	},
	'hpe_greenlake' => {
		'online'  => 'up',
		'up'      => 'up',
		'offline' => 'down',
	},
);

# args: engine, raw status. returns: up|down|degraded|unknown
sub canonical
{
	my ($engine, $raw) = @_;
	return 'unknown' if (!defined $engine || !defined $raw);
	my $emap = $MAP{ lc $engine };
	return 'unknown' if (!$emap);
	return $emap->{ lc $raw } // 'unknown';
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_redis_status.pl`
Expected: PASS, all assertions ok.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Sys/Engine/Redis/Status.pm test/t_redis_status.pl
git commit -m "feat(redis): canonical device-status map (per-engine, NMIS-side)"
```

---

## Task 2: nmisent producer HTTP model

**Files:**
- Create: `models-default/Model-nmisent.nmis`
- Create: `models-default/Graph-nmisent_poll_age.nmis`
- Test: `test/t_nmisent_model.pl`

**Interfaces:**
- Produces: model `nmisent` with a `systemHealth` concept `nmisent_poll`, indexed by the prom label `engine`, whose inventory rows carry data fields `index` (the engine), `last_success_epoch`, `interval`, `partial_total`. RRD path `database.type.nmisent_poll`. The nmisent instance is provisioned as one node using `model => 'nmisent'` and an `http_endpoints` entry named `nmisent` pointing at `:9464` (deployment step, not code).

- [ ] **Step 1: Write the failing test**

Create `test/t_nmisent_model.pl`:

```perl
#!/usr/bin/perl
# Verifies the nmisent producer model parses and that the HTTP engine
# discovers one inventory row per {engine} label from a fixture /metrics body.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib"; use lib "$FindBin::Bin/lib";
use Test::More;
use NMISNG::Sys::Engine::HTTP;
use NMISNG::Test::Fakes;

# model parses
my %hash;
my $content = do { local $/; open my $fh, '<', "$FindBin::Bin/../models-default/Model-nmisent.nmis" or die $!; <$fh> };
eval $content; die "parse failed: $@" if $@;
is($hash{system}{nodeModel}, 'nmisent', 'nmisent model parses, nodeModel set');
my $sec = $hash{systemHealth}{sys}{nmisent_poll};
ok($sec && $sec->{indexed} eq 'engine', 'nmisent_poll indexed by engine label');
ok($sec->{http_prom}{last_success_epoch}{metric} eq 'nmisent_poll_last_success_epoch',
   'last_success_epoch sources the right prom metric');
ok($hash{database}{type}{nmisent_poll}, 'database.type.nmisent_poll present');

# label discovery: one row per engine from a fixture body
my $body = join("\n",
  '# TYPE nmisent_poll_last_success_epoch gauge',
  'nmisent_poll_last_success_epoch{engine="meraki"} 1781000000',
  'nmisent_poll_last_success_epoch{engine="hpe_greenlake"} 1781000050',
  'nmisent_poll_interval_seconds{engine="meraki"} 60',
  'nmisent_poll_interval_seconds{engine="hpe_greenlake"} 120', '');
my $sys = NMISNG::Test::FakeSys->new;
my $eng = NMISNG::Sys::Engine::HTTP->new(sys => $sys);
$eng->set_endpoints([{ name => 'nmisent', port => 9464 }]);
no warnings 'redefine';
local *NMISNG::Sys::Engine::HTTP::_fetch = sub { return ($body, undef); };
my ($err, $idx) = $eng->discover_indexes(
  section_config => { indexed => 'engine',
    http_prom => { '-common-' => { endpoint => 'nmisent' },
      last_success_epoch => { metric => 'nmisent_poll_last_success_epoch' } } },
  index_var => 'engine');
is($err, undef, 'discover_indexes: no error');
is_deeply([sort @$idx], ['hpe_greenlake','meraki'], 'one index per engine label');

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_nmisent_model.pl`
Expected: FAIL opening `Model-nmisent.nmis` (no such file). (Confirm the `_fetch` method name against `lib/NMISNG/Sys/Engine/HTTP.pm` before relying on the stub; adjust the `local *` line to the actual fetch sub if it differs.)

- [ ] **Step 3: Write the model**

Create `models-default/Model-nmisent.nmis`:

```perl
#
# Model-nmisent.nmis - the nmisent producer, modelled as an HTTP node polling
# its Prometheus endpoint (:9464). One systemHealth row per {engine} label
# carrying poll-success epoch, configured interval, and partial-poll count.
# Provision one node with model => 'nmisent' and an http_endpoints entry
# named 'nmisent' pointing at the nmisent host:9464.
#
%hash = (
	'-common-' => { 'class' => { 'database' => { 'common-model' => 'database' } } },
	'database' => {
		'type' => { 'nmisent_poll' => '/nodes/$node/health/nmisent_poll-$index.rrd' },
	},
	'system' => {
		'nodegraph' => 'health',
		'nodeModel' => 'nmisent',
		'nodeType'  => 'generic',
	},
	'systemHealth' => {
		'sections' => 'nmisent_poll',
		'sys' => {
			'nmisent_poll' => {
				'indexed'   => 'engine',
				'index_oid' => 'engine',
				'headers'   => 'engine,last_success_epoch,interval,partial_total',
				'http_prom' => {
					'-common-'           => { 'endpoint' => 'nmisent' },
					'engine'             => { 'title' => 'Engine' },
					'last_success_epoch' => { 'metric' => 'nmisent_poll_last_success_epoch', 'title' => 'Last success (epoch)' },
					'interval'           => { 'metric' => 'nmisent_poll_interval_seconds',   'title' => 'Poll interval (s)' },
					'partial_total'      => { 'metric' => 'nmisent_poll_partial_total',      'title' => 'Partial polls' },
				},
			},
		},
		'rrd' => {
			'nmisent_poll' => {
				'graphtype' => 'nmisent_poll_age',
				'indexed'   => 'engine',
				'http_prom' => {
					'-common-'           => { 'endpoint' => 'nmisent' },
					'last_success_epoch' => { 'metric' => 'nmisent_poll_last_success_epoch', 'option' => 'gauge,0:U' },
					'interval'           => { 'metric' => 'nmisent_poll_interval_seconds',   'option' => 'gauge,0:U' },
				},
			},
		},
	},
);
```

Create `models-default/Graph-nmisent_poll_age.nmis`:

```perl
#
# Graph-nmisent_poll_age.nmis - per-engine seconds since the last successful
# nmisent poll, derived from now - last_success_epoch at render time.
#
%hash = (
	'heading' => 'nmisent Poll Age',
	'title'   => {
		'standard' => '$node $index - $length from $datestamp_start to $datestamp_end',
		'short'    => '$node $index - $length',
	},
	'vlabel' => { 'standard' => 'Seconds since last success', 'short' => 'Age (s)' },
	'option' => {
		'standard' => [
			'DEF:lse=$database:last_success_epoch:AVERAGE',
			'CDEF:age=TIME,lse,-',
			'LINE1:age#1E90FF: Poll age (s)\\n',
			'GPRINT:age:LAST:Now %1.0lf s',
			'GPRINT:age:MAX:Max %1.0lf s',
		],
		'small' => [
			'DEF:lse=$database:last_success_epoch:AVERAGE',
			'CDEF:age=TIME,lse,-',
			'LINE1:age#1E90FF: Poll age',
			'GPRINT:age:LAST:Now %1.0lf s\\n',
		],
	},
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_nmisent_model.pl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add models-default/Model-nmisent.nmis models-default/Graph-nmisent_poll_age.nmis test/t_nmisent_model.pl
git commit -m "feat(redis): nmisent producer modelled as an HTTP node, indexed by engine"
```

---

## Task 3: producer-stale event plugin

**Files:**
- Create: `conf-default/plugins/nmisentProducer.pm`
- Modify: `conf-default/Events.nmis` (register `nmisent Producer Stale`)
- Test: `test/t_nmisent_producer_plugin.pl`

**Interfaces:**
- Consumes: the `nmisent_poll` inventory rows from Task 2 (fields `last_success_epoch`, `interval`, `index`).
- Produces: per-engine event `nmisent Producer Stale` raised via `Compat::NMIS::notify` and cleared via `Compat::NMIS::checkEvent`, element = engine. A reusable predicate `NMISNG::Sys::Engine::Redis::Status` is NOT involved here; staleness is `now - last_success_epoch > 2 * interval`.

- [ ] **Step 1: Write the failing test**

Create `test/t_nmisent_producer_plugin.pl`:

```perl
#!/usr/bin/perl
# The collect plugin raises nmisent Producer Stale for an engine whose last
# success is older than 2x its interval, and clears it when fresh.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
require "$FindBin::Bin/../conf-default/plugins/nmisentProducer.pm";

# pure helper: stale decision
my $stale = \&nmisentProducer::is_stale;
ok( $stale->(time - 300, 60, time), 'age 300 > 2x60 -> stale');
ok(!$stale->(time - 30,  60, time), 'age 30 <= 2x60 -> fresh');
ok(!$stale->(undef,      60, time), 'missing epoch -> not stale (indeterminate, handled elsewhere)');
ok(!$stale->(time,    undef, time), 'missing interval -> not stale');

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_nmisent_producer_plugin.pl`
Expected: FAIL, cannot locate the plugin file.

- [ ] **Step 3: Write the plugin**

Create `conf-default/plugins/nmisentProducer.pm`:

```perl
#
# nmisentProducer.pm - collect plugin for the nmisent producer node.
# After the HTTP collect populates the nmisent_poll rows, evaluate each
# engine's poll age and raise/clear the per-engine "nmisent Producer Stale"
# event. Age is computed here, at collect time, where "now" is available.
#
package nmisentProducer;
use strict;
use warnings;
use NMISNG::Util;

# pure: is this engine's poll stale? age = now - last_success_epoch, vs 2x interval.
# missing inputs are NOT stale here (indeterminate is handled by producer_state).
sub is_stale
{
	my ($last_success_epoch, $interval, $now) = @_;
	return 0 if (!defined $last_success_epoch || !defined $interval || $interval <= 0);
	return (($now - $last_success_epoch) > (2 * $interval)) ? 1 : 0;
}

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $nmisng) = @args{qw(node sys config nmisng)};
	my $nobj = $nmisng->node(name => $node);
	return (0, undef) if (!$nobj);
	return (0, undef) if (($nobj->configuration->{model} // '') ne 'nmisent');

	my $now = time;
	my $ids = $nobj->get_inventory_ids(concept => 'nmisent_poll');
	for my $id (@$ids)
	{
		my ($inv) = $nobj->inventory(_id => $id);
		next if (!$inv);
		my $d = $inv->data;
		my $engine = $d->{index};
		next if (!defined $engine);
		my $stale = is_stale($d->{last_success_epoch}, $d->{interval}, $now);
		if ($stale)
		{
			Compat::NMIS::notify(
				sys     => $S,
				event   => "nmisent Producer Stale",
				element => $engine,
				level   => "Major",
				details => "nmisent has not completed a poll for engine $engine within 2x its interval",
				context => { type => "node" },
				inventory_id => $inv->id,
			);
		}
		else
		{
			Compat::NMIS::checkEvent(
				sys     => $S,
				event   => "nmisent Producer Stale",
				element => $engine,
				level   => "Normal",
				details => "nmisent poll for engine $engine is fresh",
				inventory_id => $inv->id,
			);
		}
	}
	return (0, undef);
}

1;
```

- [ ] **Step 4: Register the event**

In `conf-default/Events.nmis`, add alongside the other redis events:

```perl
  'nmisent Producer Stale' => {
    'Event' => 'nmisent Producer Stale',
    'Notify' => 'true',
    'Status' => 'true',
    'Log' => 'true',
    'Stateful' => 'true',
    'Description' => 'nmisent has not completed a successful poll for an engine within 2x its configured interval. Raised per engine on the nmisent producer node.',
  },
```

- [ ] **Step 5: Run test to verify it passes**

Run: `perl test/t_nmisent_producer_plugin.pl`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add conf-default/plugins/nmisentProducer.pm conf-default/Events.nmis test/t_nmisent_producer_plugin.pl
git commit -m "feat(redis): producer-stale event plugin for the nmisent node"
```

---

## Task 4: producer_state lookup + config pointer

**Files:**
- Modify: `lib/NMISNG/Node.pm` (add method `producer_state`, near `handle_down`)
- Modify: `conf-default/Config.nmis` (add `nmisent_producer_node`)
- Modify: `conf-default/Events.nmis` (register `nmisent Producer Misconfigured`)
- Test: `test/t_polling_redis.pl`

**Interfaces:**
- Consumes: Config `nmisent_producer_node` (a node name); the `nmisent_poll` inventory from Task 2.
- Produces: `$node->producer_state($engine)` returning `($state, $detail)` where `$state` is `'up'|'stale'|'unknown'`. On `unknown` it raises a deduplicated `nmisent Producer Misconfigured` event. Used by Task 5.

- [ ] **Step 1: Write the failing test**

Add to `test/t_polling_redis.pl` inside the existing live-DB `SKIP:` block (it already builds `$ng` and nodes):

```perl
# ---- producer_state tri-state ----
{
    # no producer node configured -> unknown
    local $C->{nmisent_producer_node};
    delete $C->{nmisent_producer_node};
    my $dev = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
    my ($st) = $dev->producer_state('meraki');
    is($st, 'unknown', 'no producer node configured -> unknown');

    # provision a producer node with one fresh and one stale engine row
    my $prod = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
    $prod->cluster_id($C->{cluster_id});
    $prod->name("t_nmisent_producer");
    $prod->activated({ NMIS => 1 });
    $prod->configuration({ host => "127.0.0.1", group => "TestGroup", netType => "default",
        roleType => "default", model => "nmisent", collect => "true", ping => "false" });
    $prod->save();
    for my $row ([ 'meraki', time, 60 ], [ 'hpe_greenlake', time - 10000, 60 ]) {
        my ($iv) = $prod->inventory(concept => 'nmisent_poll', path_keys => ['index'],
            path => [$prod->cluster_id, $prod->uuid, 'nmisent_poll', $row->[0]], create => 1,
            data => { index => $row->[0], last_success_epoch => $row->[1], interval => $row->[2] });
        $iv->save(node => $prod);
    }
    $C->{nmisent_producer_node} = "t_nmisent_producer";

    is(($ng->node(uuid => $dev->uuid) // $dev)->producer_state('meraki'), 'up',
       'fresh row -> up');
    is($dev->producer_state('hpe_greenlake'), 'stale', 'aged row -> stale');
    is($dev->producer_state('no_such_engine'), 'unknown', 'missing engine row -> unknown');
}
```

(If the `inventory(... path => ...)` shape differs from how `collect_systemhealth_info` builds systemHealth inventory in this codebase, mirror that call instead; the data fields `index`, `last_success_epoch`, `interval` are what matters.)

- [ ] **Step 2: Run test to verify it fails**

Run: `perl test/t_polling_redis.pl`
Expected: FAIL, `Can't locate object method "producer_state"`.

- [ ] **Step 3: Implement the method**

In `lib/NMISNG/Node.pm`, add after `handle_down`:

```perl
# Tri-state nmisent producer liveness for an engine, read live from the
# configured producer node's nmisent_poll inventory.
# returns: ('up'|'stale'|'unknown', detail). 'unknown' is indeterminate
# (no config, node/row/fields missing) and raises a deduplicated
# misconfiguration event distinct from the operational stale alarm.
sub producer_state
{
	my ($self, $engine) = @_;
	my $C = $self->nmisng->config;
	my $prodname = $C->{nmisent_producer_node};
	return ('unknown', 'nmisent_producer_node not configured')
		if (!defined $prodname || $prodname eq '');

	my $prod = $self->nmisng->node(name => $prodname);
	return ('unknown', "producer node '$prodname' not found") if (!$prod);

	my $ids = $prod->get_inventory_ids(concept => 'nmisent_poll');
	my ($lse, $interval);
	for my $id (@$ids)
	{
		my ($inv) = $prod->inventory(_id => $id);
		next if (!$inv);
		my $d = $inv->data;
		next if (($d->{index} // '') ne $engine);
		($lse, $interval) = ($d->{last_success_epoch}, $d->{interval});
		last;
	}
	return ('unknown', "no nmisent_poll row for engine '$engine'")
		if (!defined $lse || !defined $interval || $interval <= 0);

	my $age = time - $lse;
	return ('up', "age ${age}s within 2x ${interval}s") if ($age <= 2 * $interval);
	return ('stale', "age ${age}s exceeds 2x ${interval}s");
}
```

Have callers raise `nmisent Producer Misconfigured` on `unknown`; see Task 5 where the gate consumes the detail. Register the event in `conf-default/Events.nmis`:

```perl
  'nmisent Producer Misconfigured' => {
    'Event' => 'nmisent Producer Misconfigured',
    'Notify' => 'true',
    'Status' => 'true',
    'Log' => 'true',
    'Stateful' => 'true',
    'Description' => 'The nmisent producer node or its config pointer (nmisent_producer_node) is not set up, so producer liveness cannot be determined and redis reachability is held. Distinct from nmisent Producer Stale, which means nmisent stopped polling.',
  },
```

In `conf-default/Config.nmis`, add near the other redis keys:

```perl
	'nmisent_producer_node' => '',
```

- [ ] **Step 4: Run test to verify it passes**

Run: `perl test/t_polling_redis.pl`
Expected: PASS for the new producer_state assertions.

- [ ] **Step 5: Commit**

```bash
git add lib/NMISNG/Node.pm conf-default/Config.nmis conf-default/Events.nmis test/t_polling_redis.pl
git commit -m "feat(redis): producer_state tri-state lookup + config pointer + misconfig event"
```

---

## Task 5: producer-gated reachability step in collect

**Files:**
- Modify: `lib/NMISNG/Sys/Engine/Redis.pm` (expose `concept_fresh`)
- Modify: `lib/NMISNG/Node.pm` (add `apply_redis_reachability`, call it from `collect`)
- Test: `test/t_polling_redis.pl`

**Interfaces:**
- Consumes: `NMISNG::Sys::Engine::Redis::Status::canonical` (Task 1); `$node->producer_state($engine)` (Task 4); a per-concept freshness flag from the redis engine; `handle_down(type => 'node')`.
- Produces: `$node->apply_redis_reachability(sys => $S, catchall_inventory => $cat)`, invoked from `collect` after `collect_node_info`.

- [ ] **Step 1: Expose concept freshness on the engine**

In `lib/NMISNG/Sys/Engine/Redis.pm`, in `_payload_usable` record the verdict, and add an accessor:

```perl
# inside _payload_usable, set before each return:
$self->{_concept_fresh}{$concept} = 0;   # on the not-usable returns
$self->{_concept_fresh}{$concept} = 1;   # on the usable return

# new accessor:
# returns 1 fresh, 0 stale-or-skipped, undef if the concept was not evaluated
sub concept_fresh { return $_[0]->{_concept_fresh}{ $_[1] }; }
```

- [ ] **Step 2: Write the failing truth-table test**

Add to `test/t_polling_redis.pl` (e2e block, with the fake Redis client and a seeded producer node from Task 4). Drive each row by setting the node-level health payload status and the producer node freshness:

```perl
# ---- gated reachability truth table ----
{
    no warnings 'redefine';
    local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };
    $C->{nmisent_producer_node} = "t_nmisent_producer";  # fresh meraki row from Task 4

    my $n = $rnode;  # the existing meraki e2e node, engine=meraki, has last_update
    my $uuid = $n->uuid;
    my $set = sub { $main::REDIS_KV{"nmisent:metrics:$uuid:sdwan_health"} =
        '{"_meta":{"collected_at_epoch":'.time().'},"data":{"status":"'.$_[0].'"}}'; };

    $set->('offline'); $n->collect(wantsnmp=>0,wantwmi=>0,wanthttp=>0,wantredis=>1);
    ok($n->eventExist("Node Down"), 'producer up + fresh + offline -> Node Down');

    $set->('online');  $n->collect(wantsnmp=>0,wantwmi=>0,wanthttp=>0,wantredis=>1);
    ok(!$n->eventExist("Node Down"), 'producer up + fresh + online -> Node Down cleared');

    $set->('dormant'); $n->collect(wantsnmp=>0,wantwmi=>0,wanthttp=>0,wantredis=>1);
    ok(!$n->eventExist("Node Down"), 'degraded status -> no Node Down (held in v1)');

    # producer stale -> hold: offline must NOT raise Node Down
    $C->{nmisent_producer_node} = "t_nmisent_producer";
    # point the engine row stale: reuse the hpe_greenlake stale row by switching engine,
    # or age the meraki row; here assert via producer_state result instead:
    is($n->producer_state('hpe_greenlake'), 'stale', 'precondition: stale engine');
}
```

(Keep the truth table focused on the rows that are cheap to drive end to end; cover producer `stale`/`unknown` holding via direct `producer_state` assertions plus a unit check that the gate skips `handle_down` when `producer_state ne 'up'`.)

- [ ] **Step 3: Run test to verify it fails**

Run: `perl test/t_polling_redis.pl`
Expected: FAIL, `Node Down` not raised (no reachability step yet).

- [ ] **Step 4: Implement the gated step**

In `lib/NMISNG/Node.pm` add:

```perl
# Producer-gated reachability for a redis push node: map the canonical
# device status onto Node Down, but only when the engine's producer is up
# and this device's health payload is fresh. Otherwise hold (no change).
sub apply_redis_reachability
{
	my ($self, %args) = @_;
	my $S   = $args{sys};
	my $cat = $args{catchall_inventory};
	my $cfg = $self->configuration;
	my $engine = $cfg->{nmisent_engine_type};
	return if (!defined $engine || $engine eq '');

	my $eng = (grep { $_->protocol_name eq 'redis' } @{$S->engines})[0];
	return if (!$eng);

	my $concept = 'sdwan_health';  # node-level health concept; see note below
	my $fresh = $eng->concept_fresh($concept);

	my ($pstate, $detail) = $self->producer_state($engine);
	if ($pstate eq 'unknown')
	{
		Compat::NMIS::notify(
			sys => $S, event => "nmisent Producer Misconfigured",
			element => $engine, level => "Warning", details => $detail,
			context => { type => "node" }, inventory_id => $cat->id);
		return;  # hold
	}
	Compat::NMIS::checkEvent(
		sys => $S, event => "nmisent Producer Misconfigured",
		element => $engine, level => "Normal", details => "producer determinable",
		inventory_id => $cat->id);

	return if ($pstate ne 'up');     # stale -> hold
	return if (!$fresh);             # device data stale/absent -> hold (went-dark)

	my $raw = $cat->data_live->{status};
	my $canon = NMISNG::Sys::Engine::Redis::Status::canonical($engine, $raw);
	if ($canon eq 'down')
	{
		$self->handle_down(sys => $S, type => 'node',
			details => "device reported status '".($raw // 'undef')."'",
			catchall_inventory => $cat);
	}
	elsif ($canon eq 'up')
	{
		$self->handle_down(sys => $S, type => 'node', up => 1,
			details => "device reported status '$raw'", catchall_inventory => $cat);
	}
	else
	{
		$self->nmisng->log->info($self->name.": redis status '".($raw // 'undef')
			."' canonical=$canon for engine $engine, holding (no reachability change)");
	}
	return;
}
```

Note on the concept name: read it from the model rather than hardcoding `sdwan_health`. Resolve the node-level health concept as the `system.sys.standard.redis` `-common-.concept` of the loaded model (`$S->{mdl}{system}{sys}{standard}{redis}{'-common-'}{concept}`), falling back to skip if absent. Replace the `my $concept = 'sdwan_health'` line with that lookup so it works for `device_health` and `wifi_ap_health` too.

Then call it from `collect`, after `collect_node_info` and before the systemHealth reconcile, gated on a redis engine being active:

```perl
if (grep { $_->is_active && $_->protocol_name eq 'redis' } @{$S->engines})
{
    $self->apply_redis_reachability(sys => $S, catchall_inventory => $catchall_inventory);
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `perl test/t_polling_redis.pl`
Expected: PASS for the truth-table rows.

- [ ] **Step 6: Regression**

Run: `perl test/t_polling.pl` and `perl test/t_polling_http.pl` and `perl test/t_sys.pl`
Expected: each ends `1..N` with no `not ok`.

- [ ] **Step 7: Commit**

```bash
git add lib/NMISNG/Sys/Engine/Redis.pm lib/NMISNG/Node.pm test/t_polling_redis.pl
git commit -m "feat(redis): producer-gated reachability drives Node Down from device status"
```

---

## Task 6: live validation

**Files:** none (verification only).

- [ ] **Step 1:** provision a producer node (`model => 'nmisent'`, an `http_endpoints` entry `nmisent` at the nmisent host:9464) and set `nmisent_producer_node` in `conf/Config.nmis`. Confirm a collect of it creates `nmisent_poll` rows per engine.
- [ ] **Step 2:** on Q2KN (Meraki, live feed), seed `nmisent:metrics:<uuid>:sdwan_health` with `status=offline` and force a collect; confirm `nodestatus` is unreachable. Set `status=online`, collect, confirm reachable.
- [ ] **Step 3:** age the producer's meraki row past `2x interval` (or stop nmisent); confirm `nmisent Producer Stale` raises and that an `offline` device is then held (not flapped) until the producer is fresh again.
- [ ] **Step 4:** record results; HPE and Aruba are structural-only until they have live feeds.

---

## Sequencing

Tasks 1 and 2 are independent. Task 3 depends on Task 2's concept. Task 4 depends on Task 2's inventory shape. Task 5 depends on Tasks 1 and 4 and the engine freshness flag. Task 6 is last.

## Self-review notes

- Spec coverage: status map (T1), producer HTTP node (T2), producer-stale central event (T3), tri-state producer_state + misconfig event + config pointer (T4), gated status->Node Down with freshness and went-dark hold (T5), live validation (T6). Degraded and per-device-staleness-to-down remain out of scope by design.
- Verify before coding: the HTTP engine fetch method name used in the T2 stub, the exact systemHealth inventory `inventory(...)` call shape used by `collect_systemhealth_info` (reuse it in T4's test seeding), and that `concept_fresh` is set on every return path of `_payload_usable`.
