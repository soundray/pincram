#!/bin/bash

cdir=$(dirname "$0")
. $cdir/common
. $cdir/functions
cdir=$(normalpath "$cdir")

pn=$(basename $0)

commandline="$pn $*"


### Usage & parameter handling

usage () {
cat <<EOF

Copyright (C) 2012-2018 Rolf A. Heckemann
Web site: http://www.soundray.org/pincram

Usage: $0 <input> <options> <-result result-dir/> \\
                       [-workdir working_directory/] [-savewd] [-pickup previous_dir/]\\
                       [-atlas atlas_directory/ | -atlas file.csv] [-atlasn N ] \\
                       [-levels {1..3}] [-par max_parallel_jobs] [-ref ref.nii.gz]

<input>     : T1-weighted magnetic resonance image in gzipped NIfTI format.

-result     : Name of directory to receive output files. Will be created if it does not exist. Contents
              will be overwritten if they exist.

-workdir    : Base working directory. Default is present working directory. Should be a network-accessible 
              location. On each run, a uniquely named directory for intermediate results is generated.

-pickup     : Intermediate results directory from a previous run -- work will be continued. Overrides 
              -workdir setting if given. Implies -savewd. Previous run must be compatible (same -atlas,
              same <input>, etc.), else results are unpredictable.

-savewd     : (Optional) By default, the temporary directory under the working directory
              will be deleted after processing. Set this flag to keep intermediate files.

-atlas      : Atlas directory.
              Has to contain images/full/m{1..n}.nii.gz, masks/full/m{1..n}.nii.gz, posnorm/m{1..n}.dof.gz,
              and refspace/img.nii.gz (unless -tpn given).
              Alternatively, -atlas can point to a csv spreadsheet: first row should be base directory for
              atlas files. Entries should be relative to base directory. Each row refers to one atlas.
              Column 1: atlasname, Column 2: full image, Column 3: margin mask, Column 4: transformation
              (.dof format) for positional normalization, Column 5: prime mask, Column 6: alternative mask.
              Atlasname should be unique across entries. Note: mask voxels should range from -1 (background)
              to 1 (foreground); discrete or probabilistic maps are both allowed. Prime masks are typically
              parenchyma masks and alternative masks are intracranial volume masks, but this can be swapped.
              The probability output is calculated on the prime (Column 5) input.

-tpn        : Transformation for positional normalization or normalization to a reference space

-atlasn     : Use a maximum of N atlases.  By default, all available are used.

-levels     : Integer, minimum 1, maximum 3. Indicates level of refinement required.

-ref        : Reference label against which to log Jaccard overlap results.

-par        : Number of jobs to run in parallel (shell level).  Please use with consideration.

EOF
}

[ $# -lt 3 ] && fatal "Too few parameters"

tgt=$(normalpath "$1") ; shift
test -e $tgt || fatal "No image found -- $t"

tpn=
result=
par=1
ref=none
atlas=$(normalpath "$cdir"/atlas)
atlasn=0
workdir=$PWD
pickup=
while [ $# -gt 0 ]
do
    case "$1" in
	-tpn)               tpn=$(normalpath "$2"); shift;;
	-result)         result=$(normalpath "$2"); shift;;
	-atlas)           atlas=$(normalpath "$2"); shift;;
	-workdir)       workdir=$(normalpath "$2"); shift;;
	-pickup)         pickup=$(normalpath "$2"); shift;;
	-ref)               ref=$(normalpath "$2"); shift;;
	-savewd)         savewd=1 ;;
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

[ -n "$result" ] || fatal "Result directory name not set (e.g. -result pincram-masks)"
mkdir -p "$result" 
[[ -d "$result" ]] || fatal "Failed to create directory for result output ($result)"

[ -e "$atlas" ] || fatal "Atlas directory or file does not exist"

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

assess() {
    local glabels="$1"
    if [ -e ref.nii.gz ] ; then
	transformation "$glabels" assess.nii.gz -target ref.nii.gz >>noisy.log 2>&1
	echo -e "${glabels}:\t\t"$(labelStats ref.nii.gz assess.nii.gz -false)
    fi
    return 0
}

origin() {
    img="$1" ; shift
    info $img | grep -i origin | tr -d ',' | tr -s ' ' | cut -d ' ' -f 4-6
}

nmi() {
    local img=$1
    evaluation target-full.nii.gz $img -Tp 0 -mask emargin-$thislevel-dil.nii.gz | grep NMI | cut -d ' ' -f 2
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
	tar xf $1 ; rm $1 ; shift
    done
    touch 0.log ; rm *.log
    touch weights0.csv ; rm weights*.csv
else
    mkdir -p "$workdir"
    td=$(mktemp -d "$workdir/$(basename $0).XXXXXX") || fatal "Could not create working directory in $workdir"
fi
export PINCRAM_WORKDIR=$td
trap finish EXIT
cd "$td" || fatal "Error: cannot cd to temp directory $td"
msg "Working in directory $td"


### Atlas database read and check

if [[ -d "$atlas" ]] ; then
    if [[ -e "$atlas"/atlases.csv ]] ; then
	atlas="$atlas"/atlases.csv
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
    refspace=$atlasbase/refspace/img.nii.gz
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
    headertool "$tgt" target-full.nii.gz -origin 0 0 0
    convert target-full.nii.gz target-full.nii.gz -float
    [ -e "$ref" ] && cp "$ref" ref.nii.gz && chmod +w ref.nii.gz
    if [[ -n $refspace ]] ; then
	if which calculate-distance-map >/dev/null 2>&1 ; then
	    msg "Calculating affine normalization to reference space with distance maps"
	    seg_maths $refspace -smo 3 -otsu refspace-otsu.nii.gz
	    calculate-distance-map refspace-otsu.nii.gz refspace-euc.nii.gz 
	    seg_maths target-full.nii.gz -smo 3 -otsu target-otsu.nii.gz
	    calculate-distance-map target-otsu.nii.gz target-euc.nii.gz 
	    echo "Similarity measure = SSD" >areg2.par
	    areg2 refspace-euc.nii.gz target-euc.nii.gz -dofout pre-dof.gz -parin areg2.par >noisy.log 2>&1
	    areg2 $refspace target-full.nii.gz -dofin pre-dof.gz -dofout tpn.dof.gz >noisy.log 2>&1
	    tpn=$td/tpn.dof.gz
	else
	    msg "Calculating affine normalization to reference space"
	    areg2 $refspace target-full.nii.gz -dofout tpn.dof.gz >noisy.log 2>&1 
	fi
    fi
fi


### Array

levelname[0]="coarse"
levelname[1]="affine"
levelname[2]="nonrigid"
levelname[3]="none"


### Initialize first loop

tgt="$PWD"/target-full.nii.gz
tmg=$tgt
level=0
prevlevel=init
seq 1 $atlasn >selection-$prevlevel.csv
nselected=$(cat selection-$prevlevel.csv | wc -l)
usepercent=$(echo $nselected | awk '{ printf "%.0f", 100*(8/$1)^(1/3) } ')


### Iterate over levels

for level in $(seq 0 $maxlevel) ; do
    thislevel=${levelname[$level]}
    msg "Level $thislevel"
    cat /dev/null >job.conf

    ## Prep datasets line by line in job.conf
    for srcindex in $(cat selection-$prevlevel.csv) ; do

	set -- $(head -n $[$srcindex+1] $atlas | tail -n 1 | tr ',' ' ')
	atlasname=$1 ; shift
	src=$atlasbase/$1 ; shift
	mrg=$atlasbase/$1 ; shift
	spn=$atlasbase/$1 ; shift
	msk=$atlasbase/$1 ; shift
	alt=$atlasbase/$1 ; shift

	if [[ $level -ge 2 ]] ; then 
	    mrggen=$td/mrg-s$srcindex.nii.gz
	    if [[ ! -e $mrggen ]] ; then
		seg_maths $mrg -bin -mul $src $mrggen
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
	    echo "-tgt $tgt" "-src $src" "-srctr $srctr" "-msk $msk" "-masktr $masktr" "-alt $alt" "-alttr $alttr" "-dofin $dofin" "-dofout $dofout" "-spn $spn" "-tpn $tpn" "-lev $level -tmargin $tmg" >>$td/job.conf
	fi
    done


    ## Launch parallel registrations
    cp job.conf job-$thislevel.conf
    if [[ -s job.conf ]] 
    then
	msg "Launching registrations"
	csec=$("$cdir"/distrib -script "$cdir"/reg.sh -datalist $td/job.conf -level $level)
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
	    msg "Masks not ready by deadline. Relaunching registrations"
	    csec=$("$cdir"/distrib -script "$cdir"/reg.sh -datalist $td/job.conf -level $level)
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


    ## Generate intermediate target mask
    seg_maths tmask-$thislevel-sum.nii.gz -thr 0 -bin tmask-$thislevel.nii.gz
    assess tmask-$thislevel.nii.gz | tee -a assess.log


    ## Generate target margin mask for similarity ranking and apply
    seg_maths tmask-$thislevel-sum.nii.gz -abs -uthr 0.99 -bin emargin-$thislevel-dil.nii.gz


    ## Selection
    msg "Selecting"
    if [[ $par -eq 1 ]]
    then
	for srcindex in $(cat selection-$prevlevel.csv) ; do
	    srctr="$PWD"/srctr-$thislevel-s$srcindex.nii.gz
	    if [[ -e $srctr ]] && [[ ! -z $srctr ]] ; then
		echo $( nmi $srctr )",$srcindex"
	    fi
	done | sort -rn | tee simm-$thislevel.csv | cut -d , -f 2 > ranking-$thislevel.csv
    else
	for srcindex in $(cat selection-$prevlevel.csv) ; do
	    srctr="$PWD"/srctr-$thislevel-s$srcindex.nii.gz
	    if [[ -e $srctr ]] && [[ ! -z $srctr ]] ; then
		echo $( nmi $srctr )",$srcindex" > simm-$thislevel-s$srcindex.csv & brake $par
	    fi
	done
	wait
	cat simm-$thislevel-s*.csv | sort -rn | tee simm-$thislevel.csv | cut -d , -f 2 > ranking-$thislevel.csv
	rm simm-$thislevel-s*.csv
    fi
	
    tar -cf srctr-$thislevel.tar srctr-$thislevel-s*.nii.gz ; rm srctr-$thislevel-s*.nii.gz
    tar -cf alttr-$thislevel.tar alttr-$thislevel-s*.nii.gz
    maxweight=$(head -n 1 simm-$thislevel.csv | cut -d , -f 1)
    nselected=$[$thissize*$usepercent/100]
    [ $nselected -lt 9 ] && nselected=7
    split -l $nselected ranking-$thislevel.csv
    mv xaa selection-$thislevel.csv
    [ -e xab ] && cat x?? > unselected-$thislevel.csv
    msg "Selected $nselected at $thislevel"


    ## Build label from selection
    thissize=$#
    [[ $thissize -lt 7 ]] && fatal "Mask generation failed at level $thislevel"
    head -n $thissize simm-$thislevel.csv | tr , ' ' | while read nmi s
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
    rm masktr-$thislevel-*.nii.gz
    prevlevel=$thislevel


    ## Target data mask (skip on last iteration)
    scalefactor=$(seg_stats tmask-$thislevel-sel-sum.nii.gz -r | cut -d ' ' -f 2)
    seg_maths tmask-$thislevel-sel-sum.nii.gz -div $scalefactor probmap-$thislevel.nii.gz
    [ $level -eq $maxlevel ] && continue
    seg_maths probmap-$thislevel.nii.gz -abs -uthr 0.99 dmargin-$thislevel.nii.gz ## Tested 0.9: worse
    tmg="$PWD"/dmargin-$thislevel.nii.gz
done


### Calculate success index (SI)

echo -n "SI:" ; labelStats tmask-$thislevel.nii.gz tmask-$thislevel-sel.nii.gz -false | tee si.csv


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
convert andmask.nii.gz parenchyma1.nii.gz -uchar >>noisy.log 2>&1
convert ormask.nii.gz icv1.nii.gz -uchar >>noisy.log 2>&1


### Compare output mask with reference

assess parenchyma1.nii.gz | tee -a assess.log


### Package and delete transformations

tar -cf reg-dofs.tar reg*.dof.gz ; rm reg*.dof.gz


### Apply original origin settings and copy output

headertool parenchyma1.nii.gz "$result"/parenchyma.nii.gz -origin $originalorigin
headertool icv1.nii.gz "$result"/icv.nii.gz -origin $originalorigin
headertool probmap-$thislevel.nii.gz "$result"/prime-probmap.nii.gz -origin $originalorigin

msg "$(date)"
msg "End processing"
exit 0
