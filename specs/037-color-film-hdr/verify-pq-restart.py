#!/usr/bin/env python3
"""Kill only the private XCTest writer after it has durably prepared its second PQ file."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import time


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def rows(root):
    database = (root / "catalog/library.sqlite").resolve()
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        items = (json.loads(value) for (value,) in connection.execute(
            "SELECT value FROM lc_meta WHERE key GLOB 'wb032.item.v1/*' ORDER BY key"))
        return {item["ordinal"]: item for item in items}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-dir", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New directory for the isolated test and receipts")
    args = parser.parse_args()
    bundle = (args.products_dir / "RAWMasterUITests.xctest").resolve(strict=True)
    xctest = subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip()
    case = "RAWMasterUITests.WorkbenchContinuation035Tests/testOptInWorkbenchPQPreparedAcrossProcesses"
    command = [xctest, "-XCTest", case, str(bundle)]
    root = args.output.resolve()
    root.mkdir(parents=True)
    (root / "catalog").mkdir()
    marker = root / "checkpoint"
    environment = dict(os.environ, RAWMASTER_037_PQ_RESTART_ROOT=str(root),
                       RAWMASTER_SCENE_RAW_FIXTURES=str(args.fixtures.resolve(strict=True)))
    start = time.monotonic()
    with (root / "write.log").open("wb") as log:
        with subprocess.Popen(command, env=dict(environment, RAWMASTER_037_PQ_RESTART_PHASE="write"),
                              stdout=log, stderr=subprocess.STDOUT) as process:
            deadline = time.monotonic() + 60
            try:
                while not marker.exists():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"Writer never reached prepared ticket; see {log.name}")
                    time.sleep(0.02)
                pid, checkpoint = marker.read_text().split()
                if int(pid) != process.pid or checkpoint != "prepared":
                    raise RuntimeError("Unexpected test process marker")
            finally:
                if process.poll() is None:
                    process.kill()
            if process.wait(timeout=5) != -signal.SIGKILL:
                raise RuntimeError("Writer did not terminate at the selected native checkpoint")
    writer_seconds = time.monotonic() - start
    pending = rows(root)
    first, second = pending[1], pending[2]
    assert first["state"] == "delivered" and second["state"] == "prepared", pending
    output = root / "delivery"
    finished = output / first["ticket"]["filename"]
    original_stat = finished.stat()
    staged = list(output.glob(".rawmaster-export-*/pixels.avif"))
    assert len(staged) == 1 and digest(staged[0]) == second["ticket"]["sha256"]
    with (root / "reopen.log").open("wb") as log:
        subprocess.run(command, env=dict(environment, RAWMASTER_037_PQ_RESTART_PHASE="reopen"),
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=85)
    last = rows(root)
    after = finished.stat()
    assert (original_stat.st_dev, original_stat.st_ino) == (after.st_dev, after.st_ino)
    assert last[2]["ticket"]["sha256"] == second["ticket"]["sha256"]
    results = json.loads((root / "receipt.json").read_text())
    assert set(results["files"]) == {p.name for p in output.glob("*.avif")}
    for item in last.values():
        name = item["ticket"]["filename"]
        file = output / name
        assert item["state"] == "delivered" and item["ticket"]["sha256"] == results["files"][name] == digest(file)
        readback = subprocess.check_output(["avifdec", "--info", str(file)], text=True)
        assert "Decoded frame [0]" in readback and "4000x6000" in readback, readback
        assert " * Bit Depth      : 10" in readback and " * Color Primaries: 9" in readback and " * Transfer Char. : 16" in readback, readback
        assert " * Matrix Coeffs. : 1" in readback and " * Range          : Full" in readback, readback
        assert "CLLI" not in readback, "ImageIO defaults must not be declared as picture limits"
        (root / (name + ".readback.txt")).write_text("\n".join(line for line in readback.splitlines() if not line.startswith("Image decoded:")) + "\n")
    results.update(writerTermination="SIGKILL after prepared", nativeWriterWallSeconds=writer_seconds,
                   decodedDimensions=[4000, 6000], bitDepth=10, fullRange=True, cicp=[9, 16, 1], pictureLightLevels="unspecified",
                   decoder=subprocess.check_output(["avifdec", "--version"], text=True).splitlines()[0],
                   testExecutableSHA256=digest(bundle / "Contents/MacOS/RAWMasterUITests"))
    (root / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
    print(root / "summary.json")


if __name__ == "__main__":
    main()
