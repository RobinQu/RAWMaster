# 041 · 现有基础与缺口

2026-11-27 · 本地代码、已有验证和外调研。区分“已有能力”与“本规格尚未实现”。

## 1. 已有底座

| 能力 | 证据 | 对本规格的作用 |
| --- | --- | --- |
| 可移植点配方图 | [ImageEdit/lib.rs](../../Modules/ImageEdit/src/lib.rs) · [graph.rs](../../Modules/ImageEdit/src/graph.rs) | 曝光、基础调色、曲线／色阶、滤镜、Color Grading、蒙版局部调色；legacy SDR worker 底座 |
| 场景图执行器 | [039 Rust scene backend](../039-rust-scene-backend/spec.md) · [scene.rs](../../Modules/ImageEdit/src/scene.rs) · [scene_ffi.rs](../../Modules/ImageEdit/src/scene_ffi.rs) | 037／038 AP1 F32 场景图；**当前仅 macOS Metal**，Linux／Vulkan 未实现 |
| C ABI | [rawmaster_image.h](../../Modules/ImageEdit/include/rawmaster_image.h) · [rawmaster_image_scene.h](../../Modules/ImageEdit/include/rawmaster_image_scene.h) | 点配方计划／渲染和场景图计划／渲染 |
| 后端 | [Cargo.toml](../../Modules/ImageEdit/Cargo.toml) `wgpu` features `metal`、`vulkan`；CPU | 点配方图有 Linux Vulkan／CPU；scene 图仅 Metal |
| 跨端验证 | [035 验收](../035-portable-processing-cores/acceptance.md) · [039 验证](../039-rust-scene-backend/validation.md) | 点配方 Linux CPU／软件 Vulkan；scene 图当前 macOS Metal 影子对照 |
| 预览质量分级 | [DevelopmentPreviewModels.swift](../../Sources/RAWMasterImaging/DevelopmentPreviewModels.swift) | `interactive`／`settled`／`detail`；默认 2400 交互视口 |
| 本地交互性能 | [028 规格](../028-filter-experience/spec.md) | 暖滤镜约 16–22ms；canonical 约 2s；不能把全分辨率当每帧 |
| 显示代理边界 | [024 方案](../024-jpeg-display-proxy/plan.md) | JPEG 仅显示缓存，不是颜色敏感编辑输入；支持 `editProxy` 分层 |
| 客户端任务调度 | [CatalogTaskQueue.swift](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) | 持久任务、租约、重试、外部投递；可扩展为背景队列 |
| 场景批次 | [SceneWorkflowBatch.swift](../../Sources/RAWMasterCore/SceneWorkflowBatch.swift) · [LibraryStore+SceneWorkflowBatch.swift](../../Sources/RAWMasterCore/LibraryStore+SceneWorkflowBatch.swift) · [SceneWorkflowBatchView.swift](../../Sources/RAWMaster/SceneWorkflowBatchView.swift) | 已有 review／register／commit／cancel／retry／undo、候选与 head 冲突；041 直接复用 |
| 编辑作业记录 | [EditingModels.swift](../../Sources/RAWMasterCore/EditingModels.swift) `ProcessingJob` | 已有 queued/preparing/running/reconciling/outcomeUnknown 等；偏向 AI 作业，不是通用跨端队列 |
| HDR／SDR 交付 | [037 验证](../037-color-film-hdr/validation.md) · [DevelopmentSceneDeliveryServiceV1.swift](../../Sources/RAWMasterImaging/DevelopmentSceneDeliveryServiceV1.swift) | AVIF 10 位 PQ、SDR JPEG/PNG16、CICP；当前 Metal 组件，Server 端口待办 |
| Server 基础 | [040 Server](../040-server/spec.md) | gRPC、PostgreSQL、S3、代理取回、能力清单的承载 |

## 2. 明确缺口

- 没有统一的 **客户端编辑后台队列**：当前没有把代理预取、生成、提交、观察、取回、缓存维护放在同一个持久队列。
- 没有 **Server 图像作业队列**：没有 PostgreSQL jobs、能力准入、Vulkan worker、GPU 配额、租约、结果发布。
- 没有 **客户端与 Server 队列协同**：jobID 幂等、WatchJob、取消传播、未知结果核对、断线补差尚未实现。
- 没有 **editProxy 契约**：分辨率、位深、色域、编码、缓存键、失效、存储预算未冻结。
- 没有 **高质量代理生成**：当前 JPEG 显示代理不能作为颜色敏感编辑输入。
- 没有 **Vulkan 图像 worker**：点配方图有 Vulkan feature 和验证，但没有 Server 队列／worker 产品化。
- 没有 **Linux／Vulkan scene executor**：039 当前只实现 macOS Metal；Server HDR／DAG 不可执行。
- 没有 **sceneProxy 契约**：AP1／HDR 代理格式、分辨率、存储预算未冻结。
- 没有 **CUDA 生成式 worker**：Flux 等模型运行、许可、显存、结果登记未接入。
- 没有 **能力清单／feature flag**：无法按服务器硬件开启／关闭图像模块。
- 没有 **色彩门**：Server scene final 与本地最终的容差和采用条件未冻结；037 仍是组件级验证。
- 没有 **队列 UI**：客户端没有统一的场景批次、后台任务／远端作业视图。
- 没有 **场景批次远程化**：`SceneWorkflowBatch` 目前本地执行；服务端 final／HDR 尚未接入同一 batch／head。

## 3. 现有验证的边界

- 点配方图的 Linux CPU／软件 Vulkan 验证覆盖已接入子集，不代表完整 V3、全部蒙版／AI／镜头／输出链。
- 039 scene executor 的验证是 macOS Metal 影子对照，不是 Linux／Vulkan 或 60MP 产品验收。
- 038 的本地交互 16–22ms 是特定样本、特定滤镜、程序化提交到绘制返回；不是所有操作、所有硬件。
- 024 的 JPEG 代理是显示缓存；本规格要求 `editProxy`／`sceneProxy`，不能直接复用其语义。
- 035 的跨端像素差在部分状态接近或超过 `2e-6`；最终色彩门另立。
- 037 已验证场景线性、ACES 2、AVIF 组件和部分原生暗房，但完整 HDR 产品、跨屏、批量 PQ 和 Server 端口未通过。
- 10TB／10GbE 队列、sceneProxy、final、HDR 编码、Flux 尚未测量。

## 4. 外部调研

| 主题 | 结论 | 来源 |
| --- | --- | --- |
| Vulkan | Linux 图像 GPU 处理使用 Vulkan；wgpu 后端可用 | [wgpu](https://docs.rs/wgpu/27.0.1/wgpu/) |
| CUDA | 生成式模型使用 CUDA AI 栈；图像 worker 不依赖 CUDA API | 由本规格确认 |
| gRPC | 队列提交／状态用 gRPC over H2；不传像素帧 | [gRPC Swift 2](https://swift.org/blog/grpc-swift-2/) |
| 代理 | 高分辨率、10-bit、广色域；显示代理与编辑代理分离 | [024](../024-jpeg-display-proxy/plan.md) |

## 5. 非声明

- 本规格不表示 Server 图像编辑已实现或已验收。
- 不表示 `rawmaster-image` 已覆盖完整 V3 或 CUDA 后端。
- 不表示 editProxy 已达到“视觉无损”；分辨率和编码需独立验收。
- 不表示队列、GPU 配额、Flux 模型或色彩门已通过。
