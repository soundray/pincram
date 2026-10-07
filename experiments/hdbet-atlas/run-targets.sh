#!/bin/bash
#
# run-targets.sh VARIANT ATLASDIR REFSET TARGET...
#
# Runs pincram (3 levels) with ATLASDIR on each TARGET of a reference set and scores it:
#   REFSET hammers : target mri/<t>.nii.gz, parenchyma reference = binarized icmasked/<t> (verified TBV)
#   REFSET klasson : target limages/full/<t>.nii.gz, ICV reference = manual ICV; parenchyma scored
#                    against lmasks2/full (indicative only, provenance unknown)
# Results: $EXP/<variant>/<refset>/<target>/results.csv

set -e -o pipefail
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$here")")
variant=$1 ; atlas=$2 ; refset=$3 ; shift 3
: "${EXP:=$pincramdir/temp/hdbet-atlas}"
: "${PAR:=${SLURM_CPUS_PER_TASK:-32}}"
: "${HAMMERS:=/nobackup/proj/disk/metrimorphics0/shared/reference/atlases-hammers-scaled-with-flipped-n60}"
: "${KLASSON:=/nobackup/proj/disk/metrimorphics0/shared/projects/klasson/klasson-manual-n62}"
export PINCRAM_ARCH=local
refdir=$EXP/references ; mkdir -p "$refdir"

for t in "$@" ; do
    out=$EXP/$variant/$refset/$t
    case $refset in
        hammers)
            img=$HAMMERS/mri/$t.nii.gz
            ref=$refdir/hammers-tbv-$t.nii.gz
            [[ -s $ref ]] || "$pincramdir"/pincram-image binarize "$ref" "$HAMMERS/icmasked/$t.nii.gz"
            refopts=(-ref "$ref") ;;
        klasson)
            img=$KLASSON/limages/full/$t.nii.gz
            refopts=(-ref "$KLASSON/lmasks2/full/$t.nii.gz" -icvref "$KLASSON/lmasks/icvmasks-manual/$t.nii.gz") ;;
        *) echo "unknown reference set $refset" >&2 ; exit 1 ;;
    esac
    echo "=== $variant / $refset / $t  $(date)"
    "$pincramdir"/tests/regression/regress.sh -target "$img" -atlas "$atlas" "${refopts[@]}" -levels 3 -out "$out" \
        -- -par "$PAR" -threads 1 -workdir "$EXP/$variant/wd" 2>&1 |
        grep -E '^(=== |regress.sh|pincram.sh: (Level|Attempt|End|Too few)|[0-9] +(parenchyma|icv))'
    cp "$out/level3/si.csv" "$out/si.csv" 2>/dev/null || true
    rm -rf "$out"/level3/pincram.* 2>/dev/null || true
done
echo "=== $variant / $refset done $(date)"
