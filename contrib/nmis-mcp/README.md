# NMIS9 MCP Server

A [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server for NMIS9, implemented as a Perl CGI script. It exposes NMIS monitoring data to AI assistants (Claude, ChatGPT, etc.) via the standard MCP tool interface.

## Overview

The MCP server speaks JSON-RPC 2.0 over HTTP POST, providing six tools that let an AI assistant query node status, precise reachability, metrics, events, and inventory from a live NMIS9 installation. Metrics are returned with OTel-inspired field names for consistency with the [mqttobservations](../nmis-mqtt-observations/) plugin.

## Files

| File | Install to | Description |
|------|-----------|-------------|
| `nmis-mcp.pl` | `cgi-bin/nmis-mcp.pl` | MCP server CGI script |
| `nmis-mcp.nmis` | `conf/nmis-mcp.nmis` | Configuration (API token) |
| `t_nmis-mcp.pl` | _(test only)_ | Test suite for helpers and data structures |

## Installation

```bash
# Copy files into place
cp nmis-mcp.pl   /usr/local/nmis9/cgi-bin/nmis-mcp.pl
cp nmis-mcp.nmis /usr/local/nmis9/conf/nmis-mcp.nmis

# Set permissions
chmod 755 /usr/local/nmis9/cgi-bin/nmis-mcp.pl

# Edit the config and set a secure API token
vi /usr/local/nmis9/conf/nmis-mcp.nmis
```

The CGI script is served by Apache at `/cgi-nmis9/nmis-mcp.pl` using the existing NMIS CGI configuration.

## Authentication

The server supports three authentication methods:

| Method | Header/Parameter | Notes |
|--------|-----------------|-------|
| Custom header | `X-API-Token: <token>` | Recommended. Apache passes `X-*` headers to CGI. |
| Bearer token | `Authorization: Bearer <token>` | Standard, but requires `CGIPassAuth On` in Apache. |
| Query parameter | `?token=<token>` | For quick testing only. |

All methods check the token against `api_token` in `conf/nmis-mcp.nmis`. If no token matches, the server falls back to NMIS cookie authentication (for browser-based testing).

## Using NMIS MCP in Claude Desktop

On a MAC, edit the file ~/Library/Application Support/Claude/claude_desktop_config.json
e.g. /Users/keith/Library/Application Support/Claude/claude_desktop_config.json

Add an mcp servers section or just an additional for NMIS, showing the MCP_DOCKER one here as well.

```
{
  "mcpServers": {
    "MCP_DOCKER": {
      "command": "docker",
      "args": [
        "mcp",
        "gateway",
        "run"
      ]
    },
    "nmis": {
      "command": "npx",
      "args": [
        "mcp-remote@latest",
        "https://home.packsin.com/cgi-nmis9/nmis-mcp.pl",
        "--header",
        "X-API-Token: ${AUTH_TOKEN}"
      ],
      "env": {
        "AUTH_TOKEN": "CHANGE-ME-your-token-from-nmis-mcp-nmis-file"
      }
    }
  },
  "preferences": {
    "comment": "POSSIBLY OTHER SETTINGS"
  }
}
```

Then ask Claude for status of events of one or more NMIS nodes
![NMIS MCP Demo](nmis-mcp-demo.png)

## MCP Tools

### nmis_list_nodes

List all monitored nodes with basic status.

**Parameters:** none

**Returns:** array of `{name, group, host, nodeType, nodedown, health, reachability}`

```bash
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_list_nodes","arguments":{}}}'
```

### nmis_get_node_status

Get detailed status and health metrics for a specific node.

**Parameters:** `node` (required)

**Returns:** `{node, sysName, sysDescr, nodeType, nodeModel, group, host, nodedown, snmpdown, sysUpTime, health}`

The `health` object contains OTel-renamed metrics from the health subconcept (reachability, availability, response time, etc.).

```bash
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_get_node_status","arguments":{"node":"myrouter"}}}'
```

### nmis_get_latest_metrics

Get the latest collected metrics for a node and inventory concept.

**Parameters:** `node` (required), `concept` (required)

**Concepts:** `catchall`, `interface`, `device`, `Host_Storage`, `diskIOTable`, `env-temp`, `service`, `ping`

**Returns:** array of instances with OTel-renamed metrics. For `catchall` and `ping`, results are split by subconcept (health, tcp, laload, mib2ip, systemStats, Host_Health). For other concepts, each inventory instance is a separate entry.

```bash
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_get_latest_metrics","arguments":{"node":"myrouter","concept":"interface"}}}'
```

### nmis_list_events

List active (non-historic) NMIS events and alerts.

**Parameters:** `node` (optional, filter by node name)

**Returns:** array of `{node, event, level, element, details, startdate, ack, escalate}`

```bash
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_list_events","arguments":{}}}'
```

### nmis_list_inventory

List inventory instances for a node and concept, showing index, description, and available data fields. Useful for discovering what instances exist before fetching metrics.

**Parameters:** `node` (required), `concept` (required)

**Returns:** array of `{index, description, data_fields}`

```bash
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_list_inventory","arguments":{"node":"myrouter","concept":"Host_Storage"}}}'
```

### nmis_get_node_precise_status

Get precise reachability status for nodes, including per-protocol (SNMP, WMI, ping) status, failover state, uptime, and reachability metrics. Uses the `NMISNG::Node::precise_status()` method.

**Parameters:** `node` (optional), `group` (optional). Omit both for all nodes.

**Returns:** array of `{node, group, host, overall, overall_status, snmp_enabled, snmp_status, wmi_enabled, wmi_status, ping_enabled, ping_status, failover_status, failover_ping_status, primary_ping_status, uptime_seconds, reachability, availability}`

The `overall_status` field is a human-readable label: `reachable`, `degraded`, or `unreachable`.

```bash
# All nodes
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_get_node_precise_status","arguments":{}}}'

# Single node
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_get_node_precise_status","arguments":{"node":"myrouter"}}}'

# By group
curl -s -X POST http://localhost/cgi-nmis9/nmis-mcp.pl \
  -H "X-API-Token: YOUR_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nmis_get_node_precise_status","arguments":{"group":"Core"}}}'
```

## OTel Field Naming

Metrics are renamed from NMIS-native names to OpenTelemetry-inspired semantic conventions. Fields with a known mapping get standard names; unknown fields are prefixed with `nmis.`. Fields ending in `_raw` are filtered out.

### Interface Metrics

| NMIS Field | OTel Name |
|-----------|-----------|
| `ifInOctets` | `system.network.io.receive` |
| `ifOutOctets` | `system.network.io.transmit` |
| `ifInUcastPkts` | `system.network.packets.receive` |
| `ifOutUcastPkts` | `system.network.packets.transmit` |
| `ifInErrors` | `system.network.errors.receive` |
| `ifOutErrors` | `system.network.errors.transmit` |
| `ifInDiscards` | `system.network.dropped.receive` |
| `ifOutDiscards` | `system.network.dropped.transmit` |

### Health Metrics

| NMIS Field | OTel Name |
|-----------|-----------|
| `reachability` | `nmis.node.reachability` |
| `availability` | `nmis.node.availability` |
| `health` | `nmis.node.health` |
| `responsetime` | `nmis.node.response_time_ms` |
| `loss` | `nmis.node.packet_loss` |

### System Stats

| NMIS Field | OTel Name |
|-----------|-----------|
| `ssCpuRawUser` | `system.cpu.time.user` |
| `ssCpuRawSystem` | `system.cpu.time.system` |
| `ssCpuRawIdle` | `system.cpu.time.idle` |
| `ssIORawSent` | `system.disk.io.sent` |
| `ssIORawReceived` | `system.disk.io.received` |
| `ssRawInterrupts` | `system.cpu.interrupts` |
| `ssRawContexts` | `system.cpu.context_switches` |

### Load Average

| NMIS Field | OTel Name |
|-----------|-----------|
| `laLoad1` | `system.cpu.load_average.1m` |
| `laLoad5` | `system.cpu.load_average.5m` |

### TCP

| NMIS Field | OTel Name |
|-----------|-----------|
| `tcpCurrEstab` | `system.network.tcp.connections.established` |
| `tcpActiveOpens` | `system.network.tcp.connections.opened.active` |
| `tcpPassiveOpens` | `system.network.tcp.connections.opened.passive` |
| `tcpInSegs` | `system.network.tcp.segments.received` |
| `tcpOutSegs` | `system.network.tcp.segments.sent` |
| `tcpRetransSegs` | `system.network.tcp.segments.retransmitted` |

### Ping

| NMIS Field | OTel Name |
|-----------|-----------|
| `avg_ping_time` | `network.peer.rtt.avg_ms` |
| `max_ping_time` | `network.peer.rtt.max_ms` |
| `min_ping_time` | `network.peer.rtt.min_ms` |
| `ping_loss` | `network.peer.packet_loss` |

## JSON-RPC 2.0 Protocol

The server implements a subset of MCP over stateless HTTP POST:

| Method | Purpose |
|--------|---------|
| `initialize` | Protocol handshake, returns server info and capabilities |
| `notifications/initialized` | Client acknowledgement (no response) |
| `tools/list` | Returns the list of available tools with JSON Schema |
| `tools/call` | Executes a tool by name with arguments |

### Error Codes

| Code | Meaning |
|------|---------|
| `-32700` | Parse error (invalid JSON) |
| `-32600` | Invalid request (not JSON-RPC 2.0) |
| `-32601` | Method not found |
| `-32602` | Invalid params (unknown tool name) |
| `-32000` | Authentication required |
| `-32603` | Internal error (NMIS config load failure) |

Tool-level errors are returned as `isError: true` in the `tools/call` result, not as JSON-RPC errors.

## Running Tests

```bash
perl contrib/nmis-mcp/t_nmis-mcp.pl
```

The test suite (82 tests) covers:
- `_get_description` field mapping for all concepts
- `_apply_field_rename` OTel naming and `_raw` filtering
- `_filter_derived` prefix filtering (08\_, 16\_)
- `_filter_derived_flat` flattening across subconcepts
- `%CONCEPT_RENAME` mapping
- JSON-RPC 2.0 request validation
- Tool definition structure and required parameters
- `%FIELD_RENAME` map coverage

## Requirements

- NMIS9 with working CGI (Apache serving `/cgi-nmis9/`)
- Perl modules: `CGI`, `JSON::XS` (both standard NMIS9 dependencies)
- No additional CPAN modules required

## License

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.
   
---

Built with [Claude Code](https://claude.ai/code)
