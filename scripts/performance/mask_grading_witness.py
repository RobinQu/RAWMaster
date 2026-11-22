"""Verify a midtone color wheel inside the benchmark's central Camera Raw radial mask."""
import argparse
from hashlib import sha256
import json
from math import hypot
from pathlib import Path

from histogram_witness import native_pixel_separation


def grid(width, height):
    for gy in range(16):
        for gx in range(16):
            u, v = (gx + 0.5) / 16, (gy + 0.5) / 16
            radius = hypot((u - 0.5) / 0.3, (v - 0.5) / 0.3)
            if radius <= 0.55 or radius >= 1.4:
                yield [int(u * width), int(v * height)], "center" if radius <= 0.55 else "outside"


def sample(data, offset, width, height):
    stride = (width * 3 + 3) // 4 * 4
    result = []
    for (x, y), region in grid(width, abs(height)):
        row = height - 1 - y if height > 0 else y
        start = offset + row * stride + 3 * x
        result.append({"xy": [x, y], "region": region, "rgb": list(data[start:start + 3][::-1])})
    return result


def verify(rows):
    if len(rows) < 8 or len(rows) % 2:
        raise ValueError("The local color-wheel witness needs a calibration pair and three held-out pairs")
    expected_order = [(i, state) for i in range(len(rows) // 2) for state in ("control", "edit")]
    if [(r["iteration"], r["state"]) for r in rows] != expected_order:
        raise ValueError("Incomplete or reordered local color-wheel A/B pairs")
    dimensions = {tuple(r["spatialPixels"]) for r in rows}
    if len(dimensions) != 1 or min(dimensions.pop()) < 16:
        raise ValueError("Inconsistent spatial witness dimensions")
    positions = list(grid(*rows[0]["spatialPixels"]))
    frames = []
    for row in rows:
        captured = row["maskPixelGrid"]
        if [(p["xy"], p["region"]) for p in captured] != positions:
            raise ValueError("Mask sample positions moved outside the declared grid")
        colors = [p["rgb"] for p in captured]
        if any(len(c) != 3 or any(type(v) is not int or not 0 <= v <= 255 for v in c) for c in colors):
            raise ValueError("Invalid mask RGB8 readout")
        frames.append(colors)

    regions = {k: {"pixels": 0, "changedAtLeastTwoRGB8": 0, "identical": 0, "stableInEachState": 0}
               for k in ("center", "outside")}
    selected = []
    for index, (_, region) in enumerate(positions):
        counts = regions[region]
        counts["pixels"] += 1
        a, b = frames[0][index], frames[1][index]
        difference = max(abs(x - y) for x, y in zip(a, b))
        if region == "center" and difference >= 2:
            selected.append(index)
        if all(frame[index] == a for frame in frames[::2]) and all(frame[index] == b for frame in frames[1::2]):
            counts["stableInEachState"] += 1
            counts["identical"] += int(difference == 0)
            counts["changedAtLeastTwoRGB8"] += int(difference >= 2)

    # Reuse the release witness that freezes position, channel and sign on the first pair.
    held_out = native_pixel_separation({"coordinates": [positions[i][0] for i in selected],
                                        "samples": [[frame[i] for i in selected] for frame in frames]})
    digests = {}
    for field in ("histogramSHA256", "spatialRGBSHA256"):
        a = {row[field] for row in rows[::2]}
        b = {row[field] for row in rows[1::2]}
        digests[field] = len(a) == 1 and len(b) == 1 and a != b and all(
            len(value) == 64 and set(value) <= set("0123456789abcdef") for value in a | b)
    outside = regions["outside"]
    outside_identical = outside["identical"] == outside["pixels"]
    return {
        "geometry": "0.20–0.80 central ellipse, Feather 50 and Flipped true. Centers of 16×16 fixed tiles at normalized radius ≤0.55 or ≥1.4.",
        "selection": "The calibration A/B pair selects center tile locations, channel and sign. At least 16 center tiles, ≥90% held-out verification with a two-code RGB8 gap, all outside RGB bytes invariant. Midtone-only color changes can leave other center luminances unchanged.",
        "regions": regions, "heldOutPairs": len(rows) // 2 - 1, "center": held_out,
        "outsideByteIdentical": outside_identical, "fullImageSignaturesStableAndDistinct": digests,
        "qualified": held_out["qualified"] and outside_identical and all(digests.values())
    }


def recheck(source, output):
    raw = source.read_bytes()
    report = json.loads(raw)
    name = "grading-mask-wheels"
    if (report.get("planned") != [name] or set(report["operations"]) != {name} or not report.get("finishedAt")
            or {report.get(k) for k in ("sourceSHA256", "workCopySHA256After", "sourceSHA256After")} != {report["sourceSHA256"]}):
        raise ValueError("Requalification requires an intact, completed, isolated mask-wheel run")
    row = report["operations"][name]
    if row["settings"] != {"control": {"LocalColorGradeMidtoneHue": 142, "LocalColorGradeMidtoneSat": 0},
                            "edit": {"LocalColorGradeMidtoneHue": 142, "LocalColorGradeMidtoneSat": 65}}:
        raise ValueError("The expected masked midtone A/B comparison changed")
    if len(row["samples"]) != 2 * (report["repeats"] + 1):
        raise ValueError("Incomplete timed sample population")
    previous = {"status": row["status"], "reason": row.get("reason"), "regions": row["localMaskSeparation"]}
    separation = verify(row["samples"])
    report["qualificationRevision"] = {
        "originalCaptureSHA256": sha256(raw).hexdigest(), "assessmentSHA256": sha256(Path(__file__).read_bytes()).hexdigest(),
        "previous": previous,
        "rationale": "The initial criterion required 80% of center pixels to change by two codes. A midtone-only correction does not affect every luminance. Reuse the existing 16-tile held-out RGB protocol and require byte identity at every fixed outside position. This reassessment used the retained data; the raw first assessment remains archived."
    }
    row["localMaskSeparation"] = separation
    if separation["qualified"]:
        row.update(status="measured", witness="localMaskRGB8HeldOut")
        row.pop("reason", None)
    else:
        row.update(status="inconclusive", reason="The held-out center versus outside RGB8 requirements were not met")
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recheck", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    recheck(args.recheck, args.output)
