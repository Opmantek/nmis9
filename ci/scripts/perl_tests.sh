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
    t_updateconfig.pl
    t_event_cancelingevent_cycle.pl
    t_event_query_isolation.pl
    t_event.pl
    t_model_overrides.pl
    t_plugin_nodeobj.pl
    t_plugin_nodevalidation.pl
    notify_depend.t
    t_nmisng_node_nomodel.pl
    # OMK-12775 / BR-01: clear_active_queue must not wipe pending jobs
    t_clear_active_queue.pl
    # OMK-12776 / BR-02: service inventories must get distinct uuids
    t_service_inventory_uuid.pl
    # OMK-12779 / BR-05: escalation must not be suppressed by an inactive depend Node Down
    t_escalation_depend_suppression.pl
    # OMK-12777 / BR-03: one malformed outage record must not abort the whole check
    t_outage_check_malformed_record.pl
    # OMK-12780 / BR-06: a dampened stateless event must not be resurrected
    t_stateless_event_not_resurrected.pl
    # OMK-12781 / BR-07: cleanNodeEvents must write a TTL date and not clobber valid expiries
    t_cleannodeevents_ttl.pl
)

for i in "${working_tests[@]}"; do
    /usr/bin/yes n | /usr/bin/prove "$nmis_tests/$i"
done

exit 0