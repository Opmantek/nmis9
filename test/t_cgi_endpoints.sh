#!/bin/bash
#
# t_cgi_endpoints.sh - NMIS9 CGI endpoint smoke test
#
# Hits read-only NMIS9 CGI endpoints via curl and checks each response is
# not a 5xx error. Also extracts <img src="/nmis9/cache/..."> references
# from graph-producing pages and fetches those PNGs to verify graph rendering.
#
# Usage:
#   ./t_cgi_endpoints.sh [--node NAME] [--host URL] [--user USER] [--password PASS]
#
# If --node is not supplied, the script picks a node from
# admin/polling_summary9.pl that has status=ontime, ping=up, snmp=up.
#
# The script never hits endpoints that modify configuration, delete data,
# or change settings - it is read-only.

set -u

NMIS_BASE="/usr/local/nmis9"
DEFAULT_HOST="http://localhost"
CGI_BASE="/cgi-nmis9"
STATIC_BASE="/nmis9"
DEFAULT_USER="nmis"
DEFAULT_PASS="nm1888"

HOST="$DEFAULT_HOST"
AUTH_USER="$DEFAULT_USER"
AUTH_PASS="$DEFAULT_PASS"
NODE=""
GROUP=""

PASS=0
FAIL=0
WARN=0
TOTAL=0
FAILED_LIST=()

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
usage() {
	cat <<EOF
Usage: $0 [options]

Options:
  --node NAME       Node name to use for node-specific tests
                    (default: auto-discover an actively-polled node)
  --host URL        Base URL of the NMIS server (default: $DEFAULT_HOST)
  --user USER       Auth username (default: $DEFAULT_USER)
  --password PASS   Auth password (default: $DEFAULT_PASS)
  --help            Show this help

Exit codes:
  0   all endpoints returned non-5xx responses
  1   one or more endpoints returned 5xx or other failures
  2   could not auto-discover a node
  3   authentication failed
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--node)     NODE="$2";      shift 2 ;;
		--host)     HOST="$2";      shift 2 ;;
		--user)     AUTH_USER="$2"; shift 2 ;;
		--password) AUTH_PASS="$2"; shift 2 ;;
		--help|-h)  usage; exit 0 ;;
		*)          echo "Unknown argument: $1" >&2; usage; exit 1 ;;
	esac
done

# ----------------------------------------------------------------------------
# Temp files and cleanup
# ----------------------------------------------------------------------------
COOKIE_JAR="$(mktemp -t nmis_cgi_test_cookies.XXXXXX)"
RESPONSE_BODY="$(mktemp -t nmis_cgi_test_body.XXXXXX)"
trap 'rm -f "$COOKIE_JAR" "$RESPONSE_BODY"' EXIT

# ----------------------------------------------------------------------------
# Node auto-discovery
# ----------------------------------------------------------------------------
discover_node() {
	# polling_summary9.pl emits one row per node with columns:
	#   node attempt status ping snmp policy delta ...
	# Pick the first row where status=ontime, ping=up, snmp=up.
	local picked
	picked=$("$NMIS_BASE/admin/polling_summary9.pl" 2>/dev/null \
		| awk '$3 == "ontime" && $4 == "up" && $5 == "up" { print $1; exit }')

	if [ -n "$picked" ]; then
		echo "$picked"
		return 0
	fi

	# Fall back to any node returned by node_admin.pl act=list
	"$NMIS_BASE/admin/node_admin.pl" act=list 2>/dev/null \
		| awk 'NF { print $1; exit }'
}

discover_group() {
	local node="$1"
	"$NMIS_BASE/admin/node_admin.pl" act=export node="$node" 2>/dev/null \
		| sed -n 's/.*"group" *: *"\([^"]*\)".*/\1/p' \
		| head -1
}

if [ -z "$NODE" ]; then
	NODE=$(discover_node)
	if [ -z "$NODE" ]; then
		echo "ERROR: could not auto-discover a node" >&2
		exit 2
	fi
fi

GROUP=$(discover_group "$NODE")
[ -z "$GROUP" ] && GROUP="NMIS"

# ----------------------------------------------------------------------------
# Authentication
# ----------------------------------------------------------------------------
do_login() {
	local code
	# Note: do NOT send auth_type=login - that is the signal to *show* the
	# login form. Credential verification is triggered simply by the presence
	# of auth_username/auth_password (see Auth.pm loginout, line ~1433/1442).
	code=$(curl -s -L \
		-c "$COOKIE_JAR" \
		--max-time 30 \
		-o "$RESPONSE_BODY" \
		-w "%{http_code}" \
		--data-urlencode "auth_username=$AUTH_USER" \
		--data-urlencode "auth_password=$AUTH_PASS" \
		--data-urlencode "login=Login" \
		"$HOST$CGI_BASE/nmiscgi.pl")

	if [ "$code" -lt 200 ] || [ "$code" -ge 400 ]; then
		echo "ERROR: login HTTP status $code" >&2
		return 1
	fi

	# A failed login re-renders the login form with an auth_password field.
	if grep -q 'name="auth_password"' "$RESPONSE_BODY"; then
		echo "ERROR: credentials rejected (login form returned)" >&2
		return 1
	fi

	# Any session cookie in the jar indicates a working session. NMIS can set
	# different cookie names depending on version/config (omk, CGISESSID,
	# nmis_auth, etc.). Cookie records are tab-separated; genuine comment
	# lines have no tabs. Note: curl marks HttpOnly cookies with a
	# "#HttpOnly_" prefix, which looks like a comment but still contains tabs.
	if ! grep -qP '\t' "$COOKIE_JAR"; then
		echo "ERROR: no session cookie set after login" >&2
		return 1
	fi

	return 0
}

# ----------------------------------------------------------------------------
# Test helpers
# ----------------------------------------------------------------------------
# test_url DESCRIPTION URL [check_images]
test_url() {
	local desc="$1"
	local url="$2"
	local check_images="${3:-0}"
	local code

	TOTAL=$((TOTAL + 1))

	code=$(curl -s -L \
		-b "$COOKIE_JAR" \
		-c "$COOKIE_JAR" \
		--max-time 30 \
		-o "$RESPONSE_BODY" \
		-w "%{http_code}" \
		"$HOST$url" 2>/dev/null)

	local curl_rc=$?

	if [ $curl_rc -ne 0 ]; then
		FAIL=$((FAIL + 1))
		FAILED_LIST+=("$desc [$url] (curl exit $curl_rc)")
		printf "  [FAIL] curl-%-3d  %-50s %s\n" "$curl_rc" "$desc" "$url"
		return 1
	fi

	if [ "$code" -ge 500 ]; then
		FAIL=$((FAIL + 1))
		FAILED_LIST+=("$desc [$url] (HTTP $code)")
		printf "  [FAIL] %-9s %-50s %s\n" "$code" "$desc" "$url"
		return 1
	elif [ "$code" -eq 403 ]; then
		FAIL=$((FAIL + 1))
		FAILED_LIST+=("$desc [$url] (HTTP 403 - auth/access denied)")
		printf "  [FAIL] %-9s %-50s %s\n" "$code" "$desc" "$url"
		return 1
	elif [ "$code" -eq 404 ]; then
		WARN=$((WARN + 1))
		printf "  [WARN] %-9s %-50s %s\n" "$code" "$desc" "$url"
	elif [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
		PASS=$((PASS + 1))
		printf "  [ OK ] %-9s %-50s %s\n" "$code" "$desc" "$url"
	else
		WARN=$((WARN + 1))
		printf "  [WARN] %-9s %-50s %s\n" "$code" "$desc" "$url"
	fi

	if [ "$check_images" = "1" ] && [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
		check_response_images
	fi

	return 0
}

# Extract <img src="/nmis9/cache/..."> URLs from the last response body and
# fetch each to verify the graph PNG was generated.
check_response_images() {
	local img_path code img_count=0 img_pass=0 img_fail=0

	# Pull out unique image cache paths
	local imgs
	imgs=$(grep -oE 'src="'"$STATIC_BASE"'/cache/[^"]+\.(png|gif|jpg)"' "$RESPONSE_BODY" \
		| sed -E 's/^src="//; s/"$//' \
		| sort -u)

	[ -z "$imgs" ] && return 0

	while IFS= read -r img_path; do
		[ -z "$img_path" ] && continue
		img_count=$((img_count + 1))
		TOTAL=$((TOTAL + 1))

		code=$(curl -s -L \
			-b "$COOKIE_JAR" \
			--max-time 30 \
			-o /dev/null \
			-w "%{http_code}" \
			"$HOST$img_path" 2>/dev/null)

		if [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
			PASS=$((PASS + 1))
			img_pass=$((img_pass + 1))
		else
			FAIL=$((FAIL + 1))
			img_fail=$((img_fail + 1))
			FAILED_LIST+=("graph image $img_path (HTTP $code)")
		fi
	done <<< "$imgs"

	if [ "$img_count" -gt 0 ]; then
		printf "         images: %d total, %d ok, %d failed\n" \
			"$img_count" "$img_pass" "$img_fail"
	fi
}

# Run a category - takes its name and the array name to iterate.
run_category() {
	local name="$1"
	local -n arr="$2"
	local entry desc url check_img

	echo ""
	echo "--- $name ---"
	for entry in "${arr[@]}"; do
		IFS='|' read -r desc url check_img <<< "$entry"
		test_url "$desc" "$url" "$check_img"
	done
}

# ----------------------------------------------------------------------------
# Endpoint definitions
# ----------------------------------------------------------------------------
W="widget=false"

DASHBOARD=(
	"Main Dashboard|$CGI_BASE/nmiscgi.pl?$W|0"
)

NETWORK_VIEWS=(
	"Network Summary Metrics|$CGI_BASE/network.pl?act=network_summary_metrics&$W|0"
	"Network Summary Health|$CGI_BASE/network.pl?act=network_summary_health&$W|0"
	"Network Summary View|$CGI_BASE/network.pl?act=network_summary_view&$W|0"
	"Network Summary Large|$CGI_BASE/network.pl?act=network_summary_large&$W|0"
	"Network Summary Small|$CGI_BASE/network.pl?act=network_summary_small&$W|0"
	"Network Summary All Groups|$CGI_BASE/network.pl?act=network_summary_allgroups&$W|0"
	"Network Summary Group=$GROUP|$CGI_BASE/network.pl?act=network_summary_group&group=$GROUP&$W|0"
	"Network Summary Customer|$CGI_BASE/network.pl?act=network_summary_customer&$W|0"
	"Network Summary Business|$CGI_BASE/network.pl?act=network_summary_business&$W|0"
	"Network Metrics Graph|$CGI_BASE/network.pl?act=network_metrics_graph&$W|1"
	"Network Top10 View|$CGI_BASE/network.pl?act=network_top10_view&$W|0"
	"Network Interface View|$CGI_BASE/network.pl?act=network_interface_view&node=$NODE&intf=1&$W|0"
	"Network Interface Overview|$CGI_BASE/network.pl?act=network_interface_overview&$W|0"
	"NMIS Runtime View|$CGI_BASE/network.pl?act=nmis_runtime_view&$W|1"
	"NMIS Polling Summary|$CGI_BASE/network.pl?act=nmis_polling_summary&$W|0"
	"NMIS Selftest View|$CGI_BASE/network.pl?act=nmis_selftest_view&$W|0"
	"Node Admin Summary|$CGI_BASE/network.pl?act=node_admin_summary&$W|0"
)

NODE_GRAPHS=(
	"Node Health Graph|$CGI_BASE/node.pl?act=network_graph_view&node=$NODE&graphtype=health&$W|1"
	"Node Response Graph|$CGI_BASE/node.pl?act=network_graph_view&node=$NODE&graphtype=response&$W|1"
	"Node Stats|$CGI_BASE/node.pl?act=network_stats&node=$NODE&$W|0"
	"Node Export Options|$CGI_BASE/node.pl?act=network_export_options&node=$NODE&$W|0"
)

TOOLS=(
	"Tool Ping ($NODE)|$CGI_BASE/tools.pl?act=tool_system_ping&node=$NODE&$W|0"
	"Tool Traceroute ($NODE)|$CGI_BASE/tools.pl?act=tool_system_trace&node=$NODE&$W|0"
	"Tool Host Info|$CGI_BASE/tools.pl?act=tool_system_hostinfo&$W|0"
	"Tool Date|$CGI_BASE/tools.pl?act=tool_system_date&$W|0"
	"Tool Disk Free|$CGI_BASE/tools.pl?act=tool_system_df&$W|0"
	"Tool Process List|$CGI_BASE/tools.pl?act=tool_system_ps&$W|0"
	"Tool Who|$CGI_BASE/tools.pl?act=tool_system_who&$W|0"
	"Tool DNS host|$CGI_BASE/tools.pl?act=tool_system_dns&dns=host&$W|0"
	"Tool DNS dns|$CGI_BASE/tools.pl?act=tool_system_dns&dns=dns&$W|0"
)

REPORTS=(
	"Report Health|$CGI_BASE/reports.pl?act=report_dynamic_health&$W|0"
	"Report Availability|$CGI_BASE/reports.pl?act=report_dynamic_avail&$W|0"
	"Report Response|$CGI_BASE/reports.pl?act=report_dynamic_response&$W|0"
	"Report Top10|$CGI_BASE/reports.pl?act=report_dynamic_top10&$W|0"
	"Report Outage|$CGI_BASE/reports.pl?act=report_dynamic_outage&$W|0"
	"Report Times|$CGI_BASE/reports.pl?act=report_dynamic_times&$W|0"
	"Report Port|$CGI_BASE/reports.pl?act=report_dynamic_port&$W|0"
)

EVENTS=(
	"Event Table List|$CGI_BASE/events.pl?act=event_table_list&$W|0"
	"Event Database List|$CGI_BASE/view-event.pl?act=event_database_list&$W|0"
	"Event Flow View|$CGI_BASE/view-event.pl?act=event_flow_view&$W|0"
)

SEARCH=(
	"Find Node Menu|$CGI_BASE/find.pl?act=find_node_menu&$W|0"
	"Find Interface Menu|$CGI_BASE/find.pl?act=find_interface_menu&$W|0"
	"Find Node View ($NODE)|$CGI_BASE/find.pl?act=find_node_view&find=$NODE&$W|0"
	"Find Interface View ($NODE)|$CGI_BASE/find.pl?act=find_interface_view&find=$NODE&$W|0"
)

LOGS=(
	"Log File View (default)|$CGI_BASE/logs.pl?act=log_file_view&lines=25&$W|0"
	"Log NMIS_Log View|$CGI_BASE/logs.pl?act=log_file_view&logname=NMIS_Log&lines=25&$W|0"
	"Log List View|$CGI_BASE/logs.pl?act=log_list_view&$W|0"
)

SERVICES=(
	"Services Overview|$CGI_BASE/services.pl?$W|0"
	"Services OK only|$CGI_BASE/services.pl?only_show=ok&$W|0"
	"Services Not OK only|$CGI_BASE/services.pl?only_show=notok&$W|0"
)

MENU=(
	"Menu Bar Site|$CGI_BASE/menu.pl?act=menu_bar_site&$W|0"
	"Menu Bar Portal|$CGI_BASE/menu.pl?act=menu_bar_portal&$W|0"
	"Menu About|$CGI_BASE/menu.pl?act=menu_about_view&$W|0"
)

MISC=(
	"IP Tools Menu|$CGI_BASE/ip.pl?act=tool_ip_menu&$W|0"
	"Community RSS|$CGI_BASE/community_rss.pl?$W|0"
	"Ops Status|$CGI_BASE/opstatus.pl?$W|0"
	"SNMP Var Menu|$CGI_BASE/snmp.pl?act=snmp_var_menu&$W|0"
	"Model Policy|$CGI_BASE/model_policy.pl?$W|0"
)

TABLES=(
	"Tables Links Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Links&$W|0"
	"Tables Nodes Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Nodes&$W|0"
	"Tables Nodes Show|$CGI_BASE/tables.pl?act=config_table_show&table=Nodes&$W|0"
	"Tables Contacts Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Contacts&$W|0"
	"Tables Escalations Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Escalations&$W|0"
	"Tables Events Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Events&$W|0"
	"Tables Polling-Policy Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Polling-Policy&$W|0"
)

CONFIG_RO=(
	"Config NMIS Menu|$CGI_BASE/config.pl?act=config_nmis_menu&$W|0"
	"Models Menu|$CGI_BASE/models.pl?act=config_model_menu&$W|0"
	"Nodeconf View|$CGI_BASE/nodeconf.pl?act=config_nodeconf_view&$W|0"
	"Outage Table View|$CGI_BASE/outages.pl?act=outage_table_view&$W|0"
)

# ----------------------------------------------------------------------------
# Main execution
# ----------------------------------------------------------------------------
echo "============================================================"
echo "NMIS9 CGI Endpoint Smoke Test"
echo "============================================================"
echo "Host:  $HOST"
echo "User:  $AUTH_USER"
echo "Node:  $NODE"
echo "Group: $GROUP"
echo "============================================================"

if ! do_login; then
	exit 3
fi
echo "Login: ok"

run_category "Dashboard"        DASHBOARD
run_category "Network Views"    NETWORK_VIEWS
run_category "Node Graphs"      NODE_GRAPHS
run_category "Tools"            TOOLS
run_category "Reports"          REPORTS
run_category "Events"           EVENTS
run_category "Search"           SEARCH
run_category "Logs"             LOGS
run_category "Services"         SERVICES
run_category "Menu"             MENU
run_category "Misc"             MISC
run_category "Tables"           TABLES
run_category "Config (read-only)" CONFIG_RO

echo ""
echo "============================================================"
echo "RESULTS: $PASS passed, $FAIL failed, $WARN warnings ($TOTAL total)"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
	echo ""
	echo "Failed endpoints:"
	for f in "${FAILED_LIST[@]}"; do
		echo "  - $f"
	done
	exit 1
fi

exit 0
