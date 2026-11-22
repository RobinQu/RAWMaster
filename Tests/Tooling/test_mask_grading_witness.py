import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/performance"))
import mask_grading_witness as witness


class LocalGradingWitnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / "docs/research/camera-raw-parity/evidence/history/camera-raw-grading-mask-exclusive-first-metric.json"
        cls.rows = json.loads(path.read_bytes())["operations"]["grading-mask-wheels"]["samples"]

    def test_real_session_requalifies_independent_pairs_and_outside(self):
        result = witness.verify(self.rows)
        self.assertTrue(result["qualified"])
        self.assertEqual(result["heldOutPairs"], 3)
        self.assertEqual(result["center"], {"calibratedTiles": 18, "verifiedTiles": 18, "qualified": True})
        self.assertEqual(result["regions"]["outside"]["identical"], 108)

    def test_unchanged_data_cannot_qualify(self):
        rows = copy.deepcopy(self.rows)
        for control, edit in zip(rows[::2], rows[1::2]):
            edit["maskPixelGrid"] = copy.deepcopy(control["maskPixelGrid"])
        self.assertFalse(witness.verify(rows)["qualified"])

    def test_global_change_cannot_qualify_with_correct_center(self):
        rows = copy.deepcopy(self.rows)
        for edit in rows[1::2]:
            site = next(p for p in edit["maskPixelGrid"] if p["region"] == "outside")
            site["rgb"][0] ^= 8
        self.assertFalse(witness.verify(rows)["qualified"])

    def test_calibration_pair_cannot_qualify_failed_repetitions(self):
        rows = copy.deepcopy(self.rows)
        rows[5]["maskPixelGrid"] = copy.deepcopy(rows[4]["maskPixelGrid"])
        self.assertEqual(witness.verify(rows)["center"]["verifiedTiles"], 0)

    def test_spatial_or_histogram_drift_cannot_qualify(self):
        for key in ("histogramSHA256", "spatialRGBSHA256"):
            with self.subTest(key=key):
                rows = copy.deepcopy(self.rows)
                rows[3][key] = hashlib.sha256(b"drift").hexdigest()
                self.assertFalse(witness.verify(rows)["qualified"])

    def test_wrong_grid_and_sample_order_fail(self):
        rows = copy.deepcopy(self.rows)
        rows[0], rows[1] = rows[1], rows[0]
        with self.assertRaises(ValueError):
            witness.verify(rows)
        rows = copy.deepcopy(self.rows)
        rows[0]["maskPixelGrid"][0]["xy"] = rows[0]["maskPixelGrid"][1]["xy"]
        with self.assertRaises(ValueError):
            witness.verify(rows)


if __name__ == "__main__":
    unittest.main()
