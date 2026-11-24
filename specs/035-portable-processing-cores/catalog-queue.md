# 资料库核心与跨视图任务队列

建议在现有 `rawmaster-library` 增加作业调度域。资料库统一决定可以处理哪一份内容、哪项修订拥有发布资格，图像库接受冻结的输入与配方并返回像素或产物。两者各自编译，桌面和服务端宿主负责把它们连起来。PoC 已在 macOS 和 Linux arm64 上运行同一份 Rust 调度代码。Swift 也通过生产 C 桥取得了照片 ID，并用它提交、发布和读回了一项任务。[Swift 端到端记录](evidence/catalog-swift.json) · [Rust PoC](../../experiments/portable-processing/catalog/src/queue.rs)

## 当前实现与迁移入口

| 入口 | 已有语义 | 接入共享调度时的责任 |
| --- | --- | --- |
| 资料库导入、筛选和分页 | 现有 v8 目录用 Rust/SQLite 维护逻辑文件、纳入范围、来源、可重建的索引和游标。Swift 写入在宿主拥有的事务中执行。网格按页取卡片，需要批量操作时再取有序目标。 | 原片封存、元数据写入及其索引失效在同一目录事务提交。后台缩略图、索引、分组制作再依据已提交的水位或收据运行。列表按可见页一次取状态。保留现有书签与文件访问范围解析在宿主。[目录事务](../../Sources/RAWMasterCore/LibraryStore+Catalog.swift) · [分页](../../Modules/LibraryCatalog/src/query.rs) · [网格读取器](../../Modules/LibraryCatalog/Swift/LibraryGridDataSource.swift) |
| 资料库发现、分组制作 | 检索作业绑定模型及输入版本。组作品冻结成员和配方，已有租约、暂存、内容校验与发布收据。 | 共享调度器认领一个有界阶段。领域代码保留对原片资格、组修订及成片可读性的终验。由冻结输入登记成片及生成关系。[检索认领与回报](../../Modules/LibraryCatalog/src/discovery/jobs.rs) · [分组认领与暂存](../../Modules/LibraryCatalog/src/processing/render.rs) · [发布作品](../../Modules/LibraryCatalog/src/processing.rs) |
| 编辑、AI 蒙版、生成 | 编辑控制器已按 attempt 和 run ID 拒收旧回调，重启时区分已返回待归档字节、已提交但结果未知的远端操作、可重新准备的操作。 | 将本地推理、全质量渲染和远端结果归档分别排队。保留 `outcomeUnknown` 的查询核对和已接收输出恢复。拖动产生的连续请求留在设备内存，按视窗、作品版本和 generation 合并。[当前调度与启动恢复](../../Sources/RAWMaster/EditingController.swift) · [持久状态转换](../../Sources/RAWMasterCore/LibraryStore+Editing.swift) |
| 导出工作台 | 小尺寸 JPEG 且名称唯一时最多 3 件在途。四 GPU 槽设备上的 2048 px 以内中性 JPEG 可增至 4 件，后台栅格仍保留前台名额。已有选区复核、目标冲突策略、单张发布与文件收据。 | 批次冻结目标列表、采用版本、格式与命名，每张作为可恢复的子作业，保留原序号。编码、受管归档、对外文件交付各自保存收据。按张重试并从成功数恢复进度。[工作台并发与命名](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [外部文件发布](../../Modules/PhotoExport/src/lib.rs) · [导出收据恢复](../../Sources/RAWMasterCore/LibraryStore+RenderedExports.swift) |

## 冻结数据与执行契约

- 持久描述符包含 schema、catalogID、commandID、父批次及序号、用途、库内文件或作品 ID、输入内容摘要与工作修订、配方和资源摘要、引擎或模型版本、输出意图及重试类别。导出增加目的地授权引用、用户选择的重名策略和保留名。设备把授权引用解析为本地书签或服务端对象位置。队列传递描述符与句柄，像素通过缓冲区或受管对象传递。
- `commandID` 标识一次用户意图。相同键与相同描述符重放原收据，同键异内容报冲突。渲染缓存另用内容、图、模型及输出规格的摘要作键。将同一张照片交付到两个目的地可以复用渲染，并分别取得交付收据。生产接入以版本化命令和固定测试向量规定精度、缺省值、字段规范化。PoC 校验 Rust JSON 表示中的载荷、任务类别、资源、预算和重试策略。
- 本机目录使用 SQLite WAL。认领、预算判定、attempt 与随机 token 分配在一个短 `BEGIN IMMEDIATE` 中。长耗时的读取、GPU 计算、文件校验在事务外执行。匹配仍有效的 token 和输入修订后，以同一事务写结果引用、作业终态和变更序号。PoC 已实现 token 核验与资源登记。接入生产时由现有领域命令再核验版本、目录纳入及用户采用关系。[SQLite 事务](https://www.sqlite.org/lang_transaction.html) · [目录对象暂存与登记](../../Modules/LibraryCatalog/src/resources.rs)
- SwiftUI 的任务发起、取消和状态订阅由 actor 承接，UI 线程更新可见行。后台执行器直接使用 Rust 的 `rlib`，或由 C ABI 调用。跨 ABI 指明版本、借用期限、释放函数与错误码。PoC 的 `rmq_probe` 是隔离实验用适配层。发布时复用现有 `rm_library_*` 的长度明确缓冲和同源 SQLite 句柄校验，分发资料库、图像编辑两个核心产物。[生产 ABI](../../Modules/LibraryCatalog/include/rawmaster_library.h) · [宿主装载及 SQLite 校验](../../Modules/LibraryCatalog/Bridge/LibraryLoader.c) · [PoC ABI](../../experiments/portable-processing/catalog/include/queue_probe.h)

### 跨进程续做的设计

用提交时生成的批次 ID 同时标识工作台回执与所有子项。宿主取得输出目录访问后，在写出成片前把版本化清单、目录文件身份与批次控制记录写入同一 v10 目录事务。清单保存资料库与本机写入者身份、目标授权引用、实际命名、重名规则，以及每一项的原始序号、来源摘要、完整配方和已采用归档。暂存草稿可能沿用父版本的 ID，续做直接读取当时冻结的配方。子项各有独立的元数据记录，可以与旧任务表的执行器同时运行。[工作台当前入口](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [Spec 032 工作台](../032-export-workspace/prototype.html)

重开时批量读取已创建的子项，尚未派发的序号来自清单。已存在成片先核对冻结名字、文件身份与摘要，再同步文件和目录并确认。仅有暂存文件的子项等用户继续，在原卷重新核验授权、目标空缺、文件身份和摘要，再以有效子租约排他发布。跨宿主还原后以历史记录呈现。旧批次有足够凭证时仍可确认单张成片。[逐件核验与完成](../../Modules/LibraryCatalog/src/scheduler/batch/items.rs)

两个窗口通过同库事务取得批次执行权。显式取消先关闭该次批次的发布资格，并等待本进程工作退出。排他发布事务在同一写锁下检查批次执行代与子租约，通过已打开的原目录句柄写入。长哈希和文件同步在锁外执行。同一资料库的独立批次用目录身份和规范化文件名协调准备时的占位。占位后仍保持原票据和目标名，外来的同名文件进入核对。重启及异常退出保留未完成项，重新派发使用同一冻结输入和目的地。[原生重启回执及走查](../032-export-workspace/batch-continuation.md)

Rust 批次仓库支持不可变登记、分页、显式续领、租约校验、续租和终止。第一次登记与领租使用同一事务。重复登记同一清单只返回脱敏摘要。SQLite 保存租约令牌的 SHA-256。Swift 编辑备份和 Rust 完整包恢复共用身份轮换与旧工作租约隔离。重开文件发布时仍需解析本机的原目录授权，再在实际写事务里检查批次代与逐项租约。[Rust 批次仓库](../../Modules/LibraryCatalog/src/scheduler/batch.rs) · [Swift 编辑备份恢复](../../Sources/RAWMasterCore/LibraryStore+EditingBackup.swift)

逐项领取在一个写事务内读取当前目录身份、父批次与子项并核验租约。推进整批终态前按索引确认已登记数量，再逐一读取每个冻结序号的规范票据。票据位于非规范键时，当前确认回滚，恢复原键后可继续确认。生产 Swift 工作台已经核对两组实片的 3,872 份文件和票据，整批延迟仍有波动。[逐项事务](../../Modules/LibraryCatalog/src/scheduler/batch/items.rs) · [工作台实测](evidence/workbench-terminal-rows.json)

Linux ARM64 的现有 ABI 已在私有 tmpfs 测试 WAL 空间用尽、目标 inode 用尽及成片发布后确认失败。释放配额后，按原票据重领或确认。取消后的确认仍逐次核对原文件身份，拒绝同名同内容的另一 inode。测试保存了原文件描述符、回滚后的数据库及新旧文件回执。[容量故障与恢复](evidence/workbench-filesystem-capacity.json)

v1 内联清单上限为 8 MiB。两层合法的 64³ RGB LUT 即可超过该额度。v2 使用 `recipeResource` 按 SHA-256 引用不可变工作版本和配置，锁外校验角色、字节和完整输入身份，首份租约与资源一起登记。目录完整包及 Swift 编辑备份均能保存此类资源。双层真实 LUT 经 Swift Codable 和 C ABI 往返，RGB 像素与强度位型均精确保持。完整正文和配置按对象去重。Swift 在本机保存文件书签，Rust 按首次登记的目录身份核对重新授权。卷重新挂载后若系统无法证明同一身份，批次保持待核对。[资源暂存](../../Modules/LibraryCatalog/src/resources.rs) · [目录资源及大配方备份回执](evidence/catalog-production.md)

已知中性工作及配置的编码总计不超过 1 MiB 时，可将 v1 的实际配方直接与首份租约、原目录身份一并登记。大配方继续使用 v2。旧版无目录绑定的清单保持原有上限和读取方式。应用侧的书签绑定原目录与实际资料库文件身份。含已绑定批次的编辑备份采用格式 2，恢复副本在原机也只提供历史记录。[原生重启与备份隔离](evidence/workbench-native-restart.json)

Batch 12 在两个独立 APFS 镜像上复现了原卷以新 `st_dev` 重挂后被判为离线。v10 在新登记的本机 APFS 目录和准备票据中保存卷 UUID、inode 与纳秒出生时间。字段从已打开的文件描述符取得。重新授权时允许同一目录换设备号或挂载位置。每次实际发布仍持有本次目录描述符，在写锁内按当前授权路径核对设备号、inode 和出生时间。Swift 本机书签也记录资料库文件的 APFS 身份，支持资料库和目标位于同一原卷。现有恢复副本以独立写入者打开。[目录与成片身份](../../Modules/LibraryCatalog/src/scheduler/batch/directory.rs) · [资料库书签](../../Sources/RAWMaster/WorkbenchDeliveryAccess.swift) · [原生重挂回执](evidence/workbench-apfs-remount-batch13s.json)

v9 升级前保存旧目录快照。v10 在同一事务中核验每条准备票据和原占位，按原写入者、目录身份和规范文件名登记新占位。旧记录没有卷 UUID 时，采用保守的占位匹配，以免新批次抢占可能仍属于原卷的同名项。缺失或多余的旧占位使整个升级回滚。保留清单、票据与批次代次，清除运行租约，供用户明确继续。已打开的旧工作台连接不能提交旧控制或占位。v9 的目录与票据继续依靠原路径、设备号、inode 和出生时间，原卷改号时保持待核对。[版本栅栏](../../Modules/LibraryCatalog/src/scheduler/batch/schema_v10.sql) · [旧占位迁移](../../Modules/LibraryCatalog/src/scheduler/batch/items.rs)

Linux 使用锁定的 SQLite 3.53.2。Debian 12 系统 SQLite 3.40.1 在 `trusted_schema=OFF` 下拒绝已有目录定义中的 JSON 检查。相同 Linux arm64 容器使用随 Rust 内核构建的 SQLite 后通过队列、迁移与备份测试。macOS 继续链接系统 SQLite，以与 Swift 宿主共用事务句柄。[依赖设置](../../Modules/LibraryCatalog/Cargo.toml) · [系统库反例与双平台测试](evidence/workbench-apfs-remount-batch13s.json)

## 资源、交互与恢复

对每台执行设备设一个资源管理者，跨资料库统一核算 CPU 并行数、GPU 提交额度、推理会话、I/O 和预计峰值内存。统一内存设备按同一物理池核算，独显分别报告主机内存与显存。阶段开始前一次取得所需额度，在 GPU completion fence 或 worker 确认退出后释放。资源不足时让出队首，按等待年龄为长期放不下的大作业预留下一个完整时段。PoC 以每阶段一种资源和一个内存估计验证认领，使用 CPU 2、GPU 1、I/O 1、总计 512 MiB 的测试配额。生产 worker 在认领时声明设备、算子、精度和模型指纹。没有匹配后端时按配方批准的 CPU 路径执行，或等候具备所需能力的设备。实际预算由设备测量决定，一张 6000 万像素的 RGBA16F 表面本身就约占 458 MiB。

有积压且作业可进入时，实验按编辑、导出、编辑、资料库、编辑轮转，游标写入数据库。空任务类别或当前放不下的项让给其他工作。25 次领取实际给编辑 15 次、导出和资料库各 5 次。这个数字代表领取机会。耗时相差很大的任务还须按 tile、图片或推理阶段拆分，测量最长独占时段。预览输入保留最新 generation，已发往 GPU 的旧帧等待 fence，完成时丢弃旧 generation，然后再展示。滑块拖动的每一帧都走磁盘队列会把持久事务延迟加入交互热路径。[轮转与额度实验](evidence/catalog-macos.json)

| 事件 | 状态与效果 |
| --- | --- |
| 重复提交、取消 | 排队或等待输入的作业可直接取消。运行中进入 `cancelling`，确认退出前继续占用额度。晚到的完成回调无法登记结果。已经发布的收据可重复读取。 |
| 临时故障、输入离线 | 对可重放操作用限制次数的指数退避。实验默认最多 3 次、首个延迟 250 ms。离线停在 `waiting`，来源恢复后显式唤醒并重核内容版本。永久错误直接失败。量产按作业 ID 分散重试时间，保留错误码、诊断和尝试历史。 |
| worker 崩溃或过期 | 下一次认领清理到期租约。可重放操作分配新的 attempt/token。过期 token 的心跳和完成均失效。可能已产生外部副作用的操作进入 `reconcile`。对已提交的模型费用、远端 job ID、外部导出文件或现有归档先核对回执。 |
| 已写字节，目录尚未提交 | 私有暂存按内容 SHA-256 放置，已登记引用才进入资料库。重启核对暂存清单，校验相同内容并幂等登记。ACK 丢失可读原收据。外部交付用目的地的无覆盖发布、文件指纹与保留名对账。PoC 只在受管资源路径实测了这条故障链。 |
| 多库、多主机 | 本机多库共享设备资源管理者，各目录保留自己的冻结意图和发布事务。先取得设备暂占额度，再认领目录作业。认领失败即退还。多机服务端通过权威调度服务分配节点及租约，各节点由一个设备管理者执行。同一事务产生投递记录，消费者以操作 ID 去重。SQLite WAL 有同机共享内存要求，远程执行方通过服务 API 收发任务及收据。[SQLite WAL 的部署约束](https://www.sqlite.org/wal.html) · [033 服务端契约](../033-library-lifecycle/server.md) |

同一设备一旦无法确认旧执行器已退出，资源管理者应隔离该设备额度，等待 fence、进程退出或设备重建。数据库租约主要约束逻辑认领和发布。物理显存峰值需要设备采样，并和所有已提交的 GPU 工作对账。

## 实测

2026-11-22，在 Apple M4 Max、128 GiB 的 macOS 27.0.1 与本机 OrbStack 的 Linux arm64/Debian 12 容器上运行 release 构建。macOS 链接系统 SQLite 3.54.0，Linux 实验静态编入 SQLite 3.53.2。两端对每个提交启用 WAL 与 `synchronous=FULL`。Linux worker、状态机和受管存储完全由 Rust 宿主驱动，Python 只发命令、杀进程和核对结果。两边使用各自的本地临时文件系统。[macOS 逐项结果](evidence/catalog-macos.json) · [Linux 逐项结果](evidence/catalog-linux.json)

| 实验 | 观察 |
| --- | --- |
| 多进程及资源 | 8 个独立 Rust 进程同时认领，得到 4 个不同任务，CPU 2、GPU 1、I/O 1。384 MiB 与 128 MiB 占满测试额度后，192 MiB 项等待。对大任务发出取消后仍等待，确认取消后即可进入。 |
| 杀进程、重试、幂等 | 持有本地作业的进程实际收到 SIGKILL。重开认领后 attempt 从 1 变 2，拒绝旧 token，保留新结果。临时遗漏 worker 输出文件触发操作系统 ENOENT。补回仓库的 177,539 字节 JPEG、等待退避后重新暂存。在登记处故意中止 SQL，观察到无目录引用的完整内容对象。重试后删除 worker 临时文件，再重放 ACK，最终仅 1 个资源引用，SHA-256 与样片相同。永久、未知、离线、心跳、重试上限均有断言。[样片](../../Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg) |
| 单个空作业控制开销 | 同一常驻命令行进程，测提交、认领、完成 3 个往返，预热 10 轮后实测 100 轮。macOS P50/P95 为 1.400/3.000 ms，Linux 为 8.390/13.738 ms。该值计量 NDJSON 管道、序列化和持久事务。像素计算与成片写入另行测量。文件系统与 SQLite 版本不同，单机容量须在部署介质上重测。 |
| 资料库首屏附作业状态 | 对 033 的真实 v8 目录做 Online Backup，6,928 条资产、1,408 个纳入范围的逻辑文件。每次经生产 Rust 分页 API 读相同 60 张，附 20 条完成和 40 条待执行状态。按轮交换三种测法顺序，各预热 3 次、实测 30 次，每次均比对 ID 顺序与全部状态。单独分页 P50/P95 为 4.594/5.768 ms。分页加逐条读取为 5.458/6.320 ms。分页加一次批量读取为 4.863/5.915 ms。这一差值只适用于本次的常驻测试进程、热索引和稳定任务状态。批量读取在一个 SQL 语句中保留顺序、重复项和缺失位置。[每次耗时与快照摘要](evidence/catalog-paging.json) |
| Swift 与生产资料库接线 | Swift 使用现有 C 装载器在私有 v7 夹具事务中安装 v8，生产 overview 与 page 读到同一张样片，经实验 C ABI 提交冻结 ID/摘要、认领、发布，再从状态接口读回同一 SHA-256。两项操作分别使用生产目录和独立 PoC 库。[Swift 调用代码](../../experiments/portable-processing/catalog/CatalogSmoke.swift) · [实际返回值](evidence/catalog-swift.json) |

## 实施与验收

1. **先建兼容层。** 在目录注册新 schema、另建尝试与发布收据表。现有 `processing_jobs`、`editing_exports`、`lc_proc_jobs` 和检索任务先映射到同一份只读视图。保留 command ID、远端 ID、尝试次数、候选版本与输出。有提交意图但无收据的记录进入核对。用备份副本演练升级、重开和中断，核对旧作业数、终态和发布引用。初始灰度沿用旧 worker，单项切换前停止旧认领器。回退某类作业先停发、排空或收回租约并核对输出，再切回已有执行路径。
2. **先接资料库索引与本地全质量任务，再接导出及远端 AI。** 对相同照片更改配方、重排组成员、撤销采用、移走原片、模型升级时，逐一检查旧作业归属、结果可见范围及当前版本。命名冲突、磁盘满、重启、重复回调、半写输出均验证至物理文件及目录引用。单一动作只允许一个发布者。为暂存未登记对象建立有宽限期的回收流程。
3. **在混合负载下批准资源策略。** 用固定的实际库与 RAW 集合，同时导入、拖动编辑控件、运行一个 AI 蒙版、执行 032 的 200 张导出。记录输入至呈现 P50/P95、各类队列等待及最长独占、首件与整批、峰值 RAM/显存、取消至停止时长、成片哈希与输出数。建议热索引首卡/首图 P95 ≤ 同机当前版本 1.10 倍，导出和索引在持续编辑时均持续完成，重复恢复只产生一个有效收据。用真实 60 MP 表面测定设备额度、阶段粒度和预览等待上限。[现有原生资料库基准](../033-library-lifecycle/evidence/library-delivery.json) · [现有导出基准](../032-export-workspace/performance.md)

实验范围是一份队列、一个逻辑设备、受管对象和本地进程。多设备选址、物理 GPU 抢占、当场撤销已提交 GPU 计算、多租户服务、远端计费对账、跨库资源竞争和迁移后的真实窗口压测属于上述实施验收。所有写入均发生在私有实验数据库和暂存目录。

## 复现

在仓库根目录执行下列命令。macOS 需要 Rust、Xcode 工具和 Python 3。Linux 验证使用本机 Cargo 与 Docker，固定 Rust 和 Python 镜像摘要。测试资料库和样片副本会自动清理，完整结果保存到 `output/035-catalog-target/` 和 `output/035-catalog-linux/`。[运行脚本](../../experiments/portable-processing/catalog/verify.sh) · [跨进程断言](../../experiments/portable-processing/catalog/verify.py)

```sh
sh experiments/portable-processing/catalog/verify.sh macos
sh experiments/portable-processing/catalog/verify.sh linux
```

真实分页复测使用 033 的本地快照。也可传入一份可读的 v8 目录，其首页需含 60 个不同的文件。脚本通过只读连接做在线备份，在副本创建分页索引，报告仅写计数、摘要和耗时。[分页对照程序](../../experiments/portable-processing/catalog/compare_page.py)

```sh
python3 experiments/portable-processing/catalog/compare_page.py \
  output/library-033-delivery/plan-v8.sqlite \
  output/035-catalog-target/production-library.dylib \
  output/035-catalog-target/release/rmq-probe
```

## 工作台 SQLite 主文件身份

目录授权先核对象身份。工作台随后通过路径建立 SQLite 连接，两个操作之间允许路径换项。macOS 试验在已建立的读事务和排他写事务内，从同一次 SQLite 连接借用主文件映射，再由内核查询映射的设备号、inode 与纳秒级出生时间。每个借用都在当前事务内释放，并恢复连接原有 mmap 限额。[可复现的主文件试验](../../experiments/portable-processing/catalog/main-file-probe/README.md)

系统 SQLite 3.54.0 的同卷 APFS 验证通过 12 项。打开前换入完全相同的目录副本时，`SQLITE_FCNTL_HAS_MOVED` 返回 0，映射身份仍识别出替换对象。打开后换目录及换回原路径也分别得到预期身份。两边目录的字节、写入者与冻结标记保持一致。生产接线还需将证明传入持有事务的那条连接，并验证跨卷同 inode、WAL 与 SHM、发布前路径变化及同进程描述符与锁的寿命。[原生回执](evidence/catalog-main-file-proof.json)

在同机的 SQLite 3.54.0 上，分别用读事务和 `BEGIN IMMEDIATE` 打开空 WAL 与含未检查点提交的 WAL。四项测试均能从 `SQLITE_FCNTL_JOURNAL_POINTER` 取得当前日志的 SQLite 对象。接着向连接、主文件对象和日志对象调用 `SQLITE_FCNTL_FILESTAT`，12 次均返回 `SQLITE_NOTFOUND`，没有生成诊断数据。事务类型和读到的标记均保持一致，命令连接没有写业务数据。这确认当前系统构建的诊断接口无法提供附件描述符。[本机回执](evidence/catalog-attachment-capability.json) · [可复现程序](../../experiments/portable-processing/catalog/attachment-probe/README.md) · [SQLite 文件控制契约](https://sqlite.org/c3ref/c_fcntl_begin_atomic_write.html)

## 活跃事务的 WAL 与 SHM

隔离进程通过代理 VFS 转发 SQLite 的自然调用。主文件和 WAL 的描述符来自实际 `xOpen`，再以同一事务的 `FILE_POINTER`、`JOURNAL_POINTER`、描述符新增记录与独立进程的内核 vnode 查询交叉核验。SHM 只记录 SQLite 自己成功取得的第 0 页映射，以及成功的读写锁操作。活事务中核对映射范围、文件偏移和 vnode；解除映射或关闭时结束证明。实际对象的设备、inode 和纳秒出生时间均与事先持有的授权文件及当前名称比较。[复现与文件寿命](../../experiments/portable-processing/catalog/attachment-probe/passive-vfs/README.md) · [SQLite VFS I/O 方法](https://sqlite.org/c3ref/io_methods.html)

用归档源码在同卷 APFS 上复跑 14 项，夹具和 SQLite 连接均链接系统 3.54.0。28 次活事务观测都证明了实际主文件，26 次有实际 WAL，24 次有实际 SHM。11 次通过全部附件检查，17 次按预期拒绝。其中包括同字节 WAL 或 SHM 替换、打开后换名、恢复原名，以及独占模式使用内存索引时旁边仍存在完整 SHM 的情形。观察期间核对替换两侧文件的大小和摘要，结束前恢复 SQLite 打开时的文件组合，再用独立连接核对写入者、标记和完整性。后续生产接线仍需证明授权前的来源、最终发布时点、跨卷和其他 VFS 的行为。[14 项隔离复验](evidence/catalog-passive-attachment-proof.json)

### 真实队列的发布边界

工作台先核对书签，再由 Rust 按路径打开队列。一次条目操作先使用读事务取得快照，在锁外核对摘要和暂存文件，随后用 `BEGIN IMMEDIATE` 复核。附件证明需要来自这条写事务的连接。发布前的现有闭包分别在 `linkat` 和备用的独占 `rename` 前复核父子租约，也是验证主库、WAL 和活跃 SHM 的位置。两次尝试都用同一份授权和同一条活事务。连接刚打开时的检查与 SQLite 提交钩子分别处于这一边界的两端。[工作台授权](../../Sources/RAWMaster/WorkbenchDeliveryAccess.swift) · [条目事务](../../Modules/LibraryCatalog/src/scheduler/batch/items.rs) · [原子发布调用](../../Modules/LibraryCatalog/src/scheduler/batch/directory.rs)

在文件发布前发现身份不明时，保留 `Prepared` 票据。文件已经落地而提交确认中断时，复用 ACK 对成片和原票据的核对，再让记账所用的写事务验证自身附件。验证复用真实 v10 的批次注册、领取、准备、发布和确认，检查判断失败后原件、暂存文件、目标名和票据的状态，也验证父子租约过期、队列代次变化和发布后恢复。[交付事务测试](../../Modules/LibraryCatalog/tests/scheduled_processing/workbench_item_delivery.rs)

### 发布包队列的实际附件复验

独立进程直接加载发布包的 Rust C ABI，安装并升级夹具至 v10。用同一接口实际登记、领取、准备、发布和确认。九组用例共调用生产 ABI 99 次，观察到实际队列查询中的 99 个读事务和 66 个写事务。活跃 SHM 来自 SQLite 自己的第 0 页映射与加锁。非空 WAL 取得 96 次实际日志映射，均按原偏移和指针归还，54 次临时限额均恢复。探针使用公开 VFS 转发和连接回调。[复现与隔离约束](../../experiments/portable-processing/catalog/queue-transaction-probe/README.md) · [回执](evidence/catalog-queue-transaction-identity.json)

空 WAL 实际返回空映射，旁路的 0 字节文件会产生第二个 FD 候选。用当前原生 I/O 方法另测物理 1 字节的文件也报告 0。WAL 和 SHM 的同字节副本在原名恢复后仍留在活连接的打开集合。六次不确定或身份不符的诊断都在真正的写事务内中止，独立连接核对原 `Prepared` 票据和占位，目标文件当时尚未建立。同一票据随后成功续接并确认，九份 JPEG 的 SHA 和字节数一致。[零字节、换名及恢复回执](evidence/catalog-queue-transaction-identity.json) · [Unix VFS 参考实现](https://raw.githubusercontent.com/sqlite/sqlite/master/src/os_unix.c)

实际发布时未观察到 WAL 写入，依赖 SQLite 提交钩子无法覆盖文件副作用。诊断的中止点是 Rust 查询身份后继续执行 SQLite 的时点。生产接线仍需让同一条持有事务的执行者证明附件身份，并在现有排他链接和排他重命名调用前分别核对。当前 Apple VFS 对空 WAL 无法给出映射证明，专用执行者还需可靠取得实际打开描述符。[真实发布闭包](../../Modules/LibraryCatalog/src/scheduler/batch/directory.rs)

### Linux 读取资料库身份时保留 SQLite 锁

Linux 服务端随库编译 SQLite 3.53.2。旧版 `workbenchCatalogFile` 为读取设备号和 inode 而打开、关闭普通文件描述符。同进程已有 SQLite 事务时，内核随之释放该进程加在同一主文件上的 POSIX 记录锁，SQLite 仍报告原来的锁级别。修复后用 Linux 的 `O_PATH | O_NOFOLLOW` 固定对象，只在元数据描述符上读取 inode 和检验有效用户的读取权限。调用继续拒绝最后一级符号链接、非普通文件及相对路径。对于缺少空路径权限查询的旧内核，兼容路径经由已持有描述符的 procfs 链接。macOS 沿用原有 APFS 文件身份查询。发布时的主库、WAL、SHM 仍需在执行发布的事务内分别证明。[实现](../../Modules/LibraryCatalog/src/scheduler/batch/directory.rs) · [SQLite 的 POSIX 锁说明](https://sqlite.org/howtocorrupt.html#posix_advisory_locks_canceled_by_a_separate_thread_doing_close_) · [Linux 元数据描述符](https://man7.org/linux/man-pages/man2/open.2.html)

| 私有 v10 夹具上的观测 | 修复前的 Linux 库 | 修复后的 Linux 库 |
| --- | --- | --- |
| 同一进程、同一 inode 的真实 C ABI 查询 | WAL 和 DELETE 两种日志下，读事务及 `BEGIN IMMEDIATE` 的主文件 SHARED 锁均被释放。DELETE 写事务的 RESERVED 锁也被释放 | 四种事务的 SHARED 锁全部保留，DELETE 写事务的 RESERVED 锁也保留 |
| 同字节的另一 inode、另一进程读取同一 inode、只查元数据 | 原有锁均保留 | 原有锁均保留 |
| 同一进程另开普通数据描述符再关闭 | 主文件锁被释放 | 主文件锁被释放 |

固定 Debian arm64 镜像在容器原生文件系统运行。每版分别用发布形式的共享库和同次编译的 Rust 库调用 C ABI，各执行 20 项。两版合计 80 项，观测进程用 `F_GETLK` 和 `F_OFD_GETLK` 读取真实内核锁。每项都复核了 SHM、事务状态、主文件字节、写入者和完整性。另用具名进程锁和打开文件描述锁分别校准，前后共 8 项。macOS 系统 SQLite 3.54.0 独立执行了 20 项，原实现保留这台机器上观察到的原生锁。该结论适用于对应的 SQLite 构建、VFS 和文件系统。[双端锁矩阵、校准与原始回执摘要](evidence/catalog-file-identity-locks.json)

| Linux 验收对象 | SHA-256 |
| --- | --- |
| 修复前 `librawmaster_library.so` | `d49d44c55f09a74167d2f9b53445a82b3123253e536e2affe75eb0a332acf7ce` |
| 修复后 `librawmaster_library.so` | `be8b59311a2096c439c34440e46e81f77a1f6152c839fce1e57c8c9610bd387e` |
| 修复前 40 项回执 | `e341aa957bda9c7605e9dd3d37ff60b408f973da81cb2b22a385f5cad5fbd102` |
| 修复后 40 项回执 | `3db01b97792326bf197114167e67df6a2c2e62204e4e12f981c767aec2fbb347` |

Linux 下在仓库根目录运行以下命令，可独立复验真实读锁和保留锁、只读及替换文件、同字节不同 inode、访问时间和符号链接。以普通用户运行时还会验证无读取权限的情形。锁定依赖的全库测试在 Linux 通过 91 项，在 macOS 通过 90 项。两端各有 5 项沿用原来的外部输入条件。以 UID 65534 重跑 Linux 的两个专项用例，均通过。[回归代码](../../Modules/LibraryCatalog/tests/catalog_file_identity.rs) · [双端测试日志与非特权复验摘要](evidence/catalog-file-identity-locks.json)

```sh
cargo test --locked --offline --manifest-path Modules/LibraryCatalog/Cargo.toml --test catalog_file_identity
```

### Linux 工作台发布事务的附件核对

使用原有工作台 C ABI，在复制的 Rust 队列源码中接入检查。实验库为锁定的 SQLite 3.53.2 启用上游 `SQLITE_ENABLE_FILESTAT`。在 `Context::load` 已经取得读事务或写事务后，同一条连接报告其 Pager 实际使用的主文件、WAL 和 SHM 描述符。子进程借用描述符取得设备号与 inode，分别比对父进程事先持有的三个文件和授权目录中的当前条目。SHM 还要具有本连接的读锁位、写事务的写锁位，以及对应该 inode 的共享映射。真实的零字节 WAL 也可凭其描述符核对。[实验源码与复现](../../experiments/portable-processing/catalog/transaction-filestat-probe/README.md) · [上游 FILESTAT 契约](https://www.sqlite.org/c3ref/c_fcntl_begin_atomic_write.html)

十项实验各在初次和归档复跑中通过。每轮实际调用 C ABI 67 次，在读事务中检查 57 次，在写事务中检查 104 次，其中 48 次实际 WAL 长度为零。工作台在原有硬链接与独占重命名调用前分别检查了 13 次和 3 次。对同字节的错误引用、打开整套副本、第二次发布检查和 ACK 等七个场景，拒绝后再由独立连接核对票据与文件。失败发生在准备阶段时尚无票据，发生在发布前时原票据和暂存文件保留，发生在 ACK 时最终文件保留。按原任务重试并重复确认后，十份 JPEG 均为 47,835 字节且摘要一致。[十案结果、构建摘要与原始回执](evidence/catalog-transaction-filestat.json)

正式接入需要为每次授权建立附件的来源。已存在的文件可在首次打开受控连接前固定。首次尚无 WAL 或 SHM，以及 SQLite 合法重建附件时，需要从已授权的主文件、目录和写入者建立新的见证，再执行有文件副作用的操作。诊断 JSON 的字段随 SQLite 构建而定，每次扫描 Linux 映射表也会延长写锁持有时间。生产候选须固定后端版本、限制单次检查的工作量，并在最后一道检查失败时保留原票据。macOS 的系统 SQLite 缺少这项诊断，独立执行进程随后已在本机 APFS 测通与系统 SQLite 同时读写的锁协议，安全书签传递、卷重挂和异常恢复仍待验证。现有 SwiftUI 工作流继续使用已经验收的运行库。[macOS 接口能力回执](evidence/catalog-attachment-capability.json) · [Linux 实验边界](evidence/catalog-transaction-filestat.json)

### 限制发布写锁中的映射检查

Linux 候选使用具名 VFS 记录这条连接自然取得的 SHM 第 0 页映射。每轮读取主库、WAL、SHM 的实际描述符，核对本连接的锁位及已持有的授权。在支持 `PROCMAP_QUERY` 的内核上，直接以 SQLite 返回的地址查询对应共享映射的设备、inode、范围、权限和偏移。兼容路径在读事务中完成一次全表检查，随后要求打开代次、映射代次、原指针及文件身份均连续。SQLite 解除映射或关闭该连接时，旧见证失效。两条候选路径在写锁内读取的映射文本均为零字节。[实现与复跑](../../experiments/portable-processing/catalog/transaction-filestat-probe/mapping/README.md) · [Linux 接口说明](https://docs.kernel.org/filesystems/proc.html)

同一优化构建处理相同真实 JPEG，容器 CPU 配额为 1，按交替顺序每组实测六次。下表是 `publishItem` 从取得写锁到提交返回的 P50 / P95，单位为微秒。压力夹具增加匿名虚拟映射但不提交对应图像内存。每次发布都核对原暂存 inode、JPEG 摘要和重复 ACK。[原始测量摘要](evidence/catalog-transaction-mapping.json)

| 进程映射数 | 每道边界扫描 | 按原地址查询 | 读阶段扫描、写阶段复核代次 |
| --- | --- | --- | --- |
| 60 | 187.2 / 233.8 | 152.0 / 183.6 | 155.2 / 168.5 |
| 4,157 | 1,287.8 / 1,578.8 | 157.1 / 178.8 | 150.8 / 190.8 |

在 4,157 个映射下，重复 ACK 的写锁 P50 从 1,230.3 降至 107.7 或 120.9 微秒。桌面和服务端的整批吞吐还要分别测量。普通环境首次持久化 ACK 的 P50 在逐次扫描组为 3.666 毫秒，按地址组为 4.808 毫秒。兼容分支把压力环境下约 842 微秒的映射扫描移到了读阶段。每组仅有六个值，本表 P95 对应其中最大值。[逐动作结果](evidence/catalog-transaction-mapping.json)

两条候选路径分别通过原有十案，包括 48 次实际零字节 WAL 核对。另经三次真实附件换代，SQLite 自行删除并重建 WAL 与 SHM，原主文件及已准备票据不变。带旧授权的调用在实际读事务中停止，原暂存文件完整，目标名空缺。夹具明确接受新附件后，使用原票据完成发布和两次确认。归档复跑把两个 ACK 放在同一进程，依次打开两条队列连接，三项夹具均观察到原文件身份连续、打开代次和映射代次更新。归档构建的第二次六轮对照中，压力组发布写锁 P50 分别为 1,144.1、143.4 和 142.4 微秒。生产接入仍需证明真实服务端的首次授权及重新授权来源，并完成 macOS 书签、沙箱内的 VFS 互操作和吞吐验收。实验中的兼容分支运行于当前内核，缺失 ioctl 的场景使用受控错误模拟。[换代与拒绝回执](evidence/catalog-transaction-mapping.json)

### Linux 受控目录中首次建立 WAL 和 SHM 授权

生产 v10 夹具关闭最后一条 SQLite 连接，确认 WAL、SHM 均已消失。原创建者在关闭前把目录、主库描述符以及资料库标识交给独立主管。专用 worker 的真实 SQLite 打开请求触发主管排他创建相应附件，并将创建所得描述符交给 SQLite。keeper 取得写事务后送回实际使用的三个描述符。主管逐个核对是否为当初交出的打开文件描述，并从内核独立读取该 keeper PID 的主库读锁及 SHM 读写锁。随后核对当前目录条目、资料库标识、写入者和活动的 32,768 字节共享映射，再准许工作台处理任务。[实验接口及复跑步骤](../../experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap/README.md) · [Linux 打开文件描述核对](https://github.com/torvalds/linux/blob/v6.11/fs/fcntl.c#L311-L324)

归档夹具通过 15 案。14 案实际完成无覆盖发布和两次 ACK，交付的 JPEG 均为 47,835 字节且摘要相同。它们记录的 18 次成功激活中，真实 WAL 均为零字节，主管均确认了同一打开文件描述与三个进程锁位。夹具还覆盖单附件创建后断线、预存空文件、活映射与当前条目不符、最后关闭时出现外来条目，以及 IPC 已断但 keeper 仍活。最后一种情况下，在该具体进程退出前，主管无法删除旧附件或建立新代次。第 15 案让主管实际退出，新主管仅持有从原进程取得的目录和主库，拒绝接管遗留附件。独立 checkpoint 副本确认原票据仍为已准备、占位一条，目标路径仍空，暂存原图摘要完整。[构建摘要及逐案回执](evidence/catalog-attachment-bootstrap.json)

这一候选使用单个受信服务管理的本地私有目录。主管独自管理文件名并持有见证，合法换代需 checkpoint 完成及旧代子进程全部退出。写入者不匹配时，主管可能已经为受权主库创建新附件，工作台文件发布仍须等待身份核对成功。主管自身重启、热 WAL 中尚未 checkpoint 的数据、可由外部程序任意改名的目录、断电及远程卷需要另行设计恢复。这组 Linux 夹具只测正确性。下文的 macOS 实验补上了本机锁互操作及受控目录的附件初建，书签传递和真实卷恢复仍待验证。[适用范围](../../experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap/README.md)

### Linux 已提交 WAL 的主管异常恢复

主管和 SQLite keeper 同时异常退出时，资料库的已提交票据可能只存在 WAL 中。新实验在资料库备份之外，以独立服务密钥认证目录、主库及附件的内核对象标识。每个 worker 领取打开权限之前，主管先持久记录内核凭证对应的 PID 和启动时刻。新主管取得独占锁后，还须通过 pidfd 确认旧 worker 全部退出。当前容器的 overlayfs 可从已持有的描述符取得 44 字节的文件系统标识；同字节复制和换目录都能识别。[主管与复跑步骤](../../experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap/recovery/README.md) · [Linux 对象标识](https://man7.org/linux/man-pages/man2/open_by_handle_at.2.html)

为防止原 inode 仍在、内容却已回退，服务在对外确认 PREPARED 或 DELIVERED 前持久记录已提交 WAL 前缀的 SHA-256、salt、帧号和逐项票据摘要。恢复时先验证完整前缀，再由 SQLite 在真实写事务中核对所有承诺、实际读写锁及活动 SHM。单项样例的主库副本独立读取为零项，原 WAL 为 28,872 字节、最终提交在第 7 帧。SIGKILL 主管后，新 keeper 从 WAL 恢复原票据，内核确认 SHM 的读锁位于 byte 124、写锁位于 byte 120。两份索引头均匹配 WAL 的实际 salt 与最终滚动校验。[逐案回执与摘要](evidence/catalog-wal-recovery.json) · [SQLite WAL 格式](https://sqlite.org/fileformat.html#walformat)

归档复验通过 13 案。11 个场景交付 12 张 JPEG，均为 47,835 字节且摘要一致。覆盖发布后尚未 ACK、ACK 已提交但回复丢失、两张已确认票据、原 SHM 缺失或索引头损坏，以及旧 keeper 仍存活。一次独立 C ABI 注册在原 WAL 尾部遭遇内核短写，留下 801 字节的残帧；前序确认仍能恢复。另两案有意破坏已承诺帧或其中一张已承诺票据，服务拒绝激活并保留暂存图和空目标路径。本轮范围为同一次 Linux 启动、同一挂载、单主管私有目录、串行工作台确认及单个 checkpoint 代次。生产服务还需验证 checkpoint 换代、并发写入、整个服务记录回滚和真实吞吐。[错误边界及重放](../../experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap/recovery/README.md)


### macOS 系统与独立 SQLite 共同读写工作台

在 Apple M4 Max 的本机 APFS 上，系统进程用发布包将夹具迁至 v10，另一个进程用锁定的 SQLite 3.53.2 和复制的 Rust 队列代码执行真实 C ABI。两端按镜像地址核对自己的 SQLite。两个写入者轮流持有写事务，另一端均收到 `SQLITE_BUSY`，释放后均可重试。两端的读者跨越对方提交时分别保留旧值 0 和 1，结束快照后分别读到 1 和 2。第三个进程确认对原描述符作身份核对前后，主库读锁、SHM 写锁和读槽仍归原持有者。[复现步骤与源码](../../experiments/portable-processing/catalog/macos-interop-probe/README.md) · [版本、符号归属与锁回执](evidence/catalog-macos-interop.json)

系统 SQLite 3.54.0 缺少本实验使用的 FILESTAT SQL 接口。独立引擎从实际活跃连接借用主库、WAL 和 SHM 描述符，以 APFS 卷 UUID、设备号、inode 和纳秒出生时刻分别比对原授权和目录当前条目，再用 SQLite 自然取得的 SHM 映射地址核对内核 vnode。在同一写事务中，只有 SQLite 自己映射时，内核报告共享模式 2，同一身份检查返回拒绝。父进程只读映射同字节副本时仍为 2。映射预持的原件后变为 4，撤去后回到 2。真正的系统 SQLite 读者映射原件时也为 4。受控测试据此区分了单映射时的证据缺口与确实共享原附件的情形。[五态观测及适用系统](evidence/catalog-macos-interop.json)

归档复跑的九个交付场景共 61 次 C ABI 请求、148 次事务内核对，其中 73 次实际 WAL 长度为零。七次预期拒绝分别覆盖读阶段拿错空 WAL、准备、硬链接或独占重命名前的最后检查，以及文件已发布后的 ACK。六次活动换名期间，独立观察者仍在原 SHM 上看见队列进程的写锁，三个主库或 SHM 副本相应字节均无锁。还原原名后，九份原票据均以原暂存 inode 交付同一份 47,835 字节 JPEG，两次确认一致，占位清零，系统 SQLite 完整性及外键检查通过。该实验覆盖预先固定附件的私有目录。后续实验补测了专用主管在私有目录中的首次创建和换代。正式接入还有沙箱子进程与安全书签、外部可写目录的改名窗口、卷重挂、进程异常恢复及吞吐验收。[逐案结果与原始回执摘要](evidence/catalog-macos-interop.json)


### macOS 私有目录内首次创建和换代授权

Apple 系统 SQLite 3.54.0 在四种正常最后关闭对照中都保留了零字节 WAL 和 32,768 字节 SHM。即使 TRUNCATE 已清空日志，文件名仍存在。要从真正缺失开始，原创建者在同一个本机测试库上完成 v10 迁移和 TRUNCATE，将自己的 `SQLITE_FCNTL_PERSIST_WAL` 从 1 设为 0 并复核，再正常关闭。主管随后观察到两个文件名都不存在。已安装库中遗留的未知附件需要另行辨认。[原生对照与复现](../../experiments/portable-processing/catalog/macos-interop-probe/bootstrap/README.md)

主管持有私有目录和原主库。独立 keeper 首次真正打开 WAL、SHM 时，主管在原目录排他创建，再通过 `SCM_RIGHTS` 交出描述符。keeper 在真实写事务中送回 SQLite 实际使用的三个描述符。主管通过双向文件偏移核对同一个打开文件描述，用另外打开的同 inode 文件校准，再还原全部偏移。18 次激活、54 组校准全部通过，实际 WAL 长度均为零，活动 SHM 均为 32,768 字节。归还接收的描述符副本后，独立观察进程仍能在原 keeper 上查到主库读锁和 SHM 的读写锁。九个场景中的 Apple 写入者均先收到 BUSY，原 keeper 释放后均可重试。[授权协议及内核观测](evidence/catalog-macos-bootstrap.json)

退休旧代前，主管核对原票据、所有登记读者的退出及完整 checkpoint 结果。有旧快照时，SQLite 返回 BUSY，7 帧中仅写回 4 帧。另一场景已无日志帧，TRUNCATE 返回成功，主管仍因真实 Apple 读者存活而延后退休。每次合法换代中，在两个附件均已移除且尚未重建的间隙，独立进程直接从主库读出了原票据。新代建立后，仍持有旧 inode 的授权在九次真实工作台请求中均遭拒绝。最终九张 JPEG 全部保留原暂存 inode 和摘要，两次 ACK 一致，SQLite 完整性和外键核对通过。实验范围是单个存活主管独占的本机 APFS 目录。断电、退休中途失败、热 WAL、掉卷和沙箱书签仍需独立验证。[逐案结果与原始回执摘要](evidence/catalog-macos-bootstrap.json)


### macOS 受限签名助手的授权与交付

现有 SwiftUI 工作台在宿主进程中持有目录授权。重开时先匹配资料库身份，再核对书签是否过期。标记为安全作用域的书签还须成功重新进入该作用域。实际检查的应用与组渲染工具均为 ad-hoc 签名，未声明 App Sandbox 权益，应用包中无 XPC 服务。本轮在独立、启用 Hardened Runtime 的签名助手内运行真实 Rust 工作台 C ABI，用本机 Seatbelt 对读取、写入和改名实施内核限制。[现有宿主](../../Sources/RAWMaster/WorkbenchDeliveryAccess.swift) · [签名清单与复现](../../experiments/portable-processing/catalog/macos-interop-probe/sandbox/README.md)

主管先核对磁盘程序的 identifier、CDHash，再根据已连接 Unix socket 的内核 audit token 核对运行程序、登记 PID 和有效 UID，随后才发送目录、主库、WAL、SHM 四个只读描述符和队列命令。相同 identifier 的另一份有效签名程序未通过动态签名要求。受限助手对同目录未授权文件的读取、读写打开、创建和改名都收到 EPERM，另一个目录的文件同样不可读。相同 UID、相同签名程序在未加 Seatbelt 的独立对照中五项均成功。实际 APFS 目录描述符还需要挂载根本身的元数据权限才能查询卷 UUID。缺少该权限时，逐项领取返回 EPERM 的诊断，任务行数保持零。[签名、五项权限对照及原生错误](evidence/catalog-macos-signed-helper.json)

归档的五个场景共有 33 个签名进程，其中 32 个受 Seatbelt 限制。26 次真实 Rust C ABI 命令包含 60 次活事务核对，28 次实际 WAL 为零字节。目标只读时，原 `linkat` 和 `renameatx_np(RENAME_EXCL)` 都返回 EPERM。原票据、暂存 inode 和文件名占位保留。另一次测试在助手签名核验后、收到任何描述符前实际退休上一代附件，主管按当前代次拒绝发放。新代激活后，引用旧代的请求仍拿不到描述符。四份最终 JPEG 均用原票据和原暂存 inode 交付，摘要相同，两次 ACK 一致。这个实验只验证本机私有目录、ad-hoc 签名和明确的 Seatbelt 策略。生产用 App Sandbox、Powerbox 与跨进程书签、XPC、正式签名升级和外置卷仍需单独验收。[逐案记录](evidence/catalog-macos-signed-helper.json) · [Apple 的文件授权契约](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)


### 受签名约束的 macOS XPC 服务与临时文件权限

本机的独立后台应用通过系统 XPC 启动内嵌服务，服务实际启用了 App Sandbox。两端在激活连接前分别要求对端满足指定标识和 CDHash。宿主在收到认证回复后才传入只读描述符和当前请求所需的目录书签。同 UID、同标识的另一签名在握手时被拒，正确客户端指定错误服务签名也被拒。服务的唯一临时文件例外用于读取测试签名策略，未包含资料库、照片和交付目录。[原生夹具与复跑步骤](../../experiments/portable-processing/catalog/macos-interop-probe/xpc/README.md) · [逐项证据](evidence/catalog-macos-xpc.json)

照片只获发 O_RDONLY 描述符时，沙盒服务可读取原 JPEG，重新按名称读写同一照片或旁件均得到 EPERM。已进入的 Foundation 默认临时书签在本机同时允许读打开和写打开，停止访问后两者再次被拒。供服务仅读的 RAW 原件因此适合交付原 FD。资料库和输出目录需要能写入不同位置，分别发放并核对。在本机，接收端第一次解析刚签发的临时书签提示 stale。夹具只在当前已认证请求附带原 FD 时短时进入权限，核对原父目录、同名 inode、出生纳秒和 APFS 卷 UUID，再新建临时书签。第二次解析须 fresh，两次权限交接前后都须匹配同一原件。宿主保存的持久书签继续执行原来的过期判定。[文件权限与票据实验](evidence/catalog-macos-xpc.json) · [现有工作台宿主](../../Sources/RAWMaster/WorkbenchDeliveryAccess.swift) · [Apple 文件授权说明](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

真实 v10 逐件流程在独立沙盒进程内完成注册、领取、准备、排他发布及两次相同确认。缺少目标权限时，原 PREPARED 票据、暂存 inode 和一个占位均保留。补入正确权限后发布原 47,835 字节 JPEG，确认后占位为零。系统 SQLite 的完整性和外键检查通过。夹具用应用包内的独立 SQLite 3.53.2 核对 14 次事务内 main/WAL/SHM、锁及自然映射，六次读到真实零字节 WAL。当前正式应用使用宿主内调用。产品接入还需由沙盒宿主从实际用户选取获得持久权限、团队签名升级策略、外置卷与异常重启资格，并复测正常工作台吞吐。[实验边界和环境](evidence/catalog-macos-xpc.json)

### 工作台登记与逐项文件同步

032 工作台提交中性批次时，Swift 在导出队列的 CPU 和 I/O 配额内将完整登记命令编码一次，用这份数据检查内联清单大小并调用 Rust。1 MiB 限额仅计清单。接近上限时按同一编码方式计算外围字段所占字节；超过上限使用既有的 v2 资源对象。Rust 独立检查规范化后的字节数、配方和来源，再登记批次并签发租约。[Swift 登记](../../Sources/RAWMaster/WorkbenchDeliveryCatalog.swift) · [请求编码](../../Modules/LibraryCatalog/Swift/LibraryEngine.swift) · [边界与浮点回归](../../Modules/LibraryCatalog/tests/scheduled_processing/workbench_inline_delivery.rs)

用完整 200 张 JPEG 的原生输出作为各自独立的暂存文件，直接调用已发布的 v10 资料库 C ABI，整批登记耗时 13.98 ms。逐项领取、准备、发布、确认的中位数依次为 3.67、9.74、12.12、17.75 ms。每条命令都重新打开真实队列，确认时重读最终文件，检查身份与 SHA-256。这组串行数据用于定位协议开销；正常工作台允许多张照片同时处理。[逐阶段样本与 P95](evidence/workbench-catalog-handoff.json)

Apple M4 Max 内置 APFS 上，原生 XCTest 通过 `AppModel.openProjectExport()` 打开项目导出，并经 `exportWorkbenchPhotos()` 提交。时间从提交起算，以首个成品进度回调与整批返回为两个终点。每个进程先预热，再测一次，每个方案有两个计时样本。表中为两次的中位数。A 是之前的完整包，B 保留单次编码。A 与 B 的资料库及 PhotoExport 二进制相同，图像库和 Swift 测试程序有版本差异。第二轮保持 B 的 Swift、图像库和导出库完全一致，仅将资料库换成 C。C 在该次请求已经同步过的 APFS 暂存目录上，成功创建硬链接后，若原目录的链接数、纳秒修改和状态时间仍一致，省一次源目录同步。排他重命名仍同步两目录。[各轮包指纹、耗时与 SHA](evidence/workbench-catalog-handoff.json)

| 原生比较顺序 | 方案 | 20 张 JPEG 整批 / 首件（秒） | 200 张 JPEG 整批 / 首件（秒） |
| --- | --- | --- | --- |
| A、B、B、A | A 先前发布包 | 0.942 / 0.145 | 8.278 / 0.169 |
| 同组 | B 单次编码 | 0.776 / 0.152 | 7.946 / 0.182 |
| C、B、B、C | B 两目录同步 | 0.794 / 0.148 | 6.853 / 0.168 |
| 同组 | C 有条件省一次源目录同步 | 0.829 / 0.144 | 6.927 / 0.161 |

**最终封存采用 B 的完整目录同步。** `candidate-batch30-native-mask-ring-final` 的四个原生测试包均带有与 B 逐字节相同的资料库运行库（SHA-256 以 `1a78c936c3e6` 开头）。 C 的 200 张整批耗时增加 1.07%，20 张增加 4.35%。单次编码去除了对同一清单的第二次遍历，第一轮的首件时间未见改善。两轮各核验了 1,936 个预热和计时成品，五组的文件名与字节清单一致。另用 B 和 C 分别对 200 个真实 JPEG 重新运行逐项 C ABI，核对持久票据从准备、发布至确认始终保持同一份，最终文件保留暂存 inode，SHA-256 与大小逐个匹配。两个库均通过首末项重复确认、整批完成和 SQLite 完整性检查。200 个文件的名称与 SHA-256 清单和八个原生进程完全相同。主干 4.795 秒整批、0.082 秒首件的历史值仍优于本轮结果。[逐项复现及未采纳的差分](../../experiments/portable-processing/catalog/workbench-delivery-probe/README.md) · [独立票据、原始成片清单与采样边界](evidence/workbench-catalog-handoff.json)

首件还有一处可单独验证的开销。对 200 个已入库原片，在同一个 SQLite 读事务内，现行 Swift 入口执行了 400 次资产读取与 400 次入选凭据读取。独立小程序在同一次调用内复用刚读出的资产与凭据，两类读取各降到 200 次。两条路径生成的完整来源快照数组 SHA-256 相同。B30 结束时，这项实验尚待接入工作台。下节记录损坏行中主键与资产 ID 不一致、入选撤销再加入、无读事务等场景的接入复验。[实际 SQL 计数与冻结数组摘要](evidence/workbench-catalog-handoff.json)

### 工作台中性原片的冻结快照

未创建编辑作品的原片在工作台提交时已经位于同一个 SQLite 读事务。本次把资产及当前入选凭据的校验合并进刚刚完成的两次读取。在同一连接持锁期间，先验证解码出的资产 ID，再核对项目、可用状态、大小、摘要及已封存的入选记录，并确认来源是文件 URL。事务外的捕获与创建新编辑版本仍独立重查。两连接测试中，旧读者在另一个连接撤销并重新纳入原片后继续读到原快照，开始新事务后可见新凭据，旧凭据即失效。v7 来源迁移后仍保留原始指纹。[正常冻结入口](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [来源校验](../../Sources/RAWMasterCore/LibraryStore+Editing.swift) · [原生回归](../../Tests/RAWMasterCoreTests/EditingTests.swift)

在真实 200 张原片的公共入口上，两种 SELECT 的执行次数分别从 400 次降至 200 次。独立交叉验证中，自动提交和实际 BEGIN IMMEDIATE 写事务各保留 400 次两类 SELECT。修改前后，三种模式的 200 份完整来源快照 SHA-256 均一致。两套输入分别按 A/B/B/A 与 B/A/A/B 顺序运行，每个进程先预热再计时一次。A 与 B 仅更换私下重编的优化版 RAWMasterCore，测试入口、图像库、导出库和资料库运行库相同。主源使用 4000×2666 JPEG，副源使用来自相同场景的 2048×1365 JPEG。副源的 20 张 RGGB DNG 均有新的像素数据。两套输入文件的 SHA-256 无交集。[查询计数、逐轮数据及包指纹](evidence/workbench-snapshot-reuse.json)

| 输入 | 数量 | A 整批 / 首件（秒） | B 整批 / 首件（秒） |
| --- | ---: | ---: | ---: |
| 主源 JPEG | 20 | 1.019 / 0.153 | 0.831 / 0.156 |
| 主源 JPEG | 200 | 6.951 / 0.169 | 7.798 / 0.160 |
| 主源 DNG | 20 | 0.866 / 0.116 | 0.892 / 0.102 |
| 副源 JPEG | 20 | 0.629 / 0.113 | 0.639 / 0.126 |
| 副源 JPEG | 200 | 6.474 / 0.123 | 6.368 / 0.116 |
| 副源 DNG | 20 | 0.854 / 0.119 | 0.856 / 0.119 |

200 张 JPEG 的首件在两套输入上分别缩短 9.6 ms 和 7.6 ms。主源候选两次整批分别为 8.589 和 7.008 秒，副源为 6.406 和 6.330 秒。每项只有两次计时，主源计时期间有短暂的夹具文件只读枚举。现有数据支持保留更少的查询，尚未达到历史主干 200 张整批 4.795 秒、首件 0.082 秒的水平。[原始回执摘要与测量边界](evidence/workbench-snapshot-reuse.json)

八个测试进程在最后一次计时与关闭完成后各自保存同一资料库的事务快照。80 个批次的 3,872 份票据均能对上文件和已封存的来源凭据。独立工具从真实文件描述符读取 APFS 卷 UUID、inode 和纳秒出生时间，逐份核对冻结清单、序号、SHA-256 与大小。各组预热和计时成品的文件名、来源及全部输出字节一致，八个库均通过完整性与外键检查，最终名称占位为零。[复跑方法](../../experiments/portable-processing/catalog/workbench-delivery-probe/README.md) · [两套输入的票据摘要](evidence/workbench-snapshot-reuse.json) · [3,872 份原逐项记录与来源对应清单](evidence/workbench-snapshot-receipts.jsonl.gz)
