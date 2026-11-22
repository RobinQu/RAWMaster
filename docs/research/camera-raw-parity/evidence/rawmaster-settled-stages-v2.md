# 首次参数的原生定稿与内存

Apple M4 Max，Version 27.0.1 (Build 26A434)。同一张 9504 × 6336 Sony RAW，经 FlashRaw 解码并保留原生纹理。每个进程依次提交全局 LUT 强度、局部曝光、局部色轮的 A/B 六个新值。先走正常交互，再计时从稳定预览请求至完整 2400 × 1600 sRGB RGBA8 缓冲区可读。六个结果的 15,360,000 个字节均与各自既有定稿的 SHA-256 一致。各进程原生纹理首次填充一次，随后五次命中。

同一发行构建启用有界分带后，六次首次定稿耗时的中位数由 392.277 降到 134.304 ms。十次完整有限值检查累计由 1760.845 降到 295.569 ms。进程峰值物理内存从 2,804,074,680 增至 3,282,503,768 字节，增加 456.3 MiB。每项每个值只采集一次，适用于定位首次定稿的成本。两态交替的 20 次热采样另见完整两方对照。 [37 项对照](paired-photo-operators-v2.md)

| 操作 | 状态 | 原路径定稿（ms） | 有界分带定稿（ms） |
| --- | --- | ---: | ---: |
| 全局 LUT 强度 | A | 304.459 | 282.718 |
| 全局 LUT 强度 | B | 221.465 | 86.327 |
| 局部曝光 | A | 387.233 | 106.647 |
| 局部曝光 | B | 397.322 | 78.968 |
| 局部色轮 | A | 452.225 | 161.960 |
| 局部色轮 | B | 495.820 | 168.137 |

## 完成边界和资源占用

原路径将全分辨率浮点 RGBA 转为有限性标记，每个 1024 × 1024 网格块运行 CIAreaMaximum，等待读回标量并清理上下文。原实验在 10 次检查中合计取回 700 次标量。局部路径分别检查全局图和蒙版合成图。 [原路径阶段记录](rawmaster-settled-stages-before-v2.json)

全幅单次 Metal 提交原型使六个新值的中位耗时从 405.543 降至 158.270 ms，峰值物理内存从 2,804,992,160 增至 4,201,384,024 字节。Core Image 在同一提交内保留了全幅中间结果。 [原型对照](rawmaster-settled-stages-whole-surface-control-v2.json) · [全幅原型](rawmaster-settled-stages-whole-surface-v2.json)

发行路径对同一原生标记沿照片宽度分带，每次仍检查全部 60,217,344 个像素，最多允许两个相邻条带同时在队列中。此照片的私有 R8 和共享分组标志共占 4,980,736 字节。工作集为 Core Image 中间图另计每活动带每像素 64 字节的额度，内核还核对 Metal 推荐工作集的余量和实际资源大小。同进程总预约上限 512 MiB，显式纹理与标志上限 128 MiB。推荐工作集不足、额度较小、非整型或非零原点、非支持的复杂配方均走原有检查。统计起点是开始安排第一带，终点包含最后一个 Metal 与 Core Image 任务的完成、标志核验。该阶段嵌套于显影有限值检查，两者的时间不能相加。 [同构建旧路径](rawmaster-settled-stages-serial-control-v2.json) · [有界分带](rawmaster-settled-stages-after-v2.json)

测试在首行、末行、条带边界和非整线程组尾部植入 NaN 和正负无穷，并覆盖非规范有限 alpha、取消、降低预算及畸形写入。验证使用原始浮点有限性算子，已提交 GPU 命令完成后才会释放预留内存。全局或局部配方与源像素不写入遥测，临时纹理与缓冲在检查后释放。 [实现](../../../../Sources/RAWMasterImaging/DevelopmentCanonicalFiniteGPU.swift) · [边界测试](../../../../Tests/RAWMasterImagingTests/CanonicalFiniteGPUTests.swift) · [发行构建执行记录](rawmaster-native-finite-regression-v2.log)

在仓库根目录设置 RAWMASTER_FLASHRAW_LIBRARY 和 RAWMASTER_PERF_BUILD_PATH，然后运行两轮。输出各指向不同的新文件。

```sh
RAWMASTER_CANONICAL_SERIAL_FINITE=1 scripts/performance/run-settled-stage-profile.sh "$RAW" "$NATIVE_JSON" "$SERIAL_JSON" \
  grading-lut-amount light-mask-exposure grading-mask-wheels
scripts/performance/run-settled-stage-profile.sh "$RAW" "$NATIVE_JSON" "$BOUNDED_JSON" \
  grading-lut-amount light-mask-exposure grading-mask-wheels
python3 docs/research/camera-raw-parity/settled_stage_report.py --check
```
