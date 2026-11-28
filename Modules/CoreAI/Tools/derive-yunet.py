#!/usr/bin/env python3
"""Derive the reviewed dynamic YuNet ONNX and its conversion record."""

import argparse
from hashlib import sha256
import json
from pathlib import Path

import onnx


CONTRACT = Path(__file__).resolve().parents[1] / "ModelContracts/yunet-2023mar-dynamic-v1.json"
HEADS = {
    f"{group}_{stride}": (640 // stride) ** 2
    for group in ("cls", "obj", "bbox", "kps")
    for stride in (8, 16, 32)
}


def dimension_edits(model):
    if len(model.graph.input) != 1 or model.graph.input[0].name != "input":
        raise ValueError("Unexpected frozen YuNet input declaration")
    if [head.name for head in model.graph.output] != list(HEADS):
        raise ValueError("Unexpected frozen YuNet output declarations")
    dims = model.graph.input[0].type.tensor_type.shape.dim
    yield dims[2], 640, "height"
    yield dims[3], 640, "width"
    for head in model.graph.output:
        stride = head.name.rsplit("_", 1)[1]
        locations = head.type.tensor_type.shape.dim[1]
        yield locations, HEADS[head.name], f"locations_{stride}"


def derive(source, axes):
    frozen = onnx.load_model_from_string(source)
    model = onnx.ModelProto()
    model.CopyFrom(frozen)
    edits = list(dimension_edits(model))
    if len(edits) != axes:
        raise ValueError("Unexpected number of YuNet dimension edits")
    for dim, fixed, name in edits:
        if dim.WhichOneof("value") != "dim_value" or dim.dim_value != fixed:
            raise ValueError("Unexpected fixed YuNet axis value")
        dim.dim_param = name
    onnx.checker.check_model(model)
    restored = onnx.ModelProto()
    restored.CopyFrom(model)
    for dim, fixed, _ in dimension_edits(restored):
        dim.dim_value = fixed
    if restored != frozen:
        raise ValueError("YuNet conversion changed fields beyond the approved axes")
    return model.SerializeToString(deterministic=True)


def require_identity(data, entry, label):
    if len(data) != entry["bytes"] or sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError(f"Unexpected {label} SHA-256 or size")
    return entry["sha256"]


def convert(source, destination, record):
    contract = json.loads(CONTRACT.read_text())
    method = contract["conversion"]
    if len({source, destination, record}) != 3:
        raise ValueError("YuNet source, model output and record must be distinct")
    if onnx.__version__ != method["onnxVersion"]:
        raise ValueError(f"YuNet conversion requires onnx {method['onnxVersion']}")
    original = source.read_bytes()
    source_sha = require_identity(original, contract["source"], "original YuNet")
    converter_sha = require_identity(Path(__file__).read_bytes(), method["script"], "YuNet converter")
    result = derive(original, method["changedAxes"])
    result_sha = require_identity(result, contract, "dynamic YuNet")
    receipt = {
        "schemaVersion": 1,
        "sourceSHA256": source_sha,
        "sourceBytes": len(original),
        "derivedSHA256": result_sha,
        "bytes": len(result),
        "converter": method["script"]["path"],
        "converterSHA256": converter_sha,
        "changedAxes": method["changedAxes"],
        "structuralEqualityAfterRestoration": True,
        "onnx": onnx.__version__,
    }
    evidence = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode("utf-8")
    require_identity(evidence, method["record"], "YuNet conversion record")
    destination.write_bytes(result)
    record.write_bytes(evidence)
    print(evidence.decode("utf-8"), end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path, help="unmodified OpenCV Zoo YuNet 2023mar ONNX")
    parser.add_argument("output", type=Path, help="destination dynamic ONNX")
    parser.add_argument("--record", type=Path, help="conversion record destination")
    args = parser.parse_args()
    try:
        source = args.original.resolve(strict=True)
        destination = args.output.resolve()
        record = args.record or args.output.with_suffix(".conversion.json")
        convert(source, destination, record.resolve())
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
