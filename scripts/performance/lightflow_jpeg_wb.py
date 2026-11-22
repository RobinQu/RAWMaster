"""Exercise the distinct rendered-file white balance path using the Sony ARW's embedded JPEG."""

from datetime import datetime, timezone
import hashlib
import json
import mmap
import time

from PIL import Image
from lightflow_panel_tools import photo_witness


def capture_rendered_wb(cdp, session, args, driver):
    select, commit, geometry, zoom, view = driver
    if args.output.exists() or session.get("visible") or args.samples < 10:
        raise ValueError("Use a windowless editor and a new evidence path")
    child = args.raw.read_bytes()
    child_sha = hashlib.sha256(child).hexdigest()

    def parent_source():
        with (
            args.parent_raw.open("rb") as f,
            mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as content,
        ):
            return hashlib.sha256(content).hexdigest(), content.find(child)

    parent, offset = parent_source()
    if offset < 0 or child_sha != session["sourceSHA256"]:
        raise ValueError(
            "Camera JPEG does not occur as an intact byte range in the source RAW"
        )
    with Image.open(args.raw) as im:
        if im.format != "JPEG":
            raise ValueError("The embedded photo is not JPEG")
        size = list(im.size)
    zoom(cdp, size[0])
    viewport, photo, _ = geometry(view(cdp))
    if photo[2:] != size or view(cdp)["dpr"] != 1:
        raise ValueError(
            "Unscaled embedded photo is not fully visible in the stock editor"
        )
    loc, control = select(cdp, "base", "temperature")
    ranges = cdp.evaluate(f"""(()=>{{const slider=document.querySelector({loc}).querySelector('[role=slider]');
       return [+slider.getAttribute('aria-valuemin'),+slider.getAttribute('aria-valuemax')];}})()""")
    if ranges != [-100, 100]:
        raise ValueError(
            "The running stock editor did not select its rendered-photo temperature field"
        )
    states = [set(), set()]
    row = {
        "id": "color-temp-rendered",
        "featureIds": ["color-temp-rendered"],
        "trials": [],
        "range": ranges,
        "boundary": "Host send of trusted Return in prepared stock temperature field through accepted relative value, original viewer idle and 96 × 64 browser-compositor RGB pixels.",
    }
    for i in range(args.samples + 2):
        state = i % 2
        value = [-28, 28][state]
        answer = commit(cdp, loc, control["label"], value)
        recipe = cdp.evaluate(
            "(()=>{const a=window.__lightflow,b=a.editOf(a.stores.catalog.get().active).base;return {temperature:b.temperature,tint:b.tint,wbMode:b.wbMode};})()"
        )
        pixels = photo_witness(cdp, photo)
        ended = time.monotonic_ns()
        if (
            not answer["accepted"]
            or recipe["temperature"] != answer["actual"]
            or recipe["temperature"] != value
        ):
            raise ValueError("Rendered temperature control and JPEG recipe disagree")
        states[state].add(pixels)
        row["trials"].append(
            {
                "state": state,
                "phase": "first" if i < 2 else "warm",
                "ms": (ended - answer["sentNs"]) / 1_000_000,
                "actualFieldValue": answer["actual"],
                "recipe": recipe,
                "digest": pixels,
            }
        )
    verified = all(len(s) == 1 for s in states) and states[0] != states[1]
    row["status"] = "measured" if verified else "inconclusive"
    for t in row["trials"]:
        t["verified"] = verified
    end_parent, end_offset = parent_source()
    if (end_parent, end_offset) != (parent, offset) or hashlib.sha256(
        args.raw.read_bytes()
    ).hexdigest() != child_sha:
        raise ValueError("Container or embedded image changed")
    report = {
        "schemaVersion": 1,
        "application": "LightFlow",
        "build": session["build"],
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "protocol": "lightflow-rendered-jpeg-temperature-v1",
        "sourceKind": "camera JPEG embedded in the Sony ARW",
        "parentRawSHA256": parent,
        "parentRawSHA256After": end_parent,
        "sourceSHA256": child_sha,
        "sourceSHA256After": child_sha,
        "embeddedOffset": offset,
        "embeddedLength": len(child),
        "sourcePixels": size,
        "viewportPixels": viewport,
        "photoRectPixels": photo,
        "uiSHA256": session["uiSHA256"],
        "browserBinarySHA256": session["browserBinarySHA256"],
        "samples": args.samples,
        "operations": [row],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as f:
        json.dump(report, f, indent=2, allow_nan=False)
        f.write("\n")
