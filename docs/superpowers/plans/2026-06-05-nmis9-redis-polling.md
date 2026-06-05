# NMIS9 Redis Polling Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Redis polling engine to NMIS9 that consumes SD-WAN data pushed into Redis by the nmisent Go daemon, reconciles inventory at collect time, and schedules collects from the completion hash with a polling-interval fallback.

**Architecture:** A new `NMISNG::Sys::Engine::Redis` plugs into the existing engine abstraction (parallel to SNMP, WMI, HTTP). A `manages_own_inventory` trait makes `Node::collect` run the existing systemHealth reconcile (`collect_systemhealth_info`) at collect time for push engines. A `redis` polling flavour threads through the six scheduler layers the HTTP flavour already uses, and `find_due_nodes` consumes the `nmisent:poll-complete` hash with `HGETDEL`.

**Tech Stack:** Perl, the `Redis` CPAN client (v1.999, already installed), `JSON::XS`, MongoDB via `NMISNG::DB`, `Test::More`.

**Source of truth:** `docs/superpowers/specs/2026-06-05-nmis9-redis-polling-design.md` and the shared contract it references (Redis key shapes, payload shape, completion-hash semantics, `nmisent_*` node properties).

---

## File Structure

- **Create** `lib/NMISNG/Sys/Engine/Redis.pm` — the Redis engine. One responsibility: read concept payloads from Redis and present them to the shared `%todos` contract, plus discover indexes and raise staleness events.
- **Modify** `lib/NMISNG/Sys/Engine.pm` — add the `manages_own_inventory` predicate (default 0).
- **Modify** `lib/NMISNG/Sys.pm` — parse `wantredis`, derive `have_redis_settings`, instantiate the engine.
- **Modify** `lib/NMISNG/Node.pm` — derive `redis_enabled`; destructure `wantredis`/`redis_run_id`; stamp `last_poll_redis_attempt`; trait-gated `collect_systemhealth_info` call in `collect`.
- **Modify** `lib/NMISNG.pm` — `find_due_nodes`: `redis` interval, flavour wiring, gate, `HGETDEL` completion path, `run_id` carry.
- **Modify** `bin/nmisd` — thread `wantredis` and `redis_run_id` through scheduler and worker.
- **Modify** `conf-default/Polling-Policy.nmis` — `redis` interval per policy.
- **Modify** `conf-default/Config.nmis` — optional `redis_server`/`redis_port`/`redis_password` override block.
- **Create** `models-default/Model-CiscoMerakiCloud.nmis` — reference model with `redis` source blocks.
- **Create** `test/t_polling_redis.pl` — engine + scheduler + reconcile tests.
- **Modify** `ci/scripts/perl_tests.sh` — register the new test.

**Convention used in every commit step:** end the commit message with the trailer
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Task 1: Add the `manages_own_inventory` trait

**Files:**
- Modify: `lib/NMISNG/Sys/Engine.pm` (after the `close_session` default, ~line 97)
- Test: `test/t_polling_redis.pl` (create)

- [ ] **Step 1: Write the failing test**

Create `test/t_polling_redis.pl` with this opening (later tasks append to it):

```perl
#!/usr/bin/perl
#
# t_polling_redis.pl — Redis-engine companion to t_polling_http.pl.
# Exercises the Redis engine, the manages_own_inventory trait, the
# collect-time reconcile, and the find_due_nodes redis flavour with a
# stubbed Redis client (no real Redis server).
#
use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use NMISNG::Sys::Engine;

# Task 1: the trait exists and defaults to 0 on the base class.
can_ok('NMISNG::Sys::Engine', 'manages_own_inventory');
is(NMISNG::Sys::Engine::manages_own_inventory(), 0,
   "base engine manages_own_inventory defaults to 0");

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — `can_ok` reports `manages_own_inventory` not implemented.

- [ ] **Step 3: Add the trait to the base class**

In `lib/NMISNG/Sys/Engine.pm`, immediately after the `close_session` sub (currently ending at line 97 with `sub close_session { return undef; }`), add:

```perl
# Returns true for engines whose data is gathered by an external daemon and
# pushed to NMIS (Redis today, future streaming telemetry). Such engines own
# their inventory lifecycle and must run the systemHealth reconcile during
# collect, because no update pass will run it for them. SNMP/WMI/HTTP inherit
# 0 and keep reconciling inventory in update().
# Default: 0.
sub manages_own_inventory { return 0; }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys/Engine.pm test/t_polling_redis.pl
git commit -m "feat(redis): add manages_own_inventory engine trait

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Engine skeleton — identity, connection, payload fetch

**Files:**
- Create: `lib/NMISNG/Sys/Engine/Redis.pm`
- Test: `test/t_polling_redis.pl`

This task creates the engine class with its identity methods, the env-first
connection resolver, and the payload fetch/cache helper that distinguishes
"key absent" from "key present".

- [ ] **Step 1: Write the failing test**

Append to `test/t_polling_redis.pl`, before `done_testing();`:

```perl
# ---- Task 2: engine identity + payload fetch ----
use NMISNG::Sys::Engine::Redis;

# A minimal fake Sys: the engine only needs ->sys->{uuid},
# ->sys->nmisng->log, ->sys->nmisng->config, and ->sys->nmisng_node.
{
    package FakeLog;
    sub new { bless {}, shift }
    our $AUTOLOAD;
    sub AUTOLOAD { return 1; }   # swallow debug/info/warn/error/etc.
    sub DESTROY { }
}
{
    package FakeNmisng;
    sub new { my ($c,%a)=@_; bless { %a, _log => FakeLog->new }, $c }
    sub log    { return $_[0]->{_log}; }
    sub config { return $_[0]->{config}; }
}
{
    package FakeSys;
    sub new { my ($c,%a)=@_; bless { %a }, $c }
    sub nmisng      { return $_[0]->{nmisng}; }
    sub nmisng_node { return $_[0]->{node}; }
}

my $fake_nmisng = FakeNmisng->new(config => { });
my $fake_sys = FakeSys->new(
    uuid   => '11111111-2222-3333-4444-555555555555',
    nmisng => $fake_nmisng,
);
my $eng = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);

is($eng->protocol_name, 'redis', "protocol_name is redis");
is_deeply($eng->section_keys, ['redis'], "section_keys is [redis]");
is($eng->manages_own_inventory, 1, "redis manages its own inventory");
is($eng->is_active, 1, "redis engine is active once instantiated");

# Stub the Redis client this engine would open, returning canned GET results.
my %REDIS_KV;
{
    package FakeRedisClient;
    sub new { bless {}, shift }
    sub get { my ($s,$k)=@_; return $main::REDIS_KV{$k}; }
}
no warnings 'redefine';
local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

# Absent key -> (undef payload, undef error): "no information this cycle".
my ($p_absent, $e_absent) = $eng->_payload('sdwan_health');
ok(!defined $p_absent && !defined $e_absent,
   "absent key returns (undef,undef) — no information, not an error");

# Present key -> decoded hashref.
$REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_health'} =
    '{"_meta":{"run_id":"R1","collected_at_epoch":'.time().'},"data":{"status":"online"}}';
$eng->{_payload_cache} = {};   # clear the cache the absent-fetch populated
my ($p_ok, $e_ok) = $eng->_payload('sdwan_health');
ok(!$e_ok, "present key: no error");
is($p_ok->{data}{status}, 'online', "present key: payload decoded");
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — `Can't locate NMISNG/Sys/Engine/Redis.pm`.

- [ ] **Step 3: Create the engine skeleton**

Create `lib/NMISNG/Sys/Engine/Redis.pm`:

```perl
package NMISNG::Sys::Engine::Redis;
# Redis polling engine — consumes data pushed into Redis by the nmisent Go
# daemon. Reads one JSON payload per (node, concept) at the contract key
#   nmisent:metrics:{node_uuid}:{concept}
# and presents the named fields to the shared %todos contract. Owns its
# inventory lifecycle (manages_own_inventory=1), so Node::collect runs the
# systemHealth reconcile for it. Sessionless: the connection is process-level,
# not per-collect, so the base-class has_session/open_session/close_session
# no-op defaults are correct.
#
# See docs/superpowers/specs/2026-06-05-nmis9-redis-polling-design.md and the
# shared contract for key shapes and payload semantics.

use strict;
use warnings;
use parent 'NMISNG::Sys::Engine';

use Redis;
use JSON::XS qw(decode_json);

our $VERSION = "9.6.5";

sub protocol_name         { return "redis"; }
sub section_keys          { return ['redis']; }
sub manages_own_inventory { return 1; }

sub new
{
	my ($class, %args) = @_;
	my $self = $class->SUPER::new(%args);
	# Decoded payloads cached per Sys lifecycle, concept => payload-or-undef.
	# undef is a real cached value meaning "key absent this cycle".
	$self->{_payload_cache}  = {};
	$self->{_last_error}     = undef;
	# Expected run_id, set by Sys::init from the completion entry on the prompt
	# path. undef on the fallback path (read whatever is present).
	$self->{expected_run_id} = $args{run_id};
	return $self;
}

# The engine is only instantiated when redis_enabled, so its presence means
# the node is push-polled. No per-node endpoint config to check (unlike HTTP).
sub is_active { return 1; }

# Resolve the shared Redis connection. Env first (the deploy exports these),
# then an optional Config.nmis override block, then localhost:6379. One
# process-level connection, opened lazily, reused for the engine's lifetime.
sub _redis
{
	my ($self) = @_;
	return $self->{_redis} if $self->{_redis};

	my $cfg = $self->sys->nmisng->config;
	my $server = $ENV{NMIS_REDIS_SERVER} // $cfg->{redis_server} // 'localhost';
	my $port   = $ENV{NMIS_REDIS_PORT}   // $cfg->{redis_port}   // 6379;
	my $pass   = $ENV{NMIS_REDIS_PASSWORD};
	$pass = $cfg->{redis_password} if (!defined $pass || $pass eq '');

	my %newargs = (server => "$server:$port", reconnect => 2, every => 100, cnx_timeout => 5);
	$newargs{password} = $pass if (defined $pass && $pass ne '');

	$self->{_redis} = eval { Redis->new(%newargs) };
	if (!$self->{_redis})
	{
		$self->{_last_error} = "redis connect to $server:$port failed: $@";
		$self->sys->nmisng->log->error("redis: ".$self->{_last_error});
	}
	return $self->{_redis};
}

# Fetch and decode the JSON payload for a concept, cached per Sys lifecycle.
# Returns ($payload_hashref_or_undef, $error_or_undef). The three outcomes:
#   (hashref, undef) — key present and valid.
#   (undef,   undef) — key ABSENT. Per contract, "no information this cycle";
#                      the caller must NOT touch existing inventory.
#   (undef,   error) — connection or decode failure.
sub _payload
{
	my ($self, $concept) = @_;
	return ($self->{_payload_cache}{$concept}, undef)
		if exists $self->{_payload_cache}{$concept};

	my $redis = $self->_redis;
	return (undef, $self->{_last_error}) if (!$redis);

	my $uuid = $self->sys->{uuid};
	my $key  = "nmisent:metrics:$uuid:$concept";
	my $raw  = eval { $redis->get($key) };
	if ($@)
	{
		$self->{_last_error} = "redis get $key failed: $@";
		return (undef, $self->{_last_error});
	}

	# Absent key: cache undef so repeated lookups this cycle are cheap.
	if (!defined $raw)
	{
		$self->{_payload_cache}{$concept} = undef;
		return (undef, undef);
	}

	my $payload = eval { decode_json($raw) };
	if ($@ || ref $payload ne 'HASH')
	{
		$self->{_last_error} = "redis payload for $key is not a valid JSON object";
		return (undef, $self->{_last_error});
	}
	$self->{_payload_cache}{$concept} = $payload;
	return ($payload, undef);
}

1;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS (all Task 1 + Task 2 assertions).

- [ ] **Step 5: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys/Engine/Redis.pm test/t_polling_redis.pl
git commit -m "feat(redis): engine skeleton with env-first connection + payload fetch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Error classification + run_id / freshness gate

**Files:**
- Modify: `lib/NMISNG/Sys/Engine/Redis.pm`
- Test: `test/t_polling_redis.pl`

`classify_error` makes the lifecycle treat an absent key as a soft skip and a
dead connection as `no_session`. `_payload_usable` enforces the run_id
consistency check (prompt path only) and the freshness threshold.

- [ ] **Step 1: Write the failing test**

Append to `test/t_polling_redis.pl`, before `done_testing();`:

```perl
# ---- Task 3: classify_error + usable gate ----

# classify_error maps the last error to a lifecycle type.
$eng->{_last_error} = "redis connect to x:6379 failed: refused";
is($eng->classify_error->{type}, 'no_session', "connect failure -> no_session");
$eng->{_last_error} = "no key for concept";
is($eng->classify_error->{type}, 'not_present', "missing key -> not_present");
$eng->{_last_error} = undef;
ok(!defined $eng->classify_error, "no error -> undef classification");

# run_id gate: prompt path skips a mismatching payload.
$eng->{expected_run_id} = 'R-expected';
my $mismatch = { _meta => { run_id => 'R-other', collected_at_epoch => time() } };
is($eng->_payload_usable('c', $mismatch, 600), 0, "run_id mismatch -> not usable");
my $match = { _meta => { run_id => 'R-expected', collected_at_epoch => time() } };
is($eng->_payload_usable('c', $match, 600), 1, "run_id match + fresh -> usable");

# fallback path (no expected run_id): run_id is not checked.
$eng->{expected_run_id} = undef;
is($eng->_payload_usable('c', $mismatch, 600), 1, "fallback path ignores run_id");

# freshness: a payload older than freshness_s is not usable.
my $stale = { _meta => { collected_at_epoch => time() - 5000 } };
is($eng->_payload_usable('c', $stale, 600), 0, "stale payload -> not usable");
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — `classify_error` / `_payload_usable` not defined.

- [ ] **Step 3: Implement classify_error and the usable gate**

In `lib/NMISNG/Sys/Engine/Redis.pm`, add before the final `1;`:

```perl
# Classify the last error for Node::collect_systemhealth_info's gate.
#   connect failure   -> no_session    (lifecycle calls handle_down, aborts)
#   missing key       -> not_present   (soft skip, inventory untouched)
#   anything else     -> transport_error
sub classify_error
{
	my ($self) = @_;
	my $err = $self->{_last_error};
	return undef unless defined $err;
	return { type => 'no_session',  message => $err } if $err =~ /connect/i;
	return { type => 'not_present', message => $err } if $err =~ /no key|missing key|run_id mismatch/i;
	return { type => 'transport_error', message => $err };
}

# Decide whether a payload should be consumed this cycle.
# Returns 1 to consume, 0 to skip. Skips on run_id mismatch (prompt path only)
# and when the payload is older than freshness_s, raising/clearing the
# per-concept staleness event (see Task 5).
sub _payload_usable
{
	my ($self, $concept, $payload, $freshness_s) = @_;
	my $meta = (ref $payload->{_meta} eq 'HASH') ? $payload->{_meta} : {};

	if (defined $self->{expected_run_id}
		&& defined $meta->{run_id}
		&& $meta->{run_id} ne $self->{expected_run_id})
	{
		$self->sys->nmisng->log->debug(
			"redis: concept $concept run_id '$meta->{run_id}' != expected '$self->{expected_run_id}', skipping");
		return 0;
	}

	my $collected = $meta->{collected_at_epoch};
	if (defined $freshness_s && defined $collected)
	{
		my $age = time() - $collected;
		if ($age > $freshness_s)
		{
			$self->_raise_stale_event($concept, $age, $freshness_s);
			return 0;
		}
	}
	$self->_clear_stale_event($concept);
	return 1;
}
```

- [ ] **Step 4: Add no-op stale-event stubs so the gate runs**

The real event methods land in Task 5. For now add temporary stubs before
`1;` so `_payload_usable` runs in isolation:

```perl
# Replaced with real event raise/clear in Task 5.
sub _raise_stale_event { return; }
sub _clear_stale_event { return; }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys/Engine/Redis.pm test/t_polling_redis.pl
git commit -m "feat(redis): error classification + run_id/freshness gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `build_queries` and `execute_queries`

**Files:**
- Modify: `lib/NMISNG/Sys/Engine/Redis.pm`
- Test: `test/t_polling_redis.pl`

The model `redis` block names fields. `build_queries` joins the model field
names against the payload `data` block and fills `rawvalue`/`done` directly
(no separate fetch phase — the payload is already in Redis), so
`execute_queries` is a no-op that returns success. Handles three item shapes:
the index-self item (record the row's index value), an indexed-row field, and
a scalar field.

- [ ] **Step 1: Write the failing test**

Append to `test/t_polling_redis.pl`, before `done_testing();`:

```perl
# ---- Task 4: build_queries (scalar + indexed) ----

# Scalar concept: data is an object; fields map by name.
$REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_health'} =
    '{"_meta":{"collected_at_epoch":'.time().'},"data":{"status":"online","cpu_load_5min":0.23}}';
my $eng4 = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
{
    no warnings 'redefine';
    local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

    my %todos;
    my $section_hash = {
        '-common-' => { concept => 'sdwan_health', engine => 'meraki', freshness => 600 },
        'status'   => { field => 'status', title => 'Device status' },
        'cpu'      => { field => 'cpu_load_5min', title => 'CPU load (5m)' },
    };
    $eng4->build_queries(
        section_name => 'standard', section_key => 'redis',
        section_hash => $section_hash, section_indexed => undef,
        index => undef, todos => \%todos,
    );
    is($todos{status}{rawvalue}, 'online', "scalar field status extracted");
    ok($todos{status}{done}, "scalar field marked done");
    is($todos{cpu}{rawvalue}, '0.23', "scalar field cpu extracted");

    # execute_queries is a no-op success for redis.
    my $st = $eng4->execute_queries(todos => \%todos);
    ok(!$st->{error}, "execute_queries returns no error");

    # Indexed concept: data is an array; build_queries called per index.
    $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_uplink'} =
        '{"_meta":{"collected_at_epoch":'.time().'},"data":['
        .'{"wan_interface":"wan1","status":"active","latency_ms":24},'
        .'{"wan_interface":"wan2","status":"ready","latency_ms":null}]}';
    my $eng4b = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
    no warnings 'redefine';
    local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };
    my %todos2;
    my $sh2 = {
        '-common-'      => { concept => 'sdwan_uplink', engine => 'meraki', freshness => 600 },
        'wan_interface' => { field => 'wan_interface', title => 'WAN interface' },
        'status'        => { field => 'status', title => 'Status' },
        'latency'       => { field => 'latency_ms', title => 'Latency (ms)' },
    };
    $eng4b->build_queries(
        section_name => 'sdwan_uplink', section_key => 'redis',
        section_hash => $sh2, section_indexed => 'wan_interface',
        index => 'wan2', todos => \%todos2,
    );
    is($todos2{wan_interface}{rawvalue}, 'wan2', "index-self item records the index value");
    is($todos2{status}{rawvalue}, 'ready', "indexed-row field extracted for wan2");
    ok(exists $todos2{latency} && !defined $todos2{latency}{rawvalue},
       "null field present as undef rawvalue");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — `build_queries` not defined.

- [ ] **Step 3: Implement build_queries and execute_queries**

In `lib/NMISNG/Sys/Engine/Redis.pm`, add before the final `1;`:

```perl
# Build %todos entries for one model section. Joins the model's `field` names
# against the payload `data` block. Because the payload is already in Redis,
# extraction happens here and todos are marked done; execute_queries is a
# no-op. Args match the engine contract (see Sys::getValues dispatch).
sub build_queries
{
	my ($self, %args) = @_;
	my ($section_name, $section_hash, $section_indexed, $index, $todos)
		= @args{qw(section_name section_hash section_indexed index todos)};

	my $sys = $self->sys;
	my %status;

	my $common = (ref $section_hash->{'-common-'} eq 'HASH') ? $section_hash->{'-common-'} : {};
	my $concept = $common->{concept};
	unless (defined $concept)
	{
		$status{error} = "($sys->{name}) redis: section $section_name has no concept in -common-";
		$sys->nmisng->log->error($status{error});
		return \%status;
	}

	my ($payload, $err) = $self->_payload($concept);
	if ($err)
	{
		$status{error} = $err;
		return \%status;
	}
	# Absent key: nothing to record this cycle. Leave todos untouched.
	return \%status if (!defined $payload);

	# run_id / freshness gate (freshness declared per-section in -common-).
	return \%status unless $self->_payload_usable($concept, $payload, $common->{freshness});

	# Resolve the data row: an indexed concept's data is an array; pick the
	# row whose index field equals $index. A scalar concept's data is the
	# object itself.
	my $row;
	if (defined $section_indexed && defined $index)
	{
		my $index_field = (ref $section_indexed eq 'ARRAY') ? undef : $section_indexed;
		my $data = $payload->{data};
		if (ref $data eq 'ARRAY' && defined $index_field)
		{
			for my $entry (@$data)
			{
				next unless ref $entry eq 'HASH';
				if (defined $entry->{$index_field} && $entry->{$index_field} eq $index)
				{
					$row = $entry;
					last;
				}
			}
		}
		# No matching row this cycle: nothing to record (the index will be
		# retired by the historic-mark pass in collect_systemhealth_info).
		return \%status unless ref $row eq 'HASH';
	}
	else
	{
		$row = (ref $payload->{data} eq 'HASH') ? $payload->{data} : {};
	}

	for my $itemname (keys %$section_hash)
	{
		next if $itemname eq '-common-';
		my $thisitem = $section_hash->{$itemname};
		next unless ref $thisitem eq 'HASH';

		# Index-self item: an indexed-section item that declares no `field`
		# records the row's own index value (same role ifDescr fills for SNMP).
		if (defined $section_indexed && defined $index && !defined $thisitem->{field})
		{
			$todos->{$itemname} = {
				section  => [$section_name],
				item     => $itemname,
				details  => [$thisitem],
				rawvalue => $index,
				done     => 1,
			};
			next;
		}

		my $field = $thisitem->{field};
		unless (defined $field)
		{
			$status{error} = "($sys->{name}) redis: section $section_name item $itemname has no field";
			$sys->nmisng->log->error($status{error});
			next;
		}

		# Contract: the daemon emits every declared field, using null for
		# unavailable values. A missing field name is writer schema drift —
		# log it but don't fail the collect.
		if (!exists $row->{$field})
		{
			$sys->nmisng->log->debug(
				"($sys->{name}) redis: concept $concept field '$field' (item $itemname) absent from payload row");
		}

		$todos->{$itemname} = {
			section  => [$section_name],
			item     => $itemname,
			details  => [$thisitem],
			rawvalue => $row->{$field},   # may be undef (null in the payload)
			done     => 1,
		};
	}

	return \%status;
}

# Redis extraction happens in build_queries (the data is already local), so
# there is nothing to execute. Kept for engine-contract symmetry.
sub execute_queries
{
	my ($self, %args) = @_;
	return {};
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys/Engine/Redis.pm test/t_polling_redis.pl
git commit -m "feat(redis): build_queries field mapping for scalar + indexed concepts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `discover_indexes` + per-concept staleness event

**Files:**
- Modify: `lib/NMISNG/Sys/Engine/Redis.pm`
- Test: `test/t_polling_redis.pl`

`discover_indexes` returns the active index list for an indexed concept, and
encodes the contract's empty-data distinction: absent key -> error
(`not_present` -> soft skip, inventory untouched); `"data": []` ->
`(undef, [], {})` -> all entries historic. This task also replaces the Task 3
event stubs with real `eventAdd`/`eventDelete` calls.

- [ ] **Step 1: Write the failing test**

Append to `test/t_polling_redis.pl`, before `done_testing();`:

```perl
# ---- Task 5: discover_indexes empty-data semantics + staleness event ----
{
    no warnings 'redefine';
    local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

    # Present array -> active indices.
    my $engd = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
    my ($e1, $idx1, $tg1) = $engd->discover_indexes(
        section_config => { redis => { '-common-' => { concept => 'sdwan_uplink' } } },
        index_var      => 'wan_interface',
    );
    ok(!$e1, "discover_indexes: no error on present array");
    is_deeply([sort @$idx1], ['wan1','wan2'], "discover_indexes: both indices found");
    is($tg1->{wan1}{index_value}, 'wan1', "discover_indexes: target carries index_value");

    # Empty array -> (undef, [], {}) so the historic pass retires everything.
    $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_uplink'} =
        '{"_meta":{"collected_at_epoch":'.time().'},"data":[]}';
    my $enge = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
    my ($e2, $idx2) = $enge->discover_indexes(
        section_config => { redis => { '-common-' => { concept => 'sdwan_uplink' } } },
        index_var      => 'wan_interface',
    );
    ok(!$e2 && ref $idx2 eq 'ARRAY' && @$idx2 == 0,
       "empty array -> no error, empty index list (all historic)");

    # Absent key -> error classified not_present (soft skip, inventory kept).
    delete $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_uplink'};
    my $enga = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
    my ($e3) = $enga->discover_indexes(
        section_config => { redis => { '-common-' => { concept => 'sdwan_uplink' } } },
        index_var      => 'wan_interface',
    );
    ok($e3, "absent key -> discover_indexes error");
    is($enga->classify_error->{type}, 'not_present', "absent key -> not_present");
}

# Staleness event uses the standard NMIS event path: Compat::NMIS::notify to
# raise, Compat::NMIS::checkEvent to clear. Both take sys => $S. Load
# Compat::NMIS first so our local overrides win over the engine's lazy
# `require Compat::NMIS` (require is a no-op once the module is in %INC).
{
    require Compat::NMIS;
    our (@notified, @checked);
    no warnings 'redefine';
    local *Compat::NMIS::notify     = sub { push @main::notified, {@_}; return; };
    local *Compat::NMIS::checkEvent = sub { push @main::checked,  {@_}; return; };

    my $enge = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
    $enge->_raise_stale_event('sdwan_health', 5000, 600);
    ok(@main::notified && $main::notified[0]{event} =~ /stale/i,
       "raise -> Compat::NMIS::notify with a stale event");
    is($main::notified[0]{element}, 'sdwan_health',
       "raise -> element is the concept");
    $enge->_clear_stale_event('sdwan_health');
    ok(@main::checked && $main::checked[0]{event} =~ /stale/i,
       "clear -> Compat::NMIS::checkEvent for the concept");
    is($main::checked[0]{element}, 'sdwan_health',
       "clear -> element is the concept");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — `discover_indexes` not defined / event stubs are no-ops.

- [ ] **Step 3: Implement discover_indexes**

In `lib/NMISNG/Sys/Engine/Redis.pm`, add before the final `1;`:

```perl
# Discover active indexes for an indexed systemHealth concept. Encodes the
# contract's empty-data semantics:
#   absent key            -> ($error, undef, undef); classify_error => not_present
#                            => Node::collect_systemhealth_info soft-skips,
#                               existing inventory is untouched.
#   "data": []            -> (undef, [], {})
#                            => bulk_update_inventory_historic marks all rows
#                               for the concept historic.
#   "data": [rows]        -> (undef, \@indices, \%targets)
# index_var may be a string (single index) or arrayref (composite, joined "__").
sub discover_indexes
{
	my ($self, %args) = @_;
	my ($section_config, $index_var) = @args{qw(section_config index_var)};
	my $sys = $self->sys;

	my $section_hash = (ref $section_config->{redis} eq 'HASH') ? $section_config->{redis} : undef;
	if (!$section_hash)
	{
		$self->{_last_error} = "section has no redis subsection";
		return ($self->{_last_error}, undef, undef);
	}
	my $common = (ref $section_hash->{'-common-'} eq 'HASH') ? $section_hash->{'-common-'} : {};
	my $concept = $common->{concept};
	if (!defined $concept)
	{
		$self->{_last_error} = "redis section has no concept";
		return ($self->{_last_error}, undef, undef);
	}

	my ($payload, $err) = $self->_payload($concept);
	return ("redis discover for $concept failed: $err", undef, undef) if $err;

	# Absent key: no information this cycle. not_present -> soft skip.
	if (!defined $payload)
	{
		$self->{_last_error} = "no key for concept $concept";
		return ($self->{_last_error}, undef, undef);
	}

	# run_id mismatch on the prompt path: skip discovery this cycle rather
	# than retiring inventory against a half-written newer snapshot.
	my $meta = (ref $payload->{_meta} eq 'HASH') ? $payload->{_meta} : {};
	if (defined $self->{expected_run_id}
		&& defined $meta->{run_id}
		&& $meta->{run_id} ne $self->{expected_run_id})
	{
		$self->{_last_error} = "run_id mismatch for concept $concept";
		return ($self->{_last_error}, undef, undef);
	}
	$self->{_last_error} = undef;

	my $data = $payload->{data};
	# Present but empty array: affirmative "all indices gone".
	return (undef, [], {}) if (ref $data eq 'ARRAY' && @$data == 0);
	if (ref $data ne 'ARRAY')
	{
		$self->{_last_error} = "concept $concept payload data is not an array (not indexed?)";
		return ($self->{_last_error}, undef, undef);
	}

	my @index_vars = (ref $index_var eq 'ARRAY')
		? @$index_var
		: (defined $index_var && length $index_var ? ($index_var) : ());
	if (!@index_vars)
	{
		$self->{_last_error} = "concept $concept has no index var";
		return ($self->{_last_error}, undef, undef);
	}

	my @candidates;
	my %targets;
	for my $entry (@$data)
	{
		next unless ref $entry eq 'HASH';
		my @vals = map { $entry->{$_} } @index_vars;
		next if grep { !defined $_ } @vals;
		my $composite = (@index_vars > 1) ? join("__", @vals) : $vals[0];
		push @candidates, $composite;
		my %target = (index_var => $index_var, index_value => $composite);
		if (@index_vars > 1)
		{
			$target{$index_vars[$_]} = $vals[$_] for 0 .. $#index_vars;
		}
		$targets{$composite} = \%target;
	}

	return (undef, \@candidates, \%targets);
}
```

- [ ] **Step 4: Replace the Task 3 event stubs with real implementations**

In `lib/NMISNG/Sys/Engine/Redis.pm`, replace the two stub lines

```perl
sub _raise_stale_event { return; }
sub _clear_stale_event { return; }
```

with:

```perl
# Per-concept staleness event, keyed by node + concept (element). Uses the
# standard NMIS event path (Compat::NMIS::notify / checkEvent) rather than the
# raw event system, matching how the rest of NMIS creates and clears events.
# notify/checkEvent take the LIVE sys and resolve the node themselves. Distinct
# from the node-level handle_down source-down path: one stale concept does not
# mark the whole node's Redis source down. Compat::NMIS is required lazily to
# avoid a load-order cycle with the engine.
my $STALE_EVENT = "Redis Data Stale";

sub _raise_stale_event
{
	my ($self, $concept, $age, $freshness_s) = @_;
	require Compat::NMIS;
	Compat::NMIS::notify(
		sys     => $self->sys,
		event   => $STALE_EVENT,
		element => $concept,
		level   => "Warning",
		details => "Redis concept $concept is stale: ".int($age)."s old, freshness threshold ${freshness_s}s",
	);
}

sub _clear_stale_event
{
	my ($self, $concept) = @_;
	require Compat::NMIS;
	# checkEvent closes the event if one is open for this (node, concept),
	# and is a no-op when none exists — safe to call every fresh cycle.
	Compat::NMIS::checkEvent(
		sys     => $self->sys,
		event   => $STALE_EVENT,
		element => $concept,
		level   => "Normal",
		details => "Redis concept $concept is fresh",
	);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys/Engine/Redis.pm test/t_polling_redis.pl
git commit -m "feat(redis): discover_indexes empty-data semantics + staleness event

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Derive `redis_enabled` from `nmisent_engine_type`

**Files:**
- Modify: `lib/NMISNG/Node.pm` (in `_defaults`, after the `http_enabled` derivation at line 237-238)
- Test: `test/t_polling_redis.pl`

- [ ] **Step 1: Write the failing test**

Append to `test/t_polling_redis.pl`, before `done_testing();`. This block
needs a real NMISNG + DB like t_polling_http.pl, so it is self-contained:

```perl
# ---- Task 6: redis_enabled derivation ----
SKIP: {
    eval {
        require NMISNG;
        require NMISNG::Node;
        require NMISNG::Util;
        require NMISNG::Log;
    };
    skip "NMISNG/DB not available in this environment", 4 if $@;

    my $C = NMISNG::Util::loadConfTable();
    skip "no config", 4 if !$C;
    $C->{db_name} = "t_polling_redis-" . time;
    my $logger = NMISNG::Log->new(level => 'error');
    my $ng = NMISNG->new(config => $C, log => $logger);

    my $n = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
    $n->cluster_id($C->{cluster_id});
    $n->name("t_redis_flag_node");
    $n->activated({ NMIS => 1 });

    my %base = (host => "127.0.0.1", group => "G", netType => "default",
        roleType => "default", model => "CiscoMerakiCloud", collect => "true", ping => "false");

    $n->configuration({ %base, nmisent_engine_type => 'meraki' });
    is($n->configuration->{redis_enabled}, 1,
       "redis_enabled: 1 when nmisent_engine_type set");
    $n->configuration({ %base });
    is($n->configuration->{redis_enabled}, 0,
       "redis_enabled: 0 when nmisent_engine_type absent");
    $n->configuration({ %base, nmisent_engine_type => 'aruba_central' });
    is($n->configuration->{redis_enabled}, 1,
       "redis_enabled: 1 for a different engine type");
    $n->configuration({ %base, nmisent_engine_type => '' });
    is($n->configuration->{redis_enabled}, 0,
       "redis_enabled: 0 when nmisent_engine_type is empty string");

    $ng->get_db()->drop();
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — `redis_enabled` is undef (not derived).

- [ ] **Step 3: Add the derivation**

In `lib/NMISNG/Node.pm`, immediately after the `http_enabled` block (line 237-238, the lines ending `( ref $configuration->{http_endpoints} eq 'ARRAY' ) ? 1 : 0;`), add:

```perl
	# Redis (push) source: derived from the nmisent reconciler's
	# nmisent_engine_type property, mirroring how http_enabled derives from
	# http_endpoints. find_due_nodes and Sys::init read this flag directly
	# rather than re-inspecting the model. Hand-created test nodes set
	# nmisent_engine_type manually.
	$configuration->{redis_enabled} =
		( defined $configuration->{nmisent_engine_type}
		  && $configuration->{nmisent_engine_type} ne "" ) ? 1 : 0;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS (or SKIP if MongoDB is unavailable in the run environment).

- [ ] **Step 5: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Node.pm test/t_polling_redis.pl
git commit -m "feat(redis): derive redis_enabled from nmisent_engine_type

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `Sys::init` — parse `wantredis`, instantiate the engine

**Files:**
- Modify: `lib/NMISNG/Sys.pm` (parse near line 416; derive near 682; instantiate near 766)
- Test: covered by the end-to-end collect in Task 11; add a focused assertion here.

- [ ] **Step 1: Write the failing test**

Append to `test/t_polling_redis.pl` inside the `SKIP:` block from Task 6
(after the `redis_enabled` assertions, before `$ng->get_db()->drop();`):

```perl
    # ---- Task 7: Sys::init wires the redis engine ----
    $n->configuration({ %base, nmisent_engine_type => 'meraki' });
    my ($sop, $serr) = $n->save();
    # An update is needed to create catchall; for the engine-presence check we
    # can init in collect mode against a freshly created catchall.
    $n->update(force => 1);
    my ($cinv) = $n->inventory(concept => "catchall");
    my $S = NMISNG::Sys->new(nmisng => $ng);
    $S->init(node => $n, snmp => 0, wmi => 0, http => 0, redis => 1,
             update => 0, catchall_inventory => $cinv);
    ok((grep { $_->protocol_name eq 'redis' } @{$S->engines}),
       "redis engine present in Sys when wantredis + redis_enabled");
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — no redis engine in `@{$S->engines}` (init ignores `redis`).

- [ ] **Step 3: Parse `wantredis`**

In `lib/NMISNG/Sys.pm`, after the `$wanthttp` line (416), add:

```perl
	# redis engine gate. Default true so ad-hoc callers (dev-tools, tests)
	# get redis collection when the node is redis_enabled. nmisd workers pass
	# an explicit value from the polling policy's redis cadence and the
	# completion-hash prompt path via NMISNG::find_due_nodes.
	my $wantredis = NMISNG::Util::getbool( exists $args{redis} ? $args{redis} : 1 );
	# Expected run_id for the prompt-path consistency check (undef on the
	# fallback path). Passed straight through to the engine.
	my $redis_run_id = $args{redis_run_id};
```

- [ ] **Step 4: Derive `have_redis_settings`**

In `lib/NMISNG/Sys.pm`, after the `have_http_settings` block (680-682), add:

```perl
	my $have_redis_settings = defined $cfg->{redis_enabled}
		? ($cfg->{redis_enabled} ? 1 : 0)
		: ((defined $cfg->{nmisent_engine_type} && $cfg->{nmisent_engine_type} ne "") ? 1 : 0);
```

And extend the `have_any_settings` line (683) to include it:

```perl
	my $have_any_settings = ( $have_snmp_settings || $have_wmi_settings || $have_http_settings || $have_redis_settings ) ? 1 : 0;
```

- [ ] **Step 5: Instantiate the engine**

In `lib/NMISNG/Sys.pm`, after the HTTP engine block (ends line 766 with `$self->{http} = $http_engine;` and its closing brace), add:

```perl
	# Redis (push) engine. Created when wanted and the node is redis_enabled.
	# Sessionless: the connection is process-level, opened lazily in the engine.
	if ($wantredis && $have_redis_settings)
	{
		require NMISNG::Sys::Engine::Redis;
		my $redis_engine = NMISNG::Sys::Engine::Redis->new(
			sys    => $self,
			run_id => $redis_run_id,
		);
		push @{$self->{_engines}}, $redis_engine;
		$self->{redis} = $redis_engine;
	}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS (or SKIP without MongoDB).

- [ ] **Step 7: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Sys.pm test/t_polling_redis.pl
git commit -m "feat(redis): Sys::init parses wantredis and instantiates the engine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `Node::collect` — thread `wantredis`, trait-gated reconcile

**Files:**
- Modify: `lib/NMISNG/Node.pm` (destructure 9378-9380; attempt stamp 9432-9437; init call 9441-9447; reconcile near 9611)

This task does not add a standalone unit test; the reconcile path is verified
end-to-end in Task 11. Each edit is mechanical and mirrors the existing
`wanthttp` handling.

- [ ] **Step 1: Destructure `wantredis` and `redis_run_id`**

In `lib/NMISNG/Node.pm`, change the destructure at 9378-9380 from:

```perl
	my ($wantsnmp,$wantwmi,$wanthttp,$force,$starttime)
		= @args{"wantsnmp","wantwmi","wanthttp","force","starttime"};
	$wanthttp //= 1;   # default-on for legacy callers (dev-tools, tests, ad-hoc)
```

to:

```perl
	my ($wantsnmp,$wantwmi,$wanthttp,$wantredis,$redis_run_id,$force,$starttime)
		= @args{"wantsnmp","wantwmi","wanthttp","wantredis","redis_run_id","force","starttime"};
	$wanthttp //= 1;   # default-on for legacy callers (dev-tools, tests, ad-hoc)
	$wantredis //= 1;  # default-on for legacy callers; gated by redis_enabled in Sys::init
```

- [ ] **Step 2: Stamp `last_poll_redis_attempt`**

In `lib/NMISNG/Node.pm`, after the `$wanthttp` attempt-stamp block (9432-9437), add:

```perl
	if ($wantredis) {
		# Symmetric with snmp/wmi/http so find_due_nodes can compute next-due
		# against the redis cadence in the policy.
		$catchall_data->{last_poll_redis_attempt} = $starttime;
	}
```

- [ ] **Step 3: Pass `redis` to `Sys::init`**

In `lib/NMISNG/Node.pm`, in the `$S->init(...)` call (9441-9447), add two args
after `http => $wanthttp,`:

```perl
									http => $wanthttp,
									redis => $wantredis,
									redis_run_id => $redis_run_id,
```

- [ ] **Step 4: Add the trait-gated reconcile before collect_systemhealth_data**

In `lib/NMISNG/Node.pm`, immediately before the `collect_systemhealth_data`
call (currently at 9611-9613, the `$time_start = Time::HiRes::time;` then
`$self->collect_systemhealth_data(...)`), insert:

```perl
			# Push engines (Redis, future streaming) own their inventory: no
			# update pass runs collect_systemhealth_info for them, so run it
			# here at collect time. Gated on the engine trait so SNMP/WMI/HTTP
			# are unaffected.
			if (grep { $_->is_active && $_->manages_own_inventory } @{$S->engines})
			{
				$time_start = Time::HiRes::time;
				$self->collect_systemhealth_info(sys => $S, catchall_inventory => $catchall_inventory)
					if defined $S->{mdl}{systemHealth};
				$catchall_data->{collect_systemhealth_info_time} = Time::HiRes::time - $time_start;
			}
```

- [ ] **Step 5: Run the HTTP regression to confirm no perturbation**

Run: `cd /usr/local/nmis9 && perl test/t_polling_http.pl`
Expected: PASS — the `wantredis //= 1` default plus the engine-trait gate must
not change HTTP behaviour (HTTP's trait is 0, so the reconcile branch is
skipped for HTTP-only nodes).

- [ ] **Step 6: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG/Node.pm
git commit -m "feat(redis): thread wantredis through collect + trait-gated reconcile

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `find_due_nodes` — redis flavour, gate, completion path

**Files:**
- Modify: `lib/NMISNG.pm` (intervals 1743; read near 1913; flavour sites 1948/2084/2139; gate 2109-2114; due-test 2117-2119; new completion path)
- Test: `test/t_polling_redis.pl`

- [ ] **Step 1: Write the failing test**

Append to `test/t_polling_redis.pl` inside the Task 6 `SKIP:` block, after the
Task 7 assertions:

```perl
    # ---- Task 9: find_due_nodes sets the redis flavour ----
    $ng->ensure_indexes;
    my $due = $ng->find_due_nodes(type => 'collect', force => 1);
    ok($due->{success}, "find_due_nodes success");
    my $fl = ($due->{flavours} // {})->{ $n->uuid };
    ok($fl, "redis node present in due list");
    ok($fl->{redis}, "redis flavour enabled for a redis_enabled node");
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: FAIL — `flavours{redis}` is undef.

- [ ] **Step 3: Add `redis` to the interval defaults**

In `lib/NMISNG.pm` at line 1743, change:

```perl
		%intervals = ( default => {ping => 60, snmp => 300, wmi => 300, http => 60, update => 86400} );
```

to:

```perl
		%intervals = ( default => {ping => 60, snmp => 300, wmi => 300, http => 60, redis => 300, update => 86400} );
```

And in the policy translate loop (line 1749), add `redis` to the subtype list:

```perl
			for my $subtype (qw(snmp wmi http redis ping update))
```

- [ ] **Step 4: Read `last_poll_redis_attempt`**

In `lib/NMISNG.pm`, after the `$lasthttp` read (1913), add:

```perl
			my $lastredis = $ninfo->{last_poll_redis_attempt};
```

- [ ] **Step 5: Set the redis flavour in the policy-change and no-prior branches**

In `lib/NMISNG.pm`, after each `$flavours{$maybe}->{http} = $nodeconfig->{http_enabled} ? 1 : 0;`
line (the policy-change branch ~1948 and the no-prior-poll branch ~2084), add:

```perl
					$flavours{$maybe}->{redis} = $nodeconfig->{redis_enabled} ? 1 : 0;
```

(Use the same indentation as the adjacent `http` line in each branch.)

- [ ] **Step 6: Add the gate and steady-state flavour**

In `lib/NMISNG.pm`, after the `$has_http`/`$nexthttp` block (2109-2114), add:

```perl
				my $has_redis = $nodeconfig->{redis_enabled} ? 1 : 0;
				my $nextredis = $has_redis
					? ( $lastredis // 0 ) + $intervals{$polname}->{redis} * $fudgefactor
					: undef;
```

Extend the due-test (2117-2119) to include redis:

```perl
				if (   ( defined($lastsnmp) && $nextsnmp <= $now )
					|| ( defined($lastwmi)  && $nextwmi  <= $now )
					|| ( $has_http && defined($lasthttp) && $nexthttp <= $now )
					|| ( $has_redis && defined($lastredis) && $nextredis <= $now ) )
```

And after the steady-state `$flavours{$maybe}->{http} = ...` line (2139), add:

```perl
					$flavours{$maybe}->{redis} = ( $has_redis && $nextredis <= $now ) ? 1 : 0;
```

- [ ] **Step 7: Add the completion-hash prompt path**

In `lib/NMISNG.pm`, this override must run for **every** redis-enabled
candidate node on the collect path, no matter which cadence branch above it
took (policy-change ~1948, no-prior ~2084, or steady-state ~2139). So do not
nest it inside any one branch. Place it after the whole if/elsif cadence chain
closes for this node but still inside the per-node loop, before the loop
advances. Verify placement by checking the indentation matches the per-node
loop body, not a branch body. The override:

```perl
				# Redis prompt path: a completion entry in the nmisent hash
				# means the Go daemon finished a polling cycle for this node.
				# HGETDEL atomically reads and removes it (at-most-once). When
				# present, force the node due now and carry the run_id to the
				# engine for the consistency check. Absent entry -> fall back
				# to the cadence logic above.
				if ($has_redis && $whichop eq "collect")
				{
					my $entry = $self->_redis_poll_complete($maybe);
					if ($entry)
					{
						$due{$maybe} = $cands{$maybe};
						$flavours{$maybe}->{redis} = 1;
						$flavours{$maybe}->{redis_run_id} = $entry->{run_id};
					}
				}
```

- [ ] **Step 8: Add the `_redis_poll_complete` helper**

In `lib/NMISNG.pm`, add a method (near the other private helpers; place it just
before `sub find_due_nodes` so it is defined in the same package):

```perl
# Atomically read+remove this node's completion entry from the nmisent
# poll-complete hash (prompt path). Returns the decoded entry hashref, or
# undef when none is present. HGETDEL needs Redis 8.0+; the at-most-once
# semantics are intentional (see the contract).
sub _redis_poll_complete
{
	my ($self, $node_uuid) = @_;
	my $redis = $self->_redis_handle;
	return undef unless $redis;
	# Redis 8.0 HGETDEL syntax: HGETDEL key FIELDS numfields field [field ...].
	# The Redis Perl client AUTOLOADs commands, so the tokens are passed
	# positionally. Confirm the reply shape against your client version: this
	# returns a list of values (one per requested field); we requested one.
	my $raw = eval { my @r = $redis->hgetdel("nmisent:poll-complete", "FIELDS", 1, $node_uuid); $r[0]; };
	if ($@) { $self->log->debug("redis hgetdel failed: $@"); return undef; }
	return undef unless defined $raw;
	my $entry = eval { JSON::XS::decode_json($raw) };
	if ($@) { $self->log->warn("redis poll-complete entry for $node_uuid not valid JSON: $@"); return undef; }
	return (ref $entry eq 'HASH') ? $entry : undef;
}

# Lazily-opened scheduler-side Redis handle (separate from the per-node engine
# handle in Sys::Engine::Redis; this one lives on the nmisd scheduler).
sub _redis_handle
{
	my ($self) = @_;
	return $self->{_redis_handle} if exists $self->{_redis_handle};
	require Redis;
	my $cfg = $self->config;
	my $server = $ENV{NMIS_REDIS_SERVER} // $cfg->{redis_server} // 'localhost';
	my $port   = $ENV{NMIS_REDIS_PORT}   // $cfg->{redis_port}   // 6379;
	my $pass   = $ENV{NMIS_REDIS_PASSWORD};
	$pass = $cfg->{redis_password} if (!defined $pass || $pass eq '');
	my %newargs = (server => "$server:$port", reconnect => 2, every => 100, cnx_timeout => 5);
	$newargs{password} = $pass if (defined $pass && $pass ne '');
	$self->{_redis_handle} = eval { Redis->new(%newargs) };
	$self->log->debug("scheduler redis connect to $server:$port failed: $@") if (!$self->{_redis_handle});
	return $self->{_redis_handle};
}
```

Add `use JSON::XS;` near the top of `lib/NMISNG.pm` if it is not already
imported (grep first: `grep -n 'JSON::XS\|use JSON' lib/NMISNG.pm`).

- [ ] **Step 9: Run the test to verify it passes**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS for the flavour assertions (the prompt path needs a live Redis;
it is exercised in Task 11 with a stub).

- [ ] **Step 10: Run the HTTP scheduler regression**

Run: `cd /usr/local/nmis9 && perl test/t_polling_http.pl`
Expected: PASS — the SNMP-only and HTTP-cadence assertions must be unchanged.

- [ ] **Step 11: Commit**

```bash
cd /usr/local/nmis9
git add lib/NMISNG.pm test/t_polling_redis.pl
git commit -m "feat(redis): find_due_nodes redis cadence + poll-complete prompt path

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `bin/nmisd` — thread the flavour through the queue

**Files:**
- Modify: `bin/nmisd` (scheduler 727-730; worker 2415-2417)

No standalone test (the worker path runs under the daemon); verified
end-to-end in Task 11. Both edits mirror `wanthttp`.

- [ ] **Step 1: Copy the flavour into job args (scheduler)**

In `bin/nmisd`, in the `$operation eq "collect"` block (727-730), after the
`$jobargs{wanthttp}` line, add:

```perl
				$jobargs{wantredis}    = $duenodes->{flavours}->{$nodeuuid}->{redis};
				$jobargs{redis_run_id} = $duenodes->{flavours}->{$nodeuuid}->{redis_run_id};
```

- [ ] **Step 2: Read the flavour back (worker)**

In `bin/nmisd`, in the worker's `$ourjob->{type} eq "collect"` block
(2415-2417), extend the `@methodargs` list:

```perl
						@methodargs = ( wantsnmp => $ourjob->{args}->{wantsnmp},
														wantwmi  => $ourjob->{args}->{wantwmi},
														wanthttp => $ourjob->{args}->{wanthttp},
														wantredis => $ourjob->{args}->{wantredis},
														redis_run_id => $ourjob->{args}->{redis_run_id} );
```

- [ ] **Step 3: Syntax-check the daemon**

Run: `cd /usr/local/nmis9 && perl -c bin/nmisd`
Expected: `bin/nmisd syntax OK`.

- [ ] **Step 4: Commit**

```bash
cd /usr/local/nmis9
git add bin/nmisd
git commit -m "feat(redis): thread wantredis + redis_run_id through nmisd queue

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Config + reference model + end-to-end collect

**Files:**
- Modify: `conf-default/Polling-Policy.nmis`
- Modify: `conf-default/Config.nmis`
- Create: `models-default/Model-CiscoMerakiCloud.nmis`
- Test: `test/t_polling_redis.pl`

- [ ] **Step 1: Add the redis interval to every policy**

Inspect the file first: `grep -n "http" conf-default/Polling-Policy.nmis`.
For each policy entry that lists an `http` interval, add a sibling `redis`
interval. Example (match the file's existing quoting/spacing):

```perl
		'redis' => '300s',
```

If a policy omits a subtype it falls back to the `%intervals` default (300s,
added in Task 9), so only policies that explicitly tune cadences need the line.

- [ ] **Step 2: Add the optional Config.nmis override block**

In `conf-default/Config.nmis`, near the existing `db_server`/`db_password`
keys, add (the engine reads `NMIS_REDIS_*` env first, these second,
`localhost:6379` last — so these are safe defaults):

```perl
	'redis_server' => 'localhost',
	'redis_port' => '6379',
	'redis_password' => '',
```

- [ ] **Step 3: Create the reference Meraki model**

Create `models-default/Model-CiscoMerakiCloud.nmis`:

```perl
#
# Cisco Meraki cloud-managed SD-WAN. Data is pushed into Redis by the nmisent
# Go daemon (engine=meraki) and consumed by NMISNG::Sys::Engine::Redis. No
# SNMP/WMI/HTTP; no update cycle (the reconciler creates the node, the redis
# collect maintains inventory). See the redis source-block docs below.
#
%hash = (
	'system' => {
		'nodeModel' => 'CiscoMerakiCloud',
		'nodeType' => 'generic',
		'nodegraph' => 'health',
		'sys' => {
			'standard' => {
				# Scalar (non-indexed) concept: one sdwan_health per device.
				'redis' => {
					'-common-' => { 'concept' => 'sdwan_health', 'engine' => 'meraki', 'freshness' => 600 },
					'status'   => { 'field' => 'status', 'title' => 'Device status' },
					'cpu'      => { 'field' => 'cpu_load_5min', 'title' => 'CPU load (5m)' },
					'mem'      => { 'field' => 'memory_used_pct', 'title' => 'Memory used %' },
				},
			},
		},
	},
	'systemHealth' => {
		'sections' => 'sdwan_uplink',
		'sys' => {
			# Indexed concept: one row per WAN uplink, keyed by wan_interface.
			'sdwan_uplink' => {
				'indexed' => 'wan_interface',
				'index_oid' => 'wan_interface',
				'headers' => 'wan_interface,status,latency',
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

(Field names for `sdwan_uplink`/`sdwan_health` are the contract's example set;
confirm against the nmisent side before GA — see the spec's open items.)

- [ ] **Step 4: Write the end-to-end reconcile test**

Append to `test/t_polling_redis.pl` inside the Task 6 `SKIP:` block, after the
Task 9 assertions. This seeds a stubbed Redis, runs a collect, and asserts
inventory create + historic-on-drop:

```perl
    # ---- Task 11: end-to-end reconcile via the collect path ----
    # Stub the engine's Redis client so the whole node collect path runs.
    my %KV;
    my $uuid = $n->uuid;
    $KV{"nmisent:metrics:$uuid:sdwan_uplink"} =
        '{"_meta":{"collected_at_epoch":'.time().'},"data":['
        .'{"wan_interface":"wan1","status":"active","latency_ms":24},'
        .'{"wan_interface":"wan2","status":"ready","latency_ms":12}]}';
    $KV{"nmisent:metrics:$uuid:sdwan_health"} =
        '{"_meta":{"collected_at_epoch":'.time().'},"data":{"status":"online","cpu_load_5min":0.23,"memory_used_pct":47.2}}';
    {
        package StubRedis; sub new { bless {}, shift }
        sub get { return $main::KV{$_[1]}; }
        package main;
        no warnings 'redefine';
        local *NMISNG::Sys::Engine::Redis::_redis = sub { return StubRedis->new; };

        $n->collect(wantsnmp => 0, wantwmi => 0, wanthttp => 0, wantredis => 1, force => 1);

        my $ids = $n->get_inventory_ids(concept => 'sdwan_uplink', filter => { historic => 0 });
        ok(scalar @$ids == 2, "two sdwan_uplink rows after first collect")
            or diag("got ".scalar(@$ids));

        # Drop wan2; it must go historic, wan1 survives.
        $main::KV{"nmisent:metrics:$uuid:sdwan_uplink"} =
            '{"_meta":{"collected_at_epoch":'.time().'},"data":['
            .'{"wan_interface":"wan1","status":"active","latency_ms":20}]}';
        $n->collect(wantsnmp => 0, wantwmi => 0, wanthttp => 0, wantredis => 1, force => 1);
        my $live = $n->get_inventory_ids(concept => 'sdwan_uplink', filter => { historic => 0 });
        ok(scalar @$live == 1, "one live sdwan_uplink row after wan2 dropped")
            or diag("got ".scalar(@$live));
    }
```

- [ ] **Step 5: Run the full test**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS (or SKIP without MongoDB).

- [ ] **Step 6: Commit**

```bash
cd /usr/local/nmis9
git add conf-default/Polling-Policy.nmis conf-default/Config.nmis models-default/Model-CiscoMerakiCloud.nmis test/t_polling_redis.pl
git commit -m "feat(redis): polling-policy + config + Meraki model + e2e reconcile test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Declare the Redis dependency + register the test in CI

**Files:**
- Modify: install manifest (find it: see Step 1)
- Modify: `ci/scripts/perl_tests.sh`

- [ ] **Step 1: Find the dependency manifest and add `Redis`**

Run: `cd /usr/local/nmis9 && grep -rIl --include=*.pm --include=cpanfile --include=Makefile* -e 'JSON::XS' -e 'Mojo::UserAgent' installer* install* admin/ bin/ 2>/dev/null; ls installer* install* 2>/dev/null`

NMIS9 lists CPAN prerequisites in the installer's module list (commonly an
`installer/*` perl-modules list or `admin/`-side check). Add `Redis` alongside
the existing `Mojo::UserAgent` / `JSON::XS` entries, matching that file's
format. If no manifest is found, add `Redis` to the same place the HTTP
engine's `Mojo::UserAgent` requirement was declared when that engine landed
(check `git log --oneline -- 'install*'` for the HTTP dependency commit).

- [ ] **Step 2: Register the test in CI**

In `ci/scripts/perl_tests.sh`, in the `working_tests` array, after the
`t_polling_http.pl` line, add:

```bash
    t_polling_redis.pl
```

- [ ] **Step 3: Verify the test is picked up**

Run: `cd /usr/local/nmis9 && grep -n t_polling_redis ci/scripts/perl_tests.sh`
Expected: one match in the array.

- [ ] **Step 4: Commit**

```bash
cd /usr/local/nmis9
git add ci/scripts/perl_tests.sh
git add -A install* installer* 2>/dev/null
git commit -m "build(redis): declare Redis CPAN dep + register t_polling_redis in CI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Full regression sweep

**Files:** none (verification only)

- [ ] **Step 1: Run the new test**

Run: `cd /usr/local/nmis9 && perl test/t_polling_redis.pl`
Expected: PASS (or controlled SKIP for the MongoDB-dependent block).

- [ ] **Step 2: Run the regression set named in the spec**

Run each and confirm no new failures versus a clean `nmis9_dev` baseline:

```bash
cd /usr/local/nmis9
perl test/t_polling_http.pl
perl test/t_polling.pl
perl test/t_sys.pl
```

Expected: each ends with its existing pass count; no new failures introduced
by the `wantredis` thread or the collect-time reconcile.

- [ ] **Step 3: Syntax-check every modified Perl file**

```bash
cd /usr/local/nmis9
for f in lib/NMISNG/Sys/Engine.pm lib/NMISNG/Sys/Engine/Redis.pm \
         lib/NMISNG/Sys.pm lib/NMISNG/Node.pm lib/NMISNG.pm bin/nmisd; do
  perl -c "$f" || echo "SYNTAX FAIL: $f";
done
```

Expected: `... syntax OK` for each, no `SYNTAX FAIL` lines.

- [ ] **Step 4: Update the graphify knowledge graph**

Run: `cd /usr/local/nmis9 && graphify update .`
Expected: completes (AST-only, no API cost), so the new engine file is indexed.

- [ ] **Step 5: Commit any final touch-ups**

If steps 1-4 required fixes, commit them:

```bash
cd /usr/local/nmis9
git add -A
git commit -m "test(redis): regression fixes from full sweep

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage**
- Engine class (§3.3) — Tasks 2-5.
- `manages_own_inventory` trait + collect-time reconcile (§3.1, §3.2, decision 5) — Tasks 1, 8.
- `redis_enabled` from `nmisent_engine_type` (decision 2) — Task 6.
- Empty-data semantics, no new lifecycle code (decision 3) — Task 5 (`discover_indexes`).
- Per-concept staleness event (decision 4) — Task 5.
- Six-layer scheduler thread + HGETDEL prompt path (decision 1, §3.5) — Tasks 7, 8, 9, 10.
- Env-first connection — Tasks 2, 9, 11.
- Polling-Policy + Config + Meraki model (§3.7, §3.8) — Task 11.
- Redis dependency + CI registration — Task 12.
- Verification incl. `t_polling.pl`/`t_sys.pl` — Task 13.

**Deliberate v1 scope notes (flag for reviewer)**
- `discover_indexes` supports single and composite (`__`-joined) index vars. The
  Meraki concepts use a single `wan_interface`, so composite is exercised only
  by future models.
- `update`-scheduling suppression for push-only nodes (§3.6) is **not** a
  separate task: cloud-managed Meraki nodes set `ping=false` and carry no
  SNMP/WMI/HTTP settings, so the existing update-due logic already finds no
  work. If a push-only node is observed scheduling empty updates in practice,
  add a gate in `find_due_nodes`' update branch. Called out so it is a
  conscious decision, not an omission.
- Redis `Config.nmis` password is read as plaintext. The spec notes it *can*
  run through `NMISNG::Util::decrypt` like `db_password`; deferred until a
  deployment needs an encrypted-at-rest Redis password.

**Placeholder scan** — no TBD/TODO in code steps; the only "confirm against
nmisent" notes are the spec's named open items (Meraki field names), not plan
gaps.

**Type/name consistency** — `wantredis`, `redis_run_id`, `redis_enabled`,
`nmisent_engine_type`, `manages_own_inventory`, `_payload`, `_payload_usable`,
`_raise_stale_event`/`_clear_stale_event`, `_redis_poll_complete`,
`_redis_handle`, and the key template `nmisent:metrics:{uuid}:{concept}` are
used identically across every task.
