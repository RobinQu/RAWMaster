#!/usr/bin/env python3
"""Exercise a cold macOS Swift host, real SQLite ABI, CPU package and offline preview."""

import argparse
import json
from pathlib import Path
import os
import shutil
import sqlite3
import subprocess

BASE = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--package", type=Path, required=True, help="standalone LibraryDiscovery pack"
    )
    ap.add_argument(
        "--library",
        type=Path,
        required=True,
        help="compiled librawmaster_library.dylib",
    )
    ap.add_argument(
        "--scratch",
        type=Path,
        required=True,
        help="new private local directory; files are copied here",
    )
    ap.add_argument("--query", required=True)
    ap.add_argument(
        "--images",
        nargs="+",
        type=Path,
        required=True,
        help="positive image first, then controls; original formats accepted",
    )
    ap.add_argument(
        "--output", type=Path, required=True, help="only aggregate metrics are exported"
    )
    args = ap.parse_args()
    scratch = args.scratch.absolute()
    scratch.mkdir(mode=0o700, parents=True, exist_ok=False)
    bridge = scratch / "bridge"
    bridge.mkdir()
    shutil.copyfile(BASE / "Bridge/include/LibraryLoader.h", bridge / "LibraryLoader.h")
    (bridge / "module.modulemap").write_text(
        'module CLibraryCatalogABI {header "LibraryLoader.h" export *}\n'
    )
    bundle = scratch / "Smoke.bundle"
    bundle.mkdir()
    shutil.copytree(
        BASE / "Swift/Resources/discovery",
        bundle / "discovery",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    shutil.copy2(args.library, bundle / "rawmaster-library.runtime")
    resource = scratch / "Resources.swift"
    resource.write_text(
        'import Foundation\nextension Bundle { static let module = Bundle(path: ProcessInfo.processInfo.environment["RAWMASTER_DISCOVERY_TEST_BUNDLE"]!)! }\n'
    )
    obj = scratch / "bridge.o"
    subprocess.run(
        [
            "clang",
            "-c",
            "-I",
            str(BASE / "Bridge/include"),
            str(BASE / "Bridge/LibraryLoader.c"),
            "-o",
            str(obj),
        ],
        check=True,
    )
    swift = [
        BASE / "Swift" / name
        for name in [
            "CatalogJSON.swift",
            "LibraryEngine.swift",
            "CatalogActions.swift",
            "LibraryDiscoveryWorker.swift",
        ]
    ]
    executable = scratch / "smoke"
    subprocess.run(
        [
            "swiftc",
            "-swift-version",
            "6",
            "-I",
            str(bridge),
            str(resource),
            *map(str, swift),
            str(BASE / "Tools/Validation/NativeDiscovery.swift"),
            str(obj),
            "-lsqlite3",
            "-o",
            str(executable),
        ],
        check=True,
    )
    db = sqlite3.connect(scratch / "catalog.sqlite")
    db.executescript((BASE / "src/authority/legacy_v7_reference.sql").read_text())
    db.execute("PRAGMA user_version=8")
    db.close()
    env = {
        **os.environ,
        "RAWMASTER_DISCOVERY_TEST_QUERY": args.query,
        "RAWMASTER_DISCOVERY_TEST_BUNDLE": str(bundle),
    }
    subprocess.run(
        [
            str(executable),
            str(scratch),
            str(args.package.resolve()),
            *[str(p.resolve()) for p in args.images],
        ],
        env=env,
        check=True,
        timeout=300,
    )
    metrics = json.loads((scratch / "metrics.json").read_text())
    metrics["host"] = "macOS arm64, CPUExecutionProvider, two inference threads"
    metrics["stages"] = (
        "fresh catalog, admit, claim, verified-source proxy, inference, receipt, Chinese query, filtering, offline proxy"
    )
    args.output.write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
