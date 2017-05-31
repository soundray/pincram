#!/bin/bash

cdir=$(dirname $0)
. $cdir/common
cdir=$(normalpath $cdir)

pn=$(basename $0)

commandline="$pn $*"

# Parameter handling
usage () { 
echo
echo "pincram version 0.2 "
echo
echo "Copyright (C) 2012 Rolf A. Heckemann "
echo "Web site: http://www.soundray.org/pincram "
echo 
echo "Usage: $0 <input> <options> <-result result.nii.gz> <-output temp_output_dir> [-atlas atlas_directory] \\ "
echo "                       [-levels {2..5}] [-par max_parallel_jobs] [-ref ref.nii.gz] "
echo 
echo "<input>     : T1-weighted magnetic resonance image in gzipped NIfTI format."
echo 
echo "-result     : Name of file to receive output, a binary brain label image."
echo 
echo "-probresult : (Optional) name of file to receive output, a probabilistic label image."
echo 
echo "-tempbase   : Directory for intermediate output.  Ideally a local directory (but this does not work on HPC)."
echo "              To store these for later access, see -output option."
echo 
echo "-output     : Directory to receive intermediate output.  If a non-existent location is given,"
echo "              intermediate files will be discarded. "
echo 
echo "-atlas      : Atlas directory."
echo "            : Has to contain limages/full/m{1..n}.nii.gz, lmasks/full/m{1..n}.nii.gz and posnorm/m{1..n}.dof.gz "
echo 
echo "-levels     : Integer between 2 and 5. Indicates level of refinement required."
echo 
echo "-ref        : Reference label against which to log overlap results."
echo 
echo "-par        : Number of jobs to run in parallel.  Please use with consideration."
echo 
fatal "Parameter error"
}

[ $# -lt 3 ] && usage

tgt=$(normalpath $1) ; shift
test -e $tgt || fatal "No image found -- $t"

par=1
ref=none
exclude=0
levels=4
atlasdir=$(normalpath $cdir/..)
outdir=$(normalpath $PWD)
tdbase=$cdir/temp
while [ $# -gt 0 ]
do
    case "$1" in
	-tpn)               tpn=$(normalpath $2); shift;;
	-result)         result=$(normalpath $2); shift;;
	-probresult) probresult=$(normalpath $2); shift;;
	-atlas)        atlasdir=$(normalpath $2); shift;;
	-output)         outdir=$(normalpath $2); shift;;
	-tempbase)       tdbase=$(normalpath $2); shift;;
	-ref)               ref=$(normalpath $2); shift;;
	-levels)         levels=$2; shift;;
	-excludeatlas)  exclude=$2; shift;;
	-par)               par=$2; shift;;
	--) shift; break;;
        -*)
            usage;;
	*)  break;;
    esac
    shift
done

[ -z $result ] && fatal "Result filename not set"

maxlevel=$[$levels-1]

hostname -f | grep -q hpc.ic.ac.uk ; hpc=$?
[ $hpc -eq 0 ] && par=1 # Backgrounding not allowed on Imperial HPC

echo "Extracting $tgt"
echo "Writing brain label to $result"

# Functions

cleartospawn() { 
    local jobcount="$(jobs -r | grep -c .)"
    if [ $jobcount -lt $par ] ; then
        return 0
    fi
    return 1
}

reg () {
    local tgt=$1 ; shift
    local tgt2=$1 ; shift
    local src=$1 ; shift
    local msk=$1 ; shift
    local masktr=$1; shift
    local dofin=$1; shift
    local dofout=$1; shift
    local spn=$1; shift
    local tpn=$1; shift
    local level=$1; shift
    local ltd=$(mktemp -d reg$level.XXXXXX)
    local job=j$level
    cat pbscore >$ltd/$job
    cd $ltd
    case $level in 
	0 ) 
	    echo "dofcombine $spn $tpn pre.dof.gz -invert2 >>log 2>&1" >>$job 
       	    # echo "transformation $atlasdir/callosum-subvol.nii.gz premask.nii.gz -sbased -dofin pre.dof.gz -target $tgt" >>$job
	    echo "rreg2 $tgt $src -dofin pre.dof.gz -dofout $dofout -parin $td/lev0.reg >>log 2>&1" >>$job
	    # echo "cp pre.dof.gz premask.nii.gz $td/$ltd/" >>$job
	    echo "transformation $msk $masktr -dofin $dofout -sbased -target $tgt2 >>log 2>&1" >>$job
	    ;;
	1 ) 
	    echo "areg2 $tgt $src -dofin $dofin -dofout $dofout -parin $td/lev1.reg >>log 2>&1" >>$job 
	    echo "transformation $msk $masktr -dofin $dofout -sbased -target $tgt2 >>log 2>&1" >>$job
	    ;;
	[2-4] )
	    echo "nreg $tgt $src -dofin $dofin -dofout $dofout -parin $td/lev$level.reg >>log 2>&1" >> $job
	    echo "transformation $msk $masktr -sbased -dofin $dofout -target $tgt2 >>log 2>&1" >>$job
	    ;;
    esac
    if [ $level -ge 1 ] && [ $par -eq 1 ] && [ $hpc -eq 0 ] ; then
	echo $(qsub -l walltime=$[1800*$[$level+1]] $job) >>../reg-jobs
    else
	if [ $hpc -eq 1 ] ; then
	    . $job &
	else
	    . $job
	fi
    fi
    cd ..
    return 0
}

assess() {
    local glabels=$1
    test -e $ref || return 1
    transformation $glabels assess.nii.gz -target $ref >>noisy.log 2>&1
    echo -e "$glabels:\t\t"$(labelStats $ref assess.nii.gz -q)
    return 0
}

# Temporary working directory
test -e $tdbase || mkdir -p $tdbase
td=$(mktemp -d $tdbase/$(basename $0).XXXXXX) || fatal "Could not create temp dir in $tdbase"
trap 'if [ -e $outdir ] ; then mv $td $outdir/ ; else rm -rf $td ; fi' 0 1 15 
cd $td
echo "$commandline" >commandline.log

# Parameters (sets variables: fullsetsize, setsize[0..n])
. $cdir/parameters

# Rigid
cat >lev0.reg << EOF
No. of resolution levels          = 3
No. of bins                       = 64
Epsilon                           = 0.0001
Padding value                     = 0
Resolution level                  = 1
No. of iterations                 = 0
Resolution level                  = 2
No. of iterations                 = 40
Target resolution (in mm)         = 2 2 2
Source resolution (in mm)         = 2 2 2
Target blurring (in mm)           = 1
Source blurring (in mm)           = 1
Resolution level                  = 3
Target resolution (in mm)         = 5 5 5
Source resolution (in mm)         = 5 5 5
Target blurring (in mm)           = 2
Source blurring (in mm)           = 2
No. of iterations                 = 40
Maximum length of steps           = 2
EOF

# Affine
cat >lev1.reg << EOF
No. of resolution levels          = 3
No. of bins                       = 64
Epsilon                           = 0.0001
Padding value                     = 0
Resolution level                  = 1
No. of iterations                 = 40
Resolution level                  = 2
No. of iterations                 = 40
Resolution level                  = 3
No. of iterations                 = 0
EOF

# Coarse
cat >lev2.reg <<EOF
Padding value                     = 0
No. of resolution levels          = 3
Control point spacing in X        = 60
Control point spacing in Y        = 60
Control point spacing in Z        = 60
Resolution level                  = 1
Target resolution (in mm)         = 4 4 4
Source resolution (in mm)         = 4 4 4
Target blurring (in mm)           = 2
Source blurring (in mm)           = 2
No. of iterations                 = 40
Resolution level                  = 2
No. of iterations                 = 0
Resolution level                  = 3
No. of iterations                 = 0
EOF

# Medium
cat >lev3.reg <<EOF
Padding value                     = 0
No. of resolution levels          = 2
Control point spacing in X        = 16
Control point spacing in Y        = 16
Control point spacing in Z        = 16
Resolution level                  = 1
Target resolution (in mm)         = 2 2 2
Source resolution (in mm)         = 2 2 2
Target blurring (in mm)           = 1
Source blurring (in mm)           = 1
No. of iterations                 = 40
Resolution level                  = 2
No. of iterations                 = 0
EOF

# Fine
cat >lev4.reg <<EOF
Padding value                     = 0
No. of resolution levels          = 1
Control point spacing in X        = 3
Control point spacing in Y        = 3
Control point spacing in Z        = 3
Resolution level                  = 1
Target resolution (in mm)         = 0 0 0
Source resolution (in mm)         = 0 0 0
Target blurring (in mm)           = 0
Source blurring (in mm)           = 0
No. of iterations                 = 40
EOF

cat >pbscore <<EOF
#!/bin/bash
#PBS -l mem=1900mb,ncpus=1
#PBS -j oe
#PBS -q pqneuro
export PATH=$irtk:\$PATH
EOF

# Target preparation
originalorigin=$(info $tgt | grep origin | cut -d ' ' -f 4-6)
headertool $tgt target-full.nii.gz -origin 0 0 0
convert $tgt target-full.nii.gz -float
convert target-full.nii.gz target-full-char.nii.gz -uchar

# Arrays
levelname[0]="rigid"
levelname[1]="affine"
levelname[2]="coarse"
levelname[3]="medium"
levelname[4]="fine"
levelname[5]="none"
dil[0]=6
ero[0]=6
dil[1]=5
ero[1]=5
dil[2]=3
ero[2]=3
dil[3]=2
ero[3]=2
dil[4]=1
ero[4]=1

# Initialize first loop
tgt=$PWD/target-full.nii.gz
segtgt=$PWD/target-full-char.nii.gz
prevlevel=init
seq 1 $fullsetsize | grep -vw $exclude >selection-$prevlevel.csv

for level in $(seq 0 $maxlevel) ; do
    thislevel=${levelname[$level]}
# Registration
    echo "Level $thislevel"
    for srcindex in $(cat selection-$prevlevel.csv) ; do
	sourcenii=m$srcindex.nii.gz
	src=$atlasdir/limages/full/$sourcenii
	msk=$atlasdir/lmasks/full/$sourcenii
	masktr=$PWD/masktr-$thislevel-s$srcindex.nii.gz
	dofin=$PWD/reg-s$srcindex-$prevlevel.dof.gz 
	dofout=$PWD/reg-s$srcindex-$thislevel.dof.gz
	spn=$atlasdir/posnorm/m$srcindex.dof.gz
	reg $tgt $segtgt $src $msk $masktr $dofin $dofout $spn $tpn $level
	echo -n .
	while true ; do cleartospawn && break ; sleep 10 ; done
    done
    echo
    if [ -e reg-jobs ] ; then
	while true ; do qstat | grep -qwf reg-jobs || break ; sleep 3 ; done
	rm reg-jobs
	else
	wait
    fi
# Generate reference for atlas selection (fused from all)
    thissize=$(ls masktr-$thislevel-s* | wc -l)
    atlas tmask-$thislevel-atlas.nii.gz masktr-$thislevel-s*.nii.gz -scaling $thissize >>noisy.log 2>&1
    threshold tmask-$thislevel-atlas.nii.gz tmask-$thislevel.nii.gz $[$thissize/2] 
    assess tmask-$thislevel.nii.gz
# Selection
    echo "Selecting"
    for srcindex in $(cat selection-$prevlevel.csv) ; do
	if [ -e masktr-$thislevel-s$srcindex.nii.gz ] ; then
	    echo $(labelStats tmask-$thislevel.nii.gz masktr-$thislevel-s$srcindex.nii.gz | cut -d , -f 5)",$srcindex"
	fi
    done | sort -n | tee overlaps-$thislevel.csv | cut -d , -f 2 | tail -n ${setsize[$level]} >selection-$thislevel.csv
    nselected=$(cat selection-$thislevel.csv | wc -l)
    echo "Selected $nselected at $thislevel"
# Build label from selection
    atlaslist=$(cat selection-$thislevel.csv | while read item ; do echo masktr-$thislevel-s$item.nii.gz ; done)
    atlas tmask-$thislevel-sel-atlas.nii.gz $atlaslist -scaling $nselected >>noisy.log 2>&1
    threshold tmask-$thislevel-sel-atlas.nii.gz tmask-$thislevel-sel.nii.gz $[$nselected/2] 
    assess tmask-$thislevel-sel.nii.gz
# Data mask (skip on last iteration)
    [ $level -eq $maxlevel ] && continue
    threshold tmask-$thislevel-sel-atlas.nii.gz tmask-$thislevel-wide.nii.gz 0
    threshold tmask-$thislevel-sel-atlas.nii.gz tmask-$thislevel-narrow.nii.gz $[$nselected-1]
    dilation tmask-$thislevel-wide.nii.gz tmask-$thislevel-wide-dil.nii.gz -iterations ${dil[$level]} >>noisy.log 2>&1
    erosion tmask-$thislevel-narrow.nii.gz tmask-$thislevel-narrow-ero.nii.gz -iterations ${ero[$level]} >>noisy.log 2>&1
    subtract tmask-$thislevel-wide-dil.nii.gz tmask-$thislevel-narrow-ero.nii.gz tmargin-$thislevel.nii.gz -no_norm >>noisy.log 2>&1
    padding target-full.nii.gz tmargin-$thislevel.nii.gz target-masked.nii.gz 0 0
    tgt=$PWD/target-masked.nii.gz
    prevlevel=$thislevel
done

transformation tmask-$thislevel-sel.nii.gz output.nii.gz -target target-full-char.nii.gz >>noisy.log 2>&1
headertool output.nii.gz $result -origin $originalorigin

[ -z $probresult ] && exit 0
headertool tmask-$thislevel-sel-atlas.nii.gz $probresult -origin $originalorigin

exit 0
