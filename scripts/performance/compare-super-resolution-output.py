#!/usr/bin/env python3
"""Read every production TIFF16 channel back against the independent source-linear FP16 model."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import numpy as np
import tifffile


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("floating", type=Path)
    parser.add_argument("exported", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    if args.report.exists():
        raise SystemExit("Use a fresh report path")
    reference = tifffile.memmap(args.floating, mode="r")
    rendered = tifffile.memmap(args.exported, mode="r")
    if reference.shape[:2] != rendered.shape[:2] or reference.shape[2] != 3 or rendered.shape[2] != 4:
        raise SystemExit("The model and export dimensions differ")
    if reference.dtype.kind != "f" or rendered.dtype.kind != "u" or {reference.dtype.itemsize, rendered.dtype.itemsize} != {2}:
        raise SystemExit("Expected a floating RGB16 reference and an unsigned sRGB16 RGBA export")
    codes = np.arange(65536, dtype=np.float32) / 65535
    linear = np.where(codes <= .04045, codes / 12.92, ((codes + .055) / 1.055) ** 2.4)
    more_than_half_milli = more_than_milli = 0
    worst = None
    step = 1e-7
    hist = np.zeros(100002, dtype=np.int64)
    largest, summed, alpha_mismatch = 0., 0., 0
    for y in range(0, rendered.shape[0], 24):
        strip = rendered[y:y+24]
        expected = np.clip(reference[y:y+24].astype(np.float32), 0, 1)
        diff = abs(linear[strip[:, :, :3]] - expected)
        if float(diff.max()) > largest:
            dy, x, channel = np.unravel_index(int(np.argmax(diff)), diff.shape)
            largest = float(diff[dy,x,channel])
            worst = {"x":int(x), "y":int(y+dy), "channel":int(channel),
                     "referenceLinear":float(expected[dy,x,channel]),"exportLinear":float(linear[strip[dy,x,channel]])}
        more_than_half_milli += int(np.count_nonzero(diff > .0005))
        more_than_milli += int(np.count_nonzero(diff > .001))
        summed += diff.sum(dtype=np.float64)
        alpha_mismatch += np.count_nonzero(strip[:, :, 3] != 65535)
        indices = np.minimum((diff/step).astype(np.int32), len(hist)-1).ravel()
        hist += np.bincount(indices, minlength=len(hist))
    n = reference.size
    p95 = int(np.searchsorted(hist.cumsum(), math.ceil(.95*n))) * step + step
    info = {"size":[rendered.shape[1], rendered.shape[0]], "pixels":rendered.shape[0]*rendered.shape[1],
            "comparedRGBChannels":int(n), "normalExportSHA256":digest(args.exported), "diagnosticFP16SHA256":digest(args.floating),
            "decodedSDR": "IEC sRGB unsigned 16-bit decoded to linear compared with independently predicted linear floating TIFF clipped to the selected output gamut",
            "meanAbsoluteLinearError":float(summed/n), "p95AbsoluteLinearErrorUpperBound":p95,
            "maxAbsoluteLinearError":largest, "worst":worst, "channelsAbove0005":more_than_half_milli,
            "channelsAbove001":more_than_milli, "nonOpaqueRawPixels":int(alpha_mismatch)}
    args.report.write_text(json.dumps(info, indent=2, allow_nan=False) + "\n")
    if alpha_mismatch or largest > .001 or p95 > .00015:
        raise SystemExit("Selected-output colors differ from the independent floating-point reference")
