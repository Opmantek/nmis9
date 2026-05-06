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

# Per-source enabled flags are derived in Node::_defaults at save time
# from settings presence, then read directly by find_due_nodes and
# Sys::init. The flags can be overridden explicitly (future GUI toggle).
{
	my $flag_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
	$flag_node->cluster_id($C->{cluster_id});
	$flag_node->name("test_flag_node");
	$flag_node->activated({ NMIS => 1 });

	# Base config: all three source kinds present.
	my %base = (host => "127.0.0.1", group => "G", netType => "default",
		roleType => "default", model => "TestHTTP", collect => "true", ping => "false");

	# 1. SNMP credentials present -> snmp_enabled defaults to 1.
	$flag_node->configuration({ %base, community => "public", version => "snmpv2c" });
	is($flag_node->configuration->{snmp_enabled}, 1,
		"snmp_enabled: derived to 1 when community is set");

	# 2. SNMP credentials absent -> snmp_enabled defaults to 0.
	$flag_node->configuration({ %base });
	is($flag_node->configuration->{snmp_enabled}, 0,
		"snmp_enabled: derived to 0 when no community/username");

	# 3. WMI username -> wmi_enabled=1
	$flag_node->configuration({ %base, wmiusername => "admin" });
	is($flag_node->configuration->{wmi_enabled}, 1,
		"wmi_enabled: derived to 1 when wmiusername is set");

	# 4. No WMI username -> wmi_enabled=0
	$flag_node->configuration({ %base });
	is($flag_node->configuration->{wmi_enabled}, 0,
		"wmi_enabled: derived to 0 when wmiusername absent");

	# 5. http_endpoints arrayref with entries -> http_enabled=1
	$flag_node->configuration({ %base, http_endpoints => [{ name => 'a', port => 9100 }] });
	is($flag_node->configuration->{http_enabled}, 1,
		"http_enabled: derived to 1 from arrayref with entries");

	# 6. http_endpoints JSON string with entries -> http_enabled=1
	$flag_node->configuration({ %base, http_endpoints => '[{"name":"a","port":9100}]' });
	is($flag_node->configuration->{http_enabled}, 1,
		"http_enabled: derived to 1 from JSON string with entries");

	# 7. Empty JSON array -> http_enabled=0 (the empty-JSON regression)
	$flag_node->configuration({ %base, http_endpoints => '[]' });
	is($flag_node->configuration->{http_enabled}, 0,
		"http_enabled: derived to 0 from empty JSON array");

	# 8. Empty arrayref -> http_enabled=0
	$flag_node->configuration({ %base, http_endpoints => [] });
	is($flag_node->configuration->{http_enabled}, 0,
		"http_enabled: derived to 0 from empty arrayref");

	# 9. Invalid JSON -> http_enabled=0
	$flag_node->configuration({ %base, http_endpoints => 'not json' });
	is($flag_node->configuration->{http_enabled}, 0,
		"http_enabled: derived to 0 from invalid JSON");

	# 10. No http_endpoints at all -> http_enabled=0
	$flag_node->configuration({ %base });
	is($flag_node->configuration->{http_enabled}, 0,
		"http_enabled: derived to 0 when http_endpoints absent");

	# 11. Adding a community to a previously-no-community node flips
	#     snmp_enabled from 0 -> 1. This is the regression case the user
	#     asked about: with //= semantics the stored 0 would have stuck.
	$flag_node->configuration({ %base });
	is($flag_node->configuration->{snmp_enabled}, 0,
		"snmp_enabled: starts at 0 with no community");
	$flag_node->configuration({ %base, community => "public", version => "snmpv2c" });
	is($flag_node->configuration->{snmp_enabled}, 1,
		"snmp_enabled: flips to 1 when community is added on next save");

	# 12. Removing a community flips snmp_enabled back to 0.
	$flag_node->configuration({ %base });
	is($flag_node->configuration->{snmp_enabled}, 0,
		"snmp_enabled: flips back to 0 when community is removed");

	# 13. Same for http_enabled: add endpoints -> 1, remove -> 0.
	$flag_node->configuration({ %base });
	is($flag_node->configuration->{http_enabled}, 0,
		"http_enabled: starts at 0 with no endpoints");
	$flag_node->configuration({ %base, http_endpoints => [{ name => 'a' }] });
	is($flag_node->configuration->{http_enabled}, 1,
		"http_enabled: flips to 1 when endpoints are added");
	$flag_node->configuration({ %base });
	is($flag_node->configuration->{http_enabled}, 0,
		"http_enabled: flips back to 0 when endpoints are removed");

	# 14. Invalid http_endpoints submitted via setter -> validate() must
	#     report the error so save() returns failure (and the GUI shows
	#     it via the standard td.error path in tables.pl). Without this,
	#     a user typing bad JSON would see "save successful" and then
	#     find their input had been silently discarded.
	$flag_node->configuration({ %base, http_endpoints => 'definitely not json' });
	my ($v_ok, $v_err) = $flag_node->validate();
	cmp_ok($v_ok, '<=', 0,
		"validate: returns failure when http_endpoints is invalid JSON");
	like($v_err, qr/http_endpoints.*invalid/i,
		"validate: error message names http_endpoints");
	like($v_err, qr/JSON-decode/i,
		"validate: error message mentions the decode failure");

	# 15. After supplying a valid value, the stashed error is cleared and
	#     validate passes. This proves the next setter call is treated as
	#     a fresh attempt, not as still-broken state from the previous one.
	$flag_node->configuration({ %base, http_endpoints => [{ name => 'a' }] });
	($v_ok, $v_err) = $flag_node->validate();
	cmp_ok($v_ok, '>', 0,
		"validate: passes after the bad value is replaced with a good one");

	# 16. JSON object (not array) is also rejected.
	$flag_node->configuration({ %base, http_endpoints => '{"name":"x"}' });
	($v_ok, $v_err) = $flag_node->validate();
	cmp_ok($v_ok, '<=', 0,
		"validate: rejects http_endpoints that decodes to a non-array");
	like($v_err, qr/JSON array/i,
		"validate: error message says 'JSON array'");
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
# Phase 5: Fix 1 — HTTP-only collects must not re-arm SNMP/WMI cadence
# ============================================================
diag("=== Phase 5: HTTP-only collect doesn't stamp SNMP/WMI attempts ===");
{
	my ($pre_inv, $pre_err) = $node->inventory(concept => "catchall");
	my $pre = $pre_inv->data;
	# Plant fake older attempt timestamps for SNMP and WMI.
	my $stale_time = time() - 999;
	$pre->{last_poll_snmp_attempt} = $stale_time;
	$pre->{last_poll_wmi_attempt}  = $stale_time;
	$pre_inv->data($pre);
	$pre_inv->save(node => $node);

	# Drive an HTTP-only collect (the case find_due_nodes produces when
	# only the HTTP cadence is due). Before the fix, defined($wantsnmp=0)
	# would still stamp last_poll_snmp_attempt to "now".
	$node->collect(wantsnmp => 0, wantwmi => 0, wanthttp => 1, force => 1);

	my ($post_inv, $post_err) = $node->inventory(concept => "catchall");
	my $post = $post_inv->data;
	is($post->{last_poll_snmp_attempt}, $stale_time,
		"HTTP-only collect: last_poll_snmp_attempt unchanged (truthy gate)");
	is($post->{last_poll_wmi_attempt}, $stale_time,
		"HTTP-only collect: last_poll_wmi_attempt unchanged (truthy gate)");
	ok($post->{last_poll_http_attempt} > $stale_time,
		"HTTP-only collect: last_poll_http_attempt did advance");
}

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
cleanup();
ok(1, "Cleanup complete");

done_testing();
