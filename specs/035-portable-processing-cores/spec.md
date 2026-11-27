# 035 · 可移植资料库与图像处理内核

截至 `main@b238c0ab`，`rawmaster-library` 已承接本地目录事务及持久任务，`rawmaster-image` 已提供旧 V3 点配方重放和独立的 AP1 场景执行入口。035 Batch 34 封存的功能证据覆盖 161 个控件 ID，正式发布性能门仍未通过。旧 V3 全链路仍以 Core Image／Metal 为主。新场景路径由 [037 色彩契约](../037-color-film-hdr/spec.md)、[038 DAG](../038-node-dag-workflow/spec.md) 和 [039 Rust 场景后端](../039-rust-scene-backend/spec.md) 共同定义，演进顺序以[联合实施和验收](roadmap.md)为准。[生产验收](acceptance.md) · [PoC 与复现](validation.md) · [资料库与队列实验](catalog-queue.md)

## 影响选型的实证

| 评审问题 | 实验给出的答案 |
| --- | --- |
| 能否直接照搬参考项目的 DAG？ | 固定提交的 AlcedoStudio 通用图可拓扑排序，产品 RGB 主链会拒绝扇出。LightFlow 发布版在 WebGPU 上交换两支路合成端口后，整帧结果改变，恢复连线后逐字节还原。采用有序端口、独立计划和资源寿命管理，RAWMaster 自己实现 RGB 分支与合成。[上游 C++ 对照](alcedo.md) · [发布包复演](lightflow.md) |
| 单张处理怎么提速？ | 同一 4K 浮点图从 4 次 dispatch 合成 1 次，常驻 GPU 的逐帧完成 P50 从 4.21 降到 1.56 ms。若每次完整回主存，融合 GPU 仍需 37.58 ms，CPU 参考为 4.92 ms。生产预览优先验证纹理直达画布，急需主存结果的小图也保留 CPU 路径。[计时与边界](validation.md) |
| 桌面／服务端能否共用？ | 两张真实照片的浮点输入用单一配方在 Linux CPU 批量重放，完整输出与 macOS CPU 各自同摘要。Linux 还用已有 CFlashRaw 桥从真实 ARW 直接解出裁块。Swift 的集成测试把两个内核连到产品画布。队列经 8 进程竞争和杀进程重领，旧 token 无法发布。[跨端回执](evidence/image-replay.json) · [任务恢复](catalog-queue.md) |

Rust 四带 Metal 定稿、全局色轮和冻结局部调色已有实拍回放、精度及回退证据，日常 V3 产品路径只在特定已验算配方和试用开关下使用这些接线。逐批范围、失败、修正和 APFS 附件验证保留在[生产验收](acceptance.md#batch-27-rust-半幅定稿与-apfs-附件换代)。

## 审阅边界与用户场景

配方作用于**单张照片的版本，以及一批照片各自的版本**。可视化编辑遵循 [038 的场景图与只读兼容图](../038-node-dag-workflow/spec.md)。验证从资料库、暗房与 032 导出工作台进入，按照片版本和会话修订核对画布帧。服务端能力由 [041](../041-server-image-editing/spec.md) 分别验收。

| 从哪里进入 | 对象、完成与退出 |
| --- | --- |
| [资料库 → 项目](../../docs/ui/prototype/index.html#library/project/river) | 给当前项目的照片筛选、打分、查询下一页。在后台提取缩略图。切走再返回同一项目时按已保存的排序、筛选和选择恢复。离线原片可浏览已有预览，重连按内容身份核验。[033](../033-library-lifecycle/spec.md) |
| [基础编辑](../../docs/ui/prototype/index.html#edit/basic)、[蒙版](../../docs/ui/prototype/index.html#edit/masks)、左栏预设和滤镜 | 开一张照片的指定版本，拖动曝光、采用滤镜、调蒙版范围。拖动只显示当前会话最新的请求。应用形成可撤销的新修订。取消或换片后，迟到的模型或 GPU 结果只能回到原请求，不能覆盖新照片。[025](../025-editing-workspace/prototype-review.md) · [027](../027-mask-ai-raw-integration/spec.md) · [028](../028-filter-experience/spec.md) |
| [暗房 → 快速 Prompt](../../docs/ui/prototype/index.html#edit/development) | 冻结当前构图、来源、配方、范围和模型输入。既有云端复核确认后才提交。生成文件登记为独立候选，只有明确采用才改作品的采用指针。取消、断网和迟到结果沿当前尝试回执恢复。[034 原生验收](../034-quick-prompt-editing/native-validation.md) |
| [导出工作台](../032-export-workspace/prototype.html) | 从选区或当前编辑版本发起。提交时冻结逐张来源、修订、输出预设、命名和目标。从「任务详情」或「制作任务」核对原批次，接回原目录和原片后明确继续余项。完成、取消和单项重试均关联原批次，可返回当前选片和编辑上下文。[032](../032-export-workspace/spec.md) · [原型与实际重启走查](../032-export-workspace/batch-continuation.md) |

后续若改变这些入口的控件、状态提示、重试或退出行为，按仓库 UI 流程先评审可操作原型，再用同一输入复验原生应用。[功能覆盖表](../../docs/ui/coverage.md)

## 从当前实现出发

| 当前边界 | 实施决定 |
| --- | --- |
| 本地目录 schema 已到 v10，035 早期迁移以 v8 为输入。Swift `LibraryStore` 仍处理部分业务，`Modules/LibraryCatalog` 提供本地目录、分页、资源登记、备份和迁移。 | 沿用原件、逻辑照片、版本、作品和位置的身份，按事务逐步收口跨端能力。SwiftUI 只请求当前页、订阅增量。先采查询计划、首屏和锁等待，再决定索引。 [当前 schema](../../Sources/RAWMasterCore/DatabaseSchema.swift) · [Rust 入口](../../Modules/LibraryCatalog/src/lib.rs) · [Swift 适配](../../Modules/LibraryCatalog/Swift/LibraryEngine.swift) |
| 当前 V3 使用扩展线性 sRGB、Core Image 与 Metal。RAW 原生曝光、白平衡等可发生在解码中。调整顺序含基础、曲线、滤镜、分级 LUT、局部细节、蒙版、修复及最终几何，部分路径有版本化的专门顺序。 | 用现有引擎制作逐种算子和组合的基准。每个可替代的旧语义有单独版本映射。迁移过程保留照片原配方、原引擎标记、资源摘要及回放能力。[V3 入口和顺序](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift) · [颜色上下文](../../Sources/RAWMasterImaging/DevelopmentColorEngineV3.swift) · [旧配方结构](../../Sources/RAWMasterCore/EditingModels.swift) |
| V3 预览和场景预览已有各自的缓存、请求代际和 worker。032 按版本分流到旧显影、已存成片或场景最终根。 | 以同一版本为预览和显影交付的像素权威。收拢算子登记、资源调度和回执，保留原件直交、元数据和已验证快路径。`PhotoExport` 继续承担布局、编码和文件交付，场景色调、域转换与成像均由[037](../037-color-film-hdr/spec.md)定义。[旧预览](../../Sources/RAWMasterImaging/DevelopmentPreviewService.swift) · [场景预览](../../Sources/RAWMasterImaging/DevelopmentScenePreviewV1.swift) · [批量导出](../../Sources/RAWMasterImaging/PhotoBatchRenderExporter.swift) |
| 现有 MaskAI 已有模型身份、取消、来源绑定、蒙版快照和性能用例。工作台还有原位修复和生成补丁的独立来源记录。 | 分割、去噪、超分和修复各声明输入与输出端口。生成候选是不可变资产，只有采用操作才生成新编辑版本。重放优先使用确切快照。[蒙版契约](../../experiments/MaskAI/Sources/MaskAI/SemanticModels.swift) · [修复规格](../030-ai-retouching/spec.md) |

035 的目录迁移从 v8 起保留内容身份和领域收据，v9 引入通用任务、领取记录与外部发布票据。当前打开目录按生产备份和受信 schema 校验运行。Quick Prompt 继续由原尝试收据追溯，导出分别申请 GPU 位图和 CPU 编码额度，外部文件校验暂存及目标后排他发布。[Rust 目录任务](../../Modules/LibraryCatalog/src/scheduler.rs) · [导出生产入口](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [编辑与 Prompt 入口](../../Sources/RAWMaster/EditingController.swift)

独立图编译器覆盖曝光、V3 基础调色、PCHIP 点曲线、手动色阶、颜色矩阵、滤镜 LUT、覆盖混合和局部曝光。桌面的完整 V3 成片由 Core Image 执行，滤镜参数、曝光增益和着色器资源由新内核提供。符合条件的曝光、基础调色及曲线色阶拖动可分别试用借纹理路径。服务端可重放这些已支持的节点和已冻结覆盖图。[实际纹理契约](evidence/image-metal-iosurface.md) · [原生窗口实测](evidence/native-metal-exposure.json) · [基础调色契约](pipeline.md#v3-基础调色节点) · [曲线与色阶契约](pipeline.md#v3-点曲线和色阶)

生产图的 v2 配方可按节点 ID 绑定多张已冻结蒙版。桌面宿主从已核验的原件生成覆盖平面，同一 RGBA FP32 帧、覆盖图和配方可经相同 C ABI 交给 Linux worker。已经用同一张 RAW 的天空和主体蒙版以及一款胶片模拟对照桌面 CPU、Metal 与 Linux CPU 和软件 Vulkan。[命名蒙版契约](pipeline.md#已实现的命名蒙版配方) · [双蒙版的原生与无界面验收](acceptance.md#batch-20-双语义蒙版的跨平台重放)

完整旧 V3 的 Rust 替换按产品路由验收。Batch 32 曾单独达到 P95，P50 仍超线。Batch 34 在同一封存构建的两次正式运行中，首次精确与定稿中位为 77–81 ms，上限分别为 24.35／25.92 ms。缩放平移 relative P95 约 21 ms，上限为 8 ms。批次的逐状态证据、完整显示偏差和失败原样保留。新的 FIT 和场景热态采用各自的测量边界。[Batch 34 结果](acceptance.md#同一封存构建的两次正式运行) · [036 性能规格](../036-render-pipeline-performance/spec.md)

## 两个库以及宿主

| 边界 | 对外契约与所有权 |
| --- | --- |
| `rawmaster-library`（现有 Rust crate） | SQLite 事务、keyset 查询、导入与去重、外部／受管原件、资产／版本／集合、快照引用、派生对象、任务日志和发布收据。引用内容用 SHA-256，卷、路径和客户端书签允许变化。对外提供分页、修订条件写入、不可变输入清单、任务状态差量及一致备份。生产状态与资源登记在同一权威事务提交。 |
| `rawmaster-image`（`Modules/ImageEdit`） | 原点配方 ABI 和 039 场景 ABI 已分别部署。Rust 逐步统一算子登记、带域的执行计划、资源生命周期与结构化回执。输入是有颜色、几何和所有权说明的帧／瓦片及明确资源绑定，输出为帧、覆盖或错误。候选版本登记属于宿主。C++ 参考、RAW／CMS／模型适配按等价性和设备能力使用。 |
| SwiftUI／服务端 worker | 同一进程可同时调用两库。宿主负责书签／对象存储授权、设备选择、主线程呈现、任务心跳与编码交付。服务端按来源摘要取内容，显式报告模型、解码器、后端和精度能力。任务发送版本化消息和内容身份。进程指针、本地绝对路径、GPU 纹理句柄只在本机适配器内使用。 |

**绑定与发布。** 两个 crate 各自输出 Rust `rlib`，桌面发布提供稳定 C ABI 的 `cdylib` 或静态包。SwiftPM 使用和目录库相同的版本／加载检查。能力与 ABI 握手先于打开会话。C 调用使用定长整数、显式长度、结构体大小、返回状态及配对释放函数。只在工作线程等待 GPU 或推理。Swift actor 负责一份会话的串行访问，MainActor 只接受与当前帧 ID／修订一致的完成事件。传出驻留纹理时持有原资源直到 GPU fence 和画布释放，客户端销毁请求仅撤销交付资格。[生产图像 C ABI](../../Modules/ImageEdit/include/rawmaster_image.h) · [生产目录调度 Swift 绑定](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) · [Swift 图像对拍](../../Tests/RAWMasterImagingTests/PortableImageIntegrationTests.swift) · [目录租约与迁移](../../Tests/RAWMasterCoreTests/CatalogProcessing035Tests.swift)

**本地与服务端。** 035 的 SQLite 租约和票据用于本地目录，WAL 数据库使用本机磁盘。服务端的持久化、对象存储和远端租约按 [040](../040-server/spec.md)／[041](../041-server-image-editing/spec.md) 执行。Linux CPU 和软件 Vulkan 的现有证据覆盖点配方。新的场景执行、RAW 校准、颜色变换及模型能力在对应后端逐项准入，物理 GPU 吞吐另测。[SQLite WAL](https://www.sqlite.org/wal.html)

## 通用图、精度和 GPU 的决定

1. **同一张图有三个层次。** 版本化配方描述输入端口、节点语义和资源。Rust 编译器从输出回溯验证、有序拓扑排序、推断类型及尺寸、找出共享子图及融合边界。执行计划绑定设备、工作区和帧。改变参数只更新所需常量和下游结果。改变节点顺序或连接时重新规划。具体域、缓存键、批量绑定和失败规则见[管线契约](pipeline.md)。
2. **颜色域按配方路由声明。** V3 兼容点配方采用扩展线性 sRGB、D65、预乘 RGBA、FP32。场景配方采用 037 的 ACEScg／AP1、ACES 白与预乘 F32。两个域都明确负值、超白、alpha 及非颜色覆盖端口。FP16 或其它近似传输按算子验证。旧 SDR 输出永远按原来源和原配方回放。[035 兼容域](pipeline.md#色彩控件与精度) · [037 场景域](../037-color-film-hdr/spec.md#从输入到输出的域)
3. **macOS 场景优先 Rust + 原生 Metal。** 035 的 wgpu／WGSL 和 C++ CPU 对照继续用于已覆盖的兼容点算子。跨端复用算子规格、类型和执行计划。Apple 解码、纹理和模型互操作由平台适配。逐像素分支可以融合，直方图、卷积、模型和编码有显式屏障。每张照片独立计算输出键。[039 场景执行](../039-rust-scene-backend/spec.md) · [035 wgpu 证据](validation.md)
4. **调度按资源和可重放性分配。** 交互拖动在内存中只保留每个会话最新请求。可恢复的导入、索引、已提交 AI、批导出持久化到 SQLite。队列控制全局 CPU、GPU、内存、IO、模型驻留与单目标写入，按步骤申请和释放。离线待重连，瞬态失败有限退避，永久错误终止，外部提交结果未知先对账。崩溃后的重领使用新 token，文件与收据一起校验。详见[租约、跨视图公平和恢复实验](catalog-queue.md)。

## 实施顺序和退出条件

| 边界 | 035 后续动作与退出条件 |
| --- | --- |
| 旧配方与升级 | 固定 v1–v3 原件、解码、滤镜表、蒙版、几何及成片见证。迁移用含旧版本、离线卷、受管原件的备份副本重放 v8→v10，核对关系、指纹、分页和恢复。已有版本按原配方回放。 |
| 旧显影替换 | 优先按封存矩阵中真实耗时最高且可等价的路由移植。严格核对 RAW 白平衡、滤镜强度、局部零覆盖、几何与像素。每批验证原生 FIT、原图取样和显影导出。记录实际后端、性能与内存，通过后替换该路由并保留等价回退。 |
| 目录与调度 | 多进程领取、断卷、磁盘满、取消与重领按原票据复验。每条提交最多一份有效发布收据。图像工作与目录查询共同跑混合负载，保留前台的资源保障。 |
| 跨端渲染 | 按能力分别放行点配方和场景作业。Linux CPU／软件 Vulkan 已有点配方证据。运行物理 GPU、目标 RAW／ICC 和真实混合负载前，按 041 能力表报告支持范围。 |

**建议评审批准的门槛（待实施验证）。** 像素方面，PoC 的有界输入点算子最大通道绝对差 ≤ `2e-6`，透明度与覆盖端点单独检查。正式兼容验收采用每个旧算法原有阈值，并用灰阶、ColorChecker、饱和广色域、透明边缘及真实 RAW 对照。性能方面先让相同 4K 驻留图的融合方案相对逐节点 GPU 的 P50 提升至少 25%。生产切换还须在同照片、同原生画布下达到既有预览／导出的 P95 和首件基线，冷启动、峰值常驻内存与显存也分别记账。资料库沿用 033 的常用查询温态首屏 P95 ≤ 300 ms 目标，必须同时报告首屏可见和后台导入时延。恢复方面，以乱序 ACK、多领取者、模型中断和写盘故障验证每个任务最多一份有效发布收据。 [既有编辑测量](../024-jpeg-display-proxy/editing-performance-comparison.md) · [032 导出基线](../032-export-workspace/performance.md) · [033 目录目标](../033-library-lifecycle/spec.md)

配方、颜色、执行器和端到端的共同退出条件见[联合实施和验收](roadmap.md#实施顺序与退出条件)。历史临界值、反例及失败样本保留在[生产验收](acceptance.md)和[PoC 验证](validation.md)。
