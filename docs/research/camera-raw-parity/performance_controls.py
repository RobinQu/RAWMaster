"""Join per-control trials to the maintained feature inventory without attributing compound renders."""
import html
import hashlib
import json
import math
import re
from collections import Counter
from pathlib import Path
import statistics
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts/performance"))
from histogram_witness import grain_distances, native_pixel_separation
from lightflow_editor_evidence import supplemental_controls, rendered_temperature
from mask_grading_witness import verify as verify_mask_grading
from profile_match_witness import verify_report as verify_profile_match

HERE = Path(__file__).resolve().parent
PRODUCTS = ("LightFlow", "RAWMaster", "Camera Raw")
INPUTS = {"LightFlow": "lightflow.json", "RAWMaster": "rawmaster-controls.json", "Camera Raw": "camera-raw-open.json"}
CANVAS = {"LightFlow": "lightflow-canvas.json", "RAWMaster": "rawmaster-canvas.json", "Camera Raw": "camera-raw-canvas.json"}
LABELS = {"measured": "已实测", "inconclusive": "未验证出有效变化", "unmeasured": "未单测", "unsupported": "当前缺失", "inapplicable": "样本不适用", "unavailable-equivalent": "无同义操作", "related": "仅有相关操作"}
SOURCE_ONLY = {"color-temp-rendered": "本次输入为 RAW。该控件用于已显影图像。",
               "detail-denoise-formats": "该项针对已显影的文件。九种已显影容器和输出参考 DNG 的独立实测列在降噪表。",
               "blur-device-depth": "该 ARW 没有设备深度通道。"}
UI_CONTROLS = set("""light-histogram-drag light-auto-single light-clipping-modifier light-numeric-reset color-wb-picker
color-floating-scopes color-samplers color-rgb-readout color-lab-readouts color-vectorscope color-skin-indicator
curve-input-output curve-reset-channel curve-tat-parametric curve-tat-point curve-keyboard mixer-hsl-mode mixer-color-mode
mixer-eight-colors mixer-tat mixer-point-picker mixer-point-swatches grading-lut-manage grading-lut-import optics-profile-match
optics-profile-select optics-profile-defaults optics-defringe-picker blur-subject-focus blur-point-focus blur-area-focus
blur-brush-size blur-feather blur-flow blur-auto-mask blur-reset-refinement""".split())


def stats(values):
    if not values or any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("Expected positive, finite timings")
    ordered = sorted(values)
    return {"n": len(values), "medianMs": statistics.median(ordered),
            "p95Ms": ordered[math.ceil(0.95 * len(ordered)) - 1] if len(ordered) > 1 else None,
            "maxMs": max(values)}


def read_evidence(name, sha, product):
    path = HERE / "evidence" / name
    data = json.loads(path.read_text())
    if data["sourceSHA256"] != sha or ("sourceSHA256After" in data and data["sourceSHA256After"] != sha):
        raise ValueError(f"{product}: incompatible source in {name}")
    return data


def record(row, name, boundary, expected, samples, reason=None):
    result = {"state": "inconclusive", "boundary": boundary, "evidence": "evidence/" + name}
    if row.get("status") == "measured":
        if len(samples) != expected or any(type(x) not in (float, int) for x in samples):
            raise ValueError(f"{name}: incomplete verified sample population")
        result.update(state="measured", timing=stats(samples))
    else:
        result["reason"] = reason or row.get("reason") or row.get("error") or "未取得稳定且有不同像素的画面。"
    return result


def single_control_rows(product, name, data):
    result = {}
    if product == "Camera Raw":
        if data.get("workCopySHA256After") != data["sourceSHA256"] or not (data.get("finishedAt") or any(s.get("checkpointAt") for s in data.get("sessions", []))):
            raise ValueError("Incomplete Adobe processing run")
        planned = data.get("planned", list(data["operations"]))
        if len(planned) != len(set(planned)) or not set(data["operations"]).issubset(planned):
            raise ValueError("Unexpected control in Adobe processing run")
        if data.get("finishedAt") and set(planned) != set(data["operations"]):
            raise ValueError("Missing planned Adobe operation")
        for key, row in data["operations"].items():
            samples = row["samples"]
            verified = row["status"] == "measured"
            if verified:
                expected = [(iteration, state) for iteration in range(data["repeats"] + 1) for state in ("control", "edit")]
                if [(s["iteration"], s["state"]) for s in samples] != expected or len({tuple(s["outputPixels"]) for s in samples}) != 1:
                    raise ValueError(f"Unexpected Adobe A/B pair order or output dimensions: {key}")
            if verified and key == "grading-mask-wheels":
                local = verify_mask_grading(samples)
                if not local["qualified"] or local != row["localMaskSeparation"]:
                    raise ValueError("Local Adobe color wheel did not reproduce inside its mask")
            controls, edits = [{s["histogramSHA256"] for s in samples if s["state"] == k} for k in ("control", "edit")]
            if verified and (len(controls) != 1 or len(edits) != 1 or controls == edits):
                distances = grain_distances(samples) if "grain" in key and row.get("grainDistances") else None
                spatial_ok = False
                if row.get("witness") == "spatialRGBSHA256" and data.get("spatialWitness"):
                    spatial = [{s["spatialRGBSHA256"] for s in samples if s["state"]==state} for state in ("control","edit")]
                    spatial_ok = all(len(s)==1 for s in spatial) and spatial[0] != spatial[1] and len({tuple(s["spatialPixels"]) for s in samples}) == 1
                if row.get("witness") == "nativeRGB8HeldOut" and data.get("spatialWitness","").startswith("native-size"):
                    pixels = row["nativePixels"]
                    separation = native_pixel_separation(pixels)
                    w,h = samples[0]["outputPixels"]
                    if (len(pixels["samples"]) != len(samples) or any(s["spatialPixels"] != [w,h] for s in samples)
                            or any(not (0<=x<w and 0<=y<h) for x,y in pixels["coordinates"])):
                        raise ValueError(f"Incompatible native pixel witness for {key}")
                    spatial_ok = separation == row["nativePixelSeparation"] and separation["qualified"]
                if not spatial_ok and (not distances or distances != row["grainDistances"] or distances["minimumBetween"] <= 2 * distances["maximumWithin"]):
                    raise ValueError(f"Missing Adobe A/B histogram proof: {key}")
            warm = [s["openMs"] for s in samples if s["state"] == "edit" and s["iteration"] > 0]
            result[key] = record(row, name, "完整 RAW 打开为 Photoshop 文档", data["repeats"], warm)
            pixels = {tuple(s["outputPixels"]) for s in samples}
            if len(pixels) == 1: result[key]["outputPixels"] = list(pixels.pop())
            if samples: result[key]["firstEditMs"] = next((s["openMs"] for s in samples if s["state"] == "edit"), None)
        return result
    for row in data["operations"]:
        if product == "LightFlow":
            trials = row["trials"]
            warm = [t["ms"] for t in trials if t["phase"] == "warm" and t["verified"]]
            item = record(row, name, "2400 px · 配方提交至 GPU 完成", data["samples"], warm)
            if trials: item["firstEditMs"] = trials[0]["ms"]
            keys = row["featureIds"]
            if len(keys) > 1:
                raise ValueError(f"Compound LightFlow timing cannot count individual features: {keys}")
        else:
            trials = row["samples"]
            warm = [t["ms"] for t in trials if t["phase"] == "warm"]
            keys = [row["id"]]
            sigs = [{t["digest"] for t in trials if t["state"] == n} for n in (0, 1)]
            if row["status"] == "measured" and (any(len(x) != 1 for x in sigs) or sigs[0] == sigs[1]):
                raise ValueError(f"Missing RAWMaster control pixel proof: {keys}")
            item = record(row, name, "2400 px · 配方提交至交互帧返回", data["repeats"], warm)
            if len(trials) > 1: item["firstEditMs"] = trials[1]["ms"]
            item["outputPixels"] = row["outputPixels"]
            if "decoders" in row: item["decoders"] = row["decoders"]
        for key in keys:
            if key in result: raise ValueError(f"Duplicate feature evidence: {key}")
            result[key] = item
    return result


def unavailable(feature, product):
    key = feature["id"]
    if key in SOURCE_ONLY: return {"state": "inapplicable", "reason": SOURCE_ONLY[key]}
    if product == "RAWMaster" and feature["status"] == "missing":
        return {"state": "unsupported", "reason": feature["difference"]}
    reason = "尚无该操作的独立参数与像素验证。"
    if key in UI_CONTROLS: reason = "需要单独测量界面交互或分析结果更新。"
    return {"state": "unmeasured", "reason": reason}


def inspection_rows(data, name):
    if (data.get("protocol") != "rawmaster-analysis-and-inspection-v1" or data["sourceSHA256"] != data["sourceSHA256After"]
            or data["inspectionFramePixels"] != [2400,1600] or data["repeats"] < 10):
        raise ValueError(f"Incompatible RAWMaster inspection session: {name}")
    entries, rendered_focus = {}, {}
    for row in data["operations"]:
        key, trials = row["id"], row["samples"]
        if row["status"] == "measured":
            if len(trials) != data["repeats"]+2 or any(t["state"]!=i%2 or t["phase"]!=("first" if i<2 else "warm") for i,t in enumerate(trials)):
                raise ValueError(f"Incomplete RAWMaster inspection trials for {key}")
            witness = [{t["digest"] for t in trials if t["state"]==i} for i in (0,1)]
            if any(len(s)!=1 for s in witness) or (not row["verification"].startswith("each automatic") and witness[0]==witness[1]):
                raise ValueError(f"Missing RAWMaster inspection evidence for {key}")
            if key in {"blur-point-focus","blur-area-focus","blur-subject-focus","grading-lut-import"}:
                photo = [{tuple(t["witness"]["sampleRGB8SHA256"]) for t in trials if t["state"] == state} for state in (0,1)]
                if (any(len(group) != 1 or len(next(iter(group))) != 32 for group in photo)
                        or (key != "blur-subject-focus" and photo[0] == photo[1])):
                    raise ValueError(f"Missing independent rendered photo change for {key}")
                rendered_focus[key] = photo
        measurement = record(row,name,row["boundary"],data["repeats"],[t["ms"] for t in trials if t["phase"]=="warm"])
        measurement["input"] = row["input"]
        measurement["displayBoundary"] = ("图像分析" if row["boundary"].startswith("raw.analysis") else
            "示波器离屏绘制" if key in ("color-vectorscope","color-skin-indicator") else "画布读数／交互")
        if key in entries: raise ValueError(f"Duplicate inspection control {key}")
        entries[key] = measurement
    if "blur-subject-focus" in rendered_focus:
        # Both displaced point-focus recipes are rendered in this session with the
        # same depth map, amount and range that precede automatic subject selection.
        starts = rendered_focus.get("blur-point-focus")
        if not starts or any(not a.isdisjoint(b) for a,b in zip(starts, rendered_focus["blur-subject-focus"])):
            raise ValueError("Automatic subject focus did not change the photo from both manual starting points")
    return entries


def lightflow_editor_tools(sha, engine):
    rows = {}
    colors = {"red","orange","yellow","green","aqua","blue","purple","magenta"}
    viewer_ids = {"light-clipping-indicators","light-clipping-modifier","detail-mask-preview","detail-sharpen-radius"}
    for name, protocol, expected in (
        ("lightflow-viewer-tools.json","lightflow-stock-viewer-tools-v1",viewer_ids),
        ("lightflow-panel-tools.json","lightflow-editor-panel-actions-v1",{"mixer-hsl-mode","mixer-eight-colors","grading-lut-import"}),
    ):
        if not (HERE/"evidence"/name).is_file(): continue
        report = read_evidence(name,sha,"LightFlow")
        viewer = expected == viewer_ids
        if (report["protocol"] != protocol or report["build"] != engine["build"] or report["samples"] != 10
                or {r["id"] for r in report["operations"]} != expected or len(expected) != len(report["operations"])):
            raise ValueError(f"Different LightFlow editor workload in {name}")
        if viewer:
            if report["engineSHA256"] != engine["engineSHA256"] or report["pixels"] != [2400,1600] or report["witnessGrid"] != [96,64]:
                raise ValueError("Incompatible LightFlow viewer pixels or binary")
        elif (report["photoRectPixels"][2:] != [2368,1579] or
              not all(digest in report["uiSHA256"].values() for digest in engine["engineSHA256"].values())):
            raise ValueError("Incompatible LightFlow editor or photo geometry")
        for row in report["operations"]:
            key, trials = row["id"],row["trials"]
            if row["featureIds"] != [key] or len(trials) != 12 or any(
                t["state"] != i%2 or t["phase"] != ("first" if i<2 else "warm")
                or not t["verified"] or not re.fullmatch(r"[0-9a-f]{64}",t["digest"]) for i,t in enumerate(trials)):
                raise ValueError(f"Incomplete editor evidence for {key}")
            groups = [{t["digest"] for t in trials if t["state"]==s} for s in (0,1)]
            if key in ("light-clipping-indicators","light-clipping-modifier","detail-sharpen-radius","grading-lut-import"):
                if any(len(group)!=1 for group in groups) or groups[0]==groups[1]: raise ValueError(f"No stable output for {key}")
            for t in trials:
                if key == "light-clipping-indicators" and t["state"]:
                    c = t["clipping"]
                    if c["changed"] < 8 or c["inExtremes"] < .9*c["changed"]: raise ValueError("Missing clipped-pixel witness")
                elif key == "detail-mask-preview":
                    if not (t["grey"] >= .99*6144 and min(t["black"],t["white"])>16 if t["state"] else t["grey"] < .1*6144):
                        raise ValueError("Missing sharpening mask photo witness")
                elif key == "mixer-hsl-mode":
                    fields = t["observed"]["rows"]
                    if {f["label"].lower() for f in fields} != colors or any((f["min"],f["max"])!=(-100,100) for f in fields):
                        raise ValueError("Incomplete original HSL panel")
                elif key == "mixer-eight-colors":
                    o=t["observed"]
                    # The stock editor omits neutral parameters before the first edit.
                    if (set(o["after"])!=colors or set(o["before"])-colors or o["actualFieldValue"]!=o["after"][o["color"]]
                            or {c for c in colors if o["before"].get(c,0)!=o["after"][c]}!={o["color"]}):
                        raise ValueError("Original eight-band mixer changed the wrong color")
                elif key == "grading-lut-import":
                    if t["sourceTableSize"]!=17 or t["returned"]["asset"]!="lut-"+t["sourceCubeSHA256"][:24]:
                        raise ValueError("Imported LUT does not match its source bytes")
            boundary = report["boundary"] if viewer else row["boundary"]
            cell = record(row,name,boundary,10,[t["ms"] for t in trials[2:]])
            cell.update(firstEditMs=trials[0]["ms"], displayBoundary="2400 px 完整显示图读回" if viewer else "原版编辑器操作回执")
            rows[key] = cell
    return rows


def assemble(sha):
    features = json.loads((HERE / "feature-matrix.json").read_text())["features"]
    ids = {f["id"] for f in features}
    data, canvas, sessions = {}, {}, {}
    for product in PRODUCTS:
        source = read_evidence(INPUTS[product], sha, product)
        data[product] = single_control_rows(product, INPUTS[product], source)
        if product == "RAWMaster" and (HERE/"evidence/super-resolution-native.json").is_file():
            name = "super-resolution-native.json"
            report = json.loads((HERE/"evidence"/name).read_text())
            output = report["tiff16"]
            if (report["rawSHA256"] != sha or report["build"] != "release" or output["bits"] != 16
                    or output["size"] != [n*2 for n in report["native"]] or not re.fullmatch(r"[0-9a-f]{64}",output["sha256"])):
                raise ValueError("Missing real 2x source, geometry or export witness")
            data[product]["detail-super-resolution"] = {"state":"measured","evidence":"evidence/"+name,
                "boundary":"Normal export through complete learned 2x TIFF16 in sRGB", "displayBoundary":"完整 2× TIFF16 导出",
                "timing":stats([output["elapsedMs"]])}
        for name in ("rawmaster-inspection.json","rawmaster-inspection-focus.json") if product == "RAWMaster" else ():
            if not (HERE / "evidence" / name).is_file(): continue
            extra = inspection_rows(read_evidence(name,sha,product),name)
            if extra.keys() & data[product].keys(): raise ValueError("Duplicate RAWMaster recipe and inspection timings")
            data[product].update(extra)
        for name in ("lightflow-lut.json", "lightflow-supplement.json") if product == "LightFlow" else ():
            if not (HERE / "evidence" / name).is_file():
                continue
            supplement = read_evidence(name, sha, product)
            if any(supplement.get(k) != source.get(k) for k in ("build","target","engineSHA256")):
                raise ValueError("Incompatible LightFlow LUT runtime or target")
            more = single_control_rows(product, name, supplement)
            if set(more) & set(data[product]): raise ValueError("Duplicate LightFlow observations")
            data[product].update(more)
        if product == "LightFlow":
            support = json.loads((HERE / "evidence/lightflow-availability.json").read_text())
            if support["build"] != source["build"]: raise ValueError("Different LightFlow capability inventory")
            for category, entries in (("unavailable-equivalent", support["operations"]), ("related", support.get("relatedOperations", []))):
                for entry in entries:
                    key = entry["featureId"]
                    if key in data[product]: raise ValueError(f"Conflicting LightFlow capability or timing: {key}")
                    data[product][key] = {"state":category, "reason":entry["reason"], "evidence":"evidence/lightflow-availability.json"}
            name = "lightflow-analysis.json"
            if (HERE / "evidence" / name).is_file():
                analysis = read_evidence(name,sha,product)
                sample = analysis["sample"]
                if (analysis["protocol"] != "lightflow-auto-analysis-v1" or analysis["engineSHA256"] != source["engineSHA256"]
                        or analysis["build"] != source["build"] or analysis["samples"] != 20 or
                        [sample["width"],sample["height"]] != [384,256] or sample["opaque"] != 384*256):
                    raise ValueError("Incompatible LightFlow automatic analysis source")
                for row in analysis["operations"]:
                    key, trials = row["id"], row["trials"]
                    if (key in data[product] or key not in {"light-auto","color-wb-auto"} or row["featureIds"] != [key]
                            or len(trials) != analysis["samples"] + 2 or any(t["state"] != i%2 or
                            t["phase"] != ("first" if i < 2 else "warm") or not t["verified"] or not t["changed"]
                            or not all(math.isfinite(t["values"][f]) for f in row["fields"]) for i,t in enumerate(trials))):
                        raise ValueError(f"Unverified LightFlow automatic analysis for {key}")
                    cell = record(row,name,analysis["boundary"],analysis["samples"],[t["ms"] for t in trials if t["phase"]=="warm"])
                    cell.update(displayBoundary="384 px 图像分析", firstEditMs=trials[0]["ms"], initialSampleMs=sample["sampleReadyMs"])
                    data[product][key] = cell
            name = "lightflow-gestures.json"
            if (HERE / "evidence" / name).is_file():
                gestures = read_evidence(name,sha,product)
                if (gestures["protocol"] != "lightflow-ui-gesture-value-v1" or gestures["build"] != source["build"]
                        or gestures["samples"] != 10 or gestures["photoRectPixels"][2:] != [2368,1579]):
                    raise ValueError("Incompatible LightFlow editor gesture viewport or version")
                for row in gestures["operations"]:
                    key, trials = row["id"], row["trials"]
                    if (key in data[product] or row["featureIds"] != [key] or len(trials) != gestures["samples"]+2
                            or any(t["state"] != i%2 or t["phase"] != ("first" if i<2 else "warm") or not t["verified"]
                                   or t["before"] == t["after"] or t["after"] != t["committed"] or t["releaseCount"] < 1
                                   or abs(t["end"]-t["start"]-t["ms"]) > .001 for i,t in enumerate(trials))):
                        raise ValueError(f"Unverified LightFlow editor gesture for {key}")
                    cell = record(row,name,gestures["boundary"],gestures["samples"],[t["ms"] for t in trials if t["phase"]=="warm"])
                    cell.update(displayBoundary="原版界面手势至数值公布", firstEditMs=trials[0]["ms"], input=row["input"])
                    data[product][key] = cell
            editor = lightflow_editor_tools(sha, source)
            extra = supplemental_controls(sha, source)
            if editor.keys() & extra.keys(): raise ValueError("Duplicate supplemental LightFlow control")
            editor.update(extra)
            for key, cell in editor.items():
                if data[product].get(key,{}).get("state") not in (None, "inconclusive"):
                    raise ValueError(f"Duplicate original-editor observation for {key}")
                data[product][key] = cell
        for name in ("camera-raw-points.json","camera-raw-spatial.json","camera-raw-supplement.json","camera-raw-native-ca.json","camera-raw-native-pixels.json","camera-raw-grading-mask.json","camera-raw-lens-blur-native.json","camera-raw-profile-match.json") if product == "Camera Raw" else ():
            if not (HERE/"evidence"/name).is_file(): continue
            supplement = read_evidence(name, sha, product)
            if name == "camera-raw-profile-match.json":
                verify_profile_match(supplement, HERE / "evidence" / "camera-raw-profile-match-xmp.zip")
            if any(supplement.get(k) != source.get(k) for k in ("cameraRaw","protocol","hardware","os","repeats")):
                raise ValueError("Incompatible Adobe supplemental run")
            more = single_control_rows(product, name, supplement)
            for key, cell in more.items():
                old = data[product].get(key)
                if old and old["state"] == "measured":
                    raise ValueError(f"Duplicate successful Adobe control: {key}")
                data[product][key] = cell
        if set(data[product]) - ids: raise ValueError(f"Unknown {product} feature IDs: {set(data[product])-ids}")
        sessions[product] = {k: v for k, v in source.items() if k in ("build","cameraRaw","system","hardware","os","gpu","decoder","adapter","browser",
                                                                         "target","recordedAt","startedAt","finishedAt","rawSize","rawOpenMs","rawDecodeMs","rawDevelopMs","boundary","revision","sourceTreeSHA256","binarySHA256","physicalMemory")}
        if product == "Camera Raw":
            sessions[product]["runState"] = "complete" if source.get("finishedAt") else "checkpoint"
            sessions[product]["attempted"] = len(source["operations"])
            sessions[product]["planned"] = len(source.get("planned", source["operations"]))
        canvas[product] = {}
        if not (HERE / "evidence" / CANVAS[product]).is_file(): continue
        screen = read_evidence(CANVAS[product], sha, product)
        if screen.get("protocol") != "screen-photo-response-v1" or screen.get("sourceSHA256After") != sha:
            raise ValueError(f"Incomplete screen capture from {product}")
        if product == "LightFlow":
            stock = read_evidence("lightflow-panel-schedule.json", sha, product)
            engine = {Path(path).name:digest for path,digest in screen["uiSHA256"].items()
                      if re.fullmatch(r"_b/\d+-" + re.escape(stock["build"]) + r"/rust/web/[^/]+", path)}
            if screen["build"] != stock["build"] or any(engine.get(f) != digest for f,digest in stock["engineSHA256"].items()):
                raise ValueError("The window capture and release reference use different LightFlow engines")
        if "sessions" in screen:
            for session in screen["sessions"]:
                archive = Path(session["archive"])
                if archive.name != session["archive"] or hashlib.sha256((HERE/"evidence/history"/archive).read_bytes()).hexdigest() != session["archiveSHA256"]:
                    raise ValueError(f"{product} screen archive differs from the timing evidence")
        sessions[product]["canvas"] = {k: screen[k] for k in ("driver", "photoRectPixels", "roi", "policy", "browser", "build", "sessions") if k in screen}
        for key, row in screen["operations"].items():
            if key not in ids: raise ValueError(f"Unknown {product} display feature {key}")
            trials = row.get("trials", [])
            measured = [t["firstMs"] for t in trials if t["verified"]]
            if row.get("status") == "measured" and len(trials) < 10:
                raise ValueError(f"Short screen pilot submitted as a qualified capture for {product}/{key}")
            if product == "Camera Raw" and screen.get("sessions") and row.get("status") == "measured":
                if not any(s["archive"]==row["archive"] and s["outcomes"].get(key)=="measured" for s in screen["sessions"]):
                    raise ValueError(f"Missing complete Adobe screen series for {key}")
                events = [*row["calibration"],*trials]
                if any(float(t["committedValue"]) != row["values"][i%2] or t["state"] != i%2 for i,t in enumerate(events)):
                    raise ValueError(f"Uncommitted Adobe input for {key}")
            cell = record(row, CANVAS[product], "输入至首个经像素验证的画布变化", len(trials), measured)
            if "values" in row: cell["values"] = row["values"]
            canvas[product][key] = cell
    inventory = [{"id": f["id"], "name": f["name"], "panel": f["panel"], "implementation": f["status"],
        "products": {p: data[p].get(f["id"], unavailable(f, p)) for p in PRODUCTS},
        "canvas": {p: canvas[p][f["id"]] for p in PRODUCTS if f["id"] in canvas[p]}} for f in features]
    counts = {p: dict(Counter(r["products"][p]["state"] for r in inventory)) for p in PRODUCTS}
    return {"controls": inventory, "coverage": counts, "sessions": sessions,
            "allThreeMeasured": sum(all(r["products"][p]["state"] == "measured" for p in PRODUCTS) for r in inventory),
            "canvasMeasured": {p: sum(v["state"] == "measured" for v in canvas[p].values()) for p in PRODUCTS}}


def compositor_measurements(sha, control_matrix):
    name = "lightflow-compositor.json"
    screen = read_evidence(name, sha, "LightFlow")
    trial_rows = {}
    known = {r["id"] for r in control_matrix["controls"]}
    if (screen["protocol"] != "headless-compositor-photo-response-v1" or screen["sourceSHA256After"] != sha
            or screen["build"] != control_matrix["sessions"]["LightFlow"]["build"]):
        raise ValueError("Unexpected LightFlow compositor protocol, build or source")
    for key, row in screen["operations"].items():
        trials = row["trials"]
        if key not in known or len(set(row["referenceDigests"])) != 2:
            raise ValueError(f"Missing LightFlow reference pair for {key}")
        if row["status"] == "measured" and (len(trials) < 10 or any(t["state"] != i % 2 or not t["accepted"]
                or t["actual"] != row["values"][t["state"]] or not t["verified"] for i, t in enumerate(trials))):
            raise ValueError(f"Invalid LightFlow compositor trial for {key}")
        trial_rows[key] = {"label":row["displayLabel"], "cell":record(row, name, "按键提交到 Chromium 合成器图像交换",
            len(trials), [t["firstMs"] for t in trials if t["verified"]])}
    return {"rows":trial_rows, **{k:screen[k] for k in ("browser", "photoRectPixels", "transportPixels", "policy", "measurementSurface")}}


READBACK_CONTROLS = {"light-exposure", "light-contrast", "light-highlights", "light-shadows",
                     "light-whites", "light-blacks", "color-saturation", "color-vibrance"}


def readback_rows(data, product):
    sha = data["sourceSHA256"]
    if (not re.fullmatch(r"[0-9a-f]{64}", sha) or data["sourceSHA256After"] != sha or
            data["protocol"] != "resident-srgb8-readback-v1" or data["application"] != product or
            data["pixels"] != [2400, 1600] or data["samples"] != 20 or data["distinctInputCount"] != 20 or
            data["cachePolicy"] != "shipping defaults"):
        raise ValueError(f"Different display readback workload for {product}")
    rows = {}
    for row in data["operations"]:
        key, trials, sweep = row["id"], row["samples"], row["distinctInputs"]
        if key in rows or len(trials) != data["samples"] + 2 or any(
                t["state"] != i % 2 or t["phase"] != ("first" if i < 2 else "warm") for i, t in enumerate(trials)):
            raise ValueError(f"Invalid display readback trials for {product}/{key}")
        if any(not re.fullmatch(r"[0-9a-f]{64}", t["digest"]) or not math.isfinite(t["ms"]) or t["ms"] <= 0
               for t in trials + sweep):
            raise ValueError(f"Invalid pixel digest or timing for {product}/{key}")
        states = [{t["digest"] for t in trials if t["state"] == j} for j in (0, 1)]
        if row["status"] != "measured" or any(len(s) != 1 for s in states) or states[0] == states[1]:
            raise ValueError(f"Incomplete display readback proof for {product}/{key}")
        values = [t["value"] for t in sweep]
        if (len(set(row["values"])) != 2 or len(sweep) != data["samples"] or len(set(values)) != len(sweep)
                or len({t["digest"] for t in sweep}) != len(sweep)):
            raise ValueError(f"Unverified slider values for {product}/{key}")
        rows[key] = {"values": row["values"], "sweep": values,
                     "repeated": stats([t["ms"] for t in trials if t["phase"] == "warm"]),
                     "newValues": stats([t["ms"] for t in sweep])}
    if set(rows) != READBACK_CONTROLS:
        raise ValueError(f"Incomplete paired display control inventory for {product}")
    return rows


def compare_readback(reference, current, reference_label, current_label):
    compared = {"repeated": {}, "newValues": {}}
    for key, old in reference.items():
        new = current[key]
        if any(old[field] != new[field] for field in ("values", "sweep")):
            raise ValueError(f"Different readback slider values for {key}")
        for phase, rows in compared.items():
            before, after = old[phase], new[phase]
            median_limit = before["medianMs"] + max(1, .1 * before["medianMs"])
            p95_limit = before["p95Ms"] + max(2, .2 * before["p95Ms"])
            rows[key] = {"values": old["values"], reference_label: before, current_label: after,
                         "medianLimit": median_limit, "p95Limit": p95_limit,
                         "within": after["medianMs"] <= median_limit and after["p95Ms"] <= p95_limit}
    return compared


def matched_readback(sha):
    reference = readback_rows(read_evidence("lightflow-display-readback.json", sha, "LightFlow"), "LightFlow")
    current = readback_rows(read_evidence("rawmaster-display-readback.json", sha, "RAWMaster"), "RAWMaster")
    return compare_readback(reference, current, "LightFlow", "RAWMaster")


def readback_repeatability(sha, name="interactive-merged-readback-repeatability.json"):
    source = read_evidence(name, sha, "RAWMaster")
    reference = readback_rows(read_evidence(source["reference"], sha, "LightFlow"), "LightFlow")
    phases = ("repeated", "newValues")
    pool = {key: {"values": row["values"], "sweep": row["sweep"], **{p: [] for p in phases}}
            for key, row in reference.items()}
    runs = []
    for expected, run in enumerate(source["runs"], start=1):
        path = HERE / "evidence" / run["path"]
        if run["run"] != expected or hashlib.sha256(path.read_bytes()).hexdigest() != run["evidenceSHA256"]:
            raise ValueError("Readback repetitions must match the original process records")
        data = read_evidence(run["path"], sha, "RAWMaster")
        rows = readback_rows(data, "RAWMaster")
        if data["binarySHA256"] != source["RAWMasterBinarySHA256"]:
            raise ValueError("Readback repetitions used different builds")
        result = compare_readback(reference, rows, "LightFlow", "RAWMaster")
        counts = {p: sum(r["within"] for r in result[p].values()) for p in phases}
        if any(run["gateSummary"][p]["within"] != counts[p] for p in phases):
            raise ValueError("Readback repetition count disagrees with its sample timings")
        runs.append({"process":expected, "path":run["path"], **counts})
        for row in data["operations"]:
            out = pool[row["id"]]
            out["repeated"].extend(t["ms"] for t in row["samples"] if t["phase"] == "warm")
            out["newValues"].extend(t["ms"] for t in row["distinctInputs"])
    if len(runs) < 2:
        raise ValueError("Separate processes are required for a repeatability report")
    for row in pool.values():
        for phase in phases:
            row[phase] = stats(row[phase])
    result = compare_readback(reference, pool, "LightFlow", "RAWMaster")
    for phase in phases:
        for key, observed in result[phase].items():
            if any(source["pooled"][phase][key][field] != observed[field] for field in
                   ("LightFlow","RAWMaster","medianLimit","p95Limit","within")):
                raise ValueError(f"Invalid pooled display timing for {key}/{phase}")
    return {"binarySHA256":source["RAWMasterBinarySHA256"], "evidence":name, "runs":runs, "pooled":result}


def panel_readback_rows(source, product):
    manifest = HERE.parents[2] / "scripts/performance/paired-panel-controls.json"
    digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
    inputs = json.loads(manifest.read_text())
    rows = {}
    if (source["protocol"] != "resident-srgb8-panels-v1" or source["parameterSHA256"] != digest
            or source["cachePolicy"] != "shipping defaults" or source["application"] != product
            or not re.fullmatch(r"[0-9a-f]{64}", source["sourceSHA256"]) or source["sourceSHA256"] != source["sourceSHA256After"]
            or source["pixels"] != [2400,1600] or source["samples"] != 20
            or {r["id"] for r in source["operations"]} != inputs.keys() or len(source["operations"]) != len(inputs)):
        raise ValueError(f"Different paired panel display workload for {product}")
    for row in source["operations"]:
        key, trials = row["id"], row["samples"]
        if (any(row[k] != inputs[key][k] for k in ("values","fixed")) or len(trials) != source["samples"]+2
                or any(t["state"] != i%2 or t["phase"] != ("first" if i<2 else "warm")
                    or not re.fullmatch(r"[0-9a-f]{64}",t["digest"]) for i,t in enumerate(trials))):
            raise ValueError(f"Unexpected panel trial sequence for {product}/{key}")
        states = [{t["digest"] for t in trials if t["state"] == n} for n in (0,1)]
        verified = all(len(s) == 1 for s in states) and states[0] != states[1]
        if row["status"] != ("measured" if verified else "inconclusive"):
            raise ValueError(f"Unverified state change for {product}/{key}")
        timing = stats([t["ms"] for t in trials[2:]])
        rows[key] = {**inputs[key], "timing":timing if verified else None}
    return rows


def compare_panel_readback(reference, current, reference_label, current_label):
    summary = {}
    for key, row in reference.items():
        before, after = row["timing"], current[key]["timing"]
        within = None if not (before and after) else (
            after["medianMs"] <= before["medianMs"]+max(1,.1*before["medianMs"]) and
            after["p95Ms"] <= before["p95Ms"]+max(2,.2*before["p95Ms"]))
        summary[key] = {"values":row["values"],"fixed":row["fixed"],
                        reference_label:before, current_label:after, "within":within}
    return summary


def panel_readback(sha):
    ref = panel_readback_rows(read_evidence("lightflow-panel-readback.json",sha,"LightFlow"),"LightFlow")
    cur = panel_readback_rows(read_evidence("rawmaster-panel-readback.json",sha,"RAWMaster"),"RAWMaster")
    return compare_panel_readback(ref,cur,"LightFlow","RAWMaster")


PANEL_SCHEDULE = {"LightFlow": "resident-srgb8-panels-stock-scheduler-v1",
                  "RAWMaster": "resident-srgb8-panels-interactive-settled-v1"}


def panel_schedule_rows(source, product):
    manifest = HERE.parents[2] / "scripts/performance/paired-panel-controls.json"
    specs = json.loads(manifest.read_text())
    if (source["application"] != product or source["protocol"] != PANEL_SCHEDULE[product]
            or source["parameterSHA256"] != hashlib.sha256(manifest.read_bytes()).hexdigest()
            or not re.fullmatch(r"[0-9a-f]{64}", source["sourceSHA256"])
            or source["sourceSHA256"] != source["sourceSHA256After"] or source["samples"] != 20
            or source["pixels"] != [2400,1600] or sorted(r["id"] for r in source["operations"]) != sorted(specs)):
        raise ValueError(f"Different panel schedule workload for {product}")
    phases = ("first", "firstExact", "final")
    result = {p:{} for p in phases}
    for row in source["operations"]:
        key, trials = row["id"], row["samples"]
        if (row["status"] != "measured" or len(trials) != 22
                or any(row[field] != specs[key][field] for field in ("values","fixed"))):
            raise ValueError(f"Unqualified schedule for {product}/{key}")
        states = [set(),set()]
        times = {p:[] for p in phases}
        first_matches = 0
        for i,t in enumerate(trials):
            if t["state"] != i%2 or t["phase"] != ("first" if i<2 else "warm"):
                raise ValueError(f"Unexpected trial order for {product}/{key}")
            if product == "LightFlow":
                frames = t["frames"]
                last = frames[-1]
                h, final = frames[0]["wholeRasterSHA256"], last["wholeRasterSHA256"]
                start = frames[0]["frameStartAfterDispatchMs"]
                exact = next(f for f in frames if f["wholeRasterSHA256"] == final)
                measured = [frames[0]["ms"],t["renderToFirstExactFinalMs"],t["renderToFinalMs"]]
                if (not last["fullRes"] or last["interactive"] or last["provisional"]
                        or t["schedulerTransitions"][-1]["bits"] != 0 or t["idleConfirmedMs"] < last["actionToPixelsMs"]
                        or abs(measured[2] - last["actionToPixelsMs"] + start) > .002
                        or abs(measured[1] - exact["actionToPixelsMs"] + start) > .002):
                    raise ValueError(f"Incomplete stock viewer cycle for {key}")
            else:
                h, final = t["firstSHA256"], t["digest"]
                measured = [t["firstMs"], t["firstExactFinalMs"], t["ms"]]
                if row["pixelWitness"] != "entire-opaque-sRGB-RGBA8" or measured[1] != (measured[0] if h == final else measured[2]):
                    raise ValueError(f"Invalid first exact native frame for {key}")
            if (not all(re.fullmatch(r"[0-9a-f]{64}",x) for x in (h, final))
                    or not all(math.isfinite(v) and v > 0 for v in measured)
                    or measured[0] > measured[1]+.002 or measured[1] > measured[2]+.002):
                raise ValueError(f"Invalid photo digest or schedule timing for {product}/{key}")
            states[i%2].add(final)
            if i >= 2 and h == final: first_matches += 1
            for phase,ms in zip(phases,measured): times[phase].append(ms)
        if any(len(d) != 1 for d in states) or states[0] == states[1]:
            raise ValueError(f"Full settled A/B rasters did not separate for {product}/{key}")
        for phase in phases:
            result[phase][key] = {**specs[key], "timing":stats(times[phase][2:]),
                                  "initial":times[phase][:2], "firstMatches":first_matches}
    return result


def panel_schedule(sha):
    names = {"LightFlow":"lightflow-panel-schedule.json","RAWMaster":"rawmaster-panel-schedule.json"}
    sources = {p:read_evidence(f,sha,p) for p,f in names.items()}
    lf, rm = sources["LightFlow"], sources["RAWMaster"]
    if lf["system"]["chip"] != rm["gpu"] or lf["adapterInfo"]["isFallbackAdapter"]:
        raise ValueError("Panel schedules require the same hardware")
    samples = {p:panel_schedule_rows(s,p) for p,s in sources.items()}
    return {"files":names, "nativeBuild":rm["binarySHA256"],
            "firstExactCount":{p:sum(x["firstMatches"] for x in r["first"].values()) for p,r in samples.items()},
            "phases":{phase:compare_panel_readback(samples["LightFlow"][phase],samples["RAWMaster"][phase],"LightFlow","RAWMaster")
                      for phase in samples["RAWMaster"]},
            "initial":{p:{phase:{k:v["initial"] for k,v in rows.items()} for phase,rows in s.items()} for p,s in samples.items()}}


def cell_text(cell):
    if cell["state"] != "measured":
        return f'<span class="muted" title="{html.escape(str(cell.get("reason", "")), quote=True)}">{LABELS[cell["state"]]}</span>'
    t = cell["timing"]
    p95 = f'{t["p95Ms"]:.2f}' if t["p95Ms"] is not None else '—'
    extra = (" · " + html.escape(cell["displayBoundary"])) if "displayBoundary" in cell else ""
    return f'<b>{t["medianMs"]:.2f}</b> / {p95}<small style="display:block">n = {t["n"]}{extra}</small>'


def render_controls(data):
    ledger = data["controlMatrix"]
    panels = {p["id"]: p["title"] for p in json.loads((HERE / "feature-matrix.json").read_text())["panels"]}
    summary = "，".join(f'{p} {ledger["coverage"][p].get("measured", 0)} 项' for p in PRODUCTS)
    hashes = {"LightFlow": "WebGPU 驻留源图，逐次更改参数，自动调整测到数值返回", "RAWMaster": "驻留源图，每项交替两个配方。分析、读数和示波器在对应行标出计时终点",
              "Camera Raw": "重新打开 9504 × 6336 RAW 至 8 位 sRGB 文档，汇总编辑态三次暖打开"}
    parts = []
    if "panelSchedule" in data and "pairedPhotoOperators" in data:
        panel = data["panelSchedule"]["phases"]
        ops = [r for r in data["pairedPhotoOperators"]["operations"].values() if r["qualified"]]
        phases = [(k,sum(r["within"] for r in panel[k].values())+sum(r["phases"][k]["within"] for r in ops)) for k in ("first","final")]
        counts = dict(phases)
        amount = len(panel["first"])+len(data["pairedPhotoOperators"]["operations"])
        initial = {p:statistics.median(ms for r in ops for ms in r[p]["initial"]["final"]) for p in ("LightFlow","RAWMaster")}
        parts.append(f'<section><h2>热编辑与首次定稿</h2><p>两款引擎在 {amount} 项面板和照片操作上读回相同尺寸。往返使用已校准的两个档位时，RAWMaster 首帧有 <strong>{counts["first"]}/{amount}</strong> 项达到 LightFlow 区间，最终画面有 <strong>{counts["final"]}/{amount}</strong> 项达到。对第二组的 {len(ops)*2} 次首次档位，完成最终画面的中位数为 LightFlow <strong>{initial["LightFlow"]:.2f} ms</strong>、RAWMaster <strong>{initial["RAWMaster"]:.2f} ms</strong>。</p><nav aria-label="跳至测量"><a href="#controls">三方逐控件数据</a> · <a href="#screen-response">输入到画布</a> · <a href="#photo-edits">首次和往返耗时</a> · <a href="#release-regression">后台发版回归</a></nav></section>')
    parts.append(f'<section id="controls"><h2>同一张 RAW 的逐控件实测</h2><p>{len(ledger["controls"])} 个清单项中，{summary}取得独立实测。三方均有引擎或文档打开记录的有 <strong>{ledger["allThreeMeasured"]} 项</strong>。'
                 '表中数值为暖路径中位数 / p95（毫秒），p95 取最近秩。Adobe 每项三次暖样本的 p95 即三次中的最大值。计时边界及像素尺寸见各列。首次调用、原始样本和逐项设置保存在数据文件中。</p>')
    adobe = ledger["sessions"]["Camera Raw"]
    if adobe["runState"] != "complete":
        parts.append(f'<p class="notice">Adobe 后台测试已保存 {adobe["attempted"]}/{adobe["planned"]} 项；此表显示当前已完成的记录。</p>')
    parts.append('<ul>' + ''.join(f'<li><b>{p}</b> · {hashes[p]}。<a href="evidence/{INPUTS[p]}">原始记录</a></li>' for p in PRODUCTS) + '</ul>')
    parts.append('<p>设备为 Apple M4 Max。LightFlow 发布构建与着色器调用顺序见 <a href="evidence/lightflow-engine.md">LightFlow 源码核对</a>及<a href="evidence/lightflow-availability.json">缺少同义操作的逐项依据</a>。FlashRaw 解码策略、发版测试命令与基准复现步骤见 <a href="README.md#真实-raw-性能与发版回归">维护说明</a>。</p>')
    if (HERE/"evidence/camera-raw-lens-blur-native.json").is_file():
        parts.append('<p>Camera Raw 镜头模糊开关另用 8 次 60 MP 文档打开复测。首次 A/B 逐像素遍历 256 个网格，未找到相差至少两个 RGB8 码值的位置。该操作继续列为未验证，文档打开时间保存在原始记录。蒙版色轮通过 Adobe 写回的字段及独立像素变化验证。<a href="evidence/camera-raw-lens-blur-native.json">镜头模糊的全图对照</a> · <a href="evidence/camera-raw-grading-mask.json">蒙版色轮逐次结果</a></p>')
    if (HERE / "evidence/lightflow-lut.json").is_file():
        parts.append('<p>LightFlow 的 LUT 调色图还有独立的一批采样。<a href="evidence/lightflow-lut.json">LUT 逐次记录</a></p>')
    if (HERE / "evidence/lightflow-supplement.json").is_file():
        parts.append('<p>另在原版着色器上复测黑白模式、白平衡预设、恢复拍摄白平衡和暗角样式。<a href="evidence/lightflow-supplement.json">参数与像素证据</a></p>')
    if (HERE / "evidence/lightflow-analysis.json").is_file():
        parts.append('<p>LightFlow 的自动色调与白平衡使用原版工作线程在 384 × 256 分析图上计算。先列示首次准备分析图的时间，再对两个起始配方逐次验证返回字段。<a href="evidence/lightflow-analysis.json">分析样本与实际返回值</a></p>')
    if (HERE / "evidence/lightflow-panel-tools.json").is_file():
        parts.append('<p>LightFlow 的剪切指示、临时剪切、锐化蒙版与锐化半径测到完整显示图读回；HSL 分组、八色选择及 CUBE 导入测到原版界面返回结果。其中 CUBE 导入另核对了应用后照片。<a href="evidence/lightflow-viewer-tools.json">照片与蒙版像素</a> · <a href="evidence/lightflow-panel-tools.json">控件、文件与照片回执</a></p>')
    if (HERE / "evidence/rawmaster-inspection.json").is_file():
        parts.append('<p>RAWMaster 的自动调整与吸管测到分析结果可用，读数测到已显示图像的数值更新，示波器测到离屏界面完成栅格化。<a href="evidence/rawmaster-inspection.json">逐项计时终点与返回数值</a> · <a href="evidence/rawmaster-inspection.md">复用分析工作图前后的同机耗时</a> · <a href="evidence/rawmaster-control-verification.json">独立配方的双态像素验证</a></p>')
    if (HERE / "evidence/rawmaster-inspection-focus.json").is_file():
        parts.append('<p>焦点操作和 LUT 导入计时到新画布可读，浮动示波器计时到原生面板完成离屏绘制。这张日落原片没有可分割的前景实例，主体对焦使用同一照片的注意力显著图选取焦点，并与两个手动起点的画面分别核对。<a href="evidence/rawmaster-inspection-focus.json">五项交互的返回值与像素</a> · <a href="evidence/history/rawmaster-inspection-focus-before.json">仅使用前景实例时的结果</a></p>')
    if (HERE / "evidence/camera-raw-points.json").is_file():
        parts.append('<p>Camera Raw 的点颜色另有一组全尺寸打开记录。<a href="evidence/camera-raw-points.json">补充实测</a></p>')
    if (HERE / "evidence/camera-raw-profile-match.json").is_file():
        parts.append('<p>在 Adobe 的 EXIF 镜头匹配测试中，四次自动识别均选中 Sony 14 mm。完整 RGB8 输出与手选 14 mm 的两次参照逐字节一致，与错选 20 mm 的结果有 56,027,352 个像素不同。表中汇总三次暖文档打开。<a href="evidence/camera-raw-profile-match.json">镜头识别、照片差异与时间</a> · <a href="evidence/camera-raw-profile-match-xmp.zip">原始输入和 Adobe 写回的 XMP</a> · <a href="evidence/camera-raw-background-controls.md">其余控件的计时边界与逐项缺口</a></p>')
    if (HERE / "evidence/camera-raw-spatial.json").is_file():
        parts.append('<p>针对未能通过直方图区分的镜头调整，另从已经打开的完整文档读取 1024 像素 sRGB 位图作为空间像素证据。此项检验在计时后进行。<a href="evidence/camera-raw-spatial.json">镜头调整复核</a></p>')
    if (HERE / "evidence/camera-raw-native-pixels.json").is_file():
        parts.append('<p>移除横向色差在缩小后的画面上难以分辨。在 60 MP 原尺寸图上，用首组 A/B 在 16 × 16 个分区各选一个差异达到两个码值的像素，再由其余三组完全独立的打开逐个核对位置、通道、变化方向和幅度。<a href="evidence/camera-raw-native-pixels.json">原尺寸坐标与八次 RGB8 读数</a> · <a href="evidence/camera-raw-native-ca.json">整图哈希的复测记录</a></p>')
    if (HERE / "evidence/camera-raw-supplement.json").is_file():
        parts.append('<p>依据 Adobe 随附预设与镜头配置文件，另测自动色调、恢复拍摄白平衡、局部曲线和手动选择镜头型号。<a href="evidence/camera-raw-supplement.json">四项完整文档打开及像素记录</a></p>')
    parts.append('''<div class="filters"><label>查找控件 <input type="search" id="find-control" placeholder="控件名或 ID"></label>
        <label>显示 <select id="coverage-filter"><option value="">全部控件</option><option value="all">三方均有实测</option>
        <option value="gap">至少一方未测定</option><option value="inconclusive">有未验证的像素响应</option></select></label>
        <output id="filter-count" aria-live="polite"></output></div>''')
    for panel, title in panels.items():
        rows = [r for r in ledger["controls"] if r["panel"] == panel]
        parts.append(f'<details open class="control-panel"><summary>{html.escape(title)} · {len(rows)} 项</summary><div class="scroll"><table><thead><tr><th>控件</th><th>LightFlow · GPU 完成或分析结果</th><th>RAWMaster · 交互帧或标注终点</th><th>Camera Raw · 整幅打开</th></tr></thead><tbody>')
        for r in rows:
            states = {r["products"][p]["state"] for p in PRODUCTS}
            filters = "all" if states == {"measured"} else "gap"
            if "inconclusive" in states: filters += " inconclusive"
            parts.append(f'<tr id="perf-{r["id"]}" data-coverage="{filters}"><th>{html.escape(r["name"])}<br><small>{r["id"]}</small></th>' +
                         ''.join('<td>' + cell_text(r["products"][p]) + '</td>' for p in PRODUCTS) + '</tr>')
        parts.append('</tbody></table></div></details>')
    parts.append('''<script>
    (() => {
      const search = document.getElementById('find-control'), select = document.getElementById('coverage-filter');
      const apply = () => {
        let count = 0;
        for (const panel of document.querySelectorAll('.control-panel')) {
          let matching = 0;
          for (const row of panel.querySelectorAll('tbody tr')) {
            const match = row.querySelector('th').textContent.toLocaleLowerCase().includes(search.value.trim().toLocaleLowerCase())
              && (!select.value || row.dataset.coverage.split(' ').includes(select.value));
            row.hidden = !match;
            if (match) matching++;
          }
          panel.hidden = !matching;
          if (matching && (select.value || search.value)) panel.open = true;
          count += matching;
        }
        document.getElementById('filter-count').textContent = count + ' 项';
      };
      search.addEventListener('input', apply);
      select.addEventListener('change', apply);
      apply();
    })();
    </script>''')
    parts.append('</section><section id="screen-response"><h2>输入到可见画布</h2><p>只采样照片区域。报告按目标画面差异的 20% 定义首个可见变化，逐次核对起始画面、最终画面及输入值。每款应用的输入入口、照片尺寸和视区见采集记录。</p>')
    visible = [r for r in ledger["controls"] if r["canvas"]]
    if visible:
        compositor_rows = data.get("lightflowCompositor",{}).get("rows",{})
        parts.append('<p>LightFlow 的浏览器合成器记录另列一栏。其时间截止于 Chromium 交换画面，屏幕栏则截止于 macOS 窗口服务器采到照片变化。数值为中位数 / p95（毫秒）。</p><div class="scroll"><table><thead><tr><th>控件</th><th>LightFlow 浏览器合成器</th>' + ''.join(f'<th>{p} 屏幕</th>' for p in PRODUCTS) + '</tr></thead><tbody>')
        for r in visible:
            observed = compositor_rows.get(r["id"],{}).get("cell",{"state":"unmeasured"})
            parts.append(f'<tr><th>{html.escape(r["name"])}</th><td>{cell_text(observed)}</td>' + ''.join('<td>' + cell_text(r["canvas"].get(p, {"state": "unmeasured"})) + '</td>' for p in PRODUCTS) + '</tr>')
        parts.append('</tbody></table></div>')
    parts.append('<p>' + ' · '.join(f'{p} 已验证 {ledger["canvasMeasured"][p]} 项' for p in PRODUCTS) + '。</p>')
    for p in PRODUCTS:
        if "canvas" in ledger["sessions"][p]:
            parts.append(f'<p>{p} · {html.escape(ledger["sessions"][p]["canvas"]["driver"])}。<a href="evidence/{CANVAS[p]}">画布证据</a></p>')
    lf_screen = ledger["sessions"]["LightFlow"].get("canvas", {})
    if lf_screen.get("sessions"):
        archives = " · ".join(f'<a href="evidence/history/{html.escape(s["archive"])}">第 {i} 轮原始帧和输入</a>'
                              for i, s in enumerate(lf_screen["sessions"], 1))
        parts.append(f'<p>LightFlow 原版编辑器 {html.escape(lf_screen["build"])} 在 Electron 内的 {html.escape(lf_screen["browser"])} 运行。后台窗口与另外两端均显示 2368 × 1579 像素的照片。LightFlow 从已填数值的回车提交计时，RAWMaster 从编辑控制器提交计时，Adobe 从物理键入数值计时。三方均在照片中央 60% 区域采样。{archives} · <a href="../../../scripts/performance/replay-lightflow-screen.py">离线像素复核</a> · <a href="../../../scripts/performance/lightflow-window/README.md">复现后台窗口</a></p>')
    if (HERE / "evidence/history/camera-raw-screen-typing.zip").is_file():
        parts.append('<p>Camera Raw 使用物理数值输入和 Tab 提交。部分数值框会延后显示完整数字，逐次测量时用下一次输入前的字段值复核，并独立核对照片响应。第二轮在纹理测试时遇到屏幕采集连接中断。已完成的操作逐组复核，每项保留同一轮内连续十次的结果。<a href="evidence/history/camera-raw-screen-typing.zip">首轮照片帧和输入</a> · <a href="evidence/history/camera-raw-screen-typing-repeat.zip">第二轮照片帧和输入</a> · <a href="../../../scripts/performance/replay-acr-screen.py">离线复核程序</a></p>')
    parts.append('<p>Camera Raw 的三项历史单次屏幕观测保存在下方历史基线。</p></section>')
    if "readbackRepeatability" in data:
        repeat = data["readbackRepeatability"]
        results = repeat["pooled"]
        names = {r["id"]:r["name"] for r in ledger["controls"]}
        counts = {p:sum(r["within"] for r in result.values()) for p,result in results.items()}
        parts.append(f'<section><h2>八个基础控件的跨进程读回复测</h2><p>RAWMaster 构建 <code>{html.escape(repeat["binarySHA256"][:8])}</code> 启动 {len(repeat["runs"])} 个独立进程，每个进程、每个控件先交替输入两态 20 次，再输入 20 个不同的新值。LightFlow 的同尺寸原版查看器每组 20 次。合并所有进程后，两态往返有 <strong>{counts["repeated"]}/8</strong> 项同时达到中位数与 p95 目标，连续新值有 <strong>{counts["newValues"]}/8</strong> 项。目标按 LightFlow 中位数加 10% 或 1 ms、p95 加 20% 或 2 ms，分别取较大容差。<a href="evidence/{html.escape(repeat["evidence"])}">当前三次进程与全体样本</a> · <a href="evidence/interactive-light-guide.json">高光与阴影的分阶段耗时和像素对照</a> · <a href="evidence/interactive-readback-repeatability.json">前一构建三轮原始记录</a></p>')
        parts.append('<table><thead><tr><th>正式进程</th><th>两态往返达标</th><th>连续新值达标</th></tr></thead><tbody>')
        for run in repeat["runs"]:
            parts.append(f'<tr><th><a href="evidence/{html.escape(run["path"])}">第 {run["process"]} 次</a></th><td>{run["repeated"]} / 8</td><td>{run["newValues"]} / 8</td></tr>')
        parts.append('</tbody></table><div class="scroll"><table><thead><tr><th>控件</th><th>输入</th><th>LightFlow 中位数 / p95（ms）</th><th>RAWMaster 中位数 / p95（ms）</th><th>落在区间内</th></tr></thead><tbody>')
        for phase,label in (("repeated","两态"),("newValues","连续新值")):
            for key,row in results[phase].items():
                times = ''.join(f'<td>{row[p]["medianMs"]:.2f} / {row[p]["p95Ms"]:.2f} · n={row[p]["n"]}</td>' for p in ("LightFlow","RAWMaster"))
                parts.append(f'<tr><th>{html.escape(names[key])}</th><td>{label}</td>{times}<td>{"是" if row["within"] else "超出"}</td></tr>')
        parts.append('</tbody></table></div></section>')
    if "matchedReadback" in data:
        pairs = data["matchedReadback"]["repeated"]
        sweep = data["matchedReadback"]["newValues"]
        names = {r["id"]:r["name"] for r in ledger["controls"]}
        parts.append(f'<section><h2>同一输出边界下的双引擎对照</h2><p>驻留同一张 RAW，逐次提交相同的界面值，计时到完整的 2400 × 1600、sRGB RGBA8 显示缓冲区可被 CPU 读取。每项两次校准后再交替 20 次，每次在计时外校验照片像素。两款产品保留各自的颜色和色调算法。表内 {sum(r["within"] for r in pairs.values())}/{len(pairs)} 项进入采用项目发版容差的 LightFlow 区间。中位数容差为 10% 或 1 ms 中较大者，p95 为 20% 或 2 ms 中较大者。<a href="evidence/lightflow-display-readback.json">LightFlow 查看器原始记录</a> · <a href="evidence/rawmaster-display-readback.json">RAWMaster 显示图原始记录</a></p><div class="scroll"><table><thead><tr><th>控件</th><th>两态</th><th>LightFlow 中位数 / p95（ms）</th><th>RAWMaster 中位数 / p95（ms）</th><th>落在区间内</th></tr></thead><tbody>')
        for key,r in pairs.items():
            a,b=r["LightFlow"],r["RAWMaster"]
            parts.append(f'<tr><th>{html.escape(names[key])}</th><td>{r["values"][0]:g} ↔ {r["values"][1]:g}</td><td>{a["medianMs"]:.2f} / {a["p95Ms"]:.2f}</td><td>{b["medianMs"]:.2f} / {b["p95Ms"]:.2f}</td><td>{"是" if r["within"] else "超出"}</td></tr>')
        parts.append('</tbody></table></div>')
        if sweep:
            parts.append(f'<h3>连续送入 20 个新值</h3><p>同一个控件逐次输入不同数值，每个值都产生独立的像素摘要。两端均使用正式缓存策略。{sum(r["within"] for r in sweep.values())}/{len(sweep)} 项的中位数和 p95 同时落在上述区间。</p><div class="scroll"><table><thead><tr><th>控件</th><th>LightFlow 中位数 / p95（ms）</th><th>RAWMaster 中位数 / p95（ms）</th><th>落在区间内</th></tr></thead><tbody>')
            for key,r in sweep.items():
                a,b=r["LightFlow"],r["RAWMaster"]
                parts.append(f'<tr><th>{html.escape(names[key])}</th><td>{a["medianMs"]:.2f} / {a["p95Ms"]:.2f}</td><td>{b["medianMs"]:.2f} / {b["p95Ms"]:.2f}</td><td>{"是" if r["within"] else "超出"}</td></tr>')
            parts.append('</tbody></table></div>')
        parts.append('<p>基准使用 LightFlow 的 EV 与 −100…100 输入。RAWMaster 将 EV 除以 2 写入曝光配方，将黑色输入除以 −100 写入黑点，其余六项除以 100。两端分别核对编辑后像素确有变化。<a href="../../../Tests/RAWMasterImagingTests/IndividualControlPerformanceTests.swift">输入映射与计时程序</a></p>')
        parts.append('</section>')
    if (HERE/"evidence/parametric-curve-index.json").is_file():
        v = read_evidence("parametric-curve-index.json",data["source"]["sha256"],"RAWMaster")
        pairs = v["pixelPairs"]
        labels = {r["id"]:r["name"] for r in ledger["controls"]}
        parts.append(f'<section><h2>参数曲线的 GPU 分段查找</h2><p>在同一构建内依次用原实现、新实现、新实现、原实现运行四个独立进程。每种实现每控件合并 40 次热编辑，逐项列出中位数和 p95。十组完整画面共比对 {sum(r["bytes"] for r in pairs):,} 字节，{sum(r["changedRGBChannels"] for r in pairs)} 个颜色通道相差一个 8 位码值，透明度均相同。<a href="evidence/parametric-curve-index.json">四轮逐帧耗时和全画面摘要</a></p><table><thead><tr><th>控件</th><th>逐段扫描（ms）</th><th>直接定位（ms）</th></tr></thead><tbody>')
        for key,r in v["pooled"].items():
            cells = ''.join(f'<td>{r[m]["medianMs"]:.2f} / {r[m]["p95Ms"]:.2f}</td>' for m in ("scan","indexed"))
            parts.append(f'<tr><th>{html.escape(labels[key])}</th>{cells}</tr>')
        parts.append('</tbody></table></section>')
    if "panelSchedule" in data:
        measured = data["panelSchedule"]
        stages = measured["phases"]
        labels = {r["id"]:r["name"] for r in ledger["controls"]}
        parts.append('<section><h2>同一项编辑的首帧与最终画面</h2><p>同一张 60 MP RAW，同一档位，输出均为 2400 × 1600 的完整、不透明 sRGB8 照片。每项先测两个初始状态，再往返编辑 20 次。LightFlow 从原版查看器开始处理输入计时，保留其逐帧调度。RAWMaster 从引擎收到交互请求计时，首帧读回后立即请求精确画面。两侧均在计时后核对整帧像素。此表不含物理屏幕呈现和 RAWMaster 界面松手延迟。</p>')
        names = {"first":"首个完整缓冲区","firstExact":"首次与最终画面逐字节一致","final":"完成最终帧读回"}
        counts = '，'.join(f'{label} {sum(x["within"] for x in stages[phase].values())}/31 项达标' for phase,label in names.items())
        exact = measured["firstExactCount"]
        parts.append(f'<p><strong>{counts}。</strong>620 次热编辑中，LightFlow 有 {exact["LightFlow"]} 次首帧已等于最终画面，RAWMaster 为 {exact["RAWMaster"]} 次。已定稿画面按完整配方复用。优化前后独立核对的 62 个最终状态逐字节一致。各控件首次进入的耗时见原始记录。<a href="evidence/lightflow-panel-schedule.json">LightFlow 逐帧记录</a> · <a href="evidence/rawmaster-panel-schedule.json">RAWMaster 双阶段记录</a> · <a href="evidence/interactive-canonical-replay.json">62 个状态的前后对照</a> · <a href="evidence/lightflow-panel-schedule.md">调度与参数说明</a></p>')
        for phase,label in names.items():
            parts.append(f'<details {"open" if phase=="first" else ""}><summary>{label}（31 项）</summary><div class="scroll"><table><thead><tr><th>控件</th><th>LightFlow 中位数 / p95（ms）</th><th>RAWMaster 中位数 / p95（ms）</th><th>同水位</th></tr></thead><tbody>')
            for key,row in stages[phase].items():
                cells = ''.join(f'<td>{row[p]["medianMs"]:.2f} / {row[p]["p95Ms"]:.2f}</td>' for p in ("LightFlow","RAWMaster"))
                parts.append(f'<tr><th>{html.escape(labels[key])}</th>{cells}<td>{"是" if row["within"] else "超出"}</td></tr>')
            parts.append('</tbody></table></div></details>')
        parts.append('</section>')
    if "pairedPhotoOperators" in data:
        ops = data["pairedPhotoOperators"]["operations"]
        names = {r["id"]:r["name"] for r in ledger["controls"]}
        phases = {"first":"首个完整画面", "firstExact":"首次与最终画面逐字节一致", "final":"完成最终画面读回"}
        qualified = [r for r in ops.values() if r["qualified"]]
        tally = "，".join(f'{title} {sum(r["phases"][key]["within"] for r in qualified)}/{len(ops)} 项达标' for key,title in phases.items())
        parts.append(f'<section id="photo-edits"><h2>白平衡、LUT、覆层和局部蒙版的 {len(ops)} 项对照</h2><p>两款引擎使用相同的输入档位和 2400 × 1600 sRGB8 完整照片。每项先测两个初始画面，再往返编辑 20 次。其中 {sum(r["region"]=="radial" for r in qualified)} 项局部编辑同时验证了蒙版内颜色变化和蒙版外颜色稳定。<strong>{tally}。</strong>两个首次状态另存于报告，往返编辑包含产品正常使用的缓存。</p>')
        parts.append('<h3>首次使用每个档位</h3><p>每个控件的 A、B 两档各取一次，原片已驻留。下表的中位数和 p95 描述相同的整组首次操作，每个档位只有一个首次样本。发布检查单独比较这组操作，缓存命中的时延另列于下方。</p><table><thead><tr><th>终点</th><th>LightFlow 中位数 / p95（ms）</th><th>RAWMaster 中位数 / p95（ms）</th><th>每端次数</th><th>达到区间</th></tr></thead><tbody>')
        for phase,title in phases.items():
            samples = {p:stats([v for r in qualified for v in r[p]["initial"][phase]]) for p in ("LightFlow","RAWMaster")}
            a,b=samples["LightFlow"],samples["RAWMaster"]
            within = b["medianMs"] <= a["medianMs"]+max(1,a["medianMs"]*.1) and b["p95Ms"] <= a["p95Ms"]+max(2,a["p95Ms"]*.2)
            parts.append(f'<tr><th>{title}</th><td>{a["medianMs"]:.2f} / {a["p95Ms"]:.2f}</td><td>{b["medianMs"]:.2f} / {b["p95Ms"]:.2f}</td><td>{b["n"]}</td><td>{"是" if within else "超出"}</td></tr>')
        parts.append('</tbody></table>')
        if "photoBuildHistory" in data:
            parts.append('<details><summary>历次 RAWMaster 构建的首次输入</summary><p>每次均用同一份 74 个新状态的清单、相同的 60 MP 原片和显示尺寸。各格为中位数 / p95，单位为毫秒。</p><div class="scroll"><table><thead><tr><th>构建与证据</th><th>首次读回完整画面</th><th>首次完成定稿</th></tr></thead><tbody>')
            for run in data["photoBuildHistory"]:
                cells = ''.join(f'<td>{run[p]["medianMs"]:.2f} / {run[p]["p95Ms"]:.2f}</td>' for p in ("first","final"))
                parts.append(f'<tr><th><a href="evidence/{html.escape(run["evidence"])}">{html.escape(run["binarySHA256"][:8])}</a></th>{cells}</tr>')
            parts.append('</tbody></table></div></details>')
        for phase,title in phases.items():
            parts.append(f'<details><summary>{title}（{len(ops)} 项）</summary><div class="scroll"><table><thead><tr><th>控件</th><th>LightFlow 中位数 / p95（ms）</th><th>RAWMaster 中位数 / p95（ms）</th><th>达到区间</th></tr></thead><tbody>')
            for key,row in ops.items():
                if not row["qualified"]:
                    parts.append(f'<tr><th>{html.escape(names[key])}</th><td colspan="3">两端像素尚未通过校验</td></tr>')
                    continue
                pair = row["phases"][phase]
                cells = "".join(f'<td>{pair[p]["medianMs"]:.2f} / {pair[p]["p95Ms"]:.2f}</td>' for p in ("LightFlow","RAWMaster"))
                parts.append(f'<tr><th>{html.escape(names[key])}</th>{cells}<td>{"是" if pair["within"] else "超出"}</td></tr>')
            parts.append('</tbody></table></div></details>')
        parts.append('<p><a href="evidence/paired-photo-operators-v2.md">逐控件档位、测量边界和适用范围</a> · <a href="evidence/lightflow-photo-operators-v2.json">LightFlow 原始帧</a> · <a href="evidence/rawmaster-photo-operators-v2.json">RAWMaster 原始帧</a> · <a href="../../../scripts/performance/paired-photo-operators-v2.json">共享配方</a></p></section>')
    if "panelReadback" in data:
        panel = data["panelReadback"]
        labels = {r["id"]:r["name"] for r in ledger["controls"]}
        qualified = [r for r in panel.values() if r["within"] is not None]
        parts.append(f'<section><h2>面板控件的同尺寸显示输出</h2><p>白平衡、效果、曲线、HSL、分级和细节的 {len(panel)} 项使用同一份两态参数清单。每项先校准两帧，再按 A/B 交替采集 20 帧。两端都由完整 2400 × 1600 sRGB RGBA8 缓冲区读回照片像素。{len(qualified)} 项在两端验证出稳定差异，其中 {sum(r["within"] for r in qualified)} 项的中位数和 p95 同时达到 LightFlow 区间。<a href="../../../scripts/performance/paired-panel-controls.json">档位和固定前提</a> · <a href="evidence/lightflow-panel-readback.json">LightFlow 样本</a> · <a href="evidence/rawmaster-panel-readback.json">RAWMaster 样本</a></p><div class="scroll"><table><thead><tr><th>控件</th><th>两态</th><th>LightFlow 中位数 / p95（ms）</th><th>RAWMaster 中位数 / p95（ms）</th><th>落在区间内</th></tr></thead><tbody>')
        for key,r in panel.items():
            timings = ''.join('<td>'+(f'{r[p]["medianMs"]:.2f} / {r[p]["p95Ms"]:.2f}' if r[p] else '未验证出像素响应')+'</td>' for p in ("LightFlow","RAWMaster"))
            state = "未定" if r["within"] is None else "是" if r["within"] else "超出"
            parts.append(f'<tr><th>{html.escape(labels[key])}</th><td>{r["values"][0]:g} ↔ {r["values"][1]:g}</td>{timings}<td>{state}</td></tr>')
        parts.append('</tbody></table></div></section>')
    if (HERE/"evidence/interactive-direct-effects-noise.json").is_file():
        witness = read_evidence("interactive-direct-effects-noise.json",data["source"]["sha256"],"RAWMaster")
        comparison = witness["fullPhotoComparison"]
        frames = comparison["frames"]
        if (len(frames)!=120 or any(r["RGBABytes"] != 2400*1600*4 for r in frames)
                or comparison["worstRGBp99"] != max(r["p99RGB"] for r in frames)
                or comparison["worstRGBMax"] != max(r["maximumRGB"] for r in frames)):
            raise ValueError("Incomplete full-raster comparison for the direct vignette and denoise edits")
        changed = sum(r["changedRGBChannels"] for r in frames)
        parts.append(f'<section><h2>暗角和亮度降噪的连续新值</h2><p>在正常交互路径中，Metal 将暗角与画面校验及 sRGB 转换合为一遍，亮度降噪复用同一输入已经算出的邻域响应。六个控件分别输入 20 个未出现过的值。对新旧路径逐字节核对 {comparison["totalBytesCompared"]:,} 字节，{changed} 个 RGB 通道有差异，单通道最大 {comparison["worstRGBMax"]}/255，每张图误差 p99 均为 {comparison["worstRGBp99"]}，透明度最大差异为 {comparison["worstAlphaMax"]}。<a href="evidence/interactive-direct-effects-noise.json">原始毫秒值、各像素证据和开关</a></p></section>')
    if "lightflowCompositor" in data:
        compositor = data["lightflowCompositor"]
        parts.append('<section><h2>LightFlow 原版编辑器的合成器响应</h2><p>同一张照片以 2368 × 1579 像素显示，发布版编辑器接收两组交替的按键输入。Chromium 每次交换画面后传回 960 × 600 的见证帧，在照片中央 60% 区域核对像素。计时终点为浏览器合成器交换，RAWMaster 上表的终点为 macOS 窗口服务器的屏幕采样。Bloom 对应此版 LightFlow 提供的单一发光强度。<a href="evidence/lightflow-compositor.json">输入值、时钟校准、区域和逐帧记录</a></p><table><thead><tr><th>原版控件</th><th>中位数 / p95（毫秒）</th></tr></thead><tbody>')
        for row in compositor["rows"].values():
            parts.append(f'<tr><th>{html.escape(row["label"])}</th><td>{cell_text(row["cell"])}</td></tr>')
        parts.append('</tbody></table></section>')
    if "engineOptimization" in data:
        o = data["engineOptimization"]
        parts.append('<section><h2>FlashRaw 引擎优化前后</h2><p>同机交错运行旧、新 Release 二进制，每个版本三个独立进程。输出尺寸均为 2400 × 1600。<a href="evidence/engine-optimization.json">全部运行、纹理内存及像素差分</a></p>')
        parts.append('<div class="scroll"><table><thead><tr><th>配方</th><th>旧版本 settled 中位数</th><th>新版本 settled 中位数</th></tr></thead><tbody>')
        for name, values in o.items():
            parts.append(f'<tr><th>{html.escape(name)}</th><td>{values[0]:.2f} ms</td><td>{values[1]:.2f} ms</td></tr>')
        parts.append('</tbody></table></div></section>')
    if "interactiveValidation" in data:
        parts.append('<section><h2>交互渲染与像素校验</h2><p>在 GPU 上并行检查浮点纹理后，同一份发布版交错切换旧、新校验路径。每项每种路径取 40 个热样本。完整像素对照覆盖中性和曝光加颜色两组配方的交互及高质量图像。<a href="evidence/interactive-validation.json">逐次耗时与四张 RGBA 像素对照</a></p><table><thead><tr><th>操作</th><th>原中位数</th><th>现中位数</th></tr></thead><tbody>')
        for name, row in data["interactiveValidation"].items():
            parts.append(f'<tr><th>{html.escape(name)}</th><td>{row[0]:.2f} ms</td><td>{row[1]:.2f} ms</td></tr>')
        parts.append('</tbody></table><p><a href="evidence/engine-control-fixes.json">颗粒、局部点颜色、降噪的修复验证</a> · <a href="evidence/interactive-display-fusion.json">Metal 显示转换的逐像素对照</a> · <a href="evidence/flashraw-camera-matrix.json">不同机型、原生方向与实际 CPU/GPU 后端</a> · <a href="evidence/flashraw-engine.md">FlashRaw 架构与队列</a></p></section>')
    if "rawDetails" in data:
        parts.append('<section><h2>RAW 细节增强</h2><p>在全尺寸 Bayer 和 X-Trans 感光数据上分别选择 FlashRaw 的 AHD 或边缘感知去马赛克。每张照片检验中性与增强结果的像素差异、配方恢复和 16 位 TIFF 导出。导出每张只有一个样本。<a href="evidence/raw-details.json">两张 RAW 的记录</a></p><table><thead><tr><th>算法</th><th>原尺寸导出耗时</th></tr></thead><tbody>')
        for r in data["rawDetails"]:
            parts.append(f'<tr><th>{html.escape(r["mode"])}</th><td>{r["exportMs"]:.2f} ms</td></tr>')
        parts.append('</tbody></table></section>')
    if "sceneDepth" in data:
        v=data["sceneDepth"]
        parts.append(f'<section><h2>单张 RAW 的场景深度估算</h2><p>Depth Anything V2 Small FP16 生成的相对深度图保存在配方中。首次 {v["coldMs"]:.2f} ms，暖路径中位数 {v["warm"]["medianMs"]:.2f} ms（n={v["warm"]["n"]}），包括源文件校验和模型输入转换。<a href="evidence/scene-depth.json">源图、深度图与重开导出</a> · <a href="https://huggingface.co/apple/coreml-depth-anything-v2-small">Apple 发布的模型</a></p></section>')
    if "neuralDenoise" in data:
        neural = data["neuralDenoise"]
        parts.append(f'<section><h2>RAW 9 神经降噪</h2><p>这张 Sony 原片支持 macOS 的学习型去马赛克和降噪。下表保留同一会话的调用顺序，每行一次。首次计算新强度与重用已缓存强度分别计时。优化前回到强度 0 用时 {neural["priorRepeatedMs"]:.2f} ms。当前进程峰值 {neural["peakRSS"]/1024**3:.2f} GiB，模型准备 {neural["prepareMs"]:.2f} ms，9504 × 6336 的 16 位 TIFF 导出 {neural["exportMs"]:.2f} ms；输出与旧版逐字节相同。<a href="evidence/raw9-denoise.json">逐次采样、内存与导出</a> · <a href="evidence/history/raw9-denoise-before-cache.json">优化前的同机结果</a> · <a href="evidence/enhance-capabilities.md">系统和源格式范围</a></p><table><thead><tr><th>预览请求</th><th>耗时（毫秒）</th></tr></thead><tbody>')
        labels = {"original":"首次原图", "amount0":"首次强度 0", "amount100":"首次强度 100", "amount0-replay":"强度回到 0",
            "amount50-first":"首次强度 50","amount0-secondReplay":"再次回到 0","amount50-replay":"回到强度 50",
            "disabled":"关闭并恢复原图", "amount100-settled":"强度 100 高质量预览"}
        for key, ms in neural["requests"].items():
            parts.append(f'<tr><th>{html.escape(labels.get(key,key))}</th><td>{ms:.2f}</td></tr>')
        parts.append('</tbody></table></section>')
    if "lutImport" in data:
        parts.append('<section><h2>LUT 导入速度</h2><p>从本机读取 CUBE 或 ZIP，解析并写入新的调色库后停止计时；重新打开核对数据。此操作与当前打开的照片无关。<a href="evidence/lut-import.json">原始素材与导入样本</a> · <a href="evidence/lut-import-before.json">优化前的同一组素材</a> · <a href="evidence/lut-workflow.md">GPU 与配方验证</a></p><table><thead><tr><th>文件</th><th>中位数 / p95（毫秒）</th></tr></thead><tbody>')
        for name, value in data["lutImport"].items():
            parts.append(f'<tr><th>{html.escape(name)}</th><td>{cell_text({"state":"measured","timing":value})}</td></tr>')
        parts.append('</tbody></table></section>')
    if "photoDenoise" in data:
        v = data["photoDenoise"]
        parts.append('<section><h2>已显影照片的学习型降噪</h2><p>对相机 JPEG 和由同源照片生成的其他容器使用正式 Metal VGG7 卷积模型。每次使用完整照片执行预览、恢复与导出。导出时间每种格式取一次，两组新强度和缓存重放各取十次。<a href="evidence/photo-denoise.json">源尺寸、配置文件、模型摘要与逐次像素记录</a> · <a href="evidence/photo-denoise-comparison.json">强度滑动基线</a></p><div class="scroll"><table><thead><tr><th>输入</th><th>尺寸</th><th>输入位深</th><th>16 位 TIFF 导出（ms）</th></tr></thead><tbody>')
        for row in v["sources"]:
            w,h = row["nativePixels"]
            fmt = Path(row["source"]).suffix.lstrip(".").upper()
            parts.append(f'<tr><th>{html.escape(fmt)}</th><td>{w} × {h}</td><td>{row["sourceBits"]}</td><td>{row["exportMs"]:.2f}</td></tr>')
        parts.append('</tbody></table></div><table><thead><tr><th>新增或重放的强度</th><th>中位数 / p95（ms）</th></tr></thead><tbody>')
        for label, row in v["warm"].items():
            parts.append(f'<tr><th>{html.escape(label)}</th><td>{row["medianMs"]:.2f} / {row["p95Ms"]:.2f}</td></tr>')
        parts.append(f'</tbody></table><p>从目录导入的九种格式均在相同原生坐标核对图像。交互与高质量预览的最大通道差为 {v["interactiveMax"]} 个 8 位码值，高质量预览与 16 位 TIFF 在相同采样点转换回 RGB8 后的最大差为 {v["exportMax"]}。</p></section>')
    dng_path = HERE / "evidence/output-referred-dng.json"
    if dng_path.is_file():
        dng = json.loads(dng_path.read_text())
        result = dng["result"]
        compare = json.loads((HERE/"evidence/output-referred-dng-comparison.json").read_text())
        if compare["failures"] or dng["inputDNGColorimetricReference"] != 1 or dng["controlDNGColorimetricReference"] != 0:
            raise ValueError("Incompatible output-referred DNG")
        w,h = result["nativePixels"]
        fresh, replay = compare["warm"]["new"], compare["warm"]["replay"]
        parts.append(f'<section><h2>输出参考 DNG 的降噪</h2><p>取自同一张实拍照片的两份 16 位线性 DNG，原生图像 {w} × {h}，内嵌预览 96 × 64。应用从目录导入两份文件，只对输出参考样本启用摄影降噪。十个新强度的中位数 / p95 为 {fresh["medianMs"]:.2f} / {fresh["p95Ms"]:.2f} ms，十个重放值为 {replay["medianMs"]:.2f} / {replay["p95Ms"]:.2f} ms。全尺寸 TIFF16 与高质量预览抽取相同 147,456 个颜色通道，最大差 {result["settledVsTIFF16"]["maxRGB8"]:.0f} 个 RGB8 码值。<a href="evidence/output-referred-dng.json">导入、源标记与 37 次输入</a> · <a href="../../../scripts/performance/prepare-output-dng.py">生成配对摄影 DNG 的程序</a></p></section>')
    rendered_path = HERE / "evidence/lightflow-rendered-temperature.json"
    if rendered_path.is_file():
        v = rendered_temperature(data["source"]["sha256"], read_evidence("lightflow.json",data["source"]["sha256"],"LightFlow"))
        t = v["timing"]
        parts.append(f'<section><h2>已显影图像的相对色温</h2><p>取同一张 Sony RAW 内嵌的相机 JPEG，在 LightFlow 原版编辑器交替设置 −28 与 +28，共 10 次热操作。输入至空闲确认和抓取合成画面的中位数 / p95 为 {t["medianMs"]:.2f} / {t["p95Ms"]:.2f} ms。这段时间包含原版编辑器的 100 ms 空闲轮询。<a href="evidence/lightflow-rendered-temperature.json">JPEG 来源、全幅指纹和原始采样</a></p></section>')
    if (HERE / "evidence/super-resolution-tiles.json").is_file():
        parts.append('<section><h2>超分辨率与 HDR 高光</h2><p>在初次实验中，系统 4× 模型把线性校准值 1.5 和 3 都输出为 1。将预测缩成 2× 时，采用 64 个输入像素的分块重叠仍产生约 264 个线性 16 位码值的峰值接缝。<a href="evidence/super-resolution-tiles.json">早期原型的像素范围与接缝</a> · <a href="evidence/super-resolution-model-resource.json">系统资源与倍率</a></p>')
        if "learnedDoubleSize" in data:
            v = data["learnedDoubleSize"]
            parts.append(f'<p>随后对同一张相机原片使用原生 2× 的摄影模型。全图预测并写入 {v["width"]} × {v["height"]} 浮点 16 位 TIFF 用时 <strong>{v["fullInferenceAndWriteS"]:.2f} 秒</strong>（n=1），读回后的线性范围为 {v["decodedRange"][0]:.6f} 至 {v["decodedRange"][1]:.6f}。每组 2 × 2 子像素回算原片通道均值，最大偏差 {v["allNativeBlockMeansMaxErrorAfterFP16Write"]:.7f}。独立 128 × 128 原片区域的整块与四分块预测逐位一致。此表计时终点为诊断用浮点 TIFF 写完。<a href="evidence/super-resolution-learned-full.json">模型版本、全图摘要、像素和内存</a></p>')
        native_path = HERE / "evidence/super-resolution-native.json"
        if native_path.is_file():
            v = json.loads(native_path.read_text())
            tiff = v["tiff16"]
            memory = v.get("sampledMemoryByPhase",{}).get("normalTIFF16Export")
            preview = {r["state"]:r["renderMs"] for r in v["preview"]}
            parts.append(f'<p>正常编辑器在 2400 像素适屏视图中开启 2× 耗时 {preview["2x"]:.2f} ms，撤销效果并恢复原尺寸耗时 {preview["disabled"]:.2f} ms。正常导出 {tiff["size"][0]} × {tiff["size"][1]} 的 16 位 sRGB TIFF 用时 <strong>{tiff["elapsedMs"]/1000:.3f} 秒</strong>，文件 {tiff["byteCount"]:,} 字节。各阶段均为一次完整操作。<a href="evidence/super-resolution-native.json">正常应用路径与资源监控</a> · <a href="evidence/super-resolution-output-pixels.json">全尺寸独立浮点预测与正式导出的逐通道误差</a></p>')
            if memory:
                parts.append(f'<p>导出期间采样峰值为 RSS {memory["residentBytes"]/1e9:.2f} GB、进程物理占用 {memory["physicalFootprintBytes"]/1e9:.2f} GB、Metal 分配 {memory["metalBytes"]/1e9:.2f} GB。改为条带写入后，输出缓冲区从 1.93 GB 降至 58.4 MB。与原整幅编码器逐一比较，963,477,504 个 RGBA16 通道及 ICC 均一致。<a href="evidence/super-resolution-strip-transport.json">条带写入、通道和颜色配置文件</a></p>')
        parts.append('</section>')
    if "adobeHSL" in data:
        rows = data["adobeHSL"]
        colors = {"Red":"红", "Orange":"橙", "Yellow":"黄", "Green":"绿", "Aqua":"青",
                  "Blue":"蓝", "Purple":"紫", "Magenta":"洋红"}
        axes = {"Hue":"色相","Saturation":"饱和度","Luminance":"明度"}
        qualified = sum(row["state"] == "measured" for row in rows)
        parts.append(f'<section><h2>Camera Raw 八色 HSL 的全尺寸处理</h2><p>{qualified}/24 个独立图像参数通过写回值及全幅像素核验。每次只提交一个参数，同时核对其余 23 项。蓝色的三项暖时间取自此前同原片的独立打开，本轮另行验证。单位为毫秒，筛选颜色行所需的界面时间单列在主表。<a href="evidence/camera-raw-hsl-bands.json">每次打开、颜色参数与像素摘要</a> · <a href="evidence/camera-raw-hsl-bands-xmp.zip">输入及返回 XMP</a></p><details><summary>查看 24 个参数的中位数和 p95</summary><div class="scroll"><table><thead><tr><th>颜色</th><th>参数</th><th>首次打开</th><th>暖中位数</th><th>暖 p95</th><th>暖样本数</th></tr></thead><tbody>')
        for row in rows:
            axis, color = row["field"].split("Adjustment")
            title = f'<tr><th>{colors[color]}</th><td>{axes[axis]}</td>'
            if row["state"] == "measured":
                timing = row["timing"]
                parts.append(title + f'<td>{row["firstOpenMs"]:.2f}</td><td>{timing["medianMs"]:.2f}</td><td>{timing["p95Ms"]:.2f}</td><td>{timing["n"]}</td></tr>')
            else:
                parts.append(title + f'<td colspan="4">{html.escape(row.get("reason","像素或参数未通过验证"))}</td></tr>')
        parts.append('</tbody></table></div></details></section>')
    if "nativeSettleProfile" in data:
        before, after = (data["nativeSettleProfile"][key] for key in ("before", "after"))
        parts.append(f'<section><h2>首次定稿的 GPU 耗时与内存</h2><p>同一发行构建对 LUT 强度、局部曝光和局部色轮分别输入两个新值。将全尺寸浮点校验改为分带提交后，六次定稿中位数由 {before["median"]:.2f} 降至 {after["median"]:.2f} ms。十次全尺寸校验总计由 {before["finite"]:.2f} 降至 {after["finite"]:.2f} ms。六个最终画面的全部字节一致，进程峰值物理内存增加 {(after["peak"]-before["peak"])/1024**2:.1f} MiB。<a href="evidence/rawmaster-settled-stages-v2.md">逐参数、内存预算和算法说明</a> · <a href="evidence/rawmaster-settled-stages-serial-control-v2.json">同包原路径</a> · <a href="evidence/rawmaster-settled-stages-after-v2.json">分带阶段样本</a></p></section>')
        if (HERE / "evidence/rawmaster-global-finite-v1.md").is_file():
            parts.append('<p>随后在两张独立 RAW 上验证了已驻留全局图的复用。37 项操作的 74 个首次状态中，实际全尺寸检查由 115 次减至 73 次，两个进程的 148 张最终照片逐字节匹配前一构建。<a href="evidence/rawmaster-global-finite-v1.md">同包对照、命中数与双源隔离</a></p>')
    if "nativeDehazeGuide" in data:
        guide = data["nativeDehazeGuide"]
        parts.append('<section><h2>去朦胧强度的首次与连续定稿</h2><p>同一张原片每轮先设强度 15，再输入此前未用过的强度 45。新版用源像素、白平衡和大气光绑定透射率图，首次建立的成本仍有波动。四对定稿合计 61,440,000 个 RGBA8 字节与旧路径一致。下表按运行顺序列出从请求稳定预览至整幅缓冲可读的耗时。<a href="evidence/native-dehaze-guide.json">四个进程、全幅输出和专项目标</a> · <a href="evidence/flashraw-engine.md">引擎实现与白盒分析</a></p><div class="scroll"><table><thead><tr><th>进程</th><th>第一次定稿，强度 15（ms）</th><th>下一次定稿，强度 45（ms）</th><th>进程峰值（GB）</th></tr></thead><tbody>')
        for i, name in enumerate(guide["order"], 1):
            info = guide["runs"][name]
            mode = "复用透射率图" if name.startswith("exact") else "旧路径"
            parts.append(f'<tr><th>{i} · {mode}</th><td>{info["settledMs"][0]:.2f}</td><td>{info["settledMs"][1]:.2f}</td><td>{info["peakBytes"]/1e9:.3f}</td></tr>')
        parts.append('</tbody></table></div></section>')
    if "adobeReference" in data:
        ref = data["adobeReference"]
        parts.append(f'<section><h2>Adobe 增强画质参照</h2><p>Camera Raw 经 Photoshop {html.escape(ref["photoshop"])} 打开未增强原片并写出全尺寸 16 位 sRGB TIFF。一轮打开耗时 {ref["openMs"]:.2f} ms，写盘 {ref["saveMs"]:.2f} ms。两次打开得到的 {ref["rgb16Bytes"]:,} 个 RGB16 字节完全相同。神经降噪、原始细节和超级分辨率仍缺同一张照片的 Adobe 增强输出，三项仍计为部分对齐。<a href="evidence/adobe-enhance-baseline.json">像素摘要、尺寸和计时边界</a> · <a href="evidence/enhance-capabilities.md">三项增强的验收范围</a></p></section>')
    if "groupRegression" in data:
        v = data["groupRegression"]
        historical = "通过" if v["relativePassed"] else "未通过"
        parts.append(f'<section><h2>连续组合操作的历史发布基线</h2><p>归档的 06cd00a4 构建测得 {v["count"]} 组，逐组核对交互与高质量图。交互中位数范围 {v["medianRange"][0]:.2f}–{v["medianRange"][1]:.2f} ms，绝对门为 50 ms。与固定历史基线的比较{historical}。逐项报告记录可用的画质误差分位数及其样本。<a href="evidence/release-operator-sequence.json">组合原始记录</a> · <a href="evidence/release-operator-regression.json">逐项门禁</a> · <a href="evidence/release-operator-qualification.json">交互与定稿的像素差</a></p>')
        if v["failures"]: parts.append('<ul>'+''.join('<li>'+html.escape(f)+'</li>' for f in v["failures"])+'</ul>')
        if "targeted" in v:
            parts.append('<p>早期批次出现的几何和散景增强回退，随后以新旧二进制按 A/B/B/A 顺序同机复测。下表保留每个进程的中位数（毫秒）。<a href="evidence/overlay-regression-check.json">二进制摘要、参数、像素差与逐次记录</a></p><table><thead><tr><th>操作</th><th>旧版两次</th><th>新版两次</th></tr></thead><tbody>')
            for name,row in v["targeted"].items():
                parts.append('<tr><th>'+html.escape(name)+'</th>'+''.join('<td>'+' / '.join(f'{n:.2f}' for n in row[k])+'</td>' for k in ('beforeMs','afterMs'))+'</tr>')
            parts.append('</tbody></table>')
        if "sameDayFailures" in v:
            parts.append(f'<p>与同日首轮比较，触发相对时延报警的项目数为 {len(v["sameDayFailures"])}。<a href="evidence/release-operator-same-day.json">同日批次对照</a> · <a href="evidence/release-operator-absolute.json">50 ms 绝对门</a> · <a href="evidence/history/release-operator-sequence-initial.json">同日首轮原始样本</a></p>')
        parts.append('</section>')
    if "backgroundRegression" in data:
        r = data["backgroundRegression"]
        parts.append(f'<section id="release-regression"><h2>发布版后台回归</h2><p>同机对 {r["fixtures"]} 张真实 RAW 执行解码、导航、并排比较和离屏画布绘制。以下 p95 按项目内的发布测试定义计算。</p>')
        parts.append('<p>桌面应用从「诊断 → 图像性能监控」打开监控窗口（⌥⌘P）。可查看排队与执行中的操作、GPU 和解码阶段耗时、吞吐量与近期分位数，或导出 JSON 供跨版本比较。编辑、浏览、导出与监控通过独立接口连接图像引擎。<a href="../../../Sources/RAWMasterImaging/ImageEngine.swift">引擎接口</a> · <a href="../../../Sources/RAWMaster/PerformanceMonitorWindow.swift">监控窗口</a> · <a href="evidence/engine-composition.json">生命周期与导出回归</a> · <a href="evidence/lightflow-engine.md">LightFlow 发布代码与调度研究</a></p>')
        if "localBuild" in data:
            parts.append(f'<p>本地候选应用构建号 <code>{html.escape(data["localBuild"]["version"])}</code>。签名和内置 FlashRaw 动态库已校验，降噪、超分和深度模型指纹与本轮发布结果一同保存。<a href="evidence/local-release-build.json">应用与测试包指纹</a></p>')
        if "suite" in r:
            suite = r["suite"]
            summary = suite["summary"]
            stage_count = len(suite["runStages"])
            stage_pass = sum(v == "passed" for v in suite["runStages"].values())
            result = "通过" if summary["passed"] else "未通过"
            parts.append(f'<p>同一批 Release 测试包成功执行了 {stage_pass}/{stage_count} 个后台测量命令，整套回归{result}。覆盖 {suite["measuredControls"]} 个独立控件、{suite["combinations"]} 组配方和 {suite["inspectionOperations"]} 个分析或界面操作。包内附每阶段的结果、原片指纹和测试二进制 SHA-256。交互窗口另有上方的屏幕采集。<a href="evidence/release-background-results.zip">下载整套后台原始 JSON</a> · <a href="../../../scripts/test-image-performance.sh">发版测试入口</a></p>')
            if summary.get("failedStages"):
                baseline = html.escape(summary.get("baselineRun", ""))
                parts.append(f'<p>未通过的发布门逐项列于下表。本机构建与 {baseline} 比较，LightFlow 使用固定的同机发行版。原报告文件名对应上方压缩包中的记录。</p><div class="scroll"><table><thead><tr><th>阶段</th><th>操作与触发条件</th><th>原报告</th></tr></thead><tbody>')
                for failure in summary.get("failureDetails", []):
                    items = ''.join(f'<li>{html.escape(str(value))}</li>' for value in failure["failures"])
                    parts.append(f'<tr><th>{html.escape(failure["stage"])}</th><td><ul>{items}</ul></td><td>{html.escape(failure.get("report") or "")}</td></tr>')
                parts.append('</tbody></table></div>')
            if "frozenReleaseRepeats" in data:
                repeat = data["frozenReleaseRepeats"]
                group = repeat["interactive"]
                remained = [key for key,row in group.items() if not row["interactiveWithin"] or not row["settledWithin"]]
                controls = repeat["controls"]
                canvas = " / ".join(f'{v:.2f}' for v in repeat["twoPhotoFitP95Ms"])
                parts.append(f'<h3>旧版、新版、新版、旧版的交错复测</h3><p>冻结构建 72bab30b 与 1bb13ca2 按此顺序各运行两次。每个进程重跑全部 15 张原片，并单独测量主回归中触发告警的 {len(group)} 组配方和 {len(controls)} 个控件。双图适屏绘制 p95 依次为 {canvas} ms。把每个构建的两轮样本合并后，{sum(row["within"] for row in controls.values())}/{len(controls)} 个控件达到旧版区间。组合操作中仍超出原有时延门限的是 {html.escape("、".join(remained) or "无")}。上表保留完整发行测试的原始判定。<a href="{html.escape(repeat["archive"])}">四轮原始输入、样本与执行顺序</a></p>')
                parts.append('<p>同一新版二进制又对这三组操作交错启用和关闭新增缓存。可视化范围与局部颗粒在启用时较快，点颜色样本的交互中位数分别为关闭 4.93 ms、启用 5.95 ms。每种设置下每个操作各有六个交互样本，两种设置合计四次定稿。<a href="evidence/history/release-5-three-controls-routes.zip">同包对照</a></p>')
        if (HERE / "evidence/history/release-5-vs-06cd00a4.zip").is_file():
            parts.append('<p>另将当前结果与更早的 06cd00a4 发行基线逐项复算。十组比较中，连续组合、独立控件和检查器操作仍有相对时延告警。<a href="evidence/history/release-5-vs-06cd00a4.zip">十组比较、实际触发项和两版源文件摘要</a> · <a href="evidence/history/release-background-06cd00a4.zip">早期基线原始记录</a></p>')
        parts.append(f'<p>全尺寸浏览的应用冷缓存 p95，从 {r["priorColdP95"]:.2f} ms 降至 {r["imageMetrics"]["true_raw_app_cache_cold"]["p95Milliseconds"]:.2f} ms，发布上限为 1500 ms。</p>')
        parts.append('<div class="scroll"><table><thead><tr><th>操作</th><th>次数</th><th>中位数（毫秒）</th><th>p95（毫秒）</th></tr></thead><tbody>')
        for name, v in r["imageMetrics"].items():
            parts.append(f'<tr><th>{html.escape(name)}</th><td>{v["count"]}</td><td>{v["p50Milliseconds"]:.2f}</td><td>{v["p95Milliseconds"]:.2f}</td></tr>')
        parts.append('</tbody></table></div><p><a href="evidence/release-image.json">完整发布版样本</a> · <a href="evidence/history/release-image-before-flashraw.json">全尺寸浏览器采用 FlashRaw 之前的同机基线</a></p></section>')
    return ''.join(parts)
