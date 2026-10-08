#!/usr/bin/env python3
"""degrade.py -- make a deliberately degraded input mask from a reference brain mask

Usage: degrade.py CONDITION REF OUT

Conditions (mm are physical distances; voxel sizes are read from the header):
  erodeN / dilateN  uniform boundary shift by N mm inwards / outwards (systematic error)
  randomN           zero-mean random boundary displacement with standard deviation N mm and
                    correlation length 5 mm, seeded from the output file name

OUT is written as uint8 0/1 with the header of REF.
"""

import hashlib
import os
import re
import sys

import nibabel as nib
import numpy as np
from scipy import ndimage


def signed_distance(mask, zooms):
    """Positive inside, negative outside, in mm."""
    return ndimage.distance_transform_edt(mask, sampling=zooms) - ndimage.distance_transform_edt(~mask, sampling=zooms)


def main(condition, ref, out):
    img = nib.load(ref)
    data = np.asanyarray(img.dataobj)
    while data.ndim > 3 and data.shape[-1] == 1:
        data = data[..., 0]
    mask = data > 0.5
    zooms = np.array(img.header.get_zooms()[:3], dtype=float)
    m = re.fullmatch(r"(erode|dilate|random)([0-9.]+)", condition)
    if not m:
        sys.exit(f"degrade.py: unknown condition {condition}")
    kind, amount = m.group(1), float(m.group(2))
    sd = signed_distance(mask, zooms)
    if kind == "erode":
        result = sd > amount
    elif kind == "dilate":
        result = sd > -amount
    else:
        seed = int(hashlib.sha256(os.path.basename(out).encode()).hexdigest()[:8], 16)
        field = ndimage.gaussian_filter(np.random.default_rng(seed).standard_normal(mask.shape), sigma=5.0 / zooms)
        band = np.abs(sd) < 10.0                       # normalize the field where it matters
        result = sd + field / field[band].std() * amount > 0
    header = img.header.copy()
    header.set_data_dtype(np.uint8)
    header.set_slope_inter(1.0, 0.0)
    nib.Nifti1Image(result.astype(np.uint8), img.affine, header).to_filename(out)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
