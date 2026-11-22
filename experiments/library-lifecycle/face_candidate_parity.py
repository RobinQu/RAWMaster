#!/usr/bin/env python3
"""Verify Intel IR, production ONNX, byte-exact alignment, and the actual JSON-lines worker."""

import argparse
import collections
import importlib.util
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

import cv2
import numpy as np
from PIL import Image, ImageOps


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def compare(a, b):
    keys = sorted(a)
    if set(keys) != set(b):
        raise ValueError("Feature coverage differs")
    x = np.asarray([a[k] for k in keys], dtype=np.float64)
    y = np.asarray([b[k] for k in keys], dtype=np.float64)
    x = x / np.linalg.norm(x, axis=1)[:, None]
    y = y / np.linalg.norm(y, axis=1)[:, None]
    values = np.einsum("ij,ij->i", x, y, optimize=False)

    def gram(embeddings):
        return np.einsum("id,jd->ij", embeddings, embeddings, optimize=False)

    if not np.isfinite(values).all():
        raise ValueError("Nonfinite comparison")
    return {
        "faces": len(keys),
        "minimumCosine": float(values.min()),
        "maxUnitComponentDelta": float(np.abs(x - y).max()),
        "maxPairCosineDelta": float(np.abs(gram(x) - gram(y)).max()),
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for flag in ("worker", "models", "manifest", "native", "packed", "output"):
        p.add_argument("--" + flag, type=Path, required=True)
    args = p.parse_args()
    helper = module(
        "face_candidate_embeddings",
        Path(__file__).with_name("face_candidate_embeddings.py"),
    )
    worker = module("rawmaster_discovery_worker", args.worker)
    fixture = json.loads(args.manifest.read_text())
    native = json.loads(args.native.read_text())
    packed = json.loads(args.packed.read_text())
    digest = helper.sha(args.manifest)
    if native["manifestSHA256"] != digest or packed["manifestSHA256"] != digest:
        raise ValueError("Feature runs do not correspond to selected manifest")
    m = compare(native["vectors"], packed["vectors"])
    if m["minimumCosine"] < 0.999999 or m["maxPairCosineDelta"] > 2e-5:
        raise ValueError("Native and packed inference differ")
    by_proxy = collections.defaultdict(list)
    for row in fixture["faces"]:
        by_proxy[Path(row["proxyPath"]).resolve()].append(row)
    # The authoritative helper and production worker warp in different channel orders.
    # Compare every output byte, so a left/right-point or RGB/BGR mistake cannot pass by chance.
    identical = 0
    for path, rows in by_proxy.items():
        with Image.open(path) as src:
            rgb = np.asarray(ImageOps.exif_transpose(src).convert("RGB"))
        h, w = rgb.shape[:2]
        bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        for r in rows:
            ref = helper.intel_align(rgb, r)[0].transpose(1, 2, 0).astype(np.uint8)
            points = np.asarray(r["landmarks"]) * [w, h]
            actual = worker.align_five_points(bgr, points, worker.INTEL_TEMPLATE, 128)
            if not np.array_equal(ref, actual):
                raise ValueError("Research and product chips differ")
            identical += 1
    # Issue real worker requests independently of the recorded rectangles, one per actual proxy.
    proxy_roots = {p.parent for p in by_proxy}
    if len(proxy_roots) != 1:
        raise ValueError("Expected one generated private proxy directory")
    proxies = sorted(next(iter(proxy_roots)).glob("*.jpg"))
    if len(proxies) != fixture["metadata"]["usableProxies"]:
        raise ValueError("Proxy directory coverage differs from its manifest")
    cv = worker.Runtime(args.models).manifest
    worker_run = {}
    latency = []
    region_counts = []
    positive = next(k for k in proxies if k in by_proxy)
    proxies = [positive] + [k for k in proxies if k != positive]
    process_start = time.perf_counter_ns()
    env = {
        **os.environ,
        "OMP_NUM_THREADS": "1",
        "OPENBLAS_NUM_THREADS": "1",
        "VECLIB_MAXIMUM_THREADS": "1",
    }
    with subprocess.Popen(
        [sys.executable, "-I", str(args.worker), "--models", str(args.models)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        env=env,
    ) as child:
        try:
            for index, path in enumerate(proxies):
                start = process_start if index == 0 else time.perf_counter_ns()
                child.stdin.write(
                    json.dumps({"version": 1, "op": "faces", "proxy": str(path)}) + "\n"
                )
                child.stdin.flush()
                out = json.loads(child.stdout.readline())
                latency.append((time.perf_counter_ns() - start) / 1e6)
                if not out.get("ok"):
                    raise ValueError("Production worker failed")
                result = out["result"]
                if (
                    result["proxySHA256"] != helper.sha(path)
                    or result["model"] != cv["faceModel"]
                ):
                    raise ValueError("Wrong source or model revision")
                region_counts.append(len(result["faces"]))
                used = set()
                for row in by_proxy.get(path, []):
                    indices = [
                        i
                        for i, x in enumerate(result["faces"])
                        if np.max(np.abs(np.asarray(x["box"]) - row["box"])) < 1e-6
                        and np.max(
                            np.abs(np.asarray(x["landmarks"]) - row["landmarks"])
                        )
                        < 1e-6
                    ]
                    if len(indices) != 1 or indices[0] in used:
                        raise ValueError(
                            "Product detector changed the fixture assignment"
                        )
                    used.add(indices[0])
                    worker_run[row["faceID"]] = result["faces"][indices[0]]["vector"]
        finally:
            child.stdin.close()
        if child.wait(timeout=15) != 0:
            raise RuntimeError("Worker exited unsuccessfully")
    product = compare(worker_run, packed["vectors"])
    if product["minimumCosine"] < 0.9999999:
        raise ValueError("Full production sidecar diverged")
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss * (
        1 if sys.platform == "darwin" else 1024
    )
    report = {
        "model": cv["faceModel"],
        "onnxSHA256": packed["convertedONNXSHA256"],
        "onnxBytes": packed["convertedONNXBytes"],
        "runtime": packed["runtime"],
        "packEncoderTimingsMs": packed["latencyMs"],
        "nativeEncoderTimingsMs": native["latencyMs"],
        "nativeVsPacked": m,
        "researchVsProductIdenticalChips": identical,
        "sidecarVsPacked": product,
        "sidecar": {
            "proxyRequests": len(proxies),
            "detectedFaces": sum(region_counts),
            "warmAfterFirst": len(latency) - 1,
            "startupThroughFirstPositiveProxyMs": round(latency[0], 3),
            "firstProxyDetections": region_counts[0],
            "warmRequestMs": helper.distribution(latency[1:]),
            "childPeakRSSMiB": round(rss / 1048576, 2),
            "onnxThreads": 1,
            "opencvThreads": 2,
        },
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
