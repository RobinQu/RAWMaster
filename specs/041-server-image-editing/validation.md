# 041 · 规划验证记录

2026-11-27 · 本轮为编辑云端与队列设计，不是产品验收。

## 1. 已完成

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 阅读 `rawmaster-image` 图、C ABI、后端 feature | 完成 | [lib.rs](../../Modules/ImageEdit/src/lib.rs) · [graph.rs](../../Modules/ImageEdit/src/graph.rs) · [Cargo.toml](../../Modules/ImageEdit/Cargo.toml) |
| 阅读 035 跨端重放、028 本地交互、024 代理边界 | 完成 | [035](../035-portable-processing-cores/spec.md) · [028](../028-filter-experience/spec.md) · [024](../024-jpeg-display-proxy/plan.md) |
| 阅读 CatalogTaskQueue、ProcessingJob、编辑作业状态 | 完成 | [CatalogTaskQueue.swift](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) · [EditingModels.swift](../../Sources/RAWMasterCore/EditingModels.swift) |
| 确认编辑云端边界：无 Server 交互，仅代理／批处理／生成式 | 完成 | [spec](spec.md) |
| 设计客户端队列、Server 队列、协同 | 完成 | [queues](queues.md) |
| 设计 editProxy、Vulkan 图像 worker、CUDA 生成式、能力清单 | 完成 | [plan](plan.md) |
| 相对链接检查 | 完成 | 本目录及 040／035／037／024 入口；断链为零 |

## 2. 未完成

- **没有实现。** 没有客户端队列、Server 队列、图像 worker、生成式 worker、代理生成。
- **没有 editProxy 实测。** 分辨率、位深、编码、色彩、存储预算、预取时延未测。
- **没有队列实测。** 重启、离线、抢占、去重、取消、未知、公平未执行。
- **没有 Vulkan Server 实测。** NVIDIA GPU、Vulkan ICD、显存、吞吐未测。
- **没有 CUDA/Flux 实测。** 模型、许可、显存、质量未执行。
- **没有色彩门。** Server final 与本地最终一致性未测。
- **没有 UI 原型。** 代理、队列、作业、候选状态未进入摄影工作台。
- **没有 10TB／10GbE 基线。**

## 3. 进入 Q1 前必须补齐

1. 按 [AGENTS](../../AGENTS.md) 更新摄影工作台，覆盖代理准备、队列、Server 作业、取消、重试、候选、能力禁用。
2. 冻结 editProxy 契约：分辨率、10-bit、色域、编码、缓存键、失效、存储预算。
3. 冻结客户端／Server 队列状态机、jobID、能力清单、错误码。
4. 用真实 `rawmaster-image` + Vulkan 在 NVIDIA 上跑代理／final 样本，记录吞吐、显存、精度。
5. 用真实客户端 SQLite 跑队列重启、离线、抢占、取消、未知。
6. 用色彩规格跑 final 对照；未过门只候选。

## 4. 口径

- 本文件只证明设计已对齐现有代码／验证，不证明功能可用。
- 浏览器原型只证明交互，不证明代理、队列、Vulkan、CUDA、色彩。
- 服务端测试必须使用真实 GPU、真实 S3、真实 PostgreSQL；mock 不能替代。
- 性能数字必须注明硬件、GPU、Vulkan/CUDA、分辨率、编码、缓存、队列深度；API 返回不能冒充端到端。
- 未通过项保留在任务和发布门中。
