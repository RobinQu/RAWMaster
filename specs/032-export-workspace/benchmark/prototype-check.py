#!/usr/bin/env python3
"""Verify the live selection limit in the served prototype."""
from base64 import b64decode
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.request import urlopen

from competitors import CDP, wait

spec = Path(__file__).resolve().parents[1]
browser = Path(sys.argv[1])
results = Path(sys.argv[2])
with TemporaryDirectory() as profile:
    command = [str(browser), "--disable-background-networking", "--no-first-run", "--remote-debugging-port=0",
               f"--user-data-dir={profile}", (spec / "prototype.html").as_uri()]
    proc = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        address = Path(profile) / "DevToolsActivePort"
        wait(address.exists, 15)
        port = address.read_text().splitlines()[0]
        tab = next(t for t in json.load(urlopen(f"http://127.0.0.1:{port}/json/list")) if t["type"] == "page")
        cdp = CDP(tab["webSocketDebuggerUrl"])
        ev = cdp.evaluate
        cdp.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 760, "deviceScaleFactor": 1, "mobile": False})
        wait(lambda: ev("typeof selection !== 'undefined' && typeof byId === 'function'"), 10)
        checks = []

        def check(title, expression):
            if not ev(expression):
                raise AssertionError(title)
            checks.append(title)

        def size(count):
            ev(f"""(() => {{
                const control = byId('sample-size');
                control.value = '{count}';
                control.dispatchEvent(new Event('change'));
            }})()""")
            ev("new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")

        size(1200)
        check("1,200 candidates remain selected and visibly blocked", "included.size===1200 && byId('submit').disabled")
        check("DOM rows are virtualized", "byId('asset-rows').childElementCount<=24 && byId('asset-list').scrollHeight>60000")
        mounted = ev("byId('asset-rows').childElementCount")
        check("Limit message and trim are visible", "!byId('selection-limit').hidden && byId('limit-count').textContent.includes('200 张')")
        ev("byId('asset-list').scrollTop=60000")
        ev("new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
        screenshot = cdp.send("Page.captureScreenshot", {"format": "png"})
        (spec / "assets/selection-1200.png").write_bytes(b64decode(screenshot["data"]))
        size(201)
        check("201 selection leaves every ID and blocks rendering", "included.size===201 && selection.overLimit && byId('submit').disabled")
        ev("byId('original').click()")
        check("Original copy enforces the same limit", "included.size===201 && byId('submit').disabled")
        ev("byId('copy-mode').value='manifest';byId('copy-mode').dispatchEvent(new Event('change'))")
        check("Manifest-only enforces the same limit", "included.size===201 && byId('submit').disabled")
        ev("byId('limit-selection').click()")
        check("Trim explicitly preserves the first 200", "included.size===200 && included.has(199) && !included.has(200) && !byId('submit').disabled")
        ev("byId('submit').click()")
        check("200 photos plus one generated manifest", "job.items.length===201 && job.items.filter(item=>item.state==='已列入清单').length===200")
        check("The result list stays bounded", "byId('jobrows').childElementCount<=24")
        ev("byId('close-job').click()")
        size(3)
        check("Three photos are available as a separate preview fixture", "included.size===3 && selection.total===3")
        check("Preset bar and output folder remain separate", "!!(byId('preset').closest('#preset-bar') && byId('folder').closest('footer'))")
        results.write_text(json.dumps({"passed": len(checks), "checks": checks, "rowsFor1200": mounted}, indent=2) + "\n")
    finally:
        proc.terminate()
        proc.wait(timeout=15)
