# 007 · 数据与状态合同

- SearchQuery：文件名文本、日期范围/时区解释、机型、星级、标签与any/all、决定、可用性、已审条件。查询输入须验证范围，不将缺失字段填成默认值来匹配。
- ProjectReviewState：projectID、版本、query、sort、mode、focus、比较选择及必要浏览偏好；只布局，不含精筛决定快照。
- ReviewRecord：projectID/assetID、明确reviewed状态与修改时间；只允许正式项目成员，旧记录缺失表示未审。进度按当前成员集合计算。
- TagMutationPreview：命令ID、操作类型、目标集合、before/after/版本、共有/混合与变更摘要。提交只写冻结的集合，不在确认后根据新选择重新展开。
- TagCommand/TagDomain：持久前后值、逻辑写者、单调修订和补偿状态；用于CAS、幂等、跨次恢复和ABA保护。

实施模型位于`Sources/RAWMasterCore/ProjectReviewModels.swift`，schema5增加review_records(asset_id,data)、project_review_states(project_id,data)、tag_commands(id,data)、tag_domains(asset_id,data)。schema4→5须一致备份，v1–v3沿既有迁移路径再进入5。只为旧tag数组建立版本域，不重写标签、评分、组或006工作流。

查询是`ProjectSearchQuery`；`AssetSearchEngine.filter`在调用者明确的已纳入范围执行纯元数据过滤，Store提供`searchAssets`为直接调用补成员守卫。保存浏览状态的`saveProjectReviewState`有revision CAS，布局选中和配对引用会先验证admission；App恢复再按当前查询协调可见选择。

标签公开合同为`previewTagMutation`/`commitTagMutation`/`undoTagMutation`/`loadTagCommands`，`setTags`兼容入口走同一replace版本域。无变化请求可保留幂等收据，但不增加标签revision或可撤销历史项。新增review通过`markReviewed`，精筛决定使用updateSelection的显式markReviewed参数并在同事务写入；旧调用默认不改变审阅记录。

查询与标签以单文件真实身份为基础，CapturePair只是组织/显示/显式动作扩展关系，不能用它混合不同成员的证据。项目布局的旧ID在恢复时验证当前admission及查询；布局恢复不反写review/评分/标签。
