# 041 · 现有基础与缺口

2026-11-27 · 本地代码、已有验证和外调研。区分“已有能力”与“本规格尚未实现”。

## 1. 已有底座

| 能力 | 证据 | 对本规格的作用 |
| --- | --- | --- |
| 可移植图像图 | [ImageEdit/lib.rs](../../Modules/ImageEdit/src/lib.rs) · [graph.rs](../../Modules/ImageEdit/src/graph.rs) | 曝光、基础调色、曲线／色阶、滤镜、Color Grading、蒙版局部调色等节点；Server 图像 worker 的算子底座 |
| C ABI | [rawmaster_image.h](../../Modules/ImageEdit/include/rawmaster_image.h) | 桌面与无界面宿主共享计划、渲染、覆盖图接口 |
| 后端 | [Cargo.toml](../../Modules/ImageEdit/Cargo.toml) `wgpu` features `metal`、`vulkan`；CPU | Linux 影像用 Vulkan；当前无 CUDA 后端 |
| 跨端验证 | [035 验收](../035-portable-processing-cores/acceptance.md) | Linux CPU／软件 Vulkan 与 macOS CPU／Metal 的冻结配方重放；子集，不是完整 V3 |
| 预览质量分级 | [DevelopmentPreviewModels.swift](../../Sources/RAWMasterImaging/DevelopmentPreviewModels.swift) | `interactive`／`settled`／`detail`；默认 2400 交互视口 |
| 本地交互性能 | [028 规格](../028-filter-experience/spec.md) | 暖滤镜约 16–22ms；canonical 约 2s；不能把全分辨率当每帧 |
| 显示代理边界 | [024 方案](../024-jpeg-display-proxy/plan.md) | JPEG 仅显示缓存，不是颜色敏感编辑输入；支持 `editProxy` 分层 |
| 客户端任务调度 | [CatalogTaskQueue.swift](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) | 已有持久任务、租约、重试、外部投递；主要是资料库／导出，不是编辑后台队列 |
| 编辑作业记录 | [EditingModels.swift](../../Sources/RAWMasterCore/EditingModels.swift) `ProcessingJob` | 已有 queued/preparing/running/reconciling/outcomeUnknown 等；偏向 AI 作业，不是通用跨端队列 |
| Server 基础 | [040 Server](../040-server/spec.md) | gRPC、PostgreSQL、S3、代理取回、能力清单的承载 |

## 2. 明确缺口

- 没有统一的 **客户端编辑后台队列**：当前没有把代理预取、生成、提交、观察、取回、缓存维护放在同一个持久队列。
- 没有 **Server 图像作业队列**：没有 PostgreSQL jobs、能力准入、Vulkan worker、GPU 配额、租约、结果发布。
- 没有 **客户端与 Server 队列协同**：jobID 幂等、WatchJob、取消传播、未知结果核对、断线补差尚未实现。
- 没有 **editProxy 契约**：分辨率、位深、色域、编码、缓存键、失效、存储预算未冻结。
- 没有 **高质量代理生成**：当前 JPEG 显示代理不能作为颜色敏感编辑输入。
- 没有 **Vulkan 图像 worker**：`rawmaster-image` 有 Vulkan feature 和验证，但没有 Server 队列／worker 产品化。
- 没有 **CUDA 生成式 worker**：Flux 等模型运行、许可、显存、结果登记未接入。
- 没有 **能力清单／feature flag**：无法按服务器硬件开启／关闭图像模块。
- 没有 **色彩门**：Server final 与本地最终的容差和采用条件未冻结。
- 没有 **队列 UI**：客户端没有统一的后台任务／远端作业视图。

## 3. 现有验证的边界

- `rawmaster-image` 的 Linux CPU／软件 Vulkan 验证覆盖已接入子集，不代表完整 V3、全部蒙版／AI／镜头／输出链。
- 038 的本地交互 16–22ms 是特定样本、特定滤镜、程序化提交到绘制返回；不是所有操作、所有硬件。
- 024 的 JPEG 代理是显示缓存；本规格要求新的 `editProxy`，不能直接复用其语义。
- 035 的跨端像素差在部分状态接近或超过 `2e-6`；最终色彩门另立。
- 10TB／10GbE 队列、代理、final、Flux 尚未测量。

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
