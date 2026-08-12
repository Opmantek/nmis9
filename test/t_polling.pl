#!/usr/bin/perl
#
# t_polling.pl - Test the NMIS9 polling pipeline with mock SNMP/WMI data.
# Creates a temporary MongoDB database, exercises update and collect sub-functions
# using mock objects, and validates inventory, alerts, thresholds, and stats.
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
use File::Path qw(make_path remove_tree);
use Clone qw(clone);

use NMISNG;
use NMISNG::Node;
use NMISNG::Sys;
use NMISNG::Log;
use NMISNG::Util;
use NMISNG::Status;
use NMISNG::Inventory;
use Compat::NMIS;
use Compat::Timing;

use NMISNG::Snmp::Mock;
use NMISNG::WMI::Mock;
use NMISNG::rrdfunc;
use RRDs;

# ============================================================
# Phase 1: Setup
# ============================================================
my $C = NMISNG::Util::loadConfTable();
die "Cannot load config" if (!$C);

# Test-specific database
$C->{db_name} = "t_polling-" . time;

# Temp RRD directory
my $tmp_rrd_dir = "/tmp/t_polling_rrd_$$";
make_path($tmp_rrd_dir);
my $orig_db_root = $C->{database_root};

# Enable thresholds
$C->{global_threshold} = 'true';
$C->{threshold_poll_node} = 'true';

my $logger = NMISNG::Log->new(level => 'info');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

sub cleanup
{
	$nmisng->get_db()->drop();
	remove_tree($tmp_rrd_dir) if -d $tmp_rrd_dir;
}

# Load walk data
my $snmp_walk_json = read_file("$FindBin::Bin/testdata/snmpwalk_test.json");
my $snmp_walk_raw = decode_json($snmp_walk_json);
# Strip comment keys
my %snmp_walk;
for my $k (keys %$snmp_walk_raw) {
	$snmp_walk{$k} = $snmp_walk_raw->{$k} unless $k =~ /^_/;
}

my $wmi_data_json = read_file("$FindBin::Bin/testdata/wmi_test.json");
my $wmi_data_raw = decode_json($wmi_data_json);
my %wmi_data;
for my $k (keys %$wmi_data_raw) {
	$wmi_data{$k} = $wmi_data_raw->{$k} unless $k =~ /^_/;
}

# Monkey-patch create_update_rrd to skip actual RRD I/O but record storage
{
	no warnings 'redefine';
	my $orig_create_update_rrd = \&NMISNG::Sys::create_update_rrd;
	*NMISNG::Sys::create_update_rrd = sub {
		my ($self, %args) = @_;
		if (ref($args{inventory}))
		{
			my $type = $args{type} || 'unknown';
			my $db_path = "/nodes/$self->{name}/mock-$type.rrd";
			$args{inventory}->set_subconcept_type_storage(
				subconcept => $type, type => 'rrd',
				data => $db_path
			);
		}
		return 1;
	};
}

# Monkey-patch getSubconceptStats to return deterministic values
my %mock_stats;
{
	no warnings 'redefine';
	*Compat::NMIS::getSubconceptStats = sub {
		my %args = @_;
		my $subconcept = $args{subconcept};
		my $stats_section = $args{stats_section} // $subconcept;
		if (exists $mock_stats{$stats_section})
		{
			return clone($mock_stats{$stats_section});
		}
		return {};
	};
}

# OID constants for readability when referencing walk data
use constant {
	OID_sysDescr     => '1.3.6.1.2.1.1.1.0',
	OID_sysObjectID  => '1.3.6.1.2.1.1.2.0',
	OID_sysUpTime    => '1.3.6.1.2.1.1.3.0',
	OID_sysContact   => '1.3.6.1.2.1.1.4.0',
	OID_sysName      => '1.3.6.1.2.1.1.5.0',
	OID_sysLocation  => '1.3.6.1.2.1.1.6.0',
	OID_ifNumber     => '1.3.6.1.2.1.2.1.0',
	OID_sensorName1  => '1.3.6.1.4.1.99999.1.1.1.2.1',
	OID_sensorName2  => '1.3.6.1.4.1.99999.1.1.1.2.2',
	OID_sensorVal1   => '1.3.6.1.4.1.99999.1.1.1.3.1',
	OID_sensorVal2   => '1.3.6.1.4.1.99999.1.1.1.3.2',
	OID_sensorStat1  => '1.3.6.1.4.1.99999.1.1.1.4.1',
	OID_sensorStat2  => '1.3.6.1.4.1.99999.1.1.1.4.2',
	OID_sensorName3  => '1.3.6.1.4.1.99999.1.1.1.2.3',
	OID_sensorStat3  => '1.3.6.1.4.1.99999.1.1.1.4.3',
	OID_sensorVal3   => '1.3.6.1.4.1.99999.1.1.1.3.3',
};

# Default mock stats
$mock_stats{health} = {
	reachability => 100,
	availability => 100,
};
$mock_stats{testSensor} = {
	testSensorUtil => 50,
};
$mock_stats{wmiDisk} = {
	wmiDiskUtil => 50,
};

# ============================================================
# Helper: create and init a Sys object with mock SNMP injected
# ============================================================
sub setup_snmp_sys
{
	my (%args) = @_;
	my $node = $args{node};
	my $update = $args{update} || 0;
	my $catchall_inv = $args{catchall_inventory};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	my $init_ok = $S->init(
		node => $node,
		snmp => 1,
		wmi  => 0,
		update => ($update ? 'true' : 0),
		force  => ($update ? 1 : 0),
		catchall_inventory => $catchall_inv,
	);

	# Inject mock SNMP
	my $mock_snmp = NMISNG::Snmp::Mock->new(
		nmisng    => $nmisng,
		name      => $node->name,
		walk_data => \%snmp_walk,
	);
	$S->{snmp} = $mock_snmp;

	return $S;
}

# ============================================================
# Helper: create and init a Sys object with mock WMI injected
# ============================================================
sub setup_wmi_sys
{
	my (%args) = @_;
	my $node = $args{node};
	my $update = $args{update} || 0;
	my $catchall_inv = $args{catchall_inventory};

	my $S = NMISNG::Sys->new(nmisng => $nmisng);
	my $init_ok = $S->init(
		node => $node,
		snmp => 0,
		wmi  => 1,
		update => ($update ? 'true' : 0),
		force  => ($update ? 1 : 0),
		catchall_inventory => $catchall_inv,
	);

	# Inject mock WMI
	my $mock_wmi = NMISNG::WMI::Mock->new(
		wmi_data => \%wmi_data,
		host     => '127.0.0.2',
		username => 'testuser',
	);
	$S->{wmi} = $mock_wmi;

	return $S;
}

# ============================================================
# Create SNMP test node
# ============================================================
my $snmp_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$snmp_node->cluster_id($C->{cluster_id});
$snmp_node->name("test_snmp_node");
$snmp_node->configuration({
	host       => "127.0.0.1",
	group      => "TestGroup",
	netType    => "default",
	roleType   => "default",
	threshold  => 1,
	model      => "TestSnmp",
	collect    => "true",
	ping       => "false",
	community  => "public",
	version    => "snmpv2c",
});
my ($op, $err) = $snmp_node->save();
ok(!$err, "SNMP test node saved without error") or diag("Save error: $err");

# Create WMI test node
my $wmi_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$wmi_node->cluster_id($C->{cluster_id});
$wmi_node->name("test_wmi_node");
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
ok(!$err, "WMI test node saved without error") or diag("Save error: $err");

# ============================================================
# Phase 2: Test SNMP Update Pipeline
# ============================================================
diag("=== Phase 2: SNMP Update Pipeline ===");

my ($snmp_catchall_inv, $cinv_err) = $snmp_node->inventory(concept => "catchall", model_class => "system");
ok(!$cinv_err, "SNMP catchall inventory created") or diag("Error: $cinv_err");

my $S = setup_snmp_sys(node => $snmp_node, update => 1, catchall_inventory => $snmp_catchall_inv);
ok($S, "SNMP Sys object created");

# Open the mock session
ok($S->open(), "Mock SNMP session opened");

# update_node_info
my $result = $snmp_node->update_node_info(sys => $S, catchall_inventory => $snmp_catchall_inv);
ok($result->{success}, "update_node_info succeeded") or diag("Result: " . Dumper($result));

my $cd = $snmp_catchall_inv->data_live();
is($cd->{sysDescr}, $snmp_walk{OID_sysDescr()}, "sysDescr populated correctly");
is($cd->{sysObjectID}, $snmp_walk{OID_sysObjectID()}, "sysObjectID populated correctly");
ok($cd->{sysUpTime}, "sysUpTime populated");
is($cd->{nodeModel}, "TestSnmp", "nodeModel set to TestSnmp");
is($cd->{ifNumber}, $snmp_walk{OID_ifNumber()}, "ifNumber matches walk data");
is($cd->{sysName}, $snmp_walk{OID_sysName()}, "sysName populated");
is($cd->{sysLocation}, $snmp_walk{OID_sysLocation()}, "sysLocation populated");

# collect_systemhealth_info
$snmp_node->collect_systemhealth_info(sys => $S, catchall_inventory => $snmp_catchall_inv);

my $sensor_model = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
ok(!$sensor_model->error, "testSensor inventory query ok") or diag("Error: " . $sensor_model->error);
is($sensor_model->count, 2, "Found 2 testSensor indices");

# Validate each sensor
my $sensor_objects = $sensor_model->objects;
ok($sensor_objects->{success}, "testSensor objects retrieved");
my @sensors = @{$sensor_objects->{objects}};
my %sensor_names;
for my $inv (@sensors) {
	my $d = $inv->data;
	ok($d->{testSensorName}, "Sensor has testSensorName: $d->{testSensorName}");
	$sensor_names{$d->{testSensorName}} = 1;
	ok(!$inv->historic, "Sensor is not historic");
	ok($inv->enabled, "Sensor is enabled");
}
ok($sensor_names{$snmp_walk{OID_sensorName1()}}, "Sensor index 1 name found: " . $snmp_walk{OID_sensorName1()});
ok($sensor_names{$snmp_walk{OID_sensorName2()}}, "Sensor index 2 name found: " . $snmp_walk{OID_sensorName2()});

# update_concepts
$snmp_node->update_concepts(sys => $S);
# Re-check sensors are still active
$sensor_model = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
is($sensor_model->count, 2, "testSensor still active after update_concepts");

# Save catchall
$snmp_catchall_inv->save(node => $snmp_node);
$S->close();

# ============================================================
# Phase 2b: Test Inventory Lifecycle (Index Appear/Disappear)
# ============================================================
diag("=== Phase 2b: Inventory Lifecycle (Index Appear/Disappear) ===");

# Save original values so we can restore after lifecycle tests
my %saved_index2_oids = (
	OID_sensorName2() => $snmp_walk{OID_sensorName2()},
	OID_sensorStat2() => $snmp_walk{OID_sensorStat2()},
	OID_sensorVal2()  => $snmp_walk{OID_sensorVal2()},
);

# --- Test A: Index disappears → marked historic ---
diag("--- Test A: Index disappears ---");
delete $snmp_walk{OID_sensorName2()};
delete $snmp_walk{OID_sensorStat2()};
delete $snmp_walk{OID_sensorVal2()};

my $S_lc = setup_snmp_sys(node => $snmp_node, update => 1, catchall_inventory => $snmp_catchall_inv);
$S_lc->open();
$snmp_node->collect_systemhealth_info(sys => $S_lc, catchall_inventory => $snmp_catchall_inv);
$S_lc->close();

my $active_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
is($active_sensors->count, 1, "After removing index 2: 1 active sensor");

my $historic_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 1 });
is($historic_sensors->count, 1, "After removing index 2: 1 historic sensor");

# Validate the historic sensor is TempSensor2
my $hist_objs = $historic_sensors->objects;
my $hist_inv = $hist_objs->{objects}[0];
is($hist_inv->data->{testSensorName}, $saved_index2_oids{OID_sensorName2()},
	"Historic sensor is TempSensor2");

# Validate the active sensor
my $act_objs = $active_sensors->objects;
my $act_inv = $act_objs->{objects}[0];
ok(!$act_inv->historic, "Active sensor historic=0");
ok($act_inv->enabled, "Active sensor enabled=1");

# --- Test B: Index reappears → unmarked historic ---
diag("--- Test B: Index reappears ---");
$snmp_walk{OID_sensorName2()} = $saved_index2_oids{OID_sensorName2()};
$snmp_walk{OID_sensorStat2()} = $saved_index2_oids{OID_sensorStat2()};
$snmp_walk{OID_sensorVal2()}  = $saved_index2_oids{OID_sensorVal2()};

$S_lc = setup_snmp_sys(node => $snmp_node, update => 1, catchall_inventory => $snmp_catchall_inv);
$S_lc->open();
$snmp_node->collect_systemhealth_info(sys => $S_lc, catchall_inventory => $snmp_catchall_inv);
$S_lc->close();

$active_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
is($active_sensors->count, 2, "After restoring index 2: 2 active sensors");

$historic_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 1 });
is($historic_sensors->count, 0, "After restoring index 2: 0 historic sensors");

# Validate both are active
$act_objs = $active_sensors->objects;
for my $inv (@{$act_objs->{objects}}) {
	ok(!$inv->historic, "Sensor " . $inv->data->{testSensorName} . " is not historic");
}

# --- Test C: New index appears → new inventory created ---
diag("--- Test C: New index appears ---");
$snmp_walk{OID_sensorName3()} = "TempSensor3";
$snmp_walk{OID_sensorStat3()} = "ok";
$snmp_walk{OID_sensorVal3()}  = "60";

$S_lc = setup_snmp_sys(node => $snmp_node, update => 1, catchall_inventory => $snmp_catchall_inv);
$S_lc->open();
$snmp_node->collect_systemhealth_info(sys => $S_lc, catchall_inventory => $snmp_catchall_inv);
$S_lc->close();

$active_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
is($active_sensors->count, 3, "After adding index 3: 3 active sensors");

# Find the new sensor
$act_objs = $active_sensors->objects;
my $found_sensor3 = 0;
for my $inv (@{$act_objs->{objects}}) {
	if ($inv->data->{testSensorName} eq "TempSensor3") {
		$found_sensor3 = 1;
		ok(!$inv->historic, "TempSensor3 is not historic");
		ok($inv->enabled, "TempSensor3 is enabled");
	}
}
ok($found_sensor3, "TempSensor3 inventory was created");

# --- Test D: Collect skips historic inventory ---
diag("--- Test D: Collect skips historic inventory ---");

# Remove TempSensor3 so it becomes historic
delete $snmp_walk{OID_sensorName3()};
delete $snmp_walk{OID_sensorStat3()};
delete $snmp_walk{OID_sensorVal3()};

$S_lc = setup_snmp_sys(node => $snmp_node, update => 1, catchall_inventory => $snmp_catchall_inv);
$S_lc->open();
$snmp_node->collect_systemhealth_info(sys => $S_lc, catchall_inventory => $snmp_catchall_inv);
$S_lc->close();

$historic_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 1 });
is($historic_sensors->count, 1, "TempSensor3 is now historic");

# Run collect phase
my $S_lc_collect = setup_snmp_sys(node => $snmp_node, update => 0, catchall_inventory => $snmp_catchall_inv);
$S_lc_collect->open();
$cd = $snmp_catchall_inv->data_live();
$cd->{last_poll} = time - 300;
$snmp_catchall_inv->save(node => $snmp_node);

$snmp_node->collect_systemhealth_data(sys => $S_lc_collect, catchall_inventory => $snmp_catchall_inv);
$S_lc_collect->close();

# Active sensors should have timed data from this collect
$active_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
my $active_have_data = 1;
$act_objs = $active_sensors->objects;
for my $inv (@{$act_objs->{objects}}) {
	my $td = $inv->get_newest_timed_data();
	if (!$td || !$td->{success}) {
		$active_have_data = 0;
	}
}
ok($active_have_data, "Active sensors have timed data after collect");

# Historic sensor should NOT have timed data from this collect cycle
$historic_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 1 });
$hist_objs = $historic_sensors->objects;
$hist_inv = $hist_objs->{objects}[0];
my $hist_td = $hist_inv->get_newest_timed_data();
my $hist_has_no_recent_data = (!$hist_td || !$hist_td->{success} || !$hist_td->{data});
ok($hist_has_no_recent_data, "Historic sensor has no timed data from collect");

# --- Cleanup: restore original walk data ---
# TempSensor3 OIDs already deleted above; index 2 already restored in Test B.
# Verify we're back to 2 active sensors for subsequent phases.
$active_sensors = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
is($active_sensors->count, 2, "Restored to 2 active sensors for subsequent phases");

# ============================================================
# Phase 3: Test SNMP Collect Pipeline
# ============================================================
diag("=== Phase 3: SNMP Collect Pipeline ===");

my $S2 = setup_snmp_sys(node => $snmp_node, update => 0, catchall_inventory => $snmp_catchall_inv);
ok($S2, "Collect Sys object created");
ok($S2->open(), "Mock SNMP session opened for collect");

# Set last_poll for collect delta
$cd = $snmp_catchall_inv->data_live();
$cd->{last_poll} = time - 300;
$cd->{last_update} = time - 3600;

# collect_node_info
my $cni_ok = $snmp_node->collect_node_info(sys => $S2, catchall_inventory => $snmp_catchall_inv, time_marker => time);
ok($cni_ok, "collect_node_info succeeded");

$cd = $snmp_catchall_inv->data_live();
ok($cd->{last_poll_snmp}, "last_poll_snmp set");
is($S2->reach->{snmpresult}, 100, "snmpresult is 100");

# collect_node_data
$snmp_node->collect_node_data(sys => $S2, catchall_inventory => $snmp_catchall_inv);

# Verify mib2ip timed data was stored in catchall inventory
# Flush any delayed timed data inserts
$snmp_catchall_inv->save(node => $snmp_node);

# Verify mib2ip in latest_data
my $newest = $snmp_catchall_inv->get_newest_timed_data();
ok($newest->{success}, "catchall latest_data retrieved");
ok($newest->{time}, "catchall latest_data has timestamp");
if ($newest->{success} && ref($newest->{data}) eq "HASH") {
	my $mib2ip = $newest->{data}{mib2ip};
	ok(ref($mib2ip) eq "HASH", "mib2ip subconcept present in latest_data");
	# Counter values start at rate 0 on first collect (no previous data point)
	ok(defined($mib2ip->{ipInReceives}), "ipInReceives in latest_data (counter rate)");
	ok(defined($mib2ip->{ipInDelivers}), "ipInDelivers in latest_data (counter rate)");
	ok(defined($mib2ip->{ipOutRequests}), "ipOutRequests in latest_data (counter rate)");
}
else {
	ok(0, "mib2ip subconcept present in latest_data");
	ok(0, "ipInReceives in latest_data");
	ok(0, "ipInDelivers in latest_data");
	ok(0, "ipOutRequests in latest_data");
}

# Verify timed collection also has the data
my $newest_timed = $snmp_catchall_inv->get_newest_timed_data(from_timed => 1);
ok($newest_timed->{success}, "catchall timed collection record exists");
if ($newest_timed->{success} && $newest_timed->{time}) {
	is($newest_timed->{time}, $newest->{time}, "timed collection timestamp matches latest_data for catchall");
}
else {
	ok(0, "timed collection timestamp matches latest_data for catchall");
}

# Verify mib2ip storage path was recorded
my $storage = $snmp_catchall_inv->storage();
ok($storage->{mib2ip}, "mib2ip RRD storage path recorded in catchall inventory");

# Check that inline alert on ipOutRequests was evaluated
my $alerts = $S2->{alerts} || [];
my @system_alerts = grep { $_->{event} && $_->{event} eq 'High IP Traffic' } @$alerts;
# ipOutRequests=450000, test is '$r > 1000000', so should NOT fire
is(scalar(@system_alerts), 1, "System-level alert evaluated");
ok(!$system_alerts[0]->{test_result}, "ipOutRequests alert did not fire (450000 < 1000000)");

# Set mock stats HIGH before systemhealth collect so timed_data stores it for thresholds
$mock_stats{testSensor} = { testSensorUtil => 92 };

# collect_systemhealth_data
$snmp_node->collect_systemhealth_data(sys => $S2, catchall_inventory => $snmp_catchall_inv);

# Validate testSensor data was collected - both inventory data and timed data
$sensor_model = $snmp_node->get_inventory_model(concept => "testSensor", filter => { historic => 0 });
$sensor_objects = $sensor_model->objects;
for my $inv (@{$sensor_objects->{objects}}) {
	my $d = $inv->data;
	my $sname = $d->{testSensorName};

	# Inventory data: sys fields from update + rrd fields from collect
	ok(defined($d->{testSensorName}), "testSensorName in inventory data: $sname");
	ok(defined($d->{testSensorStatus}), "testSensorStatus in inventory data for $sname: " . ($d->{testSensorStatus} // 'undef'));
	ok(defined($d->{testSensorValue}), "testSensorValue in inventory data for $sname: " . ($d->{testSensorValue} // 'undef'));

	# latest_data: the most recent point-in-time record (read from latest_data collection)
	my $td = $inv->get_newest_timed_data();
	ok($td->{success}, "testSensor latest_data retrieved for $sname");
	ok($td->{time}, "testSensor latest_data has timestamp for $sname");
	if ($td->{success} && ref($td->{data}) eq "HASH") {
		my $pit = $td->{data}{testSensor} // $td->{data};
		ok(defined($pit->{testSensorValue}), "testSensorValue in latest_data for $sname: " . ($pit->{testSensorValue} // 'undef'));
	}
	else {
		ok(0, "testSensorValue in latest_data for $sname");
	}

	# Derived data in latest_data
	if ($td->{success} && ref($td->{derived_data}) eq "HASH") {
		my $dd = $td->{derived_data}{testSensor} // $td->{derived_data};
		ok(defined($dd->{testSensorUtil}), "testSensorUtil in latest_data derived_data for $sname: " . ($dd->{testSensorUtil} // 'undef'));
	}
	else {
		ok(0, "testSensorUtil in latest_data derived_data for $sname");
	}

	# timed collection: verify the per-concept timed collection also has the data
	my $td_timed = $inv->get_newest_timed_data(from_timed => 1);
	ok($td_timed->{success}, "testSensor timed collection record exists for $sname");
	if ($td_timed->{success} && $td_timed->{time}) {
		is($td_timed->{time}, $td->{time}, "timed collection timestamp matches latest_data for $sname");
	}
	else {
		ok(0, "timed collection timestamp matches latest_data for $sname");
	}

	# Storage path recorded
	my $inv_storage = $inv->storage();
	ok($inv_storage->{testSensor}, "testSensor RRD storage path recorded for $sname");
}

# Check inline alerts for testSensorValue
my @sensor_alerts = grep { $_->{event} && $_->{event} eq 'High Sensor Value' } @{$S2->{alerts}};
ok(scalar(@sensor_alerts) >= 2, "Got testSensorValue alerts for both indices") or diag("Alert count: " . scalar(@sensor_alerts));

# Index 1 (value=95) should fire, index 2 (value=42) should not
my @fired = grep { $_->{test_result} } @sensor_alerts;
my @normal = grep { !$_->{test_result} } @sensor_alerts;
is(scalar(@fired), 1, "One sensor alert fired (value 95 > 90)");
is(scalar(@normal), 1, "One sensor alert normal (value 42 <= 90)");

# process_alerts creates status records
$snmp_node->process_alerts(sys => $S2);

my $status_md = $snmp_node->get_status_model();
if ($status_md && !$status_md->error) {
	my $status_objs = $status_md->objects;
	my @alert_statuses = grep { $_->method eq "Alert" } @{$status_objs->{objects} || []};
	ok(scalar(@alert_statuses) > 0, "Status records created with method=Alert") or diag("Alert status count: " . scalar(@alert_statuses));
}

# ============================================================
# Phase 3b: Test error handling and handle_down
# ============================================================
diag("=== Phase 3b: Error handling and handle_down ===");

my $mock_for_errors = $S2->{snmp};

# Helper: reset catchall snmpdown state and save
sub reset_snmpdown {
	my ($inv, $node) = @_;
	my $d = $inv->data;
	$d->{snmpdown} = 'false';
	$d->{nodestatus} = 'reachable';
	$inv->data($d);
	$inv->save(node => $node, update => 1);
}

# --- Direct handle_down tests ---
diag("  -- Direct handle_down tests --");

# Test handle_down going DOWN
reset_snmpdown($snmp_catchall_inv, $snmp_node);
$snmp_node->handle_down(sys => $S2, type => "snmp", details => "test snmp down", catchall_inventory => $snmp_catchall_inv);

my $hd_data = $snmp_catchall_inv->data();
is($hd_data->{snmpdown}, 'true', "handle_down(snmp): snmpdown flag set to 'true'");
ok($hd_data->{nodestatus} && $hd_data->{nodestatus} ne 'reachable',
	"handle_down(snmp): nodestatus changed from reachable to '$hd_data->{nodestatus}'");
ok($snmp_node->eventExist("SNMP Down"), "handle_down(snmp): 'SNMP Down' event created");

# Test handle_down going UP (recovery)
$snmp_node->handle_down(sys => $S2, type => "snmp", up => 1, details => "snmp ok", catchall_inventory => $snmp_catchall_inv);

$hd_data = $snmp_catchall_inv->data();
is($hd_data->{snmpdown}, 'false', "handle_down(snmp, up): snmpdown flag set to 'false'");
is($hd_data->{nodestatus}, 'reachable', "handle_down(snmp, up): nodestatus back to 'reachable'");

# Test handle_down for WMI
reset_snmpdown($snmp_catchall_inv, $snmp_node);  # ensure clean state
$snmp_node->handle_down(sys => $S2, type => "wmi", details => "test wmi down", catchall_inventory => $snmp_catchall_inv);
$hd_data = $snmp_catchall_inv->data();
is($hd_data->{wmidown}, 'true', "handle_down(wmi): wmidown flag set to 'true'");
# Clean up WMI down state
$snmp_node->handle_down(sys => $S2, type => "wmi", up => 1, details => "wmi ok", catchall_inventory => $snmp_catchall_inv);

# --- handle_sys_get_data_error tests ---
diag("  -- handle_sys_get_data_error tests --");

# For no_session and transport_error to trigger handle_down, Sys status must have snmp_error set.
# handle_sys_get_data_error checks $S->status->{snmp_error} to decide whether to call handle_down.

# Test "not present" — return 1, NO handle_down
reset_snmpdown($snmp_catchall_inv, $snmp_node);
$mock_for_errors->force_error("Requested table is empty or does not exist");
my $err_result = $snmp_node->handle_sys_get_data_error(
	sys => $S2, caller => "test_not_present", section => "testSensor",
	index => "1", catchall_data => $snmp_catchall_inv->data_live(),
	catchall_inventory => $snmp_catchall_inv
);
is($err_result, 1, "error_not_present: returns 1");
$hd_data = $snmp_catchall_inv->data();
is($hd_data->{snmpdown}, 'false', "error_not_present: snmpdown still 'false' (no handle_down)");
ok(!$snmp_node->eventExist("SNMP Down"), "error_not_present: no 'SNMP Down' event");

# Test "model error" — return 2, NO handle_down
reset_snmpdown($snmp_catchall_inv, $snmp_node);
$mock_for_errors->force_error("incorrect syntax near OID");
$err_result = $snmp_node->handle_sys_get_data_error(
	sys => $S2, caller => "test_model_error", section => "testSensor",
	index => "1", catchall_data => $snmp_catchall_inv->data_live(),
	catchall_inventory => $snmp_catchall_inv
);
is($err_result, 2, "error_model: returns 2");
$hd_data = $snmp_catchall_inv->data();
is($hd_data->{snmpdown}, 'false', "error_model: snmpdown still 'false' (no handle_down)");
ok(!$snmp_node->eventExist("SNMP Down"), "error_model: no 'SNMP Down' event");

# Test "no session" — return 10, YES handle_down
# Need to set snmp_error in Sys status so handle_down gets triggered
reset_snmpdown($snmp_catchall_inv, $snmp_node);
$mock_for_errors->force_error("No session open");
$S2->{snmp_error} = "No session open";  # set status-level error
$err_result = $snmp_node->handle_sys_get_data_error(
	sys => $S2, caller => "test_no_session", section => "testSensor",
	index => "1", catchall_data => $snmp_catchall_inv->data_live(),
	catchall_inventory => $snmp_catchall_inv
);
is($err_result, 10, "error_no_session: returns 10");
$hd_data = $snmp_catchall_inv->data();
is($hd_data->{snmpdown}, 'true', "error_no_session: snmpdown set to 'true' (handle_down called)");
ok($snmp_node->eventExist("SNMP Down"), "error_no_session: 'SNMP Down' event created");
ok($hd_data->{nodestatus} && $hd_data->{nodestatus} ne 'reachable',
	"error_no_session: nodestatus changed to '$hd_data->{nodestatus}'");

# Clean up: recover from snmp down
$snmp_node->handle_down(sys => $S2, type => "snmp", up => 1, details => "snmp ok", catchall_inventory => $snmp_catchall_inv);
$S2->{snmp_error} = undef;

# Test "transport error" — return 4, YES handle_down
reset_snmpdown($snmp_catchall_inv, $snmp_node);
$mock_for_errors->force_error("Connection timed out");
$S2->{snmp_error} = "Connection timed out";
$err_result = $snmp_node->handle_sys_get_data_error(
	sys => $S2, caller => "test_transport_error", section => "testSensor",
	index => "1", catchall_data => $snmp_catchall_inv->data_live(),
	catchall_inventory => $snmp_catchall_inv
);
is($err_result, 4, "error_transport: returns 4");
$hd_data = $snmp_catchall_inv->data();
is($hd_data->{snmpdown}, 'true', "error_transport: snmpdown set to 'true' (handle_down called)");
ok($snmp_node->eventExist("SNMP Down"), "error_transport: 'SNMP Down' event created");
ok($hd_data->{nodestatus} && $hd_data->{nodestatus} ne 'reachable',
	"error_transport: nodestatus changed to '$hd_data->{nodestatus}'");

# Clean up for subsequent tests
$snmp_node->handle_down(sys => $S2, type => "snmp", up => 1, details => "snmp ok", catchall_inventory => $snmp_catchall_inv);
$S2->{snmp_error} = undef;
$mock_for_errors->force_error(undef);

# ============================================================
# Phase 4: Test Custom Alerts (model-level alerts class)
# ============================================================
diag("=== Phase 4: Custom Alerts ===");

my $alerts_before = scalar(@{$S2->{alerts} || []});
$snmp_node->handle_custom_alerts(sys => $S2, catchall_inventory => $snmp_catchall_inv);
my $alerts_after = scalar(@{$S2->{alerts} || []});
ok($alerts_after > $alerts_before, "handle_custom_alerts added alerts (before=$alerts_before, after=$alerts_after)");

# Check for custom test alert (CVAR1=testSensorValue;$CVAR1 > 80)
my @custom_test = grep { $_->{event} && $_->{event} eq 'Custom Sensor Alert' } @{$S2->{alerts}};
ok(scalar(@custom_test) >= 2, "Custom test alerts found for both indices");
my @custom_fired = grep { $_->{test_result} } @custom_test;
is(scalar(@custom_fired), 1, "One custom test alert fired (value 95 > 80)");

# Check for custom threshold-rising alert
my @custom_thr = grep { $_->{event} && $_->{event} eq 'Custom Sensor Threshold' } @{$S2->{alerts}};
ok(scalar(@custom_thr) >= 2, "Custom threshold alerts found for both indices");
# value=95 should be Critical (>= 95), value=42 should be Normal (< 70)
my @crit = grep { $_->{level} && $_->{level} eq 'Critical' } @custom_thr;
my @norm = grep { !$_->{test_result} } @custom_thr;
ok(scalar(@crit) >= 1, "Custom threshold alert at Critical for value=95");
ok(scalar(@norm) >= 1, "Custom threshold alert Normal for value=42");

# ============================================================
# Phase 5: Test Compute Reachability
# ============================================================
diag("=== Phase 5: Compute Reachability ===");

my $RI = $S2->reach;
$RI->{pingresult} = 100;
$RI->{pingloss}   = 0;
$RI->{pingavg}    = 2.5;
$RI->{snmpresult} = 100;
$RI->{cpu}        = 25;
$RI->{memused}    = 500000;
$RI->{memfree}    = 500000;

# Ensure catchall data has required fields for compute_reachability
$cd = $snmp_catchall_inv->data_live();
$cd->{collect}     = "true";
$cd->{nodeModel}   = "TestSnmp";
$cd->{nodeType}    = "generic";
$cd->{intfTotal}   = 0;
$cd->{intfCollect} = 0;
$snmp_catchall_inv->save(node => $snmp_node);

# Stock nmis9_dev's update_node_info sets wmiresult=0 unconditionally
# (lib/NMISNG/Node.pm:2216), so compute_reachability's min() logic treats
# the disabled WMI source as a failed poll and reports health = "U".
# The follow-up refactor (commit e44eec11 on test-and-refactor-snmp-wmi)
# replaces that init with a loop that only zeros enabled sources.
# Normalize here so this test exercises only the healthy-path semantics.
$RI->{wmiresult} = undef;

my $reachdata = $snmp_node->compute_reachability(
	sys => $S2, delayupdate => 1, catchall_inventory => $snmp_catchall_inv
);
ok(ref($reachdata) eq "HASH", "compute_reachability returned hash");
ok(exists $reachdata->{reachability}, "reachability key exists");
ok(exists $reachdata->{availability}, "availability key exists");
ok(exists $reachdata->{health}, "health key exists");
ok($reachdata->{reachability}{value} > 0, "reachability value > 0: $reachdata->{reachability}{value}");
ok($reachdata->{health}{value} > 0, "health value > 0: $reachdata->{health}{value}");

# --- Test compute_reachability when SNMP poll failed (degraded node) ---
diag("--- Compute Reachability: SNMP poll failed (degraded) ---");
$RI->{snmpresult} = 0;      # SNMP was tried and failed
$RI->{pingresult} = 100;    # but ping still works

my $degraded = $snmp_node->compute_reachability(
	sys => $S2, delayupdate => 1, catchall_inventory => $snmp_catchall_inv
);
is($degraded->{reachability}{value}, 80, "degraded: reachability is 80 (up but degraded)");
is($degraded->{health}{value}, "U", "degraded: health is U when SNMP down");

# --- Test compute_reachability when source was never enabled (undef result) ---
diag("--- Compute Reachability: WMI never enabled (undef result) ---");
$RI->{snmpresult} = 100;
$RI->{wmiresult}  = undef;  # WMI was never enabled, should not affect result

my $snmponly = $snmp_node->compute_reachability(
	sys => $S2, delayupdate => 1, catchall_inventory => $snmp_catchall_inv
);
is($snmponly->{reachability}{value}, 100, "snmp-only: reachability is 100");
ok($snmponly->{health}{value} > 0, "snmp-only: health is numeric > 0: $snmponly->{health}{value}");

# --- Test compute_reachability when both results exist and one failed ---
diag("--- Compute Reachability: dual-protocol, WMI failed ---");
$RI->{snmpresult} = 100;
$RI->{wmiresult}  = 0;      # WMI enabled but failed: min(100,0) = 0

my $dual_degraded = $snmp_node->compute_reachability(
	sys => $S2, delayupdate => 1, catchall_inventory => $snmp_catchall_inv
);
is($dual_degraded->{reachability}{value}, 80, "dual-degraded: reachability is 80 (poll failed)");
is($dual_degraded->{health}{value}, "U", "dual-degraded: health is U when a poll source failed");

# Restore for subsequent tests
$RI->{snmpresult} = 100;
$RI->{wmiresult}  = undef;

# ============================================================
# Phase 6: Test Compute Summary Stats
# ============================================================
diag("=== Phase 6: Compute Summary Stats ===");

my $summary_stats = $snmp_node->compute_summary_stats(sys => $S2, inventory => $snmp_catchall_inv);
ok(ref($summary_stats) eq "HASH", "compute_summary_stats returned hash");
ok(exists $summary_stats->{reachability} || exists $summary_stats->{availability},
	"Standard stats keys present") or diag("Stats: " . Dumper($summary_stats));

# ============================================================
# Phase 7: Test Thresholds (compute_thresholds)
# ============================================================
diag("=== Phase 7: Thresholds ===");

# Save the catchall so thresholds can find it
$snmp_catchall_inv->save(node => $snmp_node);

# Stats were set to 92 before collect_systemhealth_data, so timed_data has testSensorUtil=92
$nmisng->compute_thresholds(sys => $S2, running_independently => 0);

# Check for threshold status records
$status_md = $snmp_node->get_status_model();
if ($status_md && !$status_md->error) {
	my $objs_ret = $status_md->objects;
	my @thr_statuses = grep { $_->method eq "Threshold" } @{$objs_ret->{objects} || []};
	ok(scalar(@thr_statuses) > 0, "Threshold status records created") or diag("Threshold status count: " . scalar(@thr_statuses));
	if (@thr_statuses) {
		my @major = grep { $_->level eq "Major" } @thr_statuses;
		ok(scalar(@major) > 0, "Found Major threshold status for testSensorUtil=92");
	}
}

# Now test Normal case - need to re-collect with lower stats so timed_data is updated
$mock_stats{testSensor} = { testSensorUtil => 50 };
# Re-run systemhealth collect to store new derived_data with testSensorUtil=50
$snmp_node->collect_systemhealth_data(sys => $S2, catchall_inventory => $snmp_catchall_inv);
$nmisng->compute_thresholds(sys => $S2, running_independently => 0);

$status_md = $snmp_node->get_status_model();
if ($status_md && !$status_md->error) {
	my $objs_ret = $status_md->objects;
	my @thr_statuses = grep { $_->method eq "Threshold" && $_->property eq "testSensorUtil" } @{$objs_ret->{objects} || []};
	my @normal = grep { $_->level eq "Normal" } @thr_statuses;
	ok(scalar(@normal) > 0, "Threshold status Normal for testSensorUtil=50") or diag("Normal count: " . scalar(@normal) . ", total threshold: " . scalar(@thr_statuses));
}

$S2->close();

# ============================================================
# Phase 8: Test WMI Update Pipeline
# ============================================================
diag("=== Phase 8: WMI Update Pipeline ===");

my ($wmi_catchall_inv, $wcinv_err) = $wmi_node->inventory(concept => "catchall", model_class => "system");
ok(!$wcinv_err, "WMI catchall inventory created") or diag("Error: $wcinv_err");

my $SW = setup_wmi_sys(node => $wmi_node, update => 1, catchall_inventory => $wmi_catchall_inv);
ok($SW, "WMI Sys object created");

# update_node_info for WMI
my $wmi_result = $wmi_node->update_node_info(sys => $SW, catchall_inventory => $wmi_catchall_inv);
ok($wmi_result->{success}, "WMI update_node_info succeeded") or diag("Result: " . Dumper($wmi_result));

my $wcd = $wmi_catchall_inv->data_live();
is($wcd->{nodeModel}, "TestWmi", "WMI nodeModel set to TestWmi");
ok($wcd->{winosname} || $wcd->{sysDescr}, "WMI OS info populated");

# collect_systemhealth_info for WMI
$wmi_node->collect_systemhealth_info(sys => $SW, catchall_inventory => $wmi_catchall_inv);

my $disk_model = $wmi_node->get_inventory_model(concept => "wmiDisk", filter => { historic => 0 });
ok(!$disk_model->error, "wmiDisk inventory query ok") or diag("Error: " . $disk_model->error);
is($disk_model->count, 2, "Found 2 wmiDisk indices (C: and D:)");

$wmi_catchall_inv->save(node => $wmi_node);

# ============================================================
# Phase 9: Test WMI Collect Pipeline
# ============================================================
diag("=== Phase 9: WMI Collect Pipeline ===");

my $SW2 = setup_wmi_sys(node => $wmi_node, update => 0, catchall_inventory => $wmi_catchall_inv);
ok($SW2, "WMI collect Sys object created");

$wcd = $wmi_catchall_inv->data_live();
$wcd->{last_poll} = time - 300;
$wcd->{last_update} = time - 3600;

# collect_node_info for WMI
my $wcni_ok = $wmi_node->collect_node_info(sys => $SW2, catchall_inventory => $wmi_catchall_inv, time_marker => time);
ok($wcni_ok, "WMI collect_node_info succeeded");

# collect_node_data for WMI
$wmi_node->collect_node_data(sys => $SW2, catchall_inventory => $wmi_catchall_inv);

# Check for WMI CPU alert (value=25, test is '$r > 90', should NOT fire)
my @wmi_cpu_alerts = grep { $_->{event} && $_->{event} eq 'High WMI CPU' } @{$SW2->{alerts} || []};
if (@wmi_cpu_alerts) {
	ok(!$wmi_cpu_alerts[0]->{test_result}, "WMI CPU alert did not fire (25 < 90)");
}

# Set mock stats for WMI disk thresholds
$mock_stats{wmiDisk} = { wmiDiskUtil => 92 };

# collect_systemhealth_data for WMI
$wmi_node->collect_systemhealth_data(sys => $SW2, catchall_inventory => $wmi_catchall_inv);

# Validate WMI disk data - inventory data, timed data, and derived data
$disk_model = $wmi_node->get_inventory_model(concept => "wmiDisk", filter => { historic => 0 });
my $disk_objects = $disk_model->objects;
for my $inv (@{$disk_objects->{objects} || []}) {
	my $d = $inv->data;
	my $dname = $d->{Name} // $d->{index} // 'unknown';

	# Inventory data: sys fields from update + rrd fields from collect
	ok(defined($d->{Name}), "Name in inventory data for disk: $dname");
	ok(defined($d->{wmiDiskSize}), "wmiDiskSize in inventory data for $dname: " . ($d->{wmiDiskSize} // 'undef'));
	ok(defined($d->{wmiDiskFreeSpace}), "wmiDiskFreeSpace in inventory data for $dname: " . ($d->{wmiDiskFreeSpace} // 'undef'));

	# latest_data
	my $td = $inv->get_newest_timed_data();
	ok($td->{success}, "wmiDisk latest_data retrieved for $dname");
	ok($td->{time}, "wmiDisk latest_data has timestamp for $dname");
	if ($td->{success} && ref($td->{data}) eq "HASH") {
		my $pit = $td->{data}{wmiDisk} // $td->{data};
		ok(defined($pit->{wmiDiskFreeSpace}), "wmiDiskFreeSpace in latest_data for $dname: " . ($pit->{wmiDiskFreeSpace} // 'undef'));
	}
	else {
		ok(0, "wmiDiskFreeSpace in latest_data for $dname");
	}

	# Derived data in latest_data
	if ($td->{success} && ref($td->{derived_data}) eq "HASH") {
		my $dd = $td->{derived_data}{wmiDisk} // $td->{derived_data};
		ok(defined($dd->{wmiDiskUtil}), "wmiDiskUtil in latest_data derived_data for $dname: " . ($dd->{wmiDiskUtil} // 'undef'));
	}
	else {
		ok(0, "wmiDiskUtil in latest_data derived_data for $dname");
	}

	# timed collection
	my $td_timed = $inv->get_newest_timed_data(from_timed => 1);
	ok($td_timed->{success}, "wmiDisk timed collection record exists for $dname");
	if ($td_timed->{success} && $td_timed->{time}) {
		is($td_timed->{time}, $td->{time}, "timed collection timestamp matches latest_data for $dname");
	}
	else {
		ok(0, "timed collection timestamp matches latest_data for $dname");
	}

	# Storage path
	my $inv_storage = $inv->storage();
	ok($inv_storage->{wmiDisk}, "wmiDisk RRD storage path recorded for $dname");
}

# ============================================================
# Phase 10: Test WMI Custom Alerts and Thresholds
# ============================================================
diag("=== Phase 10: WMI Custom Alerts and Thresholds ===");

my $wmi_alerts_before = scalar(@{$SW2->{alerts} || []});
$wmi_node->handle_custom_alerts(sys => $SW2, catchall_inventory => $wmi_catchall_inv);
my $wmi_alerts_after = scalar(@{$SW2->{alerts} || []});
ok($wmi_alerts_after > $wmi_alerts_before, "WMI handle_custom_alerts added alerts");

# Save catchall for thresholds
$wmi_catchall_inv->save(node => $wmi_node);

# Test thresholds with high value
$mock_stats{wmiDisk} = { wmiDiskUtil => 92 };
$nmisng->compute_thresholds(sys => $SW2, running_independently => 0);

my $wmi_status_md = $wmi_node->get_status_model();
if ($wmi_status_md && !$wmi_status_md->error) {
	my $objs_ret = $wmi_status_md->objects;
	my @thr = grep { $_->method eq "Threshold" } @{$objs_ret->{objects} || []};
	ok(scalar(@thr) > 0, "WMI threshold status records created");
}

$SW2->close();

# ============================================================
# Phase 11: Test full update() and collect() orchestration
# ============================================================
diag("=== Phase 11: Full update/collect orchestration ===");

# Create a fresh node for this test
my $orch_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$orch_node->cluster_id($C->{cluster_id});
$orch_node->name("test_orch_node");
$orch_node->configuration({
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
($op, $err) = $orch_node->save();
ok(!$err, "Orchestration test node saved") or diag("Error: $err");

# Monkey-patch NMISNG::Snmp::new to return our mock.
# This ensures that when update()/collect() internally creates a Sys and calls init(),
# the SNMP object created is our mock with walk data.
my $orig_snmp_new = \&NMISNG::Snmp::new;
{
	no warnings 'redefine';
	*NMISNG::Snmp::new = sub {
		my ($class, %args) = @_;
		return NMISNG::Snmp::Mock->new(
			nmisng    => $args{nmisng},
			name      => $args{name},
			walk_data => \%snmp_walk,
		);
	};
}

# Test update() — full orchestration
my $update_result = $orch_node->update(force => 1);
ok($update_result->{success}, "Full update() succeeded") or diag("update error: " . ($update_result->{error} // 'none'));

# Verify update populated catchall correctly
my ($orch_catchall, $orch_err) = $orch_node->inventory(concept => "catchall");
if (!$orch_err && $orch_catchall) {
	my $ocd = $orch_catchall->data_live();
	is($ocd->{sysDescr}, $snmp_walk{OID_sysDescr()}, "update() populated sysDescr");
	is($ocd->{nodeModel}, "TestSnmp", "update() set nodeModel");
	ok($ocd->{last_update}, "update() set last_update timestamp");
}

# Test collect() — full orchestration (needs last_update set by update above)
my $collect_result = $orch_node->collect(wantsnmp => 1);
ok($collect_result->{success}, "Full collect() succeeded") or diag("collect error: " . ($collect_result->{error} // 'none'));

# Re-fetch catchall after collect (collect creates its own Sys/catchall internally)
my ($orch_catchall2, $orch_err2) = $orch_node->inventory(concept => "catchall");
if (!$orch_err2 && $orch_catchall2) {
	my $ocd2 = $orch_catchall2->data();
	ok($ocd2->{last_poll}, "collect() set last_poll timestamp");
}
else {
	ok(0, "collect() set last_poll timestamp");
}

# Restore original NMISNG::Snmp::new
{
	no warnings 'redefine';
	*NMISNG::Snmp::new = $orig_snmp_new;
}

# ============================================================
# Phase 11b: collect=false node — nodeModel and nodegraph persisted
# ============================================================
diag("=== Phase 11b: collect=false nodeModel/nodegraph persistence ===");

# A PingOnly node has collect=false. update_node_info takes the else branch and
# must write nodeModel and nodegraph directly into catchall_data so opCharts can
# read them without requiring a collect=true run.
my $ping_node = NMISNG::Node->new(uuid => NMISNG::Util::getUUID(), nmisng => $nmisng);
$ping_node->cluster_id($C->{cluster_id});
$ping_node->name("test_pingonly_node");
$ping_node->configuration({
	host     => "127.0.0.1",
	group    => "TestGroup",
	netType  => "default",
	roleType => "default",
	model    => "PingOnly",
	collect  => "false",
	ping     => "true",
});
($op, $err) = $ping_node->save();
ok(!$err, "PingOnly test node saved") or diag("Save error: $err");

my ($ping_catchall_inv, $ping_cinv_err) = $ping_node->inventory(concept => "catchall", model_class => "system");
ok(!$ping_cinv_err, "PingOnly catchall inventory created") or diag("Error: $ping_cinv_err");

my $SP = NMISNG::Sys->new(nmisng => $nmisng);
$SP->init(
	node               => $ping_node,
	snmp               => 0,
	wmi                => 0,
	update             => 'true',
	force              => 1,
	catchall_inventory => $ping_catchall_inv,
);

my $ping_result = $ping_node->update_node_info(sys => $SP, catchall_inventory => $ping_catchall_inv);
ok($ping_result->{success}, "update_node_info succeeded for collect=false node")
	or diag("Result: " . Dumper($ping_result));

my $pcd = $ping_catchall_inv->data_live();
is($pcd->{nodeModel}, "PingOnly", "collect=false: nodeModel persisted as PingOnly");
is_deeply($pcd->{nodegraph}, ["health-ping", "response"],
	"collect=false: nodegraph persisted as [health-ping, response]");

# ============================================================
# Phase 12: Cleanup
# ============================================================
diag("=== Phase 12: Cleanup ===");
cleanup();
ok(1, "Cleanup complete");

done_testing();
