import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/performance"))
from hsl_band_witness import (  # noqa: E402
    BLUE,
    FIELDS,
    NATIVE,
    SHA,
    ZERO,
    expected_mixer,
    schedule,
    summarize,
    verify_report,
)


class HSLBandWitnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.historical = json.loads(
            (ROOT / "docs/research/camera-raw-parity/evidence/camera-raw-open.json").read_text()
        )
        old = cls.historical["operations"]
        neutral_hash = old["mixer-hue"]["samples"][0]["histogramSHA256"]
        data = {k: cls.historical[k] for k in ("cameraRaw", "hardware", "os", "sourceSHA256")}
        data.update(
            protocol="acr-independent-hsl-native-v1",
            sourceSHA256After=SHA,
            workCopySHA256After=SHA,
            foregroundUnchanged=True,
            photoshop="28.0.0",
            samples=[],
        )
        for index, (iteration, field) in enumerate(schedule()):
            native = hashlib.sha256(("synthetic tooling fixture:" + field).encode()).hexdigest()
            hist = (
                neutral_hash
                if field == ZERO
                else old[BLUE[field]]["samples"][1]["histogramSHA256"]
                if field in BLUE
                else native
            )
            data["samples"].append(
                dict(
                    index=index,
                    field=field,
                    round=iteration,
                    photoshop="28.0.0",
                    openMs=100 + iteration,
                    outputPixels=NATIVE,
                    spatialPixels=NATIVE,
                    spatialRGBSHA256=native,
                    histogramSHA256=hist,
                    returnedHSL=expected_mixer(field),
                )
            )
        cls.data = data

    def test_measured_documents_and_all_archived_inputs_replay(self):
        evidence = ROOT / "docs/research/camera-raw-parity/evidence"
        captured = json.loads((evidence / "camera-raw-hsl-bands.json").read_text())
        rows = verify_report(
            captured,
            evidence / captured["metadataArchive"]["file"],
            evidence / captured["historicalSource"]["file"],
        )
        self.assertEqual(24, sum(r["state"] == "measured" for r in rows))
        self.assertTrue(all(r["fixedNativeGrid"]["pixelsCompared"] == 6144 for r in rows))

    def test_blue_uses_real_earlier_duration_and_new_fields_use_three_held_out_runs(self):
        rows = summarize(self.data, self.historical)
        self.assertEqual(91, len(self.data["samples"]))
        self.assertEqual(list(FIELDS), [r["field"] for r in rows])
        for row in rows:
            self.assertEqual("measured", row["state"])
            self.assertEqual(23, row["verifiedZeroNeighborCount"])
            if row["field"] in BLUE:
                old = self.historical["operations"][BLUE[row["field"]]]["samples"]
                self.assertEqual(
                    [s["openMs"] for s in old if s["state"] == "edit" and s["iteration"]],
                    row["timing"]["rawMs"],
                )
            else:
                self.assertEqual([101, 102, 103], row["timing"]["rawMs"])

    def test_changed_neighbor_is_not_counted(self):
        data = copy.deepcopy(self.data)
        sample = next(s for s in data["samples"] if s["field"] == "HueAdjustmentRed")
        sample["returnedHSL"]["HueAdjustmentBlue"] = 40
        rows = summarize(data, self.historical)
        self.assertEqual("inconclusive", rows[0]["state"])
        self.assertNotIn("timing", rows[0])

    def test_unchanged_native_raster_is_not_counted(self):
        data = copy.deepcopy(self.data)
        neutral = data["samples"][0]["spatialRGBSHA256"]
        for s in data["samples"]:
            if s["field"] == "HueAdjustmentRed":
                s["spatialRGBSHA256"] = neutral
        self.assertEqual("inconclusive", summarize(data, self.historical)[0]["state"])

    def test_fictitious_blue_cannot_inherit_prior_timings(self):
        data = copy.deepcopy(self.data)
        for s in data["samples"]:
            if s["field"] == "HueAdjustmentBlue":
                s["histogramSHA256"] = "f" * 64
        row = next(r for r in summarize(data, self.historical) if r["field"] == "HueAdjustmentBlue")
        self.assertEqual("inconclusive", row["state"])
        self.assertNotIn("timing", row)


if __name__ == "__main__":
    unittest.main()
