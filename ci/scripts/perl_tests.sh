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
    t_sys_dual.pl
    t_compat_nmis.pl
    t_plugin_contract.pl
    # Model overrides (Override-Model-* / Override-Common-* discovery)
    t_model_overrides.pl
    # HTTP engine + supporting parsers
    t_prom_text.pl
    t_jsonpath.pl
    t_sys_http.pl
    t_engine_http.pl
    t_engine_http_auth.pl
    t_polling_http.pl
    t_polling_redis.pl
    # Model-scaffolding tools (admin/build_http_model.pl, admin/import_grafana_dashboard.pl)
    t_build_http_model.pl
    t_import_grafana_dashboard.pl
)

for i in "${working_tests[@]}"; do
    /usr/bin/yes n | /usr/bin/prove "$nmis_tests/$i"
done

exit 0