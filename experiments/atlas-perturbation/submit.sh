#!/bin/bash
# submit.sh [CONDITION...] -- submit one Slurm job per condition (defaults: all ten). Site settings below.
here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
pincramdir=$(dirname "$(dirname "$here")")
conds=("$@") ; [[ ${#conds[@]} -eq 0 ]] && conds=(none close2 close4 close8 close16 close4smooth random2 random4 dilate1 erode1)
: "${EXP:=$pincramdir/temp/perturb}" ; mkdir -p "$EXP"
: "${PINCRAM_SIF:=/nobackup/proj/disk/metrimorphics0/apps/maper/maper.sif}"
: "${SLURM_OPTS:=-A naiss2026-4-151-cpu -p cpu -c 32 --mem=120G -t 05:00:00}"
: "${VENV:=$pincramdir/temp/venv}"
for c in "${conds[@]}" ; do
    # shellcheck disable=SC2086
    sbatch $SLURM_OPTS -J perturb-$c -o "$EXP/$c.out" \
        "--export=ALL,PINCRAM_SIF=$PINCRAM_SIF,EXP=$EXP,PATH=$VENV/bin:$pincramdir/tests/container-bin:$pincramdir:$PATH" \
        --wrap "bash '$here/run-condition.sh' '$c'"     # not the script itself: Slurm copies that to its spool directory
done
