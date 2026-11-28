#!/usr/bin/env python3
"""Re-score recorded Camera Raw screen pixels and the committed value on the following edit."""
import argparse
import hashlib
import json
import tempfile
import zipfile
from pathlib import Path
from canvas_latency import load_frames, score, warmup_states


def replay(archive, source):
    with zipfile.ZipFile(archive) as z, tempfile.TemporaryDirectory() as workspace:
        original = json.loads(z.read("observations.json"))
        info = json.loads(z.read("collection.json"))
        samples = info.get("measuredInputs", 10)
        warmup_count = info.get("warmupInputs", 0)
        if (type(samples) is not int or samples < 2 or original.get("requestedWarmSamples", samples) != samples
                or type(warmup_count) is not int or warmup_count < 0
                or original.get("requestedWarmupInputs", warmup_count) != warmup_count
                or original.get("recorderSHA256") != info.get("recorderSHA256")):
            raise ValueError("Capture metadata differ from the Adobe frame archive")
        result = {k:v for k,v in original.items() if k!="operations"}
        result["driver"] = "Physical numeric typing and Tab to ScreenCaptureKit witness; committed value read before the following edit"
        result["operations"] = {}
        for key,row in original["operations"].items():
            marker = key + ".json"
            saved = json.loads(z.read(marker)) if marker in z.namelist() else None
            events = saved["events"] if saved else [
                {k:v for k,v in t.items() if k in ("sentNs","state","old","actual","position","size")}
                for t in [*row.get("calibration",[]),*row.get("trials",[])]]
            if len(events) != samples + 2:
                if row["status"] == "measured":
                    raise ValueError(f"Incomplete frame archive for measured operation {key}")
                result["operations"][key] = row
                continue
            warmup = saved.get("warmup", []) if saved else []
            if (len(warmup) != warmup_count or warmup != row.get("warmup", [])
                    or [event["state"] for event in warmup] != warmup_states(warmup_count)):
                raise ValueError(f"Warmup markers differ for {key}")
            inputs = warmup + events
            for i,t in enumerate(inputs):
                # The following event samples AXValue before modifying the field.
                # On the final edit only its original immediate readback is available.
                following = inputs[i+1] if i+1 < len(inputs) else saved["restoration"] if saved else None
                t["valueWitness"] = "before-next-input" if following else "immediate-last-input"
                t["committedValue"] = following["old"] if following else t["actual"]
                t["accepted"] = float(t["committedValue"]) == row["values"][t["state"]]
            pixels = z.read(key+".bin")
            raw = Path(workspace) / "frames.bin"
            raw.write_bytes(pixels)
            end = saved["endNs"] if saved else events[-1]["sentNs"]+round(info["settleSeconds"]*1e9)
            judged = score(load_frames(raw),events,end)
            if judged["referenceDigests"] != row["referenceDigests"]:
                raise ValueError(f"Calibration pixels changed on replay for {key}")
            if not all(e["accepted"] for e in events[:2]):
                judged.update(status="inconclusive",reason="Calibration input differed from requested value")
            if warmup:
                if (float(warmup[0]["old"]) != row["values"][1 - warmup[0]["state"]]
                        or not all(event["accepted"] for event in warmup)):
                    judged.update(status="inconclusive", reason="An unscored warmup did not commit an alternating change")
                judged["warmup"] = warmup
            judged.update({k:row[k] for k in ("values","displayLabel","ocrLabels","scope")})
            judged.update(calibration=events[:2],framesSHA256=hashlib.sha256(pixels).hexdigest(),scoreEndNs=end)
            result["operations"][key] = judged
    result["sourceSHA256After"] = hashlib.sha256(source.read_bytes()).hexdigest()
    if result["sourceSHA256After"] != result["sourceSHA256"]: raise ValueError("Source changed")
    result["finishedAt"] = info["lastScreenCaptureEndedAt"]
    if "stopReason" in info:
        result["stopReason"] = info["stopReason"]
    result["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    return result


def merge(archives, source):
    captures = [replay(path,source) for path in archives]
    if len(captures) == 1:
        return captures[0]
    first = captures[0]
    identity = ("protocol","sourceSHA256","sourceSHA256After","hardware","os","osBuild","photoRectPixels","roi","policy",
                "recorderSHA256")
    result = {k:first[k] for k in (*identity,"schemaVersion","driver","startedAt") if k in first}
    result.update(planned=[],operations={},sessions=[],finishedAt=captures[-1]["finishedAt"])
    for archive, capture in zip(archives,captures):
        if any(capture.get(k) != first.get(k) for k in identity):
            raise ValueError("Capture geometry, source, platform or scoring policy changed")
        result["sessions"].append({k:capture[k] for k in ("startedAt","finishedAt","window","archiveSHA256","stopReason",
                                                          "requestedWarmSamples","requestedWarmupInputs","recorderSHA256") if k in capture}
            | {"archive":archive.name,"outcomes":{k:r["status"] for k,r in capture["operations"].items()}})
        for key in capture.get("planned",capture["operations"]):
            if key not in result["planned"]:
                result["planned"].append(key)
        for key, row in capture["operations"].items():
            prior = result["operations"].get(key)
            if prior and prior.get("values") != row.get("values"):
                raise ValueError(f"Input values changed for {key}")
            # Keep one uninterrupted control series. A repeat may qualify a previous
            # failure. When neither qualifies, retain the series with most verified inputs.
            def rank(record):
                return record["status"] == "measured", sum(t["verified"] for t in record.get("trials",[]))
            if prior is None or rank(row) > rank(prior):
                result["operations"][key] = {**row,"archive":archive.name}
    return result


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("archives",nargs="+",type=Path)
    p.add_argument("--source",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    args = p.parse_args()
    data = merge(args.archives,args.source)
    args.output.write_text(json.dumps(data,indent=2,allow_nan=False)+"\n")
    print({k:r["status"] for k,r in data["operations"].items()})
