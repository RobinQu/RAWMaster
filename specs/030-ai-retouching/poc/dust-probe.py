"""Offline injected sensor-spot test on a frozen lake image; no learned model."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter
from skimage.feature import peak_local_max

SPOTS = [(278, 32, 4, .24), (443, 45, 5, .20), (593, 43, 4, .22),
         (63, 345, 5, .28), (458, 324, 4, .25), (505, 449, 5, .22),
         (142, 163, 4, .24), (386, 181, 5, .26)]


def proposals(y):
    local = gaussian_filter(y, 1.6)
    surround = gaussian_filter(y, 8.0)
    texture = gaussian_filter(abs(y - gaussian_filter(y, 1.2)), 6.0)
    score = (surround - local) / np.maximum(surround, 0.02)
    score /= 1.0 + 12.0 * texture / np.maximum(surround, 0.02)
    peaks = peak_local_max(score, min_distance=9, threshold_abs=0.095, exclude_border=12)
    return [(int(x), int(y_)) for y_, x in peaks]


def evaluate(path, output):
    source_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    if source_hash != "e48857c7e657563f473357f97eddc4f53fea94897c2935c3ae829b4fc7fd84b1":
        raise ValueError("Expected the frozen 768 x 512 lake source")
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=float) / 255
    linear = np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)
    clean = linear @ np.array([.2126, .7152, .0722])
    ys, xs = np.indices(clean.shape)
    gain = np.ones(clean.shape)
    for x, y, sigma, depth in SPOTS:
        gain *= 1 - depth * np.exp(-((xs-x)**2 + (ys-y)**2) / (2 * sigma**2))
    candidates = proposals(clean * gain)
    matches = []
    remaining = set(candidates)
    for x, y, _, _ in SPOTS:
        near = [(np.hypot(px-x, py-y), px, py) for px, py in remaining if np.hypot(px-x, py-y) <= 6]
        if near:
            _, px, py = min(near)
            matches.append({"injectedXY": [x, y], "proposedXY": [px, py]})
            remaining.remove((px, py))
    doc = {"sourceSHA256": source_hash, "size": [768, 512], "injectedXYSigmaDepth": SPOTS,
           "matchingRadiusPx": 6, "cleanCandidates": len(proposals(clean)), "injectedCandidates": len(candidates),
           "matched": len(matches), "unmatchedCandidates": len(remaining), "matches": matches}
    output.write_text(json.dumps(doc, indent=2) + "\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", type=Path)
    p.add_argument("output", type=Path)
    args = p.parse_args()
    evaluate(args.source, args.output)
