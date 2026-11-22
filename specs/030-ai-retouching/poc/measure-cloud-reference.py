"""Compare both providers on the frozen source grid, using the same two reference cases."""
import argparse
import hashlib
import importlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from pixels import linear

portrait_probe = importlib.import_module("relight-check")
lake_probe = importlib.import_module("scene-style-check")


def read(path, size):
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB").resize(size, Image.Resampling.LANCZOS), dtype=float)


def measure(root):
    reports = {}
    for case, folder, source_file, local_name in [("portrait", "relight", "source.png", "photo.png"),
                                                 ("lake", "landscape", "lake.png", "transferred.png")]:
        ref_dir = root / folder
        source_path = ref_dir / source_file
        with Image.open(source_path) as im:
            size = im.size
        source = read(source_path, size)
        source_edges = lake_probe.gradients(lake_probe.luminance(linear(source)))
        reports[case] = {"analysisGrid": size, "resampling": "RGB Lanczos when dimensions differ"}
        for name, path in [("source", source_path), ("flux", ref_dir / local_name), ("seedream", root / "beijing" / (case + ".png"))]:
            arr = read(path, size)
            y = lake_probe.luminance(linear(arr))
            row = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            if case == "portrait":
                cheeks = [portrait_probe.extract(y, roi).mean() for roi in portrait_probe.CHEEKS.values()]
                bg = np.abs(arr-source)
                background = [portrait_probe.extract(bg, roi).ravel() for roi in portrait_probe.BACKGROUND]
                row.update(rightOverLeftEV=round(float(np.log2(cheeks[1]/cheeks[0])), 3),
                           backgroundMeanAbsRGB8=round(float(np.concatenate(background).mean()), 2))
            else:
                edges = lake_probe.gradients(y)
                for region, (x0, y0, x1, y1) in lake_probe.REGIONS.items():
                    box = np.s_[y0:y1, x0:x1]
                    row[region] = round(float(np.corrcoef(source_edges[box].ravel(), edges[box].ravel())[0, 1]), 4)
                row["medianLinearY"] = round(float(np.median(y)), 5)
            reports[case][name] = row
    return reports


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(measure(args.evidence), indent=2) + "\n")
