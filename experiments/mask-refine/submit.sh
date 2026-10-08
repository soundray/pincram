#!/bin/bash
# submit.sh [TARGET...] -- one Slurm job per Hammers target (default: the ten of the HD-BET experiment)
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$here")")
: "${EXP:=$pincramdir/temp/mask-refine}" ; mkdir -p "$EXP"
: "${PINCRAM_SIF:=/nobackup/proj/disk/metrimorphics0/apps/maper/maper.sif}"
: "${SLURM_OPTS:=-A naiss2026-4-151-cpu -p cpu -c 32 --mem=120G -t 03:00:00}"
: "${VENV:=$pincramdir/temp/venv}"
targets=("$@") ; [[ ${#targets[@]} -gt 0 ]] || targets=(a1 a4 a7 a10 a13 a16 a19 a22 a25 a28)
for t in "${targets[@]}" ; do
    # shellcheck disable=SC2086
    sbatch $SLURM_OPTS -J "maskref-$t" -o "$EXP/$t.out" \
        "--export=ALL,PINCRAM_SIF=$PINCRAM_SIF,EXP=$EXP,PATH=$VENV/bin:$pincramdir/tests/container-bin:$pincramdir:$PATH" \
        --wrap "bash '$here/run-target.sh' '$t'"
done
