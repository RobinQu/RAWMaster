#!/usr/bin/env python3
"""Compare two RAWMaster image-performance monitor exports for release regression.

The comparison key includes operation, stage and timing boundary. Pixel workloads must match;
when pixels are present, throughput is gated as well as median/p95 wall time.
"""
import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

SCHEMA = 1


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        raise ValueError("empty percentile input")
    position = (len(values) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return values[low] + (values[high] - values[low]) * (position - low)


def load(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != SCHEMA:
        raise ValueError(f"Unsupported performance schema in {path}")
    groups = defaultdict(list)
    for sample in data.get("samples", []):
        duration = sample.get("durationMs")
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
            raise ValueError("Invalid duration in performance export")
        if sample.get("outcome") != "成功":
            raise ValueError("Failed/cancelled operations cannot qualify a release performance baseline")
        key = (sample.get("operation"), sample.get("stage"), sample.get("boundary"))
        if not all(isinstance(v, str) and v for v in key):
            raise ValueError("Every sample needs operation, stage and boundary")
        pixels = sample.get("pixelCount", 0)
        if not isinstance(pixels, int) or pixels < 0:
            raise ValueError("Invalid pixelCount")
        groups[key].append((float(duration), pixels))
    if not groups:
        raise ValueError(f"No performance samples in {path}")
    return data, groups


def metrics(rows):
    durations = [r[0] for r in rows]
    pixels = [r[1] for r in rows]
    throughput = [p / 1_000_000 / (ms / 1000) for ms, p in rows if ms > 0 and p > 0]
    return {
        "count": len(rows),
        "medianMs": statistics.median(durations),
        "p95Ms": percentile(durations, 0.95),
        "maxMs": max(durations),
        "medianPixelCount": statistics.median(pixels),
        "medianMegapixelsPerSecond": statistics.median(throughput) if throughput else None,
    }


def compare(baseline_path, current_path, minimum_samples, median_tolerance, p95_tolerance):
    baseline_data, baseline = load(baseline_path)
    current_data, current = load(current_path)
    if set(baseline) != set(current):
        missing = sorted(set(baseline) - set(current))
        added = sorted(set(current) - set(baseline))
        raise ValueError(f"Operation coverage differs; missing={missing}, added={added}")
    rows = []
    for key in sorted(baseline):
        old, new = metrics(baseline[key]), metrics(current[key])
        if old["count"] < minimum_samples or new["count"] < minimum_samples:
            raise ValueError(f"{key} needs at least {minimum_samples} samples in both exports")
        old_pixels, new_pixels = old["medianPixelCount"], new["medianPixelCount"]
        if (old_pixels == 0) != (new_pixels == 0) or (old_pixels and abs(new_pixels / old_pixels - 1) > 0.01):
            raise ValueError(f"{key} workload differs: {old_pixels} vs {new_pixels} pixels")
        median_change = new["medianMs"] / old["medianMs"] - 1 if old["medianMs"] else 0
        p95_change = new["p95Ms"] / old["p95Ms"] - 1 if old["p95Ms"] else 0
        throughput_change = None
        if old["medianMegapixelsPerSecond"] and new["medianMegapixelsPerSecond"]:
            throughput_change = new["medianMegapixelsPerSecond"] / old["medianMegapixelsPerSecond"] - 1
        passed = median_change <= median_tolerance and p95_change <= p95_tolerance and (throughput_change is None or throughput_change >= -median_tolerance)
        rows.append({"operation": key[0], "stage": key[1], "boundary": key[2],
            "baseline": old, "current": new, "medianChangePercent": median_change * 100,
            "p95ChangePercent": p95_change * 100,
            "throughputChangePercent": throughput_change * 100 if throughput_change is not None else None,
            "passed": passed})
    failed = [r for r in rows if not r["passed"]]
    return {"passed": not failed, "schemaVersion": SCHEMA,
        "baseline": {"path": str(baseline_path), "createdAt": baseline_data.get("createdAt"), "build": baseline_data.get("build")},
        "current": {"path": str(current_path), "createdAt": current_data.get("createdAt"), "build": current_data.get("build")},
        "policy": {"minimumSamplesPerOperation": minimum_samples,
            "maximumMedianRegressionPercent": median_tolerance * 100,
            "maximumP95RegressionPercent": p95_tolerance * 100,
            "maximumThroughputRegressionPercent": median_tolerance * 100,
            "sameOperationCoverage": True, "samePixelWorkloadWithinPercent": 1,
            "failedOrCancelledSamplesAllowed": False},
        "operations": rows, "failedOperations": [r["operation"] for r in failed]}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_release_directory(directory, measure_only=False):
    """Original UI/image directory protocol, retained alongside monitor-export comparison."""
    ui = json.loads((directory / "ui.json").read_text(encoding="utf-8"))
    image = json.loads((directory / "image.json").read_text(encoding="utf-8"))
    require(ui["build"] == image["build"] == "release", "Both benchmarks must be release builds")
    require(not ui["failures"], "UI benchmark reported failed or timed-out samples")
    surfaces = {m["surface"]:m for m in ui["surfaces"]}
    require(set(surfaces) == {"grid", "filmstrip"}, "Both real input surfaces are required")
    for name, metric in surfaces.items():
        require(metric["eventToSelection"]["count"] >= 30, name + " needs at least 30 changed selections")
        require(metric["eventToViewUpdate"]["count"] == metric["eventToSelection"]["count"], name + " lost view updates")
    require(image["status"] == "passed", "Image benchmark did not finish successfully")
    if not measure_only:
        require(ui["mode"] == "budget-gated", "UI report did not enable regression timing gates")
        require(image.get("timingGatesEnabled") is True, "Image report did not enable regression timing gates")
        for name, metric in surfaces.items():
            for field, p95, maximum in (("eventToSelection",100,150),("eventToViewUpdate",150,250)):
                require(metric[field]["p95Ms"] <= p95 and metric[field]["maxMs"] <= maximum, name + "." + field + " failed absolute limits")
    metrics = {m["name"]:m for m in image["metrics"]}
    required = {"embedded_preview_app_cache_cold":30,"true_raw_app_cache_cold":30,
        "embedded_preview_warm_cache":100,"true_raw_warm_cache":50,"compare_2_native_raw":3,
        "compare_3_native_raw":3,"compare_4_native_raw":3,"sequential_preview_navigation":15,
        "rapid_navigation_cancel_burst":1,"canvas_1_fit":30,"canvas_1_zoom-pan":30,
        "canvas_2_fit":30,"canvas_2_zoom-pan":30,"canvas_4_fit":30,"canvas_4_zoom-pan":30}
    for name, minimum in required.items():
        require(name in metrics and metrics[name]["count"] >= minimum, name + " lacks required samples")
    require(len(image["fixtures"]) >= 15, "Fifteen distinct real RAW fixtures are required")
    if not measure_only:
        gates = {g["metric"]:g for g in image.get("gates",[])}
        require(set(gates) == set(metrics), "Image timing gates must cover every measured operation")
        for name, metric in metrics.items():
            gate = gates[name]
            require(gate["passed"] is True, name + " has a failed image gate")
            require(metric["p95Milliseconds"] <= gate["p95LimitMilliseconds"] and metric["maxMilliseconds"] <= gate["maxLimitMilliseconds"], name + " exceeds its reported limits")
            if gate.get("relativeP95LimitMilliseconds") is not None:
                require(metric["p95Milliseconds"] <= gate["relativeP95LimitMilliseconds"], name + " exceeds its relative limit")
    return ui, image


def compare_release_directories(current, baseline):
    ui, image = current
    old_ui, old_image = baseline
    for key in ("hardwareModel","physicalMemory","operatingSystem","build"):
        require(image[key] == old_image[key], "Baseline differs in " + key + "; record a new baseline explicitly")
    require(ui["assetCount"] == old_ui["assetCount"] and ui["fixture"] == old_ui["fixture"], "UI fixture changed")
    require(image["fixtures"] == old_image["fixtures"], "RAW fixture metadata changed")
    if old_image.get("sourceSHA256After"):
        require(image.get("sourceSHA256After") == old_image["sourceSHA256After"], "RAW fixture contents changed")
    old_surfaces = {m["surface"]:m for m in old_ui["surfaces"]}
    for metric in ui["surfaces"]:
        prior = old_surfaces[metric["surface"]]
        for field, floor in (("eventToSelection",5),("eventToViewUpdate",20)):
            budget = max(floor,prior[field]["p95Ms"] * 1.5)
            require(metric[field]["p95Ms"] <= budget,
                f"{metric['surface']}.{field}: p95 exceeds equivalent baseline +50% / {floor}ms jitter floor")


def release_directory_result(directory, baseline_dir, measure_only):
    try:
        current = load_release_directory(directory,measure_only=measure_only)
        if baseline_dir and not measure_only:
            compare_release_directories(current,load_release_directory(baseline_dir,measure_only=True))
        result = ({"status":"baseline-recorded","regressionPassed":None,"timingGatesRequired":False}
            if measure_only else {"status":"regression-passed","passed":True,"baselineCompared":bool(baseline_dir)})
    except (OSError,ValueError,KeyError,TypeError) as error:
        result = {"passed":False,"error":str(error)}
    directory.mkdir(parents=True,exist_ok=True)
    (directory / "summary.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", type=Path, nargs="+")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--baseline-dir", type=Path)
    parser.add_argument("--measure-only", action="store_true")
    parser.add_argument("--minimum-samples", type=int, default=6)
    parser.add_argument("--median-tolerance", type=float, default=0.05)
    parser.add_argument("--p95-tolerance", type=float, default=0.10)
    args = parser.parse_args()
    if len(args.paths) == 1 and (args.paths[0].is_dir() or args.baseline_dir):
        result = release_directory_result(args.paths[0],args.baseline_dir,args.measure_only)
        print(json.dumps(result,indent=2))
        return 0 if result.get("passed") is True or result.get("status") == "baseline-recorded" else 1
    if len(args.paths) != 2 or args.baseline_dir or args.measure_only:
        parser.error("Use REPORT_DIRECTORY for UI/image checks, or BASELINE_EXPORT CURRENT_EXPORT for monitor checks")
    try:
        result = compare(args.paths[0],args.paths[1],args.minimum_samples,args.median_tolerance,args.p95_tolerance)
    except (OSError, ValueError, KeyError, TypeError, statistics.StatisticsError) as error:
        result = {"passed": False, "error": str(error)}
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if result.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
