"""Compare the same-base SDXL pairs against source-coordinate and colour controls."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import sobel

from pixels import linear, srgb8

REGIONS = {"zone": {"nearBoat": (217, 331, 336, 409), "mountain": (190, 58, 710, 260)},
           "neon": {"trainAndBridge": (125, 145, 531, 207), "cyclist": (470, 245, 565, 380)}}


def read(path):
    return np.asarray(Image.open(path).convert("RGB"))


def luma(rgb):
    return linear(rgb) @ np.array([.2126, .7152, .0722])


def edge(rgb):
    y = luma(rgb)
    return np.hypot(sobel(y, axis=0), sobel(y, axis=1))


def evaluate(directory, lake):
    report = {}
    for case, source in [("zone", lake), ("neon", directory / "neon/city-input.png")]:
        folder = directory / case
        original = read(source)
        y = luma(original)
        if case == "zone":
            control = np.repeat(srgb8(y)[..., None], 3, axis=2)
        else:
            # A cool shadow / warm-magenta highlight grade retaining the input coordinates.
            mix = np.sqrt(y)[..., None]
            gain = np.array([.84, .92, 1.15]) * (1-mix) + np.array([1.12, .91, 1.04]) * mix
            control = srgb8(linear(original) * gain)
        Image.fromarray(control).save(folder / "grade.png")
        base, adapted = (read(folder / name) for name in ("base.png", "with-lora.png"))
        base_low, adapted_low = (read(folder / "low" / name) for name in ("base.png", "with-lora.png"))
        source_edges = edge(original)
        row = {"regionsXYXY": REGIONS[case], "pairedMeanAbsRGB8": round(float(np.abs(base.astype(float) - adapted).mean()), 3),
               "lowPairedMeanAbsRGB8": round(float(np.abs(base_low.astype(float) - adapted_low).mean()), 3)}
        for name, rgb in [("source", original), ("grade", control), ("base", base), ("with-lora", adapted),
                          ("base-low", base_low), ("with-lora-low", adapted_low)]:
            edges = edge(rgb)
            result = {"meanMaxMinusMinRGB8": round(float(np.ptp(rgb, axis=2).mean()), 3)}
            for region, (x0, y0, x1, y1) in REGIONS[case].items():
                box = np.s_[y0:y1, x0:x1]
                result[region] = round(float(np.corrcoef(source_edges[box].ravel(), edges[box].ravel())[0, 1]), 4)
            row[name] = result
        report[case] = row
    (directory / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory", type=Path)
    p.add_argument("lake", type=Path)
    args = p.parse_args()
    evaluate(args.directory, args.lake)
