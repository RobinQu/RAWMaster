#!/usr/bin/env python3
"""Verify native photographic DNG admission, visual strength, TIFF16 output and timing regressions."""
import argparse
import json
import math
import re
import statistics
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "performance"))
from photo_denoise_witness import DNG_V1, DNG_V2, validate_component_witness, verify_legacy_replay


def qualify(data, *, allow_legacy=False):
    legacy = allow_legacy and data.get("model") == DNG_V1
    if data["model"] != DNG_V2 and not legacy:
        raise ValueError("Expected the full-chroma output-referred DNG v2 recipe")
    row = data["result"]
    if (data["inputDNGColorimetricReference"],data["controlDNGColorimetricReference"]) != (1,0):
        raise ValueError("Unexpected or unverified DNG references")
    if (row["container"] != "com.adobe.raw-image"
            or len(set(data["importedFilenames"])) != 2 or row["source"] not in data["importedFilenames"]
            or not all(re.fullmatch(r"[0-9a-f]{64}",h) for h in (data["binarySHA256"],data["weightsSHA256"],
                row["sourceSHA256"], data["sceneControlSHA256"], row["exportSHA256"]))
            or row["exportBits"] != 16 or min(row["nativePixels"]) <= 0 or row["settledVsTIFF16"]["p95RGB8"] > 2
            or row["interactiveVsSettled"]["p95RGB8"] > 1):
        raise ValueError("Missing native-resolution DNG import, model, or output evidence")
    requests = {r["state"]:r for r in row["requests"]}
    if len(requests) != (37 if legacy else 41) or any(not re.fullmatch(r"[0-9a-f]{64}",r["sampleRGBASHA256"]) or
            not math.isfinite(r["elapsedMs"]) or r["elapsedMs"]<=0 for r in requests.values()):
        raise ValueError("Invalid DNG performance samples")
    hashes = {k:r["sampleRGBASHA256"] for k,r in requests.items()}
    if legacy:
        if (len({hashes[k] for k in ("original","zero","disabled")}) != 1 or hashes["full"] != hashes["replay100"]
                or len({hashes[k] for k in ("original","fresh35","full")}) != 3):
            raise ValueError("Unverified historical DNG strength or reset")
    else:
        validate_component_witness(row, DNG_V1)
    amounts = (11,17,23,29,41,47,53,59,67,73)
    for n in amounts:
        if hashes[f"new-{n}"] != hashes[f"replay-{n}"] or hashes[f"new-{n}"] == hashes[f"switch-{n}"]:
            raise ValueError(f"Missing DNG pixel change at {n}")
    result = {}
    for phase in ("new","replay"):
        times = [requests[f"{phase}-{n}"]["elapsedMs"] for n in amounts]
        result[phase] = {"n":len(times),"medianMs":statistics.median(times),"p95Ms":sorted(times)[math.ceil(.95*len(times))-1]}
    return result


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("current",type=Path)
    p.add_argument("--baseline",type=Path)
    p.add_argument("--output",required=True,type=Path)
    args = p.parse_args()
    current = json.loads(args.current.read_text())
    rows = qualify(current)
    failures = []
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        old = qualify(baseline, allow_legacy=True)
        if (any(current[k] != baseline[k] for k in ("gpu","os","weightsSHA256","sceneControlSHA256"))
                or current["result"]["sourceSHA256"] != baseline["result"]["sourceSHA256"]):
            raise ValueError("Incompatible DNG baseline")
        verify_legacy_replay(current["result"], baseline["result"])
        for phase, row in rows.items():
            for field,ratio,minimum in (("medianMs",.10,1),("p95Ms",.20,2)):
                ref = old[phase][field]
                if row[field] > ref+max(ratio*ref,minimum): failures.append(f"{phase}/{field} {ref:.2f} -> {row[field]:.2f} ms")
    result = {"model": current["model"], "warm": rows, "failures": failures}
    if args.baseline:
        result.update(baselineModel=baseline["model"], legacyReplayedSources=1)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False)+"\n")
    if failures: raise SystemExit("\n".join(failures))
