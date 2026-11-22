#!/usr/bin/env python3
"""Time real Camera Raw opens on macOS and independently check rendered RGB histograms."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from histogram_witness import grain_distances

CRS = "http://ns.adobe.com/camera-raw-settings/1.0/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
XMP = "adobe:ns:meta/"
for prefix, uri in (("crs", CRS), ("rdf", RDF), ("x", XMP)):
    ET.register_namespace(prefix, uri)

# Values and fixed prerequisites are recorded alongside the samples in the evidence.
def cases():
    result = {}

    def control(key, field, before, after, **fixed):
        result[key] = (dict(fixed, **{field: before}), dict(fixed, **{field: after}))

    for key, field in (("exposure", "Exposure2012"), ("contrast", "Contrast2012"),
                       ("highlights", "Highlights2012"), ("shadows", "Shadows2012"),
                       ("whites", "Whites2012"), ("blacks", "Blacks2012")):
        control("light-" + key, field, 0, 0.5 if key == "exposure" else 30)
        control("light-mask-" + key, "Local" + field, 0, 0.35)
    for key, field in (("saturation", "Saturation"), ("vibrance", "Vibrance")):
        control("color-" + key, field, 0, 30)
    control("color-wb-auto", "WhiteBalance", "As Shot", "Auto")
    control("color-wb-presets", "WhiteBalance", "As Shot", "Daylight")
    control("color-temp-raw", "Temperature", 5500, 6500, WhiteBalance="Custom", Tint=16)
    control("color-tint", "Tint", 16, 40, WhiteBalance="Custom", Temperature=5700)
    control("color-bw-treatment", "ConvertToGrayscale", "False", "True")
    for key, field in (("temp", "LocalTemperature"), ("tint", "LocalTint"),
                       ("hue", "LocalHue"), ("saturation", "LocalSaturation")):
        control("color-mask-" + key, field, 0, 0.35)
    control("color-mask-colorize", "LocalToningSaturation", 0, 0.65, LocalToningHue=50)

    for key, field in (("texture", "Texture"), ("clarity", "Clarity2012"), ("dehaze", "Dehaze")):
        control("effects-" + key, field, 0, 30)
    for key, field in (("texture", "LocalTexture"), ("clarity", "LocalClarity2012"), ("grain", "LocalGrain")):
        control("effects-mask-" + key, field, 0, 0.6)
    control("effects-glow-amount", "Glow", 0, 65)
    for key, field, start, end in (("styles", "GlowStyle", 0, 2), ("range", "GlowRange", 40, 80),
                                    ("spread", "GlowSpread", 30, 75), ("warmth", "GlowWarmth", 0, 60)):
        control("effects-glow-" + key, field, start, end, Glow=65)
    control("effects-glow-direction", "GlowDirection", 0, 70, Glow=65, GlowStyle=3)
    control("effects-glow-softness", "GlowDirectionalSoftness", 20, 80, Glow=65, GlowStyle=3)
    control("effects-glow-mask", "LocalGlow", 0, 0.65)
    control("effects-grain-amount", "GrainAmount", 0, 50)
    control("effects-grain-size", "GrainSize", 25, 65, GrainAmount=50)
    control("effects-grain-roughness", "GrainFrequency", 25, 65, GrainAmount=50)
    control("effects-pcv-amount", "PostCropVignetteAmount", 0, -50)
    for key, field, start, end in (("style", "Style", 1, 2), ("midpoint", "Midpoint", 25, 65),
                                    ("roundness", "Roundness", 0, 60), ("feather", "Feather", 25, 65),
                                    ("highlights", "HighlightContrast", 0, 80)):
        control("effects-pcv-" + key, "PostCropVignette" + field, start, end, PostCropVignetteAmount=-60)

    for band in ("Highlights", "Lights", "Darks", "Shadows"):
        control("curve-param-" + band.lower(), "Parametric" + band, 0, 40)
    control("curve-param-splits", "ParametricMidtoneSplit", 50, 65, ParametricDarks=40)
    linear, bent = ["0, 0", "255, 255"], ["0, 0", "100, 145", "255, 255"]
    control("curve-point", "ToneCurvePV2012", linear, bent, ToneCurveName2012="Custom")
    control("curve-channels", "ToneCurvePV2012Red", linear, bent, ToneCurveName2012="Custom", ToneCurvePV2012=linear, ToneCurvePV2012Green=linear, ToneCurvePV2012Blue=linear)
    control("curve-refine-saturation", "CurveRefineSaturation", 0, 100, ToneCurvePV2012=bent, ToneCurveName2012="Custom")
    for key, field in (("hue", "Hue"), ("saturation", "Saturation"), ("luminance", "Luminance")):
        control("mixer-" + key, field + "AdjustmentBlue", 0, 40)
    control("mixer-bw-mixer", "GrayMixerBlue", 0, 50, ConvertToGrayscale="True", AutoGrayscaleMix="False")

    # PointColors uses one 19-component sequence per sampled hue. The final 12 values are
    # the hue, saturation and luminance selection falloffs. Keep them fixed between edits.
    def point(index, value):
        values = [0.52, 0.45, 0.60, 0.0, 0.0, 0.0, 0.5, 0.0, 0.30, 0.70, 1.0,
                  0.0, 0.20, 0.70, 1.0, 0.0, 0.30, 0.80, 1.0]
        values[index] = value
        return [", ".join(f"{v:.6f}" for v in values)]

    for key, pos in (("hue", 3), ("saturation", 4), ("luminance", 5)):
        control("mixer-point-" + key, "PointColors", point(pos, 0.0), point(pos, 0.45))
    def point_width(width):
        components = point(3, 0.45)[0].split(", ")
        components[6] = f"{width:.6f}"
        return [", ".join(components)]
    control("mixer-point-range", "PointColors", point_width(0.20), point_width(0.85))
    control("mixer-point-variance", "ColorVariance", ["0.000000"], ["0.550000"], PointColors=point(3,0.2))
    control("mixer-point-mask", "LocalPointColors", point(3,0.0), point(3,0.45))

    for key, hue, saturation in (("shadows", "SplitToningShadowHue", "SplitToningShadowSaturation"),
                                  ("highlights", "SplitToningHighlightHue", "SplitToningHighlightSaturation"),
                                  ("midtones", "ColorGradeMidtoneHue", "ColorGradeMidtoneSat"),
                                  ("global", "ColorGradeGlobalHue", "ColorGradeGlobalSat")):
        control("grading-" + key, saturation, 0, 50, **{hue: 220})
    control("grading-luminance", "ColorGradeMidtoneLum", 0, 50)
    for key, field, before in (("blending", "ColorGradeBlending", 50), ("balance", "SplitToningBalance", 0)):
        control("grading-" + key, field, before, 80, SplitToningShadowSaturation=50, SplitToningShadowHue=245,
                SplitToningHighlightSaturation=45, SplitToningHighlightHue=45)

    for key, field, before, after, fixed in [
        ("sharpen-amount", "Sharpness", 0, 75, {}), ("sharpen-radius", "SharpenRadius", 0.8, 2.0, {"Sharpness": 75}),
        ("sharpen-detail", "SharpenDetail", 10, 70, {"Sharpness": 75}), ("sharpen-masking", "SharpenEdgeMasking", 0, 75, {"Sharpness": 75}),
        ("nr-luminance", "LuminanceSmoothing", 0, 70, {}), ("nr-lum-detail", "LuminanceNoiseReductionDetail", 10, 80, {"LuminanceSmoothing": 70}),
        ("nr-lum-contrast", "LuminanceNoiseReductionContrast", 0, 80, {"LuminanceSmoothing": 70}),
        ("nr-color", "ColorNoiseReduction", 0, 80, {}), ("nr-color-detail", "ColorNoiseReductionDetail", 10, 80, {"ColorNoiseReduction": 70}),
        ("mask-sharpness", "LocalSharpness", 0, 0.7, {}), ("mask-noise", "LocalLuminanceNoise", 0, 0.7, {}),
        ("mask-moire", "LocalMoire", 0, 0.7, {})]:
        control("detail-" + key, field, before, after, **fixed)
    for key, field, before, after, fixed in [
        ("profile-enable", "LensProfileEnable", 0, 1, {"LensProfileSetup": "LensDefaults"}),
        ("profile-distortion", "LensProfileDistortionScale", 0, 100, {"LensProfileEnable": 1}),
        ("profile-vignetting", "LensProfileVignettingScale", 0, 100, {"LensProfileEnable": 1}),
        ("remove-ca", "AutoLateralCA", 0, 1, {}), ("manual-distortion", "LensManualDistortionAmount", 0, 30, {}),
        ("purple-amount", "DefringePurpleAmount", 0, 15, {}), ("purple-hue", "DefringePurpleHueLo", 20, 50, {"DefringePurpleAmount": 18}),
        ("green-amount", "DefringeGreenAmount", 0, 15, {}), ("green-hue", "DefringeGreenHueLo", 30, 50, {"DefringeGreenAmount": 18}),
        ("lens-vignette-amount", "VignetteAmount", 0, -50, {}), ("lens-vignette-midpoint", "VignetteMidpoint", 25, 70, {"VignetteAmount": -50}),
        ("local-defringe", "LocalDefringe", 0, 0.8, {"DefringePurpleAmount": 15})]:
        control("optics-" + key, field, before, after, **fixed)
    for key, field, before, after in (("apply", "Active", "false", "true"), ("amount", "BlurAmount", 10, 75),
        ("bokeh", "BokehShape", 0, 2), ("cat-eye", "CatEyeAmount", 0, 75), ("boost", "HighlightsBoost", 0, 75),
        ("focus-range", "FocalRange", "0 0 15 30", "40 50 65 75")):
        base = {"LensBlur.Active": "true", "LensBlur.BlurAmount": 65, "LensBlur.FocalRange": "0 0 15 30"}
        base.pop("LensBlur." + field, None)
        control("blur-" + key, "LensBlur." + field, before, after, **base)
    return result


def put_attributes(node, attributes):
    for key, value in attributes.items():
        if isinstance(value, list):
            seq = ET.SubElement(ET.SubElement(node, f"{{{CRS}}}{key}"), f"{{{RDF}}}Seq")
            for point in value:
                ET.SubElement(seq, f"{{{RDF}}}li").text = point
        else:
            node.set(f"{{{CRS}}}{key}", str(value))


def write_sidecar(path, edits):
    root = ET.Element(f"{{{XMP}}}xmpmeta")
    desc = ET.SubElement(ET.SubElement(root, f"{{{RDF}}}RDF"), f"{{{RDF}}}Description", {f"{{{RDF}}}about": ""})
    put_attributes(desc, {"Version": "19.0", "ProcessVersion": "15.4", "HasSettings": "True"})
    put_attributes(desc, {k: v for k, v in edits.items() if not k.startswith(("Local", "LensBlur."))})
    local = {k: v for k, v in edits.items() if k.startswith("Local")}
    if local:
        def sequence(parent, name):
            return ET.SubElement(ET.SubElement(parent, f"{{{CRS}}}{name}"), f"{{{RDF}}}Seq")
        item = ET.SubElement(sequence(desc, "MaskGroupBasedCorrections"), f"{{{RDF}}}li")
        correction = ET.SubElement(item, f"{{{RDF}}}Description")
        put_attributes(correction, dict(What="Correction", CorrectionAmount=1, CorrectionActive="true",
            CorrectionName="Benchmark", CorrectionSyncID="70B05A74B072447398A9BD63EB3FC8FD", **local))
        mask = ET.SubElement(sequence(correction, "CorrectionMasks"), f"{{{RDF}}}li")
        put_attributes(mask, dict(What="Mask/CircularGradient", MaskActive="true", MaskName="Benchmark ellipse",
            MaskBlendMode=0, MaskInverted="false", MaskSyncID="6D91DC9B97CC4AB181EFE6545FC2AF12", MaskValue=1,
            Top=0.20, Left=0.20, Bottom=0.80, Right=0.80, Angle=0, Midpoint=50, Roundness=0, Feather=50, Flipped=True))
    lens = {k.split(".")[1]: v for k, v in edits.items() if k.startswith("LensBlur.")}
    if lens:
        put_attributes(ET.SubElement(desc, f"{{{CRS}}}LensBlur"), {"Version":1, **lens})
    path.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))


def open_document(script, path, retain_bins=False, spatial=False):
    spatial_file = path.with_name("witness.bmp")
    if spatial: spatial_file.unlink(missing_ok=True)
    js = script + "(" + json.dumps(str(path)) + "," + json.dumps(str(spatial_file) if spatial else None) + ");"
    result = subprocess.run(["osascript", "-e", "on run argv", "-e", "with timeout of 90 seconds", "-e",
        'tell application id "com.adobe.Photoshop" to do javascript (item 1 of argv)',
        "-e", "end timeout", "-e", "end run", js], capture_output=True, text=True, timeout=95, check=True)
    version, width, height, micros, *channels = result.stdout.strip().split("|")
    width, height = int(width), int(height)
    if len(channels) != 3 or min(width, height, int(micros)) < 1:
        raise ValueError("Missing rendered RGB document")
    counts = []
    for channel in channels:
        bins = [int(v) for v in channel.split(",")]
        counts.extend(bins)
        if len(bins) != 256 or sum(bins) < 1 or sum(v > 0 for v in bins) < 2:
            raise ValueError("Invalid or empty Photoshop channel histogram")
    witness = hashlib.sha256("|".join(channels).encode()).hexdigest()
    result = {**({"histogramBins":counts} if retain_bins else {}), "openMs": int(micros) / 1000, "histogramSHA256": witness,
              "outputPixels": [width, height], "photoshop": version}
    if spatial:
        import struct
        data = spatial_file.read_bytes()
        offset = int.from_bytes(data[10:14],"little")
        w,h,planes,bpp,compression = struct.unpack_from("<iiHHI",data,18)
        span = abs(h)*((w*3+3)//4*4)
        if (data[:2] != b"BM" or w != 1024 or abs(h) < 16 or (planes,bpp,compression) != (1,24,0)
                or span > len(data)-offset or len(set(data[offset:offset+span:509])) < 10):
            raise ValueError(f"Invalid spatial RGB witness w={w} h={h} planes={planes} bpp={bpp} compression={compression} offset={offset} bytes={len(data)}")
        result.update(spatialRGBSHA256=hashlib.sha256(data[offset:offset+span]).hexdigest(),spatialPixels=[w,abs(h)])
    return result


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--operations", nargs="+", choices=cases())
    selection.add_argument("--campaign", choices=("main", "points"), default="main",
                           help="Run the main adjustment inventory or the six point-color operations")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--resume", action="store_true", help="Continue an interrupted campaign on the same hardware and fixture")
    parser.add_argument("--retry-inconclusive", action="store_true", help="Recheck rows with no verified result when resuming")
    parser.add_argument("--spatial-witness", action="store_true", help="Also verify a 1024 px spatial sRGB buffer after each full RAW open")
    parser.add_argument("--stop-file", type=Path, help="Checkpoint between controls when this file exists")
    args = parser.parse_args()
    if args.output.exists() != args.resume or args.repeats < 2 or args.source.suffix.lower() not in {".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".rw2"}:
        parser.error("Expected a RAW with sidecar support, a new evidence file and at least two repeats")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    plugin = Path("/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin/Contents/Info.plist")
    source_hash = digest(args.source)
    report = {"schemaVersion": 1, "startedAt": datetime.now(timezone.utc).isoformat(), "sourceSHA256": source_hash,
        "cameraRaw": plistlib.loads(plugin.read_bytes())["CFBundleShortVersionString"],
        "os": platform.mac_ver()[0], "hardware": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
        "boundary": "CameraRAWOpenOptions selected-image app.open to Photoshop document return on warm app; real RAW reopen; 8-bit sRGB; histogram outside timer",
        "protocol": "acr-xmp-document-open-v1", "repeats": args.repeats, "operations": {}}
    script = Path(__file__).with_name("camera-raw-open.jsx").read_text()
    catalog = cases()
    point_controls = {"mixer-point-hue","mixer-point-saturation","mixer-point-luminance","mixer-point-range","mixer-point-variance","mixer-point-mask"}
    names = args.operations or [name for name in catalog if (name in point_controls) == (args.campaign == "points")]
    if args.resume:
        previous = json.loads(args.output.read_text())
        for key in ("sourceSHA256", "cameraRaw", "os", "hardware", "protocol", "repeats"):
            if previous.get(key) != report[key]:
                raise ValueError(f"Incompatible resume field {key}")
        if not args.operations and previous.get("planned"):
            names = previous["planned"]
        if previous.get("planned") and set(names) != set(previous["planned"]):
            raise ValueError("Resume the original workload")
        if set(previous["operations"]) - set(names):
            raise ValueError("Resume workload omits previously measured controls")
        report = previous
        report.pop("finishedAt", None)
    report["planned"] = names
    if args.spatial_witness:
        report["spatialWitness"] = "1024 px bicubic sRGB BGR24 bitmap from the disposable full document after the timed open"
    report.setdefault("sessions", []).append({"startedAt":datetime.now(timezone.utc).isoformat(),
        "driverSHA256":digest(Path(__file__)), "jsxSHA256":digest(Path(__file__).with_name("camera-raw-open.jsx"))})
    def save():
        staging = args.output.with_suffix(args.output.suffix + ".partial")
        staging.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        staging.replace(args.output)
    with tempfile.TemporaryDirectory(prefix="rawmaster-acr-") as folder:
        raw = Path(folder) / ("benchmark" + args.source.suffix)
        shutil.copyfile(args.source, raw)
        if digest(raw) != source_hash:
            raise ValueError("Work copy failed SHA-256 verification")
        for name in names:
            if args.stop_file and args.stop_file.exists():
                report["sessions"][-1]["checkpointAt"] = datetime.now(timezone.utc).isoformat()
                report["workCopySHA256After"] = digest(raw)
                report["sourceSHA256After"] = digest(args.source)
                save()
                return
            prior = report["operations"].get(name)
            if prior and not (args.retry_inconclusive and prior["status"] == "inconclusive"):
                continue
            a, b = catalog[name]
            if args.spatial_witness and name.startswith("blur-"):
                lens_defaults = {"LensBlur.Version":1,"LensBlur.Active":"true","LensBlur.BokehShape":1,"LensBlur.BokehShapeDetail":3,
                    "LensBlur.HighlightsThreshold":50,"LensBlur.HighlightsBoost":50,"LensBlur.CatEyeAmount":0,
                    "LensBlur.CatEyeScale":100,"LensBlur.BokehAspect":0,"LensBlur.BokehRotation":0,"LensBlur.SphericalAberration":25}
                a, b = ({**lens_defaults,**settings} for settings in (a,b))
            if (args.spatial_witness and source_hash == "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
                    and name in ("optics-profile-distortion","optics-profile-vignetting")):
                profile = {"LensProfileSetup":"Custom", "LensProfileName":"Adobe (Sony FE 14mm F1.8 GM)",
                    "LensProfileFilename":"SONY (Sony FE 14mm F1.8 GM) - RAW.lcp"}
                a, b = ({**profile,**settings} for settings in (a,b))
            row = {"settings": {"control": a, "edit": b}, "samples": [], "status": "inconclusive"}
            if prior:
                row["priorAttempts"] = [*prior.get("priorAttempts", []), {k:v for k,v in prior.items() if k != "priorAttempts"}]
            report["operations"][name] = row
            try:
                for iteration in range(args.repeats + 1):
                    for state, settings in (("control", a), ("edit", b)):
                        write_sidecar(raw.with_suffix(".xmp"), settings)
                        result = open_document(script, raw, retain_bins="grain" in name, spatial=args.spatial_witness)
                        row["samples"].append(dict(state=state, iteration=iteration, **result))
                signatures = [{s["histogramSHA256"] for s in row["samples"] if s["state"] == state} for state in ("control", "edit")]
                if all(len(s) == 1 for s in signatures) and signatures[0] != signatures[1]:
                    row["status"] = "measured"
                elif args.spatial_witness:
                    spatial = [{s["spatialRGBSHA256"] for s in row["samples"] if s["state"]==state} for state in ("control","edit")]
                    if all(len(s)==1 for s in spatial) and spatial[0] != spatial[1]:
                        row.update(status="measured", witness="spatialRGBSHA256")
                    else:
                        row["reason"] = "The spatial pixels and histograms did not distinguish the two settings consistently"
                elif "grain" in name:
                    row["grainDistances"] = grain_distances(row["samples"])
                    distances = row["grainDistances"]
                    if distances["minimumBetween"] > 2 * distances["maximumWithin"]:
                        row["status"] = "measured"
                    else:
                        row["reason"] = "Grain edits did not exceed twice the observed within-state histogram variation"
                else:
                    row["reason"] = "No stable, distinct control/edit RGB histogram"
            except (subprocess.SubprocessError, ValueError) as error:
                row["reason"] = str(getattr(error, "stderr", None) or str(error) or type(error).__name__)[:700]
            print(name, row["status"], flush=True)
            save()
        report["workCopySHA256After"] = digest(raw)
    report["sourceSHA256After"] = digest(args.source)
    if source_hash != report["sourceSHA256After"] or source_hash != report["workCopySHA256After"]:
        raise ValueError("RAW content changed")
    report["finishedAt"] = datetime.now(timezone.utc).isoformat()
    save()


if __name__ == "__main__":
    main()
