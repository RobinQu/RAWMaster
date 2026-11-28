"""Score the capture protocol used by all three application drivers."""
from bisect import bisect_left
import hashlib
from pathlib import Path
import struct

RGB_BYTES = 96 * 64 * 3
POLICY = {"roiGrid": [96, 64], "captureHz": 60, "minimumSeparationRGB8": 0.03,
          "firstFraction": 0.2, "finalToleranceFraction": 0.15, "plateauMs": 120}


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
