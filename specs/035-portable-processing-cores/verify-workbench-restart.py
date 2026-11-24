#!/usr/bin/env python3
"""Run the native delivery recovery test in independent XCTest processes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import time


def read_items(run):
    path = run / "catalog/library.sqlite"
    with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as database:
        return {
            row["ordinal"]: row for value, in database.execute(
                "SELECT value FROM lc_meta WHERE key GLOB 'wb032.item.v1/*' ORDER BY key"
            ) if (row := json.loads(value)) is not None
        }


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def run_recovery(command, root, checkpoint, advanced):
    run = root / checkpoint
    run.mkdir()
    environment = dict(os.environ, RAWMASTER_035_RESTART_ROOT=str(run), RAWMASTER_035_RESTART_CHECKPOINT=checkpoint,
                       RAWMASTER_035_RESTART_ADVANCED="1" if advanced else "0")
    with (run / "write.log").open("wb") as log:
        with subprocess.Popen(command, env=dict(environment, RAWMASTER_035_RESTART_PHASE="write"),
                              stdout=log, stderr=subprocess.STDOUT) as process:
            marker = run / "checkpoint"
            deadline = time.monotonic() + 50
            try:
                while not marker.is_file():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"Native test never reached {checkpoint}. See {log.name}")
                    time.sleep(0.02)
                pid, observed = marker.read_text().split()
                if int(pid) != process.pid or observed != checkpoint:
                    raise RuntimeError("The checkpoint belongs to another process")
            finally:
                if process.poll() is None:
                    process.kill()
            if process.wait(timeout=5) != -signal.SIGKILL:
                raise RuntimeError("The writer did not terminate at the selected native checkpoint")
    items = read_items(run)
    initial_files = sorted(path.name for path in (run / "delivery").glob("*.jpg"))
    assert items[1]["state"] == "delivered"
    assert items[2]["state"] == ("running" if checkpoint == "beforePrepare" else "prepared")
    assert len(initial_files) == (2 if checkpoint == "published" else 1)
    if checkpoint == "beforePrepare":
        staged = list((run / "delivery").glob(".rawmaster-export-*/pixels.jpg"))
        assert len(staged) == 1
        second_before_reopen = digest(staged[0])
    else:
        second_before_reopen = items[2]["ticket"]["sha256"]
    with (run / "reopen.log").open("wb") as log:
        subprocess.run(command, env=dict(environment, RAWMASTER_035_RESTART_PHASE="reopen"),
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=80)
    report = json.loads((run / "receipt.json").read_text())
    files = {path.name: digest(path) for path in (run / "delivery").glob("*.jpg")}
    items = read_items(run)
    assert report["status"] == "passed" and files == report["outputs"]
    assert all(item["state"] == "delivered" for item in items.values())
    assert {item["ticket"]["filename"]: item["ticket"]["sha256"] for item in items.values()} == files
    report["secondItemMatchesPreCrashBytes"] = items[2]["ticket"]["sha256"] == second_before_reopen
    assert report["secondItemMatchesPreCrashBytes"]
    assert report["selectionPreserved"] and report["firstInodePreserved"]
    assert report["rejectedReplacementDirectory"]
    report["initialFiles"] = initial_files
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--products-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--advanced", action="store_true", help="Freeze an edited photograph with independently staged recipe resources")
    options = parser.parse_args()
    bundle = (options.products_dir / "RAWMasterUITests.xctest").resolve(strict=True)
    executable = bundle / "Contents/MacOS/RAWMasterUITests"
    xctest = subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
    command = [xctest, "-XCTest",
               "RAWMasterUITests.WorkbenchContinuation035Tests/testOptInWorkbenchDeliveryAcrossProcesses", str(bundle)]
    root = options.output.resolve()
    root.mkdir(parents=True)
    results = {}
    for checkpoint in ["beforePrepare", "prepared", "published"]:
        results[checkpoint] = run_recovery(command, root, checkpoint, options.advanced)
    hashes = [run["outputs"] for run in results.values()]
    assert results["published"]["postPublicationInodePreserved"] and results["published"]["relocationCheckedAgainstSource"]
    identical = all(outputs == hashes[0] for outputs in hashes)
    summary = {"status": "passed" if identical else "failed", "build": digest(executable),
               "sameBatchDeliveryPassed": True, "crossRunOutputSHA256Matches": identical, "restarts": results}
    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(root / "summary.json")
    if not identical:
        raise SystemExit("Output bytes differed across replayed checkpoints")


if __name__ == "__main__":
    main()
