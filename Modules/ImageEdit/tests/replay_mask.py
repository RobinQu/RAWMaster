#!/usr/bin/env python3
"""Exercise the production C ABI on a pinned photograph and its frozen EfficientViT sky mask.

prepare needs Pillow. verify uses only Python's standard library and the caller's dylib/so.
Run `python3 replay_mask.py prepare <directory>`, then `... verify <directory> <library> cpu|gpu`.
Use `prepare <directory> --full-frame` for the 1600×1067 original, or `--crop-4k` for a
registered nearest-neighbor 3840×2160 workload from its center 1600×900 crop.
"""

from array import array
import argparse
import ctypes as c
from hashlib import sha256
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
BINDINGS = ROOT / "specs/035-portable-processing-cores/evidence/sky-bindings.json"
CATALOG = ROOT / "Sources/RAWMasterImaging/Resources/PhotoFilters"


def digest(data):
    return sha256(data).hexdigest()


def little_bytes(floats):
    values = array("f", floats)
    if sys.byteorder != "little":
        values.byteswap()
    return values.tobytes()


def prepare(directory, full_frame, crop_4k):
    from PIL import Image

    photo = ROOT / "specs/030-ai-retouching/evidence/mountain-lake.jpg"
    matte = BINDINGS.with_name("sky-mask.png")
    binding = json.loads(BINDINGS.read_text())[0]
    assert digest(photo.read_bytes()) == binding["sourceSHA256"]
    assert digest(matte.read_bytes()) == binding["maskSHA256"]
    linear = [
        v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
        for v in (n / 255 for n in range(256))
    ]
    with Image.open(photo) as rgb, Image.open(matte) as mask:
        if (
            rgb.mode != "RGB"
            or mask.mode != "L"
            or rgb.size != mask.size
            or rgb.size != (1600, 1067)
        ):
            raise ValueError("Fixture geometry or encoding changed")
        if crop_4k:
            box = (0, 83, 1600, 983)
            rgb = rgb.resize((3840, 2160), Image.Resampling.NEAREST, box=box)
            mask = mask.resize((3840, 2160), Image.Resampling.NEAREST, box=box)
        xs = range(rgb.width) if full_frame or crop_4k else range(4, rgb.width, 10)
        ys = range(rgb.height) if full_frame or crop_4k else range(4, rgb.height, 10)
        rgb_pixels, mask_pixels = rgb.load(), mask.load()
        rgba, coverage = array("f"), array("f")
        for y in ys:
            for x in xs:
                r, g, b = rgb_pixels[x, y]
                rgba.extend((linear[r], linear[g], linear[b], 1.0))
                coverage.append(mask_pixels[x, y] / 255)
    directory.mkdir(parents=True, exist_ok=True)
    image, mask = little_bytes(rgba), little_bytes(coverage)
    (directory / "source.rgba32fle").write_bytes(image)
    (directory / "mask.r32fle").write_bytes(mask)
    manifest = {
        "binding": binding,
        "size": [len(xs), len(ys)],
        "sourceF32SHA256": digest(image),
        "maskF32SHA256": digest(mask),
        "sampling": (
            "3840x2160 nearest-neighbor expansion of original top-left crop (0,83,1600,983), identical pixel-center mapping for image and mask"
            if crop_4k
            else "full original top-left pixel grid"
            if full_frame
            else "top-left oriented matched (x,y)=(4+10i,4+10j)"
        )
        + "; JPEG is tagged sRGB; inverse sRGB EOTF, alpha 1; mask grey/255",
    }
    (directory / "prepared.json").write_text(json.dumps(manifest, indent=2) + "\n")


def load(directory, file, expected):
    data = (directory / file).read_bytes()
    if digest(data) != expected:
        raise ValueError("Corrupt prepared input: " + file)
    floats = array("f")
    floats.frombytes(data)
    if sys.byteorder != "little":
        floats.byteswap()
    return (c.c_float * len(floats)).from_buffer_copy(floats)


def verify(directory, library, backend, pixel_path):
    manifest = json.loads((directory / "prepared.json").read_text())
    width, height = manifest["size"]
    rgba = load(directory, "source.rgba32fle", manifest["sourceF32SHA256"])
    mask = load(directory, "mask.r32fle", manifest["maskF32SHA256"])
    assert len(rgba) == 4 * width * height and len(mask) == width * height
    api = c.CDLL(str(library.resolve()))
    handle = c.c_void_p
    floats = c.POINTER(c.c_float)
    api.rm_image_plan_open_v1.argtypes = [
        c.c_char_p,
        c.c_size_t,
        c.c_char_p,
        c.c_size_t,
        c.c_uint32,
        c.POINTER(handle),
    ]
    api.rm_image_plan_render_v1.argtypes = [
        handle,
        c.c_uint32,
        c.c_uint32,
        floats,
        c.c_size_t,
        floats,
        c.c_size_t,
        floats,
        c.c_size_t,
    ]
    api.rm_image_plan_close_v1.argtypes = [handle]
    api.rm_image_plan_close_v1.restype = None
    assert api.rm_image_abi_version() == 1
    root = bytes(CATALOG)
    source = {"id": "src", "op": "source"}
    coverage = {"id": "sky", "op": "mask"}
    global_ev = {"id": "global", "op": "exposure", "image": "src", "ev": 0.25}
    local_ev = {
        "id": "local",
        "op": "masked_exposure",
        "image": "global",
        "mask": "sky",
        "ev": -1.25,
    }
    look = {
        "id": "look",
        "op": "photo_filter",
        "look": "vivid",
        "amount": 37.5,
        "image": "local",
    }
    blend = {
        "id": "result",
        "op": "blend",
        "base": "global",
        "layer": "look",
        "mask": "sky",
    }

    def render(nodes, image, selected, device):
        graph = json.dumps(
            {
                "version": 1,
                "working": "extended-linear-srgb-premul-f32",
                "output": nodes[-1]["id"],
                "nodes": nodes,
            }
        ).encode()
        plan = handle()
        output = (c.c_float * len(image))()
        status = api.rm_image_plan_open_v1(
            graph, len(graph), root, len(root), device, c.byref(plan)
        )
        if status:
            raise RuntimeError(f"plan open returned {status}")
        try:
            status = api.rm_image_plan_render_v1(
                plan,
                width,
                height,
                image,
                len(image),
                selected,
                len(selected) if selected is not None else 0,
                output,
                len(output),
            )
            if status:
                raise RuntimeError(f"plan render returned {status}")
        finally:
            api.rm_image_plan_close_v1(plan)
        return output

    device = 0 if backend == "cpu" else 1
    global_pixels = render([source, global_ev], rgba, None, 0)
    local_pixels = render([source, coverage, global_ev, local_ev], rgba, mask, device)
    filtered = render([source, {**look, "image": "src"}], local_pixels, None, 0)
    result = render(
        [source, coverage, global_ev, local_ev, look, blend], rgba, mask, device
    )
    max_mask_error = max_compound_error = 0.0
    zero = fractional = changed = 0
    for i, value in enumerate(mask):
        gain = 2 ** (-1.25 * value)
        j = 4 * i
        for k in range(j, j + 3):
            max_mask_error = max(
                max_mask_error, abs(local_pixels[k] - rgba[k] * 2**0.25 * gain)
            )
            expected = global_pixels[k] + value * (filtered[k] - global_pixels[k])
            max_compound_error = max(max_compound_error, abs(result[k] - expected))
        assert local_pixels[j + 3] == result[j + 3] == 1
        if value == 0:
            zero += 1
            assert (
                result[j : j + 4] == global_pixels[j : j + 4] == local_pixels[j : j + 4]
            )
        else:
            fractional += int(value < 1)
            changed += int(result[j : j + 3] != global_pixels[j : j + 3])
    if (
        max_mask_error >= 2e-5
        or max_compound_error >= 2e-4
        or min(zero, fractional, changed) == 0
    ):
        raise RuntimeError("Coverage or pixel parity failed")
    result_bytes = little_bytes(result)
    if pixel_path is not None:
        pixel_path.write_bytes(result_bytes)
    print(
        json.dumps(
            {
                "abi": 1,
                "backend": backend,
                "size": [width, height],
                "sourceSHA256": manifest["binding"]["sourceSHA256"],
                "maskSHA256": manifest["binding"]["maskSHA256"],
                "modelSHA256": manifest["binding"]["modelSHA256"],
                "sourceF32SHA256": manifest["sourceF32SHA256"],
                "maskF32SHA256": manifest["maskF32SHA256"],
                "zeroExact": zero,
                "fractional": fractional,
                "changedCovered": changed,
                "maxMaskedAbsError": max_mask_error,
                "maxBranchedLutAbsError": max_compound_error,
                "rgbaOutputSHA256": digest(result_bytes),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    groups = parser.add_subparsers(dest="command", required=True)
    prep = groups.add_parser("prepare")
    prep.add_argument("directory", type=Path)
    resolution = prep.add_mutually_exclusive_group()
    resolution.add_argument("--full-frame", action="store_true")
    resolution.add_argument("--crop-4k", action="store_true")
    check = groups.add_parser("verify")
    check.add_argument("directory", type=Path)
    check.add_argument("library", type=Path)
    check.add_argument("backend", choices=["cpu", "gpu"])
    check.add_argument(
        "--pixels",
        type=Path,
        help="also write the verified result as RGBA F32 little endian",
    )
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.directory, args.full_frame, args.crop_4k)
    else:
        verify(args.directory, args.library, args.backend, args.pixels)
