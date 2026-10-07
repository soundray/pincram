#!/bin/bash
#
# reg.sh -- register one atlas to the target and transform its masks
#
# Handles one line of a pincram job file (one atlas at one level). Started by the scheduler
# in pincram.sh as a local process or as a Slurm array task; not meant to be called by hand.
#
# All output images are written to a private temporary directory and moved into place only
# when complete; the mask (-masktr) is moved last, so its existence marks a finished
# registration. On exit, a status file status/<tag>-n<line> records the exit code, the
# elapsed time and, where the cgroup exposes it, the peak memory for the scheduler's retry
# logic and for benchmarking.

ppath=$(realpath "${BASH_SOURCE[0]}")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/functions

usage () {
    msg "Usage: $pn -conf job.conf -tag <level>-a<attempt> [-line N] [-threads T]" \
        "N defaults to \$SLURM_ARRAY_TASK_ID. Called by pincram.sh; not for interactive use."
}

: "${PINCRAM_USE_LIB:=mirtk}"

### Tuned registration parameters (changing these changes the results)

src_crop_margin_mm=7          # at the nonrigid level, the atlas image is cropped to this distance around its mask
# MIRTK, per level: model, resolution levels, background value
mirtk_coarse=(-model Rigid+Affine -levels 4 4 -bg 0)
mirtk_affine=(-model Rigid+Affine -levels 3 3 -bg -1)
mirtk_nonrigid=(-model SVFFD -par "Bending energy weight" 1e-4 -levels 1 1 -bg -1)

### Parameters

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
[[ $tag == *-a* ]] || fatal "-tag must be <level>-a<attempt>"
[[ $line =~ ^[0-9]+$ ]] || fatal "Line number not given and SLURM_ARRAY_TASK_ID not set"
[[ $threads =~ ^[1-9][0-9]*$ ]] || fatal "-threads must be a positive integer"
levelname=${tag%-a*}

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

# peak_mb : peak memory of this task's cgroup in MB (cgroup v2), empty if not readable
peak_mb () {
    local cg peak
    cg=$(cut -d : -f 3 /proc/self/cgroup 2>/dev/null | head -n 1)
    peak=$(cat "/sys/fs/cgroup$cg/memory.peak" 2>/dev/null) || return 0
    [[ $peak =~ ^[0-9]+$ ]] && echo $(( peak / 1048576 ))
    return 0
}

finish () {
    local rc=$?
    echo "rc=$rc elapsed=$((SECONDS-start)) peak_mb=$(peak_mb) tag=$tag atlas=$idx level=$levelname" >"$statusfile"
    rm -rf "$td"
    exit "$rc"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

exec >>"$rundir/logs/reg-$levelname-s$idx.log" 2>&1
echo "=== $(date) $tag atlas $idx level $lev ($levelname) threads $threads ($PINCRAM_USE_LIB) ==="

cd "$td" || fatal "Cannot cd to $td"
set -e

if [[ -s $masktr ]] ; then
    msg "Result $masktr exists -- nothing to do"
    exit 0
fi

## At the nonrigid level, register the atlas image cropped to the margin of its mask
if (( lev >= 2 )) ; then
    seg_maths "$msk" -abs -uthr "$src_crop_margin_mm" -bin -mul "$src" src-cropped.nii.gz
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
                mirtk register "$tgt" "$src" "${mirtk_coarse[@]}" -dofin dof-pre.dof -dofout dof-out.dof -threads "$threads"
                ;;
            1)
                mirtk register "$tgt" "$src" "${mirtk_affine[@]}" -dofin "$dofin" -mask "$tmargin" -dofout dof-out.dof -threads "$threads"
                ;;
            2)
                mirtk register "$tgt" "$src" "${mirtk_nonrigid[@]}" -dofin "$dofin" -mask "$tmargin" -dofout dof-out.dof -threads "$threads"
                ;;
        esac
        mirtk transform-image "$msk" masktr.nii.gz -interp Linear -Sp -1 -dofin dof-out.dof -target "$tgt" -threads "$threads"
        mirtk transform-image "$src" srctr.nii.gz -interp Linear -Sp -1 -dofin dof-out.dof -target "$tgt" -threads "$threads"
        [[ -n $alttr ]] && mirtk transform-image "$alt" alttr.nii.gz -interp Linear -Sp -1 -dofin dof-out.dof -target "$tgt" -threads "$threads"
        dofresult=dof-out.dof
        ;;

    greedy)   # experimental
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
