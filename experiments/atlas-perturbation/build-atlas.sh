#!/bin/bash
#
# build-atlas.sh CONDITION SOURCE_ATLAS OUTDIR [THREADS]
#
# Creates a pincram atlas directory at OUTDIR whose brain and ICV masks are the SOURCE_ATLAS masks
# perturbed with CONDITION (see perturb-masks.py), with the distance-map cache rebuilt by the same
# MIRTK steps atlas-gen.sh uses. Images, normalization transforms and reference space are symlinked.

set -e -o pipefail
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
cond=$1 ; src=$(realpath "$2") ; out=$(realpath -m "$3") ; threads=${4:-8}

mkdir -p "$out"/base "$out"/cache/brainmasks-dm "$out"/cache/icvmasks-dm "$out"/etc "$out"/perturbed/brainmasks "$out"/perturbed/icvmasks
ln -sfn "$src"/base/images "$out"/base/images
ln -sfn "$src"/base/refspace "$out"/base/refspace
ln -sfn "$src"/cache/affinenorm "$out"/cache/affinenorm
cp "$src"/etc/entry-* "$out"/etc/

echo "build-atlas: perturbing masks ($cond)"
rm -f "$out"/perturb-stats.csv
python3 "$here"/perturb-masks.py -j "$threads" "$cond" "$out"/perturbed/brainmasks "$out"/perturb-stats.csv "$src"/base/brainmasks/*.nii.gz
python3 "$here"/perturb-masks.py -j "$threads" "$cond" "$out"/perturbed/icvmasks   "$out"/perturb-stats.csv "$src"/base/icvmasks/*.nii.gz
ln -sfn "$out"/perturbed/brainmasks "$out"/base/brainmasks
ln -sfn "$out"/perturbed/icvmasks "$out"/base/icvmasks

# eucmap as in atlas-gen.sh: negated Euclidean distance map
eucmap () {
    local tmp
    tmp=$(mktemp -d "$out/tmp.XXXXXX")
    mirtk calculate-distance-map "$1" "$tmp"/dm.nii.gz -threads 1 >/dev/null 2>&1
    mirtk calculate-element-wise "$tmp"/dm.nii.gz -mul -1 -threads 1 -o "$2" >/dev/null 2>&1
    rm -rf "$tmp"
}
export -f eucmap ; export out
echo "build-atlas: distance maps with $threads parallel processes"
# shellcheck disable=SC2016  # expanded by the inner bash
for m in "$out"/perturbed/brainmasks/*.nii.gz ; do echo "$m $out/cache/brainmasks-dm/$(basename "$m")" ; done |
    xargs -P "$threads" -L 1 bash -c 'eucmap "$0" "$1"'
# shellcheck disable=SC2016
for m in "$out"/perturbed/icvmasks/*.nii.gz ; do echo "$m $out/cache/icvmasks-dm/$(basename "$m")" ; done |
    xargs -P "$threads" -L 1 bash -c 'eucmap "$0" "$1"'
n=$(find "$out"/cache/brainmasks-dm -name '*.nii.gz' | wc -l)
echo "build-atlas: $n brain and $(find "$out"/cache/icvmasks-dm -name '*.nii.gz' | wc -l) ICV distance maps written"
