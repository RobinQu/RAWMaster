#!/usr/bin/env python3
"""Verify Camera Raw's EXIF lens Auto against explicitly selected correct and incorrect Adobe profiles."""

import argparse
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import zipfile

from profile_match_witness import (
    CORRECT,
    KEY,
    WRONG,
    compare_rasters,
    returned_profile,
    settings,
    verify_record,
)

HERE = Path(__file__).resolve().parent
PLUGIN = Path("/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin")
PROFILES = Path("/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0/Sony")
TERMS = PLUGIN / "Contents/Resources/zh_cn.lproj/CameraRawStrings.txt"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


raw_open = load_script("benchmark-camera-raw")
reference = load_script("adobe-enhance-reference")


def run(source, output):
    if raw_open.digest(source) != reference.CAMERA:
        raise ValueError("Expected the exact Sony ILCE-7RM5 RAW")
    if output.exists():
        raise ValueError("Use a new evidence directory")
    if (
        subprocess.check_output(
            ["osascript", "-e", 'application id "com.adobe.Photoshop" is running'], text=True
        ).strip()
        != "true"
    ):
        raise ValueError("Requires a previously running Photoshop process")
    ui = TERMS.read_text()
    if not all(
        "CRaw/SettingsPane/LensCorrections/Auto/Setup/Entry/" + mode + "=" in ui
        for mode in ("Auto", "Custom", "LensDefaults")
    ):
        raise ValueError(
            "Cannot confirm the distinct Auto, Custom and LensDefaults modes in this ACR version"
        )
    profiles = {
        lens: raw_open.digest(PROFILES / settings(label)["LensProfileFilename"])
        for label, lens in [("wrong", WRONG), ("correct", CORRECT)]
    }
    front = reference.foreground()
    output.mkdir(parents=True)
    raw = output / "test.arw"
    shutil.copyfile(source, raw)
    if raw_open.digest(raw) != reference.CAMERA:
        raise ValueError("Input copy has the wrong SHA-256")
    xmp = raw.with_suffix(".xmp")
    script = (HERE / "camera-raw-open.jsx").read_text()
    evidence = output / "camera-raw-profile-match.json"
    entries, anchors = [], []
    row = {
        "settings": {"control": settings("wrong"), "edit": settings("auto")},
        "samples": entries,
        "status": "inconclusive",
    }
    report = {
        "schemaVersion": 1,
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "sourceSHA256": reference.CAMERA,
        "cameraRaw": plistlib.loads((PLUGIN / "Contents/Info.plist").read_bytes())[
            "CFBundleShortVersionString"
        ],
        "os": platform.mac_ver()[0],
        "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
        "protocol": "acr-xmp-document-open-v1",
        "planned": [KEY],
        "repeats": 3,
        "boundary": "CameraRAWOpenOptions SELECTEDIMAGE to Photoshop document return; 8-bit sRGB; native BMP and returned document XMP outside the timer.",
        "spatialWitness": "native-size uncompressed topologically identical BGR24 BMP raster",
        "operations": {KEY: row},
        "manualCorrectSettings": settings("correct"),
        "manualCorrectAnchors": anchors,
        "installedLCPFileSHA256": profiles,
        "verification": "Auto request supplies no lens name, filename or digest. Match the exact EXIF lens, returned Auto enum, digest and every image byte to independently forced 14 mm. Distinguish the 20 mm negative control in returned metadata, raster and histograms.",
    }
    sequence = [("correct", -1, "anchor-before")]
    sequence.extend(
        (label, n, state) for n in range(4) for label, state in [("wrong", "control"), ("auto", "edit")]
    )
    sequence.append(("correct", 4, "anchor-after"))
    try:
        for index, (label, iteration, state) in enumerate(sequence):
            if reference.foreground() != front:
                raise ValueError("The foreground changed between background document opens")
            prefix = f"{index:02d}-{label}"
            saved_input, returned = (output / (prefix + suffix) for suffix in (".input.xmp", ".returned.xmp"))
            raw_open.write_sidecar(xmp, settings(label))
            shutil.copyfile(xmp, saved_input)
            sample = raw_open.open_document(
                script, raw, spatial=True, native_size=True, returned_metadata=returned
            )
            result = {
                **sample,
                "iteration": iteration,
                "state": state,
                "returnedLensProfile": returned_profile(returned),
                "inputXMP": saved_input.name,
                "inputXMPSHA256": raw_open.digest(saved_input),
                "returnedXMP": returned.name,
                "returnedXMPSHA256": raw_open.digest(returned),
            }
            (anchors if label == "correct" else entries).append(result)
            bitmap = output / "witness.bmp"
            first = output / (label + ".bmp")
            if not first.exists():
                bitmap.rename(first)
            reference.write(evidence, report)
        row["profileMatchVerification"] = verify_record(entries, anchors)
        row["nativePixelComparison"] = compare_rasters(output)
        row["status"] = "measured"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        row["reason"] = str(error)
    finally:
        report["foregroundUnchanged"] = front == reference.foreground()
        report["sourceSHA256After"], report["workCopySHA256After"] = (
            raw_open.digest(source),
            raw_open.digest(raw),
        )
        if (
            not report["foregroundUnchanged"]
            or report["workCopySHA256After"] != reference.CAMERA
            or report["sourceSHA256After"] != reference.CAMERA
        ):
            row.update(status="inconclusive", reason="Foreground or RAW identity changed")
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        archive = output / "camera-raw-profile-match-xmp.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
            for xml in sorted([*output.glob("*.input.xmp"), *output.glob("*.returned.xmp")]):
                z.write(xml, arcname=xml.name)
        report["metadataArchive"] = {"file": archive.name, "sha256": raw_open.digest(archive)}
        reference.write(evidence, report)
    if row["status"] != "measured":
        raise ValueError(row.get("reason", "Lens Auto could not be confirmed"))
    print(evidence)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args()
    try:
        run(args.source.resolve(), args.output_directory.resolve())
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
