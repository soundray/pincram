#!/bin/bash

usage () {
    msg "

    Usage: $pn -img 3d-image.nii.gz -mask brainmask.nii.gz -icv icvmask.nii.gz \
               -dir atlas-directory 

    Takes an image, a brain mask, an intracranial volume mask, and a directory 
    name and creates a pincram-compatible atlas structure under the directory

    Note: at least 20 sets are needed for a pincram atlas

    Options:

    [-base basename] Base name for subject.  Image name root is used if not specified

    [-posnorm posnorm.dof.gz] Positionally normalizing rigid transformation. If not 
                              supplied, a neutral transformation is copied.
    "
}

cdir=$(dirname "$0")
. "$cdir"/common
. "$cdir"/functions
cdir=$(normalpath "$cdir")

pn=$(basename "$0")

td=$(tempdir)
trap finish EXIT

which help-rst >/dev/null || fatal "MIRTK not on $PATH"

[[ $# -lt 8 ]] && fatal "Parameter error"
img=
msk=
icv=
atlasdir=
bname=
posnorm=$cdir/neutral.dof.gz
while [[ $# -gt 0 ]]
do
    case "$1" in
        -img)               img=$(normalpath "$2"); shift;;
        -mask)              msk=$(normalpath "$2"); shift;;
        -icv)               icv=$(normalpath "$2"); shift;;
	-atlasdir)     atlasdir=$(normalpath "$2"); shift;;
        -basename)        bname="$2" ;;
	-posnorm)       posnorm=$(normalpath "$2"); shift;;
        --) shift; break;;
        -*)
            fatal "Parameter error" ;;
        *)  break;;
    esac
    shift
done

[[ -n "$img" ]] || fatal "Input image not provided"
[[ -e "$img" ]] || fatal "Input image file does not exist"

entree=$atlasdir/etc/entry-$bname

[[ -e $entree ]] && fatal "Entry $bname exists. Set a different -basename"

launchdir="$PWD"
cd $td

cp "$img" image.nii.gz
cp "$msk" mask.nii.gz

dilate-image mask.nii.gz mask-dil.nii.gz
erode-image mask.nii.gz mask-ero.nii.gz
calculate-element-wise mask-dil.nii.gz -sub mask-ero.nii.gz -o margin-d1.nii.gz
dilate-image margin-d1.nii.gz margin-mask-d5.nii.gz -iterations 4
calculate-element-wise image.nii.gz -mask margin-mask-d5.nii.gz 0 -pad 0 -o margin-d5.nii.gz

mkdir -p $atlasdir/images/full $atlasdir/images/margin-d5 $atlasdir/etc || fatal "Could not create directory structure"
mkdir -p $atlasdir/brainmasks $atlasdir/icvmasks $atlasdir/posnorm || fatal "Could not create directory structure"

cp image.nii.gz $atlasdir/images/full/$bname.nii.gz
cp margin-d5.nii.gz $atlasdir/images/margin-d5/$bname.nii.gz
cp mask.nii.gz $atlasdir/brainmasks/$bname.nii.gz
cp "$icv" $atlasdir/icvmasks/$bname.nii.gz
cp "$posnorm" $atlasdir/posnorm/$bname.dof.gz

echo -n $bname, >$entree
for i in images/full images/margin-d5 brainmasks icvmasks ; do
    echo -n $i/$bname.nii.gz, >>$entree
done
echo posnorm/$bname.dof.gz >>$entree

exit 0

