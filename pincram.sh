#!/bin/bash

cdir=$(dirname "$0")
. $cdir/common
cdir=$(normalpath "$cdir")

pn=$(basename $0)

commandline="$pn $*"

# Parameter handling
usage () { 
cat <<EOF
pincram version 0.2 

Copyright (C) 2012-2015 Rolf A. Heckemann 
Web site: http://www.soundray.org/pincram 

Usage: $0 <input> <options> <-result result.nii.gz> -altresult altresult.nii.gz \\ 
                       [-probresult probresult.nii.gz] \\ 
                       [-workdir working_directory] [-savewd] \\ 
                       [-atlas atlas_directory | -atlas file.csv] [-atlasn N ] \\ 
                       [-levels {1..3}] [-par max_parallel_jobs] [-ref ref.nii.gz] 

<input>     : T1-weighted magnetic resonance image in gzipped NIfTI format.

-result     : Name of file to receive output brain label. The output is a binary label image.

-altresult  : Name of file to receive alternative output label.  The output is a binary label image.

-probresult : (Optional) name of file to receive output, a probabilistic label image.

-workdir    : Working directory. Default is present working directory. Should be a network-accessible location

-savewd     : (Optional) By default, the temporary directory under the working directory
              will be deleted after processing. Set this flag to keep intermediate files.

-atlas      : Atlas directory.
              Has to contain limages/full/m{1..n}.nii.gz, lmasks/full/m{1..n}.nii.gz and posnorm/m{1..n}.dof.gz 
              Alternatively, it can point to a csv spreadsheet: first row should be base directory for atlas 
              files. Entries should be relative to base directory. Each row refers to one atlas.  
              Column 1: atlasname, column 2: full image, column 3: margin image, column 4: mask, column 5: transformation 
              (.dof format) for positional normalization. Atlasname should be unique across entries. 

-tpn        : Rigid transformation for positional normalization of the target image (optional)

-atlasn     : Use a maximum of N atlases.  By default, all available are used.

-levels     : Integer, minimum 1, maximum 3. Indicates level of refinement required.

-ref        : Reference label against which to log Jaccard overlap results.

-par        : Number of jobs to run in parallel (shell level).  Please use with consideration.
EOF
fatal "Parameter error"
}

[ $# -lt 3 ] && usage

tgt=$(normalpath "$1") ; shift
test -e $tgt || fatal "No image found -- $t"

tpn="$cdir"/neutral.dof.gz
result=
altresult=
probresult=
par=1
ref=none
exclude=0
atlas=$(normalpath "$cdir"/atlas)
atlasn=0
workdir=$PWD
while [ $# -gt 0 ]
do
    case "$1" in
	-tpn)               tpn=$(normalpath "$2"); shift;;
	-result)         result=$(normalpath "$2"); shift;;
	-altresult)   altresult=$(normalpath "$2"); shift;;
	-probresult) probresult=$(normalpath "$2"); shift;;
	-atlas)           atlas=$(normalpath "$2"); shift;;
	-workdir)       workdir=$(normalpath "$2"); shift;;
	-ref)               ref=$(normalpath "$2"); shift;;
	-savewd)         savewd=1 ;;
	-atlasn)         atlasn="$2"; shift;;
	-levels)         levels="$2"; shift;;
	-par)               par="$2"; shift;;
	--) shift; break;;
        -*)
            usage;;
	*)  break;;
    esac
    shift
done

[ -e "$tpn" ] || fatal "Target positional normalization does not exist"

[ -n "$result" ] || fatal "Result filename not set"

[ -e "$atlas" ] || fatal "Atlas directory or file does not exist"

## Set levels to three unless set to 1 or 2 via -levels option
[[ "$levels" =~ ^[1-2]$ ]] || levels=3
maxlevel=$[$levels-1]

[[ "$par" =~ ^[0-9]+$ ]] || par=1

. "$cdir"/pincram.rc

echo "Extracting $tgt"
echo "Writing brain label to $result"

# Functions

assess() {
    local glabels="$1"
    if [ -e ref.nii.gz ] ; then 
	transformation "$glabels" assess.nii.gz -target ref.nii.gz >>noisy.log 2>&1
	echo -e "${glabels}:\t\t"$(labelStats ref.nii.gz assess.nii.gz -false)
    fi
    return 0
}

# Core working directory
mkdir -p "$workdir"
td=$(mktemp -d "$workdir/$(basename $0)-c$exclude.XXXXXX") || fatal "Could not create working directory in $workdir"
export PINCRAM_WORKDIR=$td
trap 'if [[ $savewd != 1 ]] ; then rm -rf "$td" ; fi' 0 1 15 
cd "$td" || fatal "Error: cannot cd to temp directory $td"

if [[ -d "$atlas" ]] ; then
    if [[ -e "$atlas"/atlases.csv ]] ; then 
	atlas="$atlas"/atlases.csv
    else
	"$cdir"/atlas-csv-gen.sh "$atlas" atlases.csv
	atlas=$PWD/atlases.csv
    fi
fi
atlasbase=$(head -n 1 $atlas)
atlasmax=$[$(cat $atlas | wc -l)-1]
[[ "$atlasn" =~ ^[0-9]+$ ]] || atlasn=$atlasmax
[[ "$atlasn" -gt $atlasmax || "$atlasn" -eq 0 ]] && atlasn=$atlasmax

echo "$commandline" >commandline.log

# Target preparation
originalorigin=$(info "$tgt" | grep ^Image.origin | cut -d ' ' -f 4-6)
headertool "$tgt" target-full.nii.gz -origin 0 0 0
convert "$tgt" target-full.nii.gz -float
[ -e "$ref" ] && cp "$ref" ref.nii.gz && chmod +w ref.nii.gz

# Arrays
levelname[0]="rigid"
levelname[1]="affine"
levelname[2]="nonrigid"
levelname[3]="none"

dmaskdil[0]=3
dmaskdil[1]=3

# Initialize first loop
tgt="$PWD"/target-full.nii.gz
level=0
prevlevel=init
seq 1 $atlasn >selection-$prevlevel.csv
nselected=$(cat selection-$prevlevel.csv | wc -l)
usepercent=$(echo $nselected | awk '{ printf "%.0f", 100*(8/$1)^(1/3) } ')

# Prep datasets line by line in job.conf
for level in $(seq 0 $maxlevel) ; do
    thislevel=${levelname[$level]}
    thisthr=${thr[$level]}
    echo "Level $thislevel"
    [[ -e $td/job.conf ]] && rm $td/job.conf
    for srcindex in $(cat selection-$prevlevel.csv) ; do
    
	set -- $(head -n $[$srcindex+1] $atlas | tail -n 1 | tr ',' ' ')
	atlasname=$1 ; shift
	src=$atlasbase/$1 ; shift
	mrg=$atlasbase/$1 ; shift
	spn=$atlasbase/$1 ; shift
	msk=$atlasbase/$1 ; shift
	alt=$atlasbase/$1 ; shift

	if [[ $level -ge 2 ]] ; then src=$mrg ; fi
	srctr="$PWD"/srctr-$thislevel-s$srcindex.nii.gz
	masktr="$PWD"/masktr-$thislevel-s$srcindex.nii.gz
	dofin="$PWD"/reg-s$srcindex-$prevlevel.dof.gz 
	dofout="$PWD"/reg-s$srcindex-$thislevel.dof.gz
	alttr="$PWD"/alttr-$thislevel-s$srcindex.nii.gz

	echo "-tgt $tgt" "-src $src" "-srctr $srctr" "-msk $msk" "-masktr $masktr" "-alt $alt" "-alttr $alttr" "-dofin $dofin" "-dofout $dofout" "-spn $spn" "-tpn $tpn" "-lev $level" >>$td/job.conf
    done

    cp job.conf job-$thislevel.conf
    "$cdir"/distrib -script "$cdir"/reg$level.sh -datalist $td/job.conf -arch $ARCH -level $level

    loopcount=0
    masksready=0
    minready=$[$nselected*90/100] # Speedup at the cost of reproducibility. Comment out next line.
    # minready=$nselected
    echo -en "$masksready of $nselected calculated     "
    sleeptime=$[$level*5+5]
    sleep $sleeptime
    until [[ $masksready -ge $minready ]]
    do 
	(( loopcount += 1 ))
	[[ loopcount -gt 500 ]] && fatal "Waited too long for registration results"
	prevmasksread=$masksready
	masksready=$( ls masktr-$thislevel-s* 2>/dev/null | wc -l )
	[[ $masksready -eq 1 ]] && masksready=0
	echo -en \\b"$masksready of $nselected calculated     " | tee -a noisy.log
	sleep $sleeptime
    done
    echo
    [[ $masksready -lt $nselected ]] && sleep 30  # Extra sleep if we're going on an incomplete mask set

# Generate reference for atlas selection (fused from all)
    echo "Building reference atlas for selection at level $thislevel"
    for i in masktr-$thislevel-s* ; do 
	[[ -s $i ]] || mv $i failed-$i
    done
    set -- masktr-$thislevel-s*
    thissize=$#
    [[ $thissize -lt 7 ]] && fatal "Mask generation failed at level $thislevel" 
    set -- $(echo $@ | sed 's/ / -add /g')
    seg_maths $@ -div $thissize tmask-$thislevel-atlas.nii.gz
# Generate target margin mask for similarity ranking and apply 
    seg_maths tmask-$thislevel-atlas.nii.gz -thr 0.$thisthr -bin tmask-$thislevel.nii.gz 
    dilation tmask-$thislevel.nii.gz tmask-$thislevel-wide.nii.gz -iterations 1 >>noisy.log 2>&1
    erosion tmask-$thislevel.nii.gz tmask-$thislevel-narrow.nii.gz -iterations 1 >>noisy.log 2>&1
    subtract tmask-$thislevel-wide.nii.gz tmask-$thislevel-narrow.nii.gz emargin-$thislevel.nii.gz >>noisy.log 2>&1
    dilation emargin-$thislevel.nii.gz emargin-$thislevel-dil.nii.gz -iterations 3 >>noisy.log 2>&1
    padding target-full.nii.gz emargin-$thislevel-dil.nii.gz emasked-$thislevel.nii.gz 0 0
    assess tmask-$thislevel.nii.gz
# Selection
    echo "Selecting"
    for srcindex in $(cat selection-$prevlevel.csv) ; do
	srctr="$PWD"/srctr-$thislevel-s$srcindex.nii.gz
	if [[ -e $srctr ]] && [[ ! -z $srctr ]] ; then
	    echo $(evaluation emasked-$thislevel.nii.gz $srctr -Tp 0 -mask emargin-$thislevel-dil.nii.gz | grep NMI | cut -d ' ' -f 2 )",$srcindex"
	fi
    done | sort -rn | tee simm-$thislevel.csv | cut -d , -f 2 > ranking-$thislevel.csv
    nselected=$[$thissize*$usepercent/100]
    [ $nselected -lt 9 ] && nselected=7
    split -l $nselected ranking-$thislevel.csv
    mv xaa selection-$thislevel.csv
    [ -e xab ] && cat x?? > unselected-$thislevel.csv 
    echo "Selected $nselected at $thislevel"
# Build label from selection 
    set -- $(cat selection-$thislevel.csv | while read -r item ; do echo masktr-$thislevel-s$item.nii.gz ; done)
     #TODO: check for missing masktr-*
    thissize=$#
    [[ $thissize -lt 7 ]] && fatal "Mask generation failed at level $thislevel" 
    set -- $(echo $@ | sed 's/ / -add /g')
    seg_maths $@ -div $thissize tmask-$thislevel-sel-atlas.nii.gz 
    seg_maths tmask-$thislevel-sel-atlas.nii.gz -thr 0.$thisthr -bin tmask-$thislevel-sel.nii.gz 
    assess tmask-$thislevel-sel.nii.gz
    prevlevel=$thislevel
# Data mask (skip on last iteration)
    [ $level -eq $maxlevel ] && continue
    seg_maths tmask-$thislevel-sel-atlas.nii.gz -thr 0.15 -bin tmask-$thislevel-wide.nii.gz
    seg_maths tmask-$thislevel-sel-atlas.nii.gz -thr 0.99 -bin tmask-$thislevel-narrow.nii.gz
    subtract tmask-$thislevel-wide.nii.gz tmask-$thislevel-narrow.nii.gz dmargin-$thislevel.nii.gz -no_norm >>noisy.log 2>&1
    dilation dmargin-$thislevel.nii.gz dmargin-$thislevel-dil.nii.gz -iterations ${dmaskdil[$level]} >>noisy.log 2>&1
    padding target-full.nii.gz dmargin-$thislevel-dil.nii.gz dmasked-$thislevel.nii.gz 0 0
    tgt="$PWD"/dmasked-$thislevel.nii.gz
done

echo -n "SI:" ; labelStats tmask-$thislevel.nii.gz tmask-$thislevel-sel.nii.gz -false

set -- $(cat selection-$thislevel.csv | while read -r item ; do echo alttr-$thislevel-s$item.nii.gz ; done) 
#TODO: check for missing alttr-*
set -- $(echo $@ | sed 's/ / -add /g')
seg_maths $@ -div $thissize alt-$thislevel-sel-atlas.nii.gz
seg_maths alt-$thislevel-sel-atlas.nii.gz -thr 0.$thisthr -bin alt-$thislevel-sel.nii.gz 
seg_maths alt-$thislevel-sel.nii.gz -mul tmask-$thislevel-sel.nii.gz andmask.nii.gz
seg_maths alt-$thislevel-sel.nii.gz -add tmask-$thislevel-sel.nii.gz -bin ormask.nii.gz

convert andmask.nii.gz output.nii.gz -uchar >>noisy.log 2>&1
convert ormask.nii.gz altoutput.nii.gz -uchar >>noisy.log 2>&1
headertool output.nii.gz "$result" -origin $originalorigin
headertool altoutput.nii.gz "$altresult" -origin $originalorigin

if [ -n "$probresult" ] ; then
    headertool tmask-$thislevel-sel-atlas.nii.gz "$probresult" -origin $originalorigin
fi

exit 0
