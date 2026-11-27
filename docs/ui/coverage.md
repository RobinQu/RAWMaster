# 摄影工作台功能与走查

范围按摄影师能操作的入口统计。核对依据是工作树中的三个工作流、应用菜单、六页设置与资料库专项面板。表中动作均可在 HTML 中操作。「设计预演」标出规格中仍在验证的产品方向。这个表记录交互覆盖，原生交付状态见各特性自己的验证记录。[工作流定义](../../Sources/RAWMaster/WorkflowTabs.swift) · [应用菜单与诊断窗口](../../Sources/RAWMaster/RAWMasterApp.swift) · [资料库面板路由](../../Sources/RAWMaster/LibraryWorkspace.swift) · [应用设置](../../Sources/RAWMaster/EditingSettingsView.swift)

## 资料库与作品管理

在主窗口左上角使用「资料库导航」收起或恢复侧栏。顶栏保留工作流切换，原有项目及选片保持。窄窗口使用同一按钮打开抽屉。[标题栏走查](../../specs/025-editing-workspace/prototype-review.md#主窗口标题栏)

| 从哪里进入 | 可以走查的动作和结果 | 对照规格 |
| --- | --- | --- |
| [资料库](prototype/index.html#library/project/river) → 接入素材 | 选示例卡、引用或复制、新建或追加项目。重复接入同一来源回到已有批次。初筛操作里模拟中断、继续和核验来源 | [本地接入](../../specs/001-local-culling/spec.md) · [渐进导入与性能](../../specs/017-import-performance/validation.md) |
| [导入与初筛](prototype/index.html#library/triage/card-b) | P/X/U、仅序列用途、扫描自动组、确认组名和保护结构、检查预览风险。整批清单列出纳入、排除、待复核与未分析，需核对后封存 | [自动分组](../../specs/005-automatic-sequence-stacks/spec.md) · [初筛](../../specs/006-import-triage-workflow/spec.md) · [会话操作](../../specs/016-import-triage-actions/spec.md) |
| [导入历史](prototype/index.html#tools/history) | 查看批次与当时的排除清单、恢复纳入。原片离线时先按身份接回。操作记录可撤销最近一次资料库操作 | [封存边界](../../specs/033-library-lifecycle/spec.md) · [重新定位](../../specs/004-client-next-batch/spec.md) |
| [项目 / 全部素材 / 精选](prototype/index.html#library/project/river) | G/E/C 切换网格、单张和 2–4 张比较，Z 放大样片。单张胶片带的组框与组外选中框上下对齐，组内外缩略图同一水平线。组头第一行的箭头和组名共同折叠；长名按宽度省略，悬停可看全名。第二行是张数与设置，取消属性对话框回到原选片。多选、移焦、保留/排除、0–5 星、颜色、已审/未审、批量标签逐张预览。照片信息可核对 RAW+JPEG、解除或确认关联 | [工作区](../../specs/009-workbench-views/spec.md) · [审阅](../../specs/007-project-review/spec.md) · [导航](../../specs/012-library-navigation/spec.md) |
| 同一项目 → 搜索、筛选、显示选项 | 按文件名、日期、机型、星级、标签、决定、可用性和已审筛选。范围、排序、选区保存在当前项目。收起筛选保留查询。清除标签恢复结果。可折叠拍摄组 | [浏览与序列](../../specs/011-browser-sequences/spec.md) · [组与批次标题](../../specs/014-sequence-headers/validation.md) |
| [拍摄组](prototype/index.html#tools/groups) / [组内浏览](prototype/index.html#library/group/dusk) | 从所选作品建组，复核用途、改名、保护、排序、加入/移出、拆分/合并、逐帧勾选参与。独立精选决定与序列参与可分别修改 | [序列流转](../../specs/013-sequence-flow/validation.md) · [组编辑](../../specs/015-group-editing/spec.md) |
| [分组制作](prototype/index.html#tools/process) | 延时视频、星轨、HDR、全景。延时可播放样帧，调速度/画幅/帧率，展开去闪烁、稳定、曝光关键帧和编码。改设置后重做预览，冻结整组参与帧，任务详情能回查输入、配方与结果 | [延时](../../specs/010-timelapse-video/spec.md) · [分组制作验证](../../specs/033-library-lifecycle/group-render-validation.md) |
| [文件夹、集合与作品](prototype/index.html#tools/organization) / [受管文件](prototype/index.html#tools/files) | 建文件夹、普通或按评分的智能集合，将所选作品加入集合、创建虚拟副本、改名。先预演目标路径与文件名再执行示例移动。操作记录可回退 | [资料库生命周期](../../specs/033-library-lifecycle/spec.md) |
| [智能检索](prototype/index.html#tools/discovery) / [照片检查器](prototype/index.html#tools/inspection) | 按示例场景查询、叠加围栏/人物筛选、命名人物簇、检查本机索引、跨库检索。单张或多图检查局部、写入人工结论、批改元数据 | [检索与检查器](../../specs/033-library-lifecycle/search.md) |
| [资料库与备份](prototype/index.html#tools/package) / [迁入 Lightroom](prototype/index.html#tools/migration) | 创建/打开示例库、备份范围、增量前置条件、还原到另一份目录、整卷接回及索引维护。迁入预检、迁入集合、核对并绑定离线原片 | [目录与备份](../../specs/033-library-lifecycle/spec.md) · [Lightroom 迁入](../../specs/033-library-lifecycle/lightroom-migration.md) |

[资料库网格](prototype/index.html#library/project/river)多选后用底栏「批量导出」进入 032。返回时保留选片与焦点。若某张照片已离开筛选范围，停留在网格核对余下照片，再次导出。[操作与回归证据](../../specs/032-export-workspace/spec.md#资料库网格直接交付)

批量调色从 [照片列表](prototype/index.html#library/project/river) 多选至少两张，打开底栏「更多 → 批量工作流」。焦点照片提供源草稿，其余目标逐张预检，亦可选已存模板。最近批次的结果、取消、重试与撤销从同一菜单返回；20／200 张仅位于预检的「原型评审样本」。[走查](../../specs/038-node-dag-workflow/validation.md#紧凑画布工具与照片列表入口)

## 编辑与交付

037／038 的阶段入口已在 `main@b238c0ab` 的 Release 默认显示。HDR 暗房底部可「保存候选」和打开「作品版本」。从暗房进入 032 可用同一冻结版本分别发布 PQ 与 SDR。[联合方案](../../specs/035-portable-processing-cores/roadmap.md) · [同包实拍与跨屏](../../specs/037-color-film-hdr/validation.md#同一签名-release-首条闭环)

| 从哪里进入 | 可以走查的动作和结果 | 对照规格 |
| --- | --- | --- |
| 编辑右栏 → 节点工具条 → [Graph](prototype/index.html#edit/dag) | 当前节点下拉整合节点列表、添加、整理及更多操作，右侧只有「忽略该节点」和 Graph 开关；Graph 点击与下拉、检查器及忽略状态联动。更多菜单首层六项，高级图操作折叠；右键或 Shift+F10 按节点、连线和画布区分操作。Solo 和临时旁路互斥，不写历史或导出。按节点能力过滤九类调色域，复位本节点和查看节点输出只在节点菜单。Graph 默认 100% 可读居中，超界优先保留当前节点；「适合全图」可缩小，百分比按钮恢复可读居中。主图用同色系小提示，健康单节点终稿默认不显示，中间及失败仍保留提示和操作。主图与 Liquid Glass 非模态 Graph 同时显示，展开保留至少 240px 高画布，桌面最小外框 520×392，窄窗适配宽度，短窗只显示标题条。窗口可移动、调整大小、收起和关闭。串行、Parallel／Layer、Outside、增删／忽略／分组、连线草稿与监看；本张的工作流模板在高级图操作。左栏仅滤镜、快照、历史。Crop／Mask／Remove 从画布工具条展开。所有像素与覆盖为模拟，待摄影师确认 | [Node DAG 原型范围](../../specs/038-node-dag-workflow/spec.md) · [走查记录](../../specs/038-node-dag-workflow/validation.md) |
| [原生工作流批量阶段](prototype/index.html?batchNativeReview=1) → 资料库多选 → 更多 → 批量工作流 | 逐张冻结曝光/模板、底稿和原片；重试待处理项，保留冲突，撤销未被使用的候选。成功候选交给现有 032，不自动采用或更改原选片。Graph「更多」提供独立模板。 | [038 批量规格](../../specs/038-node-dag-workflow/spec.md#本地模板与原生批量阶段走查) · [验证](../../specs/038-node-dag-workflow/validation.md#原生模板与可恢复批量) |
| [原生 Graph 阶段](prototype/index.html?sceneNativeReview=1&graphNativeReview=1) → 创建 HDR 草稿 → 当前节点 → Graph | 已准入的场景草稿可编辑。单选联动参数，多选管理结构。串行、Parallel、Layer、组、输入连接草稿、监看与返回最终根。非法草稿暂停保存与导出，取消回到已提交图。保存和 032 使用最终根。 | [038 阶段规格](../../specs/038-node-dag-workflow/spec.md#原生可编辑-graph-阶段走查) · [阶段证据](../../specs/038-node-dag-workflow/validation.md#原生可编辑-graph) |
| [兼容评审工作台](prototype/index.html?compatibilityGraph=1) → 编辑 → 当前节点 → Graph · 评审开关 | 打开只读「照片来源 → 兼容显影 → 最终输出」，主图及旧显影控件保持不变。收起、移动、复位或关闭；Escape 返回 Graph 按钮。离线或画布草案显示原因，查看作品版本、换片和离开编辑时关闭。不会生成可编辑图，不改变导出。原生随 Release 默认显示；`RAWMASTER_EXPERIMENTAL_COMPATIBILITY_GRAPH=0` 仅用于隐藏该只读面板做诊断。 | [038 只读兼容视图](../../specs/038-node-dag-workflow/spec.md#只读兼容视图评审入口) · [验证](../../specs/038-node-dag-workflow/validation.md#原生只读兼容视图) |
| [编辑暗房](prototype/index.html#edit/development) | 编辑不显示胶片带。用底部浮动工具条的上一张／下一张或 ←／→ 在当前范围内翻片；首尾禁用对应方向。工具条仍可预览邻片、缩放、FIT 或更换背景。画布在 FIT 显示视口定稿。捏合（原型用 Ctrl + 滚轮）或点 +／− 后，按当前倍率从原图为可见窗口取样，不跳到 100%；只有 1:1 命令进入实际像素。极速缩放中可显示临时预览，两种模式结束后画质相同。[自由缩放走查](../../specs/025-editing-workspace/prototype-review.md#自由缩放与原图取样)。裁切与拉直从照片底部 Crop 打开，工具条展开后完成或取消收回。可选择原片或已有版本，擦除、混合、差值、棋盘格或并排对比 | [暗房布局与走查](../../specs/025-editing-workspace/prototype-review.md) · [原生画布](../../Sources/RAWMaster/EditingImageCanvas.swift) · [视口定稿](../../specs/036-render-pipeline-performance/spec.md) · [编辑体验](../../specs/019-editing-experience/spec.md) |
| 当前节点 → 右栏图标列 → [基础](prototype/index.html#edit/basic)、色轮、HDR、曲线、混色、切片、变形、细节、效果；输入阶段另管原片能力 | 未展开结构图时保留兼容显影控件；展开 Graph 后，Corrector 仅开放九类调色域，拍摄白平衡及 RAW／光学属于输入阶段。用图标或上下键换面板。首次打开首区，返回保留展开状态。分组用分隔线，圆形启停保留数值，单独复位不折叠。名称、轨道与精确输入共用一行，支持相对拖动和方向键；悬浮刻度不改变行距。左右边距同宽；标签采用平面样式，带箭头的提示在图标外侧。停靠直方图与矢量绘图区为 108／144 点，可呼出独立窗。文字以细节面板为基准，参数／说明／功能块分用 4／7／12 点间距；普通说明完整换行。直方图下采样采用全宽平面按钮及中性列表，色块与编号、RGB 读数并列；九点上限、重新取样、画面外占位和 Escape 取消保留。[文字与采样走查](../../specs/021-photos-editor/validation.md#文字节奏与颜色采样列表)。所有调整面板的勾选框使用无渐变、无阴影的扁平样式；效果标题「清晰度」不附英文。白平衡先选校正方式，自动与恢复／取样按钮逐行全宽堆叠；校正区与微调留出 12 点额外间距；当前采用状态与待操作方式分开 | [原生编辑](../../specs/018-native-editing/spec.md) · [显影控制](../../specs/020-development-controls/spec.md) · [照片调整](../../specs/021-photos-editor/spec.md) · [紧凑检查器走查](../../specs/021-photos-editor/validation.md#紧凑检查器白平衡与蒙版) |
| [HDR 原生阶段评审](prototype/index.html?sceneNativeReview=1) → 选「岸边的水鸟」→ 编辑 → 基础 → HDR | 确认工作表显示本张照片，支持 Tab、确认以及取消或 Escape 返回模式按钮；提交节点曝光、撤销恢复旧 SDR 草稿；切换 HDR 目标／SDR 派生只改变查看，失败重试与离线原因留在本张。原生随 Release 默认显示，`RAWMASTER_EXPERIMENTAL_SCENE_DARKROOM=0` 仅用于诊断时隐藏；实际屏幕余量由 AppKit 读取。原型使用模拟状态。 | [037 阶段规格](../../specs/037-color-film-hdr/spec.md#原生场景查看的阶段走查) · [阶段走查](../../specs/037-color-film-hdr/validation.md#原生场景查看与显影阶段) |
| [HDR 示波器阶段](prototype/index.html?sceneNativeReview=1&scopesNativeReview=1) → HDR 草稿 → 示波器 | 切场景／目标输出／SDR 派生，锁定或重选采样点。Escape 可取消采样及诊断叠加。分别查看传感器饱和、目标和屏幕余量。 | [037 示波器](../../specs/037-color-film-hdr/spec.md#hdr-示波器与诊断阶段走查) · [阶段证据](../../specs/037-color-film-hdr/validation.md#hdr-示波器与诊断) |
| [HDR 解码运行库失败模拟](prototype/index.html?sceneNativeReview=1&sceneRawRuntime=unavailable) → 水鸟 → 编辑 → 基础 → HDR | 确认创建后提示运行库不可用，从同一草稿关闭提示或重试。合格原片的运行库故障有独立原因。 | [037 阶段规格](../../specs/037-color-film-hdr/spec.md#原生场景查看的阶段走查) |
| [暗房右栏 → SDR／HDR／B&W](prototype/index.html#edit/basic)／主图／示波器／032 导出 · 完整目标原型（模拟） | 「当前节点」是独立上面板。仅「基础」顶部有模式分段和「色彩与输出」，与示波器用细线分隔；不可用原因在主图提示，作品版本无可写模式或节点控制。切换只改本张草稿，不改 Graph 选择；离开 HDR 需确认，可撤销。「岸边的水鸟」可试扩展直方图、独立屏幕余量标线、HDR 高光限制、诊断和内联 SDR 派生；查看不改模式或交付，032 仍使用同一选片和冻结版本。 | [037 交互规格](../../specs/037-color-film-hdr/spec.md#camera-raw-对照与-rawmaster-交互决策) · [分区走查](../../specs/037-color-film-hdr/validation.md#右栏色彩模式与节点面板分区) |
| 照片底部 → [Mask](prototype/index.html#edit/masks) / Remove；节点检查器 → 细节 | 启用 Graph 后，Mask 常驻显示拥有者，类型和组件恢复语义图标；强度、羽化用滑杆和精确输入，范围与引用按类型出现，细化与诊断折叠。Remove 用四个带图标的方式按钮和两个滑杆；待取样、生成和重试按状态出现。未启用 Graph 时保留兼容图层菜单，以图标配文字选择主体、背景、实例、画笔、线性／径向或亮度范围；类型图标同步用于旧图层列表。添加／减去、采用／关闭、查看与修正、排序和删除均有语义图标，叠加显示与眼睛启停各自独立。画布拖动几何选区，AI 叠加预览经采用才进图层。图层可启停、排序、删除、撤销；选中后可细化选区及局部光效、颜色和细节。修复可标点，仿制另选取样点。兼容显影中的 RAW 细节、降噪与超分示例任务保留；启用图后不将源处理或模型任务当作任意 Corrector 的参数 | [蒙版模块](../../specs/026-mask-ai-native/spec.md) · [RAW 集成](../../specs/027-mask-ai-raw-integration/spec.md) · [修复](../../specs/029-repair-tools/spec.md) |
| 左栏 → 滤镜、快照、历史 | 左右栏控件与说明共用检查器规范；参数滑块及内嵌数字输入保留键盘输入但不绘制蓝色聚焦边框。滤镜标题右侧仅放复位、圆形启停和「…」；保存当前设置、导入和导出都在「…」菜单，标题下保留搜索与强度。[标题区与聚焦走查](../../specs/021-photos-editor/validation.md#无聚焦边框与滤镜标题区)。Adaptive 和九款胶片模拟排在 Imported 前，子目录保留原分组。胶片注明 Spektrafilm 官方模型与 SDR 色彩外观，不宣称社区作者 Look、颗粒或 HDR 支持。预设与快照悬停或聚焦时在主画布试看，点击后采用或恢复；移除和撤销保留其他调整。失焦只结束试看 | [滤镜体验](../../specs/028-filter-experience/spec.md) · [预设目录与交换](../../specs/031-preset-browser/spec.md) · [九款目录走查](../../specs/031-preset-browser/film-catalog-validation.md) |
| [智能编辑 → 智能预设](prototype/index.html#edit/smart) | 新进暗房默认显示此面板。人像、风光、纪实共七种意图，核对作用范围或组照参考张后明确采用 | [场景卡](../../specs/030-ai-retouching/scene-presets.md) · [界面规格](../../specs/030-ai-retouching/ux-design.md) |
| [底部「Prompt」](prototype/index.html#edit/development) · 设计预演 | 从大输入区写提示词，点圈选或全图，可通过更多圈选操作复用蒙版。用紧凑模型按钮切换本机或云端，继续发送复核、候选对比和撤销。离开可从本张或任务返回 | [034 规格](../../specs/034-quick-prompt-editing/spec.md) · [走查](../../specs/034-quick-prompt-editing/prototype-review.md) |
| 智能预设 → 交互式创作 → [Agent 对话](prototype/index.html#edit/agent) | 发送要求、补充意图、审阅本张对话及执行位置，再发起模拟任务。可回到智能预设，也可换片后回来续写。严格纪实限制内容改写 | [AI 摄影工作流](../../specs/008-ai-photography-workflow/spec.md) · [场景精修与研发阶段](../../specs/030-ai-retouching/spec.md) |
| 照片标题栏 → [作品版本](prototype/index.html#edit/versions) / [制作任务](prototype/index.html#jobs) | 草稿保存为独立初修候选。查看、保留、放弃、恢复、采用或从版本继续，外部 TIFF 返回后登记候选。任务可取消、重试、模拟中断并核对原任务结果，回到对应照片 | [版本与交付](../../specs/023-effects-delivery/spec.md) |
| [统一导出](prototype/index.html#export) / [专项大批量样本](../../specs/032-export-workspace/prototype.html) | 从选片、编辑草稿或采用版本进入同一面板。成片/原件/仅清单，JPEG/TIFF/PNG、尺寸与质量、模板与重名、EXIF/GPS、水印边框、预设保存/导入/分享、独立目的地。逐项预检、接回、取消、重试和结果。提交成片后可关闭任务详情并返回原视图，交付继续。200 张可提交，201 张显示超额并保留勾选。1,200 张可筛选与分批 | [导出规格](../../specs/032-export-workspace/spec.md) · [批量范围与早期实测](../../specs/032-export-workspace/batch-limits.md) |
| [032 PQ 队列评审](prototype/index.html?pqReview=1) → 暗房保存 HDR 候选 → 导出 → HDR 成片 | 逐张核对已保存版本和原片；没有母版或离线时取消并改选，不隐式交付 SDR。此阶段仅全尺寸 AVIF 10 位 Rec.2020/PQ，预览明确为 SDR 代理；提交、任务恢复和回执复用 032。完整多目标和水印仍待验收。 | [037 交互](../../specs/037-color-film-hdr/spec.md#032-pq-原生队列评审) · [原生回读与中断走查](../../specs/037-color-film-hdr/validation.md#032-pq-队列与回读) |
| 导出 → [任务详情](../../specs/032-export-workspace/prototype.html) / [制作任务](prototype/index.html#jobs) → 查看本批交付 | 接回目录时核对提交时的卷和目录身份。同路径的另一卷仍离线。原卷以新设备号重挂后，先按原票据认领已发布文件，明确继续才写余项。可逐张接回原片、核对同名冲突、取消余项，并返回改选后的照片 | [中断、卷重挂、继续和取消走查](../../specs/032-export-workspace/batch-continuation.md#走查) · [原生重启回执](../../specs/035-portable-processing-cores/evidence/workbench-native-restart.json) · [APFS 重挂回执](../../specs/035-portable-processing-cores/evidence/workbench-apfs-remount-batch13s.json) |
| [设置](prototype/index.html#settings/general) / [本机 AI](prototype/index.html#settings/runtime) / [诊断](prototype/index.html#settings/diagnostics) | 跟随系统/浅/深外观、存储、编辑与预览、FLUX 模型首次下载与暂停/续传/校验/删除、实验性 Qwen 运行时、云服务启停、诊断摘要、性能监控入口。环境未就绪时从 Quick Prompt 转入设置，再返回同一张照片 | [本机模型设置](../../specs/034-quick-prompt-editing/local-ai-setup.md) · [外观与图标](../../specs/003-app-icon/spec.md) · [图像交互性能](../../specs/002-image-interaction-performance/spec.md) · [显示代理](../../specs/024-jpeg-display-proxy/plan.md) |
| [Server 规划预演](prototype/index.html#tools/server) | 逐步推演归档、Direct／Relay、外部冷备下的元数据恢复、单客户端所有权与接续、证书／令牌恢复。当前原生交付范围为本地资料库，Server 待立项 | [Server 1.0 功能设计](../../specs/040-server/spec.md) · [Server 图像编辑](../../specs/041-server-image-editing/spec.md) · [现有产品验收](../../specs/033-library-lifecycle/server.md) |

[编辑翻片与资料库胶片带走查](../../specs/025-editing-workspace/prototype-review.md#编辑翻片与资料库胶片带) · [滤镜与快照、调整和 Prompt 走查](../../specs/025-editing-workspace/prototype-review.md#胶片带与调整面板)

## 界面规范

行高、间距、字级、圆角、墨色和控件四态由 [039 界面规范](../../specs/039-design-system/spec.md) 约束。新控件先在画廊登记，再落原生。

| 从哪里进入 | 可以走查的动作和结果 | 对照规格 |
| --- | --- | --- |
| 资料库工具 → [界面规范](prototype/index.html#tools/design) | 核对行高、间距、字级、四态与检查器版式。操作滑杆、非法数值、勾选、分段、菜单与分组折叠；浅色、深色与 390pt 窄窗下版式不重叠 | [039 界面规范](../../specs/039-design-system/spec.md) · [原生证据](../../specs/039-design-system/validation.md) |

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
