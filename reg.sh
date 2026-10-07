#!/bin/bash
#
# reg.sh -- register one atlas to the target and transform its masks
#
# Handles one line of a pincram job file (one atlas at one level). Started by the scheduler
# in pincram.sh as a local process or as a Slurm array task; not meant to be called by hand.
#
# All output images are written to a private temporary directory and moved into place only
# when complete; the mask (-masktr) is moved last, so its existence marks a finished
# registration. On exit, a status file status/<tag>-n<line> records the exit code for
# the scheduler's retry logic.

ppath=$(realpath "${BASH_SOURCE[0]}")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/functions

usage () {
    msg "Usage: $pn -conf job.conf -tag TAG [-line N] [-threads T]" \
        "N defaults to \$SLURM_ARRAY_TASK_ID. Called by pincram.sh; not for interactive use."
}

: "${PINCRAM_USE_LIB:=mirtk}"

conf= ; line=${SLURM_ARRAY_TASK_ID:-} ; tag= ; threads=1
while [[ $# -gt 0 ]] ; do
    case "$1" in
        -conf)    conf=$(realpath "$2") ; shift ;;
        -line)    line=$2 ; shift ;;
        -tag)     tag=$2 ; shift ;;
        -threads) threads=$2 ; shift ;;
        *)        fatal "Unknown parameter $1" ;;
    esac
    shift
done
[[ -s $conf ]] || fatal "Job file not given or empty"
[[ -n $tag ]] || fatal "-tag not given"
[[ $line =~ ^[0-9]+$ ]] || fatal "Line number not given and SLURM_ARRAY_TASK_ID not set"
[[ $threads =~ ^[1-9][0-9]*$ ]] || fatal "-threads must be a positive integer"

rundir=$(dirname "$conf")
mkdir -p "$rundir"/status "$rundir"/logs "$rundir"/tmp
statusfile=$rundir/status/$tag-n$line
rm -f "$statusfile"

params=$(sed -n "${line}p" "$conf")
[[ -n $params ]] || fatal "No line $line in $conf"

### Job line
idx= ; lev= ; tgt= ; tdm= ; src= ; srctr= ; msk= ; masktr= ; alt= ; alttr= ; dofin= ; dofout= ; spn= ; tpn= ; tmargin=
# shellcheck disable=SC2086  # the job line is deliberately word-split
set -- $params
while [[ $# -gt 0 ]] ; do
    case "$1" in
        -idx)     idx=$2 ;;
        -lev)     lev=$2 ;;
        -tgt)     tgt=$2 ;;
        -tdm)     tdm=$2 ;;
        -src)     src=$2 ;;
        -srctr)   srctr=$2 ;;
        -msk)     msk=$2 ;;
        -masktr)  masktr=$2 ;;
        -alt)     alt=$2 ;;
        -alttr)   alttr=$2 ;;
        -dofin)   dofin=$2 ;;
        -dofout)  dofout=$2 ;;
        -spn)     spn=$2 ;;
        -tpn)     tpn=$2 ;;
        -tmargin) tmargin=$2 ;;
        *)        fatal "Job line error at '$1'" ;;
    esac
    shift 2
done
for v in idx lev tgt src srctr msk masktr dofout spn tpn ; do
    [[ -n ${!v} ]] || fatal "Job line lacks -$v"
done

### Private working directory, log and status
td=$(mktemp -d "$rundir/tmp/$tag-s$idx.XXXXXX") || fatal "Could not create temp dir in $rundir/tmp"
start=$SECONDS

finish () {
    local rc=$?
    echo "rc=$rc elapsed=$((SECONDS-start)) tag=$tag atlas=$idx level=$lev" >"$statusfile"
    rm -rf "$td"
    exit "$rc"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

exec >>"$rundir/logs/reg-l$lev-s$idx.log" 2>&1
echo "=== $(date) $tag atlas $idx level $lev threads $threads ($PINCRAM_USE_LIB) ==="

cd "$td" || fatal "Cannot cd to $td"
set -e

if [[ -s $masktr ]] ; then
    msg "Result $masktr exists -- nothing to do"
    exit 0
fi

## From the second refinement level on, register the atlas image cropped to its mask margin
if (( lev >= 2 )) ; then
    seg_maths "$msk" -abs -uthr 7 -bin -mul "$src" src-cropped.nii.gz
    src=$PWD/src-cropped.nii.gz
fi

### Registration and mask propagation
# Each branch leaves masktr.nii.gz, srctr.nii.gz, alttr.nii.gz (if -alttr given) and the
# transformation named in $dofresult in the current directory.

case "$PINCRAM_USE_LIB" in

    mirtk)
        case $lev in
            0)
                mirtk compose-dofs "$spn" "$tpn" dof-pre.dof -scale 1 -1
                mirtk register "$tgt" "$src" \
                      -model Rigid+Affine \
                      -dofout dof-out.dof \
                      -dofin dof-pre.dof \
                      -levels 4 4 \
                      -bg 0 \
                      -threads "$threads"
                ;;
            1)
                mirtk register "$tgt" "$src" \
                      -model Rigid+Affine \
                      -dofout dof-out.dof \
                      -dofin "$dofin" \
                      -mask "$tmargin" \
                      -bg -1 \
                      -levels 3 3 \
                      -threads "$threads"
                ;;
            2)
                mirtk register "$tgt" "$src" \
                      -model SVFFD \
                      -par "Bending energy weight" 1e-4 \
                      -dofout dof-out.dof \
                      -dofin "$dofin" \
                      -mask "$tmargin" \
                      -bg -1 \
                      -levels 1 1 \
                      -threads "$threads"
                ;;
        esac
        mirtk transform-image "$msk" masktr.nii.gz -interp Linear -Sp -1 -dofin dof-out.dof -target "$tgt" -threads "$threads"
        mirtk transform-image "$src" srctr.nii.gz -interp Linear -Sp -1 -dofin dof-out.dof -target "$tgt" -threads "$threads"
        [[ -n $alttr ]] && mirtk transform-image "$alt" alttr.nii.gz -interp Linear -Sp -1 -dofin dof-out.dof -target "$tgt" -threads "$threads"
        dofresult=dof-out.dof
        ;;

    greedy)
        case $lev in
            0)
                mirtk compose-dofs "$spn" "$tpn" dof-pre.dof -scale 1 -1
                convert-dof dof-pre.dof dof-pre.mat -output-format flirt -target "$tgt" -source "$src"
                greedy -d 3 -a -dof 6 -threads "$threads" \
                       -ia dof-pre.mat \
                       -i "$tgt" "$src" \
                       -o transform.mat \
                       -m NCC 5x5x5 \
                       -n 100x0x0
                dofresult=transform.mat
                ;;
            1)
                greedy -d 3 -a -dof 6 -threads "$threads" \
                       -ia "$dofin" \
                       -i "$tdm" "$msk" \
                       -gm "$tmargin" \
                       -o pre-l1.mat \
                       -m NCC 5x5x5 \
                       -n 100x50x0
                greedy -d 3 -a -dof 12 -threads "$threads" \
                       -ia pre-l1.mat \
                       -i "$tgt" "$src" \
                       -o transform.mat \
                       -gm "$tmargin" \
                       -m NCC 3x3x3 \
                       -n 40x20x5
                dofresult=transform.mat
                ;;
            2)
                greedy -d 3 -a -dof 12 -threads "$threads" \
                       -ia "$dofin" \
                       -i "$tdm" "$msk" \
                       -o pre-l2.mat \
                       -gm "$tmargin" \
                       -m NCC 3x3x3 \
                       -n 100x50x30
                greedy -d 3 -threads "$threads" \
                       -i "$tgt" "$src" \
                       -it pre-l2.mat \
                       -o transform.nii.gz \
                       -gm "$tmargin" \
                       -m NCC 2x2x2 \
                       -s 1.2vox 0.25vox \
                       -n 100x50x30
                dofresult=transform.nii.gz
                ;;
        esac
        reslice=(-rm "$msk" masktr.nii.gz -rm "$src" srctr.nii.gz)
        [[ -n $alttr ]] && reslice+=(-rm "$alt" alttr.nii.gz)
        greedy -d 3 -threads "$threads" -rf "$tgt" -ri LINEAR "${reslice[@]}" -r "$dofresult"
        ;;

    irtk)
        case $lev in
            0)
                cat >lev0.reg <<'PAR'
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

PAR
                dofcombine "$spn" "$tpn" pre1.dof.gz -invert2
                areg2 "$tgt" "$src" -dofin pre1.dof.gz -dofout pre2.dof.gz -parin lev0.reg
                # Keep the pre-alignment if the registration did not improve on it
                nmi2=$( evaluation "$tgt" "$src" -dofin pre1.dof.gz | grep NMI | cut -d : -f 2 )
                nmi3=$( evaluation "$tgt" "$src" -dofin pre2.dof.gz | grep NMI | cut -d : -f 2 )
                cp pre2.dof.gz dofout.dof.gz
                if [[ $(awk -v a="$nmi3" -v b="$nmi2" 'BEGIN { print (a > b) }') -eq 0 ]] ; then
                    cp pre1.dof.gz dofout.dof.gz
                fi
                ;;
            1)
                cat >lev1.reg <<'PAR'
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

PAR
                areg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev1.reg -mask "$tmargin"
                ;;
            2)
                cat >lev2.reg <<'PAR'
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

PAR
                nreg2 "$tgt" "$src" -dofin "$dofin" -dofout dofout.dof.gz -parin lev2.reg -mask "$tmargin"
                ;;
        esac
        transformation "$msk" masktr.nii.gz -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt"
        transformation "$src" srctr.nii.gz -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt"
        [[ -n $alttr ]] && transformation "$alt" alttr.nii.gz -linear -Sp -1 -dofin dofout.dof.gz -target "$tgt"
        dofresult=dofout.dof.gz
        ;;

    *)
        fatal "Not implemented: PINCRAM_USE_LIB=$PINCRAM_USE_LIB"
        ;;
esac

### Move results into place; the mask comes last because it marks completion
[[ -n $alttr ]] && mv alttr.nii.gz "$alttr"
mv "$dofresult" "$dofout"
mv srctr.nii.gz "$srctr"
mv masktr.nii.gz "$masktr"

msg "Done in $((SECONDS-start)) s"
exit 0
