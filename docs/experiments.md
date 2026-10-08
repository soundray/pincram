# Experiments on method details

Results of experiments that informed a decision about the method, so that the question is not
reopened without new evidence. Target for all: see the regression baseline (`tests/regression/`).

## Cavities in the Otsu head mask (2026-10-07)

The reference-space pre-alignment registers negated distance maps of smoothed, Otsu-thresholded
head masks (`smooth-otsu`, sigma 6 voxels). These masks contain enclosed cavities: ventricles,
nasal cavity and sinuses, mastoid air cells. On IXI m100 they amount to 1.2% of the mask volume;
on the ADNI image i248626 to 2.8% (118 ml), the largest (68 ml, nasal cavity and sinuses) abutting
the orbitofrontal brain surface.

Question: does filling the cavities (`smooth-otsu ... -fill`, implemented in `pincram-image`:
largest component, optional closing, fill enclosed holes) improve the result?

| Measurement | without fill | with fill |
|---|---|---|
| ADNI pre-alignment, NMI after distance-map stage / after intensity refinement | 1.0632 / 1.0987 | 1.0638 / 1.0987 |
| ADNI pre-alignment transformation difference | | 0.4 mm translation, 0.1 degree, 0.5% scale |
| ADNI parenchyma vs hd-bet 1.1 (Dice) | 0.9501 | 0.9464 |
| ADNI parenchyma vs hd-bet within 40 mm of the nasal cavity (Dice) | 0.8436 | 0.8415 |
| ADNI, where the two pincram masks disagree: share hd-bet calls brain | 90% of 18.0 ml | 78% of 8.8 ml |
| IXI m100 level 1 parenchyma / ICV Jaccard | 0.8997 / 0.9192 | 0.8979 / 0.9200 |
| IXI m100 level 3 parenchyma / ICV Jaccard | 0.9773 / 0.9501 | 0.9779 / 0.9413 |

The pre-alignment is insensitive to the cavities; the downstream differences (parenchyma Dice
0.99 between the two ADNI runs, 4 of the 7 finally selected atlases different) come from the
similarity ranking amplifying a sub-millimetre change in initialization, and the independent
reference does not favour the filled variant. Decision: `otsu_fill` stays empty; the option
remains available in `pincram-image` for other data.

## Precision of the atlas masks (2026-10-07)

Hypothesis: pincram needs consistent rather than precise atlas masks, because the vote averages
random errors while reproducing systematic ones; in particular, simplified masks (sulci filled,
as a rapid hand-drawn outline would) should work about as well as detailed ones. Experiment in
`experiments/atlas-perturbation/`: the 100 IXI atlas masks (brain and ICV) were perturbed, the
cache rebuilt, and pincram run with 3 levels on five held-out subjects (m20, m40, m60, m80,
m100), scored by Jaccard against each subject's original masks. Input precision is the Jaccard of
the perturbed atlas masks against the originals.

| Condition | Input Jaccard | Output parenchyma Jaccard | Loss vs control | Transfer ratio | Output ICV Jaccard |
|---|---|---|---|---|---|
| none (control) | 1.000 | 0.9813 ± 0.0033 | | | 0.9647 |
| closing 2 mm | 0.996 | 0.9809 | 0.000 | 0.09 | 0.9640 |
| closing 4 mm | 0.988 | 0.9782 | 0.003 | 0.27 | 0.9616 |
| closing 8 mm | 0.975 | 0.9703 | 0.011 | 0.44 | 0.9640 |
| closing 16 mm | 0.952 | 0.9519 | 0.029 | 0.62 | 0.9553 |
| closing 4 mm + smoothing | 0.977 | 0.9740 | 0.007 | 0.32 | 0.9615 |
| random boundary noise, sd 2 mm | 0.930 | 0.9637 | 0.018 | 0.25 | 0.9542 |
| random boundary noise, sd 4 mm | 0.844 | 0.9358 | 0.046 | 0.29 | 0.9400 |
| dilation 1 mm | 0.962 | 0.9649 | 0.017 | 0.44 | 0.9640 |
| erosion 1 mm | 0.961 | 0.9564 | 0.025 | 0.64 | 0.9413 |

Transfer ratio = output Jaccard loss / input Jaccard loss (mean over targets). Per-target standard
deviations of the loss are 0.001 to 0.008; the ordering of conditions is the same on every target.
Figure: `experiments/atlas-perturbation/results/precision-transfer.png`.

Findings:

* Random, independent errors are damped about fourfold (transfer 0.25 to 0.3), not eliminated.
  The vote averages them, but the selection and the margin masks derived from the fused label
  carry some of the noise into the registrations, and 7 to 18 voters at the final level leave
  residual variance.
* Systematic errors transfer at 0.4 to 0.6, less than the expected 1.0, because the final mask is
  the intersection of the parenchyma vote with the ICV vote and the ICV masks were shifted too;
  erosion costs more than dilation.
* Simplification by closing is nearly free up to 4 mm (loss 0.003, within the control's spread) and
  cheap at 8 mm (0.011), although by 8 mm most sulci are filled. Its transfer ratio rises with the
  radius, because large closings are a consistent outward bias rather than a simplification. The
  ICV output is almost insensitive to closing the atlas masks.
* So the hypothesis holds in a qualified form: consistency matters more than detail, random
  imprecision is forgiven partly, and the cheapest acceptable hand-drawn convention would be an
  outline that follows the brain surface to within about 4 mm, filling sulci, drawn the same way
  for every atlas. Masks drawn with uncorrelated 4 mm sloppiness would cost 0.05 Jaccard.

## HD-BET masks as atlas prime masks (2026-10-08)

Question: do pincram's results improve when the atlas prime (total brain volume) masks, made by an
early pincram version seeded from the Hammers atlas, are replaced by HD-BET 1.1 masks of the same
IXI atlas images (ICV masks unchanged)? Experiment in `experiments/hdbet-atlas/`. HD-BET masks
agree with the original prime masks at Jaccard 0.920 ± 0.008 and are 8.3% ± 1.0% larger, i.e.
they are a consistent, more generous convention. Scored on independent references: total brain
volume on 10 Hammers subjects against the verified `icmasked` masks, ICV on 10 Klasson subjects
against manual ICV masks. Paired, 3 levels each.

| Reference | Original atlas | HD-BET prime masks | Paired difference | Better with HD-BET |
|---|---|---|---|---|
| Hammers TBV, verified (n=10) | 0.9483 | 0.9361 | −0.012 ± 0.009 | 1 of 10 |
| Klasson ICV, manual (n=10) | 0.9464 | 0.9374 | −0.009 ± 0.023 | 3 of 10 |

Output volume relative to the reference, Hammers TBV: 1.002 (original) against 1.052 (HD-BET);
false-positive fraction 0.028 against 0.060, false-negative 0.026 against 0.008. The HD-BET atlas
shifts pincram's output outward by about 5% in volume, which is the atlas convention passing
through to the output, as the perturbation experiment predicts for a systematic change. The ICV
output also grows (volume ratio 1.015 against 1.035), because the final ICV mask is the union of
the parenchyma vote and the ICV vote. Klasson m1 is an outlier for both variants (ICV volume
ratio 1.12 and 1.22; the original ICV mask is 1378 ml and the image field of view includes much
neck).

Decision: keep the original atlas masks. The result does not say HD-BET's masks are worse masks;
it says their convention differs from the verified total-brain references used here, and pincram
reproduces whichever convention its atlas carries. A fair test of HD-BET mask *quality* as atlas
input would first shrink the HD-BET masks to the reference convention (about 1 mm), which is a
small follow-up experiment. Note: all ten Klasson target names (m1, m7, m13, m19, m25, m31, m37,
m43, m49, m55) coincide with IXI atlas entry names, and the regression script at the time left out
any atlas entry whose name matched the target, so each Klasson run used 99 IXI atlases, the
same-named one removed, identically for both variants. The script now only leaves an entry out
when told to (`-leave-out`).

### Addendum: against the target's own HD-BET mask (2026-10-08, rerun)

The 40 runs were repeated with outputs kept, and HD-BET was run on the 20 targets themselves
(`apps/pincram/temp/hdbet-targets/<set>-<target>_mask.nii.gz`). Rerun scores against the
independent references reproduced the first round (Hammers TBV 0.9483 / 0.9361; Klasson ICV
0.9467 / 0.9393). Pairwise Jaccard, mean ± sd over 10 targets; full table in
`experiments/hdbet-atlas/results/pairwise.csv`:

| Compared masks | Hammers (a1, a4, ..., a28) | Klasson (m1, m7, ..., m55) |
|---|---|---|
| pincram parenchyma, original atlas vs verified TBV `icmasked` | 0.948 ± 0.009 | |
| pincram parenchyma, HD-BET atlas vs verified TBV | 0.936 ± 0.008 | |
| HD-BET on the target vs verified TBV | 0.942 ± 0.004 | |
| pincram parenchyma, HD-BET atlas vs HD-BET on the target | 0.963 ± 0.006 | 0.946 ± 0.036 (0.957 without m1) |
| pincram parenchyma, original atlas vs HD-BET on the target | 0.948 ± 0.007 | 0.916 ± 0.006 |
| pincram parenchyma, original vs HD-BET atlas | 0.946 ± 0.006 | 0.929 ± 0.017 |
| HD-BET on the target vs manual ICV `lmasks/icvmasks-manual` | | 0.926 ± 0.012 |
| HD-BET volume / reference volume | 1.040 ± 0.010 (TBV) | 0.955 ± 0.014 (ICV) |

Reading: with the convention held fixed, pincram propagating HD-BET atlas masks agrees with
HD-BET's own output on the target at 0.963, better than either agrees with the verified TBV
masks (0.936 and 0.942). So the propagation machinery reproduces whatever convention the atlas
carries, with a residual of about 0.04 Jaccard that is the method's own imprecision. HD-BET's
convention sits between the verified TBV (4% smaller) and the manual ICV (4.5% larger). HD-BET
run directly on the Hammers targets agrees with the verified TBV masks less well (0.942) than
pincram with the original atlas does (0.948). Klasson m1 is the outlier noted above.

## Refining an input mask (2026-10-08)

`pincram.sh -mask` (README, "Refining an existing mask") replaces the coarse level by a
`prealigned` level: the atlases are transformed with their normalization only, then ranked
within the input mask's margin. The input mask then steers the affine registrations. With
`-mask`, the pre-alignment uses the atlas reference brain-mask distance map instead of the
Otsu head masks. `-refine-band W` keeps the input mask outside a band of W mm around its
boundary. Experiment: `experiments/mask-refine` (10 Hammers targets, IXI 100-atlas database,
3 levels). Every Jaccard below compares pincram's `parenchyma.nii.gz` (or the named mask) with
the verified TBV mask, binarized
`shared/reference/atlases-hammers-scaled-with-flipped-n60/icmasked/aN.nii.gz`.

| input mask | input vs TBV | output vs TBV | paired diff. to plain | output vs plain output | wall time (32 CPUs) |
|---|---|---|---|---|---|
| none (plain pincram) | | 0.9483 | | | 352 s |
| HD-BET on target (`apps/pincram/temp/hdbet-targets/hammers-aN_mask.nii.gz`) | 0.942 | 0.9483 | +0.0001 ± 0.0030 (5/10 better) | 0.980 | 300 s |
| TBV eroded 3 mm | 0.723 | 0.9503 | +0.0020 ± 0.0058 (5/10) | 0.979 | 306 s |
| TBV random boundary, sd 3 mm | 0.841 | 0.9500 | +0.0017 ± 0.0062 (6/10) | 0.980 | 306 s |
| TBV dilated 3 mm | 0.841 | 0.9365 | -0.0117 ± 0.0310 (2/10) | 0.964 | 296 s |

Recovery without a band is nearly complete. Inputs at 0.72-0.84 Jaccard come out at plain
pincram's accuracy. The output agrees with the plain output at 0.98, about as well as two
plain runs with different initializations. Unlike atlas masks (previous section), the input
mask does not impose its convention: the HD-BET input moves the result by +0.0001. Skipping the
100 coarse registrations saves 15% of the wall time. The one failure is a22 with the dilated
input: output 0.856, against 0.954 for plain pincram.
There, the brain-mask pre-alignment ended in a poor position (reference brain mask mapped onto
the target: 0.593 vs TBV), and the normalization-only level-0 fusion reached only 0.53. With
no coarse registrations to correct it, the affine level recovered only partly (0.77). Excluding
a22, the dilated input is within 0.002 of plain.

Pre-alignment, measured directly (`prealign.sh`, `results/prealign.csv`): the IXI reference
brain mask mapped onto each target, Jaccard vs TBV, mean over 10 targets. After the distance-map
step: Otsu head masks 0.590, brain-mask distance maps 0.632 (any input mask). After the intensity
refinement that pincram applies next: Otsu 0.744, brain masks 0.739-0.758, with no consistent
winner (5-7 of 10 better). So the brain-mask distance maps are the better first step, but the
end result is equivalent. On both paths the SSD distance-map registration stops after very few
iterations (a22: two iterations, energy 1.000 to 0.997), and the outcome depends mainly on whether
the intensity step escapes from there. Prealigned-level fusions (normalization only) reach
0.55-0.82 vs TBV, against 0.89-0.92 after coarse registration in plain pincram. The affine level
usually makes up the difference.

`-refine-band`, applied post hoc to the no-band outputs (in-pipeline `-refine-band 4` matched it
exactly on all 10 targets):

| input mask | band 2 mm | band 4 mm | band 8 mm | no band |
|---|---|---|---|---|
| HD-BET | 0.9500 | 0.9492 | 0.9484 | 0.9483 |
| TBV eroded 3 mm | 0.8764 | 0.9553 | 0.9505 | 0.9503 |
| TBV dilated 3 mm | 0.9131 | 0.9522 | 0.9397 | 0.9365 |
| TBV random 3 mm | 0.9085 | 0.9446 | 0.9500 | 0.9500 |

A band narrower than the input's error locks the error in (2 mm on 3 mm shifts). A band just
wider than a uniform shift scores above plain pincram, but that is circular: the protected core
and hull come from the reference mask. With the independent HD-BET input, the band adds
+0.0009 (4 mm) to +0.0017 (2 mm), within the noise noted in the cavity experiment.

Decision: `-mask` is useful as a faster route to plain pincram's accuracy when a reasonable mask
exists. It is not a way to transfer another tool's convention. `-refine-band` is for inputs
whose error is known to be smaller than the band. Open (see `docs/ideas.md`): a more robust start for mask mode,
e.g. a coarse registration of the brain-mask distance maps per atlas, or the coarse level
masked by the input mask, would remove the pre-alignment failure seen on a22.
