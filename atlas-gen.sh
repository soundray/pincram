#!/bin/bash

usage () {
    msg "

    Usage: $pn -img 3d-image.nii.gz -mask brainmask.nii.gz -icv icvmask.nii.gz \\
           -dir atlas-directory 

    Takes an image, a brain mask, an intracranial volume mask, and a directory 
    name and creates a pincram-compatible atlas structure under the directory

    Note: at least 20 sets are needed for a pincram atlas

    Options:

    [-base basename] Base name for subject.  Image name root is used if not specified

    [-affinenorm norm.dof.gz] Affine transformation normalizing entry to a common space. 
                              If not supplied, a neutral transformation is copied.
    "
}

cdir=$(dirname "$0")
. "$cdir"/common
. "$cdir"/functions
cdir=$(normalpath "$cdir")

pn=$(basename "$0")

td=$(tempdir)
trap finish EXIT

which help-rst >/dev/null 2>&1 || fatal "MIRTK not on $PATH"

[[ $# -lt 8 ]] && fatal "Parameter error"
img=
msk=
icv=
atlasdir=
bname=
norm=$cdir/neutral.dof.gz
while [[ $# -gt 0 ]]
do
    case "$1" in
        -img)               img=$(normalpath "$2"); shift;;
        -mask)              msk=$(normalpath "$2"); shift;;
        -icv)               icv=$(normalpath "$2"); shift;;
	-affinenorm)       norm=$(normalpath "$2"); shift;;
	-dir)          atlasdir=$(normalpath "$2"); shift;;
        -base)            bname="$2" ;;
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

[[ -e $entree ]] && fatal "Entry $bname exists. Set a different -base"

launchdir="$PWD"
cd $td

cp "$img" image.nii.gz
cp "$msk" mask.nii.gz

dilate-image mask.nii.gz mask-dil.nii.gz
erode-image mask.nii.gz mask-ero.nii.gz
calculate-element-wise mask-dil.nii.gz -sub mask-ero.nii.gz -o margin-d1.nii.gz
dilate-image margin-d1.nii.gz margin-mask-d5.nii.gz -iterations 4

mkdir -p $atlasdir/images $atlasdir/marginmasks $atlasdir/etc || fatal "Could not create directory structure"
mkdir -p $atlasdir/brainmasks $atlasdir/icvmasks $atlasdir/affinenorm || fatal "Could not create directory structure"

cp image.nii.gz $atlasdir/images/$bname.nii.gz
cp margin-mask-d5.nii.gz $atlasdir/marginmasks/$bname.nii.gz
cp mask.nii.gz $atlasdir/brainmasks/$bname.nii.gz
cp "$icv" $atlasdir/icvmasks/$bname.nii.gz
cp "$norm" $atlasdir/affinenorm/$bname.dof.gz

echo -n $bname, >$entree
for i in images marginmasks ; do
    echo -n $i/$bname.nii.gz, >>$entree
done
echo -n affinenorm/$bname.dof.gz, >>$entree
echo -n brainmasks/$bname.nii.gz, >>$entree
echo -n icvmasks/$bname.nii.gz >>$entree
echo >>$entree
echo $atlasdir >$atlasdir/atlas.csv
cat $atlasdir/etc/entry-* >>$atlasdir/atlas.csv

exit 0
