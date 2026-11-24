# 摄影工作台功能与走查

范围按摄影师能操作的入口统计。核对依据是工作树中的三个工作流、应用菜单、六页设置与资料库专项面板。表中动作均可在 HTML 中操作。「设计预演」标出规格中仍在验证的产品方向。这个表记录交互覆盖，原生交付状态见各特性自己的验证记录。[工作流定义](../../Sources/RAWMaster/WorkflowTabs.swift) · [应用菜单与诊断窗口](../../Sources/RAWMaster/RAWMasterApp.swift) · [资料库面板路由](../../Sources/RAWMaster/LibraryWorkspace.swift) · [应用设置](../../Sources/RAWMaster/EditingSettingsView.swift)

## 资料库与作品管理

在主窗口左上角使用「资料库导航」收起或恢复侧栏。顶栏保留工作流切换，原有项目及选片保持。窄窗口使用同一按钮打开抽屉。[标题栏走查](../../specs/025-editing-workspace/prototype-review.md#主窗口标题栏)

| 从哪里进入 | 可以走查的动作和结果 | 对照规格 |
| --- | --- | --- |
| [资料库](prototype/index.html#library/project/river) → 接入素材 | 选示例卡、引用或复制、新建或追加项目。重复接入同一来源回到已有批次。初筛操作里模拟中断、继续和核验来源 | [本地接入](../../specs/001-local-culling/spec.md) · [渐进导入与性能](../../specs/017-import-performance/validation.md) |
| [导入与初筛](prototype/index.html#library/triage/card-b) | P/X/U、仅序列用途、扫描自动组、确认组名和保护结构、检查预览风险。整批清单列出纳入、排除、待复核与未分析，需核对后封存 | [自动分组](../../specs/005-automatic-sequence-stacks/spec.md) · [初筛](../../specs/006-import-triage-workflow/spec.md) · [会话操作](../../specs/016-import-triage-actions/spec.md) |
| [导入历史](prototype/index.html#tools/history) | 查看批次与当时的排除清单、恢复纳入。原片离线时先按身份接回。操作记录可撤销最近一次资料库操作 | [封存边界](../../specs/033-library-lifecycle/spec.md) · [重新定位](../../specs/004-client-next-batch/spec.md) |
| [项目 / 全部素材 / 精选](prototype/index.html#library/project/river) | G/E/C 切换网格、单张和 2–4 张比较，Z 放大样片。多选、移焦、保留/排除、0–5 星、颜色、已审/未审、批量标签逐张预览。照片信息可核对 RAW+JPEG、解除或确认关联 | [工作区](../../specs/009-workbench-views/spec.md) · [审阅](../../specs/007-project-review/spec.md) · [导航](../../specs/012-library-navigation/spec.md) |
| 同一项目 → 搜索、筛选、显示选项 | 按文件名、日期、机型、星级、标签、决定、可用性和已审筛选。范围、排序、选区保存在当前项目。收起筛选保留查询。清除标签恢复结果。可折叠拍摄组 | [浏览与序列](../../specs/011-browser-sequences/spec.md) · [组与批次标题](../../specs/014-sequence-headers/validation.md) |
| [拍摄组](prototype/index.html#tools/groups) / [组内浏览](prototype/index.html#library/group/dusk) | 从所选作品建组，复核用途、改名、保护、排序、加入/移出、拆分/合并、逐帧勾选参与。独立精选决定与序列参与可分别修改 | [序列流转](../../specs/013-sequence-flow/validation.md) · [组编辑](../../specs/015-group-editing/spec.md) |
| [分组制作](prototype/index.html#tools/process) | 延时视频、星轨、HDR、全景。延时可播放样帧，调速度/画幅/帧率，展开去闪烁、稳定、曝光关键帧和编码。改设置后重做预览，冻结整组参与帧，任务详情能回查输入、配方与结果 | [延时](../../specs/010-timelapse-video/spec.md) · [分组制作验证](../../specs/033-library-lifecycle/group-render-validation.md) |
| [文件夹、集合与作品](prototype/index.html#tools/organization) / [受管文件](prototype/index.html#tools/files) | 建文件夹、普通或按评分的智能集合，将所选作品加入集合、创建虚拟副本、改名。先预演目标路径与文件名再执行示例移动。操作记录可回退 | [资料库生命周期](../../specs/033-library-lifecycle/spec.md) |
| [智能检索](prototype/index.html#tools/discovery) / [照片检查器](prototype/index.html#tools/inspection) | 按示例场景查询、叠加围栏/人物筛选、命名人物簇、检查本机索引、跨库检索。单张或多图检查局部、写入人工结论、批改元数据 | [检索与检查器](../../specs/033-library-lifecycle/search.md) |
| [资料库与备份](prototype/index.html#tools/package) / [迁入 Lightroom](prototype/index.html#tools/migration) | 创建/打开示例库、备份范围、增量前置条件、还原到另一份目录、整卷接回及索引维护。迁入预检、迁入集合、核对并绑定离线原片 | [目录与备份](../../specs/033-library-lifecycle/spec.md) · [Lightroom 迁入](../../specs/033-library-lifecycle/lightroom-migration.md) |

## 编辑与交付

| 从哪里进入 | 可以走查的动作和结果 | 对照规格 |
| --- | --- | --- |
| [编辑暗房](prototype/index.html#edit/development) | 从底部浮动工具条前后翻片、预览邻片、缩放、FIT 或更换背景。裁切与拉直在画布右上方打开。可选择原片或已有版本，擦除、混合、差值、棋盘格或并排对比 | [暗房布局与走查](../../specs/025-editing-workspace/prototype-review.md) · [原生画布](../../Sources/RAWMaster/EditingImageCanvas.swift) · [编辑体验](../../specs/019-editing-experience/spec.md) |
| 右栏图标列 → [基础](prototype/index.html#edit/basic)、曲线、混色、细节、光学、效果、分级 | 用图标切换相邻详情面板，键盘上下键切换工具。可调 RGB 直方图、曝光、曲线及分级，查看颜色示波器 | [原生编辑](../../specs/018-native-editing/spec.md) · [显影控制](../../specs/020-development-controls/spec.md) · [照片调整](../../specs/021-photos-editor/spec.md) |
| 右栏图标列 → [蒙版](prototype/index.html#edit/masks)、修复、细节 | 添加和定位选区，调整组合、反转、羽化、不透明度、图层曝光、排序与启停。修复可标点，仿制另选取样点。RAW 细节、降噪和超分可发起示例任务 | [蒙版模块](../../specs/026-mask-ai-native/spec.md) · [RAW 集成](../../specs/027-mask-ai-raw-integration/spec.md) · [修复](../../specs/029-repair-tools/spec.md) |
| 左栏 → 预设、快照、历史 | 基础滤镜、Adobe Adaptive 与三款胶片模拟使用同一文字目录。悬停在主画布预览，点击采用，可收藏、搜索和导入 Lightroom／Camera Raw 预设。Adaptive 蒙版先确认覆盖范围。可调整胶片强度并用快照和历史恢复 | [滤镜体验](../../specs/028-filter-experience/spec.md) · [预设目录与交换](../../specs/031-preset-browser/spec.md) |
| [智能编辑 → 智能预设](prototype/index.html#edit/smart) | 新进暗房默认显示此面板。人像、风光、纪实共七种意图，核对作用范围或组照参考张后明确采用 | [场景卡](../../specs/030-ai-retouching/scene-presets.md) · [界面规格](../../specs/030-ai-retouching/ux-design.md) |
| [底部「Prompt」](prototype/index.html#edit/development) · 设计预演 | 试浮条形变、套用提示词、整张／拖框／现有蒙版、选择两种模型、云端发送复核、候选对比和撤销。离开可从本张或任务返回 | [034 规格](../../specs/034-quick-prompt-editing/spec.md) · [走查](../../specs/034-quick-prompt-editing/prototype-review.md) |
| 智能预设 → 交互式创作 → [Agent 对话](prototype/index.html#edit/agent) | 发送要求、补充意图、审阅本张对话及执行位置，再发起模拟任务。可回到智能预设，也可换片后回来续写。严格纪实限制内容改写 | [AI 摄影工作流](../../specs/008-ai-photography-workflow/spec.md) · [场景精修与研发阶段](../../specs/030-ai-retouching/spec.md) |
| 照片标题栏 → [作品版本](prototype/index.html#edit/versions) / [制作任务](prototype/index.html#jobs) | 草稿保存为独立初修候选。查看、保留、放弃、恢复、采用或从版本继续，外部 TIFF 返回后登记候选。任务可取消、重试、模拟中断并核对原任务结果，回到对应照片 | [版本与交付](../../specs/023-effects-delivery/spec.md) |
| [统一导出](prototype/index.html#export) / [专项大批量样本](../../specs/032-export-workspace/prototype.html) | 从选片、编辑草稿或采用版本进入同一面板。成片/原件/仅清单，JPEG/TIFF/PNG、尺寸与质量、模板与重名、EXIF/GPS、水印边框、预设保存/导入/分享、独立目的地。逐项预检、接回、取消、重试和结果。提交成片后可关闭任务详情并返回原视图，交付继续。200 张可提交，201 张显示超额并保留勾选。1,200 张可筛选与分批 | [导出规格](../../specs/032-export-workspace/spec.md) · [批量范围与早期实测](../../specs/032-export-workspace/batch-limits.md) |
| 导出 → [任务详情](../../specs/032-export-workspace/prototype.html) / [制作任务](prototype/index.html#jobs) → 查看本批交付 | 接回目录时核对提交时的卷和目录身份。同路径的另一卷仍离线。原卷以新设备号重挂后，先按原票据认领已发布文件，明确继续才写余项。可逐张接回原片、核对同名冲突、取消余项，并返回改选后的照片 | [中断、卷重挂、继续和取消走查](../../specs/032-export-workspace/batch-continuation.md#走查) · [原生重启回执](../../specs/035-portable-processing-cores/evidence/workbench-native-restart.json) · [APFS 重挂回执](../../specs/035-portable-processing-cores/evidence/workbench-apfs-remount-batch13s.json) |
| [设置](prototype/index.html#settings/general) / [诊断](prototype/index.html#settings/diagnostics) | 跟随系统/浅/深外观、存储、编辑与预览、本机模型目录和环境准备、云服务启停、诊断摘要、性能监控入口。环境未就绪时从 Agent 对话转入设置，再返回同一张照片 | [外观与图标](../../specs/003-app-icon/spec.md) · [图像交互性能](../../specs/002-image-interaction-performance/spec.md) · [显示代理](../../specs/024-jpeg-display-proxy/plan.md) |
| [Server 规划预演](prototype/index.html#tools/server) | 逐步推演归档及独立备份、冷片/异机恢复、离线修订与冲突、冻结输入的远程作业和重连。当前原生交付范围为本地资料库，Server 待立项 | [Server 后续产品验收](../../specs/033-library-lifecycle/server.md) |

## 可重复的评审路线

1. **从卡到项目。** 在「河谷拍摄」接入航拍卡，排除第二张，扫描并复核分组。在整批清单核对三次拍摄、两张纳入、一张排除。封存后回项目检查选片，再从导入历史恢复第二张。原封存清单仍能读到当时的排除决定。
2. **从调整到交付。** 在河湾和水鸟上多选，从水鸟进入编辑。修改曝光、添加蒙版、裁成方形，存为候选。到作品版本中采用，再调一次曝光，选择「保存新版本并导出」。两张照片都在导出列表，水鸟预选新候选，另一张保留自己的版本。核对成品尺寸，试用相纸展签后取消或应用。
3. **检查异常与规模。** 在资料库筛「离线」找到山坡照片，打开重新定位核验。另从独立导出样本切到 201 张，确认超限后手动保留前 200 张。筛选 1,200 张候选时勾选总数保持不变。切到仅写清单验证离线条目仍能列入。
4. **冻结一组输入。** 打开「暮色延时」，调整参与帧，进入制作并修改帧率。更新预览后提交，到制作任务查看输入文件、设置与 MP4 结果名。相同入口可切星轨、HDR 或全景复核各自选项。
5. **让任务返回正确版本。** 在「智能编辑 → 交互式创作」描述要求并核对生成输入，按提示准备本机环境，返回原对话。提交后切换视图、取消、重试，再查看该照片的候选。选中「严格纪实」时核对内容改写提示。

## 本次浏览器验收

2026-11-22，macOS 上以 Chrome 157 和 agent-browser 0.26 走查。桌面 1440 × 900 同屏呈现浏览范围、照片和检查器。390 × 844 改用两列选片和可收起的导航、筛选抽屉。[桌面资料库](evidence/library.webp) · [默认智能编辑](evidence/editor.webp) · [Agent 对话](evidence/editor-agent.webp) · [窄窗暗房](evidence/editor-compact.webp) · [窄窗浅色资料库](evidence/compact.webp)

整机回归通过 14 组场景。编辑专项覆盖智能预设与胶片、浮动条与范围内翻片、蒙版与裁切、版本交付、Agent 对话与任务恢复、窄窗键盘和外观。其余场景覆盖双击本地入口、标题栏与资料库侧栏、搜索比较、接入与封存、组照制作、原件伴随交付、空库恢复和批量边界。另复跑 Spec 032 的 11 项独立检查。1,200 张候选在 1280 × 760 窗口挂载 10 个列表行，201 张时三种交付模式均阻止提交，明确缩减至 200 张后可以输出清单。[整机检查](../../scripts/check-ui-prototype.py) · [导出专项检查](../../specs/032-export-workspace/benchmark/prototype-check.py)

新增快速 Prompt 后复跑同一工作台，21 组均通过。新增 7 组覆盖形变、范围工具、云端复核、未知结果、采用撤销、过期候选和减少动态效果。[快速 Prompt 实测](../../specs/034-quick-prompt-editing/prototype-review.md)

## 验证口径

工作台使用仓库内授权的低分辨率 JPEG，文件名、拍摄参数、目录、决定和作业为演示数据。直方图取自样片 RGB 分布。浏览器的色调、裁切和选区演示用于比较操作与版式，RAW 像素、光学校正、降噪、AI 推理和序列编码效果需回原生引擎验证。XMP 导入、备份、云提交和 Server 走查使用本机示例。导出专项已有可读写的导出预设文件。模拟交付详情可检查文件名和状态。[浏览器回归脚本](../../scripts/check-ui-prototype.py) · [离线样片](../fixtures/offline-regression.md)
