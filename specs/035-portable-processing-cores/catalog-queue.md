# 资料库核心与跨视图任务队列

建议在现有 `rawmaster-library` 增加作业调度域。资料库统一决定可以处理哪一份内容、哪项修订拥有发布资格，图像库接受冻结的输入与配方并返回像素或产物。两者各自编译，桌面和服务端宿主负责把它们连起来。PoC 已在 macOS 和 Linux arm64 上运行同一份 Rust 调度代码。Swift 也通过生产 C 桥取得了照片 ID，并用它提交、发布和读回了一项任务。[Swift 端到端记录](evidence/catalog-swift.json) · [Rust PoC](../../experiments/portable-processing/catalog/src/queue.rs)

## 当前实现与迁移入口

| 入口 | 已有语义 | 接入共享调度时的责任 |
| --- | --- | --- |
| 资料库导入、筛选和分页 | 现有 v8 目录用 Rust/SQLite 维护逻辑文件、纳入范围、来源、可重建的索引和游标。Swift 写入在宿主拥有的事务中执行。网格按页取卡片，需要批量操作时再取有序目标。 | 原片封存、元数据写入及其索引失效在同一目录事务提交。后台缩略图、索引、分组制作再依据已提交的水位或收据运行。列表按可见页一次取状态。保留现有书签与文件访问范围解析在宿主。[目录事务](../../Sources/RAWMasterCore/LibraryStore+Catalog.swift) · [分页](../../Modules/LibraryCatalog/src/query.rs) · [网格读取器](../../Modules/LibraryCatalog/Swift/LibraryGridDataSource.swift) |
| 资料库发现、分组制作 | 检索作业绑定模型及输入版本。组作品冻结成员和配方，已有租约、暂存、内容校验与发布收据。 | 共享调度器认领一个有界阶段。领域代码保留对原片资格、组修订及成片可读性的终验。由冻结输入登记成片及生成关系。[检索认领与回报](../../Modules/LibraryCatalog/src/discovery/jobs.rs) · [分组认领与暂存](../../Modules/LibraryCatalog/src/processing/render.rs) · [发布作品](../../Modules/LibraryCatalog/src/processing.rs) |
| 编辑、AI 蒙版、生成 | 编辑控制器已按 attempt 和 run ID 拒收旧回调，重启时区分已返回待归档字节、已提交但结果未知的远端操作、可重新准备的操作。 | 将本地推理、全质量渲染和远端结果归档分别排队。保留 `outcomeUnknown` 的查询核对和已接收输出恢复。拖动产生的连续请求留在设备内存，按视窗、作品版本和 generation 合并。[当前调度与启动恢复](../../Sources/RAWMaster/EditingController.swift) · [持久状态转换](../../Sources/RAWMasterCore/LibraryStore+Editing.swift) |
| 导出工作台 | 小尺寸 JPEG 且名称唯一时最多 3 个 worker，其余情况串行。已有选区复核、目标冲突策略、单张发布与文件收据。 | 批次冻结目标列表、采用版本、格式与命名，每张作为可恢复的子作业，保留原序号。编码、受管归档、对外文件交付各自保存收据。按张重试并从成功数恢复进度。[工作台并发与命名](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [外部文件发布](../../Modules/PhotoExport/src/lib.rs) · [导出收据恢复](../../Sources/RAWMasterCore/LibraryStore+RenderedExports.swift) |

## 冻结数据与执行契约

- 持久描述符包含 schema、catalogID、commandID、父批次及序号、用途、库内文件或作品 ID、输入内容摘要与工作修订、配方和资源摘要、引擎或模型版本、输出意图及重试类别。导出增加目的地授权引用、用户选择的重名策略和保留名。设备把授权引用解析为本地书签或服务端对象位置。队列传递描述符与句柄，像素通过缓冲区或受管对象传递。
- `commandID` 标识一次用户意图。相同键与相同描述符重放原收据，同键异内容报冲突。渲染缓存另用内容、图、模型及输出规格的摘要作键。将同一张照片交付到两个目的地可以复用渲染，并分别取得交付收据。生产接入以版本化命令和固定测试向量规定精度、缺省值、字段规范化。PoC 校验 Rust JSON 表示中的载荷、任务类别、资源、预算和重试策略。
- 本机目录使用 SQLite WAL。认领、预算判定、attempt 与随机 token 分配在一个短 `BEGIN IMMEDIATE` 中。长耗时的读取、GPU 计算、文件校验在事务外执行。匹配仍有效的 token 和输入修订后，以同一事务写结果引用、作业终态和变更序号。PoC 已实现 token 核验与资源登记。接入生产时由现有领域命令再核验版本、目录纳入及用户采用关系。[SQLite 事务](https://www.sqlite.org/lang_transaction.html) · [目录对象暂存与登记](../../Modules/LibraryCatalog/src/resources.rs)
- SwiftUI 的任务发起、取消和状态订阅由 actor 承接，UI 线程更新可见行。后台执行器直接使用 Rust 的 `rlib`，或由 C ABI 调用。跨 ABI 指明版本、借用期限、释放函数与错误码。PoC 的 `rmq_probe` 是隔离实验用适配层。发布时复用现有 `rm_library_*` 的长度明确缓冲和同源 SQLite 句柄校验，分发资料库、图像编辑两个核心产物。[生产 ABI](../../Modules/LibraryCatalog/include/rawmaster_library.h) · [宿主装载及 SQLite 校验](../../Modules/LibraryCatalog/Bridge/LibraryLoader.c) · [PoC ABI](../../experiments/portable-processing/catalog/include/queue_probe.h)

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
