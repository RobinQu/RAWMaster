"""Validate and join original LightFlow controls with engine-, editor- and scope-specific endpoints."""

import hashlib
import json
import math
import re


PHOTO_CONTROLS = {
    "mixer-tat",
    "color-skin-indicator",
    "curve-parametric",
    "curve-input-output",
    "curve-keyboard",
    "curve-reset-channel",
    "optics-profile-enable",
}
COLORS = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]


def require(test, message):
    if not test:
        raise ValueError(message)


def digest(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None


def json_digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def alternating(row, repeats):
    trials = row["trials"]
    require(
        len(trials) == repeats + 2 and repeats >= 10,
        f"Incomplete sample population for {row['id']}",
    )
    for i, t in enumerate(trials):
        require(
            t["state"] == i % 2
            and t["phase"] == ("first" if i < 2 else "warm")
            and t["ms"] > 0
            and math.isfinite(t["ms"])
            and digest(t["digest"]),
            f"Invalid input or observation for {row['id']}",
        )
    return trials


def two_states(trials):
    groups = [{t["digest"] for t in trials if t["state"] == state} for state in (0, 1)]
    require(
        all(len(g) == 1 for g in groups) and groups[0] != groups[1],
        "Output must repeat within and differ between states",
    )


def validate_hue(row, report):
    trials, base = row["trials"], row["referenceRegions"]
    require(
        row["id"] == "color-mask-hue"
        and row["field"] == "wheels.hue"
        and row["localMask"]
        and row["fixed"] == {"wheels.hue": 50}
        and row["texture"] == [2400, 1600]
        and report["target"] == {"kind": "image", "maxSize": 2400, "exact": True},
        "Invalid local hue setup",
    )
    require(
        len(trials) == report["samples"] + 1 == 21
        and row["referenceDigest"] == base["all"]
        and (base["insideCount"], base["outsideCount"]) == (416, 1640),
        "Missing radial mask controls",
    )
    for i, t in enumerate(trials):
        r = t["regions"]
        require(
            t["phase"] == ("first-in-session" if i == 0 else "warm")
            and t["verified"]
            and r["insideCount"] == base["insideCount"]
            and r["outsideCount"] == base["outsideCount"]
            and all(digest(r[k]) for k in ("all", "inside", "outside"))
            and r["all"] == t["digest"]
            and r["inside"] != base["inside"]
            and r["outside"] == base["outside"],
            "Masked hue did not isolate a real change to the radial interior",
        )
    require(
        len({t["value"] for t in trials})
        == len(trials)
        == len({t["digest"] for t in trials}),
        "Local hue samples must exercise distinct parameter values and photos",
    )
    return trials


def validate_vector(row, report):
    require(
        row["id"] == "color-vectorscope"
        and report["protocol"] == "lightflow-vectorscope-trace-readback-v1"
        and report["pixels"] == [256, 168]
        and [s["saturation"] for s in report["sources"]] == [0, 70]
        and all(s["pixels"] == [1024, 683] for s in report["sources"]),
        "Invalid vectorscope area or inputs",
    )
    trials = alternating(row, report["samples"])
    for t in trials:
        require(
            t["stats"]["samples"] == 1024 * 683
            and (t["stats"]["cols"], t["stats"]["rows"]) == (256, 256)
            and t["coloredPixels"] > 5
            and t["totalRGBChroma"] > t["coloredPixels"] * 3,
            "Incomplete original scope trace",
        )
    two_states(trials)
    require(
        trials[0]["coloredPixels"] < trials[1]["coloredPixels"],
        "Saturation did not expand the measured trace",
    )
    return trials


def validate_skin(row, trials):
    coords = row["calibratedCoordinates"]
    require(
        len(coords) >= 6
        and len(set(map(tuple, coords))) == len(coords)
        and row["scopeTraceWidth"] > 30,
        "Insufficient independent pixels on the skin ray",
    )
    refs = [trials[0]["rayRGB"], trials[1]["rayRGB"]]
    require(
        all(max(abs(c - d) for c, d in zip(a, b)) >= 12 for a, b in zip(*refs)),
        "Insufficient ray calibration contrast",
    )

    def distance(a, b):
        return sum(abs(c - d) for c, d in zip(a, b))

    for t in trials:
        s = t["state"]
        colors = t["rayRGB"]
        o = t["observed"]
        require(
            o["line"] == o["state"] == bool(s)
            and o["checked"] == str(bool(s)).lower()
            and len(colors) == len(coords)
            and t["hostToCapturedPixelsMs"] > 0,
            "Stock checkbox, original line and readback disagree",
        )
        agreement = sum(
            distance(v, refs[s][i]) < distance(v, refs[1 - s][i])
            for i, v in enumerate(colors)
        ) / len(colors)
        require(
            abs(agreement - t["agreement"]) < 1e-8
            and agreement >= 0.9
            and t["verified"]
            and hashlib.sha256(bytes(c for p in colors for c in p)).hexdigest()
            == t["digest"],
            "Original pixel ray does not agree with the committed state",
        )


def validate_curves(row, trials):
    key = row["id"]
    for t in trials:
        o = t["observed"]
        state = t["state"]
        if key == "curve-reset-channel":
            channel = ["red", "green"][state]
            require(
                o["changedChannel"] == channel
                and len(o["before"][channel]) == 3
                and o["after"][channel] == [[0, 0], [1, 1]]
                and len(o["after"]["blue"]) == 3
                and all(
                    o["before"][k] == v for k, v in o["after"].items() if k != channel
                ),
                "Channel reset changed a protected curve or left a non-linear channel",
            )
            witness = [channel, o["after"]]
        elif key == "curve-parametric":
            value = [-40, 40][state]
            require(
                o["width"] > 64
                and o["height"] > 32
                and digest(o["hash"])
                and set(dict(o["fields"]))
                == {"Shadows", "Darks", "Lights", "Highlights"}
                and dict(o["fields"])["Shadows"] == o["parametric"]["shadows"] == value,
                "Four-zone graph or source curve missing",
            )
            witness = [value, o["hash"]]
        else:
            before = o["before"]["curves"]["red"][1]
            after = o["after"]["curves"]["red"][1]
            require(
                o["after"]["selected"] == 1
                and all(
                    abs(a - b) <= 0.000501
                    for a, b in zip(after, o["after"]["displayed"][1])
                )
                and before != after,
                "Missing original selected curve point",
            )
            if key == "curve-input-output":
                require(
                    all(
                        abs(v * 255 - x) < 1e-5
                        for v, x in zip(after, [(95, 140), (130, 90)][state])
                    ),
                    "Wrong committed input/output coordinates",
                )
            else:
                require(
                    abs(after[0] - before[0]) < 1e-8
                    and abs((after[1] - before[1]) * 255 - [1, -1][state]) < 1e-5,
                    "Keyboard must move one output level with fixed input",
                )
            witness = after
        require(
            t["digest"] == json_digest(witness) and t["verified"],
            "Wrong original curve result signature",
        )
    two_states(trials)


def validate_photo(row, report):
    require(
        report["protocol"] == "lightflow-original-photo-controls-v1"
        and report["photoRectPixels"][2:] == [2368, 1579]
        and report["viewportPixels"] == [3200, 2000]
        and row["id"] in PHOTO_CONTROLS,
        "Unexpected LightFlow editor setup",
    )
    trials = alternating(row, report["samples"])
    if row["id"] == "color-skin-indicator":
        validate_skin(row, trials)
    elif row["id"] == "optics-profile-enable":
        for t in trials:
            before, after = t["before"], t["after"]
            require(
                before["recipe"] == before["checked"] == bool(1 - t["state"])
                and after["recipe"] == after["checked"] == bool(t["state"])
                and before["photo"] == after["photo"]
                and after["frames"] > before["frames"]
                and after["ready"]
                and t["verified"],
                "RAW source, original checkbox and completed viewer sequence disagree",
            )
        two_states(trials)
        require(
            trials[1]["digest"] == row["referenceEnabledDigest"],
            "Enabling original embedded optics did not reproduce the initial photo",
        )
    elif row["id"] == "mixer-tat":
        for t in trials:
            bands = t["fields"]
            require(
                t["verified"]
                and t["sourcePoint"] == [[0.29, 0.31], [0.73, 0.69]][t["state"]]
                and [r[0] for r in bands] == COLORS
                and all(r[1] == r[2] and 0 <= r[1] <= 30 for r in bands)
                and any(r[1] > 0 for r in bands)
                and t["firstDown"] <= t["released"] <= t["verifiedAt"]
                and abs(t["ms"] - (t["verifiedAt"] - t["firstDown"])) < 0.001
                and json_digest(bands) == t["digest"],
                "Trusted HSL drag and committed fields disagree",
            )
        two_states(trials)
    else:
        validate_curves(row, trials)
    return trials


def supplemental_controls(sha, engine):
    from performance_controls import read_evidence, record

    cells = {}
    for name, validate, label in (
        ("lightflow-mask-hue.json", validate_hue, "2400 像素局部 GPU 操作"),
        ("lightflow-vectorscope.json", validate_vector, "256 × 168 矢量轨迹读回"),
        ("lightflow-photo-tools.json", validate_photo, "原版编辑器操作回执"),
    ):
        report = read_evidence(name, sha, "LightFlow")
        require(
            report["application"] == "LightFlow"
            and report["build"] == engine["build"]
            and report["sourceSHA256After"] == sha,
            "Different LightFlow source or published build",
        )
        if validate is validate_photo:
            require(
                set(engine["engineSHA256"].values())
                <= set(report["uiSHA256"].values()),
                "Unexpected original app runtime",
            )
            source_runs = {}
            for source_name, meta in report["sourceRuns"].items():
                source = read_evidence(source_name, sha, "LightFlow")
                require(
                    source["recordedAt"] == meta["recordedAt"]
                    and source["uiSHA256"] == meta["uiSHA256"]
                    and source["browserBinarySHA256"]
                    == report["browserBinarySHA256"]
                    == meta["browserBinarySHA256"]
                    and source["photoRectPixels"][2:] == [2368, 1579]
                    and set(engine["engineSHA256"].values())
                    <= set(source["uiSHA256"].values()),
                    "Incompatible source session for the original LightFlow controls",
                )
                source_runs[source_name] = {r["id"]: r for r in source["operations"]}
            for row in report["operations"]:
                observed = source_runs[row["sourceRun"]][row["id"]]
                require(
                    {
                        k: v
                        for k, v in row.items()
                        if k not in ("sourceRun", "recordedAt")
                    }
                    == observed
                    and row["recordedAt"]
                    == report["sourceRuns"][row["sourceRun"]]["recordedAt"],
                    "Selected control does not match its original complete run",
                )
        else:
            require(
                report["engineSHA256"] == engine["engineSHA256"]
                and report["rawSize"] == engine["rawSize"]
                and report["adapterInfo"]["isFallbackAdapter"] is False,
                "Unsupported original engine or source pixels",
            )
        for row in report["operations"]:
            key = row["id"]
            require(
                row["featureIds"] == [key] and key not in cells,
                "Duplicate or compound LightFlow observation",
            )
            if row["status"] != "measured":
                cells[key] = record(
                    row,
                    name,
                    row.get("boundary", report.get("boundary", label)),
                    report["samples"],
                    [],
                )
                continue
            trials = validate(row, report)
            boundary = row.get("boundary", report.get("boundary", label))
            cell = record(
                row,
                name,
                boundary,
                report["samples"],
                [t["ms"] for t in trials if t["phase"] == "warm"],
            )
            cell.update(firstEditMs=trials[0]["ms"], displayBoundary=label)
            cells[key] = cell
    return cells


def rendered_temperature(parent_sha, engine):
    """A camera JPEG fact for the rendered-file appendix, separate from the RAW cells."""
    from performance_controls import read_evidence, record

    name = "lightflow-rendered-temperature.json"
    jpeg_sha = "18513b39a513258b842500e423873dc7782faa400135565705e4e0f0dba70dcb"
    report = read_evidence(name, jpeg_sha, "LightFlow")
    require(
        report["parentRawSHA256"] == report["parentRawSHA256After"] == parent_sha
        and report["sourceSHA256After"] == jpeg_sha
        and report["embeddedOffset"] == 196770
        and report["embeddedLength"] == 258192
        and report["sourcePixels"] == report["photoRectPixels"][2:] == [1616, 1080]
        and report["build"] == engine["build"]
        and set(engine["engineSHA256"].values()) <= set(report["uiSHA256"].values())
        and report["protocol"] == "lightflow-rendered-jpeg-temperature-v1",
        "Incompatible source or original runtime for rendered-file white balance",
    )
    (row,) = report["operations"]
    require(
        row["id"] == "color-temp-rendered"
        and row["featureIds"] == [row["id"]]
        and row["range"] == [-100, 100],
        "Relative rendered temperature field was not selected",
    )
    trials = alternating(row, report["samples"])
    for t in trials:
        require(
            t["actualFieldValue"] == t["recipe"]["temperature"] == [-28, 28][t["state"]]
            and t["recipe"]["tint"] == 0
            and t["recipe"]["wbMode"] == "custom"
            and t["verified"],
            "JPEG white balance display, original recipe and expected relative value disagree",
        )
    two_states(trials)
    cell = record(
        row,
        name,
        row["boundary"],
        report["samples"],
        [t["ms"] for t in trials if t["phase"] == "warm"],
    )
    cell.update(
        firstEditMs=trials[0]["ms"],
        displayBoundary="相机 JPEG 配方至照片合成器读回",
        sourcePixels=report["sourcePixels"],
        sourceSHA256=jpeg_sha,
        parentRawSHA256=parent_sha,
    )
    return cell
