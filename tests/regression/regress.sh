#!/bin/bash
#
# regress.sh -- regression test of pincram against real data
#
# Runs pincram at each requested processing level on a target image with known reference
# masks, records the Jaccard overlap of the parenchyma and ICV outputs with the references
# and the wall time per level, and compares the overlaps with a baseline file.
#
# Usage: tests/regression/regress.sh -target T1.nii.gz -atlas DIR|CSV -ref brainmask.nii.gz
#            [-icvref icvmask.nii.gz] [-levels "1 2 3"] [-atlasn N] [-out DIR]
#            [-leave-out NAME] [-mask input-mask.nii.gz] [-baseline FILE] [-tol 0.01]
#            [-- further pincram.sh options]
#
# -leave-out NAME removes atlas entry NAME from the atlas, so that an atlas image can serve as
# the test target (leave-one-out; NAME is the target's base name then). Without -baseline, or if
# the baseline does not exist yet, the measured values are written to DIR/results.csv and
# can be adopted as the baseline. -mask passes an input mask to pincram.sh for refinement
# (e.g. a deliberately degraded mask, to measure recovery; levels 2 and 3 only) and records its
# own Jaccard overlap with -ref as level "input". Requires MIRTK and NiftySeg (or wrappers) on the PATH,
# as pincram.sh itself does; the pincram directory is added to the PATH automatically.
#
# Baseline format (csv): level,metric,value[,tolerance]   with metric in parenchyma_jaccard, icv_jaccard;
# a row's tolerance overrides -tol. Lines starting with # are comments.

set -e -o pipefail

testsdir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$testsdir")")
export PATH=$pincramdir:$PATH

usage () {
    sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}
die () { echo "regress.sh: $*" >&2 ; exit 1 ; }

target= ; atlas= ; ref= ; icvref= ; levels="1 2 3" ; atlasn= ; out=regression-out ; baseline= ; tol=0.01 ; leaveout= ; inmask=
while [[ $# -gt 0 ]] ; do
    case $1 in
        -target)   target=$(realpath "$2") ; shift ;;
        -atlas)    atlas=$(realpath "$2") ; shift ;;
        -ref)      ref=$(realpath "$2") ; shift ;;
        -icvref)   icvref=$(realpath "$2") ; shift ;;
        -levels)   levels=$2 ; shift ;;
        -atlasn)   atlasn=$2 ; shift ;;
        -out)      out=$2 ; shift ;;
        -baseline) baseline=$(realpath -m "$2") ; shift ;;
        -leave-out) leaveout=$2 ; shift ;;
        -mask)     inmask=$(realpath "$2") ; shift ;;
        -tol)      tol=$2 ; shift ;;
        --)        shift ; break ;;
        -h|-help|--help) usage ; exit 0 ;;
        *)         usage ; die "Unknown option $1" ;;
    esac
    shift
done
extra=("$@")
[[ -n $target && -n $atlas && -n $ref ]] || { usage ; die "-target, -atlas and -ref are required" ; }
[[ -e $target && -e $atlas && -e $ref ]] || die "Input not found"
type mirtk >/dev/null 2>&1 || die "mirtk not on PATH"
if [[ -n $inmask ]] ; then
    [[ -e $inmask ]] || die "Input mask not found"
    [[ " $levels " == *" 1 "* ]] && die "-mask needs levels 2 or 3 (it replaces the coarse level)"
fi

mkdir -p "$out" ; out=$(realpath "$out")
results=$out/results.csv
echo "level,metric,value,elapsed_s" >"$results"

## Atlas csv, leaving an entry out if requested
if [[ -d $atlas ]] ; then
    "$pincramdir"/atlas-csv-gen.sh "$atlas" "$out/atlases-full.csv"
else
    cp "$atlas" "$out/atlases-full.csv"
fi
if [[ -n $leaveout ]] ; then
    grep -q "^$leaveout," "$out/atlases-full.csv" || die "-leave-out $leaveout: no such atlas entry"
    grep -v "^$leaveout," "$out/atlases-full.csv" >"$out/atlases.csv"
    echo "regress.sh: leaving atlas entry $leaveout out ($(( $(grep -c '' "$out/atlases.csv") - 1 )) atlases remain)"
else
    cp "$out/atlases-full.csv" "$out/atlases.csv"
fi

# jaccard REF IMG : Jaccard overlap of two binary masks (last column of the overlap table). IMG is
# resampled onto REF's lattice and given its header first, as the overlap tool insists on identical lattices.
jaccard () {
    local tmp=$out/overlap-tmp.nii.gz
    mirtk transform-image "$2" "$tmp" -target "$1" -interp NN >/dev/null 2>&1
    mirtk edit-image "$tmp" "$tmp" -copy-size "$1" >/dev/null 2>&1
    mirtk evaluate-label-overlap "$1" "$tmp" -precision 6 -table -noid 2>/dev/null | tail -n 1 | awk -F , '{ print $NF }'
    rm -f "$tmp"
}

if [[ -n $inmask ]] ; then
    echo "input,parenchyma_jaccard,$(jaccard "$ref" "$inmask"),0" >>"$results"
fi

for level in $levels ; do
    echo "=== level $level"
    resdir=$out/level$level
    rm -rf "$resdir"
    opts=(-result "$resdir" -atlas "$out/atlases.csv" -levels "$level" -ref "$ref")
    [[ -n $atlasn ]] && opts+=(-atlasn "$atlasn")
    [[ -n $inmask ]] && opts+=(-mask "$inmask")
    start=$(date +%s)
    pincram.sh "$target" "${opts[@]}" "${extra[@]}" 2>&1 | tee "$out/level$level.log"
    elapsed=$(( $(date +%s) - start ))
    [[ -s $resdir/parenchyma.nii.gz ]] || die "pincram produced no parenchyma mask at level $level"
    pj=$(jaccard "$ref" "$resdir/parenchyma.nii.gz")
    echo "$level,parenchyma_jaccard,$pj,$elapsed" >>"$results"
    if [[ -n $icvref ]] ; then
        ij=$(jaccard "$icvref" "$resdir/icv.nii.gz")
        echo "$level,icv_jaccard,$ij,$elapsed" >>"$results"
    fi
done

echo "=== results ($results)"
column -t -s , "$results" 2>/dev/null || cat "$results"

## Comparison with baseline
if [[ -z $baseline || ! -s $baseline ]] ; then
    echo "regress.sh: no baseline to compare with; adopt $results as baseline if the values are acceptable"
    exit 0
fi
status=0
while IFS=, read -r level metric value _ ; do
    [[ $level == level ]] && continue
    read -r expected rowtol < <(awk -F , -v l="$level" -v m="$metric" '$1 == l && $2 == m { print $3, $4 }' "$baseline")
    if [[ -z $expected ]] ; then
        echo "  n/a   level $level $metric = $value (no baseline value)"
        continue
    fi
    t=${rowtol:-$tol}
    if awk -v a="$value" -v b="$expected" -v t="$t" 'BEGIN { d = a - b ; if (d < 0) d = -d ; exit !(d <= t) }' ; then
        echo "  ok    level $level $metric = $value (baseline $expected, tolerance $t)"
    else
        echo "  FAIL  level $level $metric = $value (baseline $expected, tolerance $t)"
        status=1
    fi
done <"$results"
exit $status
