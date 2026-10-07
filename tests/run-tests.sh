#!/bin/bash
#
# run-tests.sh -- static analysis and orchestration tests for pincram
#
# Usage: tests/run-tests.sh [test-name...]      (default: shellcheck and every tests/test-*.sh)
#
# The orchestration tests use placeholder MIRTK/NiftySeg/Slurm commands from tests/mock-bin, so
# they run anywhere with bash, coreutils, awk and shellcheck. Regression tests against real data
# are in tests/regression/.

testsdir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$testsdir")
cd "$pincramdir" || exit 1
failed=()

echo "=== shellcheck"
scripts=(pincram.sh reg.sh scheduler functions atlas-gen.sh atlas-csv-gen.sh run-pincram
         tests/run-tests.sh tests/lib.sh tests/mock-atlas.sh tests/test-*.sh tests/mock-bin/* tests/regression/*.sh)
if type shellcheck >/dev/null 2>&1 ; then
    # SC2317: commands in trap handlers are reported as unreachable
    if shellcheck -x -e SC2317 "${scripts[@]}" ; then echo "shellcheck: clean" ; else failed+=(shellcheck) ; fi
else
    echo "shellcheck not installed -- skipped" ; failed+=("shellcheck (not installed)")
fi

if [[ $# -gt 0 ]] ; then tests=("${@/#/$testsdir/test-}") ; tests=("${tests[@]/%/.sh}") ; else tests=("$testsdir"/test-*.sh) ; fi
for t in "${tests[@]}" ; do
    echo "=== $(basename "$t")"
    bash "$t" || failed+=("$(basename "$t")")
done

echo "==="
if [[ ${#failed[@]} -eq 0 ]] ; then echo "All tests passed" ; else echo "FAILED: ${failed[*]}" ; exit 1 ; fi
