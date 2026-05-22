# nmis-mqtt-observations

An NMIS collect plugin that publishes per-node latest data observations to an MQTT broker as OTel-inspired flat JSON messages.

## Features

- Runs automatically after each NMIS collect cycle (no separate scheduling needed)
- Publishes one JSON message per inventory instance per configured concept
- **OTel-inspired flat JSON payload** — envelope uses OTel attribute names; well-known NMIS metrics are renamed to OpenTelemetry semantic convention names; unknown fields pass through with a `nmis.` prefix
- `catchall` and `ping` concepts are singletons — each subconcept (health, tcp, laload, etc.) is published as its own message with a short topic path
- All other concepts use `{base_topic}/{node}/{concept}/{description}` topics
- `device` concept is published under the clearer name `cpuLoad`
- Skips nodes that are down or SNMP-unreachable (no stale data published)
- Supports MQTT retain flag and configurable publish retries
- Optional secondary MQTT broker for redundancy
- Configurable list of concepts (inventory types) to export
- MQTT broker authentication

## Requirements

- NMIS 9
- Perl module: [Net::MQTT::Simple](https://metacpan.org/pod/Net::MQTT::Simple)

## Installation

### Quick Install

```bash
sudo ./install.sh
```

The install script will:
- Check for `Net::MQTT::Simple`
- Copy `mqttobservations.pm` to `/usr/local/nmis9/conf/plugins/`
- Copy `mqttobservations.nmis` to `/usr/local/nmis9/conf/` (won't overwrite existing)
- Set ownership `nmis:nmis` and permissions `640`

### Manual Install

1. Install the required Perl module:
   ```bash
   cpanm Net::MQTT::Simple
   ```

2. Copy files:
   ```bash
   cp mqttobservations.pm /usr/local/nmis9/conf/plugins/mqttobservations.pm
   cp mqttobservations.nmis /usr/local/nmis9/conf/mqttobservations.nmis
   chown nmis:nmis /usr/local/nmis9/conf/plugins/mqttobservations.pm \
                   /usr/local/nmis9/conf/mqttobservations.nmis
   chmod 640 /usr/local/nmis9/conf/plugins/mqttobservations.pm \
             /usr/local/nmis9/conf/mqttobservations.nmis
   ```

## Configuration

Edit `/usr/local/nmis9/conf/mqttobservations.nmis`:

```perl
%hash = (
  'mqtt' => {
    'server'        => 'your.mqtt.server:1883',
    'topic'         => 'obs/nmis',
    'username'      => 'your_username',   # leave empty if not required
    'password'      => 'your_password',
    'retain'        => 1,                 # set to 1 to retain last message per topic
    'retries'       => 1,                 # retry attempts on publish failure
    'extra_logging' => 0,                 # set to 1 for per-message debug logs
  },

  # Optional — publish every message to a second broker as well
  #'mqtt_secondary' => {
  #  'server'   => 'secondary.mqtt.server:1883',
  #  'topic'    => 'obs/nmis',
  #  'username' => '',
  #  'password' => '',
  #},

  'concepts' => [
    'catchall',
    'interface',
    'Host_Storage',
    'diskIOTable',
    'env-temp',
    'service',
    'ping',
    'device',
  ],
);
```

### Concepts

The `concepts` list controls which NMIS inventory types are exported. Supported values:

| Concept | Description | Published under |
|---------|-------------|-----------------|
| `catchall` | Node health, TCP, IP, load, system stats | Per subconcept: `{base}/sol/health`, `{base}/sol/tcp`, etc. |
| `ping` | Ping/reachability metrics | Per subconcept: `{base}/sol/ping` |
| `interface` | Network interfaces | `{base}/sol/interface/GigabitEthernet0-0` |
| `Host_Storage` | Disk/memory storage | `{base}/sol/Host_Storage/Physical_memory` |
| `diskIOTable` | Disk I/O counters | `{base}/sol/diskIOTable/sda` |
| `env-temp` | Temperature sensors | `{base}/sol/env-temp/CPU_Temp` |
| `service` | Monitored services | `{base}/sol/service/http` |
| `device` | CPU/memory (published as `cpuLoad`) | `{base}/sol/cpuLoad/cpu0` |
| `Host_File_System` | File systems | `{base}/sol/Host_File_System/-var` |
| `entityMib` | Hardware entities | `{base}/sol/entityMib/Chassis` |
| `cdp` | CDP neighbours | `{base}/sol/cdp/switch1` |
| `lldp` | LLDP neighbours | `{base}/sol/lldp/switch1` |
| `bgp` | BGP peers | `{base}/sol/bgp/10.0.0.1` |

## Metric Types — Gauges

All metrics published by this plugin are **gauges**: each value represents the measured amount or rate for the observation period ending at the message timestamp. For example, `system.network.io.receive` is the number of bytes received during the last NMIS collect interval, not a monotonically increasing counter.

NMIS derives these gauge values from the raw SNMP counters internally — computing the delta between successive polls and normalising by the poll interval where appropriate. The raw cumulative counter values (stored internally with a `_raw` suffix, e.g. `ifInOctets_raw`) are deliberately excluded from published messages to keep the payload consistent and immediately usable without further processing.

If raw counter values are required — for example, to feed a time-series database that performs its own rate calculation — the plugin can be modified to include them by removing or adjusting the `_raw` filter in the `_apply_field_rename` sub:

```perl
# In _apply_field_rename — remove or comment out this line to include _raw fields:
next if $k =~ /_raw$/i;
```

## Message Format

Messages are flat JSON using OTel attribute naming on the envelope. Well-known metric fields are renamed to OpenTelemetry semantic convention names. Fields with no known OTel mapping pass through with a `nmis.` prefix. Fields ending in `_raw` are excluded.

### Envelope fields (every message)

| Field | OTel attribute | Example |
|-------|---------------|---------|
| Node name | `host.name` | `"sol"` |
| Node UUID | `host.id` | `"550e8400-..."` |
| Service | `service.name` | `"nmis"` |
| OTel scope | `otel.scope.name` | `"nmis"` |
| OTel version | `otel.scope.version` | `"1.0.0"` |
| NMIS group | `nmis.group` | `"Core"` |
| Node type | `nmis.node.type` | `"router"` |
| SNMP sysName | `net.host.name` | `"sol.example.com"` |
| IP address | `host.ip` | `"192.168.1.1"` |
| Concept | `nmis.concept` | `"interface"` |
| Index | `nmis.index` | `"3"` |
| Description | `nmis.description` | `"GigabitEthernet0/0"` |
| Timestamp | `timestamp` | `1708600000` |

### Example: interface message

Topic: `obs/nmis/sol/interface/GigabitEthernet0-0`

```json
{
  "host.name":                     "sol",
  "host.id":                       "550e8400-e29b-41d4-a716-446655440000",
  "service.name":                  "nmis",
  "otel.scope.name":               "nmis",
  "otel.scope.version":            "1.0.0",
  "nmis.group":                    "Core",
  "nmis.node.type":                "router",
  "net.host.name":                 "sol.example.com",
  "host.ip":                       "192.168.1.1",
  "nmis.concept":                  "interface",
  "nmis.index":                    "3",
  "nmis.description":              "GigabitEthernet0/0",
  "timestamp":                     1708600000,
  "system.network.io.receive":     12345678,
  "system.network.io.transmit":    87654321,
  "system.network.packets.receive": 9876,
  "system.network.packets.transmit": 5432,
  "system.network.errors.receive": 0,
  "system.network.errors.transmit": 0,
  "system.network.dropped.receive": 0,
  "system.network.dropped.transmit": 0,
  "system.network.speed":          1000000000,
  "system.network.status":         1,
  "nmis.ifAdminStatus":            1,
  "nmis.ifDescr":                  "GigabitEthernet0/0"
}
```

### Example: catchall health message

Topic: `obs/nmis/sol/health`

```json
{
  "host.name":                  "sol",
  "host.id":                    "550e8400-...",
  "service.name":               "nmis",
  "otel.scope.name":            "nmis",
  "otel.scope.version":         "1.0.0",
  "nmis.group":                 "Core",
  "nmis.node.type":             "router",
  "net.host.name":              "sol.example.com",
  "host.ip":                    "192.168.1.1",
  "nmis.concept":               "health",
  "nmis.index":                 "0",
  "nmis.description":           "Cisco IOS",
  "timestamp":                  1708600000,
  "nmis.node.reachability":     100,
  "nmis.node.availability":     100,
  "nmis.node.health":           98.5,
  "nmis.node.response_time_ms": 2.1,
  "nmis.node.packet_loss":      0,
  "nmis.node.cpu_health":       95,
  "nmis.node.mem_health":       88
}
```

### OTel metric name mappings

#### interface
| NMIS field | OTel name |
|-----------|-----------|
| `ifInOctets` | `system.network.io.receive` |
| `ifOutOctets` | `system.network.io.transmit` |
| `ifInUcastPkts` | `system.network.packets.receive` |
| `ifOutUcastPkts` | `system.network.packets.transmit` |
| `ifInErrors` | `system.network.errors.receive` |
| `ifOutErrors` | `system.network.errors.transmit` |
| `ifInDiscards` | `system.network.dropped.receive` |
| `ifOutDiscards` | `system.network.dropped.transmit` |
| `ifSpeed` | `system.network.speed` |
| `ifOperStatus` | `system.network.status` |

#### device (cpuLoad)
| NMIS field | OTel name |
|-----------|-----------|
| `cpuLoad` | `system.cpu.utilization` |
| `cpu1min` | `system.cpu.utilization.1m` |
| `cpu5min` | `system.cpu.utilization.5m` |
| `memUtil` | `system.memory.utilization` |
| `memAvail` | `system.memory.usage.available` |

#### Host_Storage
| NMIS field | OTel name |
|-----------|-----------|
| `hrStorageUsed` | `system.filesystem.usage.used` |
| `hrStorageSize` | `system.filesystem.usage.total` |
| `hrStorageAllocationUnits` | `system.filesystem.allocation_unit` |
| `hrStorageType` | `system.filesystem.type` |

#### diskIOTable
| NMIS field | OTel name |
|-----------|-----------|
| `diskIOReads` | `system.disk.operations.read` |
| `diskIOWrites` | `system.disk.operations.write` |
| `diskIOReadBytes` | `system.disk.io.read` |
| `diskIOWriteBytes` | `system.disk.io.write` |

#### catchall: health
| NMIS field | OTel name |
|-----------|-----------|
| `reachability` | `nmis.node.reachability` |
| `availability` | `nmis.node.availability` |
| `health` | `nmis.node.health` |
| `responsetime` | `nmis.node.response_time_ms` |
| `loss` | `nmis.node.packet_loss` |
| `cpuHealth` | `nmis.node.cpu_health` |
| `memHealth` | `nmis.node.mem_health` |
| `diskHealth` | `nmis.node.disk_health` |
| `swapHealth` | `nmis.node.swap_health` |

#### catchall: Host_Health
| NMIS field | OTel name |
|-----------|-----------|
| `hrSystemProcesses` | `system.process.count` |
| `hrSystemNumUsers` | `system.users.count` |

#### catchall: laload
| NMIS field | OTel name |
|-----------|-----------|
| `laLoad1` | `system.cpu.load_average.1m` |
| `laLoad5` | `system.cpu.load_average.5m` |

#### catchall: systemStats
| NMIS field | OTel name |
|-----------|-----------|
| `ssCpuRawUser` | `system.cpu.time.user` |
| `ssCpuRawSystem` | `system.cpu.time.system` |
| `ssCpuRawIdle` | `system.cpu.time.idle` |
| `ssCpuRawWait` | `system.cpu.time.wait` |
| `ssCpuRawNice` | `system.cpu.time.nice` |
| `ssCpuRawKernel` | `system.cpu.time.kernel` |
| `ssCpuRawInterrupt` | `system.cpu.time.interrupt` |
| `ssCpuRawSoftIRQ` | `system.cpu.time.soft_irq` |
| `ssIORawSent` | `system.disk.io.sent` |
| `ssIORawReceived` | `system.disk.io.received` |
| `ssRawInterrupts` | `system.cpu.interrupts` |
| `ssRawContexts` | `system.cpu.context_switches` |
| `ssRawSwapIn` | `system.memory.swap.in` |
| `ssRawSwapOut` | `system.memory.swap.out` |

#### catchall: tcp
| NMIS field | OTel name |
|-----------|-----------|
| `tcpCurrEstab` | `system.network.tcp.connections.established` |
| `tcpActiveOpens` | `system.network.tcp.connections.opened.active` |
| `tcpPassiveOpens` | `system.network.tcp.connections.opened.passive` |
| `tcpAttemptFails` | `system.network.tcp.connections.failed` |
| `tcpEstabResets` | `system.network.tcp.connections.reset` |
| `tcpInSegs` | `system.network.tcp.segments.received` |
| `tcpOutSegs` | `system.network.tcp.segments.sent` |
| `tcpRetransSegs` | `system.network.tcp.segments.retransmitted` |
| `tcpInErrs` | `system.network.tcp.errors.received` |
| `tcpOutRsts` | `system.network.tcp.resets.sent` |

#### catchall: mib2ip
| NMIS field | OTel name |
|-----------|-----------|
| `ipInReceives` | `system.network.ip.in_receives` |
| `ipInDelivers` | `system.network.ip.in_delivers` |
| `ipOutRequests` | `system.network.ip.out_requests` |
| `ipForwDatagrams` | `system.network.ip.forwarded` |
| `ipInDiscards` | `system.network.ip.in_discards` |
| `ipOutDiscards` | `system.network.ip.out_discards` |
| `ipInHdrErrors` | `system.network.ip.in_header_errors` |
| `ipInAddrErrors` | `system.network.ip.in_address_errors` |
| `ipInUnknownProtos` | `system.network.ip.in_unknown_protos` |
| `ipReasmReqds` | `system.network.ip.reassembly_required` |
| `ipReasmOKs` | `system.network.ip.reassembly_ok` |
| `ipReasmFails` | `system.network.ip.reassembly_failed` |
| `ipFragOKs` | `system.network.ip.fragmentation_ok` |
| `ipFragCreates` | `system.network.ip.fragments_created` |
| `ipFragFails` | `system.network.ip.fragmentation_failed` |

#### ping
| NMIS field | OTel name |
|-----------|-----------|
| `avg_ping_time` | `network.peer.rtt.avg_ms` |
| `max_ping_time` | `network.peer.rtt.max_ms` |
| `min_ping_time` | `network.peer.rtt.min_ms` |
| `ping_loss` | `network.peer.packet_loss` |

## Topic Structure

### catchall and ping (singletons)

Each subconcept is a separate message. No index or description suffix.

```
{base_topic}/{node_name}/{subconcept}
```

Examples:
- `obs/nmis/sol/health`
- `obs/nmis/sol/tcp`
- `obs/nmis/sol/laload`
- `obs/nmis/sol/mib2ip`
- `obs/nmis/sol/systemStats`
- `obs/nmis/sol/Host_Health`

### All other concepts

The description is used as the final path component (sanitized: leading `/` stripped, `/` → `-`, `:` → `-`, spaces → `_`). Falls back to the numeric index if no description is available.

```
{base_topic}/{node_name}/{concept}/{description}
```

Examples:
- `obs/nmis/sol/interface/GigabitEthernet0-0`
- `obs/nmis/sol/Host_Storage/Physical_memory`
- `obs/nmis/sol/diskIOTable/sda`
- `obs/nmis/sol/cpuLoad/1`

The `device` concept is published under the name `cpuLoad`.

## Testing

```bash
cd /home/keith/nmis-mqtt-observations
perl t_mqttobservations.pl
```

All 30 tests should pass.

## License

GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.

---

Built with [Claude Code](https://claude.ai/code)
