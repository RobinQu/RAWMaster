# 041 · 规划验证记录

2026-11-27 · 记录客户端异步任务盘点、队列设计和原型走查。

## 制作任务与远端结果走查

采用现有「制作任务」作为当前库的入口。导入与初筛、工作流批次和 032 交付可从原入口回查。Server 详情显示冻结照片与版本、原任务 ID、执行位置和下一步。[042 客户端盘点](../042-local-library-workbench/task-inventory.md) · [状态与协同](queues.md)

用 `python3 scripts/check-ui-prototype.py --library-server-only` 复现。Chrome 使用 JPEG 样片与模拟作业。

| 入口与动作 | 浏览器观察 |
| --- | --- |
| [首次打开](../../docs/ui/prototype/index.html?serverReview=1#welcome) → 同步「湖岸资料库」→ [RAWMaster Server](../../docs/ui/prototype/index.html?serverReview=1#tools/server) → 准备远端处理 | 初始缺图像节点时按钮禁用并说明原因。启用示例节点后，FLUX 冻结照片、原版本与指令 |
| 展开「走查提交回执」→ 模拟丢失 → [制作任务](../../docs/ui/prototype/index.html?serverReview=1#jobs) → 核对原任务 → 模拟失败 → 重试 | 核对前无重试。之后仍为同一 ID，执行失败后的重试增加一次尝试。详情关闭回到任务入口 |
| 断线后取消已提交作业 → Server 先发布 → 切到另一库 → 重开原库 → 联网并更新状态 | 显示取消待确认。任务留在原库，重开沿用原 ID。核对展示已经发布的结果 |
| 取回时模拟校验失败 → 重试 → 查看候选 → 采用 → 返回调整并按 ⌘Z | 首次取回没有登记候选，重试只登记一份，采用是独立动作。撤销恢复原版本并保留候选 |
| 离线提交代理请求后直接取消，随后在 390×844 浅色／深色查看库菜单与任务 | 未提交意图在本机取消。没有远端尝试记录。窄窗内容可见，键盘 Escape 回到菜单入口 |

本机验证归 [042](../042-local-library-workbench/validation.md)。Q2 验证客户端镜像、断线和切库补差。Q3 在真实 PostgreSQL／S3 中注入重启、回执丢失、事件缺口、授权换代、取消发布竞态及损坏内容，检验对象和收据。场景代理准备、跨端批次／head 竞态与最终色彩、实际 Flux/CUDA 能力为后续阶段验收。

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

- **尚待实现。** Server 作业、两端状态协同、远端代理及图像 worker。现有的本地业务队列见[盘点](../042-local-library-workbench/task-inventory.md)。
- **没有 editProxy／sceneProxy 实测。** 分辨率、位深、HDR 语义、色彩、存储预算、预取时延未测。
- **没有队列实测。** 重启、离线、抢占、去重、取消、未知、公平、场景批次 head 未执行。
- **没有 Linux／Vulkan scene executor。** 039 仅 macOS Metal；Server HDR／DAG 不能执行。tiling、前缀缓存和 receipt 只在 macOS 合成 60MP 上验证。
- **没有 Vulkan Server 实测。** NVIDIA GPU、Vulkan ICD、显存、吞吐未测。
- **没有 CUDA/Flux 实测。** 模型、许可、显存、质量未执行。
- **没有色彩门。** Server scene final 与本地最终一致性未测；HDR AVIF／SDR 派生未在 Server 验证。
- **待补的原型范围。** 真实代理级别的准备交互与批量远端 head 冲突，按 Q1／Q4 推进。单张作业和候选走查见上。
- **没有 10TB／10GbE 基线。**

## 3. 进入 Q1 前必须补齐

1. 补齐 Q1 代理准备和替换交互。进 Q4 时复用 038 批次原型验收远端批次动作和 head 冲突。
2. 冻结 editProxy／sceneProxy 契约：SDR／HDR、分辨率、10-bit／FP16、色域、编码、缓存键、失效、存储预算。
3. 冻结客户端／Server 队列状态机、`SceneWorkflowBatch` 集成、jobID、能力清单、错误码。
4. 决定 Linux／Vulkan scene executor：实现或明确关闭 `image_scene_batch`；不能用 legacy SDR 冒充。
5. 用真实 `rawmaster-image` + Vulkan 在 NVIDIA 上跑 legacy／scene 样本，记录吞吐、显存、精度。
6. 用真实客户端 SQLite 跑队列重启、离线、抢占、取消、未知、场景批次 head。
7. 用 037 色彩规格跑 scene final／HDR AVIF／SDR 派生对照；未过门只候选。
8. 把 039 的 tiling、前缀缓存、execution receipt 带到 Linux／Vulkan；用真实 60MP RAW 复核，不用合成图代替。

## 4. 口径

- 本文件只证明设计已对齐现有代码／验证，不证明功能可用。
- 浏览器原型只证明交互，不证明代理、队列、Vulkan、CUDA、色彩。
- 服务端测试必须使用真实 GPU、真实 S3、真实 PostgreSQL；mock 不能替代。
- 性能数字必须注明硬件、GPU、Vulkan/CUDA、分辨率、编码、缓存、队列深度；API 返回不能冒充端到端。
- 未通过项保留在任务和发布门中。
