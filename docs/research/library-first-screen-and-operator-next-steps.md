# 资源库首屏与算子优化的再调研（2026-11-26）

## 结论

**资源库首屏已经达到既有 300 ms 目标，数据库不再是瓶颈。** 6,928 文件的真实库在同一个 release 二进制、同一台机器上：

| 路径 | P50 | P95 |
| --- | ---: | ---: |
| 温态重开 + 首屏 | **166 ms** | **169 ms** |
| 温态重开 + 首张照片 | 174 ms | 179 ms |
| 改筛选到可见网格 | 64 ms | 76 ms |
| 改筛选到首张照片 | 68 ms | 82 ms |
| 持续导入期间改筛选 | 70 ms | 78 ms |
| 持续导入期间首张照片 | 80 ms | 88 ms |

上一轮同口径测得 77 / 92 / 200 / 213 ms，差异主要是机器负载与 trial 波动；两组都低于 300 ms。SQLite 分页现在是 0.07 ms，全库 facets 0.003–0.013 ms，已经不在首屏的关键路径上。

**冷开 2.6 s 不是正常首屏，而是旧库迁移。** 该基准是 schema v7 的 49 MB 备份，每个 trial 都从 v7 迁到 v10：`catalogOpenMs` 2.4 s，`navigationLoadMs` 30–40 ms，之后的同进程重开只有 5 ms。当前 v10 库的冷启动应按 `reopen` 的 166 ms 看，而不是 `open` 的 2.6 s。

**算子优化找到了一条可落地的路径。** 把高级细节的 band 拆成“逐像素 factor + 逐像素 restore”，并把 factor 只算在窗口 + halo 上，真实 9504×6336 ARW 上：

- 整幅 factor/restore、窗口 restore、texture→clarity 串联全部 **0 差异**；
- 窗口内重算 factor 后，factor 与 restore 仍然 **0 差异**；
- 1:1 texture 首次约 **75 ms**（整幅 531 ms，7.1×），clarity 约 **115 ms**（整幅 609 ms，5.3×）；
- 改参数只还原窗口：texture **43 ms**、clarity **50 ms**，约 **12×**；
- 不再生成 964 MB 的整幅 RGBA32F materialize，而是窗口 + halo 的 factor/restore 纹理。

这是上一轮“必须自写高斯与 band 合成”之外的另一条路：**保留 Core Image 的引导图高斯，只接管 factor 的物化与 restore 的窗口求值**。下一步应实现这条路径，而不是重写整个 band 核。

## 资源库首屏

### 测量方法

运行既有 `LibraryGridPerformanceTests`（release，边界是输入事件到可见 AppKit 网格绘制）：

```sh
RM_CATALOG_BACKUP=.../pre-install-backup-20261122-225258/library.sqlite \
RAWMASTER_RUNTIME_RAW_DIRECTORY=.../six-raw \
RAWMASTER_RUNTIME_TOOL_ROOT=.../RAWMaster.app/Contents/Resources/MetadataTool \
RAWMASTER_LIBRARY_UI_REPORT=.../library-first-screen.json \
RAWMASTER_QA_GRID_PAINT_HEADLESS=1 \
xcrun xctest -XCTest RAWMasterUITests.LibraryGridPerformanceTests \
  .build/out/Products/Release/RAWMasterUITests.xctest
```

`RAWMASTER_QA_GRID_PAINT_HEADLESS=1` 是本轮加的 QA 开关：无 WindowServer 的 SSH/xctest 环境没有 `occlusionState.contains(.visible)`，生产仍要求窗口可见，只有显式开关才让绘制标记采样。证据：[measurement-20261126.json](evidence/library-first-screen/measurement-20261126.json)。

### 冷开拆解

| 阶段 | 耗时 |
| --- | ---: |
| v7 备份迁移（含备份/校验/重写） | 2.4 s |
| 迁移后 v10 同进程重开 | 5 ms |
| 导航装载 | 30–41 ms |
| 温态网格绘制 | 64–82 ms |

因此：
- **当前 v10 库的首屏不是 2.6 s，而是 166 ms**；
- 旧库升级的一次性 2.4 s 应做成明确的迁移进度/后台任务，不能拿它当网格性能基线；
- 首次导入后的搜索缓存构建还没有单独测。下一步用 v10、无搜索缓存的库测一次；若超过 300 ms，再考虑首屏先用 authority 分页、后台构建缓存。

### 主线程归因

5 秒 `sample`（4 个 trial 的打开/导入/重开）：

| 顶端 | 样本 |
| --- | ---: |
| 空闲工作线程 | 40,312 |
| SwiftUI `AttributeGraph` / `DynamicPreferenceCombiner`（主线程） | 478 |
| `EditingController.recoverJobs` → `EditingArchive.recoverPublications` | 1,542 |
| `EditingArchive.recoverPublications` 内的 `FileSafety`/`resolvingSymlinksInPath`/`getattrlist` | 912 |
| SHA-256 | 698 |
| `stat` / `getattrlist` | 215 / 199 |

两件事可行动：

1. **启动归档恢复扫描**在后台读 6,928 个文件，和首屏争 I/O/CPU。建议在首个网格可见后再启动，或改成按需/分批恢复；它不影响首屏绘制边界，但会拖慢整机响应。
2. **根 `.onDrop` 的 SwiftUI preference** 在主线程样本里出现，但做 QA 开关直接移除后，首屏没有变化：

| | 根 drop 开 | 根 drop 关 |
| --- | ---: | ---: |
| idle P50/P95 | 63.9 / 76.3 ms | 63.2 / 75.9 ms |
| reopen P50/P95 | 165.8 / 169.0 ms | 163.8 / 165.0 ms |

因此不改生产 `.onDrop`；这个热点不在首屏边界上。样本里真正的主线程工作是 SwiftUI 视图图更新，但它的完成时间已经在 64–166 ms 内。

### 资源库下一步

| 优先级 | 项 | 说明 |
| --- | --- | --- |
| P0 | 测 v10 无搜索缓存的首屏 | 区分“迁移”与“首次建缓存”；超过 300 ms 再做首屏 fallback/后台构建 |
| P0 | 归档恢复延后到首屏可见/空闲 | 当前启动就扫 6,928 个文件；改为 idle 或按需，测量对首屏和导入的影响 |
| P1 | 迁移进度与后台化 | v7→v10 的 2.4 s 只在升级时发生；不要让窗口无反馈地等待 |
| P2 | 首屏 SwiftUI 微优化 | 当前 64–166 ms 已达标；没有证据支持继续拆网格 |
| 已完成 | 数据库分页/facets/CJK FTS | `0.07 ms` 分页、`0.003–0.013 ms` 全库 facets、2 字 CJK `0.039 ms` |

不建议再做根 `.onDrop` 改造；实测没有首屏收益。

## 算子优化 PoC

### 现状

上一轮已经拿到：1:1 可见窗口传输 1.72×（出厂窗口）、紧贴窗口 2.62×、定稿 51.6×；但邻域算子的稳态仍是：

| 1:1 配方 | 每次改参数 |
| --- | ---: |
| texture | 561–577 ms |
| clarity | 455–463 ms |
| adaptive-brilliance | 3,781–4,305 ms |

上一轮的结论是：`CIGaussianBlur` 作为最终输出是矩形无关的，但 `rmAdvancedBandV1` 的 band 输出随输入 extent 变化（texture 1.6e-5、clarity 7.0e-4），所以窗口化必须连 band 合成一起接管。

### 新 PoC：factor / restore 分解

现有引擎里已经有一组未被 `apply` 使用的 `cachedBandKernels`：

- `rmAdvancedBandFactor`：从 fine/wide 引导图算出逐像素 `band = clamp(fine.r/fine.g - wide.r/wide.g, -1, 1)`；
- `rmAdvancedBandRestore`：从源像素 + factor 算 `ev` 并乘 `exp2(ev)`。

两者都是**逐像素**的；Gaussian 只存在于引导图。于是可以把 factor 冻结成纹理，restore 只读窗口：

1. 引导图高斯在窗口 + halo 上计算（上一轮已证明高斯本身矩形无关，halo 足够时窗口值等于整幅）；
2. factor 在窗口 + halo 上物化（逐像素，窗口值与整幅 crop 相同）；
3. restore 只对窗口求值（逐像素，窗口值与整幅 crop 相同）。

探针 `AdvancedFactorRestoreProbe`（真实 9504×6336 ARW，`RAWMASTER_FACTOR_PROBE=1`）验证：

| 检查 | 最大差 | 差异分量 |
| --- | ---: | ---: |
| texture inline vs factor/restore（整幅） | **0.0** | 0 / 240,869,376 |
| texture window restore vs crop | **0.0** | 0 / 15,360,000 |
| clarity inline vs factor/restore（整幅） | **0.0** | 0 / 240,869,376 |
| clarity window restore vs crop | **0.0** | 0 / 15,360,000 |
| texture25 → clarity40 串联 | **0.0** | 0 |
| 窗口内重算 factor：texture（halo 31） | **0.0** | 0 / 15,360,000 |
| 窗口内重算 factor：clarity（halo 313） | **0.0** | 0 / 15,360,000 |

耗时（单次，9504×6336，统一内存）：

| 项 | texture | clarity |
| --- | ---: | ---: |
| 整幅 factor（guides+factor+freeze） | 588 ms | 620 ms |
| 整幅 inline band（当前） | 531 ms | 609 ms |
| 整幅 restore（factor 已冻结） | 457 ms | 456 ms |
| 窗口 inline（只渲染窗口） | 32.8 ms | 47.0 ms |
| 窗口 restore（factor 已冻结） | 32.8 ms | 32.0 ms |
| **窗口内重算 factor + restore** | **31.4 + 43.2 ms** | **64.8 + 50.0 ms** |

结论：

- 只做整幅 factor/restore 只省约 15%，因为 60 MP 的整幅 materialize 还在；**必须窗口化 factor**；
- 窗口内重算 factor + restore 是 **5.3–7.1×** 的首帧收益，改参数只 restore 约 **12×**；
- 不再分配 964 MB 的整幅 RGBA32F 纹理，factor 区域在 texture 约 65 MB、clarity 约 108 MB；
- 这比“自写高斯 + 自写 band 合成”风险低：高斯仍由 Core Image 提供，factor/restore 的数学与现有 band 逐位一致。

证据：[advanced-factor-window-probe.json](../../specs/036-render-pipeline-performance/evidence/advanced-factor-window-probe.json)。

### 生产化规划

**第 1 步：窗口 factor 缓存（P0）**

- 新增 `AdvancedDetailFactorCache`，键为 `(sourceGeneration, band, radius, quantizedWindow+halo)`；
- 1:1 请求带 `PreviewViewport.window` 时，计算 guides/factor 只在 `window.insetBy(-halo)`；`halo = ceil(12*radius + 8)`（texture 31 px，clarity 313 px @ 9504）；
- factor 冻结为 RGBA32F 纹理；restore 只对窗口求值，输出 `DevelopmentPreviewFrame.window`；
- 仅对 `.detail` 与可见窗口生效；整幅/导出/缩略图继续走现有路径；
- 用 QA 开关（如 `RAWMASTER_QA_ADVANCED_FACTOR_WINDOW=1`）先灰度，再默认。

**第 2 步：串联与缓存失效（P0）**

- texture factor 从输入源算；clarity factor 从 **texture restore 后的窗口输出**算；
- 改 clarity amount 只 restore；改 texture amount 使 clarity factor 失效；
- 上游白平衡/曝光/裁剪/蒙版变化使整个 advanced-detail factor 缓存失效；
- 平移窗口时，窗口+halo 变化才重算 factor；在 50% 外扩窗口内平移可复用。

**第 3 步：逐字节与蒙版回归（P0）**

- 新增生产路径测试：窗口帧 == 整幅帧 crop（texture、clarity、串联）；
- 重跑 `DevelopmentSemanticMaskTests` 的零覆盖像素；
- 重跑 50 个配方 1:1 矩阵，记录首帧、改参数、平移三组数据；
- 导出继续用整幅路径，直到窗口路径在蒙版/裁切/吸管上全部通过。

**第 4 步：dehaze 与 adaptive-brilliance（P1）**

- 这两者各有整幅归约，factor/restore 不能直接复用；
- 先 profile：dehaze 约 1.5 s、adaptive-brilliance 约 3.9 s；
- 方向：分块归约 + 确定性累加顺序（或 CPU/GPU 固定顺序的全局统计） + 每块 halo；先做只读统计的 PoC，再决定是否重写；
- `local detail`、`lens blur` 同形，按 ROI 收益排序。

**第 5 步：交互与产品接线（P1）**

- 1:1 拖动仍用极速代理；松手后的窗口 factor/restore 与拖动帧共用缓存；
- 状态行/缩略图见证继续走整幅帧；
- 按 AGENTS.md 更新原型与 1:1 走查，记录窗口 factor 路径的视觉证据。

### 风险

- **蒙版零覆盖**：当前整幅 freeze 是多分支共享同一结果的前提；窗口路径必须保证同一帧内所有分支读同一个 restore 结果，导出仍整幅。
- **halo 边界**：窗口贴源边缘时 `insetBy` 会被 `intersection(extent)` 裁剪；需要把裁掉的边视为 clamp，探针要覆盖四角。
- **factor 缓存内存**：texture 65 MB + clarity 108 MB/窗口；多窗口/多原件要限预算，按 generation 淘汰。
- **clarity 依赖 texture amount**：缓存键必须包含上游 band 的 amount/结果身份，否则会读到旧 factor。
- **时序**：当前是单次真实 ARW 探针；生产化前至少重复三次并覆盖不同窗口位置。

## 复现

```sh
# 首屏（无 WindowServer 环境需要 headless QA 开关）
RM_CATALOG_BACKUP=... RAWMASTER_RUNTIME_RAW_DIRECTORY=... \
RAWMASTER_RUNTIME_TOOL_ROOT=... RAWMASTER_LIBRARY_UI_REPORT=... \
RAWMASTER_QA_GRID_PAINT_HEADLESS=1 \
xcrun xctest -XCTest RAWMasterUITests.LibraryGridPerformanceTests \
  .build/out/Products/Release/RAWMasterUITests.xctest

# 算子 factor/restore
RAWMASTER_FACTOR_PROBE=1 RAWMASTER_REGION_PROBE_SOURCE=.../DSC05994.ARW \
  swift test -c release --filter AdvancedFactorRestoreProbe
```

## 本轮改动

- `Tests/RAWMasterImagingTests/AdvancedFactorRestoreProbe.swift`：factor/restore、窗口、串联、窗口内 factor 的逐字节探针；
- `DevelopmentAdvancedDetailEngineV3.applyBandWindow`：窗口 restore 的测量/生产接缝（尚未接入 `apply`）；
- `CatalogGridPaint` 的 `RAWMASTER_QA_GRID_PAINT_HEADLESS=1`：无 WindowServer 环境的 QA 采样；
- 文档与证据：本文件、`docs/research/evidence/library-first-screen/measurement-20261126.json`、`specs/036-render-pipeline-performance/evidence/advanced-factor-window-probe.json`。
