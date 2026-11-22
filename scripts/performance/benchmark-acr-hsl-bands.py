#!/usr/bin/env python3
"""Measure individual Adobe HSL settings on one original Sony RAW without opening the Camera Raw interface."""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import zipfile

from hsl_band_witness import (
    BLUE,
    SHA,
    ZERO,
    document_mixer,
    read_initial_grids,
    schedule,
    supplied,
    summarize,
    verify_report,
)

HERE = Path(__file__).resolve().parent
ARCHIVE = "camera-raw-hsl-bands-xmp.zip"
EVIDENCE = "camera-raw-hsl-bands.json"
PLUGIN = Path(
    "/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin/Contents/Info.plist"
)


def module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


raw_open = module("benchmark-camera-raw")
reference = module("adobe-enhance-reference")


def now():
    return datetime.now(timezone.utc).isoformat()


def capture(source, directory, historical, resume, retain_initial, stop_file):
    if raw_open.digest(source) != SHA:
        raise ValueError("Expected the measured Sony 60 MP ARW")
    running = subprocess.check_output(
        ["osascript", "-e", 'application id "com.adobe.Photoshop" is running'], text=True
    ).strip()
    if running != "true":
        raise ValueError("Requires a running Photoshop instance for silent document opens")
    prior = json.loads(historical.read_text())
    if prior["sourceSHA256"] != SHA or prior["finishedAt"] is None:
        raise ValueError("Original blue HSL evidence is incomplete")
    front = reference.foreground()
    evidence = directory / EVIDENCE
    raw = directory / "test.arw"
    steps = schedule()
    same_host = {
        "sourceSHA256": SHA,
        "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
        "cameraRaw": plistlib.loads(PLUGIN.read_bytes())["CFBundleShortVersionString"],
        "os": platform.mac_ver()[0],
    }
    for key, value in same_host.items():
        if prior[key] != value:
            raise ValueError("Original blue recordings use different " + key)
    history = {
        "file": historical.name,
        "sha256": raw_open.digest(historical),
        "startedAt": prior["startedAt"],
        "finishedAt": prior["finishedAt"],
    }
    if resume:
        report = json.loads(evidence.read_text())
        if (
            report.get("finishedAt")
            or any(report[k] != v for k, v in same_host.items())
            or report["historicalSource"] != history
            or [(s["round"], s["field"]) for s in report["samples"]] != steps[: len(report["samples"])]
        ):
            raise ValueError("The checkpoint has finished or has incompatible source or schedule")
    else:
        if directory.exists():
            raise ValueError("Use a fresh output directory or an existing interrupted --resume run")
        directory.mkdir(parents=True)
        shutil.copyfile(source, raw)
        report = {
            "schemaVersion": 1,
            "protocol": "acr-independent-hsl-native-v1",
            "startedAt": now(),
            **same_host,
            "historicalSource": history,
            "boundary": "CameraRAWOpenOptions.SELECTEDIMAGE app.open until a native 9504×6336 8-bit sRGB Photoshop document returns. Document histograms, native BMP, returned XMP and file I/O are outside the timer.",
            "method": "Four rounds with a shared fully neutral document per round. Every edit independently reopens the original sensor file with one parameter at +40. All 24 returned HSL values and all 180,652,032 native RGB8 bytes are verified. The first new edit per field is separate from its three repeated opens. Blue is rechecked once here; its durations come from the previous four A/B pairs.",
            "foregroundUnchanged": True,
            "sessions": [],
            "samples": [],
        }
    if raw_open.digest(raw) != SHA:
        raise ValueError("The working RAW copy is incorrect")
    report["sessions"].append({"startedAt": now(), "firstIndex": len(report["samples"])})
    script = (HERE / "camera-raw-open.jsx").read_text()
    for index in range(len(report["samples"]), len(steps)):
        if reference.foreground() != front:
            raise ValueError("Foreground application changed between background document opens")
        if stop_file and stop_file.exists():
            report["sessions"][-1]["checkpointAt"] = now()
            reference.write(evidence, report)
            print("Checkpoint after", len(report["samples"]), "of", len(steps), "documents")
            return
        iteration, field = steps[index]
        item = f"{index:02d}-{field}"
        sidecar = raw.with_suffix(".xmp")
        saved_input = directory / (item + ".input.xmp")
        returned = directory / (item + ".returned.xmp")
        raw_open.write_sidecar(sidecar, supplied(field))
        shutil.copyfile(sidecar, saved_input)
        sample = raw_open.open_document(
            script, raw, spatial=True, native_size=True, returned_metadata=returned
        )
        with returned.open("rb") as stream:
            mixer = document_mixer(stream)
        if not report["samples"]:
            report["photoshop"] = sample["photoshop"]
        observation = {
            **sample,
            "index": index,
            "round": iteration,
            "field": field,
            "returnedHSL": mixer,
            "phase": (
                "shared-neutral"
                if field == ZERO
                else "verify-earlier-blue"
                if field in BLUE
                else "first"
                if not iteration
                else "warm"
            ),
            "inputXMP": saved_input.name,
            "inputXMPSHA256": raw_open.digest(saved_input),
            "returnedXMP": returned.name,
            "returnedXMPSHA256": raw_open.digest(returned),
        }
        if retain_initial and iteration == 0:
            native = directory / (field + ".bmp")
            (directory / "witness.bmp").replace(native)
            observation["localNativeRaster"] = native.name
        report["samples"].append(observation)
        reference.write(evidence, report)
        if field == ZERO or (index + 1) % 10 == 0:
            print(f"{index + 1}/{len(steps)} native documents; {field}", flush=True)
    report["foregroundUnchanged"] = front == reference.foreground()
    report["sourceSHA256After"], report["workCopySHA256After"] = raw_open.digest(source), raw_open.digest(raw)
    if retain_initial:
        report["nativeGrids"] = read_initial_grids(directory)
    report["rows"] = summarize(report, prior)
    report["sessions"][-1]["finishedAt"] = report["finishedAt"] = now()
    archive = directory / ARCHIVE
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for s in report["samples"]:
            for key in ("inputXMP", "returnedXMP"):
                z.write(directory / s[key], arcname=s[key])
    report["metadataArchive"] = {
        "file": archive.name,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
    }
    reference.write(evidence, report)
    rows = verify_report(report, archive, historical)
    print(f"{sum(r['state'] == 'measured' for r in rows)}/{len(rows)} HSL controls qualified in {evidence}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument(
        "--historical",
        type=Path,
        default=HERE.parents[1] / "docs/research/camera-raw-parity/evidence/camera-raw-open.json",
    )
    parser.add_argument("--resume", action="store_true")
    parser.add_argument(
        "--retain-initial-native",
        action="store_true",
        help="Keep the first native BMP of each independent input in the local evidence directory (4.52 GB)",
    )
    parser.add_argument("--stop-file", type=Path)
    args = parser.parse_args()
    try:
        capture(
            args.source.resolve(),
            args.output_directory.resolve(),
            args.historical.resolve(),
            args.resume,
            args.retain_initial_native,
            args.stop_file,
        )
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")
