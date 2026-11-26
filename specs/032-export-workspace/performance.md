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

## 逐张成本与图片内容无关（2026-11-26）

为定位 200 张 JPEG 批次为何比合并基线慢，用同一台机器、同一入口、同一 2048 长边 / q0.9 配置做了对照：把 200 张源图换成 **64×64** 的同名 JPEG，其余不变。

| 输入 | 200 张整批 |
| --- | ---: |
| 2400×1600 JPEG | 8.47 / 9.47 s |
| **64×64 JPEG** | **8.84 / 9.62 s** |

两者相同。也就是说：缩图、重采样、编码、写盘的数据量在这一档完全不构成成本；**整批时间由每张的固定开销决定**（约 30–48 ms/张，随机器负载浮动）。同一轮里 1 张为 0.05–0.06 s、20 张为 0.62–0.70 s，与「200 × 固定开销」一致。

已排除的两个假设：

- **不是调度往返次数。** 把 `publish` 与 `acknowledge` 合成一个事务（每张 3 次调度往返降为 2 次）后交替 A/B：合并 9.89 / 8.51 / 9.17 s，未合并 9.23 / 9.01 / 8.62 s，差异在噪声内。改动已撤回。
- **不是 SQLite 的提交持久化。** 把调度连接改为 `synchronous=NORMAL` 后逐张计时无变化。改动已撤回。

剩余嫌疑集中在每张产出文件的多次落盘与 fsync（私有暂存、标记文件、最终文件，以及目录同步）。下一步用进程采样把时间归到具体调用，再决定合并哪几次写入；单纯减少目录事务已被证明无效。

诊断入口默认关闭，仅在 `RAWMASTER_EXPORT_TIMING=1` 时按批打印 prepare／publish／acknowledge／export 的分项累计：

```sh
RAWMASTER_EXPORT_TIMING=1 RAWMASTER_EXPORT_BENCH_ROOT="$PWD/output/performance/export-bench" \
  swift test -c release --filter ExportPerformanceTests
```

注意：分项累计包含 `ProcessingAdmission` 的许可等待，不能直接当作单项耗时；判断瓶颈以整批墙钟与采样为准。

## fsync 复核：它确实是每张固定开销的主因（2026-11-26 修正）

上一版这一节把 fsync 排除了，结论是错的。错在两个口径：

1. 微基准用的是 Swift/Python 的 `fsync(2)`，而 macOS 上真正要求驱动器刷缓存的是 `fcntl(F_FULLFSYNC)`。同一个 700 KB 文件、同一卷：`fsync(2)` **0.23 ms**，`F_FULLFSYNC` **4.99 ms**，差 22 倍。
2. A/B 改的是 SQLite 的 `synchronous=NORMAL`。SQLite 在 macOS 上即使 `synchronous=FULL`，默认也只调用 `fsync(2)`；只有 `PRAGMA fullfsync=ON` 才升级为 `F_FULLFSYNC`。实测 200 次自动提交：默认 **8.3 ms（0.042 ms/次）**，`fullfsync=ON` **896 ms（4.48 ms/次）**。所以改 `synchronous` 根本碰不到导出路径里的 Rust `sync_all`。

Rust 的 `std::fs::File::sync_all` 在 Apple 目标上就是 `fcntl(F_FULLFSYNC)`（工具链 `library/std/src/sys/fs/unix.rs` 可查）。导出的发布路径大量使用它。

给 `Modules/LibraryCatalog/src/scheduler` 的每个 `sync_all` 套上 `RAWMASTER_SYNC_TIMING=1` 可开关的计时后，跑一遍 442 张（221 张 × 预热+计时两轮）的批量导出，得到每张的同步次数：

| 调用点 | 每张次数 | 平均耗时 |
| --- | ---: | ---: |
| `hash-file`（暂存/最终校验重复哈希） | 3 | 5.29 ms |
| `stage-dir` | 2 | 2.36 ms |
| `stage-root` | 2 | 1.99 ms |
| `publish-root` | 1 | 5.29 ms |
| `publish-folder` | 1 | 2.74 ms |
| `verify-final-root` | 1 | 2.03 ms |
| `cleanup-dir`（acknowledge 后清理） | 1 | 6.17 ms |
| `cleanup-root` | 1 | 6.13 ms |
| **合计** | **12** | **约 47 ms** |

这正好覆盖实测的 30–48 ms/张固定开销。200 张批次墙钟 6.78 s（33.9 ms/张），低于 47 ms 是因为多个 worker 的同步等待重叠；同步总量仍然是主因。之前采样里的 `__fcntl` 1,391 个样本也就是这些调用，不是“零散的几十分之一”。

结论要改写为：**导出批量不是 CPU 密集，也不是解码/重采样/编码密集；它是被每张 12 次 `F_FULLFSYNC` 串行化的。** 改变 SQLite 提交模式、连接池、准入额度都不会动到它。

下一步是减少每张的同步次数，而不是继续换旋钮。安全的下限是：

- 暂存文件写完后同步一次（`hash-file` 只保留一次）；
- 暂存目录项建立后同步一次；
- rename 到目标目录后同步目标目录一次；
- `acknowledge` 的清理同步移到批次级，或直接省去（清理失败可由恢复扫描兜底）；
- 最终校验重复哈希时不再 `sync_all`（字节未变，第一次同步已经覆盖）。

目标是把 12 次降到 3–4 次，预计每张省 25–35 ms。任何合并都必须保留现有崩溃一致性证明：文件身份、SHA、PREPARED 回执与 rename 的顺序不能变；只去掉“同一不可变文件/同一目录项的重复同步”。改完用同一套 200 张 A/B 复测，并跑 `ExportPerformanceTests` 与恢复测试。
