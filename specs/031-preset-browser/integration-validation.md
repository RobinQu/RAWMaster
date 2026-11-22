# 027 / 028 / 031 · 基础编辑对齐后的集成验收

2026-11-22 · Camera Raw 基础编辑引擎、滤镜预设目录与本地 AI 蒙版的集成验收。下文保留实测结果、签收条件和复现方法。[预设验收 V1–V7](validation.md) · [027 原始服务基线](../027-mask-ai-raw-integration/service-validation.md)

## 同一 Release 的联合验收结果

本次交付为本机集成候选。普通预设的复测 p95 比等价手调慢 2.50 ms，031 SC-02 尚未通过。首次打开显示经典滤镜，左栏可以切换到预设目录并记住选择。两个入口共用当前作品、收藏和调整历史。[逐轮门槛判定](evidence/camera-raw-integration/window-gates.json)

候选的源码提交为 `a712912d23860efed05cf0e6622907be8a5e5bba`，上游基础编辑为 `e2b9c68a`。本机为 Apple M4 Max、128 GiB、macOS 27.0.1。命令从已导入的原片打开正式编辑器，在 AppKit 窗口等待同一帧的绘制完成。产品包与启用测试访问的 Release 测试程序分别登记可执行文件摘要。[构建与原始收据索引](evidence/camera-raw-integration/receipt.json) · [输入与模型指纹](evidence/camera-raw-integration/inputs.json)

### 滤镜和预设

| 61 MP 窗口指标 | 首轮 | 独立复测 | 规格门槛 |
| --- | ---: | ---: | --- |
| Classic 暖 p50 / p95 | 11.07 / 16.05 ms | 10.56 / 13.82 ms | ≤20 / ≤33 ms |
| 普通预设采用到 settled 绘制 p95 | 59.40 ms | 58.02 ms | 同轮不高于等价手调 |
| 等价手调到 settled 绘制 p95 | 61.86 ms | 55.52 ms | 同一曝光、同一基线配方 |

Classic 每轮包括 8 次切换外观、8 次强度变化和 6 次带纹理的复合编辑。每类首笔单列，其余 19 笔统计暖分位数。首轮三类首笔分别为 95.5、17.6、28.0 ms。发布与实际绘制的交互图均为 2400 × 1600，三类暖段均无额外 FlashRaw 解码或规范渲染回退。普通预设每轮保留首对和 30 对暖样本，按 AB/BA 轮换，核对每对最终配方相同。计时止于画布返回，两轮同步采用命令的暖中位数分别为 0.62 和 0.60 ms。物理输入到屏幕亮起另计。[Classic 首轮](evidence/camera-raw-integration/classic.json) · [Classic 复测](evidence/camera-raw-integration/confirm-classic.json) · [预设与手调首轮](evidence/camera-raw-integration/paired.json) · [预设与手调复测](evidence/camera-raw-integration/confirm-paired.json)

直接成像服务暖 p50 / p95 为 10.99 / 13.10 ms。十候选在 256 × 171 代理上的首次总耗时 812.7 ms，八组暖候选的整组中位数为 68.6 ms。十种外观均生成 settled 帧，强度 37% 的 Vivid 全尺寸 PNG16 为 9504 × 6336，源 SHA 保持一致，关闭后本次资源计数归零。目录检索另用 1,075 项夹具验证，浏览和采用产生的候选缩略图请求为零。[服务](evidence/camera-raw-integration/production-filter-interactive.json) · [十候选](evidence/camera-raw-integration/filter-thumbnail-direct-validation.json) · [外观与导出](evidence/camera-raw-integration/real-raw-filter-canonical.json) · [编辑器功能回归](evidence/camera-raw-integration/functional.json)

### 蒙版、重开与全尺寸导出

| RAW | 冷主体 ms | 30 次暖命中 p95 / 最慢 ms | 采用至画布 ms | 重开配方写出 TIFF | TIFF16 尺寸 | 保护像素数 / 最大通道差 |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| 水鸟 | 336.0 | 31.9 / 32.5 | 141.4 | 1.32 s | 9504 × 6336 | 60,003,066 / 0 |
| EXIF 8 人像 | 193.5 | 14.4 / 15.5 | 102.3 | 0.55 s | 4000 × 6000 | 21,538,706 / 0 |

冷主体从当前编辑器首次请求计到可采用的候选出现，门槛为 6,000 ms。每次暖命中均须在 250 ms 内。两张图的精确命中 / 成功生成计数均按 0/1、30/1、30/2、31/2 演进。各自首次分析成功解码一次，30 次暖命中均未再解码。背景与主体覆盖互补。重开的新编辑器在打开前、画布完成后、写出后模型调用数均为零，选区内亮度实际增加，原文件 SHA 保持一致。两次主成片写出后的进程峰值分别为 1.96 GiB 和 0.95 GiB。首次关闭编辑器后的进程常驻内存分别为 1.34 和 0.70 GiB。同进程还持有基础编辑引擎。[水鸟结果](evidence/camera-raw-integration/bird.json) · [竖幅人像结果](evidence/camera-raw-integration/portrait.json)

新作品的解码标识为 FlashRaw 0.3.1、线性 sRGB、双线性插值。两份报告的最近一次原生解码后端记录为 `CPU NEON x16 threads`。Metal 完成线性 F16 的方向变换与缩放。长边 1536 的分析图分别为 1536 × 1024 和 1024 × 1536。旧作品继续按保存的解码器回放，错误源和错误方向不能采用。[解码器对照](evidence/camera-raw-integration/parity.json) · [独立蒙版服务](evidence/camera-raw-integration/standalone-mask.json)

### 本次修复与签收范围

- 旧作品初测时，直接关掉图层会使保护区最大相差 2/65,535。修复沿用真实图层输入的透明度，在最终色彩转换后恢复保护区的历史样本。120 × 80 旧照片的 9,484 个保护像素最大差变为零，112 个选中像素全部增亮。采用前、禁用、撤销和零覆盖对照 TIFF 的 SHA 完全一致。另有旧色调、裁切、软边拼块、透明 PNG/TIFF 拉直的逐像素回归。[修复前](evidence/camera-raw-integration/legacy-before.json) · [修复后](evidence/camera-raw-integration/legacy-final.json)
- 61 MP 水鸟在第一次调局部曝光时，单像素校验引发了 980,254,720 字节中间区申请。现在按实际输出块取蒙版，只补入插值边界，同一单像素查询限于 15 × 15。人像首次复测中，测试程序在替换编辑器时提前终止了共享引擎。修正测试生命周期之后，两张图均完成了实际编辑器重开和导出。[Core Image 原始日志](evidence/camera-raw-integration/r1-bird-coreimage.log) · [旧人像失败报告](evidence/camera-raw-integration/r1-portrait.json) · [水鸟复测](evidence/camera-raw-integration/r2-bird.json) · [人像复测](evidence/camera-raw-integration/r2-portrait.json)
- Classic 首轮修复前的暖 p50 / p95 为 18.60 / 37.14 ms。复合编辑复用与纹理强度无关的单通道高斯结果，每个外观核验自身的四个强度锚点。画布尺寸使用实际绘制的 CGImage。保真回归覆盖横竖画幅、带符号的 HDR、半透明和缓存失效。[原始超线样本](evidence/camera-raw-integration/r1-classic.json) · [逐项功能回归](evidence/camera-raw-integration/functional.json)

- 普通预设在 `00d54671` 的首轮通过，独立复测的 p95 为 61.98 ms，手调为 60.28 ms。采用事务现复用同一次操作的结果摘要，草稿与采用记录合并写入。最新探针另记同步命令耗时，按每对的首笔计算与第二笔复用拆分样本。主门槛保留全部 30 个暖样本。[上轮首测](evidence/camera-raw-integration/00d54671-final-paired.json) · [上轮复测](evidence/camera-raw-integration/00d54671-confirm-paired.json) · [本轮耗时分解](evidence/camera-raw-integration/paired-details.json)

`91c84f09` 的两轮 p95 分别为预设 59.432 / 手调 57.650 ms 和预设 62.415 / 手调 59.373 ms，两次都超出 SC-02。每轮各臂 15 次真实渲染、15 次位图回放和 30 次请求。对应 p95 帧的同步命令差为 0.143 / 0.181 ms，耗时差主要位于命令返回至画布开画之间。同一配对中的第二侧能复用第一侧的位图，两侧的原片与最终配方校验一致。两次失败继续计入发布评审。[首轮](evidence/camera-raw-integration/91c84f09-accepted-paired.json) · [复测](evidence/camera-raw-integration/91c84f09-recheck-paired.json)

额外的正、反起始顺序诊断按 `frameID`、提交 ID、修订和绘制时间戳关联原生窗口事件。相同的 30 个曝光值，每侧各发生一次实际渲染和一次位图命中。实际渲染的「提交至主线程发布」p95 为预设 50.38 / 手调 51.58 ms，发布至开画为 8.30 / 9.19 ms。同曝光且都重新渲染时，输入到画布返回的 p95 为预设 56.59 ms、手调 57.96 ms。两种操作在这组样本中都只提交一次。追踪会在主线程编码元数据，这两组数据用于定位。各阶段分位数单独计算。原生 GPU 完成时间未被此通路记录。[分段与缓存对照](evidence/camera-raw-integration/trace-comparison.json) · [复算工具](compare-window-traces.py)

旧草稿写入若晚于新版本到达，其版本校验会拒绝覆盖。保存时的配方作为不可变候选归档，期间继续做的调节会写到新父版本的草稿。两项回归分别强制旧写入延迟，并在保存后立即关闭、通过第二个数据库连接和新编辑器检查重开结果。[写入、备份与重开回归](../../Tests/RAWMasterUITests/PhotosDevelopmentIntegrationTests.swift)

Release 共通过 218 项相关回归，覆盖独立功能版原有的全部 94 项，失败和跳过均为零。MaskAI 独立包另通过 28 项不同测试，其 8 项服务性能指标全部达标，峰值 3,548,168,192 字节，预算为 4,000,000,000 字节。固定 Adobe 样本 78 个，包含 72 个可浏览条目和 6 个隐藏依赖，重复迁移新增零项。原生键盘物理输入、VoiceOver 实际朗读、六位摄影师走查、Lightroom Classic 实机导回，以及高级 Profile／景深的全量视觉对齐继续按对应规格验收。当前交付覆盖表内机器验收与已列明的 XMP 子集。[功能结果](evidence/camera-raw-integration/functional.json) · [交换能力边界](exchange-validation.md) · [030 智能精修研发交接](../030-ai-retouching/handoff.md)

主工作区中的交付包为 `output/preset-mask-integrated/RAWMaster.app`，同目录的 `model-pack/` 存放经校验的可选本地权重和运行库，`validation/` 存放导出的原尺寸图和原始日志。正式脚本打包并签名后，从交付副本启动了隔离资料库并通过 SQLite 完整性检查。[发布包收据](evidence/camera-raw-integration/build.json)

### 尚待签收的项目

| 项目 | 负责人和复验内容 |
| --- | --- |
| 普通预设 SC-02 | 编辑器与成像。已有逐帧数据能区分排队提交、主线程发布与 AppKit 开画，GPU 完成时刻仍未观测。后续若有可定位的优化，在同源、同窗尺寸、无 trace 的独立运行中复测原有 30 对门槛，并保留所有超线样本。 |
| 新目录默认开放 | QA 与产品。真实宿主已验证浏览、收藏、切换和取消待采用蒙版。待物理键盘与 VoiceOver 完成 T-021 / T006，摄影师任务走查按 V1 执行。 |
| Adobe 交换 | 格式与 QA。已从真实安装迁移 78 份 XMP。T012 仍需在 Lightroom Classic 中导回新写的 Basic 与点曲线，核对参数和省略字段。高级 Profile 与景深分别按 V7 验收。 |

可在仓库根目录复查签收读数。命令会为超过门槛的轮次返回非零并列出实测差异。它核对冻结的输入、解码器、30 对配方、绘制分辨率、延迟、模型计数与保护区数据。

```sh
python3 specs/031-preset-browser/verify-integration.py specs/031-preset-browser/evidence/camera-raw-integration --confirm
```

## 接收版本

基础编辑交付于 2026-11-22，提交为 `e2b9c68a6c88aa3ec73a231a863bd0d1df4ea434`。滤镜、预设目录和本地蒙版沿用这次交付的编辑预览、GPU 算子及导出入口。首个集成提交为 `0fd08108`。10 个共享文件逐项合并，保留新版降噪、超分辨率资源与保存时的发布协议。蒙版创建进入候选复核，镜头模糊的主体对焦仍使用原有入口。[独立功能基线](feature-validation.md) · [原引擎的逐项记录](../../docs/research/camera-raw-parity/performance-data.json)

原引擎归档的 Adobe、LightFlow 对比包含不同操作、输入和测量边界，报告保留已知的全局算子差距。下列协议用于签收本次预设与蒙版在该引擎上的具体路径。后续智能修图已单独归档。[030 研发交接](../030-ai-retouching/handoff.md)

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

命令使用 Release 测试配置并启用测试访问。先将固定的 FlashRaw 动态库置于 `output/tools/flashraw-target/release/`，设置 `RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"` 并导出该变量。样片路径、权重与参考时序文件见[输入清单](evidence/camera-raw-integration/inputs.json)。

Classic Filters 沿用 028 的 `RAWMASTER_EDITING_PERF_FILTER_ONLY=1` 窗口协议。031 的普通预设另以 `RAWMASTER_EDITING_PERF_PRESET_PAIR=1` 运行同一原生画布。在每一对测量中分别通过真实预设采用和手工曝光命令写入相同值，等待已接受的 settled 帧绘制完成，再 Undo 回到同一基线。交替交换两条路径的顺序，保存首对样本、30 对暖样本、两侧 p95、每轮配方一致性和源文件前后 SHA。该计时边界从离散采用到 settled 绘制返回。[028 的输入、环境变量与原始运行方法](../028-filter-experience/validation.md)

```sh
RAWMASTER_EDITING_PERF=1 RAWMASTER_EDITING_PERF_PRESET_PAIR=1 \
RAWMASTER_EDITING_PERF_SOURCE="$PWD/output/performance/acr-benchmark.ARW" \
RAWMASTER_EDITING_PERF_OUTPUT="$PWD/output/performance/preset-paired-$(date +%Y%m%d-%H%M%S)" \
RAWMASTER_LIGHTFLOW_REFERENCE="$PWD/output/lightflow-research/same-size-runtime.json" \
swift test -c release -Xswiftc -enable-testing --test-product RAWMasterUITests \
  --filter EditingInteractionPerformanceTests/testOptInRealRAWCompoundEditingCanvasPerformance
```

在实际候选版本上，027 的主体专项使用同一 AppKit 宿主。以下命令以已知能产生主体与背景的竖拍 RAW 开始。61 MP 样片另存一次结果。每次指定新的输出目录。

```sh
RAWMASTER_EDITING_PERF=1 RAWMASTER_EDITING_PERF_MASK_SUBJECT=1 \
RAWMASTER_EDITING_PERF_SOURCE="$PWD/output/preset-mask-fixtures/person.ARW" \
RAWMASTER_EDITING_PERF_OUTPUT="$PWD/output/performance/mask-subject-$(date +%Y%m%d-%H%M%S)" \
RAWMASTER_LIGHTFLOW_REFERENCE="$PWD/output/lightflow-research/same-size-runtime.json" \
swift test -c release -Xswiftc -enable-testing --test-product RAWMasterUITests \
  --filter EditingInteractionPerformanceTests/testOptInRealRAWCompoundEditingCanvasPerformance
```

计时从编辑器触发「主体」到主线程发布可采用的 Gray8 候选。冷请求和三十次重复请求分别取数。读取同一蒙版服务的真实计数，相对启动时的「精确命中 / 成功新建」应依次为首次主体 0/1、重复主体 30/1、首次背景 30/2、恢复主体 31/2。记录每次耗时、Gray8 哈希及前后景逐像素的互补关系。采用至 settled 画布绘制返回单独计时。开始首个请求前先等待基础画布 settled。红色叠层第一次可见和系统窗口合成仍需另外测量。预览 RAW 基图的填充和命中另行记录。

随后以实际编辑会话调节局部曝光，关闭编辑器，按作品 ID 从磁盘读取配方并导出原尺寸 16 位 TIFF。记录源、冻结 PNG 和各 TIFF 的哈希，检查方向、尺寸和位深。另导出仅禁用该图层的对照。如果禁用会退回旧渲染器，再导出同 V3 路径、零覆盖的对照。逐行比较 16 位 RGBA 样本，冻结遮罩为零处取最大通道差，覆盖 ≥0.5 处统计增亮像素和 RGB 总增量。Release 专项对自然开关图层的保护区仍要求零差。RSS 在首次请求前、首次生成后、编辑器关闭后和主成片写出后取样，峰值属于整个进程。两份诊断对照的开销单列，不并入主成片的时间和内存读数。

独立旧作品夹具已重现同 V3 前缀保护区差 **0**、自然开关回到旧前缀时差 **2/65,535**。9,484 个保护像素和 112 个选中像素均来自同一张 120×80 自制图片。目标引擎需用此例检查旧作品兼容，同时以真实 RAW 验证显示、局部效果和导出。[原始输入、候选与对照](../027-mask-ai-raw-integration/editor-validation.md#旧作品开关图层的两组对照)

独立 `PerformanceAcceptanceTests` 的结果只作为服务对照。指定新的 `MASK_AI_PERFORMANCE_OUTPUT` 目录可保留旧基线。
