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
our %REDIS_KV;
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

done_testing();
