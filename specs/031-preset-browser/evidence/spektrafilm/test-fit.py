"""Mathematical regression for the fixed-face dense-reference atlas fitter."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest

import numpy as np
from scipy.interpolate import RegularGridInterpolator

ROOT = Path(__file__).resolve().parents[4]
spec = spec_from_file_location("film_bake", ROOT / "scripts/bake-spektrafilm-filters.py")
bake = module_from_spec(spec)
spec.loader.exec_module(bake)


class SpektrafilmAtlasFitTests(unittest.TestCase):
    def grid(self):
        return np.stack(np.meshgrid(*([np.linspace(0, 1, 127)] * 3), indexing="ij"), axis=-1)

    @staticmethod
    def curved(points):
        b, g, r = (points[..., c] for c in range(3))
        return np.stack((0.12 * r * r + 0.06 * b * g,
                         -0.08 * g * g + 0.02 * r * b,
                         0.1 * b * b - 0.04 * r * g), axis=-1)

    def testTrilinearFieldIsUnchangedByDenseFit(self):
        points = self.grid()
        b, g, r = (points[..., c] for c in range(3))
        dense = np.stack((0.02 * r * g + 0.03 * b,
                          -0.01 * g * b + 0.04 * r,
                          0.02 * r * b * g), axis=-1)
        fitted = bake.fit_delta(dense)
        np.testing.assert_allclose(fitted, dense[::2, ::2, ::2], rtol=0, atol=1e-14)

    def testCurvedFieldImprovesIndependentSamplesAndPreservesEveryCubeFace(self):
        dense = self.curved(self.grid())
        original = dense[::2, ::2, ::2]
        fitted = bake.fit_delta(dense)
        self.assertTrue(np.isfinite(fitted).all())
        for axis in range(3):
            for index in (0, 63):
                np.testing.assert_array_equal(np.take(fitted, index, axis=axis),
                                              np.take(original, index, axis=axis))
        points = np.random.default_rng(42).random((20000, 3))
        axes = (np.linspace(0, 1, 64),) * 3
        expected = self.curved(points)
        direct = RegularGridInterpolator(axes, original)(points)
        adjusted = RegularGridInterpolator(axes, fitted)(points)
        self.assertLess(np.mean((adjusted - expected) ** 2), np.mean((direct - expected) ** 2))


if __name__ == "__main__":
    unittest.main()
