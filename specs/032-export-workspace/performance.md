# 导出性能基线

2026-11-22，Apple M4 Max 16 核、128 GiB 内存，macOS 27.0.1，内置 APFS。同输入、同机器测量 RAWMaster 新版分页资料库的导出工作台、AlcedoStudio 0.3.6 的 Metal 发布版导出链路，以及 LightFlow 20261111155800-2d41ab1 在 Chromium 157 的实际下载链路。每项先预热一轮，再测三轮，中位数见下表。[所有单轮数据、成品规格、字节及内存](benchmark/baseline.json)

## 从提交到成品可用

每格为整批耗时，括号内为第一个可交付文件的耗时，单位秒。三款均输出 JPEG 8 位、长边 2048、质量 90、sRGB ICC、净图、无描述性元数据。JPEG 源是从仓库照片制备的不同内容 4000 × 2666 文件。RAW 源是 2400 × 1600、无预览的 Bayer DNG。三款均在计时前完成导入。

| 输入 | RAWMaster | AlcedoStudio | LightFlow |
| --- | ---: | ---: | ---: |
| JPEG × 1 | 0.076（0.076） | 0.061（0.060） | 0.234（0.223） |
| JPEG × 20 | 0.503（0.078） | 0.806（0.088） | 4.081（4.074） |
| JPEG × 200 | 4.684（0.079） | 8.063（0.309） | 50.543（50.543） |
| Bayer DNG × 1 | 0.057（0.057） | 0.046（0.046） | 0.218（0.185） |
| Bayer DNG × 20 | 0.357（0.058） | 0.564（0.106） | 4.711（4.691） |

五项的整批中位用时均在较快参照的 1.25 倍以内，首件均在 1.5 倍以内。200 张时 RAWMaster、AlcedoStudio、LightFlow 分别约为 42.7、24.8、4.0 张/秒。LightFlow 批量通过一个 ZIP 交付，表格统计 ZIP 到达。浏览器队列中 200 张的第一幅 JPEG 编码完成中位数为约 0.21 秒。原生两款直接写逐张文件。

各轮读回全部输出与 ICC。JPEG 产物均为 2048 × 1365。DNG 在 AlcedoStudio 读回 2048 × 1363，另两款为 2048 × 1365。不同显影和 JPEG 模块采用自己的有效区域、缩放和量化策略。200 张 JPEG 的数据量分别约为 79.13 MiB、78.48 MiB、87.09 MiB（ZIP）。RAWMaster 的 SwiftUI 测试宿主为 Debug，Rust 库为 Release。样本中最大 RAW 批次为 20 张合成 Bayer DNG，大像素真实 RAW 与不同编辑复杂度属于后续性能覆盖。[AlcedoStudio 发布版](https://github.com/zidage/AlcedoStudio/releases/tag/v0.3.6) · [LightFlow](https://lightflow.dev/)

200 张 JPEG 场景，报告中 RAWMaster 进程累计峰值的中位数为 798 MiB，AlcedoStudio 与 Chromium 的采样进程树峰值中位数约为 1,086 MiB 和 2,574 MiB。采样口径保留在 JSON 中，方便同一工具后续复测。

## 复跑

使用同一份输入目录和新目的地。竞品脚本依赖 Python、Pillow、websocket-client，LightFlow 使用保存的发布快照和 Chromium arm64。DNG 可以沿用调研用的 `CFA-export.dng`。[竞品运行与读回脚本](benchmark/competitors.py) · [实际 SwiftUI 工作台测试](../../Tests/RAWMasterUITests/ExportPerformanceTests.swift)

```sh
python3 specs/032-export-workspace/benchmark/competitors.py fixtures "$benchmark_dir" --raw "$bayer_dng"
python3 specs/032-export-workspace/benchmark/competitors.py lightflow "$benchmark_dir" --site "$site_snapshot" --chrome "$chrome"
python3 specs/032-export-workspace/benchmark/competitors.py alcedo "$benchmark_dir"
RAWMASTER_EXPORT_BENCH_ROOT="$benchmark_dir" swift test --filter ExportPerformanceTests
```

在新版资料库模式下，原生测试从项目导出入口冻结全体分页 ID，先检查未挂载照片的成片预览，再比较 1、20、200 张的产物。最长耗时统计从提交成片起，导入和建立工作台范围作为独立的步骤。
