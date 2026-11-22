#!/usr/bin/env python3
"""Observe native AX edits inside an open benchmark copy in Adobe Camera Raw."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import subprocess
import tempfile
import time

from canvas_latency import POLICY, load_frames, score

BUNDLE = "com.adobe.Photoshop"
# Numeric controls in the Light, Color and Effects panels. UI labels are identified by OCR at their AX fields.
CASES = {
    "Exposure": ("light-exposure", 0, 0.5), "Contrast": ("light-contrast", 0, 30),
    "Highlights": ("light-highlights", 0, 30), "Shadows": ("light-shadows", 0, 30),
    "Whites": ("light-whites", 0, 30), "Blacks": ("light-blacks", 0, 30),
    "Temperature": ("color-temp-raw", 5500, 6500), "Tint": ("color-tint", 16, 40),
    "Vibrance": ("color-vibrance", 0, 30), "Saturation": ("color-saturation", 0, 30),
    "Texture": ("effects-texture", 0, 30), "Clarity": ("effects-clarity", 0, 30),
    "Dehaze": ("effects-dehaze", 0, 30), "Vignette": ("effects-pcv-amount", 0, -50),
    "Grain": ("effects-grain-amount", 0, 50), "Glow": ("effects-glow-amount", 0, 65),
}
# Adobe's small 'y' and 'v' can be indistinguishable to Vision at this font size.
OCR_LABELS = {"Claritv": "Clarity"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--window", required=True, help="Exact Camera Raw version in the window title")
    parser.add_argument("--photo-rect", required=True, type=int, nargs=4, metavar=("X", "Y", "W", "H"),
                        help="Visible photo bounds in the captured window’s physical pixels")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--operations", nargs="+", choices=CASES)
    parser.add_argument("--frames", type=Path, help="Retain raw ScreenCaptureKit ROI buffers and action timestamps for independent scoring")
    parser.add_argument("--samples", default=10, type=int)
    parser.add_argument("--settle", default=0.8, type=float)
    args = parser.parse_args()
    if args.output.exists() or args.samples < 2 or args.settle < 0.5:
        parser.error("Provide a new output path, at least two alternating changes and a sufficient settle interval")
    def native(*parts, timeout=25):
        return json.loads(subprocess.check_output([args.binary, *map(str, parts)], text=True, timeout=timeout))
    def sha():
        with args.source.open("rb") as stream:
            return hashlib.file_digest(stream, "sha256").hexdigest()
    native("activate", BUNDLE, args.window)
    matches = [w for w in native("list", BUNDLE) if w["title"] == args.window]
    if len(matches) != 1:
        raise ValueError("Expected one Camera Raw dialog with the supplied title")
    window, = matches
    w, h = [round(v * window["scale"]) for v in window["frame"][2:]]
    x, y, pw, ph = args.photo_rect
    if min(pw, ph) <= 0 or min(x, y) < 0 or x + pw > w or y + ph > h:
        raise ValueError("Photo bounds exceed window pixels")
    roi = [(x + pw * .2) / w, (y + ph * .2) / h, pw * .6 / w, ph * .6 / h]
    result = {"schemaVersion": 1, "protocol": "screen-photo-response-v1", "driver": "Native numeric typing and Tab; committed value read back",
              "startedAt": datetime.now(timezone.utc).isoformat(), "sourceSHA256": sha(), "window": window,
              "os": platform.mac_ver()[0], "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
              "photoRectPixels": args.photo_rect, "roi": roi, "policy": POLICY, "operations": {}}
    def checkpoint():
        result["sourceSHA256After"] = sha()
        if result["sourceSHA256After"] != result["sourceSHA256"]:
            raise ValueError("RAW changed during capture")
        tmp_output = args.output.with_suffix(".tmp")
        tmp_output.write_text(json.dumps(result,indent=2,allow_nan=False)+"\n")
        os.replace(tmp_output,args.output)

    with tempfile.TemporaryDirectory(prefix="rawmaster-screencapture-") as folder:
        tmp = Path(folder)
        shot = tmp / "window.png"
        subprocess.run(["screencapture", "-x", "-o", "-l", str(window["id"]), shot], check=True)
        identified = native("fields", BUNDLE, args.window, "AXTextField", shot, timeout=240)
        if not any(args.source.name in word["text"] for word in identified["words"]):
            raise ValueError("The Camera Raw window did not show the benchmark file name")
        wanted = args.operations or list(CASES)
        if args.frames:
            args.frames.mkdir(parents=True, exist_ok=False)
        result["planned"] = [CASES[label][0] for label in wanted]
        checkpoint()
        for label in wanted:
            key, first, second = CASES[label]
            attrs = [f for f in identified["fields"] if label in [OCR_LABELS.get(v, v) for v in f["labelCandidates"]]]
            if len(attrs) != 1:
                result["operations"][key] = {"status": "inconclusive", "values":[first,second],
                                             "reason": "Control could not be uniquely identified on screen"}
                checkpoint()
                continue
            field = attrs[0]
            def set_value(value):
                event = native("type", BUNDLE, args.window, "AXTextField", field["index"], value)
                if event["position"] != field["position"]:
                    raise ValueError("The AX field moved during capture")
                event["accepted"] = float(event["actual"]) == float(value)
                return event
            native("activate", BUNDLE, args.window)
            time.sleep(args.settle)
            stream_file = tmp / (key + ".bin")
            capture = subprocess.Popen([args.binary, "capture", BUNDLE, str(window["id"]), *map(str, roi), stream_file],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            events = []
            original = field["value"]
            def interrupted(reason):
                result["interruption"] = {"operation":key,"completedInputs":len(events),"reason":reason,
                                           "observedAt":datetime.now(timezone.utc).isoformat()}
                checkpoint()
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(capture.stdout, selectors.EVENT_READ)
                    if not selector.select(20) or capture.stdout.readline().strip() != "READY":
                        raise ValueError("ScreenCaptureKit supplied no photo frame")
                for i in range(args.samples + 2):
                    state = i % 2
                    event = set_value((first, second)[state])
                    events.append(dict(event, state=state))
                    time.sleep(args.settle)
                end_ns = time.monotonic_ns()
            except (KeyboardInterrupt,OSError,ValueError,subprocess.SubprocessError) as error:
                interrupted(str(error) or type(error).__name__)
                raise
            finally:
                capture.stdin.close()
                try:
                    capture.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    capture.kill()
                    capture.wait()
                if events:
                    try:
                        restore = set_value(original)
                        time.sleep(args.settle)
                    except (OSError,ValueError,subprocess.SubprocessError) as error:
                        interrupted("The original field could not be restored: "+str(error))
                        raise
            if capture.returncode:
                interrupted("Window capture exited with status "+str(capture.returncode))
                raise RuntimeError("Window capture failed")
            # Adobe can publish an intermediate string (e.g. "3" before "+30").
            # Read the committed prior value before beginning the next input, including the restoration.
            for event,following in zip(events,events[1:]+[restore]):
                event["committedValue"] = following["old"]
                event["accepted"] = float(following["old"]) == (first,second)[event["state"]]
            row = score(load_frames(stream_file), events, end_ns)
            if not all(t["accepted"] for t in events[:2]):
                row.update(status="inconclusive",reason="A calibration input did not commit its requested value")
            if args.frames:
                shutil.copyfile(stream_file,args.frames/(key+".bin"))
                (args.frames/(key+".json")).write_text(json.dumps({"events":events,"endNs":end_ns,"restoration":restore},indent=2)+"\n")

            row.update({"values": [first, second], "displayLabel": label, "ocrLabels": field["labelCandidates"],
                        "calibration": events[:2], "scope": "central 60% of displayed photo"})
            result["operations"][key] = row
            print(key, row["status"], flush=True)
            checkpoint()
    result["finishedAt"] = datetime.now(timezone.utc).isoformat()
    checkpoint()


if __name__ == "__main__":
    main()
