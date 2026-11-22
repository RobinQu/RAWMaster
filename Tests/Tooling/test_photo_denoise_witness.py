import copy
import hashlib
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/performance"))
from photo_denoise_witness import PHOTO_V1, PHOTO_V2, validate_component_witness, verify_legacy_replay


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


class PhotoDenoiseGateTests(unittest.TestCase):
    def setUp(self):
        pixels = {"original": "original", "disabled": "original", "legacy-zero": "original",
                  "zero": "chroma", "half": "half", "fresh35": "chroma35", "legacy35": "rgb35",
                  "full": "network", "replay100": "network", "legacy-full": "network"}
        self.row = {"source": "camera.jpg", "sourceSHA256": digest("source"), "nativePixels": [1616, 1080],
                    "legacyModel": PHOTO_V1, "nativePredictionCacheEligible": True, "closedInputResidentBytes": 0, "requests": [], "componentWitness": {
                        "sampled": 49152, "inRangeOpaque": 48000, "sourceToFullChromaChangedByTwoCodes": 300,
                        "sourceToFullLumaChangedByTwoCodes": 800, "p95ZeroVsSourceLumaRGB8": 0.6,
                        "p95HalfVsMidpointLumaRGB8": 0.5, "p95ZeroAndHalfVsFullChromaRGB8": 1.0}}
        for name, value in pixels.items():
            model = "disabled" if name in ("original", "disabled") else PHOTO_V1 if name.startswith("legacy") else PHOTO_V2
            self.row["requests"].append({"state": name, "denoiseModel": model, "neuralGPUCompletions": int(name == "zero"), "sampleRGBASHA256": digest(value)})

    def test_full_chroma_requires_luma_and_chroma_measurements(self):
        validate_component_witness(self.row, PHOTO_V1)
        for field in ("p95ZeroVsSourceLumaRGB8", "p95HalfVsMidpointLumaRGB8", "p95ZeroAndHalfVsFullChromaRGB8"):
            row = copy.deepcopy(self.row)
            row["componentWitness"][field] = 10
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_component_witness(row, PHOTO_V1)
        self.row["componentWitness"]["sourceToFullChromaChangedByTwoCodes"] = 0
        with self.assertRaises(ValueError):
            validate_component_witness(self.row, PHOTO_V1)

    def test_extra_inference_and_retained_capture_fail(self):
        entry = next(x for x in self.row["requests"] if x["state"] == "half")
        entry["neuralGPUCompletions"] = 1
        with self.assertRaises(ValueError):
            validate_component_witness(self.row, PHOTO_V1)
        entry["neuralGPUCompletions"] = 0
        self.row["closedInputResidentBytes"] = 1024
        with self.assertRaises(ValueError):
            validate_component_witness(self.row, PHOTO_V1)

    def test_mixed_model_and_identical_legacy_strength_fail(self):
        item = next(v for v in self.row["requests"] if v["state"] == "legacy35")
        item["denoiseModel"] = PHOTO_V2
        with self.assertRaises(ValueError):
            validate_component_witness(self.row, PHOTO_V1)
        item["denoiseModel"] = PHOTO_V1
        item["sampleRGBASHA256"] = digest("chroma35")
        with self.assertRaises(ValueError):
            validate_component_witness(self.row, PHOTO_V1)

    def test_old_real_recipe_pixels_are_checked_apart_from_current_ones(self):
        old = {"sourceSHA256": self.row["sourceSHA256"], "nativePixels": self.row["nativePixels"],
               "requests": [{"state": key, "sampleRGBASHA256": digest(value)} for key, value in
                            (("original", "original"), ("zero", "original"), ("fresh35", "rgb35"), ("full", "network"))]}
        verify_legacy_replay(self.row, old)
        old["requests"][2]["sampleRGBASHA256"] = digest("wrong")
        with self.assertRaises(ValueError):
            verify_legacy_replay(self.row, old)


if __name__ == "__main__":
    unittest.main()
