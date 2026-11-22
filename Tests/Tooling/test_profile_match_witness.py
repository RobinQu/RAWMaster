import copy
import json
from pathlib import Path
import sys
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "scripts/performance"))
from profile_match_witness import KEY, verify_report  # noqa: E402


class AdobeLensProfileMatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        evidence = REPOSITORY / "docs/research/camera-raw-parity/evidence"
        cls.data = json.loads((evidence / "camera-raw-profile-match.json").read_text())
        cls.archive = evidence / cls.data["metadataArchive"]["file"]

    def test_real_auto_uses_explicit_14mm_raster_and_camera_authored_settings(self):
        verified = verify_report(self.data, self.archive)
        self.assertEqual(verified["auto"], verified["correct"])
        self.assertNotEqual(verified["auto"]["nativeRGB8SHA256"], verified["wrong"]["nativeRGB8SHA256"])

    def test_lens_defaults_cannot_be_reported_as_auto(self):
        data = copy.deepcopy(self.data)
        data["operations"][KEY]["samples"][1]["returnedLensProfile"]["crs:LensProfileSetup"] = "LensDefaults"
        with self.assertRaisesRegex(ValueError, "requested mode"):
            verify_report(data, self.archive)

    def test_edited_pixel_digest_cannot_point_at_the_wrong_lens(self):
        data = copy.deepcopy(self.data)
        samples = data["operations"][KEY]["samples"]
        for s in samples:
            if s["state"] == "edit":
                s["spatialRGBSHA256"] = samples[0]["spatialRGBSHA256"]
        with self.assertRaisesRegex(ValueError, "explicit 14 mm"):
            verify_report(data, self.archive)

    def test_missing_source_metadata_and_prefilled_auto_lens_cannot_pass(self):
        data = copy.deepcopy(self.data)
        data["operations"][KEY]["samples"][1]["returnedXMPSHA256"] = "a" * 64
        with self.assertRaisesRegex(ValueError, "Archived XMP"):
            verify_report(data, self.archive)
        data = copy.deepcopy(self.data)
        data["operations"][KEY]["settings"]["edit"]["LensProfileName"] = "Adobe (Sony FE 14mm F1.8 GM)"
        with self.assertRaisesRegex(ValueError, "Incorrect inputs"):
            verify_report(data, self.archive)


if __name__ == "__main__":
    unittest.main()
