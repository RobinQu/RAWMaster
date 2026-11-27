# 041 · 任务与发布门

2026-11-27 · 规划任务，均未开始。产品要求见[规格](spec.md)，队列见[queues.md](queues.md)，技术方案见[plan.md](plan.md)。

## 0. 原则

- **交互不进队列。** 滑杆、曲线、蒙版、撤销不走 Server；队列只服务后台任务。
- **先代理，后批处理，再生成式。** 没有高质量 editProxy，Server final 没有意义；没有色彩门，final 不能作为最终。
- **先队列正确，后 GPU 规模。** 幂等、取消、重启、公平先通过，再谈 10TB／多模型。
- **资料库基线不依赖 GPU。** 图像模块是可选能力；关闭时资料库完整可用。

## Q0 · 契约

- [ ] **IMG01 · editProxy 契约。** 分辨率、位深、色域、编码、几何、方向、色彩配置、缓存键、失效规则。[规格](spec.md#31-交互与代理)
- [ ] **IMG02 · 代理分层。** displayProxy／editProxy／linearProxy／原件职责和 UI 标记。[024](../024-jpeg-display-proxy/plan.md)
- [ ] **IMG03 · 客户端队列契约。** 任务类型、优先级、资源类、dedupe、状态、重试、取消、持久化。[queues](queues.md#2-客户端背景队列)
- [ ] **IMG04 · Server 队列契约。** lane、优先级、能力、租约、状态、发布、公平、配额。[queues](queues.md#3-server-作业队列)
- [ ] **IMG05 · 作业 envelope。** jobID、libraryID、kind、inputHash、recipeHash、engine/model、输出、幂等、错误码。[plan](plan.md#6-协议)
- [ ] **IMG06 · 能力清单。** `library_core`、`image_proxy`、`image_batch`、`generative`、Vulkan/CUDA、显存、模型、引擎。[plan](plan.md#41-能力)
- [ ] **IMG07 · 色彩门。** 引用独立色彩规格；final/batch 的容差、比较条件、未过门行为。[037](../037-color-film-hdr/spec.md)
- [ ] **IMG08 · UI 原型。** 代理准备、队列、Server 作业、取消、重试、候选、能力禁用；走查记录。

## Q1 · 代理无感

- [ ] **IMG10 · displayProxy 预取。** 网格／首屏；已有路径复用；不阻塞。
- [ ] **IMG11 · editProxy 生成。** Server 图像模块或客户端；原生／高分辨率、10-bit；缓存键。
- [ ] **IMG12 · 预取与替换。** 选中／悬停／进入编辑；displayProxy 占位；editProxy 到达不闪烁。
- [ ] **IMG13 · 本地缓存。** LRU、TTL、固定、离线、校验；显示／编辑代理分开。
- [ ] **IMG14 · 1:1／最终。** 使用原件；代理不冒充；缺原件提示。
- [ ] **IMG15 · 无 Server 图像能力。** 客户端取回原件后本地生成代理；资料库仍可用。
- [ ] **IMG16 · 代理质量验收。** 分辨率、位深、色彩、几何、方向、蒙版坐标；存储／带宽预算。

**Q1 出口。** 冷片进入编辑无空白；editProxy 高质量；替换不改变上下文；1:1 用原件；离线可用级别明确。

## Q2 · 客户端背景队列

- [ ] **IMG20 · SQLite 任务表。** 类型、优先级、资源类、dedupe、payload hash、状态、重试、租约、结果。
- [ ] **IMG21 · 调度器。** 前台抢占；network/disk/CPU/GPU 并发；暂停／恢复。
- [ ] **IMG22 · 去重与合并。** 同代理键只生成一次；同远端 jobID 只提交一次。
- [ ] **IMG23 · 取消／重试。** transient/permanent/uncertain；临时文件清理；同 ID 重试。
- [ ] **IMG24 · 重启恢复。** running → waiting／重试；不假装完成；不清空队列。
- [ ] **IMG25 · 离线。** 网络任务等待；本地编辑继续；重连恢复。
- [ ] **IMG26 · 队列 UI。** 状态、失败原因、取消、重试；不伪造 ETA。

**Q2 出口。** 前台交互不受影响；任务不丢；去重有效；取消无半成品；重启恢复。

## Q3 · Server 作业队列与 Vulkan 图像 worker

- [ ] **IMG30 · PostgreSQL 作业表。** jobs／attempts／inputs／outputs／events／capabilities／leases。
- [ ] **IMG31 · 能力准入。** NVIDIA CUDA GPU + Vulkan + feature flag + 最小显存；缺项拒绝。
- [ ] **IMG32 · 调度。** library 保留；每库加权；image-final／background／generative lane；GPU 配额。
- [ ] **IMG33 · 租约与恢复。** claim／heartbeat／complete；超时重领；旧 token 拒绝；重启转 reconcile。
- [ ] **IMG34 · 取消与重试。** 协作取消；暂存清理；同 jobID 新 attempt；不重复发布。
- [ ] **IMG35 · 结果发布。** S3 暂存、SHA-256、登记、唯一发布；不自动采用。
- [ ] **IMG36 · 客户端协同。** Submit／Watch／Get／Cancel／Retry；断线补 sequence；未知核对。
- [ ] **IMG37 · 队列公平验收。** 一个库大批量不阻塞另一库；library RPC 不被饿死。

**Q3 出口。** 作业幂等、公平、重启恢复、取消可清理、结果只发布一次；无 CUDA／Vulkan 时明确禁用。

## Q4 · final／batch 与色彩门

- [ ] **IMG40 · render.final。** 冻结输入／配方；原片；Vulkan；输出候选。
- [ ] **IMG41 · render.batch。** 多张／组；输入清单；逐项发布；失败项重试。
- [ ] **IMG42 · 候选与采用。** 结果绑定 inputHash／recipeHash／engine；不自动覆盖；旧结果过期。
- [ ] **IMG43 · 色彩门。** final 与本地最终在冻结样本／容差内一致；未过门只候选。
- [ ] **IMG44 · 失败降级。** 缺 GPU／Vulkan／色彩门时禁用；本地编辑继续。

**Q4 出口。** final／batch 色彩门通过；结果候选；旧结果不覆盖；失败不丢本地编辑。

## Q5 · 生成式（Flux/CUDA）

- [ ] **IMG50 · CUDA 能力。** GPU、显存、驱动、模型、许可；缺项禁用。
- [ ] **IMG51 · 生成 worker。** Flux CUDA；输入／模型／种子／参数；`rawmaster-image` 前后处理。
- [ ] **IMG52 · 队列隔离。** 生成式独立显存／并发；不与 final 争抢。
- [ ] **IMG53 · 结果候选。** 版本、来源、模型、输入；不自动采用；取消／重试。
- [ ] **IMG54 · 质量与安全。** 模型输出、内容、许可、资源占用；独立验收。

**Q5 出口。** 缺模型禁用；结果绑定；取消／重试；不自动覆盖。

## Q6 · 规模与运维

- [ ] **IMG60 · 10TB／10GbE。** editProxy、final、Flux、队列等待、结果下载；真实基线。
- [ ] **IMG61 · 队列监控。** 深度、等待、失败、GPU 利用率、显存；不伪造 ETA。
- [ ] **IMG62 · 恢复演练。** Server 重启、客户端重启、S3 5xx、队列满、取消竞态。
- [ ] **IMG63 · Feature flags。** 按服务器／硬件开启；客户端能力显示；关闭不影响资料库。
- [ ] **IMG64 · 发布评审。** 规格、队列、代理、色彩、模型、验证、已知限制同一包。

## 发布门速查

| 门 | 必须通过 | 不能替代 |
| --- | --- | --- |
| 设计门 | IMG01–IMG08 | 代码编译 |
| 代理门 | IMG10–IMG16 | Server 批处理 |
| 客户端队列门 | IMG20–IMG26 | Server 队列 |
| Server 队列门 | IMG30–IMG37 | final 色彩 |
| 1.0 门 | 代理 + 两端队列 + final 色彩门 | Flux、10TB |
| 生成式门 | IMG50–IMG54 | 普通编辑 |
| 规模门 | IMG60–IMG64 | 单一演示环境 |
