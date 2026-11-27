# 040 · gRPC 与 S3 协议

2026-11-27 · 控制面 gRPC over HTTP/2/TLS，内容默认经 S3 HTTPS 传输，Relay 使用有界分块流。产品要求见[规格](spec.md)，实体见[数据模型](data-model.md)，存储见[存储](storage.md)，安全见[安全](security.md)。

## 1. 分层

```text
┌─────────────────────────────────────────────────────┐
│ gRPC / HTTP2 / TLS                                  │
│ 库所有权、操作、上传意图、收据、事件、备份管理      │
├─────────────────────────────────────────────────────┤
│ S3 HTTPS                                            │
│ presigned multipart、Range、HEAD、对象校验          │
├─────────────────────────────────────────────────────┤
│ Relay（gRPC bidi stream / HTTP2 chunk）             │
│ Direct 不可达时，Server 代理缺失 part／下载          │
└─────────────────────────────────────────────────────┘
```

- H2 是 gRPC 的传输；S3 是独立 HTTPS 内容面，不强制 H2。
- gRPC 不承载 RAW／JPEG 字节；Relay 只传分块，不改变事务边界。
- PostgreSQL 事务由 Server 内部执行，客户端看不到数据库。

## 2. TLS、认证与所有权

- 自签名私有 CA 或单张自签名证书；客户端固定 CA／SPKI 指纹。详见[安全](security.md)。
- 每个 gRPC 请求带 `authorization: Bearer <device-token>`；令牌只存哈希。
- `library_id` 必须在设备可访问范围内。每个写方法及分块会话确认当前 `replica_id`、`ownership_epoch`、`recovery_generation` 与写授权，适用时在发布事务内再次核对。
- 第二客户端写返回 `FAILED_PRECONDITION` + 当前 owner；只读请求可配置允许。
- 管理方法（备份、恢复、doctor、证书轮换）要求 admin 角色或本机 CLI。

## 3. gRPC 服务

### 3.1 LibraryService

| 方法 | 类型 | 作用 |
| --- | --- | --- |
| `ListLibraries` | unary | 按设备权限列出可打开库、所有者、最近已核验快照及修订 |
| `CreateLibrary` / `GetLibraryCreation` | unary | 以稳定建库命令 ID 创建或查询原收据。初始化完成后返回库与初始快照修订 |
| `AcquireLibrary` | unary | 已授权包实例续期或显式接续。返回所有权 epoch、恢复代次和临时 fencing token |
| `TransferLibrary` | unary | 显式转移所有权 |
| `ApplyOperation` | unary | 提交一条操作；PostgreSQL 事务 + 收据 |
| `ApplyOperations` | unary | 小批操作；逐项结果，允许部分成功 |
| `GetChanges` | server streaming | 按 `afterRevision` 拉取操作、事件和修订 |
| `GetLibraryStatus` | unary | 所有权、修订、配额、归档、备份摘要 |
| `WatchEvents` | bidi streaming | 上传进度、对象校验、备份、配额、所有权事件 |
| `RegisterLibrarySnapshot` | unary | 客户端已把目录快照上传 S3；Server 校验并登记索引 |
| `GetLibrarySnapshot` | unary | 获取最新快照索引和下载地址 |
| `GetServerInfo` | unary | 服务器身份、证书链／SPKI、版本、支持能力、备份格式 |

### 3.2 TransferService

| 方法 | 类型 | 作用 |
| --- | --- | --- |
| `CreateUpload` | unary | 校验资格和配额；写 upload intent；创建 S3 multipart；返回 presigned part URL |
| `RefreshUpload` | unary | 刷新 presigned URL／过期时间 |
| `RelayUpload` | bidi streaming | Direct 失败时按 part 中转；Server 写入同一 S3 multipart |
| `CompleteUpload` | unary | 完成 multipart、HEAD 校验、登记对象和归档引用 |
| `AbortUpload` | unary | 取消并 abort multipart |
| `GetUpload` | unary | 查询已上传 part、模式、过期时间 |
| `CreateDownload` | unary | 返回 presigned GET 或 Relay 会话 |
| `RelayDownload` | server streaming | Server 从 S3 读取并按 Range 流式返回 |

### 3.3 MetadataService（admin）

| 方法 | 类型 | 作用 |
| --- | --- | --- |
| `CreateMetadataBackup` | unary | 创建一致快照、对象清单、checksums，上传 S3 |
| `ListMetadataBackups` | unary | 代次、时间、版本、验证状态 |
| `VerifyMetadataBackup` | unary | 隔离恢复 + `metadata doctor` + 对象抽样 |
| `RestoreMetadata` | unary | 恢复到隔离 PostgreSQL；返回 restore ID |
| `GetRestoreStatus` | unary | 阶段、缺项、对象核对结果 |
| `RunMetadataDoctor` | unary | 运行不变量检查 |
| `RotateServerCertificate` | unary | 从同一 CA 签发新 leaf；更新 secret bundle 引用 |

### 3.4 JobService（Server 1.1）

`GetCapabilities`、`SubmitJob`、`GetJob`、`CancelJob`、`RetryJob`、`WatchJob`、`ListJobs`、`GetJobResult`。040 预留能力和版本。完整状态机、幂等及事件补差由 [041](../041-server-image-editing/queues.md#4-双端协同) 冻结。

作业信封至少包含：

- `library_id`、`job_id`、`kind`、`request_sha256`；
- 输入 `content_id`／`file_id`／版本、按序输入；
- `recipe_version`；场景图 `scene_graph`／hash、输出状态 `route`／`sdrTrim`、模型前缀 `model_program`；
- `compatibility_route`（旧 SDR 兼容 vs 场景图）、`delivery_target`（`sdr709`／`hdr2020`）、`format`（`avif10`／`jpeg8`／`png16`）；
- 模板／批量身份、目标 head、引擎／模型、能力请求、输出规格；
- 场景执行 receipt：backend、tiles、evaluated nodes、dispatches、cache hits、peak bytes、budget、CPU time。

服务端不得把旧 SDR 兼容配方自动迁移为场景图，也不得把 HDR 目标悄悄降为 SDR；不匹配返回 `FAILED_PRECONDITION`／`INVALID_ARGUMENT`。

## 4. 通用信封与幂等

```proto
message OperationEnvelope {
  uint32 api_version = 1;
  string library_id = 2;
  string device_id = 3;
  string command_id = 4;
  int64 base_revision = 5;
  uint32 payload_version = 6;
  string action = 7;
  bytes payload_json = 8;
  string payload_sha256 = 9;
  google.protobuf.Timestamp created_at = 10;
  string replica_id = 11;
  uint64 ownership_epoch = 12;
  string recovery_generation = 13;
}
```

- `command_id` 全局唯一；同一 ID 同 payload hash 返回原收据；不同 hash 返回 `ALREADY_EXISTS`／冲突。
- `base_revision` 用于缺口和依赖检查；单客户端单写者，不做字段级合并。
- 操作应用后返回 `server_revision`、`result_revision`、`receipt_json`。
- 客户端离线队列按 `command_id` 重放；服务器按库修订单调。

**错误码映射：**

| gRPC | 场景 | 客户端行为 |
| --- | --- | --- |
| `UNAUTHENTICATED` | 令牌缺失／过期 | 重新登记／刷新 |
| `PERMISSION_DENIED` | 非所有者写、admin 受限 | 只读／申请转移 |
| `FAILED_PRECONDITION` | epoch／修订／依赖不满足 | 拉取后重试或转移 |
| `ALREADY_EXISTS` | 同 ID 不同载荷 | 不重试，报冲突 |
| `RESOURCE_EXHAUSTED` | 配额／容量 | 清理或扩容 |
| `NOT_FOUND` | 库／对象／快照不存在，或查询代次内无作业记录 | 先区分缺失对象与未知提交。恢复旧备份后的无记录不能证明未接收 |
| `UNAVAILABLE` | 暂时不可用 | 已知未提交的工作有限退避，可能提交的写操作先查收据 |
| `DEADLINE_EXCEEDED` | 超时 | 用原 ID 核对，再按操作语义恢复 |

## 5. S3 Direct 上传

### 5.1 创建

`CreateUpload` 请求包含：

```json
{
  "libraryID": "...",
  "fileID": "...",
  "contentID": "sha256:<hex>:<bytes>",
  "sha256": "<hex>",
  "byteCount": 12345678,
  "filename": "A.ARW",
  "role": "raw",
  "scopeID": "..."
}
```

Server 校验归档资格、配额、对象是否已存在；写 `upload_intent`；创建 S3 multipart；返回：

```json
{
  "uploadID": "...",
  "stagingKey": "libraries/<libraryID>/staging/<uploadID>/object",
  "partSize": 67108864,
  "parts": [
    {"partNumber": 1, "url": "https://rustfs.../...&partNumber=1", "expiresAt": "..."}
  ],
  "uploadExpiresAt": "..."
}
```

- `partSize` 由 Server 固定；Direct 和 Relay 必须使用相同 part 号。
- presigned URL 只允许精确 key、part 号、方法；TTL 5–15 分钟。
- 对象已存在时，Server 先 HEAD 校验；可直接进入 `CompleteUpload` 或只登记引用。

### 5.2 完成

客户端提交 `uploadID` 和 part ETags：

```json
{"uploadID": "...", "parts": [{"partNumber": 1, "etag": "\"...\""}]}
```

Server：

1. `CompleteMultipartUpload`（若客户端未完成）；
2. 核对暂存 key、长度及可信的整对象 SHA-256，再条件发布到同库内容 key，已有对象逐项核验复用。
3. PostgreSQL 条件事务重查资格、配额和写授权，登记 `objects.state=available`、`archive_refs` 与 outbox。
4. 返回收据和 `serverRevision`。

Provider 若无法返回可验证的整对象 SHA-256，Server 以有界缓冲读取暂存对象计算摘要。ETag、multipart 合成摘要和客户端自填元数据均只用于相应传输或声明核对。收据保存校验方式，数据库落盘前的孤儿对象交给对账。[Amazon S3 完整对象与合成校验](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity-upload.html)

## 6. 自动 Relay

### 6.1 触发

仅传输类错误触发：

- DNS 解析失败、TCP 连接失败、TLS 握手失败；
- presigned URL 过期且 Refresh 后仍失败；
- S3 5xx／超时／连接重置；
- 客户端网络策略禁止直连 S3。

以下不触发 Relay：401/403 权限、checksum 不符、配额不足、对象 key 不符、归档资格不合法。

### 6.2 流程

1. 客户端 `GetUpload` 查询已存在 part。
2. 对缺失 part 调用 `RelayUpload`，流式发送 part 数据；Server 写入同一 S3 multipart。
3. Server 记录 `upload_parts.source=relay`；Direct part 保留。
4. `CompleteUpload` 统一完成。
5. `mode` 记录 `direct`、`relay`、`mixed`；收据保留模式用于审计。

Relay 不把完整文件落本地磁盘；使用有界缓冲流式写 S3。10TB 首传仍建议 Direct；Relay 是可用性回退。

## 7. S3 下载

- `CreateDownload` 返回 presigned GET；客户端可带 `Range`。
- 客户端校验完整长度和 SHA-256；代理下载不冒充原件。
- Direct GET 失败时可 `RelayDownload`，Server 从 S3 流式返回并保持 Range。
- 服务器不缓存完整对象；本地只有临时缓冲。

## 8. 对象存储 profile

`ObjectStoreProfile` 包含：

```json
{
  "provider": "rustfs|minio|aws-s3|other",
  "endpoint": "https://truenas:9000",
  "region": "us-east-1",
  "bucket": "rawmaster",
  "addressing": "path|virtual",
  "tls": {"mode": "private-ca|pinned|system", "caRef": "..."},
  "multipartPartSize": 67108864,
  "checksum": "sha256"
}
```

- RustFS／MinIO 默认 path-style；云 S3 可用 virtual-host。
- 客户端 presigned URL 的 host 必须与证书 SAN 和实际 endpoint 一致。
- 子证书不受信任时，Direct 失败转 Relay；不关闭 TLS 校验。
- 凭据只在 Server secret store；客户端只拿 presigned URL。

## 9. 版本与兼容

- gRPC 包：`rawmaster.library.v1`、`rawmaster.transfer.v1`、`rawmaster.metadata.v1`、`rawmaster.jobs.v1`。
- proto 字段只增不删；未知字段忽略；未知写版本拒绝。
- `backup_format_version` 与 PostgreSQL schema 分开；恢复先验证再迁移。
- `object_store_profile` 和证书／令牌 key ID 带版本，支持轮换。
- 服务器在 `GetServerInfo` 声明支持版本、S3 profile、证书指纹和备份格式。

## 10. 安全约束

- presigned URL 短 TTL、精确 key、不记日志；客户端不持有长期 S3 凭据。
- 令牌、私钥、S3 密钥、备份加密密钥不进入 URL、日志、错误回显或普通 dump。
- 备份和 secret bundle 静态加密；TLS 只保护传输。
- 公开暴露 gRPC／S3 需显式配置 TLS、防火墙、速率限制和审计；默认只监听局域网。
- Relay 仍校验设备令牌、库所有权、配额和内容哈希；不能借 Relay 绕过资格。
