"""Verify the private VFS mapping and the writer lock in generated Linux catalogs."""

from pathlib import Path
import argparse
import json
import os
import sys
import tempfile
from build_variant import build, repo
from epoch import check_epoch
from fixtures import cases, digest, drive
from timing import measure

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=0)
    args = parser.parse_args()
    work = args.build_dir.resolve()
    output = args.output.resolve()
    if (
        not __debug__
        or sys.platform != "linux"
        or os.uname().machine != "aarch64"
        or (args.rounds and args.rounds < 6)
    ):
        raise SystemExit("Use Linux arm64 and at least six rounds for timings.")
    if (
        (work.is_relative_to(repo) and not work.is_relative_to(repo / "output"))
        or output.exists()
        or not output.is_relative_to(work)
    ):
        raise SystemExit(
            "Use a separate build directory and a fresh result file inside it."
        )
    build(work, "release")
    binaries = work / "target/release"
    report = {
        "kernel": os.uname().release,
        "profile": "release",
        "runtimeSHA256": digest(binaries / "librawmaster_library.so"),
        "cases": [],
        "epochs": [],
    }
    with tempfile.TemporaryDirectory(dir="/tmp") as temp:
        root = Path(temp)
        for arm in ["address", "cached"]:
            for i, case in enumerate(cases.policies):
                report["cases"].append(
                    drive(binaries, arm, case, 0, root / f"{arm}-{i}")
                )
        for arm in ["address", "cached", "scan"]:
            report["epochs"].append(check_epoch(root / f"epoch-{arm}", arm, binaries))
        os.environ["RM_MAP_FORCE_UNSUPPORTED"] = "1"
        try:
            report["simulatedUnsupported"] = drive(
                binaries,
                "auto",
                next(c for c in cases.policies if c[0] == "empty-decoys-link"),
                0,
                root / "unsupported",
            )
        finally:
            del os.environ["RM_MAP_FORCE_UNSUPPORTED"]
    if args.rounds:
        report["timing"] = measure(binaries, args.rounds)
    with output.open("x") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    print("receipt", digest(output), flush=True)
