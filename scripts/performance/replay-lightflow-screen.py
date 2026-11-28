#!/usr/bin/env python3
"""Recompute stock LightFlow's screen timings from captured RGB frames and input markers."""
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
        host = json.loads(archive.read("collection.json"))
        samples = host["measuredInputs"]
        warmup_count = host.get("warmupInputs", 0)
        if (capture["application"] != "LightFlow" or capture["protocol"] != "screen-photo-response-v1"
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
                    or capture["photoRectPixels"][2:] != [2368, 1579]
                    or capture["viewport"]["frame"]["fullRes"] is not True
                    or any(event["state"] != state or event["value"] != row["values"][state]
                           for event, state in zip(warmup + events, warmup_states(warmup_count) + [i % 2 for i in range(len(events))]))
                    or any(event["accepted"] != (event["actual"] is not None
                                                 and abs(event["actual"] - event["value"]) < 1e-4)
                           for event in warmup + events)):
                raise ValueError(f"Input, viewport or full control series missing for {name}")
            scored = score(load_frames(file), events, markers["endNs"])
            if not all(event["accepted"] for event in warmup):
                scored.update(status="inconclusive", reason="An unscored warmup did not commit its requested value")
            if (any(scored[key] != row[key] for key in scored) or events[:2] != row["calibration"]
                    or not all(event["accepted"] for event in events[:2])):
                raise ValueError(f"Captured input or reproduced pixel result differs for {name}")
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
        for field in ("sourceSHA256", "browserBinarySHA256", "hardware", "os", "osBuild", "build", "photoRectPixels", "roi", "policy",
                      "recorderSHA256"):
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
