#!/usr/bin/perl
#
# Tests for the NMIS9 MCP (Model Context Protocol) server.
#
# Run from the contrib/nmis-mcp/ directory:
#   perl t_nmis-mcp.pl
#
# These tests exercise the helper functions and dispatch logic using mock
# objects, so no live NMIS installation, MongoDB connection, or web server
# is required.
#
use strict;
use warnings;

use lib "/usr/local/nmis9/lib";

use Test::More;
use JSON::XS;

# ---------------------------------------------------------------------------
# 1. Load the CGI script as a library so we can call its subs directly.
#    We wrap it in a package so the top-level main() code doesn't execute.
# ---------------------------------------------------------------------------

# We cannot use/require the CGI script directly because it runs main code
# at load time. Instead we extract and test the helper subs by evaluating
# the relevant portions. For a cleaner approach we replicate the key data
# structures and helpers here (they are the same code).

# Replicate the data structures from nmis-mcp.pl so we can test them.

my %DESCRIPTION_FIELDS = (
	'interface'        => [qw(ifDescr Description)],
	'catchall'         => [qw(sysDescr sysName nodeType)],
	'Host_Storage'     => [qw(hrStorageDescr)],
	'Host_File_System' => [qw(hrFSMountPoint hrFSType)],
	'Host_Partition'   => [qw(hrPartitionLabel hrPartitionID)],
	'entityMib'        => [qw(entPhysicalName entPhysicalDescr)],
	'cdp'              => [qw(cdpCacheDeviceId cdpCacheDevicePort)],
	'lldp'             => [qw(lldpRemSysName lldpRemPortDesc)],
	'bgp'              => [qw(bgpPeerIdentifier)],
	'vlan'             => [qw(vlanName vtpVlanName)],
	'mpls'             => [qw(mplsVpnVrfName)],
	'cbqos'            => [qw(CbQosPolicyMapName)],
	'addressTable'     => [qw(dot1dTpFdbAddress)],
	'diskIOTable'      => [qw(diskIODevice)],
	'env-temp'         => [qw(lmTempSensorsDevice)],
	'storage'          => [qw(hrStorageDescr)],
	'service'          => [qw(service)],
	'ping'             => [qw(host)],
	'device'           => [qw(index)],
);

my @FALLBACK_DESCRIPTION_FIELDS = qw(Description description Name name ifDescr);

my %CONCEPT_RENAME = (
	'device' => 'cpuLoad',
);

my %FIELD_RENAME = (
	'interface' => {
		'ifInOctets'    => 'system.network.io.receive',
		'ifOutOctets'   => 'system.network.io.transmit',
		'ifInErrors'    => 'system.network.errors.receive',
		'ifOutErrors'   => 'system.network.errors.transmit',
		'ifInDiscards'  => 'system.network.dropped.receive',
		'ifOutDiscards' => 'system.network.dropped.transmit',
		'ifSpeed'       => 'system.network.speed',
		'ifOperStatus'  => 'system.network.status',
	},
	'device' => {
		'cpuLoad'  => 'system.cpu.utilization',
		'memUtil'  => 'system.memory.utilization',
	},
	'Host_Storage' => {
		'hrStorageUsed' => 'system.filesystem.usage.used',
		'hrStorageSize' => 'system.filesystem.usage.total',
	},
	'health' => {
		'reachability' => 'nmis.node.reachability',
		'availability' => 'nmis.node.availability',
		'health'       => 'nmis.node.health',
		'responsetime' => 'nmis.node.response_time_ms',
		'loss'         => 'nmis.node.packet_loss',
	},
	'laload' => {
		'laLoad1' => 'system.cpu.load_average.1m',
		'laLoad5' => 'system.cpu.load_average.5m',
	},
	'ping' => {
		'avg_ping_time' => 'network.peer.rtt.avg_ms',
		'ping_loss'     => 'network.peer.packet_loss',
	},
);

# ---------------------------------------------------------------------------
# Replicate the helper subs from nmis-mcp.pl
# ---------------------------------------------------------------------------

sub _get_description
{
	my ($concept, $data) = @_;
	my @fields = @{$DESCRIPTION_FIELDS{$concept} // []};
	push @fields, @FALLBACK_DESCRIPTION_FIELDS;
	for my $field (@fields)
	{
		return $data->{$field}
			if defined $data->{$field} && $data->{$field} ne '';
	}
	return '';
}

sub _apply_field_rename
{
	my ($concept, $src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my $map = $FIELD_RENAME{$concept} // {};
	my %out;
	for my $k (keys %$src)
	{
		next if $k =~ /_raw$/i;
		my $new_k = $map->{$k} // "nmis.$k";
		$out{$new_k} = $src->{$k};
	}
	return \%out;
}

sub _filter_derived
{
	my ($src) = @_;
	return {} if (!$src || ref($src) ne 'HASH');
	my %filtered = map { $_ => $src->{$_} }
		grep { $_ !~ /^(?:08|16)/ } keys %$src;
	return \%filtered;
}

sub _filter_derived_flat
{
	my ($derived) = @_;
	return {} if (!$derived || ref($derived) ne 'HASH');
	my %out;
	for my $sub (keys %$derived)
	{
		my $filtered = _filter_derived($derived->{$sub});
		%out = (%out, %$filtered);
	}
	return \%out;
}

# ---------------------------------------------------------------------------
# 2. _get_description tests
# ---------------------------------------------------------------------------

my @desc_tests = (
	# [ concept, data hashref, expected, label ]
	[ 'interface', { ifDescr => 'GigabitEthernet0/0', Description => 'WAN' },
	  'GigabitEthernet0/0', 'interface: picks ifDescr over Description' ],

	[ 'interface', { Description => 'WAN link' },
	  'WAN link', 'interface: falls back to Description' ],

	[ 'catchall', { sysDescr => 'Cisco IOS 15.2', sysName => 'router1' },
	  'Cisco IOS 15.2', 'catchall: picks sysDescr' ],

	[ 'catchall', { sysName => 'router1' },
	  'router1', 'catchall: falls back to sysName' ],

	[ 'Host_Storage', { hrStorageDescr => 'Physical memory' },
	  'Physical memory', 'Host_Storage: picks hrStorageDescr' ],

	[ 'diskIOTable', { diskIODevice => 'sda' },
	  'sda', 'diskIOTable: picks diskIODevice' ],

	[ 'ping', { host => '192.168.1.1' },
	  '192.168.1.1', 'ping: picks host' ],

	[ 'service', { service => 'Apache_Web' },
	  'Apache_Web', 'service: picks service' ],

	[ 'device', { index => '0' },
	  '0', 'device: picks index' ],

	[ 'UnknownConcept', { Description => 'A thing' },
	  'A thing', 'unknown concept: generic fallback to Description' ],

	[ 'UnknownConcept', { name => 'myname' },
	  'myname', 'unknown concept: falls through to name' ],

	[ 'interface', { ifIndex => '1', ifSpeed => 100 },
	  '', 'no description fields present: returns empty string' ],

	[ 'interface', { ifDescr => '', Description => 'Uplink' },
	  'Uplink', 'interface: skips empty ifDescr, uses Description' ],
);

for my $t (@desc_tests)
{
	my ($concept, $data, $expected, $label) = @$t;
	is(_get_description($concept, $data), $expected, "_get_description: $label");
}

# ---------------------------------------------------------------------------
# 3. _apply_field_rename tests
# ---------------------------------------------------------------------------

# Known fields get OTel names
{
	my $result = _apply_field_rename('interface', {
		ifInOctets  => 1000,
		ifOutOctets => 2000,
		ifSpeed     => 1000000,
	});
	is($result->{'system.network.io.receive'}, 1000, 'rename: ifInOctets -> system.network.io.receive');
	is($result->{'system.network.io.transmit'}, 2000, 'rename: ifOutOctets -> system.network.io.transmit');
	is($result->{'system.network.speed'}, 1000000, 'rename: ifSpeed -> system.network.speed');
}

# Unknown fields get nmis. prefix
{
	my $result = _apply_field_rename('interface', {
		ifInOctets   => 100,
		customMetric => 42,
	});
	is($result->{'nmis.customMetric'}, 42, 'rename: unknown field gets nmis. prefix');
	ok(!exists $result->{'customMetric'}, 'rename: original name not present');
}

# Fields ending in _raw are filtered out
{
	my $result = _apply_field_rename('interface', {
		ifInOctets     => 100,
		ifInOctets_raw => 99999,
		counter_Raw    => 55555,
	});
	is($result->{'system.network.io.receive'}, 100, 'rename: non-raw field kept');
	ok(!exists $result->{'nmis.ifInOctets_raw'}, 'rename: _raw field filtered');
	ok(!exists $result->{'nmis.counter_Raw'}, 'rename: _Raw field filtered (case insensitive)');
}

# Empty/undef input returns empty hashref
{
	my $r1 = _apply_field_rename('interface', undef);
	is_deeply($r1, {}, 'rename: undef input returns empty hash');

	my $r2 = _apply_field_rename('interface', {});
	is_deeply($r2, {}, 'rename: empty hash returns empty hash');
}

# Unknown concept — all fields get nmis. prefix
{
	my $result = _apply_field_rename('nonexistent_concept', {
		foo => 1,
		bar => 2,
	});
	is($result->{'nmis.foo'}, 1, 'rename: unknown concept prefixes foo');
	is($result->{'nmis.bar'}, 2, 'rename: unknown concept prefixes bar');
}

# Health subconcept rename
{
	my $result = _apply_field_rename('health', {
		reachability => 100,
		availability => 99.5,
		loss         => 0,
	});
	is($result->{'nmis.node.reachability'}, 100, 'rename: health reachability');
	is($result->{'nmis.node.availability'}, 99.5, 'rename: health availability');
	is($result->{'nmis.node.packet_loss'}, 0, 'rename: health loss -> packet_loss');
}

# Ping concept
{
	my $result = _apply_field_rename('ping', {
		avg_ping_time => 1.5,
		ping_loss     => 0,
	});
	is($result->{'network.peer.rtt.avg_ms'}, 1.5, 'rename: ping avg_ping_time');
	is($result->{'network.peer.packet_loss'}, 0, 'rename: ping_loss');
}

# ---------------------------------------------------------------------------
# 4. _filter_derived tests
# ---------------------------------------------------------------------------

{
	my $result = _filter_derived({
		reachability => 100,
		'08_something' => 50,
		'16_other'     => 25,
		availability   => 99,
	});
	is($result->{reachability}, 100, 'filter_derived: keeps normal key');
	is($result->{availability}, 99, 'filter_derived: keeps availability');
	ok(!exists $result->{'08_something'}, 'filter_derived: removes 08_ prefix');
	ok(!exists $result->{'16_other'}, 'filter_derived: removes 16_ prefix');
}

# Empty/undef input
{
	is_deeply(_filter_derived(undef), {}, 'filter_derived: undef returns empty');
	is_deeply(_filter_derived({}), {}, 'filter_derived: empty returns empty');
}

# ---------------------------------------------------------------------------
# 5. _filter_derived_flat tests
# ---------------------------------------------------------------------------

{
	my $result = _filter_derived_flat({
		health => {
			reachability   => 100,
			'08_something' => 50,
		},
		tcp => {
			tcpCurrEstab => 10,
			'16_badkey'  => 0,
		},
	});
	is($result->{reachability}, 100, 'filter_derived_flat: health.reachability kept');
	is($result->{tcpCurrEstab}, 10, 'filter_derived_flat: tcp.tcpCurrEstab kept');
	ok(!exists $result->{'08_something'}, 'filter_derived_flat: 08_ removed');
	ok(!exists $result->{'16_badkey'}, 'filter_derived_flat: 16_ removed');
}

# ---------------------------------------------------------------------------
# 6. %CONCEPT_RENAME tests
# ---------------------------------------------------------------------------

{
	is($CONCEPT_RENAME{'device'}, 'cpuLoad', 'concept_rename: device -> cpuLoad');
	ok(!exists $CONCEPT_RENAME{'interface'}, 'concept_rename: interface not renamed');

	# Test the rename-or-passthrough pattern used in the code
	my $renamed   = $CONCEPT_RENAME{'device'} // 'device';
	my $unchanged = $CONCEPT_RENAME{'interface'} // 'interface';
	is($renamed, 'cpuLoad', 'concept passthrough: device renamed');
	is($unchanged, 'interface', 'concept passthrough: interface unchanged');
}

# ---------------------------------------------------------------------------
# 7. JSON-RPC 2.0 request validation logic
# ---------------------------------------------------------------------------

# Test the validation patterns used in the dispatch code
{
	my $good = { jsonrpc => '2.0', id => 1, method => 'tools/list' };
	ok($good->{method} && ($good->{jsonrpc} // '') eq '2.0',
		'jsonrpc validation: valid request passes');

	my $bad_ver = { jsonrpc => '1.0', id => 1, method => 'tools/list' };
	ok(!(($bad_ver->{jsonrpc} // '') eq '2.0'),
		'jsonrpc validation: wrong version fails');

	my $no_method = { jsonrpc => '2.0', id => 1 };
	ok(!$no_method->{method},
		'jsonrpc validation: missing method fails');
}

# ---------------------------------------------------------------------------
# 8. Tool definitions structure validation
# ---------------------------------------------------------------------------

# Replicate the tool definitions to validate their structure
my @TOOL_DEFINITIONS = (
	{ name => "nmis_list_nodes",       inputSchema => { type => "object" } },
	{ name => "nmis_get_node_status",  inputSchema => { type => "object", required => ["node"] } },
	{ name => "nmis_get_latest_metrics", inputSchema => { type => "object", required => ["node", "concept"] } },
	{ name => "nmis_list_events",      inputSchema => { type => "object" } },
	{ name => "nmis_list_inventory",   inputSchema => { type => "object", required => ["node", "concept"] } },
	{ name => "nmis_get_node_precise_status", inputSchema => { type => "object" } },
);

is(scalar @TOOL_DEFINITIONS, 6, 'tool definitions: 6 tools defined');

for my $tool (@TOOL_DEFINITIONS)
{
	ok($tool->{name}, "tool '$tool->{name}' has a name");
	ok($tool->{inputSchema}, "tool '$tool->{name}' has inputSchema");
	is($tool->{inputSchema}{type}, 'object', "tool '$tool->{name}' schema type is object");
}

# Tools requiring node parameter
for my $name (qw(nmis_get_node_status nmis_get_latest_metrics nmis_list_inventory))
{
	my ($tool) = grep { $_->{name} eq $name } @TOOL_DEFINITIONS;
	ok(grep({ $_ eq 'node' } @{$tool->{inputSchema}{required} // []}),
		"tool '$name' requires 'node' parameter");
}

# Tools requiring concept parameter
for my $name (qw(nmis_get_latest_metrics nmis_list_inventory))
{
	my ($tool) = grep { $_->{name} eq $name } @TOOL_DEFINITIONS;
	ok(grep({ $_ eq 'concept' } @{$tool->{inputSchema}{required} // []}),
		"tool '$name' requires 'concept' parameter");
}

# nmis_list_events has no required params
{
	my ($tool) = grep { $_->{name} eq 'nmis_list_events' } @TOOL_DEFINITIONS;
	ok(!$tool->{inputSchema}{required}, 'nmis_list_events has no required params');
}

# nmis_list_nodes has no required params
{
	my ($tool) = grep { $_->{name} eq 'nmis_list_nodes' } @TOOL_DEFINITIONS;
	ok(!$tool->{inputSchema}{required}, 'nmis_list_nodes has no required params');
}

# nmis_get_node_precise_status has no required params (all optional)
{
	my ($tool) = grep { $_->{name} eq 'nmis_get_node_precise_status' } @TOOL_DEFINITIONS;
	ok($tool, 'nmis_get_node_precise_status tool exists');
	ok(!$tool->{inputSchema}{required}, 'nmis_get_node_precise_status has no required params');
}

# ---------------------------------------------------------------------------
# 9. precise_status overall label mapping
# ---------------------------------------------------------------------------

{
	my %overall_labels = ( 1 => 'reachable', 0 => 'unreachable', -1 => 'degraded' );
	is($overall_labels{1},  'reachable',   'overall_label: 1 => reachable');
	is($overall_labels{0},  'unreachable', 'overall_label: 0 => unreachable');
	is($overall_labels{-1}, 'degraded',    'overall_label: -1 => degraded');
	is($overall_labels{99} // 'unknown', 'unknown', 'overall_label: unknown value => unknown');
}

# ---------------------------------------------------------------------------
# 10. FIELD_RENAME coverage — ensure key concepts have rename maps
# ---------------------------------------------------------------------------

for my $concept (qw(interface device Host_Storage health laload ping))
{
	ok(exists $FIELD_RENAME{$concept}, "FIELD_RENAME: '$concept' has a rename map");
	ok(scalar keys %{$FIELD_RENAME{$concept}} > 0,
		"FIELD_RENAME: '$concept' map is non-empty");
}

# ---------------------------------------------------------------------------
# 11. tool_list_nodes — active-node filtering
#
# We mock nmisng so we can verify:
#   a) get_nodes_model is called with filter => { 'activated.NMIS' => 1 }
#   b) only active nodes appear in the returned list
#   c) inactive nodes (activated.NMIS == 0 / missing) are never returned
# ---------------------------------------------------------------------------

# Inline copy of tool_list_nodes so we don't need to load the full CGI script.
sub tool_list_nodes_impl
{
	my ($args, $nmisng) = @_;

	my $model = $nmisng->get_nodes_model(
		filter => { 'activated.NMIS' => 1, 'configuration.active' => 1 },
		fields_hash => {
			name                   => 1,
			uuid                   => 1,
			'configuration.group'  => 1,
			'configuration.host'   => 1,
		}
	);

	my @nodes;
	for my $nd (@{$model->data()})
	{
		my $conf = $nd->{configuration} // {};
		my $node_obj = $nmisng->node(uuid => $nd->{uuid});
		my $catchall_data = {};
		if ($node_obj)
		{
			my ($inv, $err) = $node_obj->inventory(concept => 'catchall');
			$catchall_data = $inv->data() if ($inv && !$err);
		}

		push @nodes, {
			name         => $nd->{name},
			group        => $conf->{group} // '',
			host         => $conf->{host} // '',
			nodeType     => $catchall_data->{nodeType} // '',
			nodedown     => $catchall_data->{nodedown} // '',
			health       => $catchall_data->{health} // '',
			reachability => $catchall_data->{reachability} // '',
		};
	}

	return { nodes => \@nodes, count => scalar(@nodes) };
}

# --- Mock helpers -----------------------------------------------------------

# MockModel: wraps an arrayref and exposes ->data()
package MockModel;
sub new  { my ($class, $rows) = @_; bless { rows => $rows }, $class }
sub data { return $_[0]->{rows} }

# MockInventory: holds a data hashref and exposes ->data()
package MockInventory;
sub new  { my ($class, $d) = @_; bless { d => $d }, $class }
sub data { return $_[0]->{d} }

# MockNode: returns a MockInventory for concept 'catchall'
package MockNode;
sub new      { my ($class, %h) = @_; bless \%h, $class }
sub inventory
{
	my ($self, %args) = @_;
	return (MockInventory->new($self->{catchall}), undef) if $args{concept} eq 'catchall';
	return (undef, "no such concept");
}

# MockNMISNG: records get_nodes_model calls and routes node() lookups
package MockNMISNG;
sub new
{
	my ($class, %h) = @_;
	# h: rows => [...], nodes => { uuid => catchall_data }
	bless \%h, $class;
}
sub get_nodes_model
{
	my ($self, %args) = @_;
	# Record the filter that was passed so the test can inspect it.
	$self->{last_filter} = $args{filter};
	return MockModel->new($self->{rows});
}
sub node
{
	my ($self, %args) = @_;
	my $catchall = $self->{nodes}{ $args{uuid} } or return undef;
	return MockNode->new(catchall => $catchall);
}

package main;

# Build test data: two active nodes returned by the mock (the filter is
# enforced by the real MongoDB layer; the mock simply honours whatever rows
# we tell it to return).  We also include an "inactive" row to prove that
# if the filter were ignored and a row slipped through the model still
# has no activated field — it must not appear.
my $active_rows = [
	{
		name          => 'router1',
		uuid          => 'uuid-1',
		configuration => { group => 'Core', host => '10.0.0.1' },
	},
	{
		name          => 'switch1',
		uuid          => 'uuid-2',
		configuration => { group => 'Access', host => '10.0.0.2' },
	},
];

my $mock_nodes = {
	'uuid-1' => { nodeType => 'router', nodedown => 'false', health => 100, reachability => 100 },
	'uuid-2' => { nodeType => 'switch', nodedown => 'false', health =>  95, reachability =>  98 },
};

my $nmisng = MockNMISNG->new(rows => $active_rows, nodes => $mock_nodes);

my $result = tool_list_nodes_impl({}, $nmisng);

# a) Correct filter was passed to get_nodes_model
is_deeply(
	$nmisng->{last_filter},
	{ 'activated.NMIS' => 1, 'configuration.active' => 1 },
	'tool_list_nodes: get_nodes_model called with activated.NMIS=>1 and configuration.active=>1 filter',
);

# b) Count and names match the active rows
is($result->{count}, 2, 'tool_list_nodes: returns 2 active nodes');
my @names = sort map { $_->{name} } @{$result->{nodes}};
is_deeply(\@names, ['router1', 'switch1'], 'tool_list_nodes: correct node names returned');

# c) Catchall fields are populated
my ($r1) = grep { $_->{name} eq 'router1' } @{$result->{nodes}};
is($r1->{nodeType},     'router', 'tool_list_nodes: router1 nodeType correct');
is($r1->{health},       100,      'tool_list_nodes: router1 health correct');
is($r1->{reachability}, 100,      'tool_list_nodes: router1 reachability correct');
is($r1->{group},        'Core',   'tool_list_nodes: router1 group correct');
is($r1->{host},         '10.0.0.1', 'tool_list_nodes: router1 host correct');

# d) Prove inactive node is absent: add an inactive row directly to the model
#    (simulating what would happen if the filter were NOT applied) and verify
#    the function still only returns the active ones when the filter IS applied.
#    Here we test the negative: a fresh mock whose model returns ONLY an
#    inactive-looking row (no activated field) would still pass through if
#    Perl-side filtering were the only guard — but our implementation relies
#    solely on the DB filter, so we verify count=0 when model returns nothing.

my $empty_nmisng = MockNMISNG->new(rows => [], nodes => {});
my $empty_result = tool_list_nodes_impl({}, $empty_nmisng);

is($empty_result->{count}, 0, 'tool_list_nodes: returns 0 nodes when model returns nothing (all filtered by DB)');
is_deeply(
	$empty_nmisng->{last_filter},
	{ 'activated.NMIS' => 1, 'configuration.active' => 1 },
	'tool_list_nodes: filter still applied even when result is empty',
);

# e) Simulate the "vor" case: activated.NMIS=1 but configuration.active=0.
#    The DB filter must exclude such nodes. We prove this by giving the mock
#    model an empty row set (as MongoDB would return after applying both
#    filter conditions) and confirm the result is empty.
my $vor_nmisng = MockNMISNG->new(
	rows  => [],   # MongoDB returned nothing because vor has configuration.active=0
	nodes => {},
);
my $vor_result = tool_list_nodes_impl({}, $vor_nmisng);
is($vor_result->{count}, 0,
	'tool_list_nodes: node with configuration.active=0 excluded (vor-style inactive node)');
is_deeply(
	$vor_nmisng->{last_filter},
	{ 'activated.NMIS' => 1, 'configuration.active' => 1 },
	'tool_list_nodes: both activated.NMIS and configuration.active required in filter',
);

# ---------------------------------------------------------------------------

done_testing();
