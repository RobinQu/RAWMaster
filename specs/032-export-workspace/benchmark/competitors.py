#!/usr/bin/env python3
"""Run local release AlcedoStudio and an unmodified LightFlow snapshot on shared inputs."""
import argparse
from contextlib import contextmanager
from functools import partial
import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import urlopen
import zipfile

from PIL import Image, ImageCms, ImageDraw, ImageOps
import websocket

REPO = Path(__file__).resolve().parents[3]
JPEG = "jpeg-source"
RAW = "raw-source"
TRIALS = [(JPEG, 1), (JPEG, 20), (JPEG, 200), (RAW, 1), (RAW, 20)]


def digest(path):
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()


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
def observe(folder, pid):
    """Read actual directory milestones and sample RSS for a process tree."""
    facts = {"first": None, "rssKiB": None}
    stopped = threading.Event()
    start = time.monotonic()

    def watch():
        next_sample = 0
        while not stopped.is_set():
            now = time.monotonic()
            if facts["first"] is None and any(p.suffix.lower() in (".jpg", ".jpeg", ".zip") for p in folder.iterdir()):
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


def lightflow(args):
    work = args.root / "lightflow"
    work.mkdir(exist_ok=True)

    class Handler(SimpleHTTPRequestHandler):
        def translate_path(self, path):
            if any(path.startswith("/" + kind + "/") for kind in [JPEG, RAW]):
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
        chrome = subprocess.Popen([str(args.chrome), "--disable-background-networking", "--enable-gpu", "--no-first-run",
                                   "--remote-debugging-port=0", f"--user-data-dir={profile}", origin],
                                  stdout=log, stderr=log)
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
    parser.add_argument("action", choices=("fixtures", "alcedo", "lightflow"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--alcedo", type=Path, default=Path("/Applications/AlcedoStudio.app/Contents/MacOS/alcedo-cli"))
    parser.add_argument("--site", type=Path)
    parser.add_argument("--chrome", type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
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
