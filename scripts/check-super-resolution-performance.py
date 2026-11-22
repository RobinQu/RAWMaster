#!/usr/bin/env python3
"""Qualify the real sensor, normal 2× preview, complete TIFF16 and learned pixel witnesses."""
import argparse
import json
import math
from pathlib import Path

CHECKPOINT = "deb2c288f635bed4a0ffc0be9ca8f6a735233b530ad5b2c392c5b2e6c5fe30ad"


def qualify(path):
    data = json.loads(path.read_text())
    if data["build"] != "release" or data["sourceWeightsSHA256"] != CHECKPOINT or len(data["rawSHA256"]) != 64:
        raise ValueError("Missing Release, sensor or model identity")
    width, height = data["native"]
    tiff = data["tiff16"]
    if width < 1 or height < 1 or tiff["size"] != [width * 2, height * 2] or tiff["bits"] != 16:
        raise ValueError("Export failed to double each native dimension at 16 bits")
    if tiff.get("sampleFormat") != "unsigned" or len(tiff["sha256"]) != 64 or len(tiff["iccSHA256"]) != 64:
        raise ValueError("Missing output, color profile or TIFF representation")
    frames = {row["state"]: row for row in data["preview"]}
    if set(frames) != {"original", "2x", "disabled"}:
        raise ValueError("The enable/disable edit did not traverse the normal preview")
    for name, frame in frames.items():
        factor = 2 if name == "2x" else 1
        if [frame["width"], frame["height"]] != [width * factor, height * factor] or len(frame["displaySHA256"]) != 64:
            raise ValueError("Wrong canvas or missing display pixels for " + name)
    if frames["original"]["displaySHA256"] != frames["disabled"]["displaySHA256"]:
        raise ValueError("Switching off changed source display pixels")
    if len(data["pixelSpots"]) < 7 or not 0 <= data["maxMeanError"] < .003 or not data["maxSubpixelDetail"] > .0001:
        raise ValueError("Missing learned source-grid pixels in the reopened TIFF")
    phases = data.get("sampledMemoryByPhase", {})
    if not {"preview","normalTIFF16Export","independentTIFFReopen"} <= set(phases):
        raise ValueError("Missing separate preview, export and pixel-verification memory samples")
    export = phases["normalTIFF16Export"]
    measures = {"fitOnMs": frames["2x"]["renderMs"], "fullTIFFMs": tiff["elapsedMs"],
                "exportPhysicalFootprintBytes": export["physicalFootprintBytes"],
                "exportResidentBytes": export["residentBytes"], "exportMetalBytes": export["metalBytes"]}
    if any(not math.isfinite(v) or v <= 0 for v in measures.values()):
        raise ValueError("Invalid time or memory measurement")
    return data, measures


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data, measures = qualify(args.current)
    failures = []
    if args.baseline:
        old, durations = qualify(args.baseline)
        if any(old[k] != data[k] for k in ("gpu", "os", "rawSHA256", "sourceWeightsSHA256", "model", "native")):
            raise SystemExit("Super-resolution baseline source, software, model or GPU differs")
        if old["tiff16"]["sha256"] != data["tiff16"]["sha256"]:
            failures.append("The same model and source produced a different native TIFF")
        for key, limit in (("fitOnMs", .25), ("fullTIFFMs", .25), ("exportPhysicalFootprintBytes", .2),
                           ("exportResidentBytes", .2), ("exportMetalBytes", .25)):
            if measures[key] > durations[key] * (1 + limit):
                failures.append(f"{key}: {durations[key]:.1f} -> {measures[key]:.1f}")
    args.output.write_text(json.dumps({"rawSHA256": data["rawSHA256"], "metrics": measures,
                                      "failures": failures}, indent=2, allow_nan=False) + "\n")
    if failures:
        raise SystemExit("\n".join(failures))
