#!/usr/bin/env python3
"""Compare a trained photo denoiser's Core ML conversion to the author's ONNX, sampled colors, and overlapping tiles."""
import argparse
import hashlib
import json
from pathlib import Path
from time import perf_counter

import coremltools as ct
import numpy as np
import onnxruntime as ort
from PIL import Image


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def channels(image):
    return np.ascontiguousarray(image.transpose(2, 0, 1)[None], dtype=np.float32)


def rgb(batch):
    return batch[0].transpose(1, 2, 0)


def predict(model, image):
    return rgb(model.predict({"image": channels(image)})["restored"])


def error(reference, candidate):
    delta = np.abs(candidate - reference)
    return {"meanAbsolute": float(np.mean(delta)), "p95": float(np.quantile(delta, .95)),
            "maximum": float(np.max(delta)), "meanSquared": float(np.mean(delta ** 2))}


def feather_tiled(model, image, overlap):
    height, width, _ = image.shape
    side = 128
    result, weights = np.zeros_like(image), np.zeros((height, width), dtype=np.float32)
    def starts(length):
        return sorted(set([*range(0, length - side + 1, side - overlap), length - side]))
    def rim(length, start):
        w = np.ones(side, dtype=np.float32)
        ramp = np.sin((np.arange(overlap) + 0.5) * np.pi / (2 * overlap)) ** 2
        if start > 0:
            w[:overlap] = ramp
        if start + side < length:
            w[-overlap:] = ramp[::-1]
        return w
    for y in starts(height):
        for x in starts(width):
            tile = image[y:y + side, x:x + side]
            weight = rim(height, y)[:, None] * rim(width, x)[None, :]
            result[y:y + side, x:x + side] += predict(model, tile) * weight[..., None]
            weights[y:y + side, x:x + side] += weight
    return result / weights[..., None]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--onnx", type=Path, required=True)
    p.add_argument("--weights", type=Path, required=True)
    p.add_argument("--tile128", type=Path, required=True)
    p.add_argument("--tile192", type=Path, required=True)
    p.add_argument("--source-raw", type=Path, required=True)
    p.add_argument("--embedded-jpeg", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        raise ValueError("Use an unused output filename")
    if sha(args.weights) != "0a3e22bdcb70dd790fce66f45df8d07e774e269b17c92a2835162b150d4a365c":
        raise ValueError("Wrong upstream safetensors")
    onnx_hash = sha(args.onnx)
    if onnx_hash != "fa7a85412634b30e078299aafc9a9d4074358f1a5abcd8f17a8355715a258c51":
        raise ValueError("Wrong upstream reference graph")
    options = ort.SessionOptions()
    options.intra_op_num_threads, options.inter_op_num_threads = 2, 1
    reference = ort.InferenceSession(str(args.onnx), options, providers=["CPUExecutionProvider"])
    tile = ct.models.MLModel(str(args.tile128), compute_units=ct.ComputeUnit.CPU_ONLY)
    whole = ct.models.MLModel(str(args.tile192), compute_units=ct.ComputeUnit.CPU_ONLY)
    with Image.open(args.embedded_jpeg) as jpeg:
        photo = np.asarray(jpeg.convert("RGB"), dtype=np.float32) / 255.0
    height, width = photo.shape[:2]
    x, y = width // 2 - 64, height // 2 - 64
    clean = photo[y:y + 128, x:x + 128]
    noisy = np.clip(clean + np.random.default_rng(1551).normal(0, .04, clean.shape).astype(np.float32), 0, 1)
    start = perf_counter()
    original = rgb(reference.run(None, {"input": channels(noisy)})[0])
    original_ms = (perf_counter() - start) * 1000
    start = perf_counter()
    native = predict(tile, noisy)
    native_ms = (perf_counter() - start) * 1000
    controls = []
    for color in [[0., 0., 0.], [.18, .18, .18], [.5, .5, .5], [1., 1., 1.], [.85, .2, .1]]:
        swatch = np.zeros_like(clean) + np.asarray(color, dtype=np.float32)
        result = predict(tile, swatch)
        controls.append({"input": color, "center": result[64, 64].tolist(),
                         "meanInterior": result[24:-24, 24:-24].mean(axis=(0, 1)).tolist()})
    test = photo[y - 32:y + 160, x - 32:x + 160]
    baseline = predict(whole, test)
    sampled = np.s_[16:-16, 16:-16]
    seams = [{"overlap": overlap, "interior": error(baseline[sampled], feather_tiled(tile, test, overlap)[sampled])}
             for overlap in [32, 64]]
    report = {"model": "Philip Hofmann 1xDeNoise_realplksr_otf", "license": "CC BY 4.0",
              "upstreamRevision": "829b63fdbf8b1271595893bdaee6818bdada46bb",
              "weightsSHA256": sha(args.weights), "referenceONNXSHA256": onnx_hash,
              "rawSHA256": sha(args.source_raw), "cameraEmbeddedJPEGSHA256": sha(args.embedded_jpeg),
              "jpegSize": [width, height], "cleanNativeCrop": [x, y, 128, 128],
              "color": "SDR normalized display RGB, 1x", "computeUnits": "CPU only",
              "software": {"coremltools": ct.__version__, "onnxruntime": ort.__version__},
              "noiseStdDev": .04, "rngSeed": 1551, "inputVsClean": error(clean, noisy),
              "officialModelVsClean": error(clean, original), "convertedModelVsClean": error(clean, native),
              "conversionVsOfficial": error(original, native), "meanOutputMinusClean": (native-clean).mean(axis=(0, 1)).tolist(),
              "cpuSingleWarmupInclusiveMs": {"authorONNX": original_ms, "convertedCoreML": native_ms},
              "uniformSwatches": controls, "seamReferenceCrop": [x-32, y-32, 192, 192],
              "tileStrategy": "128px, sine-squared normalized weighted overlap, no resizing",
              "tileVsMonolithic192": seams}
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
