# 040 · PostgreSQL 与对象模型

2026-11-27 · 服务端元数据、所有权、对象索引、上传意图与快照。物理表名和迁移编号在 S0 冻结；本文件固定不变量。客户端本地 SQLite 仍是离线目录；客户端不直连 PostgreSQL。产品要求见[规格](spec.md)，备份恢复见[元数据备份](metadata-backup.md)，协议见[协议](protocol.md)。

## 1. 角色与权威边界

| 对象 | 稳定身份 | 权威方 | 不变量 |
| --- | --- | --- | --- |
| 资料库 | `libraryID` | 客户端创建，Server 登记 | 一库一所有者；不跨库引用 |
| 设备 | `deviceID` | Server 登记 | 恢复副本生成新设备；旧令牌可撤销 |
| 库所有权 | `libraryID + ownershipEpoch` | Server | 同一时间一个写者；旧 epoch 被 fencing 拒绝 |
| 操作 | `libraryID + commandID` | 客户端发起，Server 收据 | 重复只生效一次；同 ID 不同载荷拒绝 |
| 内容 | `contentID = sha256 + byteCount` | 内容本身 | 不可变；跨库不去重 |
| 上传意图 | `libraryID + uploadID` | Server | 未完成不可见；过期清理 |
| 归档引用 | `libraryID + archiveRefID` | Server | 逐文件；排除项不创建 |
| 客户端快照 | `libraryID + snapshotID + revision` | 客户端生成，Server 索引 | 修订不超前；对象在 S3 |
| 元数据备份 | `backupID` | Server | 一致快照；未验证不可恢复 |

**客户端 SQLite。** 保存完整本地目录、离线操作队列和缓存状态；Server 不需要重建客户端全部业务表。Server 保存操作日志、对象索引、归档引用、快照索引和业务状态；恢复客户端时用快照 + 操作日志。

## 2. 身份、所有权与设备

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `libraries` | `library_id`、名称、`owner_device_id`、`ownership_epoch`、`quota_bytes`、`used_bytes`、`created_at` | 一库一所有者；`used_bytes` 由对象汇总维护 |
| `devices` | `device_id`、名称、`token_key_id`、登记时间、最后在线、撤销时间、客户端版本 | 当前令牌引用在 `device_tokens`；不存明文 |
| `library_members` | `library_id`、`device_id`、角色 | V1 仅 owner；只读/转移预留 |
| `library_leases` | `library_id`、`owner_device_id`、`epoch`、`fencing_token`、`acquired_at` | 可重建；恢复后清空或保留 epoch |
| `server_identity` | `ca_id`、`cert_serial`、`spki_sha256`、`not_before`、`not_after`、`status`、`secret_ref` | 公有证书可入元数据备份；私钥在 secret bundle |
| `device_tokens` | `token_id`、`device_id`、`token_hash`、`token_key_id`、`created_at`、`last_used_at`、`revoked_at` | 随机不透明令牌；哈希入备份；保留轮换历史 |

## 3. 操作与收据

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `operations` | `library_id`、`server_revision`、`command_id`、`device_id`、`base_revision`、`action`、`payload_version`、`payload_sha256`、`payload_json`、`applied_at` | 每库单调；`unique(library_id, command_id)` |
| `operation_receipts` | `library_id`、`command_id`、`result_revision`、`receipt_json`、`created_at` | 幂等返回；与 payload hash 绑定 |
| `library_revisions` | `library_id`、`revision`、`updated_at` | 当前库修订；可与 operations 最大修订核对 |
| `outbox` | `event_id`、`library_id`、`kind`、`payload_json`、`created_at`、`published_at` | gRPC 事件和后台任务；恢复后可重建 |

**操作语义。** 一条操作是客户端业务命令的不可变描述。Server 校验库所有权、`command_id`、`payload_version`、依赖和配额；在一个 PostgreSQL 事务中写入操作、收据和 outbox。客户端不直连数据库。

**恢复对账。** Server 恢复到修订 `R` 后，客户端可补交 `R+1..N`；重复 `command_id` 去重。Server 有而客户端没有的操作由客户端拉取。单客户端单写者，不需要字段级冲突合并。

## 4. 对象、上传与归档引用

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `upload_intents` | `upload_id`、`library_id`、`file_id`、`content_id`、`expected_sha256`、`expected_bytes`、`object_key`、`s3_upload_id`、`state`、`mode`、`expires_at` | `state`：`reserved`、`uploading`、`uploaded`、`verified`、`failed`、`expired`、`aborted`；`mode`：`direct`、`relay`、`mixed` |
| `upload_parts` | `upload_id`、`part_number`、`etag`、`bytes`、`sha256`、`source`、`received_at` | Direct／Relay 共用 part 号；用于跳过已完成 part |
| `objects` | `library_id`、`content_id`、`sha256`、`byte_count`、`bucket`、`object_key`、`media_kind`、`encoding`、`bit_depth`、`color_space`、`target`、`cicp`、`state`、`created_at`、`verified_at`、`last_checked_at` | 主键 `(library_id, content_id)`；`state`：`available`、`missing`、`corrupt`、`quarantined`；HDR AVIF、SDR JPEG/PNG16、代理分别记录编码、位深、色彩和 CICP |
| `archive_refs` | `archive_ref_id`、`library_id`、`file_id`、`content_id`、`scope_id`、`project_id`、`session_id`、`filename`、`role`、`basis`、`state`、`created_at` | `basis`：`admitted`、`sequenceOnly`、`restored` |
| `object_events` | `event_id`、`library_id`、`content_id`、`kind`、`detail`、`created_at` | 创建、校验、缺失、修复、删除意图 |

**对象 key：**

```text
libraries/<libraryID>/objects/<sha256[0:2]>/<sha256>
libraries/<libraryID>/staging/<uploadID>/<partNumber>
libraries/<libraryID>/manifests/<generationID>.json
```

- `objects` 不允许不同内容覆盖；同一内容已存在时复用并校验。
- `staging/` 可配置 S3 生命周期；`objects/` 不允许自动过期。
- 同一内容跨库不去重；`objects` 主键带 `library_id`。
- 文件名、来源路径、角色只存数据库，不进入对象 key。

**归档资格。**

1. 只从封存会话的 `admitted`、`sequenceOnly`、`restored` 产生引用。
2. `excluded`、`failed`、`pending`、`reconcile` 不产生。
3. 项目精筛、星级、组参与、S3 扫描和远程作业不能新增引用。
4. 恢复纳入追加事件，不修改原封存清单。
5. 删除一个引用不等于删除对象；对象回收需无引用、无保留代次、超过期限。

## 5. 上传状态机

```text
reserved
  ├─ direct upload ──→ uploading ──→ uploaded ──→ verified ──→ available
  └─ relay upload ───→ uploading ──→ uploaded ──→ verified ──→ available
                               ↓            ↓
                            expired       failed → abort/cleanup
```

- `CreateUpload` 在 PostgreSQL 写 intent；Server 创建 S3 multipart；返回 presigned part URL。
- Direct part 和 Relay part 使用同一 `part_number`；Server 通过 `ListParts` 跳过已存在 part。
- `CompleteUpload` 完成 multipart，HEAD 校验 key、长度、SHA-256；PostgreSQL 事务登记 `objects` 和 `archive_refs`。
- 重复 `CompleteUpload` 返回原收据；失败保留原因；过期 abort multipart。
- S3 与 PostgreSQL 无分布式事务；用 intent 状态、内容寻址和孤儿对账保证最终一致。

## 6. 客户端快照与恢复

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `library_snapshots` | `snapshot_id`、`library_id`、`revision`、`object_key`、`sha256`、`bytes`、`created_at`、`verified_at` | 客户端 SQLite 库包或等价目录快照；存 S3 |
| `snapshot_events` | `snapshot_id`、`kind`、`detail`、`created_at` | 上传、校验、恢复、过期 |

- 客户端在检查点或会话完成时上传快照；Server 记录索引并校验摘要。
- 快照修订不得大于当前库修订；恢复客户端时取最新快照，补 `revision` 之后的操作。
- 快照对象缺失时列出来源；不能把空目录当成完整恢复。

## 7. 作业预留（Server 1.1）

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `jobs` | `job_id`、`library_id`、`action`、`recipe_version`、`scene_graph_hash`、`output_state_hash`、`model_program_hash`、`delivery_target`、`format`、`compatibility_route`、`template_id`、`batch_id`、`target_head`、`engine`、`model`、`state`、`execution_receipt`、`created_at` | 与本地作业描述共用；场景图、旧 SDR 兼容路线、HDR／SDR 目标必须分开；receipt 记录 tiling／cache／budget |
| `job_inputs` | `job_id`、`ordinal`、`content_id`、`file_id`、`role`、`required` | 冻结输入 |
| `job_attempts` | `job_id`、`attempt`、`worker_id`、`state`、`error` | 租约与重试 |
| `job_outputs` | `job_id`、`output_id`、`object_key`、`work_id`、`state` | 唯一发布 |

1.0 只建立身份和表结构，不开放执行；1.1 按 [041](../041-server-image-editing/spec.md) 单独验收。

### 7.1 037／038／039 资源

- **场景图。** `DevelopmentRecipe` schema 4 的 `sceneGraph`、输出状态（`route`、`sdrTrim`）和 `DevelopmentSceneModelV1` 模型前缀进入操作载荷／客户端快照；Server 只按不透明版本化 JSON 保存、索引和恢复，不自行迁移旧 SDR 配方。
- **兼容路线。** 旧 SDR 配方、兼容显影图与场景图是不同路线；一条记录只能有一个 `engineVersion`／`compatibility_route`，不能把旧 SDR 结果标记为场景 HDR。
- **模板与批量。** `SceneWorkflowTemplate`、`SceneWorkflowBatch` 的 header／item／candidate、目标 head 和冲突状态属于客户端目录；随库快照保存。Server 作业若引用它们，只保存冻结的模板／批次身份和输入摘要。
- **交付目标。** HDR AVIF 10 位 Rec.2020／PQ、SDR JPEG8、PNG16 分别记录 target、format、bit depth、ICC／CICP 和 SDR 派生参数；不能只按扩展名判断语义。
- **模型前缀。** denoise → superResolution? → segmentation* 是有序、确定性前缀；Flux／Seedream 生成候选不属于该前缀，单独记录模型、输入和候选。
- **服务端执行。** Rust scene executor 当前是 macOS Metal-only；Linux／Vulkan 的 scene executor 未实现前，Server 只能执行已验证的点配方子集，不能宣称 HDR／DAG 批处理可用。

## 8. 配额、分区与规模

- 每库 `quota_bytes` 和 `used_bytes`；写入前检查，超限返回 `RESOURCE_EXHAUSTED`。
- 单库 10TB 级、约 20 万对象；PostgreSQL 只存元数据，不存字节。
- `operations`、`archive_refs`、`objects` 可按 `library_id` 哈希分区；V1 可不分区，但索引必须带 `library_id`。
- 不使用 `SELECT *` 全表扫描；列表分页、稳定游标。
- 跨库查询不做；客户端显式切换库。

## 9. 保留、垃圾桶与过期

| 数据 | 默认 | 行为 |
| --- | --- | --- |
| 本地原件缓存 | 30 天未用或磁盘压力 | 设备侧回收；需对象可用、外部冷备、未固定、未同步、非唯一 |
| 代理 | 90 天 | 可重建 |
| 垃圾桶 | 30 天 | 可恢复；到期由 Server 回收 |
| 草稿版本 | 90 天 | 只清理未采用草稿 |
| 采用版本 | 不自动过期 | 用户显式删除 |
| 同步墓碑 | 30–90 天 | 覆盖离线窗口；之后必须重新引导 |
| 上传暂存 | 7 天 | abort multipart；S3 生命周期兜底 |
| 元数据备份 | 日 30／周 8／月 12 | 最后已验证代次不自动删除 |
| 审计 | 可配置 | 不因普通缓存清理删除 |

`objects/` 不配置 S3 自动过期；S3 生命周期仅用于 `staging/`、`orphan/` 等临时前缀。

## 10. 版本与迁移

- `grpc_api_version`、`proto_version`、`postgres_schema_version`、`backup_format_version`、`object_store_profile` 分别版本化。
- 迁移前创建并验证元数据备份；迁移在隔离数据库预演。
- 未知写版本拒绝；旧客户端可只读或安全退出。
- 证书／令牌密钥版本与元数据 schema 分开；secret bundle 带版本和 key ID。

## 11. 不变量清单

1. 所有对象、引用、操作、快照都属于一个 `library_id`；无跨库外键。
2. `archive_refs` → `objects` 必须存在；`objects` 至少一个引用或保留代次。
3. `content_id`、`sha256`、`byte_count`、`object_key` 自洽。
4. 每库一个 owner 和一个 epoch；旧 epoch 写入拒绝。
5. 每库 `server_revision` 单调；`command_id` 唯一；收据 hash 一致。
6. `used_bytes` = 该库唯一对象字节和；≤ 配额。
7. 上传 intent 不进入归档引用，直到 verified。
8. 运行中作业恢复后转 `reconcile`，不自动发布。
9. 元数据备份必须包含证书公有部分、令牌哈希和 secret bundle 引用；私钥不入普通 dump。
10. 未验证备份不得作为恢复来源。
11. 场景图、输出状态、模型前缀、模板／批量身份和 HDR／SDR 交付元数据必须随版本保存；旧 SDR 兼容记录不得被静默重写为场景图。
12. 服务端作业的 `compatibility_route`、`delivery_target` 和 `format` 必须与输入版本一致；不匹配时拒绝，不自动换路线。
