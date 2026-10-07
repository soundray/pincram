# pincram tests

`tests/run-tests.sh` runs ShellCheck over every script and then the orchestration tests
`tests/test-*.sh`. Pass test names to run a subset: `tests/run-tests.sh retry slurm`.

## Orchestration tests (no imaging tools needed)

The tests put `tests/mock-bin` first on the `PATH`. It holds placeholder versions of

* `mirtk` and `seg_maths`: create output files with the expected names (contents are
  placeholders) and print tables in the formats the driver parses; `evaluate-similarity`
  returns deterministic, distinct NMI values per atlas index so selections are reproducible
* `sbatch`, `squeue`, `sacct`, `scancel`: a miniature Slurm that runs the `--wrap` command of
  every array task in the background and reports task states, mapping exit codes to Slurm
  states (137 to `OUT_OF_MEMORY`, 124 to `TIMEOUT`)

`tests/mock-atlas.sh N DIR` writes a placeholder atlas directory with N entries.

Failure injection: the mock `mirtk register` looks in `$MOCK_FAIL_DIR` for a file named after
the atlas index of the task it runs in:

| File | Behaviour |
|---|---|
| `s<i>-once` | exit 1 on the first call, then succeed |
| `s<i>-always` | exit 1 every time |
| `s<i>-kill-once` | kill itself with SIGKILL once (looks like an out-of-memory kill) |
| `s<i>-timeout-once` | exit 124 once (the mock Slurm reports `TIMEOUT`) |

`MOCK_SLEEP=<s>` slows every mock `mirtk` call, e.g. to watch the Slurm polling.
`KEEP_TEST_DIRS=1` keeps the temporary directories of the tests.

| Test | Covers |
|---|---|
| `test-args.sh` | option validation, removed options, atlas csv handling |
| `test-atlasn.sh` | 7, 20 and 100 atlases at three levels: selection sizes, job counts, logs and status files, cleanup of `srctr`/`masktr`/`alttr`/transformations |
| `test-levels.sh` | `-levels 1`, `2`, `3` with `-ref` and `-savedm`: which levels run, job line contents, outputs |
| `test-retry.sh` | transient failure, SIGKILL, permanent failure; `PINCRAM_PROCEED_PCT`; `PINCRAM_MAX_ATTEMPTS` |
| `test-slurm.sh` | array sizing and throttling, `--cpus-per-task`, per-level memory and time, OOM and timeout escalation on retry |

## Regression tests (real data)

`tests/regression/regress.sh` runs `pincram.sh` at each requested level on a target with
reference masks and compares the Jaccard overlaps with a baseline csv (`level,metric,value`);
see the header of the script. Baselines live in `tests/regression/baselines/`.

`tests/container-bin` holds wrappers that run `mirtk` and `seg_maths` inside an Apptainer
image (`PINCRAM_SIF`), for hosts where the tools are only available in a container.
