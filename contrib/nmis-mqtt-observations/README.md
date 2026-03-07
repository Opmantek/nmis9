# nmis-mqtt-observations

An NMIS collect plugin that publishes per-node latest data observations to an MQTT broker as JSON messages.

## Features

- Runs automatically after each NMIS collect cycle (no separate scheduling needed)
- Publishes one JSON message per inventory instance per configured concept
- Topic per message: `{base_topic}/{node_name}/{concept}/{index}`
- Each message includes node metadata (name, UUID, group, sysName, host, nodeType) alongside the collected metrics
- Skips nodes that are down or SNMP-unreachable (no stale data published)
- Configurable list of concepts (inventory types) to export
- Supports MQTT broker authentication
- Concept-aware description field mapping for human-readable instance labels

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
    'extra_logging' => 0,                 # set to 1 for per-message debug logs
  },
  'concepts' => [
    'interface',
    'catchall',
    'Host_Storage',
  ],
);
```

### Concepts

The `concepts` list controls which NMIS inventory types are exported. Common values:

| Concept | Description | Key fields |
|---------|-------------|------------|
| `interface` | Network interfaces | ifDescr, ifOperStatus, traffic counters |
| `catchall` | General node info | sysName, sysDescr, reachability |
| `Host_Storage` | Disk/memory storage | hrStorageDescr, utilisation |
| `Host_File_System` | File systems | hrFSMountPoint |
| `entityMib` | Hardware entities | entPhysicalName, entPhysicalDescr |
| `cdp` | CDP neighbours | cdpCacheDeviceId |
| `lldp` | LLDP neighbours | lldpRemSysName |
| `bgp` | BGP peers | bgpPeerIdentifier |

Only concepts in this list are published. Add or remove entries to suit your environment.

## Message Format

Each MQTT message is a JSON object:

```json
{
  "node_name":   "router1",
  "node_uuid":   "550e8400-e29b-41d4-a716-446655440000",
  "group":       "Core",
  "sysName":     "router1.example.com",
  "host":        "192.168.1.1",
  "nodeType":    "router",
  "concept":     "interface",
  "index":       "3",
  "description": "GigabitEthernet0/0",
  "timestamp":   1708600000,
  "data": {
    "interface": {
      "ifDescr":       "GigabitEthernet0/0",
      "ifOperStatus":  "up",
      "ifAdminStatus": "up",
      "ifSpeed":       1000000000
    },
    "pkts_hc": {
      "ifHCInOctets":         12345678,
      "ifHCOutOctets":        87654321,
      "ifHCInUcastPkts":      9876,
      "ifHCOutUcastPkts":     5432
    }
  }
}
```

The `data` object is keyed by subconcept name. Each subconcept contains the flat metrics collected for that inventory instance at the time of the last successful poll.

## Topic Structure

```
{base_topic}/{node_name}/{concept}/{index}
```

Examples:
- `obs/nmis/router1/interface/GigabitEthernet0_0`
- `obs/nmis/router1/catchall/0`
- `obs/nmis/server1/Host_Storage/1`

Forward slashes in index values are replaced with underscores. The `catchall` concept is a singleton and always uses index `0`.

## License

GNU General Public License v3.0. See the [LICENSE](../../LICENSE) file for details.

---

Built with [Claude Code](https://claude.ai/code)
