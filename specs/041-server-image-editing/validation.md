# 041 · 规划验证记录

2026-11-27 · 本轮为编辑云端与队列设计，不是产品验收。

## 1. 已完成

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 阅读点配方图、scene executor、C ABI、后端 feature | 完成 | [ImageEdit/src](../../Modules/ImageEdit/src) · [039 spec](../039-rust-scene-backend/spec.md) · [Cargo.toml](../../Modules/ImageEdit/Cargo.toml) |
| 阅读 035 跨端重放、037 色彩／HDR、038 DAG、039 scene backend | 完成 | [035](../035-portable-processing-cores/spec.md) · [037](../037-color-film-hdr/spec.md) · [038](../038-node-dag-workflow/spec.md) · [039](../039-rust-scene-backend/spec.md) |
| 阅读 028 本地交互、024 代理边界 | 完成 | [028](../028-filter-experience/spec.md) · [024](../024-jpeg-display-proxy/plan.md) |
| 阅读 CatalogTaskQueue、SceneWorkflowBatch、ProcessingJob | 完成 | [CatalogTaskQueue.swift](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) · [SceneWorkflowBatch.swift](../../Sources/RAWMasterCore/SceneWorkflowBatch.swift) · [SceneWorkflowBatchView.swift](../../Sources/RAWMaster/SceneWorkflowBatchView.swift) |
| 确认编辑云端边界：无 Server 交互，仅代理／批处理／生成式 | 完成 | [spec](spec.md) |
| 设计客户端队列（复用 SceneWorkflowBatch）、Server 队列、协同 | 完成 | [queues](queues.md) |
| 设计 sceneProxy、Vulkan／scene 能力、CUDA 生成式、能力清单 | 完成 | [plan](plan.md) |
| 相对链接检查 | 完成 | 本目录及 040／035／037／038／039／024 入口；断链为零 |

## 2. 未完成

- **没有实现。** 没有客户端队列、Server 队列、图像 worker、生成式 worker、代理生成。
- **没有 editProxy／sceneProxy 实测。** 分辨率、位深、HDR 语义、色彩、存储预算、预取时延未测。
- **没有队列实测。** 重启、离线、抢占、去重、取消、未知、公平、场景批次 head 未执行。
- **没有 Linux／Vulkan scene executor。** 039 仅 macOS Metal；Server HDR／DAG 不能执行。
- **没有 Vulkan Server 实测。** NVIDIA GPU、Vulkan ICD、显存、吞吐未测。
- **没有 CUDA/Flux 实测。** 模型、许可、显存、质量未执行。
- **没有色彩门。** Server scene final 与本地最终一致性未测；HDR AVIF／SDR 派生未在 Server 验证。
- **没有 UI 原型。** sceneProxy、场景批次、队列、作业、候选状态未进入摄影工作台。
- **没有 10TB／10GbE 基线。**

## 3. 进入 Q1 前必须补齐

1. 按 [AGENTS](../../AGENTS.md) 更新摄影工作台，覆盖 sceneProxy、场景批次、队列、Server 作业、取消、重试、候选、能力禁用。
2. 冻结 editProxy／sceneProxy 契约：SDR／HDR、分辨率、10-bit／FP16、色域、编码、缓存键、失效、存储预算。
3. 冻结客户端／Server 队列状态机、`SceneWorkflowBatch` 集成、jobID、能力清单、错误码。
4. 决定 Linux／Vulkan scene executor：实现或明确关闭 `image_scene_batch`；不能用 legacy SDR 冒充。
5. 用真实 `rawmaster-image` + Vulkan 在 NVIDIA 上跑 legacy／scene 样本，记录吞吐、显存、精度。
6. 用真实客户端 SQLite 跑队列重启、离线、抢占、取消、未知、场景批次 head。
7. 用 037 色彩规格跑 scene final／HDR AVIF／SDR 派生对照；未过门只候选。

## 4. 口径

- 本文件只证明设计已对齐现有代码／验证，不证明功能可用。
- 浏览器原型只证明交互，不证明代理、队列、Vulkan、CUDA、色彩。
- 服务端测试必须使用真实 GPU、真实 S3、真实 PostgreSQL；mock 不能替代。
- 性能数字必须注明硬件、GPU、Vulkan/CUDA、分辨率、编码、缓存、队列深度；API 返回不能冒充端到端。
- 未通过项保留在任务和发布门中。
