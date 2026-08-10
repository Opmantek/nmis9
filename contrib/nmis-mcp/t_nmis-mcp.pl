#!/usr/bin/perl
#
# Tests for the NMIS9 MCP (Model Context Protocol) server.
#
# Run from the contrib/nmis-mcp/ directory:
#   perl t_nmis-mcp.pl
#
# These tests exercise the REAL code, not copies:
#   * the OTel helpers/maps come from NMISNG::OTel (the shared module);
#   * the tool tables and tool_list_nodes come from nmis-mcp.pl itself,
#     loaded via require (its runtime is guarded by `unless (caller)`, so
#     requiring it does not start the CGI).
#
# The OTel helper tests need no live NMIS install. The require-based tests
# pull in the NMIS library stack (NMISNG::Util, Compat::NMIS, ...); if those
# modules are not available they are skipped rather than failing.
#
use strict;
use warnings;

use lib "/usr/local/nmis9/lib";

use Test::More;
use JSON::XS;

# ---------------------------------------------------------------------------
# 1. Load the shared OTel module (the single source of truth for the maps and
#    helpers that the MCP server and the mqttobservations plugin both use).
# ---------------------------------------------------------------------------

use NMISNG::OTel qw(apply_field_rename filter_derived filter_derived_flat get_description unweight_health %HEALTH_WEIGHT);

# ---------------------------------------------------------------------------
# 2. get_description tests
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
	is(get_description($concept, $data), $expected, "get_description: $label");
}

# ---------------------------------------------------------------------------
# 3. apply_field_rename tests
# ---------------------------------------------------------------------------

# Known fields get OTel names
{
	my $result = apply_field_rename('interface', {
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
	my $result = apply_field_rename('interface', {
		ifInOctets   => 100,
		customMetric => 42,
	});
	is($result->{'nmis.customMetric'}, 42, 'rename: unknown field gets nmis. prefix');
	ok(!exists $result->{'customMetric'}, 'rename: original name not present');
}

# Fields ending in _raw are filtered out
{
	my $result = apply_field_rename('interface', {
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
	my $r1 = apply_field_rename('interface', undef);
	is_deeply($r1, {}, 'rename: undef input returns empty hash');

	my $r2 = apply_field_rename('interface', {});
	is_deeply($r2, {}, 'rename: empty hash returns empty hash');
}

# Unknown concept — all fields get nmis. prefix
{
	my $result = apply_field_rename('nonexistent_concept', {
		foo => 1,
		bar => 2,
	});
	is($result->{'nmis.foo'}, 1, 'rename: unknown concept prefixes foo');
	is($result->{'nmis.bar'}, 2, 'rename: unknown concept prefixes bar');
}

# Health subconcept rename
{
	my $result = apply_field_rename('health', {
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
	my $result = apply_field_rename('ping', {
		avg_ping_time => 1.5,
		ping_loss     => 0,
	});
	is($result->{'network.peer.rtt.avg_ms'}, 1.5, 'rename: ping avg_ping_time');
	is($result->{'network.peer.packet_loss'}, 0, 'rename: ping_loss');
}

# ---------------------------------------------------------------------------
# unweight_health: turn weighted health contributions back into 0-100 percentages
# ---------------------------------------------------------------------------
{
	my %weights = (
		weight_reachability => 0.1,
		weight_availability => 0.1,
		weight_response     => 0.2,
		weight_cpu          => 0.2,
		weight_mem          => 0.1,
		weight_int          => 0.3,
	);

	# no swap/disk: each field divides straight back out by its weight
	my $r = unweight_health({
		reachabilityHealth => 10,     # 100 * 0.1
		availabilityHealth => 9.95,   # 99.5 * 0.1
		responseHealth     => 20,     # 100 * 0.2
		cpuHealth          => 17,     # 85  * 0.2
		memHealth          => 10,     # 100 * 0.1
		intHealth          => 30,     # 100 * 0.3
		swapHealth         => 0,
		diskHealth         => 0,
	}, \%weights);
	is($r->{reachabilityHealth}, 100,  'unweight: reachability 10 -> 100');
	is($r->{availabilityHealth}, 99.5, 'unweight: availability 9.95 -> 99.5');
	is($r->{responseHealth},     100,  'unweight: response 20 -> 100');
	is($r->{cpuHealth},          85,   'unweight: cpu 17 -> 85');
	is($r->{memHealth},          100,  'unweight: mem 10 -> 100');
	is($r->{intHealth},          100,  'unweight: int 30 -> 100');
	is($r->{swapHealth},         0,    'unweight: swap stays 0');

	# swap present -> weight_mem is split in half across mem+swap
	my $s = unweight_health({
		memHealth  => 3.5,   # 70 * (0.1/2)
		swapHealth => 4.5,   # 90 * (0.1/2)
	}, \%weights);
	is($s->{memHealth},  70, 'unweight: mem recovers with halved weight_mem');
	is($s->{swapHealth}, 90, 'unweight: swap recovers with halved weight_mem');

	# disk present -> weight_int is split in half across int+disk
	my $d = unweight_health({
		intHealth  => 12,   # 80 * (0.3/2)
		diskHealth => 9,    # 60 * (0.3/2)
	}, \%weights);
	is($d->{intHealth},  80, 'unweight: int recovers with halved weight_int');
	is($d->{diskHealth}, 60, 'unweight: disk recovers with halved weight_int');

	# non-numeric ("U") and unweighted fields pass through untouched
	my $u = unweight_health({
		cpuHealth    => 'U',
		reachability => 100,
		health       => 42,
	}, \%weights);
	is($u->{cpuHealth},    'U', 'unweight: non-numeric U left as-is');
	is($u->{reachability}, 100, 'unweight: non-*Health field untouched');
	is($u->{health},       42,  'unweight: overall health field untouched');

	# missing weight -> value left unchanged rather than divided by zero
	my $n = unweight_health({ cpuHealth => 17 }, {});
	is($n->{cpuHealth}, 17, 'unweight: no weight configured leaves value as-is');

	# A real record, captured from a live SNMP-polled node (sol.packsin.com)
	# with the default weights above and disk collection active, so weight_int
	# is split across int+disk. Anchors the rescale to observed production data
	# rather than only to constructed cases.
	#
	# The node's actual state at capture: CPU ~3% utilised (scores 100),
	# 23% memory free (scores 60), mean disk utilisation ~25% (scores 80).
	# Note these are health scores, not utilisation -- 100 is healthiest.
	my $live = unweight_health({
		reachabilityHealth => 10,
		availabilityHealth => 3.158,
		responseHealth     => 20,
		cpuHealth          => 20,
		memHealth          => 6,
		swapHealth         => 0,
		intHealth          => 15,
		diskHealth         => 12,
	}, \%weights);
	is($live->{reachabilityHealth}, 100,   'live record: reachability 10 -> 100');
	is($live->{availabilityHealth}, 31.58, 'live record: availability 3.158 -> 31.58');
	is($live->{responseHealth},     100,   'live record: response 20 -> 100');
	is($live->{cpuHealth},          100,   'live record: idle cpu 20 -> 100');
	is($live->{memHealth},          60,    'live record: mem 6 -> 60 (swap inactive, full weight_mem)');
	is($live->{swapHealth},         0,     'live record: inactive swap stays 0');
	is($live->{intHealth},          100,   'live record: int 15 -> 100 (disk active, halved weight_int)');
	is($live->{diskHealth},         80,    'live record: disk 12 -> 80 (halved weight_int)');
	ok(!grep { ($live->{$_} // 0) < 0 || ($live->{$_} // 0) > 100 } keys %HEALTH_WEIGHT,
		'live record: every rescaled value lands within 0-100');

	# Invariant worth pinning: compute_reachability derives reachabilityHealth
	# and availabilityHealth straight from the reachability/availability
	# percentages (value * weight), so after rescaling each must equal the
	# plain field sitting next to it in the same record. If the weight map or
	# the division ever drifts, these two diverge before anything else does.
	{
		my $rec = { reachability => 100, availability => 31.58,
		            reachabilityHealth => 100 * $weights{weight_reachability},
		            availabilityHealth => 31.58 * $weights{weight_availability} };
		my $inv = unweight_health($rec, \%weights);
		is($inv->{reachabilityHealth}, $inv->{reachability},
			'invariant: rescaled reachabilityHealth == reachability');
		is($inv->{availabilityHealth}, $inv->{availability},
			'invariant: rescaled availabilityHealth == availability');
	}

	# Round-trip against the real formula: reproduce what compute_reachability()
	# in NMISNG::Node stores, then assert unweight_health inverts it exactly.
	# This is what pins the rescale to the upstream maths rather than to
	# hand-computed constants.
	for my $pct (0.5, 37, 85, 99.5, 100)
	{
		# plain case: stored = pct * weight
		my $plain = unweight_health({
			cpuHealth  => $pct * $weights{weight_cpu},
			intHealth  => $pct * $weights{weight_int},
			swapHealth => 0,
			diskHealth => 0,
		}, \%weights);
		is($plain->{cpuHealth}, $pct, "round-trip: cpu $pct% survives weighting");
		is($plain->{intHealth}, $pct, "round-trip: int $pct% survives weighting");

		# shared-weight case: when the partner metric is active NMIS halves both
		# shares (weight/2), so the inverse must use the halved weight too.
		my $split = unweight_health({
			memHealth  => $pct * ($weights{weight_mem} / 2),
			swapHealth => $pct * ($weights{weight_mem} / 2),
			intHealth  => $pct * ($weights{weight_int} / 2),
			diskHealth => $pct * ($weights{weight_int} / 2),
		}, \%weights);
		is($split->{memHealth},  $pct, "round-trip: mem $pct% survives halved weight_mem");
		is($split->{swapHealth}, $pct, "round-trip: swap $pct% survives halved weight_mem");
		is($split->{intHealth},  $pct, "round-trip: int $pct% survives halved weight_int");
		is($split->{diskHealth}, $pct, "round-trip: disk $pct% survives halved weight_int");
	}
}

# ---------------------------------------------------------------------------
# 3b. %HEALTH_WEIGHT must name weights that actually exist in the shipped
#     config. unweight_health skips any field whose weight key is missing
#     (`next if !$weight`), so a typo'd or renamed key would silently stop the
#     rescale and republish the weighted numbers with no error anywhere.
# ---------------------------------------------------------------------------
{
	my $default_config = "$FindBin::Bin/../../conf-default/Config.nmis";

	SKIP: {
		skip "conf-default/Config.nmis not found", 1 if (!-r $default_config);

		open(my $fh, '<', $default_config) or skip "cannot read $default_config", 1;
		my %shipped;
		while (my $line = <$fh>)
		{
			$shipped{$1} = 1 while $line =~ /'(weight_\w+)'\s*=>/g;
		}
		close($fh);

		my @missing = sort grep { !$shipped{$_} } keys %{{ map { $_ => 1 } values %HEALTH_WEIGHT }};
		is_deeply(\@missing, [],
			'every %HEALTH_WEIGHT key exists in conf-default/Config.nmis')
			or diag("weight keys not present in shipped config: @missing");
	}
}

# ---------------------------------------------------------------------------
# 4. filter_derived tests
# ---------------------------------------------------------------------------

{
	my $result = filter_derived({
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
	is_deeply(filter_derived(undef), {}, 'filter_derived: undef returns empty');
	is_deeply(filter_derived({}), {}, 'filter_derived: empty returns empty');
}

# ---------------------------------------------------------------------------
# 5. filter_derived_flat tests
# ---------------------------------------------------------------------------

{
	my $result = filter_derived_flat({
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
# 6. %CONCEPT_RENAME and %FIELD_RENAME coverage (real module maps)
# ---------------------------------------------------------------------------

{
	is($NMISNG::OTel::CONCEPT_RENAME{'device'}, 'cpuLoad', 'concept_rename: device -> cpuLoad');
	ok(!exists $NMISNG::OTel::CONCEPT_RENAME{'interface'}, 'concept_rename: interface not renamed');
}

for my $concept (qw(interface device Host_Storage health laload ping))
{
	ok(exists $NMISNG::OTel::FIELD_RENAME{$concept}, "FIELD_RENAME: '$concept' has a rename map");
	ok(scalar keys %{$NMISNG::OTel::FIELD_RENAME{$concept}} > 0,
		"FIELD_RENAME: '$concept' map is non-empty");
}

# ---------------------------------------------------------------------------
# 7. precise_status overall label mapping
# ---------------------------------------------------------------------------

{
	my %overall_labels = ( 1 => 'reachable', 0 => 'unreachable', -1 => 'degraded' );
	is($overall_labels{1},  'reachable',   'overall_label: 1 => reachable');
	is($overall_labels{0},  'unreachable', 'overall_label: 0 => unreachable');
	is($overall_labels{-1}, 'degraded',    'overall_label: -1 => degraded');
	is($overall_labels{99} // 'unknown', 'unknown', 'overall_label: unknown value => unknown');
}

# ---------------------------------------------------------------------------
# 8. Load the REAL nmis-mcp.pl and test its tool tables + tool_list_nodes.
#    Its runtime is guarded by `unless (caller)`, so require() defines the
#    subs and package tables without starting the CGI.
# ---------------------------------------------------------------------------

use FindBin;
my $server_script = "$FindBin::Bin/nmis-mcp.pl";

my $loaded = eval { require $server_script; 1 };
if (!$loaded)
{
	diag("Skipping server-code tests — could not load $server_script: $@");
}

SKIP: {
	skip("nmis-mcp.pl (and its NMIS library deps) not loadable in this environment", 20)
		unless $loaded;

	# --- Tool tables are the real ones from the script -----------------------
	no warnings 'once';
	my @defs     = @main::TOOL_DEFINITIONS;
	my %handlers = %main::TOOL_HANDLERS;

	is(scalar @defs, 6, 'tool definitions: 6 tools defined');

	my %expected_required = (
		nmis_get_node_status    => ['node'],
		nmis_get_latest_metrics => ['node', 'concept'],
		nmis_list_inventory     => ['node', 'concept'],
	);

	for my $tool (@defs)
	{
		ok($tool->{name}, "tool '$tool->{name}' has a name");
		is($tool->{inputSchema}{type}, 'object', "tool '$tool->{name}' schema type is object");
		ok(!exists $tool->{handler}, "tool '$tool->{name}' definition does not leak its handler coderef");
		ok(ref($handlers{$tool->{name}}) eq 'CODE', "tool '$tool->{name}' has a dispatch handler");

		if (my $req = $expected_required{$tool->{name}})
		{
			is_deeply([sort @{$tool->{inputSchema}{required}}], [sort @$req],
				"tool '$tool->{name}' requires @$req");
		}
	}

	# nmis_list_nodes / nmis_list_events / nmis_get_node_precise_status: no required params
	for my $name (qw(nmis_list_nodes nmis_list_events nmis_get_node_precise_status))
	{
		my ($tool) = grep { $_->{name} eq $name } @defs;
		ok(!$tool->{inputSchema}{required}, "$name has no required params");
	}

	# Every handler name in the map corresponds to a defined tool
	is_deeply([sort keys %handlers], [sort map { $_->{name} } @defs],
		'handler map keys match tool definition names');

	# --- Exercise the real tool_list_nodes against mock nmisng ---------------
	# It should: pass the active-node filter to get_nodes_model, issue ONE
	# batched catchall query, and join the two by node_uuid.
	my $nmisng = MockNMISNG->new(
		rows => [
			{ name => 'router1', uuid => 'uuid-1', configuration => { group => 'Core',   host => '10.0.0.1' } },
			{ name => 'switch1', uuid => 'uuid-2', configuration => { group => 'Access', host => '10.0.0.2' } },
		],
		catchall => {
			'uuid-1' => { nodeType => 'router', nodedown => 'false', health => 100, reachability => 100 },
			'uuid-2' => { nodeType => 'switch', nodedown => 'false', health =>  95, reachability =>  98 },
		},
	);

	my $result = main::tool_list_nodes({}, $nmisng);

	is_deeply(
		$nmisng->{last_nodes_filter},
		{ 'activated.NMIS' => 1, 'configuration.active' => 1 },
		'tool_list_nodes: get_nodes_model called with active-node filter',
	);
	is($nmisng->{inventory_calls}, 1, 'tool_list_nodes: exactly ONE batched catchall query (no per-node N+1)');
	is($nmisng->{last_inventory_concept}, 'catchall', 'tool_list_nodes: batched query is for the catchall concept');

	is($result->{count}, 2, 'tool_list_nodes: returns 2 nodes');
	my ($r1) = grep { $_->{name} eq 'router1' } @{$result->{nodes}};
	is($r1->{nodeType},     'router',   'tool_list_nodes: router1 nodeType joined from catchall');
	is($r1->{health},       100,        'tool_list_nodes: router1 health joined from catchall');
	is($r1->{reachability}, 100,        'tool_list_nodes: router1 reachability joined from catchall');
	is($r1->{group},        'Core',     'tool_list_nodes: router1 group from node config');
	is($r1->{host},         '10.0.0.1', 'tool_list_nodes: router1 host from node config');

	# A node with no catchall inventory still appears, with blank derived fields.
	my $nmisng2 = MockNMISNG->new(
		rows     => [ { name => 'lonely', uuid => 'uuid-x', configuration => { group => 'G', host => 'h' } } ],
		catchall => {},   # batched catchall returns nothing
	);
	my $res2 = main::tool_list_nodes({}, $nmisng2);
	is($res2->{count}, 1, 'tool_list_nodes: node with no catchall still listed');
	is($res2->{nodes}[0]{nodeType}, '', 'tool_list_nodes: missing catchall -> empty nodeType');
}

done_testing();

# ---------------------------------------------------------------------------
# Mock objects for the tool_list_nodes test
# ---------------------------------------------------------------------------

# MockModel: wraps an arrayref, exposes ->data() and ->error()
package MockModel;
sub new   { my ($class, $rows) = @_; bless { rows => $rows }, $class }
sub data  { return $_[0]->{rows} }
sub error { return undef }

# MockNMISNG: records the get_nodes_model filter and the batched catchall query,
# and returns catchall inventory docs keyed by node_uuid.
package MockNMISNG;
sub new
{
	my ($class, %h) = @_;
	bless {
		rows              => $h{rows}     // [],
		catchall          => $h{catchall} // {},
		inventory_calls   => 0,
	}, $class;
}

sub get_nodes_model
{
	my ($self, %args) = @_;
	$self->{last_nodes_filter} = $args{filter};
	return MockModel->new($self->{rows});
}

sub get_inventory_model
{
	my ($self, %args) = @_;
	$self->{inventory_calls}++;
	$self->{last_inventory_concept} = $args{concept};
	my @docs = map { { node_uuid => $_, data => $self->{catchall}{$_} } }
		keys %{ $self->{catchall} };
	return MockModel->new(\@docs);
}
