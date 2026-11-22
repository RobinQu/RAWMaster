#!/usr/bin/env python3
"""Check native RAW 9 fresh Amount, exact replay, resident-cache release and full TIFF16 time."""
import argparse
import json
import math
from pathlib import Path

FRESH = ("amount0", "amount100", "amount50-first")
REPLAY = {"amount0-replay":"amount0", "amount0-secondReplay":"amount0", "amount50-replay":"amount50-first"}


def qualify(path):
    data = json.loads(path.read_text())
    if data["featureId"] != "detail-denoise" or len(data["sha256"]) != 64 or data["sourceSHA256After"] != data["sha256"]:
        raise ValueError("Missing immutable source identity")
    rows = {r["input"]: r for r in data["requests"]}
    if any(len(rows[k]["sampledSRGBSHA256"]) != 64 for k in ["original","disabled",*FRESH,*REPLAY]):
        raise ValueError("Missing RAW 9 display-pixel witness")
    if rows["original"]["sampledSRGBSHA256"] != rows["disabled"]["sampledSRGBSHA256"]:
        raise ValueError("RAW 9 disable failed to restore native source pixels")
    hashes = {rows[k]["sampledSRGBSHA256"] for k in FRESH}
    if len(hashes) != 3 or any(rows[k]["neutralBaseFills"] != 1 or rows[k]["neutralBaseHits"] != 0 for k in FRESH):
        raise ValueError("Each new Amount must produce independently decoded pixels")
    if any(rows[k]["neutralBaseHits"] != 1 or rows[k]["neutralBaseFills"] != 0 or
           rows[k]["sampledSRGBSHA256"] != rows[v]["sampledSRGBSHA256"] for k,v in REPLAY.items()):
        raise ValueError("Exact Amount replay failed the pixel or resident-cache witness")
    if data["closedNeutralResidentBytes"] != 0 or len(set(data["proxyKeys"])) != 4 or len(set(data["thumbnailKeys"])) != 4:
        raise ValueError("A source key or the cache lifecycle did not account for the RAW 9 Amount")
    export = data["export"]
    if export["bitDepth"] != 16 or export["amount"] != 100 or min(export["width"],export["height"]) < 1 or len(export["sha256"]) != 64:
        raise ValueError("Missing full-resolution TIFF16")
    stages = {k: rows[k]["previewMs"] for k in [*FRESH,*REPLAY]}
    stages["fullTIFFMs"] = export["elapsedMs"]
    if any(not math.isfinite(value) or value <= 0 for value in stages.values()):
        raise ValueError("Invalid fresh, replay or export elapsed time")
    return data, stages


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current",type=Path)
    parser.add_argument("--baseline",type=Path)
    parser.add_argument("--output",type=Path,required=True)
    args = parser.parse_args()
    doc, stages = qualify(args.current)
    failures = []
    if args.baseline:
        old, previous = qualify(args.baseline)
        if any(old[k] != doc[k] for k in ("sha256","model","os","maxPixel","sourceBytes")):
            raise SystemExit("RAW 9 source, decoder model, viewport or OS differs")
        if old.get("gpu") and doc.get("gpu") != old["gpu"]:
            raise SystemExit("RAW 9 GPU differs")
        if any(old["export"][k] != doc["export"][k] for k in ("sha256","width","height")):
            failures.append("RAW 9 native TIFF pixels or dimensions changed")
        for name, elapsed in stages.items():
            old_ms = previous[name]
            if elapsed > old_ms + max(2, .25*old_ms):
                failures.append(f"{name} {old_ms:.2f} -> {elapsed:.2f} ms")
    args.output.write_text(json.dumps({"sha256":doc["sha256"],"model":doc["model"],"singleRequestMs":stages,
                                      "failures":failures},indent=2,allow_nan=False) + "\n")
    if failures:
        raise SystemExit("\n".join(failures))
