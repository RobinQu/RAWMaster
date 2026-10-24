"""Pure destination ownership guards; no ExifTool/originals/network/subprocess."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

MODULE = pathlib.Path(__file__).resolve().parents[2] / "scripts/package-metadata-tool.py"
spec = importlib.util.spec_from_file_location("package_metadata_tool", MODULE)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

class PackageMetadataToolTests(unittest.TestCase):
    def test_arbitrary_or_extra_content_destination_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            precious = root / "precious.txt"
            precious.write_text("keep")
            with self.assertRaises((ValueError, FileNotFoundError)):
                packager.owned_destination(root)
            self.assertEqual(precious.read_text(), "keep")
            (root / "manifest.json").write_text(json.dumps({"commit": packager.COMMIT, "version": "13.59", "files": {str(i): "a" * 64 for i in range(101)}}))
            with self.assertRaises(ValueError):
                packager.owned_destination(root)
            self.assertEqual(precious.read_text(), "keep")

    def test_source_overlap_is_rejected_before_subprocess(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for destination in [root, root / "child", root.parent]:
                with self.assertRaises(ValueError):
                    packager.package(root, destination)

    def test_symlink_destination_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source"
            source.mkdir()
            target = root / "target"
            target.mkdir()
            alias = root / "alias"
            alias.symlink_to(target, target_is_directory=True)
            with self.assertRaises(ValueError):
                packager.package(source, alias)
            self.assertTrue(target.exists())

if __name__ == "__main__":
    unittest.main()
