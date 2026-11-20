# 018 · 实际验证记录

2026-10-30，M4 Max / 128GB，当前集成工作树。前述研发验证仅操作隔离测试库与已授权样本；后续经用户明确要求，已执行文末记录的本机安装与真实资料库升级。以下工程验证与摄影质量/商业发布分开计数。

## 回归与审查

- 基线 `swift test --jobs 4`：610项、22条件跳过、0失败。
- 最终 `swift test --jobs 4`：**675项、26条件跳过、0失败，退出0**。六目标计数为180/30/230/19/206/10，详见 [final-tests.json](../../output/validation/018-native-editing/final-tests.json) 与 [完整日志](../../output/validation/018-native-editing/final-full-tests.log)。跳过的是要求真实RAW/运行时/手动布局等显式环境的测试，不代表其默认通过；下列独立运行另有证据。
- Core严格schema7迁移/约束、档案与输入/已返回结果、采用CAS、备份恢复、持久导出与重启均有回归。导出取消遇到目标冲突后不得复活；已完成成片被外部删除后只提示核对，不自动重建。
- Controller 11项通过，包含原片离线仍可使用档案、退出不调度新云任务、导出绑定发起素材、安装/回滚任务取消后等待子进程汇合。详见 [退出回归](../../output/validation/018-native-editing/ui-runtime-shutdown-tests.log)。
- 方案、实施方案、Core、Services、UI及新增持久导出均经独立审查；所发现的问题已修复并复审关闭，没有未解决P0/P1。审查记录在 `.slim/deepwork/018-*.md`。

## 实际RAW与本地AI闭环

固定样本 DSC05994.ARW：69,488,640字节；前后SHA256均为 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`。

| 路径 | 真实结果 | 证据 |
|---|---|---|
| Imaging独立配方 | 8626×5650 JPEG8/TIFF16，sRGB ICC；独立PNG8输入1265×828，不放大 | [real-raw](../../output/validation/018-native-editing/real-raw/) |
| 新受管v4原版decoder | Swift→Comfy→独立MLX，q4/8步/CFG1/KV；原生1280×832；整项96.153秒，采样约59秒 | [real-output.json](../../output/validation/018-native-editing/real-mlx-v4/real-output.json) |
| 原生Controller完整链路 | RAW曝光+裁切→9312×6208 PNG16基础版本→1254×836 PNG8/sRGB输入→纹理优化decoder→1248×832候选→显式采用revision1→基础JPEG、候选JPEG8/TIFF16；3条持久导出记录 | [完整回执](../../output/validation/018-native-editing/native-controller/native-controller-report.json) |

Controller测试109.209秒，含启动/采样/归档/导出等整个进程执行112.107秒；不作为单纯推理SLA。成功生成后的自动采用断言为否，随后测试显式调用采用仅用于工程链路验证，不冒充人工画质认可。原片hash、审阅/纳入/成对/组数据保持不变。云端未收到任何照片。

输入可能经模型所需的ImageOps.fit/Lanczos变为原生栅格尺寸；原始/归一化尺寸、SHA、sigma、模型/encoder/decoder/runtime/worker/node身份已随候选保留。TIFF16是导出容器，不能把8-bit AI输出宣称为16-bit原生细节或RAW动态范围；未知传感器有效位深继续未知。

[进程采样](../../output/validation/018-native-editing/native-controller/execution.json)为1秒`ps` RSS，单Python进程观察峰值4,419,680KiB、测试进程1,700,704KiB；**不等于Metal分配、统一内存总量或模型最低显存要求**。此前独立实验的GPU/统一内存数据仍按原研究记录解释。

## 安装包、进程与模型

最终运行时ID `rawmaster-comfymlx-v4-arm64-py312`，manifest SHA256 `48afecfca5cd75e1e25a7e662ee7555f288ccef896d94be2583e6980ac96e305`。

- 固定uv/CPython，Comfy和MLX分别独立环境，empty/private no-cache、offline/no-index、require-hashes、binary-only安装。没有客户侧pip临时解依赖或sdist编译。
- v4新目录安装、带空格路径 `Space Install/AI Runtime` 安装与节点/MLX operator健康通过；缺精确mflux wheel、损坏hash均拒绝，原active不变；同ID已识别失败目录可隔离修复。
- 模型断点续传、hash错误、已验证复用和目录穿越4项下载fixture通过；本次直接复用已授权私有评估模型，未再次下载或把模型放入分发包。
- 真机证据包含无token健康403、worker PID存在、1秒测试空闲策略后worker消失、取消等待worker退出、宿主停止；默认产品空闲阈值120秒。关键内存压力拒绝新任务测试通过。
- 原版与纹理优化均已通过新受管链路；这不替代跨图库纹理/摄影质量验收。

[服务验收汇总](../../output/validation/018-native-editing/services-handoff.json)、[下载测试](../../output/validation/018-native-editing/model-download-tests.log)、[带空格安装回执](../../output/validation/018-native-editing/Space%20Install/AI%20Runtime/active/receipt.json)。

## 打包与原生界面

`./scripts/build-app.sh release`通过，AI资源Bundle已包含在`.app`内；7个源资源、运行时包资源、应用资源逐字节一致。主应用和隔离评估Bundle的ad-hoc严格签名验证通过；移除签名后的可执行文件payload一致。见 [构建回执](../../output/validation/018-native-editing/app-build.json)、[资源hash](../../output/validation/018-native-editing/packaged-resource-sha256.json)。

18张原生离屏布局已检查，包含1100×720/1480×940、浅深主题、初修/裁切、候选同步比较、设置与导出；使用合成QA图片，仅证明布局。见 [布局目录](../../output/validation/018-native-editing/ui-layouts/)。

实际打包评估应用已用显式`--library`启动，进程仅打开真实Controller生成的隔离SQLite；[进程核对](../../output/validation/018-native-editing/evaluation-process.json)。用户解锁后已完成真实WindowServer交互验收；实操发现比较取消任务的迟到错误遮罩和草稿标题/采用语义问题，已修复、经独立复审并重打Release包。下方追加记录区分离屏布局与真实窗口证据。

## 外部验收门

| 门 | 本次状态 |
|---|---|
| G1 数据/原生体验 | 数据/控制器/离屏布局及本机打包窗口交互通过；范围为当前隔离样本与配置 |
| G2 摄影与色彩 | 实际RAW/ICC/几何/原生像素工程验证通过；独立肤色/羽毛/文字/直线/逆光夜景留出集和人工质量评价未完成 |
| G3 本地运行时/模型 | 本机离线安装/修复/生命周期及真实原版/纹理优化通过；仅研究评估；商业许可、新Mac、最低配置预算未通过 |
| G4 三家云服务 | 直接适配、Keychain绑定、请求/限流/未知结果/本地字节恢复测试通过；没有真实账号调用与费用/内容验收，不能标三家正式支持 |
| G5 成片/恢复 | JPEG/TIFF/ICC、无覆盖/中断恢复回归和真实三次成片通过；真实322,462,741字节档案备份/恢复、采用/输入/返回结果与3条导出回执核对通过 |

未执行付费云调用。当前ad-hoc签名不代表Developer ID签名、公证或可商业分发。没有自动把本地失败改为云上传，没有自动采用候选，没有将这些工程测试算作整个008/006质量深化完成。


## 真实备份/恢复追加验收

已对Controller保留的实际作品调用公开备份/恢复API，备份7个档案文件共322,462,741字节，恢复到全新数据库和档案根。两个SQLite `quick_check`均ok；317,550,406字节PNG16基础图、AI候选、输入、已返回产物hash、采用版本ID/revision1、job与3条成片回执均一致。恢复后的输入/结果URL指向新档案根。原始资料库11张业务表的语义hash和原RAW/reference hash不变；没有再次调用provider/GPU，也没有复制外部成片或原始相机文件。见 [summary.json](../../output/validation/018-native-editing/real-backup-restore/summary.json) 与 [完整证据](../../output/validation/018-native-editing/real-backup-restore/real-backup-restore-report.json)。


分发ZIP已执行CRC校验；运行时ZIP内3308个manifest条目（含9个符号链接）逐项hash/目标校验通过。应用ZIP15,234,429字节，运行时ZIP605,896,585字节，完整SHA256见 [distribution-archives.json](../../output/validation/018-native-editing/distribution-archives.json)。本机评估请使用 [隔离启动器](../../output/validation/018-native-editing/打开隔离评估版.command)，它仅接受本批fixture路径。 [交付浏览报告](../../output/validation/018-native-editing/delivery.html)汇总真实输出与验收边界。


## 解锁后的真实原生窗口验收（最终UI修复版）

- 通过：真实RAW初修草稿、持久原图/初修/AI版本、并排比较、快速切换后100%查看、明确采用初修后恢复采用AI、原生NSSavePanel导出JPEG与持久任务历史、退出重启后采用和导出保持。
- 在描述框逐键输入`pxg5e`，照片仍未决定、0星、未审，未被选片快捷键截获；本机/三家云配置可查看，云凭证为空且未启用、无付费调用。
- 从原生设置启动受管服务并观察ready；Command-Q后宿主/worker/应用汇合。最终修复版另做原生退出与显式隔离库重启核对。
- 快速比较切换实操发现旧RAW任务取消后的错误可覆盖已加载的新图，已用代次及取消检查修复；新增取消/过期错误和草稿采用语义共3项回归。修复后全UI目标 **183项、12条件跳过、0失败**；先前全模块675项回归仍作为其他未修改模块的检查点，未把两次测试相加。见 [UI测试计数](../../output/validation/018-native-editing/final-native-ui-tests.json)。
- 真实界面新增第4条成片收据`native-ui-adopted.jpg`，独立sips检查1248×832/JPEG8/sRGB ICC，文件hash与回执一致。采用revision由1经明确两次UI操作变为3；这是隔离验收操作，原E2E回执与恢复证据仍保留其当时revision1，不改写历史。
- 原RAW SHA再次核对不变；assets/admissions/triage/review/groups/membership/versions/jobs/archive_publications九张表语义hash均与原探针一致。

[真实窗口验收JSON](../../output/validation/018-native-editing/native-ui/window-acceptance.json)、[最终比较截图](../../output/validation/018-native-editing/native-ui/candidate-compare-final.png)、[原生导出成功](../../output/validation/018-native-editing/native-ui/native-export-completed.png)、[原生退出进程检查](../../output/validation/018-native-editing/native-ui/native-quit-process-check.json)。应用ZIP已刷新并验证其可执行文件与实际验收Release完全一致，运行时包未变化。


## 用户授权的本机试用安装

2026-10-30，用户要求安装至`/Applications`并在升级前备份。目标目录当时没有旧RAWMaster.app；已将实际验收的正常Bundle（非Evaluation标识）安装到 `/Applications/RAWMaster.app`，源与安装可执行文件SHA一致，严格ad-hoc签名校验通过，并启动到原有真实资料库。

备份目录：`/Users/robinqu/Library/Application Support/RAWMaster Backups/before-018-20261030-200551`。已完整复制应用支持目录（含编辑副本、导入回执、旧迁移备份、grouping key及SQLite WAL），逐文件校验14项；另以SQLite backup API生成schema6独立一致快照并执行完整integrity_check，同时备份用户设置。外部原始相机文件保留原位置，不包含在此资料库备份中。

升级后schema7/quick_check正常：原有23张业务表（含6928素材、7项目、49组/588成员）语义hash完全不变；原metadata两条保留，仅新增editingArchiveRoot。应用自动另建v6迁移快照。独立运行时已离线安装至用户应用支持目录/AI Runtime，MLX operator与Comfy节点健康通过；模型直接复用既有已测目录，没有再次下载或复制权重。没有执行AI生成或云调用。

[安装核验JSON](../../output/validation/018-native-editing/installation-verification.json)、[升级前备份定位](../../output/validation/018-native-editing/installation-backup.json)、[安装后窗口](../../output/validation/018-native-editing/installed-application-window.png)。
