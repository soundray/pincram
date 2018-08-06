\#!/bin/bash

cdir=$(dirname "$0")
. $cdir/common
. $cdir/functions
cdir=$(normalpath "$cdir")

atlasdir=$(normalpath "$1") ; shift
atlascsv=$(normalpath "$1")

echo "$atlasdir" >"$atlascsv"

find "$atlasdir"/images/full/ -name m\*.nii.gz | while read i 
do
    bn=$(basename "$i" .nii.gz)
    echo $bn,images/full/$bn.nii.gz,images/margin-d5/$bn.nii.gz,posnorm/$bn.dof.gz,brainmasks/$bn.nii.gz,icvmasks/$bn.nii.gz
done >>$atlascsv

exit 0

