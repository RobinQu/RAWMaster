# 036 · 渲染 Pipeline 与编辑 DAG 的性能水位

**实现中。** 目标是把显影链路拉齐 LightFlow 与 Camera Raw 的响应水位。分栏对比与参考实现取证见 [GPU Pipeline 与编辑 DAG 的三份参考实现](../../docs/research/gpu-pipeline-references.md)。[实测记录](validation.md)

## 问题

2026-11-25 在 `main@d77d099e` 上，用 9504×6336 的 Sony ARW 跑既有交互性能用例（`EditingInteractivePerformanceTests`，每态 3 次交互帧 + 1 次定稿帧）：

| 配方 | 交互帧中位（2400×1600） | 定稿帧 |
| --- | ---: | ---: |
| neutral | 1.6 ms | 104.8 ms |
| exposure+color | 4.2 ms | 96.8 ms |
| texture | 4.7 ms | 494.8 ms |
| clarity | 4.1 ms | 471.0 ms |
| adaptive-brilliance | 22.0 ms | 4,480.9 ms |
| local-texture-clarity | 19.8 ms | 1,756.0 ms |

同一份代码里，交互帧已经在参考水位（LightFlow 2400×1600 实测 20.4／21.4 ms），定稿帧却慢 10–200 倍。遥测显示 `DevelopmentRendererV3.develop` 的像素数是 60,217,344，而输出的画布只有 3,840,000 像素，其中 `显影有限值检查`（全域归约）单独占 26–56 ms。

**根因：定稿帧在原生 60 MP 上构图，最后一步才缩到 2400。** 画布尺寸自 2022 年起固定为 2400 px 上限，因此这 25 倍像素从未显示过。参考实现都不这样做：

- LightFlow 的 `render(source, edit, target, options)` 显式接收 `RenderTarget`，`viewerFrame` 按视口尺寸出帧，源按「每一级」驻留。
- Alcedo 的 `RenderType.FAST_PREVIEW` 目标长边 2560，`DETAIL_ROI_PREVIEW` 只渲染可见 ROI，`DecodeRes` 还能把解码降到 1/2、1/4、1/8。

## 决定

引入 `PreviewSettledTransport`，把**画布定稿帧**从原生构图改为按请求视口构图：

| 值 | 行为 |
| --- | --- |
| `canonical` | 既有行为。原生 60 MP 构图，末端 FIT，全域归约在原生尺寸。`PreviewResourcePolicy.default` 保持此值。 |
| `viewport` | 同一算子序列在请求视口上求值，按视口像素做完整有限值校验。产品构造使用此值。 |

生效条件（`DevelopmentPreviewService.settledUsesViewport`）：`quality == .settled`、`schemaVersion == 3`、`role == .primary`、`0 < maxPixel ≤ 2400`，且 `policy.interactiveEvaluation == .proxyV1`。其余请求逐条沿用原路径。

不变的部分：

- **1:1（`detail`）继续原生构图**，且仍是 `viewport.maxPixel == 0` 的全尺寸物化。
- **保存、导出、缩略图、直方图、分析**继续走各自的原生路径。
- **回归面受控**：`PreviewResourcePolicy.default` 仍是 `canonical`，所有既有测试与既有证据不受影响；只有产品 `DevelopmentPreviewService` 的构造与显式传入 `.viewport` 的用例走新路径。

viewport 传输沿用已经通过的交互代理图（`PreviewInteractiveProxyV3`）：邻域半径按 `native→proxy` 缩放，代理基图按内容身份常驻，末帧由 `PreviewMetalFrameValidator` 在视口像素上做全帧 F32 校验后转 sRGB8。因此**定稿帧与松手前最后一帧是同一次求值**：缓存键一致，产品 128 MB 位图缓存直接命中，松手不再触发任何 GPU 工作。

无法按视口缩放的算子（`definition`、`sharpen.intensity`、`localEdits`、`grain`、`superResolution`、投影几何等）继续 fail closed 到原生渲染，帧上不带近似标记。判定沿用 `PreviewInteractiveProxyV3.support` 的单一清单。

## 原生扫描改用分带归约

原生帧（1:1、导出、不可缩放算子的回退）原先对 60 MP 浮点图单独铺一张全幅有限值遮罩，再对遮罩做整幅归约。这与锐化输出已经在用的分带传输是同一件事，只是入口不同：分带路径把遮罩写进有界的 r8 纹理，并在同一个命令缓冲里归约，每组只用 `0xa0` 表示「全部有限」。

现在通用原生扫描走分带传输（`DevelopmentCanonicalFiniteGPU.bandedNativeValidation`，默认开，`RAWMASTER_QA_CANONICAL_BANDED_NATIVE_FINITE=0` 回退）。准入条件与原锐化路径一致：统一内存设备、`workingSetLimit` 预算、逐带等待并核对每组实写。任何带无法入场时回落到原来的整幅扫描。

扫描不写图，因此输出像素不变：5 个配方（neutral、texture、dehaze-v2、optics-lens-profile、local-detail）的 1:1 成片 PNG 在两种传输下逐字节相同。接受／拒绝集合由 `DevelopmentCheckedFiniteV3Tests.testBandedNativeAdmissionAgreesWithTheLegacyFullFrameScan` 逐模式对照（valid、NaN、两个无穷、NaN alpha）。

| 1:1 配方 | 整幅扫描 | 分带归约 | 变化 |
| --- | ---: | ---: | ---: |
| neutral | 281.1 ms | 154.8 ms | −45% |
| optics-lens-profile | 317.4 ms | 171.9 ms | −46% |
| texture | 660.1 ms | 536.6 ms | −19% |
| local-detail | 922.5 ms | 808.0 ms | −12% |
| dehaze-v2 | 2,116.8 ms | 1,820.0 ms | −14% |

1:1 仍按原生像素出帧，没有做 ROI 裁剪；上表的剩余成本主要来自算子本身，`dehaze-v2` 的 1.8 s 即为代表。

## 1:1 可见窗口（传输层已实现，画布待接）

`detail` 原本整幅物化 60 MP，而 1:1 画布只显示 2400×1600。现在请求可以带一个归一化窗口（`PreviewViewport.window`，左上原点），物化只覆盖该窗口；`canonicalPixelSize` 仍是整幅，叠加层、裁切与吸管继续用原来的归一化坐标。

只在 `detail` 生效：`PreviewSettledTransport` 的定稿帧和 `interactive` 帧都是整幅 2400 代理，带窗口会被 `validate` 拒绝。窗口参与缓存键，不同的窗口不会互相命中。

9504×6336、50 个控件配方，同一二进制：

| | 整幅物化 | 窗口物化 |
| --- | ---: | ---: |
| 1:1 中位 | 191.8 ms | **73.1 ms** |
| 1:1 合计 | 20,596 ms | **13,678 ms** |
| 逐配方中位倍数 | — | **2.62×** |

点运算为主的配方 4.2–4.9×（`exposure-color` 120.0 → 26.3、`defringe` 115.0 → 23.3），邻域为主的配方 1.1–1.4×（`texture` 539.2 → 482.3、`dehaze-v2` 1836.7 → 1586.2、`adaptive-brilliance` 4470.4 → 3883.8）。原因是邻域／全局归约仍在整幅上完成，窗口只省掉物化。

**画布已接线，窗口是「可见矩形 + 每边 50% 外扩、量化到 1/32」**，所以实际窗口约为画布的 0.505×0.505（25.5% 面积）。按这个真实窗口重测 50 个配方：

| 指标 | 整幅物化 | 出厂窗口 | 倍数 |
| --- | ---: | ---: | ---: |
| 1:1 中位 | 191.8 ms | **111.4 ms** | **1.72×** |
| 1:1 合计 | 20,596 ms | 15,434 ms | 1.33× |
| 1:1 P95 | 1,742.7 ms | 1,474.3 ms | 1.18× |
| 逐配方中位倍数 | — | — | 1.80× |

紧贴视口的 0.2525×0.2525 窗口能到 2.62×，但那样平移半步就要重算；50% 外扩把平移余量做到约半个屏宽，同时保留 1.72×。

窗口化不改有限值证明的范围：扫描仍是整幅。把扫描也收窄到窗口是下一步，实测还能再省一部分，但它把证明从「整幅有限」缩小为「显示窗口有限」，需要单独审计 `thumbnailCanonicalWitness` 与 `FlashRawNativeFiniteCheck` 的复用域。

## 解码端：没有可用的降采样开关

原计划给 `CFlashRaw` 透出 `flashraw_decode_options.max_dimension`，把预览的解码降到 1/2 或 1/4（对应 Alcedo 的 `DecodeRes`）。实测后撤回：

| 手段 | 结果 |
| --- | --- |
| `max_dimension = 4800` | **直接报错** `limit exceeded: dimension 9728x6656 exceeds 4800`。源码 `crates/flashraw-capi/src/frame.rs:156` 把该字段写进 `limits`，是安全上限而不是降采样。 |
| `demosaic = HALF_SIZE` | 输出 4752×3168（原生 25% 像素），耗时 39.6 ms vs bilinear 43.5 ms。**只减尺寸不减时间**，因为解码与去马赛克的工作量不变。 |
| `demosaic = EDGE_AWARE` | 118.9 ms，是 bilinear 的 2.7 倍。`rawDetails` 选 AHD 时会付这个代价。 |

因此 FlashRaw 0.3.1 上唯一还剩的解码杠杆是**区域解码**（`use_region`，已在 C 包装里），它的用法与 1:1 可见窗口绑定：窗口帧可以只解那一块，省掉一次约 78 ms 的全幅解码。这项要等窗口接到画布之后再评估，因为窗口帧的纹理通常已经由定稿帧的解码驻留。

代理基图仍用 bilinear 全幅解码，再经 Metal 采样到 2400×1600。

## 1:1 剩余成本：冷启动与算子内部整幅工作

同一配方连测三次 1:1（窗口帧，各次均重新请求）：

| 配方 | 第 1 次 | 第 2 次 | 第 3 次 |
| --- | ---: | ---: | ---: |
| neutral | 104.4 ms | **11.7 ms** | 12.6 ms |
| exposure-color | 27.7 | 32.0 | 30.5 |
| texture | 474.8 | 490.9 | 486.3 |
| dehaze-v2 | 1,554.2 | 1,490.2 | 1,505.1 |
| adaptive-brilliance | 3,878.0 | 4,226.4 | 3,942.7 |

两件事因此可以定性：

1. **点运算配方的 1:1 首次成本主要是一次性准备**（约 90 ms：私有上下文的首次内核编译与全幅原片解码/上传），热态只有约 12 ms。这也解释了扫描不是大头——分带扫描在热态里只占十几毫秒，收窄它换不到多少，却要把证明从「整幅有限」缩成「窗口有限」。因此**窗口化扫描不做**。
2. **邻域配方的成本是算子内部的整幅工作**，与请求区块无关。`DevelopmentAdvancedDetailEngineV3.materialize` 把整幅 9504×6336 渲染进一张 RGBA32F 纹理（约 964 MB）并同步等待，`texture`/`clarity` 的 480 ms 主要来自这里；`dehaze` 与 `adaptive-brilliance` 的 1.5 s / 3.9 s 同理来自各自的整幅归约。要吃掉它们必须逐算子做邻域分解、把内部物化改成窗口＋halo，那是算子级工程，不是传输层能解决的。

## 交互与像素契约

| 从哪里进入 | 对象、完成与退出 |
| --- | --- |
| 暗房画布，适应窗口 | 拖动任一控件显示视口帧；松手后画布立即停在最后一帧，不再出现「快速预览 · 待完整预览」。状态行显示 `预览 2400 × 1600 · 原生 9504 × 6336`。 |
| 暗房画布，放大到 100% | 切到 `detail`，原生构图与原生像素；状态行显示 `原生像素 9504 × 6336`。 |
| 局部调整、裁切、吸管 | 使用当前定稿帧（视口像素）作为叠加与取样底图；坐标仍按归一化画布，构图映射不变。 |
| 保存版本、导出、缩略图 | 不受影响，继续原生。 |

定稿帧的 `approximation` 记录 `PreviewInteractiveProxyV3.version` 与 `native→proxy` 尺度，`canonicalPixelSize` 仍是原生画布，供叠加层与几何映射使用。

## 验收

| 项 | 门槛 | 结果 |
| --- | --- | --- |
| 50 个控件配方的定稿中位 | ≤ 25.92 ms（Camera Raw 同机口径） | 6.81 ms |
| 50 个配方的定稿 P95 | ≤ 210.23 ms（LightFlow 同机 P95） | 20.24 ms |
| 单配方最慢定稿 | 不高于同配方交互帧的 1.5 倍 | 33.11 ms（local-defringe，交互 12.60 ms，2.6×；产品位图缓存下 0.275 ms，见验证记录） |
| 松手后的定稿成本 | 重放同一视口帧，不重跑 GPU | 中位 0.250 ms，最大 0.505 ms |
| 视口帧与原生定稿的重采样差 | p99 ≤ 8/255，最大通道差只出现在几何与锐化边缘 | p99 中位 2/255、最大 18/255；最大通道差中位 20/255 |
| 1:1（`detail`）行为 | 保持原生像素，不改语义 | 未改；测得 258–2177 ms，作为下一轮目标 |
| 原生路径未被削弱 | `detail`、导出与 `PreviewResourcePolicy.default` 逐位不变 | 由既有回归与新增用例覆盖 |

## 取证与参考

- [GPU Pipeline 与编辑 DAG 的三份参考实现](../../docs/research/gpu-pipeline-references.md)：LightFlow 发布包引擎接口与帧循环、Alcedo 的编译计划／节点缓存／渲染意图／解码分辨率、FlashRaw 的 C ABI 开关。
- [LightFlow REA 符号取证](evidence/lightflow-rea-symbols.json)：本轮 `analyze_javascript_application` 的 21 个引擎方法、模块 SHA-256 与精确源码区间；含此前未覆盖的多线程绑定 `web-mt/lightflow_host_wasm_mt.js`。

## 任务

见[任务清单](tasks.md)。剩余项：

1. 播放尺度的 1:1 查看目前整帧原生构图，尚未按可见 ROI 裁剪（Alcedo `DETAIL_ROI_PREVIEW`）。
2. 解码端降分辨率（FlashRaw `max_dimension` / `DecodeRes`）尚未接入，视口帧仍消耗一次全尺寸解码。
3. 视口尺寸仍固定 2400 px，未随实际画布与窗口收窄调整。
4. `local-defringe` 的定稿是交互帧的 2.6 倍，需单独定位。
