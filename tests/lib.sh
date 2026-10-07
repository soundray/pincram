# shellcheck shell=bash
#
# lib.sh -- helpers for pincram's test scripts (sourced)
#
# Each test script runs pincram.sh against tests/mock-bin (placeholder MIRTK, NiftySeg and
# Slurm commands) in a private temporary directory and ends with "report".

testsdir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$testsdir")
basetmp=${TMPDIR:-/tmp}
pass=0 ; fail=0
rc=0

setup () {
    T=$(mktemp -d "$basetmp/pincram-test.XXXXXX")
    export TMPDIR=$T
    export PATH=$testsdir/mock-bin:$pincramdir:$PATH
    export MOCK_FAIL_DIR=$T/fail MOCK_SLURM_DIR=$T/slurm
    mkdir -p "$MOCK_FAIL_DIR" "$MOCK_SLURM_DIR"
    echo "placeholder target" >"$T/target.nii.gz"
    unset PINCRAM_ARCH PINCRAM_PROCEED_PCT PINCRAM_MAX_ATTEMPTS PINCRAM_SLURM_MEM PINCRAM_SLURM_TIME PINCRAM_SLURM_OPTS
    export PINCRAM_POLL_SEC=1
}

teardown () { [[ -n $KEEP_TEST_DIRS ]] || rm -rf "$T" ; }

# run_pincram ARGS... : run pincram.sh, capturing output in $T/run.log and the exit code in $rc
# shellcheck disable=SC2034  # rc is read by the test scripts
run_pincram () {
    rc=0
    pincram.sh "$@" >"$T/run.log" 2>&1 || rc=$?
}

# wd : the saved working directory of the last -savewd run under $T/result
wd () { find "$T/result" -maxdepth 1 -name 'pincram.*' 2>/dev/null | head -n 1 ; }

assert () {        # assert DESCRIPTION COMMAND...
    local desc=$1 ; shift
    if "$@" ; then echo "  ok    $desc" ; (( ++pass )) ; else echo "  FAIL  $desc" ; (( ++fail )) ; fi
}
assert_eq () {     # assert_eq DESCRIPTION EXPECTED ACTUAL
    if [[ $2 == "$3" ]] ; then echo "  ok    $1 ($3)" ; (( ++pass ))
    else echo "  FAIL  $1: expected '$2', got '$3'" ; (( ++fail )) ; fi
}
assert_grep () {   # assert_grep DESCRIPTION PATTERN FILE
    if grep -qE -- "$2" "$3" 2>/dev/null ; then echo "  ok    $1" ; (( ++pass ))
    else echo "  FAIL  $1: pattern '$2' not found in $3" ; (( ++fail )) ; fi
}
# count GLOB... : number of matching files (the glob is expanded by the caller)
# shellcheck disable=SC2012
count () { ls "$@" 2>/dev/null | wc -l ; }

report () {
    echo "$(basename "$0"): $pass passed, $fail failed"
    [[ $fail -eq 0 ]]
}
