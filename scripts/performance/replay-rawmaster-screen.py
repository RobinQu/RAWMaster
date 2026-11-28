#!/usr/bin/env python3
"""Recompute RAWMaster's visible canvas timings from preserved ROI frames and input markers."""
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import tempfile
import zipfile

from canvas_latency import NATIVE_ROI_PROTOCOL, NATIVE_ROI_SCOPE, POLICY, load_frames, score, warmup_states


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_native_geometry(capture):
    geometry = capture["nativeROI"]
    source = geometry["sourceROIPixels"]
    rect = geometry["roiWindowRectPixels"]
    full = capture["photoRectPixels"]
    window = capture["window"]
    if any(not isinstance(values, list) or len(values) != 4 or any(type(v) is not int for v in values)
           for values in (source, rect, full)):
        raise ValueError("Expected integer source, window and full-photo rectangles")
    x, y, width, height = source
    source_w, source_h = capture["sourcePixels"]
    if (capture["approximate"] is not False or [source_w, source_h] != [9504, 6336]
            or full[2:] != [source_w, source_h] or geometry["backingPixelsPerSourcePixel"] != [1, 1]
            or min(x, y) < 0 or min(width, height) <= 0 or x + width > source_w or y + height > source_h
            or (2 * x + width == source_w and 2 * y + height == source_h)
            or rect != [full[0] + x, full[1] + y, width, height]):
        raise ValueError("RAWMaster source ROI does not match the reported noncentral native photo projection")
    required = ("photoWindowRectPixelsFloat", "roiWindowRectPixelsFloat", "detailWindowNormalized",
                "detailPixelSize", "visibleSourceWindowNormalized")
    if any(key not in geometry for key in required):
        raise ValueError("Independent RAWMaster native projection and served bitmap metadata are required")
    photo_float, roi_float = (geometry[key] for key in required[:2])
    if any(not isinstance(values, list) or len(values) != 4
           or any(type(v) not in (int, float) or not math.isfinite(v) for v in values)
           for values in (photo_float, roi_float)):
        raise ValueError("Expected finite unrounded RAWMaster window rectangles")
    projected = [photo_float[0] + x * photo_float[2] / source_w, photo_float[1] + y * photo_float[3] / source_h,
                 width * photo_float[2] / source_w, height * photo_float[3] / source_h]
    if (any(abs(value - integer) > .01 for value, integer in zip(photo_float, full))
            or any(abs(value - integer) > .01 for value, integer in zip(roi_float, rect))
            or any(abs(a - b) > .01 for a, b in zip(projected, roi_float))):
        raise ValueError("RAWMaster source, window projection or backing-pixel phase differs")

    served = geometry["detailWindowNormalized"]
    if served is None:
        detail = [0, 0, source_w, source_h]
    else:
        if (not isinstance(served, list) or len(served) != 4
                or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 or v > 1 for v in served)):
            raise ValueError("Invalid normalized RAWMaster served detail window")
        pixels = [value * size for value, size in zip(served, [source_w, source_h] * 2)]
        detail = [round(value) for value in pixels]
        if any(abs(value - integer) > .01 for value, integer in zip(pixels, detail)):
            raise ValueError("RAWMaster served bitmap does not align to the source pixel grid")
    dx, dy, dw, dh = detail
    if (min(dw, dh) <= 0 or dx + dw > source_w or dy + dh > source_h or x < dx or y < dy
            or x + width > dx + dw or y + height > dy + dh or geometry["detailPixelSize"] != [dw, dh]
            or capture["previewPixels"] != [dw, dh]):
        raise ValueError("RAWMaster served bitmap differs from the exact backing ROI")
    visible = geometry["visibleSourceWindowNormalized"]
    if (not isinstance(visible, list) or len(visible) != 4
            or any(type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1 for value in visible)):
        raise ValueError("Invalid RAWMaster visible source window")
    vx, vy, vw, vh = [value * size for value, size in zip(visible, [source_w, source_h] * 2)]
    if (not dx - .01 <= vx <= x + .01 or not dy - .01 <= vy <= y + .01
            or not x + width - .01 <= vx + vw <= dx + dw + .01
            or not y + height - .01 <= vy + vh <= dy + dh + .01):
        raise ValueError("RAWMaster detail bitmap does not cover the complete visible window and capture ROI")

    window_w, window_h = [round(v * window["scale"]) for v in window["frame"][2:]]
    px, py = rect[:2]
    if (geometry["windowBackingPixels"] != [window_w, window_h] or min(px, py) < 0
            or px + width > window_w or py + height > window_h):
        raise ValueError("RAWMaster source ROI exceeds the captured window backing pixels")
    sample = [(px + width * .2) / window_w, (py + height * .2) / window_h,
              width * .6 / window_w, height * .6 / window_h]
    if geometry["sampleROINormalized"] != sample or capture["roi"] != sample:
        raise ValueError("RAWMaster capture does not sample the central 60% of the exact source ROI")
    return geometry


def exposure_commit(event, expected):
    actual = event["actual"]
    return (event["accepted"] is True and type(actual) in (int, float) and math.isclose(actual, expected, abs_tol=1e-5))


def verify_native_screenshots(archive, key, row, geometry, end_ns):
    from PIL import Image, ImageStat

    snapshots = row.get("nativeScreenshots", [])
    if len(snapshots) != 2:
        raise ValueError("RAWMaster native ROI report needs two full-resolution screenshots")
    last = end_ns
    for state, shot in enumerate(snapshots):
        file = f"{key}-1to1-{state}.png"
        value = row["values"][state]
        event = shot["event"]
        raw = archive.read(file)
        if (shot["file"] != file or shot["state"] != state or shot["value"] != value
                or hashlib.sha256(raw).hexdigest() != shot["sha256"] or not exposure_commit(event, value)
                or type(event["sentNs"]) is not int or event["sentNs"] <= last
                or event["recipeFingerprint"] != row["calibration"][state]["recipeFingerprint"]):
            raise ValueError(f"RAWMaster native screenshot file or recipe witness differs for state {state}")
        last = event["sentNs"]
        with Image.open(io.BytesIO(raw)) as image:
            if (image.format != "PNG" or list(image.size) != geometry["sourceROIPixels"][2:]
                    or list(image.size) != shot["pixels"] or image.mode != "RGB"
                    or hashlib.sha256(image.tobytes()).hexdigest() != shot["rgbSHA256"]
                    or ImageStat.Stat(image.convert("L")).mean[0] != shot["meanLuma"]):
                raise ValueError(f"RAWMaster native screenshot pixels differ for state {state}")
    if snapshots[0]["rgbSHA256"] == snapshots[1]["rgbSHA256"] or snapshots[0]["meanLuma"] >= snapshots[1]["meanLuma"]:
        raise ValueError("RAWMaster native ROI screenshots did not witness brighter Exposure B pixels")


def replay(path, raw_digest):
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory() as scratch:
        capture = json.loads(archive.read("observations.json"))
        collection = json.loads(archive.read("collection.json"))
        sample_count, warmup_count = collection["measuredInputs"], collection["warmupInputs"]
        if (capture["protocol"] not in ("screen-photo-response-v1", NATIVE_ROI_PROTOCOL) or capture["policy"] != POLICY
                or not capture["finishedAt"] or capture["sourceSHA256"] != raw_digest
                or capture["sourceSHA256After"] != raw_digest
                or capture["testBundleSHA256"] != collection["testBundleSHA256"]
                or capture["recorderSHA256"] != collection["recorderSHA256"]
                or type(sample_count) is not int or sample_count < 2 or capture["requestedWarmSamples"] != sample_count
                or type(warmup_count) is not int or warmup_count < 0 or capture["requestedWarmupInputs"] != warmup_count):
            raise ValueError("RAWMaster capture metadata differ from the frame archive")
        native = capture["protocol"] == NATIVE_ROI_PROTOCOL
        if native:
            geometry = verify_native_geometry(capture)
            if set(capture["operations"]) != {"light-exposure"}:
                raise ValueError("RAWMaster native ROI evidence must contain one Exposure series")

        files = set(archive.namelist())
        rows = {}
        for key, row in capture["operations"].items():
            marker_name, pixel_name = key + ".json", key + ".bin"
            if {marker_name, pixel_name}.isdisjoint(files) and row["status"] == "inconclusive" and not row.get("trials"):
                rows[key] = row
                continue
            markers = json.loads(archive.read(marker_name))
            events, warmup, end = markers["events"], markers["warmup"], markers["endNs"]
            if (len(events) != sample_count + 2 or events[:2] != row["calibration"]
                    or warmup != row.get("warmup", []) or [event["state"] for event in warmup] != warmup_states(warmup_count)
                    or any(event["state"] != i % 2 for i, event in enumerate(events))):
                raise ValueError(f"RAWMaster input markers differ for {key}")

            inputs = warmup + events
            if native:
                stamps = [event["sentNs"] for event in inputs] + [end]
                if (any(type(stamp) is not int or stamp <= 0 for stamp in stamps)
                        or any(a >= b for a, b in zip(stamps, stamps[1:]))):
                    raise ValueError("RAWMaster native warmup, calibration and trial markers are not ordered")
            if (not row["precondition"]["accepted"] or not all(event["accepted"] for event in warmup + events[:2])
                    or any(event["recipeFingerprint"] != events[event["state"]]["recipeFingerprint"] for event in inputs)):
                if row["status"] != "inconclusive" or row["trials"] or row["inputEvents"] != events:
                    raise ValueError(f"RAWMaster recipe witnesses differ for {key}")
                rows[key] = row
                continue

            pixels = archive.read(pixel_name)
            roi = Path(scratch) / "frames.bin"
            roi.write_bytes(pixels)
            rescored = score(load_frames(roi), events, end)
            if any(row[field] != value for field, value in rescored.items()):
                raise ValueError(f"RAWMaster pixel witness differs on replay for {key}")
            if native and row["status"] == "measured":
                if (row["scope"] != NATIVE_ROI_SCOPE or row["values"] != [0, .5]
                        or not all(exposure_commit(event, row["values"][event["state"]]) for event in inputs)
                        or events[0]["recipeFingerprint"] == events[1]["recipeFingerprint"]):
                    raise ValueError("RAWMaster native Exposure field or recipe witnesses differ")
                verify_native_screenshots(archive, key, row, geometry, end)
            rows[key] = dict(row, framesSHA256=hashlib.sha256(pixels).hexdigest(), scoreEndNs=end)
    return dict(capture, operations=rows, archiveSHA256=digest(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = replay(args.archive, digest(args.source))
    with args.output.open("x") as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write("\n")
    print({key:row["status"] for key,row in result["operations"].items()})


if __name__ == "__main__":
    main()
