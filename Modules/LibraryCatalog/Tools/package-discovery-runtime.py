#!/usr/bin/env python3
"""Package a standalone Python 3.12, installed wheels and pinned local model files."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

RESOURCES = Path(__file__).resolve().parents[1] / "Swift" / "Resources" / "discovery"
LOCK = json.loads((RESOURCES / "runtime-lock.json").read_text())
PINS = LOCK["dependencies"]
DISTRIBUTIONS = list(PINS)
PROBE = """
import importlib.metadata as md, json, sys, sysconfig
from pathlib import Path
out={}
for name in json.loads(sys.argv[1]):
    d=md.distribution(name)
    out[name]={"version":d.version,"root":str(d.locate_file("").resolve()),"files":[[str(f), None if f.hash is None else [f.hash.mode,f.hash.value]] for f in d.files or []]}
print(json.dumps({"base":sys.base_prefix,"version":list(sys.version_info[:3]),"platform":sysconfig.get_platform(),"distributions":out}))
"""


def sha(path):
    with path.open("rb") as s:
        return hashlib.file_digest(s, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--python",
        required=True,
        type=Path,
        help="Python 3.12 environment backed by a redistributable standalone base",
    )
    parser.add_argument("--models", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists():
        raise ValueError("choose a fresh output directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    inventory = json.loads(
        subprocess.check_output(
            [str(args.python.absolute()), "-I", "-c", PROBE, json.dumps(DISTRIBUTIONS)]
        )
    )
    if inventory["version"] != LOCK["python"]:
        raise ValueError("discovery pack requires standalone Python 3.12")
    versions = {n: d["version"] for n, d in inventory["distributions"].items()}
    if any(versions[n] != v for n, v in PINS.items()):
        raise ValueError(
            "runtime versions differ from validated inference dependencies"
        )
    manifest = json.loads((RESOURCES / "models.json").read_text())
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        pack = Path(temporary) / "LibraryDiscovery"
        pack.mkdir()
        runtime = pack / "runtime"
        base = Path(inventory["base"]).resolve()
        if (
            base in (Path("/usr"), Path("/usr/local"), Path("/opt/homebrew"))
            or not (base / "bin" / "python3.12").is_file()
        ):
            raise ValueError("a self-contained Python prefix is required")
        shutil.copytree(
            base,
            runtime,
            symlinks=True,
            ignore=shutil.ignore_patterns("site-packages", "__pycache__"),
        )
        site = runtime / "lib/python3.12/site-packages"
        site.mkdir(parents=True, exist_ok=True)
        for d in inventory["distributions"].values():
            root = Path(d["root"])
            for rel, expected in d["files"]:
                parts = Path(rel).parts
                if (
                    not parts
                    or ".." in parts
                    or Path(rel).is_absolute()
                    or "__pycache__" in parts
                    or rel.endswith(".pyc")
                ):
                    continue
                src, dst = root / rel, site / rel
                if src.is_file():
                    if expected:
                        mode, checksum = expected
                        with src.open("rb") as f:
                            actual = (
                                base64.urlsafe_b64encode(
                                    hashlib.file_digest(f, mode).digest()
                                )
                                .decode()
                                .rstrip("=")
                            )
                        if actual != checksum:
                            raise ValueError(
                                "wheel RECORD checksum mismatch for " + rel
                            )
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
        # ORT wheels may ship a versioned native symlink not represented in RECORD.
        for src in site.rglob("*.dylib"):
            if not src.resolve().is_relative_to(pack):
                raise ValueError("native library escapes the package")
        dest = pack / "models"
        dest.mkdir()
        for name, expected in manifest["sha256"].items():
            path = args.models / name
            if sha(path) != expected:
                raise ValueError("unexpected model file " + name)
            shutil.copyfile(path, dest / name)
        shutil.copytree(
            RESOURCES, pack / "discovery", ignore=shutil.ignore_patterns("__pycache__")
        )
        (pack / "runtime.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "python": inventory["version"],
                    "platform": inventory["platform"],
                    "dependencies": versions,
                    "sceneModel": manifest["sceneModel"],
                    "faceModel": manifest["faceModel"],
                },
                indent=2,
            )
            + "\n"
        )
        subprocess.run(
            [
                str(runtime / "bin/python3.12"),
                "-I",
                "-B",
                str(pack / "discovery/worker.py"),
                "--models",
                str(dest),
            ],
            input=b"",
            check=True,
            timeout=90,
        )
        pack.rename(output)
    print(output)


if __name__ == "__main__":
    main()
