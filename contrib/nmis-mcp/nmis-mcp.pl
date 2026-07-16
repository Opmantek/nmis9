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
# Auth:     Bearer / X-API-Token / ?token= against conf/nmis-mcp.nmis
#
# The runtime (CGI dispatch) only executes when this file is run directly.
# When loaded via require/do (e.g. from the test suite) the guard at the
# bottom is skipped, so the tool subs can be exercised in isolation.
#
# *****************************************************************************

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use CGI;
use JSON::XS;
use NMISNG::Util;
use Compat::NMIS;
use NMISNG::OTel qw(apply_field_rename filter_derived filter_derived_flat get_description);

my $VERSION = "1.0.0";

# ---------------------------------------------------------------------------
# MCP tool definitions.
#
# Single source of truth: each entry carries its MCP metadata *and* its
# handler coderef. tools/list strips the handler; tools/call dispatches on it.
# ---------------------------------------------------------------------------

our @TOOLS = (
	{
		name        => "nmis_list_nodes",
		description => "List all NMIS monitored nodes with basic status (name, group, type, host, health, reachability). Returns a summary for every node.",
		inputSchema => {
			type       => "object",
			properties => {},
		},
		handler => \&tool_list_nodes,
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
		handler => \&tool_get_node_status,
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
		handler => \&tool_get_latest_metrics,
	},
	{
		name        => "nmis_list_events",
		description => "List active NMIS events and alerts. Optionally filter by node name.",
		inputSchema => {
			type       => "object",
			properties => {
				node  => { type => "string", description => "Optional: filter events by node name" },
				limit => { type => "integer", description => "Optional: maximum number of events to return (default 1000)" },
			},
		},
		handler => \&tool_list_events,
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
		handler => \&tool_list_inventory,
	},
	{
		name        => "nmis_get_node_precise_status",
		description => "Get precise reachability status for nodes. Returns overall status (reachable/degraded/unreachable), per-protocol status (SNMP, WMI, ping), failover state, uptime, and reachability. Query all nodes, a group, or a single node. On large fleets, scope with group or limit — each node requires a live status computation.",
		inputSchema => {
			type       => "object",
			properties => {
				node  => { type => "string",  description => "Optional: specific node name" },
				group => { type => "string",  description => "Optional: filter by node group" },
				limit => { type => "integer", description => "Optional: maximum number of nodes to evaluate" },
			},
		},
		handler => \&tool_get_node_precise_status,
	},
);

# Derived views: the tools/list payload (no handler) and the name->handler map.
# Exposed as package vars so the test suite can introspect the real tables.
our @TOOL_DEFINITIONS = map {
	my %copy = %$_;
	delete $copy{handler};
	\%copy;
} @TOOLS;

our %TOOL_HANDLERS = map { $_->{name} => $_->{handler} } @TOOLS;

# ---------------------------------------------------------------------------
# JSON-RPC dispatch table
# ---------------------------------------------------------------------------

my %DISPATCH = (
	'initialize' => \&handle_initialize,
	'tools/list' => \&handle_tools_list,
	'tools/call' => \&handle_tools_call,
);

# JSON encoders, initialised by the runtime block. The response helpers close
# over these; they are only ever used while actually serving a request.
my $json;
my $json_pretty;

# ---------------------------------------------------------------------------
# Runtime (CGI request handling) — skipped when this file is require'd.
# ---------------------------------------------------------------------------

unless (caller)
{
	my $q = CGI->new;
	$json        = JSON::XS->new->utf8->canonical;
	$json_pretty = JSON::XS->new->utf8->pretty->canonical;

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
			message => "NMIS9 MCP Server. Send JSON-RPC 2.0 POST requests with Content-Type: application/json.",
			auth    => "Use X-API-Token header, Authorization: Bearer header, or ?token= query parameter.",
			example => '{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
		});
		exit 0;
	}

	# Read the raw JSON-RPC request body. CGI->new has already consumed STDIN;
	# for a Content-Type: application/json POST it stashes the unparsed body
	# under the POSTDATA pseudo-param. We deliberately do NOT fall back to
	# form-field parsing (param('keywords') etc.) — that mangles JSON bodies
	# that contain '=', '+', spaces or %XX sequences.
	my $body = $q->param('POSTDATA') // '';
	my $request = eval { JSON::XS::decode_json($body) };
	if (!$request || ref($request) ne 'HASH')
	{
		print $q->header(-type => 'application/json');
		send_json_rpc_error(undef, -32700, "Parse error: invalid JSON (send the request body as Content-Type: application/json)");
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

	# --- Authentication: API token only ------------------------------------
	# Token sources (first match wins):
	#   1. Authorization: Bearer <token>  (needs CGIPassAuth On in Apache)
	#   2. X-API-Token: <token>           (Apache passes X-* headers to CGI)
	#   3. ?token=<token> query parameter (url_param: reads QUERY_STRING even
	#      on a POST, which plain param() does not)
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
	elsif ($q->url_param('token'))
	{
		$token = $q->url_param('token');
	}

	my $authenticated = 0;
	if ($token)
	{
		my $mcp_config = NMISNG::Util::loadTable(dir => 'conf', name => 'nmis-mcp', conf => $C);
		if ($mcp_config && ref($mcp_config) eq 'HASH'
			&& $mcp_config->{api_token} && $mcp_config->{api_token} ne 'change-me-to-a-secure-token'
			&& _ct_eq($token, $mcp_config->{api_token}))
		{
			$authenticated = 1;
		}
	}

	if (!$authenticated)
	{
		print $q->header(-type => 'application/json', -status => '401');
		send_json_rpc_error($id, -32000, "Authentication required. Provide a valid API token via X-API-Token or Authorization: Bearer.");
		exit 0;
	}

	# Initialize NMISNG
	my $nmisng = Compat::NMIS::new_nmisng();

	# JSON-RPC 2.0: a request without an "id" member is a Notification.
	# Notifications MUST NOT receive any response per the spec, and MCP's
	# notifications/* methods are always notifications.
	my $is_notification = (!exists $request->{id} || $method =~ m{^notifications/});

	if ($is_notification)
	{
		# 204 No Content — no body, no Content-Type. No handler dispatch, since
		# notifications must not produce response output.
		print $q->header(-status => '204 No Content');
		exit 0;
	}

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
}

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

	my $handler = $TOOL_HANDLERS{$tool_name};
	if (!$handler)
	{
		send_json_rpc_error($id, -32602, "Unknown tool: $tool_name");
		return;
	}

	my ($content, $is_error) = eval { $handler->($arguments, $nmisng) };
	if (my $err = $@)
	{
		$nmisng->log->error("MCP tool '$tool_name' died: $err");
		send_json_rpc_result($id, {
			content => [{ type => "text", text => "Internal error" }],
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

	# One query for every node's catchall inventory, keyed by node_uuid,
	# instead of instantiating a Node object + inventory per node.
	my %catchall_by_uuid = _catchall_by_uuid($nmisng);

	my @nodes;
	for my $nd (@{$model->data()})
	{
		my $conf          = $nd->{configuration} // {};
		my $catchall_data = $catchall_by_uuid{ $nd->{uuid} } // {};

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

	# Look the node up directly; Sys::init would Carp::confess on an unknown
	# node rather than returning a falsey value.
	my $node_obj = $nmisng->node(name => $node_name)
		or return ({ error => "Node '$node_name' not found" }, 1);

	# Node::inventory returns (object, error); check both.
	my ($inv, $err) = $node_obj->inventory(concept => 'catchall');
	return ({ error => "Failed to get catchall inventory for '$node_name': " . ($err // 'not found') }, 1)
		if (!$inv || $err);

	my %overall_labels = ( 1 => 'reachable', 0 => 'unreachable', -1 => 'degraded' );
	my %precise = $node_obj->precise_status();
	my $overall_label = $overall_labels{ $precise{overall} } // 'unknown';

	my $data = $inv->data();

	# Also get latest health metrics with OTel renaming
	my $latest = $inv->get_newest_timed_data();
	my $health_metrics = {};
	if ($latest->{success} && $latest->{data} && $latest->{data}{health})
	{
		$health_metrics = apply_field_rename('health', $latest->{data}{health});
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

	my $node_obj = $nmisng->node(name => $node_name)
		or return ({ error => "Node '$node_name' not found" }, 1);

	# One model query for every instance of this concept, then instantiate.
	my $inv_model = $node_obj->get_inventory_model(
		concept => $concept,
		filter  => { historic => 0 },
	);
	return ({ error => "Failed to query inventory: " . $inv_model->error }, 1) if $inv_model->error;

	my $objres = $inv_model->objects;
	return ({ error => "Failed to load inventory: $objres->{error}" }, 1) if $objres->{error};
	my @inventories = @{ $objres->{objects} // [] };
	return ({ error => "No inventory for concept '$concept' on node '$node_name'" }, 1) unless @inventories;

	my @instances;
	for my $inventory (@inventories)
	{
		my $inv_data    = $inventory->data();
		my $description = get_description($concept, $inv_data);
		my $index       = $inv_data->{index} // '0';
		my $latest      = $inventory->get_newest_timed_data();
		next unless $latest->{success} && $latest->{data};

		if ($concept eq 'catchall' || $concept eq 'ping')
		{
			for my $subconcept (sort keys %{$latest->{data}})
			{
				my $sub_data = $latest->{data}{$subconcept};
				next unless $sub_data && ref($sub_data) eq 'HASH';

				my $renamed = apply_field_rename($subconcept, $sub_data);
				my $renamed_derived = apply_field_rename($subconcept,
					filter_derived($latest->{derived_data}{$subconcept}));

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
			my $renamed = apply_field_rename($concept, \%raw_data);
			my $renamed_derived = apply_field_rename($concept,
				filter_derived_flat($latest->{derived_data}));

			push @instances, {
				concept     => $NMISNG::OTel::CONCEPT_RENAME{$concept} // $concept,
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

	# Push the field projection and a result cap down to the DB rather than
	# pulling every active event as a full document.
	my $limit = ($args->{limit} && $args->{limit} =~ /^\d+$/) ? $args->{limit} + 0 : 1000;

	my $events_model = $nmisng->events->get_events_model(
		filter      => \%filter,
		limit       => $limit,
		fields_hash => {
			node_name => 1,
			event     => 1,
			level     => 1,
			element   => 1,
			details   => 1,
			startdate => 1,
			ack       => 1,
			escalate  => 1,
		},
	);

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

	my $node_obj = $nmisng->node(name => $node_name)
		or return ({ error => "Node '$node_name' not found" }, 1);

	# One model query; we only need the raw data documents, no objects.
	my $inv_model = $node_obj->get_inventory_model(
		concept     => $concept,
		filter      => { historic => 0 },
		fields_hash => { data => 1 },
	);
	return ({ error => "Failed to query inventory: " . $inv_model->error }, 1) if $inv_model->error;

	my $docs = $inv_model->data();
	return ({ error => "No inventory for concept '$concept' on node '$node_name'" }, 1) unless @$docs;

	my @instances;
	for my $doc (@$docs)
	{
		my $inv_data    = $doc->{data} // {};
		my $description = get_description($concept, $inv_data);
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
	my $limit      = ($args->{limit} && $args->{limit} =~ /^\d+$/) ? $args->{limit} + 0 : undef;

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
		(defined $limit ? (limit => $limit) : ()),
	);

	my $nodes_data = $model->data();

	# If a specific node was requested but not found, return error
	if ($node_name && !@$nodes_data)
	{
		return ({ error => "Node '$node_name' not found" }, 1);
	}

	# Batch the catchall inventory for uptime/reachability/availability so we
	# don't reload it (plus timed data) per node on top of precise_status.
	my %catchall_by_uuid = _catchall_by_uuid($nmisng);

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

		my $catchall_data = $catchall_by_uuid{ $nd->{uuid} } // {};

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
			uptime_seconds       => $catchall_data->{sysUpTimeSec},
			reachability         => $catchall_data->{reachability},
			availability         => $catchall_data->{availability},
		};
	}

	return { nodes => \@results, count => scalar(@results) };
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Fetch every node's catchall inventory data in a single query, returned as a
# (node_uuid => data hashref) map. Returns an empty list on error.
sub _catchall_by_uuid
{
	my ($nmisng) = @_;
	my %by_uuid;
	my $inv_model = $nmisng->get_inventory_model(
		concept     => 'catchall',
		fields_hash => { node_uuid => 1, data => 1 },
	);
	return %by_uuid if $inv_model->error;
	for my $doc (@{ $inv_model->data() })
	{
		$by_uuid{ $doc->{node_uuid} } = $doc->{data} // {};
	}
	return %by_uuid;
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

# Constant-time string equality for token comparison. Protects against
# CWE-208 (Observable Timing Discrepancy) on the auth path.
sub _ct_eq
{
	my ($a, $b) = @_;
	return 0 unless defined $a && defined $b;
	return 0 if length($a) != length($b);
	my $r = 0;
	$r |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
	return $r == 0;
}

1;
