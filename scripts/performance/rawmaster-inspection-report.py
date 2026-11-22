#!/usr/bin/env python3
"""Rebuild the inspection report's measured tables from named JSON operations."""

import argparse
import hashlib
import json
import math
import re
import statistics
from pathlib import Path


EVIDENCE = Path(__file__).resolve().parents[2] / "docs/research/camera-raw-parity/evidence"
ANALYSIS = "源图分析至有效配方或目标数值"
POINTER = "驻留预览的指针事件至格式化文本"
SCOPE = "真实色度分布至 256 × 168 控件像素"
TOOLS = {
    "light-auto": ("整组色调 Auto", ANALYSIS),
    "light-auto-single": ("曝光单项 Auto", ANALYSIS),
    "color-wb-auto": ("自动白平衡", ANALYSIS),
    "color-wb-picker": ("中性灰吸管", ANALYSIS),
    "mixer-point-picker": ("Point Color 吸管", ANALYSIS),
    "optics-defringe-picker": ("去边吸管（紫色范围）", ANALYSIS),
    "mixer-tat": ("照片上选择 HSL 并调整饱和度", "源图取样至定向拖动后各颜色的饱和度"),
    "curve-tat-point": ("照片上选择点曲线并拖动", "源图取样至拖动后的曲线节点"),
    "color-rgb-readout": ("指针 sRGB 读数", POINTER),
    "color-lab-readouts": ("指针 Lab D50 读数", POINTER),
    "color-samplers": ("替换并读取九个颜色采样点", "替换持久化采样点至九个颜色读数"),
    "curve-tat-parametric": ("照片上选择参数曲线并拖动", "显示像素取样至曲线分区及首次拖动后的值"),
    "color-vectorscope": ("矢量示波器", SCOPE),
    "color-skin-indicator": ("肤色参考虚线", SCOPE),
    "light-clipping-modifier": ("临时剪切预览修饰键", "高光区 Option 切换至预览像素取回"),
    "mixer-point-swatches": ("在已有七个取样色上新增第八个", "源图坐标输入至八个色样就绪"),
    "global-auto-light-and-color": ("全局 Light＋Color Auto", ANALYSIS),
}
WORKFLOW = {
    "light-histogram-drag": "直方图曝光区拖动",
    "light-numeric-reset": "单字段数值复位",
    "curve-input-output": "曲线点输入与输出",
    "curve-reset-channel": "单曲线通道复位",
    "curve-keyboard": "原生曲线键盘微调",
    "optics-profile-match": "原片 EXIF 自动匹配",
    "optics-profile-select": "手动选择镜头配置",
    "optics-profile-defaults": "保存和恢复镜头默认值",
    "curve-parametric": "参数曲线绘图区 121 个纵坐标",
    "mixer-hsl-mode": "HSL 模式中的八个颜色字段",
    "mixer-color-mode": "按颜色组织的 HSL 字段",
    "mixer-eight-colors": "八色混合器的单个颜色字段",
}


def warm(row):
    times = sorted(s["ms"] for s in row["samples"] if s["phase"] == "warm")
    if row["status"] != "measured":
        return ["未验证", "未验证"]
    if len(times) < 10:
        raise ValueError(f"{row['id']} has fewer than ten warm samples")
    return [f"{statistics.median(times):.3f}", f"{times[math.ceil(0.95 * len(times)) - 1]:.3f}"]


def table(text, headings, alignment, rows):
    def line(items):
        return "| " + " | ".join(items) + " |"

    header = line(headings)
    pattern = re.compile(r"^" + re.escape(header) + r"$\n(?:^\|[^\n]*\|$\n?)+", re.MULTILINE)
    updated, count = pattern.subn("\n".join([header, line(alignment), *map(line, rows)]) + "\n", text)
    if count != 1:
        raise ValueError(f"Expected one table headed {header}, found {count}")
    return updated


def adopt(capture, previous, library):
    data = json.loads(capture.read_text())
    if data["sourceSHA256"] != previous["sourceSHA256"] or data["sourceSHA256After"] != data["sourceSHA256"]:
        raise ValueError("Source hashes differ between runs")

    def items(record):
        return {row["id"]: row for row in record["operations"] + record["supplementaryOperations"]}

    current = items(data)
    if missing := items(previous).keys() - current.keys():
        raise ValueError(f"New observation is missing {sorted(missing)}")
    for row in current.values():
        if row["status"] != "measured" or len(row["samples"]) < 12:
            raise ValueError(f"Insufficient verified samples for {row['id']}")
        row.update(binarySHA256=data["binarySHA256"], recordedAt=data["recordedAt"])
    for key in ("fixtureName", "testHost", "nativeWB", "priorSkinAttempts", "analysisOptimization"):
        data[key] = previous[key]
    data["osBuild"] = data["os"].split(" (Build ", 1)[-1].rstrip(")")
    with library.open("rb") as source:
        data["flashRawLibrarySHA256"] = hashlib.file_digest(source, "sha256").hexdigest()
    before = items(json.loads((EVIDENCE / data["analysisOptimization"]["rawBefore"]).read_text()))
    for row in data["analysisOptimization"]["operations"]:
        key = row["id"]
        first, latest = before[key]["samples"], current[key]["samples"]
        if [sample["digest"] for sample in first] != [sample["digest"] for sample in latest]:
            raise ValueError(f"Source analysis output changed for {key}")
        row.update(
            currentMedianMs=statistics.median(s["ms"] for s in latest if s["phase"] == "warm"),
            currentIdenticalResultDigests=len(latest),
            currentBinarySHA256=data["binarySHA256"],
        )
    swatch_history = "history/rawmaster-point-swatches-before.json"
    old = json.loads((EVIDENCE / swatch_history).read_text())
    swatch = "mixer-point-swatches"
    old_samples = old["operations"][0]["samples"]
    new_samples = current[swatch]["samples"]
    if old["sourceSHA256"] != data["sourceSHA256"] or [s["digest"] for s in old_samples] != [
        s["digest"] for s in new_samples
    ]:
        raise ValueError("Eight-swatch result differs from the unsimplified analysis graph")
    data["pointSwatchOptimization"] = {
        "rawBefore": swatch_history, "identicalResultDigests": len(new_samples),
        "beforeMedianMs": statistics.median(s["ms"] for s in old_samples if s["phase"] == "warm"),
        "afterMedianMs": statistics.median(s["ms"] for s in new_samples if s["phase"] == "warm"),
        "beforeGraphHits": old["analysisCache"]["workingImageHits"],
        "afterGraphHits": data["analysisCache"]["workingImageHits"],
    }
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument(
        "--adopt", type=Path, help="Adopt a full same-fixture run after verifying its result history"
    )
    parser.add_argument(
        "--flashraw",
        type=Path,
        default=EVIDENCE.parents[3] / "output/tools/flashraw-target/release/libflashraw_capi.dylib",
    )
    args = parser.parse_args()
    document = EVIDENCE / "rawmaster-inspection.md"
    evidence_file = EVIDENCE / "rawmaster-inspection.json"
    evidence = json.loads(evidence_file.read_text())
    if args.adopt:
        evidence = adopt(args.adopt, evidence, args.flashraw)
    initial = document.read_text()
    rows = {r["id"]: r for r in evidence["operations"] + evidence["supplementaryOperations"]}
    if unknown := rows.keys() - TOOLS.keys() - WORKFLOW.keys():
        raise ValueError(f"Unknown operation IDs {sorted(unknown)}")
    text = table(
        initial,
        ["操作", "计时终点", "暖态中位数 ms", "p95 ms"],
        ["---", "---", "---:", "---:"],
        [[*info, *warm(rows[key])] for key, info in TOOLS.items() if key in rows],
    )
    text = table(
        text,
        ["操作", "优化前中位 ms", "首次优化后 ms", "当前复测 ms"],
        ["---", "---:", "---:", "---:"],
        [
            [
                TOOLS[r["id"]][0],
                f"{r['beforeMedianMs']:.3f}",
                f"{r['afterMedianMs']:.3f}",
                f"{r['currentMedianMs']:.3f}",
            ]
            for r in evidence["analysisOptimization"]["operations"]
        ],
    )
    text = table(
        text,
        ["操作", "中位 ms", "p95 ms"],
        ["---", "---:", "---:"],
        [[name, *warm(rows[key])] for key, name in WORKFLOW.items() if key in rows],
    )
    if args.check:
        if text != initial:
            raise SystemExit("Inspection tables are out of date")
    else:
        if args.adopt:
            evidence_file.write_text(
                json.dumps(evidence, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
            )
        document.write_text(text)


if __name__ == "__main__":
    main()
