"""Install the verified first CoreAI capability into an application staging directory."""

import argparse
from hashlib import file_digest, sha256
from io import BytesIO
import json
from pathlib import Path
import shutil
from zipfile import ZipFile


def digest(path):
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest()


def require_file(root, relative):
    path = root / relative
    if path.resolve(strict=True) != path or not path.is_file():
        raise ValueError(f"Unexpected CoreAI asset location: {relative}")
    return path


def stage(source, application):
    module = Path(__file__).resolve().parents[1]
    declared = require_file(source, "manifest.json")
    contract = json.loads((module / "ModelContracts/intel-0095-v1.json").read_text())
    if json.loads(declared.read_text()) != contract:
        raise ValueError("CoreAI model manifest does not match the reviewed Intel 0095 contract")
    model = require_file(source, contract["model"]["path"])
    if model.stat().st_size != contract["model"]["bytes"] or digest(model) != contract["model"]["sha256"]:
        raise ValueError("CoreAI Intel 0095 SHA-256 or size does not match the contract")

    runtime = contract["runtime"]
    wheel = require_file(source, runtime["wheel"])
    with wheel.open("rb") as stream:
        wheel_bytes = stream.read(runtime["wheelBytes"] + 1)
    if len(wheel_bytes) != runtime["wheelBytes"] or sha256(wheel_bytes).hexdigest() != runtime["wheelSHA256"]:
        raise ValueError("CoreAI ONNX Runtime wheel SHA-256 does not match the contract")
    with ZipFile(BytesIO(wheel_bytes)) as archive:
        library = archive.read(f"onnxruntime/capi/{runtime['library']}")
        if sha256(library).hexdigest() != runtime["librarySHA256"]:
            raise ValueError("CoreAI ONNX Runtime library SHA-256 does not match the contract")
        license_text = archive.read("onnxruntime/LICENSE")
        notices = archive.read("onnxruntime/ThirdPartyNotices.txt")

    package = application / "Contents/Resources/CoreModels/v1"
    frameworks = application / "Contents/Frameworks"
    packaged_library = frameworks / runtime["library"]
    if package.exists() or packaged_library.exists():
        raise ValueError("Stage CoreAI assets into a fresh application bundle")
    licenses = package / "Licenses"
    licenses.mkdir(parents=True)
    target = package / contract["model"]["path"]
    target.parent.mkdir()
    shutil.copyfile(model, target)
    if digest(target) != contract["model"]["sha256"]:
        raise ValueError("Intel 0095 asset changed during staging")
    shutil.copyfile(module / "ModelContracts/intel-0095-v1.json", package / "manifest.json")
    originals = module.parent / "LibraryCatalog/Swift/Resources/discovery/licenses"
    for name in ("Intel-0095-NOTICE.txt", "Intel-Open-Model-Zoo.txt"):
        shutil.copyfile(originals / name, licenses / name)
    (licenses / "ONNXRuntime-LICENSE.txt").write_bytes(license_text)
    (licenses / "ONNXRuntime-ThirdPartyNotices.txt").write_bytes(notices)
    frameworks.mkdir(parents=True, exist_ok=True)
    packaged_library.write_bytes(library)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("application", type=Path)
    args = parser.parse_args()
    try:
        stage(args.source.resolve(strict=True), args.application.resolve())
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
