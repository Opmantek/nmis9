#!/bin/bash
#
# install.sh - Install nmis-mqtt-event notification plugin for NMIS 9
#
# Usage: sudo ./install.sh
#

set -euo pipefail

NMIS_BASE="/usr/local/nmis9"
NMIS_LIB="${NMIS_BASE}/lib/Notify"
NMIS_CONF="${NMIS_BASE}/conf"
NMIS_USER="nmis"
NMIS_GROUP="nmis"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Preflight checks ---

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

if [[ ! -d "$NMIS_BASE" ]]; then
    echo "Error: NMIS base directory not found at ${NMIS_BASE}" >&2
    exit 1
fi

# Verify the nmis user/group exist
if ! id "$NMIS_USER" &>/dev/null; then
    echo "Error: User '${NMIS_USER}' does not exist." >&2
    exit 1
fi

# Check for Net::MQTT::Simple
if ! perl -MNet::MQTT::Simple -e 1 2>/dev/null; then
    echo "Warning: Perl module Net::MQTT::Simple is not installed."
    echo "  Install it with: cpanm Net::MQTT::Simple"
    echo ""
    read -rp "Continue anyway? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# --- Install files ---

echo "Installing nmis-mqtt-event plugin..."

# Ensure the Notify directory exists
mkdir -p "$NMIS_LIB"

# Install the plugin module
echo "  ${NMIS_LIB}/mqttevent.pm"
cp "${SCRIPT_DIR}/mqttevent.pm" "${NMIS_LIB}/mqttevent.pm"
chown "${NMIS_USER}:${NMIS_GROUP}" "${NMIS_LIB}/mqttevent.pm"
chmod 640 "${NMIS_LIB}/mqttevent.pm"

# Install the config file (don't overwrite if it already exists)
if [[ -f "${NMIS_CONF}/mqttevent.nmis" ]]; then
    echo "  ${NMIS_CONF}/mqttevent.nmis (exists - skipped, not overwriting)"
else
    echo "  ${NMIS_CONF}/mqttevent.nmis"
    cp "${SCRIPT_DIR}/mqttevent.nmis" "${NMIS_CONF}/mqttevent.nmis"
    chown "${NMIS_USER}:${NMIS_GROUP}" "${NMIS_CONF}/mqttevent.nmis"
    chmod 640 "${NMIS_CONF}/mqttevent.nmis"
fi

# Install the ignore list (don't overwrite if it already exists)
if [[ -f "${NMIS_CONF}/mqttIgnoreList.txt" ]]; then
    echo "  ${NMIS_CONF}/mqttIgnoreList.txt (exists - skipped, not overwriting)"
else
    echo "  ${NMIS_CONF}/mqttIgnoreList.txt"
    cp "${SCRIPT_DIR}/mqttIgnoreList.txt" "${NMIS_CONF}/mqttIgnoreList.txt"
    chown "${NMIS_USER}:${NMIS_GROUP}" "${NMIS_CONF}/mqttIgnoreList.txt"
    chmod 640 "${NMIS_CONF}/mqttIgnoreList.txt"
fi

echo ""
echo "Installation complete."
echo ""
echo "Next steps:"
echo "  1. Edit ${NMIS_CONF}/mqttevent.nmis with your MQTT broker details."
echo "  2. (Optional) Edit ${NMIS_CONF}/mqttIgnoreList.txt to filter events."
echo "  3. Configure NMIS to use Notify::mqttevent for your desired events."
