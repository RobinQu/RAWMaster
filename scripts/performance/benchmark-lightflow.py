#!/usr/bin/env python3
"""Benchmark a pinned local LightFlow release on one RAW with an isolated headless Chrome."""

import argparse
import hashlib
import json
import mimetypes
import platform
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PINNED = {
    "lightflow_host_wasm.js": "abfbf794fd93d16630a9a4427b73ae1ee0d6a370f5ecd496a00c0ea261aee055",
    "lightflow_host_wasm_bg.wasm": "bf00cd83e6ef03014878f83dc235dcf46f7e408c052cef48240a764268227674",
}


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--engine",
        type=Path,
        default=ROOT / "output/lightflow-research/site/_b/20261111155800-2d41ab1/rust/web",
    )
    parser.add_argument(
        "--chrome", type=Path, default=Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    )
    parser.add_argument(
        "--operation", action="append", default=[], help="restrict to this feature ID; repeatable"
    )
    parser.add_argument("--samples", type=int, default=20, choices=range(2, 101), metavar="2–100")
    parser.add_argument(
        "--size", type=int, default=2400, help="exact long side of the rendered image in pixels"
    )
    parser.add_argument("--timeout", type=float, default=1800)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--display-readback", action="store_true",
                        help="Time a changed viewer edit to the complete 2400 × 1600 sRGB RGBA8 CPU buffer")
    mode.add_argument("--panel-readback", action="store_true",
                      help="Measure the paired panel-control recipes at the full sRGB display readback boundary")
    mode.add_argument("--paired-photo-operators", action="store_true",
                      help="Measure the v2 global, local, LUT and overlay recipes with stock viewer settlement")
    parser.add_argument("--panel-schedule", action="store_true",
                        help="Track each stock viewerTick-requested frame through its released, idle state")
    mode.add_argument("--auto-analysis", action="store_true",
                      help="Time the stock Auto Tone and Auto White Balance actions on the worker's 384px source sample")
    mode.add_argument("--vectorscope", action="store_true",
                      help="Accumulate and read the stock 256 × 168 vectorscope for two resident RAW grades")
    mode.add_argument("--viewer-tools", action="store_true",
                      help="Time clipping, Option previews and sharpen-radius endpoints in the original Photo viewer")
    args = parser.parse_args()
    if args.panel_schedule and not args.panel_readback:
        parser.error("--panel-schedule requires --panel-readback")
    if not (64 <= args.size <= 8192) or args.output.exists():
        parser.error("choose a size of 64–8192 px and a new output file")
    resources = {name: args.engine / name for name in PINNED}
    for name, path in resources.items():
        if not path.is_file() or sha256(path) != PINNED[name]:
            parser.error(f"{name} must match the published build 2d41ab1")
    resources.update({"probe.mjs": HERE / "lightflow-probe.mjs", "fixture.raw": args.raw})
    if args.auto_analysis:
        resources["lightflow-analysis.mjs"] = HERE / "lightflow-analysis.mjs"
    if args.vectorscope:
        resources["lightflow-vectorscope.mjs"] = HERE / "lightflow-vectorscope.mjs"
    if args.viewer_tools:
        resources["lightflow-viewer-tools.mjs"] = HERE / "lightflow-viewer-tools.mjs"
    if args.panel_schedule or args.paired_photo_operators:
        resources["lightflow-panel-schedule.mjs"] = HERE / "lightflow-panel-schedule.mjs"
    if args.paired_photo_operators:
        resources["lightflow-paired-photo-operators.mjs"] = HERE / "lightflow-paired-photo-operators.mjs"
    if (args.display_readback or args.panel_readback or args.viewer_tools or args.paired_photo_operators) and args.size != 2400:
        parser.error("The paired display workload requires exactly 2400 × 1600 pixels")
    panel_file = HERE / "paired-panel-controls.json"
    extended_file = HERE / "paired-photo-operators-v2.json"
    extended = json.loads(extended_file.read_bytes()) if args.paired_photo_operators else None
    config = json.dumps({"samples": args.samples, "size": args.size, "operations": args.operation,
                         "displayReadback": args.display_readback or args.panel_readback or args.paired_photo_operators, "autoAnalysis": args.auto_analysis, "viewerTools": args.viewer_tools,
                         "panelControls": extended["controls"] if extended else json.loads(panel_file.read_bytes()) if args.panel_readback else None,
                         "extendedPhotoOperators": extended,"panelSchedule": args.panel_schedule or args.paired_photo_operators, "vectorscope": args.vectorscope}).encode()
    token = secrets.token_urlsafe(24)
    route = f"/{token}/"
    result = {}
    done = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def headers_for(self, kind, length):
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(length))
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'",
            )
            self.end_headers()

        def do_GET(self):
            name = urlsplit(self.path).path
            if not name.startswith(route):
                self.send_error(404)
                return
            name = name[len(route) :]
            if name in resources:
                path = resources[name]
                self.headers_for(
                    mimetypes.guess_type(path)[0] or "application/octet-stream", path.stat().st_size
                )
                with path.open("rb") as stream:
                    shutil.copyfileobj(stream, self.wfile)
            elif name in ("", "config.json"):
                body = (
                    config
                    if name
                    else b'<!doctype html><title>LightFlow RAW benchmark</title><script type="module" src="probe.mjs"></script>'
                )
                self.headers_for("application/json" if name else "text/html", len(body))
                self.wfile.write(body)
            else:
                self.send_error(404)

        def do_POST(self):
            if (
                self.path != route + "result"
                or not 0 < int(self.headers.get("Content-Length", 0)) <= 20_000_000
            ):
                self.send_error(400)
                return
            item = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if "progress" in item:
                print(item["progress"], flush=True)
            else:
                result.update(item)
            self.headers_for("text/plain", 0)
            if "progress" not in item:
                done.set()

    source_hash = sha256(args.raw)
    host_chip = (
        subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
        if sys.platform == "darwin"
        else platform.processor()
    )
    with (
        ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server,
        tempfile.TemporaryDirectory(prefix="lightflow-raw-") as profile,
    ):
        threading.Thread(target=server.serve_forever, daemon=True).start()
        with tempfile.TemporaryFile(mode="w+") as stderr:
            browser = subprocess.Popen(
                [
                    str(args.chrome),
                    "--headless=new",
                    "--enable-gpu",
                    "--no-first-run",
                    "--disable-background-networking",
                    "--no-default-browser-check",
                    f"--user-data-dir={profile}",
                    f"http://127.0.0.1:{server.server_port}{route}",
                ],
                stdout=stderr,
                stderr=stderr,
            )
            try:
                if not done.wait(args.timeout):
                    stderr.seek(0)
                    raise SystemExit("timed out waiting for LightFlow: " + stderr.read()[-1000:])
            finally:
                browser.terminate()
                try:
                    browser.wait(5)
                except subprocess.TimeoutExpired:
                    browser.kill()
                    browser.wait()
                server.shutdown()
    if "error" in result:
        raise SystemExit(result["error"])
    if args.auto_analysis:
        result["analysisProbeSHA256"] = sha256(resources["lightflow-analysis.mjs"])
    if args.vectorscope:
        result["scopeProbeSHA256"] = sha256(resources["lightflow-vectorscope.mjs"])
    if args.viewer_tools:
        result["viewerProbeSHA256"] = sha256(resources["lightflow-viewer-tools.mjs"])
    if args.panel_readback:
        result["parameterSHA256"] = sha256(panel_file)
    if args.paired_photo_operators:
        result["parameterSHA256"] = sha256(extended_file)
        result["photoOperatorAdapterSHA256"] = sha256(resources["lightflow-paired-photo-operators.mjs"])
    if args.panel_schedule or args.paired_photo_operators:
        result["scheduleProbeSHA256"] = sha256(resources["lightflow-panel-schedule.mjs"])
    if sha256(args.raw) != source_hash:
        raise SystemExit("RAW bytes changed during the run")
    result.update(
        schemaVersion=2 if args.paired_photo_operators else 1,
        application="LightFlow",
        build="2d41ab1",
        sourceSHA256=source_hash, sourceSHA256After=source_hash,
        recordedAt=datetime.now(timezone.utc).isoformat(),
        engineSHA256=PINNED,
        browserBinarySHA256=sha256(args.chrome),
        browserBinary=args.chrome.name,
        probeSHA256=sha256(HERE / "lightflow-probe.mjs"),
        system={"os": platform.platform(), "chip": host_chip},
        boundary=("Resident 1024px RAW output to stock scopeAccumulate, scopeResolveImage, scopeSubmit, then a complete CPU-readable 256 × 168 RGBA8 vectorscope trace"
                  if args.vectorscope else "A prepared 384px worker analysis sample and the changed starting recipe to Rust analysisAuto's returned numeric targets"
                  if args.auto_analysis else "Changed resident recipe to complete CPU-accessible 2400 × 1600 sRGB RGBA8 display buffer; hash outside timer"
                  if (args.display_readback or args.panel_readback or args.viewer_tools or args.paired_photo_operators) else "Exact output texture at the requested long side: PixelEngine.render entry to resolved PixelEngine.idle. CPU pixel verification follows timing. Excludes UI, presentation and RAW decode."),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        json.dump(result, output, indent=2, ensure_ascii=False, allow_nan=False)
        output.write("\n")


if __name__ == "__main__":
    main()
