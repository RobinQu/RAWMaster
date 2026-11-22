#!/usr/bin/env python3
"""Verify trained RGB denoising, file types, native export, pixel witnesses and warm latency per release."""
import argparse
import json
import math
from pathlib import Path
import statistics
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "performance"))
from photo_denoise_witness import PHOTO_V1, PHOTO_V2, validate_component_witness, verify_legacy_replay

AMOUNTS = (11, 17, 23, 29, 41, 47, 53, 59, 67, 73)
CONTAINERS = {"public.jpeg", "public.tiff", "public.png", "public.heic", "public.avif",
              "org.webmproject.webp", "public.jpeg-xl", "com.adobe.photoshop-image"}


def qualify(path, *, allow_legacy=False):
    data = json.loads(path.read_text())
    if data.get("build") != "release" or not all(data.get(key) for key in
            ("gpu", "os", "binarySHA256", "weightsSHA256", "cameraJPEGSHA256", "model")):
        raise ValueError("Missing release, executable, source, GPU or model identity")
    legacy = allow_legacy and data.get("model") == PHOTO_V1
    if data["model"] != PHOTO_V2 and not legacy:
        raise ValueError("Expected the photographic full-chroma v2 model")
    rows = data["results"]
    if len(rows) != 9 or {r["container"] for r in rows} != CONTAINERS:
        raise ValueError("Expected a verified camera JPEG, TIFF, PNG, HEIC, AVIF, WebP, JPEG XL, PSD and PSB")
    if {Path(r["source"]).suffix.lower() for r in rows if r["container"] == "com.adobe.photoshop-image"} != {".psd", ".psb"}:
        raise ValueError("Expected PSD and PSB containers")
    if set(data.get("importedFilenames", [])) != {Path(row["source"]).name for row in rows}:
        raise ValueError("Normal directory import did not discover all nine photo containers")
    result = {}
    for row in rows:
        values = {v["state"]: v for v in row["requests"]}
        hashes = {k: v["sampleRGBASHA256"] for k,v in values.items()}
        if any(len(h) != 64 for h in hashes.values()) or any(not math.isfinite(v["elapsedMs"]) or v["elapsedMs"] <= 0 for v in values.values()):
            raise ValueError("Incomplete pixels or timings: " + row["source"])
        if legacy:
            if hashes["original"] != hashes["zero"] or hashes["original"] != hashes["disabled"] or hashes["full"] != hashes["replay100"] or len({hashes[k] for k in ("full", "fresh35", "original")}) != 3:
                raise ValueError("Missing legacy reversible changed-state pixel evidence: " + row["source"])
        else:
            validate_component_witness(row, PHOTO_V1)
        if row["interactiveVsSettled"]["p95RGB8"] > 1:
            raise ValueError("Native interactive / settled pixels disagree: " + row["source"])
        if row["exportBits"] != 16 or len(row["exportSHA256"]) != 64 or row["settledVsTIFF16"]["p95RGB8"] > 2:
            raise ValueError("Full TIFF16 / settled preview mismatch: " + row["source"])
        if row["container"] not in {"public.jpeg", "public.tiff"}:
            continue
        if row["container"] == "public.jpeg" and row["sourceSHA256"] != data["cameraJPEGSHA256"]:
            raise ValueError("The JPEG is not the pinned camera input")
        if row["container"] == "public.tiff" and (row["sourceBits"] != 16 or row["sourceICC"] != "kCGColorSpaceDisplayP3"):
            raise ValueError("Expected an actual 16-bit Display P3 TIFF")
        for n in AMOUNTS:
            if hashes[f"new-{n}"] != hashes[f"replay-{n}"] or hashes[f"new-{n}"] == hashes[f"switch-{n}"]:
                raise ValueError(f"Missing witnessed Amount {n}")
        for phase in ("new", "replay"):
            samples = sorted(values[f"{phase}-{n}"]["elapsedMs"] for n in AMOUNTS)
            result[row["container"] + "/" + phase] = {"n": len(samples), "medianMs": statistics.median(samples),
                "p95Ms": samples[math.ceil(.95*len(samples))-1]}
    return data, result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    data, rows = qualify(args.current)
    failures = []
    if args.baseline:
        old, reference = qualify(args.baseline, allow_legacy=True)
        if any(data[k] != old[k] for k in ("cameraJPEGSHA256","gpu","os","weightsSHA256")):
            raise SystemExit("RGB denoiser baseline source, device, OS, or model differs")
        previous_sources = {r["source"]: r for r in old["results"]}
        for current in data["results"]:
            verify_legacy_replay(current, previous_sources[current["source"]])
        for key, row in rows.items():
            for metric, ratio, floor in (("medianMs", .10, 1), ("p95Ms", .20, 2)):
                previous = reference[key][metric]
                if row[metric] > previous + max(floor, previous*ratio):
                    failures.append(f"{key} {metric} {previous:.2f} -> {row[metric]:.2f} ms")
    result = {"cameraJPEGSHA256":data["cameraJPEGSHA256"],"model":data["model"],"warm":rows,"failures":failures}
    if args.baseline:
        result.update(baselineModel=old["model"], legacyReplayedSources=len(previous_sources))
    args.output.write_text(json.dumps(result,indent=2,allow_nan=False)+"\n")
    if failures: raise SystemExit("\n".join(failures))
