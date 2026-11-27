# 040 · 规划验证记录

2026-11-27 · 本轮为架构与功能设计，不是产品验收。记录已完成的文档核对、外部调研和进入实现前必须补齐的验证。

## 1. 本轮完成

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 阅读 033 资料库生命周期、Server、数据模型、方案 | 完成 | [033 spec](../033-library-lifecycle/spec.md) · [server](../033-library-lifecycle/server.md) · [data-model](../033-library-lifecycle/data-model.md) · [plan](../033-library-lifecycle/plan.md) |
| 阅读 F006／F007、04、08、26、27 | 完成 | [02](../../docs/planning/02-feature-portfolio-draft.md) · [04](../../docs/planning/04-client-server-workflow-draft.md) · [08](../../docs/planning/08-local-database-and-sync-evaluation.md) · [26](../../docs/planning/26-library-lifecycle-proposal.md) · [27](../../docs/planning/27-server-version-plan.md) |
| 核对本地操作／归档／备份／作业底座 | 完成 | [证据](evidence.md) |
| 调研 gRPC Swift 2、HTTP/2 流控、QUIC、ZeroMQ | 完成 | [evidence](evidence.md#2-外部调研证据) |
| 调研 RustFS S3 兼容矩阵、TrueNAS 25.04 App、S3 presigned／multipart | 完成 | [storage](storage.md) · [evidence](evidence.md#2-外部调研证据) |
| 设计 PostgreSQL 元数据、上传状态机、对象模型 | 完成 | [data-model](data-model.md) |
| 设计元数据一致性、备份、验证、恢复 | 完成 | [metadata-backup](metadata-backup.md) |
| 设计自签名证书、令牌、secret bundle | 完成 | [security](security.md) |
| 设计 Direct／Relay、10GbE／10TB、两种部署 | 完成 | [storage](storage.md) |
| 重写功能规格、协议、方案、任务、交互 | 完成 | [spec](spec.md) · [protocol](protocol.md) · [plan](plan.md) · [tasks](tasks.md) · [ux](ux.md) |
| 相对链接检查 | 完成 | 本目录、27 总览及入口；断链为零 |

## 2. 本轮未完成

- **没有服务端实现。** 没有 gRPC 服务、PostgreSQL schema、S3 适配、元数据备份代码。
- **没有 RustFS 实测。** 未测 TrueNAS 25.04 App 的真实吞吐、presigned multipart、checksum、TLS、升级兼容。
- **没有 PostgreSQL 备份实测。** `pg_dump --snapshot`、隔离恢复、doctor、10TB 元数据规模未执行。
- **没有证书／令牌实测。** 私有 CA、客户端固定、证书轮换、secret bundle、恢复未执行。
- **没有 Direct／Relay 实测。** 未测 10GbE、jumbo、无 LAG、S3 直传和回退。
- **没有客户端实现。** grpc-swift-2、AWS SDK for Swift／Soto、钥匙串、SQLite 快照未接入。
- **没有元数据恢复演练。** 空 PostgreSQL 恢复、对象缺失、客户端重连、所有权 epoch 未执行。
- **没有 UI 原型更新。** 现有 Server 预演仍是旧的归档／同步／作业模拟；本轮只定义交互。
- **没有远程作业。** Server 1.1 未开始。

## 3. 进入 S1 前必须补齐

1. 按 [AGENTS](../../AGENTS.md) 和 [UI 研发流程](../../docs/ui/README.md) 更新摄影工作台，覆盖 [ux.md](ux.md) 第 5 节；记录浏览器、窄窗、浅／深色、键盘、焦点、读屏。
2. 冻结 S0 契约：gRPC proto、PostgreSQL schema、S3 profile、备份格式、证书／令牌模型。
3. 用真实 RustFS 跑 Direct presigned multipart、checksum、Range、TLS、Relay 回退。
4. 用真实 PostgreSQL 跑 `pg_dump --snapshot`、隔离恢复、doctor、对象清单。
5. 用真实自签名 CA 跑客户端固定、证书轮换、令牌撤销、secret bundle 恢复。
6. 确认 10GbE／jumbo 端到端 MTU、RustFS App 网络、无 LAG 的实际吞吐。
7. 确认外部冷备状态是否可回执；若否，UI 只能显示“外部负责／未知”。

## 4. 证据口径

- 本文件只证明“设计与现有代码／外部调研已对齐”，不证明 Server 可用。
- 浏览器原型只能证明交互，不证明 TLS、S3、PostgreSQL、备份或恢复。
- 服务端测试必须使用真实 PostgreSQL、真实 S3 对象和真实网络故障；mock 不能替代。
- 性能数字必须注明硬件、网络、MTU、Direct／Relay、对象大小、冷热和并发；API 返回时间不能冒充端到端恢复时间。
- 未通过的验收项保留在任务和发布门中，不用文档完成数量替代。
