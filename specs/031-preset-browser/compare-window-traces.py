"""Compare matched preset/manual draws from two oppositely ordered diagnostic windows."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
from statistics import median


def require(value, message):
    if not value:
        raise ValueError(message)


def load_worker_phases(directory, requested):
    source = directory / "worker-phases.json"
    if not source.is_file():
        require(not requested, "missing requested worker phase trace")
        return None
    capture = json.loads(source.read_bytes())
    require(capture["overflow"] is False, "worker phase diagnostics overflowed")
    stages = defaultdict(list)
    for event in capture["phases"]:
        if event["kind"] == "render" and event["role"] == "primary":
            stages[event["phaseID"]].append(event)
    return stages


def worker_timings(stages, submission, publication, submitted, published):
    expected = ("admitted", "entered", "returned", "joined")
    events = stages.get(submission["submissionID"], [])
    require(tuple(event["phase"] for event in events) == expected, "missing or repeated worker phase for the submission")
    frames = stages.get(publication["frameID"], [])
    require(len(frames) == 1, "missing or repeated delivered worker frame")
    frame = frames[0]
    require(frame["phase"] == "frame" and frame["frameID"] == publication["frameID"], "worker frame identity differs")
    for event in [*events, frame]:
        require(event["sessionID"] == submission["leaseID"] and event["consumerID"] == submission["consumerID"]
                and event["sourceGeneration"] == submission["sourceGeneration"]
                and event["revision"] == submission["revision"] and event["quality"] == submission["quality"] == "settled"
                and event["maxPixel"] == 2400, "worker phase belongs to a different viewport request")
    stamps = [submitted, *(event["atNS"] for event in events), frame["atNS"], published]
    require(stamps == sorted(stamps), "worker phases differ from the monotonic submission and publication clocks")
    return {stage: (end - start) / 1e6 for stage, start, end in zip(
        ("submitToAdmission", "admissionToWorker", "workerToReturn", "returnToJoin", "joinToFrame", "frameToPublish"),
        stamps, stamps[1:])}


def window(directory, mirrored):
    receipt = json.loads((directory / "editing-interaction-performance.json").read_bytes())
    series = receipt["pairedExposure"]
    require(receipt["status"] == "diagnostic-complete" and series["mirrored"] is mirrored
            and series["countsTowardAcceptance"] is False and series["matchedRecipeAndExposurePairs"] == 31,
            "incomplete diagnostic window or wrong order")
    with (directory / "interaction.jsonl").open() as stream:
        events = [row for line in stream if (row := json.loads(line)).get("pane") == "primary"]
    publications = {e["frameID"]: e for e in events if e["event"] == "preview.publication"}
    submissions = {e["submissionID"]: e for e in events if e["event"] == "preview.submission" and "submissionID" in e}
    draws = {(e.get("frameID"), e["drawReturnedUptimeNanoseconds"]): e for e in events if e["event"] == "preview.draw-return"}
    worker_phases = load_worker_phases(directory, receipt.get("workerPhasesRequested", False))
    samples = {}
    for row in series["draws"]:
        pub = publications[row["frameID"]]
        sub = submissions[pub["submissionID"]]
        require((row["frameID"], row["drawReturnedNS"]) in draws, "missing the actual measured draw event")
        require(sub["operationID"] == pub["operationID"] and sub["revision"] == pub["revision"] == row["revision"]
                and sub["consumerID"] == pub["consumerID"] == row["consumerID"], "frame belongs to a different submission")
        submitted = round(sub["uptimeSeconds"] * 1e9)
        published = round(pub["uptimeSeconds"] * 1e9)
        times = [row["inputNS"], submitted, published, row["drawBeganNS"], row["drawReturnedNS"]]
        require(times == sorted(times), "inconsistent trace and monotonic draw clocks")
        if row["pair"] == 0:
            continue
        counters = row["previewCounters"]
        require(counters["renders"] + counters["bitmapHits"] == counters["submitted"] == 1, "ambiguous cache state")
        key = (row["pair"], row["path"], "render" if counters["renders"] else "bitmapHit")
        samples[key] = {
            "exposure": row["resultNativeExposure"], "recipe": row["resultRecipeSHA256"],
            "frameID": row["frameID"], "inputToSubmit": (submitted-times[0])/1e6,
            "submitToPublish": (published-submitted)/1e6, "publishToDrawBegin": (times[3]-published)/1e6,
            "draw": (times[4]-times[3])/1e6, "inputToDraw": (times[4]-times[0])/1e6,
        }
        if worker_phases is not None:
            draw = draws[(row["frameID"], row["drawReturnedNS"])]
            require(all(draw[key] == pub[key] == sub[key] for key in ("submissionID", "leaseID", "consumerID",
                    "sourceGeneration", "publicationEpoch", "channelID", "quality")), "AppKit trace identities differ")
            require(counters["renders"] == 1 and (row["width"], row["height"]) ==
                    (row["renderedWidth"], row["renderedHeight"]) == (2400, 1600), "worker trace needs a real settled viewport draw")
            samples[key].update(worker_timings(worker_phases, sub, pub, submitted, published))
    require(len(samples) == 60, "missing warm samples")
    return samples


def summarize(values):
    return {"medianMs": median(values), "p95Ms": sorted(values)[math.ceil(.95*len(values))-1]}


def matched_arms(samples, state):
    arms = {arm: [samples[(i, arm, state)] for i in range(1, 31)] for arm in ("preset", "manual")}
    for p, m in zip(arms["preset"], arms["manual"]):
        require((p["exposure"], p["recipe"]) == (m["exposure"], m["recipe"]), "uncoupled recipes")
    stages = ["inputToSubmit", "submitToPublish", "publishToDrawBegin", "draw", "inputToDraw"]
    if "workerToReturn" in arms["preset"][0]:
        stages += ["submitToAdmission", "admissionToWorker", "workerToReturn", "returnToJoin", "joinToFrame", "frameToPublish"]
    return {arm: {stage: summarize([r[stage] for r in rows]) for stage in stages} for arm, rows in arms.items()}


def compare(normal, mirror):
    a, b = window(normal, False), window(mirror, True)
    expected_renders = {(pair, arm, "render") for pair in range(1, 31) for arm in ("preset", "manual")}
    workers = [(path / "worker-phases.json").is_file() for path in (normal, mirror)]
    require(workers[0] == workers[1], "both windows must record worker phases")
    if workers[0]:
        one, two = (json.loads((path / "editing-interaction-performance.json").read_bytes()) for path in (normal, mirror))
        require(one["window"] == two["window"] and one["sourceSHA256"] == one["sourceSHA256After"]
                == two["sourceSHA256"] == two["sourceSHA256After"], "worker traces require the same source and window")
    if a.keys() == b.keys() == expected_renders:
        require(all((a[key]["exposure"], a[key]["recipe"]) == (b[key]["exposure"], b[key]["recipe"])
                    for key in expected_renders), "the two windows used different recipes")
        boundary = ("The native worker phases are CPU wall timestamps linked to the matching AppKit frame. "
                    "The join represents actor cleanup before frame delivery. GPU completion is unmeasured."
                    if workers[0] else "submission and publication are observed by the application. GPU completion is unmeasured.")
        return {"countsTowardAcceptance": False, "matchedExposureCountPerWindow": 30,
                "warmFramesWithMatchedTrace": len(a) + len(b),
                "actualRendersByWindow": {"normal": matched_arms(a, "render"), "mirror": matched_arms(b, "render")},
                "boundary": boundary}
    require(a.keys().isdisjoint(b), "the opposite run did not reverse cache state for each arm and exposure")
    samples = a | b
    return {"countsTowardAcceptance": False, "matchedExposureCountPerCacheState": 30,
            "warmFramesWithMatchedTrace": len(samples),
            "milliseconds": {state: matched_arms(samples, state) for state in ("render", "bitmapHit")},
            "boundary": "submission and publication are observed by the application. GPU completion is unmeasured."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("normal", type=Path)
    parser.add_argument("mirror", type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.normal, args.mirror), indent=2))
