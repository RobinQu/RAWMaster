"""Prepare the four public, frozen 1 MP scope inputs; this script never contacts either provider."""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageOps

PORTRAIT = "Relight this same studio photograph with broad soft daylight from the left. Preserve identity, expression, natural skin texture, clothing, patches, surroundings and framing."
LAKE = "Remove only the red STOP sign and its grey post from this lake. Restore natural ripples and lakebed. Preserve every boat, shoreline, color and all other features."
SEEDREAM_PORTRAIT = "Relight the whole photo as if lit by a broad softbox from camera left. Preserve exactly the same person, face shape, pose, clothing, camera framing and scene."
SEEDREAM_LAKE = "Remove the small bright isolated object from the center of the water and fill it with matching nearby water and ripples. Preserve the terrain, shoreline and horizon."


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(shared, out):
    evidence = Path(__file__).resolve().parents[2] / "030-ai-retouching/evidence/generative-followup"
    out.mkdir(parents=True, exist_ok=False)
    for scope, name, box, prompt in (("whole", "portrait-input.png", None, PORTRAIT),
                                      ("local", "lake-input.png", (480, 496, 992, 1008), LAKE)):
        folder = out / "flux" / scope
        folder.mkdir(parents=True)
        with Image.open(shared / name) as source:
            photo = source.convert("RGB")
            if box:
                photo = photo.crop(box).resize((1024, 1024), Image.Resampling.LANCZOS)
            assert photo.size == (1024, 1024)
            photo.save(folder / "input.png")
        (folder / "prompt.txt").write_text(prompt)
    folder = out / "seedream"
    folder.mkdir()
    for scope, name, box, prompt in (("whole", "relight/source.png", None, SEEDREAM_PORTRAIT),
                                      ("region", "landscape/lake.png", (112, 0, 624, 512), SEEDREAM_LAKE)):
        output = folder / (scope + "-input.png")
        with Image.open(evidence / name) as source:
            photo = source.convert("RGB")
            if box:
                photo = photo.crop(box)
            photo = ImageOps.contain(photo, (1024, 1024), Image.Resampling.LANCZOS)
            photo.resize((1024, 1024), Image.Resampling.LANCZOS).save(output)
        (folder / (scope + ".json")).write_text(json.dumps(dict(source=name, crop=box, inputSHA256=digest(output), prompt=prompt), indent=2) + "\n")


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--shared-inputs", required=True, type=Path, help="030 files produced by poc/fixtures.py")
    cli.add_argument("--out", required=True, type=Path)
    args = cli.parse_args()
    prepare(args.shared_inputs, args.out)
