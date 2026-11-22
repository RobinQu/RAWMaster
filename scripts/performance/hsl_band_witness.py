"""Qualify the 24 independent Camera Raw HSL settings, their source XMP and their returned native pixels."""

import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import struct
import xml.etree.ElementTree as ET
import zipfile

CRS = "http://ns.adobe.com/camera-raw-settings/1.0/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
COLORS = ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta")
AXES = ("Hue", "Saturation", "Luminance")
FIELDS = tuple(axis + "Adjustment" + color for color in COLORS for axis in AXES)
BLUE = {axis + "AdjustmentBlue": "mixer-" + axis.lower() for axis in AXES}
SHA = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
NATIVE = [9504, 6336]
ZERO = "neutral"


def supplied(field):
    return {"HueAdjustmentBlue": 0} if field == ZERO else {field: 40}


def expected_mixer(field):
    return {name: 40 if name == field else 0 for name in FIELDS}


def document_mixer(stream):
    desc = ET.parse(stream).getroot().find(f".//{{{RDF}}}Description")
    result = {}
    for name in FIELDS:
        key = "{" + CRS + "}" + name
        value = desc.get(key, desc.findtext(key))
        if value is None:
            raise ValueError("ACR did not return " + name)
        result[name] = int(value)
    return result


def timing(values):
    if len(values) != 3 or any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("Expected three independently observed warm opens")
    return {"n": len(values), "medianMs": statistics.median(values), "p95Ms": max(values), "rawMs": values}


def read_initial_grids(directory):
    width, height = NATIVE
    columns, rows = 96, 64
    result = {}
    for label in (ZERO, *FIELDS):
        with (directory / (label + ".bmp")).open("rb") as bmp:
            header = bmp.read(54)
            if header[:2] != b"BM" or struct.unpack_from("<iiHHI", header, 18) != (width, height, 1, 24, 0):
                raise ValueError("Expected the original full-size bottom-up BGR24 witness")
            offset = int.from_bytes(header[10:14], "little")
            pixels = bytearray()
            for row in range(rows):
                y = (2 * row + 1) * height // (2 * rows)
                bmp.seek(offset + (height - 1 - y) * width * 3)
                line = bmp.read(width * 3)
                for column in range(columns):
                    x = (2 * column + 1) * width // (2 * columns)
                    pixels.extend(line[3 * x : 3 * x + 3][::-1])
            result[label] = base64.b64encode(pixels).decode("ascii")
    return {
        "dimensions": [columns, rows],
        "layout": "RGB8 row-major, top-left, centers of equal native-image cells",
        "rgb8Base64": result,
    }


def grid_delta(grids, field):
    if grids["dimensions"] != [96, 64] or set(grids["rgb8Base64"]) != {ZERO, *FIELDS}:
        raise ValueError("Incomplete fixed-grid native image witnesses")
    a, b = [base64.b64decode(grids["rgb8Base64"][k], validate=True) for k in (ZERO, field)]
    if len(a) != 96 * 64 * 3 or len(b) != len(a):
        raise ValueError("Missing native grid pixels")
    d = [abs(x - y) for x, y in zip(a, b)]
    return {
        "pixelsCompared": 96 * 64,
        "pixelsChanged": sum(any(d[i : i + 3]) for i in range(0, len(d), 3)),
        "maximumRGB8Difference": max(d),
        "meanAbsoluteDifferenceRGB8": [sum(d[c::3]) / (96 * 64) for c in range(3)],
    }


def schedule():
    new = [field for field in FIELDS if field not in BLUE]
    steps = []
    for i in range(4):
        if i == 0:
            ordered = list(FIELDS)
        elif i % 2:
            ordered = list(reversed(new))
        else:
            ordered = new[len(new) // 2 :] + new[: len(new) // 2]
        steps.extend((i, field) for field in [ZERO, *ordered])
    return steps


def signatures(samples):
    proof = {}
    for key in ("spatialRGBSHA256", "histogramSHA256"):
        found = {s[key] for s in samples}
        if len(found) != 1 or not re.fullmatch(r"[0-9a-f]{64}", next(iter(found))):
            raise ValueError("Repeated documents have different " + key)
        proof[key] = found.pop()
    return proof


def summarize(data, historical):
    if (
        data["sourceSHA256"] != SHA
        or data["sourceSHA256After"] != SHA
        or data["workCopySHA256After"] != SHA
        or not data["foregroundUnchanged"]
        or data["protocol"] != "acr-independent-hsl-native-v1"
        or any(data[k] != historical[k] for k in ("cameraRaw", "hardware", "os", "sourceSHA256"))
        or historical.get("sourceSHA256After") != SHA
        or historical.get("workCopySHA256After") != SHA
        or historical.get("repeats") != 3
        or historical.get("protocol") != "acr-xmp-document-open-v1"
        or not historical.get("finishedAt")
    ):
        raise ValueError("Source, host, OS, camera plug-in or foreground does not match")
    samples = data["samples"]
    if [(s["round"], s["field"]) for s in samples] != schedule():
        raise ValueError("Expected four complete rounds and three historical blue validations")
    groups = {k: [] for k in (ZERO, *FIELDS)}
    for s in samples:
        if (
            s["outputPixels"] != NATIVE
            or s["spatialPixels"] != NATIVE
            or s["photoshop"] != data["photoshop"]
            or not math.isfinite(s["openMs"])
            or s["openMs"] <= 0
        ):
            raise ValueError("Unexpected native raster or document timing")
        groups[s["field"]].append(s)
    neutral = signatures(groups[ZERO])
    if any(s["returnedHSL"] != expected_mixer(ZERO) for s in groups[ZERO]):
        raise ValueError("At least one shared neutral document retained an adjustment")
    rows = []
    for field in FIELDS:
        group = groups[field]
        source = "camera-raw-open.json" if field in BLUE else "camera-raw-hsl-bands.json"
        row = {
            "field": field,
            "state": "inconclusive",
            "timingSource": source,
            "validationSource": "camera-raw-hsl-bands.json",
            "observationIndexes": [s["index"] for s in group],
            "neutralObservationIndexes": [s["index"] for s in groups[ZERO]],
        }
        try:
            if any(s["returnedHSL"] != expected_mixer(field) for s in group):
                raise ValueError(
                    "A neighboring value changed or the requested value did not survive in the document"
                )
            digest = signatures(group)
            if any(digest[k] == neutral[k] for k in neutral):
                raise ValueError("The edit did not change the full native raster and histogram")
            if field in BLUE:
                old = historical["operations"][BLUE[field]]
                expected_states = [(i, state) for i in range(4) for state in ("control", "edit")]
                if (
                    old["status"] != "measured"
                    or old["settings"] != {"control": {field: 0}, "edit": {field: 40}}
                    or [(s["iteration"], s["state"]) for s in old["samples"]] != expected_states
                ):
                    raise ValueError("Original blue timing or settings changed")
                for s in old["samples"]:
                    mark = neutral if s["state"] == "control" else digest
                    if (
                        s["histogramSHA256"] != mark["histogramSHA256"]
                        or s["photoshop"] != data["photoshop"]
                        or s["outputPixels"] != NATIVE
                    ):
                        raise ValueError(
                            "Native blue retest did not reproduce the previous full-document histogram"
                        )
                edits = [s for s in old["samples"] if s["state"] == "edit"]
                row["historicalOperation"] = BLUE[field]
            else:
                edits = group
            row.update(
                state="measured",
                firstOpenMs=edits[0]["openMs"],
                timing=timing([s["openMs"] for s in edits[1:]]),
                verifiedZeroNeighborCount=23,
                fullRasterSHA256=digest["spatialRGBSHA256"],
                histogramSHA256=digest["histogramSHA256"],
            )
            if "nativeGrids" in data:
                row["fixedNativeGrid"] = grid_delta(data["nativeGrids"], field)
        except ValueError as error:
            row["reason"] = str(error)
        rows.append(row)
    repeated = {
        r["fullRasterSHA256"]
        for r in rows
        if r["state"] == "measured"
        and sum(other.get("fullRasterSHA256") == r["fullRasterSHA256"] for other in rows) > 1
    }
    for row in rows:
        if row.get("fullRasterSHA256") in repeated:
            row.update(
                state="inconclusive",
                reason="Two independent HSL controls returned identical full native pixels",
            )
            row.pop("timing")
    return rows


def verify_report(data, archive_path, historical_path):
    archive_digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    if (
        archive_digest != data["metadataArchive"]["sha256"]
        or hashlib.sha256(historical_path.read_bytes()).hexdigest() != data["historicalSource"]["sha256"]
    ):
        raise ValueError("The Adobe XMP archive or the original Blue source changed")
    with zipfile.ZipFile(archive_path) as archive:
        paths = []
        for index, s in enumerate(data["samples"]):
            if s["index"] != index:
                raise ValueError("Observation indexes changed")
            for kind in ("inputXMP", "returnedXMP"):
                name = s[kind]
                paths.append(name)
                blob = archive.read(name)
                if hashlib.sha256(blob).hexdigest() != s[kind + "SHA256"]:
                    raise ValueError("Missing archived XMP for " + name)
                with archive.open(name) as stream:
                    if kind == "returnedXMP":
                        if document_mixer(stream) != s["returnedHSL"]:
                            raise ValueError("Reported HSL differs from the returned document")
                    else:
                        desc = ET.parse(stream).getroot().find(f".//{{{RDF}}}Description")
                        fields = {
                            k.split("}")[-1]: v
                            for k, v in desc.attrib.items()
                            if k.startswith("{" + CRS + "}")
                        }
                        expected = {
                            "Version": "19.0",
                            "ProcessVersion": "15.4",
                            "HasSettings": "True",
                            **{k: str(v) for k, v in supplied(s["field"]).items()},
                        }
                        if fields != expected or len(desc):
                            raise ValueError("An additional RAW parameter was changed: " + name)
        if len(set(paths)) != 2 * len(schedule()) or set(paths) != set(archive.namelist()):
            raise ValueError("Expected one independent input and output XMP per native document")
    rows = summarize(data, json.loads(historical_path.read_text()))
    if rows != data["rows"]:
        raise ValueError("HSL per-band summary differs from the recorded documents")
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    data = json.loads(args.evidence.read_text())
    rows = verify_report(
        data,
        args.evidence.parent / data["metadataArchive"]["file"],
        args.evidence.parent / data["historicalSource"]["file"],
    )
    print(f"{sum(r['state'] == 'measured' for r in rows)}/{len(rows)} isolated ACR19 HSL controls verified")
