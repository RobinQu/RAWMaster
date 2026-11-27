# 040 · Server 任务与发布门

2026-11-27 · 规划任务，均未开始。任务按可独立演示的增量拆分；完成一项不等于发布门通过。产品要求见[规格](spec.md)，技术方案见[plan.md](plan.md)。

## 0. 交付原则

- **先契约后代码。** S0 冻结 gRPC proto、PostgreSQL schema、S3 profile、备份格式、证书／令牌模型。
- **先正确后规模。** 五文件、Direct／Relay、元数据恢复、证书／令牌恢复通过后，再做 10TB／10GbE。
- **真实对象、真实网络、真实 PostgreSQL。** 不用 mock 代替 S3 校验、pg_dump／restore、TLS 和对象 HEAD。
- **不跨阶段声明。** S1 不能标 Server 1.0；S2 不能标元数据恢复；S3 不能标冷热与过期完成。

## S0 · 契约与夹具

- [ ] **SRV01 · gRPC 契约。** 冻结 `LibraryService`、`TransferService`、`MetadataService`、`JobService` proto；操作信封、错误码、幂等、所有权 epoch。[协议](protocol.md)
- [ ] **SRV02 · PostgreSQL schema。** 库、设备、令牌哈希、操作、对象、引用、上传意图、快照、配额、outbox、审计；迁移和版本。[数据模型](data-model.md)
- [ ] **SRV03 · S3 profile。** RustFS／MinIO／云 S3 的 endpoint、path-style、TLS、presigned、multipart、checksum、part size。[存储](storage.md)
- [ ] **SRV04 · 元数据备份格式。** manifest、pg_dump、对象清单、checksums、secret bundle 边界、恢复步骤。[元数据备份](metadata-backup.md)
- [ ] **SRV05 · 证书／令牌模型。** 私有 CA／单证书、客户端固定、令牌哈希／pepper、secret bundle 加密。[安全](security.md)
- [ ] **SRV06 · UI 状态。** 单客户端所有权、Direct／Relay、元数据备份恢复、证书／令牌状态；更新摄影工作台并走查。[交互](ux.md)

## S1 · 控制面与身份

- [ ] **SRV10 · Server 骨架。** Rust 单二进制；gRPC、健康、日志、指标、优雅退出；本地仅日志／临时目录。
- [ ] **SRV11 · 自签名 CA／证书。** 私有 CA + leaf 或单证书；SAN、TLS、SPKI；客户端固定与变化提示。[安全](security.md)
- [ ] **SRV12 · 设备登记与令牌。** 一次性登记码、随机令牌、哈希存储、撤销、轮换；钥匙串。[协议](protocol.md#2-tls认证与所有权)
- [ ] **SRV13 · 库所有权。** `ownerDeviceID`、`ownershipEpoch`、fencing token；第二客户端拒绝；显式转移。[数据模型](data-model.md#2-身份所有权与设备)
- [ ] **SRV14 · PostgreSQL 接入。** 连接池、迁移、事务、操作日志、收据、outbox。
- [ ] **SRV15 · gRPC 客户端。** grpc-swift-2、TLS trust roots、令牌、重试、deadline、流式事件。
- [ ] **SRV16 · 健康与版本。** 在线／离线／证书变化／版本不兼容；`GetServerInfo`、版本握手。

**S1 出口。** 错误证书／令牌被拒；第二客户端不能写；所有权转移 fencing 生效；Server 重启后库和令牌恢复；本地离线不受影响。

## S2 · 归档与对象面

- [ ] **SRV20 · 归档计划。** 封存资格、逐文件清单、排除项零引用、重复幂等。[规格](spec.md#62-归档与-s3-对象)
- [ ] **SRV21 · Direct 上传。** `CreateUpload`、S3 multipart、presigned part、part manifest、过期。
- [ ] **SRV22 · Relay 回退。** 传输错误触发；同一 upload ID／part 号；流式写 S3；不落完整本地文件。[协议](protocol.md#6-自动-relay)
- [ ] **SRV23 · 校验与登记。** 完成 multipart、HEAD、SHA-256、字节数；PostgreSQL 事务登记对象和归档引用。
- [ ] **SRV24 · 去重与引用。** 同库内容去重；多引用；删除引用不删对象；跨库不去重。
- [ ] **SRV25 · 状态与队列。** 待上传、Direct、Relay、校验中、对象可用、引用已登记、待找回、缺失／损坏。
- [ ] **SRV26 · 五文件端到端。** A.RAW 排除、A.JPG 纳入、B.RAW 仅序列、C.RAW 必要帧排除、D.RAW 失败；S3 对象恰为 A.JPG／B.RAW；恢复 A.RAW 只增一份。
- [ ] **SRV27 · 故障。** 断网、TLS 失败、S3 5xx、multipart 中断、磁盘满、checksum 不符、重复 part。

**S2 出口。** 五文件样本精确；Direct 和 Relay 都完成且哈希一致；中断续传不重复；排除项零对象引用；状态分列。

## S3 · 元数据备份、恢复与 secret bundle

- [ ] **SRV30 · `metadata doctor`。** 约束、操作缺口、收据、所有权、对象、引用、配额、上传意图、作业、快照、orphan、outbox。[元数据备份](metadata-backup.md#3-一致性不变量)
- [ ] **SRV31 · 一致快照。** `REPEATABLE READ` + `pg_export_snapshot` + `pg_dump --snapshot` + 对象清单同一时点。
- [ ] **SRV32 · 备份格式。** manifest、dump、object-manifest、library-snapshots、checksums；S3 布局；保留。
- [ ] **SRV33 · 备份验证。** 隔离 PostgreSQL 恢复、迁移、doctor、计数、抽样 HEAD；未验证不可恢复。
- [ ] **SRV34 · 隔离恢复。** pg_restore、对象 HEAD、缺项分类、瞬态重置、只读启动、客户端重连、切换。
- [ ] **SRV35 · 客户端对账。** 服务器旧修订、客户端补交；重复 command ID 去重；所有权 epoch。
- [ ] **SRV36 · 证书／令牌备份。** 公有证书、SPKI、令牌哈希入元数据；私钥／pepper 入 secret bundle；加密和恢复。
- [ ] **SRV37 · 对象缺失／重绑定。** missing／corrupt 报告；冷备修复；换 bucket／endpoint 重新 HEAD。
- [ ] **SRV38 · 恢复演练。** 空 PostgreSQL 恢复到隔离环境；记录回执、缺项、时长、临时磁盘。

**S3 出口（Server 1.0 发布门）。** 全量备份可恢复到空 PostgreSQL；doctor 通过；对象缺失准确报告；证书／令牌可恢复；secret bundle 缺失时安全失败；客户端重连不丢操作。

## S4 · 冷热、过期与单客户端重连

- [ ] **SRV40 · 代理。** JPEG 代理与机内 JPEG 分标；可重建；S3 或客户端生成。
- [ ] **SRV41 · 按需取回。** presigned GET／Relay、Range、断点、SHA-256。
- [ ] **SRV42 · 固定离线。** 照片／组／项目；设备本地状态；不参与共享同步。
- [ ] **SRV43 · 受控释放。** 未固定、对象可用、外部冷备、未同步、非唯一副本；显示原因。
- [ ] **SRV44 · 过期。** 本地缓存、代理、垃圾桶、草稿、版本、墓碑、暂存、备份代次；S3 生命周期边界。
- [ ] **SRV45 · 客户端快照。** 目录快照上传 S3、索引、修订、恢复；不超前。
- [ ] **SRV46 · 单客户端重连与转移。** 离线队列、补交、fencing、第二客户端只读。

**S4 出口。** 冷片可切换；释放门槛不可绕过；垃圾桶／版本／墓碑按策略；旧备份不倒带；单客户端所有权正确。

## S5 · 规模、运维与发布

- [ ] **SRV50 · 10TB／10GbE 基线。** 20 万对象、Direct／Relay、jumbo、无 LAG；吞吐、CPU、时长、临时磁盘。
- [ ] **SRV51 · 备份／恢复性能。** pg_dump、pg_restore、doctor、全量 HEAD、恢复窗口。
- [ ] **SRV52 · 证书轮换。** 同一 CA 换 leaf；客户端无感；单证书模式重新固定。
- [ ] **SRV53 · 密钥管理。** secret bundle 加密、轮换、权限、日志脱敏；错误密钥拒绝。
- [ ] **SRV54 · 审计与监控。** 证书、令牌、备份、恢复、上传、Relay、配额；无敏感值。
- [ ] **SRV55 · 升级与回退。** 升级前备份、隔离迁移、版本握手、只读路径。
- [ ] **SRV56 · 灾备演练。** 元数据 + secret bundle + S3 对象恢复到隔离服务器；客户端重连；记录缺项和时长。
- [ ] **SRV57 · 发布评审。** 规格、数据、协议、存储、备份、安全、验证、已知限制同一评审包。

**S5 出口。** 10TB／10GbE 有真实基线；证书／密钥轮换和恢复演练通过；未测规模不标完成。

## S5.1 · 远程作业（Server 1.1）

- [ ] **SRV60 · 能力登记。** 引擎、模型、CPU／GPU、内存、许可；缺能力禁用。
- [ ] **SRV61 · 作业提交。** 冻结输入、配方、引擎／模型；需补传对象。
- [ ] **SRV62 · 队列／取消／重试。** 租约、崩溃回收、断线查询、单次发布。
- [ ] **SRV63 · 结果登记。** 暂存、校验、采用；旧结果不覆盖。
- [ ] **SRV64 · 端到端。** 断网、改组、重试原请求只产生一个绑定原输入的结果。

## 发布门速查

| 门 | 必须通过 | 不能替代 |
| --- | --- | --- |
| 设计门 | SRV01–SRV06 评审通过 | 代码编译、演示 |
| S1 门 | 证书、令牌、所有权、gRPC、PostgreSQL | 归档、备份 |
| S2 门 | 五文件、Direct／Relay、校验、去重 | 元数据恢复 |
| 1.0 门 | S1＋S2＋S3＋S4 | 远程作业、10TB |
| 运维门 | 10TB／10GbE、证书轮换、备份恢复演练 | 单一演示环境 |
| 1.1 门 | S5.1 作业重连与单次登记 | 100TB |
