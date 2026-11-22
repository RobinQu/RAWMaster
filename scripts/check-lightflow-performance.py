#!/usr/bin/env python3
"""Compare a release and stock LightFlow on matching hardware, recipes, raster and render boundaries."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"docs/research/camera-raw-parity"))
from performance_controls import compare_panel_readback, compare_readback, panel_readback_rows, panel_schedule_rows, readback_rows
from paired_photo_operator_report import MANIFEST, PHASES, comparison as compare_photo_operators, stats


def load(path):
    return json.loads(path.read_text())


def compare(native, reference):
    lf_basic = load(reference/"lightflow-display-readback.json")
    lf_panel = load(reference/"lightflow-panel-schedule.json")
    rm_basic = load(native/"display-readback.json")
    rm_panel = load(native/"panel-schedule.json")
    for lf,rm in ((lf_basic,rm_basic),(lf_panel,rm_panel)):
        system = lf["system"]
        if (lf["sourceSHA256"] != rm["sourceSHA256"] or lf["sourceSHA256"] != lf_panel["sourceSHA256"]
                or system["chip"] != rm["gpu"] or system["os"].split("-")[1] not in rm["os"]
                or lf.get("adapterInfo",{}).get("isFallbackAdapter") is not False):
            raise ValueError("Real RAW, OS or physical GPU differs between the LightFlow reference and the native release")
    if (lf_basic["build"] != lf_panel["build"] or lf_basic["engineSHA256"] != lf_panel["engineSHA256"]
            or rm_basic["binarySHA256"] != rm_panel["binarySHA256"]):
        raise ValueError("The two workloads used different executable builds")
    basic = compare_readback(readback_rows(lf_basic,"LightFlow"),readback_rows(rm_basic,"RAWMaster"),"LightFlow","RAWMaster")
    left, right = panel_schedule_rows(lf_panel,"LightFlow"),panel_schedule_rows(rm_panel,"RAWMaster")
    panels = {p:compare_panel_readback(left[p],r,"LightFlow","RAWMaster") for p,r in right.items()}
    failures = [f"{workload}/{phase}/{key}" for workload,phases in (("basic",basic),("panels",panels))
                for phase,rows in phases.items() for key,r in rows.items() if not r["within"]]
    lf_direct = load(reference/"lightflow-panel-readback.json")
    rm_direct = load(native/"panel-readback.json")
    if (lf_direct["engineSHA256"] != lf_basic["engineSHA256"] or lf_direct["build"] != lf_basic["build"]
            or lf_direct["sourceSHA256"] != lf_basic["sourceSHA256"] or lf_direct["system"] != lf_panel["system"]
            or rm_direct["binarySHA256"] != rm_basic["binarySHA256"] or rm_direct["sourceSHA256"] != rm_basic["sourceSHA256"]
            or rm_direct["gpu"] != rm_basic["gpu"] or rm_direct["os"] != rm_basic["os"]):
        raise ValueError("The direct panel readback has a different source, build or machine")
    direct = compare_panel_readback(panel_readback_rows(lf_direct,"LightFlow"),panel_readback_rows(rm_direct,"RAWMaster"),"LightFlow","RAWMaster")
    failures.extend(f"direct/{key}" for key,r in direct.items() if r["LightFlow"] is not None and r["within"] is not True)
    lf_photo = load(reference/"lightflow-photo-operators-v2.json")
    rm_photo = load(native/"photo-operators-v2.json")
    if (lf_photo["build"] != lf_basic["build"] or lf_photo["engineSHA256"] != lf_basic["engineSHA256"]
            or rm_photo["binarySHA256"] != rm_basic["binarySHA256"]):
        raise ValueError("The photo operator suite used a different executable build")
    photo = compare_photo_operators(lf_photo,rm_photo,load(MANIFEST))["operations"]
    for key,row in photo.items():
        if not row["qualified"]:
            failures.append(f"photoOperators/pixel-validation/{key}")
        failures.extend(f"photoOperators/{phase}/{key}" for phase,metric in row["phases"].items() if not metric["within"])
    initial_mix = {}
    for phase in PHASES:
        measured = {p:stats([ms for row in photo.values() if row["qualified"] for ms in row[p]["initial"][phase]])
                    for p in ("LightFlow","RAWMaster")}
        original, release = measured["LightFlow"], measured["RAWMaster"]
        median_limit = original["medianMs"] + max(1,original["medianMs"] * .10)
        p95_limit = original["p95Ms"] + max(2,original["p95Ms"] * .20)
        within = release["medianMs"] <= median_limit and release["p95Ms"] <= p95_limit
        initial_mix[phase] = {**measured,"medianLimitMs":median_limit,"p95LimitMs":p95_limit,"within":within}
        if not within:
            failures.append(f"firstAppearanceMix/{phase}")
    return {"rawSHA256":rm_basic["sourceSHA256"],"nativeBinarySHA256":rm_basic["binarySHA256"],
            "lightflowBuild":lf_basic["build"],"gpu":rm_panel["gpu"],"basic":basic,"panels":panels,"direct":direct,
            "photoOperators":{key:row["phases"] for key,row in photo.items()},"firstAppearanceMix":initial_mix,"failures":failures}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run",type=Path)
    parser.add_argument("--reference",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    args = parser.parse_args()
    try:
        result = compare(args.run,args.reference)
    except (OSError,ValueError,TypeError,KeyError) as error:
        result = {"failures":[str(error)]}
    result["passed"] = not result["failures"]
    args.output.write_text(json.dumps(result,indent=2,allow_nan=False)+"\n")
    print("Passed" if result["passed"] else f"Failed: {', '.join(result['failures'])}")
    raise SystemExit(int(not result["passed"]))
