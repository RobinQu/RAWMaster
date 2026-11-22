# 027 / 028 / 031 · 基础编辑对齐后的集成验收

2026-11-22 · 接收对象为 Camera Raw 基础编辑引擎、滤镜预设目录与本地 AI 蒙版。此页定义集成步骤和记录口径；独立功能测试在各自阶段就可执行。[预设验收 V1–V7](validation.md) · [027 原始服务基线](../027-mask-ai-raw-integration/service-validation.md)

## 集成触发与可交付版本

基础编辑负责人交付其已对齐的范围、对应提交或可重建的源码快照、已知例外、渲染和性能报告后，记录引擎及两项功能的修订。把**功能增量**应用到该版本，保留对方对色彩、几何、预览、导出和缓存的改动。对于尚未对齐的基础算子，只能按已实测范围签收。智能修图的场景卡和生成队列留给后续 030。[项目顺序](../../docs/planning/24-mask-preset-retouch-roadmap.md) · [030 交接](../030-ai-retouching/handoff.md)

蒙版开发版的 RAW 分析取 CIRAWFilter 已定向的中性 sRGB 图，长边 1,536 像素。合入采用 FlashRaw 的引擎时，要用相同原件对照方向、有效区域和裁切，逐张记录分析前缀和重复解码次数。只有缓存身份与像素空间一致才可复用引擎的分析图。既有蒙版回放直接读取冻结结果。[编辑器功能证据](../027-mask-ai-raw-integration/editor-validation.md)

2026-11-22 18:02 复核，基础编辑报告仍标记 `measured-with-open-parity-gaps` / `not-qualified`，源码身份为 `b89702e8 + 当前工作区改动`。此处等待对齐范围的可重建交付版本。主工作区的动态证据位于 `docs/research/camera-raw-parity/performance-data.json`。

- 基础会话已对 15 张真实 RAW 完成后台测试。8 项基础调整连续三轮的中位数与 p95 达到 LightFlow 门槛，另有按面板分组的首帧、最终帧对照。31 项一组的首帧／最终帧分别通过 27／31 项。另一次 37 项对照分别通过 36／37 项。
- 两轮 Camera Raw 前台实测后，有 6 项滑块到照片屏幕响应的记录通过验证。第二轮因 Adobe 模态对话框中断，剩余项以基础编辑的最终交付记录为准。

本次只读交接检查发现，功能增量所改的既有文件中有 9 个也被基础编辑会话修改，包括 Package.swift、EditingController、DevelopmentAdjustmentCommands、DevelopmentMaskEngineV3、DevelopmentPreviewService、DevelopmentRendererV3、PreviewInteractiveProxyV3、EditingDevelopmentSessionTests 及 build-app.sh。功能新增文件当时没有重名。接到目标快照后重新计算交集，在对应方法上分别合并模型包、源绑定、预览与资源复制逻辑，随后运行双方回归。[开发版本与功能证据](feature-validation.md)

## 接收、对照与记录

| 步骤 | 操作与证据 | 判定 |
| --- | --- | --- |
| 1. 锁定输入 | QA 在同机冻结 RAW 源 SHA、解码器、方向、裁切、输入 ICC、输出色域、代理长边、设备/系统/内存、构建配置、实际模型哈希。保留当前旧工程、61MP Sony、竖幅人像、无人物图、雪与无雪风景，并记录各自用途 | 手调、应用预设和蒙版前后的比较使用同一输入与成像设置。记录冷启动、暖缓存与稳态各自的样本数 |
| 2. 试预设与保存 | 真实编辑窗口导航 1,075 条元数据，搜索、星标、键盘预览、离开恢复、采用、撤销。带裁切/蒙版的旧片仅应用显式零曝光。Amount 按 0/25/50/100/25，重开后检查已采用参数。按 V3/V4 另检 XMP 原件、缺依赖、重复或中断导入 | 目录产生的滤镜候选缩略图请求、误写历史和错片呈现均为 0。同基线两次 25 的结果一致。用功能自制样例和固定 Adobe 样本分别给出支持级别 |
| 3. 创建与修正蒙版 | 在正常编辑入口创建主体/背景和可用语义范围，检查叠层、画笔增减、取消、换片、撤销、重开和全尺寸导出。断开可选权重或服务再次回放。对同图不同点选、无目标/模型缺失、镜像与裁切另做对照 | 错源草稿不能采用，取消不产生历史。冻结快照的重开/导出推理次数为 0。仅启用局部节点时，遮罩为零处与相同前缀逐像素相同。旧内嵌 PNG 可回放 |
| 4. 测呈现时间 | Release、真实 AppKit 窗口、同一帧边界计时。预设与等价手调交替，暖样本每组至少 30 次，另列冷开、长尾、回退、解码次数。录入蒙版首次分析、精确快照命中、同图不同点/类别、取消与释放后的 RSS | Classic 窗口 p50 ≤20 ms、p95 ≤33 ms。普通预设暖 p95 不高于成对手调。蒙版冷主体 ≤6,000 ms、精确快照命中 ≤250 ms；分别对照 027 其他指标和工作集。任何超线项保留原读数和复测条件 |
| 5. 签收 | QA 保存输入/输出 SHA、日志、原始计时数组、操作计数、截图或失败样张。对每条已测路径填构建、环境、覆盖与结果，给未过项分配责任与复测条件 | 基础编辑、预设、蒙版三个负责人核认同一构建。Lightroom 实机回读、VoiceOver、真实摄影师走查及高级 Profile/景深逐项单列 |

028 历史实测的暖窗口 p50/p95 为 27.367/34.061 ms。027 独立服务的主体冷创建/快照命中为 1,621.93/1.93 ms。两组测量的边界与测试对象不同，联合签收须记录新版本的实际值。[窗口基线](../028-filter-experience/validation.md) · [蒙版基线](../027-mask-ai-raw-integration/service-validation.md)

## 对齐版本上的 Release 测量入口

Classic Filters 沿用 028 的 `RAWMASTER_EDITING_PERF_FILTER_ONLY=1` 窗口协议。031 的普通预设另以 `RAWMASTER_EDITING_PERF_PRESET_PAIR=1` 运行同一原生画布。在每一对测量中分别通过真实预设采用和手工曝光命令写入相同值，等待已接受的 settled 帧绘制完成，再 Undo 回到同一基线。交替交换两条路径的顺序，保存首对样本、30 对暖样本、两侧 p95、每轮配方一致性和源文件前后 SHA。该计时边界从离散采用到 settled 绘制返回。[028 的输入、环境变量与原始运行方法](../028-filter-experience/validation.md)

```sh
RAWMASTER_EDITING_PERF=1 RAWMASTER_EDITING_PERF_PRESET_PAIR=1 \
RAWMASTER_EDITING_PERF_SOURCE="$PWD/output/performance/acr-benchmark.ARW" \
RAWMASTER_EDITING_PERF_OUTPUT="$PWD/output/performance/preset-paired-$(date +%Y%m%d-%H%M%S)" \
RAWMASTER_LIGHTFLOW_REFERENCE="$PWD/output/lightflow-research/same-size-runtime.json" \
swift test -c release --test-product RAWMasterUITests \
  --filter EditingInteractionPerformanceTests/testOptInRealRAWCompoundEditingCanvasPerformance
```

在实际候选版本上，027 的主体专项使用同一 AppKit 宿主。以下命令以已知能产生主体与背景的竖拍 RAW 开始。61 MP 样片另存一次结果。每次指定新的输出目录。

```sh
RAWMASTER_EDITING_PERF=1 RAWMASTER_EDITING_PERF_MASK_SUBJECT=1 \
RAWMASTER_EDITING_PERF_SOURCE="$PWD/output/preset-mask-fixtures/person.ARW" \
RAWMASTER_EDITING_PERF_OUTPUT="$PWD/output/performance/mask-subject-$(date +%Y%m%d-%H%M%S)" \
RAWMASTER_LIGHTFLOW_REFERENCE="$PWD/output/lightflow-research/same-size-runtime.json" \
swift test -c release --test-product RAWMasterUITests \
  --filter EditingInteractionPerformanceTests/testOptInRealRAWCompoundEditingCanvasPerformance
```

计时从编辑器触发「主体」到主线程发布可采用的 Gray8 候选。冷请求和三十次重复请求分别取数。读取同一蒙版服务的真实计数，相对启动时的「精确命中 / 成功新建」应依次为首次主体 0/1、重复主体 30/1、首次背景 30/2、恢复主体 31/2。记录每次耗时、Gray8 哈希及前后景逐像素的互补关系。采用至 settled 画布绘制返回单独计时。开始首个请求前先等待基础画布 settled。红色叠层第一次可见和系统窗口合成仍需另外测量。预览 RAW 基图的填充和命中另行记录。

随后以实际编辑会话调节局部曝光，关闭编辑器，按作品 ID 从磁盘读取配方并导出原尺寸 16 位 TIFF。记录源、冻结 PNG 和各 TIFF 的哈希，检查方向、尺寸和位深。另导出仅禁用该图层的对照。如果禁用会退回旧渲染器，再导出同 V3 路径、零覆盖的对照。逐行比较 16 位 RGBA 样本，冻结遮罩为零处取最大通道差，覆盖 ≥0.5 处统计增亮像素和 RGB 总增量。Release 专项对自然开关图层的保护区仍要求零差。RSS 在首次请求前、首次生成后、编辑器关闭后和主成片写出后取样，峰值属于整个进程。两份诊断对照的开销单列，不并入主成片的时间和内存读数。

独立旧作品夹具已重现同 V3 前缀保护区差 **0**、自然开关回到旧前缀时差 **2/65,535**。9,484 个保护像素和 112 个选中像素均来自同一张 120×80 自制图片。目标引擎需用此例检查旧作品兼容，同时以真实 RAW 验证显示、局部效果和导出。[原始输入、候选与对照](../027-mask-ai-raw-integration/editor-validation.md#旧作品开关图层的两组对照)

独立的 `PerformanceAcceptanceTests` 复测只作为服务对照，使用副本运行以保存旧基线。
