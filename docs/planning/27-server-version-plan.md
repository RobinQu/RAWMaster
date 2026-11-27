# RAWMaster Server 1.0 功能规划

2026-11-27 · **架构已确认，规划中；未开始实现。** 本文是 Server 版本的总览与决策入口，详细设计见 [040 规格](../../specs/040-server/spec.md)。资料库前三阶段仍以 [033](../../specs/033-library-lifecycle/spec.md) 为准。

## 1. 定位

Server 托管多个独立资料库，每库授权一个可写副本。客户端是离线工作区，可在多个用户选址的库包之间逐一切换。Server 提供长期归档、冷热访问、元数据备份和后续远程计算。[042 本地客户端](../../specs/042-local-library-workbench/spec.md)

> **gRPC 控制面 + S3 对象面 + PostgreSQL 元数据 + 自签名身份。**

PostgreSQL 和 S3 的高可用由基础设施负责；RAWMaster 负责自身**元数据一致性、逻辑备份、恢复**，以及证书、令牌和 secret bundle 的安全备份。

## 2. 为什么现在做

本地资料库已经能导入、初筛、精编、编辑、导出，也已有操作收据、封存不可变、逐文件归档资格、内容身份、备份包、资源对象和作业表。缺少的是：

- 哪些原片真的在 S3，哪些只有目录记录；
- 服务器证书是否可信，哪台设备拥有这个库；
- 笔记本空间不足时，冷照片能否代理浏览、按需取回；
- 上传中断或 S3 不可达时，能否自动 Relay；
- 服务器 PostgreSQL 元数据损坏后，能否恢复到空库并核对对象；
- 证书、令牌、私钥丢失后，能否安全恢复身份。

## 3. 功能地图

| 能力 | 用户结果 | 关键边界 |
| --- | --- | --- |
| 本机库包 | Finder 双击、选址创建、移动、拷贝、应用切换 | 单活动库，独立拷贝分配新身份 |
| 身份与所有权 | 自签名身份和可转移的单写绑定 | 设备、包实例、所有权 epoch 和恢复代次 |
| 归档 | 逐文件 S3 对象、引用、校验 | 只从封存纳入／恢复纳入；排除项零引用 |
| Direct／Relay | 默认客户端直传 S3，失败自动 Relay | 同一 upload ID／part；Relay 不落完整本地文件 |
| 冷热 | 代理浏览、按需取回、固定、释放 | 释放需对象可用、外部冷备、未固定、未同步、非唯一 |
| 元数据备份 | 全 Server 一致快照、验证、恢复 | PostgreSQL 一致快照 + 对象清单；未验证不可恢复 |
| 证书／令牌 | 证书、令牌哈希、私钥／pepper 可恢复 | 公有人备份；私密入加密 secret bundle |
| 过期 | 垃圾桶、草稿、版本、墓碑、暂存、备份代次 | `objects/` 不被 S3 生命周期删除 |
| 远程作业（1.1） | 冻结输入的服务器作业 | 只开放已验证 Linux 引擎；本轮不实现 |

## 4. 关键设计选择

1. **本机单活动库，Server 单写者。** 首次启动可创建本地库，或连接 Server 后新建／同步到选定位置。Server 写授权绑定设备和包实例。
2. **gRPC 控制，S3 内容，PostgreSQL 元数据。** Direct 走 S3，Relay 传有界分块，业务事务由 PostgreSQL 提交。
3. **Direct 默认，Relay 回退。** Direct 直传 RustFS／云 S3；传输失败按 part 自动 Relay；两种路径同一 upload ID 和 S3 multipart。
4. **全 Server 全量元数据备份。** PostgreSQL 一致快照 + 对象清单 + checksums；恢复到隔离数据库，`metadata doctor` + 对象 HEAD；按库恢复后续。
5. **自签名证书是正式方案。** 私有 CA + leaf，客户端固定 CA／SPKI；证书、令牌哈希入元数据备份；私钥、pepper、S3 凭据入加密 secret bundle。
6. **存储可靠性外部化。** RAWMaster 不做 RAID／EC／跨站复制；TrueNAS 冷备负责介质与灾难恢复；RAWMaster 只做逻辑清单、哈希、引用和恢复。
7. **Server 本地磁盘只放日志／临时。** PostgreSQL、S3 外部；Server 可容器化；Relay 流式，不落完整文件。
8. **先资料库协同，随后远端计算。** 040 先做传输和恢复，041 委派代理、渲染及生成式任务，交付写盘仍由 032 在本机完成。[双端队列](../../specs/041-server-image-editing/queues.md)

2026-11-27 已把 main 的 [037 色彩／HDR](../../specs/037-color-film-hdr/spec.md)、[038 DAG 工作流](../../specs/038-node-dag-workflow/spec.md) 和 [039 Rust scene backend](../../specs/039-rust-scene-backend/spec.md) 纳入 040／041：场景图、输出状态、模型前缀、模板／批次候选随元数据保存；041 的 `image_scene_batch` 仍受 Linux／Vulkan scene executor 与色彩门约束。039 当前为 macOS Metal-only。

## 5. 交付阶段

| 阶段 | 交付 | 发布门 |
| --- | --- | --- |
| S0 · 契约 | gRPC proto、PostgreSQL schema、S3 profile、备份格式、证书／令牌 | 评审通过；无未决 P0 |
| S1 · 控制面 | 自签名 CA、令牌、所有权、gRPC、PostgreSQL | 错误证书／令牌被拒；第二客户端不能写 |
| S2 · 对象面 | 归档、Direct、Relay、校验、去重、引用 | 五文件样本；Direct／Relay 一致；断点不重复 |
| S3 · 元数据备份 | doctor、快照、dump、对象清单、验证、隔离恢复 | 空 PostgreSQL 恢复；对象缺失报告；证书／令牌恢复 |
| S4 · 同步与冷热 | 同步已有库、代理、取回、固定、释放、垃圾桶、客户端重连 | 选择位置并打开正确修订，冷片与恢复通过 |
| S5 · 规模与运维 | 10TB／10GbE、证书轮换、secret bundle、演练 | 真实基线；未测规模不标完成 |
| S5.1 · 远程作业 | 作业、能力、队列、结果 | Server 1.1 独立验收 |

**本地客户端按 042 独立发布。** Server 客户端在该版本上接入，服务端需要 S1 至 S4 通过。

## 6. 用户可见入口

- **设置 → Server**：地址、证书指纹、私有 CA、登记、设备、库绑定、S3 profile、备份目标。
- **资料库工具 → Server**：归档、Direct／Relay、对象状态、冷热、过期、所有权、元数据备份、恢复。
- **标题栏／状态区**：在线／离线、证书变化、待上传、Relay、待备份、待恢复。
- **照片／组／项目上下文**：归档状态、固定离线、取回原件、释放本地副本。
- **导入完成摘要**：本次纳入／排除／仅序列／失败、可归档数量与字节、开始归档。

预演从[首次打开](../ui/prototype/index.html?serverReview=1#welcome)开始。连接已有库后可查看 [RAWMaster Server](../ui/prototype/index.html?serverReview=1#tools/server) 和[制作任务](../ui/prototype/index.html?serverReview=1#jobs)。

## 7. 验收主线

1. **五文件。** A.RAW 排除、A.JPG 纳入、B.RAW 仅序列、C.RAW 必要帧排除、D.RAW 失败；S3 对象恰为 A.JPG／B.RAW；恢复 A.RAW 只增一份引用。
2. **Direct／Relay。** 断网／S3 不可达自动 Relay；同一 part 不重传；最终 SHA-256 一致；重复提交不产生第二对象。
3. **元数据恢复。** 全量备份恢复到空 PostgreSQL；doctor 通过；对象缺失报告；客户端重连补交；未验证备份不可恢复。
4. **证书／令牌。** 同 CA／私钥恢复后客户端无需重新固定；错误证书、过期、撤销令牌被拒；secret bundle 缺失安全失败。
5. **单客户端所有权。** 第二客户端不能写；转移后旧 epoch 被 fencing；离线操作补交。
6. **冷热／释放。** 代理切完整 RAW；释放条件不可绕过；垃圾桶／版本／墓碑按策略。
7. **对象缺失／重绑定。** missing／corrupt 报告；冷备修复；换 bucket／endpoint 重新 HEAD。
8. **10TB／10GbE。** 记录 Direct／Relay 吞吐、pg_dump／restore、doctor、HEAD 时长；不外推 100TB。

## 8. 待决问题

| 编号 | 问题 | 当前建议 |
| --- | --- | --- |
| D-SRV-01 | 私有 CA 还是单证书 | 私有 CA + leaf；单证书简化模式 |
| D-SRV-02 | 令牌模型 | 随机不透明 + 哈希；pepper 进 secret bundle |
| D-SRV-03 | secret bundle 加密 | age／OpenPGP／libsodium；密钥离线 |
| D-SRV-04 | 备份粒度 | 全 Server 全量；按库后续 |
| D-SRV-05 | S3 校验深度 | 备份抽样 HEAD；恢复全量；周期 scrub 可选 |
| D-SRV-06 | 桶布局 | 单 bucket + 前缀；严格隔离时 bucket-per-library |
| D-SRV-07 | Relay 触发 | 仅传输错误；认证／哈希／配额不触发 |
| D-SRV-08 | Postgres HA | 外部 primary + standby；不引入分布式 SQL |
| D-SRV-09 | 冷备回执 | 外部负责；可显示“未知”或接收回执 |
| D-SRV-10 | 远程作业 | Server 1.1；仅已验证 Linux 引擎 |

## 9. 与现有规格的关系

- [033 资料库生命周期](../../specs/033-library-lifecycle/spec.md)：归档资格、五文件、备份与恢复。
- [033 Server 产品规格](../../specs/033-library-lifecycle/server.md)：存储、冷热、同步、远程计算。
- [F006／F007](02-feature-portfolio-draft.md#f006-服务端归档与备份闭环)：归档与离线要求；V1 收窄为单客户端。
- [040 规格](../../specs/040-server/spec.md)：功能、存储、元数据备份、安全、数据、协议、任务。
- [040 存储](../../specs/040-server/storage.md)：RustFS／TrueNAS、Direct／Relay、10GbE／10TB。
- [040 元数据备份](../../specs/040-server/metadata-backup.md)：一致性、备份、恢复、doctor。
- [040 安全](../../specs/040-server/security.md)：自签名证书、令牌、secret bundle。
