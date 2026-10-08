#!/bin/bash
#
# run-target.sh TARGET
#
# Runs pincram (3 levels) on Hammers target TARGET without an input mask and with each input-mask
# condition, scoring the parenchyma output against the verified total brain volume mask
# (binarized icmasked/<t>). Conditions (environment CONDITIONS):
#   plain         no input mask (reference run)
#   hdbet         HD-BET 1.1 mask of the target (temp/hdbet-targets/hammers-<t>_mask.nii.gz)
#   erodeN, dilateN, randomN
#                 the verified TBV mask degraded by degrade.py
#   <cond>-bandW  as <cond>, with -refine-band W
# Results: $EXP/<cond>/<target>/results.csv (rows "input" and "3"), outputs in .../level3/.

set -e -o pipefail
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$here")")
t=$1
: "${EXP:=$pincramdir/temp/mask-refine}"
: "${PAR:=${SLURM_CPUS_PER_TASK:-32}}"
: "${ATLAS:=/nobackup/proj/disk/metrimorphics0/shared/reference/ixi-pincram-atlas-n100-dm}"
: "${HAMMERS:=/nobackup/proj/disk/metrimorphics0/shared/reference/atlases-hammers-scaled-with-flipped-n60}"
: "${HDBET:=$pincramdir/temp/hdbet-targets}"
: "${CONDITIONS:=plain hdbet erode3 dilate3 random3 hdbet-band4}"
export PINCRAM_ARCH=local

inputs=$EXP/inputs ; mkdir -p "$inputs"
ref=$inputs/tbv-$t.nii.gz
[[ -s $ref ]] || "$pincramdir"/pincram-image binarize "$ref" "$HAMMERS/icmasked/$t.nii.gz"

for cond in $CONDITIONS ; do
    base=${cond%-band*}
    maskopts=() ; extra=()
    case $base in
        plain) ;;
        hdbet) maskopts=(-mask "$HDBET/hammers-${t}_mask.nii.gz") ;;
        *)     m=$inputs/$base-$t.nii.gz
               [[ -s $m ]] || python3 "$here"/degrade.py "$base" "$ref" "$m"
               maskopts=(-mask "$m") ;;
    esac
    [[ $cond == *-band* ]] && extra=(-refine-band "${cond##*-band}")
    out=$EXP/$cond/$t
    echo "=== $cond / $t  $(date)"
    "$pincramdir"/tests/regression/regress.sh -target "$HAMMERS/mri/$t.nii.gz" -atlas "$ATLAS" -ref "$ref" \
        -levels 3 -out "$out" "${maskopts[@]}" -- -par "$PAR" -threads 1 -workdir "$EXP/wd" "${extra[@]}" 2>&1 |
        grep -E '^(=== |regress.sh|pincram.sh: (Level|Attempt|Selected|Calculating|End|Too few)|(input|[0-9]) +(parenchyma|icv))'
    rm -rf "$out"/level3/pincram.* 2>/dev/null || true
done
echo "=== $t done $(date)"
