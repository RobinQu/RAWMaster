# 照片导出调研 · Lightroom、LightFlow、AlcedoStudio、Reframe 与 RAWMaster

2026-11-22，上海。Lightroom 核对 Adobe 桌面版与 Classic 的官方帮助。LightFlow 下载当日发布的应用并在本地实际导出。AlcedoStudio 阅读固定提交的 QML、C++ 及测试。Reframe 以 REA 检查本机发行包并测量开发者截图。RAWMaster 验证了工作台交互、预设文件交换及原生出图。[机器可读证据](evidence.json) · [竞品张数限制](batch-limits.md) · [水印样式研究](reframe-styles.md)

## 哪些差异改变了设计

| 决策 | 参照中的差异 | RAWMaster 取舍 |
| --- | --- | --- |
| 用户先选什么 | Lightroom 桌面版先选用途，自定义选项分层。LightFlow 同时提供紧凑对话框和完整工作区，可见选片与队列。Alcedo 在检查器内配置、向待导队列加片。 | 保留原生非模态工作台。常用交付只需对照用途、范围、目录。逐张构图、输出名和可用性同屏。 |
| 什么时候决定交付哪一版 | LightFlow 提交时复制输出设置，到执行单张时才读编辑。Alcedo 的入队代码保存已提交的编辑快照。RAWMaster 同时有实时调整、采用版本和独立归档产物。 | 冻结本次实际输入及配方。审阅、换页、继续编辑或重试，都能解释交出的版本。 |
| 如何对待定位信息 | Lightroom Classic 可移除定位。LightFlow 的网页与打印预设在实际成品上给出了相反的 GPS 结果。Alcedo 的标准与 Web 预设也有不同默认值。 | 分享成片默认去 GPS，在元数据栏显示实际策略。复制原件完整保留其嵌入信息。 |
| 成功如何计算 | LightFlow 为每张记录状态，支持取消和单项重试。Alcedo 在临时文件完成后提交。RAWMaster 的单张导出已有可核验收据，批量路径只返回一组 URL。 | 逐项记录实际路径和内容哈希，批次显示已完成、待找回、失败、跳过及已取消。估算体积与实际字节分别展示。 |
| 交付时如何加边框和署名 | Reframe 把 EXIF、文字、Logo 放进照片或边框，也能统一一组横竖照片的外框比例。Lightroom 将水印放入导出设置，Alcedo 可整套复用输出参数。 | 在导出工作台用一个版式处理一批照片，逐张取 EXIF。用户可单换版式，或一次套用、分享包含版式的完整导出预设。 |
| 上千张怎样选 | Lightroom 显示本次选中张数。Alcedo 的 36 行明细和 200 张排序阈值独立于真实队列。 | 列表分开记录候选总数、全局勾选数和当前筛选结果。RAWMaster 单批最多勾选 2,000 张，超限必须由用户明确减选。[逐路径核对](batch-limits.md) |

## Lightroom 官方手册

- **Lightroom 桌面版。** 共享菜单提供小 JPEG、大 JPEG、原片、上次设置及自定义入口。小 JPEG 按长边 2048 px 等比缩放。自定义先给格式、尺寸、质量和水印，更多选项包括元数据、命名、输出锐化及色彩空间。确认按钮显示张数。macOS 用上次设置快速导出时会沿用目的地，给 RAWMaster 的启发是复用时也应显示目标目录。[Adobe《导出或共享您的照片》](https://helpx.adobe.com/cn/lightroom/desktop/save-share-and-export/save-share-photos.html)
- **Lightroom Classic。** 磁盘导出把目的地、命名、格式与色域、调整大小、锐化、元数据、水印及后期处理列为独立设置。原始格式关闭重新编码选项，RAW 的元数据更改可随 sidecar 交付。遇重名可询问、另起名、覆盖或跳过。宽高边界和长边各有不同几何语义，可禁止放大。PPI 服务于印刷换算。输出锐化在显影锐化之外按屏幕、哑光纸或光面纸和强度设置。[Adobe《将文件导出到磁盘或 CD》](https://helpx.adobe.com/cn/lightroom-classic/desktop/export-photos/export-files-disk-or-cd.html)
- **格式决定哪些选项有意义。** Classic 手册列出 JPEG、JPEG XL、AVIF、PSD、TIFF、PNG、DNG 和原始文件。可限制 JPEG 文件大小，TIFF 有 ZIP、LZW 或无压缩。选择输出色彩空间会同时转换像素和标记配置文件。这是 RAWMaster 把质量、无损压缩、位深和颜色做成条件控件的依据。[Adobe Classic 文件设置](https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-files-disk-or-cd.html)
- **同一批做几份。** Classic 中点击预设名称可载入并修改，勾选多个预设则按各套设定批量运行，三个源与两套预设会规划六份输出。可分预设指定目录，命名冲突时会用预设名区分。命名预设与上次手动导出的设置各自管理。这为 RAWMaster 后续支持网页、印刷同时交付提供了明确的计数方式。[Adobe《导出照片的基本工作流程》](https://helpx.adobe.com/cn/lightroom-classic/desktop/export-photos/exporting-photos-basic-workflow.html) · [Adobe《导出预设以及其他设置》](https://helpx.adobe.com/cn/lightroom-classic/desktop/export-photos/export-presets-settings-plug-ins.html)

## LightFlow 发布站点与实际成品

下载的应用构建为 `20261111155800-2d41ab1`，路由清单版本 `e2d6bcaa`。本机快照保存 61 份资源，共 43,353,764 字节，含 HTML、CSS、可达应用脚本、像素 worker、编解码 worker 和 WASM。下载围绕可运行的导出链路。REA 静态图定位到编码 worker，导出界面、持久队列与像素逻辑另对照发布字节和格式化副本。浏览器观测使用本地临时资料库与合成图片。[公开站点](https://lightflow.dev/) · [本次下载清单](../../output/research/export-panel/lightflow/manifest.json) · [REA 取证记录](../../output/research/export-panel/lightflow/rea-evidence.json)

| 从哪一层追踪 | 发布代码中可确认的功能 |
| --- | --- |
| 主界面与预设 | 完整工作区和紧凑面板共用设置与提交回调。工作区包含 9 个内置用途预设、用户预设、设置/选片、摘要和逐张队列。设置覆盖位置、命名、格式、色彩、尺寸、输出锐化、元数据、水印。格式矩阵为 JPEG/WebP 8 位、PNG 8/16、TIFF 8/16/32、AVIF 8/10/12。色域有 sRGB、Display P3、Adobe RGB、ProPhoto、Rec.2020。HDR 按格式校验并提示标签限制。[发布主包](https://lightflow.dev/assets/index-zP4kU_H7.js) |
| 提交与落盘 | `Ug` 复制输出设置，按选择顺序为每张建项。Downloads 的自动模式从四张起打 ZIP，小批可直接下载。有权限时可写选中目录。文件名可用序号、拍摄信息、输出宽高及预设名。目录目标有询问、唯一名、覆盖、跳过及子目录处理。`yq` 推进单项，记录结果、错误和实际字节。队列保存于 `export.queue`，恢复函数 `ov` 会把未完成项标为中断。[主包的原始字节位置](evidence.json) · [包含队列的发布主包](https://lightflow.dev/assets/index-zP4kU_H7.js) |
| 尺寸、色彩与编码 | 像素 worker 的 `Ff` 请求完整源，执行时取该张编辑，按裁切与旋转求尺寸，再规划格式、色彩、元数据与水印。支持原尺寸、长边、短边、单边、包围盒、百万像素和百分比。按后端条件分派，分块渲染路径把像素行带送给编码器。部分配置可走本机专用分支。样本的五个编码任务均报告多线程 Rust/WASM。图像水印、目录冲突和重启恢复在本轮取到代码证据。[像素 worker](https://lightflow.dev/assets/worker-PmnZFHwu.js) · [编码 worker](https://lightflow.dev/assets/codecWorker-Dt1VOinP.js) |

用 Chromium 157 打开离线副本，从真实面板依次选择预设、提交、取得下载文件。输入是一张 3000 × 2000 的合成 JPEG，内嵌 sRGB、作者、版权和已知 GPS。下表给出成品文件实读值。[五个成品记录](../../output/research/export-panel/lightflow/replay/results.json) · [当时的面板](../../output/research/export-panel/lightflow/replay/web-2048-panel.png)

| 面板所选预设 | 成品像素 | 字节数 | 文件内核对 |
| --- | --- | ---: | --- |
| Web 2048 px sRGB | 2048 × 1365 | 99,284 | 渐进 JPEG，520 字节 sRGB ICC，300 ppi，作者与版权保留，GPS 移除。面板估算约 865 KB |
| Print TIFF 16-bit Adobe RGB | 3000 × 2000 | 2,773,410 | 三通道 BitsPerSample 均为 16，Adobe RGB (1998) ICC，300 ppi，GPS 保留 |
| PNG 16-bit | 3000 × 2000 | 739,791 | IHDR 位深 16，sRGB ICC，GPS 移除 |
| WebP lossless | 2560 × 1707 | 1,173,072 | WebP 容器，sRGB ICC，GPS 移除 |
| AVIF HDR | 3000 × 2000 | 17,831 | ffprobe 回读 10 位 4:4:4、PQ 与 BT.2020 原色，无 ICC，矩阵标记为 SMPTE 170M。证据只覆盖编码和标签。HDR 显示效果仍需参考设备评估 |

**RAW 调整是否真的写进成片。** 另生成一张 2400 × 1600 的 RGGB Bayer DNG，单通道马赛克、16 位容器，无内嵌 JPEG 预览。先按 Web 2048 预设导出，再在 Develop 将曝光从 0 调到 +1 EV，用同一预设再次导出。两张均为 2048 × 1365、带 sRGB ICC 的 JPEG，文件分别为 33,504 和 26,505 字节。解码后的 8 位亮度均值由 211.08 升到 234.37，DNG 哈希前后一致。该对照检验了 RAW 解码、编辑和导出的连通性。相机还原与 HDR 色彩精度另需参考样本和设备。[DNG 标签](../../output/research/export-panel/lightflow/replay/raw/input-tags.json) · [两次成品读回](../../output/research/export-panel/lightflow/replay/raw/results.json)

四张一起提交，真实下载得到一个通过 CRC 检查的 ZIP，三个小图保持 600 × 400、660 × 440、720 × 480。在另一批次取消四项后单独重试一张，仅该项完成并生成 WebP。文字水印开关的像素差位于所选的右下角。此轮运行覆盖 Downloads、ZIP、取消重试和文字水印。外部盘目录写入按发布代码核对。[ZIP 回读](../../output/research/export-panel/lightflow/replay/batch/results.json) · [取消与重试](../../output/research/export-panel/lightflow/replay/cancel-retry/results.json) · [水印像素对照](../../output/research/export-panel/lightflow/replay/watermark/results.json) · [AVIF 元信息](../../output/research/export-panel/lightflow/replay/avif-color.json)

复核发布代码时按 `evidence.json` 的资产 SHA-256 匹配原文件，再按 UTF-8 零基字节偏移找对应函数。例如主包 `Ug` 位于 744105，`yq` 位于 748717，像素 worker 的 `Ff` 位于 65565。格式化副本的一基行号另有对照。本机回放通过本地 HTTP 服务加载站点，并启用跨源隔离供 WASM worker 使用。完整快照保存在 Git 忽略的 `output/research/export-panel/lightflow/`。[下载的站点](../../output/research/export-panel/lightflow/site/) · [本机回放入口](../../output/research/export-panel/lightflow/replay.py) · [字节及行号对照](../../output/research/export-panel/lightflow/source-locations.json)

## AlcedoStudio 源码

取自公开 `main` 的固定提交 `61d59bc98afad3be7b0d855bebdb86d7b9225e62`。研究路径从导出检查器、待导队列和配方构造器一直到完整渲染、写盘及上游测试断言。本轮的结论来自源码阅读，未构建或运行 AlcedoStudio。[固定版本](https://github.com/zidage/AlcedoStudio/tree/61d59bc98afad3be7b0d855bebdb86d7b9225e62) · [本地源码索引](../../output/research/export-panel/alcedo/source-map.md)

| 源码追踪 | 对 RAWMaster 实施的意义 |
| --- | --- |
| QML 检查器让用户把图库选择加入队列。默认标准预设为 JPEG 95、原尺寸。七个内置预设包括网页、社交和 TIFF 16 等。Web 为长边 2048、质量 80、去 GPS，社交为 1080 × 1350 包围盒、质量 90、去 GPS。应用和保存预设时排除目录、子目录。[检查器提交](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/qml/ExportInspectorPanel.qml#L267-L297) · [预设定义](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/export_recipe_builder.cpp#L301-L361) · [目录处理](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/export_recipe_builder.cpp#L419-L435) | 预设可复用于另一组照片。上一次目录可以单独记忆，用户切换交付规格时看得见文件去哪里。 |
| 当前 SDR 面板支持 JPEG 8、PNG 8/16、TIFF 8/16/32、OpenEXR 16/32。宽高、长边、物理尺寸与 DPI 由配方统一换算并保持比例。命名后端使用每张真实拍摄信息及序号。HDR 来源有 Ultra HDR JPEG 分派，写端还要求 PQ/HLG 和编译时可用的 libultrahdr。旧格式表列出的 WebP、32 位 PNG 与此面板矩阵有出入。[格式能力](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/export_recipe_builder.cpp#L114-L142) · [尺寸](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/io/image/export_recipe.cpp#L287-L325) · [编码器约束](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/io/image/image_writer.cpp#L617-L710) · [旧格式表](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/docs/supported_raw_formats.md#L88-L100) | 把可用格式、位深、颜色和透明组合落实成一份能力表。面板、预检与写出端都读取它。 |
| `EnqueueExportTask` 锁定已提交的编辑图快照。全分辨率渲染执行器读取这份快照及输出色彩配置，编码在独立工作线程完成。测试给两次入队之间的照片增加 2 EV，再检查最终像素和 ICC。[锁定输入](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/app/export_service.cpp#L151-L171) · [渲染与编码](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/app/export_service.cpp#L260-L342) · [像素级断言](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/tests/app/library_history_and_export_test.cpp#L412-L465) | 成片测试应在入队后继续编辑，再读取两批实际输出。任务身份须包括实时配方内容。 |
| 标准界面显式把保留元数据、GPS 和 ICC 写入逐项配方。写端筛选 EXIF/XMP/IPTC、GPS、序列号与编辑历史，重建输出方向、尺寸等标签。容器分别处理。上游测试读取写出的 GPS、像素尺寸及 TIFF 位深。[策略构造](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/import_export.cpp#L1229-L1239) · [标签筛选](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/io/image/image_writer.cpp#L353-L387) · [GPS 测试](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/tests/io/image_writer_test.cpp#L921-L1001) | 每种成片格式都有独立的文件回读样例，元数据开关的有效性以最终文件为准。 |
| 规划先避开磁盘和同批名字，遇重名递增 ` (1)`。写入同目录临时文件后再提交。核心有排他与替换两种策略，检查器生成的兼容配方继承 `REPLACE`，预检到提交之间仍可能出现新占用。逐项状态区分缺源，所读入口未见运行中取消和单项重试。[规划与策略传递](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/import_export.cpp#L1192-L1239) · [兼容配方默认值](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/io/image/export_recipe.cpp#L263-L271) · [最终提交](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/app/export_service.cpp#L74-L135) · [队列结果](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/export_queue.cpp#L146-L169) | RAWMaster 的「保留两份」须一直约束到排他发布，遇新占用再分配唯一名并更新收据。队列保留逐项结果供核对。 |

## Reframe 的边框、水印与批量模板

少数派文章由 Reframe 开发者 boringfei 于 2025-05-04 撰写。开发者说明，EXIF、自定义文字及 Logo 既可放在照片内，也可放在边框上。可调颜色与粗细的细线、阴影和模糊背景用于相纸效果，固定外框比例用于横竖图混排。对工作台，这意味着选定「4∶5」时要明确它约束的是整个成品，用户应该能先看一张横图在竖框内的真实占比。[开发者在少数派的功能说明](https://sspai.com/post/98900)

App Store 的开发者说明将模板保存、批量导出、自有 Logo 和 EXIF 预设放在同一工作流。1.2.5 的版本记录给出了保全原构图和填满边框两种适配方式。1.1.31 描述了换模板时可保留部分元素，以及通过系统分享成片。RAWMaster 的目录边界、预设交换文件和导入确认属于本项目设计。[Reframe 中国区 App Store 产品页](https://apps.apple.com/cn/app/reframe-%E7%9B%B8%E6%9C%BA%E6%B0%B4%E5%8D%B0/id6483865815)

REA 从本机 Reframe 1.4.2（88）读出 623 项简体中文资源，核对了画内九宫定位、背景模糊、可选文字行、Logo 和留白控制。发行包中的 27 张演示底图未带这些水印。开发者商店第 2 图直接显示双栏参数带，第 3 图显示居中相纸展签；底带相对照片约为 55/366，另一张底部展签约为 61/329。这些比例来自截图，可见布局由 RAWMaster 自行实现。六种样式卡均选择 RAWMaster 的当前照片作为底图。[本机清单、截图与对应关系](reframe-styles.md) · [原生合成器](../../Sources/RAWMasterImaging/PhotoExportLayout.swift)

**落到一份可交给同事的设置。** Lightroom Classic 把可重复的导出设置保存为预设。Alcedo 的预设排除了目录。结合 Reframe 的版式模板，我们把交换单位定为一套交付规格。文件只声明要印哪些拍摄字段。收件人用自己的照片解析字段值，仍能在导入预览看到发件人提供的实际署名和图片标识。[Adobe Classic 导出预设](https://helpx.adobe.com/cn/lightroom-classic/desktop/export-photos/export-presets-settings-plug-ins.html) · [Alcedo 预设目录处理](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/export_recipe_builder.cpp#L419-L435)

## RAWMaster 当前工作树

**改造前基线。** 在 `b89702e8` 加当时未提交改动的隔离副本中，用临时 SQLite 和合成图片运行 11 项已有测试。另以 4 个观察用例复现下表行为。表中描述的是改造前的代码行为，供回归时比对。LightFlow 下载、Alcedo 克隆与测试原始日志保存在本机 `output/research/export-panel/`。[基线运行日志](../../output/research/export-panel/rawmaster/baseline-tests.log) · [命名复现实验](../../output/research/export-panel/rawmaster/naming-observation.log)

| 复现操作 | 观察结果 | 代码落点 |
| --- | --- | --- |
| 三张照片按名字筛到一张，从网格菜单的原件命令进入 | 实际工作台写出全部三张 JPEG，菜单意图和范围都变了 | [菜单分派](../../Sources/RAWMaster/RAWMasterApp.swift#L36) · [网格路由](../../Sources/RAWMaster/WorkbenchActions.swift#L56) · [重新取范围](../../Sources/RAWMaster/AppModel.swift#L750) |
| 选 A+B、打开导出，返回资料库只选 C，再点顶部「导出」 | 仍取 A+B | [复用旧选择](../../Sources/RAWMaster/WorkflowTabs.swift#L34) |
| 导出页把 X 交给工作台按键处理器 | 数据库中后台照片从未决定变为排除。此项通过原生事件处理器调用复现 | [快捷键分派](../../Sources/RAWMaster/AppModel.swift#L971) |
| 两张照片使用模板 `client.v2-{index}` | 第一张落成 `client.jpg`，第二张抛出重名，磁盘已有一份文件，持久成片收据为零。上层把拼好的名字交给下层又去了一次扩展名 | [模板拼名](../../Sources/RAWMaster/AppModel.swift#L780) · [批量写入](../../Sources/RAWMasterImaging/PhotoBatchRenderExporter.swift#L20) |

改造前，面板和执行函数会各自用 `scopedAssets` 筛在线文件，归档可用的离线项可能提前消失。批量循环逐项读取编辑状态，整批结束时才交回结果。单张版本已有 prepare/complete 和恢复。新版将成片工作台的范围与适用的版本解析集中到了独立入口，预览与成片同取版本。后续仍应将整批输入及成果持久化。[输入与批量入口](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [单项收据](../../Sources/RAWMaster/EditingController.swift) · [后续实施](plan.md)

**本次工作台。** 131 项浏览器断言覆盖工作台 30 项、制作与交换 59 项、大批次选片及任务 42 项。1,200 张合成列表在 1280 × 760 窗口挂载 11 行。2,001 张保留原选择，用户显式减至 2,000 张才可提交。两个独立浏览器实际下载、导入并重开预设，覆盖非当前模式参数、关闭中的署名与透明 Logo，以及接收方自己的选片、版本和目录。先前 28 项和 36 项记录为 v1 历史结果。[交互原型](prototype.html) · [v2 预设样本](assets/portfolio.rmexport.json) · [验收断言与文件摘要](evidence.json)

**原生成片。** 使用仓库中的 DJI FC9313 横幅和 Sony ILCE-1M2 竖幅，各自写出六种样式，共 12 张 JPEG，并逐张读回尺寸、日期和 ICC。独立原生测试另覆盖 JPEG、PNG16、TIFF16、16 位渐变、超过 16,384 像素的分块输出、透明 Logo、缺 EXIF、去 GPS 及嵌入色彩描述。1,200/2,001 张的交互样本复用三张照片，2,000 张真实 RAW 的持续编码速度、内存与暂存峰值留待现场测量。[实际原生样张清单](../../output/research/export-panel/rawmaster/native-samples/results.json) · [成片文件回读日志](../../output/research/export-panel/rawmaster/native-imaging-readback.log) · [完整验收条件](plan.md)

**跨端交换与原件。** Swift 生成一份仅清单、同时携带 TIFF 参数、署名和透明 PNG Logo 的 v2 预设。在独立 Chromium 环境中，经实际导入控件应用到另一组选片、版本和目录，再从浏览器导出回 Swift。接收端的本地范围不变，往返后的设置和 Logo 字节一致。原件模式另用临时资料库核对仅清单的零图片写入、选择一张时的字节相等和 2,001 张超限时尚未创建目录。离线用例验证已采用的归档在预览和成片中取同一张的 EXIF；未归档且不同的实时调整会提示找回原片或选择版本。[跨端往返](../../output/research/export-panel/rawmaster/native-integration/cross-runtime.json) · [原件验证](../../output/research/export-panel/rawmaster/native-integration/originals-results.json) · [归档预览和成片](../../output/research/export-panel/rawmaster/native-integration/external-archive.json)

本次实际工作树的 35 项 Swift 回归全部通过，包含完整 SwiftUI 工作台的样式卡点选、取消、应用、从底栏提交和成片读回。将 2,000 份内容各异的小图实际入库后，核对仅清单的 CSV、JSON 与原始入库 ID，三者完全一致。在同一个数据集，逐张 CSV 从旧输出的 164,988,248 字节降至 1,106,255 字节，JSON 继续保留整批授权和请求范围。[原生整合验证](../../output/research/export-panel/rawmaster/native-integration/result.json) · [2,000 行核对与新旧体积](../../output/research/export-panel/rawmaster/native-integration/limit-2000-readback.json)
