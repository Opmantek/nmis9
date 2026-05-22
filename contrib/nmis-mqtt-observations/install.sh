#!/bin/bash
#
# Install script for the MqttObservations NMIS collect plugin.
#
# Usage: sudo ./install.sh
#

set -e

NMIS_HOME="${NMIS_HOME:-/usr/local/nmis9}"
PLUGIN_DIR="$NMIS_HOME/conf/plugins"
CONF_DIR="$NMIS_HOME/conf"
OWNER="nmis:nmis"

echo "=== MqttObservations NMIS Plugin Installer ==="
echo "NMIS home: $NMIS_HOME"

# Check NMIS installation
if [ ! -d "$NMIS_HOME/lib" ]; then
	echo "ERROR: NMIS not found at $NMIS_HOME. Set NMIS_HOME to override."
	exit 1
fi

# Check for required Perl module
echo "Checking for Net::MQTT::Simple..."
if ! perl -e 'use Net::MQTT::Simple' 2>/dev/null; then
	echo "ERROR: Net::MQTT::Simple is not installed."
	echo "Install it with:  cpanm Net::MQTT::Simple"
	echo "                  or: apt install libnet-mqtt-simple-perl"
	exit 1
fi
echo "  Net::MQTT::Simple OK"

# Create plugins directory if needed
if [ ! -d "$PLUGIN_DIR" ]; then
	echo "Creating $PLUGIN_DIR ..."
	mkdir -p "$PLUGIN_DIR"
	chown "$OWNER" "$PLUGIN_DIR"
fi

# Install plugin
echo "Installing mqttobservations.pm -> $PLUGIN_DIR/"
cp mqttobservations.pm "$PLUGIN_DIR/mqttobservations.pm"
chown "$OWNER" "$PLUGIN_DIR/mqttobservations.pm"
chmod 640 "$PLUGIN_DIR/mqttobservations.pm"

# Install config (do not overwrite existing)
if [ -f "$CONF_DIR/mqttobservations.nmis" ]; then
	echo "Config $CONF_DIR/mqttobservations.nmis already exists — not overwriting."
	echo "  Check contrib/nmis-mqtt-observations/mqttobservations.nmis for new options."
else
	echo "Installing mqttobservations.nmis -> $CONF_DIR/"
	cp mqttobservations.nmis "$CONF_DIR/mqttobservations.nmis"
	chown "$OWNER" "$CONF_DIR/mqttobservations.nmis"
	chmod 640 "$CONF_DIR/mqttobservations.nmis"
	echo ""
	echo "IMPORTANT: Edit $CONF_DIR/mqttobservations.nmis and set your MQTT broker details."
fi

echo ""
echo "Installation complete."
echo "The plugin will run automatically after each NMIS collect cycle."
