"""Measure positive IoU and false selected area on Stanford Background labels."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile

import numpy as np
from PIL import Image


ARCHIVE_SHA256 = "b58b6cc2be86322a94d1b7116ab8f7a8b01d88ea57ba286ce2cd85d247637db3"
# Tuple items are label ID, four positive cases and four absent cases. For each
# class, order IDs by sha256("RAWMaster030:" + id), then take the first four
# with >=1% labeled area and first four with zero labeled area, respectively.
CASES = {
    "sky": (0, ("6000079", "0007323", "6000195", "6000229"), ("6000047", "9004965", "5000149", "0002755")),
    "water": (4, ("0007323", "8002274", "8006302", "5000137"), ("6000079", "6000047", "6000195", "6000229")),
    "mountains": (6, ("0007323", "8002274", "8006302", "0102234"), ("6000079", "6000047", "6000195", "6000229")),
}


def evaluate(out, model_root):
    package = Path("experiments/MaskAI").resolve()
    rows = []
    for target, (label, positive, absent) in CASES.items():
        for sample in (*positive, *absent):
            image = out / (sample + ".jpg")
            predicted = out / (sample + "-" + target + ".png")
            subprocess.run(
                [package / ".build/debug/mask-ai-probe", "landscape", target, image, predicted],
                check=True, env={**os.environ, "MASK_AI_MODELS": str(model_root)},
            )
            truth = np.loadtxt(out / (sample + ".regions.txt"), dtype=int)
            pred = np.asarray(Image.open(predicted).convert("L")) >= 128
            assert pred.shape == truth.shape
            known = truth >= 0
            selected = pred & known
            relevant = truth == label
            assert (relevant.sum() / known.sum() >= 0.01) if sample in positive else not relevant.any()
            rows.append({
                "case": sample, "target": target, "positive": bool(relevant.any()),
                "iou": round(float((relevant & selected).sum() / (relevant | selected).sum()), 4) if relevant.any() else None,
                "selectedFractionOfKnownPixels": round(float(selected.sum() / known.sum()), 6),
                "labeledFractionOfKnownPixels": round(float(relevant.sum() / known.sum()), 6),
            })
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--models", type=Path, default=Path("experiments/MaskAI/Vendor/Models"))
    args = parser.parse_args()
    if hashlib.sha256(args.archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("Unexpected Stanford Background archive digest")
    args.out.mkdir(parents=True, exist_ok=True)
    cases = {case for _, positive, absent in CASES.values() for case in (*positive, *absent)}
    wanted = {case + suffix for case in cases for suffix in (".jpg", ".regions.txt")}
    with tarfile.open(args.archive, "r|gz") as archive:
        for member in archive:
            filename = Path(member.name).name
            if filename in wanted and member.isfile():
                (args.out / filename).write_bytes(archive.extractfile(member).read())
    model = args.models / "efficientvit-seg-b2-ade20k/model.onnx"
    result = {"archiveSHA256": ARCHIVE_SHA256, "modelSHA256": hashlib.sha256(model.read_bytes()).hexdigest(),
              "cases": evaluate(args.out, args.models.resolve())}
    (args.out / "landscape-results.json").write_text(json.dumps(result, indent=2) + "\n")
