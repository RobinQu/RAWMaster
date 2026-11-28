#!/usr/bin/env python3
"""Recompute RAWMaster's visible canvas timings from preserved ROI frames and input markers."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import zipfile

from canvas_latency import POLICY, load_frames, score, warmup_states


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def replay(path, raw_digest):
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory() as scratch:
        capture = json.loads(archive.read("observations.json"))
        collection = json.loads(archive.read("collection.json"))
        sample_count, warmup_count = collection["measuredInputs"], collection["warmupInputs"]
        if (capture["protocol"] != "screen-photo-response-v1" or capture["policy"] != POLICY
                or not capture["finishedAt"] or capture["sourceSHA256"] != raw_digest
                or capture["sourceSHA256After"] != raw_digest
                or capture["testBundleSHA256"] != collection["testBundleSHA256"]
                or capture["recorderSHA256"] != collection["recorderSHA256"]
                or type(sample_count) is not int or sample_count < 2 or capture["requestedWarmSamples"] != sample_count
                or type(warmup_count) is not int or warmup_count < 0 or capture["requestedWarmupInputs"] != warmup_count):
            raise ValueError("RAWMaster capture metadata differ from the frame archive")

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
            if any(row[key] != value for key, value in rescored.items()):
                raise ValueError(f"RAWMaster pixel witness differs on replay for {key}")
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
