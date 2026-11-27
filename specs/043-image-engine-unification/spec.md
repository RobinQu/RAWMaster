# 043 · 图像引擎统一与后续性能优化

2026-11-28 · **待实施。** 基于 `main@90b3780f`。**Rust + wgpu/WGSL 是统一的生产渲染主干。** macOS 通过 wgpu 的 Metal 后端运行，Linux 通过 Vulkan 运行。两端共用算子语义、编译和资源计划。先修复 032 回执并建立分项基线，首条 WGSL 场景 DAG 即在两端实机对照。[实施计划](plan.md) · [任务](tasks.md) · [验收基线](validation.md)

## 1. 为什么需要单独一条规格

当前实现已跑通 HDR 草稿、组内监看和 60 MP 摄影场景的双目标交付组件。三条执行路径各自管理资源和缓存。

| 入口 | 当前实现 | 主要问题 |
| --- | --- | --- |
| 旧 V3 兼容显影 | 完整产品路径走 Core Image。035 点算子子集由 `graph.rs` 和 `gpu.rs` 执行，已有 WGSL 融合、分条及原生纹理接入 | 现有点算子计划与场景 DAG 分开。跨边界物化仍有成本，035 发布性能门待复验 |
| 场景 DAG | `scene.rs` 和 `scene/metal_exec.rs` 执行原生 Metal 逐节点调度，按最后使用点复用纹理 | 每个有效点节点仍可能写一次当前执行区域的中间纹理。交付每块重新准备图，复杂图的 dispatch 和纹理读写随算子增加 |
| 摄影前缀 | `DevelopmentScenePhotographicV1` 通过 Core Image 和 `DevelopmentRendererV3` 在全图坐标构图，按请求区域输出，再转 AP1 交给 DAG | 部分算子仍有整幅工作。摄影段固定预留 192 MiB，模型、几何及跨域资源各有自己的边界 |

60 MP 摄影调整加三节点 DAG 的双目标组件样本为 `elapsedMs=1750.98`，每目标 35 个瓦片、105 次 DAG dispatch。图预算 `1,610,612,736 B`，核算峰值 `1,458,929,664 B`，含摄影段预留。两目标共用一次来源读取和 mosaic 上传，分别执行逐瓦片显影、DAG 和输出变换。032 的产品队列按目标分别进入渲染。[实拍回执](../037-color-film-hdr/evidence/2026-11-27-photographic-60mp.json) · [组件入口](../../Sources/RAWMasterImaging/DevelopmentSceneDeliveryServiceV1.swift#L43) · [032 渲染入口](../../Sources/RAWMasterImaging/PhotoBatchRenderExporter.swift#L132)

**M0 的发布阻断。** 图文档 schema 3 保存 `photographic`，Swift 在 032 `prepareItem` 随执行回执提交 `photographicEngine` 和 `dagBackend`。当前 Rust 队列的 `SceneExecution` 会拒绝这两个字段，发布止于准备阶段。原生队列接口已复现。M0 先修 V1 双端读写及重开兼容，再用摄影场景的真实 032 路径建立分项基线。[Swift 票据入口](../../Sources/RAWMaster/WorkbenchDeliveryCatalog.swift#L437) · [Rust 回执定义](../../Modules/LibraryCatalog/src/scheduler/batch/items.rs#L53) · [M0 回归](validation.md#m0--回执修复与基线)

## 2. 目标与范围

### 目标

1. **一个内部图和执行器。** 035 点配方、038 场景图和摄影段转入同一套 Rust typed IR。新增可移植 GPU 算子统一用 WGSL，经同一 wgpu 执行器调度。每端按设备能力配置资源与派发。
2. **一套可优化的计划。** 注册表同时定义像素语义和执行约束。编译器负责验证、点段融合、空间与全图切段、资源生存期、瓦片与缓存，在跨帧、跨瓦片和跨照片时复用已编译的部分。
3. **一套资源与回执契约。** 工作集、缓存、模型、输出和编码分别记账，同时记录重叠峰值、执行段、实际后端与回退。032 票据随产物保存，可重开核对。
4. **同一图跨端验收。** M2 首条 WGSL 场景 DAG 同时在 macOS Metal 与 Linux 实体 Vulkan GPU 对照，M5 用完整 RAW 和编码链路放行 041 产品能力。

### 兼容范围

- 沿用 [035](../035-portable-processing-cores/spec.md) 的旧 v1–v3 配方回放、[037](../037-color-film-hdr/spec.md) 的颜色契约和 [038](../038-node-dag-workflow/spec.md) 的 v4 配方与现有交互。IR 是内部表示。旧配方及待迁移摄影算子按已验证的实现进入同一计划和回执。
- 交付主路径采用 F32。可选交互代理有独立精度标记、缓存身份和验收。macOS 继续使用现有 AVIF 编码器，单独测量该边界。

## 3. 统一架构

### 3.1 分层

```text
035 点配方 / 038 场景图 / 摄影参数 → Rust typed IR → 编译与资源计划
FlashRaw mosaic + 版本化校准 ──────────────────────────┘
                                              ├─ WGSL + wgpu → Metal / Vulkan
                                              ├─ Core Image / 模型等适配段
                                              └─ CPU 参考 / 迁移期等价回退
                                场景结果 → 每目标一次 ACES 2 输出 → 呈现 / 编码
```

Rust 拥有算子注册、图验证、编译、资源计划、wgpu 调度和统一回执。Swift 宿主持有文件授权、AppKit/EDR 呈现和发布事务，也负责调用平台模型、Core Image 及现有编码适配器。现用 ACES 2 输出段先以适配段进入计划，携同版本的表、参数和颜色契约迁入 WGSL。039 原生 Metal DAG 和 Swift 执行器用于迁移对照及经验证的等价回退。[039 执行证据](../039-rust-scene-backend/validation.md) · [wgpu 后端](https://wgpu.rs/doc/wgpu/documentation/features/index.html)

### 3.2 FlashRaw 与宿主边界

1. **先沿用固定 C ABI。** FlashRaw 0.3.1 提供 `rawU16` Bayer mosaic 和传感器元数据。RAWMaster 冻结来源摘要、解码版本、CFA、黑白电平、白平衡/相机矩阵、方向和有效裁切，按 [037 校准](../037-color-film-hdr/spec.md) 生成有符号 AP1 F32。FlashRaw 的已成像 RGB 走对应来源域的准入，场景路径使用有校准的输入。[构建固定版本](../../scripts/build-flashraw.sh#L5) · [现行入口](../../Sources/RAWMasterImaging/DevelopmentSceneRAWV1.swift#L84)
2. **随后评估同设备驻留。** FlashRaw 支持 `GpuContext::from_device` 接受宿主设备和队列。当前固定 FlashRaw 源码依赖 wgpu 30，ImageEdit 固定 27.0.1。共享 Rust 设备前先对齐依赖，复验 Metal HAL 纹理借用、格式和用法、生产者完成信号、消费者释放及取消。收益以减少上传、整帧读回和等待的实测为准，现行 mosaic 路径提供兼容入口。[FlashRaw GPU 接口](https://github.com/ybouane/flashraw/blob/main/docs/gpu.md) · [ImageEdit 依赖](../../Modules/ImageEdit/Cargo.toml#L22) · [已有纹理借用证据](../035-portable-processing-cores/evidence/image-metal-iosurface.md)

### 3.3 Typed IR

IR 表达可执行图像程序。宿主用渲染请求传入选定根、查看意图与 ROI。最小类型如下。

```text
EngineGraph
  nodes: [EngineNode]
  output: PortRef

EngineNode
  id: StableID
  op: OpID + version
  inputs: [PortRef]
  parameters: ParameterBuffer
  enabled: Bool

PortDomain
  encoding: sceneAP1 | extendedLinearSRGB | displayLinear | coverage | depth | density
  primaries / white / transfer / referenceWhite
  alpha: premultiplied | straight | none
  precision: f32 | f16
  geometry: fullExtent, origin, scale, transformToSource
```

- 显式域转换记录在计划、缓存键和回执里。`coverage` 使用独立端口，外部蒙版以全图坐标绑定，输入采样、几何和输出取景共享同一映射。
- 首条场景链覆盖曝光、EV 曲线、coverage 和有序 Layer。场景图的其余 039 operation 逐项转入 IR。摄影前缀先作为完整适配段，随后按现行顺序迁移有像素证据的算子。
- 旧 V3 按 035 的逐算子语义映射。未满足回放和性能门槛的组合沿用现有 Core Image 执行。

### 3.4 算子注册表

每个算子在注册时定义以下契约。

| 字段 | 用途 |
| --- | --- |
| `OpID` / `version` | 标识算法与缓存身份，持久配方通过现有版本映射到对应语义 |
| 域、端口与精度 | 约束颜色、alpha、几何和输入输出表示 |
| `pointwise / spatial / reduction / model / geometry` | 指定融合资格、ROI 扩张、边缘规则、halo 和归约顺序 |
| 参数与资源 | 声明范围、默认值、量化、参数布局和 LUT/模型等资源摘要 |
| CPU 参考和像素判据 | 固定逐位或逐算子误差要求，覆盖边界及整幅/瓦片结果 |
| WGSL 或适配段 | 声明 WGSL 函数/内核、最低设备能力和绑定需求，平台实现声明适配段的输入输出契约 |
| 成本与失效 | 估算纹理、带宽、派发和峰值，限定参数变化使哪一段缓存失效 |

新增算子先给出参考、像素和成本证据，再启用融合或分块优化。空间算子从 036 的固定输出瓦片与 factor/restore 结果起步。[036 窗口化证据](../036-render-pipeline-performance/spec.md#算子-factorrestore-窗口化poc-通过)

### 3.5 编译与算子优化

1. **校验和转换。** 按 038/039 验证图、端口、循环、参数及限制，确定请求根。将配方转为 IR，显式插入域转换、几何、全图归约和模型边界。
2. **裁剪与融合。** 裁掉已证明的恒等、禁用或零权重路径。同域、同精度、同采样位置的点段生成 WGSL，保持已签收的 F32 求值顺序和逐段有限值语义。曝光及 Layer 的代数改写逐项验证后启用。按实测的编译成本、绑定上限和资源压力决定分支内联或切段。
3. **空间与全图阶段。** 将下游 ROI 反推到上游，以可计算的 halo 和边缘规则执行空间瓦片。全图归约先生成统计，再将同一结果用于各瓦片。归约顺序及误差进入算子版本契约。
4. **资源调度。** 编译纹理和缓冲区的生存期，在最后使用后回收复用。按设备纹理、存储绑定、工作组和预算确定整幅或瓦片计划。输出段尽量直接写有界目标。
5. **缓存与派发。** WGSL pipeline 按算子版本、图结构、域/精度、绑定布局及设备/能力缓存，普通参数变更只更新缓冲。像素结果另按源、有效参数、依赖、资源摘要及精确几何/ROI 缓存。记录每段实际派发、峰值、等待和回退。

### 3.6 资源与执行

- 工作集、segment/coverage 缓存、模型、终端输出和编码暂存分别准入，同时核算并行与在途资源的总峰值。记录实际分配或估算的来源，缓存按预算逐项淘汰。
- 以 wgpu 纹理/缓冲池和生存期复用为基础。普通 pipeline 按设备与规范化图结构复用，节点 UUID 保留给配方和参数绑定；平台分配或同步特化由适配段承接，并按实测放行。
- 同一队列内将可合并的阶段放入一次提交。平台适配段以原生完成信号交接，纹理直到最后一个消费者完成才回收。交互保留一个在途帧和一个最新待处理帧，按来源、版本、渲染意图与修订验证发布身份。交付可在预算内尝试瓦片双缓冲。

### 3.7 执行与回执协议

- M0 使 Swift、Rust 读写同一份 V1 回执，接受缺少摄影字段的旧票据并保留准备、发布和恢复所需的字段。V2 用明确版本扩展，版本化读取同时覆盖旧票据。
- V2 记录实际 `executor` 和 `graphicsAPI`，例如 `wgpu`/`metal`、`wgpu`/`vulkan` 或 `legacyMetal`/`metal`。计划内的 Core Image 等适配段有各自记录。严格 wgpu 对已支持的 WGSL 段要求零回退。自动模式的等价回退按段记次数和原因。
- 记录计划与编译身份、分项墙钟、GPU 时间、等待、瓦片与派发计数、预算和峰值。GPU 时间随计时能力和区间报告。032 持久化执行回执与成片摘要，重开后可回查同一次执行。[字段草案](plan.md#43-receiptv2)

## 4. 性能工作流

### P0 · 测量与低风险去重（先做）

| 工作 | 改动 | 预期 | 风险 |
| --- | --- | --- | --- |
| P0-1 分项测量 | 给摄影前缀、DAG、DRT、blit、编码加 GPU timestamp/回执；60 MP 单目标拆开 | 先判断 1.75 s 里图、编码、等待各占多少；避免优化错对象 | 低；只加观测 |
| P0-2 tiled 交付复用 | `DevelopmentSceneTiledDeliveryV1` 在 tile 循环外创建一次 Renderer/SceneProgram；复用 pipeline、output stage | 去掉 35 次重复 shader/pipeline 准备；跨 tile 缓存有机会命中 | 低；像素不变 |
| P0-3 双目标单次图执行 | 每 tile 只解码 + DAG 一次，对同一 scene tile 跑 SDR/HDR 两次 DRT | 消除 PQ+SDR 的 2× 图/解码；对 032 批量直接收益 | 低-中；需目标输出顺序与 blit 校验 |
| P0-4 单 tile 单 command buffer | decode/tile blit/graph/DRT/blit 尽量同一 command buffer，减少 `waitUntilCompleted` | 降低每 tile 同步空泡 | 中；需要对外部 command buffer 的编码接口 |
| P0-5 pipeline 形状缓存 | topology key 去掉 UUID；program 缓存改 LRU；编译一次 `MTLLibrary` 复用 | 模板/批量/多照片不再反复编译 | 低；需缓存失效测试 |

P0 放行：像素不变；60 MP 双目标不慢于基线 ±5%；tile/dispatch 数不增加；严格 Rust 回执可核对。

### P1 · 点段融合与资源计划（核心）

| 工作 | 改动 | 预期 | 风险 |
| --- | --- | --- | --- |
| P1-1 点段融合 | IR + 代码生成，把同域点算子 unroll 成一个 Metal kernel；参数放 buffer，拓扑结构哈希 | 点链从 N 次全幅读写降到约 1 次；96 节点图收益最大 | 中-高；需逐位 shadow test |
| P1-2 Heap/别名 | `MTLHeap` + liveness 别名，segment 边界 surface 复用 | 降低 60 MP 峰值，允许更大 tile/整幅 | 中；需预算与 fence 校验 |
| P1-3 结构化 pipeline 缓存 | 结构哈希不包含 UUID，跨照片/模板复用 pipeline | 200 张批量减少重复编译 | 低-中 |
| P1-4 1:1 大窗口 | 去掉 1,000 万像素硬上限，按预算/显示分辨率自适应 tile | 5K/6K 屏 1:1 可用 | 中；需 ROI 等价 |
| P1-5 模型分块 | 摄影/模型前缀按 tile+halo 推理，mask 对齐；不可分块时明确拒绝 | 60 MP 模型预览/交付从“预算拒绝”变为可用或明确原因 | 高；模型域/几何/遮罩验收 |

P1 放行：点段逐位一致（或既有 8×10⁻⁷ 门）；96 节点合成图吞吐 ≥2×、峰值 ≤50%；60 MP 图阶段 ≥15%；038 FIT/监看原门槛不退。

### P2 · 空间算子与全图归约（算子级）

| 工作 | 改动 | 预期 | 风险 |
| --- | --- | --- | --- |
| P2-1 texture/clarity | 自写可分离高斯 + 显式 halo + band 合成，替代 CI factor/restore/tile 的整幅 materialize | 1:1 窗口 5–12× 的既有 PoC 进入默认 | 高；逐字节/窗口等价 |
| P2-2 dehaze/brilliance | 分块确定性归约（有序/补偿），带 halo 的统计分析 | 压缩 1.5 s / 3.9 s 的长尾 | 高；归约顺序与像素基线 |
| P2-3 九类调色 | 按算子注册表逐类 lower；同域点段先融合，空间/全图单独切段 | 功能扩展不再线性增加 surface | 高；算子语义与 UI 逐项验收 |
| P2-4 几何/蒙版/修饰 | 几何作为显式边界；蒙版保持 coverage 端口；修饰/候选独立阶段 | 场景图与照片工具真正同引擎 | 高；模型遮罩与几何冲突 |
| P2-5 LUT/胶片/OCIO | 声明输入输出域、参考白、峰值；不叠第二次 DRT | 形成可复用输出分支 | 高；资产契约 |

P2 放行：每个算子先单独通过窗口/整幅/导出三组像素证据，再进入 50 配方矩阵；矩阵 P95 至少 1.5×，单类算子按实测设门。

## 5. 验收

### 像素

- 点运算、coverage、13 种 blend：与当前 Rust/Swift 执行逐位一致；或落在 038 的 `8×10⁻⁷ × max(1, |reference|)` 门内。
- 1:1 窗口与整幅对应区域：逐字节相等；空间算子按其既有容差单独定义。
- 零 coverage、禁用节点、零权重分支、中性 corrector：输出对象/像素保持原值。
- 旧 v1–v3：按原配方、原解码、原几何和原成片回放。
- 模型遮罩 + 几何：坐标不一致时在提交前拒绝，保留草稿与撤销；预览、示波器、交付共用同一判定。

### 性能

| 场景 | 现有基线 | 043 目标 |
| --- | --- | --- |
| 60 MP 摄影+3 节点 DAG，PQ+SDR | 1.751 s；35 tiles、105 dispatches；图峰值 1.4589 GB / 1.5 GiB | P0 不劣化 ±5%；P1 图阶段 ≥15%，tile/dispatch 数下降；P2 再按算子计 |
| 6 MP 六节点场景图 | Rust/Swift p95 约 14.26/14.27 ms；5 个全幅 surface | P1 点段融合后 ≥1.3×，峰值下降；不牺牲 038 门槛 |
| 038 FIT / 组内监看 | 22.07/23.30 ms；19.43/20.78 ms | 保持原门槛 `p50 ≤25.92`、`p95 ≤210.23`；监看 p95 ≤20 ms |
| 036 1:1 50 配方 | 中位 111.4 ms，P95 1,474.3 ms | P2 逐类算子先设门；矩阵 P95 至少 1.5× |
| 035 发布门 | 首次精确/定稿中位 77–81 ms，对 24.35/25.92 ms 上限 | 由 043 的融合/边界收口后重新跑；未过不得替换旧路径 |

性能记录必须同机、同源、同分辨率、预热 5 次、至少 30 次，分别记录冷/暖、p50/p95、峰值、tile/dispatch、fallback、实际后端。只有同测量区间的数据用于切换判断。

### 可靠性

- 严格 Rust 的受支持组合回退为 0；auto 回退必须计数、记录原因并在诊断可见。
- 取消、换片、切组、迟到结果按原请求身份拒绝；不得写入新照片/新图。
- 交付票据同时记录 plan、segment 后端、tile、峰值、编码和文件摘要；重开后可核对。
- 预算失败必须给出具体阶段（working/cache/model/encode）和可执行原因。

### 成功标准

- **SC-001**：每条受支持路由都能列出同一次执行的 plan、segment 后端、峰值和 fallback；不再以“组件通过”代替产品路径。
- **SC-002**：点段融合在 96 节点合成图上吞吐 ≥2×、峰值 ≤50%，且与当前执行器逐位一致。
- **SC-003**：60 MP 摄影+3 节点 DAG 双目标不慢于 1.751 s ±5%，图阶段 ≥15%；tile/dispatch 数下降。
- **SC-004**：60 MP 模型与 5K/6K 1:1 至少给出可用结果或可执行的预算拒绝；不再出现 1,000 万像素硬拒绝。
- **SC-005**：旧 v1–v3 成片回放不变；035 封存矩阵复跑后才能替换旧路径。

## 6. 迁移与回滚

1. **不 big-bang。** 先让 043 的 plan 包住现有 DAG/摄影前缀，一个路由一个路由切换；旧路径保留。
2. **双跑。** 每个新 segment 先与当前 Rust、Swift 参考和旧 V3 对照；点段逐位，空间段按容差。
3. **特性开关。** 按算子/路由提供 QA 开关；默认只在证据通过的组合启用。
4. **回执判定。** 放行以本次实际后端、峰值、tile、fallback 为准，不以“代码已合并”或“组件通过”代替产品路径。
5. **回滚。** 任一组合出现像素/性能回退，回退该 segment 到 Core Image/旧 DAG，保留同一配方与版本回放。

## 7. 阶段交付

| 阶段 | 交付 | 退出条件 |
| --- | --- | --- |
| M0 · 基线 | 分项回执、60 MP/6 MP/038/036 基线、tile/峰值拆解 | 同一构建可复现；明确 1.75 s 的构成 |
| M1 · P0 | Renderer 复用、双目标单次图、单 command buffer、pipeline 形状缓存 | 像素不变；60 MP 不劣化；tile/dispatch 下降 |
| M2 · IR + 融合 PoC | typed IR、算子注册表、点段融合、Metal codegen、shadow tests | 96 节点合成图 ≥2×；点段逐位一致；60 MP 图阶段 ≥15% |
| M3 · 资源与模型 | heap/别名、模型分块、1:1 大窗口、异步双缓冲 | 峰值下降；60 MP 模型可用或明确拒绝；5K/6K 1:1 可用 |
| M4 · 空间与能力 | texture/clarity、dehaze/brilliance、九类调色、几何/蒙版/修饰、LUT/胶片/OCIO | 逐算子像素/性能门；50 配方矩阵；产品入口验收 |
| M5 · 跨端 | Linux/041 场景后端与能力表 | 按 041 单独放行；不把 macOS 证据外推 |

## 8. 待评审决定

1. **摄影前缀的迁移边界**：先把它作为 adapter 段统一预算/回执，还是先融合其中点段？建议先 adapter，避免同时改像素语义和资源模型。
2. **模块归属**：`engine` 作为 `Modules/ImageEdit/src/engine` 的内部模块，还是拆成独立 crate？建议先单 crate 内聚，稳定后再评估 ABI/跨端拆分。
3. **模型分块合同**：长期采用全图 mask 拼装，还是 tile-local coverage + 显式全图坐标？这决定 `externalCoverage` ABI 是否要扩展。
4. **编码是否纳入 043 性能目标**：AVIF 当前是整帧回读 + ImageIO；建议只把编码作为独立工作流测量，不在本规格内替换编码器。
5. **FP16 交互代理**：是否允许仅用于 1:1 拖动/监看；若允许，需独立标记、缓存键和验收，不进入交付。

## 9. 风险

- **像素漂移**：融合改变求值边界，必须用逐位/容差证据和旧成片回归锁住；任何无法解释的差异都不放行。
- **Core Image 边界**：摄影前缀、蒙版、几何和模型仍依赖 CI/平台；短期 adapter 是必要的，不能假装已经统一。
- **模型遮罩与几何**：裁切/旋转/透视/镜头畸变会移动模型坐标；继续沿用 `validatePhotographicCoverage` 的准入，不允许静默错位。
- **内存**：60 MP 的终端目标、摄影中间资源和编码 staging 是三条独立峰值；预算必须分开，不能用“图预算”掩盖编码峰值。
- **编码墙钟**：AVIF 仍是整帧回读 + ImageIO；图融合不自动解决编码时间，P0 必须先测量再决定投入。
- **范围膨胀**：九类调色和空间算子不能先于融合/资源计划接入，否则会把当前线性成本放大到不可用。

## 10. 关联

- [035 可移植内核](../035-portable-processing-cores/spec.md) · [036 性能水位](../036-render-pipeline-performance/spec.md) · [037 色彩/HDR](../037-color-film-hdr/spec.md) · [038 DAG](../038-node-dag-workflow/spec.md) · [039 Rust 场景后端](../039-rust-scene-backend/spec.md) · [041 服务端图像作业](../041-server-image-editing/spec.md)
- 现行实现：`Modules/ImageEdit/src/graph.rs`、`gpu.rs`、`scene.rs`、`scene/metal_exec.rs`；`Sources/RAWMasterImaging/DevelopmentScenePhotographicV1.swift`、`DevelopmentSceneGraphRendererV1.swift`、`DevelopmentSceneTiledDeliveryV1.swift`、`DevelopmentScenePreviewV1.swift`
- 基线：[60 MP 摄影+DAG 回执](../037-color-film-hdr/evidence/2026-11-27-photographic-60mp.json) · [039 性能与边界](../039-rust-scene-backend/validation.md) · [036 实测](../036-render-pipeline-performance/validation.md)
