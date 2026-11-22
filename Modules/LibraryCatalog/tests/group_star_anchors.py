# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy==2.2.6", "opencv-python-headless==4.12.0.88"]
# ///
"""Check the three annotated star paths and two fixed foreground patches in the confirmed 24-frame set."""
import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path

import cv2
import numpy as np


SHAPE = (1000, 667)
INPUT_SET = "60c609eb24ef496b8845661c8ae444c9414f08d699c35580b0e91c55d3d3ecf1"
# Independently identified from camera previews at frozen indices 12 and 23 (x, y, top-left).
STARS = [((483, 37), (499, 65)), ((609, 340), (624, 360)), ((392, 227), (408, 248))]
TOWERS = [(432, 477), (750, 500)]


def tiff_luminance(path):
    with path.open("rb") as stream:
        head = stream.read(65536)
    assert head[:4] == b"II*\0"
    ifd, = struct.unpack_from("<I", head, 4)
    count, = struct.unpack_from("<H", head, ifd)
    fields = {}
    for index in range(count):
        tag, kind, n, value = struct.unpack_from("<HHII", head, ifd + 2 + index * 12)
        if kind == 4:
            fields[tag] = (value,) if n == 1 else struct.unpack_from("<" + "I" * n, head, value)
    raw = np.memmap(path, dtype="<f4", offset=fields[273][0], mode="r", shape=(fields[257][0], fields[256][0], 3))
    rgb = cv2.resize(raw, SHAPE, interpolation=cv2.INTER_AREA)
    return .2126 * rgb[:, :, 0] + .7152 * rgb[:, :, 1] + .0722 * rgb[:, :, 2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("request", "receipt", "master", "exiftool"):
        parser.add_argument("--"+key, type=Path, required=True)
    parser.add_argument("--foreground-master", type=Path, help="same frozen group with reference index 12 and foregroundStartY=0.58")
    args = parser.parse_args()
    frames = json.loads(args.request.read_text())["frames"]
    facts = json.loads(args.receipt.read_text())["facts"]
    identity = hashlib.sha256(b"".join(bytes.fromhex(v["sha256"]) for v in frames)).hexdigest()
    assert identity == INPUT_SET and [x["sha256"] for x in facts["inputs"]] == [x["sha256"] for x in frames]
    assert facts["foregroundReviewIndices"] == [0, 1, 2, 3]
    times, planes = [0.0], []
    for i, item in enumerate(frames):
        encoded = subprocess.check_output([str(args.exiftool), "-b", "-PreviewImage", item["path"]])
        gray = cv2.imdecode(np.frombuffer(encoded, np.uint8), cv2.IMREAD_GRAYSCALE)
        planes.append(cv2.resize(gray, SHAPE, interpolation=cv2.INTER_AREA))
        if i:
            times.append(times[-1] + facts["inputs"][i]["startIntervalSeconds"])
    inputs = np.asarray(planes).astype(np.float32)
    high_pass = [p - cv2.GaussianBlur(p, (0, 0), 4) for p in inputs]
    master = tiff_luminance(args.master)
    output = master - cv2.GaussianBlur(master, (0, 0), 4)
    tracks = []
    for start, end in STARS:
        residuals, local_mads = [], []
        for i in range(4, 24):
            fraction = (times[i] - times[12]) / (times[23] - times[12])
            x, y = np.array(start) + (np.array(end) - start) * fraction
            ix, iy = round(x), round(y)
            top = max(0, iy - 4)
            block = high_pass[i][top:iy+5, ix-4:ix+5]
            sy, sx = np.unravel_index(block.argmax(), block.shape)
            px, py = ix - 4 + sx, top + sy
            residuals.append(float(np.hypot(px - x, py - y)))
            neighborhood = output[max(0, py-8):py+9, px-8:px+9]
            median = np.median(neighborhood)
            mad = np.median(np.abs(neighborhood - median))
            peak = output[max(0, py-2):py+3, px-2:px+3].max()
            local_mads.append(float((peak - median) / (mad + 1e-6)))
        assert np.percentile(residuals,95) < 2.0 and min(local_mads) > 3.0
        tracks.append({"samples":len(residuals), "trajectoryP95ProxyPx":round(float(np.percentile(residuals,95)),3),
                       "masterLocalContrastP05MAD":round(float(np.percentile(local_mads,5)),2)})
    anchors = []
    preserved = tiff_luminance(args.foreground_master) if args.foreground_master else None
    for x,y in TOWERS:
        patch=inputs[12][y-23:y+24,x-23:x+24]
        scores, shifts = [], []
        for frame in inputs[4:]:
            region=frame[y-29:y+30,x-29:x+30]
            grid=cv2.matchTemplate(region,patch,cv2.TM_CCOEFF_NORMED)
            _, score, _, (dx,dy) = cv2.minMaxLoc(grid)
            scores.append(score); shifts.append(float(np.hypot(dx-6,dy-6)))
        assert max(shifts)<=1 and min(scores)>.95
        result={"maxShiftProxyPx":max(shifts),"lowestCorrelation":round(min(scores),4)}
        if preserved is not None:
            measured=[]
            for image in (master,preserved):
                region=np.sqrt(np.clip(image[y-32:y+33,x-32:x+33],0,None)).astype(np.float32)
                grid=cv2.matchTemplate(region,patch,cv2.TM_CCOEFF_NORMED)
                _, score, _, (dx,dy)=cv2.minMaxLoc(grid)
                measured.append((round(score,4),[dx-9,dy-9]))
            assert measured[1][0]>.95 and measured[1][0]>measured[0][0] and measured[1][1]==[0,0]
            result.update(unmaskedCorrelation=measured[0][0],preservedCorrelation=measured[1][0],preservedOffset=measured[1][1])
        anchors.append(result)
    print(json.dumps({"inputSetSHA256":identity,"proxyWidth":1000,"proxyHeight":667,
                      "stableFrozenIndices":[4,23],"starTrajectories":tracks,"foregroundAnchors":anchors},
                     sort_keys=True))


if __name__ == "__main__":
    main()
