# 042 · 实施计划与发布任务

2026-11-27 · [产品规格](spec.md) · [客户端任务盘点](task-inventory.md) · [走查与验收](validation.md)

## 1. 复用入口

| 现有入口 | 当前情况 | 实施增量 |
| --- | --- | --- |
| [打包脚本](../../scripts/build-app.sh) 与 [ApplicationDelegate](../../Sources/RAWMaster/RAWMasterApp.swift) | SwiftUI 工作台已经共享应用模型。构建尚未注册库包文稿 | Info.plist 声明自有 UTType，符合 `com.apple.package`，经 `CFBundleDocumentTypes` 与 `LSItemContentTypes` 关联。AppKit 冷启动／运行中收到包路径后转交同一会话入口 |
| [LibraryLocation](../../Modules/LibraryCatalog/Swift/LibraryLocation.swift)、[LibraryPackagePanel](../../Modules/LibraryCatalog/Swift/LibraryPackagePanel.swift)、[AppModel](../../Sources/RAWMaster/AppModel.swift) | 已能选址建包、打开 SQLite 或备份、记住地址。缺省位置会隐式创建默认库 | 区分启动时无库、旧库、待重新定位、活动库。应用默认存书签与位置身份，保留调试用的显式路径 |
| [ApplicationLibrarySession](../../Sources/RAWMaster/ApplicationLibrarySession.swift) 与 [退出协调](../../Sources/RAWMaster/ApplicationTerminationOwner.swift) | 菜单与 Finder 共用切换入口 | 确认后等待任务或保存检查点。关闭屏障与退出共用任务收尾及回执核对。异步回调核对会话打开代次 |
| [033 快照和还原](../../Modules/LibraryCatalog/src/backup.rs) | 已有一致快照、清单、对象核验和恢复 | 创建工作库清单，校验并迁移老库。复用快照和资源清单使目录、编辑资源及托管原片的引用可验证 |
| [CatalogTaskQueue](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) · [Rust 调度表](../../Modules/LibraryCatalog/src/scheduler/schema.sql) | 持久租约、重试、外部发布核对。部分领域独立领取任务 | 增加按当前库枚举、调度、重启核对和动作分派。维持一项副作用恰有一个有效执行租约 |
| [ProcessingAdmission](../../Modules/LibraryCatalog/Swift/ProcessingAdmission.swift) | 进程内资源分配 | 与持久调度共用 CPU、GPU、I/O 和峰值内存预算。前台交互优先，后台工作在分片、逐项或 worker 退出点让出 |

库包采用版本化 `library.json` 记录格式、`libraryID` 及目录文件名，存储复用 `library.sqlite` 与已有资源布局。同后缀的备份按已有备份清单处理。先判断类型及兼容性，再取得数据库写权限。保留无工作库清单的已交付包。先做真实签名包注册以及 WAL、备份与相对路径验证，再迁移工作库。[Apple 文件包](https://developer.apple.com/documentation/technologyoverviews/files-and-directories) · [SQLite WAL](https://www.sqlite.org/wal.html)

## 2. 实现约束

- **地址与身份。** SQLite 的库身份长期稳定，卷与包文件身份用于定位和识别移动，应用状态保存安全作用域 bookmark。涉及同名文件、同路径换卷或失效 bookmark 时先确认身份再更新。新包、迁移和独立副本用同卷暂存并核验，提交成功后才写最近位置。独立副本以新库身份和本机任务执行权限启动，历史收据可随数据保留。
- **打开与切换。** 解析并预检目标后，由用户确认等待或暂停。等待期间旧库继续执行任务。关闭前预留现有目标包的写锁，以便目标被占用时直接返回旧库。关闭旧库连接和 worker 后才打开目标库连接，释放旧库资源后再将目标注册为活动库。启动时合并同包的重复 Finder 事件，恢复前核验租约与发布记录。退出途中到达的旧回调仅能核对旧库的任务收据。
- **本地持久化。** 继续使用现有导入会话、032 批次／文件收据、`ProcessingJob`、`SceneWorkflowBatch`、分组或索引记录。统一任务视图通过适配读取状态、权限和可用动作。新增意图写入所属库，写入领域记录同事务完成，或从已提交的领域主键确定性补建。设备安装沿用设备存储与下载清单。
- **执行与交付。** 调度身份包含库、业务主键及逐项键。冻结输入、版本、模型、目标和任务参数，重跑沿用同一请求及收据。过期 lease 或重启时先核对目录回执、暂存物与最终文件。有可能已发布的文件要核对卷、预期内容和所有权。032 继续使用原冻结文件名与收据。Lease 只覆盖执行尝试，成功、取消和历史按领域定义。
- **资源与上下文。** 用户当前操作优先于长期批次和后台维护。后台 GPU／IO 在安全点降并发或暂停。切库保留设备任务。任务详情只刷新所属库，在画布与主窗口切换时将旧会话数据与新库隔离。

## 3. 当前版本任务

| 顺序 | 可实施的改动 | 出口证据 |
| --- | --- | --- |
| 1 | [x] **LIB01** 注册 Finder 文稿，接通无库开始页、新建、打开、最近库、失效地址与错误焦点。**LIB02** 兼容旧库和备份，支持包注册、移动、独立拷贝及迁移 | 签名验证包冷启动／热打开、两卷和旧库数据回读 |
| 2 | [x] **LIB03** 单活会话、包写锁、切库时写入和任务屏障，按库身份恢复浏览和选片。**LIB04** 复验系统文稿事件及失效位置恢复 | 两库切换后选片与授权分离。原任务无法写进另一个库。目标失败后可继续原工作 |
| 3 | [x] **TASK01** 制作任务列表接入导入、032 成片、原件与清单。**TASK02** 重启、暂停、目标身份核对与取消 | 导入保留已登记的素材。交付恢复沿用原项、文件名与收据 |
| 4 | [x] **TASK03** 本机 Flux 与 038 批次接入任务历史、核对、继续、取消、重试和候选入口 | 本机模型生成与回读。038 使用同一批次和冻结版本继续，保留已有候选与撤销能力 |
| 5 | [ ] **TASK04** 分组制作、重定位、备份与旧目录迁入、索引以及设备安装按清单接入。**TASK05** 资源预算与全版回归 | 长任务可从同一入口回查原记录。设备任务切库后仍可见。原生响应、权限及输出校验记录到验证页 |

第 1、2 步共享会话入口。第 3、4 步可先用显式测试库并行实施，再与切库屏障联验。软件、相机和媒体能力沿用当前产品配置。已安装模型的离线验收与模型下载验收分别进行。[验收记录](validation.md)
