#!/bin/bash
# Regression of the control flow for -levels 1, 2 and 3 with 20 placeholder atlases
. "$(dirname "$0")/lib.sh"

for levels in 1 2 3 ; do
    setup
    echo "--- levels $levels"
    "$testsdir"/mock-atlas.sh 20 "$T/atlas"
    echo "placeholder ref" >"$T/ref.nii.gz"
    run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -levels "$levels" -par 4 -savewd -savedm -ref "$T/ref.nii.gz"
    assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
    w=$(wd)
    names=(coarse affine nonrigid)
    for ((l = 0 ; l < 3 ; l++)) ; do
        if (( l < levels )) ; then
            assert "level ${names[$l]} ran" test -s "$w/tmask-${names[$l]}-sel.nii.gz"
            assert "distance map for ${names[$l]}" test -s "$w/distmap-${names[$l]}.nii.gz"
        else
            assert "level ${names[$l]} did not run" test ! -e "$w/job-${names[$l]}-a1.conf"
        fi
    done
    last=${names[$((levels-1))]}
    assert "no margin mask after the final level" test ! -e "$w/dmargin-$last.nii.gz"
    assert_eq "final level requested alt masks" "$(grep -c '' "$w/job-$last-a1.conf")" "$(grep -c -- '-alttr' "$w/job-$last-a1.conf")"
    assert_eq "level 0 has no -tdm" 0 "$(grep -c -- '-tdm' "$w/job-coarse-a1.conf")"
    (( levels > 1 )) && assert_eq "level 1 passes fused mask as -tdm" "$(grep -c '' "$w/job-affine-a1.conf")" "$(grep -c -- '-tdm .*/tmask-coarse-sum.nii.gz' "$w/job-affine-a1.conf")"
    assert "parenchyma mask written" test -s "$T/result/parenchyma.nii.gz"
    assert "icv mask written" test -s "$T/result/icv.nii.gz"
    assert "distance map saved (-savedm)" test -s "$T/result/prime-distmap.nii.gz"
    assert "assessment log written (-ref)" test -s "$T/result/assess.log"
    assert_eq "assessment lines" $(( 2*levels + 1 )) "$(grep -c '' "$T/result/assess.log")"
    teardown
done
report
