# RAWMaster 资料库产品设计与实现评估

2026-11-22，基于本地 `main` 工作树（`b89702e` 加当时的未提交改动），覆盖接入、初筛、资料库导航、项目精筛，以及向编辑和导出交接的入口。

建议保留“全部素材、导入记录、拍摄序列”三个入口。用户找一张已纳入的照片、接着处理上次导入、找到一段延时，分别有明确去处。下一版最值得修的是**操作实际影响哪些文件**。本次在独立资料库复现了网格只匹配 1 张却渲染出 3 张、在导出页改变后台照片的选片决定，以及历史中只选 JPEG 却连同 RAW 一起恢复。

## 现在怎样使用资料库

标题栏的“资料库、编辑、导出”切换工作流。资料库左侧选择浏览范围，主区展示该范围下的对象。导入记录和拍摄序列先展示卡片目录，单击选中，双击或回车进入照片网格。从详情返回时，两个目录分别保留搜索、筛选和选中的卡片。目录中的 ⌘F 搜索会话或组，目录会拦截照片评分和导出命令。[导航规格](../../specs/012-library-navigation/spec.md) · [工作流切换](../../Sources/RAWMaster/WorkflowTabs.swift#L16) · [目录与详情导航](../../Sources/RAWMaster/LibraryCatalogModels.swift#L53)

| 入口 | 设计意图 | 当前实现 |
| --- | --- | --- |
| 创建导入会话 | 把一次拍摄接到新项目或已有项目，先做初筛 | 选择原地引用或复制并校验。首批登记即可浏览。会话可继续接入、重新扫描来源、重新分组和检查预览风险。P/X/U 表示通过、排除、清除初筛处置，也可标为需复核。即使只查看一个子组，完成摘要仍覆盖整批。确认后，正常且未明确排除的文件纳入项目，必要序列成员可按“仅序列用途”纳入。[导入与初筛规格](../../specs/006-import-triage-workflow/spec.md) · [会话操作](../../Sources/RAWMaster/TriageWorkflowViews.swift#L4) · [纳入与关闭事务](../../Sources/RAWMasterCore/LibraryStore+Triage.swift#L301) |
| 全部素材 | 跨项目找已纳入的照片 | 左栏数字按已纳入的**文件**计。照片网格常显文件名搜索，可展开日期、机型、星级、文字标签、颜色标签、决定、可用性和已审状态。各条件要在同一文件上成立。标题分别显示拍摄数和文件数。待初筛批次在自己的会话可见。[范围选择](../../Sources/RAWMaster/AppModel.swift#L256) · [逐文件匹配](../../Sources/RAWMasterCore/AssetSearchEngine.swift#L13) · [网格搜索](../../Sources/RAWMaster/SearchReviewViews.swift#L104) |
| 导入记录 | 按来源找回一批照片，继续初筛或查历史 | 卡片按导入时间倒序，显示来源目录、目标项目、状态、拍摄数和文件数。可按来源、项目或状态文字搜索，筛选活动会话或历史。详情提供整批进度、续接、来源核验、重新定位，以及把已核验的排除项恢复到原项目。恢复保留项目后来添加的评分和标签。[会话目录](../../Sources/RAWMaster/LibraryCatalogModels.swift#L140) · [目录操作](../../Sources/RAWMaster/LibraryCatalogViews.swift#L194) · [历史恢复](../../Sources/RAWMasterCore/LibraryStore+Triage.swift#L321) |
| 拍摄序列 | 按拍摄用途组织一组照片，保留成员顺序 | 目录按组名排序，可按名称、项目和类型查找。只用已纳入成员生成公开封面及计数。可调整组名、用途、结构保护、成员、顺序和序列参与。连拍、延时、HDR、星空等都是组类型。延时／间隔组另有 MP4 合成入口，取整组参与成员及人工顺序。[序列目录](../../Sources/RAWMaster/LibraryCatalogModels.swift#L162) · [组编辑约定](../../specs/015-group-editing/spec.md) · [延时输入规则](../../Sources/RAWMasterCore/TimelapseModels.swift#L109) |
| 项目精筛 | 在一批已纳入的照片中作决定，下次接着工作 | 网格用于浏览和批量操作，单张支持 1:1 检查，比较可并排评估 2–4 张，查看 RGB、EXIF 和直方图。支持保留／排除、0–5 星和颜色标签。批量文字标签可追加、移除或替换，先预览影响，再提交，事后可从记录恢复。浏览本身不增加已审数。项目独立保存条件、排序、焦点和选择，主动离开比较后回项目显示网格。[项目审阅规格](../../specs/007-project-review/spec.md) · [比较工作台](../../Sources/RAWMaster/ComparisonViews.swift#L53) · [项目状态恢复](../../Sources/RAWMaster/AppModel.swift#L1685) |
| 转去编辑或交付 | 对选定素材继续制作，或交出原文件／成片 | 符合准入条件的照片可从全库、项目、序列或已关闭会话进入原生编辑。原件复制支持精选、显式所选及格式选择，并生成逐文件 CSV/JSON 清单。仅序列用途默认排除在精选交付之外。成片工作台按各照片当前调整渲染 JPEG、TIFF 16 位或 PNG 16 位。用户从哪个入口进入，会影响实际使用的流程和范围，详见下节。[编辑资格](../../Sources/RAWMaster/WorkbenchActions.swift#L121) · [原件交付](../../Sources/RAWMaster/WorkflowSheets.swift#L75) · [成片工作台](../../Sources/RAWMaster/ExportWorkspace.swift#L20) |

**一个计数例子。** 同一次快门的 RAW 和 JPEG 确认配对后，再加一张独立 JPEG，共有 **2 次拍摄、3 个文件**。两份伴随文件各有身份、可用性和审阅记录，组合的两份都审完才计一次已审拍摄。项目入选、初筛处置与某组的序列参与分别保存，因此一张未入选的照片仍可用于延时。自动分组目前供人工复核，预览风险检查只提供亮暗或低细节线索，自动排除规则尚未启用。[配对和计数](../../Sources/RAWMaster/LibraryCatalogModels.swift#L120) · [审阅进度](../../Sources/RAWMasterCore/ProjectReviewModels.swift#L91) · [自动分组试用范围](16-automatic-grouping-personal-trial.md)

**数据落在哪里。** 默认库为 `~/Library/Application Support/RAWMaster/library.sqlite`，当前数据库版本为 7，使用 SQLite WAL。原地引用保留来源路径，复制导入另外建立受管副本。找回原片时校验内容身份后更新有效位置。设置页显示当前库与编辑归档的位置，底层已有数据库与编辑归档的一致备份和恢复能力。原片备份、多库管理及跨设备同步分别属于更大的产品范围。[库初始化](../../Sources/RAWMasterCore/LibraryStore.swift#L18) · [数据库结构](../../Sources/RAWMasterCore/DatabaseSchema.swift#L4) · [归档备份](../../Sources/RAWMasterCore/LibraryStore+EditingBackup.swift#L7) · [存储设置](../../Sources/RAWMaster/EditingSettingsView.swift#L83) · [多库与同步路线](16-ai-native-photography-workflow.md)

## 先修会改变文件范围或选片决定的问题

| 优先级与成本 | 复现结果 | 建议与验收 |
| --- | --- | --- |
| P0 · 中，统一导出入口 | 3 个文件的项目按文件名筛到 1 个，网格菜单“复制原文件…”打开成片工作台。工作台按整个浏览范围取在线文件，实际写出 3 个 JPEG。另一条路径中，先批量选择 A+B 进入导出，返回后只选 C，再点顶部“导出”，仍取 A+B。[菜单分派](../../Sources/RAWMaster/RAWMasterApp.swift#L34) · [网格分派](../../Sources/RAWMaster/WorkbenchActions.swift#L51) · [页签复用选择](../../Sources/RAWMaster/WorkflowTabs.swift#L34) · [实际输出范围](../../Sources/RAWMaster/AppModel.swift#L750) | 把“复制原文件”和“渲染成片”做成明确的两个动作。每次进入时确定本次所选、筛选结果或明确选择的整个项目，预览和执行共用一份文件清单。列出离线文件及缺少的伴随格式。验收时，筛到 1 个就只复制这 1 个并核对内容哈希，改选 C 就只渲染 C，显式选择全项目时才输出 3 个。 |
| P0 · 小，隔离导出页的照片快捷键 | 从项目网格进入导出后，把 X 交给工作台现用的键盘处理器，数据库里的照片从“未决定”变成了“排除”。照片网格当时已被导出工作台替换。原生事件监听会避开文本框和控件，风险在照片快捷键仍收到事件时出现。[工作台与共享监听](../../Sources/RAWMaster/WorkbenchView.swift#L14) · [事件焦点判断](../../Sources/RAWMaster/RAWMasterApp.swift#L250) · [选片快捷键](../../Sources/RAWMaster/AppModel.swift#L971) | 用当前工作流决定哪些快捷键和菜单可用。验收覆盖导出页空白处、列表和命名框三种焦点，对比前后的决定、星级、已审和选择。回到资料库后 P/X/U 正常生效。 |
| P1 · 小至中，历史恢复遵循展开后的选择 | 同一对 RAW+JPEG 在初筛中均被排除。进入历史、展开组合、只选 JPEG，界面传给恢复动作的是 1 个文件，存储层又补入配对成员，最终 RAW 和 JPEG 都进入项目。[恢复按钮](../../Sources/RAWMaster/TriageWorkflowViews.swift#L171) · [动作文件集](../../Sources/RAWMaster/AppModel.swift#L1206) · [成员扩展](../../Sources/RAWMasterCore/LibraryStore+Triage.swift#L321) | 收起的组合卡可默认恢复整对，展开后按所选文件恢复。按钮或预览显示“恢复 1 个文件”或“恢复 1 次拍摄 · 2 个文件”。分别验证项目新增 1／2 个成员，并核对原有文件的星级、标签和组关系。 |

## 改进资料库的日常操作

| 优先级与成本 | 当前遇到的情况 | 建议与验收 |
| --- | --- | --- |
| P1 · 小，区分空库和待初筛 | 首批 3 个文件已登记、尚待初筛时，“全部素材”为 0，空态仍提示“从一次拍摄开始”和“接入素材…”。在该会话选中照片点“编辑”，会切成单张，实际仍停在资料库。[空态](../../Sources/RAWMaster/WorkbenchView.swift#L254) · [编辑按钮条件](../../Sources/RAWMaster/WorkflowTabs.swift#L65) | 复用现有会话状态，首次使用显示“接入素材”，已有活动批次显示“有 1 批待初筛／继续初筛”。编辑页签按照片的实际资格启用。验收覆盖新库、待初筛、零纳入关闭和已有项目四种情况。 |
| P1 · 小至中，会话能按现在的位置和文件名查找 | 把测试来源目录完整迁到新位置并完成核验，详情显示新目录名，导入记录却只能搜到旧名。目录内的搜索作用于会话，进入一个大批次后，现有筛选器主要按初筛处置或风险查找。[目录匹配字段](../../Sources/RAWMaster/LibraryCatalogModels.swift#L147) · [详情标题](../../Sources/RAWMaster/SessionWorkflowPresentation.swift#L39) · [会话内筛选](../../Sources/RAWMaster/TriageWorkflowViews.swift#L114) | 会话同时索引导入时和当前来源，卡片标明当前目录，详情保留原路径。会话照片网格增加独立的文件名查找。验收时旧名、新名均命中同一会话，在会话内搜文件也只影响该批照片的显示范围。 |
| P1 · 中，返回实际出发位置 | 从项目照片信息栏进入它的拍摄组，再点返回，会落到全局“拍摄序列”。原项目的筛选仍在，但要手动找回项目。直接从目录打开的序列则已有正确的返回定位。[照片信息入口](../../Sources/RAWMaster/WorkbenchView.swift#L730) · [返回目的地](../../Sources/RAWMaster/LibraryCatalogModels.swift#L65) | 进入组时记住出发范围、照片和位置，分别显示“返回〈项目名〉”或“返回拍摄序列”。用同一个组从两个入口往返验证，检查原查询、焦点和选区。 |
| P1 · 小，按实际参与拍摄数启用延时合成 | 只有一对 RAW+JPEG 的延时组，目录显示 1 次拍摄、2 个文件。“合成延时视频”按两个参与文件启用，点击后才提示至少需要两次拍摄。[入口资格](../../Sources/RAWMaster/TimelapseComposer.swift#L207) · [实际帧选择](../../Sources/RAWMasterCore/TimelapseModels.swift#L119) | 让组卡片和合成按钮共用参与拍摄数。只有一对时提示“还需 1 次参与拍摄”，再加入一次可用拍摄就能进入合成。另测组内有离线成员及成员退出序列的情况。 |

帮助文案可以随上述改动一并更新。README 仍指导用户点放大镜并在右栏筛选，实际照片网格常显搜索框，条件在搜索框下方展开。优先更新搜索位置和两种交付入口，方便用户按文档完成操作。[现有使用说明](../../README.md#使用) · [实际搜索栏](../../Sources/RAWMaster/SearchReviewViews.swift#L104)

## 随资料量增长再投入的方向

- **P2 · 中，保存常用筛选和收起已完成项目。** 现在每项目能恢复上一组条件，侧栏仍平铺所有已发布项目。可以先允许把“未审且 4 星以上”“离线待找回”等条件命名保存，并给项目增加收起／重新打开。验收时改变评分或可用性，集合随查询更新，序列成员与原片路径保持稳定。这两项已有本地管理规划可沿用。[项目状态模型](../../Sources/RAWMasterCore/ProjectReviewModels.swift#L71) · [项目侧栏](../../Sources/RAWMaster/WorkbenchView.swift#L361) · [已规划的智能集合与项目管理](15-next-local-workflow-review.md)
- **P2 · 先测量，再定优化成本。** 导入中已有后台读取与刷新合并，普通刷新仍读整库快照。导入记录和序列卡片在视图求值时重新汇总资产，侧栏还为每个项目重复统计文件。历史验证包括 3 万条合成元数据的一次温态查询，以及在 6,928 个文件的库中重跑 727 个真实 RAW。建议用 1 千、1 万、3 万个文件分档测量目录首次可操作时间、输入到结果呈现的 P95、导入时滚动延迟。先把项目计数和目录摘要按快照复用，再根据实测决定是否下推 SQLite 查询。[快照读取](../../Sources/RAWMaster/LibrarySnapshot.swift#L28) · [目录汇总](../../Sources/RAWMaster/LibraryCatalogModels.swift#L147) · [既有查询测量](../../specs/007-project-review/validation.md#自动化) · [真实导入验证](../../specs/017-import-performance/live-session-validation.md#真实会话验证)

## 本次验证

在当前工作树的独立副本上重新构建。使用临时 SQLite 库和合成照片，**138 项仓库已有的资料库相关测试通过**，包括目录、初筛、项目检索、组管理、导出、重新定位和两项显式开启的布局测试。另用 **8 个定向场景**核对上述现状，包含检查实际渲染文件及重新读取数据库。这些场景记录当前行为，表中的验收条件给出修复后的预期。[目录回归](../../Tests/RAWMasterUITests/LibraryCatalogTests.swift) · [初筛回归](../../Tests/RAWMasterUITests/TriageWorkflowUITests.swift) · [项目回归](../../Tests/RAWMasterUITests/ProjectReviewUITests.swift) · [成片导出回归](../../Tests/RAWMasterUITests/ExportWorkspaceTests.swift)

界面核对使用 1100 × 720 pt 离屏工作台截图。导出菜单的文字与分派经当前源代码核对，键盘场景在工作台事件处理器复现。已安装应用的系统级键鼠操作、真实用户库和大规模窗口时延属于现场验证范围。本机复核材料位于 `output/validation/library-product-review-20261122/`。
