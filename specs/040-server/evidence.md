# 040 · 现有基础、调研证据与缺口

2026-11-27 · 设计依据。以下区分“本地已有能力”“外部产品事实”和“尚未实现”。不把调研当作 Server 已存在或已验收。

## 1. 本地可复用底座

| 能力 | 证据 | 用途 |
| --- | --- | --- |
| 资料库与设备身份 | `lc_meta.libraryID`、`metadata.deviceID`；[authority_schema.sql](../../Modules/LibraryCatalog/src/authority_schema.sql) · [LibraryStore](../../Sources/RAWMasterCore/LibraryStore.swift) | 库绑定、所有权、恢复换设备 |
| 操作 ID、载荷摘要、收据 | [authority.rs](../../Modules/LibraryCatalog/src/authority.rs) | gRPC 命令幂等、重放、收据 |
| 操作水位 | [authority.rs](../../Modules/LibraryCatalog/src/authority.rs) 的 `operationRevision` | 单客户端修订、补交、对账 |
| 本地操作日志 | [LibraryStore.swift](../../Sources/RAWMasterCore/LibraryStore.swift) 的 `operations` 表 | 客户端 outbox 与恢复 |
| 封存会话不可变 | [authority_schema.sql](../../Modules/LibraryCatalog/src/authority_schema.sql) 的封存触发器 | 归档资格只来自封存清单 |
| 逐文件归档资格 | [authority_schema.sql](../../Modules/LibraryCatalog/src/authority_schema.sql) 的 `lc_archive_files` | 归档计划、排除项零引用 |
| 内容身份与去重 | `lc_contents(sha256, byte_count)`、`lc_replicas` | S3 对象 key、SHA-256、同库去重 |
| 本地备份包 | [backup.rs](../../Modules/LibraryCatalog/src/backup.rs) · [inventory.rs](../../Modules/LibraryCatalog/src/backup/inventory.rs) | 客户端目录快照、清单、恢复 |
| 内容寻址资源 | [resources.rs](../../Modules/LibraryCatalog/src/resources.rs) | 对象 key 与校验思路 |
| 分组制作作业 | [processing/schema.sql](../../Modules/LibraryCatalog/src/processing/schema.sql) · [processing.rs](../../Modules/LibraryCatalog/src/processing.rs) | Server 1.1 作业描述、冻结输入、发布 |
| 本地调度 | [scheduler.rs](../../Modules/LibraryCatalog/src/scheduler.rs) | 队列、租约、重试 |
| 组织关系 | [organization/schema.sql](../../Modules/LibraryCatalog/src/organization/schema.sql) | 库、作品、版本、集合、堆栈 |
| 现有产品验收 | [033 Server 规格](../033-library-lifecycle/server.md) | 归档、冷热、恢复、同步、远程作业 |

## 2. 外部调研证据

| 主题 | 结论 | 来源 |
| --- | --- | --- |
| gRPC over H2 | 类型化、流式、deadline、取消、拦截器；gRPC Swift 2 支持 Apple/Linux，HTTP/2 transport | [gRPC Swift 2](https://swift.org/blog/grpc-swift-2/) · [gRPC flow control](https://grpc.io/docs/guides/flow-control/) |
| gRPC 消息上限 | 默认 4MB；大对象不应放进 gRPC 消息 | [gRPC max message](https://grpc.io/docs/languages/go/api) |
| QUIC／HTTP3 | 多流、流控、TLS 1.3、连接迁移；本轮 LAN 用 H2 足够 | [RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html) |
| ZeroMQ | 消息必须进内存；大文件要分片；无内建 TLS／发现／版本 | [ZeroMQ Guide](https://zguide.zeromq.org/docs/chapter2/) |
| RustFS S3 | Presigned GET/PUT、multipart、Range、SHA-256 checksum、bucket policy 已测试；ACL 不支持、访问日志计划中 | [RustFS S3 兼容矩阵](https://docs.rustfs.com/en/reference/s3-compatibility) · [RustFS S3](https://docs.rustfs.com/en/administration/protocols/s3) |
| RustFS on TrueNAS | TrueNAS 25.04 App 目录提供 RustFS | [TrueNAS Apps](https://apps.truenas.com/catalog/rustfs) |
| SQLite WAL | 不支持网络文件系统；客户端 SQLite 不应放 NFS／SMB | [SQLite WAL](https://www.sqlite.org/wal.html) |
| PostgreSQL outbox | 业务事务 + outbox 解决跨系统双写 | 通用模式；实现时用 PostgreSQL 事务 |
| S3 ETag | multipart ETag 不是 SHA-256 | 通用 S3 事实；服务端自算 SHA-256 |

## 3. 已确认的架构选择

1. 一库一客户端；Server 托管多个独立库；不做共享库多端写或跨库逻辑。
2. gRPC 负责事务性控制；S3 负责对象字节；PostgreSQL 负责服务端元数据；客户端本地 SQLite 仍是离线目录。
3. Direct 默认，传输失败自动 Relay；两者同一 upload ID／part 号／S3 multipart。
4. PostgreSQL 和 S3 的 HA／持久性由外部负责；RAWMaster 负责元数据一致性、逻辑备份、恢复、对象清单和校验。
5. 自建服务使用自签名证书；客户端固定 CA／SPKI；证书、令牌哈希入元数据备份，私钥／pepper 入加密 secret bundle。
6. 元数据备份默认全 Server 全量逻辑备份；恢复到隔离 PostgreSQL；`metadata doctor` + 对象 HEAD。
7. Server 本地磁盘只放日志、临时文件和有界 Relay 缓冲。

## 4. 明确未实现

- 没有 `RAWMasterServer` 可执行文件、gRPC 服务或 PostgreSQL schema。
- 没有 S3 ObjectStore 适配、presigned Direct、Relay。
- 没有自签名 CA、证书固定、设备令牌、secret bundle。
- 没有元数据一致快照、pg_dump 集成、备份验证、恢复向导、doctor。
- 没有客户端 SQLite 快照上传和重连对账。
- 没有 RustFS 真实吞吐／兼容性测试。
- 没有 10TB／20 万对象基线。
- 没有远程作业。
- 没有编辑／导出云端；本轮不涉及。

## 5. 研究缺口

| 问题 | 需要的证据 | 影响 |
| --- | --- | --- |
| RustFS 在 TrueNAS 25.04 的真实吞吐／CPU | 10GbE、jumbo、Direct、multipart 并发 | S2 基线 |
| presigned multipart／checksum 兼容 | 真实 RustFS 版本、part ETag、SHA-256 | Direct／Relay |
| gRPC Swift 2 + 私有 CA | 构建、TLS trust roots、流式、重连 | 客户端 |
| AWS SDK for Swift／Soto + RustFS | path-style、presigned、multipart | 客户端 |
| PostgreSQL 一致快照 | `pg_dump --snapshot`、锁、临时磁盘 | S3 元数据备份 |
| 10TB 元数据规模 | pg_dump／restore、doctor、HEAD 时长 | S5 |
| 自签名证书轮换 | 同 CA 换 leaf、客户端固定 | 安全 |
| secret bundle 加密 | age／libsodium、密钥管理、恢复 | 安全 |
| 单客户端所有权转移 | 旧 epoch fencing、真实双机 | S1/S4 |
| 外部冷备回执 | TrueNAS 冷备状态是否可读 | S4 释放策略 |

## 6. 非声明

- 本文和 040 其它文档是设计，不是 Server 已实现或已验收。
- RustFS 是 S3 兼容子集，不是 AWS S3 全等；ACL、访问日志、POST form 等边界必须避开。
- 自签名 TLS 只保护传输，不保护备份静态数据；备份必须另行加密。
- PostgreSQL HA 不能替代逻辑备份；S3 持久性不能替代对象清单和引用一致性。
- 10TB 设计不能外推 100TB／200 万文件；容量专项另立。
