"""Compare matched preset/manual draws from two oppositely ordered diagnostic windows."""
import argparse
import json
import math
from pathlib import Path
from statistics import median


def require(value, message):
    if not value:
        raise ValueError(message)


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
    draws = {(e.get("frameID"), e["drawReturnedUptimeNanoseconds"]) for e in events if e["event"] == "preview.draw-return"}
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
    require(len(samples) == 60, "missing warm samples")
    return samples


def summarize(values):
    return {"medianMs": median(values), "p95Ms": sorted(values)[math.ceil(.95*len(values))-1]}


def compare(normal, mirror):
    a, b = window(normal, False), window(mirror, True)
    require(a.keys().isdisjoint(b), "the opposite run did not reverse cache state for each arm and exposure")
    samples = a | b
    stages = ["inputToSubmit", "submitToPublish", "publishToDrawBegin", "draw", "inputToDraw"]
    groups = {}
    for state in ("render", "bitmapHit"):
        arms = {arm: [samples[(i, arm, state)] for i in range(1, 31)] for arm in ("preset", "manual")}
        for p, m in zip(arms["preset"], arms["manual"]):
            require((p["exposure"], p["recipe"]) == (m["exposure"], m["recipe"]), "uncoupled recipes")
        groups[state] = {arm: {stage: summarize([r[stage] for r in rows]) for stage in stages} for arm, rows in arms.items()}
    return {"countsTowardAcceptance": False, "matchedExposureCountPerCacheState": 30,
            "warmFramesWithMatchedTrace": len(samples), "milliseconds": groups,
            "boundary": "submission and publication are observed by the application. GPU completion is unmeasured."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("normal", type=Path)
    parser.add_argument("mirror", type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.normal, args.mirror), indent=2))
