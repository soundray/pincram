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
