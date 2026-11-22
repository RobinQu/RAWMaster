# 四个参考实现如何接入 RAWMaster

核查日期为 2026-11-22。本次复读了 Dreamer 的 macOS 发布包、SpektraFilm 和 FlashRaw 的固定源码，以及 RAWMaster 当前工作树。LightFlow 使用已发布的 JavaScript、WASM 中的 WGSL 和 REA 静态分析。下文单独注明以往跑过的探针及其计时边界。

| 用户动作 | 可以复用的机制 | 在 RAWMaster 的落点 |
| --- | --- | --- |
| 点一个人、预览肤色、拖动强度 | LightFlow 将候选蒙版、笔刷栅格化、显示帧分开。Dreamer 在已确认的皮肤范围内执行肤色均匀 | 每张照片先做本地分析。拖动沿用已确认的蒙版与原生 GPU 算子，仅改变配方 |
| 框住干扰物，查看并调整修复 | Dreamer 冻结文档与选区，LightFlow 分别读取工作图和 Matte，再存 Patch | 冻结原片身份、配方、坐标和输入颜色。返回候选后可改羽化、强度或撤销，继续使用同一资产 |
| 给一组照片选胶片风格 | SpektraFilm 分开胶片曝光、显影、相纸和扫描。固定点变换可烘焙 LUT | 将基础色调交给 GPU，光晕和颗粒按输出尺度处理，保存数据版本和随机种子 |
| 让参考张指导一组连拍 | Dreamer 在预设中限定目标和保护范围，并校验回放尺寸 | RAWMaster 让用户明确选择参考照和字段，逐张估算曝光/白平衡。局部卡到另一张照片时重新取范围，换光张单独复核 |

## Dreamer 的可编辑回图

- **两种局部编辑。** 在版本 2.2.2 的 `panel/retouch/core/retouch-core.js`，`composite` 先校验图像尺寸与 Matte，复制底图，跳过混合系数为零的像素，按 `base + amount × matte × (edited − base)` 修改 RGB。另一条路径在 `host/ps-io.js`，`placeImageToSpecificDoc` 在首次异步操作前取得目标文档 ID 并复制选区，`createGroupAndMask` 以保存的像素坐标重建选区、创建组蒙版。对 RAWMaster，冻结范围和候选资产可以独立于生成器实现。以前的 64×64 探针在三个人像配方上得到蒙版外 RGB 与 alpha 最大差均为 0，范围内有变化。探针覆盖本地合成，Photoshop 宿主贴回仅有静态证据。[发布包](https://github.com/2771096196/PSAI-Dreamer/releases/tag/v2.2.2-macos-arm64) · [探针与此前复核](../../docs/research/dreamer-spektrafilm-implementation-review.md)
- **按摄影目标选卡。** `portrait-v3.js` 的 `skin_tone_even` 在用户确认的皮肤范围整理色差，`retouch-core.js` 的 `skin_smooth` 对低频作调整后加回高频。风格库有清爽纪实、中性层次、银调黑白。风光/建筑角色的 `final-prompt-inject.md` 列出地形、光向、几何等保护条件，作用于提示文本。`basic-mode-state.js::compilePrompt` 的字段和 `session-v3.js::replayInput` 的尺寸检查可分别借鉴到卡片与回放机制。RAWMaster 的分割、参考张配平与几何验收由自己的管线完成。[人像配方](../../output/research/ai-retouching-rea/dreamer-release/extracted/Dreamer/panel/retouch/core/portrait-v3.js) · [风格配方](../../output/research/ai-retouching-rea/dreamer-release/extracted/Dreamer/panel/retouch/core/style-recipes.js) · [五场景实现核对](../../docs/research/dreamer-spektrafilm-implementation-review.md)

静态核查的发布包 SHA-256 为 `b027ad3e54e21d695d0d1d3a8287d142dcc4549453b208a5633425e3025f4aea`。仓库首页提供说明与发布下载，以上函数来自压缩包的 `Dreamer/`。跨 Photoshop 版本的写回与生成服务稳定性尚未验证。

### 场景卡依据的直接复测

2026-11-22 从上述发布包直接执行下表五项，每项默认参数跑两次。输入 64×64、sRGB Float32 RGBA、alpha 为 1。对每个像素 (x,y) 取 R = 0.2 + 0.6x/63、G = 0.25 + 0.4y/63、B = 0.35 + 0.2(x+y)/126。左侧 32 列蒙版为 1，右侧为 0。分别与输入和另一次输出逐通道比较。

| 发布包配方 ID | 选区内最大 RGB 差（0–1） | 选区外最大 RGB 差 | 全图最大 alpha 差 | 两次输出逐值相同 |
| --- | ---: | ---: | ---: | --- |
| `skin_tone_even` | 0.008555 | 0 | 0 | 是 |
| `skin_smooth` | 0.004230 | 0 | 0 | 是 |
| `style_fresh_documentary` | 0.022284 | 0 | 0 | 是 |
| `style_neutral_documentary` | 0.007889 | 0 | 0 | 是 |
| `style_documentary_bw` | 0.346134 | 0 | 0 | 是 |

这五组数验证了指定输入上的范围与可重复性。真实肤色、毛孔、现场光线和 RAW 输出的观感列入 RAWMaster 摄影师试用。风光与建筑的依据是发布包里的角色说明，在产品方案中作为验收条件。[风光说明](../../output/research/ai-retouching-rea/dreamer-release/extracted/Dreamer/python/profiles/photography_landscape/final-prompt-inject.md) · [建筑说明](../../output/research/ai-retouching-rea/dreamer-release/extracted/Dreamer/python/profiles/architecture_design/final-prompt-inject.md) · [对应场景卡](scene-presets.md)

## SpektraFilm 的快预览与成片

`SimulationPipeline._build_topology` 把输入 RGB 转为胶片对数曝光、CMY 密度，再按模式直接扫描底片，或经相纸曝光、显影后扫描。`FilmingStage.expose` 按实际像素尺度施加滤镜扩散、模糊与 halation。`FilmingStage.develop` 读取曝光和密度曲线、DIR coupler 及颗粒参数。`digest_params` 在预览时关闭颗粒、部分模糊与扫描锐化，保留散射和光晕的核尺度。在 `lut_mode` 下进一步关闭空间、随机与按图计算的过程。RAWMaster 应保存工作色域、胶片与相纸数据标识、胶片画幅和输出像素尺度。用户查看发丝、远山或高光边缘时，应能切到完整质感预览。[管线与节点](https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/src/spektrafilm/runtime/pipeline.py) · [曝光与显影](https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/src/spektrafilm/runtime/stages/filming.py) · [预览及 LUT 模式](https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/src/spektrafilm/runtime/params_builder.py)

已有 A7R5 单张实测使用 rawpy 线性 ProPhoto 输入、Portra 400 / Endura 与 33³ LUT。M4 Max 上，9566×6374 完整管线一次为 107.17 s，`CIColorCube` 到像素缓冲区的暖中位数为 20.72 ms（3 次）。2400×1600 的同一 LUT 为 1.80 ms（5 次）。固定曝光的对照中，完整处理与三线性 LUT 的 8-bit MAE 为 2.02，最大局部差 53.03。产品上可验证即时基础外观和异步完整效果两条路径，商业发布时须分别处理 GPLv3 代码与作者为 profile、LUT 及其直接衍生物提供的 CC BY-SA 4.0 条款。[实测协议与误差](../../docs/research/ai-retouching-gpu-local-pixel-review.md) · [代码许可](https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/LICENSE) · [数据许可](https://github.com/andreavolpato/spektrafilm/blob/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/SPEKTRAFILM_LICENSE.txt)

## FlashRaw 与当前 RAWMaster 的两条图像路径

1. **上游解码。** 固定 0.3.1 构建归档的提交为 `2994e8c550bec70ab78a938ab28a74d7762124f4`，SHA-256 为 `0243cec068020465819ed2db41f20225235c2f182f010deefcebabd9c4361076`。复核了 `crates/flashraw-capi/src/frame.rs::flashraw_decode`、`crates/flashraw/src/gpu.rs::select` 与 `crates/flashraw-gpu/src/run.rs::run_banded`。C API 将输出、裁剪区域和后端转换成 Rust 解码选项，GPU 依据功能支持选择路径，过大帧可分带处理。Rust 支持 GPU 驻留结果，常规 `LinearRgbF16` 则从 GPU 下载并打包为三通道。特定白平衡、DNG opcode 与色彩配置会影响上游选路。[固定上游归档](https://codeload.github.com/ybouane/flashraw/tar.gz/2994e8c550bec70ab78a938ab28a74d7762124f4) · [本仓构建参数](../../scripts/build-flashraw.sh)
2. **交互代理。** `interactivePlan` 对支持域内的 RAW 检查 FlashRaw 库可用性。缓存未命中时读取中性 linear RGB F16，默认 bilinear，`FlashRawMetalConverter` 上传 host buffer、应用 EXIF 方向和缩放，写入 RGBA32F 代理。后续调整复用代理，在后段执行白平衡、颜色、滤镜、细节和蒙版。旧局部修复仍触发 `.canonical(.local)`。AI 分析应接在具有输入指纹的有向图像上，让点击或拖动复用缓存，避免重复 RAW 解码。预算须计入 C 帧、Metal 上传和纹理的短时重叠。[代理与支持域](../../Sources/RAWMasterImaging/PreviewInteractiveProxyV3.swift) · [C 帧与上传](../../Sources/RAWMasterImaging/FlashRawSource.swift) · [Metal 转换](../../Sources/RAWMasterImaging/FlashRawMetalConverter.swift)
3. **全尺寸预览与导出。** `PreviewNativeSource.render` 对适用 V3 RAW、可用库及 `RAWMASTER_CANONICAL_FLASHRAW=1` 提供全尺寸 FlashRaw 中性图，其他路径仍可从 Core Image RAW 得到输入。`RenderExportService.export` 对带结果资产的版本先核对资产 SHA 后写出，对普通配方进入 `DevelopmentService.render → PhotoRenderer.develop → DevelopmentRendererV3.develop`。后者在没有指定 RAW 底图时通过 `CIRAWFilter` 显影。生成补丁应基于对应渲染阶段的冻结像素，记录 decoder 身份、源裁切、方向、归一化坐标、色域和配方指纹。代理与成片中的坐标、色彩和遮罩边缘均须对拍。[原生预览](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [导出](../../Sources/RAWMasterImaging/RenderExportService.swift) · [显影入口](../../Sources/RAWMasterImaging/DevelopmentService.swift) · [V3 渲染顺序](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift)

已有 2026-11-22 Release 基准在开启 FlashRaw canonical 的 A7R5 样本上得到以下交互中位数，三次连续 API 返回计时，2400×1600。局部明暗为 11.79 ms、局部白平衡 13.93 ms、局部去雾 18.58 ms、局部纹理和清晰度 28.46 ms。这里衡量的是原生调整。语义蒙版推理、模型生成与屏幕实际呈现需要各自计时。[基准记录](../../output/performance/local-dehaze-release-gate-20261122/interactive-performance.json) · [可复测脚本](../../scripts/test-image-performance.sh)

## LightFlow 的检测、栅格化与补丁

本次复查构建 `2d41ab1` 的两个发布模块。2026-11-22 获取的线上字节与本地记录逐一匹配。REA 仅读取这两个模块，父证据为 `ev_d6e30c231e55ae4a73f71c9202a8d48c300bc549bb301fc45c70ff6e4c79316c`，分析 34,685 字节，另有 21 个清单条目未纳入这次定向分析。WASM 和主图 Worker 的结论另取自已有证据及本次对对应代码片段的复读。[已有 WASM、Worker 证据与运行记录](../024-jpeg-display-proxy/lightflow-rea.md)

| 发布文件与证据 | 观察到的实现 | 对 RAWMaster 的决定 |
| --- | --- | --- |
| `ortWorker-DaXiU2P4.js`，SHA-256 `82cb8a8b22f6cf3278b583153bb8c5081fdf1edebdc87c9858b0f1dfc421980c` | 列出 EfficientViT 场景、D-FINE 人物检测、SlimSAM 点选、ViTMatte 边缘细化、LaMa / MI-GAN 补全等候选，分别声明输出、后端和各权重。ORT session 按键复用。前台任务优先，支持取消排队任务，GPU 丢失时有 WASM 后备 | 将检测框、按点选区、边缘 alpha、生成像素分别建模。模型清单可用于发现候选，质量和分发许可逐项在 RAWMaster 上验证。[线上推理 Worker](https://lightflow.dev/assets/ortWorker-DaXiU2P4.js) |
| `inpaintGpu-Cp3ARYYv.js`，SHA-256 `a42a2698c1c8c606f863fee77649ac329dcf6afd1a70061f7a1934da513f99a7` | `FillGpu.open` 获取 full 源，`strokeBox` 计算笔划范围，`localGain` 采样区域增益，`input` 并行读取输入与 Matte 两个 ticket。`patch` 读回 Uint16 视图，`holdPatch` 写入引擎 | 对本地或云端模型均保存输入、上下文 ROI、实际输出尺寸与最终 Matte。GPU 负责颜色与坐标一致的贴回，掩模外保留原像素。拖动强度时复用同一候选。[线上补丁模块](https://lightflow.dev/assets/inpaintGpu-Cp3ARYYv.js) |
| 图像 Worker 与 WASM 的 WGSL | `decodeSensor` 优先读取 normalized F16 CFA，兼容旧接口时使用 F32。自有着色器继续显影。笔刷片段在目标区域计算像素与笔划线段的距离、插值半径和羽化。帧循环经 `viewerTick` 判断需求，`engine.idle()` 后记帧完成 | 借鉴按需渲染、ROI 和合成顺序。RAWMaster 使用自有 Metal / CI 内核和现有线性 sRGB 契约。LightFlow 的 CFA 和着色器工作色域需要单独映射。[固定构建的 WGSL 与时序](../024-jpeg-display-proxy/lightflow-rea.md) · [修复工具规格](../029-repair-tools/spec.md) |

静态推理路径只能确认代码和工件身份。旧运行记录中的曝光帧 6.77–12.68 ms 指浏览器收到 GPU-idle 的事件，样本为同一张 Sony RAW。这组数不能替代本地 Mask 推理延迟或候选清理成功率。[LightFlow 计时协议](../024-jpeg-display-proxy/lightflow-rea.md)

## 集成时需要验证的边界

- **旧蒙版与新语义。** 当前 `.subject` 由 Vision 合并检测到的前景实例，最长边 512 的 8-bit PNG 保存在图层上。既有线性、径向、亮度范围和主体蒙版已经支持局部调整。新检测、点选对象和人物部位需要独立描述与确认快照。重开旧照片应继续解码其原 PNG。长边 512 的合并主体只能作为低分辨率证据，头发边缘、多人分离需用实际资产另验。[已有蒙版类型](../../Sources/RAWMasterCore/DevelopmentMaskModelsV3.swift) · [Vision 实现](../../Sources/RAWMasterImaging/DevelopmentSubjectMaskGeneratorV1.swift) · [GPU 蒙版渲染](../../Sources/RAWMasterImaging/DevelopmentMaskEngineV3.swift)
- **修复与历史。** 在现有全局、滤镜、细节、Mask、Local、最终 Geometry 的次序中，以有序 Local 操作承载候选。配方和历史引用已确认资产、Matte、合成操作及输入身份，预览、撤销和重开据此回放。旧 `DevelopmentPatchReference` 预算为单项 16 MiB、总计 64 MiB。新增全帧或高分辨率 ROI 资产需单独记账。验收包括蒙版外逐像素相等、选区内可见变化、EXIF 方向、裁切后回放、输出 ICC、100% 接缝、重开与缺失资产错误。[局部编辑模型](../../Sources/RAWMasterCore/DevelopmentLocalEditModels.swift) · [有序局部算子](../../Sources/RAWMasterImaging/DevelopmentLocalEngineV3.swift) · [修复合成和回归门槛](../029-repair-tools/spec.md)
