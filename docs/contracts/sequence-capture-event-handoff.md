# 拍摄事件与序列检测交接

2026-10-24。008 元数据研究路径供后续 006 初筛工作流适配使用。当前是离线研究接口，未通过生产质量门；本文件不授权接入自动导入，也不替代 006 已有 `CapturePair` 持久化合同。结果见[元数据实验](../planning/14-metadata-first-sequences.md)。

## 身份与输入

`SequenceCaptureEvents`、`SequenceMetadataEventPipeline` 位于 Imaging，依赖现有 Core 值合同。每个 `SequenceCaptureFileInput` 包含原始顺序的 manifest entry、当前实际读取的 evidence/feature、显式读取失败、内容版本和历史原片元数据。当前文件 SHA 与历史原片 SHA 分开；JPEG 代理只代表本次读取的文件。历史元数据必须经过完整审计、导出和当前内容绑定校验，不能把任意数据库字段包装成已审计事实。

`SequenceCaptureMember` 保留 assetID、ordinal、contentVersion、当前 SHA 和原片 SHA。每个文件必须恰好出现一次，不去重、不隐藏、不重排；关联不能消除不可读、未完成、人工保护、相机来源和时间冲突。固定选择实际 RAW 成员作为代表，读取失败不能靠换成 JPEG 隐藏。

## 建议与确认

`SequenceCaptureProposal` 是证据相容的建议，附完整 scopeSnapshotFingerprint 和成员身份。相同设备、同秒、相同拍摄设置仍可能来自两次曝光；本轮没有原生曝光唯一 ID，不能把建议当成已确认 `CapturePair`。`strict` 只折叠调用方提供的真实确认；`assumeCorroborated` 是独立实验策略，只产生条件指标。

后续适配 `SequenceConfirmedCapturePair` 时，调用方负责核验真实确认来源。captureID、confirmationSource、confirmationRevision、scopeSnapshotFingerprint 和全部成员身份必须持久保存；随意填入来源字符串不构成用户或原生设备确认。当前实样实验传入的确认列表为空。

事件 ID 依作用域、依据、证明和成员派生，两个规则变体不会随意更换相同事件的身份。事件映射指纹另绑定全部元数据、内容版本、哈希、确认修订和策略。成员内容、关联、确认、相机声明或规则变化时，重新分析；提交结果前再次比对原快照。人工解除/保护记忆继续由 006 保存，重跑不得覆盖。

## 输出和提交边界

事件级结果仅是中间产物。`SequenceMetadataEventAnalysis` 同时返回完整原文件 manifest、覆盖、observations、结果 token、eventMap、事件级结果、配置及资源记录。投影必须以完整事件边界还原全部文件，再通过既有 Core 严格验证；跨事件时钟冲突不能通过伪加时间规避。

生产适配需保留可取消和有界执行，在完整作用域内计算差异并原子提交，核验 token、输入版本、映射与人工保护，过期则丢弃。现有研究 API、合成测试或完成任务状态都不等于已完成这套持久化/恢复协议。

只要实际折叠了假设配对，`associationHypothesisAssumed` 必须为 true，顶层质量不能通过，`pairPrecision` 留空；逐文件指标不得偷换成事件指标。0188 归属未知、未标上下文和缺少独立间隔边界的限制继续保留。

自动导入接入仍等待：可核验的配对确认路径、整体质量门通过、新独立完整连拍/间隔样本、生产范围取消/过期/恢复与界面验收。接口与实验结果均不自动关闭这些门禁。

## 009焦点桥接研究补充

新增可选 `SequenceFocusSnapshot` 与 `pauseBridgeExperiment`，默认nil；其绑定指纹包含全部实际焦点DTO、v2元数据及完整manifest，成员或字段变化会使分析失效。450审计行和815范围外行显式区分；范围外不能填假缺失/焦点值。外部应提供完整快照，逐帧上下文由内部验证工厂构造。新规则仅在旧连拍暂停桥接已通过后追加否决，间隔与密集路径保持原样。

已见Sony五组恢复5/5且零新增组内断点；独立任务与DJI确认/终点门仍未关闭。这不授权生产适配或导入接入，原确认来源、过期、原子提交和人工保护合同不变。详见[009记录](../planning/15-metadata-pause-bridge.md)。
