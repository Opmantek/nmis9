#!/usr/bin/env bash
set -eu

# The defaults are the CI container's layout. They are overridable so the
# behaviour of this script can itself be tested (test/t_ci_perl_tests.t drives
# the real file with a stub prove), and so it can be run against a checkout
# outside the container. CI sets none of these.
nmis_home="${NMIS_HOME:-/usr/local/nmis9}"
nmis_tests="$nmis_home/test"
prove_bin="${PROVE:-/usr/bin/prove}"
yes_bin="${YES:-/usr/bin/yes}"

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
    t_logs_file_confinement.t
    t_auth_graph_refusal.t
    t_graph_authz.t
    t_setup_mongodb_shell.t
    t_auth_web_key.t
    t_authkey_recovery.t
    t_authkey_env.t
    t_auth_cookie_flavour.t
    t_auth_cookie_flags.t
    t_auth_sso_shared_key.t
    t_auth_mojo9_cookie.t
    t_auth_session_no_eval.pl
    t_plugin_loader_guard.t
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
    t_htpasswd_store.t
    t_auth_password_rehash.t
    t_nmis_cli_htpasswd.t
    t_nmis_cli_seed_password.t
    t_nmis_cli_discard_password.t
    t_seed_decision.t
    t_session_expiry.t
    t_auth_session_privs.t
    t_access_policy.pl
    t_mongo_exposure.t
    t_common_dbpassword.t
    t_db_auth_source.t
    t_patch_config_value_file.t
    # t_setup_mongodb_scoped_user.t is NOT registered here: it BAIL_OUTs unless
    # NMIS_TEST_MONGO_URI points at a disposable Mongo, which CI does not yet set,
    # so registering it would abort the whole suite. Pending CI-fixture wiring
    # (a throwaway Mongo + NMIS_TEST_MONGO_URI) as a follow-up.
    t_csrf.t
    t_csrf_cgi.t
    t_ci_perl_tests.t
)

# run every file even when one fails, so a failure early in the list does not
# hide the state of everything after it. set -e would abort the loop otherwise.
status=0
failed=()
for i in "${working_tests[@]}"; do
    if ! "$yes_bin" n | "$prove_bin" "$nmis_tests/$i"; then
        status=1
        failed+=("$i")
    fi
done

if [ "$status" -ne 0 ]; then
    echo "FAILED: ${failed[*]}" >&2
fi

exit $status
