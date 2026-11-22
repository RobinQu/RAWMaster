import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


script = Path(__file__).resolve().parents[2] / "scripts/check-interactive-performance.py"
spec = importlib.util.spec_from_file_location("interactive_checker", script)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class InteractiveQualityGateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.baseline = Path(directory.name) / "old.json"
        self.current = Path(directory.name) / "new.json"
        decoder = "flashraw-0.3.1-linear-srgb-bilinear"
        self.report = {
            "schemaVersion": 1, "build": "release", "canonicalFlashRaw": True, "flashRawAvailable": True,
            "sourceDecoder": decoder, "decoderOverride": False, "proxyVersion": "test", "prewarming": True,
            "sourceSHA256": "a"*64, "sourceSHA256After": "a"*64, "transparentFrameFailures": [],
            "latestFlashRawDecode": {"decoderBackend": "test", "nativeWallMilliseconds": 1, "stages": [{}]*11},
            "measurements": [{"label": op, "width": 2400, "height": 1600, "settledMilliseconds": 100,
                "interactiveMilliseconds": [5, 5, 5], "effectiveDecoder": decoder, "qualityComparison": "matched-pixels",
                "p99ChannelError": 2, "maximumChannelError": 10} for op in checker.OPERATIONS],
        }
        self.baseline.write_text(json.dumps(self.report))

    def compare(self):
        self.current.write_text(json.dumps(self.report))
        return checker.compare(self.baseline, self.current, False, 0.1, 0.2, 50)

    def test_one_code_value_passes_but_two_fail_independently_of_timing(self):
        self.report["measurements"][0]["p99ChannelError"] = 3
        self.assertTrue(self.compare()["passed"])
        self.report["measurements"][0]["p99ChannelError"] = 4
        result = self.compare()
        self.assertEqual(result["operations"][0]["p99ChannelErrorChange"], 2)
        self.assertEqual(result["failures"], ["neutral: p99 channel error rose from 2 to 4 (+2/255)"])

    def test_missing_historical_crop_is_excluded_and_current_missing_is_rejected(self):
        old = copy.deepcopy(self.report)
        crop = next(row for row in old["measurements"] if row["label"] == "geometry")
        del crop["qualityComparison"]
        crop.update(p99ChannelError=-1, maximumChannelError=-1)
        self.baseline.write_text(json.dumps(old))
        result = self.compare()
        self.assertTrue(result["passed"])
        self.assertIsNone(next(row for row in result["operations"] if row["operation"] == "geometry")["p99ChannelErrorChange"])
        self.report["measurements"][0].update(p99ChannelError=-1, maximumChannelError=-1)
        with self.assertRaisesRegex(ValueError, "invalid proxy error evidence"):
            self.compare()

    def test_different_canvas_cannot_be_used_as_a_quality_baseline(self):
        self.report["measurements"][0]["width"] = 1200
        with self.assertRaisesRegex(ValueError, "different output sizes"):
            self.compare()
