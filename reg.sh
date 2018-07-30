#!/bin/bash

#PBS -l select=1:ncpus=1:mem=7900mb
#PBS -l place=free:shared

pn=$(basename $0)
commandline="$pn $*"

msg () {
    for msgline
    do echo "$pn: $msgline" >&2
    done
}

fatal () { msg "$@"; exit 1; }

normalpath () {
    local s=$1
    [[ $s == ${s::400} ]] || fatal "Option path too long"
    [[ $s == ${s//[^[:print:]]/} ]] || fatal "Non-printables in path"
    dir=$(dirname "$1")
    bas=$(basename "$1")
    echo $(cd $dir && pwd)/$bas
}

tempdir () {
    : ${TMPDIR:="/tmp"}
    tdbase=$TMPDIR/$USER
    test -e $tdbase || mkdir -p $tdbase
    td=$(mktemp -d $tdbase/$(basename $0).XXXXXX) || fatal "Could not create temp dir in $tdbase"
    echo $td
}

set -e   # Terminate script at first error

level=$LEVEL
echo LEVEL: $LEVEL >&2

case "$PINCRAM_ARCH" in
    bash)
	idx=$PARALLEL_SEQ
	wd=$PWD
	chunkn=1
	;;
    pbs)
	idx=$PBS_ARRAY_INDEX
	wd=$PBS_O_WORKDIR
	if [[ -n "$PINCRAM_CHUNKSIZE" ]] 
	    then chunkn="$PINCRAM_CHUNKSIZE"
	else
	    chunkn=$[$[$level-3]**2]
	fi
	;;
esac

td=$(tempdir)
cd $td

split -a 4 -l $chunkn -d $wd/job.conf
idx0=$(printf '%04g' $[$idx-1])
cp x$idx0 thischunk
rm x????

cat thischunk | sort -R | while read params
do
    set -- $(echo $params)

    while [ $# -gt 0 ]
    do
	case "$1" in
	    -tgt)               tgt=$(normalpath "$2"); shift;;
	    -src)               src=$(normalpath "$2"); shift;;
	    -srctr)           srctr=$(normalpath "$2"); shift;;
	    -msk)               msk=$(normalpath "$2"); shift;;
	    -masktr)         masktr=$(normalpath "$2"); shift;;
	    -alt)               alt=$(normalpath "$2"); shift;;
	    -alttr)           alttr=$(normalpath "$2"); shift;;
	    -dofin)           dofin=$(normalpath "$2"); shift;;
	    -dofout)         dofout=$(normalpath "$2"); shift;;
	    -spn)               spn=$(normalpath "$2"); shift;;
	    -tpn)               tpn=$(normalpath "$2"); shift;;
	    -lev)               lev="$2"; shift;;
	    --) shift; break;;
            -*)
		fatal "Parameter error" ;;
	    *)  break;;
	esac
	shift
    done

    if [[ -n "$PINCRAM_USE_MIRTK" ]] ; then
	if [[ $lev == 0 ]] ; then
	    invert-dof "$tpn" tpninv.dof
	    compose-dofs "$spn" tpninv.dof pre.dof
	    register $tgt $src -model Rigid -dofin pre.dof -dofout dofout.dof
	fi
	if [[ $lev == 1 ]] ; then
	    register "$tgt" "$src" -model Affine -dofin "$dofin" -dofout dofout.dof 
	fi
	if [[ $lev == 2 ]] ; then
	    register "$tgt" "$src" -model FFD -dofin "$dofin" -dofout dofout.dof 
	fi

	transform-image "$msk" masktr.nii.gz -interp "Linear" -dofin dofout.dof -target "$tgt" || fatal "Failure at masktr"
	transform-image "$src" srctr.nii.gz -interp "Linear"  -dofin dofout.dof -target "$tgt"  || fatal "Failure at srctr"
	transform-image "$alt" alttr.nii.gz -interp "Linear"  -dofin dofout.dof -target "$tgt"  || fatal "Failure at alttr"
	cp masktr.nii.gz "$masktr"
	cp srctr.nii.gz "$srctr"   
	cp alttr.nii.gz "$alttr"   
	gzip dofout.dof
	cp dofout.dof.gz "$dofout"
	exit 0
    fi
    
    if [[ $lev == 0 ]] ; then
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
	echo rreg2 "$tgt" "$src" -dofin pre.dof.gz -dofout dofout.dof.gz -parin lev0.reg 
	rreg2 "$tgt" "$src" -dofin pre.dof.gz -dofout dofout.dof.gz -parin lev0.reg 
    fi
    
    if [[ $lev == 1 ]] ; then
	
	cat >lev1.reg << EOF

#
# Registration parameters
#

No. of resolution levels          = 2
No. of bins                       = 64
Epsilon                           = 0.0001
Padding value                     = 0
Source padding value              = 0
Similarity measure                = NMI
Interpolation mode                = Linear

#
# Registration parameters for resolution level 1
#

Resolution level                  = 1
Target blurring (in mm)           = 0
Target resolution (in mm)         = 0 0 0
Source blurring (in mm)           = 0
Source resolution (in mm)         = 0 0 0
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 1

#
# Registration parameters for resolution level 2
#

Resolution level                  = 2
Target blurring (in mm)           = 1.5
Target resolution (in mm)         = 3 3 3
Source blurring (in mm)           = 1.5
Source resolution (in mm)         = 3 3 3
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 1

EOF

	echo areg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev1.reg
	areg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev1.reg
    fi
    
    if [[ $lev == 2 ]] ; then
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

	echo nreg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev2.reg 
	nreg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev2.reg 
    fi

    transformation "$msk" masktr.nii.gz -linear -dofin dofout.dof.gz -target "$tgt" || fatal "Failure at masktr"
    transformation "$src" srctr.nii.gz -linear -dofin dofout.dof.gz -target "$tgt"  || fatal "Failure at srctr"
    transformation "$alt" alttr.nii.gz -linear -dofin dofout.dof.gz -target "$tgt"  || fatal "Failure at alttr"
    cp masktr.nii.gz "$masktr"
    cp srctr.nii.gz "$srctr"   
    cp alttr.nii.gz "$alttr"   
    cp dofout.dof.gz "$dofout"
done
