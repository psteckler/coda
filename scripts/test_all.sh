#!/bin/bash

set -eo pipefail

eval `opam config env`

run_unit_tests() {
  date
  myprocs=`nproc --all`  # Linux specific
  dune runtest --verbose -j${myprocs}
}

run_integration_tests() {
  if [ "${WITH_SNARKS}" = true ]; then
    tests=(full-test)
    snark_info="WITH SNARKS"
  else
    tests=(full-test coda-peers-test coda-transitive-peers-test \
      coda-block-production-test 'coda-shared-prefix-test -who-proposes 0' \
        'coda-shared-prefix-test -who-proposes 1' 'coda-shared-state-test' \
          'coda-restart-node-test' 'transaction-snark-profiler -check-only')
    snark_info="WITHOUT SNARKS"
  fi 
  for test in "${tests[@]}"; do
    echo "------------------------------------------------------------------------------------------"

    date
    SECONDS=0
    echo "TESTING ${test} USING ${CODA_CONSENSUS_MECHANISM} ${snark_info}"
    set +e
    ../scripts/test_integration_test.sh $test 2>&1 >> test.log
    OUT=$?
    echo "TESTING ${test} took ${SECONDS} seconds"
    if [ $OUT -eq 0 ];then
      echo "PASSED"
    else
      echo "FAILED"
      echo "------------------------------------------------------------------------------------------"
      echo "RECENT OUTPUT:"
      cat test.log | dune exec logproc
      echo "------------------------------------------------------------------------------------------"
      exit 2
    fi
    set -e
  done
}

main() {
  export CODA_PROPOSAL_INTERVAL=1000
  export CODA_SLOT_INTERVAL=1000
  export CODA_UNFORKABLE_TRANSITION_COUNT=4
  export CODA_PROBABLE_SLOTS_PER_TRANSITION_COUNT=1

  run_unit_tests
  WITH_SNARKS=false \
  CODA_CONSENSUS_MECHANISM=proof_of_signature \
    run_integration_tests
  CODA_CONSENSUS_MECHANISM=proof_of_stake \
    run_integration_tests
}

# Only run main if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
