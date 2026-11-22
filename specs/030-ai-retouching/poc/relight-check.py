"""Create the controlled lighting reference and measure registered face/background regions.

Run with the imaging research Python that provides numpy, Pillow and scikit-image.
The two cheek regions and background patches are fixed on the 512px NASA source.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from skimage import data

ORIGINAL_SHA = "88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5"
HOPPER_SHA = "a8ca6d734765703b09728ab47fe59f473d93ae3967fc24c7c0288c3c7adb7130"
BASE = ("Edit only the lighting of the person in the FIRST image. Return the same original "
        "square NASA studio photograph with the same identity, expression, pose, eyes, hair, "
        "lettering on the suit, helmet, flags, spacecraft and camera framing. Preserve the studio "
        "background exactly and do not add or remove objects. Use natural-looking skin texture. ")
PRESET = BASE + ("Relight the face with a single broad neutral softbox at image-right, above eye level; "
                 "the viewer-right cheek should be visibly brighter than the viewer-left cheek, with "
                 "a soft nose shadow falling toward image-left. No change to the global exposure.")
REFERENCE = BASE + ("Use the SECOND image only as a lighting reference. Transfer its key-light direction "
                    "and soft contrast to the face, without copying the sphere, background or geometry "
                    "of the reference. No change to the global exposure.")
CHEEKS = {"viewerLeft": (188, 113, 200, 125), "viewerRight": (236, 113, 248, 125)}
BACKGROUND = [(10, 12, 64, 58), (411, 15, 486, 55), (465, 164, 501, 205)]

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def prepare(out, reference_photo):
    original = Path(data.data_dir) / "astronaut.png"
    if sha(original) != ORIGINAL_SHA:
        raise ValueError("Unexpected NASA fixture")
    (out / "source.png").write_bytes(original.read_bytes())
    y, x = np.mgrid[:512, :512]
    nx, ny = (x - 256) / 167, (256 - y) / 167
    squared = nx * nx + ny * ny
    nz = np.sqrt(np.maximum(0, 1 - squared))
    light = np.array([0.83, 0.30, 0.46])
    light /= np.linalg.norm(light)
    diffuse = np.maximum(0, light[0] * nx + light[1] * ny + light[2] * nz)
    value = np.where(squared <= 1, 0.07 + 0.73 * diffuse, 0.12)
    srgb = np.where(value <= 0.0031308, 12.92 * value, 1.055 * value ** (1/2.4) - 0.055)
    Image.fromarray(np.round(srgb*255).astype(np.uint8)).convert("RGB").save(out / "light-sphere.png")
    if reference_photo:
        if sha(reference_photo) != HOPPER_SHA:
            raise ValueError("Unexpected reference portrait")
        frame = np.asarray(Image.open(reference_photo).convert("RGB").crop((0, 0, 512, 512)), dtype=float) / 255
        linear = np.where(frame <= .04045, frame/12.92, ((frame+.055)/1.055)**2.4)
        gain = 0.26 + 1.10 / (1 + np.exp(-(x-253)/30))
        linear = np.clip(linear * gain[..., None], 0, 1)
        rgb = np.where(linear <= .0031308, 12.92 * linear, 1.055 * linear**(1/2.4) - .055)
        Image.fromarray(np.round(rgb*255).astype(np.uint8)).save(out / "light-photo.png")
        (out / "photo.txt").write_text(REFERENCE.replace("the sphere, background or geometry", "the other person's identity, uniform, background or geometry"))
    for name, prompt in [("preset", PRESET), ("reference", REFERENCE)]:
        (out / (name + ".txt")).write_text(prompt)

def pixels(p):
    a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float64)
    if a.shape != (512, 512, 3):
        raise ValueError(f"Unexpected dimensions {a.shape}")
    return a

def extract(a, rect):
    x0, y0, x1, y1 = rect
    return a[y0:y1, x0:x1]

def measure(out):
    source = pixels(out / "source.png")
    reports = {}
    for name in ["source", "preset", "reference", "photo"]:
        f = out / (name + ".png")
        a = pixels(f)
        srgb = a/255
        linear = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb+0.055)/1.055)**2.4)
        luminance = linear @ np.array([0.2126, 0.7152, 0.0722])
        vals = [float(extract(luminance, rect).mean()) for rect in CHEEKS.values()]
        drift = np.concatenate([extract(abs(a-source), box).reshape(-1, 3) for box in BACKGROUND])
        reports[name] = {"sha256": sha(f), "linearCheeks": [round(v, 5) for v in vals],
                         "rightOverLeftEV": round(float(np.log2(vals[1]/vals[0])), 3),
                         "backgroundMeanAbsRGB8": round(float(drift.mean()), 2)}
        metrics = f.with_suffix(".metrics.json")
        if metrics.exists():
            doc = json.loads(metrics.read_text())
            reports[name]["engineMetrics"] = {k:doc[k] for k in ["wall_seconds", "compute_seconds", "peak_mlx_active_bytes", "peak_physical_footprint_bytes"]}
    record = {"model": "FLUX.3 Image Klein MLX Q8, q8-16", "seed": 31903,
              "originalSha256": ORIGINAL_SHA, "sphereSha256": sha(out/"light-sphere.png"),
              "lightingPhotoSha256": sha(out/"light-photo.png"), "referenceOriginalSha256": HOPPER_SHA,
              "cheekRegions": CHEEKS, "backgroundRegions": BACKGROUND, "results": reports}
    (out/"measures.json").write_text(json.dumps(record, indent=2)+"\n")

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("step", choices=["prepare","measure"])
    ap.add_argument("directory", type=Path)
    ap.add_argument("--reference-photo", type=Path)
    args = ap.parse_args()
    if args.step == "prepare" and args.reference_photo is None:
        ap.error("prepare requires --reference-photo pointing to the original Grace Hopper JPEG")
    args.directory.mkdir(parents=True, exist_ok=True)
    if args.step == "prepare":
        prepare(args.directory, args.reference_photo)
    else:
        measure(args.directory)
