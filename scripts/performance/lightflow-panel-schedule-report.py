#!/usr/bin/env python3
"""Verify and summarize stock LightFlow's released-viewer readback sequence."""

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


HERE = Path(__file__).resolve().parent
EVIDENCE = HERE.parents[1] / "docs/research/camera-raw-parity/evidence"


def report():
    raw = json.loads((EVIDENCE / "lightflow-panel-schedule.json").read_text())
    parameters = HERE / "paired-panel-controls.json"
    specs = json.loads(parameters.read_text())
    features = json.loads((EVIDENCE.parent / "feature-matrix.json").read_text())[
        "features"
    ]
    names = {feature["id"]: feature["name"] for feature in features}
    digest = hashlib.sha256(parameters.read_bytes()).hexdigest()
    if (
        raw["parameterSHA256"] != digest
        or raw["sourceSHA256"] != raw["sourceSHA256After"]
    ):
        raise ValueError("Parameter or source fingerprint mismatch")
    if raw["pixels"] != [2400, 1600] or [r["id"] for r in raw["operations"]] != list(
        specs
    ):
        raise ValueError("Unexpected photo area or operation list")
    lines = []
    all_matches = warm_matches = total = warm_total = 0
    for row in raw["operations"]:
        key = row["id"]
        if row["values"] != specs[key]["values"] or row["fixed"] != specs[key]["fixed"]:
            raise ValueError(f"Wrong recipe for {key}")
        samples = row["samples"]
        final_hashes = [set(), set()]
        for i, sample in enumerate(samples):
            frames = sample["frames"]
            last = frames[-1]
            if not last["fullRes"] or last["provisional"] or last["interactive"]:
                raise ValueError(f"Unsettled final frame for {key}")
            if sample["state"] != i % 2 or sample["phase"] != (
                "first" if i < 2 else "warm"
            ):
                raise ValueError(f"Missing first or warm sample for {key}")
            if (
                sample["schedulerTransitions"][-1]["bits"] != 0
                or sample["idleConfirmedMs"] < last["actionToPixelsMs"]
            ):
                raise ValueError(f"Incomplete stock viewer cycle for {key}")
            exact = next(
                f for f in frames if f["wholeRasterSHA256"] == last["wholeRasterSHA256"]
            )
            start = frames[0]["frameStartAfterDispatchMs"]
            if (
                abs(sample["ms"] - (last["actionToPixelsMs"] - start)) > 0.002
                or abs(
                    sample["renderToFirstExactFinalMs"]
                    - (exact["actionToPixelsMs"] - start)
                )
                > 0.002
            ):
                raise ValueError(f"Invalid readback timing for {key}")
            final_hashes[i % 2].add(last["wholeRasterSHA256"])
        if (
            any(len(group) != 1 for group in final_hashes)
            or final_hashes[0] == final_hashes[1]
        ):
            raise ValueError(f"Different or indistinct full-frame target for {key}")
        warm = samples[2:]
        if len(warm) < 20 or row["status"] != "measured":
            raise ValueError(f"Insufficient verified samples for {key}")
        first_exact = [
            s["frames"][0]["wholeRasterSHA256"] == s["frames"][-1]["wholeRasterSHA256"]
            for s in samples
        ]
        if (
            sum(first_exact[2:]) != row["firstFrameExactFinal"]["warm"]
            or sum(first_exact) != row["firstFrameExactFinal"]["all"]
        ):
            raise ValueError(f"Wrong first/last match count for {key}")
        all_matches += sum(first_exact)
        warm_matches += sum(first_exact[2:])
        total += len(samples)
        warm_total += len(warm)
        first = statistics.median(s["frames"][0]["ms"] for s in warm)
        earliest = statistics.median(s["renderToFirstExactFinalMs"] for s in warm)
        finals = sorted(s["ms"] for s in warm)
        dispatch = statistics.median(s["frames"][-1]["actionToPixelsMs"] for s in warm)
        lines.append(
            f"| {names[key]} | {first:.3f} | {earliest:.3f} | {statistics.median(finals):.3f} | "
            f"{finals[math.ceil(0.95 * len(finals)) - 1]:.3f} | {dispatch:.3f} | {sum(first_exact[2:])}/{len(warm)} |"
        )
    text = f"""# LightFlow 31 项从参数提交到稳定画面的时间

同一张 9504 × 6336 Sony ARW 在 M4 Max 上按原版默认缓存运行，显示图为完整 2400 × 1600 sRGB RGBA8。31 个操作分别交替提交两种参数，每项保留两个初次输入和二十个暖态输入。对每一个操作，同一状态的最终画面均逐字一致，两个状态产生不同的全幅像素。[原始逐帧时间、全部输出指纹和参数文件指纹](lightflow-panel-schedule.json)

原版 Worker 在动画帧调用 `compileDemanded(4)` 和 `viewerTick`。本次输入已释放，无遮挡。Rust 的绘制位触发 `viewerFrame`，GPU 完成后调用 `viewerDone`，下一个动画帧可请求更精细的画面。所有 {total} 次输入均产生两帧。全幅 15,360,000 字节相同的首帧有 {all_matches}/{total} 次，暖态有 {warm_matches}/{warm_total} 次。逐帧数据记录互动标志、分辨率层级、实际细节密度、像素数及最终空闲时刻。从原版公共 JS 接口返回的完整缓冲可直接在 CPU 读取。[原版发布包和后台驱动说明](lightflow-engine.md)

首缓冲、最早整幅匹配、稳定缓冲三列均从首次调用原版 `viewerFrame` 开始计时。最早匹配要求整幅 RGBA8 与最后一帧的 SHA-256 相同。稳定缓冲列计至原版查看器要求的最后一帧读回。最后一项时间从参数提交起算，包含等待首次动画帧的时间。所有散列、ROI 和结果核验均在定时部分结束后执行。以下使用暖态数据，时间单位为毫秒，p95 按最近秩计算。

| 操作 | 首缓冲中位 | 最早整幅匹配中位 | 稳定缓冲中位 | 稳定缓冲 p95 | 提交至稳定中位 | 首末一致 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
""" + "\n".join(lines)
    return (
        text
        + """

在仓库根目录使用 `scripts/performance/benchmark-lightflow.py` 指定 `--panel-readback --panel-schedule --samples 20`，加上原片、新输出路径和独立后台 Chromium 的 `--chrome` 路径即可复跑。原先每次直接调用一帧的 31 项测量可用于对照调度差异。[直接调用时的逐项记录](lightflow-panel-readback.json)
"""
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = EVIDENCE / "lightflow-panel-schedule.md"
    current = report()
    if args.check:
        if path.read_text() != current:
            raise SystemExit("Stock scheduler report is out of date")
    else:
        path.write_text(current)
