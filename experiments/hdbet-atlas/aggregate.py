#!/usr/bin/env python3
"""aggregate.py EXPDIR -- collect results of the HD-BET atlas experiment into results.csv and summary.md"""
import csv, glob, os, statistics, sys
exp = sys.argv[1]
rows = []
for res in sorted(glob.glob(os.path.join(exp, "*", "*", "*", "results.csv"))):
    variant, refset, target = res.split(os.sep)[-4:-1]
    vals = {r["metric"]: float(r["value"]) for r in csv.DictReader(open(res))}
    rows.append({"variant": variant, "refset": refset, "target": target,
                 "parenchyma_jaccard": vals.get("parenchyma_jaccard", ""), "icv_jaccard": vals.get("icv_jaccard", "")})
with open(os.path.join(exp, "results.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
lines = ["| reference set | metric | original atlas | HD-BET prime masks | difference (paired mean ± sd, n) |", "|---|---|---|---|---|"]
for refset, metric, label in (("hammers", "parenchyma_jaccard", "TBV vs verified icmasked"), ("klasson", "icv_jaccard", "ICV vs manual"), ("klasson", "parenchyma_jaccard", "parenchyma vs lmasks2 (indicative)")):
    a = {r["target"]: r[metric] for r in rows if r["variant"] == "original" and r["refset"] == refset and r[metric] != ""}
    b = {r["target"]: r[metric] for r in rows if r["variant"] == "hdbet" and r["refset"] == refset and r[metric] != ""}
    common = sorted(set(a) & set(b))
    if not a and not b: continue
    ma = statistics.mean(a.values()) if a else float("nan"); mb = statistics.mean(b.values()) if b else float("nan")
    if common:
        d = [b[t] - a[t] for t in common]
        diff = f"{statistics.mean(d):+.4f} ± {statistics.stdev(d) if len(d) > 1 else 0:.4f} (n={len(d)})"
    else:
        diff = f"(original n={len(a)}, hdbet n={len(b)})"
    lines.append(f"| {refset} | {label} | {ma:.4f} | {mb:.4f} | {diff} |")
open(os.path.join(exp, "summary.md"), "w").write("\n".join(lines) + "\n"); print("\n".join(lines))
