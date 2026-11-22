#!/usr/bin/env python3
"""Check actual display pixels and warm release latency for repeated and new slider values."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "docs/research/camera-raw-parity"))
from performance_controls import compare_panel_readback, compare_readback, panel_readback_rows, readback_rows, PANEL_SCHEDULE, panel_schedule_rows
from paired_photo_operator_report import MANIFEST, PHASES, PROTOCOL, latency_limits, stats, validated_rows


def load(path):
    data = json.loads(path.read_text())
    if not data.get("binarySHA256") or not data.get("gpu") or not data.get("decoder"):
        raise ValueError("Missing native decoder, device or executable identity")
    if data["protocol"] == PROTOCOL["RAWMaster"]:
        return data, validated_rows(data, json.loads(MANIFEST.read_bytes()), "RAWMaster", data["sourceSHA256"])
    if data["protocol"] == PANEL_SCHEDULE["RAWMaster"]:
        return data, panel_schedule_rows(data, "RAWMaster")
    if data["protocol"] == "resident-srgb8-panels-v1":
        return data, panel_readback_rows(data, "RAWMaster")
    return data, readback_rows(data, "RAWMaster")


def check(current, baseline):
    data, rows = load(current)
    result = {"sourceSHA256": data["sourceSHA256"], "count": len(rows), "failures": []}
    if data["protocol"] == PROTOCOL["RAWMaster"]:
        unverified = [key for key, row in rows.items() if row["status"] != "measured"]
        result["failures"] = [f"{key} failed full-photo or spatial pixel validation" for key in unverified]
        result["baselineCompared"] = bool(baseline)
        if not baseline or unverified:
            return result
        old, previous = load(baseline)
        if any(data[field] != old[field] for field in ("sourceSHA256", "protocol", "os", "gpu", "decoder", "parameterSHA256")):
            raise ValueError("Photo operator baseline has different inputs, renderer, recipes or hardware")
        if any(row["status"] != "measured" for row in previous.values()):
            raise ValueError("Photo operator baseline has unverified photo states")
        measurements = {key:(previous[key]["phases"], row["phases"]) for key, row in rows.items()}
        def first_mix(records):
            return {phase:stats([ms for row in records.values() for ms in row["initial"][phase]]) for phase in PHASES}
        measurements["firstAppearanceMix"] = first_mix(previous), first_mix(rows)
        comparisons = {}
        for key, (before, after) in measurements.items():
            comparisons[key] = {}
            for phase in PHASES:
                limits = latency_limits(before[phase], after[phase])
                comparisons[key][phase] = {"previous":before[phase], "current":after[phase], **limits}
                if not limits["within"]:
                    result["failures"].append(f'{key}/{phase} exceeded baseline. Median {after[phase]["medianMs"]:.2f} ms (limit {limits["medianLimit"]:.2f}), p95 {after[phase]["p95Ms"]:.2f} ms (limit {limits["p95Limit"]:.2f})')
        result["comparisons"] = comparisons
        return result
    if data["protocol"] == PANEL_SCHEDULE["RAWMaster"]:
        result["count"] = len(rows["first"])
        if baseline:
            old, previous = load(baseline)
            if any(data[k] != old[k] for k in ("protocol","sourceSHA256","os","gpu","decoder","parameterSHA256")):
                raise ValueError("Incompatible dual-phase panel baseline")
            recipes = {r["id"]:r["recipes"] for r in old["operations"]}
            if any(r["recipes"] != recipes.get(r["id"]) for r in data["operations"]):
                raise ValueError("Changed dual-phase test recipes")
            comparisons = {phase:compare_panel_readback(previous[phase],v,"previous","current") for phase,v in rows.items()}
            result["comparisons"] = comparisons
            result["failures"] = [f"{phase}/{key} exceeds its baseline latency limits"
                                  for phase,v in comparisons.items() for key,r in v.items() if not r["within"]]
        return result
    panels = data["protocol"] == "resident-srgb8-panels-v1"
    if panels:
        result["inconclusive"] = [key for key,row in rows.items() if row["timing"] is None]
        if len(result["inconclusive"]) == len(rows):
            result["failures"].append("No panel control produced a verified image change")
    if baseline:
        old, previous = load(baseline)
        for field in ("protocol", "sourceSHA256", "os", "gpu", "decoder"):
            if data[field] != old[field]:
                raise ValueError(f"Incompatible release readback baseline {field}")
        if panels:
            recipes = {r["id"]:r["recipes"] for r in old["operations"]}
            if any(r["recipes"] != recipes[r["id"]] for r in data["operations"]):
                raise ValueError("A panel recipe changed relative to the stored workload")
            result["comparisons"] = compare_panel_readback(previous, rows, "previous", "current")
            for key,row in result["comparisons"].items():
                if row["previous"] and not row["current"]:
                    result["failures"].append(f"{key} lost its two verified photo states")
                elif row["within"] is False:
                    result["failures"].append(f"{key} exceeds its baseline latency limits")
            return result
        result["comparisons"] = compare_readback(previous, rows, "previous", "current")
        for phase, measured in result["comparisons"].items():
            for key, row in measured.items():
                if not row["within"]:
                    result["failures"].append(f"{phase}/{key} exceeds its baseline latency limits")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = check(args.current, args.baseline)
    except (OSError, ValueError, TypeError, KeyError) as error:
        result = {"failures": [str(error)]}
    result["status"] = "failed" if result["failures"] else "passed"
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(result["status"], *result["failures"], sep="\n")
    raise SystemExit(int(bool(result["failures"])))
