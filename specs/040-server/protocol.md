# 040 · Server 协议

2026-11-26 · HTTP／JSON 与内容传输契约。目标是让客户端、服务器和后续执行端能在不共享数据库文件的前提下交换业务操作、归档对象、备份和作业。物理端点可在 S1 评审时调整，语义和不变量不得改变。产品要求见[规格](spec.md)，实体见[数据模型](data-model.md)。

## 1. 传输与身份

- 基础路径：`https://<server>/api/v1`。默认只监听局域网；公开暴露必须显式配置。
- TLS 1.2 以上；客户端首次连接显示并固定服务器证书指纹。指纹变化默认阻止写入。
- 认证：`Authorization: Bearer <device-token>`。令牌按设备签发，存客户端钥匙串；服务器只保存摘要。
- 登记：管理员在服务器生成一次性登记码，客户端在有效期内使用；登记成功后签发设备令牌和设备身份。
- 请求头：`Content-Type: application/json`、`Accept: application/json`、`X-Rawmaster-Device`、`X-Rawmaster-Request-ID`（可与 `commandID` 相同，用于日志关联）。
- 时间使用 UTC RFC 3339；哈希使用小写十六进制 SHA-256；字节数使用十进制整数。
- 所有写请求支持重试；客户端必须复用原 `commandID`，不得因超时生成新 ID。

## 2. 通用响应

成功：

```json
{
  "apiVersion": 1,
  "requestID": "req-...",
  "result": {}
}
```

失败：

```json
{
  "apiVersion": 1,
  "requestID": "req-...",
  "error": {
    "code": "conflict",
    "message": "评分在另一设备已修改",
    "retryable": false,
    "details": {
      "entityType": "asset",
      "entityID": "asset-...",
      "field": "rating",
      "conflictID": "conflict-..."
    }
  }
}
```

**错误码。** `unauthorized`、`forbidden`、`not_found`、`invalid_request`、`unsupported_version`、`conflict`、`dependency_missing`、`hash_mismatch`、`length_mismatch`、`insufficient_storage`、`quota_exceeded`、`unavailable`、`rate_limited`、`internal`。`retryable` 只表示同一请求可安全重试；冲突和版本错误不能靠重试解决。

## 3. 端点

### 3.1 服务器与登记

| 方法 | 路径 | 作用 | 幂等 |
| --- | --- | --- | --- |
| GET | `/health` | 存活、版本、时间；不返回资料库内容 | 是 |
| GET | `/server` | 服务器身份、TLS 指纹、API 版本、能力、存储摘要 | 是 |
| POST | `/enroll` | 用一次性登记码登记设备，返回设备 ID、令牌、服务器指纹 | 登记码一次性 |
| GET | `/devices` | 当前所有者设备列表、最后在线、版本、撤销状态 | 是 |
| DELETE | `/devices/{deviceID}` | 撤销设备令牌 | 是 |

登记请求示例：

```json
{
  "enrollmentCode": "one-time-code",
  "deviceName": "MacBook Pro",
  "clientVersion": "1.0",
  "deviceID": "existing-or-new"
}
```

服务器可拒绝客户端自报的 `deviceID` 并要求新身份；恢复副本必须重新登记，不能复用旧令牌。

### 3.2 资料库绑定

| 方法 | 路径 | 作用 | 幂等 |
| --- | --- | --- | --- |
| GET | `/libraries` | 当前设备可访问的资料库及状态 | 是 |
| POST | `/libraries/attach` | 绑定已有 `libraryID`，可附带目录摘要和 schema | 是，按 `libraryID` |
| GET | `/libraries/{libraryID}` | 库状态、目录版本、水位、存储摘要 | 是 |
| POST | `/libraries/{libraryID}/detach` | 解除本设备绑定，不删除服务器对象 | 是 |

绑定请求不得上传活动数据库；只提交身份、schema、摘要和可选引导快照。服务器已有同 ID 但不同来源时返回 `conflict`。

### 3.3 操作同步

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| POST | `/libraries/{libraryID}/operations` | 批量提交操作；逐项返回收据、服务器修订或冲突 |
| GET | `/libraries/{libraryID}/changes?after={revision}&limit=200` | 增量拉取操作、冲突和解决结果 |
| GET | `/libraries/{libraryID}/snapshot?cursor={revision}` | 分页引导快照，供新设备或恢复使用 |
| GET | `/libraries/{libraryID}/conflicts` | 当前未解决冲突 |
| POST | `/libraries/{libraryID}/conflicts/{conflictID}/resolve` | 选择本机、服务器、保留分支或稍后处理 |

单条操作：

```json
{
  "apiVersion": 1,
  "libraryID": "library-...",
  "deviceID": "device-...",
  "commandID": "command-...",
  "baseRevision": 42,
  "payloadVersion": 1,
  "action": "org.rating",
  "payload": {
    "workID": "work-...",
    "rating": 4
  },
  "createdAt": "2026-11-26T10:00:00Z"
}
```

批量请求：

```json
{
  "apiVersion": 1,
  "operations": [ { "...": "..." }, { "...": "..." } ]
}
```

响应逐项返回，允许部分成功：

```json
{
  "apiVersion": 1,
  "results": [
    {
      "commandID": "command-...",
      "status": "applied",
      "serverRevision": 43,
      "resultRevision": 43,
      "receipt": {}
    },
    {
      "commandID": "command-...",
      "status": "conflict",
      "conflictID": "conflict-...",
      "details": { "field": "rating" }
    }
  ]
}
```

**幂等。** `unique(libraryID, commandID)`；同 ID 同载荷摘要返回缓存收据；同 ID 不同摘要返回 `conflict`。客户端重试不得更换 `commandID`。

**拉取。** `changes` 返回 `operations`、`conflicts`、`resolutions`、`nextRevision`、`hasMore`。客户端按 `nextRevision` 更新游标；回放自己已发送的操作时按 `commandID` 去重。

**引导。** `snapshot` 分页返回目录实体和最后修订，不包含原件字节；客户端完成快照后按游标追平，再按需取代理或原件。快照必须来自一致水位。

### 3.4 归档与内容传输

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| POST | `/libraries/{libraryID}/archive/plans` | 生成或复用归档计划，返回逐文件资格、字节、缺项和计划 ID |
| GET | `/libraries/{libraryID}/archive/refs?state=...` | 查询归档引用与状态 |
| POST | `/libraries/{libraryID}/archive/transfers` | 为计划中的文件创建或复用上传；已存在对象可直接返回完成 |
| PUT | `/uploads/{uploadID}/chunks/{index}` | 上传一个块，带 `Content-Range` 和块摘要 |
| GET | `/uploads/{uploadID}` | 查询已收字节／区间、状态和到期时间 |
| POST | `/uploads/{uploadID}/complete` | 提交完整长度和整体 SHA-256，触发校验与归档登记 |
| DELETE | `/uploads/{uploadID}` | 取消未完成上传并清理暂存 |
| GET | `/objects/{contentID}` | 下载完整对象，支持 `Range` |
| HEAD | `/objects/{contentID}` | 查询对象长度、哈希、范围和可用状态 |

`contentID` 是 `sha256:<hex>:<byteCount>` 的逻辑身份；作为 URL path segment 时必须整体百分号编码。服务器也可接受 `/objects/{sha256}?bytes={byteCount}` 作为等价形式，但归档、收据和备份清单始终记录完整 `contentID`。

归档计划响应示例：

```json
{
  "planID": "plan-...",
  "libraryID": "library-...",
  "scope": { "kind": "session", "id": "session-..." },
  "files": [
    {
      "fileID": "file-...",
      "captureID": "capture-...",
      "contentID": "sha256:...:12345678",
      "sha256": "...",
      "byteCount": 12345678,
      "filename": "A.JPG",
      "role": "jpeg",
      "basis": "admitted",
      "state": "needsUpload"
    },
    {
      "fileID": "file-...",
      "filename": "A.RAW",
      "basis": "excluded",
      "state": "historyOnly"
    }
  ],
  "summary": {
    "eligibleFiles": 2,
    "uniqueContents": 2,
    "totalBytes": 45678901,
    "alreadyAvailableBytes": 0,
    "excludedFiles": 1,
    "missingFiles": 0
  }
}
```

上传：

1. `POST /archive/transfers` 返回 `uploadID`、`chunkSize`、`nextOffset`、`expiresAt`。若内容已存在且引用未登记，直接登记引用并返回完成。
2. 客户端按块 `PUT`；服务器按 `Content-Range` 校验顺序和重叠。重复块幂等。
3. `complete` 提交总长度和整体摘要；服务器重新计算并核对，成功后原子发布对象并登记 `srv_archive_refs`。
4. 失败返回 `hash_mismatch`／`length_mismatch`，保留可重试状态；未完成暂存到期清理。
5. 客户端可 `GET /uploads/{id}` 续传；服务器重启后区间仍可读。

下载：

```http
GET /api/v1/objects/sha256:...:12345678 HTTP/1.1
Range: bytes=0-8388607
Authorization: Bearer ...
```

响应 `200` 或 `206`，带 `Content-Length`、`Content-Range`、`Accept-Ranges: bytes`、`ETag`（内容摘要）。客户端必须核对完整长度和 SHA-256 后再标记原件可用。

### 3.5 备份与恢复

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/libraries/{libraryID}/backups` | 备份代次列表和状态 |
| POST | `/libraries/{libraryID}/backups` | 创建一代独立备份；返回代次 ID |
| GET | `/backups/{generationID}` | 代次详情、对象数、字节、缺项、校验 |
| POST | `/backups/{generationID}/verify` | 逐对象校验并记录收据 |
| POST | `/backups/{generationID}/restore` | 恢复到指定目标；返回 `restoreID` |
| GET | `/restores/{restoreID}` | 恢复阶段、进度、缺项和结果 |

创建备份请求包含模式（目录＋资源／完整）、目标、保留标签；服务器先返回计划，确认后执行。恢复请求包含目标服务器／设备、位置和是否只恢复目录。恢复不能覆盖活动库，必须先进入隔离目标。

### 3.6 作业

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| POST | `/libraries/{libraryID}/jobs` | 提交作业；返回 `jobID`、状态、需补传输入 |
| GET | `/jobs/{jobID}` | 状态、输入、尝试、进度、输出、错误 |
| POST | `/jobs/{jobID}/cancel` | 取消 |
| POST | `/jobs/{jobID}/retry` | 以同一作业身份重试 |
| GET | `/jobs/{jobID}/outputs` | 输出与登记状态 |
| GET | `/libraries/{libraryID}/jobs?state=...` | 作业列表 |

提交示例：

```json
{
  "apiVersion": 1,
  "libraryID": "library-...",
  "projectID": "project-...",
  "action": "timelapse",
  "recipe": { "version": 1, "fps": 30 },
  "engine": { "name": "rawmaster-image", "version": "..." },
  "model": null,
  "inputs": [
    {
      "ordinal": 0,
      "captureID": "capture-...",
      "fileID": "file-...",
      "contentID": "sha256:...:...",
      "role": "raw",
      "required": true
    }
  ],
  "output": { "kind": "video", "format": "mp4" }
}
```

提交前客户端和服务端都核对输入是否有归档对象、引擎能力、模型许可和输出空间。响应中的 `needsUpload` 列出缺对象；客户端补传后以同一 `jobID` 重试。作业完成输出先 `staged`，客户端预览后才 `published`。

### 3.7 统计与诊断

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/libraries/{libraryID}/stats` | 文件／拍摄／内容／归档／备份／缓存／作业计数和字节 |
| GET | `/libraries/{libraryID}/integrity` | 最近完整性报告 |
| GET | `/server/logs?after=...` | 结构化审计日志；不返回令牌、密钥或完整路径 |

## 4. 重试、超时与限流

- 网络错误、`429`、`502`、`503`、`504` 可重试；使用指数退避和抖动。`conflict`、`unsupported_version`、`hash_mismatch` 不自动重试。
- 上传空闲超时和上传会话到期时间由服务器返回；到期前客户端可续传。
- 批量操作限制单批条数和总字节；超限返回 `invalid_request`，客户端拆分。
- 客户端时钟只用于显示；服务器以自身时间和修订为准，不信任客户端时间排序。
- 所有响应带 `requestID`；审计日志只记录 ID、摘要、计数和错误码。

## 5. 版本与兼容

- URL 大版本 `/api/v1`；不兼容变更升 `/api/v2`，不原地改变语义。
- 操作载荷独立版本；服务器可读旧版本、拒绝未知写版本。
- 服务器在 `GET /server` 声明支持的 `payloadVersions`、`snapshotFormats`、`engineCapabilities`。
- 客户端在写入前检查版本；不支持的库进入只读或提示升级，不发送半兼容操作。
- 快照格式与目录 schema 分开版本化；恢复时先验证再打开。

## 6. 安全约束

- 不把令牌、登记码、备份目标凭据写入 URL、日志、错误消息或资料库包。
- 内容下载按设备授权和库成员关系校验；不能凭 `contentID` 猜测访问其他库对象。
- 上传完成前不可读；对象路径不使用用户文件名，避免路径注入。
- 所有文件路径使用规范化相对路径和 `O_NOFOLLOW` 等安全打开方式；拒绝符号链接逃逸。
- 公开暴露时要求 TLS、强登记码、速率限制和失败审计；默认不允许匿名上传或匿名列举。
- 备份目标只由服务器管理员配置；客户端不能指定任意服务器本地路径。
