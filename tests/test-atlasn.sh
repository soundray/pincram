#!/bin/bash
# Selection sizes, job counts and intermediate-file cleanup for 7, 20 and 100 atlases at 3 levels
. "$(dirname "$0")/lib.sh"

# expected sizes: usepercent = round(100 * (8/n)^(1/3)); nselected = n_done * usepercent / 100, min rule (<9 -> 7)
expect () {   # expect N : prints "sel0 sel1 sel2"
    awk -v n="$1" 'BEGIN { p = int(100*(8/n)^(1/3) + 0.5) ; s = n ; out = ""
        for (l = 0 ; l < 3 ; l++) { s = int(s*p/100) ; if (s < 9) s = 7 ; out = out (l ? " " : "") s } ; print out }'
}

for n in 7 20 100 ; do
    setup
    echo "--- atlasn $n"
    "$testsdir"/mock-atlas.sh "$n" "$T/atlas"
    run_pincram "$T/target.nii.gz" -result "$T/result" -atlas "$T/atlas" -atlasn "$n" -levels 3 -par 8 -savewd
    assert_eq "exit status" 0 "$rc" || cat "$T/run.log"
    w=$(wd)
    read -r s0 s1 s2 < <(expect "$n")
    assert_eq "level 0 job lines" "$n" "$(grep -c '' "$w/job-coarse-a1.conf")"
    assert_eq "selected after coarse" "$s0" "$(grep -c '' "$w/selection-coarse.csv")"
    assert_eq "level 1 job lines" "$s0" "$(grep -c '' "$w/job-affine-a1.conf")"
    assert_eq "selected after affine" "$s1" "$(grep -c '' "$w/selection-affine.csv")"
    assert_eq "level 2 job lines" "$s1" "$(grep -c '' "$w/job-nonrigid-a1.conf")"
    assert_eq "selected after nonrigid" "$s2" "$(grep -c '' "$w/selection-nonrigid.csv")"
    assert_eq "alt masks only requested at the final level" "$s1" "$(grep -c -- '-alttr' "$w"/job-*-a1.conf | awk -F: '{ s += $2 } END { print s }')"
    assert_eq "one log per registration" "$(( n + s0 + s1 ))" "$(count "$w"/logs/reg-*-s*.log)"
    assert_eq "one status file per registration" "$(( n + s0 + s1 ))" "$(count "$w"/status/*-a1-n*)"
    assert_eq "no transformed source images left" 0 "$(count "$w"/srctr-*)"
    assert_eq "no transformed masks left" 0 "$(count "$w"/masktr-*)"
    assert_eq "no transformed alternative masks left" 0 "$(count "$w"/alttr-*)"
    assert_eq "no task temp dirs left" 0 "$(count -A "$w"/tmp)"
    assert_eq "only final-level transformations kept (-savewd)" "$s1" "$(count "$w"/reg-s*-nonrigid.dof.gz)"
    assert_eq "no earlier transformations kept" 0 "$(count "$w"/reg-s*-coarse.dof.gz "$w"/reg-s*-affine.dof.gz)"
    assert "parenchyma mask written" test -s "$T/result/parenchyma.nii.gz"
    assert "icv mask written" test -s "$T/result/icv.nii.gz"
    assert "success index written" test -s "$T/result/si.csv"
    assert_grep "no retries needed" 'Attempt 1: [0-9]+ succeeded, 0 to retry, 0 given up' "$T/run.log"
    assert "selection is a subset of the ranking" bash -c "sort '$w/selection-coarse.csv' | comm -23 - <(sort '$w/ranking-coarse.csv') | wc -l | grep -qx 0"
    teardown
done
report
