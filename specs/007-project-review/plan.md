# 007 · 实施与所有权

先冻结合同并独立审查，再进行Core/App两条有边界的实现。当前main保留006未提交代码，自动分组在独立工作树；不创建新分支/合并或移动其文件。

1. Core增加SearchReviewModels/AssetSearchEngine/LibraryStore+ProjectReview，schema5独立表保存review、project view state与标签命令/版本域。复用DatabaseSchema只读检查与SQLite一致备份；旧字段/历史语义不改。
2. 检索以已加载元数据为基础，明确归属/成员守卫、AND条件及配对成员语义；排序有稳定tie-break，组关系只读。新查询/词表缓存按输入变化失效，不在逐卡绘制重复全库查找。
3. 标签新add/remove/replace API统一预览/提交/持久恢复，旧setTags仅为兼容显式replace且更新同一版本域，防止旧API绕过新CAS。恢复使用逻辑写者与单调revision，复用006因果经验。
4. AppModel消费冻结Core合同，新增SearchReviewViews，项目/全库显示组合条件与匹配计数。初筛/历史继续原职责；结果改变主动协调选择，操作只覆盖清晰可见的范围。
5. 每项目状态由Store持有，正常切换/退出刷新，恢复验证引用有效性；UserDefaults全局入口仍兼容。已审是独立持久记录，不用rating或last focus推断。
6. 增量验证与源码审查后串行完整测试/发布构建/原同机性能门/隔离窗口，文档回填。不得用大量镜像单测代替组合边界、恢复、迁移、冲突与用户闭环验证。

所有权：Core worker独占非Sequence的Core/迁移与Core测试；App worker独占AppModel/视图与UI行为测试；root维护规格/索引/进度及集成；oracle只读审查。Core先冻结公开API再让App调用，不独立猜第二套状态。现有Imaging、Sequence、Probe、fixtures和005全不修改。

用户随后明确要求：完成实现/测试/验收后生成Release并更新`~/Applications/RAWMaster.app`，保留现有资料库和偏好。先完成隔离验证，再暂存并核验应用、备份现有安装、替换应用包；如当前应用运行则正常退出以保存状态。安装过程不重置或打开真实资料库；核对安装前后库/偏好不变。用户未要求Git提交/推送。

## 搜索体验追加实施（2026-10-24）

designer与oracle已批准图片优先方案，详见[交互](ux.md)和SR07–12。唯一App实现者改SearchReviewViews/WorkbenchView/AppModel搜索UI状态与guard/RAWMasterApp命令和相关UI测试；原引擎缓存、schema5、项目CAS、动作范围/allowed export保持。root负责规格及集成，designer复核视觉意图，oracle只读评审阶段与最终源。Core/Imaging/Sequence/fixtures/008不写，保护hash冻结。

搜索开合、筛选面板、焦点请求与键盘ownership是临时App UI状态，不新增持久字段；有效query仍是Store项目状态权威。控件原子校验再改query，局部无效输入按范围/外部query变化重同步。panel显式scope变更可带合法query，先保存离开项目；sidebar切换保持独立恢复。

定向验证输入即时/无Apply、chip独立删除、清空及query合法性、A/B/重启、modal/初筛guard、键盘ownership和photo释放；之后普通回归/Release/隔离真实窗口（默认高度、1100窄窗、明暗、⌘F/Esc、双格式范围）及既有性能门。开发验收用独立bundle和资料库，完成后沿用保留旧包/一致库备份/prefs核对的用户Applications更新安装。
