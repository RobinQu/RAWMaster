#!/usr/bin/env python3
"""Compare every generated delivery case against its frozen reference, sequentially."""
import argparse
import json
import os
import subprocess
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True)
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    run = os.path.abspath(args.run)
    repo = os.path.abspath(args.repo)
    with open(os.path.join(run, "run-start.json")) as file:
        start = json.load(file)
    references = start["references"]
    output_root = os.path.join(run, "comparisons")
    os.makedirs(output_root, exist_ok=True)
    rows = []
    for case in start["cases"]:
        receipt_path = os.path.join(run, case, "candidate-receipt.json")
        with open(receipt_path) as file:
            receipt = json.load(file)
        reference = references[case]
        case_out = os.path.join(output_root, case)
        os.makedirs(case_out, exist_ok=True)
        scratch = os.path.join(case_out, "scratch")
        os.makedirs(scratch, exist_ok=True)
        result_path = os.path.join(case_out, "comparison.json")
        if not os.path.exists(result_path):
            command = [
                "python", os.path.join(repo, "scripts/compare-adjustment-reference.py"),
                "--reference", reference["path"], "--candidate", receipt["candidate"],
                "--reference-sha256", reference["sha256"],
                "--protocol", os.path.join(repo, "output/validation/021-photos-editor/reference-protocol.json"),
                "--output", result_path, "--scratch-parent", scratch,
                "--category", reference["category"],
            ]
            log_path = os.path.join(case_out, "compare.log")
            with open(log_path, "wb") as log:
                result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT)
            # The comparator returns 1 for a completed measurement that fails its quality gate.
            if result.returncode not in (0, 1):
                raise SystemExit(f"Comparator execution failed for {case}: {result.returncode}")
        with open(result_path) as file:
            measured = json.load(file)
        if measured["reference"]["sha256"] != reference["sha256"] or measured["candidate"]["sha256"] != receipt["candidateSHA256"]:
            raise SystemExit("Existing comparison identity mismatch: " + case)
        rows.append({
            "case": case,
            "category": reference["category"],
            "qualification": measured["qualification"],
            "candidateSHA256": receipt["candidateSHA256"],
            "referenceSHA256": reference["sha256"],
            "publicRenderIncludingVerifyCaptureEncodeIOMilliseconds": receipt["publicRenderIncludingVerifyCaptureEncodeIOMilliseconds"],
            "comparison": result_path,
        })
        print(json.dumps(rows[-1]), flush=True)
    summary = {
        "generationRun": run,
        "count": len(rows),
        "pass": sum(row["qualification"] == "PASS" for row in rows),
        "fail": sum(row["qualification"] == "FAIL" for row in rows),
        "unverified": sum(row["qualification"] == "UNVERIFIED" for row in rows),
        "rows": rows,
    }
    summary_path = os.path.join(run, "comparison-summary.json")
    with open(summary_path, "x") as file:
        json.dump(summary, file, indent=2, ensure_ascii=False)
    print(json.dumps({key: value for key, value in summary.items() if key != "rows"}), flush=True)
    return 0 if summary["fail"] == 0 and summary["unverified"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
