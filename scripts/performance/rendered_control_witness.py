"""Qualify the rendered-file control benchmark that covers JPEG/TIFF temperature, photographic
denoise strength and Lens Blur on a real device-depth image.

The report is produced by `RenderedFileControlPerformanceTests` on the normal preview service. Each
operation alternates two committed recipes and keeps its 192 px sRGB witness outside the timed call,
so the returned median shares the resident-control boundary rather than the export or settled one.
"""
import json
import math
import re
import statistics
from pathlib import Path

PROTOCOL = "rawmaster-rendered-control-v1"
BOUNDARY = "已提交的已显影图像配方请求至交互帧返回；192 px sRGB 见证在计时外读取"
DISPLAY_BOUNDARY = "已显影照片的 2400 px 交互帧"
# Stable Camera Raw feature ID → the measured operation's source and the product surface it covers.
FEATURES = {
    "color-temp-rendered": ("jpeg", "imageio-rendered-jpeg"),
    "detail-denoise-formats": ("jpeg", "waifu2x-vgg7-photo-noise2-cc385f97-full-chroma-v2"),
    "blur-device-depth": ("heic", "device-depth-heic"),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value)


def load(path):
    data = json.loads(Path(path).read_text())
    require(data.get("protocol") == PROTOCOL, "Unexpected rendered-control protocol")
    require(data.get("build") == "release" and digest(data.get("binarySHA256")), "Missing Release binary provenance")
    require(data.get("requestedPixels") == 2400 and data.get("repeats") >= 20, "Expected the 2400 px workload and 20 warm edits")
    require(all(v > 0 for v in data["sources"]["jpeg"]["pixels"][:2]), "Missing rendered source geometry")
    repeats = data["repeats"]
    operations = {}
    for row in data["operations"]:
        key = row["id"]
        require(key not in operations, f"Duplicate rendered control {key}")
        samples = row["samples"]
        if row.get("status") != "measured":
            operations[key] = None
            continue
        require(len(samples) == repeats + 2, f"Missing trials for {key}")
        require(len(set(row["recipes"])) == 2 and len(row["decoders"]) == 2, f"Missing state pair for {key}")
        require(0 < max(row["outputPixels"]) <= data["requestedPixels"] and min(row["outputPixels"]) > 0,
                f"Unexpected pixels for {key}")
        seen = [set(), set()]
        warm = []
        for i, trial in enumerate(samples):
            require(trial["state"] == i % 2 and trial["phase"] == ("first" if i < 2 else "warm"), f"Trial order for {key}")
            require(digest(trial["digest"]), f"Pixel signature for {key}")
            require(math.isfinite(trial["ms"]) and trial["ms"] > 0, f"Invalid timing for {key}")
            seen[i % 2].add(trial["digest"])
            if i >= 2:
                warm.append(trial["ms"])
        require(all(len(s) == 1 for s in seen) and seen[0] != seen[1], f"Pixel A/B verification failed for {key}")
        operations[key] = {"measured": True, "source": row["source"], "decoder": row["decoders"][0],
                           "medianMs": statistics.median(warm),
                           "p95Ms": sorted(warm)[math.ceil(.95 * len(warm)) - 1],
                           "maxMs": max(warm),
                           "pixels": row["outputPixels"], "firstEditMs": samples[0]["ms"]}
    for feature, (source, _) in FEATURES.items():
        require(feature in operations, f"Missing rendered receipt for {feature}")
    return data, operations


def rendered_rows(path, evidence):
    data, operations = load(path)
    rows = {}
    for feature, (source, decoder) in FEATURES.items():
        observed = operations.get(feature)
        if not observed:
            rows[feature] = {"state": "inconclusive", "reason": "两种已提交状态没有稳定且不同的 sRGB 见证。",
                             "evidence": evidence}
            continue
        require(observed["source"] == source, f"{feature}: different rendered source")
        require(observed["decoder"] == decoder, f"{feature}: different rendered decoder")
        rows[feature] = {"state": "measured", "evidence": evidence, "boundary": BOUNDARY,
                         "displayBoundary": DISPLAY_BOUNDARY,
                         "timing": {"n": data["repeats"], "medianMs": observed["medianMs"],
                                    "p95Ms": observed["p95Ms"], "maxMs": observed["maxMs"]},
                         "firstEditMs": observed["firstEditMs"], "sourcePixels": observed["pixels"],
                         "sourceContainer": data["sources"][source]["container"]}
    return rows
