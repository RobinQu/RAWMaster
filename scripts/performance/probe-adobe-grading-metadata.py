#!/usr/bin/env python3
"""Inventory public Adobe grading terms and inspect the XMP returned by a silent disposable RAW open."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("adobe_raw_open", HERE / "benchmark-camera-raw.py")
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)
CRS = "{" + DRIVER.CRS + "}"
ROOT = Path("/Library/Application Support/Adobe/CameraRaw/Settings")
PLUGIN = Path("/Library/Application Support/Adobe/Plug-Ins/CC/File Formats/Camera Raw.plugin")
MATCH = re.compile(r"(?<!so)lut|lookup|table|grad(?:e|ing)|splitton|localton|look", re.I)
WITNESS = "RAWMasterUnrecognizedMetadataWitness"
JS = """
(function (rawPath, metadataPath) {
    var dialogs = app.displayDialogs, doc = null;
    try {
        app.displayDialogs = DialogModes.NO;
        var opts = new CameraRAWOpenOptions();
        opts.settings = CameraRAWSettingsType.SELECTEDIMAGE;
        opts.colorSpace = ColorSpaceType.SRGB;
        opts.bitsPerChannel = BitsPerChannelType.EIGHT;
        doc = app.open(new File(rawPath), opts);
        var target = new File(metadataPath);
        try {
            target.encoding = "UTF8";
            if (!target.open("w") || !target.write(doc.xmpMetadata.rawData)) throw Error("Cannot save metadata");
        } finally { target.close(); }
        return [app.version, doc.width.as("px"), doc.height.as("px")].join("|");
    } finally {
        try { if (doc) doc.close(SaveOptions.DONOTSAVECHANGES); }
        finally { app.displayDialogs = dialogs; }
    }
})
"""


def schema(item):
    terms = set()
    for node in item.iter():
        for name in [node.tag, *node.attrib]:
            if name.startswith(CRS):
                terms.add(name[len(CRS):])
    return terms


def inventory():
    result = {"presetSources":{}, "factoryCubes":[]}
    lr = Path("/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/Resources")
    for name, root in (("Camera Raw", ROOT), ("Lightroom Classic", lr)):
        files = list(root.rglob("*.xmp"))
        terms = set()
        for path in files:
            terms.update(schema(ET.parse(path).getroot()))
        result["presetSources"][name] = {"files":len(files),"gradingOrTableTerms":sorted(t for t in terms if MATCH.search(t) and not t.startswith("Table_")),
            "embeddedProfileTableCount":sum(t.startswith("Table_") for t in terms)}
    for p in sorted((ROOT / "Adobe/LUTs").glob("*.cube")):
        with p.open() as f:
            dimension = next(int(line.split()[1]) for line in f if line.startswith("LUT_3D_SIZE"))
        result["factoryCubes"].append({"file":p.name,"dimension":dimension,"sha256":DRIVER.digest(p)})
    # Read only the plug-in's publicly declared Apple Event scripting terminology.
    resource = (PLUGIN/"Contents/Resources/Camera Raw.rsrc").read_bytes()
    data, map_offset, _, _ = struct.unpack_from(">4I",resource)
    table = map_offset + struct.unpack_from(">H",resource,map_offset+24)[0]
    total = struct.unpack_from(">H",resource,table)[0]+1
    terms = set()
    for i in range(total):
        type_id, count, relative = struct.unpack_from(">4sHH",resource,table+2+8*i)
        if type_id != b"aete":
            continue
        for j in range(count+1):
            entry = table+relative+j*12
            offset = data + int.from_bytes(resource[entry+5:entry+8],"big")
            length = struct.unpack_from(">I",resource,offset)[0]
            payload = resource[offset+4:offset+4+length]
            terms.update(t.decode() for t in re.findall(rb"\$\$\$/CRaw/AETE/([A-Za-z0-9]+)",payload))
    result["appleEventTerminology"] = sorted(t for t in terms if MATCH.search(t))
    return result


def candidate_settings(path):
    tree=ET.parse(path)
    description=tree.getroot().find(".//{"+DRIVER.RDF+"}Description")
    correction=description.find(".//"+CRS+"MaskGroupBasedCorrections//{"+DRIVER.RDF+"}Description")
    # The known local colorize has different meaning. Leave it untouched. Candidate keys only
    # become evidence when Camera Raw serializes them back inside the correction and changes pixels.
    for prefix in ("ColorGrade","ColorGrading","LocalColorGrade","LocalColorGrading"):
        for light in ("Global","Midtone","Shadow","Highlight","Shadows","Midtones","Highlights"):
            for suffix,value in (("Hue",142),("Sat",.75),("Saturation",.65),("Lum",.25),("Luminance",.15)):
                correction.set(CRS+prefix+light+suffix,str(value))
        correction.set(CRS+prefix+"Blending","62")
        correction.set(CRS+prefix+"Balance","21")
    for prefix in ("LocalSplitToning","SplitToning"):
        for light in ("Shadow","Highlight"):
            correction.set(CRS+prefix+light+"Hue","122")
            correction.set(CRS+prefix+light+"Saturation",".8")
    correction.set(CRS+"LocalRAWMasterUnrecognizedMetadataWitness","discard-me")
    profile=ROOT/"Premium/Style - Film/Profiles/Film 09.xmp"
    source=ET.parse(profile).getroot().find(".//{"+DRIVER.RDF+"}Description")
    fingerprint=source.attrib[CRS+"RGBTable"]
    data=source.attrib.get(CRS+"Table_"+fingerprint)
    if not data:
        entry=source.find(CRS+"Table_"+fingerprint)
        if entry is None:raise ValueError("No serialized 3D table in the installed profile")
        data=entry.text
    # Embed valid table bytes without selecting the legacy Look / RGBTable profile.
    description.set(CRS+"Table_"+fingerprint,data)
    structures=("ColorTables","ColorLookupTables","GradingTables","ColorGradingLUTs","ColorGradeLUTs","ColorGradeTables",
        "ColorGradingTables","AppliedLUTs","LookupTables","LUTs","ColorLookupTableStack","ColorTableStack","TableStack")
    refs=("ColorTable","ColorLookupTable","GradingTable","GradingLUT","ColorGradeLUT","ColorGradingLUT","ApplyLUT","LUT","LookupTable")
    for parent,prefixes in ((description,("",)),(correction,("","Local"))):
        for prefix in prefixes:
            for key in structures:
                seq=ET.SubElement(ET.SubElement(parent,CRS+prefix+key),"{"+DRIVER.RDF+"}Seq")
                item=ET.SubElement(seq,"{"+DRIVER.RDF+"}li")
                values=ET.SubElement(item,"{"+DRIVER.RDF+"}Description")
                DRIVER.put_attributes(values,{"Table":fingerprint,"RGBTable":fingerprint,"ColorTable":fingerprint,"TableFingerprint":fingerprint,
                    "TableID":fingerprint,"LookupTable":fingerprint,"TableAmount":1,"RGBTableAmount":1,"Amount":1,"Name":"Color LUT 01"})
            for key in refs:
                parent.set(CRS+prefix+key,fingerprint)
                parent.set(CRS+prefix+key+"Amount",".75")
    tree.write(path,encoding="utf-8",xml_declaration=True)
    return {"candidateStructures":list(structures),"candidateTableReferences":list(refs),"validEmbeddedRGBTable":fingerprint,
            "selectedLegacyProfile":False,"includedFactoryCubeFiles":False}


def foreground():
    command = 'use framework "AppKit"\nreturn (current application\'s NSWorkspace\'s sharedWorkspace()\'s frontmostApplication()\'s bundleIdentifier()) as text'
    return subprocess.check_output(["osascript","-l","AppleScript","-e",command],text=True).strip()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--candidates",action="store_true")
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit("Select a fresh report path")
    doc = inventory()
    active = foreground()
    if active == "com.adobe.Photoshop":
        raise SystemExit("Choose a background Photoshop session")
    source_hash = DRIVER.digest(args.raw)
    with tempfile.TemporaryDirectory(prefix="rawmaster-grading-schema-") as temp:
        root = Path(temp)
        source, result = root/"probe.ARW", root/"result.xmp"
        shutil.copyfile(args.raw,source)
        DRIVER.write_sidecar(source.with_suffix(".xmp"),{WITNESS:"ignore-this-property","ColorGradeMidtoneHue":165,
            "ColorGradeMidtoneSat":30, "LocalExposure2012":.35})
        if args.candidates:doc["candidates"]=candidate_settings(source.with_suffix(".xmp"))
        js = JS+"("+json.dumps(str(source))+","+json.dumps(str(result))+");"
        value = subprocess.check_output(["osascript","-e","on run argv","-e","with timeout of 90 seconds","-e",
            'tell application id "com.adobe.Photoshop" to do javascript (item 1 of argv)',"-e","end timeout","-e","end run",js],
            timeout=95,text=True).strip().split("|")
        if foreground() != active:
            raise SystemExit("Foreground owner changed during the probe")
        raw_tree = ET.parse(result).getroot()
        terms = schema(raw_tree)
        levels = {}
        def inspect(node, ancestors=()):
            name=node.tag.split("}")[-1]
            path=(*ancestors,name)
            if node.tag.startswith(CRS) and MATCH.search(name) and not name.startswith("Table_"):
                if node.text and len(node.text.strip()) < 100:levels["/".join(path)]=node.text.strip()
                else:levels["/".join(path)]=None
            for k,v in node.attrib.items():
                if k.startswith(CRS) and MATCH.search(k[len(CRS):]) and not k[len(CRS):].startswith("Table_"):
                    levels["/".join([*path,"@"+k[len(CRS):]])]=v[:80]
            for child in node:inspect(child,path)
        inspect(raw_tree)
        doc["renderedMetadata"]={"photoshop":value[0],"size":list(map(int,value[1:])),
            "allCRSTermCount":len(terms),"gradingTerms":sorted(t for t in terms if MATCH.search(t) and not t.startswith("Table_")),
            "scopes":levels,"unknownWitnessCopied":WITNESS in terms,"knownGlobalWheelRecorded":"ColorGradeMidtoneHue" in terms,
            "knownCorrectionRecorded":"LocalExposure2012" in terms,"returnedXMPBytes":result.stat().st_size,
            "returnedXMPSHA256":DRIVER.digest(result)}
    if DRIVER.digest(args.raw)!=source_hash:
        raise ValueError("Original RAW changed")
    doc.update(sourceSHA256=source_hash,sourceSHA256After=source_hash,foregroundUnchanged=True)
    args.output.write_text(json.dumps(doc,indent=2,ensure_ascii=False)+"\n")
