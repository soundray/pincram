#!/bin/bash

ppath=$(realpath "$BASH_SOURCE")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/common
. "$cdir"/functions

commandline="$pn $*"

finish () {
    savewd=1
    if [[ $savewd -eq 1 ]] ; then
	mv "$td" "$wd"
    else
	rm -rf "$td"
    fi
    exit
}

cmpdofs () {
    # Is dof1 better than dof2?
    local img1=$1 ; shift
    local img2=$1 ; shift
    local dof1=$1 ; shift
    local dof2=$1 ; shift
    nmi1=$( mirtk evaluate-similarity $img1 $img2 -csv -dofin $dof1 -threads $par | cut -d , -f 9 | tail -n 1 )
    nmi2=$( mirtk evaluate-similarity $img1 $img2 -csv -dofin $dof2 -threads $par | cut -d , -f 9 | tail -n 1 )
    echo $nmi1 '>' $nmi2 | bc 
}

set -e   # Terminate script at first error

level=$LEVEL

case "$PINCRAM_ARCH" in
    bash-single | bash)
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
set -vx
    (( loopc += 1 ))

    set -- $(echo $params)
    while [ $# -gt 0 ]
    do
	case "$1" in
	    -tgt)               tgt=$(realpath "$2"); shift;;
	    -tdm)               tdm=$(realpath "$2"); shift;;
	    -src)               src=$(realpath "$2"); shift;;
	    -srctr)           srctr=$(realpath "$2"); shift;;
	    -msk)               msk=$(realpath "$2"); shift;;
	    -masktr)         masktr=$(realpath "$2"); shift;;
	    -alt)               alt=$(realpath "$2"); shift;;
	    -alttr)           alttr=$(realpath "$2"); shift;;
	    -dofin)           dofin=$(realpath "$2"); shift;;
	    -dofout)         dofout=$(realpath "$2"); shift;;
	    -spn)               spn=$(realpath "$2"); shift;;
	    -tpn)               tpn=$(realpath "$2"); shift;;
	    -tmargin)       tmargin=$(realpath "$2"); shift;;
	    -lev)               lev="$2"; shift;;
	    -par)               par="$2"; shift;;
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

    case "$PINCRAM_USE_LIB" in

	greedy)

	    if [[ $lev == 0 ]] ; then
		mirtk compose-dofs "$spn" "$tpn" dof-pre.dof -scale 1 -1
		convert-dof dof-pre.dof dof-pre.mat -output-format flirt -target "$tgt" -source "$src"
		greedy -d 3 \
		       -a \
		       -dof 6 \
		       -threads $par \
		       -ia dof-pre.mat \
		       -i "$tgt" "$src" \
		       -o transform.mat \
		       -m NCC 5x5x5 \
		       -n 100x0x0 
		greedy -d 3 \
		       -threads $par \
		       -rf "$tgt" \
		       -ri LINEAR \
		       -rm "$msk" $masktr \
		       -rm "$src" $srctr \
		       -rm "$alt" $alttr \
		       -r transform.mat
		mv transform.mat "$dofout"
		
	    fi
	    
	    if [[ $lev == 1 ]] ; then
		greedy -d 3 \
		       -a \
		       -dof 6 \
		       -threads $par \
		       -ia "$dofin" \
		       -i "$tdm" "$msk" \
		       -gm "$tmargin" \
		       -o pre-l1.mat \
		       -m NCC 5x5x5 \
		       -n 100x50x0
		greedy -d 3 \
		       -a \
		       -dof 12 \
		       -threads $par \
		       -ia pre-l1.mat \
		       -i "$tgt" "$src" \
		       -o transform.mat \
		       -gm "$tmargin" \
		       -m NCC 3x3x3 \
		       -n 40x20x5
		greedy -d 3 \
		       -threads $par \
		       -rf "$tgt" \
		       -ri LINEAR \
		       -rm "$msk" $masktr \
		       -rm "$src" $srctr \
		       -rm "$alt" $alttr \
		       -r transform.mat
		mv transform.mat "$dofout"
	    fi
	    
	    if [[ $lev == 2 ]] ; then
		greedy -d 3 \
		       -a \
		       -dof 12 \
		       -threads $par \
		       -ia "$dofin" \
		       -i "$tdm" "$msk" \
		       -o pre-l2.mat \
		       -gm "$tmargin" \
		       -m NCC 3x3x3 \
		       -n 100x50x30
		greedy -d 3 \
		       -threads $par \
		       -i "$tgt" "$src" \
		       -it pre-l2.mat \
		       -o transform.nii.gz \
		       -gm "$tmargin" \
		       -m NCC 2x2x2 \
		       -s 1.2vox 0.25vox \
		       -n 100x50x30 
		greedy -d 3 \
		       -threads $par \
		       -rf "$tgt" \
		       -ri LINEAR \
		       -rm "$msk" $masktr \
		       -rm "$src" $srctr \
		       -rm "$alt" $alttr \
		       -r transform.nii.gz
		mv transform.nii.gz "$dofout"
		
	    fi;;

    
	mirtk)
    
	    if [[ $lev == 0 ]] ; then
		mirtk compose-dofs "$spn" "$tpn" dof-pre.dof -scale 1 -1
		mirtk register "$tgt" "$src" \
		      -model Rigid+Affine \
		      -dofout dof-reg.dof \
		      -dofin dof-pre.dof \
		      -levels 4 4 \
		      -bg 0 \
		      -threads $par
		cmp=$( cmpdofs "$tgt" "$src" dof-pre.dof dof-reg.dof )
		if [[ $cmp == 1 ]] ; then
		    cp dof-pre.dof dofout-m-$lev.dof
		else
		    cp dof-reg.dof dofout-m-$lev.dof
		fi
	    fi
	    
	    if [[ $lev == 1 ]] ; then
		mirtk register "$tgt" "$src" \
		      -model Rigid+Affine \
		      -dofout dofout-m-$lev.dof \
		      -dofin "$dofin" \
		      -mask "$tmargin" \
		      -bg -1 \
		      -levels 3 3 \
		      -threads $par
	    fi
	    
	    if [[ $lev == 2 ]] ; then
		mirtk register "$tgt" "$src" \
		      -model SVFFD \
		      -par "Bending energy weight" 1e-4 \
		      -dofout dofout-m-$lev.dof \
		      -dofin "$dofin" \
		      -mask "$tmargin" \
		      -bg -1 \
		      -levels 1 1 \
		      -threads $par
	    fi
	    
	    mirtk transform-image "$msk" $masktr -interp "Linear" -Sp -1 -dofin dofout-m-$lev.dof -target "$tgt" || fatal "Failure at masktr"
	    mirtk transform-image "$src" $srctr -interp "Linear" -Sp -1 -dofin dofout-m-$lev.dof -target "$tgt"  || fatal "Failure at srctr"
	    mirtk transform-image "$alt" $alttr -interp "Linear" -Sp -1 -dofin dofout-m-$lev.dof -target "$tgt"  || fatal "Failure at alttr"
	    mv dofout-m-$lev.dof "$dofout"
	    ;;

	irtk)

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
	    ;;

	*)
	    fatal "Not implemented: $PINCRAM_USE_LIB"
	    ;;
    esac
done >reg-l$level-i$idx.log 2>&1

exit 0
