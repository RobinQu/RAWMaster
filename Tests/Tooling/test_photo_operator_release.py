import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_readback", ROOT / "scripts/check-display-readback.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
BASELINE = ROOT / "docs/research/camera-raw-parity/evidence/rawmaster-photo-operators-v2.json"


class PhotoOperatorReleaseTests(unittest.TestCase):
    def test_first_use_regression_is_detected_with_unchanged_warm_timings(self):
        report = json.loads(BASELINE.read_bytes())
        with tempfile.TemporaryDirectory() as scratch:
            current = Path(scratch) / "current.json"
            for row in report["operations"]:
                for sample in row["samples"][:2]:
                    for key in ("firstMs", "firstExactFinalMs", "ms"):
                        sample[key] += 1000
            current.write_text(json.dumps(report))
            result = release.check(current, BASELINE)
            self.assertEqual(result["count"], 37)
            self.assertEqual(len(result["failures"]), 3)
            self.assertTrue(all(fail.startswith("firstAppearanceMix/") for fail in result["failures"]))

    def test_no_previous_run_still_validates_all_photo_states(self):
        result = release.check(BASELINE, None)
        self.assertFalse(result["baselineCompared"])
        self.assertEqual(result["count"], 37)
        self.assertEqual(result["failures"], [])
