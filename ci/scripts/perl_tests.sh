#!/usr/bin/env bash
set -eu

nmis_home="/usr/local/nmis9"
nmis_tests="$nmis_home/test"

working_tests=(
    uuid.t
    t_util.pm
    t_nmis_config.pl
    t_status.pl
    t_nmisng_sys.pl
    t_nmisng_node_rename.pl
    t_nmisng_node.pl
    t_nmisng_inventory.pl
    t_nmisng.pl
    t_network_status.pl
    t_model_data.pl
    t_db_stats.pl
    nmisng_log.t
    t_sys.pl
    t_polling.pl
    t_node_lock_stale.pl
    t_duplicate_event.pl
    t_eval_injection.pl
    t_report_filename.t
    t_isindex_guard.t
    t_rrddraw_filename.t
    t_auth_cookie_flavour.t
    t_auth_sso_shared_key.t
    t_util_escape.pl
    t_xss_modules_render.pl
    t_cgi_xss_escaping.t
    t_cgi_modules_xbase.t
    t_filter_params.t
)

for i in "${working_tests[@]}"; do
    /usr/bin/yes n | /usr/bin/prove "$nmis_tests/$i"
done

exit 0