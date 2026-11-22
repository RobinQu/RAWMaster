#!/usr/bin/env python3
"""Validate real-RAW canvas reports; compare only equivalent protocols."""
import argparse
import json
from pathlib import Path

CASES = {"exposure", "color", "texture", "clarity", "compound"}
BURST_PROTOCOL = "interactive-burst-one-settled-per-case-v1"
ABSOLUTE_MEDIANS = {"exposure": 30, "color": 30, "texture": 35, "clarity": 35, "compound": 45}


def load(path):
    data = json.loads(path.read_text())
    if data.get("build") != "release":
        raise ValueError("Performance report is not a Release build")
    if "failure" in data:
        raise ValueError("Performance report contains a failure")
    present = {key for key in CASES if key in data}
    if present != CASES:
        raise ValueError(f"Missing performance cases: {sorted(CASES - present)}")
    burst = data.get("protocol") == BURST_PROTOCOL
    for name in sorted(CASES):
        for phase in ("interactive", "settledAfterGesture"):
            metric = data[name].get(phase, {})
            minimum = 1 if burst and phase == "settledAfterGesture" else 6
            if metric.get("count", 0) < minimum or metric.get("count") != len(metric.get("samplesMs", [])):
                raise ValueError(f"{name}.{phase} lacks complete samples")
            if any(not isinstance(x, (int, float)) or x < 0 for x in metric["samplesMs"]):
                raise ValueError(f"{name}.{phase} has invalid timing")
    if "allInteractive" not in data or data["allInteractive"].get("count") != 36:
        raise ValueError("The complete 36-sample interactive sequence is required")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("current", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    baseline_path = args.baseline / "editing-interaction-performance.json"
    current_path = args.current / "editing-interaction-performance.json"
    try:
        baseline, current = load(baseline_path), load(current_path)
        for key in ("sourceSHA256", "sourcePixelWidth", "sourcePixelHeight", "measurementBoundary"):
            if baseline[key] != current[key]:
                raise ValueError(f"Baseline differs in {key}")
        if current["sourceSHA256After"] != current["sourceSHA256"]:
            raise ValueError("Source RAW changed during the test")
        same_protocol = baseline.get("protocol", "settled-every-gesture-v1") == current.get("protocol", "settled-every-gesture-v1")
        rows = []
        for name in sorted(CASES):
            old = baseline[name]
            new = current[name]
            old_median = old["interactive"]["medianMs"]
            new_median = new["interactive"]["medianMs"]
            if same_protocol and new_median > old_median * 1.05:
                raise ValueError(f"{name} interactive median regressed by more than 5%")
            if not same_protocol and new_median > ABSOLUTE_MEDIANS[name]:
                raise ValueError(f"{name} exceeds its interactive-burst absolute gate")
            rows.append({
                "case": name,
                "baselineInteractiveMedianMs": old_median,
                "currentInteractiveMedianMs": new_median,
                "interactiveChangePercent": (new_median / old_median - 1) * 100,
                "baselineSettledMedianMs": old["settledAfterGesture"]["medianMs"],
                "currentSettledMedianMs": new["settledAfterGesture"]["medianMs"],
            })
        old_all = baseline["allInteractive"]["medianMs"]
        new_all = current["allInteractive"]["medianMs"]
        if same_protocol and new_all > old_all * 0.95:
            raise ValueError("Aggregate interactive median did not improve by at least 5%")
        if not same_protocol and new_all > 40:
            raise ValueError("Aggregate interactive-burst median exceeds 40 ms")
        result = {
            "passed": True,
            "sourceSHA256": current["sourceSHA256"],
            "measurementBoundary": current["measurementBoundary"],
            "protocol": current.get("protocol", "settled-every-gesture-v1"),
            "baselineCompared": same_protocol,
            "aggregateBaselineMedianMs": old_all,
            "aggregateCurrentMedianMs": new_all,
            "aggregateImprovementPercent": (1 - new_all / old_all) * 100 if same_protocol else None,
            "cases": rows,
            "lightflowReference": current["lightflowReference"],
            "crossApplicationCaveat": "Different timing boundaries; report ranges, not a strict cross-app percentage ranking",
        }
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {"passed": False, "error": str(error)}
    output = args.output or args.current / "comparison-summary.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
