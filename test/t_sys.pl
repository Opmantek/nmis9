#!/usr/bin/perl
#
# t_sys.pl - Unit test for NMISNG::Sys functions (loadInfo, getData, getValues).
# Tests all model item properties: calculate, format, replace, control,
# skip_collect, calculate_index, nosave, HTML escaping, alerts, and more.
# Uses the same mock SNMP/WMI infrastructure as t_polling.pl.
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
use File::Slurp;

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
use Compat::NMIS;

use NMISNG::Snmp::Mock;
use NMISNG::WMI::Mock;

# ============================================================
# Setup
# ============================================================

my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);

$C->{db_name} = "t_sys-" . time;

my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

sub cleanup { $nmisng->get_db()->drop(); }

# Load walk data
my $snmp_walk_raw = decode_json(read_file("$FindBin::Bin/testdata/snmpwalk_test.json"));
my %snmp_walk;
for my $k (keys %$snmp_walk_raw) {
	$snmp_walk{$k} = $snmp_walk_raw->{$k} unless $k =~ /^_/;
}

my $wmi_data_raw = decode_json(read_file("$FindBin::Bin/testdata/wmi_test.json"));
my %wmi_data;
for my $k (keys %$wmi_data_raw) {
	$wmi_data{$k} = $wmi_data_raw->{$k} unless $k =~ /^_/;
}

# OID constants for referencing walk data
use constant {
	OID_sysDescr     => '1.3.6.1.2.1.1.1.0',
	OID_sysObjectID  => '1.3.6.1.2.1.1.2.0',
	OID_sysUpTime    => '1.3.6.1.2.1.1.3.0',
	OID_sysContact   => '1.3.6.1.2.1.1.4.0',
	OID_sysName      => '1.3.6.1.2.1.1.5.0',
	OID_sysLocation  => '1.3.6.1.2.1.1.6.0',
	OID_ifNumber     => '1.3.6.1.2.1.2.1.0',
	OID_ipInReceives => '1.3.6.1.2.1.4.3.0',
	OID_ipInDelivers => '1.3.6.1.2.1.4.9.0',
	OID_ipOutRequests => '1.3.6.1.2.1.4.10.0',
	OID_sensorVal1   => '1.3.6.1.4.1.99999.1.1.1.3.1',
	OID_sensorVal2   => '1.3.6.1.4.1.99999.1.1.1.3.2',
	OID_rawCounter    => '1.3.6.1.4.1.99999.2.1.0',
	OID_calcValue     => '1.3.6.1.4.1.99999.2.2.0',
	OID_fmtValue      => '1.3.6.1.4.1.99999.2.3.0',
	OID_replValue     => '1.3.6.1.4.1.99999.2.4.0',
	OID_replNoFallback => '1.3.6.1.4.1.99999.2.5.0',
	OID_nosaveValue   => '1.3.6.1.4.1.99999.2.6.0',
	OID_htmlValue     => '1.3.6.1.4.1.99999.2.7.0',
	OID_calcUndef     => '1.3.6.1.4.1.99999.2.8.0',
	OID_calcOidVal1   => '1.3.6.1.4.1.99999.3.1.1.0',
	OID_calcOidVal2   => '1.3.6.1.4.1.99999.3.1.2.0',
};

# Monkey-patch create_update_rrd to skip RRD I/O
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

# Create SNMP test node
my $snmp_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$snmp_node->cluster_id($C->{cluster_id});
$snmp_node->name("test_sys_snmp");
$snmp_node->configuration({
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
});
my ($op, $err) = $snmp_node->save();
ok(!$err, "SNMP test node saved") or diag("Error: $err");

# Create WMI test node
my $wmi_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$wmi_node->cluster_id($C->{cluster_id});
$wmi_node->name("test_sys_wmi");
$wmi_node->configuration({
	host        => "127.0.0.2",
	group       => "TestGroup",
	netType     => "default",
	roleType    => "default",
	threshold   => 1,
	model       => "TestWmi",
	collect     => "true",
	ping        => "false",
	wmiusername => "testuser",
	wmipassword => "testpass",
});
($op, $err) = $wmi_node->save();
ok(!$err, "WMI test node saved") or diag("Error: $err");

# Init SNMP Sys and run update_node_info to get model loaded
my ($snmp_catchall, $cerr) = $snmp_node->inventory(concept => "catchall", model_class => "system");
ok(!$cerr, "SNMP catchall created");

my $S = NMISNG::Sys->new(nmisng => $nmisng);
$S->init(node => $snmp_node, snmp => 1, wmi => 0, update => 'true', force => 1, catchall_inventory => $snmp_catchall);
$S->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $nmisng, name => "test_sys_snmp", walk_data => \%snmp_walk);
$S->open();
$snmp_node->update_node_info(sys => $S, catchall_inventory => $snmp_catchall);
# Also discover systemHealth indices for indexed tests
$snmp_node->collect_systemhealth_info(sys => $S, catchall_inventory => $snmp_catchall);
$snmp_catchall->save(node => $snmp_node);

# ============================================================
# Test 1: open / testsession / close
# ============================================================
diag("=== Test 1: Session lifecycle ===");

my $mock_snmp = $S->{snmp};
ok($mock_snmp->isopen, "isopen returns 1 after open");
is($mock_snmp->version, 'snmpv2c', "version returns snmpv2c");
is($mock_snmp->max_msg_size, 1472, "max_msg_size returns 1472");
ok($mock_snmp->testsession, "testsession returns 1 (sysObjectID.0 in walk data)");
ok(!$mock_snmp->error, "no error after successful operations");

$mock_snmp->close();
ok(!$mock_snmp->isopen, "isopen returns 0 after close");
is($mock_snmp->version, undef, "version returns undef when closed");

# Reopen for remaining tests
$mock_snmp->open(config => { oidpkt => 10 });
ok($mock_snmp->isopen, "session reopened");

# ============================================================
# Test 1b: disable_source
# ============================================================
diag("=== Test 1b: disable_source ===");

# Use a separate Sys object since disable_source destroys state
my $S_ds = NMISNG::Sys->new(nmisng => $nmisng);
$S_ds->init(node => $snmp_node, snmp => 1, wmi => 0, update => 0, catchall_inventory => $snmp_catchall);
$S_ds->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $nmisng, name => "test_disable", walk_data => \%snmp_walk);
$S_ds->open();

# Keep a reference to the mock before disable deletes it from Sys
my $ds_mock = $S_ds->{snmp};

# State BEFORE disable_source("snmp")
is($S_ds->status->{snmp_enabled}, 1, "before disable: snmp_enabled is 1");
ok(defined($S_ds->snmp), "before disable: snmp accessor returns object");
ok(defined($S_ds->engine("snmp")), "before disable: engine('snmp') returns object");
ok(scalar(@{$S_ds->engines}) >= 1, "before disable: engines list has entries");
ok($ds_mock->isopen, "before disable: SNMP session is open");

# Disable SNMP
$S_ds->disable_source("snmp");

# State AFTER disable_source("snmp")
is($S_ds->status->{snmp_enabled}, 0, "after disable: snmp_enabled is 0");
ok(!defined($S_ds->snmp), "after disable: snmp accessor returns undef");
ok(!defined($S_ds->engine("snmp")), "after disable: engine('snmp') returns undef");
my @snmp_engines = grep { $_->protocol_name eq "snmp" } @{$S_ds->engines};
is(scalar(@snmp_engines), 0, "after disable: no SNMP engine in engines list");
ok(!$ds_mock->isopen, "after disable: SNMP session was closed");

# disable_source("wmi") when WMI not configured — should be a no-op
my $engine_count_before = scalar(@{$S_ds->engines});
$S_ds->disable_source("wmi");
is(scalar(@{$S_ds->engines}), $engine_count_before, "disable_source('wmi') no-op when WMI not configured");

# disable_source("bogus") — unknown source, should be a no-op
$S_ds->disable_source("bogus");
ok(1, "disable_source('bogus') did not crash");

# ============================================================
# Test 1c: has_session
# ============================================================
diag("=== Test 1c: has_session ===");

# SNMP engine has a real session (returns 1)
my $S_hs = NMISNG::Sys->new(nmisng => $nmisng);
$S_hs->init(node => $snmp_node, snmp => 1, wmi => 0, update => 0, catchall_inventory => $snmp_catchall);
$S_hs->{snmp} = NMISNG::Snmp::Mock->new(nmisng => $nmisng, name => "test_has_session", walk_data => \%snmp_walk);

my $snmp_engine = $S_hs->engine("snmp");
ok($snmp_engine, "has_session: SNMP engine exists");
is($snmp_engine->has_session, 1, "has_session: SNMP engine returns 1 (has real session)");

# WMI engine does NOT have a session (returns 0)
# Instantiate directly since the test node is SNMP-only
use NMISNG::Sys::Engine::WMI;
my $wmi_engine = NMISNG::Sys::Engine::WMI->new(sys => $S_hs);
is($wmi_engine->has_session, 0, "has_session: WMI engine returns 0 (no real session)");

# Base Engine class also returns 0
use NMISNG::Sys::Engine;
my $base_engine = NMISNG::Sys::Engine->new(sys => $S_hs);
is($base_engine->has_session, 0, "has_session: base Engine returns 0");

# ============================================================
# Test 1d: disable_source validates against known_sources
# ============================================================
diag("=== Test 1d: disable_source property protection ===");

# Verify that disable_source rejects non-protocol strings
# even if they match existing Sys object properties
my $name_before = $S_hs->{name};
$S_hs->disable_source("name");
is($S_hs->{name}, $name_before, "disable_source('name') did not delete Sys->{name}");

my $mdl_before = $S_hs->{mdl};
$S_hs->disable_source("mdl");
is($S_hs->{mdl}, $mdl_before, "disable_source('mdl') did not delete Sys->{mdl}");

# ============================================================
# Test 2: copyModelCfgInfo
# ============================================================
diag("=== Test 2: copyModelCfgInfo ===");

$S->copyModelCfgInfo(type => 'all');
my $cd = $snmp_catchall->data_live();
is($cd->{nodeModel}, "TestSnmp", "copyModelCfgInfo preserved nodeModel");
# Verify node config fields were copied to catchall
is($cd->{host}, "127.0.0.1", "copyModelCfgInfo copied host from node config");
is($cd->{group}, "TestGroup", "copyModelCfgInfo copied group from node config");

# ============================================================
# Test 3: loadInfo (sys section, non-indexed)
# ============================================================
diag("=== Test 3: loadInfo ===");

my %sys_target;
my $li_ok = $S->loadInfo(class => 'system', target => \%sys_target, inventory => $snmp_catchall);
ok($li_ok, "loadInfo returned success");
is($sys_target{sysDescr}, $snmp_walk{OID_sysDescr()}, "loadInfo: sysDescr matches walk data");
is($sys_target{sysObjectID}, $snmp_walk{OID_sysObjectID()}, "loadInfo: sysObjectID matches walk data");
is($sys_target{sysName}, $snmp_walk{OID_sysName()}, "loadInfo: sysName matches walk data");
is($sys_target{sysLocation}, $snmp_walk{OID_sysLocation()}, "loadInfo: sysLocation matches walk data");
is($sys_target{sysContact}, $snmp_walk{OID_sysContact()}, "loadInfo: sysContact matches walk data");
is($sys_target{ifNumber}, $snmp_walk{OID_ifNumber()}, "loadInfo: ifNumber matches walk data");
ok($sys_target{sysUpTime}, "loadInfo: sysUpTime populated");

# ============================================================
# Test 4: getData (rrd section, non-indexed)
# ============================================================
diag("=== Test 4: getData ===");

$S->{alerts} = [];  # clear alerts from previous ops
my $rrd_data = $S->getData(class => 'system', inventory => $snmp_catchall);
ok(ref($rrd_data) eq "HASH", "getData returned hash");
ok(exists $rrd_data->{mib2ip}, "getData has mib2ip section");

my $ip = $rrd_data->{mib2ip};
ok(exists $ip->{ipInReceives}, "mib2ip has ipInReceives");
ok(exists $ip->{ipInDelivers}, "mib2ip has ipInDelivers");
ok(exists $ip->{ipOutRequests}, "mib2ip has ipOutRequests");
is($ip->{ipInReceives}{option}, 'counter,0:U', "ipInReceives option is counter,0:U");
is($ip->{ipInReceives}{title}, 'IP In Receives', "ipInReceives title correct");
is($ip->{ipInReceives}{value}, $snmp_walk{OID_ipInReceives()}, "ipInReceives value matches walk data");
is($ip->{ipInDelivers}{value}, $snmp_walk{OID_ipInDelivers()}, "ipInDelivers value matches walk data");
is($ip->{ipOutRequests}{value}, $snmp_walk{OID_ipOutRequests()}, "ipOutRequests value matches walk data");

# ============================================================
# Test 5: loadInfo vs getData — different model branches
# ============================================================
diag("=== Test 5: loadInfo vs getData ===");

# loadInfo returns sys items, NOT rrd items
ok(!exists $sys_target{ipInReceives}, "loadInfo did NOT return rrd item ipInReceives");
ok(!exists $sys_target{rawCounter}, "loadInfo did NOT return rrd item rawCounter");

# getData returns rrd items, NOT sys items
ok(!exists $rrd_data->{standard}, "getData did NOT return sys section 'standard'");

# ============================================================
# Test 6: calculate with $r and CVAR
# ============================================================
diag("=== Test 6: calculate ===");

ok(exists $rrd_data->{testProcessing}, "getData has testProcessing section");
my $tp = $rrd_data->{testProcessing};

# rawCounter: plain value
is($tp->{rawCounter}{value}, $snmp_walk{OID_rawCounter()}, "rawCounter value matches walk data");

# calcValue: calculate='CVAR1=rawCounter;return int($r / 10) + $CVAR1;'
# raw=555, rawCounter=1000, expected: int(555/10) + 1000 = 55 + 1000 = 1055
my $expected_calc = int($snmp_walk{OID_calcValue()} / 10) + $snmp_walk{OID_rawCounter()};
is($tp->{calcValue}{value}, $expected_calc, "calcValue: calculate with \$r and CVAR produced $expected_calc");

# ============================================================
# Test 7: format (sprintf)
# ============================================================
diag("=== Test 7: format ===");

my $expected_fmt = sprintf("%.2f", $snmp_walk{OID_fmtValue()});
is($tp->{fmtValue}{value}, $expected_fmt, "fmtValue: format %.2f produced $expected_fmt");

# ============================================================
# Test 8: replace — match found
# ============================================================
diag("=== Test 8: replace (match) ===");

my %repl_table = ('1' => 'Up', '2' => 'Down', 'unknown' => 'Other');
my $raw_repl = $snmp_walk{OID_replValue()};
my $expected_repl = $repl_table{$raw_repl} // $repl_table{unknown} // $raw_repl;
is($tp->{replValue}{value}, $expected_repl, "replValue: replace lookup for '$raw_repl' => '$expected_repl'");

# ============================================================
# Test 9: replace — no match, no fallback (value unchanged)
# ============================================================
diag("=== Test 9: replace (no fallback) ===");

my $raw_nofb = $snmp_walk{OID_replNoFallback()};
# 99 is not in replace table {1=>Up, 2=>Down}, no 'unknown' key → value unchanged
is($tp->{replNoFallback}{value}, $raw_nofb, "replNoFallback: value '$raw_nofb' unchanged (not in replace table)");

# ============================================================
# Test 10: nosave — alert suppressed
# ============================================================
diag("=== Test 10: nosave ===");

ok(exists $tp->{nosaveValue}, "nosaveValue present in data");
is($tp->{nosaveValue}{option}, 'nosave', "nosaveValue option is nosave");
# The alert '$r > 0' would fire since 42 > 0, but nosave should suppress it
my @nosave_alerts = grep { $_->{event} && $_->{event} eq 'Nosave Alert Should Not Fire' } @{$S->{alerts}};
is(scalar(@nosave_alerts), 0, "nosave suppressed alert (none in \$S->{alerts})");

# ============================================================
# Test 11: HTML escaping
# ============================================================
diag("=== Test 11: HTML escaping ===");

my $html_val = $tp->{htmlValue}{value};
ok(defined($html_val), "htmlValue is defined");
unlike($html_val, qr/<b>/, "htmlValue does NOT contain raw '<b>' tag");
like($html_val, qr/&lt;b&gt;/, "htmlValue contains escaped '&lt;b&gt;'");
like($html_val, qr/&amp;/, "htmlValue contains escaped '&amp;'");

# ============================================================
# Test 12: calculate returns undef — alert skipped
# ============================================================
diag("=== Test 12: calculate undef ===");

# calcUndef: calculate='return undef;', raw=123 but result is undef
ok(exists $tp->{calcUndef}, "calcUndef present in data");
ok(!defined($tp->{calcUndef}{value}), "calcUndef value is undef (calculate returned undef)");
my @undef_alerts = grep { $_->{event} && $_->{event} eq 'CalcUndef Alert Should Not Fire' } @{$S->{alerts}};
is(scalar(@undef_alerts), 0, "calculate-undef suppressed alert (none in \$S->{alerts})");

# ============================================================
# Test 13: control expression — section skipped
# ============================================================
diag("=== Test 13: control ===");

# testSkipped has control='$nodeModel eq "NeverMatch"' — nodeModel is TestSnmp
ok(!exists $rrd_data->{testSkipped}, "testSkipped section not in getData (control expression false)");

# ============================================================
# Test 14: skip_collect — section skipped
# ============================================================
diag("=== Test 14: skip_collect ===");

ok(!exists $rrd_data->{testSkipCollect}, "testSkipCollect section not in getData (skip_collect=true)");

# ============================================================
# Test 14b: indexed control — inventory created for ALL rows,
# but per-row collection is gated by the control expression.
# This is the contract the HTTP engine relies on after we move
# off `label_filter` (which dropped rows pre-inventory).
# ============================================================
diag("=== Test 14b: indexed control ===");

# testFiltered walks the same indices as testSensor (TempSensor1 / TempSensor2)
# but its rrd block has control='CVAR=testFilteredName;$CVAR eq "TempSensor1"'.
# After collect_systemhealth_info ran during setup, both rows must be in
# inventory; only index 1 should produce fresh data via getData.
my $tf_all = $snmp_node->get_inventory_model(
	concept => 'testFiltered', filter => { historic => 0 });
is($tf_all->count, 2,
	"testFiltered: inventory created for BOTH rows despite control expression");

my %tf_by_index;
for my $inv (@{$tf_all->objects->{objects} || []}) {
	$tf_by_index{$inv->data->{index}} = $inv;
}
ok($tf_by_index{1}, "testFiltered: index 1 (TempSensor1) has inventory");
ok($tf_by_index{2}, "testFiltered: index 2 (TempSensor2) has inventory");

# Index 1 matches the control — getData returns the section with data.
my $tf_data1 = $S->getData(class => 'systemHealth', section => 'testFiltered',
	index => '1', inventory => $tf_by_index{1});
ok(ref($tf_data1) eq "HASH", "testFiltered index 1: getData returned hash");
ok(exists $tf_data1->{testFiltered},
	"testFiltered index 1: section present in getData (control matched)");

# Index 2 fails the control — getData should NOT include the section's data.
my $tf_data2 = $S->getData(class => 'systemHealth', section => 'testFiltered',
	index => '2', inventory => $tf_by_index{2});
ok(!exists $tf_data2->{testFiltered}{'2'}{filteredValue}
	|| !defined $tf_data2->{testFiltered}{'2'}{filteredValue}{value},
	"testFiltered index 2: no fresh per-DS data (control suppressed collection)");

# ============================================================
# Test 15: indexed getData (systemHealth testSensor)
# ============================================================
diag("=== Test 15: indexed getData ===");

$S->{alerts} = [];
# Get all testSensor inventories
my $ts_all = $snmp_node->get_inventory_model(concept => 'testSensor', filter => { historic => 0 });
my %ts_by_index;
my $ts_objs = $ts_all->objects;
for my $inv (@{$ts_objs->{objects} || []}) {
	$ts_by_index{$inv->data->{index}} = $inv;
}

my $sh_data1 = $S->getData(class => 'systemHealth', section => 'testSensor', index => '1',
	inventory => $ts_by_index{1});
ok(ref($sh_data1) eq "HASH", "indexed getData returned hash for index 1");
ok(exists $sh_data1->{testSensor}, "testSensor section in indexed getData");
is($sh_data1->{testSensor}{'1'}{testSensorValue}{value}, $snmp_walk{OID_sensorVal1()},
	"testSensorValue index 1 matches walk data");

my $sh_data2 = $S->getData(class => 'systemHealth', section => 'testSensor', index => '2',
	inventory => $ts_by_index{2});
is($sh_data2->{testSensor}{'2'}{testSensorValue}{value}, $snmp_walk{OID_sensorVal2()},
	"testSensorValue index 2 matches walk data");

# ============================================================
# Test 16: calculate_index
# ============================================================
diag("=== Test 16: calculate_index ===");

# testCalcOid: calculate_index='CVAR1=index;return "$CVAR1.0";'
# For index=1: suffix becomes ".1.0", full OID = 1.3.6.1.4.1.99999.3.1.1.0
# Get all testCalcOid inventories, match by index value
my $co_all = $snmp_node->get_inventory_model(concept => 'testCalcOid', filter => { historic => 0 });
is($co_all->count, 2, "testCalcOid has 2 inventory items");

my %co_by_index;
my $co_objs = $co_all->objects;
for my $inv (@{$co_objs->{objects} || []}) {
	$co_by_index{$inv->data->{index}} = $inv;
}

for my $idx (1, 2) {
	my $inv = $co_by_index{$idx};
	if ($inv) {
		my $co_data = $S->getData(class => 'systemHealth', section => 'testCalcOid', index => "$idx", inventory => $inv);
		my $expected_oid = $idx == 1 ? OID_calcOidVal1() : OID_calcOidVal2();
		if ($co_data->{testCalcOid} && $co_data->{testCalcOid}{$idx}) {
			is($co_data->{testCalcOid}{$idx}{calcOidValue}{value}, $snmp_walk{$expected_oid},
				"calculate_index: index $idx value matches walk data (OID suffix .$idx.0)");
		} else {
			ok(0, "calculate_index: index $idx value matches walk data");
		}
	} else {
		ok(0, "calculate_index: index $idx value matches walk data");
	}
}

# ============================================================
# Test 17: inline alert evaluation
# ============================================================
diag("=== Test 17: inline alert ===");

# Alerts from the indexed getData calls above (testSensorValue alert: '$r > 90')
my @sensor_alerts = grep { $_->{event} && $_->{event} eq 'High Sensor Value' } @{$S->{alerts}};
ok(scalar(@sensor_alerts) >= 2, "Two sensor alert records generated");

my @fired = grep { $_->{test_result} } @sensor_alerts;
my @normal = grep { !$_->{test_result} } @sensor_alerts;
is(scalar(@fired), 1, "One alert fired (index 1, value > 90)");
is(scalar(@normal), 1, "One alert normal (index 2, value <= 90)");

if (@fired) {
	is($fired[0]->{event}, 'High Sensor Value', "Alert event correct");
	is($fired[0]->{level}, 'Warning', "Alert level correct");
	ok(defined($fired[0]->{value}), "Alert has value");
	is($fired[0]->{section}, 'testSensor', "Alert section correct");
	# inventory_id may be set if inventory was passed and saved (has a DB id)
	ok(1, "Alert record has expected fields (inventory_id=" . ($fired[0]->{inventory_id} // 'undef') . ")");
}

# ============================================================
# Test 18: WMI loadInfo (non-indexed)
# ============================================================
diag("=== Test 18: WMI loadInfo ===");

my ($wmi_catchall, $wcerr) = $wmi_node->inventory(concept => "catchall", model_class => "system");
ok(!$wcerr, "WMI catchall created");

my $SW = NMISNG::Sys->new(nmisng => $nmisng);
$SW->init(node => $wmi_node, snmp => 0, wmi => 1, update => 'true', force => 1, catchall_inventory => $wmi_catchall);
$SW->{wmi} = NMISNG::WMI::Mock->new(wmi_data => \%wmi_data, host => '127.0.0.2', username => 'testuser');

my %wmi_target;
my $wli_ok = $SW->loadInfo(class => 'system', target => \%wmi_target, inventory => $wmi_catchall);
ok($wli_ok, "WMI loadInfo returned success");

# Values come from WMI mock data
my $expected_caption = $wmi_data{"select Caption from Win32_OperatingSystem"}[0]{Caption};
my $expected_version = $wmi_data{"select Version from Win32_OperatingSystem"}[0]{Version};
my $expected_build = $wmi_data{"select BuildNumber from Win32_OperatingSystem"}[0]{BuildNumber};
my $expected_csname = $wmi_data{"select CSName from Win32_OperatingSystem"}[0]{CSName};

is($wmi_target{winosname}, $expected_caption, "WMI loadInfo: winosname matches mock data");
is($wmi_target{winversion}, $expected_version, "WMI loadInfo: winversion matches mock data");
is($wmi_target{winbuild}, $expected_build, "WMI loadInfo: winbuild matches mock data");
is($wmi_target{winsysname}, $expected_csname, "WMI loadInfo: winsysname matches mock data");

# ============================================================
# Test 19: WMI getData (non-indexed rrd)
# ============================================================
diag("=== Test 19: WMI getData ===");

my $wmi_rrd = $SW->getData(class => 'system', inventory => $wmi_catchall);
ok(ref($wmi_rrd) eq "HASH", "WMI getData returned hash");
ok(exists $wmi_rrd->{wmiCpu}, "WMI getData has wmiCpu section");

my $expected_cpu = $wmi_data{"select PercentProcessorTime from Win32_PerfFormattedData_PerfOS_Processor where Name='_Total'"}[0]{PercentProcessorTime};
is($wmi_rrd->{wmiCpu}{percentProcessor}{value}, $expected_cpu, "WMI percentProcessor matches mock data");

# ============================================================
# Test 20: WMI indexed getData
# ============================================================
diag("=== Test 20: WMI indexed getData ===");

# First discover disk indices
$wmi_node->update_node_info(sys => $SW, catchall_inventory => $wmi_catchall);
$wmi_node->collect_systemhealth_info(sys => $SW, catchall_inventory => $wmi_catchall);
$wmi_catchall->save(node => $wmi_node);

my $disk_inv_c = $wmi_node->get_inventory_model(concept => 'wmiDisk', filter => { 'data.index' => 'C:', historic => 0 })->objects->{objects}[0];
if ($disk_inv_c) {
	my $wmi_disk_data = $SW->getData(class => 'systemHealth', section => 'wmiDisk', index => 'C:', inventory => $disk_inv_c);
	ok(ref($wmi_disk_data) eq "HASH", "WMI indexed getData returned hash");
	my $expected_free = $wmi_data{"select Name,Size,FreeSpace from Win32_LogicalDisk where DriveType=3"}[0]{FreeSpace};
	if ($wmi_disk_data->{wmiDisk} && $wmi_disk_data->{wmiDisk}{'C:'}) {
		is($wmi_disk_data->{wmiDisk}{'C:'}{wmiDiskFreeSpace}{value}, $expected_free,
			"WMI wmiDiskFreeSpace for C: matches mock data");
	} else {
		ok(0, "WMI wmiDiskFreeSpace for C: matches mock data");
	}
} else {
	ok(0, "wmiDisk inventory for C: exists");
	ok(0, "WMI wmiDiskFreeSpace for C: matches mock data");
}

# ============================================================
# Test 21: WMI execute_queries handles missing index gracefully
# ============================================================
diag("=== Test 21: WMI execute_queries missing index ===");

# Create a WMI Sys with mock data, then call getData with a non-existent index.
# Before the fix, this would crash with "Can't use an undefined value as a HASH reference".
my $SW_bad = NMISNG::Sys->new(nmisng => $nmisng);
$SW_bad->init(node => $wmi_node, snmp => 0, wmi => 1, update => 0, catchall_inventory => $wmi_catchall);
$SW_bad->{wmi} = NMISNG::WMI::Mock->new(wmi_data => \%wmi_data, host => '127.0.0.2', username => 'testuser');

# Request data for an index that doesn't exist in the WMI result set
my $bad_result = $SW_bad->getData(class => 'systemHealth', section => 'wmiDisk', index => 'Z:');
my $bad_status = $SW_bad->status;
# Should not crash — getData returns empty/error, not a die
ok(1, "WMI getData with missing index did not crash");
# The status should have an error or the result should be empty for that index
ok(!$bad_result->{wmiDisk}{'Z:'} || !defined($bad_result->{wmiDisk}{'Z:'}{wmiDiskFreeSpace}{value}),
	"WMI getData with missing index returned no data for Z:");

# ============================================================
# Test 22: WMI discover_indexes rejects bad metadata
# ============================================================
diag("=== Test 22: WMI discover_indexes bad metadata ===");

# Create mock data where the index field doesn't exist in the rows,
# causing gettable to return meta->{index} = undef
my %bad_wmi_data = (
	"select BadField from FakeTable" => [
		{ "SomeOtherField" => "value1" },
		{ "SomeOtherField" => "value2" },
	]
);
my $bad_wmi_mock = NMISNG::WMI::Mock->new(wmi_data => \%bad_wmi_data, host => '127.0.0.2', username => 'test');

# Build a minimal Sys with the bad mock
my $SW_meta = NMISNG::Sys->new(nmisng => $nmisng);
$SW_meta->init(node => $wmi_node, snmp => 0, wmi => 1, update => 'true', force => 1, catchall_inventory => $wmi_catchall);
$SW_meta->{wmi} = $bad_wmi_mock;

# Call discover_indexes with a section config where the index field doesn't exist
use NMISNG::Sys::Engine::WMI;
my $wmi_eng = NMISNG::Sys::Engine::WMI->new(sys => $SW_meta);
my ($disc_err, $disc_indices, $disc_targets) = $wmi_eng->discover_indexes(
	section_config => {
		'wmi' => {
			'BadField' => {
				'query' => 'select BadField from FakeTable',
				'field' => 'BadField',
			}
		}
	},
	index_var => 'BadField',
);

ok($disc_err, "discover_indexes returned error when index field missing from data");
like($disc_err, qr/failed|missing/i, "discover_indexes error mentions failure: $disc_err");
ok(!defined($disc_indices), "discover_indexes returned no indices on failure");

# ============================================================
# Test 23: SNMP discover_indexes sort stability
# ============================================================
# Regression guard for commit 03778b70 ("fix index sorting regression from
# refactor"). Engine::SNMP::discover_indexes iterates OIDs via
# Net::SNMP::oid_lex_sort and then returns `sort keys %targets`, i.e.
# lexicographic sort of the extracted index values.
#
# This test locks in two properties:
#   1. The returned order is deterministic across repeated calls.
#   2. The current order is lex-sort of index strings ("1","10","2","5","7").
# If the policy ever changes to numeric sort, the second assertion will fail
# intentionally so the author has to confirm the change was deliberate.
diag("=== Test 23: SNMP discover_indexes sort stability ===");

# Extend walk data under testSensor's index OID (1.3.6.1.4.1.99999.1.1.1.2)
# with out-of-order indexes. Existing entries: .1, .2. Adding .5, .7, .10 so
# numeric vs lex sort would give different answers.
my %extra_oids = (
	'1.3.6.1.4.1.99999.1.1.1.2.5'  => "TempSensor5",
	'1.3.6.1.4.1.99999.1.1.1.2.7'  => "TempSensor7",
	'1.3.6.1.4.1.99999.1.1.1.2.10' => "TempSensor10",
);
$snmp_walk{$_} = $extra_oids{$_} for keys %extra_oids;

my $snmp_eng = $S->engine("snmp");
ok($snmp_eng, "SNMP engine available for discover_indexes test");

my ($err1, $idx1, $targets1) = $snmp_eng->discover_indexes(
	section_config => {},
	index_var      => 'testSensorName',
	index_snmp     => '1.3.6.1.4.1.99999.1.1.1.2',
	index_regex    => '1\.3\.6\.1\.4\.1\.99999\.1\.1\.1\.2\.(\d+)',
);
ok(!$err1, "SNMP discover_indexes succeeded");
is_deeply([sort { $a <=> $b } @$idx1], [qw(1 2 5 7 10)],
	"SNMP discover_indexes returned all 5 expected indexes");
is_deeply($idx1, [qw(1 10 2 5 7)],
	"SNMP discover_indexes: current policy is lex sort (1,10,2,5,7)");

# Two successive calls must produce identical order.
my ($err2, $idx2, $targets2) = $snmp_eng->discover_indexes(
	section_config => {},
	index_var      => 'testSensorName',
	index_snmp     => '1.3.6.1.4.1.99999.1.1.1.2',
	index_regex    => '1\.3\.6\.1\.4\.1\.99999\.1\.1\.1\.2\.(\d+)',
);
is_deeply($idx2, $idx1, "SNMP discover_indexes order is stable across repeated calls");

# %targets keys should cover the same set as @active_indices.
is_deeply([sort keys %$targets1], [qw(1 10 2 5 7)],
	"SNMP discover_indexes: targets hash keys match returned indexes");

# Restore walk data so later tests (if any) see the original.
delete $snmp_walk{$_} for keys %extra_oids;

# ============================================================
# Test 24: WMI discover_indexes sort stability
# ============================================================
# Mirror of test 23 for WMI. Engine::WMI::discover_indexes returns
# `keys %$fields` without an explicit sort — order depends on Perl hash
# iteration. This test asserts that the order is at least deterministic
# across repeated calls within a process (so inventory save order is stable).
# If hash iteration order differs between calls, this fails and surfaces a
# real asymmetry vs the SNMP engine.
diag("=== Test 24: WMI discover_indexes sort stability ===");

# Out-of-order disk names: Z:, A:, M:, B:
my %sort_wmi_data = (
	"select Name from Win32_LogicalDisk where DriveType=3" => [
		{ Name => "Z:" },
		{ Name => "A:" },
		{ Name => "M:" },
		{ Name => "B:" },
	],
);
my $sort_wmi_mock = NMISNG::WMI::Mock->new(
	wmi_data => \%sort_wmi_data, host => '127.0.0.2', username => 'test'
);

my $SW_sort = NMISNG::Sys->new(nmisng => $nmisng);
$SW_sort->init(node => $wmi_node, snmp => 0, wmi => 1, update => 'true',
	force => 1, catchall_inventory => $wmi_catchall);
$SW_sort->{wmi} = $sort_wmi_mock;

my $wmi_sort_eng = $SW_sort->engine("wmi");
ok($wmi_sort_eng, "WMI engine available for discover_indexes test");

my $sort_section_cfg = {
	'wmi' => {
		'Name' => {
			'query' => 'select Name from Win32_LogicalDisk where DriveType=3',
			'field' => 'Name',
		},
	},
};

my ($werr1, $widx1, $wtargets1) = $wmi_sort_eng->discover_indexes(
	section_config => $sort_section_cfg,
	index_var      => 'Name',
);
ok(!$werr1, "WMI discover_indexes succeeded") or diag("error: $werr1");
is_deeply([sort @$widx1], [qw(A: B: M: Z:)],
	"WMI discover_indexes returned all 4 expected indexes");

# Determinism across calls.
my ($werr2, $widx2, $wtargets2) = $wmi_sort_eng->discover_indexes(
	section_config => $sort_section_cfg,
	index_var      => 'Name',
);
is_deeply($widx2, $widx1,
	"WMI discover_indexes order is stable across repeated calls");

# %targets keys should cover the same set as @active_indices.
is_deeply([sort keys %$wtargets1], [qw(A: B: M: Z:)],
	"WMI discover_indexes: targets hash keys match returned indexes");

# ============================================================
# class-level source section keys: must reflect the engines' real model
# block keys (http models use http_prom/http_json, NOT 'http'), usable
# without instantiated engines (the GUI calls this on the class).
{
	my %sk = map { $_ => 1 } @{ NMISNG::Sys->known_source_section_keys };
	ok($sk{$_}, "known_source_section_keys includes $_")
		for (qw(snmp wmi http_prom http_json redis));
	ok(!$sk{http},
		"known_source_section_keys does not contain the bogus plain 'http' key");
}

# ============================================================
# Cleanup
# ============================================================
diag("=== Cleanup ===");
$S->close();
$SW->close() if $SW;
cleanup();
ok(1, "Cleanup complete");

done_testing();
