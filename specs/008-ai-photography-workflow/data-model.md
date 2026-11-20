# 008 · 数据与版本设计

规划合同，字段/类型名为拟议领域模型，不代表已存在的Swift API或数据库表。实施前与006/007当前代码冻结名称和迁移版本。

## 已有对象与独立维度

- AssetRecord、Content、Replica继续标识原文件；CapturePair只表达同次拍摄的两个文件。每个制作输入明确到单文件，不把两个文件的证据/参数混合。
- ProjectAdmission是项目制作/导出守卫。SessionWorkflow、TriageRecord、ReviewRecord、评分/标签由006/007负责；制作状态不反写这些对象。
- CaptureGroup/成员及005试用来源只读；人工组与自动候选均可提供上下文。质量结果与制作输入分别关联组修订，不能把后来变化的成员套到旧证据。
- TriageQualityEvidence当前按assetID覆盖有限结果；深化需要同一quality_evidence权威域的兼容演进，支持多方法/区域/内容版本，而非另建平行质量决定。旧preview-v1原义保留；投影读取可继续兼容旧loadQualityEvidence，具体接口在T01冻结。

## 新对象

| 对象 | 最小内容与约束 |
|---|---|
| InputSnapshot | projectID、assetID、hash/size/内容修订、可读位置引用、纳入角色/修订、pair/组修订、选用格式；时间和原顺序按来源保留 |
| QualityEvidence扩展 | 方法/版本、输入快照、ROI与坐标变换、源层级、指标/置信适用性、风险/未知/不支持/故障、组内比较对象；RAW额外记通道/黑白电平/归一化与缺失 |
| Work | 项目内作品身份、源输入引用及revision；首轮恰一个源文件，同一原片可创建不同作品，未来可扩展多输入但本轮拒绝多图运行 |
| EditVersion | workID、不可变versionID、parentVersionID、kind(base/AI/external)、inputSnapshot、recipeID、依赖指纹、创建时间；禁止环及跨项目父引用 |
| DevelopmentRecipe | 方向/几何/裁切、曝光/白平衡、相机和镜头profile ID/版本、已应用校正、引擎、工作色彩与参数来源（自动/手动/未应用） |
| StyleRecipe | 模型/权重指纹、运行时、适配器与兼容组合、Prompt模板/最终Prompt、参考内容身份、强度、支持时ROI/seed；不把seed当可重现证据 |
| RenderArtifact | versionID、档案路径、hash、实际像素/ICC/编码位深、有效源位深、模型原生像素/位深、重采样/超分链；可执行重现与仅留档独立标记 |
| Adoption | workID→versionID与单调revision、逻辑写者；采用/恢复为有因果关系的命令，不等于用户已审或入选 |
| ProcessingJob/Attempt | commandID/请求指纹、stage、冻结输入/配方、执行位置/能力版本、运行身份、输出引用、状态、取消意图、对账状态、资源与可选费用状态 |
| ExternalEditSession | 源version/input、应用、工作副本/sidecar隔离位置及hash、显式回流结果、父引用；外部修改不覆盖档案 |
| RenderExportPlan/Item | 冻结版本及artifact、输出参数/位置/命名/冲突策略/项目成员快照；逐项状态、临时路径、最终hash/元数据、重试与失败原因 |

## 状态

任务：queued→running→succeeded/failed/cancelled；依赖缺失为waitingInput；执行进程/连接丢失为outcomeUnknown→reconciling→明确结果或needsAttention。取消意图不等于远端/本地native调用已终止；未汇合之前不释放同一资源预算。

费用/计量：notApplicable（本地货币费用）、estimated、pendingReconciliation、confirmed、unknown；处理状态与计费状态独立。首轮本地记录时长/资源，后续远端不能用失败状态推断未计费。

作品版本内容不可变；采用指针可变。生成成功只新增候选，不切换采用。上游编辑创建新父分支，旧下游继续引用原输入并可显示与当前分支不同；原始内容失配时禁止执行，仍可查看已有档案。

## 保留与恢复

预览缓存可再生成；已采用版本、仍有依赖的候选及外部结果属于制作档案。只有用户明确放弃且无引用的候选可清理，先检查依赖闭包。生成不可复现时已有档案尤其不能被普通缓存策略回收。

资料库备份须包含一致SQLite快照及被引用制作档案清单/hash；数据库备份不等于原片/作品字节备份。恢复先在隔离位置对账档案，缺失显示不完整，不能只恢复行后宣称作品已恢复。

## 迁移

本轮不创建schema。实际编码前读取007及005最终合入版本，由Store负责人分配下一版；006质量域在同一迁移链演进。增加制作/任务/导出实体，不改原片资产身份，不将派生作品写成新的RAW/JPEG拍摄成员，不增加原片审阅分母。未知更高schema只读检查并拒绝写入；升级失败回滚且旧库备份可恢复。
