#!/usr/bin/env python3
"""Prepare a nonactivating local Electron 41.3.0 arm64 host for window-scoped LightFlow measurements."""
import argparse
import hashlib
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--electron-zip", type=Path, required=True)
    parser.add_argument("--node-headers", type=Path, required=True, help="Directory containing node_api.h")
    parser.add_argument("--output", type=Path, required=True, help="New local directory for the benchmark host")
    args = parser.parse_args()
    with args.electron_zip.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != "7a98f47f4c4f49399d3a838e9150b8828d2f5bf8aa7db769657ae82fab21f9d0":
            parser.error("Use the unmodified electron-v41.3.0-darwin-arm64.zip")
    if args.output.exists() or not (args.node_headers / "node_api.h").is_file():
        parser.error("Provide a new output directory and existing Node N-API headers")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(dir=args.output.parent) as temp:
        host = Path(temp) / "host"
        subprocess.run(["ditto", "-x", "-k", args.electron_zip, host], check=True)
        bundle = host / "Electron.app"
        plist_path = bundle / "Contents/Info.plist"
        info = plistlib.loads(plist_path.read_bytes())
        info.update(LSUIElement=True, LSBackgroundOnly=True, CFBundleIdentifier="org.rawmaster.benchmark.lightflow-chromium")
        plist_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", bundle], check=True)
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-bundle", "-undefined", "dynamic_lookup",
                        "-I", args.node_headers, "-framework", "AppKit", "-framework", "CoreGraphics",
                        source / "WindowLayer.mm", "-o", host / "layer.node"], check=True)
        shutil.copyfile(source / "main.cjs", host / "main.cjs")
        host.rename(args.output)


if __name__ == "__main__":
    main()
