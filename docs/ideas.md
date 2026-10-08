# Ideas not yet implemented

Postponed work, with enough context to pick it up in a fresh session. Each entry names the
problem, the evidence, the proposed change and how to evaluate it.

## Robust start for mask mode: per-atlas coarse registration (postponed 2026-10-08)

**Problem.** With `-mask`, level 0 ("prealigned") transforms each atlas with its normalization
transforms only (`reg.sh` job line `-register 0`). Every atlas therefore inherits the error of
the target's pre-alignment, and nothing corrects it before the affine level. Usually the affine
level makes up the difference, but not always.

**Evidence** (`experiments/mask-refine`, `docs/experiments.md`, "Refining an input mask").
Jaccard against the verified TBV mask, binarized
`shared/reference/atlases-hammers-scaled-with-flipped-n60/icmasked/aN.nii.gz`:

- Target a22, input = TBV dilated 3 mm: output 0.856, against 0.954 for plain pincram. The
  reference brain mask mapped onto a22 by the pre-alignment scored 0.593. The prealigned
  fusion reached 0.53 and the affine level only 0.77 (plain pincram after the coarse level: 0.91).
- Over all 40 mask runs, prealigned fusions scored 0.55-0.82, against 0.89-0.92 after coarse
  registration in plain pincram.
- The distance-map pre-alignment stalls on both paths (Otsu and brain-mask). The SSD
  registration stops after about 2 iterations (a22: energy 1.000 to 0.997), so the result
  depends on whether the intensity refinement escapes from there.

**Proposed change.** Give level 0 in mask mode a cheap registration per atlas, guided by the
masks rather than by intensities:

- Variant A (preferred): register the atlas's prime distance map (the job line's `-msk`, i.e.
  `cache/brainmasks-dm/<name>.nii.gz`) to the input mask's distance map (`input-dm.nii.gz`, to
  be passed as `-tdm` at level 0). Use Rigid+Affine at coarse resolution, initialized with the
  composed normalizations (`dof-pre.dof`). In `reg.sh` this would be a third `-register` mode,
  e.g. `-register dm`. It is cheap (smooth images, few levels), independent of image contrast,
  and uses exactly the information the input mask provides.
- Variant B: keep the normal coarse level (intensity registration, `mirtk_coarse` in `reg.sh`)
  and use the input mask only for the ranking margin and the affine level. This is more
  robust but loses most of the time saving (about 15% of the wall time).

Check first whether the SSD stall also affects variant A. If it does, try normalizing the
distance maps, clipping them to a band (e.g. ±20 mm) so the background does not dominate SSD,
or adding a finer level. Fixing the stall might also improve the existing target pre-alignment
for plain pincram, which would be a separate change and needs its own regression baseline.

**Evaluation.** Rerun `experiments/mask-refine` with the new mode (`run-target.sh`, conditions
`plain hdbet erode3 dilate3 random3`). Run from a snapshot copy of the repo, passing `EXP`,
`VENV` and `HDBET` explicitly (the snapshot has no `temp/`). Compare against
`experiments/mask-refine/results/results.csv`. Success means:

- a22/dilate3 is back near plain (≥ 0.94);
- no condition loses more than 0.002 on average against the current mask mode;
- the prealigned-level fusion scores improve towards the plain coarse level (log them from
  each run's `assess.log`);
- wall time stays clearly below plain pincram's 352 s.
