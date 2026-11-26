# 040 · Server 数据模型

2026-11-26 · 服务端逻辑实体、身份、归档资格、同步与备份代次。物理表名和 schema 编号在 S1 冻结时确定；本文件先固定不变量。产品要求见[规格](spec.md)，接口见[协议](protocol.md)。

## 1. 身份与权威边界

| 对象 | 稳定身份 | 权威方 | 不变量 |
| --- | --- | --- | --- |
| 资料库 | `libraryID` | 客户端创建，服务器绑定后共同引用 | 服务器不改写业务身份；恢复后仍为同一 `libraryID` |
| 设备 | `deviceID` | 服务器登记，客户端保存 | 恢复副本生成新设备身份；旧令牌不随备份恢复 |
| 操作 | `commandID`＋`deviceID` | 客户端发起，服务器受理 | 同一操作重复提交只生效一次；同 ID 不同载荷拒绝 |
| 拍摄 | `captureID` | 客户端目录 | 一次快门；RAW／JPEG 是不同文件 |
| 文件 | `fileID` | 客户端目录 | 改名、换路径不改变身份 |
| 内容 | `contentID = sha256 + byte_count` | 内容本身 | 相同字节可共享对象；不同来源和引用仍分别保留 |
| 副本 | `replicaID` | 客户端／服务器各自登记 | 本地、服务器主存、独立备份、引用盘分开 |
| 归档引用 | `archiveRefID` | 服务器由有效纳入派生 | 逐文件；排除项不创建；恢复纳入追加 |
| 拍摄组修订 | `groupID + revision` | 客户端产生，服务器保存 | 成员顺序、参与和缺帧可追溯；并发产生分支 |
| 作品／版本 | `workID + versionID` | 客户端产生，服务器保存 | 虚拟副本共享原件但独立编辑；旧版本不被静默覆盖 |
| 作业 | `jobID` | 客户端提交，服务器或本地执行 | 绑定冻结输入；同一作业只登记一个结果 |
| 备份代次 | `generationID` | 服务器创建 | 同代目录快照、对象清单和资源；独立目标单独校验 |

**两种权威并存。** 客户端目录是本地编辑与离线操作的权威；服务器是已同步共享状态、归档对象和备份代次的权威。服务器不接收活动 SQLite 文件，也不把服务器状态直接覆盖到本地未同步操作上。

## 2. 服务端逻辑实体

### 2.1 服务器与资料库

| 实体 | 关键字段 | 说明 |
| --- | --- | --- |
| `srv_server` | `serverID`、版本、TLS 指纹、创建时间 | 单节点服务器身份；指纹用于客户端确认 |
| `srv_libraries` | `libraryID`、显示名、目录 schema、状态、创建时间 | 一个服务器可保管多个库；状态含 `active`、`readOnly`、`restoring` |
| `srv_devices` | `deviceID`、名称、令牌摘要、登记时间、最后在线、撤销时间、客户端版本 | 令牌只存摘要；设备可访问多个库 |
| `srv_library_members` | `libraryID`、`deviceID`、角色 | 首版单所有者；角色预留但不实现团队权限 |
| `srv_library_snapshots` | `libraryID`、`snapshotID`、目录对象、清单对象、水位、校验时间 | 新设备引导和异机恢复使用；不是活动数据库共享 |

### 2.2 操作与同步

| 实体 | 关键字段 | 说明 |
| --- | --- | --- |
| `srv_operations` | `libraryID`、`serverRevision`、`commandID`、`deviceID`、`baseRevision`、`action`、`payloadVersion`、`payloadSHA256`、`payload`、`result`、`appliedAt` | 每库单调修订；`unique(libraryID, commandID)` |
| `srv_entity_heads` | `libraryID`、`entityType`、`entityID`、`revision`、`updatedAt` | 用于快速判断实体是否有更新；不是业务真值 |
| `srv_conflicts` | `conflictID`、`libraryID`、实体、字段、基线、双方值、设备、状态、解决操作 | 同一人工决定冲突保留双方；解决产生新操作 |
| `srv_change_cursor` | `libraryID`、`deviceID`、最后拉取修订、最后推送修订 | 设备私有游标；可用于重放与诊断 |
| `srv_outbox_receipts` | `libraryID`、`commandID`、请求摘要、结果摘要 | 服务器端幂等收据；可与客户端本地收据对账 |

**操作载荷。** 统一包含：`apiVersion`、`libraryID`、`deviceID`、`commandID`、`baseRevision`、`payloadVersion`、`action`、`payload`、产生时间。动作名沿用现有目录命令（`session.*`、`occurrence.put`、`org.*`、`group.revise`、`inspect.*`、`discover.*` 等），编辑域使用现有编辑命令或明确的同步投影。

**修订语义。**

- `serverRevision` 是每库全序，用于拉取和审计，不要求客户端全量顺序应用。
- 实体 `revision` 用于冲突判断；不同实体可并行。
- `baseRevision` 是客户端已知的实体或库修订；服务器允许落后修订在无冲突字段上合并。
- 同字段冲突时不自动写入投影；实体保留共同基线并记录冲突，直到用户选择。
- 依赖缺失时返回 `dependency_missing` 和所需实体／修订；客户端先拉取再重试。

### 2.3 归档与对象

| 实体 | 关键字段 | 说明 |
| --- | --- | --- |
| `srv_archive_refs` | `archiveRefID`、`libraryID`、`fileID`、`contentID`、`scopeID`、`projectID`、`sessionID`、`filename`、`role`、`basis`、`state`、`createdAt`、`verifiedAt` | 逐文件归档资格；`basis` 为 `admitted`、`sequenceOnly`、`restored` |
| `srv_objects` | `contentID`、`sha256`、`byteCount`、`state`、`storageClass`、`createdAt`、`verifiedAt`、`lastCheckedAt` | 内容寻址主存对象；`state` 含 `staging`、`available`、`corrupt`、`missing`、`quarantined` |
| `srv_object_replicas` | `contentID`、`location`、`kind`、`state`、`verifiedAt` | `kind` 含 `main`、`backup`、`clientCache`（客户端缓存仅诊断，不作为服务器权威） |
| `srv_uploads` | `uploadID`、`libraryID`、`deviceID`、`contentID`、`expectedSHA256`、`expectedBytes`、`receivedBytes`、`ranges`、`state`、`expiresAt` | 隔离暂存；完成前不可见为归档对象 |
| `srv_archive_events` | `eventID`、`archiveRefID`、`kind`、`detail`、`createdAt` | 创建、恢复纳入、校验、缺失、修复、删除意图 |

**资格派生规则。**

1. 只从封存会话的逐文件处置读取：`admitted`、`sequenceOnly`、`restored` 产生归档引用；`excluded`、`failed`、`pending`、`reconcile` 不产生。
2. 项目精筛、星级、组参与、缓存扫描、备份扫描和远程作业不能直接新增引用。
3. 恢复纳入必须带来源、核验时间和可读原件证据；追加事件，不修改原封存清单。
4. `contentID` 已存在时只增加引用；不同文件、项目、会话仍分别保留。
5. 删除归档引用只表示业务不再需要该引用；物理回收需满足第 7 节条件。

### 2.4 备份与恢复

| 实体 | 关键字段 | 说明 |
| --- | --- | --- |
| `srv_backup_generations` | `generationID`、`libraryID`、模式、目录快照对象、清单对象、状态、创建时间、校验时间、目标 | 一代不可变备份 |
| `srv_backup_objects` | `generationID`、`contentID`、`kind`、`state`、`verifiedAt`、`error` | 原件、资源、成片分别记录 |
| `srv_backup_targets` | `targetID`、类型、位置、独立性声明、容量、最后校验 | 目标凭据加密保存，不进入日志 |
| `srv_restore_runs` | `restoreID`、`generationID`、目标、阶段、状态、开始／完成时间 | 可续跑；部分成功不标完整 |
| `srv_integrity_reports` | `reportID`、范围、缺失、损坏、不可读、引用不一致、创建时间 | 周期检查与手动检查共用 |

**备份代次内容。**

- 同代目录快照：使用现有目录 schema 的可打开 SQLite 快照，含 schema 版本、操作水位、清单摘要和完整性检查结果。
- 引用原件：按 `srv_archive_refs` 收集，逐对象记录 `contentID`、哈希、字节数、文件名、来源关系和业务引用。
- 资源：编辑配方所需 LUT、模型清单、历史外观、必要 sidecar；模型权重是否入备份按许可和体积单独决定。
- 成片与派生作品：受管母版和来源关系；外部导出路径不作为备份对象。
- 代理、缩略图、可重建搜索索引：不在必需清单内；恢复后可重建。
- 设备令牌、服务器私钥、备份目标凭据：不进入资料库备份；恢复后重新登记。

### 2.5 作业与执行端

| 实体 | 关键字段 | 说明 |
| --- | --- | --- |
| `srv_workers` | `workerID`、能力、CPU／GPU／内存、引擎、模型、最后心跳 | 执行端注册；缺能力不接单 |
| `srv_jobs` | `jobID`、`libraryID`、`projectID`、动作、配方版本、引擎、模型、状态、创建／开始／完成时间 | 作业描述与本地共用 |
| `srv_job_inputs` | `jobID`、序号、`captureID`、`fileID`、`contentID`、角色、来源版本、缺失原因 | 冻结输入；按序保存 |
| `srv_job_attempts` | `jobID`、尝试号、worker、状态、开始／结束、错误 | 重试可审计 |
| `srv_job_outputs` | `jobID`、输出 ID、资源、`workID`、`versionID`、状态、登记时间 | 唯一约束防重复登记 |
| `srv_job_events` | `jobID`、事件、详情、时间 | 排队、领取、进度、取消、完成、过期 |

**作业状态。** `draft`、`needsInput`、`queued`、`running`、`waiting`、`staged`、`published`、`failed`、`cancelled`、`reconcile`。只有 `staged` 通过输出校验后才能 `published`；`published` 不可重复。

## 3. 同步冲突矩阵

| 数据 | 并发修改 | 服务器处理 | 客户端显示 |
| --- | --- | --- | --- |
| 评分、旗标、独立入选／排除决定 | 同字段 | 保留双方值和设备来源，实体保持共同基线，等待解决 | 冲突列表；选择后产生新修订 |
| 评分、旗标、决定 | 不同字段 | 逐字段合并 | 已同步 |
| 标签 | 双方都追加 | 集合并集 | 已同步 |
| 标签 | 一方移除、一方追加 | 移除与追加分别保留，移除冲突 | 冲突；可选择保留或恢复 |
| 元数据／IPTC | 不同字段 | 字段级合并 | 已同步 |
| 元数据／IPTC | 同字段 | 保留双方值，等待解决 | 冲突 |
| 集合成员 | 双方添加 | 并集，按稳定 ID 去重 | 已同步 |
| 集合成员 | 一方移除、一方添加 | 保留添加与移除意图，等待解决 | 冲突 |
| 组顺序／参与 | 同一组修订 | 产生新修订分支，不丢帧、不静默重排 | 分支选择；缺帧提示 |
| 编辑配方 | 同一作品 | 各自成为版本分支，不覆盖旧版本 | 版本列表；显式采用 |
| 导入会话封存 | 同会话 | 封存不可变；新导入另开会话 | 不合并 |
| 归档资格 | 恢复纳入 | 追加引用和事件，不修改原清单 | 新增引用 |
| 删除／移除 | 一端删除、一端修改 | 删除意图与修改都保留，不物理删除 | 冲突；确认回收 |
| 分析／机器结果 | 输入版本变化 | 结果标记过期，不覆盖当前决定 | 过期结果可回看 |
| 本机路径、缓存、窗口 | 任意 | 不进入共享同步 | 设备私有 |

**不做通用 CRDT。** 首版按领域规则合并，宁可保留冲突，也不引入无法解释的自动收敛。

## 4. 内容与对象存储

```
data/
  server.sqlite                 # 服务器元数据、设备、作业、备份代次
  libraries/<libraryID>/        # 每库目录与操作日志
    library.sqlite
    LibraryResources/           # 已登记资源
  objects/<sha256[0:2]>/<sha256># 主存内容寻址对象
  staging/<uploadID>/           # 隔离上传，完成前不可见
  backups/<generationID>/       # 备份暂存与清单
  proxies/                      # 可重建代理与缩略图
  logs/
```

- 对象写入遵循“临时文件 → fsync → 原子改名 → 目录 fsync”，成功后更新 `srv_objects`。
- `contentID` 由 `sha256` 与 `byte_count` 组成；对象路径只使用哈希，不使用用户文件名。
- 主存和备份使用相同内容寻址布局，便于逐对象核对和断点补缺；备份目标必须是独立故障域。
- 代理键包含源内容、生成版本、尺寸、色彩和渲染配方；代理可删除并重建，不进入必需备份。
- 临时上传和未完成备份代次有到期清理；清理不得触碰已登记对象或唯一副本。

## 5. 客户端同步状态

客户端新增但不共享的本地表（逻辑名）：

| 表 | 作用 |
| --- | --- |
| `sync_outbox` | 待发送操作：命令 ID、实体、基准修订、载荷版本、动作、载荷、创建时间、重试次数 |
| `sync_cursor` | 每个服务器／库的最后拉取服务器修订和最后推送修订 |
| `sync_conflicts` | 本地已知冲突、双方值、来源、解决状态 |
| `server_bindings` | 服务器 ID、指纹、地址、库绑定、设备 ID；令牌存钥匙串 |
| `cache_state` | 本地原件／代理可用级别、校验时间、固定范围、可释放原因 |
| `transfer_state` | 上传／取回／备份的断点、已收区间、重试和错误 |

这些是设备私有状态，不进入共享业务同步，也不写入资料库包作为跨设备事实。

## 6. 版本与迁移

- `apiVersion`：HTTP 接口大版本；不兼容写入拒绝。
- `payloadVersion`：单条操作载荷版本；未知版本拒绝修改，可只读或跳过。
- `catalogSchemaVersion`：每库目录 schema；服务器和客户端都必须能识别。
- `snapshotFormat`：备份代次与引导快照格式。
- `engineVersion` / `modelVersion`：作业与输出重现依据。
- 升级流程：一致备份 → 私有副本迁移 → 完整性与抽样对账 → 短写入屏障 → 切换 → 重开核对。失败回到备份，不覆盖迁移前快照。
- 旧客户端遇到更高写版本：安全退出或进入受支持只读路径；不得忽略未知写语义。
- 回退：只有在已验证的回放或导出能保留新操作时才允许；否则保留新版并阻止旧版写入。

## 7. 保留、回收与删除

1. 默认不自动删除唯一原件、唯一归档引用或唯一备份代次。
2. 物理回收对象需同时满足：无任何 `srv_archive_refs` 引用、未被保留备份代次引用、超过保留期、没有进行中的恢复或作业输入。
3. 删除是带操作 ID、来源和时间的意图；先标记，后回收。用户可在回收期限前撤销。
4. 删除一个文件引用不删除仍被其他文件、项目或备份代次使用的内容对象。
5. 独立备份代次按保留策略轮换；删除旧代次前确认新代次已完整校验。
6. 代理、缩略图和搜索索引可随时重建，不属于唯一副本。

## 8. 规模与查询边界

- 目录元数据按库保存在 SQLite；查询使用索引、分页和稳定游标，不把整库资产加载进内存。
- 服务器 API 的列表默认分页；归档、备份、冲突和作业列表都带总数和稳定续页。
- 跨库检索由客户端合并或显式请求；每个结果必须带库和覆盖状态。
- 100 TB／200 万文件是设计参照，不是 Server 1.0 验收。S5 使用现有库和受控放大样本记录文件数、拍摄数、关系数、版本数、内存、索引体积、归档吞吐和恢复时长。
- 单库单写队列是 V1 的明确约束；若并发写或规模测量不足，迁移到 PostgreSQL 或分片库，API 和业务身份保持不变。
