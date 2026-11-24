# 035 · 可移植资料库与图像处理内核

**功能验收完成，发布性能门待评审。** 实现基线为合并后的 `main@1b7df6b6`。沿用 `rawmaster-library` 作为目录的写入入口，新增独立的 `rawmaster-image`。桌面和服务端共用版本化算子、滤镜参数及资源契约。交互预览优先把中间数据留在 GPU，批处理按每张照片冻结输入，资料库、编辑和导出共用有资源预算的任务调度。[生产验收与回执](acceptance.md) · [PoC 实测与复现](validation.md) · [AlcedoStudio 源码](alcedo.md) · [LightFlow 发布包与 GPU 复演](lightflow.md) · [资料库与队列实验](catalog-queue.md)

## 影响选型的实证

| 评审问题 | 实验给出的答案 |
| --- | --- |
| 能否直接照搬参考项目的 DAG？ | 固定提交的 AlcedoStudio 通用图可拓扑排序，产品 RGB 主链会拒绝扇出。LightFlow 发布版在 WebGPU 上交换两支路合成端口后，整帧结果改变，恢复连线后逐字节还原。采用有序端口、独立计划和资源寿命管理，RAWMaster 自己实现 RGB 分支与合成。[上游 C++ 对照](alcedo.md) · [发布包复演](lightflow.md) |
| 单张处理怎么提速？ | 同一 4K 浮点图从 4 次 dispatch 合成 1 次，常驻 GPU 的逐帧完成 P50 从 4.21 降到 1.56 ms。若每次完整回主存，融合 GPU 仍需 37.58 ms，CPU 参考为 4.92 ms。生产预览优先验证纹理直达画布，急需主存结果的小图也保留 CPU 路径。[计时与边界](validation.md) |
| 桌面／服务端能否共用？ | 两张真实照片的浮点输入用单一配方在 Linux CPU 批量重放，完整输出与 macOS CPU 各自同摘要。Linux 还用已有 CFlashRaw 桥从真实 ARW 直接解出裁块。Swift 的集成测试把两个内核连到产品画布。队列经 8 进程竞争和杀进程重领，旧 token 无法发布。[跨端回执](evidence/image-replay.json) · [任务恢复](catalog-queue.md) |

主画布现有一条 Rust 四带 Metal 定稿试用路径。它已在两张已验证 RAW 的纯 PCHIP 曲线和手动色阶上通过完整显示对照、撤销和旧运行库回退。试用覆盖指定设备和原生尺寸，整套预览的时延门槛单独验证。macOS 队列的 APFS 附件首次创建和换代已有隔离实测，生产端仍沿用现有写入协议。[原生定稿设计](pipeline.md#主画布的-rust-半幅试用) · [Batch 27 验收](acceptance.md#batch-27-rust-半幅定稿与-apfs-附件换代)

Batch 28 新增全幅定稿缓存、去雾合并提交及冻结蒙版调色节点。已在桌面和 Linux CPU 重放相同的天空、主体与胶片配方。APFS 隔离验证也覆盖了内核限制下的签名助手、权限撤销与原票据重试。整套时延和软件 Vulkan 的色相精度仍有超线。[Batch 28 验收](acceptance.md#batch-28-分组定稿与冻结蒙版调色) · [资料库签名助手](catalog-queue.md#macos-受限签名助手的授权与交付)

Batch 29 修正了冻结蒙版调色的 Metal 黑白位舍入、次正规 alpha 和软件 Vulkan 色相。两张 RAW 的 32 个全幅状态在 Metal 逐位一致，软件 Vulkan 的两图采样通过原误差门。定稿另试用已清空的 Core Image 上下文，限定在主画布的已验证点运算。新增真实 App Sandbox 和 XPC 助手夹具，用原票据验证沙盒拒绝、排他发布和重复确认。[Batch 29 验收](acceptance.md#batch-29-跨后端精度与定稿上下文) · [局部调色数值契约](portable-local-mask-tone.md#batch-29-封存运行库复验)

## 审阅边界与用户场景

本规格把节点配方应用于**单张照片的版本，以及一批照片各自的版本**。可视化节点编辑器的交互另行立项。验证从既有资料库、暗房与导出工作台入口执行。桌面继续按照片版本和会话修订确认画布帧。服务端按冻结配方、资源摘要和所声明的后端执行。

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
| 工作树中的目录基线是 v8。Swift `LibraryStore` 仍处理部分业务，`Modules/LibraryCatalog` 已有 Rust 权威目录、查询分页、资源登记、备份及迁移 API，SwiftPM 插件已有装载流程。 | 以现有库为起点，把跨平台查询与事务逐项收口，沿用原件、逻辑照片、版本、作品和位置的身份。SwiftUI 只请求当前页、订阅增量。先采查询计划、首屏和锁等待，再决定索引。 [v8 schema](../../Sources/RAWMasterCore/DatabaseSchema.swift) · [Rust 入口](../../Modules/LibraryCatalog/src/lib.rs) · [Swift 适配](../../Modules/LibraryCatalog/Swift/LibraryEngine.swift) |
| 当前 V3 使用扩展线性 sRGB、Core Image 与 Metal。RAW 原生曝光、白平衡等可发生在解码中。调整顺序含基础、曲线、滤镜、分级 LUT、局部细节、蒙版、修复及最终几何，部分路径有版本化的专门顺序。 | 用现有引擎制作逐种算子和组合的基准。每个可替代的旧语义有单独版本映射。迁移过程保留照片原配方、原引擎标记、资源摘要及回放能力。[V3 入口和顺序](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift) · [颜色上下文](../../Sources/RAWMasterImaging/DevelopmentColorEngineV3.swift) · [旧配方结构](../../Sources/RAWMasterCore/EditingModels.swift) |
| 预览服务已有请求替代、缓存和原生 worker 生命周期管理。批量导出可走中性 JPEG 捷径、开发后像素或既有成片，有的路线会写 TIFF 中间文件。独立的 PhotoExport 负责交付相关工作。 | 把已有选择语义适配到共享调度，保留原件直交、元数据和有效快路径。需要显影的导出及预览调用同一个图，输出意图不同。既有 `PhotoExport` 作为布局／编码／文件交付依赖，避免引入另一套色调算子。[预览](../../Sources/RAWMasterImaging/DevelopmentPreviewService.swift) · [批量导出](../../Sources/RAWMasterImaging/PhotoBatchRenderExporter.swift) · [交付库](../../Modules/PhotoExport/) |
| 现有 MaskAI 已有模型身份、取消、来源绑定、蒙版快照和性能用例。工作台还有原位修复和生成补丁的独立来源记录。 | 分割、去噪、超分和修复各声明输入与输出端口。生成候选是不可变资产，只有采用操作才生成新编辑版本。重放优先使用确切快照。[蒙版契约](../../experiments/MaskAI/Sources/MaskAI/SemanticModels.swift) · [修复规格](../030-ai-retouching/spec.md) |

实现以 v8 的内容身份和原有领域收据作为迁移基线。v9 在同一目录库增加通用任务、领取记录和已准备外部文件的收据，生产打开时先完成备份和受信 schema 校验。Quick Prompt 的模型提交继续由原尝试收据追溯，调度器让本机 MLX 加入设备准入，并用已收到的候选登记收据收敛目录发布。导出的 GPU 位图阶段与 CPU 编码分开取额度，外部文件先校验暂存和目标，再进行排他发布。[Rust 目录任务入口](../../Modules/LibraryCatalog/src/scheduler.rs) · [导出生产入口](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [编辑与 Prompt 生产入口](../../Sources/RAWMaster/EditingController.swift)

独立图编译器覆盖曝光、V3 基础调色、PCHIP 点曲线、手动色阶、颜色矩阵、滤镜 LUT、覆盖混合和局部曝光。桌面的完整 V3 成片由 Core Image 执行，滤镜参数、曝光增益和着色器资源由新内核提供。符合条件的曝光、基础调色及曲线色阶拖动可分别试用借纹理路径。服务端可重放这些已支持的节点和已冻结覆盖图。[实际纹理契约](evidence/image-metal-iosurface.md) · [原生窗口实测](evidence/native-metal-exposure.json) · [基础调色契约](pipeline.md#v3-基础调色节点) · [曲线与色阶契约](pipeline.md#v3-点曲线和色阶)

生产图的 v2 配方可按节点 ID 绑定多张已冻结蒙版。桌面宿主从已核验的原件生成覆盖平面，同一 RGBA FP32 帧、覆盖图和配方可经相同 C ABI 交给 Linux worker。已经用同一张 RAW 的天空和主体蒙版以及一款胶片模拟对照桌面 CPU、Metal 与 Linux CPU 和软件 Vulkan。[命名蒙版契约](pipeline.md#已实现的命名蒙版配方) · [双蒙版的原生与无界面验收](acceptance.md#batch-20-双语义蒙版的跨平台重放)

在桌面定稿中，分带锐化、正向去雾及局部校验分组经过实片复验，可选择试用。独立 Rust Metal 探针从原生 RGBA16F 直接求值 FP32 DAG，通过硬件采样生成 FP32 半幅。合并每次 GPU 提交中的带数后，两张 RAW 的半幅位型全部匹配，其中一组混合编辑的最终显示仍有偏差。正式候选的精确定稿 P95 为 284.82 ms，高于 252.27 ms 门槛。[真实原件、差异和发布验收](acceptance.md#batch-26-分组归约与-apfs-互操作)

Batch 30 将全局色轮接入版本化 FP32 图，并在两张 RAW 上验证两端 CPU、Metal 与软件 Vulkan。桌面定稿仍由原色轮执行。冻结径向蒙版半幅和去雾最小值行缓冲已接入正常编辑服务，两项均在默认关闭的试用开关内。全片像素、撤销、旧库回退和真实时延见 [Batch 30 验收](acceptance.md#batch-30-全局色轮冻结局部调色与冷去雾)。

Batch 31 消除了独立色轮借入 Metal 纹理的实片舍入差，将该节点接入隔离的桌面定稿试用。两张 RAW 同时核验了局部蒙版的区域重绘、相同降噪邻域的复用和原有完整显示。导出工作台复用同一数据库读快照，逐件复查了原成片与持久票据。两次正式复验的首次精确和定稿时延仍超线。[Batch 31 验收](acceptance.md#batch-31-色轮定稿区域蒙版和读快照)

Batch 32 试用直接写入显示缓冲、清理后的半幅上下文复用、局部降噪和纹理分带检查及去雾 R32F 双带。目录核心在一个写事务内完成子项领取，结束批次时核对每个冻结序号的规范票据。正式 74 态的首次精确与定稿 P95 为 225.94 ms，通过 252.27 ms 上限。P50 仍超标，试用默认关闭。[Batch 32 实片、队列与发布验收](acceptance.md#batch-32-显示缓冲去雾引导与批次完成)

Batch 33 在原生局部清晰度和纹理上试用单次请求缓存，局部色温、色调和色轮试用在硬径向区域内核验。软件 Vulkan 的基础调色幂函数按 CPU 的 `libm` 精度处理，两张 RAW 的基础调整串接曲线符合 `2×10⁻⁶` 门槛。资料库已在 Linux 实际复现写满和 inode 耗尽，核验回滚及原成片确认。正式定稿中位时延仍超发布门槛。[Batch 33 验收](acceptance.md#batch-33-空间蒙版请求缓存与跨平台精度)

Batch 34 补齐了最后三个没有逐控件计时的功能 ID：已显影 JPEG／TIFF 的近似色温、相机 JPEG 的摄影降噪强度、以及带真实深度附属数据的 HEIC 上的 Lens Blur。三项都在正常预览服务上以两种已提交配方取 20 次暖态并核对不同的 sRGB 见证，由统一发布脚本生成、并入逐 ID 索引，Camera Raw 19.0 的 161 个稳定 ID 在 RAWMaster 侧全部有同一封存构建的实测。同一封存的两次正式运行仍未通过发布性能门：首个可见画面通过，首次精确与定稿的中位数为 77–81 ms 对 24.35／25.92 ms，画布缩放平移的 relative P95 稳定在约 21 ms 对 8 ms。功能与性能的完整签收范围、逐状态数据与待评审的门限口径见 [Batch 34 验收](acceptance.md#batch-34-已显影控件与发布验收)。

## 两个库以及宿主

| 边界 | 对外契约与所有权 |
| --- | --- |
| `rawmaster-library`（现有 Rust crate） | SQLite 事务、keyset 查询、导入与去重、外部／受管原件、资产／版本／集合、快照引用、派生对象、任务日志和发布收据。引用内容用 SHA-256，卷、路径和客户端书签允许变化。对外提供分页、修订条件写入、不可变输入清单、任务状态差量及一致备份。生产状态与资源登记在同一权威事务提交。 |
| `rawmaster-image`（生产路径为 `Modules/ImageEdit`） | Rust 拥有配方 IR、校验、算子规格、执行计划和作业取消检查。输入是有颜色、几何和所有权说明的帧／瓦片、资源解析器及设备能力。输出是帧、覆盖、候选资产或结构化错误。C 接口封装第三方 RAW／CMS／推理句柄。C++ 可实现经测量的向量化内核或接成熟后端。该库能独立从内存运行，无目录数据库、Swift、AppKit 或专属文件结构依赖。 |
| SwiftUI／服务端 worker | 同一进程可同时调用两库。宿主负责书签／对象存储授权、设备选择、主线程呈现、任务心跳与编码交付。服务端按来源摘要取内容，显式报告模型、解码器、后端和精度能力。任务发送版本化消息和内容身份。进程指针、本地绝对路径、GPU 纹理句柄只在本机适配器内使用。 |

```mermaid
flowchart LR
  U["SwiftUI 资料库 / 编辑 / 导出"] --> C["rawmaster-library · SQLite / 任务 / 收据"]
  S["服务端 API"] --> C
  C -->|不可变输入与租约| W["桌面或服务端 worker"]
  W -->|帧、配方、模型资源| I["rawmaster-image · 图编译与执行"]
  I --> G["wgpu / Metal、Vulkan 或 CPU"]
  G --> P["驻留预览或编码器"]
  P -->|内容摘要与提交凭证| C
```

**绑定与发布。** 两个 crate 各自输出 Rust `rlib`，桌面发布提供稳定 C ABI 的 `cdylib` 或静态包。SwiftPM 使用和目录库相同的版本／加载检查。能力与 ABI 握手先于打开会话。C 调用使用定长整数、显式长度、结构体大小、返回状态及配对释放函数。只在工作线程等待 GPU 或推理。Swift actor 负责一份会话的串行访问，MainActor 只接受与当前帧 ID／修订一致的完成事件。传出驻留纹理时持有原资源直到 GPU fence 和画布释放，客户端销毁请求仅撤销交付资格。[生产图像 C ABI](../../Modules/ImageEdit/include/rawmaster_image.h) · [生产目录调度 Swift 绑定](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) · [Swift 图像对拍](../../Tests/RAWMasterImagingTests/PortableImageIntegrationTests.swift) · [目录租约与迁移](../../Tests/RAWMasterCoreTests/CatalogProcessing035Tests.swift)

**服务端部署。** 单机 SQLite 使用本机磁盘和单一目录写入所有者。多机 worker 通过该所有者的 claim／heartbeat／complete 协议取租约。对象存储以内容键或条件写入发布，收到相同键和相同摘要可重放。提交结果需要当前 fencing token 与输入修订。Linux 无加速设备时仅调度有 CPU 等价实现的节点，缺少指定解码器或模型时返回能力错误。已物化的旧版本成片可按摘要交付。WAL 的共享内存要求决定远程 worker 不能直接打开网络共享目录里的同一 WAL 数据库。[SQLite WAL](https://www.sqlite.org/wal.html)

## 通用图、精度和 GPU 的决定

1. **同一张图有三个层次。** 版本化配方描述输入端口、节点语义和资源。Rust 编译器从输出回溯验证、有序拓扑排序、推断类型及尺寸、找出共享子图及融合边界。执行计划绑定设备、工作区和帧。改变参数只更新所需常量和下游结果。改变节点顺序或连接时重新规划。具体域、缓存键、批量绑定和失败规则见[管线契约](pipeline.md)。
2. **兼容基线为扩展线性 sRGB、D65、预乘 RGBA、FP32。** 阴影负值与大于 1 的高光要穿过线性节点。RAW 解码及相机配置、编码域 LUT、模型归一化、显示变换与导出 ICC 都有显式边界。蒙版是一张数值覆盖图。先用独立 CPU 结果与现有 V3 校准，再按算子批准 FP16 存储和误差预算。
3. **GPU 后端先验证 wgpu / WGSL。** 同一算子描述面向 macOS Metal 和无窗口 Vulkan。Apple 特有解码／纹理互操作放在适配器。逐像素分支可在寄存器中汇合。直方图、卷积、多分辨率、提交模型和导出编码都有明确屏障。前台复用编译和输入资源，批量复用执行计划，每张照片分别计算输出键。独立 CPU 后端覆盖无设备服务端与像素对照。[wgpu 固定实验版本](https://docs.rs/wgpu/27.0.1/wgpu/) · [WGSL](https://www.w3.org/TR/WGSL/)
4. **调度按资源和可重放性分配。** 交互拖动在内存中只保留每个会话最新请求。可恢复的导入、索引、已提交 AI、批导出持久化到 SQLite。队列控制全局 CPU、GPU、内存、IO、模型驻留与单目标写入，按步骤申请和释放。离线待重连，瞬态失败有限退避，永久错误终止，外部提交结果未知先对账。崩溃后的重领使用新 token，文件与收据一起校验。详见[租约、跨视图公平和恢复实验](catalog-queue.md)。

## 实施顺序和退出条件

| 批次 | 交付与放量条件 |
| --- | --- |
| A · 建立双跑基线 | 冻结 V1／V2／V3、RAW 解码配置、滤镜表、曲线、软边蒙版、几何与成片的参照清单。建立 macOS arm64、Linux CPU、目标物理 Vulkan GPU CI。给 Swift 既有入口后增加后端能力判断。相同输入在旧引擎可独立重放，才能启用影子渲染。 |
| B · 目录和调度 | 备份并恢复一个有旧版本、离线卷和受管原件的真实 v8 库。在副本上迁移任务／收据表，核对行数、关系、资源摘要和分页顺序。切换一种命令的唯一写入者，先接入可重建索引与缩略图，再接入已提交的编辑与导出。用崩溃、磁盘满、断卷和取消／重领竞态做恢复验证。 |
| C · 单张快速预览 | 先移植可独立验算的曝光、点颜色、矩阵和混合，再实现现有滤镜 LUT 的实际算子。把驻留帧接到产品画布，连测 4K＋真实 60MP RAW 的输入到可见帧 P50/P95、内存和上传／读回。试验开关按配方和设备放量。 |
| D · 蒙版、空间计算与批处理 | 把绑定来源的覆盖、模型推理、光晕／降噪的 halo、全局统计、分级／输出 ICC 纳入同图执行。批次逐张发布、取消和重试。已有成片和原件直交保留快路径。Mac 和 Linux 对同一冻结输入产出可追溯的解码／模型／颜色指纹。 |
| E · 迁移和回退 | 在复制的目录上跑旧配方与新图双读比对。按算子、文件类型、设备分批启用。每批记录出图差异、错误与性能。回退开关把后续工作分配给已验证引擎。已生成的版本、收据和原配方仍可读取。只有备份还原与版本兼容矩阵通过后才退役旧写入路径。 |

**建议评审批准的门槛（待实施验证）。** 像素方面，PoC 的有界输入点算子最大通道绝对差 ≤ `2e-6`，透明度与覆盖端点单独检查。正式兼容验收采用每个旧算法原有阈值，并用灰阶、ColorChecker、饱和广色域、透明边缘及真实 RAW 对照。性能方面先让相同 4K 驻留图的融合方案相对逐节点 GPU 的 P50 提升至少 25%。生产切换还须在同照片、同原生画布下达到既有预览／导出的 P95 和首件基线，冷启动、峰值常驻内存与显存也分别记账。资料库沿用 033 的常用查询温态首屏 P95 ≤ 300 ms 目标，必须同时报告首屏可见和后台导入时延。恢复方面，以乱序 ACK、多领取者、模型中断和写盘故障验证每个任务最多一份有效发布收据。 [既有编辑测量](../024-jpeg-display-proxy/editing-performance-comparison.md) · [032 导出基线](../032-export-workspace/performance.md) · [033 目录目标](../033-library-lifecycle/spec.md)

**请评审的取舍。** 第一，认可继续以 v8 目录和扩展线性 sRGB/FP32 承接旧版本。第二，认可先部署 wgpu＋CPU，原生 Metal 专用内核按同口径的端到端收益引入。第三，认可本机单目录写入者＋可重领任务。多机共享通过服务协议实现。第四，确定下一个交付里用于放量的真实目录、RAW／ICC 组合和物理 Linux GPU 型号。PoC 的实测范围、反例及尚待验证项随[验证报告](validation.md)保留。
