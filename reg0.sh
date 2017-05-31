#!/bin/bash

if [[ $PBS_ARRAY_INDEX -gt 0 ]] 
then
    idx=$PBS_ARRAY_INDEX
    wd=$PBS_O_WORKDIR
else
    idx=$1
    wd=$PWD
fi

set -- $(head -n $idx $wd/job.conf | tail -n 1)

tgt="$1" ; shift
src="$1" ; shift
srctr="$1" ; shift
msk="$1" ; shift
masktr="$1"; shift
dofin="$1"; shift
dofout="$1"; shift
spn="$1"; shift
tpn="$1"; shift

cat >lev0.reg << EOF

#
# Registration parameters
#

No. of resolution levels          = 2
No. of bins                       = 64
Epsilon                           = 0.0001
Padding value                     = -1
Source padding value              = -1
Similarity measure                = NMI
Interpolation mode                = Linear

#
# Registration parameters for resolution level 1
#

Resolution level                  = 1
Target blurring (in mm)           = 1
Target resolution (in mm)         = 2 2 2
Source blurring (in mm)           = 1
Source resolution (in mm)         = 2 2 2
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 1

#
# Registration parameters for resolution level 2
#

Resolution level                  = 2
Target blurring (in mm)           = 2
Target resolution (in mm)         = 5 5 5
Source blurring (in mm)           = 2
Source resolution (in mm)         = 5 5 5
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 2

EOF

dofcombine "$spn" "$tpn" pre.dof.gz -invert2
echo rreg2 "$tgt" "$src" -dofin pre.dof.gz -dofout "$dofout" -parin lev0.reg
rreg2 "$tgt" "$src" -dofin pre.dof.gz -dofout "$dofout" -parin lev0.reg
transformation "$msk" "$masktr" -linear -dofin "$dofout" -target "$tgt"
transformation "$src" "$srctr" -linear -dofin "$dofout" -target "$tgt"
