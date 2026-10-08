#!/bin/bash
#
# prealign.sh TARGET... -- compare pincram's two pre-alignments to the atlas reference space
#
# For each Hammers target: the Otsu head-mask pre-alignment (pincram without -mask) and the
# brain-mask pre-alignment (pincram -mask) with each input mask in $INPUTS (hdbet, erode3, dilate3,
# random3; see run-target.sh), each before (step 1, distance maps only) and after the intensity
# refinement (step 2). The atlas reference brain mask (base/refspace/brainmask-dm.nii.gz > 0) is
# mapped onto the target with the resulting normalization and compared with the verified TBV mask.
# Writes $EXP/prealign/<target>.csv: target,method,input,step,jaccard_refspace_mask_vs_tbv

set -e -o pipefail
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$here")")
: "${EXP:=$pincramdir/temp/mask-refine}"
: "${ATLAS:=/nobackup/proj/disk/metrimorphics0/shared/reference/ixi-pincram-atlas-n100-dm}"
: "${HAMMERS:=/nobackup/proj/disk/metrimorphics0/shared/reference/atlases-hammers-scaled-with-flipped-n60}"
: "${HDBET:=$pincramdir/temp/hdbet-targets}"
: "${INPUTS:=hdbet erode3 dilate3 random3}"
: "${THREADS:=${SLURM_CPUS_PER_TASK:-8}}"
img=$pincramdir/pincram-image
refspace=$ATLAS/base/refspace/img.nii.gz
refdm=$ATLAS/base/refspace/brainmask-dm.nii.gz
mkdir -p "$EXP/prealign"

dm () {   # dm MASK OUT : signed distance map, positive inside (pincram.sh maskdm)
    mirtk calculate-distance-map "$1" mdm.nii.gz -threads "$THREADS"
    mirtk calculate-element-wise mdm.nii.gz -mul -1 -threads "$THREADS" -o "$2"
}
odm () {  # odm IMG OUT : distance map of the smoothed Otsu head mask (pincram.sh odistmap)
    "$img" smooth-otsu otsu.nii.gz "$1" 6
    dm otsu.nii.gz "$2"
}
score () { # score DOF : Jaccard of the reference brain mask mapped onto the target with DOF, vs TBV
    mirtk transform-image refbrain.nii.gz warped.nii.gz -dofin "$1" -invert -target target.nii.gz -interp NN -threads "$THREADS" >/dev/null
    python3 -c '
import sys, nibabel as nib, numpy as np
a = np.asanyarray(nib.load(sys.argv[1]).dataobj).squeeze() > 0.5
b = np.asanyarray(nib.load(sys.argv[2]).dataobj).squeeze() > 0.5
print(f"{(a & b).sum() / (a | b).sum():.6f}")' warped.nii.gz tbv.nii.gz
}

for t in "$@" ; do
    wd=$(mktemp -d "$EXP/prealign/$t.XXXXXX") ; cd "$wd"
    out=$EXP/prealign/$t.csv ; : >"$out"
    mirtk edit-image "$HAMMERS/mri/$t.nii.gz" target.nii.gz -origin 0 0 0
    mirtk convert-image target.nii.gz target.nii.gz -float
    mirtk edit-image "$EXP/inputs/tbv-$t.nii.gz" tbv.nii.gz -origin 0 0 0
    "$img" binarize refbrain.nii.gz "$refdm"
    odm "$refspace" ref-otsu-dm.nii.gz
    for input in otsu $INPUTS ; do
        case $input in
            otsu)  odm target.nii.gz tgt-dm.nii.gz ; refd=ref-otsu-dm.nii.gz ; method=otsu-head ;;
            hdbet) m=$HDBET/hammers-${t}_mask.nii.gz ;;&
            erode*|dilate*|random*) m=$EXP/inputs/$input-$t.nii.gz ;;&
            *)     [[ $input == otsu ]] && continue
                   mirtk transform-image "$m" inmask.nii.gz -target "$HAMMERS/mri/$t.nii.gz" -interp NN >/dev/null
                   mirtk edit-image inmask.nii.gz inmask.nii.gz -origin 0 0 0
                   "$img" binarize inmask.nii.gz inmask.nii.gz
                   dm inmask.nii.gz tgt-dm.nii.gz ; refd=$refdm ; method=brain-mask ;;
        esac
        mirtk register "$refd" tgt-dm.nii.gz -model Affine -sim SSD -dofout pre.dof.gz -level 4 -threads "$THREADS" >/dev/null 2>&1
        mirtk register "$refspace" target.nii.gz -model Affine -dofin pre.dof.gz -dofout tpn.dof.gz -levels 3 1 -threads "$THREADS" >/dev/null 2>&1
        echo "$t,$method,$input,1,$(score pre.dof.gz)" >>"$out"
        echo "$t,$method,$input,2,$(score tpn.dof.gz)" >>"$out"
    done
    cat "$out"
    cd "$EXP/prealign" ; rm -rf "$wd"
done
