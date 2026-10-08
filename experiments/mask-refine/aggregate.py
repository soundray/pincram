#!/usr/bin/env python3
"""aggregate.py EXP OUTDIR -- score the mask refinement runs

For every target and condition under EXP (see run-target.sh): Jaccard of the input mask and of
pincram's parenchyma output with the verified TBV mask (EXP/inputs/tbv-<t>.nii.gz, binarized
Hammers icmasked/<t>), the agreement of the output with the plain run's output, and the wall time.
For conditions without a band, the band refinement is also applied post hoc to the output for
several widths (it is a deterministic final step, see pincram.sh); the <cond>-bandW runs check
that the in-pipeline -refine-band agrees with it. Writes OUTDIR/results.csv and OUTDIR/summary.md.
"""

import csv
import os
import re
import sys

import nibabel as nib
import numpy as np
from scipy import ndimage

BANDS = (2, 4, 8)
HDBET = os.environ.get("HDBET", os.path.join(os.path.dirname(__file__), "../../temp/hdbet-targets"))


def load(path):
    img = nib.load(path)
    d = np.asanyarray(img.dataobj)
    while d.ndim > 3 and d.shape[-1] == 1:
        d = d[..., 0]
    return d > 0.5, np.array(img.header.get_zooms()[:3], dtype=float)


def jaccard(a, b):
    return (a & b).sum() / (a | b).sum()


def refine(label, inmask, zooms, width):
    sd = ndimage.distance_transform_edt(inmask, sampling=zooms) - ndimage.distance_transform_edt(~inmask, sampling=zooms)
    return np.where(sd > width, True, np.where(sd < -width, False, label))


def elapsed(path):
    with open(path) as f:
        for row in csv.DictReader(f):
            if row["level"] == "3":
                return int(row["elapsed_s"])
    return None


def main(exp, outdir):
    os.makedirs(outdir, exist_ok=True)
    def runs(c):
        d = os.path.join(exp, c)
        return [t for t in os.listdir(d) if re.fullmatch(r"a[0-9]+", t)] if os.path.isdir(d) and c not in ("inputs", "wd") else []
    conds = sorted(c for c in os.listdir(exp) if runs(c))
    targets = sorted({t for c in conds for t in runs(c)}, key=lambda t: int(t[1:]))
    rows = []
    for t in targets:
        ref, zooms = load(os.path.join(exp, "inputs", f"tbv-{t}.nii.gz"))
        plain_path = os.path.join(exp, "plain", t, "level3", "parenchyma.nii.gz")
        plain = load(plain_path)[0] if os.path.exists(plain_path) else None
        for c in conds:
            out_path = os.path.join(exp, c, t, "level3", "parenchyma.nii.gz")
            if not os.path.exists(out_path):
                continue
            out = load(out_path)[0]
            base = c.split("-band")[0]
            band = c.split("-band")[1] if "-band" in c else ""
            inmask = None
            if base == "hdbet":
                inmask = load(os.path.join(HDBET, f"hammers-{t}_mask.nii.gz"))[0]
            elif base != "plain":
                inmask = load(os.path.join(exp, "inputs", f"{base}-{t}.nii.gz"))[0]
            row = dict(target=t, condition=c, band_mm=band, posthoc="",
                       input_vs_tbv=f"{jaccard(inmask, ref):.6f}" if inmask is not None else "",
                       output_vs_tbv=f"{jaccard(out, ref):.6f}",
                       output_vs_plain=f"{jaccard(out, plain):.6f}" if plain is not None else "",
                       output_vs_input=f"{jaccard(out, inmask):.6f}" if inmask is not None else "",
                       elapsed_s=elapsed(os.path.join(exp, c, t, "results.csv")))
            rows.append(row)
            if inmask is not None and not band:
                for w in BANDS:
                    r = refine(out, inmask, zooms, w)
                    rows.append(dict(row, condition=f"{c}-band{w}", band_mm=str(w), posthoc="yes",
                                     output_vs_tbv=f"{jaccard(r, ref):.6f}",
                                     output_vs_plain=f"{jaccard(r, plain):.6f}" if plain is not None else "",
                                     output_vs_input=f"{jaccard(r, inmask):.6f}"))
    with open(os.path.join(outdir, "results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    # summary: mean over targets per condition (post-hoc and in-pipeline band rows kept apart)
    def key(r):
        return (r["condition"], r["posthoc"])
    groups = {}
    for r in rows:
        groups.setdefault(key(r), []).append(r)
    plain_by_t = {r["target"]: float(r["output_vs_tbv"]) for r in rows if r["condition"] == "plain"}
    lines = ["Jaccard means over targets. Masks compared: input = the input mask given to pincram -mask;",
             "output = pincram's parenchyma.nii.gz; TBV = verified total brain volume, binarized",
             "shared/reference/atlases-hammers-scaled-with-flipped-n60/icmasked/<t>.nii.gz; plain = pincram",
             "output without -mask. Post-hoc rows apply the refine-band step to the no-band output.", "",
             "| condition | band | n | input vs TBV | output vs TBV | output - plain (vs TBV), paired | better than plain | output vs plain | output vs input | time (s) |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    order = sorted(groups, key=lambda k: (k[0].split("-band")[0] != "plain", k[0].split("-band")[0], k[1] == "", int(k[0].split("-band")[1]) if "-band" in k[0] else 0))
    for k in order:
        g = groups[k]
        def mean(field):
            v = [float(r[field]) for r in g if r[field] not in ("", None)]
            return f"{np.mean(v):.4f}" if v else ""
        d = [float(r["output_vs_tbv"]) - plain_by_t[r["target"]] for r in g if r["target"] in plain_by_t]
        diff = f"{np.mean(d):+.4f} ± {np.std(d, ddof=1):.4f}" if len(d) > 1 and k[0] != "plain" else (f"{d[0]:+.4f}" if d and k[0] != "plain" else "")
        better = f"{sum(x > 0 for x in d)}/{len(d)}" if k[0] != "plain" else ""
        times = [r["elapsed_s"] for r in g if r["elapsed_s"] and not r["posthoc"]]
        band = g[0]["band_mm"] + (" (post hoc)" if k[1] else "")
        lines.append(f"| {k[0].split('-band')[0]} | {band} | {len(g)} | {mean('input_vs_tbv')} | {mean('output_vs_tbv')} | {diff} | {better} | "
                     f"{mean('output_vs_plain')} | {mean('output_vs_input')} | {np.mean(times):.0f} |" if times else
                     f"| {k[0].split('-band')[0]} | {band} | {len(g)} | {mean('input_vs_tbv')} | {mean('output_vs_tbv')} | {diff} | {better} | "
                     f"{mean('output_vs_plain')} | {mean('output_vs_input')} | |")
    # in-pipeline band vs post hoc on the corresponding no-band run
    checks = []
    for r in rows:
        if r["band_mm"] and not r["posthoc"]:
            twin = [p for p in rows if p["posthoc"] and p["target"] == r["target"] and p["condition"] == r["condition"]]
            if twin:
                checks.append(float(r["output_vs_tbv"]) - float(twin[0]["output_vs_tbv"]))
    if checks:
        lines += ["", f"In-pipeline -refine-band minus post hoc on the separate no-band run (output vs TBV): "
                  f"mean {np.mean(checks):+.4f}, max |d| {np.max(np.abs(checks)):.4f} (n={len(checks)})"]
    with open(os.path.join(outdir, "summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
