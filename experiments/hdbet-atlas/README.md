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
