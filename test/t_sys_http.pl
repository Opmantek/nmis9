#!/usr/bin/perl
#
# t_sys_http.pl — HTTP-engine companion to t_sys.pl. Exercises Sys::init wiring,
# section_keys dispatch through getValues, and Engine::HTTP integration with the
# rest of the model pipeline (catchall + systemHealth indexes).
#
# Mocks NMISNG::Sys::Engine::HTTP::_fetch so the test runs entirely in-process
# with no real HTTP transport (no Mojo::UserAgent, no fork). Each fixture URL
# maps to a canned response body.
#

use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Deep;
use Data::Dumper;
use JSON::XS;

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Sys::Engine::HTTP;

# ============================================================
# Setup
# ============================================================
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);

$C->{db_name} = "t_sys_http-" . time;

my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

sub cleanup { $nmisng->get_db()->drop(); }

# Skip RRD I/O — same monkey-patch t_polling.pl uses.
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

# ============================================================
# HTTP fixture: monkey-patch _fetch to return canned responses by URL.
# Each test phase can override %FIXTURE to suit.
# ============================================================
our %FIXTURE;     # url => { body => ..., content_type => ... }
{
	no warnings 'redefine';
	*NMISNG::Sys::Engine::HTTP::_fetch = sub {
		my ($self, $endpoint, $url) = @_;
		if (exists $FIXTURE{$url}) {
			my $f = $FIXTURE{$url};
			return ($f->{body}, $f->{content_type} // 'text/plain', undef);
		}
		return (undef, undef, "fixture missing for $url");
	};
}

my $PROM_BODY = <<'EOM';
# HELP node_load1 1m load
# TYPE node_load1 gauge
node_load1 0.42
# HELP node_load5 5m load
# TYPE node_load5 gauge
node_load5 0.30
# HELP node_load15 15m load
# TYPE node_load15 gauge
node_load15 0.10
# HELP node_memory_MemFree_bytes free memory
# TYPE node_memory_MemFree_bytes gauge
node_memory_MemFree_bytes 1234567890
EOM

my $APP_METRICS_BODY = <<'EOM';
# HELP app_queue_depth queue depth
# TYPE app_queue_depth gauge
app_queue_depth{queue="orders"} 3
app_queue_depth{queue="payments"} 1
app_queue_depth{queue="email"} 7
# HELP app_queue_processed_total total processed
# TYPE app_queue_processed_total counter
app_queue_processed_total{queue="orders"} 100
app_queue_processed_total{queue="payments"} 50
app_queue_processed_total{queue="email"} 200
EOM

my $STATUS_BODY = encode_json({ app => { state => 'running', uptime_seconds => 3600 } });

# ============================================================
# Create node with http_endpoints
# ============================================================
my $http_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$http_node->cluster_id($C->{cluster_id});
$http_node->name("test_sys_http");
$http_node->configuration({
	host      => "127.0.0.1",
	group     => "TestGroup",
	netType   => "default",
	roleType  => "default",
	threshold => 1,
	model     => "TestHTTP",
	collect   => "true",
	ping      => "false",
	http_endpoints => [
		{ name => 'node_exporter', port => 9100 },
		{ name => 'app_metrics',   port => 9200 },
		{ name => 'app_status',    port => 9300 },
	],
});
my ($op, $err) = $http_node->save();
ok(!$err, "HTTP test node saved") or diag("Error: $err");

# Map URLs to canned bodies. With node host=127.0.0.1 and the ports above,
# each endpoint's resolved URL is deterministic.
%FIXTURE = (
	'http://127.0.0.1:9100/metrics' => { body => $PROM_BODY,        content_type => 'text/plain' },
	'http://127.0.0.1:9200/metrics' => { body => $APP_METRICS_BODY, content_type => 'text/plain' },
	'http://127.0.0.1:9300/status'  => { body => $STATUS_BODY,      content_type => 'application/json' },
);

# ============================================================
# Phase 1: Sys::init wires Engine::HTTP correctly
# ============================================================
diag("=== Phase 1: Sys::init wires Engine::HTTP ===");

my ($catchall, $cerr) = $http_node->inventory(concept => "catchall", model_class => "system");
ok(!$cerr, "catchall created");

my $S = NMISNG::Sys->new(nmisng => $nmisng);
$S->init(node => $http_node, snmp => 0, wmi => 0, update => 'true', force => 1, catchall_inventory => $catchall);

# HTTP engine should be present and active.
my @http_engines = grep { $_->protocol_name eq 'http' } @{$S->engines};
is(scalar @http_engines, 1, "exactly one HTTP engine in engines list");
ok($http_engines[0]->is_active, "HTTP engine reports is_active");

# section_keys returns the two HTTP body-format keys.
is_deeply([sort @{$http_engines[0]->section_keys}], [sort qw(http_prom http_json)],
	"HTTP engine section_keys = http_prom + http_json");

# known_sources should include http.
ok((grep { $_ eq 'http' } @{$S->known_sources}), "'http' is a known_source on Sys");

# enabled_sources should include http (since the engine is active).
ok((grep { $_ eq 'http' } @{$S->enabled_sources}), "'http' is in enabled_sources");

# ============================================================
# Phase 2: update_node_info populates catchall from sys.standard
# ============================================================
diag("=== Phase 2: sys.standard.http_prom + http_json -> catchall ===");

$http_node->update_node_info(sys => $S, catchall_inventory => $catchall);
$catchall->save(node => $http_node);

my $cd = $catchall->data_live();
diag("catchall keys: " . join(",", sort keys %$cd));
diag("model loaded? mdl.system.sys.standard.http_prom keys: " . join(",", sort keys %{$S->{mdl}{system}{sys}{standard}{http_prom} || {}}));
is($cd->{load1},   '0.42',       "catchall.load1 from http_prom");
is($cd->{memfree}, '1234567890', "catchall.memfree from http_prom");
is($cd->{state},   'running',    "catchall.state from http_json");
is($cd->{uptime},  3600,         "catchall.uptime from http_json");

# nodeModel should be set
is($cd->{nodeModel}, 'TestHTTP', "catchall.nodeModel set");

# ============================================================
# Phase 3: collect_systemhealth_info discovers indexes via Engine::HTTP
# ============================================================
diag("=== Phase 3: systemHealth discover_indexes via http_prom ===");

$http_node->collect_systemhealth_info(sys => $S, catchall_inventory => $catchall);

# Inventory should have one record per discovered queue.
my $ids = $http_node->get_inventory_ids(
	concept => 'AppQueues',
	filter  => { historic => 0 },
);
ok(@$ids >= 3, "AppQueues inventory has >= 3 rows discovered") or diag("got " . scalar @$ids . " rows");

my %by_queue;
for my $id (@$ids) {
	my ($inv, $ie) = $http_node->inventory(_id => $id);
	next if $ie || !$inv;
	my $d = $inv->data;
	$by_queue{$d->{index}} = $d if defined $d->{index};
}
ok(exists $by_queue{orders},   "AppQueues discovered: orders");
ok(exists $by_queue{payments}, "AppQueues discovered: payments");
ok(exists $by_queue{email},    "AppQueues discovered: email");

# ============================================================
# Phase 4: section_keys dispatch — getValues delegates to HTTP engine
# ============================================================
diag("=== Phase 4: getValues dispatch via section_keys ===");

# Grab the rrd.load section and verify build/execute populates rawvalues.
my $S2 = NMISNG::Sys->new(nmisng => $nmisng);
$S2->init(node => $http_node, snmp => 0, wmi => 0, update => 0, catchall_inventory => $catchall);

my $eng = (grep { $_->protocol_name eq 'http' } @{$S2->engines})[0];
ok($eng, "HTTP engine present in collect-mode Sys");
$eng->reset_cache;

my %todos;
my $sec = $S2->{mdl}{system}{rrd}{load};
ok(ref $sec eq 'HASH', "rrd.load section loaded from model");

# Build via the engine using section_keys["http_prom"] (mirrors what Sys::getValues does).
$eng->build_queries(
	section_name => 'load',
	section_key  => 'http_prom',
	section_hash => $sec->{http_prom},
	todos        => \%todos,
);
$eng->execute_queries(todos => \%todos);

cmp_ok($todos{load1}{rawvalue},  '==', 0.42, "rrd.load.load1 fetched");
cmp_ok($todos{load5}{rawvalue},  '==', 0.30, "rrd.load.load5 fetched");
cmp_ok($todos{load15}{rawvalue}, '==', 0.10, "rrd.load.load15 fetched");
ok($todos{load1}{done},                     "rrd.load.load1 marked done");

# ============================================================
# Phase 5: scrape-response cache reused across todos sharing a URL
# ============================================================
diag("=== Phase 5: response cache ===");

# load1, load5, load15 all hit the same URL — cache should hold exactly one.
is(scalar(keys %{$eng->{response_cache}}), 1,
	"response cache has 1 URL despite 3 items sharing it");

# ============================================================
# Phase 6: regressions — known_sources / enabled_sources / disable
# ============================================================
diag("=== Phase 6: source-list integrations ===");

# disable_source removes the engine cleanly.
my $S3 = NMISNG::Sys->new(nmisng => $nmisng);
$S3->init(node => $http_node, snmp => 0, wmi => 0, update => 0, catchall_inventory => $catchall);
ok(scalar(grep { $_->protocol_name eq 'http' } @{$S3->engines}) == 1,
	"before disable: http engine present");

$S3->disable_source('http');
ok(scalar(grep { $_->protocol_name eq 'http' } @{$S3->engines}) == 0,
	"after disable_source('http'): engine removed");

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
cleanup();
ok(1, "Cleanup complete");

done_testing();
