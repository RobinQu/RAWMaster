# 已驻留 RAW 全局阶段的有限性证明

在 Apple M4 Max 上，用同一可执行文件分两次打开同一张 9504 × 6336 Sony RAW。每个进程首次提交 37 项的 A/B 配方，分别请求交互和稳定预览。两次都以发行归档中的 74 个完整最终 SHA-256 作参照。两轮的全部 148 张稳定预览逐字节通过，每张为 2400 × 1600、15,360,000 字节的不透明 sRGB RGBA8。两进程另有 74/74 张交互预览逐字节相同。

原生有限性扫描由 115 次减至 73 次。42 个首次状态各省去一次完整扫描，共少检查 2,529,128,448 个像素。这 42 个状态的稳定请求中位耗时由 153.250 降至 143.128 ms。全部 74 次的中位数为 110.461 与 93.671 ms。两进程的峰值物理内存分别为 4,529,130,160 和 4,477,717,168 字节。每个状态只采样一次。

计时从稳定请求前开始，到稳定预览的完整 sRGB8 像素可供 CPU 读取为止。交互预览的哈希和遥测在稳定请求发出前完成。发版测试另行记录从第一次交互调用到最终照片的墙钟时间。 [发行版逐项对照](paired-photo-operators-v2.md) · [同包强制扫描](rawmaster-global-finite-rescan-v1.json) · [同包证明复用](rawmaster-global-finite-reuse-v1.json)

| 控件 | 强制扫描 A / B（ms） | 允许复用 A / B（ms） | A / B 省去的全幅扫描 |
| --- | ---: | ---: | ---: |
| color-bw-treatment | 119.575 / 65.048 | 116.589 / 68.435 | 0 / 0 |
| color-mask-hue | 69.756 / 80.569 | 64.509 / 69.019 | 1 / 1 |
| color-mask-saturation | 74.045 / 78.254 | 67.813 / 68.660 | 1 / 1 |
| color-mask-temp | 142.241 / 154.901 | 143.496 / 145.357 | 1 / 1 |
| color-mask-tint | 162.146 / 177.983 | 147.001 / 145.724 | 1 / 1 |
| color-wb-as-shot | 125.600 / 110.250 | 136.204 / 110.962 | 0 / 1 |
| color-wb-presets | 119.159 / 0.587 | 118.024 / 0.708 | 0 / 0 |
| curve-channels | 71.303 / 69.346 | 71.299 / 73.727 | 0 / 0 |
| curve-mask-curve | 145.119 / 153.286 | 154.038 / 160.011 | 1 / 1 |
| curve-point | 80.770 / 74.543 | 86.593 / 80.660 | 0 / 0 |
| detail-mask-noise | 593.646 / 634.199 | 477.729 / 451.160 | 1 / 1 |
| detail-mask-preview | 366.553 / 481.124 | 355.098 / 337.755 | 0 / 1 |
| detail-mask-sharpness | 573.342 / 562.675 | 419.881 / 426.795 | 1 / 1 |
| detail-nr-color-detail | 530.935 / 512.030 | 541.230 / 504.302 | 0 / 0 |
| detail-nr-lum-contrast | 517.433 / 512.052 | 538.240 / 548.693 | 0 / 0 |
| effects-dehaze | 2251.760 / 2261.665 | 2109.167 / 2145.481 | 1 / 1 |
| effects-mask-clarity | 693.980 / 709.089 | 505.612 / 518.377 | 1 / 1 |
| effects-mask-grain | 510.344 / 551.683 | 316.908 / 308.894 | 1 / 1 |
| effects-mask-texture | 800.341 / 824.549 | 489.949 / 516.780 | 1 / 1 |
| effects-pcv-style | 258.997 / 259.196 | 68.579 / 53.701 | 1 / 1 |
| grading-balance | 77.515 / 69.905 | 76.094 / 71.167 | 0 / 0 |
| grading-blending | 73.254 / 71.645 | 72.631 / 69.930 | 0 / 0 |
| grading-luminance | 0.836 / 80.795 | 0.671 / 70.230 | 0 / 0 |
| grading-lut-amount | 74.997 / 71.064 | 66.511 / 74.681 | 0 / 0 |
| grading-lut-manage | 104.545 / 110.672 | 100.750 / 110.438 | 0 / 0 |
| grading-lut-mask | 157.940 / 149.935 | 145.911 / 142.761 | 1 / 1 |
| grading-lut-select | 89.377 / 70.204 | 77.497 / 79.085 | 0 / 0 |
| grading-lut-stack | 0.736 / 140.670 | 0.656 / 147.536 | 0 / 0 |
| grading-mask-wheels | 155.697 / 153.214 | 145.129 / 141.722 | 1 / 1 |
| light-clipping-indicators | 56.886 / 118.742 | 61.476 / 119.605 | 0 / 0 |
| light-clipping-modifier | 0.685 / 124.057 | 0.619 / 116.507 | 0 / 0 |
| light-mask-blacks | 79.922 / 76.900 | 77.749 / 70.595 | 1 / 1 |
| light-mask-contrast | 74.619 / 72.121 | 70.419 / 70.657 | 1 / 1 |
| light-mask-exposure | 78.381 / 75.299 | 67.719 / 70.746 | 1 / 1 |
| light-mask-highlights | 72.461 / 75.081 | 70.763 / 76.322 | 1 / 1 |
| light-mask-shadows | 81.257 / 75.067 | 69.264 / 74.698 | 1 / 1 |
| light-mask-whites | 79.162 / 72.987 | 70.002 / 68.653 | 1 / 1 |

## 有效范围

FlashRaw 解码和 F16 转换全部完成后，缓存条目拥有一个不可变的私有原生纹理。正常全局处理结束于蒙版合成之前。仅当该阶段的输出仍是驻留条目的同一 CIImage 对象，且此前相同阶段确实完成了全原图有限性验证时，后续请求才可使用这个布尔值。改变白平衡、曝光、全局 LUT 等产生新图节点，正常执行全幅检查。蒙版最终合成和任何独立输出保留各自的检查。

一个条目仅新增一位状态。退役、释放后重建及源替换分别受池锁、具体条目和对象身份约束。失败、取消和未完成的并发首扫不会发布证明。CPU 命中在监控中记录查找时长，实际处理像素为 0。 [实现](../../../../Sources/RAWMasterImaging/FlashRawCanonicalTexturePool.swift) · [并发与失效测试](../../../../Tests/RAWMasterImagingTests/NativeGlobalFiniteProofTests.swift) · [回归记录](rawmaster-global-finite-unit-v1.log)

两张不同实拍 Sony RAW（9504 × 6336 与 8640 × 5760）交错提交局部曝光、全局 LUT 和局部色轮。两源分别完成首次扫描。第二次局部曝光均命中，全局 LUT 均重新扫描。关闭 A 再重开后，A 的下一个局部状态重新扫描，仍驻留的 B 继续命中。两种设置下 10 张照片的完整 SHA 逐一相同，同一配方的两源照片彼此不同。 [双源强制扫描](rawmaster-global-finite-two-source-rescan-v1.json) · [双源复用](rawmaster-global-finite-two-source-reuse-v1.json)

## 复现

设置 RAWMASTER_FLASHRAW_LIBRARY 和 RAWMASTER_PERF_BUILD_PATH。每次使用新的输出文件。脚本为每个实验链接一次 Release 程序，依次用同一程序运行两种设置，期间独占同一 GPU。本次两边均沿用归档时的去朦胧导图实现。

```sh
export RAWMASTER_NATIVE_DEHAZE_GUIDE=0
scripts/performance/run-settled-stage-profile.sh --rescan-and-reuse "$BEFORE" "$RAW" "$REF" "$AFTER" --all-archived-controls
scripts/performance/run-settled-stage-profile.sh --rescan-and-reuse "$TWO_BEFORE" --two-sources "$RAW" "$SECOND_RAW" "$REF" "$TWO_AFTER"
python3 docs/research/camera-raw-parity/resident_global_proof_report.py --check
```
