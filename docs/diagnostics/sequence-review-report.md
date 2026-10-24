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
- 组编辑显示起止原文件名、ordinal 和数量，可增加、改范围/类型、移除组。至少两张，范围连续。与边界修订冲突或组重叠时会提示，解决前不能导出。
- 撤销和清空仅影响草稿。清空可撤销。浏览器若不允许 localStorage，编辑仍保留在内存并提示导出 JSON；关闭页面前请手动导出。

导入/导出 JSON 为 `RAWMaster-sequence-label-revision` schema1，绑定完整 index、每案例 truth SHA256 和全部文件的 caseID/assetID/ordinal/JPEG/原片哈希。来源不一致、文件身份篡改、重复字段、非相邻边、无效类型、范围重叠或冲突会拒绝导入，原草稿保留。导入本身可撤销。该文件是人工修订提案，不能直接当新 truth 或自动应用到客户端。

## 验证

```sh
python3 -m unittest discover -s Tests/Tooling -p test_sequence_review_report.py -v
```

9 项合成测试不解码图像，缩图使用 stub；覆盖完整错误集、未知不补负例、哈希/路径篡改拒绝、源字节保留、输出禁止覆盖、HTML 转义，封存计数一致性，以及 Node 下的纯修订校验器往返/篡改/双向关系与组冲突检查。真实 1,265 张缩图、浏览器 file://、导入导出、撤销、搜索与储存降级由主线程另行验收，不能以合成测试代替。
