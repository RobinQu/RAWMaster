#!/usr/bin/env python3
"""Run real user-selected RAWs in a private scratch directory; print only reproducible, path-free measures."""
import argparse
import hashlib
import json
import math
import mmap
import os
import resource
import sys
from pathlib import Path
import struct
import subprocess
import tempfile
import time


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_tiff(path):
    with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        assert data[:4] == b"II*\0"
        ifd, = struct.unpack_from("<I", data, 4)
        n, = struct.unpack_from("<H", data, ifd)
        fields = {}
        for i in range(n):
            tag, kind, count, offset = struct.unpack_from("<HHII", data, ifd + 2 + i * 12)
            length = {3: 2, 4: 4, 7: 1}[kind] * count
            index = ifd + 2 + i * 12 + 8 if length <= 4 else offset
            if kind in (3, 4):
                fields[tag] = struct.unpack_from("<" + ("H" if kind == 3 else "I") * count, data, index)
            else:
                fields[tag] = data[index:index + length]
        w, h = fields[256][0], fields[257][0]
        assert fields[258] == (32, 32, 32) and fields[339] == (3, 3, 3)
        assert (fields[259], fields[262], fields[274], fields[277], fields[284]) == ((1,), (2,), (1,), (3,), (1,))
        assert fields[34675][16:20] == b"RGB " and fields[34675][36:40] == b"acsp"
        offsets, lengths = fields[273], fields[279]
        assert len(offsets) == len(lengths) and sum(lengths) == w * h * 12
        assert all(start + size == end for start, size, end in zip(offsets, lengths, offsets[1:] + (len(data),)))
        stride = max(1, (w * h) // 16384)
        sampled = [struct.unpack_from("<fff", data, offsets[0] + 12 * i) for i in range(0, w * h, stride)]
        assert all(math.isfinite(v) for rgb in sampled for v in rgb)
        luma = sorted(.2126*r + .7152*g + .0722*b for r,g,b in sampled)
        assert luma[-1] > luma[0]
        return {"width": w, "height": h, "sampleCount": len(luma),
                "p01Luminance": luma[len(luma)//100], "p99Luminance": luma[len(luma)*99//100]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--scratch", required=True, type=Path)
    parser.add_argument("--case", required=True, choices=["starTrail", "hdr", "panorama"])
    parser.add_argument("--recipe", default="{}")
    parser.add_argument("--expect-failure")
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    folder = Path(tempfile.mkdtemp(prefix="case-", dir=args.scratch))
    os.chmod(folder, 0o700)
    image, receipt = folder / "master.tiff", folder / "receipt.json"
    frames = []
    for i, source in enumerate(args.files):
        h = sha(source)
        frames.append({"path": str(source.resolve()), "sha256": h, "byteCount": source.stat().st_size,
                       "fileID": f"file-{i}", "captureID": f"capture-{i}", "assetID": f"asset-{i}", "contentID": h})
    request = folder / "request.json"
    request.write_text(json.dumps({"jobID": "replay", "groupID":"private", "revision": 1,
                                   "operation": args.case, "recipe": json.loads(args.recipe),
                                   "frames": frames, "outputURL": image.as_uri()}))
    fingerprint = hashlib.sha256(b"".join(bytes.fromhex(x["sha256"]) for x in frames)).hexdigest()
    started = time.monotonic()
    proc = subprocess.run([str(args.worker.resolve()), str(request), str(receipt)], capture_output=True, text=True)
    elapsed = round(time.monotonic() - started, 2)
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    peak_mib = round(peak / (1024**2 if sys.platform == "darwin" else 1024), 1)
    if args.expect_failure:
        assert proc.returncode and not image.exists() and not receipt.exists(), "failure published output"
        assert args.expect_failure.lower() in proc.stderr.lower(), proc.stderr[-1500:]
        print(json.dumps({"case": args.case, "inputSetSHA256": fingerprint, "seconds":elapsed,
                          "workerPeakRSSMiB":peak_mib,"expectedFailure":args.expect_failure, "diagnostic":proc.stderr.strip().splitlines()[-1]}))
        return
    if proc.returncode:
        raise SystemExit(proc.stderr[-2500:])
    response = json.loads(receipt.read_text())
    measure = inspect_tiff(image)
    assert (response["width"],response["height"]) == (measure["width"],measure["height"])
    assert response["frameCount"] == 1 and response["format"] == "tiff32f"
    facts = response["facts"]
    assert [x["sha256"] for x in facts["inputs"]] == [x["sha256"] for x in frames]
    assert facts["outputSHA256"] == sha(image) and facts["outputByteCount"] == image.stat().st_size
    if args.case == "starTrail":
        winners = [x["winningOutputPixels"] for x in facts["inputs"]]
        assert sum(winners) == measure["width"]*measure["height"] and sum(x>0 for x in winners)>1
        measure.update({k:facts[k] for k in ("changedFromFirstPixels","medianStartIntervalSeconds",
                                              "maximumUnexposedSeconds","cadenceBreakIndices","foregroundReviewIndices",
                                              "foregroundUnknownIndices","referenceForegroundPixels","featheredForegroundPixels") if k in facts})
        measure["winningFrames"] = sum(x>0 for x in winners)
    elif args.case == "hdr":
        assert len({x["measuredExposureSeconds"] for x in facts["inputs"]}) > 1
        measure.update({k:facts[k] for k in ("referenceIndex","motionReferencePixels","zeroWeightReferenceFallbackPixels")})
        measure["registration"] = [x["registration"] for x in facts["inputs"]]
    else:
        assert facts["uncroppedOverlapPixels"]>0 and len(facts["overlapEdges"]) >= len(frames)-1
        measure.update({k:facts[k] for k in ("cropRect","uncroppedSize","uncroppedEmptyPixels","uncroppedOverlapPixels","overlapEdges")})
    measure.update({k:facts[k] for k in ("minimumSample","maximumSample","overOnePixels","outputSHA256","outputByteCount")})
    print(json.dumps({"case":args.case,"frames":len(frames),"seconds":elapsed,"workerPeakRSSMiB":peak_mib,"inputSetSHA256":fingerprint,**measure},
                     sort_keys=True))


if __name__ == "__main__":
    main()
