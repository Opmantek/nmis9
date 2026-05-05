#!/usr/bin/perl
#
# t_polling_http.pl — HTTP-engine companion to t_polling.pl. Exercises full
# Node->update() and Node->collect() lifecycle for an HTTP-only node, with
# Engine::HTTP::_fetch monkey-patched to return canned bodies (no real HTTP).
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
use File::Path qw(make_path remove_tree);

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Sys::Engine::HTTP;
use Compat::NMIS;

# ============================================================
# Setup
# ============================================================
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);
$C->{db_name} = "t_polling_http-" . time;
$C->{global_threshold} = 'true';
$C->{threshold_poll_node} = 'true';

my $tmp_rrd_dir = "/tmp/t_polling_http_rrd_$$";
make_path($tmp_rrd_dir);

my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = NMISNG->new(config => $C, log => $logger);

sub cleanup
{
	$nmisng->get_db()->drop();
	remove_tree($tmp_rrd_dir) if -d $tmp_rrd_dir;
}

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

# Stub RRDs::info — Node::compute_reachability reads the previous polltime
# from the health.rrd; with no real RRD this would die otherwise.
require RRDs unless defined &RRDs::info;
{
	no warnings 'redefine';
	*RRDs::info = sub { return {}; };
}

# Stub stats so threshold computations don't blow up
my %mock_stats;
{
	no warnings 'redefine';
	*Compat::NMIS::getSubconceptStats = sub {
		my %args = @_;
		my $key = $args{stats_section} // $args{subconcept};
		return exists $mock_stats{$key} ? { %{$mock_stats{$key}} } : {};
	};
}
$mock_stats{health}    = { reachability => 100, availability => 100 };
$mock_stats{AppQueues} = { depth => 5, processed => 100 };

# ============================================================
# HTTP fixture: monkey-patch _fetch to return canned bodies by URL.
# ============================================================
our %FIXTURE;
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

%FIXTURE = (
	'http://127.0.0.1:9100/metrics' => {
		body => <<'EOM',
# TYPE node_load1 gauge
node_load1 0.42
# TYPE node_load5 gauge
node_load5 0.30
# TYPE node_load15 gauge
node_load15 0.10
# TYPE node_memory_MemFree_bytes gauge
node_memory_MemFree_bytes 1234567890
EOM
		content_type => 'text/plain',
	},
	'http://127.0.0.1:9200/metrics' => {
		body => <<'EOM',
# TYPE app_queue_depth gauge
app_queue_depth{queue="orders"} 3
app_queue_depth{queue="payments"} 1
app_queue_depth{queue="email"} 7
# TYPE app_queue_processed_total counter
app_queue_processed_total{queue="orders"} 100
app_queue_processed_total{queue="payments"} 50
app_queue_processed_total{queue="email"} 200
EOM
		content_type => 'text/plain',
	},
	'http://127.0.0.1:9300/status' => {
		body => encode_json({ app => { state => 'running', uptime_seconds => 3600 } }),
		content_type => 'application/json',
	},
);

# ============================================================
# Phase 1: create node + run full update()
# ============================================================
diag("=== Phase 1: full update() lifecycle ===");

my $node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$node->cluster_id($C->{cluster_id});
$node->name("test_http_node");
$node->activated({ NMIS => 1 });
$node->configuration({
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
my ($op, $err) = $node->save();
ok(!$err, "HTTP node saved") or diag($err);

my $update_result = $node->update(force => 1);
ok($update_result->{success}, "Node->update() succeeded")
	or diag("update error: " . ($update_result->{error} // 'none'));

# Verify catchall has the http-sourced data after update
my ($cinv, $cierr) = $node->inventory(concept => "catchall");
ok(!$cierr && $cinv, "catchall inventory exists after update");
my $cd = $cinv->data;
is($cd->{nodeModel}, 'TestHTTP',  "catchall.nodeModel set after update");
is($cd->{load1},     '0.42',      "catchall.load1 (http_prom)");
is($cd->{memfree},   '1234567890',"catchall.memfree (http_prom)");
is($cd->{state},     'running',   "catchall.state (http_json)");
is($cd->{uptime},    3600,        "catchall.uptime (http_json)");
ok($cd->{last_update}, "last_update set after update");

# Verify systemHealth indexed inventory rows exist for each queue label
my $aq_ids = $node->get_inventory_ids(concept => 'AppQueues', filter => { historic => 0 });
ok(scalar @$aq_ids >= 3, "AppQueues has >= 3 indexed inventory rows after update")
	or diag("got " . scalar(@$aq_ids) . " rows");
my %seen_queues;
for my $id (@$aq_ids) {
	my ($inv, $ie) = $node->inventory(_id => $id);
	$seen_queues{ $inv->data->{index} } = 1 if !$ie && $inv;
}
ok($seen_queues{orders},   "AppQueues row: orders");
ok($seen_queues{payments}, "AppQueues row: payments");
ok($seen_queues{email},    "AppQueues row: email");

# ============================================================
# Phase 2: full collect() against same node
# ============================================================
diag("=== Phase 2: full collect() ===");

my $collect_result = $node->collect(force => 1);
ok($collect_result->{success}, "Node->collect() succeeded")
	or diag("collect error: " . ($collect_result->{error} // 'none'));

my ($cinv2, $cierr2) = $node->inventory(concept => "catchall");
ok(!$cierr2 && $cinv2, "catchall inventory exists after collect");
my $cd2 = $cinv2->data;
ok($cd2->{last_poll}, "last_poll set after collect");

# ============================================================
# Phase 3: regression — known_sources / polling-policy `http`
# ============================================================
diag("=== Phase 3: polling-policy http cadence ===");

# Default policy must include http (added in Sys::init) — exercise via a
# fresh Sys to confirm the lookup works without errors.
my $S = NMISNG::Sys->new(nmisng => $nmisng);
$S->init(node => $node, snmp => 0, wmi => 0, update => 0, catchall_inventory => $cinv2);
ok((grep { $_->protocol_name eq 'http' } @{$S->engines}), "HTTP engine present in collect-mode Sys");
ok((grep { $_ eq 'http' } @{$S->known_sources}), "'http' in known_sources");

# ============================================================
# Phase 4: HTTP cadence is gated on configured endpoints
# ============================================================
diag("=== Phase 4: HTTP cadence gating ===");

# Direct unit tests for the helper.
{
	is(NMISNG::_has_http_endpoints({ http_endpoints => [{ name => 'x' }] }), 1,
		"_has_http_endpoints: arrayref with entries -> true");
	is(NMISNG::_has_http_endpoints({ http_endpoints => [] }), 0,
		"_has_http_endpoints: empty arrayref -> false");
	is(NMISNG::_has_http_endpoints({ http_endpoints => '[{"name":"x"}]' }), 1,
		"_has_http_endpoints: non-empty JSON string -> true");
	is(NMISNG::_has_http_endpoints({ http_endpoints => '   ' }), 0,
		"_has_http_endpoints: whitespace-only string -> false");
	is(NMISNG::_has_http_endpoints({}), 0,
		"_has_http_endpoints: missing key -> false");
	is(NMISNG::_has_http_endpoints(undef), 0,
		"_has_http_endpoints: undef -> false");
}

# End-to-end: create a fresh SNMP-only node (no http_endpoints) alongside the
# existing HTTP node, drive find_due_nodes, and confirm only the HTTP node
# has flavours.http=1. This is the regression that was failing before:
# every legacy node was being scheduled for HTTP-cadence collects.
{
	my $snmp_only = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$snmp_only->cluster_id($C->{cluster_id});
	$snmp_only->name("test_snmp_only_node");
	$snmp_only->activated({ NMIS => 1 });
	$snmp_only->configuration({
		host      => "127.0.0.1",
		group     => "TestGroup",
		netType   => "default",
		roleType  => "default",
		threshold => 1,
		model     => "TestSnmp",
		collect   => "true",
		ping      => "false",
		community => "public",
		version   => "snmpv2c",
		# deliberately NO http_endpoints
	});
	my ($op2, $err2) = $snmp_only->save();
	ok(!$err2, "snmp-only node saved") or diag($err2);

	# find_due_nodes uses a hinted query — ensure the test DB has the indexes.
	$nmisng->ensure_indexes;

	my $due = $nmisng->find_due_nodes(type => 'collect', force => 1);
	ok($due->{success}, "find_due_nodes returned success")
		or diag("find_due_nodes error: " . ($due->{error} // 'unknown'));
	my $flavours = $due->{flavours} // {};
	diag("find_due_nodes full return: " . Dumper($due)) if $ENV{DEBUG};

	my $snmp_uuid = $snmp_only->uuid;
	# The HTTP node was just collected in Phase 2 so its cadence isn't due
	# yet; we can only assert about the brand-new SNMP-only node here. The
	# unit tests above already exercise _has_http_endpoints itself.
	ok(exists $flavours->{$snmp_uuid},
		"SNMP-only node appears in due list (no prior polls -> always due)");

	# THE FIX: flavours.http for an SNMP-only node must be falsy (0 or absent).
	# Before the fix, this would always be 1 because $nexthttp = 0+60 <= now.
	ok(!$flavours->{$snmp_uuid}{http},
		"SNMP-only node: flavours.http NOT enabled (no http_endpoints config)");
	is($flavours->{$snmp_uuid}{snmp}, 1,
		"SNMP-only node: flavours.snmp=1");
}

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
cleanup();
ok(1, "Cleanup complete");

done_testing();
