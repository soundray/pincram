#!/usr/bin/env python3
"""Unit and equivalence tests for pincram-image.

Builds small random NIfTI images, runs every pincram-image operation and compares the result
with a numpy reference. If seg_maths (NiftySeg) is on the PATH, the result is also compared
with the seg_maths chain that pincram used before, which pins the semantics of the port.
Run: python3 tests/image-unit.py   (needs numpy, scipy, nibabel)
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import nibabel as nib
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(os.path.dirname(HERE), "pincram-image")
SEG_MATHS = shutil.which("seg_maths")


def run(*args):
    subprocess.run([str(a) for a in args], check=True, stdout=subprocess.DEVNULL)


class ImageOps(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="pincram-image-test.")
        rng = np.random.default_rng(7)
        cls.affine = np.diag([1.2, 0.9375, 0.9375, 1.0])
        cls.shape = (12, 14, 10)
        # signed "distance map" like masks in [-20, 20] with some exact zeros, and an intensity image
        cls.masks = []
        for i in range(5):
            m = rng.uniform(-20, 20, cls.shape)
            m[rng.random(cls.shape) < 0.05] = 0.0
            cls.masks.append(m.astype(np.float32))
        cls.img = (rng.uniform(0, 3000, cls.shape)).astype(np.float32)
        cls.img[:4] = rng.uniform(0, 50, cls.img[:4].shape)  # a "background" slab for Otsu
        cls.paths = [cls.save(m, f"m{i}.nii.gz") for i, m in enumerate(cls.masks)]
        cls.img_path = cls.save(cls.img, "img.nii.gz")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir)

    @classmethod
    def save(cls, data, name):
        path = os.path.join(cls.dir, name)
        nib.Nifti1Image(data, cls.affine).to_filename(path)
        return path

    def out(self, name):
        return os.path.join(self.dir, name)

    def read(self, path):
        return np.asanyarray(nib.load(path).dataobj).astype(np.float64)

    def check(self, path, expected, atol=1e-5):
        got = self.read(path)
        self.assertEqual(got.shape, expected.shape)
        np.testing.assert_allclose(got, expected, atol=atol, rtol=0)
        hdr = nib.load(path).header
        self.assertEqual(hdr.get_data_dtype(), np.float32)
        np.testing.assert_allclose(nib.load(path).affine, self.affine)

    def seg(self, out, *chain):
        if SEG_MATHS is None:
            return None
        run(SEG_MATHS, *chain, out)
        return self.read(out)

    def test_mean(self):
        run(TOOL, "mean", self.out("mean.nii.gz"), *self.paths)
        expected = np.mean([m.astype(np.float64) for m in self.masks], axis=0)
        self.check(self.out("mean.nii.gz"), expected)
        chain = [self.paths[0]]
        for p in self.paths[1:]:
            chain += ["-add", p]
        ref = self.seg(self.out("mean-seg.nii.gz"), *chain, "-div", len(self.paths))
        if ref is not None:
            np.testing.assert_allclose(self.read(self.out("mean.nii.gz")), ref, atol=1e-4, rtol=0)

    def test_weighted_sum(self):
        weights = [0.9, 0.5, 0.0, 0.25, 1.0]
        pairs = [x for pw in zip(self.paths, weights) for x in pw]
        run(TOOL, "weighted-sum", self.out("ws.nii.gz"), *pairs)
        expected = sum(w * m.astype(np.float64) for w, m in zip(weights, self.masks))
        self.check(self.out("ws.nii.gz"), expected, atol=1e-4)
        run(TOOL, "weighted-sum", self.out("wsn.nii.gz"), "-normalize", *pairs)
        self.check(self.out("wsn.nii.gz"), expected / sum(weights), atol=1e-4)
        if SEG_MATHS:
            parts = []
            for p, w in zip(self.paths, weights):
                q = self.out(f"w-{os.path.basename(p)}")
                run(SEG_MATHS, p, "-mul", w, q)
                parts.append(q)
            chain = [parts[0]]
            for q in parts[1:]:
                chain += ["-add", q]
            ref = self.seg(self.out("ws-seg.nii.gz"), *chain)
            np.testing.assert_allclose(self.read(self.out("ws.nii.gz")), ref, atol=1e-3, rtol=0)
            ref = self.seg(self.out("wsn-seg.nii.gz"), self.out("ws-seg.nii.gz"), "-div", sum(weights))
            np.testing.assert_allclose(self.read(self.out("wsn.nii.gz")), ref, atol=1e-3, rtol=0)

    def test_band(self):
        run(TOOL, "band", self.out("band.nii.gz"), self.paths[0], 7)
        a = np.abs(self.masks[0].astype(np.float64))
        self.check(self.out("band.nii.gz"), ((a > 0) & (a <= 7)).astype(float))
        ref = self.seg(self.out("band-seg.nii.gz"), self.paths[0], "-abs", "-uthr", 7, "-bin")
        if ref is not None:
            np.testing.assert_array_equal(self.read(self.out("band.nii.gz")), ref)

    def test_binarize(self):
        run(TOOL, "binarize", self.out("bin.nii.gz"), self.paths[1])
        self.check(self.out("bin.nii.gz"), (self.masks[1] > 0).astype(float))
        ref = self.seg(self.out("bin-seg.nii.gz"), self.paths[1], "-thr", 0, "-bin")
        if ref is not None:
            np.testing.assert_array_equal(self.read(self.out("bin.nii.gz")), ref)

    def test_crop(self):
        run(TOOL, "crop", self.out("crop.nii.gz"), self.img_path, self.paths[2], 7)
        a = np.abs(self.masks[2].astype(np.float64))
        expected = np.where((a > 0) & (a <= 7), self.img.astype(np.float64), 0.0)
        self.check(self.out("crop.nii.gz"), expected, atol=1e-3)
        ref = self.seg(self.out("crop-seg.nii.gz"), self.paths[2], "-abs", "-uthr", 7, "-bin", "-mul", self.img_path)
        if ref is not None:
            np.testing.assert_allclose(self.read(self.out("crop.nii.gz")), ref, atol=1e-3, rtol=0)

    def test_icv_vote(self):
        run(TOOL, "icv-vote", self.out("icv.nii.gz"), *self.paths[:3])
        acc = sum(2 * m.astype(np.float64) - 1 for m in self.masks[:3])
        self.check(self.out("icv.nii.gz"), (acc / 3 > 0).astype(float))
        if SEG_MATHS:
            acc_path = self.out("icv-sum-seg.nii.gz")
            run(SEG_MATHS, self.paths[0], "-add", 1, "-mul", 2, "-sub", 3, acc_path)
            for p in self.paths[1:3]:
                run(SEG_MATHS, p, "-add", 1, "-mul", 2, "-sub", 3, "-add", acc_path, acc_path)
            ref = self.seg(self.out("icv-seg.nii.gz"), acc_path, "-div", 3, "-thr", 0, "-bin")
            np.testing.assert_array_equal(self.read(self.out("icv.nii.gz")), ref)

    def test_and_or(self):
        run(TOOL, "binarize", self.out("a.nii.gz"), self.paths[0])
        run(TOOL, "binarize", self.out("b.nii.gz"), self.paths[1])
        a, b = self.masks[0] > 0, self.masks[1] > 0
        run(TOOL, "and", self.out("and.nii.gz"), self.out("a.nii.gz"), self.out("b.nii.gz"))
        run(TOOL, "or", self.out("or.nii.gz"), self.out("a.nii.gz"), self.out("b.nii.gz"))
        self.check(self.out("and.nii.gz"), (a & b).astype(float))
        self.check(self.out("or.nii.gz"), (a | b).astype(float))
        if SEG_MATHS:
            ref = self.seg(self.out("and-seg.nii.gz"), self.out("a.nii.gz"), "-mul", self.out("b.nii.gz"))
            np.testing.assert_array_equal(self.read(self.out("and.nii.gz")), ref)
            ref = self.seg(self.out("or-seg.nii.gz"), self.out("a.nii.gz"), "-add", self.out("b.nii.gz"), "-bin")
            np.testing.assert_array_equal(self.read(self.out("or.nii.gz")), ref)

    def test_smooth_otsu(self):
        run(TOOL, "smooth-otsu", self.out("otsu.nii.gz"), self.img_path, 1.5)
        got = self.read(self.out("otsu.nii.gz"))
        self.assertTrue(set(np.unique(got)) <= {0.0, 1.0})
        # the low-intensity slab must be background, the rest mostly foreground
        self.assertEqual(got[:3].sum(), 0)
        self.assertGreater(got[5:].mean(), 0.9)
        ref = self.seg(self.out("otsu-seg.nii.gz"), self.img_path, "-smo", 1.5, "-otsu")
        if ref is not None:
            ref = ref > 0
            dice = 2 * np.logical_and(got > 0, ref).sum() / (got.sum() + ref.sum())
            self.assertGreater(dice, 0.97, f"Dice against seg_maths {dice:.4f}")

    def test_smooth_otsu_fill(self):
        """-fill removes enclosed cavities and detached blobs; -fill R also closes narrow gaps."""
        img = np.full(self.shape, 2000.0, dtype=np.float32)
        img[:4] = 10.0                 # background slab
        img[6:8, 6:8, 4:6] = 10.0      # an enclosed dark cavity
        img[1, 1, 1] = 3000.0          # a detached bright voxel in the background
        path = self.save(img, "fillimg.nii.gz")
        run(TOOL, "smooth-otsu", self.out("nofill.nii.gz"), path, 0)
        run(TOOL, "smooth-otsu", self.out("fill.nii.gz"), path, 0, "-fill")
        nofill, fill = self.read(self.out("nofill.nii.gz")), self.read(self.out("fill.nii.gz"))
        self.assertEqual(nofill[6:8, 6:8, 4:6].sum(), 0)          # cavity is open before
        self.assertEqual(fill[6:8, 6:8, 4:6].sum(), 8)            # and filled after
        self.assertEqual(nofill[1, 1, 1], 1)                      # blob present before
        self.assertEqual(fill[1, 1, 1], 0)                        # removed after
        self.assertEqual(fill[4:].sum(), fill.sum())              # nothing added in the background slab
        img[6:8, 6:8, 0:6] = 10.0      # cavity opened to the surface: a narrow channel
        path = self.save(img, "channel.nii.gz")
        run(TOOL, "smooth-otsu", self.out("fill0.nii.gz"), path, 0, "-fill")
        run(TOOL, "smooth-otsu", self.out("fill2.nii.gz"), path, 0, "-fill", 2)
        self.assertEqual(self.read(self.out("fill0.nii.gz"))[6:8, 6:8, 4:6].sum(), 0)   # not enclosed: not filled
        self.assertEqual(self.read(self.out("fill2.nii.gz"))[6:8, 6:8, 4:6].sum(), 8)   # closed by radius 2, then filled

    def test_singleton_fourth_dimension(self):
        """Atlas distance maps may be stored as 4D with one volume; they must combine with 3D images."""
        path4d = os.path.join(self.dir, "m4d.nii.gz")
        nib.Nifti1Image(self.masks[0][..., np.newaxis], self.affine).to_filename(path4d)
        self.assertEqual(nib.load(path4d).shape, self.shape + (1,))
        run(TOOL, "crop", self.out("crop4d.nii.gz"), self.img_path, path4d, 7)
        a = np.abs(self.masks[0].astype(np.float64))
        self.check(self.out("crop4d.nii.gz"), np.where((a > 0) & (a <= 7), self.img.astype(np.float64), 0.0), atol=1e-3)
        self.assertEqual(nib.load(self.out("crop4d.nii.gz")).shape, self.shape)
        run(TOOL, "mean", self.out("mean4d.nii.gz"), path4d, self.paths[1])
        self.assertEqual(nib.load(self.out("mean4d.nii.gz")).shape, self.shape)

    def test_errors(self):
        for args in (["band", self.out("x.nii.gz"), self.paths[0]],
                     ["mean", self.out("x.nii.gz")],
                     ["nonsense", self.out("x.nii.gz"), self.paths[0]],
                     ["crop", self.out("x.nii.gz"), self.img_path, self.paths[0], "wide"]):
            r = subprocess.run([TOOL] + args, capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0, args)
            self.assertIn("pincram-image:", r.stderr)


if __name__ == "__main__":
    print("seg_maths equivalence:", "enabled" if SEG_MATHS else "skipped (seg_maths not on PATH)")
    unittest.main(verbosity=1)
