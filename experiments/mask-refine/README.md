# Refining an input mask (`pincram.sh -mask`, `-refine-band`)

Question: given an existing brain mask of the target, can pincram refine it? Does the input
mask let it skip the coarse level without losing accuracy, and does it recover from degraded
inputs?

Design: 10 Hammers targets (`shared/reference/atlases-hammers-scaled-with-flipped-n60/mri/aN.nii.gz`,
N = 1, 4, ..., 28), the IXI 100-atlas database (`shared/reference/ixi-pincram-atlas-n100-dm`), 3 levels.
Every score is the Jaccard index against the verified total brain volume (TBV) mask, binarized
`icmasked/aN.nii.gz`. `run-target.sh` runs per target: `plain` (no input mask); `hdbet` (HD-BET 1.1
mask of the target, `apps/pincram/temp/hdbet-targets/hammers-aN_mask.nii.gz`); `erode3` / `dilate3` (the
verified TBV mask shifted 3 mm inwards / outwards); `random3` (TBV mask with random boundary
displacement, sd 3 mm, correlation length 5 mm). `degrade.py` makes these. `hdbet-band4` repeats `hdbet`
with `-refine-band 4`. `aggregate.py` also applies the band step post hoc to the no-band
outputs for 2, 4 and 8 mm. `prealign.sh` compares the two pre-alignments directly: the atlas
reference brain mask is mapped onto each target with each normalization and scored against TBV.
`submit.sh` runs one 32-CPU Slurm job per target (all conditions sequentially on the same node).

## Results (2026-10-08)

`results/summary.md`, `results/results.csv`, `results/prealign.csv`; discussion in `docs/experiments.md`.

| input mask (to `-mask`) | input vs TBV | output vs TBV | paired diff. to plain | better | output vs plain output | time |
|---|---|---|---|---|---|---|
| none (plain) | | 0.9483 | | | | 352 s |
| HD-BET on target | 0.942 | 0.9483 | +0.0001 ± 0.0030 | 5/10 | 0.980 | 300 s |
| TBV eroded 3 mm | 0.723 | 0.9503 | +0.0020 ± 0.0058 | 5/10 | 0.979 | 306 s |
| TBV random 3 mm | 0.841 | 0.9500 | +0.0017 ± 0.0062 | 6/10 | 0.980 | 306 s |
| TBV dilated 3 mm | 0.841 | 0.9365 | -0.0117 ± 0.0310 | 2/10 | 0.964 | 296 s |

Without a band, pincram converges to about its own answer, whatever the input. The one failure
(a22, dilated input: 0.856) comes from the pre-alignment, not the refinement; see `docs/experiments.md`.
Post-hoc bands help only when the band is wider than the input's error. With an input derived
from the reference itself, the core and hull are then reference information. HD-BET input with
`-refine-band 4` gives +0.0009 (5/10). The in-pipeline `-refine-band 4` matched the post-hoc
computation exactly on all 10 targets.
