"""Read a counterbalanced repetition of two frozen release test bundles."""
import hashlib
import json
import statistics
import zipfile

from paired_photo_operator_report import latency_limits, stats


def summarize(path, raw_sha):
    with zipfile.ZipFile(path) as archive:
        index = json.loads(archive.read("index.json"))
        old, new = index["reference"], index["candidate"]
        if (index["rawSHA256"] != raw_sha or not index["finishedAt"]
                or [r["origin"] for r in index["rounds"]] != [old,new,new,old]):
            raise ValueError("Incomplete A/B/B/A release control")
        builds, canvas, image_failures = {}, [], []
        interactive = {key:[] for key in index["interactiveOperations"]}
        controls = {key:[] for key in index["controlOperations"]}
        for run in index["rounds"]:
            origin, binary = run["origin"], run["binarySHA256"]
            if builds.setdefault(origin, binary) != binary:
                raise ValueError("The release executable changed during the repetitions")
            reports = {}
            for name, receipt in run["commands"].items():
                raw = archive.read(receipt["report"])
                if hashlib.sha256(raw).hexdigest() != receipt["sha256"]:
                    raise ValueError("Changed frozen repeat result")
                reports[name] = json.loads(raw)
            image = reports["image"]
            canvas.append(next(row["p95Milliseconds"] for row in image["metrics"] if row["name"] == "canvas_2_fit"))
            image_failures.append([gate["metric"] for gate in image["gates"] if not gate["passed"]])
            for report in (reports["interactive"], reports["controls"]):
                if report["binarySHA256"] != binary or report["sourceSHA256"] != raw_sha or report["sourceSHA256After"] != raw_sha:
                    raise ValueError("The repeated controls used a different source or executable")
            measurements = {r["label"]:r for r in reports["interactive"]["measurements"]}
            measured = {r["id"]:r for r in reports["controls"]["operations"]}
            if measured.keys() != controls.keys() or measurements.keys() != interactive.keys():
                raise ValueError("Repeated operation inventory changed")
            for key, row in measurements.items():
                interactive[key].append((row["interactiveMilliseconds"], row["settledMilliseconds"]))
            for key,row in measured.items():
                series = [s["ms"] for s in row["samples"] if s["phase"] == "warm"]
                if row["status"] != "measured" or len(series) != 20:
                    raise ValueError("Missing repeated verified control timings")
                controls[key].append(series)
    def paired_medians(series):
        return [statistics.median([*series[i], *series[j]]) for i,j in ((0,3),(1,2))]
    groups = {}
    for key, runs in interactive.items():
        first = paired_medians([r[0] for r in runs])
        final = paired_medians([[r[1]] for r in runs])
        groups[key] = {"interactiveMs":first,"settledMs":final,"interactiveWithin":first[1] <= 1.10*first[0],
                       "settledWithin":final[1] <= 1.20*final[0]}
    changes = {}
    for key, series in controls.items():
        prior, current = (stats([*series[i], *series[j]]) for i,j in ((0,3),(1,2)))
        changes[key] = {"previous":prior, "current":current, **latency_limits(prior, current)}
    return {"archive":"evidence/history/" + path.name,"builds":builds,"order":[old,new,new,old],
            "twoPhotoFitP95Ms":canvas,"imageGateFailures":image_failures,"interactive":groups,"controls":changes}
