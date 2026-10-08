#!/bin/bash
#
# pincram.sh -- brain extraction using label propagation and group agreement
#
# Driver. Prepares the target, then for each refinement level registers the selected atlases
# to the target in parallel (see "scheduler"), fuses the transformed masks, ranks the atlases
# by similarity and narrows the selection for the next level. Intermediate files have defined
# lifetimes; see README.md, "Working directory".

set -e -o pipefail

### Usage & parameter handling

usage () {
    cat <<EOF

Copyright (C) 2012-2026 Rolf A. Heckemann
Web site: http://www.soundray.org/pincram

Usage: $pn <input> -result result-dir/ [-atlas atlas-dir/ | -atlas file.csv] [-atlasn N] [-levels {1..3}]
                        [-par N] [-threads T] [-workdir dir/] [-savewd] [-savedm] [-tpn norm.dof.gz] [-ref ref.nii.gz]
                        [-mask mask.nii.gz [-refine-band mm]]

<input>     : T1-weighted magnetic resonance image in gzipped NIfTI format.

-result     : Directory to receive output files (parenchyma.nii.gz, icv.nii.gz, si.csv). Created if it
              does not exist; existing contents are overwritten.

-atlas      : Atlas directory, or csv file describing the atlas database. A directory must contain the
              etc/entry-* files written by atlas-gen.sh (or a ready-made etc/atlases.csv). In a csv file,
              the first row is the base directory for atlas files; each further row describes one atlas
              with paths relative to the base directory. Column 1: atlas name (unique), Column 2: full
              image, Column 3: transformation (.dof format) for positional normalization, Column 4: prime
              mask, Column 5: alternative mask. Mask voxels should range from -1 (background) to 1
              (foreground); discrete or probabilistic maps are both allowed. Prime masks are typically
              parenchyma masks and alternative masks are intracranial volume masks, but this can be
              swapped. The output distance map is calculated on the prime (Column 4) input.

-atlasn     : Use a maximum of N atlases. By default, all available are used. At least 7 are needed.

-levels     : Number of refinement levels, 1 to 3 (default 3): coarse, affine, nonrigid.

-par        : Maximum number of registrations running at the same time. Local execution: default is the
              number of available CPUs divided by -threads. Slurm: default is no limit (the value becomes
              the job array throttle).

-threads    : CPU threads per registration (default 1). Under Slurm this sets --cpus-per-task.

-workdir    : Base directory in which a uniquely named working directory is created for the run. Default:
              \$TMPDIR/\$USER for local execution; the current directory under Slurm (it must be visible
              from the compute nodes).

-savewd     : Move the working directory into the result directory at the end instead of deleting it.

-savedm     : Save the final distance map to the result directory as prime-distmap.nii.gz.

-tpn        : Transformation normalizing the target to the atlas reference space. By default it is
              calculated by registering the target to the atlas's base/refspace/img.nii.gz.

-ref        : Reference label against which to log Jaccard overlap results (assess.log).

-mask       : Existing brain mask of the input (same convention as the atlas prime masks; voxels > 0 are
              brain, any lattice) to be refined. It replaces the fused mask of the coarse level: the atlases
              are transformed with their normalization only (no coarse registration), ranked within the
              margin of the input mask, and the input mask steers the affine level's registrations. Without
              -tpn, the pre-alignment registers the atlas's reference brain-mask distance map to the input
              mask's. Needs -levels 2 or 3.

-refine-band: Restrict pincram's decision to a band of this width (mm) around the input mask's boundary:
              the output keeps the input mask's foreground deeper than this inside and its background
              farther than this outside. Affects the parenchyma mask (and, through it, the ICV mask).

Environment:

PINCRAM_ARCH          local (default) or slurm: how registrations are run. See README.md.
PINCRAM_USE_LIB       mirtk (default) or greedy (experimental): registration library.
PINCRAM_PROCEED_PCT   Percentage of the selected atlases that must be registered successfully (after
                      retries) for a level to proceed (default 100).
PINCRAM_MAX_ATTEMPTS  Attempts per registration before giving up on an atlas (default 3).
PINCRAM_SLURM_MEM     Memory per registration task, one value per level (default "4G 4G 8G").
PINCRAM_SLURM_TIME    Time limit per registration task in minutes, one value per level (default "30 30 120").
PINCRAM_SLURM_OPTS    Further sbatch options, e.g. "-A account -p partition".
PINCRAM_DRIVER_THREADS Threads for the driver's own image processing steps (default: see README.md).
PINCRAM_IMAGE         Path of the pincram-image tool (default: next to this script); set it to run it with a
                      particular Python environment.

EOF
}

ppath=$(realpath "${BASH_SOURCE[0]}")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/functions

commandline="$pn $*"

# version : short commit SHA of this pincram. Nix builds record it in VERSION (the store copy has no
# .git); a git checkout reports it directly, with -dirty if tracked files have uncommitted changes.
version () {
    local sha
    if [[ -s $cdir/VERSION ]] ; then
        head -n 1 "$cdir/VERSION"
    elif sha=$(git -C "$cdir" rev-parse --short HEAD 2>/dev/null) ; then
        [[ -n $(git -C "$cdir" status --porcelain --untracked-files=no 2>/dev/null) ]] && sha+=-dirty
        echo "$sha"
    else
        echo unknown
    fi
}
pincram_version=$(version)
msg "pincram version $pincram_version"     # first, so that runs ending in fatal report it too

### Tuned parameters (Heckemann et al. 2015; changing these changes the results)

min_atlases=7            # fewest atlases a level may be fused from, and the smallest selection
final_selection=8        # the per-level selection fraction is chosen so that about this many atlases
                         # remain after three rounds: fraction = (final_selection / atlasn)^(1/3)
selection_floor_below=9  # selections smaller than this are set to min_atlases
otsu_smoothing_vox=6     # Gaussian standard deviation (voxels) before Otsu thresholding in the reference-space pre-alignment
otsu_fill=()             # (-fill [radius]) would fill cavities of the Otsu head mask; left empty, see docs/experiments.md

# rank_margin_mm LEVEL : distance from the fused boundary within which atlases are ranked by
# similarity; (5-level)^2/3 gives 8.3, 5.3, 3.0 mm at the coarse, affine and nonrigid level
rank_margin_mm () { awk -v l="$1" 'BEGIN { printf "%.8f", (l-5)^2/3 }' ; }
# reg_margin_mm LEVEL : distance from the fused boundary that masks the next level's registrations;
# (6-level)^2/5 gives 7.2 and 5.0 mm after the coarse and affine level
reg_margin_mm ()  { awk -v l="$1" 'BEGIN { printf "%.8f", (l-6)^2/5 }' ; }

: "${PINCRAM_ARCH:=local}"
: "${PINCRAM_USE_LIB:=mirtk}"
: "${PINCRAM_PROCEED_PCT:=100}"

case $PINCRAM_ARCH in
    local|bash) arch=local ;;
    slurm)      arch=slurm
                type sbatch >/dev/null 2>&1 || fatal "PINCRAM_ARCH=slurm, but sbatch is not on the path" ;;
    *)          fatal "PINCRAM_ARCH=$PINCRAM_ARCH is not supported (use local or slurm)" ;;
esac

case $PINCRAM_USE_LIB in
    mirtk)  ;;
    greedy) type greedy >/dev/null 2>&1 || fatal "Missing binary: greedy not on path" ;;
    *)      fatal "PINCRAM_USE_LIB=$PINCRAM_USE_LIB is not supported (use mirtk or greedy)" ;;
esac
type mirtk     >/dev/null 2>&1 || fatal "Missing binary: mirtk (MIRTK) not on path"
: "${PINCRAM_IMAGE:=$cdir/pincram-image}"      # voxel-wise image operations (python3 with numpy, scipy, nibabel)
"$PINCRAM_IMAGE" -h >/dev/null 2>&1 || fatal "$PINCRAM_IMAGE cannot run: python3 with numpy, scipy and nibabel is needed"
export PINCRAM_ARCH PINCRAM_USE_LIB PINCRAM_IMAGE

. "$cdir"/scheduler

[[ $# -lt 3 ]] && fatal "Too few parameters"

tgt=$(realpath "$1") ; shift
[[ -e $tgt ]] || fatal "No image found -- $tgt"

tpn= ; inmask= ; refineband= ; result= ; par= ; threads=1 ; ref=none ; atlas=$cdir/atlas ; atlasn=0 ; workdir= ; savewd=0 ; savedm=0 ; levels=3
while [[ $# -gt 0 ]] ; do
    case "$1" in
        -tpn)     tpn=$(realpath "$2") ; shift ;;
        -result)  result=$(realpath -m "$2") ; shift ;;
        -atlas)   atlas=$(realpath "$2") ; shift ;;
        -workdir) workdir=$(realpath -m "$2") ; shift ;;
        -ref)     ref=$(realpath "$2") ; shift ;;
        -mask)    inmask=$(realpath "$2") ; shift ;;
        -refine-band) refineband=$2 ; shift ;;
        -savewd)  savewd=1 ;;
        -savedm)  savedm=1 ;;
        -atlasn)  atlasn=$2 ; shift ;;
        -levels)  levels=$2 ; shift ;;
        -par)     par=$2 ; shift ;;
        -threads) threads=$2 ; shift ;;
        -pickup)  fatal "-pickup has been removed: runs cannot be resumed" ;;
        -*)       fatal "Unknown parameter $1" ;;
        *)        fatal "Unexpected argument $1" ;;
    esac
    shift
done

[[ -n $result ]] || fatal "Result directory name not set (e.g. -result pincram-masks)"
mkdir -p "$result" || fatal "Failed to create directory for result output ($result)"
[[ -e $atlas ]] || fatal "Atlas directory or file does not exist ($atlas)"
[[ $levels =~ ^[1-3]$ ]] || fatal "-levels must be 1, 2 or 3"
maxlevel=$((levels-1))
if [[ -n $inmask ]] ; then
    [[ -e $inmask ]] || fatal "Input mask does not exist ($inmask)"
    (( levels >= 2 )) || fatal "-mask replaces the coarse level and needs -levels 2 or 3"
fi
if [[ -n $refineband ]] ; then
    [[ -n $inmask ]] || fatal "-refine-band needs -mask"
    [[ $refineband =~ ^[0-9]+([.][0-9]+)?$ ]] || fatal "-refine-band must be a non-negative number (mm)"
fi
[[ $atlasn =~ ^[0-9]+$ ]] || fatal "-atlasn must be an integer"
[[ $threads =~ ^[1-9][0-9]*$ ]] || fatal "-threads must be a positive integer"
[[ $PINCRAM_PROCEED_PCT =~ ^[0-9]+$ && $PINCRAM_PROCEED_PCT -le 100 ]] || fatal "PINCRAM_PROCEED_PCT must be an integer from 0 to 100"
minpct=$PINCRAM_PROCEED_PCT

## Concurrency: -par registrations at a time, -threads each; the driver's own steps use drvthreads
ncpu=$(nproc)
if [[ -z $par ]] ; then
    if [[ $arch == local ]] ; then par=$(( ncpu / threads )) ; (( par < 1 )) && par=1 ; else par=0 ; fi
fi
[[ $par =~ ^[0-9]+$ ]] || fatal "-par must be a non-negative integer"
[[ $arch == local && $par -eq 0 ]] && fatal "-par must be at least 1 for local execution"
drvthreads=${PINCRAM_DRIVER_THREADS:-}
if [[ -z $drvthreads ]] ; then
    if [[ $arch == local ]] ; then
        drvthreads=$(( par * threads )) ; (( drvthreads > ncpu )) && drvthreads=$ncpu
    else
        drvthreads=${SLURM_CPUS_ON_NODE:-$threads}
    fi
fi
[[ $drvthreads =~ ^[1-9][0-9]*$ ]] || fatal "PINCRAM_DRIVER_THREADS must be a positive integer"

msg "$(date)"
msg "Extracting $tgt"
msg "Writing brain label to $result"
msg "Execution: $arch, library $PINCRAM_USE_LIB, $( (( par > 0 )) && echo "up to $par" || echo "unlimited") concurrent registrations with $threads thread(s) each, $drvthreads thread(s) for fusion steps"

### Functions

finish () {
    local rc=$? jid active
    set +e
    if [[ $arch == slurm ]] ; then
        jid=$(cat "$td"/slurm-*.jobid 2>/dev/null | paste -s -d ,)
        if [[ -n $jid ]] ; then
            active=$(squeue -j "$jid" -h -r -o %A 2>/dev/null | sort -u | paste -s -d ,)
            if [[ -n $active ]] ; then
                msg "Cancelling Slurm job(s) $active"
                scancel "$active"
            fi
        fi
    fi
    if [[ $savewd -eq 1 ]] ; then
        chmod -R u+rwX "$td"
        mv "$td" "$result"/
        msg "Working directory saved as $result/$(basename "$td")"
    else
        rm -rf "$td"
    fi
    exit "$rc"
}

labelstats () {
    mirtk evaluate-label-overlap "$1" "$2" -precision 6 -table -noid | tail -n 1
}

# assess LABEL : log the overlap of LABEL with the -ref image, if given. The label is resampled
# onto the reference lattice and given its header, as the overlap tool insists on identical lattices.
assess () {
    local glabels=$1
    if [[ -e ref.nii.gz ]] ; then
        mirtk transform-image "$glabels" assess.nii.gz -target ref.nii.gz -interp NN >>noisy.log 2>&1
        mirtk edit-image assess.nii.gz assess.nii.gz -copy-size ref.nii.gz >>noisy.log 2>&1
        echo -e "${glabels}:\t\t$(labelstats ref.nii.gz assess.nii.gz)"
    fi
    return 0
}

origin () {
    mirtk info "$1" | grep -v 'File name' | grep -i origin | tr -d ',' | tr -s ' ' | cut -d ' ' -f 4-6
}

# maskdm MASK OUT : signed distance map (mm) of a binary mask, positive inside like the atlas masks
maskdm () {
    mirtk calculate-distance-map "$1" mdm.nii.gz -threads "$drvthreads"
    mirtk calculate-element-wise mdm.nii.gz -mul -1 -threads "$drvthreads" -o "$2"
}

# odistmap IMG OUT : distance map of the Otsu-thresholded, smoothed image
odistmap () {
    "$PINCRAM_IMAGE" smooth-otsu im-otsu.nii.gz "$1" "$otsu_smoothing_vox" "${otsu_fill[@]}"
    maskdm im-otsu.nii.gz "$2"
}

### Working directory

if [[ -z $workdir ]] ; then
    if [[ $arch == slurm ]] ; then workdir=$PWD ; else workdir=${TMPDIR:-/tmp}/$USER ; fi
fi
mkdir -p "$workdir" || fatal "Could not create $workdir"
td=$(mktemp -d "$workdir/pincram.XXXXXX") || fatal "Could not create working directory in $workdir"
trap finish EXIT
cd "$td" || fatal "Cannot cd to working directory $td"
mkdir -p status logs tmp
msg "Working in directory $td"
msg "$commandline"
printf '%s\n# pincram version %s\n' "$commandline" "$pincram_version" >commandline.log

### Atlas database read and check

if [[ -d $atlas ]] ; then
    if [[ -e $atlas/etc/atlases.csv ]] ; then
        atlas=$atlas/etc/atlases.csv
    else
        "$cdir"/atlas-csv-gen.sh "$atlas" atlases.csv
        atlas=$PWD/atlases.csv
    fi
fi

atlasbase=$(head -n 1 "$atlas")
IFS=, read -r _ f1 f2 f3 f4 < <(sed -n 2p "$atlas")
for f in "$f1" "$f2" "$f3" "$f4" ; do
    [[ -e $atlasbase/$f ]] || fatal "Atlas error ($atlasbase/$f does not exist)"
done

refspace=
if [[ -z $tpn ]] ; then
    refspace=$atlasbase/base/refspace/img.nii.gz
    [[ -e $refspace ]] || fatal "No reference space found ($refspace) and -tpn not provided"
fi

atlasmax=$(( $(grep -c '' "$atlas") - 1 ))
(( atlasn == 0 || atlasn > atlasmax )) && atlasn=$atlasmax
(( atlasn >= min_atlases )) || fatal "At least $min_atlases atlases are needed; $atlasn available"

### Target preparation

originalorigin=$(origin "$tgt")
mirtk edit-image "$tgt" target-full.nii.gz -origin 0 0 0
mirtk convert-image target-full.nii.gz target-full.nii.gz -float
if [[ -e $ref ]] ; then
    mirtk edit-image "$ref" ref.nii.gz -origin 0 0 0
    chmod +w ref.nii.gz
fi
if [[ -n $inmask ]] ; then
    # onto the target lattice in world coordinates, then the same origin shift as the target
    mirtk transform-image "$inmask" input-mask.nii.gz -target "$tgt" -interp NN >>noisy.log 2>&1
    mirtk edit-image input-mask.nii.gz input-mask.nii.gz -origin 0 0 0 >>noisy.log 2>&1
    "$PINCRAM_IMAGE" binarize input-mask.nii.gz input-mask.nii.gz
    maskdm input-mask.nii.gz input-dm.nii.gz
    assess input-mask.nii.gz | tee -a assess.log
fi
if [[ -n $refspace ]] ; then
    refspacedm=$atlasbase/base/refspace/brainmask-dm.nii.gz
    if [[ -n $inmask && -e $refspacedm ]] ; then
        msg "Calculating affine normalization to reference space with brain mask distance maps"
        cp "$refspacedm" refspace-dm.nii.gz
        cp input-dm.nii.gz target-dm.nii.gz
    else
        [[ -n $inmask ]] && msg "No $refspacedm in the atlas: pre-aligning with head masks"
        msg "Calculating affine normalization to reference space with distance maps"
        odistmap "$refspace" refspace-dm.nii.gz
        odistmap target-full.nii.gz target-dm.nii.gz
    fi
    mirtk register refspace-dm.nii.gz target-dm.nii.gz \
          -model Affine \
          -sim SSD \
          -dofout pre-dof.gz \
          -level 4 \
          -threads "$drvthreads" >noisy.log 2>&1
    mirtk register "$refspace" target-full.nii.gz \
          -model Affine \
          -dofin pre-dof.gz \
          -dofout tpn.dof.gz \
          -levels 3 1 \
          -threads "$drvthreads" >>noisy.log 2>&1
    tpn=$td/tpn.dof.gz
fi

### Iterate over levels
#
# Job lines: one per atlas and level, in job-<level>-a1.conf, consumed by reg.sh:
#   -idx N -lev L [-register 0] -tgt IMG -src IMG -msk IMG -spn DOF -tpn DOF -tmargin IMG
#   -srctr OUT -masktr OUT -dofin DOF -dofout OUT [-tdm IMG] [-alt IMG -alttr OUT]
# -tdm (fused mask of the previous level) exists from level 1 on; the alternative masks
# are only propagated at the final level, where they are needed.
#
# With -mask, level 0 is "prealigned": the job lines carry -register 0, so the atlases are only
# transformed with their normalization, and the input mask takes the place of the fused mask
# (ranking margin, -tdm and registration margin of the affine level).

levelname=(coarse affine nonrigid)
[[ -n $inmask ]] && levelname[0]=prealigned
tgt=$PWD/target-full.nii.gz
tdm=
tmg=$tgt
prevlevel=init
seq 1 "$atlasn" >selection-$prevlevel.csv
nselected=$atlasn
usepercent=$(awk -v n="$nselected" -v f="$final_selection" 'BEGIN { printf "%.0f", 100*(f/n)^(1/3) }')

for level in $(seq 0 "$maxlevel") ; do
    thislevel=${levelname[$level]}
    msg "Level $level ($thislevel)"

    ## Job lines for the atlases selected at the previous level
    conf=$td/job-$thislevel-a1.conf
    : >"$conf"
    while read -r srcindex ; do
        IFS=, read -r _ src spn msk alt < <(sed -n "$((srcindex+1))p" "$atlas")
        line="-idx $srcindex -lev $level"
        [[ $level -eq 0 && -n $inmask ]] && line+=" -register 0"
        line+=" -tgt $tgt -src $atlasbase/$src -msk $atlasbase/$msk"
        line+=" -spn $atlasbase/$spn -tpn $tpn -tmargin $tmg"
        line+=" -srctr $PWD/srctr-$thislevel-s$srcindex.nii.gz -masktr $PWD/masktr-$thislevel-s$srcindex.nii.gz"
        line+=" -dofin $PWD/reg-s$srcindex-$prevlevel.dof.gz -dofout $PWD/reg-s$srcindex-$thislevel.dof.gz"
        (( level > 0 )) && line+=" -tdm $tdm"
        (( level == maxlevel )) && line+=" -alt $atlasbase/$alt -alttr $PWD/alttr-s$srcindex.nii.gz"
        echo "$line" >>"$conf"
    done <selection-"$prevlevel".csv

    ## Registrations, with retries
    minready=$(( nselected * minpct / 100 ))
    (( minready < min_atlases )) && minready=$min_atlases
    run_registrations "$level" "$thislevel"
    thissize=$(count_ready "$thislevel")
    msg "Level $thislevel: $thissize of $nselected mask transformations completed (minimum $minready)"
    (( thissize >= minready )) || fatal "Too few registrations succeeded at level $thislevel"

    ## Reference for atlas selection, fused from all transformed masks
    msg "Building reference atlas for selection at level $thislevel"
    "$PINCRAM_IMAGE" mean tmask-"$thislevel"-sum.nii.gz masktr-"$thislevel"-s*.nii.gz
    tdm=$PWD/tmask-$thislevel-sum.nii.gz
    (( level == 0 )) && [[ -n $inmask ]] && tdm=$PWD/input-dm.nii.gz      # the input mask replaces the coarse fusion

    ## Intermediate target mask
    "$PINCRAM_IMAGE" binarize tmask-"$thislevel".nii.gz tmask-"$thislevel"-sum.nii.gz
    assess tmask-"$thislevel".nii.gz | tee -a assess.log

    ## Target margin mask for similarity ranking
    "$PINCRAM_IMAGE" band emargin-"$thislevel"-dil.nii.gz "$tdm" "$(rank_margin_mm "$level")"

    ## Selection: rank atlases by NMI between their transformed image and the target within the margin
    msg "Selecting"
    srcs=(srctr-"$thislevel"-s*.nii.gz)
    mirtk evaluate-similarity target-full.nii.gz "${srcs[@]}" \
          -mask emargin-"$thislevel"-dil.nii.gz \
          -metric NMI -precision 7 -threads "$drvthreads" \
          -table -header off |
        sed -E 's/^.*-s([0-9]+),/\1,/' | sort -rn -t , -k 2 >simm-"$thislevel".csv
    [[ -s simm-$thislevel.csv ]] || fatal "Similarity ranking failed at level $thislevel"
    cut -d , -f 1 simm-"$thislevel".csv >ranking-"$thislevel".csv
    rm -f srctr-"$thislevel"-s*.nii.gz                         # srctr: no longer needed

    maxweight=$(head -n 1 simm-"$thislevel".csv | cut -d , -f 2)
    nselected=$(( thissize * usepercent / 100 ))
    (( nselected < selection_floor_below )) && nselected=$min_atlases
    head -n "$nselected" ranking-"$thislevel".csv >selection-"$thislevel".csv
    tail -n +"$((nselected+1))" ranking-"$thislevel".csv >unselected-"$thislevel".csv
    msg "Selected $nselected at $thislevel"

    ## Label from the selection: masks weighted by similarity, normalized by the sum of weights
    : >weights-"$thislevel".csv
    weighted=()
    while IFS=, read -r s nmi ; do
        weight=$(awk -v m="$maxweight" -v n="$nmi" 'BEGIN { printf "%.10f", (n-1)/(m-1) }')
        echo "$s,$weight" >>weights-"$thislevel".csv
        weighted+=(masktr-"$thislevel"-s"$s".nii.gz "$weight")
    done < <(head -n "$nselected" simm-"$thislevel".csv)
    "$PINCRAM_IMAGE" weighted-sum distmap-"$thislevel".nii.gz -normalize "${weighted[@]}"
    "$PINCRAM_IMAGE" binarize tmask-"$thislevel"-sel.nii.gz distmap-"$thislevel".nii.gz
    assess tmask-"$thislevel"-sel.nii.gz | tee -a assess.log
    rm -f masktr-"$thislevel"-s*.nii.gz                # masktr: no longer needed
    rm -f reg-s*-"$prevlevel".dof.gz                 # previous level's transformations: only needed as initialization
    prevlevel=$thislevel

    ## Margin mask for the next level
    (( level == maxlevel )) && continue
    margindm=distmap-$thislevel.nii.gz
    (( level == 0 )) && [[ -n $inmask ]] && margindm=input-dm.nii.gz
    "$PINCRAM_IMAGE" band dmargin-"$thislevel".nii.gz "$margindm" "$(reg_margin_mm "$level")"
    tmg=$PWD/dmargin-$thislevel.nii.gz
done

### Success index (SI)

echo -n "SI:" ; labelstats tmask-"$thislevel".nii.gz tmask-"$thislevel"-sel.nii.gz | tee "$result"/si.csv

### Alternative (ICV) mask from the final selection: vote of the transformed alternative masks

alts=()
while read -r s ; do
    [[ -s alttr-s$s.nii.gz ]] && alts+=(alttr-s"$s".nii.gz)
done <selection-"$thislevel".csv
(( ${#alts[@]} > 0 )) || fatal "No transformed alternative masks found"
"$PINCRAM_IMAGE" icv-vote altmsk-bin.nii.gz "${alts[@]}"
rm -f alttr-s*.nii.gz                                # alttr: no longer needed
[[ $savewd -eq 1 ]] || rm -f reg-s*-"$thislevel".dof.gz

### Combine mask types to create wide (ICV) and narrow (parenchymal) masks
# With -refine-band, both the prime label and the parenchyma mask keep the input mask outside
# the band around its boundary; the ICV mask, their union with the alternative vote, contains both.

prime=tmask-$thislevel-sel.nii.gz
"$PINCRAM_IMAGE" and andmask.nii.gz altmsk-bin.nii.gz "$prime"
if [[ -n $refineband ]] ; then
    "$PINCRAM_IMAGE" refine-band tmask-"$thislevel"-refined.nii.gz "$prime" input-dm.nii.gz "$refineband"
    "$PINCRAM_IMAGE" refine-band andmask.nii.gz andmask.nii.gz input-dm.nii.gz "$refineband"
    prime=tmask-$thislevel-refined.nii.gz
fi
"$PINCRAM_IMAGE" or ormask.nii.gz altmsk-bin.nii.gz "$prime"
mirtk convert-image andmask.nii.gz parenchyma1.nii.gz -uchar >>noisy.log 2>&1
mirtk convert-image ormask.nii.gz icv1.nii.gz -uchar >>noisy.log 2>&1

### Compare output mask with reference

assess parenchyma1.nii.gz | tee -a assess.log

### Apply original origin settings and copy output

# shellcheck disable=SC2086  # three coordinates
mirtk edit-image parenchyma1.nii.gz parenchyma.nii.gz -origin $originalorigin
# shellcheck disable=SC2086
mirtk edit-image icv1.nii.gz icv.nii.gz -origin $originalorigin
# shellcheck disable=SC2086
[[ $savedm -eq 1 ]] && mirtk edit-image distmap-"$thislevel".nii.gz "$result"/prime-distmap.nii.gz -origin $originalorigin
cp parenchyma.nii.gz icv.nii.gz "$result"/
[[ -s assess.log ]] && cp assess.log "$result"/

msg "$(date)"
msg "End processing"
exit 0
