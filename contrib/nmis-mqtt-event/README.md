# nmis-mqtt-event

An NMIS notification plugin that publishes NMIS events to an MQTT broker as JSON messages.

## Features

- Publishes NMIS events to a configurable MQTT topic (per-node subtopics)
- Supports MQTT authentication (username/password)
- Configurable ignore list using regex patterns to filter unwanted events
- Enriches events with extra details (host name, formatted date, optional group info)
- JSON-formatted MQTT messages

## Requirements

- [NMIS](https://community.opmantek.com/display/NMIS) (tested with NMIS 9)
- Perl module: [Net::MQTT::Simple](https://metacpan.org/pod/Net::MQTT::Simple)

## Installation

### Quick Install

```bash
sudo ./install.sh
```

The install script will:
- Check for required dependencies (`Net::MQTT::Simple`)
- Copy `mqttevent.pm` to `/usr/local/nmis9/lib/Notify/`
- Copy config files to `/usr/local/nmis9/conf/` (won't overwrite existing ones)
- Set ownership to `nmis:nmis` and permissions to `640`

### Manual Install

1. Install the required Perl module:

   ```bash
   cpanm Net::MQTT::Simple
   ```

2. Copy the plugin to your NMIS installation:

   ```bash
   cp mqttevent.pm /usr/local/nmis9/lib/Notify/mqttevent.pm
   cp mqttevent.nmis /usr/local/nmis9/conf/mqttevent.nmis
   cp mqttIgnoreList.txt /usr/local/nmis9/conf/mqttIgnoreList.txt
   chown nmis:nmis /usr/local/nmis9/lib/Notify/mqttevent.pm /usr/local/nmis9/conf/mqttevent.nmis /usr/local/nmis9/conf/mqttIgnoreList.txt
   chmod 640 /usr/local/nmis9/lib/Notify/mqttevent.pm /usr/local/nmis9/conf/mqttevent.nmis /usr/local/nmis9/conf/mqttIgnoreList.txt
   ```

### Configuration

1. Edit `/usr/local/nmis9/conf/mqttevent.nmis` with your MQTT broker details:

   ```perl
   %hash = (
     'mqtt' => {
       'topic'         => 'nmis/event',
       'server'        => 'your.mqtt.server:1883',
       'username'      => 'your_mqtt_username',
       'password'      => 'your_mqtt_password',
       'extra_logging' => 0,
     }
   );
   ```

2. *(Optional)* Edit `/usr/local/nmis9/conf/mqttIgnoreList.txt` with one regex per line to filter events:

   ```
   Node Down
   Interface Down
   ```

3. Configure NMIS to use `Notify::mqttevent` as a notification method for the desired events.

You will need to use the NMIS Escalation system to tell NMIS when to send events to MQTT, for details refer to [Custom Notification Methods for NMIS Events](https://docs.community.firstwave.com/wiki/spaces/NMIS/pages/3165685741/Custom+Notification+Methods+for+NMIS+Events) and [NMIS8 Escalations](https://docs.community.firstwave.com/wiki/spaces/NMIS/pages/3165685353/NMIS8+Escalations) these work the same way in NMIS9.

Generally speaking adding the MQTT method to default escalation at level0 would likely be what you would need, this will send every event to MQTT.  If you preferred a little dampening, add it to level1 or level2, this would remove the transient flapping events from going to MQTT.

```
 'default_default_default_default__' => {
   'Event' => 'default',
   'Event_Element' => '',
   'Event_Node' => '',
   'Group' => 'default',
   'Level0' => 'syslog:localhost,json:localhost,mqttevent:Contact1',
   'Level1' => '',
   'Level2' => '',
   'Level3' => '',
   'Level4' => '',
   'Level5' => '',
   'Level6' => '',
   'Level7' => '',
   'Level8' => '',
   'Level9' => '',
   'Level10' => '',
   'Role' => 'default',
   'Type' => 'default',
   'UpNotify' => 'true'
 },
 ```

## How It Works

When NMIS triggers a notification, this plugin:

1. Reads MQTT connection settings from `conf/mqttevent.nmis`
2. Checks the event against the ignore list — matching events are silently skipped
3. Enriches the event with the NMIS server hostname and a human-readable date string
4. Publishes the event as a JSON object to `<topic>/<node_name>` on the configured MQTT broker

## License

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.

---

Built with [Claude Code](https://claude.ai/code)
