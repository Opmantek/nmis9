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
    t_operational_status.pl
    t_event_cancelingevent_cycle.pl
    t_event_query_isolation.pl
    t_event.pl
    t_model_overrides.pl
    t_plugin_nodeobj.pl
    notify_depend.t
    t_nmisng_node_nomodel.pl
)

for i in "${working_tests[@]}"; do
    /usr/bin/yes n | /usr/bin/prove "$nmis_tests/$i"
done

exit 0