#!/usr/bin/env python3
"""Measure the frozen 60 MP 032 renditions and shared scene component in Release."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess


ROOT = Path(__file__).resolve().parents[2]
CASES = (
    "testOptIn60MPPhotographicPublishedBatchReceipts",
    "testOptInPhotographic60MPFrozenGraphPublishesPQTogetherWithTheEditedSDRDerivative",
)
FORMATS = ("avif10", "jpeg8")


def sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def read_command(*arguments):
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def timing(values):
    values = sorted(value / 1e6 for value in values)
    return {
        "n": len(values),
        "p50Ms": statistics.median(values),
        "p95Ms": values[math.ceil(len(values) * 0.95) - 1],
    }


def summarize(paths, warmups, sample_count, backend, assembly):
    samples = sorted((json.loads(path.read_bytes()) for path in paths), key=lambda record: record["startedUptimeNS"])
    if len(samples) != 1 + warmups + sample_count or any(record["outcome"] != "succeeded" for record in samples):
        raise ValueError("A cold sample, all warmups and all successful measured deliveries are required for each route")
    measured = samples[1 + warmups :]
    result = {
        "firstRunWallMs": samples[0]["elapsedWallNS"] / 1e6,
        "elapsedWall": timing(record["elapsedWallNS"] for record in measured),
        "targets": {},
    }
    for target in sorted({key for record in measured for key in record["targets"]}):
        records = [record["targets"][target] for record in measured if target in record["targets"]]
        stages = {}
        for stage in sorted({key for record in records for key in record["stages"]}):
            observations = [record["stages"][stage] for record in records if stage in record["stages"]]
            valid = [entry["totalNS"] for entry in observations if entry["samples"] > 0]
            stages[stage] = {
                "observedRuns": len(observations),
                "stageSamples": sum(entry["samples"] for entry in observations),
                "unavailableSamples": sum(entry["unavailableSamples"] for entry in observations),
            }
            if valid:
                stages[stage]["perRunTotals"] = timing(valid)
        graph = [record["graph"] for record in records if "graph" in record]
        if target != "shared" and (len(graph) != sample_count or any(
            item.get("dagBackend") != backend or item["dispatches"] < 3 for item in graph
        )):
            raise ValueError(f"Missing the actual photographic {backend} DAG receipt for {target}")
        if target != "shared":
            for record, receipt in zip(records, graph, strict=True):
                observed = record["stages"]
                drt_waits = observed.get("drt.host_wait", {}).get("samples", 0)
                blit_waits = observed.get("assembly.blit.host_wait", {}).get("samples", 0)
                tiles = receipt["tiles"]
                if drt_waits != tiles or blit_waits != (tiles if assembly == "blit" else 0):
                    raise ValueError(f"Unexpected DRT or assembly submit count for {target} in {assembly} mode")
        transport = [record.get("wgpu") for record in records] if backend == "wgpu" and target != "shared" else []
        if transport and any(
            receipt is None or receipt["graphicsAPI"] != "metal"
            or receipt["textureTransport"] != "same-device-native" or receipt["frameCopyBytes"] != 0
            or receipt["submissions"] != item["dispatches"] or receipt["hostWaits"] != item["dispatches"]
            or receipt["validationBytes"] != 4 * item["dispatches"]
            for item, receipt in zip(graph, transport, strict=True)
        ):
            raise ValueError(f"Incomplete or unexpected wgpu texture transport for {target}")
        memory = {}
        for record in records:
            for key, value in record["memory"].items():
                memory[key] = max(memory.get(key, 0), value)
        target_summary = {"stages": stages, "exampleGraphReceipt": next(iter(graph), None), "memoryMaxima": memory}
        if transport:
            target_summary["exampleWGPUTransport"] = transport[0]
        result["targets"][target] = target_summary
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--flashraw-library", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--backend", choices=("rust", "wgpu"), default="rust")
    parser.add_argument("--drt-assembly", choices=("blit", "direct"), default="blit")
    parser.add_argument("--retain-component-evidence", action="store_true",
                        help="Keep component receipts and renditions outside the measured export interval")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--samples", type=int, default=30)
    args = parser.parse_args()
    repeats = 1 + args.warmup + args.samples
    if args.warmup < 0 or args.samples < 1 or repeats > 64:
        parser.error("Provide 1 to 64 total runs including the first run and warmups")
    raw, flashraw, output, scratch = (
        path.resolve() for path in (args.raw, args.flashraw_library, args.output, args.scratch_path)
    )
    if not raw.is_file() or not flashraw.is_file() or output.exists():
        parser.error("Provide an existing fixture and FlashRaw library and a new output directory")
    commit = read_command("git", "rev-parse", "HEAD")
    changes = read_command("git", "status", "--porcelain").splitlines()
    source_sha = sha256(raw)
    flashraw_sha = sha256(flashraw)
    output.mkdir(parents=True)
    traces = output / "traces"
    traces.mkdir()
    environment = dict(
        os.environ,
        RAWMASTER_SCENE_60MP_ARW=str(raw),
        RAWMASTER_FLASHRAW_LIBRARY=str(flashraw),
        RAWMASTER_SCENE_BACKEND=args.backend,
        RAWMASTER_SCENE_DIRECT_DRT="1" if args.drt_assembly == "direct" else "0",
        RAWMASTER_EDITOR_ACCEPTANCE_DIR=str(output / "queue"),
        RAWMASTER_SCENE_DELIVERY_TRACE_DIR=str(traces),
        RAWMASTER_SCENE_DELIVERY_PROFILE_REPEATS=str(repeats),
    )
    environment.pop("RAWMASTER_SCENE_DELIVERY_EVIDENCE", None)
    if args.retain_component_evidence:
        component = output / "component"
        component.mkdir()
        environment["RAWMASTER_SCENE_DELIVERY_EVIDENCE"] = str(component)
    command = ["swift", "test", "--scratch-path", str(scratch), "-c", "release", "--jobs", "4", "-Xswiftc", "-enable-testing"]
    if args.skip_build:
        command.append("--skip-build")
    command.extend(["--filter", "|".join(CASES)])
    print(f"Writing Release test output and delivery traces to {output}", flush=True)
    with (output / "native-tests.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    if sha256(raw) != source_sha or sha256(flashraw) != flashraw_sha:
        raise ValueError("The fixture or FlashRaw library changed during the run")
    routes = {"component": [], **{f"032-{format}": [] for format in FORMATS}}
    for path in traces.glob("scene-delivery-*.json"):
        record = json.loads(path.read_bytes())
        if record["sourceSHA256"] != source_sha:
            raise ValueError("The delivery source differs from the declared fixture")
        route, formats = record["route"], record["formats"]
        if route == "sceneComponent" and formats == list(FORMATS):
            routes["component"].append(path)
        elif route == "workbench032" and len(formats) == 1 and formats[0] in FORMATS:
            routes[f"032-{formats[0]}"].append(path)
        else:
            raise ValueError(f"Unexpected delivery trace {path.name}")
    products = Path(read_command("swift", "build", "--scratch-path", str(scratch), "-c", "release", "--show-bin-path"))
    test_bundles = {}
    for name in ("RAWMasterUITests", "RAWMasterImagingTests"):
        executable = products / f"{name}.xctest" / "Contents" / "MacOS" / name
        test_bundles[name] = sha256(executable)
    checkpoints = json.loads((output / "queue/photographic/memory-checkpoints.json").read_bytes())
    if len(checkpoints) != repeats + 2:
        raise ValueError("Expected memory samples before the delivery sweep, between pairs and after closing the library owners")
    report = {
        "schemaVersion": 1,
        "sourceSHA256": source_sha,
        "flashRawLibrarySHA256": flashraw_sha,
        "hardware": read_command("sysctl", "-n", "hw.model"),
        "os": read_command("sw_vers", "-productVersion"),
        "osBuild": read_command("sw_vers", "-buildVersion"),
        "sourceCommitAtStart": commit,
        "worktreeChangesAtStart": changes,
        "testBundleSHA256": test_bundles,
        "configuration": f"Swift Release with testability, {args.backend} scene, 9504×6336 Bayer fixture",
        "drtAssembly": args.drt_assembly,
        "warmups": args.warmup,
        "measuredSamplesPerRoute": args.samples,
        "firstRunBoundary": "first delivery of this route in the test process with system file caches intact",
        "stageTotals": "nested CPU wall, host waits and GPU intervals overlap; timings are per-run stage sums",
        "memory": "sampled process/device and logical graph accounting, each reported independently",
        "workbenchMemoryOutsideTimedRegions": {
            "beforeSweep": checkpoints[0],
            "afterEachTargetPair": checkpoints[1:-1],
            "afterClosingLibraryOwners": checkpoints[-1],
        },
        "routes": {route: summarize(paths, args.warmup, args.samples, args.backend, args.drt_assembly)
                   for route, paths in routes.items()},
    }
    (output / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(output / "summary.json")


if __name__ == "__main__":
    main()
