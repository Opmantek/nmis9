#!/usr/bin/perl
#
#  Copyright (C) Keith Sinclair (https://github.com/kcsinclair/)
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# *****************************************************************************
#
# NMIS9 MCP (Model Context Protocol) Server
#
# Exposes NMIS monitoring data via the Model Context Protocol so that AI
# assistants can query node status, metrics, events, and inventory.
#
# Protocol: JSON-RPC 2.0 over HTTP POST (stateless)
# Endpoint: /cgi-nmis9/nmis-mcp.pl
# Auth:     Bearer token (conf/nmis-mcp.nmis) or NMIS cookie auth
#
# *****************************************************************************

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use CGI;
use JSON::XS;
use NMISNG::Util;
use NMISNG::Sys;
use NMISNG::Auth;
use Compat::NMIS;

my $VERSION = "1.0.0";

# ---------------------------------------------------------------------------
# OTel field rename maps and description fields (from mqttobservations.pm)
# ---------------------------------------------------------------------------

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
		'ifInOctets'        => 'system.network.io.receive',
		'ifOutOctets'       => 'system.network.io.transmit',
		'ifInUcastPkts'     => 'system.network.packets.receive',
		'ifOutUcastPkts'    => 'system.network.packets.transmit',
		'ifInErrors'        => 'system.network.errors.receive',
		'ifOutErrors'       => 'system.network.errors.transmit',
		'ifInDiscards'      => 'system.network.dropped.receive',
		'ifOutDiscards'     => 'system.network.dropped.transmit',
		'ifSpeed'           => 'system.network.speed',
		'ifOperStatus'      => 'system.network.status',
	},
	'device' => {
		'cpuLoad'           => 'system.cpu.utilization',
		'cpu1min'           => 'system.cpu.utilization.1m',
		'cpu5min'           => 'system.cpu.utilization.5m',
		'memUtil'           => 'system.memory.utilization',
		'memAvail'          => 'system.memory.usage.available',
	},
	'Host_Storage' => {
		'hrStorageUsed'            => 'system.filesystem.usage.used',
		'hrStorageSize'            => 'system.filesystem.usage.total',
		'hrStorageAllocationUnits' => 'system.filesystem.allocation_unit',
		'hrStorageType'            => 'system.filesystem.type',
	},
	'diskIOTable' => {
		'diskIOReads'       => 'system.disk.operations.read',
		'diskIOWrites'      => 'system.disk.operations.write',
		'diskIOReadBytes'   => 'system.disk.io.read',
		'diskIOWriteBytes'  => 'system.disk.io.write',
	},
	'health' => {
		'reachability'       => 'nmis.node.reachability',
		'availability'       => 'nmis.node.availability',
		'health'             => 'nmis.node.health',
		'responsetime'       => 'nmis.node.response_time_ms',
		'loss'               => 'nmis.node.packet_loss',
		'intfCollect'        => 'nmis.node.intf_collect',
		'intfColUp'          => 'nmis.node.intf_collect_up',
		'reachabilityHealth' => 'nmis.node.reachability_health',
		'availabilityHealth' => 'nmis.node.availability_health',
		'responseHealth'     => 'nmis.node.response_health',
		'cpuHealth'          => 'nmis.node.cpu_health',
		'memHealth'          => 'nmis.node.mem_health',
		'intHealth'          => 'nmis.node.int_health',
		'diskHealth'         => 'nmis.node.disk_health',
		'swapHealth'         => 'nmis.node.swap_health',
	},
	'Host_Health' => {
		'hrSystemProcesses' => 'system.process.count',
		'hrSystemNumUsers'  => 'system.users.count',
	},
	'laload' => {
		'laLoad1'           => 'system.cpu.load_average.1m',
		'laLoad5'           => 'system.cpu.load_average.5m',
	},
	'mib2ip' => {
		'ipInReceives'      => 'system.network.ip.in_receives',
		'ipInHdrErrors'     => 'system.network.ip.in_header_errors',
		'ipInAddrErrors'    => 'system.network.ip.in_address_errors',
		'ipForwDatagrams'   => 'system.network.ip.forwarded',
		'ipInUnknownProtos' => 'system.network.ip.in_unknown_protos',
		'ipInDiscards'      => 'system.network.ip.in_discards',
		'ipInDelivers'      => 'system.network.ip.in_delivers',
		'ipOutRequests'     => 'system.network.ip.out_requests',
		'ipOutDiscards'     => 'system.network.ip.out_discards',
		'ipReasmReqds'      => 'system.network.ip.reassembly_required',
		'ipReasmOKs'        => 'system.network.ip.reassembly_ok',
		'ipReasmFails'      => 'system.network.ip.reassembly_failed',
		'ipFragOKs'         => 'system.network.ip.fragmentation_ok',
		'ipFragCreates'     => 'system.network.ip.fragments_created',
		'ipFragFails'       => 'system.network.ip.fragmentation_failed',
	},
	'systemStats' => {
		'ssCpuRawUser'      => 'system.cpu.time.user',
		'ssCpuRawNice'      => 'system.cpu.time.nice',
		'ssCpuRawSystem'    => 'system.cpu.time.system',
		'ssCpuRawIdle'      => 'system.cpu.time.idle',
		'ssCpuRawWait'      => 'system.cpu.time.wait',
		'ssCpuRawKernel'    => 'system.cpu.time.kernel',
		'ssCpuRawInterrupt' => 'system.cpu.time.interrupt',
		'ssCpuRawSoftIRQ'   => 'system.cpu.time.soft_irq',
		'ssIORawSent'       => 'system.disk.io.sent',
		'ssIORawReceived'   => 'system.disk.io.received',
		'ssRawInterrupts'   => 'system.cpu.interrupts',
		'ssRawContexts'     => 'system.cpu.context_switches',
		'ssRawSwapIn'       => 'system.memory.swap.in',
		'ssRawSwapOut'      => 'system.memory.swap.out',
	},
	'tcp' => {
		'tcpActiveOpens'    => 'system.network.tcp.connections.opened.active',
		'tcpPassiveOpens'   => 'system.network.tcp.connections.opened.passive',
		'tcpAttemptFails'   => 'system.network.tcp.connections.failed',
		'tcpEstabResets'    => 'system.network.tcp.connections.reset',
		'tcpCurrEstab'      => 'system.network.tcp.connections.established',
		'tcpInSegs'         => 'system.network.tcp.segments.received',
		'tcpOutSegs'        => 'system.network.tcp.segments.sent',
		'tcpRetransSegs'    => 'system.network.tcp.segments.retransmitted',
		'tcpInErrs'         => 'system.network.tcp.errors.received',
		'tcpOutRsts'        => 'system.network.tcp.resets.sent',
	},
	'ping' => {
		'avg_ping_time'     => 'network.peer.rtt.avg_ms',
		'max_ping_time'     => 'network.peer.rtt.max_ms',
		'min_ping_time'     => 'network.peer.rtt.min_ms',
		'ping_loss'         => 'network.peer.packet_loss',
	},
);

# ---------------------------------------------------------------------------
# MCP tool definitions
# ---------------------------------------------------------------------------

my @TOOL_DEFINITIONS = (
	{
		name        => "nmis_list_nodes",
		description => "List all NMIS monitored nodes with basic status (name, group, type, host, health, reachability). Returns a summary for every node.",
		inputSchema => {
			type       => "object",
			properties => {},
		},
	},
	{
		name        => "nmis_get_node_status",
		description => "Get detailed status and health metrics for a specific NMIS node, including overall status (reachable/degraded/unreachable), reachability, availability, response time, system description, and uptime.",
		inputSchema => {
			type       => "object",
			properties => {
				node => { type => "string", description => "Node name (as shown in nmis_list_nodes)" },
			},
			required => ["node"],
		},
	},
	{
		name        => "nmis_get_latest_metrics",
		description => "Get the latest collected metrics for a node and concept. Metrics use OTel-inspired field names. For catchall/ping, returns per-subconcept results (health, tcp, laload, etc.). For interface, returns per-interface results.",
		inputSchema => {
			type       => "object",
			properties => {
				node    => { type => "string", description => "Node name" },
				concept => { type => "string", description => "Inventory concept: interface, catchall, device, Host_Storage, diskIOTable, env-temp, service, ping" },
			},
			required => ["node", "concept"],
		},
	},
	{
		name        => "nmis_list_events",
		description => "List active NMIS events and alerts. Optionally filter by node name.",
		inputSchema => {
			type       => "object",
			properties => {
				node => { type => "string", description => "Optional: filter events by node name" },
			},
		},
	},
	{
		name        => "nmis_list_inventory",
		description => "List inventory instances for a node and concept, showing index, description, and available data fields. Useful for discovering what instances exist before fetching metrics.",
		inputSchema => {
			type       => "object",
			properties => {
				node    => { type => "string", description => "Node name" },
				concept => { type => "string", description => "Inventory concept: interface, catchall, device, Host_Storage, diskIOTable, etc." },
			},
			required => ["node", "concept"],
		},
	},
	{
		name        => "nmis_get_node_precise_status",
		description => "Get precise reachability status for nodes. Returns overall status (reachable/degraded/unreachable), per-protocol status (SNMP, WMI, ping), failover state, uptime, and reachability. Query all nodes, a group, or a single node.",
		inputSchema => {
			type       => "object",
			properties => {
				node  => { type => "string", description => "Optional: specific node name" },
				group => { type => "string", description => "Optional: filter by node group" },
			},
		},
	},
);

# ---------------------------------------------------------------------------
# JSON-RPC dispatch table
# ---------------------------------------------------------------------------

my %DISPATCH = (
	'initialize'                => \&handle_initialize,
	'notifications/initialized' => \&handle_notifications_initialized,
	'tools/list'                => \&handle_tools_list,
	'tools/call'                => \&handle_tools_call,
);

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

my $q = CGI->new;
my $json = JSON::XS->new->utf8->canonical;
my $json_pretty = JSON::XS->new->utf8->pretty->canonical;

# Load NMIS config
my $C = NMISNG::Util::loadConfTable();
if (!$C)
{
	print $q->header(-type => 'application/json', -status => '500');
	print $json->encode({ jsonrpc => "2.0", id => undef,
		error => { code => -32603, message => "Failed to load NMIS configuration" }});
	exit 0;
}

# Non-POST requests get a helpful message
if (($ENV{REQUEST_METHOD} // '') ne 'POST')
{
	print $q->header(-type => 'application/json');
	print $json->encode({
		name    => "nmis9-mcp",
		version => $VERSION,
		message => "NMIS9 MCP Server. Send JSON-RPC 2.0 POST requests to this endpoint.",
		auth    => "Use X-API-Token header, Authorization: Bearer header, or ?token= query parameter.",
		example => '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
	});
	exit 0;
}

# Read and parse JSON-RPC request from POST body
# CGI->new already consumed STDIN, so retrieve via POSTDATA param
my $body = $q->param('POSTDATA') // $q->param('keywords') // '';
my $request = eval { JSON::XS::decode_json($body) };
if (!$request || ref($request) ne 'HASH')
{
	print $q->header(-type => 'application/json');
	send_json_rpc_error(undef, -32700, "Parse error: invalid JSON");
	exit 0;
}

my $method = $request->{method};
my $id     = $request->{id};

if (!$method || ($request->{jsonrpc} // '') ne '2.0')
{
	print $q->header(-type => 'application/json');
	send_json_rpc_error($id, -32600, "Invalid Request: must be JSON-RPC 2.0 with a method field");
	exit 0;
}

# Authentication
my $authenticated = 0;

# Try to extract API token from multiple sources:
# 1. Authorization: Bearer <token> header (may be stripped by Apache without CGIPassAuth On)
# 2. X-API-Token custom header (Apache passes X-* headers to CGI)
# 3. ?token=<token> query parameter (useful for simple testing)
my $token;
my $auth_header = $ENV{HTTP_AUTHORIZATION} // '';
if ($auth_header =~ /^Bearer\s+(\S+)$/)
{
	$token = $1;
}
elsif ($ENV{HTTP_X_API_TOKEN})
{
	$token = $ENV{HTTP_X_API_TOKEN};
}
elsif ($q->param('token'))
{
	$token = $q->param('token');
}

if ($token)
{
	my $mcp_config = NMISNG::Util::loadTable(dir => 'conf', name => 'nmis-mcp', conf => $C);
	if ($mcp_config && ref($mcp_config) eq 'HASH'
		&& $mcp_config->{api_token} && $mcp_config->{api_token} ne 'change-me-to-a-secure-token'
		&& $token eq $mcp_config->{api_token})
	{
		$authenticated = 1;
	}
}

# Fallback: NMIS cookie auth (for browser-based testing)
if (!$authenticated)
{
	my $AU = NMISNG::Auth->new(conf => $C);
	if ($AU->Require)
	{
		my $user = $AU->verify_id();
		$authenticated = 1 if $user;
	}
	else
	{
		$authenticated = 1;    # auth not required in config
	}
}

if (!$authenticated)
{
	print $q->header(-type => 'application/json', -status => '401');
	send_json_rpc_error($id, -32000, "Authentication required. Use Authorization: Bearer <token> header.");
	exit 0;
}

# Initialize NMISNG
my $nmisng = Compat::NMIS::new_nmisng();

# Print response header
print $q->header(-type => 'application/json', -charset => 'utf-8');

# Dispatch
if (my $handler = $DISPATCH{$method})
{
	$handler->($request, $id, $nmisng);
}
else
{
	send_json_rpc_error($id, -32601, "Method not found: $method");
}

exit 0;

# ---------------------------------------------------------------------------
# MCP protocol handlers
# ---------------------------------------------------------------------------

sub handle_initialize
{
	my ($request, $id, $nmisng) = @_;
	send_json_rpc_result($id, {
		protocolVersion => "2024-11-05",
		capabilities    => {
			tools => {},
		},
		serverInfo => {
			name    => "nmis9-mcp",
			version => $VERSION,
		},
		instructions => "NMIS9 MCP Server. Use tools to query node status, metrics, events, and inventory.",
	});
}

sub handle_notifications_initialized
{
	# Notification — no response required. Output empty body.
}

sub handle_tools_list
{
	my ($request, $id, $nmisng) = @_;
	send_json_rpc_result($id, {
		tools => \@TOOL_DEFINITIONS,
	});
}

sub handle_tools_call
{
	my ($request, $id, $nmisng) = @_;
	my $tool_name = $request->{params}{name} // '';
	my $arguments = $request->{params}{arguments} // {};

	my %TOOLS = (
		nmis_list_nodes       => \&tool_list_nodes,
		nmis_get_node_status  => \&tool_get_node_status,
		nmis_get_latest_metrics => \&tool_get_latest_metrics,
		nmis_list_events      => \&tool_list_events,
		nmis_list_inventory   => \&tool_list_inventory,
		nmis_get_node_precise_status => \&tool_get_node_precise_status,
	);

	my $handler = $TOOLS{$tool_name};
	if (!$handler)
	{
		send_json_rpc_error($id, -32602, "Unknown tool: $tool_name");
		return;
	}

	my ($content, $is_error) = eval { $handler->($arguments, $nmisng) };
	if ($@)
	{
		send_json_rpc_result($id, {
			content => [{ type => "text", text => "Internal error: $@" }],
			isError => JSON::XS::true,
		});
		return;
	}

	send_json_rpc_result($id, {
		content => [{ type => "text", text => $json_pretty->encode($content) }],
		($is_error ? (isError => JSON::XS::true) : ()),
	});
}

# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

sub tool_list_nodes
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

sub tool_get_node_status
{
	my ($args, $nmisng) = @_;
	my $node_name = $args->{node}
		or return ({ error => "Missing required parameter: node" }, 1);

	my $S = NMISNG::Sys->new;
	my $ok = $S->init(name => $node_name, snmp => 'false');
	return ({ error => "Node '$node_name' not found or init failed" }, 1) unless $ok;

	my ($inv, $err) = $S->inventory(concept => 'catchall');
	return ({ error => "Failed to get catchall inventory: $err" }, 1) if $err;

	my %overall_labels = ( 1 => 'reachable', 0 => 'unreachable', -1 => 'degraded' );
	my $node_obj = $nmisng->node(name => $node_name);
	my %precise = $node_obj->precise_status();
	my $overall_label = $overall_labels{ $precise{overall} } // 'unknown';

	my $data = $inv->data();

	# Also get latest health metrics with OTel renaming
	my $latest = $inv->get_newest_timed_data();
	my $health_metrics = {};
	if ($latest->{success} && $latest->{data} && $latest->{data}{health})
	{
		$health_metrics = _apply_field_rename('health', $latest->{data}{health});
	}

	return {
		node       => $node_name,
		overall        => $precise{overall},
		overall_status => $overall_label,
		sysName    => $data->{sysName} // '',
		sysDescr   => $data->{sysDescr} // '',
		nodeType   => $data->{nodeType} // '',
		nodeModel  => $data->{nodeModel} // '',
		group      => $data->{group} // '',
		host       => $data->{host} // '',
		nodedown   => $data->{nodedown} // '',
		snmpdown   => $data->{snmpdown} // '',
		sysUpTime  => $data->{sysUpTimeSec} // '',
		lastUpdate => $data->{last_poll} // '',
		health     => $health_metrics,
	};
}

sub tool_get_latest_metrics
{
	my ($args, $nmisng) = @_;
	my $node_name = $args->{node}
		or return ({ error => "Missing required parameter: node" }, 1);
	my $concept = $args->{concept}
		or return ({ error => "Missing required parameter: concept" }, 1);

	my $S = NMISNG::Sys->new;
	my $ok = $S->init(name => $node_name, snmp => 'false');
	return ({ error => "Node '$node_name' not found or init failed" }, 1) unless $ok;

	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => $concept,
		filter  => { historic => 0 },
	);
	return ({ error => "No inventory for concept '$concept' on node '$node_name'" }, 1) unless @$ids;

	my @instances;
	for my $inv_id (@$ids)
	{
		my ($inventory, $err) = $S->nmisng_node->inventory(_id => $inv_id);
		next if $err;

		my $inv_data    = $inventory->data();
		my $description = _get_description($concept, $inv_data);
		my $index       = $inv_data->{index} // '0';
		my $latest      = $inventory->get_newest_timed_data();
		next unless $latest->{success} && $latest->{data};

		if ($concept eq 'catchall' || $concept eq 'ping')
		{
			for my $subconcept (sort keys %{$latest->{data}})
			{
				my $sub_data = $latest->{data}{$subconcept};
				next unless $sub_data && ref($sub_data) eq 'HASH';

				my $renamed = _apply_field_rename($subconcept, $sub_data);
				my $renamed_derived = _apply_field_rename($subconcept,
					_filter_derived($latest->{derived_data}{$subconcept}));

				push @instances, {
					subconcept  => $subconcept,
					index       => $index,
					description => $description,
					timestamp   => $latest->{time} // time(),
					metrics     => { %$renamed, %$renamed_derived },
				};
			}
		}
		else
		{
			my %raw_data;
			for my $sub (keys %{$latest->{data}})
			{
				my $sub_data = $latest->{data}{$sub};
				%raw_data = (%raw_data, %$sub_data) if ref($sub_data) eq 'HASH';
			}
			my $renamed = _apply_field_rename($concept, \%raw_data);
			my $renamed_derived = _apply_field_rename($concept,
				_filter_derived_flat($latest->{derived_data}));

			push @instances, {
				concept     => $CONCEPT_RENAME{$concept} // $concept,
				index       => $index,
				description => $description,
				timestamp   => $latest->{time} // time(),
				metrics     => { %$renamed, %$renamed_derived },
			};
		}
	}

	return { node => $node_name, concept => $concept, instances => \@instances, count => scalar(@instances) };
}

sub tool_list_events
{
	my ($args, $nmisng) = @_;

	my %filter = (historic => 0);

	if ($args->{node})
	{
		my $node_obj = $nmisng->node(name => $args->{node});
		return ({ error => "Node '$args->{node}' not found" }, 1) unless $node_obj;
		$filter{node_uuid} = $node_obj->uuid;
	}

	my $events_model = $nmisng->events->get_events_model(filter => \%filter);

	my @events;
	for my $ev (@{$events_model->data})
	{
		push @events, {
			node      => $ev->{node_name} // '',
			event     => $ev->{event} // '',
			level     => $ev->{level} // '',
			element   => $ev->{element} // '',
			details   => $ev->{details} // '',
			startdate => $ev->{startdate} // 0,
			ack       => $ev->{ack} ? JSON::XS::true : JSON::XS::false,
			escalate  => $ev->{escalate} // 0,
		};
	}

	return { events => \@events, count => scalar(@events) };
}

sub tool_list_inventory
{
	my ($args, $nmisng) = @_;
	my $node_name = $args->{node}
		or return ({ error => "Missing required parameter: node" }, 1);
	my $concept = $args->{concept}
		or return ({ error => "Missing required parameter: concept" }, 1);

	my $S = NMISNG::Sys->new;
	my $ok = $S->init(name => $node_name, snmp => 'false');
	return ({ error => "Node '$node_name' not found or init failed" }, 1) unless $ok;

	my $ids = $S->nmisng_node->get_inventory_ids(
		concept => $concept,
		filter  => { historic => 0 },
	);
	return ({ error => "No inventory for concept '$concept' on node '$node_name'" }, 1) unless @$ids;

	my @instances;
	for my $inv_id (@$ids)
	{
		my ($inventory, $err) = $S->nmisng_node->inventory(_id => $inv_id);
		next if $err;

		my $inv_data    = $inventory->data();
		my $description = _get_description($concept, $inv_data);
		my $index       = $inv_data->{index} // '0';

		push @instances, {
			index       => $index,
			description => $description,
			data_fields => [sort keys %$inv_data],
		};
	}

	return { node => $node_name, concept => $concept, instances => \@instances, count => scalar(@instances) };
}

sub tool_get_node_precise_status
{
	my ($args, $nmisng) = @_;

	my $node_name  = $args->{node};
	my $group_name = $args->{group};

	# Build filter for get_nodes_model
	my %filter;
	if ($node_name)
	{
		$filter{name} = $node_name;
	}
	elsif ($group_name)
	{
		$filter{"configuration.group"} = $group_name;
	}

	my $model = $nmisng->get_nodes_model(
		fields_hash => {
			name                  => 1,
			uuid                  => 1,
			'configuration.group' => 1,
			'configuration.host'  => 1,
		},
		(%filter ? (filter => \%filter) : ()),
	);

	my $nodes_data = $model->data();

	# If a specific node was requested but not found, return error
	if ($node_name && !@$nodes_data)
	{
		return ({ error => "Node '$node_name' not found" }, 1);
	}

	my %overall_labels = ( 1 => 'reachable', 0 => 'unreachable', -1 => 'degraded' );

	my @results;
	for my $nd (@$nodes_data)
	{
		my $conf     = $nd->{configuration} // {};
		my $node_obj = $nmisng->node(uuid => $nd->{uuid});
		next unless $node_obj;

		# Get precise_status from the Node object
		my %precise = $node_obj->precise_status();
		next if $precise{error};

		my $overall_label = $overall_labels{ $precise{overall} } // 'unknown';

		# Get uptime and reachability from catchall inventory
		my $uptime_sec;
		my $reachability;
		my $availability;

		my ($inv, $err) = $node_obj->inventory(concept => 'catchall');
		if ($inv && !$err)
		{
			my $catchall_data = $inv->data();
			$uptime_sec = $catchall_data->{sysUpTimeSec};

			my $latest = $inv->get_newest_timed_data();
			if ($latest->{success} && $latest->{data} && $latest->{data}{health})
			{
				$reachability = $latest->{data}{health}{reachability};
				$availability = $latest->{data}{health}{availability};
			}
		}

		push @results, {
			node                 => $nd->{name},
			group                => $conf->{group} // '',
			host                 => $conf->{host} // '',
			overall              => $precise{overall},
			overall_status       => $overall_label,
			snmp_enabled         => $precise{snmp_enabled},
			snmp_status          => $precise{snmp_status},
			wmi_enabled          => $precise{wmi_enabled},
			wmi_status           => $precise{wmi_status},
			ping_enabled         => $precise{ping_enabled},
			ping_status          => $precise{ping_status},
			failover_status      => $precise{failover_status},
			failover_ping_status => $precise{failover_ping_status},
			primary_ping_status  => $precise{primary_ping_status},
			uptime_seconds       => $uptime_sec,
			reachability         => $reachability,
			availability         => $availability,
		};
	}

	return { nodes => \@results, count => scalar(@results) };
}

# ---------------------------------------------------------------------------
# OTel helpers (from mqttobservations.pm)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# JSON-RPC response utilities
# ---------------------------------------------------------------------------

sub send_json_rpc_result
{
	my ($id, $result) = @_;
	print $json->encode({
		jsonrpc => "2.0",
		id      => $id,
		result  => $result,
	});
}

sub send_json_rpc_error
{
	my ($id, $code, $message) = @_;
	print $json->encode({
		jsonrpc => "2.0",
		id      => $id,
		error   => { code => $code + 0, message => $message },
	});
}
