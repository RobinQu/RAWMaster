"""Validate materialized recipe pairs, spatial evidence and complete readbacks for the second panel suite."""

import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import struct

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[2] / "scripts/performance"
MANIFEST = SCRIPTS / "paired-photo-operators-v2.json"
FILES = {"LightFlow": "lightflow-photo-operators-v2.json", "RAWMaster": "rawmaster-photo-operators-v2.json"}
PROTOCOL = {"LightFlow": "resident-photo-operators-stock-scheduler-v2",
            "RAWMaster": "resident-photo-operators-interactive-settled-v2"}
PHASES = ("first", "firstExact", "final")
RAW = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
ASSET = {"warm": "lut-a01", "mono": "lut-b02"}
OLD_MANIFEST_SHA = "2e7cc1b77bf59e97a5f91054d6b76006f47d3e343cacc4b91deb753570fed036"
EXCLUDED = {
    "直方图或编辑器手势，计时终点为选择、参数提交或重置":
        ["light-histogram-drag", "light-numeric-reset", "curve-parametric", "curve-input-output",
         "curve-reset-channel", "curve-keyboard", "mixer-hsl-mode", "mixer-eight-colors", "mixer-tat"],
    "依赖产品各自的分析或取样结果，结束时没有共同的固定照片配方":
        ["light-auto", "light-auto-single", "color-wb-auto", "color-wb-picker", "color-vectorscope", "color-skin-indicator"],
    "素材入库结束于可用目录项，照片可以保持原样": ["grading-lut-import"],
    "LightFlow 在 RAW 解码时应用内嵌校正，RAWMaster 从镜头库应用配置，驻留照片后续工作量不同": ["optics-profile-enable"],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def valid_digest(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None


def stats(series):
    ordered = sorted(series)
    return {"n": len(ordered), "medianMs": statistics.median(ordered), "p95Ms": ordered[math.ceil(.95 * len(ordered)) - 1]}


def cube_bytes(manifest, name):
    rows = [s.split() for s in manifest["luts"][name].splitlines() if re.match(r"^[0-9+.-]", s)]
    require(len(rows) == 8 and all(len(r) == 3 for r in rows), "Expected a complete 2³ CUBE")
    return struct.pack("<24f", *(float(v) for row in rows for v in row))


def validate_source(data, manifest, product, expected_source=RAW):
    specs = manifest["controls"]
    require(data["schemaVersion"] == 2 and data["protocol"] == PROTOCOL[product] and data["application"] == product
            and data["samples"] == 20 and data["pixels"] == [2400, 1600]
            and valid_digest(expected_source) and data["sourceSHA256"] == data["sourceSHA256After"] == expected_source
            and data["parameterSHA256"] == sha(MANIFEST.read_bytes())
            and sorted(row["id"] for row in data["operations"]) == sorted(specs), f"Invalid {product} source or inventory")
    if product == "LightFlow":
        reference = json.loads((HERE / "evidence/lightflow-panel-schedule.json").read_bytes())
        require(data["rawSize"] == [9504, 6336] and data["build"] == reference["build"] and
                data["engineSHA256"] == reference["engineSHA256"] and data["browserBinarySHA256"] == reference["browserBinarySHA256"]
                and data["adapterInfo"]["isFallbackAdapter"] is False and data["radial"] == manifest["radial"]
                and all(valid_digest(data[k]) for k in ("scheduleProbeSHA256", "photoOperatorAdapterSHA256", "probeSHA256")),
                "Wrong stock browser/engine, radial geometry or hardware")
        for name, label in ASSET.items():
            table = data["registeredLUTs"][label]
            require(table["dim"] == "3d" and table["size"] == 2 and table["domainMin"] == [0]*3 and table["domainMax"] == [1]*3
                    and struct.pack("<24f", *table["data"]) == cube_bytes(manifest,name), f"Wrong registered {name} CUBE values")
    else:
        require(valid_digest(data["binarySHA256"]) and data["decoder"] == "flashraw-0.3.1-linear-srgb-bilinear", "Wrong native binary or decoder")


def validate_geometry(mask, radial, original):
    if original:
        require(not mask["invert"] and len(mask["components"]) == 1, "Wrong node-level matte")
        component = mask["components"][0]
        require(component["type"] == "radial" and component["op"] == "add" and component["angle"] == 0
                and component["inside"] and component["enabled"], "Wrong stock local matte")
        rx, ry = component["rx"], component["ry"]
        feather, opacity, inverted = component["feather"]/100, component["opacity"], component["invert"]
    else:
        component = mask
        require(component["kind"] == "radial" and component["enabled"], "Wrong native local matte")
        rx, ry = component["radiusX"], component["radiusY"]
        feather, opacity, inverted = component["feather"], component["opacity"], component["inverted"]
    require([component["center"]["x"], component["center"]["y"]] == radial["center"] and [rx, ry] == radial["radius"]
            and (feather, opacity, inverted) == (radial["feather"], radial["opacity"], radial["inverted"]), "Ellipse differs")


def validate_recipe(key, spec, state, value, data, manifest, stock):
    """Check submitted engine data, including native unit conversions, not just the copied manifest."""
    f = spec["fixed"]
    if stock:
        edit, view = state["edit"], state["view"]
        nodes = edit["grade"]["nodes"]
        require(all(n["enabled"] and n["kind"] == "corrector" and n["opacity"] == 1 for n in nodes), key)
        if spec["region"] == "radial":
            require(len(nodes) == 1, key)
            validate_geometry(nodes[0]["mask"], manifest["radial"], True)
        else:
            require(all(n["mask"] is None for n in nodes), key)
        tools, base = nodes[0]["tools"], edit["base"]
    else:
        p = state["adjustmentsV3"]
        require(state["engineVersion"] == "rawmaster-adjust-v3" and p["rawDecoder"] == data["decoder"], key)
        if spec["region"] == "radial":
            require(len(p["masks"]) == 1, key)
            validate_geometry(p["masks"][0], manifest["radial"], False)
            local = p["masks"][0]["adjustments"]
        else:
            require(not p.get("masks"), key)

    if key.startswith("grading-lut-"):
        names = [value] if key == "grading-lut-select" else [f["cube"]] if "cube" in f else value.split(",")
        amounts = f["amounts"][:len(names)] if "amounts" in f else [f.get("amount", value)]
        if stock:
            edges = edit["grade"]["edges"]
            path = ["@input"] + [n["id"] for n in nodes] + ["@output"]
            require([(e["from"],e["to"],e["index"]) for e in edges] == [(a,b,0) for a,b in zip(path,path[1:])], key)
            colors = [n["tools"]["effects"]["lut"] for n in nodes]
            require([c["name"] for c in colors] == names and [c["strength"] for c in colors] == amounts
                    and all(c["asset"] == ASSET[c["name"]] and c["inputSpace"] == c["outputSpace"] == "srgb" for c in colors), key)
        else:
            layers = [local["gradingLUT"]] if key == "grading-lut-mask" else p["gradingLUTs"]["layers"]
            require([layer["cube"]["name"] for layer in layers] == names and [layer["amount"] for layer in layers] == amounts, key)
            for layer in layers:
                c = layer["cube"]
                require(c["dimension"] == 2 and c["domainMin"] == [0]*3 and c["domainMax"] == [1]*3
                        and base64.b64decode(c["lutCubeRGB32"],validate=True) == cube_bytes(manifest,c["name"]), key)
        return

    if key.startswith("color-wb-"):
        if stock:
            require(base["wbMode"] == value and (value == "as-shot" or [base["temperature"],base["tint"]] == f[value]), key)
        else:
            wb = p["whiteBalance"]["resolvedState"]
            require(wb["kind"] == "raw" and RAW in json.dumps(wb["source"]), key)
            wb = wb["state"]
            require(wb["selectedMode"] == ("asShot" if value == "as-shot" else "temperatureTint"), key)
            if value != "as-shot":
                tt = wb["temperatureTint"]
                require([tt["temperatureBits"],tt["tintBits"]] == [struct.unpack("<I",struct.pack("<f",n))[0] for n in f[value]], key)
    elif key == "color-bw-treatment":
        require(base["profile"] == ("standard" if value == "color" else "monochrome") if stock
                else p["blackAndWhite"]["enabled"] == (value == "monochrome"), key)
    elif key == "effects-pcv-style":
        v = tools["effects"] if stock else p["effects"]["postCropVignette"]
        require(all(v["vignette"+k.title() if stock else k] == n for k,n in f.items()), key)
        require(v["vignetteStyle"] == value if stock else v["style"] == {"paint-overlay":"paintOverlay","highlight-priority":"highlightPriority"}[value], key)
    elif key == "effects-dehaze":
        require(tools["basic"]["dehaze"] == value if stock else p["advancedDetail"]["dehaze"]["amount"] == value
                and RAW in json.dumps(p["advancedDetail"]["preparedDehaze"]["sourceBinding"]), key)
    elif key.startswith("curve-"):
        if stock:
            points = tools["curves"][f["channel"]]
        else:
            section = local if spec["region"] == "radial" else p
            points = [[v["x"],v["y"]] for v in section["curves"]["rgb" if f["channel"] == "master" else "red"]["curve"]["points"]]
        require(points == [[0,0],[f["input"],value],[1,1]], key)
    elif key in ("grading-luminance","grading-blending","grading-balance","grading-mask-wheels"):
        g = tools["wheels"] if stock else local["grading"] if key == "grading-mask-wheels" else p["legacyBasis"]["color"]["grading"]
        def wheel(which, hue, saturation, lum):
            w = g["lr"+which.title() if stock else which]
            require((w["hue"],w["sat"],w["lum"]) == (hue,saturation,lum) if stock else
                    (w["hueDegrees"],w["saturation"],w["luminance"]) == (hue,saturation,lum), key)
        if key == "grading-mask-wheels":
            wheel("midtones",f["hue"],value,0)
        else:
            wheel("shadows",f["shadowsHue"],f["shadowsSaturation"],value if key == "grading-luminance" else 0)
            wheel("highlights",f["highlightsHue"],f["highlightsSaturation"],0)
        require(g["lrBlending" if stock else "blending"] == (value if key == "grading-blending" else f["blending"])
                and g["lrBalance" if stock else "balance"] == (value if key == "grading-balance" else f["balance"]), key)
    elif key.startswith("detail-nr-"):
        d = tools["detail"] if stock else p["noiseReduction"]
        scale = 1 if stock else 100
        kind = "luminanceContrast" if key == "detail-nr-lum-contrast" else "colorDetail"
        fields = {"luminanceNoise":"noiseLuminance","colorNoise":"noiseColor","luminanceContrast":"noiseLumContrast","colorDetail":"noiseColorDetail"}
        for field, expected in [("luminanceNoise",f["luminanceNoise"]),("colorNoise",f["colorNoise"]),(kind,value)]:
            require(abs(d[fields[field] if stock else field]*scale-expected) < 1e-8, key)
    elif key.startswith("light-clipping-"):
        require(base["exposure"] == f["exposure"] if stock else p["light"]["exposure"]*2 == f["exposure"], key)
        if stock:
            require(view["clipping"] == value if key == "light-clipping-indicators" else
                    view["alt"] == ({"node":"","view":"clip-high"} if value else None), key)
        else:
            require(p["light"].get("clippingPreview") == (f["preview"] if value else None), key)
    elif key == "detail-mask-preview":
        d = tools["detail"] if stock else p["sharpen"]
        for native, original in (("intensity","sharpenAmount"),("radius","sharpenRadius"),("detail","sharpenDetail"),("masking","sharpenMasking")):
            field = "masking" if native == "masking" else original
            require(d[original if stock else native] == f[field]/(1 if stock or native == "radius" else 100), key)
        require(view["alt"] == ({"node":nodes[0]["id"],"view":"mask"} if value else None) if stock else d["visualiseMasking"] == value, key)
    else:
        field = key.split("-")[-1]
        prop = {"temp":"temperature","noise":"noiseReduction"}.get(field,field)
        if stock:
            if field == "hue": actual, expected = tools["wheels"]["hue"], 50+50*value
            elif field == "grain":
                actual, expected = tools["effects"]["grainAmount"], value
                require(tools["effects"]["grainSize"] == f["size"] and tools["effects"]["grainRoughness"] == f["roughness"], key)
            elif field in ("sharpness","noise"):
                actual, expected = tools["detail"]["sharpenAmount" if field == "sharpness" else "noiseLuminance"], value
            else: actual, expected = tools["basic"][prop], value
        else:
            actual = local[prop]
            expected = value/2 if field == "exposure" else value if field == "hue" else value/(-100 if field=="blacks" else 100)
            if field == "grain": require(local["grainSize"] == f["size"]/100 and local["grainRoughness"] == f["roughness"]/100, key)
        require(abs(actual-expected) < 1e-8, f"{key} ({actual} versus {expected})")


def validated_rows(data, manifest, product, expected_source=RAW):
    validate_source(data, manifest, product, expected_source)
    out = {}
    stock = product == "LightFlow"
    previous_sequence = 0
    for row in data["operations"]:
        key = row["id"]
        spec = manifest["controls"][key]
        require(all(row[k] == spec[k] for k in ("values","fixed","region","unit")) and len(row["stateDescriptions"]) == 2, key)
        for i, value in enumerate(spec["values"]):
            validate_recipe(key,spec,row["stateDescriptions"][i],value,data,manifest,stock)
        samples = row["samples"]
        require(len(samples) <= 22, key)
        all_states, inside, outside = [set(),set()], [set(),set()], set()
        times = {p:[] for p in PHASES}
        first_matches = 0
        qualified_frames = True
        for i, t in enumerate(samples):
            s = i % 2
            require(t["state"] == s and t["phase"] == ("first" if i < 2 else "warm"), key)
            if stock:
                frames = t["frames"]
                require(bool(frames), key)
                for frame in frames:
                    require(frame["seq"] > previous_sequence and valid_digest(frame["wholeRasterSHA256"]) and
                            valid_digest(frame["digest"]) and math.isfinite(frame["ms"]) and frame["ms"] > 0, key)
                    previous_sequence = frame["seq"]
                first, last = frames[0], frames[-1]
                first_hash, final_hash = first["wholeRasterSHA256"], last["wholeRasterSHA256"]
                exact = next(f for f in frames if f["wholeRasterSHA256"] == final_hash)
                delay = first["frameStartAfterDispatchMs"]
                values = [first["ms"],t["renderToFirstExactFinalMs"],t["renderToFinalMs"]]
                require(abs(exact["actionToPixelsMs"]-delay-values[1]) <= .002 and
                        abs(last["actionToPixelsMs"]-delay-values[2]) <= .002 and
                        abs(first["actionToPixelsMs"]-delay-values[0]) <= .002 and
                        t["schedulerTransitions"][-1]["bits"] == 0 and t["idleConfirmedMs"] >= last["actionToPixelsMs"] and
                        t["digest"] == last["digest"] and t["ms"] == values[2], key)
                qualified_frames &= last["fullRes"] and not last["interactive"] and not last["provisional"]
            else:
                first_hash, final_hash = t["firstSHA256"], t["digest"]
                values = [t["firstMs"],t["firstExactFinalMs"],t["ms"]]
                require(row["pixelWitness"] == "entire-opaque-sRGB-RGBA8" and values[1] == (
                    values[0] if first_hash == final_hash else values[2]), key)
            require(valid_digest(first_hash) and valid_digest(final_hash) and all(math.isfinite(v) and v > 0 for v in values)
                    and values[0] <= values[1]+.002 and values[1] <= values[2]+.002, key)
            all_states[s].add(final_hash)
            if spec["region"] == "radial":
                r = t["regions"]
                require((r["insideCount"],r["outsideCount"]) == (416,1640) and
                        valid_digest(r["inside"]) and valid_digest(r["outside"]), key)
                inside[s].add(r["inside"])
                outside.add(r["outside"])
            if i >= 2 and first_hash == final_hash:
                first_matches += 1
            for phase, ms in zip(PHASES, values):
                times[phase].append(ms)
        stable = len(samples) == 22 and all(len(a) == 1 for a in all_states) and all_states[0] != all_states[1]
        spatial = spec["region"] == "global" or (len(outside) == 1 and all(len(a)==1 for a in inside) and inside[0] != inside[1])
        verified = bool(stable and spatial and qualified_frames)
        require(row["status"] == ("measured" if verified else "inconclusive"), f"Qualification disagrees for {product}/{key}")
        if stock:
            require(row["finalWholeRasterDigestsByState"] == [sorted(a) for a in all_states] if verified else True, key)
            require(row["firstFrameExactFinal"]["warm"] == first_matches, key)
        else:
            require(len(row["recipes"]) == 2 and all(valid_digest(x) for x in row["recipes"]) and row["recipes"][0] != row["recipes"][1], key)
        out[key] = {"status":row["status"],"reason":row.get("reason"),"samples":len(samples),"firstMatches":first_matches,
                    "phases":{p:stats(v[2:]) for p,v in times.items()} if verified else {},
                    "initial":{p:v[:2] for p,v in times.items()}}
    return out


def latency_limits(previous, current):
    median_limit = previous["medianMs"] + max(1, .1 * previous["medianMs"])
    p95_limit = previous["p95Ms"] + max(2, .2 * previous["p95Ms"])
    return {"medianLimit":median_limit, "p95Limit":p95_limit,
            "within":current["medianMs"] <= median_limit and current["p95Ms"] <= p95_limit}


def comparison(lightflow, native, manifest):
    require(sha((SCRIPTS/"paired-panel-controls.json").read_bytes()) == OLD_MANIFEST_SHA and
            not set(manifest["controls"]) & set(json.loads((SCRIPTS/"paired-panel-controls.json").read_bytes())),
            "Original 31-control manifest changed or inventories overlap")
    require(lightflow["system"]["chip"] == native["gpu"] and lightflow["system"]["os"].split("-")[1] in native["os"],
            "Operating system or physical GPU differs")
    all_rows = {p:validated_rows(d,manifest,p) for p,d in (("LightFlow",lightflow),("RAWMaster",native))}
    rows = {}
    for key, spec in manifest["controls"].items():
        stocks, current = all_rows["LightFlow"][key], all_rows["RAWMaster"][key]
        comparable = stocks["status"] == current["status"] == "measured"
        phases = {}
        for phase in PHASES if comparable else ():
            a, b = stocks["phases"][phase], current["phases"][phase]
            phases[phase] = {"LightFlow":a, "RAWMaster":b, **latency_limits(a, b)}
        rows[key] = {"values":spec["values"],"fixed":spec["fixed"],"unit":spec["unit"],"region":spec["region"],
                     "LightFlow":stocks,"RAWMaster":current,"qualified":comparable,"phases":phases}
    return {"schemaVersion":2,"sourceSHA256":native["sourceSHA256"],"pixels":native["pixels"],"gpu":native["gpu"],
            "parameterSHA256":native["parameterSHA256"],"binarySHA256":native["binarySHA256"],"operations":rows}


def panel_photo_operators(sha256):
    require(sha256 == RAW, "Unknown RAW for paired-photo-operators-v2")
    return compare_paths(HERE/"evidence"/FILES["RAWMaster"])


def compare_paths(native, lightflow=HERE/"evidence"/FILES["LightFlow"]):
    """Validate a fresh release JSON against the pinned stock capture; never modify either input."""
    return comparison(json.loads(Path(lightflow).read_bytes()),json.loads(Path(native).read_bytes()),json.loads(MANIFEST.read_bytes()))


def markdown(result):
    rows = result["operations"]
    labels = {f["id"]:f["name"] for f in json.loads((HERE/"feature-matrix.json").read_bytes())["features"]}
    qualified = sum(r["qualified"] for r in rows.values())
    verified = {p:sum(r[p]["status"]=="measured" for r in rows.values()) for p in FILES}
    within = {p:sum(r["phases"][p]["within"] for r in rows.values() if r["qualified"]) for p in PHASES}
    all_three = sum(all(r["phases"][p]["within"] for p in PHASES) for r in rows.values() if r["qualified"])
    lines = ["# 驻留照片全幅读回 · 第二组 37 项","",
             f"同一台 {result['gpu']}、同一张 9504 × 6336 Sony RAW。两端各交替提交 37 组 A/B 配方，每组先记录两次首次输入，再记录 20 次热输入。每次读回 2400 × 1600 不透明 sRGB RGBA8 的 15,360,000 个字节。"
             f" 原版 LightFlow 通过 {verified['LightFlow']}/37 项，RAWMaster 通过 {verified['RAWMaster']}/37 项，双方共同通过 {qualified}/37 项的输入与像素验证。","",
             f"按既有发版阈值，RAWMaster 的首张完整照片有 {within['first']}/{qualified} 项达线，首张与最终照片逐字节一致的照片有 {within['firstExact']}/{qualified} 项达线，"
             f"最终处理请求有 {within['final']}/{qualified} 项达线。三个终点同时达线 {all_three}/{qualified} 项。每个终点同时比较热采样中位数和 p95，前者容许 LightFlow 加 1 ms 或 10% 中较大者，后者容许加 2 ms 或 20% 中较大者。","",
             "## 采样边界","",
             "LightFlow 2d41ab1 使用发行版 Photo viewer 的公开 WASM 接口。操作先使视图失效，原版调度器随后经动画帧请求绘制；每次绘制都读回完整像素，直至原版首次报告无需绘制且不忙。表中从第一次实际绘制调用计时。第二、第三终点包含后续帧间等待。原始数据另记从失效到每帧及空闲确认的耗时。","",
             "RAWMaster 通过 ImageEngine 的正常入口，在同一会话中提交交互预览并完整读回，随即提交同配方的稳定预览并完整读回。计时包含 GPU 计算与完整 CPU 像素传输。两端在计时结束后对每个完整缓冲区计算 SHA-256。窗口输入、绘图层合成与显示器刷新各有独立测量。","",
             "每个引擎必须在 22 次试验中按各自 A/B 状态精确复现完整最终像素，两态之间必须不同。18 项局部操作使用相同归一化椭圆，中心 (0.50, 0.50)，横纵半径 0.35 与 0.30，羽化 0、不透明度 1、向内、无旋转。中心 416 个采样点的 RGB 必须随状态改变，远外部 1,640 个点必须在所有输入中保持相同。每个引擎均从自己的显影结果核验 A/B。","",
             "20 次热输入只包含这两个出现过的配方，允许各产品复用相同配方的缓存。每项首次 A/B 的三个耗时单列于下表。8 个基础滑杆另有 20 个连续新值的测量。","",
             "CUBE 记录含相同的浮点表数据、域、叠加顺序及强度。曝光按实际 EV 换算，局部黑场按提升黑位的方向换算。色相用各自正向拨盘行程分数，其他图像滑块按两端同一归一化强度。两端的降噪、锐化、提示色及默认显影算法各自生效。RAWMaster 的去朦胧先对源建立空气光模型，首次准备单独记录。","",
             "## 逐项","",
             "各时间格先列 LightFlow、后列 RAWMaster，两者各为中位数 / p95（ms）。首帧命中数的分母是 20。末列从左至右对应三个时间终点，✓ 表示两个分位数同时达线。","",
             "| 操作与配方 | 首张完整照片 LF → RM | 首张等于最终照片 LF → RM | 最终请求结束 LF → RM | 首帧命中 LF / RM | 达线 |",
             "| --- | ---: | ---: | ---: | ---: | :---: |"]
    for key,r in rows.items():
        a,b = r["LightFlow"],r["RAWMaster"]
        values = " → ".join(str(v).lower() for v in r["values"])
        title = f"{labels[key]} · {key} · {values}"
        if not r["qualified"]:
            failed = "，".join(p+" "+str(r[p]["reason"]) for p in FILES if r[p]["status"] != "measured")
            lines.append(f"| {title} | — | — | — | {a['firstMatches']} / {b['firstMatches']} | {failed} |")
            continue
        times = []
        flags = []
        for phase in PHASES:
            paired = r["phases"][phase]
            times.append(" → ".join(f"{paired[p]['medianMs']:.2f} / {paired[p]['p95Ms']:.2f}" for p in FILES))
            flags.append("✓" if paired["within"] else "×")
        lines.append(f"| {title} | "+" | ".join(times)+f" | {a['firstMatches']} / {b['firstMatches']} | {' '.join(flags)} |")
    lines += ["", "## 首次提交各项 A/B 的耗时", "",
              "同一 RAW 已打开。每个格子分别列出 A / B 两次首次提交的毫秒数，先列 LightFlow，后列 RAWMaster。B 在 A 之后提交，可以复用同一张照片的解码或上游准备结果。最后一行汇总所有通过像素校验的首次输入。每个配方只有一次首次输入，未据此估计逐项 p95。", "",
              "| 操作 | 首张完整照片 LF → RM | 首张等于最终照片 LF → RM | 最终请求结束 LF → RM |",
              "| --- | ---: | ---: | ---: |"]
    initial = {p: {phase: [] for phase in PHASES} for p in FILES}
    for key, row in rows.items():
        cells = []
        for phase in PHASES:
            values = []
            for product in FILES:
                pair = row[product]["initial"][phase]
                values.append(" / ".join(f"{v:.2f}" for v in pair) if len(pair) == 2 else "—")
                if row["qualified"]:
                    initial[product][phase].extend(pair)
            cells.append(" → ".join(values))
        lines.append(f"| {labels[key]} · {key} | " + " | ".join(cells) + " |")
    if qualified:
        medians = [" → ".join(f"{statistics.median(initial[p][phase]):.2f}" for p in FILES) for phase in PHASES]
        lines.append(f"| 通过验证的 {qualified*2} 次首次输入中位数 | " + " | ".join(medians) + " |")
    lines += ["", "另取全局 LUT 强度、局部曝光与局部色轮的六次首次输入，逐阶段核验了原生有限值检查、GPU 完成、定稿像素和进程峰值内存。全组 74 个首次配方另有同一源纹理证明的逐态开关对照。 [首次定稿阶段对照](rawmaster-settled-stages-v2.md) · [全组有限性证明对照](rawmaster-global-finite-v1.md)"]
    lines += ["","## 其余 17 项的独立测量","",
              "现有对照另涵盖 8 项基础滑杆和 31 项面板操作。下列 17 项保留编辑器、分析、目录或解码各自的终点。与本报告 37 项合计覆盖 93 个有同义入口的控件。",""]
    for reason, ids in EXCLUDED.items():
        lines.append("- "+reason+"。"+"、".join("`"+key+"`" for key in ids)+"。")
    lines += ["","## 复核与复现","",
              "锐化蒙版另有逐像素参考。独立程序以原生 9504 × 6336 线性亮度生成边缘蒙版，先写出全尺寸 RGBA16F，再缩放到共同的展示尺寸。实拍参考与定稿蒙版在 384 万个像素上均为精确灰阶，定稿有 145 个灰阶，绝对误差的 p99 为 0、最大为 1 个 8 位码值。第二个同时驻留的 Sony RAW 也通过不同源和重复取用核验。 [全分辨率参考](rawmaster-sharpen-mask-reference-v2.json) · [优化前单项](rawmaster-sharpen-mask-before-replay-v2.json) · [优化后单项](rawmaster-sharpen-mask-after-replay-v2.json)","",
              "两份原始记录保留了每次实际提交的 A/B 配方和每次读回时刻，LightFlow 还保留各中间帧、调度器状态和实际注册的 LUT。"
              " [LightFlow 原始数据](lightflow-photo-operators-v2.json) · [RAWMaster 当前发行构建](rawmaster-photo-operators-v2.json) · [RAWMaster 初次归档](rawmaster-photo-operators-initial-v2.json) · "
              "[公共配方](../../../../scripts/performance/paired-photo-operators-v2.json) · [逐项校验程序](../paired_photo_operator_report.py)","",
              "仓库根目录下可用下列入口生成新的原始记录。两个引擎分别独占同一台机器的 GPU。","",
              "```sh","python3 scripts/performance/benchmark-lightflow.py --paired-photo-operators --samples 20 \\",
              "  --raw \"$RAW\" --chrome \"$CHROME_HEADLESS_SHELL\" --output \"$STOCK_JSON\"",
              "RAWMASTER_FLASHRAW_LIBRARY=\"$FLASHRAW_DYLIB\" RAWMASTER_PANEL_READBACK_SET=photo-operators-v2 \\",
              "  RAWMASTER_PANEL_READBACK_RAW=\"$RAW\" RAWMASTER_PANEL_READBACK_REPORT=\"$NATIVE_JSON\" \\",
              "  xcrun xctest -XCTest RAWMasterImagingTests.IndividualControlPerformanceTests/testPanelDisplayReadback \\",
              "  \"$RELEASE_TEST_BUNDLE\"","python3 docs/research/camera-raw-parity/paired_photo_operator_report.py --check","```",""]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check",action="store_true",help="Verify the checked-in Markdown equals the two source records")
    modes.add_argument("--summary-json",type=Path,help="Write the validated release comparison as JSON, without changing the Markdown")
    parser.add_argument("--require-within",action="store_true",help="Exit unsuccessfully if any control misses any endpoint")
    parser.add_argument("--native",type=Path,default=HERE/"evidence"/FILES["RAWMaster"])
    parser.add_argument("--lightflow",type=Path,default=HERE/"evidence"/FILES["LightFlow"])
    parser.add_argument("--output",type=Path,default=HERE/"evidence/paired-photo-operators-v2.md")
    args = parser.parse_args()
    result = compare_paths(args.native,args.lightflow)
    if args.summary_json:
        args.summary_json.write_text(json.dumps(result,indent=2,allow_nan=False)+"\n")
    else:
        content = markdown(result)
        if args.check:
            require(args.output.read_text() == content, "Committed second-suite report differs from its sources")
        else:
            args.output.write_text(content)
    failures = [k for k,r in result["operations"].items() if not r["qualified"] or not all(p["within"] for p in r["phases"].values())]
    print(f"{sum(r['qualified'] for r in result['operations'].values())}/37 comparable A/B photo controls; {37-len(failures)}/37 within all latency thresholds")
    if args.require_within and failures:
        raise SystemExit("Outside matched thresholds: "+", ".join(failures))
