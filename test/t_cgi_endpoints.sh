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
#                        [--save FILE] [--compare FILE]
#
# If --node is not supplied, the script picks a node from
# admin/polling_summary9.pl that has status=ontime, ping=up, snmp=up.
#
# The script avoids endpoints that modify configuration, delete data, or change
# settings. A handful of benign-but-mutating actions (e.g. nmis_selftest_reset)
# are included because the user has asked that they be verified not to 500.
# Endpoints skipped entirely are listed in the SKIPPED array below for manual
# testing (uncomment the matching run_category line at the bottom of main).
#
# Examples:
#   # one-off smoke test
#   ./t_cgi_endpoints.sh
#
#   # baseline a known-good install
#   ./t_cgi_endpoints.sh --save /var/tmp/nmis_baseline.tsv
#
#   # check for regressions against that baseline
#   ./t_cgi_endpoints.sh --compare /var/tmp/nmis_baseline.tsv
#
#   # produce today's baseline while comparing against the old one
#   ./t_cgi_endpoints.sh --save /var/tmp/nmis_today.tsv \
#                        --compare /var/tmp/nmis_baseline.tsv
#
#   # target a specific node and a non-default host
#   ./t_cgi_endpoints.sh --node localhost --host http://nmis.example.com

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
SAVE_FILE=""
COMPARE_FILE=""

PASS=0
FAIL=0
WARN=0
TOTAL=0
FAILED_LIST=()
# Each entry: "URL<TAB>HTTP_CODE<TAB>KIND<TAB>IMG_COUNT<TAB>IMG_OK<TAB>IMG_FAIL"
RESULTS=()

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
  --save FILE       Save per-URL results (TSV) to FILE after the run.
                    Columns: URL<tab>HTTP_CODE<tab>KIND<tab>IMG_COUNT<tab>
                    IMG_OK<tab>IMG_FAIL. Rows are sorted by URL.
  --compare FILE    Compare live results against FILE (a previous --save).
                    Reports status-code changes, new URLs, removed URLs,
                    and (as warnings) image-count changes.
  --help            Show this help

Exit codes:
  0   all endpoints returned non-5xx responses (and no diffs with --compare)
  1   one or more endpoints returned 5xx or other failures (takes priority)
  2   could not auto-discover a node
  3   authentication failed
  4   --compare found differences (but no endpoint failures)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--node)     NODE="$2";      shift 2 ;;
		--host)     HOST="$2";      shift 2 ;;
		--user)     AUTH_USER="$2"; shift 2 ;;
		--password) AUTH_PASS="$2"; shift 2 ;;
		--save)     SAVE_FILE="$2"; shift 2 ;;
		--compare)  COMPARE_FILE="$2"; shift 2 ;;
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
# Globals set by check_response_images and consumed by test_url to record
# per-endpoint image stats in the RESULTS array.
LAST_IMG_COUNT=0
LAST_IMG_OK=0
LAST_IMG_FAIL=0

# test_url DESCRIPTION URL [check_images]
test_url() {
	local desc="$1"
	local url="$2"
	local check_images="${3:-0}"
	local code
	local img_c="-" img_o="-" img_f="-"

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
		# Record as pseudo-code "curl-NN" so save/compare can see timeouts etc.
		record_result "$url" "curl-$curl_rc" "endpoint" "-" "-" "-"
		return 1
	fi

	if [ "$code" -ge 500 ]; then
		FAIL=$((FAIL + 1))
		FAILED_LIST+=("$desc [$url] (HTTP $code)")
		printf "  [FAIL] %-9s %-50s %s\n" "$code" "$desc" "$url"
		record_result "$url" "$code" "endpoint" "-" "-" "-"
		return 1
	elif [ "$code" -eq 403 ]; then
		FAIL=$((FAIL + 1))
		FAILED_LIST+=("$desc [$url] (HTTP 403 - auth/access denied)")
		printf "  [FAIL] %-9s %-50s %s\n" "$code" "$desc" "$url"
		record_result "$url" "$code" "endpoint" "-" "-" "-"
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
		LAST_IMG_COUNT=0; LAST_IMG_OK=0; LAST_IMG_FAIL=0
		check_response_images
		img_c="$LAST_IMG_COUNT"
		img_o="$LAST_IMG_OK"
		img_f="$LAST_IMG_FAIL"
	fi

	record_result "$url" "$code" "endpoint" "$img_c" "$img_o" "$img_f"
	return 0
}

# Append one tab-separated row to the RESULTS array.
# Args: URL HTTP_CODE KIND IMG_COUNT IMG_OK IMG_FAIL
record_result() {
	local tab=$'\t'
	RESULTS+=("$1$tab$2$tab$3$tab$4$tab$5$tab$6")
}

# Extract <img src="/nmis9/cache/..."> URLs from the last response body and
# fetch each to verify the graph PNG was generated. Populates LAST_IMG_*
# globals for the caller to include in its RESULTS record.
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

		# Note: intentionally NOT calling record_result here. Graph cache
		# URLs contain "<md5>_<start>_<end>.png" where start/end are
		# time() values, so each run produces different URLs even when the
		# rendering pipeline is healthy. The per-endpoint IMG_COUNT / IMG_OK /
		# IMG_FAIL stats already capture whether graphs rendered correctly
		# and are stable across runs.
	done <<< "$imgs"

	if [ "$img_count" -gt 0 ]; then
		printf "         images: %d total, %d ok, %d failed\n" \
			"$img_count" "$img_pass" "$img_fail"
	fi

	LAST_IMG_COUNT=$img_count
	LAST_IMG_OK=$img_pass
	LAST_IMG_FAIL=$img_fail
}

# Write the RESULTS array to FILE as sorted TSV with a metadata header.
# Args: file path
write_results_file() {
	local path="$1"
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	{
		printf "# NMIS9 CGI smoke test results\n"
		printf "# timestamp: %s\n" "$ts"
		printf "# host:      %s\n" "$HOST"
		printf "# user:      %s\n" "$AUTH_USER"
		printf "# node:      %s\n" "$NODE"
		printf "# group:     %s\n" "$GROUP"
		printf "# columns:   URL\\tHTTP_CODE\\tKIND\\tIMG_COUNT\\tIMG_OK\\tIMG_FAIL\n"
		# Sort by URL (first column, tab-delimited) for deterministic output.
		printf "%s\n" "${RESULTS[@]}" | LC_ALL=C sort -t $'\t' -k1,1
	} > "$path"
}

# Compare live RESULTS to baseline file.
# Args: baseline file path
# Returns: 0 if no differences, 1 if any differences found.
compare_to_baseline() {
	local path="$1"
	local diffs=0
	local warnings=0
	local url code kind imgc imgo imgf
	local base_code base_kind base_imgc

	# Build associative arrays from the baseline, keyed by URL.
	declare -A BASE_CODE BASE_KIND BASE_IMGC BASE_IMGO BASE_IMGF
	while IFS=$'\t' read -r url code kind imgc imgo imgf; do
		# Skip comment/blank lines
		[[ "$url" =~ ^# ]] && continue
		[ -z "$url" ] && continue
		BASE_CODE["$url"]="$code"
		BASE_KIND["$url"]="$kind"
		BASE_IMGC["$url"]="$imgc"
		BASE_IMGO["$url"]="$imgo"
		BASE_IMGF["$url"]="$imgf"
	done < "$path"

	# Walk live results, compare each to baseline.
	declare -A LIVE_SEEN
	local entry
	for entry in "${RESULTS[@]}"; do
		IFS=$'\t' read -r url code kind imgc imgo imgf <<< "$entry"
		LIVE_SEEN["$url"]=1

		if [ -z "${BASE_CODE[$url]+_}" ]; then
			printf "  [NEW]      %s (status %s)\n" "$url" "$code"
			diffs=$((diffs + 1))
			continue
		fi

		base_code="${BASE_CODE[$url]}"
		base_imgc="${BASE_IMGC[$url]}"

		if [ "$code" != "$base_code" ]; then
			printf "  [CHANGED]  %s : %s -> %s\n" "$url" "$base_code" "$code"
			diffs=$((diffs + 1))
		fi
		# Image count drift is a warning only (structural change, not a bug).
		if [ "$imgc" != "-" ] && [ "$base_imgc" != "-" ] && [ "$imgc" != "$base_imgc" ]; then
			printf "  [IMG#]     %s : images %s -> %s (warning)\n" \
				"$url" "$base_imgc" "$imgc"
			warnings=$((warnings + 1))
		fi
	done

	# Walk baseline for URLs the live run didn't hit.
	for url in "${!BASE_CODE[@]}"; do
		if [ -z "${LIVE_SEEN[$url]+_}" ]; then
			printf "  [REMOVED]  %s (was %s)\n" "$url" "${BASE_CODE[$url]}"
			diffs=$((diffs + 1))
		fi
	done

	echo ""
	if [ $diffs -eq 0 ] && [ $warnings -eq 0 ]; then
		echo "No differences from baseline."
	else
		echo "Differences: $diffs changed/new/removed, $warnings image-count warnings."
	fi

	return $diffs
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
	"NMIS Selftest Reset|$CGI_BASE/network.pl?act=nmis_selftest_reset&$W|0"
	"Node Admin Summary|$CGI_BASE/network.pl?act=node_admin_summary&$W|0"
)

# Node-scoped network views - each requires node=$NODE. Subs live in
# network.pl; see the dispatcher around line 192-245.
NODE_VIEWS=(
	"Network Node View|$CGI_BASE/network.pl?act=network_node_view&node=$NODE&$W|1"
	"Network Storage View|$CGI_BASE/network.pl?act=network_storage_view&node=$NODE&$W|0"
	"Network Service View|$CGI_BASE/network.pl?act=network_service_view&node=$NODE&$W|0"
	"Network Service List|$CGI_BASE/network.pl?act=network_service_list&node=$NODE&$W|0"
	"Network CPU List|$CGI_BASE/network.pl?act=network_cpu_list&node=$NODE&$W|0"
	"Network Status View|$CGI_BASE/network.pl?act=network_status_view&node=$NODE&$W|0"
	"Network System Health|$CGI_BASE/network.pl?act=network_system_health_view&node=$NODE&$W|0"
	"Network Port View|$CGI_BASE/network.pl?act=network_port_view&node=$NODE&$W|0"
	"Network Interface View All|$CGI_BASE/network.pl?act=network_interface_view_all&node=$NODE&$W|0"
	"Network Interface View Active|$CGI_BASE/network.pl?act=network_interface_view_act&node=$NODE&$W|0"
)

NODE_GRAPHS=(
	"Node Health Graph|$CGI_BASE/node.pl?act=network_graph_view&node=$NODE&graphtype=health&$W|1"
	"Node Response Graph|$CGI_BASE/node.pl?act=network_graph_view&node=$NODE&graphtype=response&$W|1"
	"Node Stats|$CGI_BASE/node.pl?act=network_stats&node=$NODE&$W|0"
	"Node Export Options|$CGI_BASE/node.pl?act=network_export_options&node=$NODE&$W|0"
	"Node Export|$CGI_BASE/node.pl?act=network_export&node=$NODE&$W|0"
)

TOOLS=(
	"Tool Ping ($NODE)|$CGI_BASE/tools.pl?act=tool_system_ping&node=$NODE&$W|0"
	"Tool Traceroute ($NODE)|$CGI_BASE/tools.pl?act=tool_system_trace&node=$NODE&$W|0"
	"Tool Nslookup ($NODE)|$CGI_BASE/tools.pl?act=tool_system_nslookup&node=$NODE&$W|0"
	"Tool Finger ($NODE)|$CGI_BASE/tools.pl?act=tool_system_finger&node=$NODE&$W|0"
	"Tool LFT ($NODE)|$CGI_BASE/tools.pl?act=tool_system_lft&node=$NODE&$W|0"
	"Tool MTR ($NODE)|$CGI_BASE/tools.pl?act=tool_system_mtr&node=$NODE&$W|0"
	"Tool SNMP ($NODE)|$CGI_BASE/tools.pl?act=tool_system_snmp&node=$NODE&$W|0"
	"Tool Mank ($NODE)|$CGI_BASE/tools.pl?act=tool_system_mank&node=$NODE&$W|0"
	"Tool Collect|$CGI_BASE/tools.pl?act=tool_system_collect&$W|0"
	"Tool Host Info|$CGI_BASE/tools.pl?act=tool_system_hostinfo&$W|0"
	"Tool Date|$CGI_BASE/tools.pl?act=tool_system_date&$W|0"
	"Tool Disk Free|$CGI_BASE/tools.pl?act=tool_system_df&$W|0"
	"Tool Process List|$CGI_BASE/tools.pl?act=tool_system_ps&$W|0"
	"Tool IOStat|$CGI_BASE/tools.pl?act=tool_system_iostat&$W|0"
	"Tool VMStat|$CGI_BASE/tools.pl?act=tool_system_vmstat&$W|0"
	"Tool Who|$CGI_BASE/tools.pl?act=tool_system_who&$W|0"
	"Tool DNS host|$CGI_BASE/tools.pl?act=tool_system_dns&dns=host&$W|0"
	"Tool DNS dns|$CGI_BASE/tools.pl?act=tool_system_dns&dns=dns&$W|0"
	"Tool DNS arpa|$CGI_BASE/tools.pl?act=tool_system_dns&dns=arpa&$W|0"
	"Tool DNS loc|$CGI_BASE/tools.pl?act=tool_system_dns&dns=loc&$W|0"
)

REPORTS=(
	"Report Health|$CGI_BASE/reports.pl?act=report_dynamic_health&$W|0"
	"Report Availability|$CGI_BASE/reports.pl?act=report_dynamic_avail&$W|0"
	"Report Response|$CGI_BASE/reports.pl?act=report_dynamic_response&$W|0"
	"Report Top10|$CGI_BASE/reports.pl?act=report_dynamic_top10&$W|0"
	"Report Outage|$CGI_BASE/reports.pl?act=report_dynamic_outage&$W|0"
	"Report Times|$CGI_BASE/reports.pl?act=report_dynamic_times&$W|0"
	"Report Port|$CGI_BASE/reports.pl?act=report_dynamic_port&$W|0"
	"Report Stored Health|$CGI_BASE/reports.pl?act=report_stored_health&$W|0"
	"Report Stored Availability|$CGI_BASE/reports.pl?act=report_stored_avail&$W|0"
	"Report Stored Response|$CGI_BASE/reports.pl?act=report_stored_response&$W|0"
	"Report Stored Port|$CGI_BASE/reports.pl?act=report_stored_port&$W|0"
	"Report Stored Top10|$CGI_BASE/reports.pl?act=report_stored_top10&$W|0"
	"Report Stored Outage|$CGI_BASE/reports.pl?act=report_stored_outage&$W|0"
	"Report Stored Times|$CGI_BASE/reports.pl?act=report_stored_times&$W|0"
	"Report Stored File|$CGI_BASE/reports.pl?act=report_stored_file&$W|0"
	"Report CSV Node Details|$CGI_BASE/reports.pl?act=report_csv_nodedetails&$W|0"
)

EVENTS=(
	"Event Table List|$CGI_BASE/events.pl?act=event_table_list&$W|0"
	"Event Table View ($NODE)|$CGI_BASE/events.pl?act=event_table_view&node=$NODE&$W|0"
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
	"Log File Summary|$CGI_BASE/logs.pl?act=log_file_summary&logname=NMIS_Log&$W|0"
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
	"Access Menu Load|$CGI_BASE/access.pl?act=access_menu_load&$W|0"
	"Modules Page|$CGI_BASE/modules.pl?module=opCharts&$W|0"
)

TABLES=(
	"Tables Links Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Links&$W|0"
	"Tables Nodes Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Nodes&$W|0"
	"Tables Nodes Show|$CGI_BASE/tables.pl?act=config_table_show&table=Nodes&$W|0"
	"Tables Nodes View ($NODE)|$CGI_BASE/tables.pl?act=config_table_view&table=Nodes&key=$NODE&$W|0"
	"Tables Contacts Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Contacts&$W|0"
	"Tables Contacts Add (form)|$CGI_BASE/tables.pl?act=config_table_add&table=Contacts&$W|0"
	"Tables Escalations Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Escalations&$W|0"
	"Tables Events Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Events&$W|0"
	"Tables Polling-Policy Menu|$CGI_BASE/tables.pl?act=config_table_menu&table=Polling-Policy&$W|0"
)

CONFIG_RO=(
	"Config NMIS Menu|$CGI_BASE/config.pl?act=config_nmis_menu&$W|0"
	"Config NMIS Edit Form|$CGI_BASE/config.pl?act=config_nmis_edit&section=system&item=nmis_user&$W|0"
	"Models Menu|$CGI_BASE/models.pl?act=config_model_menu&$W|0"
	"Nodeconf View|$CGI_BASE/nodeconf.pl?act=config_nodeconf_view&$W|0"
	"Outage Table View|$CGI_BASE/outages.pl?act=outage_table_view&$W|0"
)

# ----------------------------------------------------------------------------
# SKIPPED array - endpoints NOT run by default. Listed here so they are easy
# to find and enable when investigating a specific regression.
#
# Two opt-in mechanisms:
#   1. Uncomment the `run_category "Skipped (manual)" SKIPPED` line in main
#      (at the bottom of the run_category calls) to run them all.
#   2. Copy an individual entry into any other active array to run just one.
#
# Reasons endpoints end up here:
#   - Need discovery data we can't reliably get (real event UUIDs, service
#     names, table keys).
#   - Mutation action (add/edit/delete/doadd/doedit/dodelete) - included so
#     the full URL shape is preserved for manual testing with known-safe args.
#   - Not a useful GUI test (e.g. tool_system_man).
# ----------------------------------------------------------------------------
SKIPPED=(
	# --- non-mutating but need discovery data ---
	"SKIP (needs node_uuid/event/element): Event Database View|$CGI_BASE/view-event.pl?act=event_database_view&node_uuid=UUID&event=EVENT&element=ELEMENT&$W|0"
	"SKIP (needs service=): Services Details|$CGI_BASE/services.pl?act=details&node=$NODE&service=SERVICE&$W|0"
	"SKIP (covered by image extraction): Draw Graph View|$CGI_BASE/rrddraw.pl?act=draw_graph_view&obj=node&node=$NODE&graphtype=health&start=0&end=0&width=400&height=120&$W|0"
	# --- tools exclusion ---
	"SKIP (not a useful GUI test): Tool Man|$CGI_BASE/tools.pl?act=tool_system_man&node=$NODE&$W|0"
	# --- display forms duplicative of _view/_menu coverage ---
	"SKIP (needs key=): Tables Nodes Edit Form|$CGI_BASE/tables.pl?act=config_table_edit&table=Nodes&key=$NODE&$W|0"
	"SKIP (needs key=): Tables Nodes Delete Confirm|$CGI_BASE/tables.pl?act=config_table_delete&table=Nodes&key=$NODE&$W|0"
	"SKIP: Config NMIS Add Form|$CGI_BASE/config.pl?act=config_nmis_add&$W|0"
	"SKIP (needs section+item): Config NMIS Delete Confirm|$CGI_BASE/config.pl?act=config_nmis_delete&section=system&item=nmis_user&$W|0"
	"SKIP: Models Add Form|$CGI_BASE/models.pl?act=config_model_add&$W|0"
	"SKIP (needs model=): Models Edit Form|$CGI_BASE/models.pl?act=config_model_edit&model=Default&$W|0"
	"SKIP (needs model=): Models Delete Confirm|$CGI_BASE/models.pl?act=config_model_delete&model=Default&$W|0"
	# --- setup wizard ---
	"SKIP (setup wizard): Setup Menu|$CGI_BASE/setup.pl?act=setup_menu&$W|0"
	"SKIP (MUTATES - setup commit): Setup Do-Edit|$CGI_BASE/setup.pl?act=setup_doedit&$W|0"
	# --- MUTATING - only ever test manually with known-safe args ---
	"SKIP (MUTATES - add outage): Outage Add|$CGI_BASE/outages.pl?act=outage_table_doadd&node=$NODE&start=0&end=0&$W|0"
	"SKIP (MUTATES - delete outage): Outage Delete|$CGI_BASE/outages.pl?act=outage_table_dodelete&key=KEY&$W|0"
	"SKIP (MUTATES - nodeconf update): Nodeconf Update|$CGI_BASE/nodeconf.pl?act=config_nodeconf_update&node=$NODE&$W|0"
	"SKIP (MUTATES - event update): Event Table Update|$CGI_BASE/events.pl?act=event_table_update&$W|0"
	"SKIP (MUTATES - event delete confirm): Event DB Delete Confirm|$CGI_BASE/view-event.pl?act=event_database_delete&node_uuid=UUID&event=EVENT&element=ELEMENT&$W|0"
	"SKIP (MUTATES - event delete commit): Event DB Do-Delete|$CGI_BASE/view-event.pl?act=event_database_dodelete&node_uuid=UUID&event=EVENT&element=ELEMENT&$W|0"
	"SKIP (MUTATES - model policy update): Model Policy Update|$CGI_BASE/model_policy.pl?act=update&$W|0"
	"SKIP (MUTATES - config add commit): Config Do-Add|$CGI_BASE/config.pl?act=config_nmis_doadd&section=SECTION&item=ITEM&value=VAL&$W|0"
	"SKIP (MUTATES - config edit commit): Config Do-Edit|$CGI_BASE/config.pl?act=config_nmis_doedit&section=SECTION&item=ITEM&value=VAL&$W|0"
	"SKIP (MUTATES - config delete commit): Config Do-Delete|$CGI_BASE/config.pl?act=config_nmis_dodelete&section=SECTION&item=ITEM&$W|0"
	"SKIP (MUTATES - table add commit): Tables Do-Add|$CGI_BASE/tables.pl?act=config_table_doadd&table=Contacts&$W|0"
	"SKIP (MUTATES - table edit commit): Tables Do-Edit|$CGI_BASE/tables.pl?act=config_table_doedit&table=Nodes&key=$NODE&$W|0"
	"SKIP (MUTATES - table delete commit): Tables Do-Delete|$CGI_BASE/tables.pl?act=config_table_dodelete&table=Nodes&key=$NODE&$W|0"
	"SKIP (MUTATES - model add commit): Models Do-Add|$CGI_BASE/models.pl?act=config_model_doadd&model=NEWMODEL&$W|0"
	"SKIP (MUTATES - model edit commit): Models Do-Edit|$CGI_BASE/models.pl?act=config_model_doedit&model=Default&$W|0"
	"SKIP (MUTATES - model delete commit): Models Do-Delete|$CGI_BASE/models.pl?act=config_model_dodelete&model=NAME&$W|0"
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
run_category "Node Views"       NODE_VIEWS
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

# Uncomment the following line to run the SKIPPED list too:
# run_category "Skipped (manual)" SKIPPED

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
fi

# --save: write deterministic TSV of all results
if [ -n "$SAVE_FILE" ]; then
	write_results_file "$SAVE_FILE" || {
		echo "ERROR: could not write $SAVE_FILE" >&2
	}
	echo ""
	echo "Saved results to: $SAVE_FILE"
fi

# --compare: diff the current results against a baseline file
COMPARE_DIFFS=0
if [ -n "$COMPARE_FILE" ]; then
	echo ""
	echo "--- Compare against baseline: $COMPARE_FILE ---"
	if [ ! -r "$COMPARE_FILE" ]; then
		echo "ERROR: cannot read $COMPARE_FILE" >&2
		COMPARE_DIFFS=1
	else
		compare_to_baseline "$COMPARE_FILE"
		COMPARE_DIFFS=$?
	fi
fi

# Exit priority: endpoint failures (1) > compare diffs (4) > success (0).
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
if [ "$COMPARE_DIFFS" -ne 0 ]; then
	exit 4
fi

exit 0
