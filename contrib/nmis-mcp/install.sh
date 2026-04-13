#!/bin/bash
#
# install.sh - Install NMIS9 MCP server
#
# Usage: sudo ./install.sh
#

set -euo pipefail

NMIS_BASE="${NMIS_BASE:-/usr/local/nmis9}"
NMIS_CGI="${NMIS_BASE}/cgi-bin"
NMIS_CONF="${NMIS_BASE}/conf"
NMIS_USER="nmis"
NMIS_GROUP="nmis"
CGI_ALIAS="cgi-nmis9"   # Apache CGI alias that maps to cgi-bin/

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

if ! id "$NMIS_USER" &>/dev/null; then
    echo "Error: User '${NMIS_USER}' does not exist." >&2
    exit 1
fi

# --- Detect server hostname for config example ---

SERVER_HOST=""

# Try NMIS Config.nmis server_name first, then fall back to hostname
if [[ -f "${NMIS_CONF}/Config.nmis" ]]; then
    NMIS_SERVER=$(perl -ne "print \$1 if /'server_name'\s*=>\s*'([^']+)'/" "${NMIS_CONF}/Config.nmis" 2>/dev/null || true)
    if [[ -n "$NMIS_SERVER" ]]; then
        SERVER_HOST="$NMIS_SERVER"
    fi
fi

if [[ -z "$SERVER_HOST" ]]; then
    SERVER_HOST=$(hostname -f 2>/dev/null || hostname)
fi

MCP_URL="https://${SERVER_HOST}/${CGI_ALIAS}/nmis-mcp.pl"

# --- Generate or read API token ---

CONF_FILE="${NMIS_CONF}/nmis-mcp.nmis"
GENERATED_TOKEN=0

if [[ -f "$CONF_FILE" ]]; then
    # Read existing token
    API_TOKEN=$(perl -ne "print \$1 if /'api_token'\s*=>\s*'([^']+)'/" "$CONF_FILE" 2>/dev/null || true)
    if [[ -z "$API_TOKEN" || "$API_TOKEN" == "change-me-to-a-secure-token" ]]; then
        # Config exists but token is placeholder — generate and update it
        API_TOKEN=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
        perl -i -pe "s/'api_token'\s*=>\s*'[^']+'/'api_token' => '$API_TOKEN'/" "$CONF_FILE"
        GENERATED_TOKEN=1
        echo "  Updated ${CONF_FILE} with new API token"
    else
        echo "  ${CONF_FILE} (exists — keeping existing token)"
    fi
else
    # Generate new token and create config
    API_TOKEN=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
    GENERATED_TOKEN=1
fi

# --- Install files ---

echo "Installing NMIS MCP server..."

# Install the CGI script
echo "  ${NMIS_CGI}/nmis-mcp.pl"
cp "${SCRIPT_DIR}/nmis-mcp.pl" "${NMIS_CGI}/nmis-mcp.pl"
chown "${NMIS_USER}:${NMIS_GROUP}" "${NMIS_CGI}/nmis-mcp.pl"
chmod 755 "${NMIS_CGI}/nmis-mcp.pl"

# Install the config file (create with generated token if it didn't exist)
if [[ $GENERATED_TOKEN -eq 1 && ! -f "$CONF_FILE" ]]; then
    echo "  ${CONF_FILE} (created with generated token)"
    cat > "$CONF_FILE" <<EOF
#
# Configuration for the NMIS MCP (Model Context Protocol) server.
#
# Install this file to: /usr/local/nmis9/conf/nmis-mcp.nmis
# CGI endpoint:         /${CGI_ALIAS}/nmis-mcp.pl
#
%hash = (
	# API token for authentication.
	# Clients send:  X-API-Token: <api_token>
	#           or:  Authorization: Bearer <api_token>
	'api_token' => '${API_TOKEN}',
);
EOF
    chown "${NMIS_USER}:${NMIS_GROUP}" "$CONF_FILE"
    chmod 640 "$CONF_FILE"
fi

# --- Summary ---

echo ""
echo "Installation complete."
echo ""

if [[ $GENERATED_TOKEN -eq 1 ]]; then
    echo "  Generated API token: ${API_TOKEN}"
    echo ""
fi

echo "Claude Desktop config (~Library/Application Support/Claude/claude_desktop_config.json on macOS):"
echo ""
cat <<EOF
{
  "mcpServers": {
    "nmis": {
      "command": "npx",
      "args": [
        "mcp-remote@latest",
        "${MCP_URL}",
        "--header",
        "X-API-Token: \${AUTH_TOKEN}"
      ],
      "env": {
        "AUTH_TOKEN": "${API_TOKEN}"
      }
    }
  }
}
EOF
echo ""
echo "Tip: Replace ${MCP_URL} with your actual public hostname if different."
