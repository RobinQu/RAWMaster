#!/usr/bin/env python3
"""Measure native RAWMaster edits with the shared screen-photo-response recorder in a private background window."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import runpy
import selectors
import shutil
import signal
import subprocess
import tempfile
import time

from canvas_latency import POLICY, load_frames, score, warmup_states

ROOT = Path(__file__).resolve().parents[2]
# Use the same published operation IDs and A/B settings as Adobe's driver.
CASES = runpy.run_path(str(Path(__file__).with_name("benchmark-acr-canvas.py")))["CASES"]


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def write(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="Compiled CaptureCanvas.swift")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--flashraw-library", type=Path,
                        default=ROOT / "output/RAWMaster.app/Contents/Resources/FlashRaw/libflashraw_capi.dylib",
                        help="FlashRaw dylib shipped in the release app (XCTest has its own bundle)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frames", type=Path, help="Retain raw ScreenCaptureKit ROI buffers and action timestamps for independent scoring")
    parser.add_argument("--diagnostics", action="store_true",
                        help="Record clock anchors, accepted AppKit draws and a final image telemetry sidecar")
    parser.add_argument("--samples", default=10, type=int)
    parser.add_argument("--warmup", default=0, type=int, help="Unscored alternating changes before A/B calibration")
    parser.add_argument("--settle", default=0.8, type=float)
    parser.add_argument("--operations", nargs="+", choices=CASES)
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build/native-presented-lab",
                        help="SwiftPM build directory for the release canvas fixture")
    parser.add_argument("--skip-build", action="store_true", help="Use the already rebuilt Release test bundle")
    args = parser.parse_args()
    args.source, args.binary, args.output = (p.resolve() for p in (args.source, args.binary, args.output))
    args.flashraw_library = args.flashraw_library.resolve()
    if (args.output.exists() or args.samples < 2 or args.warmup < 0 or args.settle < 0.5
            or not args.binary.is_file() or not args.source.is_file()):
        parser.error("Provide an existing RAW and recorder, a new output, a nonnegative warmup and sufficient repetitions/settle interval")
    if not args.flashraw_library.is_file():
        parser.error("Supply the packaged FlashRaw library using --flashraw-library")
    telemetry_output = args.output.with_name(args.output.stem + ".telemetry.json") if args.diagnostics else None
    if telemetry_output and telemetry_output.exists():
        parser.error(f"Provide a new diagnostics sidecar destination: {telemetry_output}")
    warmup_order = warmup_states(args.warmup)
    frame_folder = args.frames.resolve() if args.frames else None
    if frame_folder:
        frame_folder.mkdir(parents=True, exist_ok=False)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = {"schemaVersion": 1, "protocol": "screen-photo-response-v1",
              "driver": "typed numeric commit through the shipping EditingController; nonactivating background AppKit canvas",
              "trialEnd": "native canvas acknowledged the target settled recipe, followed by the recorded quiet interval",
              "testHostActivity": "userInitiatedAllowingIdleSystemSleep",
              "quietSeconds": args.settle,
              "build": "Release, -O with testability enabled", "startedAt": datetime.now(timezone.utc).isoformat(),
              "sourceSHA256": digest(args.source), "os": platform.mac_ver()[0],
              "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
              "osBuild": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
              "requestedWarmSamples": args.samples, "requestedWarmupInputs": args.warmup,
              "recorderSHA256": digest(args.binary), "flashRawLibrarySHA256": digest(args.flashraw_library),
              "policy": POLICY, "operations": {}}
    if telemetry_output:
        result["diagnostics"] = {
            "enabled": True,
            "telemetrySidecar": telemetry_output.name,
            "clockAnchor": "Core Media host sentNs bracketed by Dispatch uptime nanoseconds",
            "drawBoundary": "AppKit draw began and returned for the coordinator's accepted current frame, in Dispatch uptime nanoseconds",
            "telemetryBoundary": "Bounded ImagePerformanceTelemetry snapshot at stop before editor shutdown, in Dispatch uptime nanoseconds",
        }
    with tempfile.TemporaryDirectory(prefix="rawmaster-native-presented-") as work:
        folder = Path(work)
        def path(name):
            return folder / name
        # Compile with the same optimizer as the shipping executable. Testability permits
        # the fixture to drive the existing typed controls and observe the native canvas.
        cmd = ["swift", "test", "--scratch-path", str(args.scratch_path.resolve()),
               "-c", "release", "--jobs", "4", "-Xswiftc", "-enable-testing"]
        if args.skip_build:
            cmd.append("--skip-build")
        cmd.extend(["--filter", "NativePresentedCanvasTests/testOptInRealRAWPresentedCanvas"])
        environment = dict(os.environ, RAWMASTER_PRESENTED_CANVAS_SOURCE=str(args.source), RAWMASTER_PRESENTED_CANVAS_JOB=work,
                           RAWMASTER_PRESENTED_CANVAS_DIAGNOSTICS="1" if args.diagnostics else "0",
                           RAWMASTER_FLASHRAW_LIBRARY=str(args.flashraw_library))
        log = args.output.with_name(args.output.stem + ".log")
        with log.open("x") as output_log:
            host = subprocess.Popen(cmd, cwd=ROOT, env=environment, stdout=output_log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            sequence = 0
            def wait(name, timeout):
                deadline = time.monotonic() + timeout
                while not path(name).is_file():
                    if path("failure.json").is_file():
                        raise RuntimeError(json.loads(path("failure.json").read_text())["error"])
                    if host.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError(f"Could not obtain {name} from native fixture; see {log}")
                    time.sleep(0.01)
                return json.loads(path(name).read_text())

            def request(action, **values):
                nonlocal sequence
                sequence += 1
                write(path(f"request-{sequence}.json"), dict(action=action, **values))
                reply = wait(f"reply-{sequence}.json", 65)
                if "error" in reply:
                    raise ValueError(reply["error"])
                return reply

            try:
                meta = wait("ready.json", 720)
                if meta.get("diagnosticsEnabled", False) != args.diagnostics:
                    raise RuntimeError("Native fixture diagnostics mode does not match the request; rebuild the Release test bundle")
                if meta["sourceSHA256"] != result["sourceSHA256"]:
                    raise ValueError("The displayed native work and requested source differ")
                scope = f"pid:{meta['pid']}"
                matches = json.loads(subprocess.check_output([args.binary, "list", scope], text=True, timeout=20))
                matched_windows = [row for row in matches if row["id"] == meta["id"]]
                if len(matched_windows) != 1:
                    raise ValueError(f"ScreenCaptureKit could not find the fixture's window {meta['id']} for {scope}")
                window = matched_windows[0]
                w, h = [round(v * window["scale"]) for v in window["frame"][2:]]
                x, y, pw, ph = meta["photoRectPixels"]
                if min(x, y) < 0 or x + pw > w + 1 or y + ph > h + 1:
                    raise ValueError(f"Native photo bounds exceed captured window: {meta['photoRectPixels']}")
                roi = [(x + pw * 0.2) / w, (y + ph * 0.2) / h, pw * 0.6 / w, ph * 0.6 / h]
                result.update(window=window, photoRectPixels=meta["photoRectPixels"], roi=roi,
                              sourcePixels=meta["sourcePixels"], previewPixels=meta["previewPixels"],
                              initialRecipe=meta["recipe"], decoder=meta["decoder"], testBundleSHA256=meta["testBundleSHA256"])
                write(args.output, result)
                for label in args.operations or CASES:
                    key, a, b = CASES[label]
                    try:
                        request("reset")
                        # Committing zero to a pristine, disabled adjustment is a no-op in the
                        # shipping UI. Visit B once so the first A and later A share the same
                        # enabled group, prepared state and complete recipe fingerprint.
                        precondition = request("set", key=key, value=b)
                        if warmup_order and warmup_order[0] == 1 and not request("set", key=key, value=a)["accepted"]:
                            raise ValueError("Could not prepare the initial state for warmup")
                    except ValueError as error:
                        result["operations"][key] = {"status": "inconclusive", "reason": str(error), "values": [a, b], "trials": []}
                        write(args.output, result)
                        print(key, "inconclusive", flush=True)
                        continue
                    time.sleep(args.settle)
                    raw = path(key + ".bin")
                    recorder = subprocess.Popen([args.binary, "capture", scope, str(meta["id"]),
                        *map(str, roi), raw], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                    warmup, events = [], []
                    try:
                        with selectors.DefaultSelector() as ready:
                            ready.register(recorder.stdout, selectors.EVENT_READ)
                            if not ready.select(15) or recorder.stdout.readline().strip() != "READY":
                                raise ValueError("ScreenCaptureKit did not supply an initial photo frame")
                        time.sleep(0.15)
                        for state in warmup_order:
                            event = request("set", key=key, value=(a, b)[state])
                            warmup.append(dict(event, state=state))
                            time.sleep(args.settle)
                        for i in range(args.samples + 2):
                            state = i % 2
                            event = request("set", key=key, value=(a, b)[state])
                            events.append(dict(event, state=state))
                            time.sleep(args.settle)
                        end = time.monotonic_ns()
                    except ValueError as error:
                        row = {"status": "inconclusive", "reason": str(error), "inputEvents": events, "trials": []}
                    finally:
                        recorder.stdin.close()
                        try:
                            recorder.wait(timeout=12)
                        except subprocess.TimeoutExpired:
                            recorder.kill()
                            recorder.wait()
                    if recorder.returncode:
                        raise RuntimeError("Canvas recorder failed")
                    if len(events) == args.samples + 2 and (not precondition["accepted"]
                            or not all(e["accepted"] for e in warmup + events[:2])
                            or any(e["recipeFingerprint"] != events[e["state"]]["recipeFingerprint"] for e in warmup + events)):
                        row = {"status": "inconclusive", "reason": "The accepted inputs did not reproduce the calibrated A/B recipes",
                               "inputEvents": events, "trials": []}
                    elif len(events) == args.samples + 2:
                        row = score(load_frames(raw), events, end)
                    if args.diagnostics and not row["trials"]:
                        row.setdefault("inputEvents", events)
                    row.update(values=[a, b], displayLabel=label, precondition=precondition, calibration=events[:2],
                               scope="central 60% of displayed photo")
                    if args.warmup:
                        row["warmup"] = warmup
                    if frame_folder and len(events) == args.samples + 2:
                        shutil.copyfile(raw, frame_folder / (key + ".bin"))
                        write(frame_folder / (key + ".json"), {"events": events, "warmup": warmup, "endNs": end})
                    raw.unlink(missing_ok=True)
                    result["operations"][key] = row
                    write(args.output, result)
                    print(key, row["status"], flush=True)
                request("stop")
                host.wait(timeout=60)
                if host.returncode:
                    raise RuntimeError(f"Native fixture failed; see {log}")
                if telemetry_output:
                    snapshot = path("telemetry.json")
                    if not snapshot.is_file():
                        raise RuntimeError(f"Native fixture did not write image telemetry; see {log}")
                    with snapshot.open("rb") as source, telemetry_output.open("xb") as destination:
                        shutil.copyfileobj(source, destination)
            finally:
                if host.poll() is None:
                    # Notify the test so the normal shutdown path releases its window, engine and private library.
                    sequence += 1
                    write(path(f"request-{sequence}.json"), {"action": "stop"})
                    try:
                        host.wait(timeout=25)
                    except subprocess.TimeoutExpired:
                        # The test runner may have spawned xctest. Terminate only the
                        # process group created for this dedicated invocation.
                        os.killpg(host.pid, signal.SIGTERM)
                        try:
                            host.wait(timeout=12)
                        except subprocess.TimeoutExpired:
                            os.killpg(host.pid, signal.SIGKILL)
                            host.wait()
    result["finishedAt"] = datetime.now(timezone.utc).isoformat()
    result["sourceSHA256After"] = digest(args.source)
    if result["sourceSHA256After"] != result["sourceSHA256"]:
        raise ValueError("Source hash changed during capture")
    write(args.output, result)
    if frame_folder:
        write(frame_folder / "collection.json", {"measuredInputs": args.samples, "warmupInputs": args.warmup,
              "settleSeconds": args.settle, "recorderSHA256": result["recorderSHA256"],
              "testBundleSHA256": result["testBundleSHA256"]})
        observations = frame_folder / "observations.json"
        if observations != args.output:
            shutil.copyfile(args.output, observations)


if __name__ == "__main__":
    main()
