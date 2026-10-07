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
