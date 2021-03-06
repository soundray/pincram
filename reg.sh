#!/bin/bash

pn=$(basename "$0")
commandline="$pn $*"

. $cdir/common
. $cdir/functions

finish () {
    savewd=1
    if [[ $savewd -eq 1 ]] ; then
	mv "$td" "$wd"
    else
	rm -rf "$td"
    fi
    exit
}

set -e   # Terminate script at first error

level=$LEVEL

case "$PINCRAM_ARCH" in
    bash)
	idx=$PARALLEL_SEQ
	wd=$PWD
	chunkn=1
	;;
    pbs)
	idx=$PBS_ARRAY_INDEX
	wd=$PBS_O_WORKDIR
	jobid=$PBS_JOBID
	if [[ -n "$PINCRAM_CHUNKSIZE" ]] 
	    then chunkn="$PINCRAM_CHUNKSIZE"
	else
	    chunkn=$[$[$level-3]**2]
	fi
	;;
esac

td=$(tempdir)
trap finish EXIT
cd $td

if [[ $idx -gt 0 ]] 
then
    split -a 4 -l $chunkn -d $wd/job.conf
    idx0=$(printf '%04g' $[$idx-1])
    cp x$idx0 thischunk
    rm x????
else
    echo $@ >thischunk
fi

cat thischunk | sort -R | while read params
do

    (( loopc += 1 ))

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
	    -tmargin)       tmargin=$(normalpath "$2"); shift;;
	    -lev)               lev="$2"; shift;;
	    --) shift; break;;
            -*)
		fatal "Parameter error" ;;
	    *)  break;;
	esac
	shift
    done

    if [[ -e "$masktr" ]] ; then
	msg "Result file $masktr exists"
	continue 
    fi

    if [[ -n "$PINCRAM_USE_MIRTK" ]] ; then

	if [[ $lev == 0 ]] ; then
	    invert-dof "$tpn" tpninv.dof 
	    compose-dofs "$spn" tpninv.dof dofout.dof
	    # register $tgt $src -model Rigid -dofin pre.dof -dofout dofout.dof
	fi

	if [[ $lev == 1 ]] ; then
	    register "$tgt" "$src" \
		-dofin "$dofin" -dofout dofout.dof \
		-model Affine \
		-par "Background value" 0 \
		-par "No. of resolution levels" 2 \
		-par "Image interpolation" "Fast linear" \
		-mask "$tmargin" 
	fi

	if [[ $lev == 2 ]] ; then
	    register "$tgt" "$src" \
		-dofin "$dofin" -dofout dofout.dof \
		-model FFD \
		-par "Background value" 0 \
		-par "No. of resolution levels" 2 \
		-par "Control point spacing [mm]" 3 \
		-par "Image interpolation" "Fast linear" \
		-mask "$tmargin" 
	fi

	tempmasktr=$(echo "$masktr" | tr '/' '_')
	tempsrctr=$(echo "$srctr" | tr '/' '_')
	tempalttr=$(echo "$alttr" | tr '/' '_')
	tempdof=$(echo "$dofout" | tr '/' '_')
	transform-image "$msk" $tempmasktr -interp "Linear" -Sp -1 -dofin dofout.dof -target "$tgt" || fatal "Failure at masktr"
	transform-image "$src" $tempsrctr -interp "Linear" -Sp -1 -dofin dofout.dof -target "$tgt"  || fatal "Failure at srctr"
	transform-image "$alt" $tempalttr -interp "Linear" -Sp -1 -dofin dofout.dof -target "$tgt"  || fatal "Failure at alttr"
	gzip dofout.dof
	mv dofout.dof.gz $tempdof
    else

        if [[ $lev == 0 ]] ; then
	    cat >lev0.reg << EOF
#
# Registration parameters
#

No. of resolution levels          = 1
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
Target blurring (in mm)           = 2
Target resolution (in mm)         = 5 5 5
Source blurring (in mm)           = 2
Source resolution (in mm)         = 5 5 5
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 2

EOF
	    dofcombine "$spn" "$tpn" pre1.dof.gz -invert2
	    echo areg2 "$tgt" "$src" -dofin pre1.dof.gz -dofout pre2.dof.gz -parin lev0.reg 
	    areg2 "$tgt" "$src" -dofin pre1.dof.gz -dofout pre2.dof.gz -parin lev0.reg 
	    # nmi1=$( evaluation "$tgt" "$src" | grep NMI | cut -d : -f 2 )
	    nmi2=$( evaluation "$tgt" "$src" -dofin pre1.dof.gz | grep NMI | cut -d : -f 2 )
	    nmi3=$( evaluation "$tgt" "$src" -dofin pre2.dof.gz | grep NMI | cut -d : -f 2 )
	    cp pre2.dof.gz dofout.dof.gz
	    better=$( echo $nmi3 '>' $nmi2 | bc ) ; [[ $better -eq 0 ]] && cp pre1.dof.gz dofout.dof.gz
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

	    echo areg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev1.reg -mask $tmargin
	    areg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev1.reg -mask $tmargin
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

	    echo nreg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev2.reg -mask $tmargin
	    nreg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev2.reg -mask $tmargin
	fi

	transformation "$msk" $masktr -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt" || fatal "Failure at masktr"
	transformation "$src" $srctr -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt"  || fatal "Failure at srctr"
	transformation "$alt" $alttr -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt"  || fatal "Failure at alttr"
	mv dofout.dof.gz $dofout
    fi
done >reg-l$level-i$idx.log 2>&1

mv reg-l$level-i$idx.log $wd/

exit 0


        dofcombine "$spn" "$tpn" pre.dof.gz -invert2
        echo areg2 "$tgt" "$src" -dofin pre.dof.gz -dofout dofout.dof.gz -parin lev0.reg 
        areg2 "$tgt" "$src" -dofin pre.dof.gz -dofout dofout.dof.gz -parin lev0.reg 
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

    transformation "$msk" masktr.nii.gz -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt" || fatal "Failure at masktr"
    transformation "$src" srctr.nii.gz -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt"  || fatal "Failure at srctr"
    transformation "$alt" alttr.nii.gz -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt"  || fatal "Failure at alttr"
    cp masktr.nii.gz "$masktr"
    cp srctr.nii.gz "$srctr"   
    cp alttr.nii.gz "$alttr"   
    cp dofout.dof.gz "$dofout"
done
