#!/bin/bash

cdir=$(dirname "$0")
. $cdir/common
cdir=$(normalpath "$cdir")

pn=$(basename $0)

commandline="$pn $*"

# Parameter handling
usage () { 
echo
echo "pincram version 0.2 "
echo
echo "Copyright (C) 2012-2015 Rolf A. Heckemann "
echo "Web site: http://www.soundray.org/pincram "
echo 
echo "Usage: $0 <input> <options> <-result result.nii.gz> <-output temp_output_dir> \\ "
echo "                       [-atlas atlas_directory | -atlas file.csv] \\ "
echo "                       [-levels {1..3}] [-par max_parallel_jobs] [-ref ref.nii.gz] "
echo 
echo "<input>     : T1-weighted magnetic resonance image in gzipped NIfTI format."
echo 
echo "-result     : Name of file to receive output, a binary brain label image."
echo 
echo "-probresult : (Optional) name of file to receive output, a probabilistic label image."
echo 
echo "-tempbase   : Temporary working directory.  Ideally a local directory (but this does not work on HPC)."
echo "              To store intermediate output for later access, see -output option."
echo 
echo "-output     : Directory to receive intermediate output.  If a non-existent location is given,"
echo "              intermediate files will be discarded.  If not specified, the intermediate files will"
echo "              be copied to the directory of the result file."
echo 
echo "-atlas      : Atlas directory."
echo "              Has to contain limages/full/m{1..n}.nii.gz, lmasks/full/m{1..n}.nii.gz and posnorm/m{1..n}.dof.gz "
echo "              Alternatively, it can point to a csv spreadsheet: first line should be base directory for atlas "
echo "              files. Entries should be relative to base directory. Each row refers to one atlas.  "
echo "              Column 1: atlasname, column 2: full image, column 3: margin image, column 4: mask, column 5: transformation "
echo "              (.dof format) for positional normalization. Atlasname should be unique across entries." 
echo 
echo "-tpn        : Rigid transformation for positional normalization of the target image (optional)"
echo 
echo "-atlasn     : Maximum number of atlases to use.  By default, all available are used."
echo 
echo "-levels     : Integer, minimum 1, maximum 3. Indicates level of refinement required."
echo 
echo "-ref        : Reference label against which to log Jaccard overlap results."
echo 
echo "-par        : Number of jobs to run in parallel (shell level).  Please use with consideration."
echo 
fatal "Parameter error"
}

[ $# -lt 3 ] && usage

tgt=$(normalpath "$1") ; shift
test -e $tgt || fatal "No image found -- $t"

tpn="$cdir"/neutral.dof.gz
result=
probresult=
par=1
ref=none
exclude=0
atlas=$(normalpath "$cdir"/atlas)
atlasn=0
tdbase="$cdir"/temp
outdir=notspecified
while [ $# -gt 0 ]
do
    case "$1" in
	-tpn)               tpn=$(normalpath "$2"); shift;;
	-result)         result=$(normalpath "$2"); shift;;
	-probresult) probresult=$(normalpath "$2"); shift;;
	-atlas)           atlas=$(normalpath "$2"); shift;;
	-output)         outdir=$(normalpath "$2"); shift;;
	-tempbase)       tdbase=$(normalpath "$2"); shift;;
	-ref)               ref=$(normalpath "$2"); shift;;
	-atlasn)         atlasn="$2"; shift;;
	-levels)         levels="$2"; shift;;
	-excludeatlas)  exclude="$2"; shift;;
	-par)               par="$2"; shift;;
	-queue)           queue="$2"; shift;;
	-clusterthr) clusterthr="$2"; shift;;
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

[ "$outdir" = notspecified ] && outdir=$(basename "$result")

## Set levels to three unless set to 1 or 2 via -levels option
[[ "$levels" =~ ^[1-2]$ ]] || levels=3
maxlevel=$[$levels-1]

[[ "$exclude" =~ ^[0-9]+$ ]] || exclude=0

[[ "$par" =~ ^[0-9]+$ ]] || par=1

[[ $queue =~ ^[[:alpha:]]+$ ]] || queue=

# Do not spawn on cluster unless clusterthr is set to 0, 1, or 2
[[ $clusterthr =~ ^[0-2]$ ]] || clusterthr=$levels 

. "$cdir"/pincram.rc

echo "Extracting $tgt"
echo "Writing brain label to $result"

# Functions

cleartospawn() { 
    local jobcount=$(jobs -r | grep -c .)
    if [ $jobcount -lt $par ] ; then
        return 0
    fi
    return 1
}

reg () {
    local tgt="$1" ; shift
    local src="$1" ; shift
    local srctr="$1" ; shift
    local msk="$1" ; shift
    local masktr="$1"; shift
    local dofin="$1"; shift
    local dofout="$1"; shift
    local spn="$1"; shift
    local tpn="$1"; shift
    local level="$1"; shift
    local ltd
    ltd=$(mktemp -d "$PWD"/reg$level.XXXXXX)
    local job=j$level
    cat pbscore >$ltd/$job
    cd $ltd || fatal "Error: cannot cd to temp directory $ltd"
    case $level in 
	0 ) 
	    echo "dofcombine "$spn" "$tpn" pre.dof.gz -invert2 >>"$ltd/log" 2>&1" >>$job 
	    echo "rreg2 "$tgt" "$src" -dofin pre.dof.gz -dofout "$dofout" -parin "$td/lev0.reg" >>"$ltd/log" 2>&1" >>$job 
	    ;;
	1 ) 
	    echo "areg2 "$tgt" "$src" -dofin "$dofin" -dofout "$dofout" -parin "$td/lev1.reg" >>"$ltd/log" 2>&1" >>$job  
	    ;;
	[2-4] )
	    echo "nreg2 "$tgt" "$src" -dofin "$dofin" -dofout "$dofout" -parin "$td/lev$level.reg" -parout "$ltd/parout" >>"$ltd/log" 2>&1" >> $job
	    ;;
    esac
    echo "transformation "$msk" "$masktr" -linear -dofin "$dofout" -target "$tgt" >>"$ltd/log" 2>&1" >>$job 
    echo "transformation "$src" "$srctr" -linear -dofin "$dofout" -target "$tgt" >>"$ltd/log" 2>&1" >>$job 
    . $job &
    cd ..
    return 0
}

assess() {
    local glabels="$1"
    if [ -e ref.nii.gz ] ; then 
	transformation "$glabels" assess.nii.gz -target ref.nii.gz >>noisy.log 2>&1
	echo -e "$glabels:\t\t"$(labelStats ref.nii.gz assess.nii.gz -q | cut -d ',' -f 1)
    fi
    return 0
}

# Temporary working directory
test -e "$tdbase" || mkdir -p "$tdbase"
td=$(mktemp -d "$tdbase/$(basename $0)-c$exclude.XXXXXX") || fatal "Could not create temp dir in $tdbase"
trap 'if [ -e "$outdir" ] ; then mv "$td" "$outdir"/ ; else rm -rf "$td" ; fi' 0 1 15 
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

# Rigid
cat >lev0.reg << EOF

#
# Registration parameters
#

No. of resolution levels          = 2
No. of bins                       = 64
Epsilon                           = 0.0001
Padding value                     = -1
Source padding value              = -1
Similarity measure                = NMI
Interpolation mode                = Linear

#
# Registration parameters for resolution level 1
#

Resolution level                  = 1
Target blurring (in mm)           = 1
Target resolution (in mm)         = 2 2 2
Source blurring (in mm)           = 1
Source resolution (in mm)         = 2 2 2
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 1

#
# Registration parameters for resolution level 2
#

Resolution level                  = 2
Target blurring (in mm)           = 2
Target resolution (in mm)         = 5 5 5
Source blurring (in mm)           = 2
Source resolution (in mm)         = 5 5 5
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 2

EOF

# Affine
cat >lev1.reg << EOF
#
# Registration parameters
#

No. of resolution levels          = 2
No. of bins                       = 64
Epsilon                           = 0.0001
Padding value                     = 0
Source padding value              = 0
Similarity measure                = NMI
Interpolation mode                = Linear

#
# Registration parameters for resolution level 1
#

Resolution level                  = 1
Target blurring (in mm)           = 0
Target resolution (in mm)         = 0 0 0
Source blurring (in mm)           = 0
Source resolution (in mm)         = 0 0 0
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 1

#
# Registration parameters for resolution level 2
#

Resolution level                  = 2
Target blurring (in mm)           = 1.5
Target resolution (in mm)         = 3 3 3
Source blurring (in mm)           = 1.5
Source resolution (in mm)         = 3 3 3
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 1

EOF

# Nonrigid
cat >lev2.reg <<EOF
#
# Non-rigid registration parameters
#

Lambda1                           = 0.0001
Lambda2                           = 1
Lambda3                           = 1
Control point spacing in X        = 6
Control point spacing in Y        = 6
Control point spacing in Z        = 6
Subdivision                       = True
MFFDMode                          = True

#
# Registration parameters
#

No. of resolution levels          = 1
No. of bins                       = 128
Epsilon                           = 0.0001
Padding value                     = 0
Source padding value              = 0
Similarity measure                = NMI
Interpolation mode                = Linear

#
# Skip resolution level 1
#

Resolution level                  = 1
Target blurring (in mm)           = 0
Target resolution (in mm)         = 0 0 0
Source blurring (in mm)           = 0
Source resolution (in mm)         = 0 0 0
No. of iterations                 = 40
Minimum length of steps           = 0.01
Maximum length of steps           = 2
EOF

[ -n "$queue" ] && queueline="PBS -q $queue"
cat >pbscore <<EOF
#!/bin/bash
#PBS -l ncpus=1
#PBS -j oe
#$queueline
. "$cdir"/common
export PATH="$irtk":\$PATH
EOF

# Target preparation
originalorigin=$(info "$tgt" | grep ^Image.origin | cut -d ' ' -f 4-6)
headertool "$tgt" target-full.nii.gz -origin 0 0 0
convert "$tgt" target-full.nii.gz -float
[ -e "$ref" ] && cp "$ref" ref.nii.gz

# Arrays
levelname[0]="rigid"
levelname[1]="affine"
levelname[2]="nonrigid"
levelname[3]="none"

dmaskdil[0]=3
dmaskdil[1]=3

# Initialize first loop
tgt="$PWD"/target-full.nii.gz
prevlevel=init
seq 1 $atlasn | grep -vw $exclude >selection-$prevlevel.csv
nselected=$(cat selection-$prevlevel.csv | wc -l)
usepercent=$(echo $nselected | awk '{ printf "%.0f", 100*(8/$1)^(1/3) } ')

for level in $(seq 0 $maxlevel) ; do
    thislevel=${levelname[$level]}
    thisthr=${thr[$level]}
# Registration
    echo "Level $thislevel"
    for srcindex in $(cat selection-$prevlevel.csv) ; do

	set -- $(head -n $[$srcindex+1] $atlas | tail -n 1 | tr ',' ' ')
	atlasname=$1 ; shift
	src=$atlasbase/$1 ; shift
	[ $level -ge 2 ] && src=$atlasbase/$1 ; shift
	msk=$atlasbase/$1 ; shift
	spn=$atlasbase/$1 ; shift

	srctr="$PWD"/srctr-$thislevel-s$srcindex.nii.gz
	masktr="$PWD"/masktr-$thislevel-s$srcindex.nii.gz
	dofin="$PWD"/reg-s$srcindex-$prevlevel.dof.gz 
	dofout="$PWD"/reg-s$srcindex-$thislevel.dof.gz

	reg "$tgt" "$src" "$srctr" "$msk" "$masktr" "$dofin" "$dofout" "$spn" "$tpn" $level
	echo -n .
	while true ; do cleartospawn && break ; sleep 8 ; done
    done
    echo
# Wait for registration results
    if [ -e reg-jobs ] ; then
	waitsec=60
	while true ; do 
	    sleep $waitsec
	    available=$(ls masktr-$thislevel-s*.nii.gz 2>/dev/null | wc -l)
	    waitsec=$[$nselected-$available]
	    [[ $waitsec -le 3 ]] && break
	done
	while true ; do
	    sleep 30
	    qstat | grep -qwf reg-jobs || break  
	done
	sleep 1
	rm reg-jobs
	else
	wait
    fi
# Generate reference for atlas selection (fused from all)
    set -- $(ls masktr-$thislevel-s*)
    thissize=$#
    [[ $thissize -gt 3 ]] || fatal "Mask generation failed at level $thislevel" 
    set -- $(echo $@ | sed 's/ / -add /g')
    seg_maths $@ -div $thissize tmask-$thislevel-atlas.nii.gz
    seg_maths tmask-$thislevel-atlas.nii.gz -thr 0.$thisthr -bin tmask-$thislevel.nii.gz 
    dilation tmask-$thislevel.nii.gz tmask-$thislevel-wide.nii.gz -iterations 1 >>noisy.log 2>&1
    erosion tmask-$thislevel.nii.gz tmask-$thislevel-narrow.nii.gz -iterations 1 >>noisy.log 2>&1
    subtract tmask-$thislevel-wide.nii.gz tmask-$thislevel-narrow.nii.gz emargin-$thislevel.nii.gz >>noisy.log 2>&1
    dilation emargin-$thislevel.nii.gz emargin-$thislevel-dil.nii.gz -iterations 3 >>noisy.log 2>&1
    padding target-full.nii.gz emargin-$thislevel-dil.nii.gz emasked-$thislevel.nii.gz 0 0
    assess tmask-$thislevel.nii.gz
# Selection
    echo "Selecting"
    for srcindex in $(cat selection-init.csv) ; do
	srctr="$PWD"/srctr-$thislevel-s$srcindex.nii.gz
	if [ -e $srctr ] ; then
	    echo $(evaluation emasked-$thislevel.nii.gz $srctr -Tp 0 -mask emargin-$thislevel-dil.nii.gz -linear | grep NMI | cut -d ' ' -f 2 )",$srcindex"
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
    thissize=$#
    [[ $thissize -gt 3 ]] || fatal "Mask generation failed at level $thislevel" 
    set -- $(echo $@ | sed 's/ / -add /g')
    seg_maths $@ -div $thissize tmask-$thislevel-sel-atlas.nii.gz 
    seg_maths tmask-$thislevel-sel-atlas.nii.gz -thr 0.$thisthr -bin tmask-$thislevel-sel.nii.gz 
    assess tmask-$thislevel-sel.nii.gz
# Data mask (skip on last iteration)
    [ $level -eq $maxlevel ] && continue
    seg_maths tmask-$thislevel-sel-atlas.nii.gz -thr 0.15 -bin tmask-$thislevel-wide.nii.gz
    seg_maths tmask-$thislevel-sel-atlas.nii.gz -thr 0.99 -bin tmask-$thislevel-narrow.nii.gz
    subtract tmask-$thislevel-wide.nii.gz tmask-$thislevel-narrow.nii.gz dmargin-$thislevel.nii.gz -no_norm >>noisy.log 2>&1
    dilation dmargin-$thislevel.nii.gz dmargin-$thislevel-dil.nii.gz -iterations ${dmaskdil[$level]} >>noisy.log 2>&1
    padding target-full.nii.gz dmargin-$thislevel-dil.nii.gz dmasked-$thislevel.nii.gz 0 0
    tgt="$PWD"/dmasked-$thislevel.nii.gz
    prevlevel=$thislevel
done

labelStats tmask-$thislevel.nii.gz tmask-$thislevel-sel.nii.gz -false

convert tmask-$thislevel-sel.nii.gz output.nii.gz -char >>noisy.log 2>&1
headertool output.nii.gz "$result" -origin $originalorigin

if [ -n "$probresult" ] ; then
    atlas prob.nii.gz $atlaslist >>noisy.log 2>&1
    headertool prob.nii.gz "$probresult" -origin $originalorigin
fi

exit 0
