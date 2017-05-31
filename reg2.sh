#!/bin/bash

set -- $(head -n $PBS_ARRAY_INDEX $PBS_O_WORKDIR/job.conf | tail -n 1)

tgt="$1" ; shift
src="$1" ; shift
srctr="$1" ; shift
msk="$1" ; shift
masktr="$1"; shift
dofin="$1"; shift
dofout="$1"; shift
spn="$1"; shift
tpn="$1"; shift

cat >lev2.reg << EOF

#
# Non-rigid registration parameters
#

Lambda1                           = 0.0001
Lambda2                           = 1
Lambda3                           = 1
Control point spacing in X        = 6
Control point spacing in Y        = 6
Control point spacing in Z        = 6
Subdivision                       = True
MFFDMode                          = True

#
# Registration parameters
#

No. of resolution levels          = 1
No. of bins                       = 128
Epsilon                           = 0.0001
Padding value                     = 0
Source padding value              = 0
Similarity measure                = NMI
Interpolation mode                = Linear

#
# Skip resolution level 1
#

Resolution level                  = 1
Target blurring (in mm)           = 0
Target resolution (in mm)         = 0 0 0
Source blurring (in mm)           = 0
Source resolution (in mm)         = 0 0 0
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 2

EOF

nreg2 "$tgt" "$src" -dofin "$dofin" -dofout "$dofout" -parin lev2.reg
transformation "$msk" "$masktr" -linear -dofin "$dofout" -target "$tgt"
transformation "$src" "$srctr" -linear -dofin "$dofout" -target "$tgt"
