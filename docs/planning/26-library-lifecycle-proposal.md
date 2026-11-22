# RAWMaster 资料库生命周期方案

2026-11-22 · 已确认的方案与交付顺序。资料库包含摄影师长期持有的照片、组织关系和作品版本。原片可以在本机、外置盘或 RAWMaster Server。用户从同一张照片可查位置、所属拍摄、处理结果和备份状态。具体要求和验收以正式规格为准，上轮单点问题单独记录。[资料库生命周期规格](../../specs/033-library-lifecycle/spec.md) · [资料库现状评估](25-library-workflow-review.md)

## 1. 建库、迁移与恢复

**建议默认由应用管理命名资料库，同时提供可移动的资料库包。** 首次启动即可导入。在“资料库设置”里可以查看位置、选择其他磁盘、迁移、备份和恢复。包内封装目录数据库、版本清单及必要的编辑资源。原片可受管或原地引用，多个盘可属于同一库。现在已有默认 SQLite 库、原地引用和复制校验。Lightroom Classic 的目录搬迁涉及目录、附属数据与预览，原片也需要独立的备份安排。[当前存储行为](../../README.md#使用) · [Adobe 目录搬迁](https://helpx.adobe.com/lightroom-classic/desktop/manage-catalogs-and-files/create-catalogs.html) · [Adobe 目录备份](https://helpx.adobe.com/lightroom-classic/desktop/manage-catalogs-and-files/back-catalog.html)

备份界面提供“仅目录与编辑资料”和“含原件的完整备份”，预先列出覆盖的卷、离线缺项与空间。应用生成同一时点的目录快照及内容清单，支持增量复制。换机时先恢复目录，再整卷重定位并按内容校验。照片、文件内容、存储位置分别有身份，同一个 RAW 在两个盘上有两个位置，一个 RAW 的两个虚拟副本也能保留各自的编辑与集合关系。

**100 TB 先按文件数设计查询，再按字节设计归档。** 按十进制、每文件平均 50 MB 估算，100 TB 约有 200 万个原文件，RAW+JPEG 会让文件数与拍摄数不同。当前普通刷新会读取整库快照，照片筛选还在 Swift 数组中执行。建议保留本机 SQLite，把常用 EXIF、评分、集合成员及位置拆成可索引字段，在数据库内筛选、排序、统计和分页。原始提取值与人工修改保留来源。全文、地理和语义搜索分别建立可重建的文本、空间和向量索引。缩略图及索引按变更增量更新。[当前目录读取](../../Sources/RAWMaster/LibrarySnapshot.swift#L28) · [当前检索](../../Sources/RAWMasterCore/AssetSearchEngine.swift#L13) · [数据库与同步研究](08-local-database-and-sync-evaluation.md)

前三阶段先在现有照片和目录上测首次打开、筛选首屏 P95、导入期间的查询时延、峰值内存和索引占用。常用结构化筛选温态首屏的目标为 300 ms。另测中断导入后续跑、坏块校验、索引重建和整库恢复，对账原件哈希、人工决定、版本与集合关系。百万级和 100 TB 压测留待后续容量专项。[前三阶段技术方案与实测范围](../../specs/033-library-lifecycle/plan.md)

## 2. Server 归档、冷热数据与远程计算

建议服务器用对象存储按内容哈希保存不可变的原件与成片，用事务型目录数据库保存照片、集合、配方、版本和各位置的副本。客户端以稳定 ID 引用这些对象。备份清单把同一代目录快照和引用的内容版本关联起来，可以指出具体哪一张照片、哪一份编辑资源尚待备份。

| 用户操作 | 建议行为 |
| --- | --- |
| 开启服务器全量归档 | 归档正式纳入且已核验的原件，以及编辑资源、成片、关系和历史。**导入时最终排除的原片不进入全量归档。** 保留排除记录与已有内容身份。必要帧可明确改为“仅序列用途”纳入，仍排除的只提示缺口。历史恢复依赖仍可找到并核验的原件，显式恢复后才取得新的归档资格。 |
| 在笔记本浏览冷照片 | 客户端保存目录，近期 RAW 自动缓存，可固定照片、项目或整组供离线使用。冷照片浏览使用 JPEG 代理，按容量预取、按需取得，也可固定。即使只有 100 万张、每份代理 1 MB，全部常驻也约占 1 TB。界面分别标出本地原件、代理可用、需联网和备份状态。 |
| 打开原始细节或释放空间 | 可显式取回完整 RAW，支持断点续传和内容校验。自动释放仅作用于应用托管、未固定的本地副本，先验证服务端原件可回取且有独立备份。引用的外置盘由用户管理。归档主存、独立备份和定期恢复校验分别记录。 |
| 离线整理、重连 | 无服务器也能建库和工作。多设备交换带版本的操作和对象清单，客户端各自维护数据库。独立字段修改可合并，同一决定有冲突时保留双方记录，配方冲突保留为版本分支。 |
| 将 AI 或批量作业交给 Server | 本地与服务器使用同一种任务描述，固定输入内容版本、顺序、配方、引擎和模型。服务器用自己的 CPU/GPU 读取已归档原件，只补传缺少的输入。支持取消、重试与查询进度，断线重试只登记一次结果。任务完成后将新版本或新成片登记回库，客户端可先取预览。 |

存储、同步和计算可分期交付。首期就为副本、操作、作业及产物预留稳定身份，随后用“服务器归档 → 清理本地受管缓存 → 换机恢复 → 同一作业断线重试”验收整条链。[既有客户端与服务端规划](04-client-server-workflow-draft.md)

## 3. 导入、配对和会话封存

- **一次会话只完成一次。** 退出、断电或暂停后续接同一会话，保留扫描清单、已校验文件和人工决定。完成时原子封存本次输入与初筛结果。当前实现已经拒绝向已关闭会话写入，“打开历史”和“恢复到项目”仍然可用。建议将入口明确为“继续未完成的导入”“查看导入记录”“从此来源再次导入”。最后一项新建会话，可关联上批记录。[会话复用与关闭保护](../../Sources/RAWMasterCore/LibraryStore+Triage.swift#L27) · [完成与历史恢复](../../Sources/RAWMasterCore/LibraryStore+Triage.swift#L301) · [应用中的续接条件](../../Sources/RAWMaster/AppModel.swift#L1892)
- **按一次快门组织照片，按文件管理原件。** 现有配对限同会话，组成员存文件 ID，延时合成另行折叠已确认的 RAW+JPEG。建议给一次拍摄稳定身份，RAW 与机内 JPEG 是它的两个原件，可展开、各自恢复和交付。连拍、间隔拍摄等有序组引用拍摄，一次快门在一个组里只计一帧，同一次拍摄可用于多个组。例：第二次导入才到的 JPEG 可以补到原拍摄，两次导入记录都能追溯。[当前配对边界](../../Sources/RAWMasterCore/LibraryStore+Triage.swift#L198) · [当前组成员](../../Sources/RAWMasterCore/Models.swift#L85) · [延时选帧](../../Sources/RAWMasterCore/TimelapseModels.swift#L113)
- **扫描结果可解释、可纠正。** 后台增量读元数据，先处理配对，再用相机身份、子秒时间、帧号和拍摄间隔判断序列。重名、多机同秒、跨卡边界或证据冲突时呈现待复核建议。人工确认、拆分、锁组及帧顺序随库保存。重新分析只提交差异，封存后的纠正记为资料库操作。重复导入可复用已核验内容，仍记录本次来源和项目选择。[自动分组运行时](../../Sources/RAWMasterImaging/RuntimeAutomaticGrouping.swift#L48) · [现有组操作](../../specs/015-group-editing/spec.md)

## 4. Lightroom Classic 迁移、资料库面板与搜索

| 工作流 | 当前差距与建议 |
| --- | --- |
| 文件、集合和虚拟副本 | 现有项目、拍摄组和文字标签不能完整承载一个旧目录。补多卷文件夹树、整树重连、带伴随文件的移动／重命名，以及“从资料库移除”和“删除受管文件”两种动作。补普通集合、集合组及层级、手动顺序、智能集合、虚拟副本。Lightroom 堆栈保留其文件夹或集合范围、封面和顺序，作为原有的整理方式导入。摄影拍摄组另存识别依据。[Adobe 集合](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/photo-collections.html) · [Adobe 堆栈](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/grouping-photos-stacks.html) |
| 单向迁移与对账 | 从一致的目录副本盘点原件及可用的 `.lrcat-data`、XMP、ACR、预览。迁移评分、旗标、颜色标签、分层关键词、IPTC、GPS 与组织关系。智能集合保留规则和当时的成员快照。虚拟副本逐个保留，Adobe 专有显影设置连同可得的 Adobe 渲染外观封存。用源目录和源对象身份支持重复执行。报告按类型核对数量、关系、缺失文件、仅封存项和无法等价执行的规则，离线原片可稍后重连。[现有迁移规划](02-feature-portfolio-draft.md#f008-lightroom-历史库接入) · [Adobe 元数据](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/metadata-basics-actions.html) · [Adobe 伴随文件](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/create-xmp-acr-files.html) |
| 单张检查与选片 | 普通资料栏已有基本文件信息，比较视图已有 15 个字段及预览 RGB 直方图。先把常用 EXIF、直方图及其来源、可编辑 IPTC、分层关键词和多选批改放到资料库网格／单张也能用的检查器。单张支持相机 AF 点叠加。再补多张总览选片（Survey）和人物视图。快速显影、发布服务及评论列为较低优先级。[当前资料栏](../../Sources/RAWMaster/WorkbenchView.swift#L720) · [当前比较视图](../../Sources/RAWMaster/ComparisonViews.swift#L276) · [Adobe 资料库视图](https://helpx.adobe.com/lightroom-classic/help/library-module-basic-workflow.html) · [快速显影](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/using-quick-develop-panel.html) · [发布与评论](https://helpx.adobe.com/lightroom-classic/desktop/export-photos/prepare-send-or-post-photos.html) |
| 结构化过滤与关键字 | 现有文件名、机型、日期、星级、标签等条件可复用。补文本、属性和可选元数据列，覆盖镜头、焦距、ISO、光圈、快门、格式、版权、拍摄地点、编辑／导出状态等。支持按库、文件夹、项目、集合限定范围，组合条件、查看分项计数、保存为智能集合。精确文字可查文件名、标题、说明、关键词与 IPTC。Adobe 的元数据过滤支持最多八个可选列，可作为交互参考。[Adobe 资料库过滤](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/finding-photos-catalog.html) · [Adobe 关键词](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/keywords.html) |
| 按画面、人物和地理围栏找图 | 文搜图用文本与图像向量匹配，能找到未写标签的内容。人物支持检测、人脸聚类、命名、合并、拆分和纠错。GPS 支持半径和多边形、保存围栏以及单独筛出无坐标照片。三种能力与结构化条件可叠加，如在某湿地围栏内，选“四星以上”和已确认的人物，再搜“红色雨伞”。展示已索引范围、离线覆盖和重建进度，模型重建保留人工命名与纠正。人物索引由库所有者开启。[Adobe 人物视图](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/face-recognition.html) · [Adobe 地图与半径地点](https://helpx.adobe.com/lightroom-classic/desktop/maps/maps-module.html) |

## 5. 连拍判断和分组制作

**连拍优先进入比较选片。** 相机记录的 AF 点回答“相机对在哪里”，主体或眼部清晰度回答“成像是否清楚”。Adobe 的 AF 点查看适用于记录了相应信息的佳能、尼康、索尼原始 RAW，辅助选片另行评估主体和眼部。RAWMaster 已在分组分析中读取部分索尼对焦字段，初筛有基于预览的低细节提示。建议新增资料库级的对焦点查看与清晰度属性，保存观测区域、依据、置信度和人工复核。算法可给出清晰、疑似失焦或无法判断，用户可确认、纠正并筛选。夜空、运动拖影及低对比场景单列验收。标记后仍可导入和参与序列。[当前对焦元数据](../../Sources/RAWMasterImaging/RuntimeSequenceMetadata.swift#L69) · [当前初筛质量分析](../../Sources/RAWMasterImaging/TriageQualityAnalyzer.swift#L75) · [Adobe 对焦点](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/view-focus-points-in-photos.html) · [Adobe 辅助选片](https://helpx.adobe.com/lightroom-classic/desktop/organize-photos-in-lightroom-classic/assisted-culling.html)

**建议在现有“编辑”里增加分组状态。** 从资料库对组执行“制作”，首次列出全组，默认勾选全部参与拍摄，保留用户已明确停用的成员。显示缺帧和离线情况，允许调整本次顺序与参与范围。一对 RAW+JPEG 默认优先用 RAW 制作，需要用机内 JPEG 替代时明确提示。开始制作时冻结输入，每次完成登记一张新照片或一段新视频，关联源组、实际输入、顺序、配方和引擎版本。成片能检索、导出、反查原始帧，也可按媒体类型继续制作。此后调整组成员，可按新输入另做一个版本。

| 类型 | 实现情况和建议顺序 |
| --- | --- |
| 延时视频 | 已有真实 RAW 到 H.264／HEVC MP4 的预览、导出及读回验证。当前导出记录输出路径。优先打通“成片入库、返回源组、重新制作”，用现有合成器验证整个设计。[合成出口](../../Sources/RAWMaster/TimelapseComposer.swift#L108) · [既有验证](../../specs/010-timelapse-video/validation.md) |
| 星轨 | 待实现。接在延时之后，验收长序列叠加、缺帧导致的断轨和前景处理。[既有制作路线](16-ai-native-photography-workflow.md) |
| 多曝光 HDR | 待实现。以曝光包围组为输入，验收对齐、运动去鬼影和高动态范围结果。[Adobe HDR 合成](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/hdr-photo-merge.html) |
| 全景 | 待实现。验收重叠匹配、投影、接缝、裁切及失败时的修正。既有路线中的景深合成继续作为独立专项。[Adobe 全景合成](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/panorama.html) · [既有制作路线](16-ai-native-photography-workflow.md) |

## 6. 已确认的交付顺序

1. **目录与导入基础。** 建立可迁移的资料库、拍摄／文件／副本身份、可恢复的导入与索引分页。用现有目录、真实原片和一次异地还原验收。在本地数据与作业中保留跨平台身份及版本。
2. **日常管理与迁移。** 补文件夹、集合、检查器、结构化检索、连拍清晰度复核。用含离线盘、堆栈、智能集合、虚拟副本与旁车文件的真实 Lightroom 样本做迁移对账。
3. **制作与智能查找。** 先让延时成片回库，再推进星轨、HDR 和全景。并行交付地理围栏、文搜图、人物聚类，分别验证查询精度、人工纠错和索引更新。
4. **Server 交付。** 待后续启动 Server 方案时，存储先完成全量归档、独立备份、冷热调度和异机恢复，再接通远程 AI／批处理。

已确认默认由应用建库并提供可搬迁的库包。Lightroom Classic 首版以组织关系、元数据和可获得的历史外观验收，Adobe 专有显影参数原样封存。[存储与 Server](../../specs/033-library-lifecycle/server.md) · [Lightroom 迁移](../../specs/033-library-lifecycle/lightroom-migration.md) · [资料库检索](../../specs/033-library-lifecycle/search.md)
