#!/usr/bin/env python3
"""Apply the fixed ACES 2 display-linear prefix on Linux with OpenColorIO 2.5.0.

This is the P2 color parity half of the 040/041 PoC. It deliberately uses the same
built-in Studio config and the same DisplayViewTransform prefix as
`scripts/bake-scene-output.py`, then optionally emits the PQ RGB16 stream used by
the HDR AVIF encoder bake-off.
"""

import argparse
import hashlib
import json
import time
from pathlib import Path

import numpy as np
import PyOpenColorIO as ocio

CONFIG = "studio-config-v4.0.0_aces-v2.0_ocio-v2.5"
CONFIG_SHA = "3a48b0421e51d4284ec07187f86b74387321550b65f5a2f237885bf269dbc99e"
VIEWS = {
    "hdr2020": ("Rec.2100-PQ - Display", "ACES 2.0 - HDR 1000 nits (Rec.2020)"),
    "sdr709": ("sRGB - Display", "ACES 2.0 - SDR 100 nits (Rec.709)"),
}


def config():
    cfg = ocio.Config.CreateFromBuiltinConfig(CONFIG)
    digest = hashlib.sha256(cfg.serialize().encode()).hexdigest()
    if ocio.__version__ != "2.5.0" or digest != CONFIG_SHA:
        raise SystemExit(f"unexpected OCIO {ocio.__version__} config {digest}")
    return cfg


def processor(view: str):
    display, name = VIEWS[view]
    transform = config().getProcessor(
        ocio.DisplayViewTransform(src="ACEScg", display=display, view=name)
    )
    group = list(transform.createGroupTransform())
    prefix = ocio.GroupTransform()
    for item in group[:-1]:
        prefix.appendTransform(item)
    return config().getProcessor(prefix)


def pq16(rgb: np.ndarray) -> np.ndarray:
    m1 = 2610.0 / 16384.0
    m2 = 2523.0 / 32.0
    c1 = 3424.0 / 4096.0
    c2 = 2413.0 / 128.0
    c3 = 2392.0 / 128.0
    v = np.clip(rgb.astype(np.float64) / 100.0, 0.0, 10.0)
    p = np.power(v, m1)
    encoded = np.power((c1 + c2 * p) / (1.0 + c3 * p), m2)
    return np.rint(encoded * 65535.0).astype("<u2")


def compare(actual: np.ndarray, reference: np.ndarray) -> dict:
    difference = np.abs(actual - reference)
    scale = np.maximum(1.0, np.abs(reference))
    relative = difference / scale
    finite = np.isfinite(actual) & np.isfinite(reference)
    return {
        "channelSamples": int(relative.size),
        "maxAbs": float(difference[finite].max()) if finite.any() else None,
        "maxRelative": float(relative[finite].max()) if finite.any() else None,
        "meanAbs": float(difference[finite].mean()) if finite.any() else None,
        "over1e5": int(np.count_nonzero(relative > 1e-5)),
        "over1e4": int(np.count_nonzero(relative > 1e-4)),
        "over1e3": int(np.count_nonzero(relative > 1e-3)),
        "nonfinite": int(np.count_nonzero(~finite)),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True, help="RGBA32F AP1 scene output")
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--view", choices=sorted(VIEWS), required=True)
    parser.add_argument("--output", type=Path, help="RGBA32F display-linear prefix")
    parser.add_argument("--pq16", type=Path, help="RGB48LE PQ output for AVIF encoders")
    parser.add_argument("--reference", type=Path, help="macOS RGBA32F display-linear reference")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()

    expected = args.width * args.height * 4 * 4
    if args.input.stat().st_size != expected:
        raise SystemExit(f"input is {args.input.stat().st_size} bytes, expected {expected}")
    source = np.memmap(args.input, dtype="<f4", mode="r", shape=(args.height, args.width, 4))
    rgb = np.ascontiguousarray(source[:, :, :3], dtype=np.float32)
    del source

    cpu = processor(args.view).getDefaultCPUProcessor()
    started = time.perf_counter()
    cpu.applyRGB(rgb)
    apply_ms = (time.perf_counter() - started) * 1000.0

    report = {
        "schema": "rawmaster-server-poc-aces2-linux-v1",
        "ocioVersion": ocio.__version__,
        "config": CONFIG,
        "configSHA256": CONFIG_SHA,
        "view": args.view,
        "display": VIEWS[args.view][0],
        "transform": VIEWS[args.view][1],
        "width": args.width,
        "height": args.height,
        "applyMs": apply_ms,
    }

    if args.output:
        output = np.memmap(args.output, dtype="<f4", mode="w+", shape=(args.height, args.width, 4))
        output[:, :, :3] = rgb.reshape(args.height, args.width, 3)
        output[:, :, 3] = 1.0
        output.flush()
        del output
        report["output"] = str(args.output)
        report["outputSHA256"] = hashlib.sha256(args.output.read_bytes()).hexdigest()

    if args.pq16:
        started = time.perf_counter()
        encoded = pq16(rgb)
        encoded.tofile(args.pq16)
        report["pq16"] = str(args.pq16)
        report["pq16SHA256"] = hashlib.sha256(args.pq16.read_bytes()).hexdigest()
        report["pq16Ms"] = (time.perf_counter() - started) * 1000.0

    if args.reference:
        reference = np.memmap(args.reference, dtype="<f4", mode="r", shape=(args.height, args.width, 4))
        report["comparison"] = compare(rgb.reshape(args.height, args.width, 3), reference[:, :, :3])
        del reference

    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
