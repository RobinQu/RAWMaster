# 本地序列分组复核报告

报告对照现有 reduced JPEG、不可改写的旧标签和已封存算法结果。它可以帮助修订分组意图，不把视觉相似度当作标注正确性的证明，也不会写回原片、资料库、truth 或 golden。

## 生成

需要 Python 3 与 Pillow。仅执行报告生成时才会读取已有 JPEG；不打开 RAW、不扫描原片目录、不下载模型。

```sh
python3 scripts/build-sequence-review-report.py \
  --fixture-root Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1 \
  --visual-review docs/diagnostics/sequence-codex-visual-review-v1.json \
  --output output/validation/010-visual-review/report-01
```

输出目录必须是新目录，且在 fixture 之外。已有 JPEG 的 SHA256 在缩图前后核对；最长边不超过 384，保留原始 JPEG 不动。输出包含可直接打开的 `index.html`、本地 CSS/JS、`catalog.json`、缩图及 `preservation-receipt.json`。离线打开无需服务器，目录整体打包后仍可浏览。

默认历史数据为 v1 `behavior-v1.json` 及 `spatial-cv-v1-summary.json`、`metadata-sequence-v1-summary.json`、`metadata-pause-bridge-v1-summary.json` 中的质量记录。保留各版完整预测、旧误并/漏分与未知信息。DJI 的大量错误只在概览中聚合呈现，完整边界可展开、搜索；全部 1,265 个表示文件仍在图库，不合并或删除 DNG/JPG 表示。

可选 `--sources /absolute/local-control.json` 明确补充历史实验，路径相对该控制文件解析，支持：

```json
{
  "artifacts": [
    {"id":"dev4","title":"原始规则","format":"behavior","path":"/absolute/repository/Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/baselines/behavior-v1.json"},
    {"id":"007","title":"空间连续性","format":"quality","path":"/absolute/repository/docs/diagnostics/spatial-cv-v1-summary.json"},
    {"id":"008","title":"元数据事件","format":"quality","path":"/absolute/repository/docs/diagnostics/metadata-sequence-v1-summary.json"},
    {"id":"009","title":"暂停桥接","format":"quality","path":"/absolute/repository/docs/diagnostics/metadata-pause-bridge-v1-summary.json"},
    {"id":"005-startup-burst","title":"首次启动边界","format":"probe","caseID":"burst48-context72","path":"/absolute/primary/output/validation/005-2026-10-24/validation-burst-context/attempt-01/report.json"},
    {"id":"005-startup-interval","title":"首次启动边界","format":"probe","caseID":"interval427-context439","path":"/absolute/primary/output/validation/005-2026-10-24/validation-interval-context/attempt-01/report.json"}
  ],
  "attributions": []
}
```

`quality` 可为完整 unit 数组或文档中的 `quality` 数组，兼容 `behavior.result`、`ranges`、`fileRanges`；`variants` 可显式限制版本。所有输入路径及字节摘要都会保留。首次 005 启动实验不在默认摘要内，需要如上明确加入；不能将默认摘要目录误称为所有历史实验。缺少请求的文件或案例、重复版本、越界范围、控制哈希不符均拒绝生成。未知负边不计为 TN；图中派生边计数与原始封存指标分别保留。

视觉复核通过 `--visual-review` 导入 Root 实际用 Codex 查看图像后写下的记录。每条 ordinal 与 imageSHA256 一一对应核验；未提供复核时明确显示未复核，不生成视觉结论。记录超过四张时只预览首/中/末，完整已看文件清单可展开。`reviewMethod` 保留实际方法说明，不声称所有表示对都逐对检查。

## 使用与修订

- “失败与复核”展示视觉事实、算法归因、人工建议和置信度；完整历史边界清单保留已修复错误。
- “浏览全部照片”按案例、算法和文件名/assetID/ordinal 搜索。旧标签、所选预测和草稿组分别显示，0188 的未知状态醒目标示。
- 点击一张照片可将它与下一张的关系改为同组、分开、未知。恢复旧标签只清除此边的草稿。
- 组编辑显示起止原文件名、ordinal 和数量，可增加、改范围/类型、移除组。至少两张，范围连续。与边界修订冲突或组重叠时会在顶部提示；此时导出可恢复草稿备份，解决后再导出正式修订。
- 撤销和清空仅影响草稿。清空可撤销。浏览器若不允许 localStorage，编辑仍保留在内存并提示导出 JSON；关闭页面前请手动导出。

导入/导出 JSON 为 `RAWMaster-sequence-label-revision` schema1，绑定完整 index、每案例 truth SHA256 和全部文件的 caseID/assetID/ordinal/JPEG/原片哈希。来源不一致、文件身份篡改、重复字段、非相邻边、无效类型或越界范围会拒绝导入，原草稿保留。重叠及边界冲突可导入为待处理草稿，并在顶部显示；正式修订仍要求无冲突。导入本身可撤销。该文件是人工修订提案，不能直接当新 truth 或自动应用到客户端。

## 验证

```sh
python3 -m unittest discover -s Tests/Tooling -p test_sequence_review_report.py -v
```

合成测试不解码图像，缩图使用 stub；覆盖完整错误集、未知不补负例、哈希/路径篡改拒绝、源字节保留、输出禁止覆盖、HTML 转义，封存计数一致性，以及 Node 下的纯修订校验器往返/篡改/双向关系与组冲突检查。原报告的 1,265 张缩图已核验；浏览器 file:// 交互仍受工具安全策略限制，不能以内存 DOM 测试冒充真实浏览器验收。


## 连续标注（2026-10-25）

详情顶部可以直接切换上一段/下一段，并选择复核片段、数据集、算法分组或历史错误边界队列；不必回到“失败与复核”。“本段完成，下一段”只记录浏览进度，不修改标签。`[` / `]` 切换队列片段，左右方向键切换相邻图片；输入框中不会拦截这些键。

- “上一对/下一对”支持逐边标注；勾选“标完自动下一对”后，同组/分开/未知会保存到草稿并前进，末尾不会越界。
- 两张图片位于同一草稿组时，可显式点击“在此拆分草稿组”。保留两侧至少两张的片段及原用途；单张仍保留为未分组图片。操作可撤销，原标签不变。
- “保存范围，继续下一组”优先从当前范围末尾之后继续同一数据集，避免跳过尚未标注的内部序列。
- 修改范围尚未保存时，导航会要求保存、放弃本次编辑或留在原处；无效范围不会跳转。未保存表单和浏览位置也单独保存，刷新可恢复。
- 使用同一报告地址和原 schema1 草稿存储键；浏览进度另用 workspace-v2 存储，不写入标签 JSON。更新前建议先导出备份，刷新后页脚显示“连续标注 v2”。

顶部和算法表格的指标仍依据封存旧标签，新增草稿边界不冒充已重评真值。数据集名称表示带上下文的素材集合，并不意味着集合内只有一个连拍组。

连续工作流采用固定版本 jsdom 的内存 DOM 交互回归，不启动浏览器、不读取图像、不访问网络。准备与执行：

```sh
npm ci --prefix Tests/ReviewUI --ignore-scripts --no-audit --no-fund
python3 -m unittest discover -s Tests/Tooling -p test_sequence_review_report.py -v
```

CI 在完整工具回归前安装该固定测试依赖。覆盖跨片段/数据集/算法组导航，保存/放弃/无效范围保护，刷新恢复、旧 schema1 草稿保留、逐对自动前进、拆分/撤销、连续保存范围、进度标记和存储不可用降级。它不替代真实浏览器呈现与下载验收。

## DJI JPEG 单表示标注（2026-10-25）

用户确认 DJI 的间隔拍摄标注只使用相机 JPEG，不重复标注对应 DNG。本次调整只创建标注投影，不修改原始文件、v1 fixture、旧 truth、历史基线或客户端算法。它与客户端 RAW+JPEG 先形成单张照片资源、再进行序列分组的粒度一致；JPEG 子集本身不验证客户端的 RAW+JPEG 关联实现。

- `dji187-context376` 从 376 个文件投影为 188 张 JPEG；0001–0187 的 187 张继续保留已确认同组，0188 的归属仍未知，不增加组外负边。
- 根据原文件名 `.JPG`/`.JPEG` 选择，不能根据缩图扩展名选择：DNG 对应的低分辨率缩图本身也是 `.jpg`。
- 新 ordinal 为 0–187；保留稳定 assetID、原片及缩图哈希、`sourceOrdinal`，投影描述绑定完整源文件列表。其他案例不改变。
- DJI 历史文件级错误边、算法评分和 DNG/JPEG 视觉复核保存在旧报告，不直接转换为 JPEG 事件级评分。新版以独立的“JPEG 序列标注”入口进入连续标注；没有声称已重新运行算法或已通过质量门槛。
- 新 indexSHA256 是投影描述的 SHA256，新 truthSHA256 是投影标签的 SHA256。完整源绑定保留在 `annotationProjection.legacyCatalog`。schema1 导出继续严格绑定新列表，旧版与新版草稿使用不同存储键。
- 新版可自动读取同地址下的旧草稿，或导入旧 JSON：先验证完整源绑定，再迁移未改动案例的修订；旧存储保持原字节不动。旧修订若含 DJI 边界/组编辑则明确拒绝自动迁移，要求保留旧导出并在 JPEG 序列重新标注，避免猜测 DNG 编号含义。加载失败后仍可使用旧报告/旧导出恢复。

新建投影报告：

```sh
python3 scripts/build-sequence-review-report.py \
  --fixture-root Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1 \
  --visual-review docs/diagnostics/sequence-codex-visual-review-v1.json \
  --jpeg-only-case dji187-context376 \
  --output output/reports/sequence-review-jpeg-new
```

既有报告原地升级时，先在独立新目录备份完整旧报告，再从其已封存 catalog 生成投影并验证所有保留缩图的哈希，最后更新原报告地址。投影后共 1,077 张标注图片，减少的 188 张均为 DJI DNG 对应缩图；未修改任何源 fixture 图片。

12 项报告测试包含 JPEG 子集选择、密集编号/源编号追溯、0188 式未知边界保留、源对象不变、历史评分隔离、旧标注迁移与篡改拒绝，以及内存 DOM 中 JPEG→JPEG 相邻标注、旧存储字节保留和连续工作流。


## 导出与冲突恢复（2026-10-25，连续标注 v4）

旧实现会在任意案例出现组范围/边界冲突时禁用全局“导出修订”，而提示藏在详情侧栏，导致复核页看不到原因。例如旧整组内部新增“分开”边界，但尚未拆组，便无法导出已做的标注。

- “导出修订”始终可点击。草稿无冲突且范围已保存时，仍导出原 schema1 修订。
- 存在冲突或范围尚未保存时，导出 `RAWMaster-sequence-review-backup` schema1 包装文件，名称含 `sequence-review-backup`。包含结构验证后的原修订、浏览位置、队列进度和未保存范围表单；不伪装成可用于评测的正式标签。
- 用同一个“导入修订”入口恢复备份，包含尚未保存甚至数值无效的表单内容；修订身份/哈希仍严格验证。跨标注版本迁移时，只迁移允许的标签，不套用旧编号浏览位置。
- 页面顶部持续展示全局冲突和未保存状态，每条冲突可定位。不会再因为详情隐藏而看不到导出状态。
- 显式“按分开／未知边界拆分草稿组”可一次调整受影响组范围，保留每条关系和备注；操作可撤销。单张仍保留为未分组照片。重叠范围和跨组的“同组”关系不自动猜测修复，仍可备份并手动调整。
- 报告绑定、JPEG 子集、浏览器存储键、旧标注和基线不变。导出本身不改写草稿或标签。

新增内存 DOM 回归覆盖：详情隐藏时的全局冲突提示/定位、冲突草稿可下载、未保存无效范围的备份往返、原修订字节不变、拆分修复与撤销、同组跨组/范围重叠备份、哈希篡改拒绝，以及修复后恢复原格式的正式导出。内存 DOM 测试不替代真实浏览器下载验收。


## 简明标注与再次复核（2026-10-25，v5）

默认界面改为一个问题、一对大图、三个选择：同一组、右图另起一组、暂不确定。点击即保存到浏览器，下一项继续；支持 1/2/3、方向键、可选自动下一项及撤销。无需输入 ordinal、选择算法版本或同时维护组范围。高级编辑器与历史评测默认折叠。

边界选择是主要输入：对当前案例按所有明确边界重新计算连续组范围；同组会合并相邻片段，分开会拆组，未知仍保留未知。已有边界备注保留，未标注上下文不会自动补为负例。既有范围重叠会提示使用高级工具解决；读取旧草稿本身不修改标签。导出仍兼容 schema1 和 v4 的可恢复备份。标注绑定、旧草稿键和 DJI JPEG 投影保持不变；新版浏览位置另存 guided-v1。

本次实际查看 78 张缩图（5 张联系表）并核对已有元数据、用户确认及 5 条导出修订。新证据记录在 `sequence-review-guidance-v1.json`，绑定当前标注 index、每个待确认边界的 assetID/JPEG SHA256、所有已看图片及元数据来源摘要。构建器 `--guidance` 会验证数据绑定，拒绝编号或图像哈希不符的建议。

待确认只保留以下 5 项：

| 边界 | 已有证据 | 待人工决定 |
| --- | --- | --- |
| DSC01731 → DSC01732 | 间隔 1.401 秒；SequenceFileNumber 11 → 1 | 是否在 01732 开始新连拍 |
| DSC01741 → DSC01742 | 间隔 7.207 秒；计数 10 → 1；明显重新取景 | 是否在 01742 开始新连拍 |
| DSC01752 → DSC01753 | 间隔 0.650 秒；计数 11 → 1；场景仍连续 | 是否在 01753 开始新连拍 |
| DSC01761 → DSC01762 | 间隔 5.389 秒；计数 9 → 1 | 是否在 01762 开始新连拍 |
| DJI 0187 → 0188（JPEG） | 间隔仍为 5 秒；构图基本一致；快门 1/3200 → 1/8000，ISO 200 → 130，亮度下降 | 0188 的归属继续保持未知 |

四个 Sony 分界构成 11、10、11、9、7 张的五段候选，总计 48 张；只是建议，不自动写入标签。先前只凭画面相似而“建议保留同组”的复核不能排除快门重启，新待办优先呈现这四处。旧视觉记录保留，以便追溯。

移出重复确认项：用户导出已重申的 burst123 三处同组边界；burst48 两端组外邻片；burst193 已明确接受的两端组外边界；Sony 间隔组起点及 05992/05993 的新增分开标注；burst14 的已确认范围。DSC06421 已由用户确认组外，但当前 fixture 未包含该照片；本次只读检查发现用户提供目录可访问，却没有 DSC06421.ARW。记录为后邻片素材缺口，不再次向用户索要同一事实。

带本次待办的新报告构建参数，在 JPEG 投影后增加：

```sh
--guidance docs/diagnostics/sequence-review-guidance-v1.json
```

新版交互回归覆盖自动拆分/合并、未知不补负边、旧备注和草稿字节保留、撤销、连续导航、键盘操作、刷新恢复及正式导出。仍不将内存 DOM 验证称为实际浏览器视觉或下载验收。
