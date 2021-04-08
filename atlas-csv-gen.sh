#!/bin/bash


ppath=$(realpath "$BASH_SOURCE")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/common
. "$cdir"/functions

atlasdir=$(realpath "$1") ; shift
atlascsv=$(realpath "$1")

echo "$atlasdir" >"$atlascsv"

find "$atlasdir"/images/ -name m\*.nii.gz | while read i 
do
    bn=$(basename "$i" .nii.gz)
    echo $bn,images/$bn.nii.gz,marginmasks/$bn.nii.gz,affinenorm/$bn.dof.gz,brainmasks/$bn.nii.gz,icvmasks/$bn.nii.gz
done >>$atlascsv

exit 0

