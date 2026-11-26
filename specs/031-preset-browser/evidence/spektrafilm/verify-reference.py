"""Compare the expanded atlas to direct development of two tagged sRGB photographic inputs."""
import argparse
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys

import numpy as np
from PIL import Image, PngImagePlugin
from scipy.interpolate import RegularGridInterpolator

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
spec = spec_from_file_location("bake", ROOT / "scripts/bake-spektrafilm-filters.py")
bake = module_from_spec(spec)
spec.loader.exec_module(bake)
CASES = {
    "person": ("Hung Pham", "https://discuss.pixls.us/t/cinematic-portrait-in-golden-hour/54881"),
    "snow": ("Sean Liu", "https://discuss.pixls.us/t/snow-and-sunset/55869"),
}


def encode(value):
    value = np.clip(value, 0, 1)
    return np.where(value <= 0.0031308, 12.92 * value, 1.055 * value ** (1 / 2.4) - 0.055)


def summary(error):
    return {"mean": float(error.mean()), "p99": float(np.quantile(error, 0.99)), "max": float(error.max())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("photos", type=Path, nargs="?", help="Optional folder with opaque, tagged person-oriented.png and snow-oriented.png")
    parser.add_argument("--assets", type=Path, default=bake.ASSETS)
    parser.add_argument("--destination", type=Path, default=ROOT / "Tests/RAWMasterImagingTests/Fixtures/Spektrafilm")
    parser.add_argument("--report", type=Path, default=HERE / "direct-comparison-v2.json")
    args = parser.parse_args()
    sys.path.insert(0, str(args.checkout.resolve() / "src"))
    import colour
    profiles = {}
    coordinates = np.broadcast_to((bake.AXIS / 65535), (3, 64))
    for name, pair in bake.LOOKS.items():
        atlas = np.fromfile(args.assets / (name + "-100.delta64.rgba32f"), dtype="<f4").reshape(64, 64, 64, 4)
        profiles[name] = (bake.simulator(*pair), bake.simulator(*pair, input_space="ProPhoto RGB", encoded_output=True),
                          RegularGridInterpolator(tuple(coordinates), atlas[:, :, :, :3]))
    report = {"referenceRevision": bake.REVISION, "photoLicense": "CC BY-SA 4.0", "sampleWidth": 160, "sampleHeight": 240,
              "columns": ["Input"] + list(bake.LOOKS), "photos": {}}
    fixture = ROOT / "Tests/RAWMasterImagingTests/Fixtures/Spektrafilm"
    args.destination.mkdir(parents=True, exist_ok=True)
    for label, (credit, url) in CASES.items():
        src = args.photos / (label + "-oriented.png") if args.photos else fixture / (label + ".png")
        with Image.open(src) as original:
            if "srgb" not in original.info or original.mode not in ("RGB", "RGBA"):
                raise ValueError("Expected an RGB or opaque RGBA photographic input tagged with the PNG sRGB chunk")
            if original.mode == "RGBA" and original.getchannel("A").getextrema() != (255, 255):
                raise ValueError("Expected an opaque photographic input")
            intent = original.info["srgb"]
            if args.photos:
                image = original.convert("RGB").resize((160, 240), Image.Resampling.LANCZOS)
            else:
                if original.size != (640, 240):
                    raise ValueError("Expected the original input plus three frozen reference columns")
                image = original.crop((0, 0, 160, 240)).convert("RGB")
        code = np.asarray(image).astype(np.float64) / 255
        original = bake.linear(code)
        prophoto = colour.RGB_to_RGB(original, "sRGB", "ProPhoto RGB", apply_cctf_decoding=False, apply_cctf_encoding=False)
        info = {"creator": credit, "source": url, "inputSourceSHA256": bake.sha(src),
                "inputKind": "oriented RAW preview" if args.photos else "unfiltered first column of the frozen sRGB photographic fixture",
                "inputRGB8SHA256": hashlib.sha256(np.asarray(image).tobytes()).hexdigest(),
                "looks": {}, "pairwiseMeanDifference8": {}}
        outputs = {"Input": code}
        for name, (direct, previous_contract, interpolator) in profiles.items():
            expected = direct.process(original)
            displayed = encode(expected)
            trilinear = original + interpolator(code[:, :, ::-1])
            old = previous_contract.process(prophoto)
            info["looks"][name] = {
                "atlasVsDirectLinear": summary(np.abs(trilinear - expected)),
                "atlasVsDirectDisplay8": summary(255 * np.abs(encode(trilinear) - displayed)),
                "linearSRGBVsConvertedProPhotoDisplay8": summary(255 * np.abs(displayed - old)),
            }
            for before, value in outputs.items():
                info["pairwiseMeanDifference8"][before + " / " + name] = float(255 * np.abs(value - displayed).mean())
            outputs[name] = displayed
        # Strip 0 is the unfiltered photo. Each remaining strip is an independent upstream reference.
        strip = np.rint(255 * np.concatenate(list(outputs.values()), axis=1)).astype(np.uint8)
        png_info = PngImagePlugin.PngInfo()
        png_info.add(b"sRGB", bytes([intent]))
        png_info.add_text("Copyright", f"Photograph by {credit}, {url}; source, resized image and derived grades CC BY-SA 4.0.")
        png_info.add_text("Description", "Input | " + " | ".join(bake.LOOKS) + ". Official film profiles by Andrea Volpato, CC BY-SA 4.0. Derived by RAWMaster.")
        path = args.destination / (label + "-catalog-v2.png")
        Image.fromarray(strip).save(path, pnginfo=png_info)
        info["sourceAndReferencesRGB8SHA256"] = hashlib.sha256(strip.tobytes()).hexdigest()
        report["photos"][label] = info
    bake.write_json(args.report, report)


if __name__ == "__main__":
    main()
