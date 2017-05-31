#!/bin/bash

cdir=$(dirname $0)
. $cdir/common
cdir=$(normalpath $cdir)

atlasdir=$(normalpath $1) ; shift
atlascsv=$(normalpath $1)

echo $atlasdir >$atlascsv

find $atlasdir/limages/full/ -name m\*.nii.gz | while read i 
do
    bn=$(basename $i .nii.gz)
    echo $bn,limages/full/$bn.nii.gz,limages/margin-d5/$bn.nii.gz,lmasks/full/$bn.nii.gz,posnorm/$bn.dof.gz
done >>$atlascsv

exit 0

