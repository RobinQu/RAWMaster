"""Prepare two pinned, public photographic controls. Requires Pillow, numpy and scikit-image."""

import argparse
import hashlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps
from scipy.ndimage import distance_transform_edt
from skimage import data

from pixels import composite, linear, srgb8


def verified_image(path, digest):
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError(f"Unexpected source bytes in {path}")
    return Image.open(path).convert("RGB")


def change_ev(image, alpha, stops):
    return Image.fromarray(srgb8(linear(image) * 2.0 ** (stops * alpha[:, :, None])))


def prepare_lake(source, directory):
    truth = ImageOps.fit(source, (1024, 1024), method=Image.Resampling.LANCZOS)
    truth.save(directory / "lake-truth.png")
    marked = truth.copy()
    draw = ImageDraw.Draw(marked)
    draw.rectangle((803, 809, 814, 845), fill=(88, 93, 95))
    draw.rounded_rectangle((744, 751, 873, 815), radius=5, fill=(217, 24, 31), outline="white", width=3)
    draw.text((809, 783), "STOP", font=ImageFont.load_default(size=28), fill="white", anchor="mm")
    marked.save(directory / "lake-input.png")
    # Sidecar support extends past the object by 10+ pixels to inspect transitions.
    mask = Image.new("L", truth.size)
    ImageDraw.Draw(mask).rounded_rectangle((728, 735, 889, 861), radius=12, fill=255)
    distance = distance_transform_edt(np.asarray(mask) > 0)
    mask = Image.fromarray(np.rint(np.minimum(distance / 10, 1) * 255).astype("uint8"))
    mask.save(directory / "lake-matte.png")
    # User-directed clone: sample clean water 126 px below the whole selection.
    donor = np.asarray(marked).copy()
    donor[735:862, 728:890] = np.asarray(marked)[861:988, 728:890]
    Image.fromarray(composite(marked, donor, mask)).save(directory / "lake-baseline.png")


def prepare_portrait(source, directory):
    truth = source.resize((1024, 1024), Image.Resampling.LANCZOS)
    truth.save(directory / "portrait-truth.png")
    y, x = np.ogrid[:1024, :1024]
    radius = np.sqrt(((x - 452) / 122) ** 2 + ((y - 246) / 151) ** 2)
    alpha = np.clip((1 - radius) / 0.40, 0, 1)
    mask = Image.fromarray(np.rint(alpha * 255).astype("uint8"))
    mask.save(directory / "portrait-matte.png")
    shadow = change_ev(truth, alpha, -1.0)
    shadow.save(directory / "portrait-input.png")
    # Reference operation: known selection, fixed +0.70 EV, no model or fitting to output.
    change_ev(shadow, alpha, 0.70).save(directory / "portrait-baseline.png")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lake", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    lake = verified_image(args.lake, "503aa25139ab5cabccdc919c4e76643b97e51cf202643766d9606ad36406c442")
    portrait = verified_image(Path(data.data_dir) / "astronaut.png",
                              "88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5")
    prepare_lake(lake, args.out)
    prepare_portrait(portrait, args.out)
