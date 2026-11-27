# 040 · 对象存储方案

2026-11-27 · S3 兼容对象面、Direct／Relay、TrueNAS 25.04 + RustFS、两种部署形态。产品要求见[规格](spec.md)，协议见[协议](protocol.md)，元数据备份见[元数据备份](metadata-backup.md)。

## 1. 需求

- 单库 10TB 级、约 20 万对象；RAW 平均约 50MB，存在更大的 TIFF／视频。
- 不可变内容寻址对象；整文件 SHA-256；Range 读；断点／并行上传。
- 默认客户端直传 S3；失败自动 Relay。
- 多库独立；不做跨库去重和跨库逻辑。
- Server 本地磁盘只放日志、临时文件和有限中转缓冲；不持久化对象或元数据。
- PostgreSQL 和 S3 的 HA、RAID、纠删码、跨站点复制由基础设施负责；RAWMaster 只做逻辑一致性、清单和校验。
- 自建服务只有自签名证书；gRPC 和 S3 直传都必须能工作，不能关闭 TLS 校验。

## 2. TrueNAS 25.04 + RustFS

用户环境：TrueNAS SCALE 25.04，RustFS 作为 S3 API，10GbE + jumbo frame，无链路聚合，已有多个 TrueNAS 冷备。

### 2.1 RustFS 能力

RustFS 在 TrueNAS 25.04 的 App 目录可安装，提供 S3 兼容 API。其 [S3 兼容矩阵](https://docs.rustfs.com/en/reference/s3-compatibility) 显示：

| 能力 | 状态 | 用途 |
| --- | --- | --- |
| Presigned GET / PUT | ✅ 已测试 | 客户端直传／下载 |
| Multipart create/upload/complete/abort | ✅ 已测试 | 大文件、Direct／Relay |
| Range / conditional reads | ✅ 已测试 | 断点、代理、按需取回 |
| SHA-256 / CRC64NVME PutObject checksum | ✅ 已测试 | 内容校验 |
| Bucket policy / IAM | ✅ 已测试 | 服务账号、前缀授权 |
| Versioning / Object Lock / lifecycle | 部分已测试 | 不作为核心依赖 |
| ACL | ⊘ 不支持 | 用 bucket policy/IAM |
| Bucket access logging | ❌ 计划中 | 用 Server 审计 |
| POST Object checksum | ❌ 计划中 | 用 PUT／multipart |

**结论：** 核心路径可用；避开 ACL、S3 访问日志、POST 表单上传和高级 multipart 边界。固定 RustFS 版本，升级前跑同一组兼容性回归。

### 2.2 自签名 TLS 与直传

- RustFS 使用私有 CA 或自签名证书；客户端必须信任／固定该证书，否则 Direct 失败。
- presigned URL 的 host、端口、scheme 必须与证书 SAN 和实际 endpoint 一致。
- macOS 客户端把私有 CA 装入钥匙串，或在 URLSession／S3 客户端实现自定义信任；不能全局关闭 TLS 校验。
- 如果客户端无法信任 RustFS 证书，自动 Relay；Relay 只信任 Server 证书。
- RustFS 根凭据只用于管理；Server 使用受限服务账号，客户端只拿 presigned URL。

### 2.3 10GbE 与 jumbo frame

- 10GbE 无 LAG：理论约 1.25GB/s，实际 1.0–1.1GB/s 更现实；10TB 首传约 3 小时起步，加协议／磁盘开销通常 3–5 小时。
- Jumbo frame 要端到端：Mac、交换机、TrueNAS 接口、RustFS App/容器网络。容器 bridge 默认 1500 MTU 是常见瓶颈。
- 单流很难打满 10GbE；S3 multipart 建议 4–8 并发、64–128MB 分片。
- TLS 和 SHA-256 会占 CPU；记录 RustFS／Server／客户端 CPU 与吞吐。
- 10GbE 下 Direct 直传避免 Server 转发；Relay 只作回退。

## 3. 对象布局

默认单 bucket + 库前缀：

```text
s3://rawmaster/
  libraries/<libraryID>/objects/<sha256[0:2]>/<sha256>
  libraries/<libraryID>/staging/<uploadID>/<partNumber>
  libraries/<libraryID>/manifests/<generationID>.json
  libraries/<libraryID>/catalog-snapshots/<snapshotID>.sqlite
  backups/metadata/<generationID>/
    manifest.json
    metadata.dump
    object-manifest.ndjson.zst
    library-snapshots.json
    checksums.json
```

- 默认单 bucket + 前缀，便于云 S3 迁移、生命周期按前缀、统一审计。
- 严格物理隔离时可用 bucket-per-library；代价是 bucket／权限／生命周期管理增加。
- `objects/` 永不配置自动过期；`staging/`、`orphan/` 可配置生命周期。
- 对象 key 不使用用户文件名；文件名、来源路径、角色在 PostgreSQL。
- 跨库不去重；同一内容在不同库各存一份。

### 3.1 代理、HDR 与 SDR 交付

- `displayProxy`、`editProxy`、`sceneProxy`、`linearProxy` 可分别存 S3；代理可重建，不进入原件归档引用。
- HDR AVIF 10 位 Rec.2020／PQ、SDR JPEG8、PNG16 是不同交付对象；对象索引记录 `target`、`format`、`bit_depth`、ICC／CICP 和 SDR 派生参数，不能只按扩展名判断。
- `sceneProxy` 是 037／038 场景图的线性输入代理，不能拿 SDR JPEG 代替；其格式、分辨率和存储预算由 041 冻结。
- 代理可配置生命周期；成片母版和归档对象不得被 S3 生命周期自动删除。

## 4. Direct 与 Relay

### 4.1 Direct

1. Server `CreateUpload` 创建 S3 multipart，返回 presigned part URL。
2. 客户端直传 RustFS／云 S3。
3. Server 完成 multipart、HEAD／checksum 校验、PostgreSQL 登记。
4. 10TB 首传默认走此路径；Server 只做控制。

### 4.2 Relay

- 触发：DNS／TCP／TLS／5xx／超时／presigned 过期且刷新失败。
- 同一 upload ID、part 号、S3 multipart；Direct 已传 part 通过 ListParts 跳过。
- 客户端 gRPC bidi stream 发送缺失 part；Server 流式写 S3，不落完整本地文件。
- 认证、哈希、配额、资格错误不触发 Relay。
- 收据记录 `direct`、`relay`、`mixed`。

### 4.3 自动回退

- 客户端对每个 part 先 Direct，失败按策略重试；仍失败则 Relay 该 part。
- presigned URL 先尝试刷新一次；仍失败再 Relay。
- Relay 失败保留 upload intent，可续传；过期后 abort。
- 不因为 Relay 成功就降低校验要求；最终 SHA-256 一致。

## 5. 两种部署形态

### 5.1 同机：Server + RustFS + PostgreSQL 在 TrueNAS

```text
TrueNAS SCALE 25.04
  ├─ RustFS App（S3）
  ├─ Server VM/App（gRPC）
  ├─ PostgreSQL VM/App 或外部 PostgreSQL
  └─ 客户端 → gRPC + S3 直传
```

优点：链路短、无额外主机、可直接用 TrueNAS 数据集／快照；缺点：Server、PostgreSQL、RustFS 争 CPU／内存／10GbE，TrueNAS App/VM 升级和端口限制要处理。

### 5.2 分离：Server + PostgreSQL 独立，RustFS 在 TrueNAS

```text
Linux Server
  ├─ Server（gRPC）
  ├─ PostgreSQL（外部 HA）
  └─ 10GbE → TrueNAS RustFS
客户端
  ├─ gRPC → Linux Server
  └─ S3 直传 → TrueNAS RustFS
```

优点：计算与存储隔离，PostgreSQL/Server 升级自由；缺点：多一跳 10GbE，RustFS 单独运维。

**代码不区分两种形态。** `ObjectStoreProfile` 只描述 endpoint、region、bucket、addressing、TLS、credentials；同机、独立、云 S3、MinIO 都是配置差异。

## 6. 存储可靠性边界

- RAWMaster 不实现 RAID、纠删码、S3／ZFS 复制、跨站点容灾。
- RustFS／TrueNAS／云 S3 的持久性由基础设施负责；现有 TrueNAS 冷备负责灾难恢复。
- RAWMaster 仍负责：
  - 内容 SHA-256 和对象清单；
  - 归档引用与对象的一致性；
  - 元数据逻辑备份／恢复；
  - 恢复时对象存在性核对；
  - 孤儿／缺失报告。
- 不因为“底层可靠”就跳过上传校验；S3 ETag 不等于 SHA-256。

## 7. 过期与生命周期

| 前缀／数据 | 生命周期 | 说明 |
| --- | --- | --- |
| `libraries/*/objects/` | 禁止自动过期 | 归档对象；由业务删除意图回收 |
| `libraries/*/staging/` | 7 天 | 未完成 multipart／暂存 |
| `orphan/` | 7–30 天 | 无数据库引用的对象；人工确认后清理 |
| `libraries/*/catalog-snapshots/` | 保留策略 | 客户端目录快照 |
| `backups/metadata/` | 日 30／周 8／月 12 | 最后已验证代次不自动删除 |
| 垃圾桶 | 30 天 | PostgreSQL 墓碑；到期后业务回收 |

- S3 生命周期只作兜底，不替代业务 GC。
- `objects/` 的删除必须先确认无归档引用、无保留代次、无作业输入。

## 8. 10TB 基线

- 10TB / 50MB ≈ 20 万对象；PostgreSQL 元数据小，S3 列表不用于业务枚举。
- 首传：10GbE + jumbo + 6 并发 multipart，记录吞吐、CPU、RustFS 延迟、错误率。
- 增量：记录每日新增／变更对象、上传时长、Relay 比例。
- 恢复：记录 `pg_dump`、`pg_restore`、`metadata doctor`、全量 HEAD 时长。
- 冷片：记录代理首屏、完整 RAW 取回、Range 续传。
- 不以 10TB 单库外推到 100TB／200 万文件；容量专项另立。

## 9. 验收与测试

1. RustFS 兼容性：presigned PUT／GET、multipart、Range、HEAD、SHA-256 checksum、bucket policy、abort、过期。
2. Direct 上传：50MB RAW、5GB 文件、20 万对象规模抽样；中断续传；重复 part；并发。
3. Relay 回退：模拟 DNS／TLS／5xx／超时；Direct 部分完成后 Relay 剩余 part；最终哈希一致。
4. 自签名 TLS：客户端信任 CA、证书变化、主机名不匹配、过期；Direct 失败转 Relay。
5. 10GbE：MTU 9000 端到端；单流／多流；CPU／吞吐；无 LAG 下的实际瓶颈。
6. 对象缺失／损坏：HEAD 失败、checksum 不符、冷备恢复后转 available。
7. 生命周期：staging 过期、orphan 清理、objects 不被删除、备份代次保留。
8. 存储重绑定：换 bucket／endpoint，更新对象位置并重新 HEAD。
9. 元数据备份：`pg_dump` 流式上传、对象清单、验证、恢复；详见[元数据备份](metadata-backup.md)。

## 10. 风险

| 风险 | 对策 |
| --- | --- |
| RustFS S3 兼容性与 AWS 有差异 | 固定版本；用兼容矩阵；避开 ACL／访问日志／POST form；回归测试 |
| 自签名证书导致 Direct 失败 | 私有 CA + 客户端信任／固定；失败自动 Relay |
| 10GbE 单流打不满 | multipart 4–8 并发；jumbo 端到端；测 RustFS 容器 MTU |
| Server 变带宽瓶颈 | Direct 默认；Relay 仅回退；Relay 流式不落盘 |
| S3 元数据与 PostgreSQL 不一致 | upload intent 状态机、内容寻址、orphan 对账、`metadata doctor` |
| 存储可靠性被误解为 RAWMaster 功能 | 明确外部责任；RAWMaster 只做逻辑备份／校验／恢复 |
| 证书／令牌备份泄露 | 私钥／pepper 单独加密 secret bundle；权限最小化；离线密钥 |
| 10TB 首传时间长 | 断点、并行、Direct；规划窗口；记录真实基线 |
