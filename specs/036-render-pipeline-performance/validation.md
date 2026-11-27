# 036 验证记录

以下数字属于各次历史测量。`main@b238c0ab` 的 Release 回归重跑了原图取样和定稿运输用例，覆盖实拍 RAW 的 65% 可见区与固定瓦片像素。历史 50 态及 035 封存性能矩阵仍按各自口径保留。[联合复验](../035-portable-processing-cores/roadmap.md#本次-main-复验)

## 环境

| 项 | 值 |
| --- | --- |
| 机器 | Apple M4 Max，128 GB |
| 系统 | macOS 27.0.1 |
| 构建 | `swift test -c release`（`-O -whole-module-optimization`） |
| 分支 | `perf/gpu-pipeline-dag` |
| 原片 | `output/performance/acr-benchmark.ARW`，SHA-256 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`，9504×6336 |
| 解码 | FlashRaw 0.3.1，GPU 后端，bilinear，线性 RGB F16 |
| 画布 | 2400×1600（`PreviewViewport.maxPixel = 2400`） |
| 用例 | `Tests/RAWMasterImagingTests/EditingInteractivePerformanceTests.swift`，每配方 3 次交互帧 + 1 次定稿帧，冷进程不清理 OS 缓存 |

两次运行使用同一二进制、同一原片、同一策略，只切换 `settledTransport`：

```sh
RAWMASTER_FLASHRAW_LIBRARY=$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib \
RAWMASTER_REQUIRE_FLASHRAW=1 RAWMASTER_INTERACTIVE_PERF=1 \
RAWMASTER_INTERACTIVE_PERF_SOURCE=$PWD/output/performance/acr-benchmark.ARW \
RAWMASTER_INTERACTIVE_RAW_BASE_CACHE=1 \
RAWMASTER_INTERACTIVE_SETTLED_TRANSPORT=canonical   # 或不设，默认 viewport \
swift test -c release --jobs 4 --filter EditingInteractivePerformanceTests
```

| 组 | 输出目录 | 仓库内证据 |
| --- | --- | --- |
| 原生定稿（改前口径） | `output/performance/perf-viewport-full-075150/` | [canonical-settled.json](evidence/canonical-settled.json) |
| 视口定稿，无位图缓存（新求值） | `output/performance/perf-viewport-final/` | [viewport-settled.json](evidence/viewport-settled.json) |
| 视口定稿，产品 128 MB 位图缓存 | `output/performance/perf-viewport-product/` | [viewport-settled-product-cache.json](evidence/viewport-settled-product-cache.json) |
| 视口定稿 vs 原生定稿逐像素 | `output/performance/perf-viewport-quality/` | [viewport-settled-vs-native.json](evidence/viewport-settled-vs-native.json) |
| 1:1 整幅扫描（改前） | `output/performance/perf-detail-banded-0/` | [native-detail-fullframe-scan.json](evidence/native-detail-fullframe-scan.json) |
| 1:1 分带归约（改后） | `output/performance/perf-detail-banded-1/` | [native-detail-banded-scan.json](evidence/native-detail-banded-scan.json) |

证据目录只保留测量矩阵、策略标识与相关阶段遥测；完整原始日志留在各自的 `output/` 目录（该目录被 git 忽略）。[索引](evidence/index.json)

## 汇总

| 指标 | 原生定稿 | 视口定稿（无缓存） | 倍数 |
| --- | ---: | ---: | ---: |
| 50 个配方定稿合计 | 20,594.0 ms | 398.9 ms | **51.6×** |
| 定稿中位 | 255.47 ms | **6.81 ms** | 37.5× |
| 定稿 P95 | 842.57 ms | **20.24 ms** | 41.6× |
| 定稿最大值 | 4,480.94 ms | **33.11 ms** | 135× |

对照水位：Camera Raw 同机口径 24.35 / 25.92 ms；LightFlow 同机 P50／P95 22.13 / 23.56 ms 与 210.23 ms。视口定稿的中位与 P95 都低于两者。

## 产品位图缓存下的松手成本

产品构造持有 128 MB 位图缓存。定稿帧与松手前最后一帧共用同一 `outputKey`，因此松手后不重跑任何 GPU 工作：

| 指标 | 视口定稿（产品缓存） |
| --- | ---: |
| 50 个配方定稿合计 | 13.20 ms |
| 定稿中位 | **0.250 ms** |
| 定稿 P95 | 0.369 ms |
| 定稿最大值 | 0.505 ms |

同一轮里交互帧中位也降到约 0.3 ms，因为三次重复请求命中了同一缓存键。因此这一轮只用于衡量**松手重放**；衡量**新求值**须用上一节无缓存的那一轮。

## 逐配方

| 配方 | 原生定稿 ms | 视口定稿 ms | 倍数 |
| --- | ---: | ---: | ---: |
| neutral | 104.78 | 1.40 | 74.8× |
| exposure-color | 96.78 | 4.27 | 22.7× |
| adaptive-brilliance | 4480.94 | 21.28 | 210.6× |
| texture | 494.76 | 3.90 | 126.7× |
| clarity | 471.02 | 3.46 | 136.3× |
| dehaze-v1 | 575.66 | 6.55 | 87.9× |
| dehaze-v2 | 842.57 | 11.18 | 75.4× |
| geometry | 138.21 | 5.36 | 25.8× |
| post-crop-vignette | 164.87 | 7.66 | 21.5× |
| lens-blur-procedural | 538.56 | 11.05 | 48.7× |
| lens-blur-device-depth | 562.76 | 8.76 | 64.2× |
| lens-blur-refine-focus | 594.39 | 12.60 | 47.2× |
| lens-blur-refine-blur | 592.54 | 13.58 | 43.6× |
| lens-blur-refine-auto-mask | 598.60 | 12.40 | 48.3× |
| lens-blur-bokeh-bubble | 261.14 | 9.62 | 27.1× |
| lens-blur-bokeh-five-blade | 258.65 | 8.97 | 28.8× |
| lens-blur-bokeh-ring | 239.77 | 8.56 | 28.0× |
| lens-blur-bokeh-anamorphic | 256.42 | 8.97 | 28.6× |
| lens-blur-cat-eye | 260.81 | 8.36 | 31.2× |
| lens-blur-bokeh-boost | 266.39 | 8.17 | 32.6× |
| lens-blur-depth-preview | 223.13 | 5.69 | 39.2× |
| local-glow | 409.79 | 7.64 | 53.6× |
| bw-mixer | 109.14 | 4.40 | 24.8× |
| point-variance | 242.55 | 4.01 | 60.6× |
| targeted-hsl | 231.24 | 4.43 | 52.1× |
| visualise-range | 209.18 | 7.54 | 27.7× |
| hue-isolation | 207.58 | 8.72 | 23.8× |
| clipping-shadows | 63.42 | 3.77 | 16.8× |
| clipping-highlights | 66.66 | 3.94 | 16.9× |
| wb-flash-preset | 38.16 | 3.67 | 10.4× |
| refine-saturation | 97.59 | 5.07 | 19.2× |
| point-curve-targeted | 76.46 | 3.50 | 21.8× |
| defringe | 227.82 | 3.51 | 64.9× |
| point-color-samples | 240.13 | 3.85 | 62.4× |
| local-point-color | 249.68 | 3.57 | 69.9× |
| local-light-extended | 64.01 | 3.31 | 19.3× |
| local-wb | 127.73 | 6.34 | 20.1× |
| local-hue-colorize | 69.67 | 3.59 | 19.4× |
| local-texture-clarity | 1755.98 | 20.24 | 86.7× |
| local-dehaze | 517.22 | 8.62 | 60.0× |
| local-grain | 319.20 | 4.28 | 74.6× |
| local-curves | 141.05 | 7.08 | 19.9× |
| local-grading | 127.92 | 7.06 | 18.1× |
| local-detail | 826.54 | 19.65 | 42.1× |
| local-defringe | 510.04 | 33.11 | 15.4× |
| global-sharpen-detail | 359.11 | 3.93 | 91.4× |
| global-sharpen-mask-preview | 350.65 | 15.97 | 22.0× |
| global-noise-detail | 375.16 | 7.41 | 50.6× |
| optics-ca-distortion | 303.11 | 5.01 | 60.5× |
| optics-lens-profile | 254.51 | 3.85 | 66.2× |

`local-defringe` 的视口定稿是交互帧（12.60 ms）的 2.6 倍，是本表唯一超过 1.5 倍的配方；产品位图缓存下它回落到 0.275 ms，说明额外成本发生在无缓存的重求值上，而非定稿本身。原因为何单独慢待查（见[任务](tasks.md)）。

## 像素差

定稿视口帧与松手前的交互帧是同一次求值（同一 `outputKey`，产品缓存直接命中），所以「改前 vs 改后」的像素差等于「视口构图 vs 原生定稿」的差。交互性能用例为此在 `viewport` 策略下另开一个 `canonical` 会话，把原生定稿整帧以高质量重采样到 2400 后逐通道比较，记录 `p99ChannelError` / `maximumChannelError`。

| 项 | 结果 |
| --- | --- |
| p99 通道差中位 | 2/255（0.8%） |
| p99 通道差最大 | 18/255 |
| 最大通道差中位 | 20/255 |
| 最大通道差最大 | 211/255（`geometry`、`post-crop-vignette`；两项 p99 均为 3/255，差值集中在几何校正边缘的个别像素） |

纯点运算配方（曝光、白平衡、曲线、色阶、色轮、黑白、饱和度细化）的最大差在 19–26/255，p99 在 2–3/255，差值集中在高对比边缘的重采样振铃。

同一轮视口定稿的时延：中位 4.97 ms、P95 16.35 ms、最大 28.07 ms（`local-detail`），合计 337.1 ms。

## 逐字节等价

新增 `Tests/RAWMasterImagingTests/PreviewSettledTransportTests.swift`（4 项，全部通过）：

1. `PreviewResourcePolicy.default.settledTransport == .canonical`，既有默认与既有证据不受影响。
2. 3000×2000 合成输入在 `viewport` 策略下：定稿帧与同配方交互帧的 `outputKey`、`outputPixelSize`、`canonicalPixelSize`、`approximation.version` 相同，RGBA 逐字节相同；`detail` 帧不带近似标记且宽度大于定稿帧。
3. `definition` 这类不可缩放算子仍在定稿帧走原生渲染（`approximation == nil`，输出 2400×1600，`canonicalPixelSize` 为 3000×2000）。
4. `canonical` 策略下的定稿帧仍不带近似标记。

```sh
swift test -c release --jobs 4 --filter PreviewSettledTransportTests
# Executed 4 tests, with 0 failures
```

回归范围：

| 范围 | 结果 |
| --- | --- |
| `RAWMasterImagingTests`（1,053 项） | 0 失败，79 项 opt-in／真实原片用例按设计跳过 |
| `PreviewInteractiveProxyTests`（18 项） | 0 失败；其中两项断言「定稿仍是原生」，因为它们使用 `PreviewResourcePolicy.default`（`canonical`） |
| `DevelopmentPreviewServiceTests` | 0 失败 |
| `scripts/check-ui-prototype.py`（37 组） | 0 失败 |
| `RAWMasterUITests`（552 项） | 13 条失败，与 `main` 同批同文本，见「未覆盖」 |

`PreviewResourcePolicy.default` 保持 `canonical` 是本次受控回归面的关键：既有测试与既有证据都不改语义，新路径只在产品构造与显式传入 `.viewport` 时生效。

## 参考实现复核

- [三份参考实现对照](../../docs/research/gpu-pipeline-references.md)：Alcedo `68a2c235`、FlashRaw `bee2ca1a`、LightFlow 发布构建 `20261111155800-2d41ab1`。
- [LightFlow REA 符号](evidence/lightflow-rea-symbols.json)：`analyze_javascript_application` 覆盖 43 个 JS、670,783 个 AST 节点，提取 21 个引擎方法的模块 SHA 与源码区间；发现此前 035 未覆盖的多线程绑定 `web-mt/lightflow_host_wasm_mt.js`。WABT 未配置，本轮未做 WAT 级验证，沿用 035 的既有取证。

## 1:1 改造前的原生全帧基线

1:1 仍按原生分辨率构图（未做 ROI 裁剪）。用 `RAWMASTER_INTERACTIVE_DETAIL=1` 在同一原片上取 7 个配方，先看改前的成本构成：

| 配方 | 定稿（视口）ms | 1:1（原生）ms，整幅扫描 |
| --- | ---: | ---: |
| neutral | 1.26 | 275.0 |
| exposure-color | 4.78 | 257.6 |
| texture | 3.47 | 662.6 |
| clarity | 4.79 | 630.7 |
| dehaze-v2 | 10.69 | 2177.3 |
| local-detail | 22.90 | 923.5 |
| optics-lens-profile | 3.80 | 333.8 |

遥测显示 `optics-lens-profile` 的 333.8 ms 里，`DevelopmentRendererV3.develop` 占 208.2 ms，其中 `显影有限值检查` 的**全域归约**就是 208.1 ms，图构建本身只有 0.01 ms。也就是说原生路径的可压缩部分不在算子，而在对 60 MP 浮点图做整幅有限值扫描。

### 分带归约（本轮已默认启用）

把通用原生扫描接到锐化输出已在用的分带传输上（见[规格](spec.md#原生扫描改用分带归约)）。同机逐配方：

| 1:1 配方 | 整幅扫描 ms | 分带归约 ms | 变化 |
| --- | ---: | ---: | ---: |
| neutral | 281.1 | 154.8 | −45% |
| optics-lens-profile | 317.4 | 171.9 | −46% |
| texture | 660.1 | 536.6 | −19% |
| local-detail | 922.5 | 808.0 | −12% |
| dehaze-v2 | 2,116.8 | 1,820.0 | −14% |

输出不变：同一轮的 1:1 成片 PNG 在两种传输下逐字节相同（`neutral`、`texture`、`dehaze-v2`、`optics-lens-profile`、`local-detail`）。接受／拒绝集合由 `testBandedNativeAdmissionAgreesWithTheLegacyFullFrameScan` 逐模式对照。

复现：

```sh
for MODE in 0 1; do
RAWMASTER_QA_CANONICAL_BANDED_NATIVE_FINITE=$MODE \
RAWMASTER_FLASHRAW_LIBRARY=$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib \
RAWMASTER_REQUIRE_FLASHRAW=1 RAWMASTER_INTERACTIVE_PERF=1 RAWMASTER_INTERACTIVE_DETAIL=1 \
RAWMASTER_INTERACTIVE_WRITE_IMAGES=1 \
RAWMASTER_INTERACTIVE_PERF_ONLY='neutral,texture,dehaze-v2,optics-lens-profile,local-detail' \
RAWMASTER_INTERACTIVE_PERF_SOURCE=$PWD/output/performance/acr-benchmark.ARW \
RAWMASTER_INTERACTIVE_PERF_OUTPUT=$PWD/output/performance/perf-detail-pixels-$MODE \
RAWMASTER_INTERACTIVE_RAW_BASE_CACHE=1 \
swift test -c release --skip-build --jobs 4 --filter EditingInteractivePerformanceTests
done
```

### 可见窗口的服务端测量

`detail` 现在可以带一个归一化窗口，只物化 2400×1600 那一块。9504×6336、50 个控件配方、同一二进制：

| 指标 | 整幅物化 | 窗口物化 | 倍数 |
| --- | ---: | ---: | ---: |
| 1:1 中位 | 191.8 ms | **73.1 ms** | 2.62× |
| 1:1 P95 | 1,742.7 ms | 1,381.7 ms | 1.26× |
| 1:1 合计 | 20,596 ms | 13,678 ms | 1.51× |
| 逐配方倍数 | — | 中位 2.48× | 最好 4.96× / 最差 1.12× |

分档看：

| 类别 | 代表配方 | 整幅 → 窗口 |
| --- | --- | ---: |
| 点运算 | exposure-color | 120.0 → **26.3**（4.57×） |
| 点运算 | defringe | 115.0 → **23.3**（4.93×） |
| 点运算 | targeted-hsl | 102.2 → **24.3**（4.21×） |
| 邻域 | texture | 539.2 → 482.3（1.12×） |
| 邻域 | dehaze-v2 | 1,836.7 → 1,586.2（1.16×） |
| 邻域 | adaptive-brilliance | 4,470.4 → 3,883.8（1.15×） |

邻域与全局归约仍在整幅上算，窗口只省掉物化，所以这一档只有 1.1–1.2×。

窗口帧与整幅帧同区域逐字节相同（`testDetailWindowIsExactlyTheCropOfTheWholeNativeFrame`，3000×2000 合成源）；非 `detail` 请求与越界／退化窗口由 `testNonDetailRequestsRejectAWindow` 拒绝。

### 画布接线后的出厂窗口

画布请求的是「可见矩形 + 每边 50% 外扩、量化到 1/32」，即约 0.505×0.505 的窗口（25.5% 面积）。按这个窗口重测 50 个配方：

| 指标 | 整幅物化 | 出厂窗口 | 倍数 |
| --- | ---: | ---: | ---: |
| 1:1 中位 | 191.8 ms | **111.4 ms** | **1.72×** |
| 1:1 合计 | 20,596 ms | 15,434 ms | 1.33× |
| 1:1 P95 | 1,742.7 ms | 1,474.3 ms | 1.18× |
| 逐配方中位 | — | — | 1.80× |

紧贴视口的窗口（0.2525×0.2525）可到 2.62×，代价是平移半步就要重算；50% 外扩把平移余量做到约半个屏宽。[出厂窗口数据](evidence/native-detail-window-margin.json) · [紧贴窗口数据](evidence/native-detail-window-scoped.json)

绘制侧由 `ImageViewportWindowGeometryTests` 覆盖：位图只落在窗口对应的子矩形，其余保持背景；缩放、命中与叠加层仍按整幅画布计算。平移在留边内不会重发请求（同一组测试里有逐级平移的覆盖）。

```sh
for MODE in 0 1; do
RAWMASTER_INTERACTIVE_DETAIL_WINDOW=$MODE \
RAWMASTER_FLASHRAW_LIBRARY=$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib \
RAWMASTER_REQUIRE_FLASHRAW=1 RAWMASTER_INTERACTIVE_PERF=1 RAWMASTER_INTERACTIVE_DETAIL=1 \
RAWMASTER_INTERACTIVE_PERF_SOURCE=$PWD/output/performance/acr-benchmark.ARW \
RAWMASTER_INTERACTIVE_PERF_OUTPUT=$PWD/output/performance/perf-detail-window2-$MODE \
RAWMASTER_INTERACTIVE_RAW_BASE_CACHE=1 \
swift test -c release --skip-build --jobs 4 --filter EditingInteractivePerformanceTests
done
```

### 冷热拆分

同一配方在窗口帧上连测三次（每次重新请求）：

| 配方 | 第 1 次 | 第 2 次 | 第 3 次 |
| --- | ---: | ---: | ---: |
| neutral | 104.4 | **11.7** | 12.6 |
| exposure-color | 27.7 | 32.0 | 30.5 |
| texture | 474.8 | 490.9 | 486.3 |
| dehaze-v2 | 1,554.2 | 1,490.2 | 1,505.1 |
| adaptive-brilliance | 3,878.0 | 4,226.4 | 3,942.7 |

点运算配方首次约 100 ms、热态约 12 ms，差额是一次性的上下文与内核准备加全幅原片解码。邻域配方三次一致，说明成本在算子内部。据此否决了「把有限值扫描也收窄到窗口」：热态下扫描只占十几毫秒，而收窄要把证明范围改成「显示窗口有限」。

复现：

```sh
RAWMASTER_INTERACTIVE_DETAIL_SAMPLES=3 RAWMASTER_INTERACTIVE_DETAIL_WINDOW=1 \
RAWMASTER_FLASHRAW_LIBRARY=$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib \
RAWMASTER_REQUIRE_FLASHRAW=1 RAWMASTER_INTERACTIVE_PERF=1 RAWMASTER_INTERACTIVE_DETAIL=1 \
RAWMASTER_INTERACTIVE_PERF_ONLY='neutral,exposure-color,texture,dehaze-v2,adaptive-brilliance' \
RAWMASTER_INTERACTIVE_PERF_SOURCE=$PWD/output/performance/acr-benchmark.ARW \
RAWMASTER_INTERACTIVE_PERF_OUTPUT=$PWD/output/performance/perf-detail-warm \
RAWMASTER_INTERACTIVE_RAW_BASE_CACHE=1 \
swift test -c release --skip-build --jobs 4 --filter EditingInteractivePerformanceTests
```

### 仍未压缩的部分

`createCGImage` 仍会把同一棵图再算一遍。`RAWMASTER_QA_CANONICAL_INTERMEDIATE_CACHE=1` 让上下文缓存中间值，实测只省 1–3%，因此默认关闭。

当前保持整幅有限值证明。热态数据及既有见证复用范围决定先处理已定位的邻域和全幅归约。[任务](tasks.md)

早期用 2 个配方的探针估算 ROI 只有 1.8×，那个数字只覆盖扫描与物化两项、且未算上真实路径里的占比，已被上表替代。[旧探针数据](evidence/roi-probe.json)

## 参考实现策略复核

先前的总结有两处需要更正，依据是源码而非印象：

| | 拖动 | 松手定稿 | 缩放 > 1× | 导出 / 全图任务 |
| --- | --- | --- | --- | --- |
| LightFlow | 整帧 → 目标 `cw×ch`（含 dpr） | 同左 | 同左（常驻多级源） | `exportTile` 1024，整帧原生 |
| Alcedo | 整帧 ≤2560 | **整帧 ≤4096** | **可见 ROI → 视口设备像素** | `FULL_RES_EXPORT`，整帧原生 |
| RAWMaster 现状 | 整帧 → 2400 | 整帧 → 2400 | **整帧原生** | 整帧原生 |

- Alcedo 的 `QUALITY_BASE_PREVIEW` 是 `metadata.source_roi_norm = {}` + `max_edge = kQualityBaseMaxLongEdge (4096)`（`include/edit/runtime/pipeline_apply_request.hpp:67,88-93`）；`use_viewport_region_` 只在 `Detail` 或 `ScopeRefresh` 为真（`ui/alcedo_main/album_backend/editor_session_render_scheduler_port.cpp:106`）。
- zoom 跨过 1.0 才切 Detail：`emitViewChange(zoom() > 1.0f + 1.0e-4f ? .DetailRefresh : …)`（`ui/editor_rhi/editor_interaction_controller.cpp:61`），ROI 与目标尺寸由 `ViewportMapper::ComputeViewportRenderRegion` 从 `widget×dpr×zoom` 推出（`ui/edit_viewer/viewport_mapper.cpp:132-210`）。
- LightFlow 的每次采样都写着 `{"kind":"image","maxSize":2400,"exact":true}`，即整帧 2400；源 `s.load(id,"full")` 常驻。
- 仓库内 Adobe 的实测边界是「完整 RAW 打开为 Photoshop 文档」，`outputPixels: [9504,6336]`；早前引用的 24.35／25.92 ms 方法与分辨率不在 `performance-data.json`，不能当作分辨率策略的证据。

结论：两条实现都在**整幅**上完成定稿（分别 2400 与 4096），只有 Alcedo 在 zoom > 1 时切成可见 ROI。RAWMaster 的定稿与它们一致；不一致的是 zoom ≥ 1 时跳到整帧原生，而不是切 ROI —— 该项经实测否决，见[已否决](spec.md#已否决11-按可见-roi-裁剪)。

## 自由缩放与原图取样

- [浏览器走查](../025-editing-workspace/prototype-review.md#自由缩放与原图取样)：验证两种模式、结束后倍率与位置、1:1、FIT、键盘，以及窄窗浅深外观。样片状态不作为像素质量证据。
- [AppKit 几何回归](../../Tests/RAWMasterImagingTests/ImageCanvasTests.swift)记录缩放开始、更新、结束和取消；安装窗口细节帧不能更改倍率、画布矩形或锚点。
- [像素传输回归](../../Tests/RAWMasterImagingTests/PreviewSettledTransportTests.swift)用 3000 × 2000 的图验证 50% 整图 1500 × 1000、可见块 750 × 600、同一块在 80% 时 1200 × 960；50% 的窗口帧与同倍率整图的对应裁块逐字节一致。不同倍率不共用位图缓存条目，显式 1:1 的裁块一致性测试仍通过。

真实样片为本机 FlashRaw 测试夹具 `canon-5d3-lossy.dng`（3960 × 2640）。[原生画布回归](../../Tests/RAWMasterUITests/NativePresentedCanvasTests.swift)在 SwiftUI 承载的 AppKit 编辑画布上注入缩放阶段，实测两档均停在 65%、整幅输出 2574 × 1716、交付前后同一变换和图像矩形、最终位图数据相同。极速手势中没有交付 detail，均衡手势中已有 detail；`FIT` 返回原来的视口模式。引擎另以此 DNG 渲染画面中间 50% × 50% 的窗口，结果为 1288 × 858（边界向外对齐像素）。未用实体触控板复核系统事件投递。

最终定向回归共 71 项（界面 30、成像 41），全部通过。仓库的全量原型脚本因本机缺少 `agent-browser` 未运行；上面的原型场景已在内置浏览器走查。

本机 RAW 输入可通过 `RAWMASTER_PRESENTED_CANVAS_SOURCE` 指定。复验命令：

```bash
RAWMASTER_PRESENTED_CANVAS_SOURCE=/absolute/path/to/sample.dng \
  swift test --jobs 4 --filter 'ImageCanvasTests|ImageViewportWindowGeometryTests|PreviewQualityPolicyTests|PreviewSettledTransportTests|EditingPreviewCoordinationTests|PhotosLocalCanvasInputTests|testOptInRealRAWFreeZoom'
```

## 未覆盖

- **`RAWMasterUITests` 有 13 条失败与本次改动无关。** 同一组用例在 `main@d77d099e`（暂存全部改动后重建）与本次分支上失败名称、断言文本和数量一致：`EditingDevelopmentSessionTests.testDevelopmentPreset1075MetadataDirectorySearchStableReferencesAndHiddenRows`（4）、`PhotosDevelopmentIntegrationTests`（5）、`SessionWorkflowActionTests`（4）。报错为 `13 is not equal to 10`、`[] is not equal to [.light]` 与 `初筛会话已关闭…`，都与预览传输和有限值扫描无关，属本机既有状态。
- 窗口级呈现（WindowServer 合成）未测量；以上均为 API 返回计时。
- 真实桌面走查、浅深色、窗口收窄、1:1 切换未在本轮执行。
- Linux 未执行。
- Camera Raw 的同机对照未重跑；24.35／25.92 ms 取自既有 035 验收记录的封存构建。
