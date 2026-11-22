#!/usr/bin/env python3
"""Offline asset builder. Run with the pinned upstream checkout and its Python dependencies."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np

REVISION = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
SOURCE = "https://github.com/andreavolpato/spektrafilm"
LOOKS = {
    "spektraPortra400Endura": ("kodak_portra_400", "kodak_portra_endura"),
    "spektraVelvia100": ("fujifilm_velvia_100", None),
    "spektraVision250D2383": ("kodak_vision3_250d", "kodak_2383"),
}
PROFILE = "sRGB IEC 61966-2-1"
OPERATOR = "spektrafilm-v1/srgb-axis64/linear-delta/endpoint-strength/HDR-boundary-residual/alpha-bypass65535"
HERE = Path(__file__).resolve().parents[1]
ASSETS = HERE / "Sources/RAWMasterImaging/Resources/PhotoFilters/Spektrafilm"
PROBES = HERE / "Tests/RAWMasterImagingTests/Fixtures/spektrafilm-v1-reference.json"
AXIS = (65535 * np.arange(64) + 31) // 63


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def linear(code):
    return np.where(code <= 0.04045, code / 12.92, ((code + 0.055) / 1.055) ** 2.4)


def simulator(film, paper, input_space="sRGB", encoded_output=False):
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.process import Simulator
    # A direct positive scan bypasses the print stage. The constructor still requires a print profile.
    p = init_params(film_profile=film, print_profile=paper or "kodak_portra_endura")
    p.settings.use_enlarger_lut = True
    p.settings.use_scanner_lut = True
    p.settings.lut_resolution = 17
    p.debug.lut_mode = True
    p.io.scan_film = paper is None
    p.io.input_color_space = input_space
    p.io.input_cctf_decoding = False
    p.io.output_color_space = "sRGB"
    p.io.output_cctf_encoding = encoded_output
    return Simulator(digest_params(p))


def bake(sim):
    axis = linear(AXIS / 65535)
    table = np.ones((64, 64, 64, 4), dtype="<f4")
    for start in range(0, 64, 8):
        b, g, r = np.meshgrid(axis[start:start + 8], axis, axis, indexing="ij")
        pixels = np.stack([r, g, b], axis=-1)
        output = sim.process(pixels.reshape(8 * 64, 64, 3)).reshape(pixels.shape)
        delta = output - pixels
        if not np.all(np.isfinite(delta)) or np.max(np.abs(delta)) > 1:
            raise ValueError("Unrepresentable linear RGB delta from reference processor")
        table[start:start + 8, :, :, :3] = delta
    return table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    args = parser.parse_args()
    upstream = args.checkout.resolve()
    revision = subprocess.check_output(["git", "-C", upstream, "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise ValueError("Unexpected upstream revision: " + revision)
    subprocess.run(["git", "-C", upstream, "diff", "--quiet", "HEAD", "--", "src/spektrafilm", "SPEKTRAFILM_LICENSE.txt"], check=True)
    sys.path.insert(0, str(upstream / "src"))
    ASSETS.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(upstream / "SPEKTRAFILM_LICENSE.txt", ASSETS / "SPEKTRAFILM_LICENSE.txt")
    names = sorted({name for pair in LOOKS.values() for name in pair if name is not None})
    files = [f"src/spektrafilm/data/profiles/{name}.json" for name in names]
    files += ["src/spektrafilm/data/filters/neutral_print_filters.json", "SPEKTRAFILM_LICENSE.txt"]
    provenance = {
        "source": SOURCE, "revision": REVISION, "originalAuthor": "Andrea Volpato",
        "derivativeAuthor": "RAWMaster contributors", "license": "CC BY-SA 4.0",
        "licenseURL": "https://creativecommons.org/licenses/by-sa/4.0/",
        "sourceFileSHA256": {name: sha(upstream / name) for name in files},
        "dependencies": {name: importlib.metadata.version(name) for name in ("numpy", "numba", "colour-science", "scipy")},
        "input": "Unassociated linear sRGB D65. Grid sampled at inverse IEC 61966-2-1 transfer of 64 rounded 16-bit codes.",
        "output": "Unassociated linear sRGB D65 from the scanner, output CCTF off. The native renderer encodes only at final display/export.",
        "simulation": {"lut_mode": True, "use_enlarger_lut": True, "use_scanner_lut": True, "lut_resolution": 17,
                       "cameraExposureCompensationEV": 0, "printExposure": 1, "stockSpecifics": True},
        "stored": "Little-endian RGBA32Float; linear output minus linear grid input, alpha lane 1. R fastest, then G and B.",
        "strength": "Linear blend from the original to the stock endpoint in working RGB. Outside [0,1] preserve the signed source residual.",
        "looks": {key: {"film": film, "print": paper, "scanFilmDirectly": paper is None} for key, (film, paper) in LOOKS.items()},
    }
    write_json(ASSETS / "provenance.json", provenance)
    # Off-grid samples include the toe, neutrals, skin, foliage, sky and near-white. Expected values use
    # an independent direct reference call, so the native test never derives its answers from the atlas.
    probes = [[0, 0, 0], [3, 9, 17], [28, 31, 47], [55, 55, 55], [119, 119, 119], [180, 180, 180],
              [232, 180, 152], [139, 83, 62], [48, 132, 75], [31, 80, 191], [221, 35, 65], [232, 239, 246], [255, 255, 255]]
    samples = linear(np.asarray(probes, dtype=float) / 255).reshape(1, -1, 3)
    reference = {"inputSRGB8": probes, "expectedLinearRGB": {}}
    looks = []
    for name, pair in LOOKS.items():
        sim = simulator(*pair)
        table = bake(sim)
        filename = name + "-100.delta64.rgba32f"
        path = ASSETS / filename
        table.tofile(path)
        looks.append({"id": name, "planes": [{"file": filename, "byteCount": path.stat().st_size,
                                               "intensityPercent": 100, "sha256": sha(path)}]})
        reference["expectedLinearRGB"][name] = sim.process(samples)[0].tolist()
        print(name, sha(path), flush=True)
    write_json(PROBES, reference)
    manifest = {"schemaVersion": 1, "operatorVersion": OPERATOR, "representation": "linear-delta64-rgba32f-v1",
                "cubeDimension": 64, "atlasWidth": 512, "atlasHeight": 512, "axisCodes": AXIS.tolist(),
                "inputICCsha256": "2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e",
                "alphaPolicy": "source-alpha-preserved/lowalpha-1over65535-bypass", "hdrPolicy": "boundary-residual-v1",
                "sourceBindingsSHA256": sha(ASSETS / "provenance.json"), "builderSHA256": sha(Path(__file__)), "looks": looks}
    write_json(ASSETS / "catalog-v1.json", manifest)


if __name__ == "__main__":
    main()
