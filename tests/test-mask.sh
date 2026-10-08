#!/bin/bash
# -mask (input mask replaces the coarse level) and -refine-band, with 20 placeholder atlases
. "$(dirname "$0")/lib.sh"

setup
"$testsdir"/mock-atlas.sh 20 "$T/atlas"
echo "placeholder input mask" >"$T/inmask.nii.gz"
a="$T/target.nii.gz -result $T/result -atlas $T/atlas -par 4"

# shellcheck disable=SC2086
run_pincram $a -mask "$T/inmask.nii.gz" -levels 1 ;        assert_eq "-mask with -levels 1 rejected" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -mask "$T/nowhere.nii.gz" ;                 assert_eq "missing input mask rejected" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -refine-band 3 ;                            assert_eq "-refine-band without -mask rejected" 1 "$rc"
# shellcheck disable=SC2086
run_pincram $a -mask "$T/inmask.nii.gz" -refine-band x ;   assert_eq "non-numeric -refine-band rejected" 1 "$rc"

echo "--- -mask, 3 levels, atlas without a reference brain-mask distance map"
# shellcheck disable=SC2086
run_pincram $a -mask "$T/inmask.nii.gz" -savewd
assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
w=$(wd)
assert_grep "falls back to head-mask pre-alignment" 'pre-aligning with head masks' "$T/run.log"
assert "no coarse level" test ! -e "$w/job-coarse-a1.conf"
assert_eq "prealigned level has a job per atlas" 20 "$(grep -c '' "$w/job-prealigned-a1.conf")"
assert_eq "prealigned jobs do not register" 20 "$(grep -c -- '-register 0' "$w/job-prealigned-a1.conf")"
assert_eq "no registration at the prealigned level" 0 "$(cat "$w"/logs/reg-prealigned-s*.log | grep -c 'mock register')"
assert_eq "affine jobs register" 0 "$(grep -c -- '-register' "$w/job-affine-a1.conf")"
assert_eq "selection after prealigned as after coarse (20 x (8/20)^(1/3))" 14 "$(grep -c '' "$w/selection-prealigned.csv")"
assert_eq "affine level gets the input mask as -tdm" "$(grep -c '' "$w/job-affine-a1.conf")" "$(grep -c -- '-tdm .*/input-dm.nii.gz' "$w/job-affine-a1.conf")"
assert_eq "affine registrations masked by the input mask's margin" "$(grep -c '' "$w/job-affine-a1.conf")" "$(grep -c -- '-tmargin .*/dmargin-prealigned.nii.gz' "$w/job-affine-a1.conf")"
assert "nonrigid level ran" test -s "$w/tmask-nonrigid-sel.nii.gz"
assert "no refinement without -refine-band" test ! -e "$w/tmask-nonrigid-refined.nii.gz"
assert "parenchyma mask written" test -s "$T/result/parenchyma.nii.gz"
teardown

echo "--- -mask -refine-band, 2 levels, atlas with a reference brain-mask distance map"
setup
"$testsdir"/mock-atlas.sh 20 "$T/atlas"
echo "placeholder input mask" >"$T/inmask.nii.gz"
echo "placeholder refspace brainmask-dm" >"$T/atlas/base/refspace/brainmask-dm.nii.gz"
run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -par 4 -levels 2 -mask "$T/inmask.nii.gz" -refine-band 4 -savewd
assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
w=$(wd)
assert_grep "pre-alignment with brain-mask distance maps" 'with brain mask distance maps' "$T/run.log"
assert_eq "reference distance map is the atlas's brain-mask map" "placeholder refspace brainmask-dm" "$(cat "$w/refspace-dm.nii.gz")"
assert "refined label written" test -s "$w/tmask-affine-refined.nii.gz"
assert "no nonrigid level" test ! -e "$w/job-nonrigid-a1.conf"
assert_eq "final level requested alt masks" "$(grep -c '' "$w/job-affine-a1.conf")" "$(grep -c -- '-alttr' "$w/job-affine-a1.conf")"
assert "icv mask written" test -s "$T/result/icv.nii.gz"
teardown
report
