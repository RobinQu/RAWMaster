#!/usr/bin/env python3
"""Gate the rendered-file controls (JPEG/TIFF temperature, denoise strength and device depth)."""
import argparse
import runpy
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
witness = runpy.run_path(str(ROOT / "scripts/performance/rendered_control_witness.py"))
load, rendered_rows = witness["load"], witness["rendered_rows"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    result = {"protocol": "rawmaster-rendered-control-v1", "failures": [], "comparisons": {}}
    try:
        data, operations = load(args.report)
        result.update(sourceSHA256={k: v["sha256"] for k, v in data["sources"].items()},
                      measuredCount=sum(1 for row in operations.values() if row),
                      attempted=len(operations), repeats=data["repeats"])
        rows = rendered_rows(args.report, args.report.name)
        result["failures"].extend(f"{key}: pixel response unverified" for key, row in rows.items()
                                  if row["state"] != "measured")
        if args.baseline:
            _, reference = load(args.baseline)
            for key, row in operations.items():
                old = reference.get(key)
                if not row or not old:
                    continue
                limit = old["medianMs"] + max(old["medianMs"] * .10, 1.0)
                result["comparisons"][key] = {"previous": old["medianMs"], "current": row["medianMs"],
                                              "limit": limit}
                if row["medianMs"] > limit:
                    result["failures"].append(f"{key}: medianMs {row['medianMs']:.2f} > {limit:.2f} ms")
    except (OSError, TypeError, ValueError, KeyError) as exc:
        result["failures"].append(str(exc))
    result["status"] = "failed" if result["failures"] else ("baseline-recorded" if not args.baseline else "passed")
    args.output.write_text(__import__("json").dumps(result, indent=2) + "\n")
    print(result["status"], *result["failures"], sep="\n")
    sys.exit(int(bool(result["failures"])))
