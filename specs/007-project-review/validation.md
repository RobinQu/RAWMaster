# 007 · 验证

2026-10-24。本轮三项实现、Core/App最终静态审查、隔离桌面验收、普通测试及最终正式性能门均完成；Release已更新安装。另一对话的自动分组/005质量不由本轮宣布达标。

## 自动化

- `swift test --jobs 4`：341项、6项既有可选跳过、0失败；日志`output/validation/007-project-review/full-tests.log`。
- 新增Core 17项、App行为14项：逐文件AND/缺字段/配对不跨成员拼条件、时区及DST半开日期、规范化机型/标签、稳定排序；项目状态CAS/A-B切换重启/导入前保存、compare最多4；浏览和旧评分不推断已审、决定撤销保留审阅、组合完整审阅；标签精确预览/独有标签保留/ABA冲突/原子提交/幂等/跨重启LIFO恢复/无操作收据；筛选导出冻结范围及不可扩展隐藏伴随成员。
- 30,000合成元数据、15,000组合的查询与进度在debug一次温态测量约0.12秒，没有读取图片；仅证明元数据计算规模，不冒充30k真实RAW全界面或p95验收。
- schema4升级隔离副本保持旧标签/决定/项目纳入；旧数据不新增推断审阅。迁移回归覆盖原有版本/一致备份。
- Release脚本构建成功，图标资源检查及临时签名完成；后续桌面验收使用该构建独立副本。

## 性能

沿用2026-10-22同机同样本基线、绝对与相对门槛；没有调整阈值。首轮`output/performance/007-project-review-2026-10-24`：原生点击通过，图像测量的四图缩放绘制p95 10.720875ms，高于相对上限10.6524375ms（绝对33.333ms内），因此该轮明确失败。图像/画布源未修改。第二轮`-recheck`同项10.826416ms仍失败，两份报告均保留。

只执行一次现有CanvasIsolationTests诊断，720正式交错样本，旧画布p95 11.118125ms、当前control 10.914208ms；热状态正常、低电量模式关闭，后轮普遍变快。支持共有路径/运行环境/热身贡献，不能证明原因或宣称零回归；诊断不替代性能门。报告`output/validation/007-project-review/canvas-isolation.json`。

诊断后预先限定只做一次最终完整原门，已退出隔离应用并协调另一对话实验窗口。`output/performance/007-project-review-2026-10-24-final/summary.json`为`regression-passed`，与原基线比较、未调整源码/门槛/基线。最终p95：网格选中1.897ms/更新5.988ms，胶片条选中1.320ms/更新4.733ms；内嵌预览27.739ms、原始RAW630.460ms，四图原始RAW比较2123.828ms，四图缩放绘制9.196416ms。最终门通过，前两轮波动根因仍未确定。

## 隔离桌面与安装

测试库与偏好使用独立bundle `io.robinqu.RAWMaster.Validation007`、006测试库的schema4一致副本及本地代理/已有DJI双格式副本，开发验收不打开真实资料库。原生窗口实际确认：

- 旧五星保留但未审；文件名QA-02+最低5星+精选标签只匹配1/5文件，清除恢复范围；标已审/未审独立于原评分。
- 两文件追加共同标签保留QA-02独有标签；移除共有标签保留独有标签；空替换明确显示清空差异，取消不写入；无变化禁用应用。
- 通过实际导入/人工初筛关闭创建B，A保留QA-0/单张/QA-02焦点，B保留B-03/网格/2星与1/3已审；来回切换及完整退出重启均独立恢复。标签历史跨重启恢复完整两文件操作，不因当前只选一文件而部分撤销。
- 空结果保留搜索/清除、禁用无目标动作。仅匹配JPG时只选一个成员，标已审后显示0/4次拍摄、1/5文件及1个部分组合；交付预览仅1个JPG11.2MB，明确当前范围缺RAW，不扩展隐藏DNG。实际复制/清单不可绕过范围由Core/App自动化覆盖，桌面验收覆盖预览。
- 桌面发现组合说明在筛选时仍暗示整对操作，已仅修正文案；重新构建最终Release并在独立窗口确认准确说明匹配成员范围，正常退出。上述结果记录`output/validation/007-project-review/desktop-acceptance.json`。

2026-10-24 21:50更新安装`/Users/robinqu/Applications/RAWMaster.app`，0.1.0(1)，Release优化、本机临时签名，无公证。暂存/最终包与构建逐文件一致，签名深度严格验证、plist、图标检查通过，LaunchServices重新登记。旧包、真实库一致备份、偏好快照保留在`output/installation/007-20261024-215056/`，收据为`install-report.json`。

安装不启动真实资料库、不改用户偏好；安装前后数据库主文件+WAL逐字节SHA256一致，偏好导出规范化后相同。第一次安装前防护把SQLite SHM读者索引变化当作数据变化，因此在替换前中止；其一致备份仍保留于`007-20261024-214949/`。后续明确SHM是可重建索引、排除其读者记账，仍严格比较主文件/WAL，完成更新。没有删除原片/资料库或重置偏好；真实库的schema升级将在用户下次启动时按现有一致备份规则执行。Git提交/推送不包含在本轮。

## 隔离与限制

main中既有006未提交修改保留；另一工作树`.slim/worktrees/metadata-sequences`不修改、不合并。本轮实施前冻结的1321个Sequence/Probe/fixtures/005受保护文件SHA256全部一致，记录`output/validation/007-project-review/protected-files.json`。人工初筛、固定基础RAW渲染及005质量门边界沿用，未增加自动排除、固定参考比较、智能集合或服务器能力。

## 搜索体验追加验收（SR07–12，2026-10-24）

实现、静态复核、自动化及2026-10-25解锁后的真实窗口验收完成，已更新安装搜索优化Release。前文341项/已安装包属于原007，不能当作追加界面已完成验收。追加证据在`output/validation/007-search-ux/`，独立bundle `io.robinqu.RAWMaster.Validation007UX`、已关闭007测试库一致副本；真实资料库未用于开发。

- designer确认按需native toolbar、复用右信息栏的实时filter panel、两行header/chips；oracle最终静态复核无P1/P2，Core匹配/action/export范围保持。
- worker定向20项通过（19项ProjectReview含新增5项，以及既有KeyboardMonitor）；`/tmp/rawmaster-search-ux-tests.log`。验证no-op候选不扫描/保存、非法query不发布、条件独立移除、显式scope与sidebar恢复区别、键盘ownership与开合不改信息栏偏好。完整`swift test --jobs 4`共401项、9可选跳过、0失败，`full-tests.log`。本UX只新增5项；相较原341，当前共享主线已有额外Imaging实验/证据测试，不归本UX新增，也不推导其质量通过。
- `scripts/build-app.sh release`成功，图标、plist与临时签名完成，`release-build.log`；该冻结构建的独立副本随后完成真实窗口验证。
- 原性能门首轮通过，`output/performance/007-search-ux-2026-10-24/summary.json`为`regression-passed`且`baselineCompared=true`，沿用2026-10-22基线及原阈值。p95：网格选中1.636ms/更新5.133ms、胶片条1.630ms/更新5.147ms；原始RAW687.421ms、四图原始比较2153.973ms、四图缩放绘制7.7845ms。执行期间Mac锁屏，此门是原有native in-process事件/离屏绘制，不能替代WindowServer呈现或人工桌面输入验收。
- 既有`testOptionalOffscreenWorkbenchSnapshot`显式启用通过，1440×900默认暗色布局及single fit→1:1→fit恢复绘制一致；截图`offscreen/workbench-offscreen.png`等，`offscreen.log`。这是无native工具栏的离屏诊断，不冒充真实窗口/1100窄窗/浅色验收。旧Release真实窗口`before-dark.png`已保存。
- UX冻结和发布自动化时1364个Core/Imaging/Sequence/fixtures/008保护文件SHA256一致，`protected-files.json`；本UX未写这些文件。等待解锁期间，另一对话将分组集成推进到main 893a0e5，导致12个旧保护文件变化，记录`protected-files-after-external-integration.json`。本次只安装此前已测试的997d51b+既有006/007+搜索UX冻结产物，未重建或带入尚在独立试用的分组集成；没有覆盖其源文件。对方后续整体构建须保留最新搜索UI，已同步边界。

2026-10-25，用户手动解锁后继续原生窗口验收，`desktop-acceptance.json`记录：

- 默认无常驻搜索附加行；⌘F和重复⌘F选中已有内容，粘贴即更新结果。放大镜再次点击、字段Esc和面板Esc分别收起对应控件，保留条件。
- 评分5星/精选标签实时交集，最高星低于最低星时inline提示并保留最后有效结果；无结果仍有搜索、chips和清除入口；单删标签和最后chip恢复结果并释放键盘所有权。
- Picker、标签输入pX05和日期控件X不误改照片；图片重新选择后数字评分生效并退出五星结果，撤销恢复评分，审阅记录按原合同保留。字段仍可见时也能返回图片操作。
- A的QA/最低5星/精选和B的B03独立切换恢复；正常退出重启后A三条件及焦点恢复，搜索未抢焦点。面板开合保持信息栏原显隐；Settings或交付sheet中⌘F不激活背后搜索。
- JPEG单成员搜索只显示1/5文件，RAW+JPEG交付预览仅1个JPG11.2MB，明确缺RAW，无隐藏DNG扩展。
- 实际拖到1100pt宽、940pt高，暗色3chips/匹配数/审阅进度/固定清除和两行header正常，一列筛选panel；原生输入展开态明/暗已检查，截图`narrow-active-dark.jpg`、`narrow-search-dark.jpg`、`narrow-search-light.jpg`。designer对真实暗色收起态及明/暗原生输入展开态均复核通过，无阻塞性视觉建议。未建立精确1100×720高度或所有显示器矩阵；不将离屏或CPU时延当作WindowServer呈现帧验收。

已运行保留数据安装脚本，收据`output/installation/007-search-ux-20261025-092005/install-report.json`。`/Users/robinqu/Applications/RAWMaster.app`与最终冻结Release逐文件一致，深度严格签名/资源验证通过，旧应用副本、库一致备份和偏好快照保留。安装前后数据库主文件+WAL SHA256及规范化偏好相同（可重建SHM读者索引不当作业务数据比较）；未启动真实库开发验收、未重置偏好、未删除原片。安装不包含尚在另一对话试用的新分组集成，后续发布衔接已通知。

原锁屏阻塞曾记录并请求用户手动解锁，未绕过系统锁屏；现已解除。没有Git提交/推送。

## 搜索与最新自动分组整合发布（2026-10-25）

本节替代上一节“正式安装尚未包含最新自动分组”的发布状态。用户明确授权整合893a0e5主线自动分组与既有006/007/搜索UX工作区修改，已完成实现、最终复核、Release回归、原性能门、真实素材原生验收及更新安装。未重置/提交/推送共享工作区，未改另一实验工作树。[整合合同](integration.md)与任务T12/T13完成。

### 实现及自动化

- 会话中新增“本批次拍摄组”导航，选择子组仍保持session初筛语义；项目评分/标签/审阅/导出不能绕过纳入守卫。完成摘要始终基于整批；普通项目组按admitted成员显示计数。组管理候选、预览和应用拒绝另一开放初筛会话。
- 自动分组状态结合真实run ledger与精确命令恢复状态；新增只读`loadGroupCommand(id:)`，不受最近50条窗口限制，不改schema/命令写入/算法。保留全批撤销、导入租约和完成fingerprint。修正遗留running记录无本机job时误报正在运行，以及逐组合反复构建范围集合的平方成本。
- 最终44项定向测试全部通过：8项整合、7项组工作流、19项项目审阅、10项初筛。Core精确读取另有3项定向通过。最终`swift test --configuration release --jobs 4`共442项、10项按需跳过、0失败，UI72/Probe30/Imaging193/Diagnostics19/Core128；工具78项、1跳过、0失败。日志在`output/validation/007-search-grouping-integration/`的`integration-p2-directed-tests.log`、`full-release-tests-final.log`和`tooling-tests.log`。
- 首轮完整Release440项通过后，oracle发现上述两项P2，修正并重新冻结/重跑最终442项；旧日志保留。更早新测试曾误期待关闭后resume成功，已改为开放会话撤销后resume不重施、关闭后resume拒绝；006守卫未放宽。该首次scratch全日志已被worker覆写，仅存真实失败excerpt，不能声称完整失败日志仍在。
- 30k文件/15k组合/7501组纯元数据路径约0.379秒，3秒预算内，无图像读取；不是30k真实RAW的全窗口或p95验收。

### 构建与性能

`./scripts/build-app.sh release`成功。正式资源内含固定ExifTool13.59、官方源码commit `2200871d9cef988051d2a99d67df3bda6cbb30a8`，249文件闭包SHA256 `8d48cc55aa7f8d05dc037c08d914e008318d58d5396619e26141809af80d1acd`；manifest、各文件内容、权限、Perl实际版本、plist、图标与深度严格临时签名核验通过。依赖从另一工作树干净固定副本本地clone，未改原副本。

原性能门`output/performance/007-search-grouping-integration-2026-10-25/summary.json`为`regression-passed`且`baselineCompared=true`，沿用2026-10-22原基线与阈值，首轮通过。p95：网格选中1.923ms/更新6.715ms、胶片条1.589ms/更新5.251ms；原始RAW676.955ms、四图原始比较2140.769ms、四图缩放绘制9.140333ms。SwiftPM编译锁串行等待后完成构建与测量；测量期间未操作原生QA。该门仍测native receiver/NSView更新及离屏绘制，不冒充WindowServer呈现延迟。

### 真实窗口整合验收

新Release使用独立bundle `io.robinqu.RAWMaster.ValidationIntegration007`，Info环境和启动参数均固定到独立QA库。继承既有8文件A/B验收状态，开发不打开真实用户资料库。实际操作与13张截图、数据库只读核验见`output/validation/007-search-grouping-integration/desktop-acceptance.json`：

1. 原地接入Sony50个ARW，自动生成DSC01721–DSC01768的48张待复核连拍组；初筛期间全部素材仍为旧8文件，新项目未发布。组内只有初筛P/X/U，没有项目评分/标签/交付。
2. 子组内排除DSC01721，完成摘要覆盖整批49纳入/1不纳入。返回初筛、恢复完整自动批次后组消失且排除处置保留；开放会话“继续/重新校验”未重建组。再通过持久历史恢复组，关闭整批后项目49文件、组行47可见成员。
3. 组内即时文件名搜索匹配1/47，收起搜索保留紧凑条件；对DSC01722评分5星/追加标签“整合验收”后已审。关闭后的自动组恢复预览仍为完整48成员，包含已排除历史成员；应用后项目仍49，评分/标签/已审保留。已关闭会话只显示导入历史，不提供继续接入入口；关闭后底层resume拒绝另有自动化覆盖。
4. 复制模式导入28个真实ARW到独立受管目标，自动生成16张间隔组；排除其必要成员DSC05994后，整批摘要28纳入、1个仅序列用途。完成后28文件/16成员组持久存在。
5. DJI24文件生成24成员待复核间隔组；另由CapturePair规则确认12对拍摄证据关联，显示12次拍摄/24文件。自动事件组中的关联假设与确认组合是不同证据，不能混为真值。
6. 项目仅搜索一个JPG，匹配1/24文件，不扩展隐藏DNG；仅JPG评分5星、DNG仍0星。文件名+最低5星在非模态侧栏即时生效，无应用按钮。实际以RAW+JPEG格式交付当前所选，只复制1个JPEG并校验SHA256，清单allowed/requested均只1文件、无DNG；因请求格式中的RAW不在当前范围，界面明确报告缺RAW、清单`partial`。这是预期缺格式路径，不能写成“所有请求格式均成功”。
7. 正常退出并重启，所有批次已关闭，项目/组/纳入状态、查询和评分持久保留。视觉复核确认浅色真实窗口层级与搜索设计保持；本次未重新执行深色/1100宽全矩阵，不把此前搜索UX结果冒充此次新截图。

102个真实来源文件的SHA256、大小、mtime_ns、inode全部与验收前一致；28个复制件逐一SHA256与来源一致；原QA的assets/admissions/tags/review/project states行全部保持。最终159个源码文件冻结哈希与1341个分组/Imaging/Probe/fixtures/008保护文件哈希一致。核验脚本与收据在同证据目录，已见有界样本不代表独立分组质量门通过，不新增自动丢弃/阈值/标签真值。

### 安装与保留

2026-10-25 10:24完成更新`~/Applications/RAWMaster.app`。收据`output/installation/007-search-grouping-20261025-102450/install-report.json`：最终257文件与构建逐文件一致；binary SHA256 `c28a33c7d288860c4770aaca81b6f0478ba47839c450090a88883b5390408930`；本机ad-hoc签名，无公证。包内元数据闭包验证通过，QA环境未写入正式Info。安装前正常退出QA且正式应用没有运行；暂存验证后替换并重新登记LaunchServices。

同目录保留旧App、一致SQLite备份、偏好快照；若存在grouping-key也备份保留。安装前后真实资料库主文件+WAL SHA256不变，规范化偏好不变；SHM可重建读者索引不纳入业务字节比较。没有删除原片、重置偏好或用QA库替换用户资料库；正式新版本首次打开沿用原升级前一致备份规则。本轮未自动启动真实资料库做开发验收，也未进行Git提交/推送。

最终安装审查另发现安装工具失败回滚分支风险：旧App首次rename若失败，不应把仍在target的旧包当作失败新包移走。正常安装本次已成功、未触发该分支；随后工具增加`new_bundle_promoted`保护并通过语法检查，以及抽取实际try/except在临时目录注入旧包搬移失败、新包提升失败、提升后验证失败三条路径，均保留target旧包。该修补只作用于安装工具，不改已验源码或已安装二进制，无需再次替换正式安装。最终发布结果与避免旧trial覆盖的边界已同步原自动分组对话。
