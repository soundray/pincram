# HD-BET masks as pincram atlas masks

Question: do pincram's results improve when the atlas prime (total brain volume) masks, made by an
early pincram version seeded from the Hammers atlas, are replaced by HD-BET masks of the same
atlas images? The alternative (ICV) masks stay as they are.

Design: HD-BET 1.1 (`-mode accurate -tta 0 -pp 1`) on the 100 IXI atlas images; `build-atlas.sh`
assembles an atlas with those masks as prime masks and rebuilds the brain distance-map cache.
`run-targets.sh` runs pincram (3 levels) with the original and the HD-BET atlas on targets that
have independent references: 10 Hammers subjects (`mri/`, scored on total brain volume against
the binarized verified `icmasked/` images) and 10 Klasson subjects (`limages/full/`, scored on ICV
against the manual ICV masks; parenchyma against `lmasks2/full` is reported as indicative only).
`submit.sh VARIANT ATLASDIR` submits four Slurm jobs per variant; `aggregate.py` writes
`results.csv` and `summary.md` with paired differences.

## Results (2026-10-08)

`results/results.csv` and `results/summary.md`; discussion in `docs/experiments.md`. HD-BET prime
masks lower the total-brain Jaccard against the verified Hammers reference by 0.012 ± 0.009 (worse
on 9 of 10 targets) and the ICV Jaccard against manual Klasson masks by 0.009 ± 0.023, because the
HD-BET convention is about 5% more generous and pincram reproduces its atlas convention.
