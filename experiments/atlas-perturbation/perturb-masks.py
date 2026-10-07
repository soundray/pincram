#!/usr/bin/env python3
"""perturb-masks.py -- apply one perturbation condition to a set of binary masks

Usage: perturb-masks.py [-j JOBS] CONDITION OUTDIR STATS.csv MASK...

Conditions (mm refer to physical distances; voxel sizes are read from the headers):
  none           copy (rewritten through the same I/O as the others)
  close2/4/8/16  morphological closing with an ellipsoid of that radius (fills sulci: a rapid outline)
  close4smooth   closing 4 mm, then Gaussian smoothing of the mask (sigma 2 mm) re-thresholded at 0.5
  random2/4      zero-mean random boundary displacement with that standard deviation, correlation
                 length 5 mm, independent per mask (seeded from the file name)
  dilate1/erode1 uniform boundary shift by 1 mm outwards / inwards (systematic bias)

Each output mask is written as float32 0/1 under OUTDIR with the input's base name. One line per
mask is appended to STATS.csv: condition,mask,jaccard,volume_ratio,mean_surface_distance_mm, where
jaccard and the distance compare the perturbed mask with the original.
"""

import csv
import hashlib
import os
import sys

import nibabel as nib
import numpy as np
from scipy import ndimage


def load_mask(path):
    img = nib.load(path)
    data = np.asanyarray(img.dataobj).astype(np.float64)
    while data.ndim > 3 and data.shape[-1] == 1:
        data = data[..., 0]
    return img, data > 0.5, np.array(img.header.get_zooms()[:3], dtype=float)


def signed_distance(mask, zooms):
    """Positive inside, negative outside, in mm."""
    inside = ndimage.distance_transform_edt(mask, sampling=zooms)
    outside = ndimage.distance_transform_edt(~mask, sampling=zooms)
    return inside - outside


def closing(mask, radius_mm, zooms):
    """Euclidean closing (dilation then erosion by radius_mm) via distance transforms: exact for any
    radius and independent of it in cost, unlike a structuring-element closing."""
    dilated = ndimage.distance_transform_edt(~mask, sampling=zooms) <= radius_mm
    return ndimage.distance_transform_edt(dilated, sampling=zooms) >= radius_mm


def random_field(shape, zooms, corr_mm, seed):
    rng = np.random.default_rng(seed)
    noise = rng.standard_normal(shape)
    field = ndimage.gaussian_filter(noise, sigma=corr_mm / zooms)
    return field


def perturb(condition, mask, zooms, seed):
    if condition == "none":
        return mask
    if condition.startswith("close"):
        radius = float(condition.replace("close", "").replace("smooth", ""))
        out = closing(mask, radius, zooms)
        if condition.endswith("smooth"):
            out = ndimage.gaussian_filter(out.astype(np.float64), sigma=2.0 / zooms) > 0.5
        return out
    if condition.startswith("random"):
        amplitude = float(condition.replace("random", ""))
        sd = signed_distance(mask, zooms)
        field = random_field(mask.shape, zooms, 5.0, seed)
        band = np.abs(sd) < 10.0                       # normalize the field where it matters
        field = field / field[band].std() * amplitude
        return sd + field > 0
    if condition in ("dilate1", "erode1"):
        sd = signed_distance(mask, zooms)
        return sd > (-1.0 if condition == "dilate1" else 1.0)
    raise SystemExit(f"perturb-masks.py: unknown condition {condition}")


def stats(original, perturbed, zooms):
    inter = np.logical_and(original, perturbed).sum()
    jaccard = inter / np.logical_or(original, perturbed).sum()
    volume_ratio = perturbed.sum() / original.sum()
    sd = signed_distance(original, zooms)
    boundary = perturbed ^ ndimage.binary_erosion(perturbed)
    msd = np.abs(sd[boundary]).mean() if boundary.any() else float("nan")
    return jaccard, volume_ratio, msd


def process(args):
    condition, outdir, path = args
    img, mask, zooms = load_mask(path)
    seed = int(hashlib.sha256(f"{condition}:{os.path.basename(os.path.dirname(path))}:{os.path.basename(path)}".encode()).hexdigest()[:8], 16)
    out = perturb(condition, mask, zooms, seed)
    header = img.header.copy()
    header.set_data_dtype(np.float32)
    header.set_slope_inter(1.0, 0.0)
    nib.Nifti1Image(out.astype(np.float32), img.affine, header).to_filename(os.path.join(outdir, os.path.basename(path)))
    jaccard, vr, msd = stats(mask, out, zooms)
    return [condition, os.path.basename(os.path.dirname(path)) + "/" + os.path.basename(path), f"{jaccard:.5f}", f"{vr:.5f}", f"{msd:.3f}"]


def main(argv):
    jobs = 1
    if len(argv) > 2 and argv[1] == "-j":
        jobs = int(argv[2])
        argv = argv[:1] + argv[3:]
    if len(argv) < 5:
        sys.stderr.write(__doc__)
        sys.exit(1)
    condition, outdir, statsfile, masks = argv[1], argv[2], argv[3], argv[4:]
    os.makedirs(outdir, exist_ok=True)
    work = [(condition, outdir, path) for path in masks]
    if jobs > 1:
        from multiprocessing import Pool
        with Pool(jobs) as pool:
            rows = pool.map(process, work)
    else:
        rows = [process(w) for w in work]
    new = not os.path.exists(statsfile)
    with open(statsfile, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["condition", "mask", "jaccard", "volume_ratio", "mean_surface_distance_mm"])
        w.writerows(rows)


if __name__ == "__main__":
    main(sys.argv)
