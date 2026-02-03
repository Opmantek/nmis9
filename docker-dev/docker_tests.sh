#!/bin/bash
# This script is to run NMIS9 unit tests that currently work in container environments

PROVE_CMD=/usr/bin/prove
PERL_CMD=/usr/bin/perl
NMIS_TEST_HOME=/usr/local/nmis9/test

# Tests that currently work in Docker environments
WRKNG_TESTS=(
  "dev-tools.pl act=graphs node=localhost"
  "support_depend_info.pl act=dump data_dir=/tmp"
  "t_auth_sessions.pl"
  "remove_duplicate_catchall.pl dryrun=0"
  "t_metrics.pl"
  "t_netsnmp.pl"
  "t_network_status.pl"
  "t_nmisng.pl"
  "t_nmisng_node_nomodel.pl"
  "t_nmisng_sys.pl"
  "t_regex_eval.pl"
  "t_sstatus.pl"
  "t_util.pm"
  "test-proctable.pl"
  "testservice.pl"
  "uuid.t"
)

WRKNG_INPUT_TEST=(
  "notify_depend.t"
  "t_model_data.pl"
  "t_nmisng_inventory.pl"
  "t_status.pl"
)

run_tests () {
echo -e "========== BEGIN TESTING ==========\n"

  cd $NMIS_TEST_HOME

  for utest in "${WRKNG_TESTS[@]}"; do
    echo "$utest"
    echo -e "\n$($PERL_CMD $utest)\n"
  done

  for utest in "${WRKNG_INPUT_TESTS[@]}"; do
    echo "$utest"
    echo -e "\n$(yes | $PERL_CMD $utest)\n"
  done

echo -e "\n========== END TESTING =========="
}

run_tests