# 039 · Rust + Metal 场景执行器

截至 `main@b238c0ab`，macOS 已对有资格的 038 场景图默认尝试 Rust。目标是由 `Modules/ImageEdit` 的 Rust 执行器负责新显影的算子语义、编译、Metal 资源与回执。持久图仍由 [038](../038-node-dag-workflow/spec.md) 定义，工作域及输出由 [037](../037-color-film-hdr/spec.md) 定义。Swift 保留平台呈现、文件授权和验证用参考执行，RAW、模型及编码通过平台适配器接入。[联合实施方案](../035-portable-processing-cores/roadmap.md) · [验证记录](validation.md)

## 生产路径

| 路径 | 当前状态 |
| --- | --- |
| 场景预览／冻结最终图 | 非组内请求默认尝试 Rust + Metal，输出为预乘 AP1 `RGBA32Float`，解析及外部覆盖为 `R32Float`。曝光／EV 曲线、强度和覆盖、Parallel、Layer 的 13 模式、Group 及解析遮罩已有执行。Swift 的 ACES 2、浮点 `CAMetalLayer` 和文件输出阶段消费场景纹理。 |
| 组内查看／旁路 | 图中的 Group 可由 Rust 执行。带 `groupPath` 的监看目前走 Swift。顶层旁路及直接输入根可快速返回源纹理。组内、直通或无正式回执的请求需要分别统计。 |
| 旧 V3 | `graph.rs` 的点配方与 Scene ABI 是两个执行入口。原产品的 Core Image／Metal V3 显影、RAW 域操作和多数空间算子仍在使用。035 的已验收点配方可独立重放，部分接线仅限 QA 模式。 |
| 跨端 | Scene Metal executor 和 Scene C ABI 仅 macOS 提供。035 的点配方已测 Linux CPU 与软件 Vulkan。服务端按 041 逐项验收 Scene decode、执行、模型与成片后再申报能力。 |

`RAWMASTER_SCENE_BACKEND` 省略时走自动选择，在执行错误时可尝试 Swift 参考。设 `rust` 时合格的顶层请求失败即报错，组内路径仍绕过 Rust。设 `swift`、`off` 或 `0` 时强制参考。验收同时核对请求资格和本次执行回执。修复后严格模式对未支持的请求给明确原因，自动模式只在等价能力存在时回退，并记录原失败。取消、过期和语义校验失败直接返回。[路由](../../Sources/RAWMasterImaging/DevelopmentSceneGraphRendererV1.swift) · [Swift 桥](../../Sources/RAWMasterImaging/RustSceneGraphRenderer.swift)

## 编译、瓦片和回执

- `RMSceneProgram` 通过版本化 C ABI 接收 038 图的运行文档。Rust 独立检查节点、深度、层数、依赖、参数、端口与最终根，与 Swift 使用同一组有效／无效文档作一致性测试。[解析器](../../Modules/ImageEdit/src/scene.rs) · [C ABI](../../Modules/ImageEdit/include/rawmaster_image_scene.h)
- Rust 将可达图编码进一个 command buffer，再等待一次完成。ROI 使用源域尺寸和原点。当前瓦片从完整源图及覆盖纹理裁入工作区，瓦片结果写回完整输出。单次提交与瓦片执行都仍受内存带宽和全幅表面限制。程序缓存按拓扑复用。节点键含源修订、操作、依赖、几何与尺寸，解析覆盖可跨源复用。来源变化、已完成 fence 和取消代际决定缓存可否交付。[Metal 执行](../../Modules/ImageEdit/src/scene/metal_exec.rs)
- 场景预览的整幅 AP1 和饱和图解码输出上限为 440 MiB，图预算为 640 MiB，交付图默认 1.5 GiB。回执报告 backend、tiles、evaluated nodes、dispatches、cache hits、peak bytes、budget、CPU 时间及回退原因。原片、跨图程序缓存、模型内部工作区、DRT、drawable 和编码还需统一计量。61.4 MP 合成图使用 6 GiB 测试预算。真实 60 MP 在预览会先撞解码上限，在交付时需要解除图的全幅输入输出约束。[预览预算](../../Sources/RAWMasterImaging/DevelopmentScenePreviewV1.swift) · [RAW 解码](../../Sources/RAWMasterImaging/DevelopmentSceneRAWV1.swift) · [60 MP 测试](../../Tests/RAWMasterImagingTests/RustSceneGraphRendererTests.swift)

## 模型与资源

确定性模型程序最多四个阶段，顺序是全色度去噪、可选一次 2× 超分、分割。PhotoVGG7 和 PhotoUpconv7 的适配器通过 Rec.709 模型域接入。主体／人物来自 Vision，风景遮罩依赖已核验的 EfficientViT 包。阶段的输入范围和有符号／超白还原须在实拍 HDR 上验算。分割只产与来源几何对齐的覆盖。`externalCoverage(id:)` 使用模型阶段 ID。生成式处理由现有候选流程登记。[模型程序](../../Sources/RAWMasterCore/DevelopmentSceneModelV1.swift) · [设备适配器](../../Sources/RAWMasterImaging/DevelopmentSceneProductionModelProvider.swift)

现有接线可在组件中跑通，但 v4 持久配方排斥 `adjustmentsV3`，正常场景草稿从此字段派生模型时得不到模型程序。示波器和冻结交付调用也未携带模型，预览后缀键和 Rust 源修订未包括模型身份。产品开放前应通过同一版本化场景文档和冻结票据保存阶段及资源引用。FIT、ROI、示波器及导出共用已声明的全图模型作用尺度。按来源、模型、权重、分析 View、输入及几何保留可复用结果。模板重绑到目标原片时核对全部覆盖引用。缺模型或权重不符在预检拒绝。[配方](../../Sources/RAWMasterCore/EditingModels.swift) · [预览与示波器](../../Sources/RAWMasterImaging/DevelopmentScenePreviewV1.swift) · [冻结成片](../../Sources/RAWMasterImaging/DevelopmentSceneDeliveryServiceV1.swift)

## 迁移顺序

| 阶段 | 改动 | 放行 |
| --- | --- | --- |
| 1 · 记录实际路由 | 将完成回执随预览／示波器帧和 032 冻结任务传回，附配方／来源、意图、后端版本与失败原因。严格模式按资格判定，补故障、直通与组路径差分。 | 同一受验输入在强制 Swift、严格 Rust、自动三种模式可核对路由。重试和 GPU 完成按原请求身份校验。合格严格请求的回执证明实际 Rust 执行。 |
| 2 · 统一执行入口 | 从 v4 语义扩展同一版本约定，冻结模型及资源。预览、示波器和导出消费同一解释。组内路径编译为独立查看目标，最终根交付继续使用已发布图。 | 旧 v4 和旧 V3 重开与历史等价。有模型的分割覆盖、全图尺度、ROI、重试及缺资源可重复验收。监看从未进入交付票据。 |
| 3 · 降低搬运和物化 | 用带 CFA、EXIF 与 halo 的有界源瓦片生成 FIT 金字塔、原图 ROI 及交付瓦片。预检实际活跃表面后分配，把点瓦片边界接到 DRT／编码。编码器需要整帧时单列输出暂存额度。融合相同域、采样和精度的点段，按实际依赖复用覆盖及分析。 | 真 24／60 MP 的 FIT、ROI 和成片逐项通过 036 的同质量双跑，记录 p50／p95、峰值、回退及像素差。通过实际产品预算与画质的路由进入默认。 |
| 4 · 空间算子与兼容接管 | 按耗时推进 texture／clarity 的 halo、去雾和 brilliance 的确定性全图归约，再扩展模型和剩余算子。让 035 点配方与场景编译共享带域的算子登记和 Rust 资源计划，保留各自算法版本。 | 旧配方的顺序、校准、精度、蒙版零区和几何经双跑。新场景的负值、高光、接缝和色彩按 037／038 验收。Linux 后端单独对照，按能力表开放。[035 兼容方案](../035-portable-processing-cores/spec.md) · [036 性能](../036-render-pipeline-performance/spec.md) |

在上述实际路由具备稳定回执、性能与等价性之前，Swift 参考继续承担验证和支持范围内的回退。仅按已验收路由退役重复实现，历史配方可通过兼容路径读取和回放。
