#!/usr/bin/env python3
"""Check Spec 043's three-way native-window photo response against the faster original."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import runpy
import sys

from canvas_latency import POLICY, warmup_states

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "docs/research/camera-raw-parity"))
from performance_controls import stats

CASES = {
    key: [first, second]
    for key, first, second in runpy.run_path(str(Path(__file__).with_name("benchmark-acr-canvas.py")))["CASES"].values()
}
PRODUCTS = ("RAWMaster", "LightFlow", "Camera Raw")
ORIGINALS = ("LightFlow", "Camera Raw")
PROTOCOL = "screen-photo-response-v1"
MINIMUM_HISTORY_SAMPLES = 10
MINIMUM_RELEASE_SAMPLES = 30
MINIMUM_RELEASE_WARMUP = 5
INVALID = (ValueError, TypeError, KeyError, IndexError, OverflowError)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def sha256(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def inspect_capture(product, data):
    require(type(data["schemaVersion"]) is int and data["schemaVersion"] == 1
            and data["protocol"] == PROTOCOL, f"expected {PROTOCOL}")
    require(data["policy"] == POLICY, "screen scoring policy differs")
    require(sha256(data["sourceSHA256"]) and data["sourceSHA256After"] == data["sourceSHA256"],
            "source SHA-256 changed or is missing")
    require(all(isinstance(data[key], str) and data[key].strip() for key in ("hardware", "os", "driver", "startedAt")),
            "hardware, OS, input driver or capture time missing")
    require("osBuild" not in data or isinstance(data["osBuild"], str) and data["osBuild"].strip(), "invalid OS build")
    require("requestedWarmSamples" not in data or type(data["requestedWarmSamples"]) is int
            and data["requestedWarmSamples"] >= 2, "invalid requested warm sample count")
    require("requestedWarmupInputs" not in data or type(data["requestedWarmupInputs"]) is int
            and data["requestedWarmupInputs"] >= 0, "invalid requested warmup count")
    require(isinstance(data["operations"], dict) and not data.get("interruption"), "capture was interrupted")
    rect = data["photoRectPixels"]
    require(isinstance(rect, list) and len(rect) == 4 and all(type(value) is int for value in rect),
            "missing integer photo bounds")
    x, y, width, height = rect
    require(x >= 0 and y >= 0 and width > 0 and height > 0, "invalid photo bounds")

    windows = [data["window"]] if "window" in data else [session["window"] for session in data.get("sessions", [])]
    require(windows, "missing captured window identity")
    titles = {window["title"] for window in windows}
    require(all(isinstance(title, str) for title in titles), "invalid window title")
    roi = data["roi"]
    require(len(roi) == 4 and all(number(v) and 0 <= v <= 1 for v in roi), "invalid captured photo ROI")
    for window in windows:
        scale = window["scale"]
        window_width, window_height = [round(size * scale) for size in window["frame"][2:]]
        require(window_width > 0 and window_height > 0 and x + width <= window_width + 1
                and y + height <= window_height + 1, "photo does not fit captured window")
        expected_roi = [x + .2 * width, y + .2 * height, .6 * width, .6 * height]
        actual_roi = [value * size for value, size in zip(roi, [window_width, window_height] * 2)]
        require(all(abs(a - b) <= 1 for a, b in zip(expected_roi, actual_roi)),
                "capture ROI does not sample the central 60% of the photo")

    provenance = {field: data[field] for field in ("driver", "startedAt", "finishedAt", "osBuild", "build", "browser",
                  "browserBinarySHA256", "testBundleSHA256", "flashRawLibrarySHA256", "recorderSHA256") if field in data}
    if product == "RAWMaster":
        require(all(title.startswith("RAWMaster Presented Canvas ") for title in titles)
                and sha256(data["testBundleSHA256"]) and sha256(data["flashRawLibrarySHA256"]),
                "missing RAWMaster release canvas identity")
    elif product == "LightFlow":
        engine_names = ("lightflow_host_wasm.js", "lightflow_host_wasm_bg.wasm")
        require(isinstance(data["build"], str) and data["build"] and isinstance(data["uiSHA256"], dict),
                "missing original LightFlow engine identity")
        engine = {Path(path).name: digest for path, digest in data["uiSHA256"].items()
                  if re.fullmatch(r"_b/\d+-" + re.escape(data["build"]) + r"/rust/web/[^/]+", path)
                  and Path(path).name in engine_names}
        require(data["application"] == "LightFlow" and sha256(data["browserBinarySHA256"])
                and all(title.startswith("LightFlow RAW benchmark ") for title in titles)
                and data["viewport"]["frame"]["fullRes"] is True and data["finishedAt"]
                and all(sha256(engine.get(asset)) for asset in engine_names),
                "missing original LightFlow viewer, runtime or engine identity")
        provenance["engineSHA256"] = engine
    else:
        require(len(titles) == 1 and re.fullmatch(r"Camera Raw \d+(?:\.\d+)+", next(iter(titles)))
                and data["finishedAt"], "missing original Camera Raw dialog identity")
        provenance["cameraRaw"] = next(iter(titles))
    return provenance


def measured_timing(product, row, values):
    require(row["scope"] == "central 60% of displayed photo"
            and len(row["values"]) == 2 and all(number(value) for value in row["values"])
            and row["values"] == values, "operation scope or A/B control values differ")
    refs = row["referenceDigests"]
    separation = row["separationRGB8"]
    require(len(refs) == 2 and all(sha256(ref) for ref in refs) and refs[0] != refs[1]
            and number(separation) and POLICY["minimumSeparationRGB8"] <= separation <= 255,
            "missing distinct calibration frames")
    warmup, calibration, trials = row.get("warmup", []), row["calibration"], row["trials"]
    require(isinstance(warmup, list) and isinstance(calibration, list) and len(calibration) == 2
            and isinstance(trials, list) and trials, "expected warmup, two calibration inputs and warm samples in order")
    events = calibration + trials
    all_inputs = warmup + events
    stamps = [event["sentNs"] for event in all_inputs]
    require(all(type(stamp) is int and stamp > 0 for stamp in stamps)
            and all(a < b for a, b in zip(stamps, stamps[1:])), "input timestamps are missing or out of order")
    expected_states = warmup_states(len(warmup)) + [i % 2 for i in range(len(events))]
    for i, (event, state) in enumerate(zip(all_inputs, expected_states)):
        committed = event["committedValue"] if product == "Camera Raw" else event["actual"]
        if product == "Camera Raw" and isinstance(committed, str):
            committed = float(committed)
        require(type(event["state"]) is int and event["state"] == state and event["accepted"] is True
                and number(committed) and abs(committed - values[state]) < 1e-4,
                f"input {i + 1} failed the alternating committed-value witness")
        if product == "LightFlow":
            require(number(event["value"]) and event["value"] == values[state],
                    f"input {i + 1} did not request the calibrated value")
        if product == "RAWMaster":
            fingerprint = event["recipeFingerprint"]
            require(sha256(fingerprint) and fingerprint == calibration[state]["recipeFingerprint"],
                    f"input {i + 1} did not reproduce the calibrated recipe")
    if product == "RAWMaster":
        require(calibration[0]["recipeFingerprint"] != calibration[1]["recipeFingerprint"],
                "calibration recipes must differ")

    first_error = (1 - POLICY["firstFraction"]) * separation
    final_error = POLICY["finalToleranceFraction"] * separation
    for i, trial in enumerate(trials):
        trace = trial["changesMsAndTargetError"]
        latency = trial["firstMs"]
        final = trial["finalErrorRGB8"]
        require(trial["verified"] is True and number(latency) and latency > 0
                and number(final) and 0 <= final <= final_error and trace
                and all(number(ms) and ms >= 0 and number(error) and 0 <= error <= 255 for ms, error in trace)
                and all(a[0] < b[0] for a, b in zip(trace, trace[1:]))
                and latency == next((ms for ms, error in trace if error <= first_error), None),
                f"warm sample {i + 1} failed the displayed-pixel witness")
        if i + 1 < len(trials):
            require(trace[-1][0] < (trials[i + 1]["sentNs"] - trial["sentNs"]) / 1e6,
                    f"warm sample {i + 1} extends beyond the next input")
    return stats([trial["firstMs"] for trial in trials]), len(warmup)


def compare_operation(captures, key, missing_os_build):
    values = CASES[key]
    result = {"values": values, "state": "inconclusive", "passed": False, "products": {}}
    for product, capture in captures.items():
        row = capture["operations"].get(key)
        try:
            require(isinstance(row, dict), "no capture for this operation")
            require(row.get("status") == "measured", row.get("reason") or "no qualified pixel change")
            timing, warmup = measured_timing(product, row, values)
            require(timing["n"] == capture.get("requestedWarmSamples", timing["n"]),
                    "warm sample count differs from the recorded capture plan")
            require(warmup == capture.get("requestedWarmupInputs", warmup),
                    "unscored warmup count differs from the recorded capture plan")
        except INVALID as error:
            result["products"][product] = {"state": "inconclusive", "reason": str(error)}
        else:
            result["products"][product] = {"state": "measured", "timing": timing, "unscoredWarmupInputs": warmup}
    products = result["products"]
    if any(item["state"] != "measured" for item in products.values()):
        return result
    timings = {product: item["timing"] for product, item in products.items()}
    minimum = min(timing["n"] for timing in timings.values())
    if minimum < MINIMUM_HISTORY_SAMPLES:
        result["reason"] = f"fewer than {MINIMUM_HISTORY_SAMPLES} valid warm samples per product"
        return result
    release_requirements = []
    if minimum < MINIMUM_RELEASE_SAMPLES:
        release_requirements.append(f"at least {MINIMUM_RELEASE_SAMPLES} warm samples per product")
    if min(item["unscoredWarmupInputs"] for item in products.values()) < MINIMUM_RELEASE_WARMUP:
        release_requirements.append(f"at least {MINIMUM_RELEASE_WARMUP} unscored warmup inputs per product")
    if release_requirements:
        result.update(state="history", reason="requires " + " and ".join(release_requirements))
    elif missing_os_build:
        result["reason"] = "missing recorded OS build for " + ", ".join(missing_os_build)
        return result
    else:
        result["state"] = "qualified"
    comparison = {}
    for name, field, fraction, floor in (("p50", "medianMs", .10, 1), ("p95", "p95Ms", .20, 2)):
        ordered = sorted(PRODUCTS, key=lambda product: timings[product][field])
        fastest = min(timings[product][field] for product in ORIGINALS)
        native = timings["RAWMaster"][field]
        limit = fastest + max(floor, fastest * fraction)
        comparison[name] = {"rankedProducts": ordered, "fastestOriginals": [product for product in ORIGINALS
                            if timings[product][field] == fastest], "fastestOriginalMs": fastest,
                            "limitMs": limit, "rawmasterDeltaMs": native - fastest, "withinBudget": native <= limit}
    result["comparison"] = comparison
    result["passed"] = result["state"] == "qualified" and all(row["withinBudget"] for row in comparison.values())
    return result


def compare(paths, operations):
    result = {"schemaVersion": 1, "spec": "043", "protocol": PROTOCOL, "policy": POLICY,
              "metric": "native-window input to first verified photo response (firstMs)",
              "minimumWarmSamples": MINIMUM_RELEASE_SAMPLES, "minimumUnscoredWarmupInputs": MINIMUM_RELEASE_WARMUP,
              "requiredOperations": operations,
              "inputs": {}, "operations": {}, "failures": [], "passed": False}
    captures = {}
    for product, path in paths.items():
        try:
            contents = path.read_bytes()
            capture = json.loads(contents)
            provenance = inspect_capture(product, capture)
        except (OSError, *INVALID) as error:
            result["failures"].append(f"{product}: {error}")
        else:
            captures[product] = capture
            result["inputs"][product] = {"path": str(path), "reportSHA256": hashlib.sha256(contents).hexdigest(),
                                         **provenance}
    if result["failures"]:
        return result

    native = captures["RAWMaster"]
    builds = {capture["osBuild"] for capture in captures.values() if capture.get("osBuild")}
    missing_os_build = [product for product, capture in captures.items() if "osBuild" not in capture]
    result.update(sourceSHA256=native["sourceSHA256"], hardware=native["hardware"], os=native["os"],
                  photoPixels=native["photoRectPixels"][2:])
    for product in ORIGINALS:
        capture = captures[product]
        for field in ("sourceSHA256", "hardware", "os"):
            if capture[field] != result[field]:
                result["failures"].append(f"{product}: {field} differs from RAWMaster")
        if capture["photoRectPixels"][2:] != result["photoPixels"]:
            result["failures"].append(f"{product}: captured photo size differs from RAWMaster")
    if len(builds) > 1:
        result["failures"].append("OS builds differ between capture reports")
    if result["failures"]:
        return result
    if not missing_os_build:
        result["osBuild"] = native["osBuild"]

    for key in operations:
        row = compare_operation(captures, key, missing_os_build)
        result["operations"][key] = row
        if row["state"] == "history":
            result["failures"].append(f"{key}: history {row['reason']}")
        elif row["state"] == "inconclusive":
            result["failures"].append(f"{key}: " + row.get("reason", "missing or mismatched three-way evidence"))
        elif not row["passed"]:
            failed = ", ".join(name for name, metric in row["comparison"].items() if not metric["withinBudget"])
            result["failures"].append(f"{key}: RAWMaster {failed} exceeds the fastest-original budget")
    result["passed"] = not result["failures"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rawmaster", required=True, type=Path)
    parser.add_argument("--lightflow", required=True, type=Path)
    parser.add_argument("--camera-raw", required=True, type=Path)
    parser.add_argument("--operations", nargs="+", choices=CASES, default=list(CASES),
                        help="required subset of the visible control inventory (default: all controls)")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    paths = dict(zip(PRODUCTS, (args.rawmaster, args.lightflow, args.camera_raw)))
    if args.output.exists() or len(args.operations) != len(set(args.operations)):
        parser.error("provide a new output path and unique required operations")
    result = compare(paths, args.operations)
    with args.output.open("x") as output:
        json.dump(result, output, indent=2, allow_nan=False)
        output.write("\n")
    print("Passed" if result["passed"] else "Failed\n" + "\n".join(result["failures"]))
    return int(not result["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
