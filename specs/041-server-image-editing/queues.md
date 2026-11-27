# 041 · 客户端与 Server 队列

2026-11-27 · 客户端背景队列、Server 作业队列以及两者的协同。**两边不共享队列数据库**；客户端本地 SQLite 保存自己的任务、`SceneWorkflowBatch` 批次和远端作业镜像，Server PostgreSQL 是作业执行状态权威。交互编辑帧不进入任何队列。客户端复用现有 `CatalogTaskQueue` 的持久任务／租约语义和 `SceneWorkflowBatch` 的 review／register／commit／cancel／retry／undo，不另造不兼容批次。

## 1. 目标

- 前台交互永远优先；后台任务不能阻塞画布、选片或退出。
- 任务可持久化、重启恢复、离线等待、断线重连。
- 重复提交不重复执行；取消不产生半成品；未知结果先核对。
- 客户端和 Server 各自可独立工作；没有 Server 时本地任务继续。
- Server 队列按能力、显存、库配额和优先级公平调度；资料库基础不被图像任务饿死。

## 2. 客户端背景队列

### 2.1 任务类型

| 类型 | 作用 | 资源 | 可取消 |
| --- | --- | --- | --- |
| `prefetch.displayProxy` | 网格／首屏代理 | network, disk | 是 |
| `prefetch.editProxy` | 进入 SDR 编辑前准备高质量代理 | network, disk | 是 |
| `prefetch.sceneProxy` | 进入 037／038 场景图编辑前准备线性／HDR 代理 | network, disk | 是 |
| `prefetch.original` | 1:1／最终前取回原件 | network, disk | 是 |
| `generate.editProxy` | Server 不可用时本地生成 SDR 代理 | CPU/GPU, disk | 是 |
| `generate.sceneProxy` | Server 不可用时本地生成场景线性／HDR 代理 | CPU/GPU, disk | 是 |
| `scene.batch.run` | 本地执行 `SceneWorkflowBatch` review／commit／retry／undo | CPU/GPU, disk | 是 |
| `scene.batch.remote` | 将场景批次项提交 Server final／HDR 渲染 | network, disk | 是 |
| `submit.remoteJob` | 提交 Server 作业 | network | 提交前可；已提交转核对 |
| `watch.remoteJob` | 查询／订阅 Server 作业 | network | 是 |
| `fetch.remoteResult` | 下载并校验结果 | network, disk | 是 |
| `cache.evict` | 缓存回收／过期 | disk | 是 |
| `verify.cache` | 校验本地代理／原件 | disk | 是 |
| `local.batchRender` | 客户端批量渲染（后续） | CPU/GPU | 是 |

**不进入客户端队列：** 滑杆、曲线、蒙版、裁切、撤销、比较、当前画布帧。这些走编辑会话的 latest-wins 取消，不进持久队列。

### 2.2 优先级

1. `foregroundBlocking`：用户已打开编辑但缺少 editProxy／原件；只允许一个，立即抢占。
2. `userInitiated`：用户明确提交 final／Flux／取回原件。
3. `visiblePrefetch`：当前项目／选区的代理预取。
4. `backgroundBatch`：后续批次、缓存预热。
5. `maintenance`：校验、清理、索引。

规则：

- 前台交互始终优先；`prefetch` 在画布拖动时可暂停或降并发。
- 同一照片的 `prefetch.editProxy` 可升级为 `foregroundBlocking`，不重复建任务。
- `userInitiated` 高于 `visiblePrefetch`；但 `foregroundBlocking` 高于一切。
- 低优先级任务不能在电池／热压力／低磁盘时无限运行；按设备策略暂停。

### 2.3 资源类与并发

| 资源 | 默认并发 | 说明 |
| --- | --- | --- |
| network | 2–4 | 下载／上传；与 S3／gRPC 共享 |
| disk | 2 | 代理写入、校验、缓存 |
| CPU | 1–2 | 本地代理生成／批处理 |
| GPU | 1 | 本地编辑以外的大任务；前台可抢占 |
| memory | 按任务 | 代理／解码缓冲；超限排队 |

客户端队列不直接控制编辑预览的 GPU；两者共享 `ProcessingAdmission` 式预算，前台交互优先。

### 2.4 任务记录

```text
client_tasks(
  task_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  priority INTEGER NOT NULL,
  resource_class TEXT NOT NULL,
  dedupe_key TEXT,
  payload_json TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  state TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  not_before REAL,
  lease_owner TEXT,
  lease_until REAL,
  last_error TEXT,
  result_json TEXT,
  created_at REAL,
  updated_at REAL
)
```

- `dedupe_key`：例如 `editProxy:<library>:<contentID>:<proxyContract>`、`sceneProxy:<library>:<contentID>:<sceneProxyContract>`；同键只保留一个任务。
- 场景批次任务额外绑定 `batch_id`、`asset_id`、`parent_version`、`target_head`、`scene_graph_hash`、`output_state_hash`；不得把不同 head 的批次项合并。
- `payload_hash`：任务输入不可变；同 `task_id` 不同 payload 拒绝。
- 状态：`queued`、`running`、`waiting`（网络／资源）、`paused`、`cancelling`、`cancelled`、`succeeded`、`failed`、`reconcile`。
- 结果：缓存键、文件、SHA-256、字节数、验证时间；不把临时文件当完成。

### 2.5 生命周期

```text
queued → running → succeeded
   ↓         ↓
 waiting   failed → retry (transient)
   ↓         ↓
 paused    reconcile
   ↓
 cancelled
```

- 启动时 `running` 转 `waiting` 或按任务类型重试；不能假装仍在运行。
- 网络任务断线 → `waiting`；恢复后按 `not_before` 重试。
- 取消：`cancelling` → 协作停止 → 删除临时文件 → `cancelled`。
- 失败分类：transient（网络／S3 5xx／超时）、permanent（校验／权限／不存在）、uncertain（提交结果未知）。
- `uncertain` 不自动重发；先查询 Server 作业结果。
- 重试沿用同 `task_id`；不重复建缓存或重复提交。

### 2.6 前台抢占

- 用户开始拖动／缩放／切片时，客户端队列暂停非必要 `prefetch`／`backgroundBatch`。
- GPU 任务与前台编辑共享预算；前台需要时取消或降级后台任务。
- 取消后台任务不能破坏已完成的缓存；部分文件清理。
- 交互恢复后不自动全速重启所有后台任务；按优先级逐步恢复。

### 2.7 `SceneWorkflowBatch` 集成

- 现有 `SceneWorkflowBatch` 已定义 header／item／candidate、`pending`／`offline`／`incompatible`／`conflict`／`completed`／`cancelled`／`undone`／`failed`，以及 review／register／commit／cancel／retry／undo。客户端队列直接复用这些语义。
- 本地批次继续由 `SceneWorkflowBatchCoordinator` 执行；新增 `scene.batch.run` 只负责持久化、优先级、抢占和重启恢复，不改变“只创建候选、不自动采用、head 冲突保留”的规则。
- 需要 Server final／HDR 渲染时，批次项生成 `jobID`，由 `scene.batch.remote` 提交；客户端保存 batch／item／target head 与 jobID 的映射。Server 结果回到同一批次作为候选，不直接改采用版本。
- 批次取消／重试只作用于未完成项；已完成候选和旧版本不删除；`undo` 仍检查目标 head 和版本依赖。

## 3. Server 作业队列

### 3.1 作业类型

| 类型 | 用途 | 资源 | 硬件 |
| --- | --- | --- | --- |
| `proxy.generate` | display／edit／linear proxy | CPU/GPU, IO | `image_module`；无模块时客户端生成 |
| `scene.proxy` | sceneProxy（AP1／HDR 线性表示） | GPU Vulkan/CPU, IO | `image_scene_batch` 或客户端生成 |
| `scene.render.final` | 单张场景图／HDR／SDR 最终渲染 | GPU Vulkan, memory | `image_scene_batch` |
| `scene.render.batch` | 多张／场景批次／模板渲染 | GPU Vulkan, memory | `image_scene_batch` |
| `legacy.render.final` | 旧 SDR 兼容配方最终渲染 | Vulkan/CPU | `image_sdr_batch` |
| `model.prefix` | denoise／superResolution／segmentation 确定性前缀 | GPU/CPU, model | `image_module` + 模型 |
| `generative` | Flux 等 | CUDA GPU, model, memory | 生成式模块 |

`image_module` 的硬件准入门槛：兼容 CUDA 的 NVIDIA GPU、最低显存／驱动、Vulkan 后端可用、feature flag 开启。实际图像算子优先 Vulkan；CUDA 只用于生成式 AI 栈，除非未来单独验证 CUDA 图像后端。

### 3.2 Lane 与优先级

| Lane | 内容 | 优先级 |
| --- | --- | --- |
| `library` | 归档、元数据、取回、备份 | 最高；不能被图像任务饿死 |
| `image-foreground-proxy` | 用户当前编辑所需代理生成 | 高 |
| `image-scene-final` | 场景图／HDR final／batch | 中高 |
| `image-legacy-final` | 旧 SDR 兼容 final／batch | 中高 |
| `image-background` | 预取代理、缓存预热 | 中 |
| `model-prefix` | 确定性降噪／超分／分割 | 按模型准入 |
| `generative` | Flux 等 | 按用户提交，独立 GPU 配额 |
| `maintenance` | 校验、清理、重建 | 低 |

规则：

- 每库加权公平；一个库的大批任务不能占满队列。
- `library` lane 有保留容量；图像 lane 队列满时拒绝或延后，不挤占资料库。
- 场景图／HDR lane 需要 Linux／Vulkan scene executor；未通过 039 等价验收时该 lane 关闭，不能把 legacy SDR 结果冒充场景输出。
- 同一库的单张 final 可优先于同库大批量；避免用户等待被批处理拖死。
- GPU 任务按显存和模型准入；显存不足排队，不超卖。

### 3.3 作业记录

```text
jobs(
  job_id TEXT PRIMARY KEY,
  library_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  priority INTEGER NOT NULL,
  state TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  input_manifest JSONB NOT NULL,
  recipe_hash TEXT,
  scene_graph_hash TEXT,
  output_state_hash TEXT,
  model_program_hash TEXT,
  compatibility_route TEXT,
  delivery_target TEXT,
  format TEXT,
  template_id TEXT,
  batch_id TEXT,
  target_head TEXT,
  scene_backend TEXT,
  engine_version TEXT,
  model_version TEXT,
  backend TEXT,
  resource_request JSONB NOT NULL,
  created_at TIMESTAMPTZ,
  admitted_at TIMESTAMPTZ,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  error TEXT,
  result JSONB,
  execution_receipt JSONB
)
job_attempts(job_id, attempt, worker_id, state, started_at, finished_at, error)
job_inputs(job_id, ordinal, content_id, file_id, role, required)
job_outputs(job_id, output_id, object_key, sha256, bytes, target, format, bit_depth, color_space, cicp, work_id, version_id, state, execution_receipt)
job_events(job_id, sequence, kind, payload, created_at)
worker_capabilities(worker_id, backends, cuda, vulkan, vram, models, last_seen)
```

- `job_id` 由客户端生成或 Server 按幂等规则分配；`unique(library_id, job_id)`。
- `request_hash` 绑定输入、场景图／旧配方、输出状态、模型前缀、模板／批次、目标 head、引擎、模型和输出；同 ID 不同 hash 拒绝。
- `compatibility_route` 区分 legacy SDR 与 scene graph；`delivery_target`／`format` 区分 HDR AVIF 与 SDR JPEG/PNG16；不匹配拒绝，不自动换路线。
- 状态：`submitted`、`queued`、`admitted`、`running`、`staged`、`published`、`failed`、`cancelled`、`reconcile`、`expired`。
- `staged` 通过输出校验后才能 `published`；`published` 唯一。
- 结果登记在 PostgreSQL + S3；客户端不直接改队列。

### 3.4 调度与租约

1. 客户端 `SubmitJob`；Server 校验能力、配额、输入。
2. 入队；返回 `jobID`、状态、队列位置（如可得）。
3. 调度器按 lane／优先级／资源选择 worker；写 `admitted`。
4. worker `claim` 租约；心跳；超时重领。
5. worker 执行；上传 S3 暂存；回报 `staged`。
6. Server 校验输出；PostgreSQL 事务登记派生资源／版本；`published`。
7. 客户端 `WatchJob`／`GetJob` 获取状态和结果。

- 同一作业同一时刻一个有效 lease；旧 token 不能发布。
- worker 崩溃／租约过期：作业回到 `queued` 或 `reconcile`；已发布结果不重复。
- 取消：`cancelling`；worker 协作停止；未发布暂存清理；已发布结果保留。
- 重试：同 `jobID`，新 attempt；输入不变；不重复发布。

### 3.5 背压与准入

- 队列长度、每库并发、每 worker 并发、显存、内存、模型驻留都有上限。
- 超限返回 `RESOURCE_EXHAUSTED`／`QUEUE_FULL`，客户端延后或提示；不无限重试。
- `library` lane 有保留容量；图像任务不能挤占。
- 生成式模型有独立显存配额；模型加载失败不自动换模型。
- 队列满时仍接受 `library` 基础请求；图像请求明确显示排队或拒绝。

## 4. 两边协同

### 4.1 提交

1. 客户端本地生成稳定 `jobID`（UUID）和 `requestHash`。
2. 客户端 `client_tasks` 写 `submit.remoteJob`，再 gRPC `SubmitJob`。
3. 成功：服务器返回 `jobID`、状态、能力；客户端写 `remote_job` 镜像，任务转 `watch.remoteJob`。
4. 失败：transient → 退避重试；permanent → 显示原因；uncertain → 查询同 `jobID`，不新建。
5. 客户端关闭窗口不取消 Server 作业；用户显式取消才传播。

### 4.2 状态同步

- gRPC `WatchJob` server-streaming 或 `GetJob` 轮询；断线后按 `afterSequence` 补事件。
- 客户端按 `job_id` 更新本地镜像；重复事件幂等；旧 sequence 丢弃。
- Server 状态权威；客户端不能把本地“完成”当 Server 已发布。
- `published` 后客户端下载结果，校验，登记候选；下载失败可重试。
- 结果事件包含 `inputHash`、`recipeHash`／`sceneGraphHash`、`outputStateHash`、`modelProgramHash`、`compatibilityRoute`、`deliveryTarget`、`format`、`engineVersion`、`outputHash`、`executionReceipt`（tiles、cache hits、dispatches、budget、peak bytes、CPU time）；客户端核对当前版本、目标 head 和输出目标。

### 4.3 取消

- 客户端取消：本地任务 `cancelling` → gRPC `CancelJob` → Server `cancelling` → worker 停止 → `cancelled`。
- 若 Server 已 `published`：取消无效，客户端按已发布结果核对；不删除母版。
- 若客户端离线：取消排队；重连后传播；本地不再等待。
- 取消不产生作品版本；临时 S3 对象清理。

### 4.4 未知结果

- 提交超时／断线：客户端标 `uncertain`；用同 `jobID` 查询。
- Server 返回 `queued/running/published/failed`；按状态恢复。
- 不自动用新 `jobID` 重发；避免重复付费／重复结果。
- 如果 Server 无记录且确认未接受，可重发同 ID；仍幂等。

### 4.5 重试

- 客户端 `retry.remoteJob` 沿用 `jobID`；Server 新 attempt。
- 输入／配方／引擎／模型不变；否则新作业。
- 旧结果保留；新结果不自动覆盖当前采用。
- 重试不产生第二个 `published` 结果。

## 5. 失败矩阵

| 故障 | 客户端 | Server |
| --- | --- | --- |
| 网络断开 | 任务 `waiting`；本地编辑继续 | 作业保留 |
| Server 重启 | 查询／补事件；不重复提交 | 运行中 → `reconcile`／重领 |
| S3 5xx | 退避重试 | 作业等待／重试 |
| 队列满 | 延后／提示 | 拒绝并给出原因 |
| 显存不足 | 不提交或等待 | 排队／拒绝 |
| 模型缺失 | 禁用入口 | 拒绝；不换模型 |
| 场景后端未移植 | 只显示 legacy 能力 | `image_scene_batch` 关闭 |
| 场景图／目标不匹配 | 拒绝提交 | 拒绝；不换路线 |
| HDR／SDR 格式不匹配 | 拒绝采用 | 拒绝；不静默降级 |
| 作业取消 | 停止等待 | 协作取消；清理暂存 |
| 结果下载失败 | 重试 | 结果保留 |
| 结果哈希不符 | 拒绝采用 | 标记输出异常 |
| 客户端重启 | 恢复 `client_tasks`；`running` → `waiting` | 作业继续 |
| 服务器恢复旧元数据 | 按 job ID 查询；不重发 | 需核对 job 记录 |

## 6. 队列可见性

- 客户端显示本地任务和远端作业的摘要，不阻塞画布。
- 状态：排队、运行、等待、已完成、失败、待核对、已取消。
- 不伪造 ETA；可显示“前面还有 N 个”或“等待 GPU”。
- 用户可取消／重试；失败显示原因和下一步。
- 队列详情可导出诊断，但不含令牌／密钥。

## 7. 验收

1. 客户端重启：`running` 任务不丢；网络任务恢复；未完成任务不重复。
2. 前台抢占：拖动时后台预取暂停；松手后恢复；画布不掉帧。
3. 同键去重：同一 editProxy 并发请求只生成一次；不同 key 不误合并。
4. Server 重启：运行中作业转待核对／重领；旧 lease 不能发布；客户端补差。
5. 队列公平：一个库大批量不阻塞另一个库 short job；library lane 保留容量。
6. 取消：客户端取消传播；Server 未发布暂存清理；已发布结果保留。
7. 未知结果：提交超时后用同 ID 查询，不重复建作业。
8. 结果下载：S3 presigned／Relay；SHA-256 校验；预览不当母版。
9. 能力缺失：无 CUDA／Vulkan／模型时入口禁用；资料库仍可用。
10. 生成式：模型加载失败不换模型；结果候选，不自动采用。
11. 场景批次：`SceneWorkflowBatch` 候选／head 冲突保留；远程 final 结果回到同一批次，不直接采用；旧 SDR 兼容不迁移。
12. HDR／SDR：HDR AVIF 与 SDR JPEG/PNG16 的 target／format 不可互换；未过色彩门只候选。
13. 场景后端：Linux／Vulkan scene executor 未通过时 `image_scene_batch` 关闭；legacy SDR 不能冒充场景输出。

## 8. 待决

| 编号 | 问题 | 建议 |
| --- | --- | --- |
| Q-D01 | 客户端队列并发默认值 | network 2–4、disk 2、CPU 1–2、GPU 1；按设备调整 |
| Q-D02 | 前台抢占策略 | 暂停 prefetch／background；取消非必要 GPU 任务 |
| Q-D03 | Server 队列公平 | 每库加权；library lane 保留 |
| Q-D04 | 队列位置展示 | 有准确信息才显示；否则只显示状态 |
| Q-D05 | 未知结果窗口 | 提交后查询至少一个超时周期；不自动新 ID |
| Q-D06 | 生成式配额 | 独立显存／并发；模型驻留策略 |
| Q-D07 | 结果候选 | 显式采用；不自动覆盖 |
| Q-D08 | 队列持久化 | 客户端 SQLite；Server PostgreSQL |
| Q-D09 | 跨设备 | 一库一客户端；不做跨设备队列共享 |
| Q-D10 | 观测 | 队列深度、等待、失败、GPU 利用率；不伪造 ETA |
