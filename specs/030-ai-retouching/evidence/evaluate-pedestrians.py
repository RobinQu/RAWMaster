"""Evaluate the standalone MaskAI CLI against a fixed Penn–Fudan sample.

Run from the repository root. The report describes the dataset and commands.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

import numpy as np
from PIL import Image, ImageFilter


ARCHIVE_SHA256 = "9095a9613c95586f1c7f2a327d454833d16e0f5e17e5f83d35027ffd315b48e2"
CASES = {"Fudan": (1, 9, 20, 35, 50, 65), "Penn": (1, 15, 30, 50, 71, 90)}
PACKAGE = Path("experiments/MaskAI").resolve()
BOX = re.compile(r"box: MaskAI\.NormalizedRect\(x: ([^,]+), y: ([^,]+), width: ([^,]+), height: ([^)]+)\)")


def probe(*args, allow_no_people=False):
    result = subprocess.run(
        [PACKAGE / ".build/debug/mask-ai-probe", *args], text=True, capture_output=True,
        env={**os.environ, "MASK_AI_MODELS": str(PACKAGE / "Vendor/Models")},
    )
    if allow_no_people and result.returncode == 1 and "No people were detected." in result.stderr:
        return "[]"
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def apply_filter(mask, image_filter):
    return np.asarray(Image.fromarray(mask.astype("uint8")).filter(image_filter), dtype=bool)


def scores(prediction, truth):
    pred = np.asarray(Image.open(prediction).convert("L")) >= 128
    assert pred.shape == truth.shape and truth.any()
    intersection = int((pred & truth).sum())
    # Inner boundaries, symmetric precision/recall within two pixels (Chebyshev).
    pred_edge = pred & ~apply_filter(pred, ImageFilter.MinFilter(3))
    true_edge = truth & ~apply_filter(truth, ImageFilter.MinFilter(3))
    precision = (pred_edge & apply_filter(true_edge, ImageFilter.MaxFilter(5))).sum() / max(1, pred_edge.sum())
    recall = (true_edge & apply_filter(pred_edge, ImageFilter.MaxFilter(5))).sum() / max(1, true_edge.sum())
    return {
        "iou": round(intersection / int((pred | truth).sum()), 4),
        "boundaryF1At2px": round(float(2 * precision * recall / (precision + recall)), 4) if precision + recall else 0,
    }


def box_of(mask):
    ys, xs = np.where(mask)
    h, w = mask.shape
    return xs.min() / w, ys.min() / h, (xs.max() + 1) / w, (ys.max() + 1) / h


def box_iou(a, b):
    iw = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    ih = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    area = lambda r: (r[2] - r[0]) * (r[3] - r[1])
    return iw * ih / (area(a) + area(b) - iw * ih)


def matched_boxes(pred, true):
    pairs = sorted(((box_iou(a, b), i, j) for i, a in enumerate(pred) for j, b in enumerate(true)), reverse=True)
    used_pred, used_true = set(), set()
    for similarity, i, j in pairs:
        if similarity >= 0.5 and i not in used_pred and j not in used_true:
            used_pred.add(i)
            used_true.add(j)
    return len(used_true)


def evaluate(zipfile_handle, case, out):
    def extract_member(folder, filename):
        member = "PennFudanPed/" + folder + "/" + filename
        return Path(zipfile_handle.extract(member, out))

    image = extract_member("PNGImages", case + ".png")
    truth_path = extract_member("PedMasks", case + "_mask.png")
    labels = np.asarray(Image.open(truth_path))
    instances = [labels == i for i in np.unique(labels) if i]
    true_boxes = [box_of(mask) for mask in instances]
    detections = probe("people", "detect", image, os.devnull, allow_no_people=True)
    pred_boxes = [(x, y, x + w, y + h) for x, y, w, h in (map(float, box) for box in BOX.findall(detections))]
    assert len(pred_boxes) == detections.count("PersonDetection(")
    union = out / (case + "-all.png")
    if pred_boxes:
        probe("people", "entirePerson", image, union)
    else:
        Image.new("L", labels.shape[::-1]).save(union)
    largest = max(range(len(instances)), key=lambda index: instances[index].sum())
    x0, y0, x1, y1 = true_boxes[largest]
    boxed = out / (case + "-box.png")
    probe("object", image, boxed, f"{x0},{y0},{x1-x0},{y1-y0}")
    return {
        "case": case, "imageSize": list(Image.open(image).size),
        "labeledPeople": len(instances), "detections": len(pred_boxes),
        "matchedAtBoxIoU50": matched_boxes(pred_boxes, true_boxes),
        "allPeople": scores(union, labels > 0), "boxTargetLabel": int(labels[instances[largest]][0]),
        "largestPersonWithGroundTruthBox": scores(boxed, instances[largest]),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("out", type=Path, help="Private working directory for images and metrics")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    if hashlib.sha256(args.archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("Unexpected Penn–Fudan archive digest")
    with zipfile.ZipFile(args.archive) as source:
        rows = [evaluate(source, f"{region}Ped{index:05}", args.out) for region, ids in CASES.items() for index in ids]
    report = {"archiveSHA256": ARCHIVE_SHA256, "cases": rows}
    (args.out / "pedestrian-results.json").write_text(json.dumps(report, indent=2) + "\n")
