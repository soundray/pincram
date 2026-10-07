#!/bin/bash
# Slurm backend against mock sbatch/squeue/sacct/scancel: array sizing, resources, OOM and timeout escalation
. "$(dirname "$0")/lib.sh"

echo "--- job arrays per level, throttle from -par, cpus from -threads, mem/time per level"
setup
"$testsdir"/mock-atlas.sh 20 "$T/atlas"
export PINCRAM_ARCH=slurm PINCRAM_SLURM_MEM="3G 4000M 8G" PINCRAM_SLURM_TIME="10 20 60" PINCRAM_SLURM_OPTS="-A acct -p part"
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -levels 3 -par 5 -threads 2 -savewd -workdir "$T/work"
assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
w=$(wd)
assert_eq "three job arrays submitted" 3 "$(count "$MOCK_SLURM_DIR"/*.args)"
j0=$(<"$w/slurm-l0-a1.jobid") ; j1=$(<"$w/slurm-l1-a1.jobid") ; j2=$(<"$w/slurm-l2-a1.jobid")
assert_grep "level 0 array sized and throttled" '^--array=1-20%5$' "$MOCK_SLURM_DIR/$j0.args"
assert_grep "level 1 array sized" "^--array=1-$(grep -c '' "$w/job-l1-a1.conf")%5\$" "$MOCK_SLURM_DIR/$j1.args"
assert_grep "level 2 array sized" "^--array=1-$(grep -c '' "$w/job-l2-a1.conf")%5\$" "$MOCK_SLURM_DIR/$j2.args"
assert_grep "cpus per task" '^--cpus-per-task=2$' "$MOCK_SLURM_DIR/$j0.args"
assert_grep "level 0 memory" '^--mem=3G$' "$MOCK_SLURM_DIR/$j0.args"
assert_grep "level 1 memory" '^--mem=4000M$' "$MOCK_SLURM_DIR/$j1.args"
assert_grep "level 2 memory" '^--mem=8G$' "$MOCK_SLURM_DIR/$j2.args"
assert_grep "level 2 time" '^--time=60$' "$MOCK_SLURM_DIR/$j2.args"
assert_grep "extra options passed" '^-A$' "$MOCK_SLURM_DIR/$j0.args"
assert_grep "chdir is the working directory" "^--chdir=$T/work/pincram\\." "$MOCK_SLURM_DIR/$j0.args"
assert_grep "task output goes to logs" "^--output=.*/logs/slurm-l0-a1-%a.out$" "$MOCK_SLURM_DIR/$j0.args"
assert_grep "wrap runs reg.sh with threads" "^--wrap=exec '.*/reg.sh' -conf '.*/job-l0-a1.conf' -tag 'l0-a1' -threads 2$" "$MOCK_SLURM_DIR/$j0.args"
assert_eq "task logs collected" 20 "$(count "$w"/logs/slurm-l0-a1-*.out)"
assert_grep "progress reported" "Job $j0: [0-9]+/20 masks ready" "$T/run.log"
assert "working directory defaulted under -workdir" test -d "$T/work"
teardown

echo "--- unlimited throttle by default; OOM doubles memory, timeout doubles time"
setup
"$testsdir"/mock-atlas.sh 20 "$T/atlas"
touch "$MOCK_FAIL_DIR"/s2-kill-once "$MOCK_FAIL_DIR"/s9-timeout-once
export PINCRAM_ARCH=slurm
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -levels 1 -savewd -workdir "$T/work"
assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
w=$(wd)
j1=$(<"$w/slurm-l0-a1.jobid") ; j2=$(<"$w/slurm-l0-a2.jobid")
assert_grep "no throttle without -par" '^--array=1-20$' "$MOCK_SLURM_DIR/$j1.args"
assert_grep "default memory" '^--mem=4G$' "$MOCK_SLURM_DIR/$j1.args"
assert_grep "default time" '^--time=30$' "$MOCK_SLURM_DIR/$j1.args"
assert_grep "OOM detected from accounting" 'Atlas 2: out of memory \(Slurm\); will retry' "$T/run.log"
assert_grep "timeout detected from accounting" 'Atlas 9: time limit exceeded \(Slurm\); will retry' "$T/run.log"
assert_grep "retry array has two tasks" '^--array=1-2$' "$MOCK_SLURM_DIR/$j2.args"
assert_grep "retry doubles memory" '^--mem=8G$' "$MOCK_SLURM_DIR/$j2.args"
assert_grep "retry doubles time" '^--time=60$' "$MOCK_SLURM_DIR/$j2.args"
assert_grep "all succeeded after retry" 'Attempt 2: 2 succeeded, 0 to retry, 0 given up' "$T/run.log"
assert_grep "status file of the killed task records SIGKILL" '^rc=137 ' "$w/status/l0-a1-n2"
assert_grep "status file of the timed-out task records its exit" '^rc=124 ' "$w/status/l0-a1-n9"
teardown
report
