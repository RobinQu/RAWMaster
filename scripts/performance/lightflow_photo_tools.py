"""Measure actual photo-targeted mixer moves and the original vectorscope indicator."""

from datetime import datetime, timezone
from io import BytesIO
import base64
import hashlib
import json
import math
import platform
import time

from PIL import Image
from lightflow_curve_tools import CONTROLS as CURVES, capture_curve
from lightflow_gestures import mouse
from lightflow_panel_tools import click, photo_witness, show_panel


CASES = ("mixer-tat", "color-skin-indicator", *CURVES, "optics-profile-enable")
MIXER = """(()=>{const a=window.__lightflow,id=a.stores.catalog.get().active,
  node=a.editOf(id).grade.nodes.find(n=>n.kind==='corrector'), values=node.tools.mixer?.saturation || {};
  const rows=Array.from(document.querySelectorAll('lightflow-hsl-group[data-prop=sat] lightflow-slider'),
    e=>{const k=e.dataset.id.slice('hsl-sat-'.length),v=Number(e.querySelector('[role=slider]').getAttribute('aria-valuenow'));
        return [k,v,values[k]||0];});return rows;})()"""
SKIN = """(()=>{const a=window.__lightflow,pane=document.querySelector('lightflow-scope[data-kind=vectorscope]'),
  line=pane?.querySelector('svg line.skin'),check=[...document.querySelectorAll('lightflow-scope-settings[data-global=true] [role=checkbox]')]
    .find(e=>e.textContent.trim()==='Skin tone indicator'),box=check?.getBoundingClientRect();
  function point(a,b){const p=new DOMPoint(+line.getAttribute(a),+line.getAttribute(b)).matrixTransform(line.getScreenCTM());return [p.x,p.y]}
  return {state:a.scopes.store.get().vecSkin,checked:check?.getAttribute('aria-checked'),line:!!line,
    ends:line?[point('x1','y1'),point('x2','y2')]:null,box:box?[box.x+box.width/2,box.y+box.height/2]:null,
    trace:pane?.querySelector('canvas.trace')?.width};})()"""


def wait(cdp, expression, message, timeout=3):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = cdp.evaluate(expression)
        if result:
            return result
        time.sleep(0.01)
    raise ValueError(message)


def pointer_clock(cdp):
    cdp.evaluate("""(()=>{window.rawmasterTrustedDown=null;window.rawmasterTrustedUp=null;
      function down(e){if(e.isTrusted)window.rawmasterTrustedDown=performance.now()}
      function up(e){if(e.isTrusted)window.rawmasterTrustedUp=performance.now()}
      document.addEventListener('pointerdown',down,{once:true,capture:true});
      document.addEventListener('pointerup',up,{once:true,capture:true});})()""")


def touched(cdp, state):
    return cdp.evaluate(
        f"(()=>{{const value={state};return {{value,end:performance.now(),"
        "start:window.rawmasterTrustedDown,up:window.rawmasterTrustedUp};})()"
    )


def targeted(cdp, photo, samples):
    show_panel(cdp, "mixer", 'lightflow-hsl[data-id="mixer.hsl"]')
    click(cdp, '[aria-label="Mixer property"] [aria-label="Saturation"]')
    cdp.evaluate("window.__lightflow.runCommand('develop.tat.saturation')")
    wait(
        cdp,
        "!!document.querySelector('lightflow-dev-picker[data-mode=tat]')",
        "Targeted tool did not open",
    )
    result = {
        "id": "mixer-tat",
        "featureIds": ["mixer-tat"],
        "status": "inconclusive",
        "trials": [],
        "boundary": "Trusted photo pointerdown through source sampling, a 60px upward CSS drag, release, and all eight visible saturation values matching the original node recipe.",
    }
    states = [set(), set()]
    for i in range(samples + 2):
        state = i % 2
        if i:
            cdp.evaluate("window.__lightflow.runCommand('edit.undo')")
        wait(
            cdp,
            f"({MIXER}).length===8 && ({MIXER}).every(r=>r[1]===0 && r[2]===0)",
            "Undo failed to restore neutral bands",
        )
        u, v = [(0.29, 0.31), (0.73, 0.69)][state]
        x, y = photo[0] + photo[2] * u, photo[1] + photo[3] * v
        mouse(cdp, "mouseMoved", x, y)
        pointer_clock(cdp)
        mouse(cdp, "mousePressed", x, y)
        until = time.monotonic() + 2
        moves = 0
        try:
            while time.monotonic() < until:
                mouse(cdp, "mouseMoved", x, y - 60, pressed=True)
                moves += 1
                if any(r[2] for r in cdp.evaluate(MIXER)):
                    break
            else:
                raise ValueError("No original photo-targeted band changed")
        finally:
            mouse(cdp, "mouseReleased", x, y - 60)
        observation = touched(cdp, MIXER)
        rows = observation["value"]
        if (
            not observation["up"]
            or not observation["start"]
            or len(rows) != 8
            or any(r[1] != r[2] or not 0 <= r[2] <= 30 for r in rows)
            or not any(r[2] > 0 for r in rows)
        ):
            raise ValueError("Visible saturation bands and edited node differ")
        digest = hashlib.sha256(
            json.dumps(rows, separators=(",", ":")).encode()
        ).hexdigest()
        states[state].add(digest)
        result["trials"].append(
            dict(
                state=state,
                phase="first" if i < 2 else "warm",
                ms=observation["end"] - observation["start"],
                firstDown=observation["start"],
                released=observation["up"],
                verifiedAt=observation["end"],
                sourcePoint=[u, v],
                pointerMoveEvents=moves,
                fields=rows,
                digest=digest,
                verified=True,
            )
        )
    if any(len(s) != 1 for s in states) or states[0] == states[1]:
        raise ValueError(
            "Different photosite selections did not produce repeatable and distinct band mixtures"
        )
    result["status"] = "measured"
    return result


def skin_pixels(cdp, points):
    left, top = min(x for x, y in points), min(y for x, y in points)
    width, height = (
        max(x for x, y in points) - left + 1,
        max(y for x, y in points) - top + 1,
    )
    image = cdp.call(
        "Page.captureScreenshot",
        {
            "format": "png",
            "fromSurface": True,
            "clip": {"x": left, "y": top, "width": width, "height": height, "scale": 1},
        },
    )["data"]
    with Image.open(BytesIO(base64.b64decode(image))) as source:
        rgb = source.convert("RGB")
        if rgb.size != (width, height):
            raise ValueError("Wrong compositor readback bounds")
        return [list(rgb.getpixel((x - left, y - top))) for x, y in points]


def skin(cdp, samples):
    present = "document.querySelector('lightflow-scope[data-kind=vectorscope] canvas.trace')?.getBoundingClientRect().width > 0"
    if not cdp.evaluate(present):
        cdp.evaluate("window.__lightflow.runCommand('panels.scopes')")
    wait(cdp, present, "Original vectorscope did not appear")
    options = 'lightflow-scopes-controls [aria-label="Scope options"]'
    if not cdp.evaluate(f"({SKIN}).box"):
        click(cdp, options)
    initial = wait(
        cdp,
        f"({SKIN}).box && ({SKIN})",
        "Original skin indicator checkbox did not appear",
    )
    if not initial["line"]:
        x, y = initial["box"]
        mouse(cdp, "mousePressed", x, y)
        mouse(cdp, "mouseReleased", x, y)
        initial = wait(cdp, f"({SKIN}).line && ({SKIN})", "No original SVG skin ray")
    (x1, y1), (x2, y2) = initial["ends"]
    if math.hypot(x2 - x1, y2 - y1) < 30:
        raise ValueError(
            "Original vectorscope is too small to verify a photographic color trace"
        )
    points = sorted(
        {
            (round(x1 + (x2 - x1) * t / 22) + dx, round(y1 + (y2 - y1) * t / 22) + dy)
            for t in range(11, 20)
            for dx in range(-1, 2)
            for dy in range(-1, 2)
        }
    )
    result = {
        "id": "color-skin-indicator",
        "featureIds": ["color-skin-indicator"],
        "status": "inconclusive",
        "trials": [],
        "boundary": "Trusted checkbox press to the original enabled setting, accessibility state and vector overlay agreeing. The localized browser-compositor RGB readback has a separate host time.",
        "initialRay": initial["ends"],
        "radialFraction": [0.5, 19 / 22],
        "scopeTraceWidth": initial["trace"],
    }
    refs = []
    for i in range(samples + 2):
        state = i % 2
        x, y = initial["box"]
        pointer_clock(cdp)
        start = time.monotonic_ns()
        mouse(cdp, "mousePressed", x, y)
        mouse(cdp, "mouseReleased", x, y)
        cond = f"({SKIN}).state==={str(bool(state)).lower()} && ({SKIN}).checked==='{str(bool(state)).lower()}' && ({SKIN}).line==={str(bool(state)).lower()}"
        wait(cdp, cond, "Stock indicator state, SVG and accessible checkbox disagree")
        event = touched(cdp, SKIN)
        observed = skin_pixels(cdp, points)
        hostms = (time.monotonic_ns() - start) / 1_000_000
        if i < 2:
            refs.append(observed)
        result["trials"].append(
            dict(
                state=state,
                phase="first" if i < 2 else "warm",
                ms=event["end"] - event["start"],
                hostToCapturedPixelsMs=hostms,
                observed=event["value"],
                rgb=observed,
            )
        )
    # Choose calibration witnesses on the physical ray only, then verify all later samples independently.
    keep = [
        i
        for i, (a, b) in enumerate(zip(*refs))
        if max(abs(c - d) for c, d in zip(a, b)) >= 12
    ]
    if len(keep) < 6:
        raise ValueError("Fewer than six ray pixels changed by 12 RGB8 levels")
    result["calibratedCoordinates"] = [points[i] for i in keep]

    def distance(a, b):
        return sum(abs(c - d) for c, d in zip(a, b))

    for t in result["trials"]:
        observed = t.pop("rgb")
        mine, other = refs[t["state"]], refs[1 - t["state"]]
        match = sum(
            distance(observed[k], mine[k]) < distance(observed[k], other[k])
            for k in keep
        )
        t["rayRGB"] = [observed[k] for k in keep]
        t["agreement"] = match / len(keep)
        t["verified"] = t["agreement"] >= 0.9
        t["digest"] = hashlib.sha256(
            bytes(c for p in t["rayRGB"] for c in p)
        ).hexdigest()
    if all(t["verified"] for t in result["trials"]):
        result["status"] = "measured"
    else:
        result["reason"] = "Skin ray A/B calibration did not repeat on later frames"
    click(cdp, options)
    return result


def embedded_optics(cdp, photo, repeats):
    selector = 'lightflow-checkbox[data-id="base.lensCorrections"]'
    cdp.evaluate(
        "window.__lightflow.stores.develop.set({target:{kind:'base'}});window.__lightflow.develop.showSection('basic')"
    )
    wait(
        cdp,
        "!!document.querySelector(" + json.dumps(selector) + ")",
        "Original lens corrections checkbox unavailable",
    )
    read = """(()=>{const a=window.__lightflow,p=a.stores.catalog.get().active,el=document.querySelector('lightflow-checkbox[data-id="base.lensCorrections"]');
      const v=document.querySelector('lightflow-viewer canvas'),s=a.stores.develop.get().status;
      return {checked:el.getAttribute('aria-checked')==='true',recipe:a.editOf(p).source.lensCorrections!==false,
        ready:!s.decoding && v.dataset.busy!=='1',frames:+v.dataset.frames,photo:p}})()"""
    if not cdp.evaluate("(" + read + ").checked"):
        click(cdp, selector)
    initial = photo_witness(cdp, photo)
    out = {
        "id": "optics-profile-enable",
        "featureIds": ["optics-profile-enable"],
        "trials": [],
        "boundary": "Host start of trusted stock RAW lens-profile checkbox through updated source recipe, newly completed original viewer frames, the editor's built-in idle check and a 96 × 64 compositor photo readback.",
        "referenceEnabledDigest": initial,
    }
    signatures = [set(), set()]
    for i in range(repeats + 2):
        state = i % 2
        before = cdp.evaluate(read)
        start = time.monotonic_ns()
        click(cdp, selector)
        expected = str(bool(state)).lower()
        wait(
            cdp,
            f"({read}).checked==={expected} && ({read}).recipe==={expected}",
            "Original lens correction did not toggle",
        )
        wait(
            cdp,
            f"({read}).frames > {before['frames']}",
            "No newly committed original viewer frame for the changed source",
            8,
        )
        pixels = photo_witness(cdp, photo)
        end = time.monotonic_ns()
        after = cdp.evaluate(read)
        if (
            not after["ready"]
            or after["photo"] != before["photo"]
            or after["frames"] <= before["frames"]
        ):
            raise ValueError("Lens correction did not complete on the original RAW")
        signatures[state].add(pixels)
        out["trials"].append(
            {
                "phase": "first" if i < 2 else "warm",
                "state": state,
                "ms": (end - start) / 1_000_000,
                "before": before,
                "after": after,
                "digest": pixels,
            }
        )
    verified = (
        all(len(s) == 1 for s in signatures)
        and signatures[0] != signatures[1]
        and signatures[1] == {initial}
    )
    out["status"] = "measured" if verified else "inconclusive"
    if not verified:
        out["reason"] = (
            "The real source checkbox changed, but its photo did not produce two stable, distinct RGB witnesses on this RAW."
        )
    for t in out["trials"]:
        t["verified"] = verified
    return out


def capture(cdp, session, args, driver):
    geometry, set_zoom, view, commit = driver
    if session.get("visible") or args.samples < 10 or args.output.exists():
        raise ValueError(
            "Use a fresh headless session, output path and 10+ observations"
        )

    def source_hash():
        with args.raw.open("rb") as f:
            return hashlib.file_digest(f, "sha256").hexdigest()

    source = source_hash()
    if session["sourceSHA256"] != source:
        raise ValueError("Unexpected original RAW")
    set_zoom(cdp, 2368)
    viewport, photo, _ = geometry(view(cdp))
    if view(cdp)["dpr"] != 1:
        raise ValueError("Photo coordinates require DPR 1")
    output = {
        "schemaVersion": 1,
        "application": "LightFlow",
        "build": session["build"],
        "sourceSHA256": source,
        "uiSHA256": session["uiSHA256"],
        "browserBinarySHA256": session["browserBinarySHA256"],
        "system": platform.platform(),
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "protocol": "lightflow-original-photo-controls-v1",
        "photoRectPixels": photo,
        "viewportPixels": viewport,
        "samples": args.samples,
        "operations": [],
    }
    for key in args.operations or CASES:
        try:
            if key in CURVES:
                row = capture_curve(cdp, key, args.samples, wait, commit)
            elif key == "mixer-tat":
                row = targeted(cdp, photo, args.samples)
            elif key == "optics-profile-enable":
                row = embedded_optics(cdp, photo, args.samples)
            else:
                row = skin(cdp, args.samples)
        except (KeyError, RuntimeError, ValueError) as error:
            row = {
                "id": key,
                "featureIds": [key],
                "trials": [],
                "status": "inconclusive",
                "reason": str(error),
            }
        output["operations"].append(row)
        print(key, row["status"], row.get("reason", ""), flush=True)
    output["sourceSHA256After"] = source_hash()
    if output["sourceSHA256After"] != source:
        raise ValueError("RAW source changed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as f:
        json.dump(output, f, indent=2, allow_nan=False)
        f.write("\n")
