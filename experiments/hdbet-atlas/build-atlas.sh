#!/bin/bash
#
# build-atlas.sh SOURCE_ATLAS MASKDIR OUTDIR [THREADS]
#
# Creates a pincram atlas directory at OUTDIR with the prime (brain) masks taken from MASKDIR
# (<name>_mask.nii.gz or <name>.nii.gz per atlas entry, e.g. HD-BET output) and everything else
# (images, ICV masks, normalization, reference space) from SOURCE_ATLAS. The brain distance-map
# cache is rebuilt with the atlas-gen.sh steps; the ICV cache is symlinked.

set -e -o pipefail
src=$(realpath "$1") ; masks=$(realpath "$2") ; out=$(realpath -m "$3") ; threads=${4:-8}

mkdir -p "$out"/base "$out"/cache/brainmasks-dm "$out"/etc "$out"/base/brainmasks
ln -sfn "$src"/base/images "$out"/base/images
ln -sfn "$src"/base/icvmasks "$out"/base/icvmasks
ln -sfn "$src"/base/refspace "$out"/base/refspace
ln -sfn "$src"/cache/affinenorm "$out"/cache/affinenorm
ln -sfn "$src"/cache/icvmasks-dm "$out"/cache/icvmasks-dm
cp "$src"/etc/entry-* "$out"/etc/

for e in "$src"/etc/entry-* ; do
    n=$(<"$e")
    if [[ -s $masks/${n}_mask.nii.gz ]] ; then ln -sfn "$masks/${n}_mask.nii.gz" "$out/base/brainmasks/$n.nii.gz"
    elif [[ -s $masks/$n.nii.gz ]] ; then ln -sfn "$masks/$n.nii.gz" "$out/base/brainmasks/$n.nii.gz"
    else echo "build-atlas: no mask for $n in $masks" >&2 ; exit 1 ; fi
done

eucmap () {
    local tmp
    tmp=$(mktemp -d "$out/tmp.XXXXXX")
    mirtk calculate-distance-map "$1" "$tmp"/dm.nii.gz -threads 1 >/dev/null 2>&1
    mirtk calculate-element-wise "$tmp"/dm.nii.gz -mul -1 -threads 1 -o "$2" >/dev/null 2>&1
    rm -rf "$tmp"
}
export -f eucmap ; export out
echo "build-atlas: brain distance maps with $threads parallel processes"
# shellcheck disable=SC2016  # expanded by the inner bash
for m in "$out"/base/brainmasks/*.nii.gz ; do echo "$m $out/cache/brainmasks-dm/$(basename "$m")" ; done |
    xargs -P "$threads" -L 1 bash -c 'eucmap "$0" "$1"'
echo "build-atlas: $(find "$out"/cache/brainmasks-dm -name '*.nii.gz' | wc -l) brain distance maps written"
