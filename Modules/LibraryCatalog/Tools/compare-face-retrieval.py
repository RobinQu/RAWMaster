#!/usr/bin/env python3
"""Compare local face embeddings with thresholds fit only on earlier shooting days."""

import argparse
import collections
import itertools
import json
import os
from pathlib import Path
import resource
import time

import numpy as np


def sface_vectors(manifest, model, mirror):
    import cv2

    cv2.setNumThreads(2)
    t = time.perf_counter()
    recognizer = cv2.FaceRecognizerSF.create(str(model), "")
    init = 1000 * (time.perf_counter() - t)
    vectors, times = {}, []
    for f in manifest["faces"]:
        aligned = cv2.imread(f["alignedPath"], cv2.IMREAD_COLOR)
        if aligned is None or aligned.shape != (112, 112, 3):
            raise ValueError("unreadable aligned input")
        t = time.perf_counter()
        raw = recognizer.feature(aligned).flatten()
        if mirror:
            raw = normalize(raw) + normalize(recognizer.feature(cv2.flip(aligned, 1)).flatten())
        vectors[f["faceID"]] = normalize(raw).tolist()
        times.append((time.perf_counter() - t) * 1000)
    import hashlib
    return {
        "model": "SFace-flip" if mirror else "SFace",
        "weightsSHA256": hashlib.sha256(model.read_bytes()).hexdigest(),
        "weightBytes": model.stat().st_size,
        "dimensions": 128,
        "preprocessing": "YuNet five-point 112 BGR; normalized mirror mean" if mirror else "YuNet five-point 112 BGR",
        "latencyMs": {"coldStart": init, "first": times[0], "p50": float(np.median(times[1:])),
                      "p95": float(np.percentile(times[1:], 95)), "threads": 2},
        "peakRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "vectors": vectors,
    }


def normalize(row):
    v = np.asarray(row, dtype=np.float32)
    length = np.linalg.norm(v)
    if v.ndim != 1 or not np.isfinite(length) or length <= 1e-7:
        raise ValueError("expected a nonzero, finite feature vector")
    return v / length


def eligible(a, b, protocol):
    if a["imageID"] == b["imageID"]:
        return False
    if protocol == "all":
        return True
    if protocol in ("day", "camera-day", "body-day") and a["day"] == b["day"]:
        return False
    key = {"camera": "camera", "camera-day": "camera", "body-day": "body"}.get(protocol)
    return key is None or a[key] is not None and b[key] is not None and a[key] != b[key]


def split(manifest, stratified=True):
    rows = manifest["faces"] + manifest["unmapped"]
    days = sorted({f["day"] for f in rows})
    if stratified:
        totals = collections.Counter(f["personID"] for f in rows)
        if len(days) > 14:
            raise ValueError("use an explicit chronological split for more than 14 shooting days")

        def balance(group):
            counts = collections.Counter(f["personID"] for f in rows if f["day"] in group)
            return (min(min(counts[k], n - counts[k]) / n for k, n in totals.items()),
                    -sum(abs(2 * counts[k] - n) / n for k, n in totals.items()))

        early = set(max(itertools.combinations(days, len(days) // 2), key=balance))
    else:
        early = set(days[:len(days) // 2])
    return ([r for r in rows if r["day"] in early],
            [r for r in rows if r["day"] not in early])


def pairs(query, gallery, protocol, similarities):
    same, different = [], []
    seen = set()
    for a in query:
        for b in gallery:
            key = tuple(sorted((a["faceID"], b["faceID"])))
            if key in seen or not eligible(a, b, protocol):
                continue
            seen.add(key)
            score = similarities.get(key)
            if score is not None:
                (same if a["personID"] == b["personID"] else different).append(score)
    return np.array(same), np.array(different)


def max_templates(refs, features, limit):
    # Deduplicate copies/exports of the same photo. Enrol reliable individual views.
    items = sorted(
        refs, key=lambda f: (-f["detectionScore"] * (f["box"][2] * f["box"][3]) ** 0.5, f["faceID"])
    )
    poses, photos = [], set()
    for row in items:
        if row["imageID"] in photos:
            continue
        poses.append(row)
        photos.add(row["imageID"])
    if limit is None or len(poses) <= limit:
        return poses
    selected = [poses.pop(0)]
    while len(selected) < limit:
        def score(f):
            return max(float(np.dot(features[f["faceID"]], features[g["faceID"]])) for g in selected)
        selected.append(poses.pop(min(range(len(poses)), key=lambda j: score(poses[j]))))
    return selected


def retrieval_cases(queries, gallery, protocol, similarities, features, template_limit, top_two=False, independent_events=False):
    cases = []
    for q in queries:
        by_person = collections.defaultdict(list)
        for ref in gallery:
            if ref["faceID"] in features and eligible(q, ref, protocol):
                by_person[ref["personID"]].append(ref)
        if not by_person:
            continue
        true_person = q["personID"]
        scores = {}
        if q["faceID"] in features:
            for person, refs in by_person.items():
                exemplars = max_templates(refs, features, template_limit)
                if independent_events:
                    by_event = {}
                    for reference in exemplars:
                        by_event.setdefault((reference["day"], reference["body"]), reference)
                    exemplars = list(by_event.values())
                scores_by_shot = sorted(
                    (similarities[tuple(sorted((q["faceID"], ref["faceID"])))] for ref in exemplars),
                    reverse=True,
                )
                count = min(len(scores_by_shot), 2) if top_two else 1
                scores[person] = sum(scores_by_shot[:count]) / count
        ranked = sorted(scores.items(), key=lambda p: (-p[1], p[0]))
        unknown_ranked = [item for item in ranked if item[0] != true_person]
        cases.append({
            "actual": true_person,
            "hasReference": true_person in by_person,
            "distractors": any(person != true_person for person in by_person),
            "ranked": ranked,
            "withoutIdentity": unknown_ranked,
            "queryEmbeddable": q["faceID"] in features,
        })
    return cases


def decision(ranked, cutoff, margin, singleton_increment):
    if not ranked:
        return None
    person, score = ranked[0]
    if len(ranked) == 1:
        return person if score >= cutoff + singleton_increment else None
    return person if score >= cutoff and score - ranked[1][1] >= margin else None


def results(cases, cutoff, margin, singleton_increment, detailed=False):
    counts = collections.Counter()
    per_person = collections.defaultdict(collections.Counter)
    for case in cases:
        person = case["actual"]
        ranked = case["ranked"]
        if case["hasReference"]:
            counts["known"] += 1
            per_person[person]["known"] += 1
            if case["distractors"]:
                counts["knownWithDistractors"] += 1
                counts["rankTop1WithDistractors"] += bool(ranked and ranked[0][0] == person)
            counts["detectedKnown"] += case["queryEmbeddable"]
            counts["rankTop1"] += bool(ranked and ranked[0][0] == person)
            predicted = decision(ranked, cutoff, margin, singleton_increment)
            counts["correctAccepted"] += predicted == person
            per_person[person]["correctAccepted"] += predicted == person
            counts["wrongAccepted"] += predicted is not None and predicted != person
            counts["knownAbstained"] += predicted is None
        if case["distractors"]:
            counts["absentIdentity"] += 1
            counts["absentWrongAccepted"] += decision(case["withoutIdentity"], cutoff, margin, singleton_increment) is not None
        if not case["hasReference"] and case["distractors"]:
            counts["actuallyAbsentIdentity"] += 1
            counts["actuallyAbsentWrongAccepted"] += decision(ranked, cutoff, margin, singleton_increment) is not None
    columns = ("known", "detectedKnown", "knownWithDistractors", "rankTop1", "rankTop1WithDistractors",
               "correctAccepted", "wrongAccepted", "knownAbstained", "absentIdentity", "absentWrongAccepted",
               "actuallyAbsentIdentity", "actuallyAbsentWrongAccepted")
    scores = {k: counts[k] for k in columns}
    if detailed:
        scores["identitiesWithKnownQueries"] = len(per_person)
        scores["macroRecall"] = round(np.mean([p["correctAccepted"]/p["known"] for p in per_person.values()]), 6) if per_person else None
    return scores


def select_gate(cases):
    # Predeclared grid. Seek a conservative reviewer, selecting for macro recall
    # while requiring zero early known misroutes and zero early absent-ID matches.
    candidates = []
    for cutoff, margin, single in itertools.product(np.arange(0.20, 0.90, 0.02), (0.04, 0.08, 0.12), (0.04, 0.08)):
        cutoff = round(float(cutoff), 2)
        v = results(cases, cutoff, margin, single, detailed=True)
        if v["wrongAccepted"] + v["absentWrongAccepted"] == 0:
            candidates.append((v["macroRecall"] or 0, v["correctAccepted"], cutoff + margin + single,
                               cutoff, margin, single, v))
    if not candidates:
        return {"minimum": 0.94, "margin": 0.12, "soloIncrement": 0.04,
                "fit": results(cases, 0.94, 0.12, 0.04, detailed=True)}
    _, _, _, threshold, margin, single, counts = max(candidates, key=lambda a: a[:-1])
    return {"minimum": threshold, "margin": margin, "soloIncrement": single, "fit": counts}


def pair_report(positive, negative, threshold):
    both = len(positive) > 0 and len(negative) > 0
    auc = None
    if both:
        delta = positive[:, None] - negative[None, :]
        auc = round(float(np.mean((delta > 0) + 0.5 * (delta == 0))), 6)
    return {"positive": len(positive), "negative": len(negative), "acceptedPositive": int(np.sum(positive >= threshold)),
            "acceptedNegative": int(np.sum(negative >= threshold)), "auc": auc}


def measure(manifest, descriptor, fixed_gate=None):
    faces = manifest["faces"]
    features = {k: normalize(v) for k, v in descriptor["vectors"].items()}
    if set(features) != {f["faceID"] for f in faces}:
        raise ValueError(f"{descriptor['model']} returned a different set of faces")
    if len({v.shape for v in features.values()}) != 1:
        raise ValueError("mixed vector dimensions")
    keys = sorted(features)
    weights = np.array([features[k] for k in keys])
    sim = weights @ weights.T
    similarities = {(a, b): float(sim[i, j]) for i, a in enumerate(keys) for j, b in enumerate(keys) if i < j}
    calibration, audit = split(manifest)
    early, later = split(manifest, stratified=False)
    best = {}
    stress = {}
    for limit in (1, 8, None):
        cases = retrieval_cases(calibration, calibration, "day", similarities, features, limit)
        gate = select_gate(cases)
        name = "all" if limit is None else str(limit)
        best[name] = {
            **gate,
            "heldOut": {
                p: results(retrieval_cases(audit, calibration, p, similarities, features, limit),
                           gate["minimum"], gate["margin"], gate["soloIncrement"], detailed=True)
                for p in ("day", "camera-day", "body-day")
            },
        }
        stress[name] = {
            p: results(retrieval_cases(later, early, p, similarities, features, limit),
                       gate["minimum"], gate["margin"], gate["soloIncrement"], detailed=True)
            for p in ("day", "camera-day", "body-day")
        }
    gate = best["8"]
    gate_value = gate["minimum"]
    output = {k: v for k, v in descriptor.items() if k != "vectors"}
    output["pairCalibration"] = {}
    output["pairs"] = {}
    output["retrieval"] = best
    output["chronologicalStress"] = stress
    if fixed_gate:
        cutoff, margin, single = fixed_gate

        def replay(queries, gallery, top_two, independent_events=False):
            return {
                p: results(retrieval_cases(queries, gallery, p, similarities, features, 8,
                                           top_two=top_two, independent_events=independent_events),
                           cutoff, margin, single, detailed=True)
                for p in ("day", "camera-day", "body-day")
            }

        output["fixedGate"] = {
            "minimum": cutoff, "margin": margin, "soloIncrement": single,
            "maximum": {"holdout": replay(audit, calibration, False),
                        "chronologicalStress": replay(later, early, False)},
            "meanOfTopTwo": {"holdout": replay(audit, calibration, True),
                             "chronologicalStress": replay(later, early, True)},
            "atMostOneReferencePerDayAndBody": replay(audit, calibration, True, independent_events=True),
        }
    output["previousFixed080"] = {
        p: results(retrieval_cases(audit, calibration, p, similarities, features, None), 0.8, 0, 0, detailed=True)
        for p in ("day", "camera-day", "body-day")
    }
    for p in ("day", "camera-day", "body-day", "all"):
        pos, neg = pairs(calibration, calibration, p, similarities)
        same, diff = pairs(audit, calibration, p, similarities)
        output["pairCalibration"][p] = pair_report(pos, neg, gate_value)
        output["pairs"][p] = pair_report(same, diff, gate_value)
        output["pairs"][p]["aboveOld080"] = pair_report(same, diff, 0.80)
    return output


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest", required=True, type=Path)
    p.add_argument("--sface", type=Path)
    p.add_argument("--vectors", type=Path, nargs="*", default=[])
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--native-fixture", type=Path, help="Write a private native host fixture with held-out enrolment roles")
    p.add_argument("--fixed-gate", type=float, nargs=3, metavar=("CUTOFF", "MARGIN", "SOLO"))
    args = p.parse_args()
    manifest = json.loads(args.manifest.read_text())
    variants = [json.loads(path.read_text()) for path in args.vectors]
    if args.sface:
        variants.extend(sface_vectors(manifest, args.sface, flip) for flip in (False, True))
    if any("SFace" == v["model"] for v in variants):
        sface = next(v for v in variants if v["model"] == "SFace")
        for v in list(variants):
            if "retail-0095" in v["model"] and v["model"].endswith("-ort"):
                variants.append({
                    "model": "SFace+Intel-0095",
                    "weightsSHA256": [sface["weightsSHA256"], v["weightsSHA256"]],
                    "weightBytes": sface["weightBytes"] + v["weightBytes"],
                    "dimensions": sface["dimensions"] + v["dimensions"],
                    "preprocessing": "Normalize each recognition vector, concatenate with equal weights",
                    "latencyMs": {"timedRegion": "Individual embedding models timed separately"},
                    "vectors": {k: np.concatenate((normalize(x), normalize(v["vectors"][k]))).tolist()
                                for k, x in sface["vectors"].items()},
                })
    if not variants:
        p.error("provide --sface or --vectors")
    calibration, audit = split(manifest)
    result = {
        "detector": manifest["metadata"],
        "protocol": {
            "referenceAndCalibrationDays": len({f["day"] for f in calibration}),
            "holdoutDays": len({f["day"] for f in audit}),
            "calibrationTruthFaces": len(calibration),
            "holdoutTruthFaces": len(audit),
            "allTruthIdentities": len({f["personID"] for f in calibration + audit}),
            "originalsWithKnownBody": len({f["imageID"] for f in calibration + audit if f["body"] is not None}),
            "bodyCount": len({f["body"] for f in calibration + audit if f["body"] is not None}),
            "holdout": "shooting days split in half by label balance before scoring; thresholds and gallery use only the reference dates",
            "chronologicalStress": "use the earliest half as gallery, then search on later dates with the balanced split gate",
            "unknown": "remove the true identity while retaining the other identities",
            "eligibility": "different source photo; apply differing dates, camera models or known body serials as labeled",
        },
        "models": [measure(manifest, model, args.fixed_gate) for model in variants],
    }
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    if args.native_fixture:
        references = {f["imageID"] for f in calibration}
        metadata = ("faceID", "imageID", "personID", "day", "body", "truthBox")
        truth = [{k: f[k] for k in metadata if k in f} for f in manifest["faces"] + manifest["unmapped"]]
        fixture = {"photos": [{**f, "reference": f["imageID"] in references} for f in manifest["photos"]],
                   "truth": truth}
        descriptor = os.open(args.native_fixture, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w") as output_file:
            json.dump(fixture, output_file)



if __name__ == "__main__":
    main()
