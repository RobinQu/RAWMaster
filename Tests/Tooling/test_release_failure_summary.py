import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-image-performance.py"
spec = importlib.util.spec_from_file_location("release_checker", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ReleaseFailureSummaryTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def write(self, name, data):
        (self.root / name).write_text(json.dumps(data))

    def test_summary_keeps_all_named_exceeded_metrics_and_checker_failures(self):
        self.write("image.json", {
            "status": "failed", "build": "release",
            "metrics": [
                {"name": "canvas_4_fit", "p95Milliseconds": 14, "maxMilliseconds": 25},
                {"name": "true_raw_app_cache_cold", "p95Milliseconds": 1600, "maxMilliseconds": 4000}
            ],
            "gates": [
                {"metric": "canvas_4_fit", "p95LimitMilliseconds": 33, "maxLimitMilliseconds": 100,
                 "relativeP95LimitMilliseconds": 12, "passed": False},
                {"metric": "true_raw_app_cache_cold", "p95LimitMilliseconds": 1500,
                 "maxLimitMilliseconds": 3750, "passed": False}
            ]
        })
        text = "first/effects-pcv-midpoint exceeds its baseline latency limits"
        self.write("panel-schedule-comparison.json", {"status": "failed", "failures": [text]})
        self.write("raw9-denoise-comparison.json", {"failures": ["native-export 20.00 -> 28.00 ms"]})
        self.write("image.command.json", {"status": "command-failed", "exitCode": 1})
        self.write("panel-schedule.command.json", {"status": "passed", "exitCode": 0})
        summary = checker.release_directory_result(self.root, self.root / "previous-release", False, True)
        self.assertFalse(summary["passed"])
        self.assertEqual(summary["baselineRun"], "previous-release")
        self.assertEqual(set(summary["failedStages"]), {"image-pipeline", "panel-schedule-comparison", "raw9-comparison"})
        by_stage = {r["stage"]: r for r in summary["failureDetails"]}
        self.assertEqual(by_stage["image-pipeline"]["report"], "image.json")
        self.assertEqual(by_stage["image-pipeline"]["failures"], [
            "canvas_4_fit: relative p95 14.00 > 12.00 ms",
            "true_raw_app_cache_cold: p95 1600.00 > 1500.00 ms, max 4000.00 > 3750.00 ms"
        ])
        self.assertEqual(by_stage["panel-schedule-comparison"]["failures"], [text])
        self.assertEqual(by_stage["raw9-comparison"]["report"], "raw9-denoise-comparison.json")
        self.assertEqual(summary, json.loads((self.root / "summary.json").read_text()))

    def test_timeout_and_missing_report_never_invent_an_operation_or_a_link(self):
        self.write("controls.command.json", {"status": "timeout", "timeoutSeconds": 600})
        rows = checker.release_failure_details(self.root, ["control-sequence", "control-comparison"])
        self.assertEqual(rows[0], {
            "stage": "control-sequence", "report": "controls.command.json", "failures": ["controls: timeout"]
        })
        self.assertIsNone(rows[1]["report"])
        self.assertTrue(rows[1]["failures"])

    def test_successful_receipts_and_comparisons_do_not_add_failures(self):
        self.write("controls.command.json", {"status": "passed"})
        self.write("control-comparison.json", {"status": "passed", "failures": []})
        self.write("interactive-comparison.json", {"passed": True, "failures": []})
        self.assertEqual(checker.release_failure_details(self.root, []), [])


if __name__ == "__main__":
    unittest.main()
