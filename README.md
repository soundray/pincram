# pincram

Brain extraction using label propagation and group agreement.

Pincram takes as input

* a target image -- T1-weighted 3D magnetic resonance (MR) volume of the human brain in NIfTI format

* an atlas database consisting of reference MR images and corresponding binary segmentations (total brain volume masks and intracranial volume masks).

It produces

* a total brain volume mask (parenchyma plus internal cerebrospinal fluid)

* an intracranial volume mask that fully contains the former

* a probabilistic segmentation of the total brain

corresponding to the target image.

The atlas-target registrations are embarrassingly parallel. Pincram runs them either on the local machine or as Slurm job arrays.

## Dependencies

* MIRTK (https://github.com/BioMedIA/MIRTK) -- always needed, also for the fusion steps
* NiftySeg (https://github.com/KCL-BMEIS/NiftySeg) -- `seg_maths`
* bash 4, GNU coreutils, findutils (`xargs`), awk, sed, grep
* optional: greedy (https://github.com/pyushkevich/greedy) as experimental alternative registration library (`PINCRAM_USE_LIB=greedy`), Slurm (`PINCRAM_ARCH=slurm`), ShellCheck for the tests

A reproducible build is available via Nix (`nix build`, see `default.nix`). If MIRTK and NiftySeg are only available in a container image, put `tests/container-bin` on the `PATH` and point `PINCRAM_SIF` at the image.

## Instructions

Add the pincram directory to `PATH`. Review the `run-pincram` script for a sample invocation. Call `pincram.sh` without arguments for usage. Create an atlas directory with `atlas-gen.sh` (one call per subject).

## Execution and parallelism

Each refinement level registers every selected atlas to the target. These registrations are independent and are run as a batch by the `scheduler` module:

| `PINCRAM_ARCH` | How registrations run | `-par` | `-threads` |
|---|---|---|---|
| `local` (default) | `xargs -P` on this machine | registrations at a time; default: CPUs / threads | threads per registration (MIRTK `-threads`); default 1 |
| `slurm` | one job array per level and attempt, one task per registration | job array throttle; default: no limit | `--cpus-per-task` per task |

`-par` only controls how many registrations run concurrently. The scheduler allocation (memory, time limit, account, partition) is set separately through the environment:

| Variable | Meaning | Default |
|---|---|---|
| `PINCRAM_SLURM_MEM` | memory per registration task, one value per level | `4G 4G 8G` |
| `PINCRAM_SLURM_TIME` | time limit per task in minutes, one value per level | `30 30 120` |
| `PINCRAM_SLURM_OPTS` | further `sbatch` options, e.g. `-A account -p partition` | empty |
| `PINCRAM_MAX_ATTEMPTS` | attempts per registration before an atlas is given up | `3` |
| `PINCRAM_PROCEED_PCT` | % of selected atlases that must register successfully for a level to proceed | `100` |
| `PINCRAM_DRIVER_THREADS` | threads for the driver's own MIRTK steps (fusion, ranking, distance maps) | local: `-par` x `-threads`, capped at the CPU count; Slurm: `SLURM_CPUS_ON_NODE` or `-threads` |
| `PINCRAM_POLL_SEC` | interval for polling `squeue` | `20` |

Typical invocations:

```sh
# Workstation or interactive allocation: 16 registrations at a time, 2 threads each
pincram.sh t1.nii.gz -result out -atlas atlas -par 16 -threads 2

# Login node driving Slurm job arrays; the working directory must be on a shared file system
export PINCRAM_ARCH=slurm PINCRAM_SLURM_OPTS="-A myaccount -p cpu"
pincram.sh t1.nii.gz -result out -atlas atlas -workdir "$PWD" -par 50

# The whole run as one Slurm job (registrations stay inside the allocation)
sbatch -c 32 --mem 120G -t 3:00:00 --wrap "pincram.sh t1.nii.gz -result out -atlas atlas"
```

### Retries

After a batch has finished, every registration that produced no mask is classified from the status file that `reg.sh` writes on exit (`status/<level>-a<A>-n<line>`, which also records elapsed time and, where the cgroup exposes it, peak memory) and, under Slurm, from `sacct`:

* exit code 137 or Slurm state `OUT_OF_MEMORY`: retried with doubled memory
* Slurm state `TIMEOUT`: retried with doubled time limit
* any other failure, or no status at all (process killed): retried with the same resources

Tasks that are still queued or running are never resubmitted; the driver waits for them. If `PINCRAM_PROCEED_PCT` is below 100, a level proceeds as soon as that percentage of masks exists and no task is running any more; queued tasks are then cancelled. Atlases that fail `PINCRAM_MAX_ATTEMPTS` times are dropped from the level with a pointer to their log. Driver failure cancels outstanding job arrays.

## Working directory

A uniquely named directory `pincram.XXXXXX` is created under `-workdir` (default `$TMPDIR/$USER` locally, the current directory under Slurm). It is deleted at the end unless `-savewd` moves it into the result directory. Intermediate files have these lifetimes:

| File | Created | Deleted |
|---|---|---|
| `job-<level>-a<A>.conf` | before each batch (one job line per atlas) | with the working directory |
| `logs/reg-<level>-s<i>.log`, `status/<level>-a<A>-n<line>`, `logs/slurm-*.out` | by each task | with the working directory |
| `tmp/<tag>-s<i>.XXXXXX/` | private scratch of one task | when the task exits |
| `srctr-<level>-s<i>.nii.gz` (transformed atlas image) | by the task | after similarity ranking |
| `masktr-<level>-s<i>.nii.gz`, `masktr-<level>-weighted-s<i>.nii.gz` | by the task / during fusion | after the level's fused label is built |
| `alttr-s<i>.nii.gz` (transformed alternative mask) | by the tasks of the final level only | after the ICV mask is summed |
| `reg-s<i>-<level>.dof.gz` (transformation) | by the task | after the next level's registrations (they initialize them); final level: at the end unless `-savewd` |
| `tmask-*`, `distmap-*`, `dmargin-*`, `emargin-*`, `simm-*`, `ranking-*`, `selection-*`, `weights-*` | per level | with the working directory |

Tasks write all outputs in their private scratch directory and move them into place when complete, the mask last, so an existing `masktr` file always means a finished registration.

## Tests

```sh
tests/run-tests.sh            # ShellCheck on all scripts + orchestration tests with placeholder tools
tests/run-tests.sh retry      # a single test (tests/test-retry.sh)
```

The orchestration tests (`tests/test-*.sh`) exercise selection sizes, job counts and file lifetimes for 7, 20 and 100 atlases, all three processing levels, the retry logic (transient failure, SIGKILL, permanent failure, `PINCRAM_PROCEED_PCT`) and the Slurm backend against mock `sbatch`/`squeue`/`sacct`/`scancel` (array sizing, throttling, memory and time escalation). They need only bash, coreutils, awk and ShellCheck.

Regression tests against real data run `pincram.sh` at each processing level and compare the Jaccard overlap of the outputs with reference masks against a baseline:

```sh
tests/regression/regress.sh -target atlas/base/images/m100.nii.gz -atlas atlas \
    -ref atlas/base/brainmasks/m100.nii.gz -icvref atlas/base/icvmasks/m100.nii.gz \
    -levels "1 2 3" -baseline tests/regression/baselines/ixi-n100-m100.csv -- -par 32
```

A target that is itself an atlas entry is left out of the atlas automatically. See `docs/parallelism.md` for benchmarking.

## Changes from the PBS-era version

* `-pickup` and the `tar` archives of intermediate masks are gone; runs are not resumable. Use `-savewd` to keep intermediates.
* `distrib`, `spark` and the PBS/GE/`bash-single` modes (`PINCRAM_ARCH=pbs|ge|bash-single`, `PINCRAM_QUEUE`, `PINCRAM_CHUNKSIZE`, `PINCRAM_PBS_OPTION`) are replaced by `scheduler` with `PINCRAM_ARCH=local|slurm`. `bash` is accepted as an alias of `local`.
* `-par` no longer doubles as the MIRTK thread count; use `-threads`.
* The IRTK registration branch (`PINCRAM_USE_LIB=irtk`) is removed; MIRTK is the reference implementation, greedy is experimental.
* The tuned constants of the method are named at the top of `pincram.sh` and `reg.sh`.
* `bc` and `rev` are no longer needed (replaced by awk and sed), which shortens the dependency list.
* The atlas csv has five columns (name, image, normalization, prime mask, alternative mask); the usage text used to describe six.

## See also

http://soundray.org/pincram

## If you use this software for your research

Please cite: [Heckemann RA, Ledig C, Gray KR, Aljabar P, Rueckert D, Hajnal JV, Hammers A. Brain Extraction Using Label Propagation and Group Agreement: Pincram. PLOS ONE. 2015 Jul 10;10(7):e0129211.](http://journals.plos.org/plosone/article?id=10.1371/journal.pone.0129211 "PLOS ONE")
