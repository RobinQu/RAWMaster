# 040 · 元数据一致性、备份与恢复

2026-11-27 · Server 端 PostgreSQL 元数据的逻辑一致性、全量备份、验证与隔离恢复。底层 PostgreSQL／S3 的 HA 与持久性由基础设施负责；本文件设计的是 RAWMaster 自身的业务恢复能力。存储见[存储](storage.md)，安全见[安全](security.md)，数据模型见[数据模型](data-model.md)。

## 1. 目标与边界

### 1.1 必须做到

- 备份与恢复**同一个逻辑时点**的 PostgreSQL 元数据和 S3 对象清单。
- 备份能恢复到空 PostgreSQL，不依赖原服务器本地磁盘。
- 恢复前能验证 dump、清单、checksum、schema、引用和对象存在性。
- 客户端重连后能对账未同步操作，不静默丢操作。
- 证书、令牌哈希、私钥／pepper 的备份边界清楚：公有部分入元数据备份，私密部分入加密 secret bundle。
- 备份和恢复过程可审计、可重复、可演练。

### 1.2 不负责

- S3／ZFS 的 RAID、纠删码、跨站点复制和介质故障。
- PostgreSQL 主备切换、PITR、WAL 归档本身；这些可由 pgBackRest／WAL-G／云数据库承担。
- 复制 S3 对象字节；对象由 S3 和现有冷备负责。元数据备份只保存对象清单和引用。
- 客户端本地 SQLite 的完整备份；由客户端库包和快照负责，Server 保存索引与副本。

## 2. 元数据范围

| 数据 | 入元数据备份 | 说明 |
| --- | --- | --- |
| `libraries`、`devices`、`library_members` | 是 | 库、设备、所有权、配额 |
| `server_identity`、公有证书链、SPKI | 是 | 私钥不入普通 dump |
| `device_tokens` 哈希、key ID、撤销状态 | 是 | 不存明文令牌 |
| `operations`、`operation_receipts`、`library_revisions` | 是 | 操作日志和收据；场景图、输出状态、模型前缀随操作载荷保存 |
| `objects`、`archive_refs`、`object_events` | 是 | 对象索引和归档引用；HDR／SDR 交付目标、格式、位深、ICC／CICP 一并保存 |
| `library_snapshots`、`snapshot_events` | 是 | 快照索引；快照字节在 S3 |
| `jobs`、`job_inputs`、`job_attempts`、`job_outputs` | 是 | 历史作业；运行中恢复后转待核对 |
| `upload_intents`、`upload_parts` | 否 | 瞬态；恢复后作废并清理 |
| `library_leases`、fencing tokens | 否 | 重建；不恢复旧租约 |
| `outbox` | 否 | 从当前状态重建 |
| 审计日志 | 可配置 | 可全量或按保留期 |
| S3 对象字节 | 否 | 由 S3／冷备负责 |
| CA 私钥、服务器私钥、令牌 pepper／签名密钥、S3 凭据 | 否 | 单独加密 secret bundle |
| gRPC／TLS 配置、非秘密参数 | 可选 | 单独 config 备份；不含密钥 |

**设备令牌。** 推荐随机不透明令牌 + SHA-256 哈希；数据库和备份不含明文，恢复后设备继续使用原令牌。若使用带 pepper 的 HMAC，pepper 必须进 secret bundle；丢失则全部令牌失效，需要重新登记。

**证书。** 公有证书链、序列号、SPKI、SAN、有效期进元数据备份；私钥进 secret bundle。单张自签名证书和私有 CA 都适用；私有 CA 更利于轮换。

## 3. 一致性不变量

`metadata doctor` 至少检查：

1. **Schema／格式**：应用、PostgreSQL schema、备份格式、proto 版本可识别。
2. **约束**：外键、唯一键、CHECK、非空。
3. **操作日志**：每库 `server_revision` 连续；`command_id` 唯一；收据 payload hash 匹配。
4. **所有权**：每库一个 owner；epoch 单调；owner 设备存在。
5. **对象**：`content_id`、`sha256`、`byte_count`、`bucket`、`object_key` 自洽；key 符合 `libraries/<libraryID>/objects/<sha2>/<sha256>`；HDR AVIF／SDR JPEG／PNG16 的 target、format、bit depth、ICC／CICP 与对象索引一致。
6. **归档引用**：每个引用指向同库对象；每个对象至少一个引用或保留代次引用；无跨库引用。
7. **配额**：`used_bytes` 等于该库唯一对象字节和；≤ `quota_bytes`。
8. **上传意图**：没有未过期活动残留；状态合法；part 号不冲突。
9. **作业**：输入／输出引用完整；`published` 唯一；运行中恢复后转 `reconcile`；`scene_graph_hash`、`output_state_hash`、`model_program_hash`、`compatibility_route`、`delivery_target`、`format` 与输入版本一致；scene execution receipt 可读且与输出绑定。
10. **快照**：`revision` 不超前；S3 快照对象存在；摘要匹配；场景工作流模板／批量候选身份随客户端快照保存。
11. **outbox／审计**：事件 ID 唯一；可从当前状态重建。
12. **S3 清单**：对象数／字节数一致；抽样 HEAD；恢复时全量 HEAD。
13. **孤儿**：S3 有对象但无 DB 引用；DB 有对象但 S3 缺失。
14. **证书／令牌**：SPKI 与证书匹配；token hash 非空；secret ref 可解析（不读取私钥明文）。

失败时输出具体库、表、ID、原因；不自动删除。孤儿、缺失、损坏进入报告和人工／异步修复。

## 4. 一致快照

### 4.1 快照流程

1. 专用连接执行 `BEGIN ISOLATION LEVEL REPEATABLE READ`。
2. `SELECT pg_export_snapshot()` 得到 `snapshot_id`；`SELECT pg_current_wal_lsn()` 记录 LSN。
3. 用 `pg_dump --snapshot=<snapshot_id> --format=custom` 导出元数据。
4. 在同一事务中查询 `objects`、`archive_refs`、`library_snapshots`，流式生成对象清单。
5. 记录行数、字节数、对象数、归档引用数、作业数。
6. 提交事务。
7. 计算 dump／清单／checksums，上传 S3。

`pg_dump` 使用同一导出快照，保证 dump 和对象清单不是两个时点。元数据量通常小，可临时文件；也可流式 `pg_dump -Fc` 到 S3 multipart。

### 4.2 备份格式

```text
backups/metadata/<generationID>/
  manifest.json
  metadata.dump
  object-manifest.ndjson.zst
  library-snapshots.json
  checksums.json
```

- `metadata.dump`：`pg_dump -Fc`，含 schema 和数据。
- `object-manifest.ndjson.zst`：每行 `libraryID`、`contentID`、`sha256`、`bytes`、`bucket`、`key`、`mediaKind`、`target`、`format`、`bitDepth`、`colorSpace`、`cicp`、`state`、`archiveRefIDs`、`verifiedAt`。
- `library-snapshots.json`：快照 ID、修订、S3 key、SHA-256、字节、验证时间。
- `checksums.json`：所有文件的 SHA-256。
- `manifest.json`：

```json
{
  "formatVersion": 1,
  "backupID": "...",
  "createdAt": "2026-11-27T...",
  "appVersion": "...",
  "postgresVersion": "...",
  "postgresSchemaVersion": 1,
  "protoVersion": 1,
  "snapshotID": "...",
  "walLSN": "...",
  "dump": {"key": "...", "sha256": "...", "bytes": 0},
  "objectManifest": {"key": "...", "sha256": "...", "bytes": 0, "count": 0, "contentBytes": 0},
  "librarySnapshots": {"key": "...", "sha256": "...", "bytes": 0, "count": 0},
  "counts": {
    "libraries": 0, "devices": 0, "operations": 0, "objects": 0,
    "archiveRefs": 0, "jobs": 0, "snapshots": 0,
    "sceneGraphVersions": 0, "hdrArtifacts": 0, "sdrArtifacts": 0
  },
  "retention": "daily",
  "verifiedAt": null,
  "verification": null
}
```

### 4.3 保留与存储

- 默认全 Server 全量逻辑备份；按库过滤恢复作为后续。
- 每日一次；升级前、迁移前、证书轮换前、手动触发。
- 日 30／周 8／月 12；最后一个已验证代次永不自动删除。
- 备份放独立前缀或独立 bucket；可由现有 TrueNAS 冷备再次复制。
- S3 SSE／服务端加密；secret bundle 额外加密。TLS 只保护传输。

## 5. 备份验证

“上传成功”不等于“可恢复”。验证步骤：

1. 下载或读取 `manifest.json`、`metadata.dump`、`object-manifest`、`checksums`。
2. 校验所有文件 SHA-256 和字节数。
3. 在临时 PostgreSQL 数据库执行 `pg_restore`。
4. 运行 schema 迁移到当前版本；只升不降。
5. 运行 `metadata doctor`。
6. 对比 manifest 的行数、对象数、字节数、归档引用数。
7. 抽样 HEAD S3 对象（例如每个库 20 个，加最近写入）；全量对象检查可异步。
8. 写入 `verifiedAt` 和验证回执；未验证代次不能作为恢复来源。

**验证失败处理：** 保留代次和失败报告；不覆盖上一个已验证代次；不自动删除失败代次，供排查。

## 6. 恢复

### 6.1 预检

- 目标 PostgreSQL 为空库或隔离 schema；不与生产共用连接。
- 应用版本 ≥ 备份版本；否则拒绝或先升级应用。
- S3 endpoint／bucket 可访问；证书可验证。
- secret bundle 可用（若需要保留证书身份和令牌）。
- 目标库名、连接串、维护窗口确认。

### 6.2 步骤

1. 选择已验证代次；下载并校验所有文件。
2. `pg_restore` 到隔离 PostgreSQL；运行迁移。
3. `metadata doctor`；失败停止。
4. 按对象清单 HEAD S3：检查 key、长度、SHA-256；分类 `present`、`missing`、`corrupt`。
5. 重置瞬态：
   - `upload_intents` 全部 `expired`，abort multipart；
   - 清空 `library_leases`，保留备份的逻辑所有权记录用于核对。生产切换时生成全新 `recoveryGeneration`，使已签发的旧 token 与 worker lease 失效。
   - 运行中 `jobs` → `reconcile`；
   - `outbox` 重建；
   - `objects.state` 按 S3 核对结果更新。
6. 如换 bucket／endpoint，更新 `objects.bucket/key`，重新 HEAD。
7. 只读／诊断启动 Server；客户端重连、对账、补交操作。
8. 通过后切换生产连接；记录恢复回执、缺失对象、未完成项。

### 6.3 客户端对账

一库一客户端，不需要多写冲突合并：

- 比较恢复代次、设备、包实例、授权 epoch 和共同修订的收据摘要。先完成只读对账。备份点后发生过转移或撤销时，由管理员按保留的记录确认当前设备与包实例后再开放写授权。
- 确认共同修订 `R` 后，纯目录操作可按 `command_id` 逐项证明并补交，Server 领先时客户端拉取。重复 ID 同载荷去重，历史分岔进待核对。
- 归档、生成或其他外部效果使用原命令／对象／作业收据核对。找不到备份点后的作业仍可能已发生。未确定效果前保留待核对。[041 双端协同](../041-server-image-editing/queues.md#4-双端协同)
- 客户端也丢失：恢复到备份点；报告丢失窗口，不假装完整。

### 6.4 对象缺失与重绑定

- 元数据恢复成功但 S3 对象缺失：`objects.state=missing`，归档引用保留；界面“待找回”。
- 从冷备恢复对象后重新 HEAD／checksum，转 `available`。
- 换 bucket／endpoint：更新对象位置，重新 HEAD；不重写内容哈希。
- 对象存在但 key 不符：标 `corrupt`／`quarantined`，不自动覆盖。

## 7. 证书与令牌

### 7.1 备份边界

| 数据 | 位置 | 恢复影响 |
| --- | --- | --- |
| 公有证书链、SPKI、SAN、有效期 | 元数据 dump | 客户端固定身份；私钥缺失则不能完成 TLS |
| CA 私钥、服务器私钥 | secret bundle | 恢复同一身份；缺失需重新签发／重新固定 |
| 令牌哈希、设备记录、撤销状态 | 元数据 dump | 设备原令牌继续有效 |
| 令牌 pepper／HMAC 密钥 | secret bundle | 缺失则令牌全部失效，需重新登记 |
| S3 凭据 | secret bundle／密钥管理 | 缺失需重新配置 |
| 备份加密密钥 | 离线／独立密钥管理 | 缺失无法解密备份；不能与备份同址 |

### 7.2 恢复

- 证书与私钥都恢复：客户端固定不变；可直接连接。
- 只有证书、无私钥：Server 不能完成 TLS；必须重新签发，客户端重新固定。
- 证书过期／主机名变化：用同一 CA 签发新 leaf；客户端信任 CA 时无需重新固定；单证书方案需重新固定。
- 令牌哈希与 pepper 恢复：原设备令牌继续有效；缺失 pepper 则全部失效，重新登记。
- secret bundle 解密失败：停止恢复，不启动半安全服务。

## 8. 失败矩阵

| 故障 | 行为 |
| --- | --- |
| dump 校验和不符 | 拒绝；尝试上一代 |
| pg_restore 失败 | 隔离库保留；不改生产 |
| schema 高于应用 | 拒绝；升级应用后重试 |
| `metadata doctor` 失败 | 停止；输出具体 ID |
| S3 对象缺失 | 标记 missing；报告；不显示可用 |
| S3 对象 checksum 不符 | 标记 corrupt／quarantine；不覆盖 |
| 证书私钥缺失 | 拒绝启动 TLS 身份；要求重新签发 |
| 令牌 pepper 缺失 | 全部令牌失效；要求重新登记 |
| secret bundle 解密失败 | 停止；不回退到明文 |
| 客户端有更新操作 | 补交；按 command ID 去重 |
| 客户端 epoch 不同 | 拒绝写入；显式转移 |
| 恢复中断 | 不切换生产；可从检查点重试 |

## 9. 验收

1. 全量备份恢复到空 PostgreSQL；`metadata doctor` 通过；库、所有权、操作、对象、引用、快照、配额、令牌哈希完整。
2. 五文件样本：备份前归档引用恰为 A.JPG／B.RAW；恢复后一致；排除项零引用。
3. 对象缺失：恢复后 `missing` 报告准确；冷备修复后转 `available`。
4. 备份验证：损坏 dump、错误 checksum、跨库引用、操作缺口、配额不一致被拒；未验证备份不能恢复。
5. 客户端重连：服务器恢复旧修订，客户端补交后续操作；重复命令去重；所有权 epoch 正确。
6. 证书／令牌：同 CA／私钥恢复后客户端无需重新固定；secret bundle 缺失时明确要求重新登记；错误指纹被拒。
7. 换 bucket／endpoint：重绑定后对象全部 HEAD 通过；缺项列出。
8. 场景图／HDR：恢复含 `sceneGraph`、输出状态、模型前缀、模板／批量候选的版本；HDR AVIF 与 SDR JPEG/PNG16 的 target／format／位深／ICC／CICP 保留；旧 SDR 兼容记录不变。
9. 10TB 级：记录备份、恢复、doctor、全量 HEAD 时长和临时磁盘占用；不以单次结果外推 100TB。
10. 加密：备份静态加密。错误密钥不能解密。日志不含密钥／令牌。

## 10. 待决

| 编号 | 问题 | 建议 |
| --- | --- | --- |
| M-01 | 备份粒度 | 全 Server 全量逻辑备份；按库恢复后续 |
| M-02 | 设备令牌 | 随机不透明 + 哈希；pepper 进 secret bundle |
| M-03 | 证书模式 | 私有 CA + leaf；单自签名证书作为简化模式 |
| M-04 | 对象校验深度 | 备份抽样 HEAD；恢复全量 HEAD；周期 scrub 可选 |
| M-05 | secret bundle 加密 | age／OpenPGP 或 libsodium；密钥离线 |
| M-06 | 云 S3 备份 | 元数据备份是否跨云复制；由冷备策略决定 |
| M-07 | 恢复切换 | 新 PostgreSQL 连接串 + 只读验证 + 短写屏障 |
| M-08 | 审计保留 | 全量或按 90 天；与元数据备份分开 |
