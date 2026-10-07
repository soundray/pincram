#!/bin/bash
# Argument validation and usage errors
. "$(dirname "$0")/lib.sh"
setup
"$testsdir"/mock-atlas.sh 7 "$T/atlas"
a="$T/target.nii.gz -result $T/result -atlas $T/atlas"

# shellcheck disable=SC2086
run_pincram $a -pickup /nowhere ;      assert_eq "-pickup rejected" 1 "$rc" ; assert_grep "-pickup message" 'pickup has been removed' "$T/run.log"
# shellcheck disable=SC2086
run_pincram $a -bogus ;                assert_eq "unknown option rejected" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -levels 4 ;             assert_eq "-levels 4 rejected" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -par 0 ;                assert_eq "-par 0 rejected locally" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -threads x ;            assert_eq "non-numeric -threads rejected" 1 "$rc"
run_pincram "$T/target.nii.gz" -atlas "$T/atlas" ; assert_eq "missing -result rejected" 1 "$rc"
# shellcheck disable=SC2086
PINCRAM_ARCH=pbs run_pincram $a ;      assert_eq "PINCRAM_ARCH=pbs rejected" 1 "$rc"
# shellcheck disable=SC2086
PINCRAM_PROCEED_PCT=150 run_pincram $a ; assert_eq "PINCRAM_PROCEED_PCT=150 rejected" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -atlasn 5 ;             assert_eq "-atlasn below 7 rejected" 1 "$rc"
"$testsdir"/mock-atlas.sh 6 "$T/atlas6"
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas6" ; assert_eq "atlas with 6 entries rejected" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -atlasn 500 -levels 1 -par 2 ; assert_eq "-atlasn above available is clamped" 0 "$rc"
assert_eq "working directory removed without -savewd" 0 "$(count -d "$T"/pincram.*)"
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas/etc/entry-m1" ; assert_eq "bad atlas csv rejected" 1 "$rc"
"$pincramdir"/atlas-csv-gen.sh "$T/atlas" "$T/atlases.csv"
assert_eq "atlas csv has 5 columns" 5 "$(sed -n 2p "$T/atlases.csv" | tr , '\n' | wc -l)"
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlases.csv" -levels 1 -par 2 ; assert_eq "csv atlas accepted" 0 "$rc"
teardown
report
