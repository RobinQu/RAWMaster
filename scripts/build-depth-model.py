#!/usr/bin/env python3
"""Verify the pinned Depth Anything v2 Small Core ML weights and compile them for this macOS."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

MODEL = "DepthAnythingV2SmallF16"
REVISION = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
BASE = f"https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/{REVISION}/{MODEL}.mlpackage/"
FILES = {
    "Manifest.json": "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7",
    "Data/com.apple.CoreML/model.mlmodel": "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042",
    "Data/com.apple.CoreML/weights/weight.bin": "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed",
}


def digest(path):
    with path.open('rb') as stream:
        h = hashlib.sha256()
        for block in iter(lambda: stream.read(2**20), b''):
            h.update(block)
        return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path(__file__).resolve().parents[1] / "output/tools/monocular-depth")
    parser.add_argument("--destination", type=Path, required=True, help="Parent directory for the compiled model")
    args = parser.parse_args()
    package = args.cache / (MODEL + ".mlpackage")
    for name, expected in FILES.items():
        path = package / name
        if path.is_file() and digest(path) == expected:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
            download = Path(out.name)
            try:
                with urllib.request.urlopen(BASE + name, timeout=120) as source:
                    shutil.copyfileobj(source, out)
                out.flush()
                if digest(download) != expected:
                    raise ValueError(f"Unexpected model SHA-256 for {name}")
                download.replace(path)
            finally:
                download.unlink(missing_ok=True)
    args.destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(args.destination)], check=True)


if __name__ == "__main__":
    main()
