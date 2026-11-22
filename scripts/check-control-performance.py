#!/usr/bin/env python3
"""Gate resident-RAW release timings per changed control and verify the two output states."""
import argparse
import json
import math
import re
import statistics
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(path):
    data = json.loads(path.read_text())
    sha = data["sourceSHA256"]
    require(re.fullmatch("[0-9a-f]{64}", sha) and sha == data["sourceSHA256After"], "RAW provenance mismatch")
    require(data["build"] == "release" and data["protocol"] == "rawmaster-resident-control-v1", "Unexpected build/protocol")
    require(data["requestedPixels"] == 2400 and data["repeats"] >= 20, "Expected the 2400 px release workload and at least 20 warm edits")
    require(data.get("completeCatalog") is True and data.get("binarySHA256") and data.get("decoder"), "Expected complete catalog and build provenance")
    groups = {}
    for row in data["operations"]:
        key, trials = row["id"], row["samples"]
        require(key not in groups, f"Duplicate control {key}")
        groups[key] = None
        if row["status"] == "inconclusive":
            continue
        require(row["status"] == "measured" and len(trials) == data["repeats"] + 2, f"Missing trials for {key}")
        require(len(set(row["recipes"])) == 2 and len(row["decoders"]) == 2, f"Missing state pair or decoder for {key}")
        require(max(row["outputPixels"]) == 2400 and min(row["outputPixels"]) > 0, f"Unexpected pixels for {key}")
        seen = [set(), set()]
        warm = []
        for i, trial in enumerate(trials):
            require(trial["state"] == i % 2 and trial["phase"] == ("first" if i < 2 else "warm"), f"Trial order for {key}")
            require(re.fullmatch("[0-9a-f]{64}", trial["digest"]), f"Pixel signature for {key}")
            require(math.isfinite(trial["ms"]) and trial["ms"] > 0, f"Invalid timing for {key}")
            seen[i % 2].add(trial["digest"])
            if i >= 2:
                warm.append(trial["ms"])
        require(all(len(s) == 1 for s in seen) and seen[0] != seen[1], f"Pixel A/B verification failed for {key}")
        groups[key] = {"medianMs": statistics.median(warm), "p95Ms": sorted(warm)[math.ceil(.95 * len(warm)) - 1],
                       "recipes": row["recipes"], "decoders": row["decoders"], "pixels": row["outputPixels"]}
    require(groups and any(groups.values()), "No measured controls")
    return data, groups


def compare(current, baseline, measure_only):
    data, rows = load(current)
    result = {"protocol": data["protocol"], "sourceSHA256": data["sourceSHA256"], "measureOnly": measure_only,
              "measuredCount": sum(r is not None for r in rows.values()), "attempted": len(rows),
              "inconclusive": [k for k, r in rows.items() if r is None], "failures": [], "comparisons": {}}
    if measure_only:
        return result
    failures = result["failures"]
    failures.extend(f"{k}: pixel response unverified" for k in result["inconclusive"])
    if baseline is None:
        return result
    ref, old = load(baseline)
    for key in ("sourceSHA256", "os", "gpu", "physicalMemory", "protocol", "decoder", "requestedPixels", "repeats"):
        require(data[key] == ref[key], f"Incompatible baseline {key}")
    failures.extend(f"{k}: removed from workload" for k in old.keys() - rows.keys())
    for key, new in rows.items():
        prev = old.get(key)
        if not new or not prev:
            continue
        require(all(new[field] == prev[field] for field in ("recipes", "decoders", "pixels")), f"Different workload for {key}")
        checks = {}
        for field, scale, jitter in (("medianMs", 1.10, 1.0), ("p95Ms", 1.20, 2.0)):
            limit = prev[field] + max(prev[field] * (scale - 1), jitter)
            checks[field] = {"previous": prev[field], "current": new[field], "limit": limit}
            if new[field] > limit:
                failures.append(f"{key}: {field} {new[field]:.2f} > {limit:.2f} ms")
        result["comparisons"][key] = checks
    require(result["comparisons"], "No common measured controls")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--baseline", type=Path)
    mode.add_argument("--measure-only", action="store_true")
    mode.add_argument("--verify-pixels", action="store_true")
    args = parser.parse_args()
    try:
        result = compare(args.current, args.baseline, args.measure_only)
    except (OSError, TypeError, ValueError, KeyError) as exc:
        result = {"failures": [str(exc)]}
    result["status"] = "failed" if result["failures"] else ("baseline-recorded" if args.measure_only else "passed")
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(result["status"], *result["failures"], sep="\n")
    raise SystemExit(int(bool(result["failures"])))
