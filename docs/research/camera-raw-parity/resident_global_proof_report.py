"""Validate real RAW pixel parity, per-state full-sensor scan counts, and two-source proof isolation."""
import argparse
import hashlib
import json
from pathlib import Path
from statistics import median

from paired_photo_operator_report import RAW, require, valid_digest

FOLDER = Path(__file__).resolve().parent / "evidence"
REFERENCE = "7d655a96388a1defed7aa075dcb5e3abd0fdd96bbf1725faa21faa54eb57fda7"
SENSOR = 9504 * 6336
PREFIX = "rawmaster-global-finite-"
SECOND = "4e7e80f4e34e3f9d2b77c93c4c0864fb2a8b950df69e615b5e99b7bad6a9739f"
SCAN = "显影有限值检查"
REUSE = "NativeGlobalFiniteReuse"


def read(name):
    return json.loads((FOLDER / f"{PREFIX}{name}-v1.json").read_bytes())


def archive():
    for name in ("rawmaster-photo-operators-v2.json", "rawmaster-photo-operators-release4-v2.json"):
        file = FOLDER / name
        if file.is_file() and hashlib.sha256(file.read_bytes()).hexdigest() == REFERENCE:
            return json.loads(file.read_bytes())
    raise ValueError("The source release-4 raster archive is missing")


def events(records, sensor_pixels=SENSOR):
    scans = [r for r in records if r["operation"] == SCAN and r["pixels"] == sensor_pixels]
    hits = [r for r in records if r["operation"] == REUSE]
    require(all(r["boundary"] == "GPU 完成" for r in scans), "A native scan lacks a completion boundary")
    require(all(r["boundary"] == "API 返回" and r["pixels"] == 0 for r in hits),
            "A cached CPU decision was misclassified as physical pixel work")
    return len(scans), len(hits)


def primary(reference, rescan):
    data = read("rescan" if rescan else "reuse")
    require(data["verified"] and data["sourceSHA256"] == data["sourceSHA256After"] == RAW
            and data["baselineSHA256"] == REFERENCE and data["sourceSize"] == [9504, 6336]
            and data["pixels"] == [2400, 1600] and data["rescanResidentGlobalOverride"] is rescan
            and data["serialFiniteOverride"] is False
            and valid_digest(data["binarySHA256"]) and data["processPeakPhysicalFootprintBytes"] > 0, "Invalid 37-row source")
    expected = {r["id"]: r["firstStateFullFrameDigests"] for r in reference["operations"]}
    require(len(expected) == 37 and [r["id"] for r in data["operations"]] == list(expected), "Wrong operator set")
    values = {}
    for row in data["operations"]:
        key = row["id"]
        samples = row["samples"]
        require([(s["state"], s["quality"]) for s in samples] ==
                [(i, q) for i in range(2) for q in ("interactive", "settled")], key)
        for i, sample in enumerate(samples):
            if sample["quality"] != "settled":
                continue
            state = sample["state"]
            require(not sample["approximate"] and sample["digest"] == expected[key][state]
                    and sample["beginNs"] < sample["frameNs"] <= sample["endNs"]
                    and abs(sample["ms"] - (sample["endNs"] - sample["beginNs"]) / 1e6) < .001, key)
            scans, hits = events(sample["stages"])
            require(hits == 0 if rescan else hits <= 1, key)
            values[key, state] = {"ms": sample["ms"], "scans": scans, "hits": hits,
                                  "first": samples[i - 1]["digest"], "stable": sample["digest"]}
    return data, values


def two_sources(reference):
    before, after = read("two-source-rescan"), read("two-source-reuse")
    require(before["binarySHA256"] == after["binarySHA256"] and valid_digest(after["binarySHA256"]), "Different dual-source binaries")
    expected = {r["id"]: r["firstStateFullFrameDigests"] for r in reference["operations"]}
    for mode, data in enumerate((before, after)):
        require(data["archiveSHA256"] == REFERENCE and data["sourceSHA256"] == data["sourceSHA256After"] == [RAW, SECOND]
                and data["pixels"] == [2400, 1600] and data["rescanResidentGlobalOverride"] is (mode == 0), "Dual-source metadata")
    left, right = before["operations"], after["operations"]
    require(len(left) == len(right) == 10, "Dual-source step count")
    expected_hits = [0, 0, 1, 1, 0, 0, 1, 1, 0, 1]
    for i, (a, b) in enumerate(zip(left, right)):
        require(all(a[k] == b[k] for k in ["source", "step", "state", "id", "digest"]) and valid_digest(b["digest"])
                and b["source"] == i % 2 and b["step"] == i // 2, "Reopen/dual-source digest mismatch")
        if not b["source"]:
            require(b["digest"] == expected[b["id"]][b["state"]], "Wrong primary archive digest")
        else:
            require(b["digest"] != right[i - 1]["digest"], "Distinct RAW sources share a raster")
        pixels = (SENSOR, 8640 * 5760)[b["source"]]
        scans, oldhits = events(a["events"], pixels)
        actual, hits = events(b["events"], pixels)
        require(oldhits == 0 and hits == expected_hits[i] and scans - actual == hits, "Wrong dual-source scan evidence")
    require(right[0]["generation"] != right[8]["generation"] and right[1]["generation"] == right[9]["generation"],
            "The intended source was not reopened")


def render():
    ref = archive()
    left, a = primary(ref, True)
    right, b = primary(ref, False)
    require(left["binarySHA256"] == right["binarySHA256"] and left["gpu"] == right["gpu"] and left["os"] == right["os"]
            and left["nativeDehazeGuideAllowed"] is right["nativeDehazeGuideAllowed"] is False, "Controlled runs differ")
    affected = [key for key in a if b[key]["hits"]]
    require(bool(affected) and all(a[k]["scans"] - b[k]["scans"] == b[k]["hits"] and a[k]["stable"] == b[k]["stable"]
                                   for k in a), "Every CPU hit must displace exactly one original full native scan")
    two_sources(ref)
    total = lambda records, column: sum(r[column] for r in records.values())
    ms = lambda values, keys: median(values[k]["ms"] for k in keys)
    rows = [r["id"] for r in ref["operations"]]
    lines = ["# 已驻留 RAW 全局阶段的有限性证明", "",
        f"在 {right['gpu']} 上，用同一可执行文件分两次打开同一张 9504 × 6336 Sony RAW。每个进程首次提交 37 项的 A/B 配方，分别请求交互和稳定预览。"
        "两次都以发行归档中的 74 个完整最终 SHA-256 作参照。"
        "两轮的全部 148 张稳定预览逐字节通过，每张为 2400 × 1600、15,360,000 字节的不透明 sRGB RGBA8。"
        f"两进程另有 {sum(a[k]['first'] == b[k]['first'] for k in a)}/74 张交互预览逐字节相同。", "",
        f"原生有限性扫描由 {total(a,'scans')} 次减至 {total(b,'scans')} 次。{len(affected)} 个首次状态各省去一次完整扫描，共少检查 {len(affected) * SENSOR:,} 个像素。"
        f"这 {len(affected)} 个状态的稳定请求中位耗时由 {ms(a,affected):.3f} 降至 {ms(b,affected):.3f} ms。全部 74 次的中位数为 {ms(a,a):.3f} 与 {ms(b,b):.3f} ms。"
        f"两进程的峰值物理内存分别为 {left['processPeakPhysicalFootprintBytes']:,} 和 {right['processPeakPhysicalFootprintBytes']:,} 字节。每个状态只采样一次。", "",
        "计时从稳定请求前开始，到稳定预览的完整 sRGB8 像素可供 CPU 读取为止。交互预览的哈希和遥测在稳定请求发出前完成。"
        "发版测试另行记录从第一次交互调用到最终照片的墙钟时间。"
        " [发行版逐项对照](paired-photo-operators-v2.md) · [同包强制扫描](rawmaster-global-finite-rescan-v1.json) · [同包证明复用](rawmaster-global-finite-reuse-v1.json)", "",
        "| 控件 | 强制扫描 A / B（ms） | 允许复用 A / B（ms） | A / B 省去的全幅扫描 |",
        "| --- | ---: | ---: | ---: |"]
    for name in rows:
        line = [name] + [" / ".join(f"{record[name,s]['ms']:.3f}" for s in (0,1)) for record in (a,b)]
        line.append(" / ".join(str(b[name,s]["hits"]) for s in (0,1)))
        lines.append("| " + " | ".join(line) + " |")
    lines += ["", "## 有效范围", "",
        "FlashRaw 解码和 F16 转换全部完成后，缓存条目拥有一个不可变的私有原生纹理。正常全局处理结束于蒙版合成之前。仅当该阶段的输出仍是驻留条目的同一 CIImage 对象，且此前相同阶段确实完成了全原图有限性验证时，后续请求才可使用这个布尔值。改变白平衡、曝光、全局 LUT 等产生新图节点，正常执行全幅检查。蒙版最终合成和任何独立输出保留各自的检查。", "",
        "一个条目仅新增一位状态。退役、释放后重建及源替换分别受池锁、具体条目和对象身份约束。失败、取消和未完成的并发首扫不会发布证明。CPU 命中在监控中记录查找时长，实际处理像素为 0。"
        " [实现](../../../../Sources/RAWMasterImaging/FlashRawCanonicalTexturePool.swift) · [并发与失效测试](../../../../Tests/RAWMasterImagingTests/NativeGlobalFiniteProofTests.swift) · [回归记录](rawmaster-global-finite-unit-v1.log)", "",
        "两张不同实拍 Sony RAW（9504 × 6336 与 8640 × 5760）交错提交局部曝光、全局 LUT 和局部色轮。两源分别完成首次扫描。第二次局部曝光均命中，全局 LUT 均重新扫描。关闭 A 再重开后，A 的下一个局部状态重新扫描，仍驻留的 B 继续命中。"
        "两种设置下 10 张照片的完整 SHA 逐一相同，同一配方的两源照片彼此不同。 [双源强制扫描](rawmaster-global-finite-two-source-rescan-v1.json) · [双源复用](rawmaster-global-finite-two-source-reuse-v1.json)", "",
        "## 复现", "",
        "设置 RAWMASTER_FLASHRAW_LIBRARY 和 RAWMASTER_PERF_BUILD_PATH。每次使用新的输出文件。脚本为每个实验链接一次 Release 程序，依次用同一程序运行两种设置，期间独占同一 GPU。本次两边均沿用归档时的去朦胧导图实现。", "",
        "```sh",
        'export RAWMASTER_NATIVE_DEHAZE_GUIDE=0',
        'scripts/performance/run-settled-stage-profile.sh --rescan-and-reuse "$BEFORE" "$RAW" "$REF" "$AFTER" --all-archived-controls',
        'scripts/performance/run-settled-stage-profile.sh --rescan-and-reuse "$TWO_BEFORE" --two-sources "$RAW" "$SECOND_RAW" "$REF" "$TWO_AFTER"',
        "python3 docs/research/camera-raw-parity/resident_global_proof_report.py --check", "```", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = FOLDER / f"{PREFIX}v1.md"
    report = render()
    if args.check:
        require(path.read_text() == report, "The resident proof report differs from its captures")
    else:
        path.write_text(report)
