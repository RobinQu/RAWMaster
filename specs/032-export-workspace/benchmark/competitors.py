#!/usr/bin/env python3
"""Run local release AlcedoStudio and an unmodified LightFlow snapshot on shared inputs."""
import argparse
from contextlib import contextmanager
from functools import partial
import hashlib
import io
import json
import math
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import urlopen
import zipfile

from PIL import Image, ImageCms, ImageDraw, ImageOps, ImageStat, JpegImagePlugin
import websocket

REPO = Path(__file__).resolve().parents[3]
JPEG = "jpeg-source"
RAW = "raw-source"
TRIALS = [(JPEG, 1), (JPEG, 20), (JPEG, 200), (RAW, 1), (RAW, 20)]
LIGHTFLOW_BUILD = "20261111155800-2d41ab1"
LIGHTFLOW_EXPORT_ASSETS = {
    "assets/index-zP4kU_H7.js": "0ca67eaec7788ac79439d6700c6791cff845bbb8938d6b2d295831871afc678e",
    "assets/worker-PmnZFHwu.js": "1c1203c0e3d6e4329d9ac2892b61fc4e3fca4e805c73b919ab17f72cf240d2fc",
    "assets/codecWorker-Dt1VOinP.js": "6ea14c9f2b5c8c5141597d9e28ea2fff807d50816c7c9c777706b43f895fbc4e",
    f"_b/{LIGHTFLOW_BUILD}/rust/web/lightflow_host_wasm.js": "abfbf794fd93d16630a9a4427b73ae1ee0d6a370f5ecd496a00c0ea261aee055",
    f"_b/{LIGHTFLOW_BUILD}/rust/web/lightflow_host_wasm_bg.wasm": "bf00cd83e6ef03014878f83dc235dcf46f7e408c052cef48240a764268227674",
    f"_b/{LIGHTFLOW_BUILD}/rust/web-mt/lightflow_host_wasm_mt.js": "4ba8bdddca77d75c12d57f9822cfa854dd602c696c98ba0375f9ff9b8d89461d",
    f"_b/{LIGHTFLOW_BUILD}/rust/web-mt/lightflow_host_wasm_mt_bg.wasm": "99cd37e2b3a3d61d35ef9e9ccebec597043e9cc5b52fa9525b2b72ec42d90391",
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fixtures(root, raw):
    """Use identical on-disk files with distinct hashes for all tools."""
    photos = list((REPO / "Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases").glob("*/files/asset0000.jpg"))
    photos = sorted(photos)[:12]
    if not photos:
        raise RuntimeError("Missing repository JPEG fixtures")
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    for kind in [JPEG, RAW]:
        (root / kind).mkdir(exist_ok=True)
    bases = [ImageOps.fit(Image.open(p).convert("RGB"), (4000, 2666)) for p in photos]
    for i in range(200):
        path = root / JPEG / f"J{i:03}.jpg"
        if not path.exists():
            photo = bases[i % len(bases)].copy()
            ImageDraw.Draw(photo).rectangle((2500, 1900, 2510, 1910), fill=(i, i * 7 % 256, 130))
            photo.save(path, quality=92, icc_profile=profile, comment=f"export benchmark fixture {i}")
    if raw:
        source = raw.read_bytes()
        for i in range(20):
            path = root / RAW / f"R{i:03}.dng"
            if not path.exists():
                path.write_bytes(source + i.to_bytes(2, "little"))
    summary = {kind: {p.name: digest(p) for p in sorted((root / kind).iterdir())} for kind in [JPEG, RAW]}
    (root / "inputs.json").write_text(json.dumps(summary, indent=2) + "\n")


def files_in(folder, kind):
    return sorted((folder / kind).glob("*.jpg" if kind == JPEG else "*.dng"))


def wait(check, timeout=600):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        val = check()
        if val:
            return val
        time.sleep(0.025)
    raise TimeoutError("The operation did not finish before the benchmark timeout")


def photo_info(stream):
    with Image.open(stream) as img:
        img.load()
        icc = img.info.get("icc_profile")
        return (img.width, img.height, bool(icc))


def read_output(folder, expected):
    images = list(folder.glob("*.jpg")) + list(folder.glob("*.jpeg"))
    archives = list(folder.glob("*.zip"))
    if archives:
        if len(archives) != 1 or images:
            raise RuntimeError("Unexpected transfer layout")
        with zipfile.ZipFile(archives[0]) as bundle:
            names = bundle.namelist()
            if len(names) != expected or bundle.testzip():
                raise RuntimeError(f"Incomplete ZIP {len(names)}/{expected}")
            photos = [photo_info(bundle.open(name)) for name in names]
        return {"dimensionsAndICC": sorted(set(photos)), "bytes": archives[0].stat().st_size, "container": "ZIP"}
    if len(images) != expected:
        raise RuntimeError(f"Incomplete directory {len(images)}/{expected}: {folder}")
    return {"dimensionsAndICC": sorted({photo_info(p) for p in images}),
            "bytes": sum(p.stat().st_size for p in images), "container": "files"}


@contextmanager
def observe(folder, pid, final_file=None):
    """Read actual directory milestones and sample RSS for a process tree."""
    facts = {"first": None, "rssKiB": None}
    stopped = threading.Event()
    start = time.monotonic()

    def watch():
        next_sample = 0
        while not stopped.is_set():
            now = time.monotonic()
            if facts["first"] is None:
                if final_file is None:
                    if any(p.suffix.lower() in (".jpg", ".jpeg", ".zip") for p in folder.iterdir()):
                        facts["first"] = now - start
                elif path := final_file(folder):
                    facts["finalObservedUptimeNS"] = time.monotonic_ns()
                    facts["path"] = path
                    facts["first"] = now - start
            if pid and now >= next_sample:
                next_sample = now + 0.25
                items = []
                output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
                for line in output.splitlines():
                    items.append(tuple(map(int, line.split())))
                family = {pid}
                while True:
                    kids = {p for p, parent, _ in items if parent in family}
                    if kids.issubset(family):
                        break
                    family |= kids
                rss = sum(value for process, _, value in items if process in family)
                facts["rssKiB"] = max(facts["rssKiB"] or 0, rss)
            stopped.wait(0.015)

    sampler = threading.Thread(target=watch, daemon=True)
    sampler.start()
    try:
        yield start, facts
    finally:
        stopped.set()
        sampler.join()


def alcedo(args):
    work = args.root / "alcedo"
    prefix = [str(args.alcedo), "--session-dir", str(work / "sessions"),
              "--session", "export-benchmark", "--timeout", "600000", "--json"]

    def call(method, params=None):
        result = subprocess.run(prefix + ["call", method, json.dumps(params or {})], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        return payload.get("result", payload)

    project = work / "project"
    for path in (project, work / "sessions", work / "config"):
        path.mkdir(parents=True, exist_ok=True)
    try:
        call("export.options")
    except RuntimeError:
        subprocess.run(prefix + ["session", "start", "--headless", "--create", f"{project},ExportBench",
                                 "--editor-backend", "metal", "--viewport", "1024x768", "--settings-dir",
                                 str(work / "config"), "--log-file", str(work / "host.log")], check=True)

    def listing():
        rows = []
        for offset in range(0, 250, 100):
            rows.extend(call("library.list", {"limit": 100, "offset": offset})["items"])
        return {row["file_name"]: row["element_id"] for row in rows}

    selected = listing()
    requested = [p for kind in [JPEG, RAW] for p in files_in(args.root, kind)]
    missing = [str(path) for path in requested if path.name not in selected]
    if missing:
        task = call("library.import", {"paths": missing})
        call("tasks.wait", {"task_id": task["task_id"], "timeout_ms": 600000})
        selected = listing()
    session = json.loads((work / "sessions/export-benchmark.json").read_text())
    pid = session.get("process_id", session.get("pid"))

    def trial(kind, count, folder):
        ids = [selected.get(path.name) for path in files_in(args.root, kind)[:count]]
        if len(ids) != count or None in ids:
            raise RuntimeError("Selected input format was not imported")
        recipe = {"element_ids": ids, "out_dir": str(folder), "format": "JPEG", "bit_depth": 8, "quality": 90,
                  "resize_mode": "long_edge", "long_edge": 2048, "include_metadata": False,
                  "embed_icc_profile": True, "include_gps": False}
        with observe(folder, pid) as (start, watched):
            task = call("export.run", recipe)
            call("tasks.wait", {"task_id": task["task_id"], "timeout_ms": 600000})
            finished = time.monotonic() - start
        return {"seconds": finished, "firstPhotoSeconds": watched["first"] or finished, "rssKiB": watched["rssKiB"],
                **read_output(folder, count)}
    return run_trials(args, "alcedo", trial)


class CDP:
    def __init__(self, endpoint):
        self.socket = websocket.create_connection(endpoint, suppress_origin=True, timeout=620)
        self.serial = 0

    def send(self, name, options=None):
        self.serial += 1
        self.socket.send(json.dumps({"id": self.serial, "method": name, "params": options or {}}))
        while True:
            answer = json.loads(self.socket.recv())
            if answer.get("id") == self.serial:
                if "error" in answer:
                    raise RuntimeError(answer["error"])
                return answer["result"]

    def evaluate(self, code):
        result = self.send("Runtime.evaluate", {"expression": code, "returnByValue": True, "awaitPromise": True})
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"])
        return result["result"].get("value")


def finalized_jpeg(folder):
    files = list(folder.iterdir())
    if len(files) != 1 or files[0].suffix.lower() not in (".jpg", ".jpeg"):
        return None
    path = files[0]
    try:
        with path.open("rb") as stream:
            if stream.seek(0, 2) >= 4:
                stream.seek(-2, 2)
                if stream.read(2) == b"\xff\xd9":
                    return path
    except FileNotFoundError:
        pass  # Chromium can rename between directory enumeration and open.
    return None


def inspect_native_jpeg(path, expected_pixels):
    with Image.open(path) as image:
        icc = image.info.get("icc_profile")
        if (image.format != "JPEG" or list(image.size) != expected_pixels or image.mode != "RGB" or image.bits != 8
                or JpegImagePlugin.get_sampling(image) != 2 or image.info.get("progressive") or not icc
                or not image.quantization):
            raise ValueError("Expected an original-size 8-bit baseline RGB JPEG with embedded ICC and 4:2:0 sampling")
        profile = ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(icc))).strip()
        if "srgb" not in profile.casefold():
            raise ValueError(f"Unexpected JPEG ICC description {profile}")
        image.load()
        witness = image.resize((96, 64), Image.Resampling.BOX)
        tables = {}
        for index, values in sorted(image.quantization.items()):
            encoded = json.dumps(values, separators=(",", ":")).encode("ascii")
            tables[str(index)] = {"entries": len(values), "min": min(values), "max": max(values),
                                  "sha256": hashlib.sha256(encoded).hexdigest()}
        return {"name": path.name, "sha256": digest(path), "bytes": path.stat().st_size, "dimensions": list(image.size),
                "format": "JPEG", "bitsPerComponent": image.bits, "subsampling": "4:2:0", "progressive": False,
                "sofComponents": image.layer, "dqt": tables, "iccName": profile, "iccBytes": len(icc),
                "iccSHA256": hashlib.sha256(icc).hexdigest(), "witnessRGBSHA256": hashlib.sha256(witness.tobytes()).hexdigest(),
                "witnessMeanLuma": ImageStat.Stat(witness.convert("L")).mean[0]}


def set_lightflow_exposure(cdp, photo_id, exposure):
    ev = cdp.evaluate
    ev("window.__lightflow.setWorkspace('develop');"
       "window.__lightflow.stores.develop.set({target:{kind:'base'}});"
       "window.__lightflow.develop.showSection('basic')")
    label = wait(lambda: ev("""(() => {
        const input = document.querySelector('lightflow-slider[data-id="base.exposure"] input');
        if (!input || !input.getBoundingClientRect().width) return null;
        input.scrollIntoView({block:'nearest'});
        input.focus(); input.select();
        return input.getAttribute('aria-label');
    })()"""), 20)
    cdp.send("Input.insertText", {"text": str(exposure)})
    for action in ("keyDown", "keyUp"):
        cdp.send("Input.dispatchKeyEvent", {"type": action, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13})
    read = f"window.__lightflow.editOf({json.dumps(photo_id)}).base.exposure"
    wait(lambda: ev(read) == exposure, 12)
    return {"control": label, "actualEV": ev(read)}


def run_lightflow_native_raw(args, work, cdp, origin, source_sha, browser_gpu):
    ev = cdp.evaluate
    result = {"schemaVersion": 1, "protocol": "single-native-jpeg-delivery-v1", "application": "LightFlow",
              "build": LIGHTFLOW_BUILD, "assetSHA256": LIGHTFLOW_EXPORT_ASSETS, "sourceSHA256": source_sha,
              "sourcePixels": args.output_pixels, "browser": cdp.send("Browser.getVersion")["product"],
              "browserBinarySHA256": digest(args.chrome), "browserGPU": browser_gpu, "os": platform.mac_ver()[0],
              "osBuild": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
              "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
              "boundary": "Monotonic host time immediately before stock Export button dispatch to first 15 ms poll with one final JPEG, an EOI marker and no temporary download file. Queue and full decode verify the file after timing.",
              "requestedWarmups": args.warmup, "requestedSamples": args.repeats, "warmups": [], "samples": [], "complete": False}

    def save():
        report = work / "results.json"
        pending = work / "results.tmp"
        pending.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
        pending.replace(report)

    def settings(exposure):
        ev("window.__lightflow.setWorkspace('export')")
        wait(lambda: ev("!!document.querySelector('[data-id=export-now]')"), 45)
        expected = {"file": {"format": "jpeg", "bitDepth": 8, "quality": args.quality, "chroma": "4:2:0",
                             "progressive": False, "progressiveLarge": False, "fitLimits": False},
                    "sizing": {"mode": "original", "allowEnlarge": False},
                    "color": {"space": "srgb", "hdr": "off", "embedIcc": True},
                    "sharpening": {"on": False}, "watermark": {"on": False},
                    "metadata": {"policy": "none", "keywords": False, "embedEdit": False},
                    "location": {"target": "downloads", "zip": "never", "useSubfolder": False}}
        form = ev(f"""(() => {{
            const api=window.__lightflowExport;
            api.applyPreset('builtin.jpeg-full');
            const s=api.form.get().settings;
            const expected={json.dumps(expected)};
            const overrides=Object.fromEntries(Object.entries(expected).map(([group, values])=>[group,{{...s[group],...values}}]));
            api.setSettings({{...s,...overrides}});
            return api.form.get().settings;
        }})()""")
        if any(form[group].get(key) != value for group, subset in expected.items() for key, value in subset.items()):
            raise ValueError("LightFlow did not accept the native JPEG export settings")
        if ev(exposure_read) != exposure:
            raise ValueError("LightFlow did not preserve the committed exposure in its export workspace")
        return form

    def trial(label, exposure):
        actual_exposure = ev(exposure_read)
        if actual_exposure != exposure:
            raise ValueError("The committed exposure changed before the export")
        folder = work / label
        folder.mkdir()
        cdp.send("Browser.setDownloadBehavior", {"behavior": "allow", "downloadPath": str(folder)})
        previous = ev("window.__lightflowExport.queue.get().jobs.length")
        with observe(folder, None, finalized_jpeg) as (_, watched):
            start = time.monotonic_ns()
            ev("document.querySelector('[data-id=export-now]').click()")

            def job_done():
                rows = ev(f"""window.__lightflowExport.queue.get().jobs.slice({previous}).map(
                    x=>({{status:x.status,error:x.error,photoId:x.photoId,outName:x.outName,bytes:x.bytes,
                        width:x.width,height:x.height,added:x.added,started:x.started,finished:x.finished,via:x.via??null}}))""")
                if len(rows) > 1:
                    raise ValueError("The stock export button submitted more than one file")
                return rows[0] if rows and rows[0]["status"] in ("done", "failed", "cancelled", "interrupted") else None

            job = wait(job_done)
            if job["status"] != "done" or job["photoId"] != photo_id:
                raise ValueError(f"LightFlow did not complete the selected RAW job {job}")
            finish = wait(lambda: watched.get("finalObservedUptimeNS") if "path" in watched else None, 20)
        file = inspect_native_jpeg(watched["path"], args.output_pixels)
        if finish <= start or file["name"] != job["outName"] or file["bytes"] != job["bytes"]:
            raise ValueError("Downloaded JPEG differs from the completed queue record")
        return {"label": label, "exposureEV": actual_exposure, "submitUptimeNS": start, "finalWriteObservedUptimeNS": finish,
                "elapsedMs": (finish - start) / 1e6, "job": job, "file": file}

    try:
        result["availableWebGPUAdapter"] = ev("""(async () => {
            const adapter = await navigator.gpu?.requestAdapter();
            if (!adapter) return null;
            return Object.fromEntries(['vendor','architecture','device','description','isFallbackAdapter'].map(k=>[k,adapter.info[k]]));
        })()""")
        adapter = result["availableWebGPUAdapter"]
        vendor = " ".join(str(adapter.get(key, "")).lower() for key in ("vendor", "architecture", "device", "description")) if adapter else ""
        if not adapter or adapter.get("isFallbackAdapter") is not False or any(name in vendor for name in ("swiftshader", "llvmpipe", "software")):
            raise ValueError("A physical WebGPU adapter is required for the LightFlow baseline")
        ev("window.__lightflow.importUrls([" + json.dumps(origin + "/spec043/source.ARW") + "])")
        photo = wait(lambda: ev("""(() => {
            const catalog=window.__lightflow.stores.catalog.get();
            const p=catalog.photos[catalog.order[0]];
            return p && catalog.order.length===1 && (p.info?.width || p.error)
                ? {id:catalog.order[0],kind:p.kind,name:p.name,info:p.info,error:p.error} : null;
        })()"""), 180)
        if (photo.get("error") or photo["kind"] != "raw" or photo["name"] != "source.ARW"
                or [photo["info"]["width"], photo["info"]["height"]] != args.output_pixels or photo["info"]["orientation"] != 1):
            raise ValueError("Expected one unrotated RAW with the declared native output size")
        photo_id = photo["id"]
        selected = json.dumps(photo_id)
        ev(f"window.__lightflow.setActive({selected});window.__lightflow.select([{selected}])")
        exposure_read = f"window.__lightflow.editOf({selected}).base.exposure"
        result["sourceOrientation"] = photo["info"]["orientation"]
        result["initialExposureEV"] = ev(exposure_read)
        if result["initialExposureEV"] != 0:
            raise ValueError("A clean default exposure is required in the isolated catalog")
        result["exposure"] = (set_lightflow_exposure(cdp, photo_id, args.exposure) if args.exposure
                              else {"control": None, "actualEV": result["initialExposureEV"]})
        result["settings"] = settings(args.exposure)
        result["firstExport"] = trial("first-export", args.exposure)
        save()
        for group, count in (("warmups", args.warmup), ("samples", args.repeats)):
            for index in range(count):
                result[group].append(trial(f"{group}-{index:02d}", args.exposure))
                save()
        if args.exposure:
            result["neutralExposure"] = set_lightflow_exposure(cdp, photo_id, 0.0)
            if settings(0.0) != result["settings"]:
                raise ValueError("Neutral witness export output settings changed")
            neutral = trial("neutral-witness", 0.0)["file"]
            edited = [row["file"] for row in [result["firstExport"], *result["warmups"], *result["samples"]]]
            minimum_delta = min(file["witnessMeanLuma"] - neutral["witnessMeanLuma"] for file in edited)
            if minimum_delta <= 0 or any(file["witnessRGBSHA256"] == neutral["witnessRGBSHA256"] for file in edited):
                raise ValueError("The committed exposure did not brighten the exported JPEG pixels")
            result["neutralWitness"] = {"file": neutral, "minimumEditedMinusNeutralMeanLuma": minimum_delta}
        result["sourceSHA256After"] = digest(args.raw)
        if result["sourceSHA256After"] != source_sha:
            raise ValueError("Source RAW changed during benchmark")
        elapsed = sorted(row["elapsedMs"] for row in result["samples"])
        result["statistics"] = {"n": len(elapsed), "p50Ms": statistics.median(elapsed),
                                "p95Ms": elapsed[math.ceil(.95 * len(elapsed)) - 1]}
        result["complete"] = True
        return result
    except (OSError, RuntimeError, ValueError) as error:
        result["error"] = str(error)
        raise
    finally:
        save()


def lightflow(args):
    single_raw = getattr(args, "action", "lightflow") == "lightflow-native-raw"
    if single_raw:
        source_sha = digest(args.raw)
        for relative, expected in LIGHTFLOW_EXPORT_ASSETS.items():
            path = args.site / relative
            if not path.is_file() or digest(path) != expected:
                raise ValueError(f"Expected pinned LightFlow {LIGHTFLOW_BUILD} asset {relative}")
    work = args.root / ("lightflow-native-raw" if single_raw else "lightflow")
    work.mkdir(exist_ok=not single_raw)

    class Handler(SimpleHTTPRequestHandler):
        def translate_path(self, path):
            if single_raw and urlsplit(path).path == "/spec043/source.ARW":
                return str(args.raw)
            if not single_raw and any(path.startswith("/" + kind + "/") for kind in [JPEG, RAW]):
                return str(args.root / path.lstrip("/"))
            return super().translate_path(path)

        def end_headers(self):
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Content-Security-Policy", "default-src 'self'; connect-src 'self' blob: data:; "
                             "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; "
                             "img-src 'self' blob: data:; worker-src 'self' blob:; object-src 'none'")
            super().end_headers()

        def log_message(self, *args):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=args.site)) as server, (work / "chrome.log").open("w") as log:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        origin = f"http://127.0.0.1:{server.server_port}"
        profile = work / f"profile-{time.time_ns()}"
        command = [str(args.chrome), "--disable-background-networking", "--enable-gpu", "--no-first-run",
                   "--remote-debugging-port=0", f"--user-data-dir={profile}"]
        if single_raw:
            command.append("--window-size=1600,1000")
        chrome = subprocess.Popen([*command, origin], stdout=log, stderr=log)
        try:
            portfile = profile / "DevToolsActivePort"
            wait(portfile.exists, 30)
            port = portfile.read_text().splitlines()[0]
            endpoint = wait(lambda: next((tab["webSocketDebuggerUrl"]
                for tab in json.load(urlopen(f"http://127.0.0.1:{port}/json/list"))
                if tab["url"].startswith(origin)), None), 30)
            cdp = CDP(endpoint)
            ev = cdp.evaluate
            def app_ready():
                try:
                    return ev("!!window.__lightflow?.importUrls && !!window.__lightflowExport")
                except RuntimeError as error:
                    if "execution context" not in str(error):
                        raise
                    return False

            wait(app_ready, 40)
            if single_raw:
                gpu = {"status": "unavailable"}
                browser = None
                try:
                    with urlopen(f"http://127.0.0.1:{port}/json/version", timeout=5) as info:
                        browser = CDP(json.load(info)["webSocketDebuggerUrl"])
                    gpu = {"status": "observed", "devices": browser.send("SystemInfo.getInfo")["gpu"]["devices"]}
                except (OSError, RuntimeError, KeyError, websocket.WebSocketException) as error:
                    gpu["reason"] = type(error).__name__
                finally:
                    if browser:
                        browser.socket.close()
                return run_lightflow_native_raw(args, work, cdp, origin, source_sha, gpu)
            urls = [f"{origin}/{kind}/{p.name}" for kind in [JPEG, RAW] for p in files_in(args.root, kind)]
            for offset in range(0, len(urls), 20):
                ev("window.__lightflow.importUrls(" + json.dumps(urls[offset:offset+20]) + ")")
                wait(lambda: ev("window.__lightflow.stores.catalog.get().order.length") == min(offset + 20, len(urls)), 180)
            photo_index = ev("""(() => {
                const catalog = window.__lightflow.stores.catalog.get();
                return catalog.order.map(id => [id, catalog.photos[id].originalName || catalog.photos[id].name]);
            })()""")
            index = {name: photo for photo, name in photo_index}
            ev(f"window.__lightflow.setActive({json.dumps(photo_index[0][0])});window.__lightflow.setWorkspace('export')")
            wait(lambda: ev("!!document.querySelector('[data-id=export-now]')"), 45)
            ev("""(() => {
                const api=window.__lightflowExport;
                api.applyPreset('builtin.web-2048');
                const s=api.form.get().settings;
                api.setSettings({...s,file:{...s.file,quality:90,progressive:false},metadata:{...s.metadata,policy:'none',keywords:false,embedEdit:false}});
            })()""")
            (work / "settings.json").write_text(json.dumps(ev("window.__lightflowExport.form.get().settings"), indent=2))
            def trial(kind, count, folder):
                ids = [index.get(p.name) for p in files_in(args.root, kind)[:count]]
                if len(ids) != count or None in ids:
                    raise RuntimeError(f"Missing browser input {kind} {count}: {list(index)[:3]}")
                cdp.send("Browser.setDownloadBehavior", {"behavior": "allow", "downloadPath": str(folder)})
                ev("window.__lightflow.select(" + json.dumps(ids) + ")")
                previous = ev("window.__lightflowExport.queue.get().jobs.length")
                with observe(folder, chrome.pid) as (start, watched):
                    ev("document.querySelector('[data-id=export-now]').click()")
                    def jobs():
                        rows = ev(f"""window.__lightflowExport.queue.get().jobs.slice({previous}).map(
                            x=>({{status:x.status,error:x.error,added:x.added,finished:x.finished,via:x.via}}))""")
                        return rows if len(rows) == count and all(row["status"] in ("done", "failed") for row in rows) else None
                    rows = wait(jobs)
                    if any(row["status"] != "done" for row in rows):
                        raise RuntimeError(rows[:3])
                    wait(lambda: len(list(folder.glob("*.zip"))) == 1 or
                         len(list(folder.glob("*.jpg"))) + len(list(folder.glob("*.jpeg"))) == count)
                    finished = time.monotonic() - start
                first_job = (min(row["finished"] for row in rows)-min(row["added"] for row in rows))/1000
                return {"seconds": finished, "firstPhotoSeconds": watched["first"] or finished,
                        "firstEncodedSeconds": first_job, "rssKiB": watched["rssKiB"],
                        "backends": sorted({row["via"] for row in rows if row.get("via")}), **read_output(folder, count)}
            return run_trials(args, "lightflow", trial)
        finally:
            chrome.terminate()
            chrome.wait(timeout=25)
            server.shutdown()


def run_trials(args, name, trial):
    directory = args.root / name
    result = {}
    for kind, count in TRIALS:
        key = f"{kind}/{count}"
        if kind == RAW and not files_in(args.root, kind):
            continue
        keydir = directory / f"{kind}-{count}-{time.time_ns()}"
        keydir.mkdir(parents=True)
        result[key] = []
        for index in range(-1, args.repeats):
            folder = keydir / f"run-{index}"
            folder.mkdir()
            try:
                row = trial(kind, count, folder)
            except (RuntimeError, TimeoutError) as e:
                result[key].append({"error": str(e)})
                break
            print(name, key, index, row, flush=True)
            if index >= 0:
                result[key].append(row)
        (directory / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("fixtures", "alcedo", "lightflow", "lightflow-native-raw"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--alcedo", type=Path, default=Path("/Applications/AlcedoStudio.app/Contents/MacOS/alcedo-cli"))
    parser.add_argument("--site", type=Path)
    parser.add_argument("--chrome", type=Path)
    parser.add_argument("--repeats", type=int, help="Measured runs (3 for batch benchmarks, 30 for lightflow-native-raw)")
    parser.add_argument("--warmup", type=int, default=5, help="Unscored lightflow-native-raw exports after its first export")
    parser.add_argument("--quality", type=int, default=95, help="JPEG quality for lightflow-native-raw")
    parser.add_argument("--exposure", type=float, choices=(0.0, 0.5), default=0.5, help="LightFlow Develop exposure for the single RAW")
    parser.add_argument("--output-pixels", type=int, nargs=2, default=[9504, 6336], metavar=("WIDTH", "HEIGHT"),
                        help="Expected original-size JPEG dimensions for lightflow-native-raw")
    args = parser.parse_args()
    if args.action == "lightflow-native-raw":
        if not args.raw or not args.raw.is_file() or args.raw.suffix.lower() != ".arw":
            parser.error("lightflow-native-raw requires one existing --raw .ARW file")
        args.raw = args.raw.resolve()
        args.repeats = 30 if args.repeats is None else args.repeats
        if args.repeats < 1 or args.warmup < 0 or not 1 <= args.quality <= 100 or min(args.output_pixels) < 1:
            parser.error("Use positive sample count and dimensions, nonnegative warmups, and JPEG quality 1–100")
    elif args.repeats is None:
        args.repeats = 3
    args.root = args.root.resolve()
    args.root.mkdir(parents=True, exist_ok=True)
    if args.action == "fixtures":
        fixtures(args.root, args.raw)
    elif args.action == "alcedo":
        alcedo(args)
    else:
        if not args.site or not args.chrome:
            parser.error("LightFlow requires a local --site snapshot and --chrome binary.")
        lightflow(args)


if __name__ == "__main__":
    main()
