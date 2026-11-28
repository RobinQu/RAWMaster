"""Score the capture protocol used by all three application drivers."""
from bisect import bisect_left
import hashlib
import math
from pathlib import Path
import struct
import subprocess
import tempfile

RGB_BYTES = 96 * 64 * 3
POLICY = {"roiGrid": [96, 64], "captureHz": 60, "minimumSeparationRGB8": 0.03,
          "firstFraction": 0.2, "finalToleranceFraction": 0.15, "plateauMs": 120}
NATIVE_ROI_PROTOCOL = "screen-photo-native-roi-response-v1"
NATIVE_ROI_SCOPE = "central 60% of the 1:1 source ROI"


def native_roi_geometry(view, window, source_roi):
    """Project an upright source rectangle to exact backing pixels in the stock LightFlow window."""
    frame, metrics, state = view["frame"], view["metrics"], view["developView"]
    source_w, source_h = frame["frameW"], frame["frameH"]
    x, y, width, height = source_roi
    if (frame["fullRes"] is not True or [source_w, source_h] != [metrics["sourceW"], metrics["sourceH"]]
            or metrics["geometry"] != [1, 0, 0, 1, 0, 0]
            or min(x, y) < 0 or min(width, height) <= 0 or x + width > source_w or y + height > source_h):
        raise ValueError("Native ROI requires an in-bounds source rectangle on the full unrotated and uncropped image")
    center = [(x + width / 2) / source_w, (y + height / 2) / source_h]
    if (center == [.5, .5] or state["viewerIdle"] is not True or state["zoom"] != 1
            or not math.isclose(metrics["scale"], 1, abs_tol=1e-5)
            or not all(math.isclose(state["center"][axis], target, abs_tol=1e-6)
                       for axis, target in zip(("x", "y"), center))):
        raise ValueError("The stock editor did not retain a noncentral 1:1 source focus")

    a, b, c, d, tx, ty = frame["affine"]
    if min(a, d) <= 0 or max(abs(b), abs(c)) > 1e-6:
        raise ValueError("Expected an upright, axis-aligned native photo transform")
    density = [1 / (a * source_w), 1 / (d * source_h)]
    if not all(math.isclose(value, 1, abs_tol=1e-5) for value in density):
        raise ValueError(f"A source pixel does not map to one backing pixel: {density}")
    bx, by = (x / source_w - tx) / a, (y / source_h - ty) / d
    bw, bh = width * density[0], height * density[1]
    backing_rect = [round(value) for value in (bx, by, bw, bh)]
    if (max(abs(actual - rounded) for actual, rounded in zip((bx, by, bw, bh), backing_rect)) > .01
            or min(backing_rect[:2]) < 0 or backing_rect[0] + width > frame["width"]
            or backing_rect[1] + height > frame["height"]):
        raise ValueError("Native source ROI is clipped by the canvas or does not align to integer backing pixels")

    outer_w, outer_h = view["outer"]
    inner_w, inner_h = view["inner"]
    ratio, canvas = view["dpr"], view["canvasCSS"]
    if (window["scale"] != ratio or abs(outer_w - window["frame"][2]) > 2 or abs(outer_h - window["frame"][3]) > 2
            or abs(canvas["width"] * ratio - frame["width"]) > 1
            or abs(canvas["height"] * ratio - frame["height"]) > 1):
        raise ValueError("The browser canvas and ScreenCaptureKit window use different pixel geometry")
    wx = (max(0, (outer_w - inner_w) / 2) + canvas["x"]) * ratio + bx
    wy = (outer_h - inner_h + canvas["y"]) * ratio + by
    window_w, window_h = [round(size * ratio) for size in window["frame"][2:]]
    screen_x, screen_y = round(wx), round(wy)
    if (max(abs(wx - screen_x), abs(wy - screen_y)) > .01 or min(screen_x, screen_y) < 0
            or screen_x + width > window_w or screen_y + height > window_h):
        raise ValueError("Native source ROI is clipped by the captured window or does not align to its pixel grid")
    return {"sourcePixels": [source_w, source_h], "sourceROIPixels": source_roi, "sourceCenterNormalized": center,
            "backingPixelsPerSourcePixel": density, "canvasBackingPixels": [frame["width"], frame["height"]],
            "roiCanvasRectPixels": backing_rect, "roiWindowRectPixels": [screen_x, screen_y, width, height],
            "windowBackingPixels": [window_w, window_h],
            "sampleROINormalized": [(screen_x + width * .2) / window_w, (screen_y + height * .2) / window_h,
                                    width * .6 / window_w, height * .6 / window_h]}


def capture_native_roi_screenshot(path, window, geometry):
    from PIL import Image, ImageStat

    with tempfile.TemporaryDirectory(prefix="native-roi-snapshot-") as scratch:
        full = Path(scratch) / "window.png"
        subprocess.run(["screencapture", "-x", "-o", "-l", str(window["id"]), str(full)], check=True, timeout=20)
        with Image.open(full) as image:
            if list(image.size) != geometry["windowBackingPixels"]:
                raise ValueError("Window screenshot dimensions differ from the verified backing-pixel dimensions")
            x, y, width, height = geometry["roiWindowRectPixels"]
            roi = image.crop((x, y, x + width, y + height)).convert("RGB")
            roi.save(path, icc_profile=image.info.get("icc_profile"))
    return {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "pixels": list(roi.size),
            "rgbSHA256": hashlib.sha256(roi.tobytes()).hexdigest(), "meanLuma": ImageStat.Stat(roi.convert("L")).mean[0]}


def warmup_states(count):
    """Alternate A/B and leave B active before recording calibration A."""
    return [(index + count) % 2 for index in range(count)]


def load_frames(path: Path):
    record = struct.Struct(f">Q{RGB_BYTES}s")
    with path.open("rb") as stream:
        frames = list(record.iter_unpack(stream.read()))
    if not frames or any(a[0] >= b[0] for a, b in zip(frames, frames[1:])):
        raise ValueError("Missing frames or non-monotonic capture timestamps")
    return frames


def distance(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / RGB_BYTES


def score(frames, events, end_ns):
    """First A and B are witness images. Later alternating inputs must converge on the same target."""
    stamps = [f[0] for f in frames]
    rows = []
    for i, event in enumerate(events):
        start = event["sentNs"]
        end = events[i + 1]["sentNs"] if i + 1 < len(events) else end_ns
        lo, hi = bisect_left(stamps, start), bisect_left(stamps, end)
        if lo < 1 or hi < 1 or end <= start:
            raise ValueError("Action markers fall outside the capture or share the wrong clock")
        rows.append((frames[lo - 1][1], frames[lo:hi], frames[hi - 1][1], end))
    refs = [rows[i][2] for i in (0, 1)]
    separation = distance(*refs)
    output = {"separationRGB8": separation, "referenceDigests": [hashlib.sha256(r).hexdigest() for r in refs],
              "trials": [], "status": "inconclusive"}
    if separation < POLICY["minimumSeparationRGB8"]:
        output["reason"] = "Calibration edit produced insufficient stable photo contrast"
        return output
    limit = separation * POLICY["finalToleranceFraction"]
    first_fraction = 1 - POLICY["firstFraction"]
    for i, (before, changes, last, end) in enumerate(rows[2:], start=2):
        state = events[i]["state"]
        target, prior = refs[state], refs[1-state]
        trace = [[(stamp - events[i]["sentNs"]) / 1e6, round(distance(pixels, target), 5)] for stamp, pixels in changes]
        arrival = next((ms for ms, error in trace if error <= first_fraction * separation), None)
        quiet_start = end - int(POLICY["plateauMs"] * 1e6)
        plateau = [pixels for stamp, pixels in changes if stamp >= quiet_start]
        ok = (events[i].get("accepted", True) and distance(before, prior) <= limit and arrival is not None and
              distance(last, target) <= limit and all(distance(pixels, target) <= limit for pixels in plateau))
        output["trials"].append(dict(events[i], firstMs=arrival, verified=ok, finalErrorRGB8=distance(last, target),
                                     changesMsAndTargetError=trace))
    if output["trials"] and all(t["verified"] for t in output["trials"]):
        output["status"] = "measured"
    else:
        output["reason"] = "At least one edited input failed the prior/target pixel or value witness"
    return output
