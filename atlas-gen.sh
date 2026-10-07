#!/usr/bin/env bash
#
# atlas-gen.sh -- add an entry to a pincram atlas directory, or recreate its cache

set -e

usage() {
    msg "

    Usage: $pn -img 3d-image.nii.gz -mask brainmask.nii.gz -icv icvmask.nii.gz \\
           -dir atlas-directory

    Options:

    [-base basename] Base name for subject.  Image name root is used if not specified

    [-affinenorm norm.dof.gz] Affine transformation normalizing entry to a common space.
                              If not supplied, a neutral transformation is copied.

    [-par threads] CPU threads for MIRTK commands (default 1)

    Prepare a pincram-compatible atlas directory

    Note: at least 20 sets are needed for a pincram atlas

    If only -base basename and -dir atlas-directory are supplied, the script generates
    contents of atlas-directory/cache using data in atlas-directory/base for the
    corresponding entry. The idea is that the cache directory can be deleted for a
    compact atlas representation and recreated as and when pincram is to be run.

    If an image, a brain mask, and an intracranial volume mask are supplied,
    the script generates contents of atlas-directory/base and atlas-directory/cache.

    If atlas-directory/base/refspace/brainmask-dm.nii.gz does not exist, the script
    copies brainmask.nii.gz and 3d-image.nii.gz to this location. When a new atlas
    directory is created, the first participant's image set serves as the reference for
    pre-alignment.

    "
}

ppath=$(realpath "${BASH_SOURCE[0]}")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/functions

td=$(tempdir)
trap 'rm -rf "$td"' EXIT

type mirtk >/dev/null 2>&1 || fatal "MIRTK not on \$PATH"

# eucmap MASK OUT : negated Euclidean distance map of a binary mask
eucmap() {
    mirtk calculate-distance-map "$1" dm.nii.gz -threads "$par"
    mirtk calculate-element-wise dm.nii.gz -mul -1 -threads "$par" -o "$2"
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
        -img)        img=$(realpath "$2"); shift;;
        -mask)       msk=$(realpath "$2"); shift;;
        -icv)        icv=$(realpath "$2"); shift;;
        -affinenorm) inorm=$(realpath "$2"); shift;;
        -dir)        atlasdir=$(realpath -m "$2"); shift;;
        -base)       bname="$2" ; shift ;;
        -par)        par="$2" ; shift ;;
        --) shift; break;;
        -*)
            fatal "Parameter error" ;;
        *)  break;;
    esac
    shift
done

[[ -n $atlasdir ]] || fatal "-dir not given"
[[ -n $bname || -n $img ]] || fatal "Neither -img nor -base given"
[[ $par =~ ^[1-9][0-9]*$ ]] || fatal "-par must be a positive integer"

cd "$td"

[[ -z $bname ]] && bname=$(basename "$img" .nii.gz)
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
    [[ -n $img && -n $msk && -n $icv ]] || fatal "New entry $bname needs -img, -mask and -icv"
    cp "$img" "$atlasdir"/base/images/"$bname".nii.gz
    cp "$msk" "$atlasdir"/base/brainmasks/"$bname".nii.gz
    cp "$icv" "$atlasdir"/base/icvmasks/"$bname".nii.gz
fi

mskdm="$atlasdir"/cache/brainmasks-dm/$bname.nii.gz
eucmap "$atlasdir"/base/brainmasks/"$bname".nii.gz "$mskdm"
eucmap "$atlasdir"/base/icvmasks/"$bname".nii.gz "$atlasdir"/cache/icvmasks-dm/"$bname".nii.gz

affnorm="$atlasdir"/cache/affinenorm/$bname.dof.gz
dmtarget="$atlasdir"/base/refspace/brainmask-dm.nii.gz
if [[ -e "$dmtarget" ]] ; then
    if [[ -n "$inorm" ]] ; then
        cp "$inorm" "$affnorm"
    else
        mirtk register "$dmtarget" "$mskdm" -model Affine -sim SSD -dofout "$affnorm" -threads "$par"
    fi
else
    cp "$cdir"/neutral.dof.gz "$affnorm"
    cp "$mskdm" "$dmtarget"
    cp "$atlasdir"/base/images/"$bname".nii.gz "$atlasdir"/base/refspace/img.nii.gz
    echo "From \"$bname\"" >"$atlasdir"/base/refspace/readme
fi

echo "$bname" >"$entree"

exit 0
