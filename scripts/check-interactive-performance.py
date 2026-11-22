#!/usr/bin/env python3
"""Validate and compare the complete real-RAW interactive operator sequence."""
import argparse
import json
import math
import statistics
from pathlib import Path

SCHEMA = 1
OPERATIONS = (
    "neutral", "exposure-color", "adaptive-brilliance", "texture", "clarity", "dehaze-v1", "dehaze-v2",
    "geometry", "post-crop-vignette", "lens-blur-procedural", "lens-blur-device-depth", "lens-blur-refine-focus", "lens-blur-refine-blur", "lens-blur-refine-auto-mask", "lens-blur-bokeh-bubble", "lens-blur-bokeh-five-blade",
    "lens-blur-bokeh-ring", "lens-blur-bokeh-anamorphic", "lens-blur-cat-eye", "lens-blur-bokeh-boost", "lens-blur-depth-preview", "local-glow", "bw-mixer", "point-variance", "targeted-hsl", "visualise-range", "hue-isolation", "clipping-shadows", "clipping-highlights",
    "wb-flash-preset", "refine-saturation", "point-curve-targeted", "defringe", "point-color-samples", "local-point-color",
    "local-light-extended", "local-wb", "local-hue-colorize", "local-texture-clarity", "local-dehaze", "local-grain",
    "local-curves", "local-grading", "local-detail", "local-defringe", "global-sharpen-detail", "global-sharpen-mask-preview", "global-noise-detail",
    "optics-ca-distortion", "optics-lens-profile",
)


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def metric(values):
    if not values or any(not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("Timing samples must be finite, positive and complete")
    return {"count": len(values), "medianMs": statistics.median(values),
            "p95Ms": percentile(values, 0.95), "maxMs": max(values), "samplesMs": values}


def load(path, historical=False):
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != SCHEMA or data.get("build") != "release":
        raise ValueError("Interactive report must use schema v1 and an explicit Release build")
    if data.get("canonicalFlashRaw") is not True or data.get("flashRawAvailable") is not True:
        raise ValueError("The release operator baseline requires actual FlashRaw availability and canonical rendering")
    if not historical and (data.get("sourceDecoder") != "flashraw-0.3.1-linear-srgb-bilinear" or data.get("decoderOverride") is not False):
        raise ValueError("Release measurement requires the persisted production FlashRaw source decoder without an override")
    if not historical:
        recent = data.get("flashRawDecodeStatistics") or []
        native = data.get("latestFlashRawDecode") or (recent[0] if recent else None)
        if not isinstance(native, dict) or not native.get("decoderBackend") or native.get("nativeWallMilliseconds",0) <= 0 or len(native.get("stages",[])) != 11:
            raise ValueError("The release report is missing the decoder's native backend and stage timings")
    if data.get("prewarming") is not True:
        raise ValueError("The warm operator sequence requires explicit shader prewarming")
    if not data.get("sourceSHA256") or data.get("sourceSHA256After") != data.get("sourceSHA256"):
        raise ValueError("Source identity is missing or the RAW changed during measurement")
    if data.get("transparentFrameFailures") != []:
        raise ValueError("Any transparent interactive or settled frame rejects the report")
    rows = data.get("measurements", [])
    labels = [row.get("label") for row in rows]
    if len(labels) != len(set(labels)) or set(labels) != set(OPERATIONS):
        raise ValueError(f"Operation coverage differs; missing={sorted(set(OPERATIONS)-set(labels))}, added={sorted(set(labels)-set(OPERATIONS))}")
    result = {}
    for row in rows:
        interactive = metric(row.get("interactiveMilliseconds", []))
        if interactive["count"] != 3:
            raise ValueError(f"{row['label']} requires exactly three interactive samples")
        settled = metric([row.get("settledMilliseconds")])
        if row.get("width", 0) <= 0 or row.get("height", 0) <= 0:
            raise ValueError(f"{row['label']} has an invalid output size")
        p99 = row.get("p99ChannelError")
        maximum = row.get("maximumChannelError")
        historical_size_mismatch = historical and p99 == -1 and maximum == -1 and "qualityComparison" not in row
        if not historical_size_mismatch and (type(p99) is not int or type(maximum) is not int or not 0 <= p99 <= maximum <= 255):
            raise ValueError(f"{row['label']} has invalid proxy error evidence")
        if not historical and (not row.get("effectiveDecoder") or row.get("qualityComparison") not in ("matched-pixels","settled-resampled-to-proxy")):
            raise ValueError(f"{row['label']} is missing its effective decoder or comparison method")
        result[row["label"]] = {"interactive": interactive, "settled": settled, "outputPixels": [row["width"],row["height"]],
                                "p99ChannelError": p99, "maximumChannelError": row.get("maximumChannelError")}
    return data, result


def compare(baseline_path, current_path, measure_only, interactive_tolerance, settled_tolerance, absolute_median_ms, p99_tolerance=1):
    if type(p99_tolerance) is not int or not 0 <= p99_tolerance <= 255:
        raise ValueError("The p99 tolerance must be an integer from 0 to 255")
    current_data, current = load(current_path)
    baseline_data, baseline = (None, None)
    if baseline_path:
        baseline_data, baseline = load(baseline_path, historical=True)
        if baseline_data["sourceSHA256"] != current_data["sourceSHA256"]:
            raise ValueError("Baseline and current reports use different RAW sources")
        if baseline_data.get("proxyVersion") != current_data.get("proxyVersion"):
            raise ValueError("Baseline and current reports use different proxy protocols")
    rows, failures = [], []
    for name in OPERATIONS:
        new = current[name]
        row = {"operation": name, "current": new}
        if not measure_only and new["interactive"]["medianMs"] > absolute_median_ms:
            failures.append(f"{name}: interactive median exceeds {absolute_median_ms:g} ms")
        if baseline:
            old = baseline[name]
            row["baseline"] = old
            if new["outputPixels"] != old["outputPixels"]:
                raise ValueError(f"{name}: baseline and current reports use different output sizes")
            if old["p99ChannelError"] >= 0:
                delta = new["p99ChannelError"] - old["p99ChannelError"]
                row["p99ChannelErrorChange"] = delta
                if not measure_only and delta > p99_tolerance:
                    failures.append(f"{name}: p99 channel error rose from {old['p99ChannelError']} to {new['p99ChannelError']} (+{delta}/255)")
            else:
                row["p99ChannelErrorChange"] = None
            for phase, tolerance in (("interactive", interactive_tolerance), ("settled", settled_tolerance)):
                change = new[phase]["medianMs"] / old[phase]["medianMs"] - 1
                row[phase + "MedianChangePercent"] = change * 100
                if not measure_only and change > tolerance:
                    failures.append(f"{name}: {phase} median regressed {change*100:.2f}%")
        rows.append(row)
    result = {"passed": not failures, "schemaVersion": SCHEMA,
        "sourceSHA256": current_data["sourceSHA256"], "proxyVersion": current_data.get("proxyVersion"),
        "operationCount": len(rows), "baseline": str(baseline_path) if baseline_path else None,
        "current": str(current_path), "measureOnly": measure_only,
        "policy": {"requiredOperations": list(OPERATIONS), "interactiveSamplesPerOperation": 3,
            "maximumInteractiveMedianMs": None if measure_only else absolute_median_ms,
            "maximumInteractiveRegressionPercent": None if measure_only else interactive_tolerance * 100,
            "maximumSettledRegressionPercent": None if measure_only else settled_tolerance * 100,
            "maximumP99ChannelErrorIncrease": None if measure_only else p99_tolerance,
            "transparentFramesAllowed": False, "crossApplicationParityClaimed": False},
        "failures": failures, "operations": rows}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--measure-only", action="store_true")
    parser.add_argument("--interactive-tolerance", type=float, default=0.10)
    parser.add_argument("--settled-tolerance", type=float, default=0.20)
    parser.add_argument("--absolute-median-ms", type=float, default=50)
    parser.add_argument("--p99-tolerance", type=int, default=1, help="Maximum increase from measured baseline p99, in 8-bit channel levels")
    args = parser.parse_args()
    try:
        result = compare(args.baseline, args.current, args.measure_only,
            args.interactive_tolerance, args.settled_tolerance, args.absolute_median_ms, args.p99_tolerance)
    except (OSError, ValueError, KeyError, TypeError, statistics.StatisticsError) as error:
        result = {"passed": False, "error": str(error)}
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if result.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
