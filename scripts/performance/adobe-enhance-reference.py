#!/usr/bin/env python3
"""Prepare isolated Sony RAW copies; export only settings authored by an actual Adobe application."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
from pathlib import Path

STATES = ("baseline", "denoise-50", "raw-details", "super-resolution")
CAMERA = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"

JS = r"""
(function(path, output, metadata, settings) {
    var previous = app.displayDialogs, doc = null;
    try {
        app.displayDialogs = DialogModes.NO;
        var opts = new CameraRAWOpenOptions();
        opts.settings = CameraRAWSettingsType.SELECTEDIMAGE;
        opts.colorSpace = ColorSpaceType.SRGB;
        opts.bitsPerChannel = BitsPerChannelType.SIXTEEN;
        var start = $.hiresTimer;
        doc = app.open(new File(path), opts);
        var openUs = $.hiresTimer;
        var w = doc.width.as("px"), h = doc.height.as("px");
        if (Math.abs(w-settings[0])>0.01 || Math.abs(h-settings[1])>0.01 ||
            String(doc.bitsPerChannel) != String(BitsPerChannelType.SIXTEEN))
            throw Error("Actual ACR dimensions/depth do not match: "+w+" x "+h+" "+doc.bitsPerChannel);
        var side = new File(metadata);
        side.encoding = "UTF8";
        try { if (!side.open("w") || !side.write(doc.xmpMetadata.rawData)) throw Error("Cannot record returned metadata"); }
        finally { side.close(); }
        var tiff = new TiffSaveOptions();
        tiff.embedColorProfile = true;
        tiff.layers = false;
        tiff.imageCompression = TIFFEncoding.NONE;
        var beforeSave = $.hiresTimer;
        doc.saveAs(new File(output), tiff, true, Extension.LOWERCASE);
        var saveUs = $.hiresTimer;
        return [app.version, openUs, saveUs, Math.round(w), Math.round(h), doc.colorProfileName].join("|");
    } finally {
        try { if (doc) doc.close(SaveOptions.DONOTSAVECHANGES); }
        finally { app.displayDialogs = previous; }
    }
})
"""


def digest(path):
    with path.open("rb") as reader:
        return hashlib.file_digest(reader, "sha256").hexdigest()


def tiff_properties(path, expected):
    names = ("pixelWidth", "pixelHeight", "bitsPerSample", "samplesPerPixel", "profile")
    command = ["sips", *[value for name in names for value in ("-g", name)], str(path)]
    lines = subprocess.check_output(command, text=True).splitlines()
    fields = {line.strip().split(": ", 1)[0]:line.strip().split(": ", 1)[1] for line in lines if ": " in line}
    if ([int(fields["pixelWidth"]), int(fields["pixelHeight"])] != expected
            or int(fields["bitsPerSample"]) != 16 or int(fields["samplesPerPixel"]) != 3
            or "sRGB" not in fields["profile"]):
        raise ValueError("The TIFF on disk does not preserve native RGB16 and the expected sRGB ICC")
    return fields


def native_rgb16(path, expected):
    from PIL import Image
    native_pixels = expected[0] * expected[1]
    prior_limit = Image.MAX_IMAGE_PIXELS
    try:
        Image.MAX_IMAGE_PIXELS = max(prior_limit or 0, native_pixels)
        with Image.open(path) as image:
            tags = image.tag_v2
            if (list(image.size) != expected or tags.get(259) != 1 or tags.get(262) != 2
                    or tags.get(258) != (16, 16, 16) or tags.get(284, 1) != 1):
                raise ValueError("Expected uncompressed interleaved native RGB16 strips")
            offsets, sizes = tags[273], tags[279]
            if len(offsets) != len(sizes) or sum(sizes) != native_pixels * 6:
                raise ValueError("Incomplete RGB16 TIFF strip table")
    finally:
        Image.MAX_IMAGE_PIXELS = prior_limit
    result = hashlib.sha256()
    with path.open("rb") as source:
        byte_order = source.read(2).decode("ascii")
        for offset, size in zip(offsets, sizes):
            source.seek(offset)
            while size:
                chunk = source.read(min(8 << 20, size))
                if not chunk:
                    raise ValueError("Truncated RGB16 TIFF strip")
                result.update(chunk)
                size -= len(chunk)
    return {"byteOrder":byte_order, "rgb16Bytes":native_pixels * 6, "rgb16SHA256":result.hexdigest()}


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def prepare(source, session):
    if digest(source) != CAMERA:
        raise ValueError("Expected the measured Sony 9504×6336 sensor file")
    if session.exists():
        raise ValueError("Use a new session directory; existing work is preserved")
    session.mkdir(parents=True)
    manifest = {"source": str(source), "sourceSHA256": CAMERA, "native": [9504, 6336], "states": {}}
    for name in STATES:
        raw = session / (name + source.suffix.lower())
        copied = platform.system() == "Darwin" and subprocess.run(["/bin/cp", "-c", str(source), str(raw)], capture_output=True).returncode == 0
        if not copied:
            shutil.copyfile(source, raw)
        if digest(raw) != CAMERA:
            raise ValueError("RAW copy content changed")
        manifest["states"][name] = {"raw":raw.name, "expectedPixels":[19008,12672] if name == "super-resolution" else [9504,6336]}
    write(session / "session.json", manifest)


def foreground():
    script = """use framework "AppKit"
return (current application's NSWorkspace's sharedWorkspace()'s frontmostApplication()'s bundleIdentifier()) as text"""
    return subprocess.check_output(["osascript", "-l", "AppleScript", "-e", script], text=True).strip()


def baseline_for_enhancement(session, source_dimensions):
    record = json.loads((session / "baseline.reference.json").read_text())
    if (record["state"] != "baseline" or record["sourceSHA256"] != CAMERA or record["sidecars"]
            or record["actualPixels"] != source_dimensions or record["bits"] != 16):
        raise ValueError("Expected the untouched native RGB16 baseline for this exact RAW")
    raster = native_rgb16(session / "baseline.tif", source_dimensions)
    if record["nativeRGB16"] != raster:
        raise ValueError("The untouched TIFF pixels changed after capture")
    return raster


def compare_native_rasters(untouched, rendered, state):
    if rendered["byteOrder"] != untouched["byteOrder"]:
        raise ValueError("Expected matching native RGB16 byte order for the Adobe exports")
    size_multiple = 4 if state == "super-resolution" else 1
    if rendered["rgb16Bytes"] != untouched["rgb16Bytes"] * size_multiple:
        raise ValueError("Native raster length disagrees with the requested Enhance dimensions")
    if rendered["rgb16SHA256"] == untouched["rgb16SHA256"]:
        raise ValueError("The staged Adobe settings produced exactly the untouched baseline pixels")
    return {"baselineRGB16SHA256": untouched["rgb16SHA256"], "fullRasterChanged": True}


def export(session, names, host):
    manifest = json.loads((session / "session.json").read_bytes())
    if manifest["sourceSHA256"] != CAMERA or digest(Path(manifest["source"])) != CAMERA:
        raise ValueError("Original RAW identity changed")
    for name in names:
        task = manifest["states"][name]
        raw = session / task["raw"]
        if raw.parent.resolve() != session or digest(raw) != CAMERA:
            raise ValueError("Wrong staging source for " + name)
        def adjacent_settings():
            return sorted(p for p in session.iterdir() if p.stem == raw.stem and p.suffix.lower() in (".acr", ".xmp"))
        settings = adjacent_settings()
        if name != "baseline" and not settings:
            raise ValueError("No externally authored settings for " + name)
        if any(p.stat().st_size == 0 for p in settings):
            raise ValueError("Empty Adobe settings for " + name)
        if name == "baseline" and settings:
            raise ValueError("Untouched baseline unexpectedly has a sidecar")
        baseline = None if name == "baseline" else baseline_for_enhancement(session, manifest["native"])
        sidecars = {p.name:digest(p) for p in settings}
        tiff, xmp, result = (session / (name + s) for s in (".tif",".returned-xmp",".reference.json"))
        if any(p.exists() for p in (tiff, xmp, result)):
            raise ValueError("Use a fresh output path; reference already exists: " + name)
        running = subprocess.check_output(["osascript", "-e", 'application id "com.adobe.Photoshop" is running'], text=True).strip()
        if running != "true":
            raise ValueError("There is no existing Photoshop process for silent capture")
        front = foreground()
        args = [str(raw), str(tiff), str(xmp), task["expectedPixels"]]
        js = JS + "(" + ",".join(json.dumps(arg) for arg in args) + ");"
        completed = subprocess.run(["osascript","-e","on run argv","-e","with timeout of 600 seconds","-e",
            'tell application id "com.adobe.Photoshop" to do javascript (item 1 of argv)',"-e","end timeout","-e","end run",js],
            capture_output=True,text=True,timeout=610)
        if completed.returncode:
            raise ValueError("Photoshop reference failed: " + completed.stderr.strip())
        ps, opened, saved, width, height, icc = completed.stdout.strip().split("|")
        if int(opened) <= 0 or int(saved) <= 0 or not tiff.is_file() or digest(raw) != CAMERA:
            raise ValueError("Missing output or mutated RAW")
        if foreground() != front:
            raise ValueError("Foreground changed during the background reference run")
        if sidecars != {p.name:digest(p) for p in adjacent_settings()}:
            raise ValueError("Source Adobe settings changed during replay")
        image_properties = tiff_properties(tiff, task["expectedPixels"])
        raster = native_rgb16(tiff, task["expectedPixels"])
        comparison = compare_native_rasters(baseline, raster, name) if baseline else None
        write(result, {"sourceSHA256":CAMERA,"state":name,"settingsMadeIn":host if name != "baseline" else "untouched",
            "sidecars":sidecars,"renderedIn":"Photoshop Camera Raw, CameraRAWOpenOptions.SELECTEDIMAGE",
            "photoshop":ps,"foregroundUnchanged":True,"sourcePixels":manifest["native"],"actualPixels":[int(width),int(height)],"bits":16,
            "icc":icc,"timedBoundary":"One full document open; TIFF writing timed separately. No interactive or warm timing claim.",
            "openMs":int(opened)/1000, "saveMs":int(saved)/1000, "referenceFile":tiff.name,
            "tiffBytes":tiff.stat().st_size,"tiffSHA256":digest(tiff),"returnedXMPSHA256":digest(xmp),
            "imageIOFileProperties": image_properties, "nativeRGB16": raster, "enhancementVsUntouched": comparison,
            "qualification":"Captured for image comparison. Verify actual Enhance state, change only that setting and compare with the untouched baseline."})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    create = commands.add_parser("prepare")
    create.add_argument("--source", required=True, type=Path)
    create.add_argument("--session", required=True, type=Path, metavar="DIRECTORY")
    render = commands.add_parser("export")
    render.add_argument("--session", required=True, type=Path, metavar="DIRECTORY")
    render.add_argument("--states", required=True, choices=STATES, nargs="+")
    render.add_argument("--settings-author", required=True, choices=("Camera Raw 19", "Lightroom Classic"))
    args = parser.parse_args()
    try:
        if args.operation == "prepare":
            prepare(args.source.resolve(), args.session.resolve())
        else:
            export(args.session.resolve(), args.states, args.settings_author)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")
