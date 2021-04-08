#!/usr/bin/env bash

set -e

usage() {
    msg "

    Usage: $pn -img 3d-image.nii.gz -mask brainmask.nii.gz -icv icvmask.nii.gz \\
           -dir atlas-directory 

    Options:

    [-base basename] Base name for subject.  Image name root is used if not specified

    [-affinenorm norm.dof.gz] Affine transformation normalizing entry to a common space. 
                              If not supplied, a neutral transformation is copied.

    Prepare a pincram-compatible atlas directory

    Note: at least 20 sets are needed for a pincram atlas

    If only -base basename and -dir atlas-directory are supplied, the script generates 
    contents of atlas-directory/cache using data in atlas-directory/base for the 
    corresponding entry. The idea is that the cache directory can be deleted for a 
    compact atlas representation and recreated as and when pincram is to be run.

    If an image, a brain mask, and an intracranial volume mask are supplied, 
    the script generates contents of atlas-directory/base and atlas-directory/cache.

    If atlas-directory/base/refspace/brainmask-dm.nii.gz does not exist, the script 
    copies brainmask.nii.gz to this location. When you populate a new atlas directory,
    start with the participant whose images shall serve as the reference for 
    pre-alignment.

    "
}

ppath=$(realpath "$BASH_SOURCE")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/common
. "$cdir"/functions

td=$(tempdir)
trap 'rm -rf $td' EXIT

type help-rst >/dev/null 2>&1 || fatal "MIRTK not on $PATH"

eucmap() {
    local mask=$1 ; shift
    local map=$1
    mirtk calculate-distance-map $mask dm.nii.gz -threads $par
    mirtk calculate-element-wise dm.nii.gz -mul -1 -threads $par -o $map
}

[[ $# -lt 4 ]] && fatal "Parameter error"
img=
msk=
icv=
atlasdir=
bname=
inorm=
par=1
while [[ $# -gt 0 ]]
do
    case "$1" in
        -img)               img=$(realpath "$2"); shift;;
        -mask)              msk=$(realpath "$2"); shift;;
        -icv)               icv=$(realpath "$2"); shift;;
	-affinenorm)      inorm=$(realpath "$2"); shift;;
	-dir)          atlasdir=$(realpath "$2"); shift;;
        -base)            bname="$2" ; shift ;;
        -par)               par="$2" ; shift ;;
        --) shift; break;;
        -*)
            fatal "Parameter error" ;;
        *)  break;;
    esac
    shift
done

launchdir="$PWD"
cd $td

[[ -z $bname ]] && bname=$(basename $img .nii.gz)
entree="$atlasdir"/etc/entry-$bname

mkdir -p \
      "$atlasdir"/base/images \
      "$atlasdir"/base/brainmasks \
      "$atlasdir"/base/icvmasks \
      "$atlasdir"/base/refspace \
      "$atlasdir"/cache/brainmasks-dm \
      "$atlasdir"/cache/icvmasks-dm \
      "$atlasdir"/cache/affinenorm \
      "$atlasdir"/etc || fatal "Could not create directory structure"

if [[ -e $entree ]] ; then
    msg "Re-creating cache content for $bname"
else
    cp "$img" "$atlasdir"/base/images/$bname.nii.gz
    cp "$msk" "$atlasdir"/base/brainmasks/$bname.nii.gz
    cp "$icv" "$atlasdir"/base/icvmasks/$bname.nii.gz
fi

mskdm="$atlasdir"/cache/brainmasks-dm/$bname.nii.gz
eucmap "$atlasdir"/base/brainmasks/$bname.nii.gz "$mskdm"
eucmap "$atlasdir"/base/icvmasks/$bname.nii.gz "$atlasdir"/cache/icvmasks-dm/$bname.nii.gz

affnorm="$atlasdir"/cache/affinenorm/$bname.dof.gz
dmtarget="$atlasdir"/base/refspace/brainmask-dm.nii.gz
if [[ -e "$dmtarget" ]] ; then
    if [[ -n "$inorm" ]] ; then
	cp "$inorm" "$affnorm"
    else
	mirtk register "$dmtarget" "$mskdm" -model Affine -sim SSD -dofout $affnorm -threads $par
    fi
else
    cp $cdir/neutral.dof.gz "$affnorm"
    cp "$mskdm" "$dmtarget"
fi

echo $bname >$entree

exit 0
