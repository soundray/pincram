#!/bin/bash

set -e

### Usage & parameter handling

usage () {
    cat <<EOF

Copyright (C) 2012-2018 Rolf A. Heckemann
Web site: http://www.soundray.org/pincram

Usage: $0 <input> <options> <-result result-dir/> \\
                       [-workdir working_directory/] [-savewd] [-savedm] [-pickup previous_dir/] \\
                       [-atlas atlas_directory/ | -atlas file.csv] [-atlasn N ] [-levels {1..3}] \\
                       [-par max_parallel_jobs] [-ref ref.nii.gz]

<input>     : T1-weighted magnetic resonance image in gzipped NIfTI format.

-result     : Name of directory to receive output files. Will be created if it does not exist. Contents
              will be overwritten if they exist.

-workdir    : Base working directory. Default is present working directory. When running under PBS, this
              location needs to be accessible from the cluster nodes. On each run, a uniquely named directory
              for intermediate results is generated.

-pickup     : Intermediate results directory from a previous run -- work will be continued. Overrides
              -workdir setting if given. Implies -savewd. Previous run must be compatible (same -atlas,
              same <input>, etc.), else results are unpredictable.

-savewd     : By default, the temporary directory under the working directory will be deleted
              after processing. Set this flag to save intermediate files in the -result location.

-savedm     : By default, the final distance map is discarded. Set this flag to save it to the result
              directory instead

-atlas      : Atlas directory.
              Has to contain images/m{1..n}.nii.gz, brainmasks/m{1..n}.nii.gz, affinenorm/m{1..n}.dof.gz,
              and refspace/img.nii.gz (unless -tpn given).
              Alternatively, -atlas can point to a csv spreadsheet: first row should be base directory for
              atlas files. Entries should be relative to base directory. Each row refers to one atlas.
              Column 1: atlasname, Column 2: full image, Column 3: margin mask, Column 4: transformation
              (.dof format) for positional normalization, Column 5: prime mask, Column 6: alternative mask.
              Atlasname should be unique across entries. Note: mask voxels should range from -1 (background)
              to 1 (foreground); discrete or probabilistic maps are both allowed. Prime masks are typically
              parenchyma masks and alternative masks are intracranial volume masks, but this can be swapped.
              The output distance map is calculated on the prime (Column 5) input.

-tpn        : Transformation for positional normalization or normalization to a reference space

-atlasn     : Use a maximum of N atlases.  By default, all available are used.

-levels     : Integer, minimum 1, maximum 3. Indicates level of refinement required.

-ref        : Reference label against which to log Jaccard overlap results.

-par        : Number of jobs to run in parallel (shell level).  Please use with consideration.

EOF
}

ppath=$(realpath "$BASH_SOURCE")
cdir=$(dirname "$ppath")
pn=$(basename "$ppath")

. "$cdir"/functions

commandline="$pn $*"

: ${PINCRAM_ARCH:="bash"}
: ${PINCRAM_USE_LIB:="mirtk"}
: ${PINCRAM_PROCEED_PCT:=100}

case $PINCRAM_USE_LIB in
    irtk)
        type areg2 || fatal "Missing binary: areg2 (IRTK) not on path" ;;
    mirtk)
        type mirtk || fatal "Missing binary: mirtk not on path" ;;
    greedy)
        type greedy || fatal "Missing binary: greedy not on path" ;;
esac

export PINCRAM_ARCH PINCRAM_USE_LIB
msg "Architecture $PINCRAM_ARCH"
msg "Library $PINCRAM_USE_LIB"

type seg_maths || fatal "Missing binary: seg_maths (NiftySeg) not on path"

[[ $# -lt 3 ]] && fatal "Too few parameters"

tgt=$(realpath "$1") ; shift
test -e $tgt || fatal "No image found -- $t"

tpn=
result=
par=1
ref=none
atlas=$(realpath "$cdir"/atlas)
atlasn=0
workdir=$PWD
pickup=
while [[ $# -gt 0 ]]
do
    case "$1" in
        -tpn)               tpn=$(realpath "$2"); shift;;
        -result)         result=$(realpath "$2"); shift;;
        -atlas)           atlas=$(realpath "$2"); shift;;
        -workdir)       workdir=$(realpath "$2"); shift;;
        -pickup)         pickup=$(realpath "$2"); shift;;
        -ref)               ref=$(realpath "$2"); shift;;
        -savewd)         savewd=1 ;;
        -savedm)         savedm=1 ;;
        -atlasn)         atlasn="$2"; shift;;
        -levels)         levels="$2"; shift;;
        -par)               par="$2"; shift;;
        --) shift; break;;
        -*)
            fatal "Unknown parameter" ;;
        *)  break;;
    esac
    shift
done

[[ -n "$result" ]] || fatal "Result directory name not set (e.g. -result pincram-masks)"
mkdir -p "$result"
[[ -d "$result" ]] || fatal "Failed to create directory for result output ($result)"

[[ -e "$atlas" ]] || fatal "Atlas directory or file does not exist"

## Set levels to three unless set to 1 or 2 via -levels option
[[ "$levels" =~ ^[1-2]$ ]] || levels=3
maxlevel=$[$levels-1]

[[ "$par" =~ ^[0-9]+$ ]] || par=1

msg "$(date)"
msg "Extracting $tgt"
msg "Writing brain label to $result"

if [[ -n $PINCRAM_PROCEED_PCT ]]
then
    minpct=$PINCRAM_PROCEED_PCT
else
    minpct=100
fi

### Functions

finish () {
    if [[ $savewd -eq 1 ]] ; then
        chmod -R u+rwX $td
        mv "$td" "$result"
    else
        rm -rf "$td"
    fi
    exit
}

labelstats() {
    local i1=$1 ; shift
    local i2=$1 ; shift
    mirtk evaluate-label-overlap $i1 $i2 -precision 6 -table -noid | tail -n 1
}

assess() {
    local glabels="$1"
    if [[ -e ref.nii.gz ]] ; then
        mirtk edit-image "$glabels" assess.nii.gz -copy-size ref.nii.gz >>noisy.log 2>&1
        echo -e "${glabels}:\t\t"$(labelstats ref.nii.gz assess.nii.gz -false)
    fi
    return 0
}

origin() {
    img="$1" ; shift
    mirtk info $img | grep -v File.name | grep -i origin | tr -d ',' | tr -s ' ' | cut -d ' ' -f 4-6
}

nmi() {
    local img=$1
    mirtk evaluate-similarity \
          target-full.nii.gz $img \
          -mask emargin-$thislevel-dil.nii.gz \
          -metric NMI \
          -precision 7 \
          -table \
          -threads 1 \
          -noid | tail -n 1
}

odistmap() {
    local img=$1 ; shift
    local out=$1
    seg_maths $img -smo 6 -otsu im-otsu.nii.gz
    mirtk calculate-distance-map im-otsu.nii.gz odm.nii.gz -threads $par
    mirtk calculate-element-wise odm.nii.gz -mul -1 -threads $par -o $out
}

eucmap() {
    local mask=$1 ; shift
    local map=$1
    mirtk calculate-distance-map $mask dm.nii.gz -threads $par
    mirtk calculate-element-wise dm.nii.gz -mul -1 -threads $par -o $map
}

### Core working directory

if [[ -n "$pickup" ]]
then
    [[ -d $pickup ]] || fatal "Pickup directory $pickup does not exist"
    td=$pickup
    savewd=1
    cd "$td" || fatal "Error: cannot cd to temp directory $td"
    ## Unpack old results if existing
    touch 0.tar
    set -- *.tar
    shift
    while [[ $# -gt 0 ]]
    do
        tar -xf $1 ; rm $1 ; shift
    done
    touch 0.log ; rm *.log
    touch weights0.csv ; rm weights*.csv
else
    if [[ $PINCRAM_ARCH == "pbs" ]] ; then
        mkdir -p "$workdir"
        td=$(mktemp -d "$workdir/$(basename $0).XXXXXX") || fatal "Could not create working directory in $workdir"
    else
        : ${TMPDIR:=/tmp/$USER}
        mkdir -p $TMPDIR
        td=$(mktemp -d $TMPDIR/$(basename $0).XXXXXX) || fatal "Could not create working directory in $TMPDIR"
    fi
fi
export PINCRAM_WORKDIR=$td
trap finish EXIT
cd "$td" || fatal "Error: cannot cd to temp directory $td"
msg "Working in directory $td"


### Atlas database read and check

if [[ -d "$atlas" ]] ; then
    if [[ -e "$atlas"/etc/atlases.csv ]] ; then
        atlas="$atlas"/etc/atlases.csv
    else
        "$cdir"/atlas-csv-gen.sh "$atlas" atlases.csv
        atlas=$PWD/atlases.csv
    fi
fi

atlasbase=$(head -n 1 $atlas)
set -- $(head -n 2 $atlas | tail -n 1 | tr ',' ' ')
shift
while [[ $# -gt 0 ]] ; do
    [[ -e $atlasbase/$1 ]] || fatal "Atlas error ($atlasbase/$1 does not exist)"
    shift
done

if [[ -z $tpn ]] ; then
    refspace=$atlasbase/base/refspace/img.nii.gz
    [[ -e $refspace ]] || fatal "No reference space declared ($refspace) and -tpn not provided"
fi

atlasmax=$[$(cat $atlas | wc -l)-1]
[[ "$atlasn" =~ ^[0-9]+$ ]] || atlasn=$atlasmax
[[ "$atlasn" -gt $atlasmax || "$atlasn" -eq 0 ]] && atlasn=$atlasmax

msg "$commandline"
echo "$commandline" >commandline.log


### Target preparation

originalorigin=$(origin "$tgt")
if [[ -z $pickup ]]
then
    mirtk edit-image "$tgt" target-full.nii.gz -origin 0 0 0
    mirtk convert-image target-full.nii.gz target-full.nii.gz -float
    [[ -e "$ref" ]] && mirtk edit-image "$ref" ref.nii.gz -origin 0 0 0 && chmod +w ref.nii.gz
    if [[ -n $refspace ]] ; then
        msg "Calculating affine normalization to reference space with distance maps"
        odistmap $refspace refspace-dm.nii.gz
        odistmap target-full.nii.gz target-dm.nii.gz
        mirtk register refspace-dm.nii.gz target-dm.nii.gz \
              -model Affine \
              -sim SSD \
              -dofout pre-dof.gz \
              -level 4 \
              -threads $par >noisy.log 2>&1
        mirtk register $refspace target-full.nii.gz \
              -model Affine \
              -dofin pre-dof.gz \
              -dofout tpn.dof.gz \
              -levels 3 1 \
              -threads $par >noisy.log 2>&1
        tpn=$td/tpn.dof.gz
    fi
fi

### Array

levelname[0]="coarse"
levelname[1]="affine"
levelname[2]="nonrigid"
levelname[3]="none"


### Initialize first loop

tgt="$PWD"/target-full.nii.gz
tdm="dummy"
tmg=$tgt
level=0
prevlevel=init
seq 1 $atlasn >selection-$prevlevel.csv
nselected=$(cat selection-$prevlevel.csv | wc -l)
usepercent=$(echo $nselected | awk '{ printf "%.0f", 100*(8/$1)^(1/3) } ')
# usepercent=75

### Iterate over levels

for level in $(seq 0 $maxlevel) ; do
    thislevel=${levelname[$level]}
    msg "Level $thislevel"
    cat /dev/null >job.conf

    ## Prep datasets line by line in job.conf
    for srcindex in $(cat selection-$prevlevel.csv) ; do

        # Read in atlas
        atlasname= ; src= ; mrgorspn= ; mrg= ; spn= ; msk= ; alt= ; mrggen=
        set -- $(head -n $[$srcindex+1] $atlas | tail -n 1 | tr ',' ' ')
        atlasname=$1 ; shift
        src=$atlasbase/$1 ; shift
        spn=$atlasbase/$1 ; shift
        msk=$atlasbase/$1 ; shift
        alt=$atlasbase/$1 ; shift
        if [[ $level -ge 2 ]] ; then
            mrggen=$td/mrggen-s$srcindex.nii.gz
            if [[ ! -e $mrggen ]] ; then
                mrg=$td/mrg-s$srcindex.nii.gz
                seg_maths $msk -abs -uthr 7 -bin -mul $src $mrggen
                src=$mrggen
            fi
        fi
        srctr="$PWD"/srctr-$thislevel-s$srcindex.nii.gz
        masktr="$PWD"/masktr-$thislevel-s$srcindex.nii.gz
        dofin="$PWD"/reg-s$srcindex-$prevlevel.dof.gz
        dofout="$PWD"/reg-s$srcindex-$thislevel.dof.gz
        alttr="$PWD"/alttr-$thislevel-s$srcindex.nii.gz

        if [[ ! -s $masktr ]]
        then
            echo "-tgt $tgt" "-tdm $tdm" "-src $src" "-srctr $srctr" "-msk $msk" "-masktr $masktr" "-alt $alt" "-alttr $alttr" "-dofin $dofin" "-dofout $dofout" "-spn $spn" "-tpn $tpn" "-lev $level" "-tmargin $tmg" "-par $par" >>$td/job.conf
        fi
    done


    ## Launch parallel registrations
    cp job.conf job-$thislevel.conf
    if [[ -s job.conf ]]
    then
        msg "Launching registrations"
        csec=$("$cdir"/distrib -script "$cdir"/reg.sh -datalist $td/job.conf -level $level -jobs $par)
        etasec=$(( $(date +%s) + $csec ))
        eta=$(date -d "@$etasec")
        [[ $PINCRAM_ARCH == "pbs" ]] && msg "First job status check at $eta"
    fi


    ## Monitor incoming results and wait
    loopcount=0
    masksready=0
    minready=$[$nselected*$minpct/100]
    echo -n $($cdir/spark 0 $masksready $nselected | cut -c 2)
    sleeptime=$[$level*5+5]
    until [[ $masksready -ge $minready ]]
    do
        (( loopcount += 1 ))
        [[ loopcount -gt 500 ]] && fatal "Waited too long for registration results"
        prevmasksready=$masksready
        masksready=$( ls masktr-$thislevel-s* 2>/dev/null | wc -l )
        [[ $masksready -gt $prevmasksready ]] && loopcount=0
        [[ $masksready -eq 1 ]] && masksready=0
        echo -n $($cdir/spark 0 $masksready $nselected | cut -c 2)
        if [[ $(date +%s ) -gt $etasec ]]
        then
            echo
            fatal "Masks not ready by deadline. Relaunching registrations" # TODO: change back to "msg"
            csec=$("$cdir"/distrib -script "$cdir"/reg.sh -datalist $td/job.conf -level $level -jobs $par)
            etasec=$(( $(date +%s) + $csec ))
            eta=$(date -d "@$etasec")
            [[ $PINCRAM_ARCH == "pbs" ]] && msg "Next job status check at $eta"
        fi
        sleep $sleeptime
    done
    echo
    msg "Minimum number of mask transformations calculated"
    [[ $masksready -lt $nselected ]] && sleep 30  # Extra sleep if we're going on an incomplete mask set

    ## Generate reference for atlas selection (fused from all)
    set -- masktr-$thislevel-s*
    thissize=$#
    msg "Individual mask transformations: selected $nselected, minimum $minready, completed $thissize"
    msg "Building reference atlas for selection at level $thislevel"
    tar -cf masktr-$thislevel-n$thissize.tar $@
    [[ $thissize -lt 7 ]] && fatal "Mask generation failed at level $thislevel"
    set -- $(echo $@ | sed 's/ / -add /g')
    seg_maths $@ -div $thissize tmask-$thislevel-sum.nii.gz
    tdm=$PWD/tmask-$thislevel-sum.nii.gz

    ## Generate intermediate target mask
    seg_maths tmask-$thislevel-sum.nii.gz -thr 0 -bin tmask-$thislevel.nii.gz
    assess tmask-$thislevel.nii.gz | tee -a assess.log


    ## Generate target margin mask for similarity ranking and apply
    thresh1=$( echo "( $level - 5 )^2 / 3" | bc -l )
    seg_maths tmask-$thislevel-sum.nii.gz -abs -uthr $thresh1 -bin emargin-$thislevel-dil.nii.gz


    ## Selection
    msg "Selecting"
    set -- $(cat selection-$prevlevel.csv)
    set -- $(for i ; do ls srctr-$thislevel-s$i.nii.gz ; done)
    mirtk evaluate-similarity target-full.nii.gz $@ \
          -mask emargin-$thislevel-dil.nii.gz \
          -metric NMI -precision 7 -threads $par \
          -table -header off |\
        rev | cut -d s -f 1 | rev | sort -rn -t , -k 2 | tee simm-$thislevel.csv |\
        cut -d , -f 1 >ranking-$thislevel.csv

    tar -cf srctr-$thislevel.tar srctr-$thislevel-s*.nii.gz ; rm srctr-$thislevel-s*.nii.gz
    tar -cf alttr-$thislevel.tar alttr-$thislevel-s*.nii.gz
    maxweight=$(head -n 1 simm-$thislevel.csv | cut -d , -f 2)
    nselected=$[$thissize*$usepercent/100]
    [[ $nselected -lt 9 ]] && nselected=7
    split -l $nselected ranking-$thislevel.csv
    mv xaa selection-$thislevel.csv
    [[ -e xab ]] && cat x?? > unselected-$thislevel.csv
    msg "Selected $nselected at $thislevel"


    ## Build label from selection
    head -n $nselected simm-$thislevel.csv | tr , ' ' | while read s nmi
    do
        weight=$(echo '1 / ( '$maxweight' - 1 ) * ( '$nmi' - 1 )' | bc -l )
        echo $s,$weight >>weights-$thislevel.csv
        seg_maths masktr-$thislevel-s$s.nii.gz -mul $weight masktr-$thislevel-weighted-s$s.nii.gz
    done
    set -- masktr-$thislevel-weighted-s*.nii.gz
    set -- $(echo $@ | sed 's/ / -add /g')
    seg_maths $@ tmask-$thislevel-sel-sum.nii.gz
    seg_maths tmask-$thislevel-sel-sum.nii.gz -thr 0 -bin tmask-$thislevel-sel.nii.gz
    assess tmask-$thislevel-sel.nii.gz | tee -a assess.log
    prevlevel=$thislevel


    ## Target data mask (skip on last iteration)
    set -- $( head -n $nselected weights-$thislevel.csv | cut -d , -f 2 )
    scalefactor=$( echo $@ | sed 's/ / + /g' | bc -l )
    seg_maths tmask-$thislevel-sel-sum.nii.gz -div $scalefactor distmap-$thislevel.nii.gz
    [[ $level -eq $maxlevel ]] && continue
    thresh2=$( echo "( $level - 6 )^2 / 5" | bc -l )
    seg_maths distmap-$thislevel.nii.gz -abs -uthr $thresh2 -bin dmargin-$thislevel.nii.gz
    tmg="$PWD"/dmargin-$thislevel.nii.gz
done


### Calculate success index (SI)

echo -n "SI:" ; labelstats tmask-$thislevel.nii.gz tmask-$thislevel-sel.nii.gz -false | tee "$result"/si.csv


### Generate alt (ICV) masks

altc=0
addswitch=
cat selection-$thislevel.csv | while read -r item
do
    alts=alttr-$thislevel-s$item.nii.gz
    if [[ -s $alts ]]
    then
        (( altc += 1 ))
        seg_maths $alts -add 1 -mul 2 -sub 3 $addswitch altmsk-sum.nii.gz
        addswitch="-add altmsk-sum.nii.gz"
    fi
done
rm alttr-*.nii.gz


### Combine mask types to create wide (ICV) and narrow (parenchymal) masks

seg_maths altmsk-sum.nii.gz -div $altc -thr 0 -bin altmsk-bin.nii.gz
seg_maths altmsk-bin.nii.gz -mul tmask-$thislevel-sel.nii.gz andmask.nii.gz
seg_maths altmsk-bin.nii.gz -add tmask-$thislevel-sel.nii.gz -bin ormask.nii.gz
mirtk convert-image andmask.nii.gz parenchyma1.nii.gz -uchar >>noisy.log 2>&1
mirtk convert-image ormask.nii.gz icv1.nii.gz -uchar >>noisy.log 2>&1


### Compare output mask with reference

assess parenchyma1.nii.gz | tee -a assess.log


### Package and delete transformations

# tar -cf reg-dofs.tar reg*.dof* ; rm reg*.dof*


### Apply original origin settings and copy output

mirtk edit-image parenchyma1.nii.gz parenchyma.nii.gz -origin $originalorigin
mirtk edit-image icv1.nii.gz icv.nii.gz -origin $originalorigin
[[ $savedm == 1 ]] && mirtk edit-image distmap-$thislevel.nii.gz "$result"/prime-distmap.nii.gz -origin $originalorigin
cp parenchyma.nii.gz icv.nii.gz "$result"/
[[ -s assess.log ]] && cp assess.log "$result"/

msg "$(date)"
msg "End processing"
exit 0
