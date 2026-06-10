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
require RRDs unless defined &RRDs::info;
{
    no warnings 'redefine';
    *RRDs::info = sub { return {}; };
}
{
    no warnings 'redefine';
    *Compat::NMIS::getSubconceptStats = sub { return {}; };
}

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
    package FakeNode;
    sub new  { my ($c,%a)=@_; bless { %a }, $c }
    sub uuid { return $_[0]->{uuid}; }
    sub name { return $_[0]->{name} // 'fakenode'; }
    our $AUTOLOAD;
    sub AUTOLOAD { return undef; }
    sub DESTROY  { }
}
{
    package FakeSys;
    sub new { my ($c,%a)=@_; bless { %a }, $c }
    sub nmisng      { return $_[0]->{nmisng}; }
    sub nmisng_node { return $_[0]->{node}; }
    our $AUTOLOAD;
    sub AUTOLOAD { return undef; }
    sub DESTROY  { }
}

my $fake_nmisng = FakeNmisng->new(config => { });
my $fake_node   = FakeNode->new(uuid => '11111111-2222-3333-4444-555555555555', name => 'fakenode');
my $fake_sys = FakeSys->new(
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
            .'{"wan_interface":"wan1","status":"active","latency_ms":24},'
            .'{"wan_interface":"wan2","status":"ready","latency_ms":12}]}';
        $main::REDIS_KV{"nmisent:metrics:$ruuid:sdwan_health"} =
            '{"_meta":{"collected_at_epoch":'.time().'},"data":{"status":"online","cpu_load_5min":0.23,"memory_used_pct":47.2}}';

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
