"""Regression checker tests use synthetic records only; published measurements use the real RAW."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-control-performance.py"
spec = importlib.util.spec_from_file_location("control_checker", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ControlGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.report = {"sourceSHA256": "a"*64, "sourceSHA256After":"a"*64, "build":"release",
            "protocol":"rawmaster-resident-control-v1", "completeCatalog":True, "requestedPixels":2400, "repeats":20,
            "binarySHA256":"c"*64, "decoder":"flashraw", "os":"test", "gpu":"test", "physicalMemory":1024,
            "operations":[{"id":"light-exposure", "recipes":["low","high"], "decoders":["flashraw"]*2,
                "outputPixels":[2400,1600], "status":"measured", "samples":[{"ms":10, "state":i%2,
                    "phase":"first" if i<2 else "warm", "digest":str(i%2)*64} for i in range(22)]}]}
        self.baseline = self.write("base", self.report)

    def write(self, name, data):
        path = self.root / name
        path.write_text(json.dumps(data))
        return path

    def compare(self, data):
        return checker.compare(self.write("current", data), self.baseline, False)

    def test_p95_catches_tail_regression_independent_of_median(self):
        self.assertEqual(self.compare(self.report)["failures"], [])
        for row in self.report["operations"][0]["samples"][-2:]:
            row["ms"] = 14
        failures = self.compare(self.report)["failures"]
        self.assertEqual(len(failures), 1)
        self.assertIn("p95Ms", failures[0])

    def test_failed_witness_never_passes_and_removed_control_is_reported(self):
        second = copy.deepcopy(self.report["operations"][0])
        second["id"] = "effects-texture"
        self.report["operations"].append(second)
        self.baseline = self.write("base", self.report)
        del self.report["operations"][1]
        self.assertTrue(any("removed" in f for f in self.compare(self.report)["failures"]))
        self.report["operations"][0]["samples"][3]["digest"] = "0"*64
        with self.assertRaisesRegex(ValueError, "Pixel A/B"):
            self.compare(self.report)

    def test_incompatible_machine_workload_and_partial_runs_are_rejected(self):
        for key, changed in (("completeCatalog",False), ("requestedPixels",1200), ("repeats",3),
                             ("sourceSHA256After","b"*64), ("gpu","different")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.compare(dict(self.report, **{key:changed}))


class PanelScheduleGateTests(unittest.TestCase):
    def setUp(self):
        import hashlib
        import sys
        report_dir = SCRIPT.parents[1] / "docs/research/camera-raw-parity"
        sys.path.insert(0,str(report_dir))
        self.addCleanup(sys.path.remove,str(report_dir))
        from performance_controls import PANEL_SCHEDULE, panel_schedule_rows
        self.validate = panel_schedule_rows
        manifest = SCRIPT.parent / "performance/paired-panel-controls.json"
        features = json.loads(manifest.read_text())
        operations = []
        for key,specification in features.items():
            trials = []
            for i in range(22):
                digest = str(i%2)*64
                first = digest if i%2==0 else "a"*64
                trials.append({"state":i%2,"phase":"first" if i<2 else "warm","digest":digest,"firstSHA256":first,
                               "firstMs":2.0,"ms":6.0,"firstExactFinalMs":2.0 if first==digest else 6.0})
            operations.append({**specification,"id":key,"status":"measured","pixelWitness":"entire-opaque-sRGB-RGBA8","samples":trials})
        self.report = {"application":"RAWMaster","protocol":PANEL_SCHEDULE["RAWMaster"],"samples":20,"pixels":[2400,1600],
                       "sourceSHA256":"a"*64,"sourceSHA256After":"a"*64,
                       "parameterSHA256":hashlib.sha256(manifest.read_bytes()).hexdigest(),"operations":operations}

    def test_first_exact_uses_full_photo_and_excludes_calibration(self):
        rows = self.validate(self.report,"RAWMaster")
        first = next(iter(rows["firstExact"].values()))
        self.assertEqual(first["timing"]["n"],20)
        self.assertEqual(first["timing"]["medianMs"],4.0)
        self.assertEqual(first["firstMatches"],10)
        self.report["operations"][0]["samples"][3]["firstExactFinalMs"] = 2.0
        with self.assertRaisesRegex(ValueError,"first exact"):
            self.validate(self.report,"RAWMaster")

    def test_rejects_unchanged_and_unstable_settled_rasters(self):
        self.report["operations"][0]["samples"][-1]["digest"] = "b"*64
        with self.assertRaisesRegex(ValueError,"did not separate"):
            self.validate(self.report,"RAWMaster")
