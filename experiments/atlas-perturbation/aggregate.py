#!/usr/bin/env python3
"""aggregate.py EXPDIR -- collect perturbation statistics and pincram results into results.csv and summary.md"""

import csv
import glob
import os
import statistics
import sys

exp = sys.argv[1]
order = ["none", "close2", "close4", "close8", "close16", "close4smooth", "random2", "random4", "dilate1", "erode1"]
rows = []
for cond in order:
    stats = {"brainmasks": [], "icvmasks": []}
    for r in csv.DictReader(open(os.path.join(exp, cond, "atlas", "perturb-stats.csv"))):
        if "jaccard" not in r:                       # stats written before the switch from Dice
            d = float(r["dice"]) ; r["jaccard"] = f"{d / (2 - d):.5f}"
        stats[r["mask"].split("/")[0]].append(r)
    for res in sorted(glob.glob(os.path.join(exp, cond, "m*", "results.csv"))):
        target = os.path.basename(os.path.dirname(res))
        vals = {r["metric"]: (float(r["value"]), int(r["elapsed_s"])) for r in csv.DictReader(open(res))}
        si = ""
        sipath = os.path.join(exp, cond, target, "si.csv")
        if os.path.exists(sipath):
            si = open(sipath).read().strip().split(",")[-1]
        rows.append({"condition": cond, "target": target,
                     "parenchyma_jaccard": vals["parenchyma_jaccard"][0], "icv_jaccard": vals["icv_jaccard"][0],
                     "si": si, "elapsed_s": vals["parenchyma_jaccard"][1],
                     "atlas_brain_jaccard": statistics.mean(float(r["jaccard"]) for r in stats["brainmasks"]),
                     "atlas_brain_volume_ratio": statistics.mean(float(r["volume_ratio"]) for r in stats["brainmasks"]),
                     "atlas_brain_msd_mm": statistics.mean(float(r["mean_surface_distance_mm"]) for r in stats["brainmasks"]),
                     "atlas_icv_jaccard": statistics.mean(float(r["jaccard"]) for r in stats["icvmasks"])})
with open(os.path.join(exp, "results.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader(); w.writerows(rows)

lines = ["| condition | atlas brain Jaccard vs original | atlas volume ratio | atlas surface dist (mm) | output parenchyma Jaccard (mean ± sd, n) | output ICV Jaccard (mean ± sd) |",
         "|---|---|---|---|---|---|"]
for cond in order:
    rs = [r for r in rows if r["condition"] == cond]
    if not rs:
        continue
    pj = [r["parenchyma_jaccard"] for r in rs]; ij = [r["icv_jaccard"] for r in rs]
    sd = lambda v: statistics.stdev(v) if len(v) > 1 else 0.0
    lines.append(f"| {cond} | {rs[0]['atlas_brain_jaccard']:.3f} | {rs[0]['atlas_brain_volume_ratio']:.3f} | {rs[0]['atlas_brain_msd_mm']:.2f} | "
                 f"{statistics.mean(pj):.4f} ± {sd(pj):.4f} (n={len(pj)}) | {statistics.mean(ij):.4f} ± {sd(ij):.4f} |")
open(os.path.join(exp, "summary.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
