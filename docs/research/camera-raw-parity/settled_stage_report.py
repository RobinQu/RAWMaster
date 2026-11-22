"""Verify full-sensor, first-use stage and memory measurements and render the supporting report."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import statistics

from paired_photo_operator_report import RAW, valid_digest, require

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / "evidence"
CONTROLS = {
    "grading-lut-amount": "全局 LUT 强度",
    "light-mask-exposure": "局部曝光",
    "grading-mask-wheels": "局部色轮",
}
SAMPLES = ("A", "B")
NATIVE_COUNT = 9504 * 6336
ORIGINAL_ARCHIVE = "6dc62be8c5baa120e544482fbe950a75651de8f1f7c8da4dd66d0d2b061573d3"


def capture(name):
    return EVIDENCE / f"rawmaster-settled-stages-{name}-v2.json"


def read_capture(name, reference, serial):
    data = json.loads(capture(name).read_bytes())
    require(data["verified"] is True and data["sourceSHA256"] == data["sourceSHA256After"] == RAW
            and data["sourceSize"] == [9504, 6336] and data["pixels"] == [2400, 1600]
            and data["baselineSHA256"] in (ORIGINAL_ARCHIVE, hashlib.sha256(reference.read_bytes()).hexdigest())
            and data["serialFiniteOverride"] is serial and valid_digest(data["binarySHA256"]), name)
    baseline = {r["id"]: r for r in json.loads(reference.read_bytes())["operations"]}
    require([r["id"] for r in data["operations"]] == list(CONTROLS), name)
    times, finite, scratch = {}, [], []
    fills = hits = 0
    for row in data["operations"]:
        key = row["id"]
        samples = row["samples"]
        require([(s["state"], s["quality"]) for s in samples] ==
                [(state, quality) for state in (0, 1) for quality in ("interactive", "settled")], key)
        for sample in samples:
            if sample["quality"] != "settled":
                continue
            state = sample["state"]
            require(sample["approximate"] is False and sample["digest"] == baseline[key]["firstStateFullFrameDigests"][state]
                    and sample["beginNs"] < sample["frameNs"] <= sample["endNs"]
                    and abs(sample["ms"] - (sample["endNs"] - sample["beginNs"]) / 1e6) < .001, key)
            times[key, state] = sample["ms"]
            fills += sample["nativePoolFills"]
            hits += sample["nativePoolHits"]
            full = [s for s in sample["stages"] if s["operation"] == "显影有限值检查"]
            gpu = [s for s in sample["stages"] if s["operation"] == "NativeFiniteReduction"]
            require(len(full) == (1 if key == "grading-lut-amount" else 2)
                    and len(gpu) == (0 if serial else len(full)), key)
            for stage in full + gpu:
                require(stage["pixels"] == NATIVE_COUNT and stage["boundary"] == "GPU 完成"
                        and stage["queue"] == "Metal GPU" and stage["ms"] > 0, key)
            finite.extend(s["ms"] for s in full)
            scratch.extend(s["bytes"] for s in gpu)
    require(fills == 1 and hits == 5 and len(finite) == 10 and data["processPeakPhysicalFootprintBytes"] > 0, name)
    require(serial or len(set(scratch)) == 1 and 0 < scratch[0] <= 128 * 1024**2, name)
    return dict(binary=data["binarySHA256"], gpu=data["gpu"], os=data["os"], times=times,
                median=statistics.median(times.values()), finite=sum(finite), scratch=max(scratch, default=0),
                peak=data["processPeakPhysicalFootprintBytes"])


def generate():
    reference = EVIDENCE / "rawmaster-photo-operators-v2.json"
    old = read_capture("serial-control", reference, True)
    bounded = read_capture("after", reference, False)
    prototypeOld = read_capture("whole-surface-control", reference, True)
    prototype = read_capture("whole-surface", reference, False)
    require(old["binary"] == bounded["binary"] and prototype["binary"] == prototypeOld["binary"]
            and old["gpu"] == bounded["gpu"] == prototype["gpu"]
            and old["os"] == bounded["os"] == prototype["os"], "Build or machine differs")
    lines = [
        "# 首次参数的原生定稿与内存", "",
        f"{old['gpu']}，{old['os']}。同一张 9504 × 6336 Sony RAW，经 FlashRaw 解码并保留原生纹理。"
        "每个进程依次提交全局 LUT 强度、局部曝光、局部色轮的 A/B 六个新值。先走正常交互，再计时从稳定预览请求至完整 2400 × 1600 sRGB RGBA8 缓冲区可读。"
        "六个结果的 15,360,000 个字节均与各自既有定稿的 SHA-256 一致。各进程原生纹理首次填充一次，随后五次命中。", "",
        f"同一发行构建启用有界分带后，六次首次定稿耗时的中位数由 {old['median']:.3f} 降到 {bounded['median']:.3f} ms。"
        f"十次完整有限值检查累计由 {old['finite']:.3f} 降到 {bounded['finite']:.3f} ms。"
        f"进程峰值物理内存从 {old['peak']:,} 增至 {bounded['peak']:,} 字节，增加 {(bounded['peak']-old['peak'])/1024**2:.1f} MiB。"
        "每项每个值只采集一次，适用于定位首次定稿的成本。两态交替的 20 次热采样另见完整两方对照。 [37 项对照](paired-photo-operators-v2.md)", "",
        "| 操作 | 状态 | 原路径定稿（ms） | 有界分带定稿（ms） |",
        "| --- | --- | ---: | ---: |",
    ]
    for key, label in CONTROLS.items():
        for state, name in enumerate(SAMPLES):
            lines.append(f"| {label} | {name} | {old['times'][key, state]:.3f} | {bounded['times'][key, state]:.3f} |")
    lines += ["", "## 完成边界和资源占用", "",
        "原路径将全分辨率浮点 RGBA 转为有限性标记，每个 1024 × 1024 网格块运行 CIAreaMaximum，等待读回标量并清理上下文。"
        "原实验在 10 次检查中合计取回 700 次标量。局部路径分别检查全局图和蒙版合成图。 [原路径阶段记录](rawmaster-settled-stages-before-v2.json)", "",
        f"全幅单次 Metal 提交原型使六个新值的中位耗时从 {prototypeOld['median']:.3f} 降至 {prototype['median']:.3f} ms，"
        f"峰值物理内存从 {prototypeOld['peak']:,} 增至 {prototype['peak']:,} 字节。Core Image 在同一提交内保留了全幅中间结果。"
        " [原型对照](rawmaster-settled-stages-whole-surface-control-v2.json) · [全幅原型](rawmaster-settled-stages-whole-surface-v2.json)", "",
        f"发行路径对同一原生标记沿照片宽度分带，每次仍检查全部 {NATIVE_COUNT:,} 个像素，最多允许两个相邻条带同时在队列中。"
        f"此照片的私有 R8 和共享分组标志共占 {bounded['scratch']:,} 字节。"
        "工作集为 Core Image 中间图另计每活动带每像素 64 字节的额度，内核还核对 Metal 推荐工作集的余量和实际资源大小。"
        "同进程总预约上限 512 MiB，显式纹理与标志上限 128 MiB。推荐工作集不足、额度较小、非整型或非零原点、非支持的复杂配方均走原有检查。"
        "统计起点是开始安排第一带，终点包含最后一个 Metal 与 Core Image 任务的完成、标志核验。"
        "该阶段嵌套于显影有限值检查，两者的时间不能相加。 [同构建旧路径](rawmaster-settled-stages-serial-control-v2.json) · [有界分带](rawmaster-settled-stages-after-v2.json)", "",
        "测试在首行、末行、条带边界和非整线程组尾部植入 NaN 和正负无穷，并覆盖非规范有限 alpha、取消、降低预算及畸形写入。"
        "验证使用原始浮点有限性算子，已提交 GPU 命令完成后才会释放预留内存。全局或局部配方与源像素不写入遥测，临时纹理与缓冲在检查后释放。 "
        "[实现](../../../../Sources/RAWMasterImaging/DevelopmentCanonicalFiniteGPU.swift) · [边界测试](../../../../Tests/RAWMasterImagingTests/CanonicalFiniteGPUTests.swift) · [发行构建执行记录](rawmaster-native-finite-regression-v2.log)", "",
        "在仓库根目录设置 RAWMASTER_FLASHRAW_LIBRARY 和 RAWMASTER_PERF_BUILD_PATH，然后运行两轮。输出各指向不同的新文件。", "",
        "```sh", 'RAWMASTER_CANONICAL_SERIAL_FINITE=1 scripts/performance/run-settled-stage-profile.sh "$RAW" "$NATIVE_JSON" "$SERIAL_JSON" \\',
        "  grading-lut-amount light-mask-exposure grading-mask-wheels", 'scripts/performance/run-settled-stage-profile.sh "$RAW" "$NATIVE_JSON" "$BOUNDED_JSON" \\',
        "  grading-lut-amount light-mask-exposure grading-mask-wheels",
        "python3 docs/research/camera-raw-parity/settled_stage_report.py --check", "```", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = generate()
    path = EVIDENCE / "rawmaster-settled-stages-v2.md"
    if args.check:
        require(path.read_text() == result, "Stage report differs from the measurements")
    else:
        path.write_text(result)
