#!/bin/bash
#
# run-condition.sh CONDITION
#
# Builds the perturbed atlas for CONDITION and runs pincram (3 levels) on each held-out target,
# scoring against the target's original masks. Environment: PINCRAM_SIF (MIRTK container), the
# pincram directory and tests/container-bin on the PATH, python3 with numpy/scipy/nibabel.
# Results: $EXP/<condition>/<target>/results.csv and $EXP/<condition>/atlas/perturb-stats.csv.

set -e -o pipefail
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$here")")
cond=$1
: "${SRC_ATLAS:=/nobackup/proj/disk/metrimorphics0/shared/reference/ixi-pincram-atlas-n100-dm}"
: "${EXP:=$pincramdir/temp/perturb}"
: "${TARGETS:=m20 m40 m60 m80 m100}"
: "${PAR:=${SLURM_CPUS_PER_TASK:-32}}"
export PINCRAM_ARCH=local

mkdir -p "$EXP/$cond"
[[ -s $EXP/$cond/atlas/perturb-stats.csv && $(find "$EXP/$cond/atlas/cache/brainmasks-dm/" -name '*.nii.gz' 2>/dev/null | wc -l) -ge 100 ]] ||
    "$here"/build-atlas.sh "$cond" "$SRC_ATLAS" "$EXP/$cond/atlas" "$PAR"

for t in $TARGETS ; do
    echo "=== $cond / $t  $(date)"
    "$pincramdir"/tests/regression/regress.sh \
        -target "$SRC_ATLAS/base/images/$t.nii.gz" -atlas "$EXP/$cond/atlas" \
        -ref "$SRC_ATLAS/base/brainmasks/$t.nii.gz" -icvref "$SRC_ATLAS/base/icvmasks/$t.nii.gz" \
        -levels 3 -out "$EXP/$cond/$t" -- -par "$PAR" -threads 1 -workdir "$EXP/$cond/wd" 2>&1 |
        grep -E '^(=== |regress.sh|pincram.sh: (Level|Attempt|Selected|End|Too few)|[0-9] +(parenchyma|icv))'
    cp "$EXP/$cond/$t/level3/si.csv" "$EXP/$cond/$t/si.csv" 2>/dev/null || true
    rm -rf "$EXP/$cond/$t/level3/pincram."* 2>/dev/null || true
done
echo "=== $cond done $(date)"
