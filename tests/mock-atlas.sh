#!/bin/bash
# mock-atlas.sh N DIR : create a placeholder atlas directory with N entries in the layout of atlas-gen.sh
set -e
n=$1 ; dir=$2
[[ $n =~ ^[0-9]+$ && -n $dir ]] || { echo "Usage: $0 N DIR" >&2 ; exit 1 ; }
mkdir -p "$dir"/{etc,base/images,base/refspace,cache/affinenorm,cache/brainmasks-dm,cache/icvmasks-dm}
for ((i=1; i<=n; i++)) ; do
    echo "m$i" >"$dir/etc/entry-m$i"
    for f in base/images/m$i.nii.gz cache/affinenorm/m$i.dof.gz cache/brainmasks-dm/m$i.nii.gz cache/icvmasks-dm/m$i.nii.gz ; do
        echo "placeholder $f" >"$dir/$f"
    done
done
echo "placeholder refspace" >"$dir/base/refspace/img.nii.gz"
