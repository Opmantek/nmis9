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
use NMISNG::Sys;
use Compat::NMIS;

# Skip RRD I/O via the shared recording stub (test/lib/NMISNG/Test/RRDStub.pm);
# tests assert on the recorded calls so redis-sourced data provably reaches
# the RRD writer. Alias keeps the existing @main::RRD_CALLS references.
use NMISNG::Test::RRDStub;
NMISNG::Test::RRDStub::install();
our @RRD_CALLS;
*RRD_CALLS = \@NMISNG::Test::RRDStub::CALLS;

# Task 1: the trait exists and defaults to 0 on the base class.
can_ok('NMISNG::Sys::Engine', 'manages_own_inventory');
is(NMISNG::Sys::Engine::manages_own_inventory(), 0,
   "base engine manages_own_inventory defaults to 0");

# ---- shared connection settings resolver (NMISNG::Util) ----
# one source of endpoint truth for the engine and the scheduler prompt path
{
    require NMISNG::Util;
    local @ENV{qw(NMIS_REDIS_SERVER NMIS_REDIS_PORT NMIS_REDIS_PASSWORD)};
    delete @ENV{qw(NMIS_REDIS_SERVER NMIS_REDIS_PORT NMIS_REDIS_PASSWORD)};

    my ($args, $disp) = NMISNG::Util::redis_connect_args({});
    is($disp, 'localhost:6379', "resolver defaults to localhost:6379");
    is($args->{server}, 'localhost:6379', "Redis->new server arg matches");
    ok(!exists $args->{password}, "no password arg by default");

    ($args, $disp) = NMISNG::Util::redis_connect_args(
        { redis_server => 'redis.example', redis_port => 7000, redis_password => 'cfgpass' });
    is($disp, 'redis.example:7000', "config overrides defaults");
    is($args->{password}, 'cfgpass', "config password used");

    local $ENV{NMIS_REDIS_SERVER}   = 'envhost';
    local $ENV{NMIS_REDIS_PORT}     = 7777;
    local $ENV{NMIS_REDIS_PASSWORD} = 'envpass';
    ($args, $disp) = NMISNG::Util::redis_connect_args(
        { redis_server => 'redis.example', redis_port => 7000, redis_password => 'cfgpass' });
    is($disp, 'envhost:7777', "env overrides config");
    is($args->{password}, 'envpass', "env password wins");

    # empty env password falls through to the config one
    $ENV{NMIS_REDIS_PASSWORD} = '';
    ($args) = NMISNG::Util::redis_connect_args({ redis_password => 'cfgpass' });
    is($args->{password}, 'cfgpass', "empty env password falls through to config");
}

# ---- Task 2: engine identity + payload fetch ----
use NMISNG::Sys::Engine::Redis;

# A minimal fake Sys: the engine only needs ->sys->{uuid},
# ->sys->nmisng->log, ->sys->nmisng->config, and ->sys->nmisng_node.
# Shared fakes from test/lib/NMISNG/Test/Fakes.pm.
use NMISNG::Test::Fakes;

my $fake_nmisng = NMISNG::Test::FakeNmisng->new(config => { });
my $fake_node   = NMISNG::Test::FakeNode->new(uuid => '11111111-2222-3333-4444-555555555555', name => 'fakenode');
my $fake_sys = NMISNG::Test::FakeSys->new(
    uuid   => '11111111-2222-3333-4444-555555555555',
    nmisng => $fake_nmisng,
    node   => $fake_node,
);

# Pre-load Compat::NMIS and install no-op stubs so that the real
# _raise_stale_event / _clear_stale_event (added in Task 5) don't try to
# drive the full event system against the fake Sys throughout this test file.
# The Task 5 event block overrides these locally with capturing stubs.
require Compat::NMIS;
{
    no warnings 'redefine';
    *Compat::NMIS::notify     = sub { return; };
    *Compat::NMIS::checkEvent = sub { return; };
}
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
    # scheduler prompt path: HGETDEL key FIELDS n field [field ...] —
    # destructive batch read of the poll-complete hash, faked via
    # %main::REDIS_HASH (field => json). Positional results, undef gaps.
    sub hgetdel { my ($s, $key, $kw, $n, @fields) = @_; return map { delete $main::REDIS_HASH{$_} } @fields; }
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

    # Stale payload: discovery must refuse it like the data path does (and
    # raise the stale alarm), instead of creating/retiring inventory from
    # data the engine itself classifies unusable.
    {
        our @notified_d;
        no warnings 'redefine';
        local *Compat::NMIS::notify = sub { push @notified_d, {@_}; return; };
        $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_uplink'} =
            '{"_meta":{"collected_at_epoch":'.(time()-9999).'},"data":[{"wan_interface":"wan1"}]}';
        my $engs = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
        my ($es) = $engs->discover_indexes(
            section_config => { redis => { '-common-' => { concept => 'sdwan_uplink', freshness => 600 } } },
            index_var      => 'wan_interface',
        );
        ok($es, "stale payload -> discover_indexes refuses");
        is($engs->classify_error->{type}, 'not_present',
           "stale payload -> not_present (soft skip, inventory untouched)");
        ok(@notified_d && $notified_d[0]{event} =~ /stale/i,
           "stale payload at discovery raises the stale event");
        delete $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_uplink'};
    }

    # classify_error must not mistake a concept named like 'connect' for a
    # connection failure (no_session aborts the whole systemHealth collect).
    {
        my $engc = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
        $engc->{_last_error} = "no key for concept vpn_connections";
        is($engc->classify_error->{type}, 'not_present',
           "concept named *connect* with missing key stays not_present");
        $engc->{_last_error} = "redis connect to localhost:6379 failed: timeout";
        is($engc->classify_error->{type}, 'no_session',
           "real connect failure still classifies no_session");
    }
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

# An absent key must clear an open stale alarm (the key vanishing is a
# normal state — optional concept, reset store — not a frozen payload),
# and raise/clear must hit the event system once per concept per engine
# lifetime, not once per index.
{
    our (@notified2, @checked2);
    no warnings 'redefine';
    local *Compat::NMIS::notify     = sub { push @notified2, {@_}; return; };
    local *Compat::NMIS::checkEvent = sub { push @checked2,  {@_}; return; };

    delete $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_health'};
    my $enga = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
    my $st = $enga->build_queries(
        section_name => 'sdwan_health',
        section_hash => { '-common-' => { concept => 'sdwan_health' } },
        todos        => {},
    );
    ok(!$st->{error}, "absent key: no error from build_queries");
    is(scalar(@checked2), 1, "absent key clears any open stale event");
    is($checked2[0]{element} // '', 'sdwan_health', "clear is for the right concept");

    # second call in the same engine lifetime: guarded, no extra round trip
    $enga->build_queries(
        section_name => 'sdwan_health',
        section_hash => { '-common-' => { concept => 'sdwan_health' } },
        todos        => {},
    );
    is(scalar(@checked2), 1, "clear runs once per concept per engine lifetime");

    # raise guard: a stale payload gated three times raises once
    $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_health'} =
        '{"_meta":{"collected_at_epoch":'.(time()-9999).'},"data":{"status":"online"}}';
    my $engb = NMISNG::Sys::Engine::Redis->new(sys => $fake_sys);
    for (1..3) {
        my ($pl) = $engb->_payload('sdwan_health');
        $engb->_payload_usable('sdwan_health', $pl, 600);
    }
    is(scalar(@notified2), 1, "stale raise runs once per concept per engine lifetime");
    delete $main::REDIS_KV{'nmisent:metrics:11111111-2222-3333-4444-555555555555:sdwan_health'};
}

# ---- Task 6: redis_enabled derivation ----
SKIP: {
    eval {
        require NMISNG;
        require NMISNG::Node;
        require NMISNG::Sys;
        require NMISNG::Util;
        require NMISNG::Log;
    };
    skip "NMISNG/DB not available in this environment", 5 if $@;

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

    # ---- Task 7: Sys::init wires the redis engine ----
    $n->configuration({ %base, nmisent_engine_type => 'meraki' });
    my ($sop, $serr) = $n->save();
    # Create a minimal catchall directly (avoids calling update which requires
    # RRDs and a live SNMP session). Sys::init needs non-empty catchall data
    # in collect mode to proceed past the gigo guard.
    my ($cinv, $cierr) = $n->inventory(
        concept => "catchall", path_keys => [], create => 1,
        data => { name => $n->name, nodeType => "generic" });
    $cinv->save(node => $n) if $cinv;
    my $S = NMISNG::Sys->new(nmisng => $ng);
    $S->init(node => $n, snmp => 0, wmi => 0, http => 0, redis => 1,
             update => 0, catchall_inventory => $cinv);
    ok((grep { $_->protocol_name eq 'redis' } @{$S->engines}),
       "redis engine present in Sys when wantredis + redis_enabled");
    ok((grep { $_ eq 'redis' } @{$S->known_sources}),
       "redis is in Sys::known_sources");
    is($S->status->{redis_enabled}, 1,
       "Sys::status surfaces redis_enabled=1 when the engine is active");
    ok(exists $S->status->{redis_error},
       "Sys::status surfaces a redis_error key (undef when no error)");

    # ---- Task 9: find_due_nodes sets the redis flavour ----
    $ng->ensure_indexes;
    my $due = $ng->find_due_nodes(type => 'collect', force => 1);
    ok($due->{success}, "find_due_nodes success");
    my $fl = ($due->{flavours} // {})->{ $n->uuid };
    ok($fl, "redis node present in due list");
    ok($fl->{redis}, "redis flavour enabled for a redis_enabled node");

    # ---- handle_down: per-source down/up events for push + http sources ----
    # The type gate in Node::handle_down used to silently drop 'redis' and
    # 'http', so a dead source raised no event at all. Pin the contract:
    # these sources map to a stateful "<X> Down" event raised via
    # Compat::NMIS::notify and cleared via checkEvent, and unknown source
    # types stay no-ops.
    {
        no warnings 'redefine';
        my (@notified, @checked);
        local *Compat::NMIS::notify     = sub { push @notified, {@_}; return; };
        local *Compat::NMIS::checkEvent = sub { push @checked,  {@_}; return; };

        for my $case ([redis => 'Redis Down'], [http => 'HTTP Down'])
        {
            my ($type, $eventname) = @$case;
            @notified = @checked = ();
            $n->handle_down(sys => $S, type => $type,
                details => "$type test failure", catchall_inventory => $cinv);
            is(scalar(@notified), 1, "handle_down($type) raises one event");
            is($notified[0]{event} // '', $eventname,
               "handle_down($type) raises '$eventname'");
            $n->handle_down(sys => $S, type => $type, up => 1,
                details => "$type ok", catchall_inventory => $cinv);
            is(scalar(@checked), 1, "handle_down($type, up) clears via checkEvent");
            is($checked[0]{event} // '', $eventname,
               "handle_down($type) clear targets '$eventname'");
        }

        @notified = @checked = ();
        $n->handle_down(sys => $S, type => 'bogus',
            details => "x", catchall_inventory => $cinv);
        ok(!@notified && !@checked, "unknown source type stays a no-op");

        # Both events must ship registered as stateful in conf-default,
        # or notify/checkEvent pairing degrades to the Default entry.
        my %events;
        {
            open(my $fh, '<', "$FindBin::Bin/../conf-default/Events.nmis")
                or die "cannot read Events.nmis: $!";
            my $content = do { local $/; <$fh> };
            my %hash;
            eval $content;
            die "Events.nmis parse failed: $@" if $@;
            %events = %hash;
        }
        for my $ev ('Redis Down', 'HTTP Down')
        {
            is(($events{$ev}{Stateful} // ''), 'true',
               "$ev registered stateful in conf-default/Events.nmis");
        }
    }

    # ---- Task 11: end-to-end reconcile via the collect path ----
    {
        my $rnode = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
        $rnode->cluster_id($C->{cluster_id});
        $rnode->name("t_redis_e2e_node");
        $rnode->activated({ NMIS => 1 });
        $rnode->configuration({
            host => "127.0.0.1", group => "TestGroup", netType => "default",
            roleType => "default", model => "TestRedis", collect => "true",
            ping => "false", nmisent_engine_type => "meraki",
        });
        my ($rop, $rerr) = $rnode->save();
        ok(!$rerr, "redis e2e node saved") or diag($rerr);

        my $ruuid = $rnode->uuid;

        # Faithful end-to-end: stub the engine's redis client (covering update
        # too) and seed the data BEFORE update. update then sees the data,
        # loadInfo(system) succeeds, nodeModel settles to TestRedis and
        # last_update is set — so collect proceeds to the RRD pass with NO
        # planted catchall state.
        no warnings 'redefine';
        local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

        $main::REDIS_KV{"nmisent:metrics:$ruuid:sdwan_uplink"} =
            '{"_meta":{"collected_at_epoch":'.time().'},"data":['
            .'{"wan_interface":"wan1","status":"active","latency_ms":24,"loss_pct":0.5,'
            .'"ip":"192.168.0.4","gateway":"192.168.0.1","public_ip":"201.141.126.57",'
            .'"primary_dns":"8.8.8.8","secondary_dns":"8.8.4.4","ip_assigned_by":"dhcp"},'
            .'{"wan_interface":"wan2","status":"ready","latency_ms":12,"loss_pct":1.0}]}';
        $main::REDIS_KV{"nmisent:metrics:$ruuid:sdwan_health"} =
            '{"_meta":{"collected_at_epoch":'.time().'},"data":{"status":"online","cpu_load_5min":0.23,"memory_used_pct":47.2,'
            .'"ha_role":"primary","ha_enabled":false,"last_reported_at":"2026-06-10T05:12:19Z"}}';

        $rnode->update(force => 1);

        {
            @main::RRD_CALLS = ();
            # No force: routine scheduled polling runs collect without it (force
            # is only set for operator-triggered jobs). Proves the prod path.
            $rnode->collect(wantsnmp => 0, wantwmi => 0, wanthttp => 0, wantredis => 1);

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
            # loss is the new time-series field — it must reach the RRD writer too.
            my %loss = map { ($_->{index} // '') => $_->{data}{loss} } @uplink_rrd;
            ok((defined $loss{wan1} && $loss{wan1} == 0.5),
               "wan1 loss (0.5) reached the RRD writer")
                or diag("wan1 loss at RRD writer: ".(defined $loss{wan1} ? $loss{wan1} : 'undef'));
            # new inventory string fields must land on the inventory row.
            my $ipseen;
            for my $id (@$ids) {
                my ($iv) = $rnode->inventory(_id => $id);
                next unless $iv;
                $ipseen = $iv->data->{ip} if (($iv->data->{index} // '') eq 'wan1');
            }
            ok((defined $ipseen && $ipseen eq '192.168.0.4'),
               "wan1 inventory captured the uplink ip field")
                or diag("wan1 inventory ip: ".(defined $ipseen ? $ipseen : 'undef'));

            # Drop wan2; it must go historic, wan1 survives.
            $main::REDIS_KV{"nmisent:metrics:$ruuid:sdwan_uplink"} =
                '{"_meta":{"collected_at_epoch":'.time().'},"data":['
                .'{"wan_interface":"wan1","status":"active","latency_ms":20}]}';
            # No force: routine scheduled polling runs collect without it (force
            # is only set for operator-triggered jobs). Proves the prod path.
            $rnode->collect(wantsnmp => 0, wantwmi => 0, wanthttp => 0, wantredis => 1);
            my $live = $rnode->get_inventory_ids(concept => 'sdwan_uplink', filter => { historic => 0 });
            ok(scalar(@$live) == 1, "one live sdwan_uplink row after wan2 dropped")
                or diag("got ".scalar(@$live));

            # The graphtype must resolve to an RRD database path (a
            # database.type.sdwan_uplink template), else both RRD creation and
            # the GUI fail with "failed to find database for graphtype". The
            # e2e above stubs create_update_rrd, so assert the resolution
            # directly via makeRRDname.
            my $Sg = NMISNG::Sys->new(nmisng => $ng);
            my ($gci) = $rnode->inventory(concept => "catchall");
            $Sg->init(node => $rnode, snmp => 0, wmi => 0, http => 0, redis => 1,
                      update => 0, catchall_inventory => $gci);
            my $rrdname = $Sg->makeRRDname(graphtype => 'sdwan_uplink', index => 'wan1', relative => 1);
            ok(defined $rrdname && $rrdname =~ /sdwan_uplink.*wan1/,
               "graphtype sdwan_uplink resolves to an RRD path (database.type present)")
                or diag("makeRRDname returned: ".(defined $rrdname ? $rrdname : 'undef'));
            # the loss graphtype shares the same per-uplink RRD (second DS).
            my $lossrrd = $Sg->makeRRDname(graphtype => 'sdwan_loss', index => 'wan1', relative => 1);
            ok(defined $lossrrd && $lossrrd =~ /sdwan_uplink.*wan1/,
               "graphtype sdwan_loss resolves to the shared sdwan_uplink RRD")
                or diag("makeRRDname(sdwan_loss) returned: ".(defined $lossrrd ? $lossrrd : 'undef'));

            # loadInfo must propagate redis_error into Sys status. It used to
            # copy only wmi/snmp/http_error, so a redis failure during
            # loadInfo(system) was recorded downstream as a successful poll
            # (redisresult=100, last_poll_redis stamped).
            {
                local *FakeRedisClient::get = sub { die "connection lost\n" };
                my $Se = NMISNG::Sys->new(nmisng => $ng);
                $Se->init(node => $rnode, snmp => 0, wmi => 0, http => 0, redis => 1,
                          update => 0, catchall_inventory => $gci);
                $Se->loadInfo(class => 'system', inventory => $gci, target => {});
                ok($Se->status->{redis_error},
                   "loadInfo propagates redis_error into Sys status")
                    or diag("status redis_error: ".($Se->status->{redis_error} // 'undef')
                            .", error: ".($Se->status->{error} // 'undef'));
            }

            # ---- prompt path: redis-only flavours, at-most-once, collect gate ----
            {
                local *NMISNG::_redis_handle = sub { return FakeRedisClient->new; };

                # make the node not cadence-due: fresh redis attempt marker,
                # no snmp/wmi/http history (those sources are disabled).
                my $cd = $gci->data_live;
                $cd->{last_poll_redis_attempt} = time;
                $gci->save(node => $rnode);

                # a completion entry must force the node due with a
                # redis-ONLY flavour set: snmp/wmi/http pinned to 0, not
                # left undef (Node::collect treats undef wanthttp as
                # legacy default-on and would poll HTTP at the push rate).
                $main::REDIS_HASH{$ruuid} = '{"run_id":"R42"}';
                my $pdue = $ng->find_due_nodes(type => 'collect');
                ok($pdue->{success}, "prompt-path find_due_nodes success");
                ok(exists $pdue->{nodes}{$ruuid},
                   "completion entry forces non-cadence-due node due");
                my $pfl = ($pdue->{flavours} // {})->{$ruuid} // {};
                is($pfl->{redis}, 1, "prompt: redis flavour on");
                is($pfl->{redis_run_id} // '', 'R42', "prompt: run_id carried");
                ok((defined $pfl->{snmp} && !$pfl->{snmp}
                    && defined $pfl->{wmi} && !$pfl->{wmi}
                    && defined $pfl->{http} && !$pfl->{http}),
                   "prompt: snmp/wmi/http explicitly 0, not undef")
                    or diag("flavours: ".join(",", map {"$_=".($pfl->{$_}//'undef')} qw(snmp wmi http redis)));
                ok(!exists $main::REDIS_HASH{$ruuid},
                   "prompt entry consumed (at-most-once)");

                # without an entry the node is not due (cadence fresh).
                my $ndue = $ng->find_due_nodes(type => 'collect');
                ok(!exists $ndue->{nodes}{$ruuid},
                   "no entry, fresh cadence: node not due");

                # collect=false (ping-only) node: prompt must not force a
                # collect, and its entry must be left unconsumed.
                my $ping = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
                $ping->cluster_id($C->{cluster_id});
                $ping->name("t_redis_pingonly_node");
                $ping->activated({ NMIS => 1 });
                $ping->configuration({
                    host => "127.0.0.1", group => "TestGroup", netType => "default",
                    roleType => "default", model => "TestRedis", collect => "false",
                    ping => "true", nmisent_engine_type => "meraki",
                });
                $ping->save();
                my ($pci) = $ping->inventory(
                    concept => "catchall", path_keys => [], create => 1,
                    data => { name => $ping->name, nodeType => "generic" });
                my $pcd = $pci->data_live;
                $pcd->{nodeModel} = "TestRedis";       # skip the demotion branch
                $pcd->{last_poll_attempt} = time;      # generic pingonly cadence fresh
                $pci->save(node => $ping);

                $main::REDIS_HASH{$ping->uuid} = '{"run_id":"R43"}';
                my $gdue = $ng->find_due_nodes(type => 'collect');
                ok(!exists $gdue->{nodes}{$ping->uuid},
                   "collect=false node: prompt does not force a collect");
                ok(exists $main::REDIS_HASH{$ping->uuid},
                   "collect=false node: entry left unconsumed");
                delete $main::REDIS_HASH{$ping->uuid};
            }

            # ---- scheduler redis handle: cached failures + connect holdoff ----
            # (the real _redis_handle, not the stub above — these states must
            # short-circuit before any require/connect attempt)
            {
                local $ng->{_redis_handle};
                local $ng->{_redis_module_missing} = 1;
                local $ng->{_redis_connect_failed_at};
                is($ng->_redis_handle, undef,
                   "missing-module failure is cached: returns undef, no die");

                $ng->{_redis_module_missing} = 0;
                $ng->{_redis_connect_failed_at} = Time::HiRes::time;
                is($ng->_redis_handle, undef,
                   "recent connect failure: holdoff returns undef without reconnecting");

                $ng->{_redis_handle} = FakeRedisClient->new;
                isa_ok($ng->_redis_handle, 'FakeRedisClient',
                       "cached handle is reused");
            }

            # ---- orphan sweep: stale events for concepts dropped from model ----
            {
                require NMISNG::ModelData;
                our @checked3;
                no warnings 'redefine';
                local *Compat::NMIS::checkEvent = sub { push @checked3, {@_}; return; };
                local *NMISNG::Node::get_events_model = sub {
                    return NMISNG::ModelData->new(data => [
                        { element => 'ghost_concept' },
                        { element => 'sdwan_uplink'  },
                    ]);
                };
                my ($sweep) = grep { $_->protocol_name eq 'redis' } @{$Sg->engines};
                ok($sweep, "redis engine available for sweep");
                my %mc = map { $_ => 1 } @{ $sweep->model_concepts };
                ok($mc{sdwan_uplink} && $mc{sdwan_health},
                   "model_concepts finds the TestRedis concepts");
                $sweep->close_orphaned_stale_events;
                is(scalar(@checked3), 1, "sweep clears exactly one event");
                is($checked3[0]{element} // '', 'ghost_concept',
                   "swept event is the concept no longer in the model");
            }
        }
    }

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

    # ---- Explicit configured model is honored, even with no data yet ----
    # A correctly-configured push node whose redis data has not arrived yet
    # (update's loadInfo collects nothing) must keep its configured nodeModel,
    # NOT fall back to Generic, and must NOT raise a spurious model error.
    {
        my @notified;
        no warnings 'redefine';
        local *Compat::NMIS::notify = sub { push @notified, {@_}; return; };

        my $boot = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
        $boot->cluster_id($C->{cluster_id});
        $boot->name("t_redis_bootstrap_node");
        $boot->activated({ NMIS => 1 });
        $boot->configuration({
            host => "127.0.0.1", group => "TestGroup", netType => "default",
            roleType => "default", model => "TestRedis", collect => "true",
            ping => "false", nmisent_engine_type => "meraki",
        });
        $boot->save();
        # deliberately NO redis data seeded — update's loadInfo(system) finds nothing
        $boot->update(force => 1);

        my ($bci) = $boot->inventory(concept => "catchall");
        is($bci->data->{nodeModel}, 'TestRedis',
           "explicit model honored: nodeModel stays TestRedis with no data (not Generic)")
            or diag("got nodeModel=".($bci->data->{nodeModel}//'undef'));
        ok(!(grep { ($_->{event} // '') eq "Model File Invalid" } @notified),
           "correctly-configured push model awaiting data does NOT raise Model File Invalid")
            or diag("notify events: ".join(",", map { $_->{event} // '?' } @notified));

        # Contrast case: a poll-based node (no push engine) with an explicit
        # model whose first load fails must NOT have the configured model
        # stamped into nodeModel. Upstream semantics: nodeModel reflects what
        # discovery found — update()'s 'Generic' fallback when it found
        # nothing — and reachability weighting keys on that.
        my $dead = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
        $dead->cluster_id($C->{cluster_id});
        $dead->name("t_dead_snmp_node");
        $dead->activated({ NMIS => 1 });
        $dead->configuration({
            host => "127.0.0.1", group => "TestGroup", netType => "default",
            roleType => "default", model => "TestSnmp", collect => "true",
            ping => "false",
        });
        $dead->save();
        $dead->update(force => 1);

        my ($dci) = $dead->inventory(concept => "catchall");
        my $deadmodel = $dci ? $dci->data->{nodeModel} : undef;
        isnt($deadmodel // '', 'TestSnmp',
           "poll-based node with failed load does not get the configured model stamped");
        is($deadmodel // '', 'Generic',
           "poll-based node with failed load keeps update()'s Generic fallback (base parity)");
    }

    # ---- Model File Invalid clears once the push model is fixed ----
    {
        my (@notified, @checked);
        no warnings 'redefine';
        local *Compat::NMIS::notify     = sub { push @notified, {@_}; return; };
        local *Compat::NMIS::checkEvent = sub { push @checked,  {@_}; return; };
        local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

        my $fx = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
        $fx->cluster_id($C->{cluster_id});
        $fx->name("t_redis_fixclear_node");
        $fx->activated({ NMIS => 1 });

        # 1. misconfigured push model (no system-level redis section) -> raises
        $fx->configuration({
            host => "127.0.0.1", group => "G", netType => "default", roleType => "default",
            model => "TestRedisNoSys", collect => "true", ping => "false", nmisent_engine_type => "meraki",
        });
        $fx->save();
        $fx->update(force => 1);
        ok((grep { ($_->{event} // '') eq "Model File Invalid" } @notified),
           "fix-clear: misconfigured push model raises Model File Invalid");

        # 2. fix it: correct model + data present -> the event must be cleared
        my $fu = $fx->uuid;
        $main::REDIS_KV{"nmisent:metrics:$fu:sdwan_health"} =
            '{"_meta":{"collected_at_epoch":'.time().'},"data":{"status":"online","cpu_load_5min":0.1,"memory_used_pct":30}}';
        $fx->configuration({
            host => "127.0.0.1", group => "G", netType => "default", roleType => "default",
            model => "TestRedis", collect => "true", ping => "false", nmisent_engine_type => "meraki",
        });
        $fx->save();
        @checked = ();
        $fx->update(force => 1);
        ok((grep { ($_->{event} // '') eq "Model File Invalid" } @checked),
           "fix-clear: correcting the model clears Model File Invalid (checkEvent)")
            or diag("checkEvent events: ".join(",", map { $_->{event} // '?' } @checked));
    }

    # ---- Model File Invalid clears when fixed even before data arrives ----
    # (symmetric clear on the !firstloadok branch). Raise via a section-less
    # model, then correct the model with NO data seeded — update stays on the
    # !firstloadok path, which must still clear the event.
    {
        my (@notified, @checked);
        no warnings 'redefine';
        local *Compat::NMIS::notify     = sub { push @notified, {@_}; return; };
        local *Compat::NMIS::checkEvent = sub { push @checked,  {@_}; return; };
        local *NMISNG::Sys::Engine::Redis::_redis = sub { return FakeRedisClient->new; };

        my $nd = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $ng);
        $nd->cluster_id($C->{cluster_id});
        $nd->name("t_redis_fixnodata_node");
        $nd->activated({ NMIS => 1 });
        # 1. broken model, no data -> raise
        $nd->configuration({
            host => "127.0.0.1", group => "G", netType => "default", roleType => "default",
            model => "TestRedisNoSys", collect => "true", ping => "false", nmisent_engine_type => "meraki",
        });
        $nd->save();
        $nd->update(force => 1);
        ok((grep { ($_->{event} // '') eq "Model File Invalid" } @notified),
           "fix-nodata: broken push model raises Model File Invalid");

        # 2. correct the model but seed NO data (firstloadok stays false) -> must clear
        $nd->configuration({
            host => "127.0.0.1", group => "G", netType => "default", roleType => "default",
            model => "TestRedis", collect => "true", ping => "false", nmisent_engine_type => "meraki",
        });
        $nd->save();
        @checked = ();
        $nd->update(force => 1);
        ok((grep { ($_->{event} // '') eq "Model File Invalid" } @checked),
           "fix-nodata: corrected model clears Model File Invalid even with no data yet")
            or diag("checkEvent events: ".join(",", map { $_->{event} // '?' } @checked));
    }

    $ng->get_db()->drop();
}

done_testing();
