# RAWMaster

面向大量 RAW 拍摄的 Mac 原生选片工具。首个本地 MVP 已实现，可在本机离线使用；后续服务器、同步、自动排除与完整显影仍按独立阶段推进。

## 运行

已构建应用位于 `output/RAWMaster.app`，双击打开。重新构建（首次先准备下方固定版本的元数据工具）：

```sh
./scripts/build-app.sh release
open output/RAWMaster.app
```

首次构建自动分组组件前，准备固定的官方 ExifTool 源码；打包脚本校验提交与文件内容，应用运行时使用包内副本，不依赖全局安装：

```sh
mkdir -p output/tools
git clone https://github.com/exiftool/exiftool.git output/tools/exiftool
git -C output/tools/exiftool checkout --detach 2200871d9cef988051d2a99d67df3bda6cbb30a8
```

需要 macOS SDK / Swift 6 工具链。产品面向 Apple M4 及以后；当前验收环境是 M4 Max、128 GB、macOS 27.0.1。包的最低构建目标为 macOS 15，不代表旧系统或低配机型已完成兼容验收。当前应用为本机自用的临时签名构建，尚无公证及正式发布流程。运行时使用系统框架及包内固定的 ExifTool 13.59 元数据组件，无第三方数据库或同步服务依赖。

## 使用

“RAWMaster → 设置…（⌘,）”可选择浅色、深色或跟随 macOS，首次默认跟随系统（含系统自动日夜切换）。浅色使用 C2，深色使用 C1；手动档联动应用界面、应用内图标与运行中 Dock。Finder / Spotlight / 退出后的图标仍按 macOS 的图标外观偏好；macOS 15 使用静态浅色后备资源，不代表旧系统已完成兼容验收。见 [图标规格](specs/003-app-icon/spec.md)。

1. 点击“接入素材”，通过“选择…”指定拍摄目录；选择原地接入或复制到新工作目录。复制导入会校验副本。外置盘建议始终通过系统选择器选取，以取得文件访问上下文。
2. 网格浏览，`E` 看单张，`C` 比较 2–4 张；按住 ⌘ 点击多选，⇧ 点击连续选择。每个导入会话内按文件名的数字自然顺序显示；手动组保留保存的组内顺序。连拍不会被自动折叠或排除。
3. `P` 保留，`X` 排除，`U` 清除决定，`0–5` 设星级，`⌘Z` 按实际顺序撤销本次运行中的选片与组操作。决定、组关系和补偿操作写入本地数据库；重启保留决定。
4. `Z` 按需解码 RAW 并查看原始像素，再按一次恢复适合窗口。可缩放、平移及同步比较。RAW 使用固定基础渲染，色调可能与相机内嵌 JPEG 不同，不提供调色。
5. 将所选建立为手动拍摄组。管理组可改名称、用途、保护、拆分或合并；先预览影响，合并参与冲突逐项选择。序列参与与保留/排除分别保存；排除照片不会删除原片或破坏序列。“最近组操作…”可在重启后复核恢复，冲突时不覆盖后续修改。
6. 缺片或目录移动后，从素材信息或会话菜单“重新定位位置…”选择原始来源 / 受管副本；只读核验完整 SHA256，审阅后才应用匹配，保留原有选片身份。
7. “交付精选”把保留或显式选择的原片复制到独立目录，并输出 CSV / JSON 清单。清单覆盖当前范围所有已登记素材，标明复制结果与扫描覆盖。RAW+JPEG 伴随文件需分别选择，不会自动补选。

默认资料库：`~/Library/Application Support/RAWMaster/library.sqlite`。原片和用户资料库不会写进仓库；仓库另包含经用户授权的低分辨率JPEG测试衍生图。调试时可通过 `--library /absolute/path/library.sqlite` 或 `RAWMASTER_LIBRARY_PATH` 指定独立资料库。备份资料库前应退出应用；WAL 工作期间不能只复制主文件。原地接入并未增加安全副本，交付副本也不等同独立备份。

## 验证与研发文档

个人试用接入：[新导入自动分组与标注复核](docs/planning/16-automatic-grouping-personal-trial.md)。完整导入后自动生成“待复核”连拍/间隔组，保留全部照片，可从“最近组操作…”整批恢复；这是用户授权的人工试用，不代表独立质量验收通过。[005序列堆叠](docs/planning/10-automatic-sequence-stacks-review.md)的历史重跑与进一步界面增量继续独立推进。旧标注、误例和基线保留；[离线HTML标注工具](docs/diagnostics/sequence-review-report.md)只保存独立修订草稿。算法及CV/机器学习/多模态评估见[技术方案](docs/planning/12-sequence-grouping-algorithms.md)。

M2a 已获批准并分阶段实现：[功能取舍与体验方案](docs/planning/09-next-batch-review.md)、[004 规格](specs/004-client-next-batch/spec.md)、[技术计划](specs/004-client-next-batch/plan.md)、[实际验证与限制](specs/004-client-next-batch/validation.md)。主题三档、原片重新定位、人工组编辑与恢复已实现。连拍已有开发组和独立边界样本；时间窗试评估未建立通过验收的生产规则，按 SC05 仅交付 [隔离诊断与评估](docs/diagnostics/README.md)，暂不提供正式建议入口。最终普通测试与同机发布性能门通过；前两次绘制波动及桌面矩阵限制保留于验证记录。

```sh
swift test --jobs 4
swift run RAWMasterDiagnostics /absolute/path/photo.ARW --output output/probe --smoke
```

诊断工具使用应用同一套预览和 RAW 解码代码。可选界面布局诊断：设置 `RAWMASTER_OFFSCREEN_SNAPSHOT_DIR` 和 `RAWMASTER_OFFSCREEN_LIBRARY` 后运行 `swift test --filter testOptionalOffscreenWorkbenchSnapshot`。

- [M1 规格](specs/001-local-culling/spec.md)、[实现计划](specs/001-local-culling/plan.md)、[任务](specs/001-local-culling/tasks.md)
- [实际验收记录与限制](specs/001-local-culling/validation.md)
- [SDD 规划总览](docs/planning/00-sdd-planning-overview.md)、[客户端体验确认](docs/planning/07-m1-client-experience-review.md)、[数据库与同步评估](docs/planning/08-local-database-and-sync-evaluation.md)

项目按规格 → 技术计划 → 任务 → 实现 → 验收推进，参考 GitHub Spec Kit；尚未安装其 CLI。SQLite 为当前领域状态的权威存储；操作记录保留稳定实体 ID 与版本。Automerge 已完成独立冲突保存/恢复小实验，未接入应用运行时，网络协议和多端冲突体验尚未实现。

## 图片交互性能回归

2026-10-22 起，普通测试包含立即单击、双击/多选、导航跟随、旧图片结果隔离及图像资源限制的回归。发布前另外执行：

```sh
./scripts/test-image-performance.sh --source /absolute/path/to/RAW-directory --output output/performance/current
```

脚本顺序测试网格与胶片条输入、真实 RAW 预览/解码、连续切换、取消、2–4 张比较及画布离屏绘制，保存 `ui.json`、`image.json`、`summary.json` 和日志。输出目录必须是新目录或空目录；每段测试有 180 秒超时，超时会终止该测试进程并留下失败记录。缺少样本、超时、未生成报告或超出预算会失败。真实 RAW 目录应包含至少 15 张受支持文件；原片只读，交互测试使用临时资料库。

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
