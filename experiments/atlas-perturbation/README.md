# Atlas mask perturbation experiment

Question: how precise do the atlas masks have to be for pincram to produce precise masks? In
particular, do simplified masks (sulci filled, as a rapid hand-drawn outline would) work as well as
the detailed ones? Hypothesis: random, independent errors average out in the vote, systematic
errors pass straight through, and simplification is mostly systematic.

Design: the 100 IXI atlas masks (brain and ICV) are perturbed with one condition each
(`perturb-masks.py`), the distance-map cache is rebuilt with the same steps as `atlas-gen.sh`
(`build-atlas.sh`), and pincram runs with 3 levels on five held-out atlas subjects (m20, m40,
m60, m80, m100; the target is left out of the atlas), scored by Jaccard against the target's
original, unperturbed masks (`run-condition.sh`, one Slurm job per condition via `submit.sh`).
`aggregate.py` writes `results.csv` and `summary.md`.

Conditions: `none` (rebuild only, checks the pipeline), closing with 2, 4, 8 and 16 mm radius,
closing 4 mm plus boundary smoothing (simplification family); random zero-mean boundary
displacement with 2 and 4 mm standard deviation, independent per mask (random error); uniform
dilation and erosion by 1 mm (systematic error).

Input precision is reported as the mean Jaccard of the perturbed atlas masks against the originals,
the volume ratio and the mean distance of the perturbed boundary to the original boundary (the
`none` row shows the ~1 mm discretization floor of that measure).

Requirements as for the regression test: MIRTK (or `tests/container-bin` with `PINCRAM_SIF`) and
python3 with numpy, scipy and nibabel.
