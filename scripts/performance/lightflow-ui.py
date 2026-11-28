#!/usr/bin/env python3
"""Run the pinned LightFlow editor offline with a dedicated profile.

The start command keeps the local server alive. A second invocation prepares a numeric value
in the actual UI and sends Return to commit it. Only that last key is on the timed boundary.
Python requires websocket-client to talk to the isolated browser's local DevTools port.
"""

import argparse
from datetime import datetime, timezone
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import secrets
import selectors
import shutil
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

import websocket

from canvas_latency import (NATIVE_ROI_PROTOCOL, NATIVE_ROI_SCOPE, POLICY, capture_native_roi_screenshot,
                            load_frames, native_roi_geometry, score, warmup_states)

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
DEFAULT_SHELL = (
    ROOT
    / "output/tools/chrome-157.0.8103.78/chrome-headless-shell-mac-arm64/chrome-headless-shell"
)
EDITOR = "assets/index-zP4kU_H7.js"
EDITOR_SHA = "0ca67eaec7788ac79439d6700c6791cff845bbb8938d6b2d295831871afc678e"
NATIVE_ROI_SOURCE_SHA256 = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"


class DevTools:
    def __init__(self, endpoint):
        self.ws = websocket.create_connection(
            endpoint, suppress_origin=True, timeout=90
        )
        self.identifier = 0

    def call(self, method, params=None):
        self.identifier += 1
        self.ws.send(
            json.dumps(
                {"id": self.identifier, "method": method, "params": params or {}}
            )
        )
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get("id") == self.identifier:
                if "error" in reply:
                    raise RuntimeError(reply["error"]["message"])
                return reply["result"]

    def evaluate(self, expression):
        reply = self.call(
            "Runtime.evaluate",
            {"expression": expression, "awaitPromise": True, "returnByValue": True},
        )
        if "exceptionDetails" in reply:
            raise RuntimeError(
                reply["exceptionDetails"]
                .get("exception", {})
                .get("description", "LightFlow script failed")
            )
        return reply["result"].get("value")


def wait_for(check, description, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.15)
    raise RuntimeError("timed out waiting for " + description)


class EditorFiles(SimpleHTTPRequestHandler):
    def __init__(self, *args, raw, raw_path, served, **kwargs):
        self.raw = raw
        self.raw_path = raw_path
        self.served = served
        super().__init__(*args, **kwargs)

    def translate_path(self, path):
        if urlsplit(path).path == self.raw_path:
            return str(self.raw)
        return super().translate_path(path)

    def list_directory(self, path):
        self.send_error(404)
        return None

    def log_message(self, fmt, *args):
        if fmt.startswith("code "):
            print(self.path, *args, flush=True)

    def send_head(self):
        stream = super().send_head()
        if stream is not None and urlsplit(self.path).path != self.raw_path:
            name = (
                Path(stream.name)
                .resolve()
                .relative_to(Path(self.directory).resolve())
                .as_posix()
            )
            self.served.add(name)
        return stream

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self' blob: data:; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; worker-src 'self' blob:; object-src 'none'; form-action 'none'",
        )
        super().end_headers()


def view_geometry(cdp):
    return cdp.evaluate("""(() => {
      const canvas = document.querySelector('lightflow-viewer canvas');
      if (!canvas) return null;
      const rect = canvas.getBoundingClientRect(), frame = window.__lightflow.frames.last();
      if (!(rect.width>0 && rect.height>0 && frame?.frameW>0 && frame.fullRes)) return null;
      return {canvasCSS:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}, dpr:devicePixelRatio,
        inner:[innerWidth,innerHeight],outer:[outerWidth,outerHeight],screen:[screenX,screenY], frame,
        metrics:window.__lightflow.develop.viewerInfo.get().metrics,
        availableInputs:[...document.querySelectorAll('lightflow-slider-value input')].filter(x=>x.getBoundingClientRect().width).map(x=>x.getAttribute('aria-label'))};
    })()""")


def start(args):
    with (args.site / EDITOR).open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != EDITOR_SHA:
            raise SystemExit("LightFlow editor build 2d41ab1 is required")
    if args.session.exists():
        raise SystemExit("use a new session path")
    with args.raw.open("rb") as stream:
        raw_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    raw_path = f"/{secrets.token_urlsafe(24)}/benchmark{args.raw.suffix}"
    served = set()
    handler = partial(
        EditorFiles,
        directory=str(args.site),
        raw=args.raw,
        raw_path=raw_path,
        served=served,
    )
    with (
        ThreadingHTTPServer(("127.0.0.1", 0), handler) as server,
        tempfile.TemporaryDirectory(prefix="lightflow-ui-") as profile,
    ):
        threading.Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_port}"
        host = args.background_host
        if host and (args.visible or args.chrome):
            raise ValueError("Choose the prepared background host or a Chrome session")
        browser = host / "Electron.app/Contents/MacOS/Electron" if host else args.chrome or (DEFAULT_CHROME if args.visible else DEFAULT_SHELL)
        if not browser.is_file():
            raise ValueError(
                "provide --chrome with the path to a Chrome Headless Shell binary"
            )
        if not host and not args.visible and browser.name != "chrome-headless-shell":
            raise ValueError(
                "background UI runs require the standalone chrome-headless-shell executable"
            )
        flags = [
            str(browser),
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--remote-debugging-port=0",
            f"--user-data-dir={profile}",
            f"--window-size={args.width},{args.height}",
        ]
        env = None
        marker = Path(profile) / "window.json"
        if host:
            flags = [str(browser), str(host.resolve() / "main.cjs")]
            env = dict(os.environ, RAWMASTER_LF_PROFILE=profile, RAWMASTER_LF_ORIGIN=origin, RAWMASTER_LF_WINDOW=str(marker))
        elif args.visible:
            flags.append(f"--app={origin}/")
        else:
            flags += ["--enable-gpu", origin + "/"]
        proc = subprocess.Popen(
            flags, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        try:
            portfile = Path(profile, "DevToolsActivePort")
            wait_for(portfile.exists, "Chrome control port")
            port = int(portfile.read_text().splitlines()[0])

            def page():
                with urlopen(f"http://127.0.0.1:{port}/json/list") as stream:
                    return next(
                        (
                            t
                            for t in json.load(stream)
                            if t["type"] == "page" and t["url"].startswith(origin)
                        ),
                        None,
                    )

            tab = wait_for(page, "local LightFlow page")
            cdp = DevTools(tab["webSocketDebuggerUrl"])
            def editor_ready():
                try:
                    return cdp.evaluate("!!window.__lightflow?.frames && !!window.__lightflow?.develop")
                except RuntimeError as error:
                    # The tab URL appears before Chromium creates its first page context.
                    if "Cannot find default execution context" in str(error) or "Execution context was destroyed" in str(error):
                        return False
                    raise
            wait_for(editor_ready, "LightFlow editor")
            cdp.evaluate(
                f"window.__lightflow.importUrls([{json.dumps(origin + raw_path)}])"
            )
            photo = wait_for(
                lambda: cdp.evaluate(
                    "window.__lightflow.stores.catalog.get().order[0]"
                ),
                "RAW import",
            )
            cdp.evaluate(
                f'window.__lightflow.setActive({json.dumps(photo)});window.__lightflow.setWorkspace("develop")'
            )
            state = wait_for(lambda: view_geometry(cdp), "decoded RAW in viewer", 90)
            title = "LightFlow RAW benchmark " + secrets.token_hex(4)
            cdp.evaluate(f"document.title={json.dumps(title)}")
            info = {
                "title": title,
                "build": "2d41ab1",
                "visible": bool(host or args.visible),
                "sourceSHA256": raw_hash,
                "browserBinarySHA256": hashlib.sha256(browser.read_bytes()).hexdigest(),
                "tab": tab["webSocketDebuggerUrl"],
                "pid": proc.pid,
                "photo": photo,
                "view": state,
            }
            if host:
                wait_for(marker.exists, "background window identifier")
                win = json.loads(marker.read_bytes())
                info.update(windowID=win["id"], windowBundle="org.rawmaster.benchmark.lightflow-chromium", electron=win)
            info["uiSHA256"] = {}
            for filename in sorted(served):
                with (args.site / filename).open("rb") as asset:
                    info["uiSHA256"][filename] = hashlib.file_digest(
                        asset, "sha256"
                    ).hexdigest()
            args.session.write_text(json.dumps(info, indent=2) + "\n")
            print("Ready", args.session, flush=True)
            proc.wait()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            server.shutdown()


def prepare(cdp, label, value, locator=None):
    selected = cdp.evaluate(
        """(async ([label,locator])=>{
      const root=locator?document.querySelector(locator):document;
      const input=root&&[...root.querySelectorAll('lightflow-slider-value input')].find(e=>e.getAttribute('aria-label')===label&&!e.disabled&&e.getBoundingClientRect().width>0);
      if(!input)return null;
      input.focus();await new Promise(requestAnimationFrame);input.select();
      return input.value;
    })("""
        + json.dumps([label, json.loads(locator) if locator else None])
        + ")"
    )
    if selected is None:
        raise ValueError(f"No visible editable LightFlow control {label}")
    cdp.call("Input.insertText", {"text": str(value)})
    actual = cdp.evaluate("document.activeElement.value")
    if actual != str(value):
        raise RuntimeError(f"prepared control reads {actual!r}")
    return selected


def commit(cdp):
    event = {
        "key": "Enter",
        "code": "Enter",
        "windowsVirtualKeyCode": 13,
        "nativeVirtualKeyCode": 13,
    }
    started = time.monotonic_ns()
    cdp.call("Input.dispatchKeyEvent", {"type": "keyDown", **event})
    responded = time.monotonic_ns()
    cdp.call("Input.dispatchKeyEvent", {"type": "keyUp", **event})
    return {
        "sentNs": started,
        "dispatchResponseHostNs": responded,
        "boundary": "host send of trusted Return on prepared numeric control to captured frame",
    }


# Values match the native Camera Raw capture cases. Setup changes select the real editor panel outside timing.
CASES = {
    "light-exposure": ("base", "exposure", 0, 0.5),
    "light-contrast": ("base", "contrast", 0, 30),
    "light-highlights": ("base", "highlights", 0, 30),
    "light-shadows": ("base", "shadows", 0, 30),
    "light-whites": ("base", "whites", 0, 30),
    "light-blacks": ("base", "blacks", 0, 30),
    "color-temp-raw": ("base", "temperature", 5500, 6500),
    "color-tint": ("base", "tint", 16, 40),
    "color-vibrance": ("base", "vibrance", 0, 30),
    "color-saturation": ("base", "saturation", 0, 30),
    "effects-texture": ("basic", "texture", 0, 30),
    "effects-clarity": ("basic", "clarity", 0, 30),
    "effects-dehaze": ("basic", "dehaze", 0, 30),
    "effects-pcv-amount": ("effects", "vignetteAmount", 0, -50),
    "effects-grain-amount": ("effects", "grainAmount", 0, 50),
    "effects-glow-amount": ("effects", "bloom", 0, 65),
}


def select_control(cdp, group, key):
    locator = json.dumps(f'lightflow-slider[data-id="{group}.{key}"]')
    cdp.evaluate(
        """(([group])=>{
      const app=window.__lightflow, photo=app.stores.catalog.get().active;
      const id=app.editOf(photo).grade.nodes.find(n=>n.kind==='corrector').id;
      app.stores.develop.set({target:group==='base'?{kind:'base'}:{kind:'node',id}});
      app.develop.showSection(group==='base'?'basic':group);
    })("""
        + json.dumps([group])
        + ")"
    )
    control = wait_for(
        lambda: cdp.evaluate(
            """(()=>{
      const slider=document.querySelector("""
            + locator
            + """);
      const field=slider?.querySelector('input'), track=slider?.querySelector('[role=slider]');
      if(!field||!track||field.disabled||!field.getBoundingClientRect().width) return null;
      return {label:field.getAttribute('aria-label'),value:track.getAttribute('aria-valuenow')};
    })()"""
        ),
        group + "." + key,
        2,
    )
    return locator, control


def photo_roi(view, window):
    scale, frame = window["scale"], view["frame"]
    a, b, c, d, tx, ty = frame["affine"]
    if min(a, d) <= 0 or max(abs(b), abs(c)) > 1e-6:
        raise ValueError("upright, unrotated photo required")
    canvas, ratio = view["canvasCSS"], view["dpr"]
    # The editor affine maps backing-canvas px to normalized photo coordinates.
    dx, dy, pw, ph = -tx / a, -ty / d, 1 / a, 1 / d
    if (
        dx < -2
        or dy < -2
        or dx + pw > frame["width"] + 2
        or dy + ph > frame["height"] + 2
    ):
        raise ValueError(
            f"photo leaves visible canvas {[(dx, dy, pw, ph), frame['width'], frame['height']]}"
        )
    outerW, outerH = view["outer"]
    innerW, innerH = view["inner"]
    if (
        abs(outerW - window["frame"][2]) > 2
        or abs(outerH - window["frame"][3]) > 2
        or scale != ratio
    ):
        raise ValueError(
            f"Chrome and captured window geometry differ (CSS {view['outer']}, SC {window})"
        )
    x = (max(0, (outerW - innerW) / 2) + canvas["x"]) * ratio + dx
    y = (outerH - innerH + canvas["y"]) * ratio + dy
    w, h = window["frame"][2] * scale, window["frame"][3] * scale
    return [round(n) for n in (x, y, pw, ph)], [
        (x + pw * 0.2) / w,
        (y + ph * 0.2) / h,
        pw * 0.6 / w,
        ph * 0.6 / h,
    ]


def compositor_geometry(view):
    frame, canvas, dpr = view["frame"], view["canvasCSS"], view["dpr"]
    a, b, c, d, tx, ty = frame["affine"]
    if a <= 0 or d <= 0 or max(abs(b), abs(c)) > 1e-6:
        raise ValueError("Upright photo geometry required")
    dx, dy, width, height = -tx / a, -ty / d, 1 / a, 1 / d
    if (
        dx < -2
        or dy < -2
        or dx + width > frame["width"] + 2
        or dy + height > frame["height"] + 2
    ):
        raise ValueError("The full photograph is outside the compositor canvas")
    x, y = canvas["x"] * dpr + dx, canvas["y"] * dpr + dy
    viewport = [round(n * dpr) for n in view["inner"]]
    photo = [round(n) for n in [x, y, width, height]]
    roi = [x + width * 0.2, y + height * 0.2, width * 0.6, height * 0.6]
    if min(x, y) < 0 or x + width > viewport[0] + 2 or y + height > viewport[1] + 2:
        raise ValueError("The full photo does not fit the browser compositor viewport")
    return viewport, photo, roi


def set_zoom(cdp, photo_width):
    initial = view_geometry(cdp)
    scale = photo_width / float(initial["frame"]["frameW"])
    cdp.evaluate("window.__lightflow.develop.setZoom(" + json.dumps(scale) + ")")

    def matched():
        view = view_geometry(cdp)
        return view if view and abs(view["metrics"]["scale"] - scale) < 1e-4 else None

    return wait_for(matched, "requested displayed photo size")


def wait_for_native_roi(cdp, window, source_roi):
    last_error = None

    def matched():
        nonlocal last_error
        view = view_geometry(cdp)
        if view is None:
            return None
        view["developView"] = cdp.evaluate("""(() => {
          const {zoom,center,status} = window.__lightflow.stores.develop.get();
          const canvas=document.querySelector('lightflow-viewer canvas');
          return {zoom,center,viewerIdle:!!canvas && canvas.dataset.busy!=='1' && !status.decoding};
        })()""")
        if not view["developView"]["viewerIdle"]:
            return None
        try:
            return view, native_roi_geometry(view, window, source_roi)
        except ValueError as error:
            last_error = error
            return None

    try:
        return wait_for(matched, "a settled 1:1 frame with the requested source ROI")
    except TimeoutError as error:
        if last_error:
            raise ValueError(f"Could not capture the requested native ROI: {last_error}") from error
        raise


def set_native_roi(cdp, window, source_roi):
    frame = wait_for(lambda: view_geometry(cdp), "full-resolution source before setting native zoom")["frame"]
    x, y, width, height = source_roi
    if [frame["frameW"], frame["frameH"]] != [9504, 6336] or x + width > frame["frameW"] or y + height > frame["frameH"]:
        raise ValueError("Native ROI requires the uncropped 9504×6336 Sony source and an in-bounds rectangle")
    center = {"x": (x + width / 2) / frame["frameW"], "y": (y + height / 2) / frame["frameH"]}
    cdp.evaluate("""((center) => {
      const app=window.__lightflow;
      app.develop.setZoom(1);
      app.stores.develop.set({center});
    })(""" + json.dumps(center) + ")")
    return wait_for_native_roi(cdp, window, source_roi)


def commit_control(cdp, locator, label, value):
    prepare(cdp, label, value, locator)
    timing = commit(cdp)
    actual = cdp.evaluate(f"""(async () => {{
      await new Promise(requestAnimationFrame);
      const track = document.querySelector({locator}).querySelector('[role=slider]');
      return Number(track.getAttribute('aria-valuenow'));
    }})()""")
    return dict(
        timing,
        value=value,
        actual=actual,
        accepted=actual is not None and abs(actual - float(value)) < 1e-4,
    )


def compositor_provenance(cdp):
    view = view_geometry(cdp)
    viewport, photo, roi = compositor_geometry(view)
    adapter = cdp.evaluate("""(async () => {
      const a = await navigator.gpu?.requestAdapter();
      if (!a) return null;
      const i = a.info;
      return { vendor: i.vendor, architecture: i.architecture, device: i.device,
        description: i.description, isFallbackAdapter: i.isFallbackAdapter };
    })()""")
    return {
        "viewportPixels": viewport, "photoRectPixels": photo, "roiPixels": roi,
        "sourcePixels": [view["frame"]["frameW"], view["frame"]["frameH"]],
        "canvasPixels": [view["frame"]["width"], view["frame"]["height"]],
        "sourceFullResolution": view["frame"]["fullRes"], "devicePixelRatio": view["dpr"],
        "webGPUAdapterAvailableToEditor": adapter,
        "osBuild": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
    }


def capture_compositor(cdp, session, args):
    from lightflow_compositor import CompositorStream, clock_anchor

    if (
        session["visible"]
        or args.output.exists()
        or args.samples < 10
        or args.settle < 0.5
    ):
        raise ValueError(
            "A windowless session, an unused output file, at least 10 trials and 0.5 s settle are required"
        )
    with args.raw.open("rb") as file:
        raw_hash = hashlib.file_digest(file, "sha256").hexdigest()
    if raw_hash != session["sourceSHA256"]:
        raise ValueError("Photo changed since it was opened")
    view = set_zoom(cdp, args.photo_width)
    viewport, photo, roi = compositor_geometry(view)
    transport_width = min(args.transport_width, viewport[0])
    transport = [transport_width, round(transport_width * viewport[1] / viewport[0])]
    if transport_width < 600:
        raise ValueError("Use at least 600 transport pixels across the editor")
    if abs(photo[2] - args.photo_width) > 1 or abs(photo[3] - args.photo_height) > 1:
        raise ValueError(
            f"Requested {args.photo_width}×{args.photo_height} displayed photo; measured {photo}"
        )
    policy = {
        **POLICY,
        "captureHz": "every available Chromium compositor swap",
        "capture": "Page.screencastFrame, lossless PNG, everyNthFrame=1, transport downsample after compositor rendering",
    }
    result = {
        "schemaVersion": 1,
        "application": "LightFlow",
        "protocol": "headless-compositor-photo-response-v1",
        "driver": "Host send of trusted Return in the original numeric UI field to first recorded compositor swap crossing the photo threshold",
        "build": session["build"],
        "uiSHA256": session["uiSHA256"],
        "browser": cdp.call("Browser.getVersion")["product"],
        "browserBinarySHA256": session["browserBinarySHA256"],
        "sourceSHA256": raw_hash,
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "os": platform.mac_ver()[0],
        "hardware": subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True
        ).strip(),
        "viewportPixels": viewport,
        "transportPixels": transport,
        "photoRectPixels": photo,
        "roiPixels": roi,
        "policy": policy,
        "measurementSurface": "windowless Chromium compositor; no WindowServer, display scanout or physical input",
        "operations": {},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")

    save()
    for identity in args.operations or list(CASES):
        group, key, first, second = CASES[identity]
        row = {}
        try:
            locator, control = select_control(cdp, group, key)

            def change(value):
                return commit_control(cdp, locator, control["label"], value)

            change(second)
            time.sleep(args.settle)
            events = []
            try:
                with CompositorStream(session["tab"], transport) as stream:
                    time.sleep(0.15)
                    for i in range(args.samples + 2):
                        state = i % 2
                        events.append(dict(change((first, second)[state]), state=state))
                        time.sleep(args.settle)
                    end = time.monotonic_ns()
                    time.sleep(0.15)
            finally:
                change(control["value"])
                time.sleep(args.settle)
            viewport_after, photo_after, _ = compositor_geometry(view_geometry(cdp))
            if photo_after != photo or viewport_after != viewport:
                raise ValueError(
                    "Compositor photo geometry changed during the edit series"
                )
            frames, delivery = stream.signatures(roi, viewport)
            drift = (
                clock_anchor()["realtimeMinusMonotonicNs"]
                - stream.anchor["realtimeMinusMonotonicNs"]
            )
            if abs(drift) > 1_000_000:
                raise ValueError(
                    "Wall-clock offset changed by more than one millisecond during this series"
                )
            row = score(frames, events, end)
            row.update(
                values=[first, second],
                displayLabel=control["label"],
                calibration=events[:2],
                swapCount=len(frames),
                swapDeliveryMs=delivery,
                clockAnchor=stream.anchor,
                endClockDriftNs=drift,
            )
        except (
            OSError,
            RuntimeError,
            ValueError,
            KeyError,
            IndexError,
            TypeError,
        ) as exc:
            row = {"status": "inconclusive", "reason": str(exc)}
        result["operations"][identity] = row
        save()
        print(identity, row["status"], row.get("reason", ""), flush=True)
    with args.raw.open("rb") as file:
        result["sourceSHA256After"] = hashlib.file_digest(file, "sha256").hexdigest()
    if result["sourceSHA256After"] != raw_hash:
        raise ValueError("RAW source identity changed")
    result["finalSessionInspection"] = compositor_provenance(cdp)
    save()


def capture(cdp, session, args):
    if not session.get("visible", False):
        raise ValueError("ScreenCaptureKit requires a session started with --visible")
    if args.output.exists() or args.samples < 2 or args.warmup < 0 or args.settle < 0.5:
        raise ValueError(
            "new output file, at least two measured samples, nonnegative warmup and 0.5 s settle required"
        )
    source_roi = getattr(args, "source_roi", None)
    if source_roi and (not args.frames or not session.get("electron") or args.operations not in (None, ["light-exposure"])
                       or min(source_roi[:2]) < 0 or min(source_roi[2:]) <= 0):
        raise ValueError("1:1 source ROI needs the isolated Electron window, --frames and one in-bounds exposure operation")
    warmup_order = warmup_states(args.warmup)
    with args.raw.open("rb") as source:
        source_sha = hashlib.file_digest(source, "sha256").hexdigest()
        if source_sha != session["sourceSHA256"]:
            raise ValueError("Photo changed since the stock editor opened it")
        if source_roi and source_sha != NATIVE_ROI_SOURCE_SHA256:
            raise ValueError("The native ROI workload requires the authorized 8f96…91e1c Sony ARW")
    bundle = session.get("windowBundle", "com.google.Chrome")
    windows = json.loads(subprocess.check_output([args.binary, "list", bundle]))
    matches = [w for w in windows if w["title"] == session["title"] and
               ("windowID" not in session or w["id"] == session["windowID"])]
    if len(matches) != 1:
        raise ValueError(
            f"exact LightFlow window unavailable, title {session['title']}"
        )
    (window,) = matches
    if source_roi:
        view, geometry = set_native_roi(cdp, window, source_roi)
        roi = geometry["sampleROINormalized"]
    else:
        view = set_zoom(cdp, args.photo_width)
        bounds, roi = photo_roi(view, window)
        expected_height = args.photo_width * view["frame"]["frameH"] / view["frame"]["frameW"]
        if abs(bounds[2] - args.photo_width) > 1 or abs(bounds[3] - expected_height) > 1:
            raise ValueError("Visible photo does not match the requested real RAW display size")
    with args.binary.open("rb") as binary:
        recorder_hash = hashlib.file_digest(binary, "sha256").hexdigest()
    result = {
        "schemaVersion": 1,
        "protocol": NATIVE_ROI_PROTOCOL if source_roi else "screen-photo-response-v1",
        "application": "LightFlow",
        "build": session["build"],
        "uiSHA256": session["uiSHA256"],
        "hardware": subprocess.check_output(
            ["sysctl", "-n", "hw.model"], text=True
        ).strip(),
        "os": platform.mac_ver()[0],
        "osBuild": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
        "requestedWarmSamples": args.samples,
        "requestedWarmupInputs": args.warmup,
        "recorderSHA256": recorder_hash,
        "browser": cdp.call("Browser.getVersion")["product"],
        "browserBinarySHA256":session["browserBinarySHA256"],"windowBundle":bundle,
        "driver": "Trusted Return on prepared LightFlow numeric control through local Chrome DevTools; reads committed slider value",
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "sourceSHA256": session["sourceSHA256"],
        "window": window,
        "roi": roi,
        "policy": POLICY,
        "operations": {},
        "viewport": view,
    }
    if source_roi:
        result["nativeROI"] = geometry
    else:
        result["photoRectPixels"] = bounds
    args.output.parent.mkdir(parents=True, exist_ok=True)
    frame_folder = getattr(args,"frames",None)
    if frame_folder:
        frame_folder.mkdir(parents=True,exist_ok=False)

    def save():
        pending = args.output.with_suffix(".partial")
        pending.write_text(json.dumps(result, indent=2) + "\n")
        pending.replace(args.output)

    with tempfile.TemporaryDirectory(prefix="rawmaster-lightflow-frames-") as temp:
        for identity in args.operations or (["light-exposure"] if source_roi else CASES):
            group, key, first, second = CASES[identity]
            try:
                locator, control = select_control(cdp, group, key)

                def set_value(value):
                    prepare(cdp, control["label"], value, locator)
                    focus = None
                    if source_roi:
                        focus = cdp.evaluate(f"""(() => {{
                          const slider=document.querySelector({locator}), input=document.activeElement;
                          return slider?.contains(input) && input.tagName==='INPUT'
                            ? {{slider:slider.dataset.id,label:input.getAttribute('aria-label'),prepared:input.value}} : null;
                        }})()""")
                        if focus != {"slider": "base.exposure", "label": control["label"], "prepared": str(value)}:
                            raise ValueError("The committed input was not focused on the prepared Exposure field")
                    timing = commit(cdp)
                    actual = cdp.evaluate(f"""(async () => {{
                      await new Promise(requestAnimationFrame);
                      const track = document.querySelector({locator}).querySelector('[role=slider]');
                      return Number(track.getAttribute('aria-valuenow'));
                    }})()""")
                    event = {
                        **timing,
                        "value": value,
                        "actual": actual,
                        "accepted": actual is not None
                        and abs(actual - float(value)) < 1e-4,
                    }
                    if source_roi:
                        event["focus"] = focus
                    return event

                # Both calibration targets must be real transitions, even when the initial UI contains zero.
                seed = (first, second)[1 - warmup_order[0]] if warmup_order else second
                if not set_value(seed)["accepted"] and warmup_order:
                    raise ValueError("Could not prepare the initial state for warmup")
                time.sleep(args.settle)
                if source_roi and wait_for_native_roi(cdp, window, source_roi)[1] != geometry:
                    raise ValueError("The native ROI moved while preparing Exposure")
                file = Path(temp) / f"{identity}.bin"
                stream = subprocess.Popen(
                    [
                        args.binary,
                        "capture",
                        bundle,
                        str(window["id"]),
                        *map(str, roi),
                        str(file),
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    text=True,
                )
                warmup, events = [], []
                try:
                    with selectors.DefaultSelector() as selector:
                        selector.register(stream.stdout, selectors.EVENT_READ)
                        if (
                            not selector.select(20)
                            or stream.stdout.readline().strip() != "READY"
                        ):
                            raise ValueError(
                                "ScreenCaptureKit did not supply an initial frame"
                            )
                    for state in warmup_order:
                        warmup.append(dict(set_value((first, second)[state]), state=state))
                        time.sleep(args.settle)
                    for i in range(args.samples + 2):
                        state = i % 2
                        events.append(
                            dict(set_value((first, second)[state]), state=state)
                        )
                        time.sleep(args.settle)
                    end = time.monotonic_ns()
                finally:
                    stream.stdin.close()
                    try:
                        stream.wait(timeout=12)
                    except subprocess.TimeoutExpired:
                        stream.kill()
                        stream.wait()
                    set_value(control["value"])
                    time.sleep(args.settle)
                if stream.returncode:
                    raise ValueError("ScreenCaptureKit stopped unexpectedly")
                if source_roi:
                    if wait_for_native_roi(cdp, window, source_roi)[1] != geometry:
                        raise ValueError("The native ROI moved during the measured input sequence")
                elif photo_roi(view_geometry(cdp), window)[0] != bounds:
                    raise ValueError("displayed image bounds changed during the test")
                row = score(load_frames(file), events, end)
                if not all(event["accepted"] for event in warmup):
                    row.update(status="inconclusive", reason="An unscored warmup did not commit its requested value")
                if source_roi and not all(event["accepted"] for event in events[:2]):
                    row.update(status="inconclusive", reason="A native ROI calibration input did not commit its requested value")
                if source_roi and row["status"] == "measured":
                    snapshots = []
                    try:
                        for state, value in enumerate((first, second)):
                            event = set_value(value)
                            if not event["accepted"]:
                                raise ValueError("A screenshot reference exposure did not commit")
                            time.sleep(args.settle)
                            witnessed_view, witnessed_geometry = wait_for_native_roi(cdp, window, source_roi)
                            if witnessed_geometry != geometry:
                                raise ValueError("The native ROI moved during a screenshot witness")
                            image = frame_folder / f"{identity}-1to1-{state}.png"
                            snapshot = capture_native_roi_screenshot(image, window, geometry)
                            snapshots.append(dict(snapshot, state=state, event=event, viewport=witnessed_view))
                    finally:
                        set_value(control["value"])
                        time.sleep(args.settle)
                    if snapshots[0]["rgbSHA256"] == snapshots[1]["rgbSHA256"] or snapshots[0]["meanLuma"] >= snapshots[1]["meanLuma"]:
                        raise ValueError("The full-resolution ROI screenshots did not witness brighter Exposure B pixels")
                    row["nativeScreenshots"] = snapshots
                if frame_folder:
                    shutil.copyfile(file,frame_folder/(identity+".bin"))
                    markers = {"events": events, "warmup": warmup, "endNs": end}
                    (frame_folder/(identity+".json")).write_text(json.dumps(markers,indent=2)+"\n")
                row.update(
                    values=[first, second],
                    displayLabel=control["label"],
                    calibration=events[:2],
                    scope=NATIVE_ROI_SCOPE if source_roi else "central 60% of displayed photo",
                )
                if args.warmup:
                    row["warmup"] = warmup
            except (
                OSError,
                RuntimeError,
                ValueError,
                subprocess.SubprocessError,
            ) as error:
                row = {"status": "inconclusive", "reason": str(error)}
            result["operations"][identity] = row
            save()
            print(identity, row["status"], row.get("reason", ""), flush=True)
    result["finishedAt"] = datetime.now(timezone.utc).isoformat()
    with args.raw.open("rb") as raw:
        result["sourceSHA256After"] = hashlib.file_digest(raw, "sha256").hexdigest()
    if result["sourceSHA256After"] != result["sourceSHA256"]:
        raise ValueError("RAW source identity changed")
    save()
    if frame_folder and session.get("electron"):
        collection = {key: session[key] for key in ("electron", "windowBundle", "browserBinarySHA256")}
        collection.update(recorderSHA256=recorder_hash, settleSeconds=args.settle, measuredInputs=args.samples, warmupInputs=args.warmup,
                          windowLevel="kCGDesktopIconWindowLevel + 1", activationPolicy="prohibited")
        (frame_folder / "collection.json").write_text(json.dumps(collection, indent=2) + "\n")
        shutil.copyfile(args.output, frame_folder / "observations.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="cmd", required=True)
    boot = commands.add_parser("start")
    boot.add_argument(
        "--site", type=Path, default=ROOT / "output/lightflow-research/site"
    )
    boot.add_argument("--chrome", type=Path)
    boot.add_argument("--background-host", type=Path, help="Nonactivating macOS host directory prepared by lightflow-window/prepare.py")
    boot.add_argument("--raw", type=Path, required=True)
    boot.add_argument("--width", type=int, default=1700)
    boot.add_argument("--height", type=int, default=1060)
    boot.add_argument(
        "--visible",
        action="store_true",
        help="open a separate Chrome window for ScreenCaptureKit capture",
    )
    for cmd in [boot, commands.add_parser("inspect"), commands.add_parser("close")]:
        cmd.add_argument("--session", type=Path, required=True)
    change = commands.add_parser("change")
    change.add_argument("--session", type=Path, required=True)
    change.add_argument("--label", required=True)
    change.add_argument("--value", required=True)
    run = commands.add_parser("capture")
    run.add_argument("--session", type=Path, required=True)
    run.add_argument("--binary", type=Path, required=True)
    run.add_argument("--raw", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--frames",type=Path,help="Retain the sampled screen pixels and committed input markers")
    run.add_argument("--operations", nargs="+", choices=CASES)
    framing = run.add_mutually_exclusive_group()
    framing.add_argument("--photo-width", type=int, default=2368)
    framing.add_argument("--source-roi", type=int, nargs=4, metavar=("X", "Y", "W", "H"),
                         help="Use a noncentral source-pixel ROI at 1:1 on the pinned Sony RAW (Exposure only)")
    run.add_argument("--samples", type=int, help="Measured changes, default 10 for FIT or 30 for source ROI")
    run.add_argument("--warmup", type=int, help="Unscored changes before A/B calibration, default 0 for FIT or 5 for source ROI")
    run.add_argument("--settle", type=float, default=0.8)
    compositor = commands.add_parser("compositor")
    compositor.add_argument("--session", type=Path, required=True)
    compositor.add_argument("--raw", type=Path, required=True)
    compositor.add_argument("--output", type=Path, required=True)
    compositor.add_argument("--operations", nargs="+", choices=CASES)
    compositor.add_argument("--photo-width", type=int, default=2368)
    compositor.add_argument("--photo-height", type=int, default=1579)
    compositor.add_argument("--samples", type=int, default=10)
    compositor.add_argument("--settle", type=float, default=0.8)
    compositor.add_argument("--transport-width", type=int, default=960)
    from lightflow_gestures import CASES as gesture_cases, capture as capture_gestures
    gestures = commands.add_parser("gestures")
    gestures.add_argument("--session", type=Path, required=True)
    gestures.add_argument("--raw", type=Path, required=True)
    gestures.add_argument("--output", type=Path, required=True)
    gestures.add_argument("--operations", nargs="+", choices=gesture_cases)
    gestures.add_argument("--samples", type=int, default=10)
    from lightflow_panel_tools import CASES as panel_cases, capture as capture_panel_tools
    panel = commands.add_parser("panel-tools")
    panel.add_argument("--session", type=Path, required=True)
    panel.add_argument("--raw", type=Path, required=True)
    panel.add_argument("--output", type=Path, required=True)
    panel.add_argument("--operations", nargs="+", choices=panel_cases)
    panel.add_argument("--samples", type=int, default=10)
    from lightflow_photo_tools import CASES as photo_cases, capture as capture_photo_tools
    photo = commands.add_parser("photo-tools")
    photo.add_argument("--session", type=Path, required=True)
    photo.add_argument("--raw", type=Path, required=True)
    photo.add_argument("--output", type=Path, required=True)
    photo.add_argument("--operations", nargs="+", choices=photo_cases)
    photo.add_argument("--samples", type=int, default=10)
    jpeg = commands.add_parser("rendered-wb")
    jpeg.add_argument("--session", type=Path, required=True)
    jpeg.add_argument("--raw", type=Path, required=True, help="Camera-rendered JPEG loaded by this session")
    jpeg.add_argument("--parent-raw", type=Path, required=True, help="Unmodified RAW containing these exact JPEG bytes")
    jpeg.add_argument("--output", type=Path, required=True)
    jpeg.add_argument("--samples", type=int, default=10)
    args = parser.parse_args()
    if args.cmd == "start":
        start(args)
        return
    session = json.loads(args.session.read_text())
    cdp = DevTools(session["tab"])
    if args.cmd == "compositor":
        capture_compositor(cdp, session, args)
    elif args.cmd == "gestures":
        capture_gestures(cdp, session, args, (select_control, commit_control, compositor_geometry, set_zoom, view_geometry))
    elif args.cmd == "panel-tools":
        capture_panel_tools(cdp, session, args, (DevTools, commit_control, compositor_geometry, set_zoom, view_geometry))
    elif args.cmd == "photo-tools":
        capture_photo_tools(cdp, session, args, (compositor_geometry, set_zoom, view_geometry, commit_control))
    elif args.cmd == "rendered-wb":
        from lightflow_jpeg_wb import capture_rendered_wb
        capture_rendered_wb(cdp, session, args, (select_control, commit_control, compositor_geometry, set_zoom, view_geometry))
    elif args.cmd == "capture":
        if args.samples is None:
            args.samples = 30 if args.source_roi else 10
        if args.warmup is None:
            args.warmup = 5 if args.source_roi else 0
        capture(cdp, session, args)
    elif args.cmd == "inspect":
        print(json.dumps(view_geometry(cdp), indent=2))
    elif args.cmd == "close":
        try:
            cdp.call("Browser.close")
        except websocket.WebSocketConnectionClosedException:
            pass
    else:
        previous = prepare(cdp, args.label, args.value)
        timing = commit(cdp)
        print(
            json.dumps(
                {
                    "label": args.label,
                    "value": args.value,
                    "previous": previous,
                    **timing,
                }
            )
        )


if __name__ == "__main__":
    main()
