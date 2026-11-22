#!/usr/bin/env python3
"""Recreate the exact RAWMaster FP32 Intel-0095 ONNX model and retain its notices.

Run with Python 3.12.11 in a dedicated venv containing the packages in VERSIONS.
Use --source-dir for an offline run. --output names a models directory.
"""

import argparse
import hashlib
from importlib import metadata
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


VERSIONS = {
    "openvino2onnx": "1.1.0",
    "onnx": "1.17.0",
    "numpy": "2.1.3",
    "protobuf": "7.36.2",
    "networkx": "3.7",
    "colorlog": "6.12.0",
    "tabulate": "0.10.0",
    "termcolor": "3.3.0",
}
PIN = "2c9b5c563ab3a202d085a42e2bbfc48f77961f4b"
IR = "https://storage.openvinotoolkit.org/repositories/open_model_zoo/2023.0/models_bin/1/face-reidentification-retail-0095/FP32/face-reidentification-retail-0095"
ARTIFACTS = {
    "model.xml": (
        IR + ".xml",
        "6cf60c341452155e35c467510c6c50a96ade5b2bd8f88c5a90902e905d8a80c3",
        "d5adadadf98f45459bf740b0d5cb425b029ef81133280d3b4f9d0ba0d565b8e21b834c3d030448b8926d849340a8ca7a",
    ),
    "model.bin": (
        IR + ".bin",
        "21319b95e54181857f99e22dc32ec89770eca2969a1432cfa1594bffc94edd62",
        "953bb75f16d4e7faa0a19700871e6107726cb83e0e062215a841848335694a1e274c61efacab81b4d240d935fe30efda",
    ),
    "LICENSE": (
        "https://raw.githubusercontent.com/openvinotoolkit/open_model_zoo/"
        + PIN
        + "/LICENSE",
        "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
        None,
    ),
}
FINAL = "53349972f8899c86d7afe7f585f3be76f2303f458893679ae42baafc59be6373"
FILENAME = "face-reidentification-retail-0095.onnx"


def digest(path, algorithm):
    with path.open("rb") as f:
        return hashlib.file_digest(f, algorithm).hexdigest()


def install(src, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        if digest(src, "sha256") != digest(dest, "sha256"):
            raise ValueError("Output already exists with different bytes: " + str(dest))
        return
    # Link a completed temporary file: an interrupted run cannot publish a partial model.
    with tempfile.NamedTemporaryFile(dir=dest.parent) as tmp:
        with src.open("rb") as f:
            shutil.copyfileobj(f, tmp)
        tmp.flush()
        os.fsync(tmp.fileno())
        os.fchmod(tmp.fileno(), 0o644)
        try:
            os.link(tmp.name, dest)
        except FileExistsError:
            if digest(src, "sha256") != digest(dest, "sha256"):
                raise


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument(
        "--source-dir",
        type=Path,
        help="directory containing verified model.xml, model.bin and LICENSE",
    )
    p.add_argument(
        "--licenses",
        type=Path,
        help="notice output directory (defaults to OUTPUT/licenses)",
    )
    args = p.parse_args()
    actual = {k: metadata.version(k) for k in VERSIONS}
    if sys.version_info[:3] != (3, 12, 11) or actual != VERSIONS:
        raise RuntimeError(
            "Reproducible interpreter is Python 3.12.11. Required packages: "
            + " ".join(k + "==" + v for k, v in VERSIONS.items())
        )
    converter = Path(sys.executable).with_name("openvino2onnx")
    with tempfile.TemporaryDirectory(prefix="rawmaster-intel0095-") as tmp:
        root = Path(tmp)
        for name, (url, sha256, sha384) in ARTIFACTS.items():
            f = root / name
            if args.source_dir:
                shutil.copyfile(args.source_dir / name, f)
            else:
                subprocess.run(
                    [
                        "curl",
                        "--proto",
                        "=https",
                        "--tlsv1.2",
                        "--fail",
                        "--silent",
                        "--show-error",
                        "--location",
                        "--retry",
                        "3",
                        "--max-time",
                        "90",
                        "--output",
                        str(f),
                        url,
                    ],
                    check=True,
                )
            if digest(f, "sha256") != sha256 or (
                sha384 and digest(f, "sha384") != sha384
            ):
                raise ValueError("Unexpected official input: " + name)
        model = root / FILENAME
        subprocess.run(
            [str(converter), "-v", "17", str(root / "model.xml"), str(model)],
            env={**os.environ, "PYTHONHASHSEED": "0"},
            check=True,
        )
        if model.stat().st_size != 4466624 or digest(model, "sha256") != FINAL:
            raise ValueError("Conversion did not reproduce the accepted ONNX")
        notices = args.licenses or args.output / "licenses"
        here = (
            Path(__file__).resolve().parents[1] / "Swift/Resources/discovery/licenses"
        )
        install(root / "LICENSE", notices / "Intel-Open-Model-Zoo.txt")
        install(here / "Intel-0095-NOTICE.txt", notices / "Intel-0095-NOTICE.txt")
        install(model, args.output / FILENAME)
    print(FINAL, args.output / FILENAME)


if __name__ == "__main__":
    main()
