# 006 · 数据合同

## 独立维度

- ImportSession：来源与文件接入进度保持原义。
- SessionWorkflow：业务阶段、目标项目、来源是否封存、修订、关闭时间与完成记录；旧会话独立标为legacyUnknown。
- TriageDisposition：每文件待审/通过/排除/需复核、来源与修订；不覆盖AssetRecord.decision/rating。
- CapturePair：同次拍摄的RAW/JPEG文件ID、有依据的来源、人工确认/解除保护与修订；每文件最多一个有效配对。文件身份、hash和故障不合并。
- ProjectAdmission：会话文件是否正式纳入、正常/仅序列角色，关闭与历史恢复记录。旧项目资产视为既有成员；新暂存成员不可经全库、组或导出旁路出现。
- QualityEvidence：资产及内容版本、预览来源/算法版本、risk/unknown/unsupported/error、可解释指标；机器证据与人工处置分离。
- AssetTags：独立用户标签，不写源文件，不由初筛重置。

实施结构为schema 4；新增session_workflows、project_admissions、triage_records、capture_pairs、pair_dismissals、triage_commands、quality_evidence、asset_tags、workflow_completions。每表以实体ID为主键，data保存版本合同的JSON，复用同一连接/事务。旧v1/v2先沿原迁移至v3，再进入v4；新库直接建立完整结构。升级前仍使用SQLite backup包含活动WAL。

公开合同见`Sources/RAWMasterCore/TriageModels.swift`和`LibraryStore+Triage.swift`：loadWorkflows/loadAdmissions/loadTriageRecords/loadCapturePairs/loadQualityEvidence/loadTags、updateTriage/undoTriage、scanCapturePairs/confirmCapturePair/unlinkCapturePair、previewCompletion/commitCompletion/restoreArchivedAssets、exportSelection。应用通过ImportService的initialScreening入口启动；原底层调用保留兼容默认供既有集成使用。

项目身份全程稳定：新项目用draft隐藏，已有项目的待初筛资产由独立纳入集合隔离；完成不得重写asset/group的projectID，避免损坏既有组命令与恢复历史。常规项目、全库、组视图和ExportService均执行同一纳入守卫。

## 纳入事务

摘要绑定会话、文件集合/状态、内容身份、人工处置、配对、组关系与质量证据版本。任何影响纳入的变化使旧摘要拒绝；操作幂等键绑定其摘要与选择，不能同键不同请求静默成功。完成时同时写纳入集合、目标项目可见状态、关闭业务状态与记录。失败全部回滚。关闭检查无活动接入，旧saveSession/登记/恢复调用不能把关闭会话改回活动。

必要序列成员根据其用途/参与记录保护；普通单张拒绝不能破坏必要输入。历史恢复只增加尚未纳入的成员，不重置精筛字段。已关闭会话拒绝继续扫描修改其封存集合，追加来源创建新会话。

## 旧库

沿用DatabaseSchema只读识别→一致备份→事务升级。旧project/asset/selection/group不重写语义。已完成旧文件任务不伪装为已初筛，未完成任务可恢复。未知/更高版本结构继续拒绝且不写原库。
