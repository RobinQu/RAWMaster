import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-image-performance.py"
spec = importlib.util.spec_from_file_location("monitor_checker", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class MonitorExportTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def report(self, name, samples, version=3):
        data = {"schemaVersion":version, "build":"test", "createdAt":"2026-11-22"}
        if version == 3:
            data["snapshot"] = {"recent":samples, "completedSampleCount":len(samples)+100}
        else:
            data["samples"] = samples
        path = self.root / name
        path.write_text(json.dumps(data))
        return path

    def test_current_monitor_keeps_queue_and_excludes_graph_construction_throughput(self):
        samples = [{"operation":"Preview", "stage":"shape", "boundary":boundary, "queue":queue,
                    "durationMilliseconds":2, "outcome":"成功", "pixelCount":1000}
                   for queue in ("预览","导出") for boundary in ("图构建","GPU 完成") for _ in range(6)]
        report = self.report("monitor.json",samples)
        result = checker.compare(report,report,6,.05,.1)
        self.assertTrue(result["passed"])
        self.assertEqual(result["current"]["retainedSamples"],24)
        self.assertEqual(result["current"]["completedSamples"],124)
        self.assertEqual({row["queue"] for row in result["operations"]},{"预览","导出"})
        for row in result["operations"]:
            self.assertEqual(row["current"]["medianMegapixelsPerSecond"], .5 if row["boundary"]=="GPU 完成" else None)

    def test_legacy_snapshot_without_queue_compares_to_the_same_native_work(self):
        row = {"operation":"Preview", "stage":"display", "boundary":"API 返回", "outcome":"成功", "pixelCount":1000}
        old = self.report("old.json",[{**row,"durationMs":1}]*6,version=1)
        new = self.report("new.json",[{**row,"queue":"预览","durationMilliseconds":2}]*6)
        result = checker.compare(old,new,6,.05,.1)
        self.assertFalse(result["policy"]["comparedByQueue"])
        self.assertFalse(result["passed"])
        self.assertEqual(result["operations"][0]["medianChangePercent"],100)
