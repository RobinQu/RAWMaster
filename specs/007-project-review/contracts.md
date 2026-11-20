# 007 · 协作与跨层合同

本对话在主checkout实施App/非Sequence Core；原对话在`.slim/worktrees/metadata-sequences`继续元数据/暂停桥接研究。已同步边界，不修改其工作树、Sequence*、Probe、旧fixtures、005或事件级评价基线；不将未提交006文件擅自提交到实验分支。

Core负责过滤语义、成员守卫、review与项目state、标签preview/commit/restore；App负责用户当前范围/匹配可见选择、保存/恢复时机。两者共同确保标签预览的目标与实际动作一致。App不新增第二个标签数据库或用UserDefaults保存权威review记录。

Imaging显示、RAW实际来源、配对折叠和006初筛职责继续沿旧合同。更新查询不启动解码任务；图像pipeline缓存不以查询字符串为键重复存图。分组的新结果未来进入006的关系接口，不改变本轮查询的来源可信规则。

Core API冻结后记录准确名称与数据迁移。所有状态/标签操作在存储层验证当前项目/admission，不能仅靠按钮禁用提供安全边界。

实现接口：`ProjectSearchQuery`/`AssetSearchEngine.filter`/`ReviewProgress.calculate`，`loadReviewRecords`/`markReviewed`/`loadProjectReviewState`/`saveProjectReviewState`，`previewTagMutation`/`commitTagMutation`/`undoTagMutation`。导出既有接口增可选`allowedAssetIDs`，nil保持旧调用兼容；App将当前匹配集合冻结传入，Core同时限制ids、manifest与伴随扩展，JSON/CSV保存请求范围。搜索本身不要求事件级分组实验变化。

## 搜索UX修订的App合同

Core类型/API和schema5均不变。App增加按需工具栏搜索、右筛选面板及键盘ownership等暂态UI状态；面板显式范围切换仍先保存离开项目状态，sidebar A/B仍分别恢复。查询编辑复制当前effectiveQuery、验证后原子应用，结果缓存/选择/标签预览/导出范围沿用原007。局部无效文本不进入Store，范围/外部查询变化后同步；收起不等于清除，清除不更改评分/审阅/标签/组。
