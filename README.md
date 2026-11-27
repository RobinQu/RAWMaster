# RAWMaster

面向大量 RAW 拍摄的 AI 原生摄影工作流，沿用“初筛、精筛、初修、精修、导出”。本地选片、延时合成、原生初修、作品版本、本地 AI 工程链路和单张成片导出均已实现；当前 023 版本正在收口效果一致性、操作完成性能与安装验收，不能把研究候选当作已通过全部发布门。当前方向与路线见[AI摄影规划](docs/planning/16-ai-native-photography-workflow.md)。

## 运行

已构建应用位于 `output/RAWMaster.app`，双击打开。重新构建（首次先准备下方固定版本的元数据工具）：

```sh
./scripts/build-app.sh release
open output/RAWMaster.app
```

应用包必须包含经校验的离线 AI 运行时。可用 `RAWMASTER_RUNTIME_ARTIFACTS_DIR` 指向既有固定包目录，并用 `RAWMASTER_BUILD_VERSION` 指定本次构建版本；不得把本机模型权重或付费云凭证打进包内。FLUX.3 本机 worker 由 `scripts/build-app.sh` 在打包前用 `Modules/FluxWorker/build-worker.sh` 构建，再复制进 `RAWMasterAI` 资源包；首次需要网络准备 MLX C++ 源，之后使用 `Modules/FluxWorker/target` 缓存。单独运行 `swift build` 只用于不调用本机 FLUX 的开发或测试。

首次构建自动分组组件前，准备固定的官方 ExifTool 源码；打包脚本校验提交与文件内容，应用运行时使用包内副本，不依赖全局安装：

```sh
mkdir -p output/tools
git clone https://github.com/exiftool/exiftool.git output/tools/exiftool
git -C output/tools/exiftool checkout --detach 2200871d9cef988051d2a99d67df3bda6cbb30a8
```

需要 macOS SDK / Swift 6 工具链。产品面向 Apple M4 及以后；当前验收环境是 M4 Max、128 GB、macOS 27.0.1。包的最低构建目标为 macOS 15，不代表旧系统或低配机型已完成兼容验收。当前应用为本机自用的临时签名构建，尚无公证及正式发布流程。运行时使用系统框架及包内固定的 ExifTool 13.59 元数据组件，无第三方数据库或同步服务依赖。

## 使用

“RAWMaster → 设置…（⌘,）”可选择浅色、深色或跟随 macOS，首次默认跟随系统（含系统自动日夜切换）。浅色使用 C2，深色使用 C1；手动档联动应用界面、应用内图标与运行中 Dock。Finder / Spotlight / 退出后的图标仍按 macOS 的图标外观偏好；macOS 15 使用静态浅色后备资源，不代表旧系统已完成兼容验收。见 [图标规格](specs/003-app-icon/spec.md)。

1. 点击“接入素材”，选择来源、原地引用或复制方式，以及新建/追加目标项目。新批次先进入“导入与初筛”，尚未纳入的素材不出现在常规项目。
2. 首批登记即可浏览，`G`看网格、`E`看单张、`C`比较2–4张，⌘多选、⇧连续选择，Space切换当前照片选中，⇧+方向键扩展选择。初筛中`P`通过、`X`排除、`U`清除处置，不设置项目精选或星级。初筛操作自动保存，可撤销和从操作记录恢复。
3. 相容的唯一RAW/JPEG候选可关联成一张组合卡，可展开单文件并人工确认/解除。组合卡操作默认整对，冲突保留原值。快速预览优先JPEG；`Z`按需查看RAW原始像素，展开单文件时保留明确的查看范围。拍摄数和文件数分别显示。
4. 完整接入后自动生成待复核的连拍/间隔组；初筛会话顶部可“重新扫描分组”，只替换未经人工调整的自动组，失败或取消保留旧组，成功后可整批撤销。接入中断时先“继续接入”；“重新扫描来源目录”单独用于发现和核验文件。标题区显示整批状态，查看具体拍摄组只改变浏览范围。“检查预览风险”提供有限亮暗/低细节证据，不等于失焦或RAW曝光判定；分组为个人试用，没有自动排除规则启用，独立质量门尚未通过。
5. 点击“完成整批初筛…”核对纳入/排除、待复核、仅序列用途、异常与未分析项，当前正在查看子组时，摘要仍覆盖整批。确认人工初筛后纳入项目并关闭会话。未明确排除的正常素材默认纳入，保持未精筛/无新增星级；关闭不搬运或删除原片。
6. 项目中完成保留/排除、0–5星级、批量标签与比较；已纳入照片可从全部素材、导入记录或项目内直接进入原生初修与AI精修，按`D`或Return进入单张沉浸式初修，使用调整、滤镜、裁切、局部工具、版本候选及成片导出，不必先切换到项目。`⌘S`保存独立初修候选，`⌘Return`保存并退出；保存失败会留在编辑器，未修改时不会重复创建版本，保存候选不会自动改变当前采用版本。拍摄组卡片和组内列表提供属性编辑入口，名称、用途与结构保护在同一表单中保存并整体撤销；合并、拆分保留独立操作。组内多选可移除成员，单张右键可加入或移出同项目拍摄组，序列参与独立保存。项目内也可维护已纳入文件的双格式关联。
7. 导入历史保存来源及排除记录，可恢复未纳入素材，不覆盖项目后续评分和标签。旧项目原样保留，旧导入记录标为初筛状态未知；未完成接入可继续。缺片通过“重新定位位置…”只读核验后找回，身份不变。
8. 点击工具栏放大镜或按⌘F搜索文件名；平时不常驻搜索条。筛选图标打开右侧实时面板，调整日期、机型、星级、标签、决定、可用性和已审状态立即更新图片，不用“应用筛选”。不同条件同时满足，标题中的条件标签可逐项移除；Esc收起编辑器保留条件，清除按钮才移除查询。每个项目独立保存查询、排序、浏览位置和比较选择，重启可继续。浏览不标记已审；明确评分、决定或“审阅”菜单会记录已审，可单独标回未审。RAW+JPEG全体成员已审才计整次拍摄已审。
9. 批量标签默认追加，也支持移除和明确替换；先核对共有/部分标签和逐文件预览再应用，操作历史支持持久恢复，追加/移除保留各文件独有标签。
10. 项目“交付精选”支持RAW+JPEG、仅RAW、仅JPEG或全部原有格式，按已确认关联扩展当前查询范围内的伴随文件，不带出未匹配成员。预览文件数、容量和缺项；CSV/JSON逐文件记录结果、请求格式及缺项，不自动生成不存在的格式。仅序列用途不默认混入精选交付。

默认资料库：`~/Library/Application Support/RAWMaster/library.sqlite`。原片和用户资料库不会写进仓库；仓库另包含经用户授权的低分辨率JPEG测试衍生图。调试时可通过 `--library /absolute/path/library.sqlite` 或 `RAWMASTER_LIBRARY_PATH` 指定独立资料库。备份资料库前应退出应用；WAL 工作期间不能只复制主文件。原地接入并未增加安全副本，交付副本也不等同独立备份。

## 延时组视频合成

进入项目中用途为“延时”或“间隔拍摄”的组，点击组标题旁的“合成延时视频…”，也可使用组右键菜单或应用菜单。面板自动生成可播放预览；默认 1080p / 30 fps / H.264 MP4，可直接导出。速度和画幅放在默认页面；“高级设置”默认收起，包含光照、对齐、曝光关键帧和导出四个选项卡，提供去闪烁、平移稳定、手选主体参考区域、最大裁切、4K / 24–30 fps / HEVC 等设置。

合成使用完整组内明确“参与序列”的成员及人工顺序，不受当前搜索、星级或照片保留/排除筛选影响；已确认且两者都参与的 RAW+JPEG 只计一次，优先解码 RAW。参与原片缺失或读取失败会停止并提示，不能依靠隐藏当前文件跳过问题。预览只降低空间分辨率，帧序、抽帧和节奏与导出相同；修改设置后需重新生成预览。

去闪烁保留渐变光照，主体锚定首轮仅提供区域平移配准。低纹理、无法可靠配准或裁切超限时整片回退并提示，不合成边缘内容。此功能不提供任意三维主体跟踪、透视修复、光流补帧或自动白平衡平滑。只生成独立新 MP4，不修改原片/组状态，也不覆盖已有视频；取消会清理本次临时文件。见[规格](specs/010-timelapse-video/spec.md)、[实现方案](specs/010-timelapse-video/plan.md)与[验证记录](specs/010-timelapse-video/validation.md)。

## 验证与研发文档

涉及界面变更时，先在[全功能 HTML 原型](docs/ui/prototype/index.html)中走查，再对照原生应用验收。浏览器可直接打开仓库内的入口。[UI 研发约定](AGENTS.md) · [设计与验收流程](docs/ui/README.md) · [功能与规格对应表](docs/ui/coverage.md)

**当前交付入口：[023 效果一致性与版本闭环规格](specs/023-effects-delivery/spec.md)、[研发任务](specs/023-effects-delivery/tasks.md)、[实际验证记录](specs/023-effects-delivery/validation.md)。** 018 已实现原生制作、版本、AI 工程链路和成片导出；020 已安装基础影调、曲线与 Color Grading；021/022 为后续研究预览和效果修复。023 优先收口当前调整能力、操作完成性能、保存重放与安全安装，未通过的窗口或外部质量门必须明确保留。已有“交付精选”复制原文件与渲染导出是不同能力。

**Server 版本规划：[Server 1.0 总览](docs/planning/27-server-version-plan.md)、[040 功能设计](specs/040-server/spec.md)。** 架构为 gRPC + PostgreSQL + S3；一库一客户端，先规划归档、Direct／Relay、元数据逻辑备份与恢复、冷热数据，远程 AI／批处理作为 1.1。S3／ZFS 存储可靠性由现有 TrueNAS 冷备承担；本轮仅规划，未开始服务端实现。

本轮会话操作调整：[016 导入与初筛会话操作](specs/016-import-triage-actions/spec.md)、[验证记录](specs/016-import-triage-actions/validation.md)。

项目检索交付入口：[007 项目检索与审阅](specs/007-project-review/spec.md)、[研发任务](specs/007-project-review/tasks.md)、[验证记录](specs/007-project-review/validation.md)。本轮实现组合搜索、项目独立审阅进度与恢复、批量标签预览及持久恢复；schema5沿用升级前一致备份，旧评分不会推断为已审。搜索优化已与最新导入自动分组整合，完整回归、真实素材工作流及安装证据见[整合合同](specs/007-project-review/integration.md)和验证记录。

前轮交付：[006 导入初筛与项目精筛](specs/006-import-triage-workflow/spec.md)、[研发任务](specs/006-import-triage-workflow/tasks.md)、[验证与限制](specs/006-import-triage-workflow/validation.md)。本轮增加会话关闭/项目纳入、JPEG+RAW、预览风险证据、历史恢复、标签及格式交付。schema4升级前生成一致备份；验证使用隔离资料库，未自动迁移用户真实资料库。完整自动分组与摄影质量判定仍受独立验收约束。

个人试用接入：[新导入自动分组与标注复核](docs/planning/16-automatic-grouping-personal-trial.md)。完整导入后自动生成“待复核”连拍/间隔组，保留全部照片，可从“最近组操作…”整批恢复；这是用户授权的人工试用，不代表独立质量验收通过。[005序列堆叠](docs/planning/10-automatic-sequence-stacks-review.md)的历史重跑与进一步界面增量继续独立推进。旧标注、误例和基线保留；[离线HTML标注工具](docs/diagnostics/sequence-review-report.md)只保存独立修订草稿。算法及CV/机器学习/多模态评估见[技术方案](docs/planning/12-sequence-grouping-algorithms.md)。

M2a 已获批准并分阶段实现：[功能取舍与体验方案](docs/planning/09-next-batch-review.md)、[004 规格](specs/004-client-next-batch/spec.md)、[技术计划](specs/004-client-next-batch/plan.md)、[实际验证与限制](specs/004-client-next-batch/validation.md)。主题三档、原片重新定位、人工组编辑与恢复已实现。连拍已有开发组和独立边界样本；时间窗试评估未建立通过验收的生产规则，按 SC05 仅交付 [隔离诊断与评估](docs/diagnostics/README.md)，暂不提供正式建议入口。最终普通测试与同机发布性能门通过；前两次绘制波动及桌面矩阵限制保留于验证记录。

```sh
scripts/fetch-rust-dependencies.sh
swift test --jobs 4
swift run RAWMasterDiagnostics /absolute/path/photo.ARW --output output/probe --smoke
```

SwiftPM 构建插件在无网络、只读 Cargo 缓存的沙箱中运行，因此照片导出、图像核心和资料库三个 Rust 库都以 `cargo --offline --locked` 构建。首次检出或在任一 `Modules/*/Cargo.lock` 变更后先运行 `scripts/fetch-rust-dependencies.sh`：它下载并解包依赖到插件实际读取的 `~/.cargo`（需要网络，重复执行是幂等的）。之后 `swift build` / `swift test` 不再访问 crates.io，也不需要再下载或解包 crates。需要只校验缓存时可运行 `scripts/fetch-rust-dependencies.sh --check`。

诊断工具使用应用同一套预览和 RAW 解码代码。可选界面布局诊断：设置 `RAWMASTER_OFFSCREEN_SNAPSHOT_DIR` 和 `RAWMASTER_OFFSCREEN_LIBRARY` 后运行 `swift test --filter testOptionalOffscreenWorkbenchSnapshot`。

- [M1 规格](specs/001-local-culling/spec.md)、[实现计划](specs/001-local-culling/plan.md)、[任务](specs/001-local-culling/tasks.md)
- [实际验收记录与限制](specs/001-local-culling/validation.md)
- [SDD 规划总览](docs/planning/00-sdd-planning-overview.md)、[客户端体验确认](docs/planning/07-m1-client-experience-review.md)、[数据库与同步评估](docs/planning/08-local-database-and-sync-evaluation.md)

项目按规格 → 技术计划 → 任务 → 实现 → 验收推进，参考 GitHub Spec Kit；尚未安装其 CLI。SQLite 为当前领域状态的权威存储；操作记录保留稳定实体 ID 与版本。Automerge 已完成独立冲突保存/恢复小实验，未接入应用运行时，网络协议和多端冲突体验尚未实现。

## 图片交互性能回归

**当前性能入口：[036 渲染 Pipeline 与编辑 DAG 的性能水位](specs/036-render-pipeline-performance/spec.md)、[参考实现对照](docs/research/gpu-pipeline-references.md)、[实测记录](specs/036-render-pipeline-performance/validation.md)。** 画布定稿帧改为按视口分辨率构图后，9504×6336 原片上 50 个控件配方的定稿中位由 255.47 ms 降到 6.81 ms、P95 由 842.57 ms 降到 20.24 ms；产品 128 MB 位图缓存下松手重放的中位为 0.250 ms。1:1、保存与导出仍走原生像素。更早的门槛与记录见 [002](specs/002-image-interaction-performance/validation.md)。

2026-10-22 起，普通测试包含立即单击、双击/多选、导航跟随、旧图片结果隔离及图像资源限制的回归。发布前另外执行：

```sh
./scripts/test-image-performance.sh --source /absolute/path/to/RAW-directory --output output/performance/current
```

脚本顺序测试网格与胶片条输入、真实 RAW 预览/解码、连续切换、取消、2–4 张比较、画布离屏绘制，以及 50 项 FlashRaw 交互／canonical 算子序列，保存 `ui.json`、`image.json`、`interactive/interactive-performance.json`、`interactive-comparison.json`、`summary.json` 和日志。输出目录必须是新目录或空目录；UI、图像和交互算子测试分别有 180、180、300 秒超时，超时会终止该测试进程并留下失败记录。缺少样本、操作覆盖不全、透明帧、原片哈希变化、未生成报告或超出预算会失败。真实 RAW 目录应包含至少 15 张受支持文件；原片只读，交互测试使用临时资料库。算子回归要求可用的 FlashRaw 动态库，可用 `RAWMASTER_FLASHRAW_LIBRARY` 显式指定；默认交互中位数门槛为 50 ms，基线比较默认允许交互／settled 中位数分别回退 10%／20%。这些门槛只约束 RawMaster 发版回归，不构成 LightFlow 或 Camera Raw 的同口径等价证明。

同机同系统、同样本的后续版本还应比较前次通过的报告：

```sh
./scripts/test-image-performance.sh --source /absolute/path/to/RAW-directory --output output/performance/current --baseline-dir output/performance/previous
```

`--measure-only` 仅用于显式记录新环境基线，不执行时延门槛，不能作为发布通过依据。测试窗口内的原生接收器计时不包含操作系统的事件递送；真实桌面复查可启用 `RAWMASTER_INTERACTION_TRACE=/absolute/path/trace.jsonl`，再通过 `scripts/analyze-interaction-trace.py` 检查原生事件到选中和视图更新的时间。两类检查均不等同屏幕呈现帧测量。详细范围、预算、结果与限制见 [图片交互性能记录](specs/002-image-interaction-performance/validation.md)。

M2a 还包含后台找回期间的点击回归：`RAWMASTER_UI_PERF_RELOCATION=1 RAWMASTER_UI_PERF_GATE=1 RAWMASTER_UI_PERF_REPORT=/absolute/path/new-ui-report.json swift test -c release --jobs 4 --filter UIClickPerformanceTests`。该项只使用临时合成文件和真实找回流程，要求活动覆盖、完整哈希证据、取消汇合及业务状态不变；不将合成 IO 当作真实 RAW 解码负载。

## 自动分组离线回归数据集

用户已提供的六段标注素材被转换为低分辨率JPEG测试代理（最长边1024px），包含实际上下文和独立DNG/JPG资产。普通 `swift test --jobs 4` 会读取仓库内完整数据集，实际经过元数据读取、图像特征和分组检测，无需原始外置盘或网络。格式、来源映射、人工真值与行为基线分别保存，见[数据集合同](docs/fixtures/sequence-grouping-schema-v1.md)。

普通回归通过表示与已审行为基线一致，不代表自动分组已经达到人工标签质量门。独立执行：

```sh
./scripts/sequence-fixture-quality.sh
```

该命令保存完整机器评价；退出码0为质量通过，2为完成测量但质量未达，1为编译/执行/完整性或基线错误。当前质量尚未达标，已知误并/漏分和负例支持不足必须保留。JPEG转码会影响特征，不能把JPEG结果冒充RAW结果；原始RAW冻结结果摘要见[原片基线](docs/diagnostics/sequence-raw-baselines.json)。

GitHub Actions在macOS上运行同一回归、构建客户端，并单独发布严格质量状态和报告。CI的通过不代表M4硬件或所有RAW解码路径已验收。图像衍生物权利说明与代码分别约定，未自动授予通用素材许可。
