#!/usr/bin/env python3
"""Compare the 8-step subset with the 16-step Rust worker on the 030 task cases."""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import binary_dilation, binary_erosion
from skimage.metrics import structural_similarity

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "poc"))

from evaluate import CROPS, measure, rgb  # noqa: E402
from pixels import composite, linear  # noqa: E402


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def psnr(a, b):
    error = (a.astype(np.float64) - b.astype(np.float64)) ** 2
    mse = float(error.mean())
    return 99.0 if mse == 0 else round(float(10 * np.log10(255 ** 2 / mse)), 4)


def ssim(a, b):
    return round(float(structural_similarity(a, b, channel_axis=2, data_range=255)), 6)


def difference(a, b, gain=6):
    delta = np.abs(a.astype(np.int16) - b.astype(np.int16)).astype(np.uint16) * gain
    return np.clip(delta, 0, 255).astype(np.uint8)


def sheet(case, columns, destination):
    labels = {"input": "Input", "step8": "Rust 8-step", "step16": "Rust 16-step", "truth": "Clean reference", "diff": "8 vs 16 x6"}
    cell = 244
    panels = [(name, np.asarray(image)) for name, image in columns.items()]
    canvas = Image.new("RGB", (12 + (cell + 12) * len(panels), 704), "#f6f4f0")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=18)
    for index, (name, source) in enumerate(panels):
        x = 12 + index * (cell + 12)
        draw.text((x, 8), labels[name], font=font, fill="#20221e")
        image = Image.fromarray(source)
        canvas.paste(image.resize((cell, cell), Image.Resampling.LANCZOS), (x, 40))
        for box, y in zip(CROPS[case], (296, 500)):
            canvas.paste(image.crop(box), (x, y))
    canvas.save(destination, "JPEG", quality=94, subsampling=0)


def evaluate(inputs, evidence, output):
    output.mkdir(parents=True, exist_ok=True)
    report = {
        "units": "8-bit RGB code values, interpreted as sRGB",
        "config": {
            "worker": "rawmaster-flux-rust-mlx-v1",
            "weightsRevision": "d9790a1ceaba200e8b773fb236f7c9fa754283a7",
            "seed": 8521,
            "step8Grid": [0, 2, 4, 6, 8, 10, 13, 15, 16],
            "step16": "uniform 16-step schedule",
        },
        "cases": {},
    }
    for case in CROPS:
        paths = {kind: inputs / f"{case}-{kind}.png" for kind in ("input", "truth", "matte")}
        original, truth = rgb(paths["input"]), rgb(paths["truth"])
        with Image.open(paths["matte"]) as matte:
            mask = np.array(matte.convert("L"))
        target = np.any(original != truth, axis=2) if case == "lake" else mask >= 128
        support = mask > 0
        boundary = binary_dilation(support, iterations=5) & ~binary_erosion(support, iterations=5)
        columns = {"input": Image.fromarray(original), "truth": Image.fromarray(truth)}
        runs, applied = {}, {}
        for steps in (8, 16):
            path = evidence / f"{case}-{steps}.png"
            candidate = rgb(path)
            applied[steps] = composite(original, candidate, mask)
            if case == "portrait":
                weights = np.array([0.2126, 0.7152, 0.0722])
                face_ev = float(np.log2(
                    (linear(applied[steps][target]) @ weights).mean()
                    / (linear(truth[target]) @ weights).mean()
                ))
            else:
                face_ev = None
            row = measure(original, truth, candidate, applied[steps], mask, target, boundary, case)
            row.update({
                "candidate_sha256": sha(path),
                "step8_delta_target_mae": None,
                "applied_face_ev_vs_truth": None if face_ev is None else round(face_ev, 3),
            })
            if row["applied_exterior_max"] != 0:
                raise ValueError(f"composite changed protected pixels: {case} {steps}")
            runs[f"step{steps}"] = row
            columns[f"step{steps}"] = Image.fromarray(candidate)
        runs["step8"]["step8_delta_target_mae"] = round(
            runs["step8"]["raw_target_mae"] - runs["step16"]["raw_target_mae"], 3
        )
        runs["step16"]["step8_delta_target_mae"] = 0.0
        raw8, raw16 = rgb(evidence / f"{case}-8.png"), rgb(evidence / f"{case}-16.png")
        comparison = {
            "raw_psnr_db": psnr(raw8, raw16),
            "raw_ssim": ssim(raw8, raw16),
            "raw_max_abs_diff": int(np.abs(raw8.astype(np.int16) - raw16.astype(np.int16)).max()),
            "applied_psnr_db": psnr(applied[8], applied[16]),
            "applied_ssim": ssim(applied[8], applied[16]),
            "applied_max_abs_diff": int(np.abs(applied[8].astype(np.int16) - applied[16].astype(np.int16)).max()),
            "target_mae_8_minus_16": round(
                runs["step8"]["raw_target_mae"] - runs["step16"]["raw_target_mae"], 3
            ),
        }
        report["cases"][case] = {
            "assets_sha256": {name: sha(path) for name, path in paths.items()},
            "runs": runs,
            "step8_vs_step16": comparison,
        }
        columns["diff"] = Image.fromarray(difference(rgb(evidence / f"{case}-8.png"), rgb(evidence / f"{case}-16.png")))
        sheet(case, columns, output / f"{case}-8v16.jpg")
    (output / "8v16-metrics.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    options = parser.parse_args()
    evaluate(options.inputs, options.evidence, options.out)
