#!/usr/bin/env python3
"""Run an Intel or dlib face encoder on the private RAWMaster comparison manifest."""

import argparse
from functools import lru_cache
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import resource
import sys
import time

# Each invocation measures one CPU model. Set before loading any native library.
for key in (
    "OMP_NUM_THREADS",
    "OPENBLAS_NUM_THREADS",
    "VECLIB_MAXIMUM_THREADS",
    "MKL_NUM_THREADS",
):
    os.environ[key] = "1"

import cv2  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image, ImageOps  # noqa: E402


INTEL_WEIGHTS = "21319b95e54181857f99e22dc32ec89770eca2969a1432cfa1594bffc94edd62"
INTEL_XML = "6cf60c341452155e35c467510c6c50a96ade5b2bd8f88c5a90902e905d8a80c3"
DLIB_WEIGHTS = "55533b28a95800a551ba546ba62fe69625c7e95a7061c338adffead08719da30"
DLIB_LANDMARKS = "c4b1e9804792707d3a405c2c16a80a20269e6675021f64a41d30fffafbc41888"
TAGUCHI_WEIGHTS = "ba6d064646e0ff0bfe9cb8b21e328cb2eb18d58ec43935a1b9e080f325b4de9e"
# Model card for face-reidentification-retail-0095, normalized in the 128 x 128 input.
INTEL_TEMPLATE = (
    np.array(
        [
            [0.3155687500000000, 0.4615741071428571],
            [0.6826229166666667, 0.4615741071428571],
            [0.5002624999999999, 0.6405053571428571],
            [0.3494718750000000, 0.8246919642857142],
            [0.6534364583333333, 0.8246919642857142],
        ]
    )
    * 128
)


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def checked(path, expected):
    if sha(path) != expected:
        raise ValueError(f"Unexpected resource digest for {path.name}")
    return path


@lru_cache(maxsize=3)
def load_proxy(name, expected):
    path = checked(Path(name), expected)
    with Image.open(path) as im:
        return np.ascontiguousarray(
            np.asarray(ImageOps.exif_transpose(im).convert("RGB"))
        )


def intel_align(rgb, row):
    h, w = rgb.shape[:2]
    src = np.asarray(row["landmarks"], dtype=np.float64) * [w, h]
    if src.shape != (5, 2) or not np.isfinite(src).all():
        raise ValueError("Expected five ordered finite landmarks")
    # Least-squares similarity from all points. Positive determinant excludes reflection.
    a = src - src.mean(axis=0)
    b = INTEL_TEMPLATE - INTEL_TEMPLATE.mean(axis=0)
    u, s, vt = np.linalg.svd(a.T @ b)
    sign = np.array([1.0, np.linalg.det(vt.T @ u.T)])
    m = (vt.T * sign) @ u.T * (s @ sign / np.sum(a * a))
    offset = INTEL_TEMPLATE.mean(axis=0) - m @ src.mean(axis=0)
    transform = np.column_stack([m, offset])
    chip = cv2.warpAffine(
        rgb,
        transform,
        (128, 128),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    return np.ascontiguousarray(
        chip[:, :, ::-1].transpose(2, 0, 1)[None], dtype=np.float32
    )


def dlib_rectangle(dlib, rgb, row):
    h, w = rgb.shape[:2]
    x, y, bw, bh = np.asarray(row["box"]) * [w, h, w, h]
    left, top = max(0, int(np.floor(x))), max(0, int(np.floor(y)))
    right, bottom = (
        min(w - 1, int(np.ceil(x + bw)) - 1),
        min(h - 1, int(np.ceil(y + bh)) - 1),
    )
    if left >= right or top >= bottom:
        raise ValueError("Face box falls outside oriented proxy")
    return dlib.rectangle(left, top, right, bottom)


def prepare(args):
    if args.model in ("dlib", "taguchi"):
        import dlib

        k = args.model
        weights = checked(
            args.weights / (k + "_face_recognition_resnet_model_v1.dat"),
            DLIB_WEIGHTS if k == "dlib" else TAGUCHI_WEIGHTS,
        )
        points = checked(
            args.landmarks or args.weights / "shape_predictor_5_face_landmarks.dat",
            DLIB_LANDMARKS,
        )
        predictor, encoder = (
            dlib.shape_predictor(str(points)),
            dlib.face_recognition_model_v1(str(weights)),
        )

        def align(rgb, row):
            face = predictor(rgb, dlib_rectangle(dlib, rgb, row))
            return dlib.get_face_chip(rgb, face, size=150, padding=0.25)

        info = {
            "model": k + "-resnet29-v1",
            "dimensions": 128,
            "runtime": "dlib " + dlib.__version__,
            "preprocessing": "EXIF-upright RGB proxy; shared YuNet box floor/ceil clipped; dlib native five eye-corner/nose predictor; native 150 RGB chip padding 0.25; no jitter; unit vector for shared cosine evaluator.",
            "sidecars": {
                "fivePointPredictor": {
                    "sha256": DLIB_LANDMARKS,
                    "bytes": points.stat().st_size,
                }
            },
            "nativeDistance": "Unnormalized descriptor Euclidean distance; cosine benchmark uses a unit copy.",
        }
        return (
            weights,
            align,
            lambda chip: np.asarray(encoder.compute_face_descriptor(chip, 0)),
            info,
        )

    xml = checked(args.weights / "model.xml", INTEL_XML)
    weights = checked(args.weights / "model.bin", INTEL_WEIGHTS)
    info = {
        "model": "intel-face-reidentification-retail-0095-fp32",
        "dimensions": 256,
        "preprocessing": "EXIF-upright RGB proxy; published Intel five point template on a 128-square grid; unreflected similarity fitted on all points; bilinear zero-border warp; BGR float32 NCHW 0..255; L2-normalized 256D.",
        "sidecars": {"IRgraph": {"sha256": INTEL_XML, "bytes": xml.stat().st_size}},
    }
    if args.model == "intel-ort":
        import onnxruntime as ort

        if not args.onnx:
            raise ValueError("--onnx is required for intel-ort")
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = opts.inter_op_num_threads = 1
        opts.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        encoder = ort.InferenceSession(
            str(args.onnx), sess_options=opts, providers=["CPUExecutionProvider"]
        )
        name = encoder.get_inputs()[0].name
        info.update(
            runtime="ONNX Runtime CPU " + ort.__version__,
            model=info["model"] + "-ort",
            convertedONNXSHA256=sha(args.onnx),
            convertedONNXBytes=args.onnx.stat().st_size,
        )
        return weights, intel_align, lambda x: encoder.run(None, {name: x})[0], info

    import openvino as ov

    core = ov.Core()
    encoder = core.compile_model(
        core.read_model(xml),
        "CPU",
        {
            "INFERENCE_NUM_THREADS": 1,
            "NUM_STREAMS": 1,
            "INFERENCE_PRECISION_HINT": ov.Type.f32,
        },
    )
    info["runtime"] = "OpenVINO CPU " + ov.__version__
    return weights, intel_align, lambda x: encoder(x)[0], info


def milliseconds(t):
    return (time.perf_counter_ns() - t) / 1e6


def distribution(values):
    p50, p95 = np.percentile(values, [50, 95])
    return {"p50": round(float(p50), 3), "p95": round(float(p95), 3)}


def euclidean_audit(manifest, native, path):
    """Keep the published dlib distance in its native, unnormalized feature space."""
    evaluator = (
        Path(__file__).resolve().parents[2]
        / "Modules/LibraryCatalog/Tools/compare-face-retrieval.py"
    )
    spec = importlib.util.spec_from_file_location(
        "rawmaster_face_comparison", evaluator
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    keys = sorted(native)
    unit = {k: native[k] / np.linalg.norm(native[k]) for k in keys}
    scores = {
        (first, second): -float(np.linalg.norm(native[first] - native[second]))
        for i, first in enumerate(keys)
        for second in keys[i + 1 :]
    }
    gallery, audit = module.split(manifest)
    result = {}
    for gate in ("day", "camera-day", "body-day"):
        cases = module.retrieval_cases(audit, gallery, gate, scores, unit, 8)
        result[gate] = module.results(cases, -0.6, 0, 0, detailed=True)
    path.write_text(
        json.dumps(
            {
                "protocol": "official unnormalized Euclidean distance <= 0.6, eight confirmed views, no score-gap gate",
                "heldOut": result,
            },
            indent=2,
        )
        + "\n"
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--model", required=True, choices=["intel", "intel-ort", "dlib", "taguchi"]
    )
    for name in ("manifest", "weights", "output"):
        p.add_argument("--" + name, required=True, type=Path)
    p.add_argument("--onnx", type=Path)
    p.add_argument(
        "--landmarks", type=Path, help="dlib 5-point predictor, if kept separately"
    )
    p.add_argument(
        "--euclidean-audit",
        type=Path,
        help="also evaluate the original dlib 0.6 distance on the published held-out days",
    )
    args = p.parse_args()
    if args.euclidean_audit and args.model != "dlib":
        p.error("The 0.6 Euclidean gate is defined for the original dlib model")
    cv2.setNumThreads(1)
    manifest = json.loads(args.manifest.read_text())
    faces = manifest["faces"]
    if (
        not faces
        or manifest["protocol"] != 1
        or len({f["faceID"] for f in faces}) != len(faces)
    ):
        raise ValueError("Unknown protocol or duplicate face ID")
    t = time.perf_counter_ns()
    weights, align, encode, info = prepare(args)
    cold = milliseconds(t)
    vectors, native, elapsed, combined, norms = {}, {}, [], [], []
    for face in faces:
        rgb = load_proxy(face["proxyPath"], face["proxySHA256"])
        a = time.perf_counter_ns()
        chip = align(rgb, face)
        start = time.perf_counter_ns()
        v = np.asarray(encode(chip), dtype=np.float32).reshape(-1)
        elapsed.append(milliseconds(start))
        combined.append(milliseconds(a))
        norm = np.linalg.norm(v)
        if len(v) != info["dimensions"] or not np.isfinite(v).all() or norm <= 0:
            raise ValueError("Invalid embedding")
        vectors[face["faceID"]] = (v / norm).tolist()
        if args.euclidean_audit:
            native[face["faceID"]] = v
        norms.append(float(norm))
    latency = distribution(elapsed[1:])
    # macOS reports bytes; Linux reports KiB.
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (
        1 if sys.platform == "darwin" else 1024
    )
    info.update(
        weightsSHA256=sha(weights),
        weightBytes=weights.stat().st_size,
        manifestSHA256=sha(args.manifest),
        hardware=platform.machine(),
        cpuThreads=1,
        decodedFaces=len(vectors),
        latencyMs={
            **latency,
            "coldStart": round(cold, 3),
            "firstInfer": round(elapsed[0], 3),
            "alignAndInferWarm": distribution(combined[1:]),
            "warmCount": len(elapsed) - 1,
            "rssPeakMiB": round(rss / 1048576, 2),
            "scope": "World-clock CPU on one process. Cold includes backend import/weight validation/initialization after common packages. Warm excludes proxy I/O and first face.",
        },
        unnormalizedL2Range=[min(norms), max(norms)],
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Output contains biometric data. Keep it private even outside the standard ignored directory.
    tmp = args.output.with_name(args.output.name + ".partial-" + str(os.getpid()))
    with os.fdopen(os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o600), "w") as f:
        json.dump(
            {**info, "vectors": vectors}, f, separators=(",", ":"), allow_nan=False
        )
    os.replace(tmp, args.output)
    if args.euclidean_audit:
        euclidean_audit(manifest, native, args.euclidean_audit)
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
