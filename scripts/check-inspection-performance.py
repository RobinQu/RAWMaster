#!/usr/bin/env python3
"""Qualify real-RAW inspection results and compare per-operation warm latency for a release."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "docs/research/camera-raw-parity"))
from performance_controls import inspection_rows


def qualify(path):
    data = json.loads(path.read_text())
    if data.get("build") != "release" or not data.get("binarySHA256") or not data.get("gpu"):
        raise ValueError("Expected a release inspection run with executable and GPU provenance")
    rows = inspection_rows(data, path.name)
    if not rows or any(row["state"] != "measured" for row in rows.values()):
        raise ValueError("Unverified inspection results: " + ", ".join(k for k,r in rows.items() if r["state"] != "measured"))
    return data, rows


def compare(current, reference):
    data, rows = qualify(current)
    result = {"count":len(rows),"sourceSHA256":data["sourceSHA256"],"failures":[],"comparisons":{}}
    if reference is None: return result
    old_data, old_rows = qualify(reference)
    if any(data[k] != old_data[k] for k in ("sourceSHA256","os","gpu","decoder","inspectionFramePixels","repeats")):
        raise ValueError("Incompatible source, host, decoder, sample count or viewport")
    for key, old in old_rows.items():
        if key not in rows or any(rows[key][k] != old[k] for k in ("input","boundary")):
            raise ValueError("Missing or changed inspection workload: " + key)
        checks = {}
        for field, scale, floor in (("medianMs",.10,1),("p95Ms",.20,2)):
            previous, current_ms = old["timing"][field], rows[key]["timing"][field]
            limit = previous + max(previous*scale,floor)
            checks[field] = {"previous":previous,"current":current_ms,"limit":limit}
            if current_ms > limit: result["failures"].append(f"{key} {field}: {current_ms:.2f} > {limit:.2f} ms")
        result["comparisons"][key] = checks
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current",type=Path)
    parser.add_argument("--baseline",type=Path)
    parser.add_argument("--output",type=Path,required=True)
    args = parser.parse_args()
    try:
        result = compare(args.current,args.baseline)
    except (ValueError,TypeError,OSError,KeyError) as error:
        result = {"failures":[str(error)]}
    result["status"] = "failed" if result["failures"] else "passed"
    args.output.write_text(json.dumps(result,indent=2)+"\n")
    print(result["status"],*result["failures"],sep="\n")
    raise SystemExit(int(bool(result["failures"])))
