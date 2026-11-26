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
    "spektraGold200UltraEndura": ("kodak_gold_200", "kodak_ultra_endura"),
    "spektraPortra800SupraEndura": ("kodak_portra_800", "kodak_supra_endura"),
    "spektraEktar100Endura": ("kodak_ektar_100", "kodak_portra_endura"),
    "spektraProvia100F": ("fujifilm_provia_100f", None),
    "spektraEktachrome100": ("kodak_ektachrome_100", None),
    "spektraVision500T2383": ("kodak_vision3_500t", "kodak_2383"),
}
DIRECT_ENDPOINTS = frozenset(("spektraPortra400Endura", "spektraVelvia100", "spektraVision250D2383"))
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


def sample_delta(sim, codes):
    axis = linear(codes)
    size = len(axis)
    samples = np.empty((size, size, size, 3), dtype=np.float64)
    for start in range(0, size, 8):
        count = min(8, size - start)
        b, g, r = np.meshgrid(axis[start:start + count], axis, axis, indexing="ij")
        pixels = np.stack([r, g, b], axis=-1)
        output = sim.process(pixels.reshape(count * size, size, 3)).reshape(pixels.shape)
        samples[start:start + count] = output - pixels
    if not np.all(np.isfinite(samples)):
        raise ValueError("Non-finite linear RGB delta from reference processor")
    return samples


def fit_delta(dense, codes=None):
    from scipy.linalg import solve_banded
    codes = np.linspace(0, 1, 64) if codes is None else np.asarray(codes)
    intervals = np.diff(codes)
    if dense.shape != (127, 127, 127, 3) or codes.shape != (64,) or not np.all(intervals > 0):
        raise ValueError("Unexpected reference grid for the atlas fit")
    knots = dense[::2, ::2, ::2].copy()
    interpolated = knots
    for axis in range(3):
        moved = np.moveaxis(interpolated, axis, 0)
        expanded = np.empty((127,) + moved.shape[1:], dtype=np.float64)
        expanded[::2] = moved
        expanded[1::2] = (moved[:-1] + moved[1:]) / 2
        interpolated = np.moveaxis(expanded, 0, axis)
    residual = dense - interpolated
    # Simpson quadrature approximates a continuous uniform encoded-RGB measure, not a
    # discrete objective that disproportionately rewards the already-exact original knots.
    weights = np.zeros(127, dtype=np.float64)
    weights[:-2:2] += intervals / 6
    weights[1::2] = intervals * 2 / 3
    weights[2::2] += intervals / 6
    # Fix every cube face to its reference knots; residual extrapolation must not change.
    normal = np.zeros((3, 62), dtype=np.float64)
    normal[1] = weights[2:-1:2] + 0.25 * (weights[1:-2:2] + weights[3::2])
    normal[0, 1:] = 0.25 * weights[3:-2:2]
    normal[2, :-1] = 0.25 * weights[3:-2:2]
    for axis in range(3):
        moved = np.moveaxis(residual, axis, 0)
        shape = (62,) + (1,) * (moved.ndim - 1)
        rhs = moved[2:-1:2] * weights[2:-1:2].reshape(shape)
        rhs += 0.5 * (moved[1:-2:2] * weights[1:-2:2].reshape(shape) +
                      moved[3::2] * weights[3::2].reshape(shape))
        solved = solve_banded((1, 1), normal, rhs.reshape(62, -1)).reshape(rhs.shape)
        residual = np.moveaxis(solved, 0, axis)
    knots[1:-1, 1:-1, 1:-1] += residual
    return knots


def bake(sim, fitted=False):
    codes = AXIS / 65535
    if fitted:
        dense_codes = np.empty(127, dtype=np.float64)
        dense_codes[::2] = codes
        dense_codes[1::2] = (codes[:-1] + codes[1:]) / 2
        delta = fit_delta(sample_delta(sim, dense_codes), codes)
    else:
        delta = sample_delta(sim, codes)
    if not np.all(np.isfinite(delta)) or np.max(np.abs(delta)) > 1:
        raise ValueError("Unrepresentable fitted linear RGB delta from reference processor")
    table = np.ones((64, 64, 64, 4), dtype="<f4")
    table[:, :, :, :3] = delta
    return table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--destination", type=Path, default=ASSETS, help="Use a staging directory before installing verified assets")
    parser.add_argument("--reference", type=Path, default=PROBES)
    args = parser.parse_args()
    upstream = args.checkout.resolve()
    destination = args.destination.resolve()
    revision = subprocess.check_output(["git", "-C", upstream, "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise ValueError("Unexpected upstream revision: " + revision)
    subprocess.run(["git", "-C", upstream, "diff", "--quiet", "HEAD", "--", "src/spektrafilm", "SPEKTRAFILM_LICENSE.txt"], check=True)
    sys.path.insert(0, str(upstream / "src"))
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(upstream / "SPEKTRAFILM_LICENSE.txt", destination / "SPEKTRAFILM_LICENSE.txt")
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
        "stored": "Little-endian RGBA32Float linear delta, alpha lane 1. R fastest, then G and B. Original three endpoints preserve their direct64 nodes; new endpoints fit the full dense127 reference with fixed cube faces.",
        "strength": "Linear blend from the original to the stock endpoint in working RGB. Outside [0,1] preserve the signed source residual.",
        "scope": "Official-model/default-parameter SDR colour and tone endpoints, not named community-authored looks. Grain, halation and HDR output rendering are not included.",
        "fit": {"method": "fixed-faces-simpson-trilinear-fit-v1", "referenceGrid": 127, "storedGrid": 64,
                "inputMeasure": "uniform encoded sRGB, tensor-product Simpson quadrature",
                "preservedDirectEndpoints": sorted(DIRECT_ENDPOINTS)},
        "looks": {key: {"film": film, "print": paper, "scanFilmDirectly": paper is None,
                        "bakeMethod": "direct64-v1" if key in DIRECT_ENDPOINTS else "dense127-fit-v1"}
                  for key, (film, paper) in LOOKS.items()},
    }
    write_json(destination / "provenance.json", provenance)
    # Off-grid samples include the toe, neutrals, skin, foliage, sky and near-white. Expected values use
    # an independent direct reference call, so the native test never derives its answers from the atlas.
    probes = [[0, 0, 0], [3, 9, 17], [28, 31, 47], [55, 55, 55], [119, 119, 119], [180, 180, 180],
              [232, 180, 152], [139, 83, 62], [48, 132, 75], [31, 80, 191], [221, 35, 65], [232, 239, 246], [255, 255, 255]]
    samples = linear(np.asarray(probes, dtype=float) / 255).reshape(1, -1, 3)
    reference = {"inputSRGB8": probes, "expectedLinearRGB": {}}
    looks = []
    for name, pair in LOOKS.items():
        sim = simulator(*pair)
        table = bake(sim, fitted=name not in DIRECT_ENDPOINTS)
        filename = name + "-100.delta64.rgba32f"
        path = destination / filename
        table.tofile(path)
        looks.append({"id": name, "planes": [{"file": filename, "byteCount": path.stat().st_size,
                                               "intensityPercent": 100, "sha256": sha(path)}]})
        reference["expectedLinearRGB"][name] = sim.process(samples)[0].tolist()
        print(name, sha(path), flush=True)
    write_json(args.reference, reference)
    manifest = {"schemaVersion": 1, "operatorVersion": OPERATOR, "representation": "linear-delta64-rgba32f-v1",
                "cubeDimension": 64, "atlasWidth": 512, "atlasHeight": 512, "axisCodes": AXIS.tolist(),
                "inputICCsha256": "2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e",
                "alphaPolicy": "source-alpha-preserved/lowalpha-1over65535-bypass", "hdrPolicy": "boundary-residual-v1",
                "sourceBindingsSHA256": sha(destination / "provenance.json"), "builderSHA256": sha(Path(__file__)), "looks": looks}
    write_json(destination / "catalog-v1.json", manifest)


if __name__ == "__main__":
    main()
