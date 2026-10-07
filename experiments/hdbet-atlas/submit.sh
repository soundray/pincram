#!/bin/bash
# submit.sh VARIANT ATLASDIR -- submit the Hammers and Klasson target runs for one atlas variant (4 jobs of 5 targets)
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$here")")
variant=$1 ; atlas=$(realpath "$2")
: "${EXP:=$pincramdir/temp/hdbet-atlas}" ; mkdir -p "$EXP"
: "${PINCRAM_SIF:=/nobackup/proj/disk/metrimorphics0/apps/maper/maper.sif}"
: "${SLURM_OPTS:=-A naiss2026-4-151-cpu -p cpu -c 32 --mem=120G -t 03:00:00}"
: "${VENV:=$pincramdir/temp/venv}"
: "${HAMMERS_TARGETS:=a1 a4 a7 a10 a13 a16 a19 a22 a25 a28}"
: "${KLASSON_TARGETS:=m1 m7 m13 m19 m25 m31 m37 m43 m49 m55}"
submit () {   # submit REFSET TARGETS...
    local refset=$1 ; shift
    # shellcheck disable=SC2086
    sbatch $SLURM_OPTS -J "hdbet-$variant-$refset" -o "$EXP/$variant-$refset-$1.out" \
        "--export=ALL,PINCRAM_SIF=$PINCRAM_SIF,EXP=$EXP,PATH=$VENV/bin:$pincramdir/tests/container-bin:$pincramdir:$PATH" \
        --wrap "bash '$here/run-targets.sh' '$variant' '$atlas' '$refset' $*"
}
read -r -a h <<<"$HAMMERS_TARGETS" ; read -r -a k <<<"$KLASSON_TARGETS"
submit hammers "${h[@]:0:5}" ; submit hammers "${h[@]:5:5}"
submit klasson "${k[@]:0:5}" ; submit klasson "${k[@]:5:5}"
