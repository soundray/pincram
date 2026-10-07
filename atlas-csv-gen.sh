#!/bin/bash
#
# atlas-csv-gen.sh -- write the atlas csv for an atlas directory created by atlas-gen.sh

ppath=$(realpath "${BASH_SOURCE[0]}")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/functions

usage() {
    msg "Usage: $pn atlas-directory output.csv"
}

[[ $# -eq 2 ]] || fatal "Two arguments expected"
atlasdir=$(realpath "$1")
atlascsv=$(realpath -m "$2")

[[ -d $atlasdir/etc ]] || fatal "$atlasdir/etc does not exist -- not an atlas directory"

echo "$atlasdir" >"$atlascsv"

cat "$atlasdir"/etc/entry-* | while read -r bn
do
    echo "$bn,base/images/$bn.nii.gz,cache/affinenorm/$bn.dof.gz,cache/brainmasks-dm/$bn.nii.gz,cache/icvmasks-dm/$bn.nii.gz"
done >>"$atlascsv"

exit 0
