"""Recompute coverage and the review sheet from mask-ai-probe PNGs and receipts."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw


CASES = [
    ("person", "person.ARW", ["people-entirePerson", "people-faceSkin"]),
    ("bright-snow", "bright-snow.NEF", ["landscape-snow"]),
    ("snow", "snow.ARW", ["landscape-snow"]),
    ("cottage", "cottage.NEF", ["landscape-snow"]),
]
MODELS = {
    "dfine-s-coco": "dfine-s-coco/model_quantized.onnx",
    "slimsam-encoder": "slimsam/vision_encoder_quantized.onnx",
    "slimsam-decoder": "slimsam/prompt_encoder_mask_decoder_quantized.onnx",
    "selfie-multiclass": "selfie-multiclass/model.onnx",
    "efficientvit-seg-b2-ade20k": "efficientvit-seg-b2-ade20k/model.onnx",
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("images", type=Path)
    parser.add_argument("models", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--scene-weights", type=Path,
                        help="Also compare approved-scene/<id>.png from this separately exported ONNX.")
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    report = {"thresholdGray8": 128, "modelsSHA256": {}, "cases": []}
    if args.scene_weights:
        report["otherSceneExportSHA256"] = digest(args.scene_weights)
    sheet = Image.new("RGB", (960, 960), "#202124")
    draw = ImageDraw.Draw(sheet)
    for i, (name, filename, operations) in enumerate(CASES):
        source = json.loads((args.images / (name + "-oriented.json")).read_text())
        if digest(args.images / filename) != source["sourceSHA256"]:
            raise ValueError("Source SHA mismatch: " + filename)
        base = Image.open(args.images / (name + "-oriented.png")).convert("RGB")
        base.thumbnail((310, 210))
        row = {"id": name, "source": source, "masks": {}}
        report["cases"].append(row)
        panels = [("source", base)]
        for op in operations:
            stem = name + "-" + op
            mask = Image.open(args.images / (stem + ".png")).convert("L")
            receipt = json.loads((args.images / (stem + ".json")).read_text())
            histogram = mask.histogram()
            for model in receipt["modelIDs"]:
                if model not in report["modelsSHA256"]:
                    report["modelsSHA256"][model] = digest(args.models / MODELS[model])
            pixels = mask.width * mask.height
            row["masks"][op] = {
                "size": list(mask.size), "pixelsAtOrAbove128": sum(histogram[128:]),
                "fractionAtOrAbove128": sum(histogram[128:]) / pixels,
                "meanAlpha": sum(k * v for k, v in enumerate(histogram)) / pixels / 255,
                "maxGray8": mask.getextrema()[1], "modelIDs": receipt["modelIDs"],
            }
            if args.scene_weights and op == "landscape-snow":
                from PIL import ImageChops
                other = Image.open(args.images / "approved-scene" / (name + ".png")).convert("L")
                if mask.size != other.size:
                    raise ValueError("Different scene mask dimensions")
                delta = ImageChops.difference(mask, other)
                row["masks"][op]["otherExportMaxGray8Difference"] = delta.getextrema()[1]
                row["masks"][op]["otherExportPixelsDifferent"] = pixels - delta.histogram()[0]
            tint = Image.blend(base, Image.new("RGB", base.size, "#ff2266"), 0.65)
            panels.append((op, Image.composite(tint, base, mask.resize(base.size, Image.Resampling.BILINEAR))))
        for j, (label, panel) in enumerate(panels):
            sheet.paste(panel, (320*j + (320 - panel.width)//2, 240*i))
            draw.text((320*j + 8, 240*i + 216), name + "  /  " + label, fill="white")
    (args.destination / "raw-fixture-results.json").write_text(json.dumps(report, indent=2) + "\n")
    sheet.save(args.destination / "raw-fixture-review.jpg", quality=89)


if __name__ == "__main__":
    main()
