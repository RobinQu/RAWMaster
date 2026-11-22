"""Measure paired edits against clean plates and render identically cropped review sheets."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import binary_dilation, binary_erosion

from pixels import composite, linear


CROPS = {
    "lake": [(696, 695, 940, 895), (179, 638, 423, 838)],
    "portrait": [(330, 145, 574, 345), (230, 662, 474, 862)],
}
COLUMNS = {"input": "Input", "baseline": "Local control", "flux": "FLUX.3 Q8", "seedream": "Seedream 5.5", "truth": "Clean reference"}


def rgb(path):
    with Image.open(path) as im:
        if im.size != (1024, 1024):
            raise ValueError(f"Unexpected size in {path}")
        return np.array(im.convert("RGB"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def absolute(a, b):
    return np.abs(a.astype(np.int16) - b.astype(np.int16))


def measure(original, truth, candidate, applied, mask, target, ring, case):
    exterior = mask == 0
    outside = absolute(candidate, original)[exterior]
    large_changes = outside.max(axis=1) > 8
    left, top, right, bottom = CROPS[case][1]
    protected_error = absolute(candidate[top:bottom, left:right], original[top:bottom, left:right])
    row = {
        "target_pixels": int(target.sum()),
        "exterior_pixels": int(exterior.sum()),
        "raw_target_mae": round(float(absolute(candidate, truth)[target].mean()), 3),
        "applied_target_mae": round(float(absolute(applied, truth)[target].mean()), 3),
        "raw_exterior_mae": round(float(outside.mean()), 3),
        "raw_exterior_max": int(outside.max()),
        "raw_exterior_any_channel_gt8_pixels": int(large_changes.sum()),
        "raw_exterior_any_channel_gt8_pct": round(float(large_changes.mean() * 100), 3),
        "raw_protected_crop_mae": round(float(protected_error.mean()), 3),
        "applied_exterior_max": int(absolute(applied, original)[exterior].max()),
        "applied_boundary_mae": round(float(absolute(applied, truth)[ring].mean()), 3),
        "applied_pixels_sha256": hashlib.sha256(applied.tobytes()).hexdigest(),
    }
    if case == "portrait":
        weights = [0.2126, 0.7152, 0.0722]
        applied_luma = (linear(applied[target]) @ weights).mean()
        truth_luma = (linear(truth[target]) @ weights).mean()
        row["applied_face_ev_vs_truth"] = round(float(np.log2(applied_luma / truth_luma)), 3)
    return row


def sheet(case, columns, destination):
    cell = 244
    panels = [(name, Image.fromarray(columns[name])) for name in COLUMNS if name in columns]
    canvas = Image.new("RGB", (12 + (cell + 12) * len(panels), 704), "#f6f4f0")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=18)
    for index, (name, source) in enumerate(panels):
        x = 12 + index * (cell + 12)
        draw.text((x, 8), COLUMNS[name], font=font, fill="#20221e")
        canvas.paste(source.resize((cell, cell), Image.Resampling.LANCZOS), (x, 40))
        for box, y in zip(CROPS[case], (296, 500)):
            canvas.paste(source.crop(box), (x, y))
    canvas.save(destination, "JPEG", quality=94, subsampling=0)


def evaluate(inputs, evidence, providers, output):
    output.mkdir(parents=True, exist_ok=True)
    report = {"units": "8-bit RGB code values, interpreted as sRGB", "cases": {}}
    for case in CROPS:
        paths = {kind: inputs / f"{case}-{kind}.png" for kind in ("input", "truth", "baseline", "matte")}
        columns = {kind: rgb(paths[kind]) for kind in ("input", "truth", "baseline")}
        original, truth = columns["input"], columns["truth"]
        with Image.open(paths["matte"]) as matte:
            mask = np.array(matte.convert("L"))
        target = np.any(original != truth, axis=2) if case == "lake" else mask >= 128
        support = mask > 0
        boundary = binary_dilation(support, iterations=5) & ~binary_erosion(support, iterations=5)
        results = {"assets_sha256": {name: sha(path) for name, path in paths.items()}, "runs": {}}
        for control in ("input", "baseline"):
            value = columns[control]
            results["runs"][control] = measure(original, truth, value, value, mask, target, boundary, case)
        for name in providers:
            trials = [case, "lake-repeat"] if case == "lake" else [case]
            for trial in trials:
                path = evidence / name / (trial + ".png")
                candidate = rgb(path)
                applied = composite(original, candidate, mask)
                row = measure(original, truth, candidate, applied, mask, target, boundary, case)
                if row["applied_exterior_max"] != 0:
                    raise ValueError("composite changed protected pixels")
                row["candidate_sha256"] = sha(path)
                results["runs"][f"{name}-{trial}"] = row
                if trial == case:
                    columns[name] = candidate
        report["cases"][case] = results
        sheet(case, columns, output / (case + "-comparison.jpg"))
    (output / "paired-metrics.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--providers", nargs="+", choices=["flux", "seedream"], default=["flux", "seedream"])
    options = parser.parse_args()
    evaluate(options.inputs, options.evidence, options.providers, options.out)
