#!/usr/bin/env python3
"""Check the read-only federation using two completed validate-discovery-native runs."""

import argparse
import json
import os
from pathlib import Path
import subprocess

MODULE = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--first", type=Path, required=True, help="four-photo native run"
    )
    parser.add_argument(
        "--second", type=Path, required=True, help="three-photo native run"
    )
    parser.add_argument(
        "--package", type=Path, required=True, help="isolated local ML runtime"
    )
    parser.add_argument(
        "--scratch", type=Path, required=True, help="new private directory"
    )
    parser.add_argument(
        "--output", type=Path, required=True, help="anonymous aggregate JSON"
    )
    args = parser.parse_args()
    first = args.first.resolve()
    scratch = args.scratch.resolve()
    scratch.mkdir(mode=0o700, parents=True, exist_ok=False)
    executable = scratch / "federation"
    sources = [
        "CatalogJSON",
        "LibraryEngine",
        "CatalogActions",
        "LibraryDiscoveryFederation",
        "LibraryDiscoveryWorker",
    ]
    subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-swift-version",
            "6",
            "-I",
            str(first / "bridge"),
            str(first / "Resources.swift"),
            *(str(MODULE / "Swift" / f"{name}.swift") for name in sources),
            str(MODULE / "Tools/Validation/FederatedDiscovery.swift"),
            str(first / "bridge.o"),
            "-lsqlite3",
            "-o",
            str(executable),
        ],
        check=True,
    )
    run = scratch / "check"
    subprocess.run(
        [
            str(executable),
            str(first / "catalog.sqlite"),
            str(args.second.resolve() / "catalog.sqlite"),
            str(run),
            str(args.package.resolve()),
        ],
        env={
            **os.environ,
            "RAWMASTER_DISCOVERY_TEST_BUNDLE": str(first / "Smoke.bundle"),
        },
        check=True,
        timeout=180,
    )
    report = json.loads((run / "metrics.json").read_text())
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
