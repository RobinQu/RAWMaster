#!/usr/bin/env python3
"""Compare local detections to confirmed Lightroom face regions. Never export names or images."""

import argparse
import collections
import concurrent.futures
import hashlib
import itertools
import json
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from PIL import Image, ImageOps
import numpy as np

sys.path.insert(
    0, str(Path(__file__).resolve().parents[1] / "Swift/Resources/discovery")
)
from worker import Runtime, digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--catalog",
        required=True,
        type=Path,
        help="read-only Lightroom snapshot with reachable source files",
    )
    ap.add_argument("--models", required=True, type=Path)
    ap.add_argument(
        "--scratch",
        required=True,
        type=Path,
        help="private local disposable space for proxies",
    )
    ap.add_argument(
        "--output", required=True, type=Path, help="anonymous aggregate metrics JSON"
    )
    args = ap.parse_args()
    db = sqlite3.connect(args.catalog.resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    db.execute("BEGIN")
    sql = """SELECT f.id_local AS faceID,k.tag, f.image,f.tl_x,f.tl_y,f.tr_x,f.tr_y,f.bl_x,f.bl_y,f.br_x,f.br_y,f.imageOrientation,
      i.rootFile,i.captureTime,fi.baseName,fi.extension,fo.pathFromRoot,root.absolutePath
      FROM AgLibraryKeywordFace k JOIN AgLibraryFace f ON f.id_local=k.face JOIN Adobe_images i ON i.id_local=f.image
      JOIN AgLibraryFile fi ON fi.id_local=i.rootFile JOIN AgLibraryFolder fo ON fo.id_local=fi.folder
      JOIN AgLibraryRootFolder root ON root.id_local=fo.rootFolder
      WHERE k.userPick=1 AND coalesce(k.userReject,0)=0 AND coalesce(f.ignored,0)=0 ORDER BY k.rowid"""
    private = []
    for row in db.execute(sql):
        r = dict(row)
        r["native"] = str(
            Path(r.pop("absolutePath"))
            / r.pop("pathFromRoot")
            / (r.pop("baseName") + "." + r.pop("extension"))
        )
        private.append(r)
    dest = args.scratch.resolve() / digest(args.catalog)[:16]
    dest.mkdir(parents=True, exist_ok=True, mode=0o700)
    cams = dict(db.execute("select image,cameraModelRef from AgHarvestedExifMetadata"))
    photos = {}
    for row in private:
        key = row["rootFile"]
        photos.setdefault(key, []).append(row)
    out = dest

    def extract(item):
        n, (key, rows) = item
        src = Path(rows[0]["native"])
        if not src.is_file():
            return key, None
        fingerprint = hashlib.sha256(
            (str(src) + str(src.stat().st_mtime_ns) + str(src.stat().st_size)).encode()
        ).hexdigest()
        p = out / (fingerprint + ".jpg")
        if not p.exists():
            a = subprocess.run(
                [
                    "sips",
                    "-s",
                    "format",
                    "jpeg",
                    "-Z",
                    "1024",
                    str(src),
                    "--out",
                    str(p),
                ],
                capture_output=True,
            )
            if a.returncode or not p.is_file():
                return key, None
        return key, p

    runtime = Runtime(args.models)
    outputs = {}
    timings = []
    errors = []
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        for key, path in pool.map(extract, enumerate(sorted(photos.items()))):
            if not path:
                errors.append("decode")
                continue
            try:
                t = time.perf_counter()
                v = runtime.run(
                    {"version": 1, "op": "faces", "proxy": str(path.resolve())}
                )["faces"]
                timings.append((time.perf_counter() - t) * 1000)
                with Image.open(path) as im:
                    ex = im.getexif()
                    exif_time = ex.get_ifd(34665).get(36867)
                    pw, ph = ImageOps.exif_transpose(im).size
                if not exif_time or exif_time[:19].replace(":", "").replace(
                    "-", ""
                ).replace(" ", "").replace("T", "") != photos[key][0]["captureTime"][
                    :19
                ].replace(":", "").replace("-", "").replace(" ", "").replace("T", ""):
                    errors.append("captureTimeMismatch")
                    continue
                outputs[key] = {"faces": v, "time": exif_time, "w": pw, "h": ph}
            except Exception as e:
                errors.append(str(type(e)))

    # The earliest 3 shooting days containing both reported camera orientations
    # calibrate only the coordinate convention; all model settings remain frozen.
    days = sorted(set(r["captureTime"][:10] for r in private))
    orient = sorted(set(r["imageOrientation"] for r in private))
    cal_days = []
    for day in days:
        cal_days.append(day)
        counts = collections.Counter(
            r["imageOrientation"] for r in private if r["captureTime"][:10] in cal_days
        )
        if len(cal_days) >= 3 and all(counts[o] >= 2 for o in orient):
            break

    def transformed(r, k):
        pts = np.array([[r[a + "_x"], r[a + "_y"]] for a in ["tl", "tr", "bl", "br"]])
        x, y = pts[:, 0], pts[:, 1]
        swap, fx, fy = ((k >> 2) & 1, (k >> 1) & 1, k & 1)
        if swap:
            x, y = y, x
        if fx:
            x = 1.0 - x
        if fy:
            y = 1.0 - y
        return [x.min(), y.min(), x.max() - x.min(), y.max() - y.min()]

    def iou(a, b):
        d = max(min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]), 0) * max(
            min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]), 0
        )
        return d / (a[2] * a[3] + b[2] * b[3] - d)

    def overlaps(r, k):
        obs = outputs.get(r["rootFile"], {}).get("faces", [])
        box = transformed(r, k)
        return [(iou(box, f["box"]), i) for i, f in enumerate(obs)]

    mapping = {}
    fit = {}
    for o in orient:
        data = [
            r
            for r in private
            if r["imageOrientation"] == o and r["captureTime"][:10] in cal_days
        ]
        scores = [
            sum(max([v for v, i in overlaps(r, k)], default=0.0) for r in data)
            for k in range(8)
        ]
        mapping[o] = int(np.argmax(scores))
        fit[o] = {
            "observations": len(data),
            "best": max(scores),
            "second": sorted(scores)[-2],
        }

    def classified(r):
        if r["rootFile"] not in outputs:
            return
        box = overlaps(r, mapping[r["imageOrientation"]])
        box.sort(reverse=True)
        if not box or box[0][0] < 0.35 or len(box) > 1 and box[1][0] >= 0.35:
            return
        ix = box[0][1]
        return r["rootFile"], ix

    matched = []
    unused = 0
    for key, rows in photos.items():
        vals = [classified(r) for r in rows]
        for r, cand in zip(rows, vals):
            if cand and vals.count(cand) == 1:
                f = outputs[key]["faces"][cand[1]]
                matched.append(
                    {
                        "label": r["tag"],
                        "day": r["captureTime"][:10],
                        "camera": cams.get(r["image"]),
                        "image": key,
                        "vector": f["vector"],
                    }
                )
            else:
                unused += 1

    def pairs(items):
        out = {}
        for group in ["all", "crossDay", "crossCamera", "crossDayAndCamera"]:
            same = diff = accepted = wrong = 0
            for a, b in itertools.combinations(items, 2):
                if group in ["crossDay", "crossDayAndCamera"] and a["day"] == b["day"]:
                    continue
                if group in ["crossCamera", "crossDayAndCamera"] and (
                    a["camera"] is None
                    or b["camera"] is None
                    or a["camera"] == b["camera"]
                ):
                    continue
                score = np.einsum(
                    "i,i->",
                    np.array(a["vector"]),
                    np.array(b["vector"]),
                    optimize=False,
                )
                if a["label"] == b["label"]:
                    same += 1
                    accepted += int(score >= 0.50 and a["image"] != b["image"])
                else:
                    diff += 1
                    wrong += int(score >= 0.50 and a["image"] != b["image"])
            out[group] = {
                "positive": same,
                "aboveCutoffPositive": accepted,
                "negative": diff,
                "aboveCutoffNegative": wrong,
            }
        return out

    def clusters(items):
        groups = []
        for n, a in enumerate(items):
            choices = []
            for i, g in enumerate(groups):
                if any(items[j]["image"] == a["image"] for j in g):
                    continue
                score = min(
                    float(
                        np.einsum(
                            "i,i->", a["vector"], items[j]["vector"], optimize=False
                        )
                    )
                    for j in g
                )
                if score >= 0.5:
                    choices.append((score, -i))
            if not choices:
                groups.append([n])
            else:
                groups[-max(choices)[1]].append(n)
        wrong = retained = 0
        for g in groups:
            for a, b in itertools.combinations(g, 2):
                if items[a]["label"] == items[b]["label"]:
                    retained += 1
                else:
                    wrong += 1
        return {
            "groups": len(groups),
            "singletons": sum(len(g) == 1 for g in groups),
            "coClusterSame": retained,
            "coClusterDifferent": wrong,
        }

    hold = [r for r in matched if r["day"] not in cal_days]
    dated = [
        (v["time"], photos[k][0]["captureTime"])
        for k, v in outputs.items()
        if v.get("time")
    ]

    def normalized(t):
        return (
            t[:19].replace(":", "").replace("-", "").replace(" ", "").replace("T", "")
        )

    result = {
        "format": 1,
        "labelSource": "AgLibraryKeywordFace.userPick=1,userReject=0, matched original path",
        "inputFiles": len(photos),
        "humanBoxes": len(private),
        "humanIdentities": len(set(r["tag"] for r in private)),
        "shootDates": len(days),
        "cameraModels": len(
            set(c for r in private if (c := cams.get(r["image"])) is not None)
        ),
        "inputDecodeErrors": len(errors),
        "comparedCaptureTimes": len(dated),
        "matchingCaptureTimes": sum(normalized(a) == normalized(b) for a, b in dated),
        "calibrationDates": len(cal_days),
        "heldoutDates": len(days) - len(cal_days),
        "coordinateMappings": mapping,
        "coordinateCalibration": fit,
        "iouCutoff": 0.35,
        "detectedBoxes": sum(len(r["faces"]) for r in outputs.values()),
        "allMatched": len(matched),
        "unmatchedOrAmbiguous": unused,
        "heldoutHumanBoxes": sum(
            r["captureTime"][:10] not in cal_days for r in private
        ),
        "heldoutMatched": len(hold),
        "heldoutIdentities": len(set(r["label"] for r in hold)),
        "heldoutPairCounts": pairs(hold),
        "allPairCounts": pairs(matched),
        "heldoutClusters": clusters(hold),
        "latencyIncludingDecodeMsP50": float(np.median(timings)),
    }

    # Date-stratification uses the known Lightroom class counts only. Scores never
    # determine membership in calibration or audit. Tie break by calendar order.
    identities = sorted({r["tag"] for r in private})
    target = collections.Counter(r["tag"] for r in private)

    def balance(cal):
        cnt = collections.Counter(
            r["tag"] for r in private if r["captureTime"][:10] in cal
        )
        return (
            min(min(cnt[i], target[i] - cnt[i]) / target[i] for i in identities),
            -sum(abs(2 * cnt[i] - target[i]) / target[i] for i in identities),
        )

    split = max(itertools.combinations(days, len(days) // 2), key=balance)
    train = [r for r in matched if r["day"] in split]
    test = [r for r in matched if r["day"] not in split]

    def sims(photos):
        return [
            (
                a["label"] == b["label"],
                float(np.einsum("i,i->", a["vector"], b["vector"])),
                a["day"] != b["day"],
                a["camera"] is not None
                and b["camera"] is not None
                and a["camera"] != b["camera"],
            )
            for a, b in itertools.combinations(photos, 2)
            if a["image"] != b["image"]
        ]

    tr = sims(train)
    te = sims(test)
    largest = max(s for match, s, *_ in tr if not match)
    cut = next(
        (c for c in [0.6, 0.65, 0.70, 0.75, 0.8, 0.85, 0.9] if c >= largest + 0.03), 1.0
    )

    def metric(rows, th):
        result = {}
        for name, cond in [
            ("all", lambda d, c: True),
            ("crossDay", lambda d, c: d),
            ("crossCamera", lambda d, c: c),
            ("crossDayAndCamera", lambda d, c: d and c),
        ]:
            filtered = [(y, s) for y, s, d, c in rows if cond(d, c)]
            result[name] = {
                "same": sum(y for y, s in filtered),
                "different": sum(not y for y, s in filtered),
                "acceptedSame": sum(y and s >= th for y, s in filtered),
                "acceptedDifferent": sum(not y and s >= th for y, s in filtered),
            }
        return result

    def cluster_metric(items, threshold):
        # This fixture supplies stable anonymous work keys. Sort observations just as
        # the native candidate reader does. No label enters the grouping algorithm.
        groups = []
        order = sorted(
            range(len(items)),
            key=lambda k: hashlib.sha256(
                repr((items[k]["image"], k)).encode()
            ).hexdigest(),
        )
        for j in order:
            a = items[j]
            matches = []
            for n, g in enumerate(groups):
                if any(items[i]["image"] == a["image"] for i in g):
                    continue
                score = min(
                    np.einsum("i,i->", a["vector"], items[i]["vector"]) for i in g
                )
                if score >= threshold:
                    matches.append((float(score), -n))
            if matches:
                groups[-max(matches)[1]].append(j)
            else:
                groups.append([j])
        pairs = [
            items[i]["label"] == items[j]["label"]
            for g in groups
            for i, j in itertools.combinations(g, 2)
        ]
        return {
            "groups": len(groups),
            "singletons": sum(len(g) == 1 for g in groups),
            "togetherSame": sum(pairs),
            "togetherDifferent": sum(not p for p in pairs),
        }

    outdata = {
        "calibrationRule": "five whole dates split by balance of confirmed source identities; smallest 0.05-grid cutoff above maximum calibration impostor score plus 0.03",
        "priorObservedAllDatesAt0.50": True,
        "newCutoff": cut,
        "calibrationMaxDifferent": largest,
        "calibrationDays": len(split),
        "auditDays": len(days) - len(split),
        "calibrationMatched": len(train),
        "auditHumanBoxes": sum(r["captureTime"][:10] not in split for r in private),
        "auditMatched": len(test),
        "auditIdentities": len(set(r["label"] for r in test)),
        "calibrationPairs": metric(tr, cut),
        "auditPairs": metric(te, cut),
        "auditClusters": cluster_metric(test, cut),
        "auditAtPriorThreshold": metric(te, 0.50),
    }

    table = []
    for t in [0.5, 0.6, 0.65, 0.70, 0.75, 0.80, 0.85, 0.9]:
        table.append(
            {
                "threshold": t,
                "audit": metric(te, t)["all"],
                "auditCrossDateAndCamera": metric(te, t)["crossDayAndCamera"],
                "auditGroups": cluster_metric(test, t),
                "allMatched": metric(sims(matched), t)["all"],
                "allGroups": cluster_metric(matched, t),
            }
        )
    args.output.write_text(
        json.dumps(
            {
                "detection": result,
                "daySplit": outdata,
                "sensitivity": table,
                "operatingPoint": 0.80,
                "releaseNote": "Chosen conservatively following the recorded sweep; wider independent identity validation is outstanding.",
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
