# 031 · 本地开发版本交付

本页保留独立功能版本的历史实测。基于 Camera Raw 提交 `e2b9c68a` 的集成候选位于 `output/preset-mask-integrated/RAWMaster.app`。打开照片编辑器，在左栏「滤镜」选择「预设目录」即可试用，随时可切回经典滤镜。[集成验收记录](integration-validation.md)

## 独立版本与复测

功能源码提交为 `1a7d6b35`（初版 `d0091997`），分支为 `codex/preset-mask-delivery`。在 Apple M4 Max 上合并运行常规编辑器、Core 和成像功能测试 **94/94**，含真实窗口、本机 Adobe 安装、真实相机样片和可选权重。另用独立 MaskAI 包跑模型、RAW、方向与服务功能测试 **27/27**，两组均零跳过，其中 7 项窗口、跨片与导出用例也在 Release 构建复跑通过。首次整组运行时发现既有滤镜的预算测试假设全进程缓存为空；修正夹具按尚可用内存制造同等压力后，整组复跑通过。[逐项测试与构建身份](evidence/feature-functional.json)

开发工作树建立时冻结了当时未提交的基础编辑源码。`2df67339` 为冻结点，`78505f04` 为该树的编译基线；这两项属于对齐交付方已有的代码。后续接入在目标版本上重放 `78505f04..1a7d6b35` 的功能与测试增量，再按联合验收单执行。030 的方案、视觉稿与 PoC 仍可以直接从主工作区的 Spec Kit 目录打开。[030 交接](../030-ai-retouching/handoff.md)

## 试用 Release 包

主工作区可直接打开 `output/preset-mask-release/RAWMaster.app`。这是从独立功能提交构建的 arm64 Release 0.1.0，交付副本的可执行文件、FlashRaw 和可选权重 SHA-256 均与构建收据一致。应用已通过本地签名校验，隔离启动后正常创建资料库，SQLite 完整性检查通过。包内含 FlashRaw 和经逐字节核对的 53 条迁移规则。开发构建和 Release 包的测试范围分别见[构建收据](evidence/feature-functional.json)。

左栏「照片工具 → 预设」可试用、保存和迁入预设。右栏「调整 → 蒙版」可直接选主体、背景并用画笔修正。需要点选、框选、天空或水面时，从「模型包」选择主工作区 `output/preset-mask-release/model-pack`。运行库和权重随该目录提供，可在本机验证安装。[模型与安装说明](../027-mask-ai-raw-integration/model-pack.md)

如需和已经打开的 RAWMaster 并行试用，可在主工作区执行 `open -n "$PWD/output/preset-mask-release/RAWMaster.app" --args --library "$PWD/output/preset-mask-release/trial.sqlite"`，新窗口会使用独立资料库。

## 滤镜预设

| 操作 | 当前开发实现 |
| --- | --- |
| 找到和试用外观 | 左栏默认显示原片、九个 Classic Filters、目录搜索、收藏和分组。切换到配置文件可查看其本张适用性。目录浏览只读元数据。对可试看的普通预设，焦点或悬停暂时改变主图，离开恢复 |
| 保存自己的做法 | 选中想复用的字段，可以保存明确的零值。应用时保留未勾选字段，Amount 从采用前的配方计算。命名、分组、复制、版本替换、删除、原生文件交换与撤销沿用同一图库和编辑会话 |
| 从其他软件迁入 | 手选 XMP、ZIP 或显式扫描本机 Adobe 目录。预检列出内容、依赖、源条件与缺失字段，确认才写入；可用的子集可单独审阅和采用。导出时区分授权原件、原生格式和新写 XMP 的可表示字段 |
| 在另一张照片上重建相同范围 | 个人预设可保存主体、背景、天空或水面的语义和局部参数。用户显式准备，按目标照片重算并预览，再确认一次采用。无目标、缺少模型、取消及换片都有明确处理。目录浏览和悬停不启动分割 |

## 真实 Adobe 安装的覆盖

冻结样本包含 53 个审核过的系统资源和 25 个用户资源，扫描得到 78 个不同内容、72 个可浏览条目以及 6 个隐藏依赖，重复迁移新增 0 个。12 条内部 Look 引用、1 条外部缺失引用以及 6 项相机基底要求分别报告。这个样本中，1 项 Reset 可以整项采用，7 项普通预设可确认应用部分参数，9 项可在本图用本地蒙版重建。其余条目保留原因和原件。15 项交换回归涵盖反序提交、重复导入、旧索引恢复，以及两阶段曝光的写出和显式零／省略回读。[冻结清单](contracts/migration-manifest-v1.json) · [交换实测](exchange-validation.md) · [逐级验收](validation.md)

| 资源 | 暂可执行的范围 | 保留的限制 |
| --- | --- | --- |
| 普通 XMP | 已映射的 Basic 字段和 RGB／分通道点曲线。能识别显式零与省略值，曝光按实际渲染器单位换算 | 受 Process Version、相机、依赖、字段和照片条件约束。独立 Lightroom Classic 导回、固定相机/配置文件的像素还原待 V3/V5 |
| 语义校正 38 项 | 9 个 Subject 和 9 个 Sky 可读取结构。其中 4 个 Subject、5 个 Sky 可显式用本地算法在本张重建，包括 Subject Soft 和 Sky Sunrise | 余下 9 个 Subject/Sky 有局部字段、曲线或 Amount 尚未匹配。8 个 Landscape、12 个人物局部项留档；天空与水面需要离线模型包。重建只承诺列出的本地操作 |
| Lens Blur 13 项 | 冻结样本中的 Reset 在本张复位镜头模糊，保留其他效果 | 其他 12 项的对焦、景深、散景和遮挡另按 V7 验证 |
| Profile / Look | 展示 2 个 Adaptive Profile 的依赖和状态；6 个隐藏静态 Look 可从依赖详情查看 | RIMM、增益表、HDR、LookTable 和上游 RAW 色彩前端按具体版本和样片验收，实时严格套用只对已满足条件的组合开放 |

## 可复查的相邻交付

- 真实 AppKit 测试在临时资料库中打开原生编辑器，挂载同一个左栏和蒙版面板，读取 1,075 项自有目录。通过搜索框定位最后一项并采用，目录请求滤镜缩略图 0 次。完整配方行首次选中只显示详情，显式预览与退出保持原配方和历史，采用后只有一笔新历史，撤销恢复上一种曝光。该测试覆盖辅助功能按钮，可听的 VoiceOver 输出和物理键盘仍在 V1 走查。[原生预设验证](native-validation.md)
- 027 的系统 Vision、可选点／框选模型、手工增减、不可变快照与 TIFF16 导出由同一编辑器使用。实拍样片、离线模型包、兼容旧 PNG 和取消/换片证据独立归档。[编辑器实测](../027-mask-ai-raw-integration/editor-validation.md) · [四张真实 RAW](../027-mask-ai-raw-integration/portrait-snow-validation.md) · [模型包](../027-mask-ai-raw-integration/model-pack.md)
- 030 的人像、风光、纪实智能修图及生成式专项保存在 Spec Kit 目录，后续开发可直接使用方案、交互稿、任务和 PoC。现有配对评分已在本地重新计算，与归档 JSON 逐字节一致。[030 研发交接](../030-ai-retouching/handoff.md)
