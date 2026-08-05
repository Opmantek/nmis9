#!/usr/bin/env bash
set -eu

nmis_home="/usr/local/nmis9"
nmis_tests="$nmis_home/test"

working_tests=(
    uuid.t
    t_util.pm
    t_nmis_config.pl
    t_writehashtofile.pl
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
    t_event_cancelingevent_cycle.pl
    t_event_query_isolation.pl
    t_event.pl
    t_model_overrides.pl
    t_plugin_nodeobj.pl
    t_eval_injection.pl
    t_report_filename.t
    t_isindex_guard.t
    t_rrddraw_filename.t
    t_auth_graph_refusal.t
    t_graph_authz.t
    t_setup_mongodb_shell.t
    t_auth_web_key.t
    t_authkey_recovery.t
    t_authkey_env.t
    t_auth_cookie_flavour.t
    t_auth_sso_shared_key.t
    t_auth_session_no_eval.pl
    notify_depend.t
    t_nmisng_node_nomodel.pl
    t_util_escape.pl
    t_xss_modules_render.pl
    t_cgi_xss_escaping.t
    t_cgi_modules_xbase.t
    t_filter_params.t
    t_collect_services_injection.t
    t_compare_models_injection.t
    t_tests_snmp_injection.t
    t_http_security_headers.t
    t_config_load_perms.pl
    t_mongo_exposure.t
)

for i in "${working_tests[@]}"; do
    /usr/bin/yes n | /usr/bin/prove "$nmis_tests/$i"
done

exit 0