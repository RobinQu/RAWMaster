#!/usr/bin/env python3
"""Compare a decoded HDR AVIF (RGB48) with the PQ16 stream that was encoded."""

import argparse
import json
from pathlib import Path

import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True, help="RGB48LE PQ input")
    parser.add_argument("--decoded", type=Path, required=True, help="RGB48LE decoded AVIF")
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()

    shape = (args.height, args.width, 3)
    expected = args.width * args.height * 3 * 2
    for path in (args.input, args.decoded):
        if path.stat().st_size != expected:
            raise SystemExit(f"{path} is {path.stat().st_size} bytes, expected {expected}")

    source = np.fromfile(args.input, dtype="<u2").reshape(shape).astype(np.float64)
    decoded = np.fromfile(args.decoded, dtype="<u2").reshape(shape).astype(np.float64)
    difference = decoded - source
    absolute = np.abs(difference)
    mse = float(np.mean(difference * difference))
    psnr = float("inf") if mse == 0 else 10.0 * np.log10((65535.0 ** 2) / mse)
    per_channel_psnr = []
    for channel in range(3):
        channel_mse = float(np.mean(difference[:, :, channel] ** 2))
        per_channel_psnr.append(
            float("inf") if channel_mse == 0 else 10.0 * np.log10((65535.0 ** 2) / channel_mse)
        )
    report = {
        "channelSamples": int(absolute.size),
        "psnr": psnr,
        "psnrChannels": per_channel_psnr,
        "maxAbs": float(absolute.max()),
        "meanAbs": float(absolute.mean()),
        "p99Abs": float(np.percentile(absolute, 99)),
        "overTwo10BitCodes": int(np.count_nonzero(absolute > 2.0 * 65535.0 / 1023.0)),
        "overEight10BitCodes": int(np.count_nonzero(absolute > 8.0 * 65535.0 / 1023.0)),
        "nonfinite": 0,
    }
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
