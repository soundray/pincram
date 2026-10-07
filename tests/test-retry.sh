#!/bin/bash
# Retry logic (local backend): transient failure, SIGKILL (out of memory), permanent failure
. "$(dirname "$0")/lib.sh"

echo "--- transient failures are retried, a permanent one is given up; PROCEED_PCT=100 aborts"
setup
"$testsdir"/mock-atlas.sh 20 "$T/atlas"
touch "$MOCK_FAIL_DIR"/s3-once "$MOCK_FAIL_DIR"/s4-kill-once "$MOCK_FAIL_DIR"/s5-always
export PINCRAM_PROCEED_PCT=100
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -levels 1 -par 4 -savewd
assert_eq "exit status is failure" 1 "$rc"
w=$(wd)
assert_grep "attempt 1 summary" 'Attempt 1: 17 succeeded, 3 to retry, 0 given up' "$T/run.log"
assert_grep "attempt 2 summary" 'Attempt 2: 2 succeeded, 1 to retry, 0 given up' "$T/run.log"
assert_grep "attempt 3 gives up" 'Attempt 3: 0 succeeded, 0 to retry, 1 given up' "$T/run.log"
assert_grep "exit status reported for atlas 3" 'Atlas 3: exit status 1; will retry' "$T/run.log"
assert_grep "SIGKILL reported as probable OOM for atlas 4" 'Atlas 4: killed by SIGKILL, probably out of memory \(consider a lower -par\); will retry' "$T/run.log"
assert_grep "atlas 5 given up with log pointer" 'Atlas 5: exit status 1; giving up after 3 attempt\(s\), see logs/reg-coarse-s5.log' "$T/run.log"
assert_grep "level aborted" 'Too few registrations succeeded at level coarse' "$T/run.log"
assert_grep "status file records rc=1" '^rc=1 ' "$w/status/coarse-a1-n3"
assert_grep "status file records rc=137" '^rc=137 ' "$w/status/coarse-a1-n4"
assert_eq "retry job file has 3 lines" 3 "$(grep -c '' "$w/job-coarse-a2.conf")"
assert_eq "third attempt has 1 line" 1 "$(grep -c '' "$w/job-coarse-a3.conf")"
assert_eq "atlas 5 log shows 3 attempts" 3 "$(grep -c '^=== ' "$w/logs/reg-coarse-s5.log")"
assert_eq "19 of 20 masks produced" 19 "$(count "$w"/masktr-coarse-s*.nii.gz)"
teardown

echo "--- PROCEED_PCT=90 continues with 19 of 20"
setup
"$testsdir"/mock-atlas.sh 20 "$T/atlas"
touch "$MOCK_FAIL_DIR"/s5-always
export PINCRAM_PROCEED_PCT=90
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -levels 2 -par 4 -savewd
assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
w=$(wd)
assert_grep "19 of 20 completed" 'Level coarse: 19 of 20 mask transformations completed \(minimum 18\)' "$T/run.log"
assert "atlas 5 not selected for level 1" bash -c "! grep -qx 5 '$w/selection-coarse.csv'"
assert "parenchyma mask written" test -s "$T/result/parenchyma.nii.gz"
teardown

echo "--- PINCRAM_MAX_ATTEMPTS=1 gives up immediately"
setup
"$testsdir"/mock-atlas.sh 20 "$T/atlas"
touch "$MOCK_FAIL_DIR"/s7-once
export PINCRAM_MAX_ATTEMPTS=1 PINCRAM_PROCEED_PCT=50
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -levels 1 -par 4
assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
assert_grep "given up after 1 attempt" 'Atlas 7: exit status 1; giving up after 1 attempt' "$T/run.log"
teardown
report
