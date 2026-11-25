# 036 验证记录

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

定稿视口帧与松手前的交互帧是同一次求值（同一 `outputKey`，产品缓存直接命中），所以「改前 vs 改后」的像素差等于「交互代理 vs 原生定稿」的差。该差由同一二进制在原生定稿那一轮里逐像素记录（`measurements[].p99ChannelError` / `maximumChannelError`，把原生定稿整帧以高质量重采样到 2400 后比较）：

| 项 | 结果 |
| --- | --- |
| p99 通道差中位 | 2/255（0.8%） |
| p99 通道差最大 | 18/255 |
| 最大通道差中位 | 20/255 |
| 最大通道差最大 | 211/255（`geometry`、`post-crop-vignette`，集中在校正边缘的个别像素；这两项 p99 均为 3） |

纯点运算配方（曝光、白平衡、曲线、色阶、色轮、黑白、饱和度细化）的最大差在 19–26/255，p99 在 2–3/255，差值集中在高对比边缘的重采样振铃。

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
| `RAWMasterImagingTests`（1,052 项） | 0 失败，79 项 opt-in／真实原片用例按设计跳过 |
| `PreviewInteractiveProxyTests`（18 项） | 0 失败；其中两项断言「定稿仍是原生」，因为它们使用 `PreviewResourcePolicy.default`（`canonical`） |
| `DevelopmentPreviewServiceTests` | 0 失败 |
| `scripts/check-ui-prototype.py`（37 组） | 0 失败 |
| `RAWMasterUITests`（552 项） | 13 条失败，与 `main` 同批同文本，见「未覆盖」 |

`PreviewResourcePolicy.default` 保持 `canonical` 是本次受控回归面的关键：既有测试与既有证据都不改语义，新路径只在产品构造与显式传入 `.viewport` 时生效。

## 参考实现复核

- [三份参考实现对照](../../docs/research/gpu-pipeline-references.md)：Alcedo `68a2c235`、FlashRaw `bee2ca1a`、LightFlow 发布构建 `20261111155800-2d41ab1`。
- [LightFlow REA 符号](evidence/lightflow-rea-symbols.json)：`analyze_javascript_application` 覆盖 43 个 JS、670,783 个 AST 节点，提取 21 个引擎方法的模块 SHA 与源码区间；发现此前 035 未覆盖的多线程绑定 `web-mt/lightflow_host_wasm_mt.js`。WABT 未配置，本轮未做 WAT 级验证，沿用 035 的既有取证。

## 未覆盖

- **`RAWMasterUITests` 有 13 条失败与本次改动无关。** 同一组用例在 `main@d77d099e`（暂存全部改动后重建）与本次分支上失败名称、断言文本和数量一致：`EditingDevelopmentSessionTests.testDevelopmentPreset1075MetadataDirectorySearchStableReferencesAndHiddenRows`（4）、`PhotosDevelopmentIntegrationTests`（5）、`SessionWorkflowActionTests`（4）。报错为 `13 is not equal to 10`、`[] is not equal to [.light]` 与 `初筛会话已关闭…`，都与预览传输无关，属本机既有状态。`RAWMasterImagingTests` 全 1,052 项通过（79 项 opt-in 跳过）。
- 窗口级呈现（WindowServer 合成）未测量；以上均为 API 返回计时。
- 真实桌面走查、浅深色、窗口收窄、1:1 切换未在本轮执行。
- Linux 未执行。
- Camera Raw 的同机对照未重跑；24.35／25.92 ms 取自既有 035 验收记录的封存构建。
