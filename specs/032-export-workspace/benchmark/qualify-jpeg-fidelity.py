#!/usr/bin/env python3
"""Compare product JPEG delivery against each product's repeated PNG16, outside the timed run."""
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageCms, JpegImagePlugin


SOURCE_SHA = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
PIXELS = [9504, 6336]
EXPOSURE = .5
ANCHOR_QUALITY = 95
PSNR_TOLERANCE_DB = .25
SSIM_TOLERANCE = .001


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def observed_path(directory, receipt):
    label, name = receipt["label"], receipt["file"]["name"]
    require(Path(label).name == label and Path(name).name == name, "LightFlow receipt paths must be leaf names")
    return directory / label / name, receipt["file"]["sha256"]


def lightflow_inputs(report):
    data = json.loads(report.read_text())
    require(data["protocol"] == "single-native-jpeg-delivery-v1" and data["complete"] and data["build"].endswith("2d41ab1")
            and data["sourceSHA256"] == data["sourceSHA256After"] == SOURCE_SHA and data["sourcePixels"] == PIXELS
            and data["exposure"]["actualEV"] == EXPOSURE, "Incompatible LightFlow source, release, recipe or dimensions")
    settings = data["settings"]
    file = settings["file"]
    require(file["quality"] == ANCHOR_QUALITY and file["format"] == "jpeg" and file["bitDepth"] == 8
            and file["chroma"] == "4:2:0" and file["progressive"] is False
            and settings["color"]["space"] == "srgb" and settings["color"]["hdr"] == "off"
            and settings["color"]["embedIcc"] is True and settings["sizing"]["mode"] == "original",
            "LightFlow must be the predeclared full-size SDR baseline q95 anchor")
    png = [row for row in data["losslessReferences"] if row["bitDepth"] == 16]
    require(len(png) == 1 and len(png[0]["outputs"]) == 2, "LightFlow needs two same-session PNG16 references")
    for key in ("color", "sizing", "sharpening", "watermark", "metadata"):
        require(png[0]["settings"][key] == settings[key], f"LightFlow lossless and JPEG output requirements differ for {key}")
    jpeg = [data["firstExport"], *data["warmups"], *data["samples"]]
    require(all(row["exposureEV"] == EXPOSURE for row in jpeg + png[0]["outputs"]), "LightFlow exposure changed between outputs")
    return {"product": "LightFlow", "quality": ANCHOR_QUALITY, "reportSHA256": digest(report),
            "recipeSHA256": data["developmentStateSHA256"], "release": data["build"],
            "runtimeSHA256": data["browserBinarySHA256"],
            "png": [observed_path(report.parent, row) for row in png[0]["outputs"]],
            "jpeg": [observed_path(report.parent, row) for row in jpeg]}


def rawmaster_inputs(report):
    data = json.loads(report.read_text())
    quality = data["quality"]
    require(data["protocol"] == "single-raw-sdr-jpeg-workbench-v1" and data["sourceSHA256"] == SOURCE_SHA
            and data["exposureEV"] == EXPOSURE and data["progressive"] is False and data["subsampling"] == "4:2:0"
            and data["resize"] is False and data["metadata"] == "none" and type(quality) is int and 5 <= quality <= 100,
            "Incompatible RAWMaster source, recipe or output configuration")
    png, jpeg = data["losslessReferences"], data["samples"]
    require(len(png) == 2 and jpeg and all([row["width"], row["height"]] == PIXELS for row in png + jpeg),
            "RAWMaster needs two same-session full-size PNG16 references and a JPEG series")
    return {"product": "RAWMaster", "quality": quality, "reportSHA256": digest(report),
            "recipeSHA256": data["recipeSHA256"], "runtimeSHA256": data["binarySHA256"],
            "png": [(Path(row["file"]), row["sha256"]) for row in png],
            "jpeg": [(Path(row["file"]), row["sha256"]) for row in jpeg]}


def inspect_image(path, lossless):
    with Image.open(path) as image:
        icc = image.info.get("icc_profile")
        require(list(image.size) == PIXELS and icc and image.getexif().get(274, 1) == 1,
                f"Expected original-size color-tagged upright image: {path}")
        profile = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        require(profile.profile.xcolor_space.strip() == "RGB" and "srgb" in ImageCms.getProfileDescription(profile).casefold(),
                f"Expected an RGB sRGB profile: {path}")
        if lossless:
            with path.open("rb") as stream:
                header = stream.read(26)
            require(image.format == "PNG" and len(header) == 26 and header[24] == 16 and header[25] in (2, 6),
                    f"Reference must be an RGB(A) PNG with 16-bit source samples: {path}")
            evidence = {"format": "PNG", "bitsPerComponent": 16, "pngColorType": header[25]}
        else:
            require(image.format == "JPEG" and image.bits == 8 and image.mode == "RGB" and not image.info.get("progressive")
                    and JpegImagePlugin.get_sampling(image) == 2 and image.quantization,
                    f"Expected 8-bit sequential JPEG with 4:2:0: {path}")
            tables = json.dumps(image.quantization, sort_keys=True, separators=(",", ":")).encode("ascii")
            evidence = {"format": "JPEG", "bitsPerComponent": 8, "subsampling": "4:2:0", "progressive": False,
                        "dqtSHA256": hashlib.sha256(tables).hexdigest()}
        return {**evidence, "dimensions": PIXELS, "iccSHA256": hashlib.sha256(icc).hexdigest()}


def run(*command, cwd=None):
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=True).stdout.strip()


def decode(magick, path, target, srgb):
    # ImageMagick Q16 with LCMS retains RGB16; Pillow is used only for headers and ICC metadata.
    opaque = run(magick, "-limit", "thread", "1", str(path), "-format", "%[opaque]", "info:")
    require(opaque.lower() == "true", f"Non-opaque source cannot be compared to JPEG: {path}")
    run(magick, "-limit", "thread", "1", str(path), "-intent", "Relative", "-profile", str(srgb),
        "-alpha", "off", "-depth", "16", "-endian", "LSB", "rgb:" + str(target))
    w, h = PIXELS
    require(target.stat().st_size == w * h * 6, "RGB16 decoder changed image dimensions or discarded channels")
    return digest(target)


def prepared_assets(assets, lossless, magick, srgb, scratch, target):
    unique = {}
    for source, expected in assets:
        require(digest(source) == expected, f"Delivery receipt SHA differs from file {source}")
        unique.setdefault(expected, source)
    require(unique, "No matching product files were supplied")
    witnesses = []
    candidate = scratch / "probe.rgb"
    for file_sha, path in unique.items():
        evidence = inspect_image(path, lossless)
        rgb_sha = decode(magick, path, candidate, srgb)
        witnesses.append({**evidence, "sourceFileSHA256": file_sha, "canonicalRGB16SHA256": rgb_sha})
        if not target.exists():
            candidate.replace(target)
    require(len({row["canonicalRGB16SHA256"] for row in witnesses}) == 1,
            "Repeated product deliveries did not reproduce the same normalized decoded pixels")
    require(len({row.get("dqtSHA256") for row in witnesses}) == 1, "Repeated JPEGs did not use one quantization table set")
    return witnesses


def single_stats(path):
    rows = path.read_text().strip().splitlines()
    require(len(rows) == 1, f"Expected one measured frame in {path.name}")
    return dict(token.split(":", 1) for token in rows[0].split() if ":" in token)


def quality(ffmpeg, jpeg, reference, scratch):
    w, h = PIXELS
    raw = ("-f", "rawvideo", "-pixel_format", "rgb48le", "-video_size", f"{w}x{h}", "-framerate", "1")
    filters = ("[0:v]format=gbrp16le,split[jp][js];[1:v]format=gbrp16le,split[rp][rs];"
               "[jp][rp]psnr=stats_file=psnr.txt[p];[js][rs]ssim=stats_file=ssim.txt[s]")
    run(ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-filter_complex_threads", "1",
        *raw, "-i", str(jpeg), *raw, "-i", str(reference), "-filter_complex", filters,
        "-map", "[p]", "-map", "[s]", "-frames:v:0", "1", "-frames:v:1", "1", "-f", "null", "-", cwd=scratch)
    psnr = single_stats(scratch / "psnr.txt")
    ssim = single_stats(scratch / "ssim.txt")
    mse, similarity = float(psnr["mse_avg"]), float(ssim["All"])
    require(mse >= 0 and math.isfinite(mse) and -1 <= similarity <= 1, "Invalid independent quality metric output")
    return {"rgbMSE16": mse, "rgbPSNRdB": 10 * math.log10(65535**2 / mse) if mse else "inf", "rgbSSIM": similarity,
            "componentPSNRdB": {c: psnr["psnr_" + c] for c in "rgb"},
            "componentSSIM": {c: float(ssim[c.upper()]) for c in "rgb"}}


def qualify_product(product, magick, ffmpeg, srgb):
    with tempfile.TemporaryDirectory(prefix="rawmaster-jpeg-fidelity-") as directory:
        scratch = Path(directory)
        png, jpeg = scratch / "reference.rgb", scratch / "candidate.rgb"
        references = prepared_assets(product["png"], True, magick, srgb, scratch, png)
        candidates = prepared_assets(product["jpeg"], False, magick, srgb, scratch, jpeg)
        metrics = quality(ffmpeg, jpeg, png, scratch)
    detail = {key: value for key, value in product.items() if key not in ("png", "jpeg")}
    return {**detail, "referenceCount": len(product["png"]), "jpegCount": len(product["jpeg"]),
            "references": references, "jpegs": candidates, "metrics": metrics}


def matches(anchor, candidate):
    reference, test = anchor["metrics"], candidate["metrics"]
    if reference["rgbPSNRdB"] == test["rgbPSNRdB"] == "inf":
        psnr_delta = 0.0
    elif "inf" in (reference["rgbPSNRdB"], test["rgbPSNRdB"]):
        psnr_delta = None
    else:
        psnr_delta = test["rgbPSNRdB"] - reference["rgbPSNRdB"]
    ssim_delta = round(test["rgbSSIM"] - reference["rgbSSIM"], 6)
    passed = (psnr_delta is not None and (abs(psnr_delta) <= PSNR_TOLERANCE_DB
              or math.isclose(abs(psnr_delta), PSNR_TOLERANCE_DB, rel_tol=0, abs_tol=1e-12))
              and abs(ssim_delta) <= SSIM_TOLERANCE)
    return {"psnrDeltaDB": psnr_delta, "ssimDelta": ssim_delta, "matchesAnchor": passed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lightflow", type=Path, required=True, help="q95 results.json from LightFlow's normal export")
    parser.add_argument("--rawmaster", type=Path, nargs="+", required=True, help="summary.json files for actual RAWMaster JPEG quality settings")
    parser.add_argument("--srgb-profile", type=Path, required=True, help="Canonical RGB ICC, use Modules/PhotoExport/profiles/srgb.icc")
    parser.add_argument("--magick", default="magick")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    magick_version = run(args.magick, "-version").splitlines()
    require("Q16" in magick_version[0] and any(" lcms " in f" {line} " for line in magick_version),
            "ImageMagick must provide a Q16 build and an LCMS delegate")
    srgb = args.srgb_profile.resolve()
    anchor = qualify_product(lightflow_inputs(args.lightflow), args.magick, args.ffmpeg, srgb)
    trials = [rawmaster_inputs(path) for path in args.rawmaster]
    require(len({trial["quality"] for trial in trials}) == len(trials), "RAWMaster quality candidates must be unique")
    require(len({trial["runtimeSHA256"] for trial in trials}) == 1, "RAWMaster calibration used different executable builds")
    results = []
    for product in sorted(trials, key=lambda trial: trial["quality"]):
        candidate = qualify_product(product, args.magick, args.ffmpeg, srgb)
        results.append({**candidate, **matches(anchor, candidate)})
    require(len({item["references"][0]["canonicalRGB16SHA256"] for item in results}) == 1,
            "RAWMaster calibration did not reproduce the same lossless rendering")
    qualified = [item for item in results if item["matchesAnchor"]]
    def distance(item):
        return (max(abs(item["psnrDeltaDB"]) / PSNR_TOLERANCE_DB, abs(item["ssimDelta"]) / SSIM_TOLERANCE), -item["quality"])

    result = {"protocol": "jpeg-fidelity-to-own-png16-v1", "sourceSHA256": SOURCE_SHA, "exposureEV": EXPOSURE,
              "sourcePixels": PIXELS, "absolutePSNRDeltaLimitDB": PSNR_TOLERANCE_DB, "absoluteSSIMDeltaLimit": SSIM_TOLERANCE,
              "metric": "Pooled full-frame normalized sRGB RGB16 PSNR and FFmpeg RGB SSIM against each product's repeated same-recipe PNG16",
              "magick": magick_version[0], "ffmpeg": run(args.ffmpeg, "-version").splitlines()[0],
              "canonicalICCProfileSHA256": digest(srgb), "lightflowAnchor": anchor, "rawmasterCandidates": results,
              "selectedRAWMasterQuality": min(qualified, key=distance)["quality"] if qualified else None,
              "passed": bool(qualified)}
    with args.output.open("x") as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write("\n")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
