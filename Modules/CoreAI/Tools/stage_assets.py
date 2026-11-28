"""Install reviewed CoreAI models and runtime into an application staging directory."""

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


def unique_object(pairs):
    obj = dict(pairs)
    if len(obj) != len(pairs):
        raise ValueError("Duplicate key in CoreAI model manifest")
    return obj


def verified_bytes(root, entry, label):
    with require_file(root, entry["path"]).open("rb") as stream:
        data = stream.read(entry["bytes"] + 1)
    if len(data) != entry["bytes"] or sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError(f"CoreAI {label} SHA-256 or size does not match the contract")
    return data


def verified_detector_assets(source, module, originals, detector):
    conversion = detector["conversion"]
    verified_bytes(source, detector["source"], "original YuNet")
    verified_bytes(module.parent.parent, conversion["script"], "YuNet converter")
    license_file = detector["license"]["file"]
    return {
        detector["path"]: verified_bytes(source, detector, "dynamic YuNet"),
        conversion["record"]["path"]: verified_bytes(source, conversion["record"], "YuNet conversion record"),
        f"Licenses/{license_file['path']}": verified_bytes(originals, license_file, "YuNet MIT license"),
    }


def stage(source, application):
    module = Path(__file__).resolve().parents[1]
    contracts = module / "ModelContracts"
    intel_contract = contracts / "intel-0095-v1.json"
    declared = json.loads(require_file(source, "manifest.json").read_text(), object_pairs_hook=unique_object)
    contract = json.loads(intel_contract.read_text())
    if not isinstance(declared, dict):
        raise ValueError("CoreAI model manifest must be an object")
    if "detector" in declared:
        contract["detector"] = json.loads((contracts / "yunet-2023mar-dynamic-v1.json").read_text())
    detector = contract.get("detector")
    if json.dumps(declared, sort_keys=True) != json.dumps(contract, sort_keys=True):
        bundle = "Intel 0095 and YuNet" if detector is not None else "Intel 0095"
        raise ValueError(f"CoreAI model manifest does not match the reviewed {bundle} contract")
    model = require_file(source, contract["model"]["path"])
    if model.stat().st_size != contract["model"]["bytes"] or digest(model) != contract["model"]["sha256"]:
        raise ValueError("CoreAI Intel 0095 SHA-256 or size does not match the contract")

    originals = module.parent / "LibraryCatalog/Swift/Resources/discovery/licenses"
    detector_assets = {}
    if detector is not None:
        detector_assets = verified_detector_assets(source, module, originals, detector)

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
    if detector is None:
        shutil.copyfile(intel_contract, package / "manifest.json")
    else:
        (package / "manifest.json").write_text(json.dumps(contract, indent=2) + "\n")
        for relative, data in detector_assets.items():
            (package / relative).write_bytes(data)
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
