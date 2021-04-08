#!/bin/bash

ppath=$(realpath "$BASH_SOURCE")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/common
. "$cdir"/functions

atlasdir=$(realpath "$1") ; shift
atlascsv=$(realpath "$1")

echo "$atlasdir" >"$atlascsv"

cat "$atlasdir"/etc/entry-* | while read bn
do
    echo $bn,base/images/$bn.nii.gz,cache/affinenorm/$bn.dof.gz,cache/brainmasks-dm/$bn.nii.gz,cache/icvmasks-dm/$bn.nii.gz
done >>$atlascsv

exit 0
