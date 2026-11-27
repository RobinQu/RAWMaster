# 041 · 任务与发布门

2026-11-27 · 规划任务，均未开始。产品要求见[规格](spec.md)，队列见[queues.md](queues.md)，技术方案见[plan.md](plan.md)。

## 0. 原则

- **交互不进队列。** 滑杆、曲线、蒙版、撤销不走 Server；队列只服务后台任务。
- **复用 042。** 本机队列独立交付。040 先提供归档／取回，再以单张代理或已验证 SDR 子集接通作业链。Scene／HDR、生成式各自通过能力门。
- **先队列正确，后 GPU 规模。** 幂等、取消、重启、公平先通过，再谈 10TB／多模型。
- **旧 SDR 与场景图分开。** 不自动迁移兼容配方；不把 legacy SDR 结果标成 HDR。
- **资料库基线不依赖 GPU。** 图像模块关闭时资料库完整可用。

## Q0 · 契约

- [ ] **IMG01 · 代理契约。** displayProxy、editProxy、sceneProxy、linearProxy、原件；分辨率、位深、色域、编码、几何、方向、HDR 语义、缓存键、失效。[规格](spec.md#31-交互与代理)
- [ ] **IMG02 · 场景图／输出状态。** `DevelopmentRecipe` schema 4、`DevelopmentSceneGraphV1`、`DevelopmentSceneOutputStateV1`、`DevelopmentSceneModelV1`、模板／批量 head。[038](../038-node-dag-workflow/spec.md) · [039](../039-rust-scene-backend/spec.md)
- [ ] **IMG03 · 旧 SDR 兼容。** `compatibility_route`、旧配方、兼容显影图与场景图的边界；不自动迁移。
- [ ] **IMG04 · 远端任务契约。** 复用 [042](../042-local-library-workbench/plan.md) 的本机记录与恢复。冻结客户端意图、镜像、核对、取回与版本关联。[队列](queues.md#2-客户端的远端任务)
- [ ] **IMG05 · Server 队列契约。** lane、优先级、能力、租约、状态、发布、公平、配额。按 scene／legacy／generative 准入。[Server 作业与准入](queues.md#3-server-作业和准入)
- [ ] **IMG06 · 作业 envelope。** jobID、sceneGraph／旧配方、outputState、modelProgram、模板／批次、target head、delivery target、format、幂等、错误码。[plan](plan.md#6-协议)
- [ ] **IMG07 · 能力清单。** `library_core`、`image_proxy`、`image_sdr_batch`、`image_scene_batch`、`model.prefix`、`generative`、Vulkan／CUDA、scene backend、显存、模型、引擎。
- [ ] **IMG08 · 色彩门。** 037 契约、ACES 2、SDR／HDR、AVIF PQ、SDR 派生、未过门行为。[037](../037-color-film-hdr/spec.md)
- [ ] **IMG09 · UI 原型。** 代理准备、场景批次、队列、Server 作业、取消、重试、候选、能力禁用；走查记录。

## Q1 · 代理无感

- [ ] **IMG10 · displayProxy 预取。** 网格／首屏；已有路径复用；不阻塞。
- [ ] **IMG11 · editProxy。** 原生或高分辨率、10-bit SDR；缓存键；Server 或客户端生成。
- [ ] **IMG12 · sceneProxy。** 场景线性／HDR（AP1 FP16／FP32 或明确可逆表示）；不能拿 SDR JPEG 代替；按需、0.5–1×。
- [ ] **IMG13 · 预取与替换。** 选中／悬停／进入编辑；displayProxy 占位；editProxy／sceneProxy 到达不闪烁。
- [ ] **IMG14 · 本地缓存。** LRU、TTL、固定、离线、校验；三类代理分开。
- [ ] **IMG15 · 1:1／最终。** 使用原件；代理不冒充；缺原件提示。
- [ ] **IMG16 · 无 Server 图像能力。** 客户端取回原件后本地生成代理；资料库仍可用。
- [ ] **IMG17 · 代理质量验收。** SDR／HDR、色彩、几何、方向、蒙版坐标；存储／带宽预算。

**Q1 出口。** 冷片／HDR 进入编辑无空白；sceneProxy 语义正确；1:1 用原件；离线可用级别明确。

## Q2 · 客户端的远端作业接入

- [ ] **IMG20 · 接入持久任务。** 复用 042 执行入口，增加远端提交、代理取回和结果取回。
- [ ] **IMG21 · 批次映射。** 场景批次项绑定远端 ID、父版本和目标 head，取回后回到原项。
- [ ] **IMG22 · 资源。** 按需取回提升优先级，后台预取让出前台资源。
- [ ] **IMG23 · 去重。** 代理缓存键、远端 job ID 和同一批次项各按其身份复用。
- [ ] **IMG24 · 取消与重试。** 保存取消意图，使用原 ID 核对提交或发布状态。
- [ ] **IMG25 · 重启及切库。** 持久化镜像与游标，重开后补差，校验事件作用域。
- [ ] **IMG26 · 离线。** 网络任务等待，已准备的数据仍可在本机使用。
- [ ] **IMG27 · 任务界面。** 在 042 的详情中标出远端位置、能力不足、待核对和取回动作。

**Q2 出口。** 远端任务恢复和本地工作同时可验收。本机导入、032、Flux 和批次恢复归 [042 发布验证](../042-local-library-workbench/validation.md)。

## Q3 · Server 队列与 legacy SDR worker

- [ ] **IMG30 · PostgreSQL 作业表。** jobs／attempts／inputs／outputs／events／capabilities／leases；scene／output／model／target 字段。
- [ ] **IMG31 · 能力准入。** NVIDIA CUDA GPU + Vulkan + feature flag + 最小显存；scene backend 单独判定。
- [ ] **IMG32 · 调度。** library 保留；image-scene／legacy／background／model／generative lane；每库加权。
- [ ] **IMG33 · 租约与恢复。** claim／heartbeat／complete；超时重领；旧 token 拒绝；重启 reconcile。
- [ ] **IMG34 · 取消与重试。** 协作取消；暂存清理；同 jobID 新 attempt；不重复发布。
- [ ] **IMG35 · 结果发布。** S3 暂存、SHA-256、target／format／位深／ICC／CICP 登记；唯一发布；不自动采用。
- [ ] **IMG36 · 客户端协同。** Submit／Watch／Get／Cancel／Retry。补事件、恢复代次与取消发布竞态。切库后晚到结果。按源和 head 登记。
- [ ] **IMG37 · Legacy SDR worker。** 旧点配方／兼容图；Vulkan／CPU；不参与 HDR。
- [ ] **IMG38 · 队列公平验收。** 一个库大批量不阻塞另一库；library RPC 不被饿死。

**Q3 出口。** 作业幂等、公平、重启恢复、取消可清理、结果只发布一次；legacy SDR 正常；无 CUDA／Vulkan 时明确禁用。

## Q4 · Linux scene executor 与 HDR／SDR 批处理

- [ ] **IMG40 · scene executor 端口。** 039 当前 macOS Metal-only；为 Linux／Vulkan（或明确 CPU）实现同等 parser／executor／tiling／前缀缓存／receipt／预算／输出；未完成时 `image_scene_batch` 关闭。
- [ ] **IMG41 · scene worker。** 037／038 场景图、coverage、输出状态、SDR trim、模型前缀；S3 输入／输出；保存 execution receipt。
- [ ] **IMG42 · scene.render.final。** 冻结 sceneGraph／outputState／modelProgram／target head；HDR AVIF 与 SDR 派生。
- [ ] **IMG43 · scene.render.batch。** 模板／批量；候选／head；取消／重试／undo；旧 SDR 不迁移。
- [ ] **IMG44 · 色彩门。** 与本地最终在冻结样本、目标、容差内一致；未过门只候选。
- [ ] **IMG45 · HDR／SDR 交付。** AVIF 10 位 Rec.2020／PQ、JPEG8、PNG16；ICC／CICP；SDR 水印／元数据不套 PQ；60MP 合成图与真实 RAW 分开记录。
- [ ] **IMG46 · 失败降级。** 缺 scene executor／Vulkan／色彩门时关闭；legacy SDR 与本地编辑继续。

**Q4 出口。** Linux scene executor 与本地参考通过；scene／HDR 像素与色彩门通过；旧 SDR 不迁移；结果候选。

## Q5 · 模型前缀与生成式

- [ ] **IMG50 · 模型前缀。** `DevelopmentSceneModelV1` 顺序、模型身份、provider、预算、externalCoverage；不是 Flux。
- [ ] **IMG51 · CUDA 能力。** GPU、显存、驱动、模型、许可；缺项禁用。
- [ ] **IMG52 · 生成 worker。** Flux CUDA；输入／模型／种子／参数；`rawmaster-image` 前后处理。
- [ ] **IMG53 · 队列隔离。** 生成式独立显存／并发；不与 scene／final 争抢。
- [ ] **IMG54 · 结果候选。** 版本、来源、模型、输入；不自动采用；取消／重试。
- [ ] **IMG55 · 质量与安全。** 模型输出、内容、许可、资源占用；独立验收。

**Q5 出口。** 模型前缀与 Flux 分开；缺模型禁用；结果绑定；取消／重试；不自动覆盖。

## Q6 · 规模与运维

- [ ] **IMG60 · 10TB／10GbE。** sceneProxy、scene final（含 tiling／cache receipt）、HDR 编码、Flux、队列等待、结果下载；真实基线。
- [ ] **IMG61 · 队列监控。** 深度、等待、失败、GPU／显存、scene backend；不伪造 ETA。
- [ ] **IMG62 · 恢复演练。** Server／客户端重启、S3 5xx、队列满、取消竞态、批次 head。
- [ ] **IMG63 · Feature flags。** `image_proxy`、`image_sdr_batch`、`image_scene_batch`、`model.prefix`、`generative`；按硬件／部署开启。
- [ ] **IMG64 · 发布评审。** 规格、队列、代理、scene／HDR、色彩、模型、验证、已知限制同一包。

## 发布门速查

| 门 | 必须通过 | 不能替代 |
| --- | --- | --- |
| 设计门 | IMG01–IMG09 | 代码编译 |
| 代理门 | IMG10–IMG17 | Server 批处理 |
| 远端客户端接入门 | IMG20–IMG27 | Server 队列 |
| Server 队列门 | IMG30–IMG38 | scene／HDR |
| 041 首个计算闭环 | 040 传输＋两端队列＋已验收的代理与 SDR 子集 | scene／HDR、Flux、10TB |
| Scene 门 | IMG40–IMG46 | legacy SDR |
| 生成式门 | IMG50–IMG55 | 普通编辑 |
| 规模门 | IMG60–IMG64 | 单一演示环境 |
