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
| 视口帧与原生定稿的重采样差 | p99 ≤ 8/255，最大通道差只出现在几何与锐化边缘 | p99 中位 2/255，最大中位 20/255 |
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
