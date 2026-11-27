# 041 · Server 图像编辑模块

2026-11-27 · **规划中，未开始实现。** 本文把 Server 图像编辑收窄为**非交互批处理**：客户端负责全部交互编辑；Server 负责代理生成、场景图／HDR／SDR 最终与批量渲染、确定性模型前缀和 Flux 等生成式任务。不做 Server 交互预览，不做客户端与 Server 同请求并行渲染。

Server 图像模块是资料库 Server 的可选能力：资料库基础始终可用；图像模块需要兼容 CUDA 的 NVIDIA GPU 作为硬件准入，影像渲染和计算使用 Vulkan 后端；生成式模型使用 CUDA AI 推理栈。客户端与 Server 队列语义见 [queues.md](queues.md)，技术方案见 [plan.md](plan.md)，任务见 [tasks.md](tasks.md)。

[040 Server](../040-server/spec.md) · [037 色彩／胶片／HDR](../037-color-film-hdr/spec.md) · [038 Node DAG](../038-node-dag-workflow/spec.md) · [039 Rust scene backend](../039-rust-scene-backend/spec.md) · [035 可移植处理内核](../035-portable-processing-cores/spec.md) · [024 显示代理](../024-jpeg-display-proxy/plan.md) · [现有基础](evidence.md)

## 1. 结论

1. **交互只在客户端。** 滑杆、曲线、蒙版、裁切、撤销、历史、版本采用都不经过 Server。任何网络环境下都不做 Server 交互渲染。
2. **Server 只做批处理。** 代理生成、场景图／HDR／SDR final／batch、确定性模型前缀、Flux 等进入 Server 队列；结果异步返回，作为候选或派生资源。
3. **高质量代理分层。** `displayProxy` 用于浏览；`editProxy` 面向 SDR 交互；`sceneProxy` 面向 037／038 场景线性／HDR 交互；`linearProxy` 按需；1:1、最终和导出使用原件。
4. **场景图与旧 SDR 兼容路线分开。** `DevelopmentRecipe` schema 4 `sceneGraph`、输出状态、模型前缀和模板／批量候选必须随版本保存；旧 SDR 兼容配方不得静默迁移为场景图。
5. **色彩门。** Server final／batch 必须消费 037 的色彩管理契约；HDR AVIF 10 位 Rec.2020／PQ 与 SDR JPEG/PNG16 分别求值。未过门的 Server final 只作候选／诊断，不自动采用。
6. **CUDA 准入、Vulkan 影像。** 图像模块要求 NVIDIA CUDA GPU；`rawmaster-image` 在 Linux 使用 Vulkan；Flux 使用 CUDA AI 栈。**039 的 Rust scene executor 当前是 macOS Metal-only，Linux／Vulkan scene executor 尚未实现。**
7. **队列各自持久化。** 客户端复用 `CatalogTaskQueue` 与 `SceneWorkflowBatch` 语义并扩展为背景队列；Server 使用 PostgreSQL 作业队列；通过 gRPC 协同，不共享队列数据库。
8. **资料库与图像能力解耦。** 没有 GPU 的 Server 仍完整提供归档、取回、元数据和恢复；客户端隐藏图像批处理入口，不静默降级。

## 2. 用户故事

### US1 · 云端存储无感（P0）

摄影师打开一张只有显示代理的照片。资料库先显示代理；进入编辑前，客户端后台取回或生成高质量 `editProxy`／`sceneProxy`，到达后平滑替换；本地交互保持响应。离线或网络慢时明确显示可用级别，不阻塞已有缓存照片。

**独立验收。** displayProxy 立即可看；editProxy／sceneProxy 后台准备；进入编辑不出现空白；代理替换不改变选片／编辑上下文；1:1 和最终使用原件或明确提示。

### US2 · 本地交互不受 Server 影响（P0）

Server 在线或离线都不改变本地滑杆、曲线、蒙版、裁切、撤销或场景图编辑的响应。Server 队列只显示后台状态，不阻塞画布；用户可继续编辑、换片或退出。

**独立验收。** 断开 Server 后本地编辑继续；后台任务排队／重试不影响前台帧；Server 结果迟到不会覆盖当前编辑。

### US3 · 场景图／HDR 批处理（P0）

用户对一张或多张照片提交场景图 final／batch，以及 HDR AVIF 或 SDR 派生交付。作业冻结输入、场景图、输出状态、模型前缀和交付目标；客户端可关闭窗口；结果作为候选，显式采用。

**独立验收。** 同一作业重试只登记一份结果；旧场景图／输出状态结果标过期；旧 SDR 兼容版本不被迁移；HDR／SDR 目标不被静默替换；Server 失败不丢本地编辑。

### US4 · 生成式任务（P1）

用户提交 Flux 等生成任务；Server 使用 CUDA 栈执行，`rawmaster-image` 负责输入准备、色彩、蒙版、合成和后处理；结果作为候选，需显式采用。

**独立验收。** 缺 CUDA／模型／显存时明确禁用；生成结果绑定输入和模型版本；取消／失败／重试可清理；不自动覆盖当前版本。

### US5 · 队列可见、可取消、可恢复（P0）

用户能看到客户端背景任务、`SceneWorkflowBatch` 批次和 Server 作业的状态、队列位置、取消和重试。关闭窗口、断网、重启后任务不丢失；不确定结果先核对，不重复提交。

**独立验收。** 客户端重启恢复本地任务；场景批量批次保留候选／head 冲突；Server 重启后作业可续／重试；重复提交同 ID 只生效一次；取消不产生半成品；未知结果不自动重发。

## 3. 功能要求

### 3.1 交互与代理

- **IMG-R01 · 本地交互。** 所有交互编辑在客户端完成；Server 不提供逐滑杆 RPC、帧流或会话级交互缓存。
- **IMG-R02 · 代理分层。** 区分 `displayProxy`、`editProxy`、`sceneProxy`、`linearProxy`、原件；显示代理不得作为颜色敏感或 HDR 编辑的唯一输入。
- **IMG-R03 · 高质量代理。** `editProxy` 默认原生或高分辨率、10-bit 广色域；`sceneProxy` 必须保留 037 的场景线性／HDR 语义（AP1／ACES 或明确的线性表示），不能拿 SDR JPEG 代替。具体格式、位深、分辨率由代理契约冻结。
- **IMG-R04 · 视口渲染。** 拖动时按视口分辨率；松手后按代理分辨率；1:1、最终、导出使用原件。不能每帧全分辨率渲染。
- **IMG-R05 · 后台预取。** 选中／进入编辑前按优先级取回 editProxy／sceneProxy 或原件；先用 displayProxy 占位；替换不闪烁、不改变上下文。
- **IMG-R06 · 本地缓存。** 代理本地缓存，支持 LRU、TTL、固定、离线、校验；缓存键含源、解码器、profile、方向、分辨率、编码、场景图／输出状态和算子版本。
- **IMG-R07 · 无 Server 图像能力。** 客户端取回原件后本地生成代理；不能把 Server 图像模块当作编辑前置条件。
- **IMG-R08 · 色彩一致。** 代理使用与最终相同的色彩管理；分辨率可以降低，但颜色、几何、蒙版坐标和 HDR／SDR 分支不得改变。
- **IMG-R09 · 1:1 与最终。** 1:1、最终、导出必须使用原件；代理只作交互预览，不能冒充最终像素。

### 3.2 Server 图像能力

- **IMG-R10 · 硬件准入。** `image_module` 需要兼容 CUDA 的 NVIDIA GPU、最低显存／驱动、Vulkan 后端和 feature flag；缺一项则禁用并说明。
- **IMG-R11 · Vulkan 影像。** Linux 影像渲染和计算优先使用 Vulkan；`rawmaster-image` 是共享算子层；CUDA 后端只在单独评估后引入。
- **IMG-R12 · 生成式 CUDA。** Flux 等生成式模型使用 CUDA AI 推理栈；`rawmaster-image` 负责前置解码、色彩、蒙版、合成和后处理。
- **IMG-R13 · 能力清单。** Server 提供 `library_core`、`image_proxy`、`image_sdr_batch`、`image_scene_batch`、`model.prefix`、`generative`、后端、显存、scene backend、引擎／模型版本；客户端按能力显示入口。
- **IMG-R14 · 资料库基线。** 无 GPU 的 Server 仍提供归档、取回、元数据备份恢复；图像模块关闭不影响资料库。
- **IMG-R15 · 资源隔离。** 资料库 RPC／归档优先；图像批处理和生成式队列有独立 GPU／显存／并发配额，不能饿死基础服务。
- **IMG-R16 · 版本绑定与 receipt。** 每个作业记录 `rawmaster-image`、Vulkan／CPU 后端、RAW 解码器、色彩 profile、scene graph／output state／model program 摘要和资源；场景作业保存 tiling、节点／覆盖缓存命中、dispatches、峰值字节、预算和 CPU 时间的 execution receipt；缺依赖不执行。
- **IMG-R17 · 场景后端门。** `image_scene_batch` 只有在 Linux／Vulkan（或明确 CPU）scene executor 通过 039 等价验收后才能开启；当前 039 仅 macOS Metal，不能把 040 的元数据保存能力当作 Server HDR／DAG 可用。
- **IMG-R18 · 兼容路线。** 旧 SDR 兼容配方、兼容显影图和场景图是不同路线；Server 不自动迁移，必须按冻结的 `engineVersion`／`compatibility_route` 执行。
- **IMG-R19 · 模型前缀。** `DevelopmentSceneModelV1` 的 denoise → superResolution? → segmentation* 是确定性、全图、有序前缀；Flux／Seedream 生成候选不属于该前缀，单独记录模型、输入和候选。

### 3.3 批处理作业

- **IMG-R20 · 作业类型。** `proxy.generate`、`scene.proxy`、`scene.render.final`、`scene.render.batch`、`legacy.render.final`、`model.prefix`、`generative`；交互编辑不是作业类型。
- **IMG-R21 · 冻结输入。** 作业冻结原件 `contentID`、场景图／旧配方、输出状态、SDR 派生、模型前缀、模板／批量身份、目标 head、引擎／模型和交付规格；输入变化即过期。
- **IMG-R22 · 幂等提交。** 客户端 `jobID` 稳定；Server 按 `(libraryID, jobID)` 去重；同 ID 不同请求拒绝。
- **IMG-R23 · 结果发布。** 输出先写 S3 暂存、校验、再登记派生资源／版本；同一作业只发布一次；HDR AVIF 与 SDR JPEG/PNG16 分别记录 target、format、位深、ICC／CICP；场景输出附 execution receipt（tiles、cache hits、dispatches、budget、peak bytes、CPU time）。
- **IMG-R24 · 候选采用。** 结果不自动改变当前采用版本；用户明确采用或导出；旧结果可回看；`SceneWorkflowBatch` 的候选／head 冲突保留。
- **IMG-R25 · 取消与重试。** 取消协作式；未发布暂存可清理；重试沿用原输入；不确定结果先核对。
- **IMG-R26 · 队列公平。** 每库配额、加权公平、优先级；一个库的大批任务不能占满所有 GPU；library lane 保留。
- **IMG-R27 · 离线与重启。** 客户端离线保留作业镜像和场景批次；Server 作业持久化；重启后恢复或转待核对。

### 3.4 队列与协同

- **IMG-R28 · 客户端背景队列。** 复用／扩展 `CatalogTaskQueue` 的持久任务、租约、重试和 `SceneWorkflowBatch` 的 review／register／commit／cancel／retry／undo；不另造不兼容批次。
- **IMG-R29 · Server 作业队列。** 持久化、能力匹配、租约、心跳、重试、取消、发布、过期；资料库、scene／legacy、generative 分 lane。
- **IMG-R30 · 两边不共享队列。** 客户端只保存本地任务、场景批次和作业镜像；Server 是作业执行状态权威；不直连数据库。
- **IMG-R31 · 状态同步。** gRPC 提交／查询／watch；客户端按事件更新本地；重复事件幂等；断线重连补差。
- **IMG-R32 · 背压。** Server 队列满、显存不足、能力缺失返回明确错误；客户端延后或提示，不无限重试。
- **IMG-R33 · 取消传播。** 客户端取消 → Server 协作取消 → 结果不发布；Server 已完成则按核对流程处理。
- **IMG-R34 · 结果取回。** 结果通过 S3 presigned／Relay 下载；客户端校验 SHA-256 后登记候选；不把预览当母版。
- **IMG-R35 · 可见性。** 用户能看到本地任务、场景批次和 Server 作业的队列、运行、失败、待核对；不伪造 ETA。

### 3.5 色彩、HDR 与验收

- **IMG-R36 · 色彩门。** Server scene final／batch 必须消费 037 的色彩管理、场景线性、ACES 2、SDR／HDR 输出契约；未过门前只作候选／诊断。
- **IMG-R37 · HDR 交付。** HDR AVIF 10 位 Rec.2020／PQ、参考白 100 nits、目标峰值 1000 nits；SDR 派生使用独立参数和 JPEG8／PNG16；不能把 SDR 水印／元数据套到 PQ，也不能以屏幕能力决定交付。
- **IMG-R38 · 跨后端容差。** CPU／Vulkan／Metal／039 Rust scene executor 差异按 037／035 门槛验收；显示码值差是否允许由色彩规格冻结。
- **IMG-R39 · 生成式结果。** Flux 输出是新内容，不要求与本地同一编辑一致；仍需统一输出色彩、版本、来源和候选采用。
- **IMG-R40 · 性能基线。** 记录 sceneProxy 取回／生成、视口交互、scene final、SDR 派生、HDR 编码、队列等待、结果下载、模型前缀和 Flux 推理；注明硬件、后端、分辨率、tiling、缓存、receipt、色彩目标。60MP 合成图基线不能替代真实 RAW 或 Linux／Vulkan。
- **IMG-R41 · 失败降级。** 缺 GPU／Vulkan／scene executor／模型／色彩门时明确禁用相应队列；本地编辑和资料库继续。

## 4. 交付阶段

| 阶段 | 范围 | 可独立验收 |
| --- | --- | --- |
| Q0 · 契约 | 代理契约、客户端／Server 队列、场景图／输出状态／模型前缀作业信封、能力清单、色彩门 | 评审通过；无未决 P0 |
| Q1 · 代理无感 | displayProxy／editProxy／sceneProxy 预取、缓存、本地生成、离线 | 冷片／HDR 进入编辑无空白；1:1 用原件 |
| Q2 · 客户端队列 | `CatalogTaskQueue` + `SceneWorkflowBatch` 扩展、优先级、去重、取消、重试、重启恢复 | 前台不受影响；批次不丢；取消无半成品 |
| Q3 · Server 队列 | PostgreSQL 作业、能力匹配、scene／legacy lane、租约、发布 | 作业幂等、公平、重启恢复 |
| Q4 · scene／HDR 批处理 | Linux scene executor（或明确关闭）、tiling／前缀缓存／receipt、`scene.render.*`、模型前缀、HDR AVIF／SDR 派生 | 场景图／HDR 输出候选；色彩门通过；旧 SDR 不迁移；60MP 基线 |
| Q5 · 生成式 | Flux/CUDA 队列、模型能力、结果候选 | 缺模型禁用；结果绑定；取消／重试 |
| Q6 · 运维 | 10TB／10GbE、GPU 配额、监控、恢复、feature flags | 真实基线；未测能力不标完成 |

## 5. 验收场景

1. **冷片进入编辑。** displayProxy 立即显示；editProxy／sceneProxy 后台到达；交互上下文不变；1:1 提示取回原件。
2. **HDR 编辑代理。** SDR JPEG 不能代替 sceneProxy；sceneProxy 保留场景线性／HDR 语义；颜色、几何、蒙版坐标一致；1:1 用原件。
3. **Server 离线。** 本地编辑继续；客户端队列和场景批次等待；重连后任务继续；无重复提交。
4. **场景图批处理。** 冻结 sceneGraph／输出状态／模型前缀／模板／目标 head；HDR AVIF 与 SDR JPEG/PNG16 分别登记；结果候选；旧 SDR 兼容版本不迁移。
5. **色彩门。** Server final 与本地最终在冻结样本、目标和容差内一致；未过门只诊断，不标“最终”。
6. **场景后端门。** 039 仅 Metal 时 `image_scene_batch` 关闭或仅本地；Linux／Vulkan scene executor 未通过时不得宣称 HDR／DAG Server 可用。
7. **队列公平。** 一个库大批 scene 任务不阻塞另一库 short job；library lane 保留。
8. **取消／重试。** 客户端取消传播；Server 未发布暂存清理；重试同 ID 不重复发布；场景批次候选／head 冲突保留。
9. **Server 重启。** 运行中作业转待核对或可续；客户端重连补差；旧 token／lease 不能发布。
10. **Flux。** 缺 CUDA／模型／显存时禁用；生成结果绑定输入／模型；不自动覆盖当前版本。
11. **10TB／10GbE。** sceneProxy、final、HDR 编码、Flux、队列等待和结果下载有真实基线；不外推 100TB。

## 6. 成功标准

- **交互不被云端拖慢。** 本地滑杆／曲线／蒙版／撤销／场景图编辑不依赖 Server；后台任务不阻塞前台帧。
- **代理高质量且无感。** 冷片／HDR 进入编辑无空白；editProxy／sceneProxy 语义正确；1:1／最终用原件。
- **场景图可追溯。** sceneGraph、输出状态、模型前缀、模板、批量候选和 head 冲突随版本／批次保存；旧 SDR 不迁移。
- **队列不丢、不重、不脏。** 客户端重启恢复；Server 作业幂等；取消无半成品；旧结果不覆盖。
- **能力边界清楚。** 无 CUDA GPU／Vulkan／scene executor／模型时明确禁用；资料库基线不受影响。
- **色彩可验收。** Server final 只在色彩门通过后作为最终；HDR AVIF 与 SDR 派生分别验证。
- **生成式独立。** Flux 队列与 scene 队列隔离；模型、许可、显存和结果质量独立验收。
- **性能有基线。** 队列等待、代理、scene final、HDR 编码、Flux、结果下载和资源占用可复现。

## 7. 非目标

- Server 交互编辑、逐滑杆 RPC、帧流、会话级 GPU 缓存。
- 客户端与 Server 同一编辑请求并行渲染。
- 跨库队列共享、团队调度、多租户公平。
- 在色彩门通过前把 Server scene final 自动采用为当前版本。
- 无 NVIDIA CUDA GPU 时启用 Server 图像模块。
- 用 SDR displayProxy 代替颜色敏感或 HDR 编辑。
- 在 Linux／Vulkan scene executor 未实现时宣称 Server HDR／DAG 可用。
- 100 TB／200 万文件容量验收；另立专项。

## 8. 待决

| 编号 | 问题 | 建议 |
| --- | --- | --- |
| IMG-D01 | editProxy 分辨率／位深／编码 | 原生或高分辨率、10-bit 广色域 AVIF/HEIF；linearProxy 按需 |
| IMG-D02 | sceneProxy 格式 | 场景线性 AP1 FP16／FP32 优先；或明确定义、可转换的 PQ／12-bit 表示；原生/0.5×；按需 |
| IMG-D03 | 代理存储预算 | 只对冷／远程照片生成；缓存；不默认全量 16-bit 线性 |
| IMG-D04 | 色彩门依赖 | 037 契约；未过门 scene final 仅候选 |
| IMG-D05 | 图像模块 GPU 准入 | NVIDIA CUDA GPU + Vulkan + feature flag；CPU 回退另定 |
| IMG-D06 | scene executor Linux 端口 | 039 当前 Metal-only；Vulkan／CPU 单独立项与验收 |
| IMG-D07 | 客户端队列复用 | `CatalogTaskQueue` + `SceneWorkflowBatch`；不另造批次 |
| IMG-D08 | Server 队列公平 | 每库加权；library lane 保留；GPU 配额 |
| IMG-D09 | 生成式模型 | CUDA、模型、许可、显存、质量独立；缺项禁用 |
| IMG-D10 | 结果采用 | 候选 + 显式采用；场景批次 head 冲突保留 |
| IMG-D11 | 队列可见性 | 状态、位置、失败原因；不伪造 ETA |
| IMG-D12 | 失败回退 | 本地编辑继续；Server 明确错误；不静默换后端 |

## 9. 参考

- [Server 图像编辑队列语义](queues.md)
- [技术方案](plan.md)
- [任务与发布门](tasks.md)
- [现有基础与缺口](evidence.md)
- [040 Server](../040-server/spec.md)
- [037 色彩／胶片／HDR](../037-color-film-hdr/spec.md)
- [038 Node DAG 工作流](../038-node-dag-workflow/spec.md)
- [039 Rust scene backend](../039-rust-scene-backend/spec.md)
- [035 可移植处理内核](../035-portable-processing-cores/spec.md)
- [024 显示代理](../024-jpeg-display-proxy/plan.md)
