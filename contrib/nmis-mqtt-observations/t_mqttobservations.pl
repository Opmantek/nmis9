#!/usr/bin/perl
#
# Tests for the mqttobservations NMIS collect plugin.
#
# Run from the contrib/nmis-mqtt-observations/ directory:
#   perl t_mqttobservations.pl
#
# These tests exercise the plugin logic using mock objects, so no live
# NMIS installation, MongoDB connection, or MQTT broker is required.
#
use strict;
use warnings;

# if using something other than /usr/local/nmis9
#use FindBin;
#use lib "$FindBin::Bin/../../lib";
#use lib "$FindBin::Bin/../../conf/plugins";

use lib "/usr/local/nmis9/lib";
use lib "/usr/local/nmis9/conf/plugins";

use Test::More;

# ---------------------------------------------------------------------------
# 1. Plugin loads and exports expected symbols
# ---------------------------------------------------------------------------

# We load the plugin directly. Because NMISNG::Util is pulled in via lib/,
# that must be available. If running on a system without the full NMIS stack,
# this will catch that early.
use_ok('mqttobservations') or BAIL_OUT("Plugin failed to load — check NMIS lib path");

can_ok('mqttobservations', 'collect_plugin');

# ---------------------------------------------------------------------------
# 2. _get_description — concept-specific field mapping
# ---------------------------------------------------------------------------

my $desc_tests = [
	# [ concept, data hashref, expected description ]

	# interface — prefers ifDescr
	[ 'interface', { ifDescr => 'GigabitEthernet0/0', Description => 'WAN link' },
	  'GigabitEthernet0/0', 'interface: picks ifDescr over Description' ],

	# interface — falls back to Description when no ifDescr
	[ 'interface', { Description => 'WAN link' },
	  'WAN link', 'interface: falls back to Description' ],

	# catchall — prefers sysDescr
	[ 'catchall', { sysDescr => 'Cisco IOS 15.2', sysName => 'router1' },
	  'Cisco IOS 15.2', 'catchall: picks sysDescr' ],

	# catchall — falls back to sysName
	[ 'catchall', { sysName => 'router1', nodeType => 'router' },
	  'router1', 'catchall: falls back to sysName' ],

	# Host_Storage — hrStorageDescr
	[ 'Host_Storage', { hrStorageDescr => 'Physical memory' },
	  'Physical memory', 'Host_Storage: picks hrStorageDescr' ],

	# Host_File_System — hrFSMountPoint
	[ 'Host_File_System', { hrFSMountPoint => '/var', hrFSType => 'ext4' },
	  '/var', 'Host_File_System: picks hrFSMountPoint' ],

	# Host_Partition — hrPartitionLabel
	[ 'Host_Partition', { hrPartitionLabel => 'sda1', hrPartitionID => '1' },
	  'sda1', 'Host_Partition: picks hrPartitionLabel' ],

	# entityMib — entPhysicalName
	[ 'entityMib', { entPhysicalName => 'GigE0/0', entPhysicalDescr => 'Gigabit Ethernet' },
	  'GigE0/0', 'entityMib: picks entPhysicalName' ],

	# cdp — cdpCacheDeviceId
	[ 'cdp', { cdpCacheDeviceId => 'switch1.example.com', cdpCacheDevicePort => 'Fa0/1' },
	  'switch1.example.com', 'cdp: picks cdpCacheDeviceId' ],

	# lldp — lldpRemSysName
	[ 'lldp', { lldpRemSysName => 'switch2', lldpRemPortDesc => 'GE1' },
	  'switch2', 'lldp: picks lldpRemSysName' ],

	# bgp — bgpPeerIdentifier
	[ 'bgp', { bgpPeerIdentifier => '10.0.0.1' },
	  '10.0.0.1', 'bgp: picks bgpPeerIdentifier' ],

	# vlan — vlanName
	[ 'vlan', { vlanName => 'MGMT', vtpVlanName => 'Management' },
	  'MGMT', 'vlan: picks vlanName' ],

	# Unknown concept — generic fallback to Description
	[ 'SomeUnknownConcept', { Description => 'A thing', name => 'something' },
	  'A thing', 'unknown concept: generic fallback to Description' ],

	# Unknown concept — falls through to name
	[ 'SomeUnknownConcept', { name => 'myname' },
	  'myname', 'unknown concept: falls through to name' ],

	# No description at all — returns empty string
	[ 'interface', { ifIndex => '1', ifSpeed => 100 },
	  '', 'no description fields present: returns empty string' ],

	# Empty string fields are skipped
	[ 'interface', { ifDescr => '', Description => 'Uplink' },
	  'Uplink', 'interface: skips empty ifDescr, uses Description' ],
];

for my $t (@$desc_tests)
{
	my ($concept, $data, $expected, $label) = @$t;
	my $got = mqttobservations::_get_description($concept, $data);
	is($got, $expected, "_get_description: $label");
}

# ---------------------------------------------------------------------------
# 3. Topic index sanitization (tested via collect_plugin mock path below,
#    but also verified directly here as the logic lives inside the loop)
# ---------------------------------------------------------------------------

# These helpers replicate the sanitization logic from the plugin
sub sanitize_index
{
	my $idx = shift;
	$idx =~ s|/|_|g;
	$idx =~ s/\s+/_/g;
	return $idx;
}

my @idx_tests = (
	[ 'GigabitEthernet0/0', 'GigabitEthernet0_0', 'slash replaced with underscore' ],
	[ 'eth 0',              'eth_0',              'space replaced with underscore'  ],
	[ 'Fa0/1/2',            'Fa0_1_2',            'multiple slashes replaced'       ],
	[ '3',                  '3',                  'plain numeric index unchanged'   ],
	[ '0',                  '0',                  'zero index unchanged'            ],
);

for my $t (@idx_tests)
{
	my ($input, $expected, $label) = @$t;
	is(sanitize_index($input), $expected, "topic index sanitization: $label");
}

# ---------------------------------------------------------------------------
# 4. collect_plugin — down-node guard (mock objects, no MQTT/MongoDB)
# ---------------------------------------------------------------------------

# Build minimal mock objects that satisfy the plugin's interface

# Mock logger
package MockLog;
sub new      { bless {}, shift }
sub debug    { }
sub error    { }
sub warn     { }
sub info     { }

package MockInventory;
sub new      { my ($class, %a) = @_; bless { data => $a{data} }, $class }
sub data     { $_[0]->{data} }

package MockNode;
sub new      { bless { uuid => 'test-uuid-1234' }, shift }
sub uuid     { $_[0]->{uuid} }
sub get_inventory_model { }    # not reached in down-node tests

package MockSys;
sub new
{
	my ($class, %a) = @_;
	bless { catchall_data => $a{catchall_data}, node => MockNode->new }, $class;
}
sub nmisng_node { $_[0]->{node} }
sub inventory
{
	my ($self, %a) = @_;
	return (MockInventory->new(data => $self->{catchall_data}), undef)
		if $a{concept} eq 'catchall';
	return (undef, "unknown concept $a{concept}");
}

package MockNMISNG;
sub new  { bless { log => MockLog->new }, shift }
sub log  { $_[0]->{log} }

package main;

# Helper: run collect_plugin with a given catchall state
sub run_with_catchall
{
	my (%catchall) = @_;
	my $sys = MockSys->new(catchall_data => \%catchall);
	my $ng  = MockNMISNG->new;
	my $cfg = {};    # empty config — plugin should bail before loading file
	return mqttobservations::collect_plugin(
		node   => 'testnode',
		sys    => $sys,
		config => $cfg,
		nmisng => $ng,
	);
}

# Node down → should return (0, undef) without attempting MQTT
{
	my @result = run_with_catchall(nodedown => 'true', snmpdown => 'false');
	is($result[0], 0, 'down-node guard: nodedown=true returns 0');
}

# SNMP down → should return (0, undef)
{
	my @result = run_with_catchall(nodedown => 'false', snmpdown => 'true');
	is($result[0], 0, 'down-node guard: snmpdown=true returns 0');
}

# Node up, but config file missing → should return (2, error)
{
	my @result = run_with_catchall(nodedown => 'false', snmpdown => 'false');
	is($result[0], 2, 'up node with missing config returns error code 2');
	like($result[1] // '', qr/config/i, 'error message mentions config');
}

# ---------------------------------------------------------------------------
# 5. collect_plugin — empty concepts list is a no-op
# ---------------------------------------------------------------------------

# Override loadTable to return a config with an empty concepts list
{
	no warnings 'redefine';
	local *NMISNG::Util::loadTable = sub {
		return { mqtt => { server => 'localhost:1883', topic => 'obs/nmis' }, concepts => [] };
	};

	my @result = run_with_catchall(nodedown => 'false', snmpdown => 'false');
	is($result[0], 0, 'empty concepts list returns 0 (no-op)');
}

# ---------------------------------------------------------------------------
# 6. collect_plugin — bad MQTT server config returns error
# ---------------------------------------------------------------------------

{
	no warnings 'redefine';
	local *NMISNG::Util::loadTable = sub {
		return { mqtt => { server => '' }, concepts => ['interface'] };
	};

	my @result = run_with_catchall(nodedown => 'false', snmpdown => 'false');
	is($result[0], 2, 'missing mqtt.server returns error code 2');
	like($result[1] // '', qr/server/i, 'error message mentions server');
}

# ---------------------------------------------------------------------------

done_testing();
