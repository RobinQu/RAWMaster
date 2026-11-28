#!/usr/bin/env python3
"""Recompute stock LightFlow's screen timings from captured RGB frames and input markers."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tempfile
import zipfile

from canvas_latency import NATIVE_ROI_PROTOCOL, NATIVE_ROI_SCOPE, POLICY, load_frames, native_roi_geometry, score, warmup_states


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def exposure_focus(event, label):
    return event.get("focus") == {"slider": "base.exposure", "label": label, "prepared": str(event["value"])}


def verify_native_screenshots(archive, name, row, capture, geometry):
    from PIL import Image, ImageStat

    snapshots = row.get("nativeScreenshots", [])
    if len(snapshots) != 2:
        raise ValueError(f"Missing two full 1:1 screenshot witnesses for {name}")
    for state, witness in enumerate(snapshots):
        file = f"{name}-1to1-{state}.png"
        event = witness["event"]
        raw = archive.read(file)
        if (witness["state"] != state or witness["file"] != file or hashlib.sha256(raw).hexdigest() != witness["sha256"]
                or event["accepted"] is not True or event["value"] != row["values"][state]
                or abs(event["actual"] - event["value"]) >= 1e-4 or not exposure_focus(event, row["displayLabel"])
                or native_roi_geometry(witness["viewport"], capture["window"], geometry["sourceROIPixels"]) != geometry):
            raise ValueError(f"Native screenshot source or control witness differs for {name}")
        with Image.open(io.BytesIO(raw)) as image:
            if (image.format != "PNG" or list(image.size) != geometry["sourceROIPixels"][2:]
                    or list(image.size) != witness["pixels"] or image.mode != "RGB"
                    or hashlib.sha256(image.tobytes()).hexdigest() != witness["rgbSHA256"]
                    or ImageStat.Stat(image.convert("L")).mean[0] != witness["meanLuma"]):
                raise ValueError(f"Native screenshot pixels differ for {name}")
    if snapshots[0]["rgbSHA256"] == snapshots[1]["rgbSHA256"] or snapshots[0]["meanLuma"] >= snapshots[1]["meanLuma"]:
        raise ValueError(f"Native ROI screenshots do not witness brighter Exposure B pixels for {name}")


def replay(path, raw_digest):
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory() as scratch:
        capture = json.loads(archive.read("observations.json"))
        host = json.loads(archive.read("collection.json"))
        samples = host["measuredInputs"]
        warmup_count = host.get("warmupInputs", 0)
        if (capture["application"] != "LightFlow" or capture["protocol"] not in ("screen-photo-response-v1", NATIVE_ROI_PROTOCOL)
                or capture["policy"] != POLICY or capture["sourceSHA256"] != raw_digest
                or capture["sourceSHA256After"] != raw_digest or not capture["finishedAt"]
                or type(samples) is not int or samples < 2 or capture.get("requestedWarmSamples", samples) != samples
                or type(warmup_count) is not int or warmup_count < 0
                or capture.get("requestedWarmupInputs", warmup_count) != warmup_count
                or capture.get("recorderSHA256", host["recorderSHA256"]) != host["recorderSHA256"]
                or host["electron"]["id"] != capture["window"]["id"]
                or host["browserBinarySHA256"] != capture["browserBinarySHA256"]
                or host["windowBundle"] != capture["windowBundle"]):
            raise ValueError(f"Screen session identities differ in {path.name}")
        native = capture["protocol"] == NATIVE_ROI_PROTOCOL
        if native:
            geometry = capture["nativeROI"]
            try:
                projected = native_roi_geometry(capture["viewport"], capture["window"], geometry["sourceROIPixels"])
            except ValueError as error:
                raise ValueError(f"Native source rectangle or geometry differs in {path.name}: {error}") from error
            if (set(capture["operations"]) != {"light-exposure"} or capture["roi"] != geometry["sampleROINormalized"]
                    or projected != geometry):
                raise ValueError(f"Native source rectangle or geometry differs in {path.name}")
        rows = {}
        files = set(archive.namelist())
        for name, row in capture["operations"].items():
            if (name + ".json" not in files and name + ".bin" not in files
                    and row["status"] == "inconclusive" and row.get("reason") and not row.get("trials")):
                rows[name] = dict(row, archive=path.name)
                continue
            markers = json.loads(archive.read(name + ".json"))
            frame_data = archive.read(name + ".bin")
            file = Path(scratch) / "frames.bin"
            file.write_bytes(frame_data)
            events = markers["events"]
            warmup = markers.get("warmup", [])
            if (len(events) != samples + 2 or len(row["values"]) != 2
                    or len(warmup) != warmup_count or warmup != row.get("warmup", [])
                    or (not native and capture["photoRectPixels"][2:] != [2368, 1579])
                    or capture["viewport"]["frame"]["fullRes"] is not True
                    or any(event["state"] != state or event["value"] != row["values"][state]
                           for event, state in zip(warmup + events, warmup_states(warmup_count) + [i % 2 for i in range(len(events))]))
                    or any(event["accepted"] != (event["actual"] is not None
                                                 and abs(event["actual"] - event["value"]) < 1e-4)
                           for event in warmup + events)):
                raise ValueError(f"Input, viewport or full control series missing for {name}")
            if native and (row["scope"] != NATIVE_ROI_SCOPE or row["values"] != [0, .5]
                           or not all(exposure_focus(event, row["displayLabel"]) for event in warmup + events)):
                raise ValueError(f"Native ROI inputs did not use the visible Exposure field for {name}")
            scored = score(load_frames(file), events, markers["endNs"])
            if not all(event["accepted"] for event in warmup):
                scored.update(status="inconclusive", reason="An unscored warmup did not commit its requested value")
            if native and not all(event["accepted"] for event in events[:2]):
                scored.update(status="inconclusive", reason="A native ROI calibration input did not commit its requested value")
            if (any(scored[key] != row[key] for key in scored) or events[:2] != row["calibration"]
                    or (not native and not all(event["accepted"] for event in events[:2]))):
                raise ValueError(f"Captured input or reproduced pixel result differs for {name}")
            if native and row["status"] == "measured":
                verify_native_screenshots(archive, name, row, capture, geometry)
            rows[name] = dict(row, archive=path.name, framesSHA256=hashlib.sha256(frame_data).hexdigest())
        return dict(capture, operations=rows), dict(host, archive=path.name, archiveSHA256=digest(path))


def merge(paths, raw):
    raw_digest = digest(raw)
    result = None
    for path in paths:
        capture, host = replay(path, raw_digest)
        if result is None:
            result = {**capture, "operations": {}, "sessions": []}
            # Individual sessions can have distinct warmup and trial counts.
            result.pop("requestedWarmSamples", None)
            result.pop("requestedWarmupInputs", None)
        for field in ("protocol", "sourceSHA256", "browserBinarySHA256", "hardware", "os", "osBuild", "build", "photoRectPixels",
                      "nativeROI", "roi", "policy", "recorderSHA256"):
            if result.get(field) != capture.get(field):
                raise ValueError(f"Screen sessions differ on {field}")
        required_assets = [name for name in result["uiSHA256"] if name.endswith((".wasm", ".js"))]
        if any(capture["uiSHA256"].get(name) != result["uiSHA256"][name] for name in required_assets):
            raise ValueError("The editor, worker or pixel engine changed between screen captures")
        result["finishedAt"] = capture["finishedAt"]
        result["sessions"].append({**host, "startedAt":capture["startedAt"], "finishedAt":capture["finishedAt"],
                                   "outcomes":{key:row["status"] for key,row in capture["operations"].items()}})
        for name, row in capture["operations"].items():
            prior = result["operations"].get(name)
            if prior and "values" in prior and "values" in row and prior["values"] != row["values"]:
                raise ValueError(f"Control inputs differ for {name}")
            if not prior or (row["status"] == "measured" and (prior["status"] != "measured"
                    or len(row["trials"]) > len(prior["trials"]))):
                result["operations"][name] = row
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", type=Path, nargs="+")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = merge(args.archives, args.source)
    args.output.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")
    print({key:row["status"] for key,row in data["operations"].items()})
