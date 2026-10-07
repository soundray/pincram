# Benchmarking pincram's parallelism

Pincram alternates between an embarrassingly parallel phase (one registration per selected
atlas) and a serial phase in the driver (mask fusion, similarity ranking, distance maps).
The questions worth answering by measurement, and how to answer them with what the scripts
already record:

## What the scripts record

* `status/<level>-a<attempt>-n<line>` in the working directory: `rc=<exit> elapsed=<s> peak_mb=<MB> ... atlas=<i> level=<name>` for every task. `peak_mb` is the task cgroup's `memory.peak` (cgroup v2), which Slurm provides per task and which survives container wrappers; it is empty where the cgroup is not readable. It includes page cache, so it is an upper bound on what the task needs. Under local execution all concurrent tasks share one cgroup, so the value is the peak of the whole job, not of the task; use a Slurm run to measure per-task memory. Aggregate per level with

  ```sh
  awk -F'[ =]' '{ l=$12 ; e[l] += $4 ; n[l]++ ; if ($4 > t[l]) t[l] = $4 ; if ($6 > p[l]) p[l] = $6 } END { for (l in n) printf "%s: %d tasks, mean %.0f s, max %.0f s, peak %s MB\n", l, n[l], e[l]/n[l], t[l], p[l] }' status/*
  ```

* Under Slurm, `sacct` has peak memory and queue wait per task:

  ```sh
  sacct -j <jobid> -X -P -o JobID,Elapsed,MaxRSS,Submit,Start,State
  ```

  Memory and time requests (`PINCRAM_SLURM_MEM`, `PINCRAM_SLURM_TIME`) should sit a little above the observed maxima per level, so that retries with doubled resources stay rare and queue wait stays low. When the tools run through a container wrapper, `MaxRSS` may only reflect the wrapper process; measure with `/usr/bin/time -v` inside the container instead.

* `tests/regression/regress.sh` writes `results.csv` with the wall time per level and the overlap with the reference masks, so speed and accuracy are measured together.

## Experiments

1. **Threads per registration.** Run the same target with `-threads 1 2 4 8` and `-par` = CPUs / threads. Compare registrations per CPU-hour (total task CPU time / count). MIRTK's thread scaling is sublinear, so 1 or 2 threads with more concurrent registrations is usually the throughput optimum; more threads only shorten the tail of the last round.

2. **Concurrency.** With `-threads` fixed, increase `-par` until wall time per level stops falling. Watch for memory pressure (exit code 137 in the status files, `OUT_OF_MEMORY` in `sacct`) and I/O saturation (elapsed grows although CPU per task does not). Under Slurm, `-par` is only a throttle; the useful comparison is unlimited versus a value that keeps the queue wait of the last tasks short.

3. **Driver share (Amdahl).** Subtract the registration phases (max `elapsed` per attempt) from the level's wall time. What remains is the serial driver work: `evaluate-similarity` over all transformed images, the `pincram-image` fusions, the distance map. `PINCRAM_DRIVER_THREADS` speeds up the MIRTK parts; the fusions read every transformed mask once and grow linearly with `-atlasn`.

4. **Atlas count.** Time and accuracy for `-atlasn 20 40 60 100`. Level 0 cost grows linearly with the count; later levels grow with the cube-root selection rule, so the marginal cost of more atlases is mostly in level 0.

5. **Scheduler overhead.** Compare `Start - Submit` from `sacct` with task `elapsed`. If queue wait or array start-up dominates (short tasks at level 0 on a busy cluster), bundling several registrations per task would help; the per-line job file makes that a small change in `reg.sh` and `batch_slurm`.

6. **Failure tolerance.** `PINCRAM_PROCEED_PCT` of 100 versus 90 or 80 with `PINCRAM_MAX_ATTEMPTS` of 1: how much accuracy is lost when a share of the registrations is allowed to be missing, which bounds the value of retries.

Report wall time per level, mean and max task time, peak task memory, and the Jaccard overlaps for every configuration, from the same target and atlas.

## Measurements so far (2026-10-07, IXI 100-atlas database, target m100 left out, MIRTK in a container)

| Setting | Level 0 (99 tasks) | Level 1 (42 tasks) | Level 2 (18 tasks) | Wall time per run | Parenchyma / ICV Jaccard |
|---|---|---|---|---|---|
| local, `-par 32 -threads 1`, 32-CPU node, seg_maths | 9-12 s per task | 9-12 s | 272 s mean, 371 s max | levels 1: 260 s; 2: 282 s; 3: 657 s | 0.899/0.920; 0.927/0.924; 0.977/0.938 |
| same, pincram-image (MIRTK via container wrapper) | | | | levels 1: 190 s; 2: 231 s; 3: 586 s | 0.900/0.919; 0.926/0.921; 0.977/0.950 |
| slurm, 1 CPU per task, no throttle (30 atlases) | 14 s mean, 17 s max | | | levels 1: ~4 min incl. queueing | 0.887/0.922 (20 atlases), 0.975 parenchyma (30 atlases, 3 levels) |

Slurm task cgroups report a peak of about 850 MB for coarse-level tasks (page cache included); level-0 tasks succeed with 600 MB but not with 300 MB (`PINCRAM_SLURM_MEM=150M` retried through 300M to 600M); the 4G default leaves ample room. The nonrigid level dominates the run time, so `-threads 2` or more for level 2 only is the first thing worth measuring next. Local and Slurm execution of the same configuration gave identical overlaps.
