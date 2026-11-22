"""Compare a reference-conditioned lake edit with a pointwise cool grade.

Run on the archived 768 x 512 sRGB PNGs. Coordinates are in the source image.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import sobel

REGIONS = {
    "mainBoat": (217, 331, 336, 409),
    "distantBoat": (525, 278, 565, 306),
    "mountain": (190, 58, 710, 260),
    "upperRightCloud": (684, 0, 750, 38),
}
SCALE = [0.68 * 0.88, 0.68 * 0.97, 0.68 * 1.12]


def linear_rgb(path):
    image = np.asarray(Image.open(path).convert("RGB"), dtype=float) / 255
    if image.shape != (512, 768, 3):
        raise ValueError(f"Expected a registered 768 x 512 RGB image: {path}")
    return np.where(image <= 0.04045, image / 12.92, ((image + 0.055) / 1.055) ** 2.4)


def luminance(linear):
    return linear @ np.array([0.2126, 0.7152, 0.0722])


def gradients(y):
    return np.hypot(sobel(y, axis=0), sobel(y, axis=1))


def measure(directory):
    source = linear_rgb(directory / "lake.png")
    grade = np.clip(source * SCALE, 0, 1)
    srgb = np.where(grade <= 0.0031308, 12.92 * grade, 1.055 * grade ** (1 / 2.4) - 0.055)
    Image.fromarray(np.rint(srgb * 255).astype(np.uint8)).save(directory / "native-control.png")
    ref_edges = gradients(luminance(source))
    report = {"size": [768, 512], "linearRgbControlMultiplier": SCALE, "regionsXYXY": REGIONS, "results": {}}
    for filename in ("lake.png", "native-control.png", "transferred.png"):
        path = directory / filename
        y = luminance(linear_rgb(path))
        edges = gradients(y)
        row = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "medianLinearY": round(float(np.median(y)), 5)}
        row["regions"] = {}
        for name, (x0, y0, x1, y1) in REGIONS.items():
            box = np.s_[y0:y1, x0:x1]
            corr = np.corrcoef(ref_edges[box].ravel(), edges[box].ravel())[0, 1]
            row["regions"][name] = {"sourceEdgeCorrelation": round(float(corr), 4),
                                    "meanLinearY": round(float(y[box].mean()), 5)}
        report["results"][filename] = row
    (directory / "measures.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    measure(parser.parse_args().directory)
