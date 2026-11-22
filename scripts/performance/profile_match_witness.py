"""Verify the automatic lens profile returned by Camera Raw against full native image and XMP controls."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import xml.etree.ElementTree as ET
import zipfile

CRS = "http://ns.adobe.com/camera-raw-settings/1.0/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
KEY = "optics-profile-match"
WRONG = "Sony FE 20mm F1.8 G"
CORRECT = "Sony FE 14mm F1.8 GM"
SOURCE = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"


def settings(label):
    values = {
        "LensProfileSetup": "Auto" if label == "auto" else "Custom",
        "LensProfileEnable": 1,
        "LensProfileDistortionScale": 100,
        "LensProfileVignettingScale": 100,
    }
    if label != "auto":
        lens = CORRECT if label == "correct" else WRONG
        values.update(LensProfileName=f"Adobe ({lens})", LensProfileFilename=f"SONY ({lens}) - RAW.lcp")
    return values


def returned_profile(path):
    desc = ET.parse(path).getroot().find(f".//{{{RDF}}}Description")
    namespaces = {
        "crs": CRS,
        "aux": "http://ns.adobe.com/exif/1.0/aux/",
        "exifEX": "http://cipa.jp/exif/1.0/",
    }
    result = {}
    for key in (
        "crs:LensProfileSetup",
        "crs:LensProfileEnable",
        "crs:LensProfileName",
        "crs:LensProfileFilename",
        "crs:LensProfileDigest",
        "crs:LensProfileDistortionScale",
        "crs:LensProfileVignettingScale",
        "aux:Lens",
        "exifEX:LensModel",
    ):
        prefix, local = key.split(":")
        qualified = "{" + namespaces[prefix] + "}" + local
        result[key] = desc.get(qualified, desc.findtext(qualified))
    return result


def verify_record(samples, anchors):
    if len(samples) != 8 or len(anchors) != 2:
        raise ValueError(
            "Expected an initial A/B pair and three held-out A/B pairs, plus two correct-profile anchors"
        )
    if [s["state"] for s in anchors] != ["anchor-before", "anchor-after"]:
        raise ValueError("Missing independent correct-profile references around the A/B sequence")
    if [(s["iteration"], s["state"]) for s in samples] != [
        (n, state) for n in range(4) for state in ("control", "edit")
    ]:
        raise ValueError("Wrong A/B order")
    groups = {
        "wrong": [s for s in samples if s["state"] == "control"],
        "auto": [s for s in samples if s["state"] == "edit"],
        "correct": anchors,
    }
    digests = {}
    for label, observations in groups.items():
        manual = settings("wrong" if label == "wrong" else "correct")
        expected_mode = settings(label)["LensProfileSetup"]
        for s in observations:
            m = s["returnedLensProfile"]
            if (
                m["crs:LensProfileSetup"] != expected_mode
                or m["crs:LensProfileEnable"] != "1"
                or m["crs:LensProfileFilename"] != manual["LensProfileFilename"]
                or m["crs:LensProfileName"] != manual["LensProfileName"]
                or m["aux:Lens"] != "FE 14mm F1.8 GM"
                or m["exifEX:LensModel"] != m["aux:Lens"]
                or any(
                    m["crs:" + k] != "100"
                    for k in ("LensProfileDistortionScale", "LensProfileVignettingScale")
                )
                or not re.fullmatch(r"[0-9A-F]{32}", m["crs:LensProfileDigest"] or "")
                or s["outputPixels"] != [9504, 6336]
                or s["spatialPixels"] != s["outputPixels"]
            ):
                raise ValueError(
                    f"{label}: Camera Raw did not return the requested mode, resolved lens and native pixels: {m}"
                )

        def stable(field):
            values = {s[field] for s in observations}
            if len(values) != 1 or not all(re.fullmatch(r"[0-9a-f]{64}", value or "") for value in values):
                raise ValueError(f"{label}: {field} was not stable in separate document opens")
            return values.pop()

        profile_ids = {s["returnedLensProfile"]["crs:LensProfileDigest"] for s in observations}
        if len(profile_ids) != 1:
            raise ValueError(f"Unstable resolved LCP for {label}")
        digests[label] = {
            "nativeRGB8SHA256": stable("spatialRGBSHA256"),
            "histogramSHA256": stable("histogramSHA256"),
            "adobeProfileDigest": profile_ids.pop(),
        }
    for key in digests["auto"]:
        if digests["auto"][key] != digests["correct"][key] or digests["auto"][key] == digests["wrong"][key]:
            raise ValueError("Auto must agree with explicit 14 mm and differ from explicit 20 mm for " + key)
    return digests


def compare_rasters(directory):
    from contextlib import ExitStack
    from PIL import Image, ImageChops

    width, height = 9504, 6336
    stride = width * 3
    result = {"pixelsPerImage": width * height, "rasterBytesPerImage": width * height * 3}
    for label in ("correct", "wrong"):
        same_pixels = 0
        channel_totals = [0, 0, 0]
        code_sums = [0, 0, 0]
        peak = 0
        with ExitStack() as opened:
            streams = []
            for tag in ("auto", label):
                path = directory / (tag + ".bmp")
                stream = opened.enter_context(path.open("rb"))
                header = stream.read(54)
                offset = int.from_bytes(header[10:14], "little")
                shape = struct.unpack_from("<iiHHI", header, 18)
                native_end = offset + stride * height
                if (
                    header[:2] != b"BM"
                    or shape != (width, height, 1, 24, 0)
                    or not native_end <= path.stat().st_size <= native_end + 3
                ):
                    raise ValueError("Expected full native bottom-up BGR24 in all three reference files")
                stream.seek(offset)
                streams.append(stream)
            for y in range(0, height, 128):
                lines = min(128, height - y)
                a, b = [
                    Image.frombytes("RGB", (width, lines), stream.read(lines * stride), "raw", "BGR")
                    for stream in streams
                ]
                delta = ImageChops.difference(a, b)
                red, green, blue = delta.split()
                same_pixels += ImageChops.lighter(ImageChops.lighter(red, green), blue).histogram()[0]
                all_bins = delta.histogram()
                for channel in range(3):
                    bins = all_bins[channel * 256 : (channel + 1) * 256]
                    channel_totals[channel] += width * lines - bins[0]
                    code_sums[channel] += sum(k * n for k, n in enumerate(bins))
                    peak = max(peak, max(k for k, n in enumerate(bins) if n))
        result[label + "VsAuto"] = {
            "differingPixels": width * height - same_pixels,
            "differingChannelsRGB": channel_totals,
            "meanAbsoluteDifferenceRGB8": [n / (width * height) for n in code_sums],
            "maxRGB8Difference": peak,
        }
    if result["correctVsAuto"]["differingPixels"] or not result["wrongVsAuto"]["differingPixels"]:
        raise ValueError("The native rasters did not agree with the selected lens")
    return result


def verify_report(data, archive_path):
    if (
        data["sourceSHA256"] != SOURCE
        or data["sourceSHA256After"] != SOURCE
        or data["workCopySHA256After"] != SOURCE
        or not data["foregroundUnchanged"]
        or data["planned"] != [KEY]
        or list(data["operations"]) != [KEY]
        or data["repeats"] != 3
    ):
        raise ValueError("Incompatible source, foreground, or operation")
    row = data["operations"][KEY]
    if (
        row["status"] != "measured"
        or row["settings"] != {"control": settings("wrong"), "edit": settings("auto")}
        or data["manualCorrectSettings"] != settings("correct")
    ):
        raise ValueError("Incorrect inputs for lens profile verification")
    if verify_record(row["samples"], data["manualCorrectAnchors"]) != row["profileMatchVerification"]:
        raise ValueError("Reported lens identity or raster summary differs from original samples")
    comparison = row["nativePixelComparison"]
    pixels = 9504 * 6336
    if (
        comparison["pixelsPerImage"] != pixels
        or comparison["rasterBytesPerImage"] != 3 * pixels
        or comparison["correctVsAuto"]
        != {
            "differingPixels": 0,
            "differingChannelsRGB": [0, 0, 0],
            "meanAbsoluteDifferenceRGB8": [0, 0, 0],
            "maxRGB8Difference": 0,
        }
        or not 0 < comparison["wrongVsAuto"]["differingPixels"] <= pixels
    ):
        raise ValueError("Missing native all-pixel comparison with both explicit profiles")
    if hashlib.sha256(archive_path.read_bytes()).hexdigest() != data["metadataArchive"]["sha256"]:
        raise ValueError("XMP archive changed")
    with zipfile.ZipFile(archive_path) as archive:
        original_paths = []
        for s in [*row["samples"], *data["manualCorrectAnchors"]]:
            label = {
                "edit": "auto",
                "control": "wrong",
                "anchor-before": "correct",
                "anchor-after": "correct",
            }[s["state"]]
            for kind in ("inputXMP", "returnedXMP"):
                name = s[kind]
                blob = archive.read(name)
                if hashlib.sha256(blob).hexdigest() != s[kind + "SHA256"]:
                    raise ValueError("Archived XMP disagrees with its record: " + name)
                original_paths.append(name)
                if kind == "returnedXMP":
                    with archive.open(name) as stream:
                        if returned_profile(stream) != s["returnedLensProfile"]:
                            raise ValueError("Adobe document XMP disagrees with captured lens identity")
                else:
                    desc = ET.fromstring(blob).find(f".//{{{RDF}}}Description")
                    actual = {
                        k.split("}")[-1]: v for k, v in desc.attrib.items() if k.startswith("{" + CRS + "}")
                    }
                    expected = {
                        "Version": "19.0",
                        "ProcessVersion": "15.4",
                        "HasSettings": "True",
                        **{k: str(v) for k, v in settings(label).items()},
                    }
                    if actual != expected or len(desc):
                        raise ValueError("An unexpected setting was supplied to the lens match")
        if len(set(original_paths)) != 20 or set(original_paths) != set(archive.namelist()):
            raise ValueError("Expected one unique input and returned XMP per document open")
    return row["profileMatchVerification"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    data = json.loads(args.evidence.read_text())
    details = verify_report(data, args.evidence.parent / data["metadataArchive"]["file"])
    print(
        f"Verified {KEY} against both native manual-profile rasters and 20 Adobe XMP records. {details['auto']['adobeProfileDigest']}"
    )
