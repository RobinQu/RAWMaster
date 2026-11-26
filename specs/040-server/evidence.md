# 040 · 现有基础与缺口

2026-11-26 · 设计依据。以下只证明本地资料库已经具备哪些可复用底座，**不证明 Server 已存在或已验收**。服务端网络、认证、服务器目录、独立备份自动化、冷热缓存、多设备同步和远程执行均未实现。

## 1. 可复用的本地底座

| 现有能力 | 证据 | 对 Server 1.0 的作用 |
| --- | --- | --- |
| 资料库身份与设备身份 | `lc_meta.libraryID`、`metadata.deviceID`；[目录 schema](../../Modules/LibraryCatalog/src/authority_schema.sql) · [LibraryStore](../../Sources/RAWMasterCore/LibraryStore.swift#L85) | 绑定服务器、区分设备、恢复后换设备身份 |
| 操作 ID、载荷摘要、收据 | [authority.rs](../../Modules/LibraryCatalog/src/authority.rs#L243) 按 `commandID` 保存请求摘要与结果；同 ID 不同载荷报冲突 | 同步幂等、重放去重、客户端收据对账 |
| 操作水位与结果修订 | [authority.rs](../../Modules/LibraryCatalog/src/authority.rs#L298) 维护 `operationRevision`，收据带 `baseCatalogRevision`／`resultCatalogRevision` | 服务器修订、增量拉取、冲突判断 |
| 本地业务操作日志 | [LibraryStore.swift](../../Sources/RAWMasterCore/LibraryStore.swift#L111) 的 `operations` 表含设备、实体、基准修订、结果修订、载荷版本 | 客户端 outbox 与冲突来源 |
| 封存会话不可变 | [authority_schema.sql](../../Modules/LibraryCatalog/src/authority_schema.sql) 的封存触发器；`session.seal` 后拒绝写入 | 归档资格只来自封存清单，不能被后续编辑改写 |
| 逐文件归档资格视图 | [authority_schema.sql](../../Modules/LibraryCatalog/src/authority_schema.sql#L77) 的 `lc_archive_files` 从有效 scope 取文件、内容、哈希、路径 | 服务端归档计划与引用派生 |
| 内容身份与去重 | `lc_contents(sha256, byte_count)`、`lc_replicas`；[authority_schema.sql](../../Modules/LibraryCatalog/src/authority_schema.sql#L11) | 内容寻址对象、多引用、多副本 |
| 本地备份包 | [backup.rs](../../Modules/LibraryCatalog/src/backup.rs#L73) 的 manifest 含目录快照、原件、资源、缺项；[inventory.rs](../../Modules/LibraryCatalog/src/backup/inventory.rs#L10) 的 Original／Resource | 服务端备份代次与恢复清单 |
| 内容寻址资源 | [resources.rs](../../Modules/LibraryCatalog/src/resources.rs#L10) 的 `lc_resources` 与 `objects/<sha>/<sha>` 布局 | 主存对象库、资源校验、去重 |
| 分组制作作业 | [processing/schema.sql](../../Modules/LibraryCatalog/src/processing/schema.sql) 的 jobs／inputs／attempts；[processing.rs](../../Modules/LibraryCatalog/src/processing.rs#L132) 的 freeze／claim／publish | 远程作业描述、输入冻结、结果登记 |
| 本地任务调度 | [scheduler.rs](../../Modules/LibraryCatalog/src/scheduler.rs) 的队列、租约、尝试、外部交付 | 服务端队列、worker 租约、重试 |
| 组织关系与版本 | [organization/schema.sql](../../Modules/LibraryCatalog/src/organization/schema.sql) 的 works／versions／collections／stacks | 恢复与同步的关系对象 |
| 现有产品验收 | [033 Server 规格](../033-library-lifecycle/server.md#服务端验收场景) 的归档、冷热、恢复、同步、远程作业场景 | 本规格的验收来源 |
| 同步选型研究 | [08 本地数据库与同步评估](../../docs/planning/08-local-database-and-sync-evaluation.md) 的业务级同步、冲突和媒体分离结论 | 不共享活动数据库、按操作同步 |

## 2. 已有但尚未达到 Server 要求

| 现有实现 | 差距 |
| --- | --- |
| Rust 目录命令 | 只在本地进程调用；没有 HTTP、设备鉴权、服务器修订、字段冲突层 |
| 操作收据 | 每库本地收据；没有跨设备 outbox、拉取游标、回声抑制 |
| 备份包 | 本地文件系统包；没有独立目标、代次调度、周期校验、服务器恢复入口 |
| 归档视图 | 本地查询视图；没有服务端归档引用、上传暂存、对象主存、待找回状态 |
| 资源对象 | 本地 `LibraryResources`；没有服务器对象库、Range 下载、内容寻址主存 |
| 分组作业 | 本地渲染；没有执行端能力、远程输入解析、跨机器租约和结果回传 |
| 资料库 UI | 没有 Server 设置、归档队列、备份代次、固定离线、冲突解决、作业重连 |
| 代理 | 现有 JPEG 显示代理研究，不等于服务器冷片代理与按需取回闭环 |

## 3. 明确未实现

- 没有 `RAWMasterServer` 可执行文件、HTTP 服务、数据库 schema 或部署脚本。
- 没有 TLS、设备登记、令牌、撤销、指纹确认。
- 没有服务器端资料库绑定、操作同步、冲突表或引导快照。
- 没有服务端独立备份目标、代次调度、逐对象校验、恢复向导。
- 没有服务器冷片代理、固定离线、受控释放。
- 没有远程 worker、能力登记、远程作业提交／查询／取消／重试。
- 没有百万级／100 TB 容量测量。
- 没有真实多设备同步或灾备恢复演练。

## 4. 本轮使用的现有文档

- [033 资料库生命周期](../033-library-lifecycle/spec.md)：四阶段、归档资格、五文件样本、100 TB 参照。
- [033 Server 产品规格](../033-library-lifecycle/server.md)：存储、备份、冷热、同步、远程计算和服务端验收。
- [033 数据模型](../033-library-lifecycle/data-model.md)：本地身份、操作、作业、原件与兼容。
- [033 前三阶段方案](../033-library-lifecycle/plan.md)：Rust 目录内核、SQLite、索引与 Server 后置。
- [26 资料库生命周期方案](../../docs/planning/26-library-lifecycle-proposal.md)：产品交付顺序与 Server 建议。
- [04 客户端与服务端工作流](../../docs/planning/04-client-server-workflow-draft.md)：历史协作流程、状态与冲突原则。
- [02 特性地图](../../docs/planning/02-feature-portfolio-draft.md)：F006、F007 要求。
- [08 本地数据库与同步评估](../../docs/planning/08-local-database-and-sync-evaluation.md)：业务级同步与 Turso 边界。
- [00 SDD 规划总览](../../docs/planning/00-sdd-planning-overview.md)：阶段与文档入口。

## 5. 证据缺口与研究问题

| 问题 | 需要的证据 | 影响 |
| --- | --- | --- |
| 每库 SQLite 是否支撑目标设备数和批次 | 多设备并发写入、批量操作、作业写入的等待与错误率 | D-SRV-01 目录引擎 |
| 归档吞吐瓶颈 | 1／10 Gbps、SSD／HDD／NAS、不同块大小的真实字节与时长 | S2 计划与容量 |
| 代理规格 | 冷片首屏、判读质量、带宽、生成 CPU／GPU 成本 | S3 计划 |
| 独立备份最小方案 | 第二块盘／NAS／远端的容量、校验时长、恢复演练 | D-SRV-02 |
| 冲突可理解性 | 双设备真实工作流的冲突类型、解决耗时、误操作 | S3 计划 |
| 远程引擎边界 | 各作业类型在 Linux 与 Mac 的输入、输出、像素差异和许可 | S4 计划 |
| 百万级目录 | 分页、引导、索引、恢复、内存和存储 | S5 容量专项 |

## 6. 结论

现有本地资料库已经具备 Server 需要的**身份、操作收据、封存不可变、归档资格、内容身份、备份清单、资源对象和作业表**底座。Server 1.0 的主要工作不是重写资料库，而是把这些本地契约接到一个可认证、可恢复、可解释的服务端，并补齐跨设备同步、独立备份、冷热缓存和作业执行。设计阶段不能把这些底座说成已经联网或已经验收。
