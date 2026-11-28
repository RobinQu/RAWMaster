# 043 · 实施计划

2026-11-28 · **M0 外部对标继续采集。** M1 目标内程序复用已实测。首条 Rust + wgpu/WGSL 场景 DAG 组件已通过 macOS Metal 和 Linux 实体 Vulkan 对照。[规格](spec.md) · [任务清单](tasks.md) · [验收基线](validation.md)

## 1. 当前代码边界

| 层 | 现有入口 | 043 的改动方式 |
| --- | --- | --- |
| 旧 V3 点配方 | `graph.rs`、`gpu.rs`、`metal_ffi.rs` | 沿用 C ABI，按 035 等价证据共用 WGSL、融合与缓存。其余组合经 Core Image 适配段执行 |
| 场景 DAG | `scene.rs`、`scene/metal_exec.rs`、`scene_ffi.rs` | 沿用 JSON 文档 ABI，执行计划优先使用 WGSL，039 原生 Metal 和 Swift 提供对照与等价回退 |
| RAW 输入 | `DevelopmentSceneRAWV1`、`CFlashRaw` | 固定 FlashRaw C ABI 提供 Bayer mosaic 和传感器事实。RAWMaster 维护 037 校准和 AP1 输入。按实测评估后续同设备解码 |
| 摄影/模型 | `DevelopmentScenePhotographicV1`、`DevelopmentRendererV3`、模型提供者 | 先用适配段记录资源、域和几何，随后迁移有等价证据的摄影点段和空间算子 |
| 预览与输出 | `DevelopmentScenePreviewV1`、`DevelopmentSceneTiledDeliveryV1`、`DevelopmentSceneOutputV1` | 绑定来源、视图、计划和资源生命期。ACES 2 先作为适配段，随后使用同版本 WGSL 输出段。Swift 管理呈现、授权及编码适配 |
| 交付持久化 | `WorkbenchDeliveryCatalog.prepare` 和 Rust 目录 `SceneExecution` | M0 先补齐 Swift/Rust 的 V1 摄影字段与旧票据读回，之后引入版本化 V2 记录计划和资源 |

持久配方、图文档、颜色/输出含义、既有交互及 032 发布事务沿用 035、037 和 038 的契约。

## 2. 目标模块

```text
Modules/ImageEdit/src/
  engine/
    ir.rs           EngineGraph / EngineNode / PortDomain / OpID
    registry.rs     OpDescriptor、参数、CPU 参考和 WGSL 注册
    lower.rs        V3 recipe / SceneGraph / Photographic → IR
    passes.rs       校验、域转换、裁剪与生存期
    fuse.rs         WGSL 点段融合与切段
    tile.rs         ROI、halo、设备上限和目标预算
    plan.rs         ExecutionPlan、SegmentPlan、PipelineKey、PixelCacheKey
    receipt.rs      版本化回执和阶段计量
  scene.rs          现行场景 JSON 解析和校验
  scene/metal_exec.rs  039 原生 Metal 对照与迁移回退
  graph.rs         现行 V3 点配方入口
  gpu.rs           wgpu 执行、资源和 WGSL 编译复用
  gpu/metal_surface.rs  Apple 原生纹理借用边界
  metal_ffi.rs / scene_ffi.rs  现有 ABI 入口
```

- `engine` 依赖图像端口、资源和设备能力声明。Swift 通过现有 ABI 交付冻结输入，通过版本化接口传入适配段表面或接收结果。
- `scene.rs` 校验后的图转入 IR。`OpDescriptor` 将 CPU 参考、WGSL 内核、参数和像素判据绑定到同一版本。平台段在同一计划声明域、ROI、资源与执行者。
- FlashRaw 第一阶段复用固定 0.3.1 C ABI。直接同设备驻留需先统一 FlashRaw 与 ImageEdit 的 wgpu 依赖，再验证设备、队列、纹理描述、同步和 GPU 驻留收益。[接入边界](spec.md#32-flashraw-与宿主边界)

## 3. 阶段设计

### M0 · 032 回执修复与基线

1. **修复 V1。** Swift 的 `DevelopmentSceneExecutionReceiptV1` 已编码 `photographicEngine` 和 `dagBackend`。在 Rust 目录 `SceneExecution` 添加同类型的可选字段，保留严格字段校验和旧票据读回。确认阶段比较、已持久化票据和重开回传保持字段语义。
2. **原生队列回归。** 用非中性 `photographic` 和有实际派发的 DAG 冻结场景，分别通过 032 提交 PQ AVIF 与 SDR JPEG，验证准备、发布、摘要、混合段回执、旧票据读取和中断续跑。两目标分别核对冻结输入，成功文件重开后沿用原回执和摘要。[M0 回归](validation.md#m0--回执修复与基线)
3. **分项计量。** 把来源校验/读取、FlashRaw 解码、mosaic 上传、摄影/模型、DAG 准备和求值、DRT、blit、编码读回、发布和等待纳入同一次报告。记录队列与端到端墙钟、各阶段 CPU 墙钟及可用的 GPU 计时。分别核算阶段峰值与同一时刻的总峰值。
4. **固定复现口径。** 60 MP 记录 032 的 PQ/SDR 单目标及双目标组件，6 MP 六节点、038 FIT/监看和 036 的 1:1 矩阵各留同构建基线。固定输入和校准版本、运行库摘要、驱动/屏幕及实测区间。定稿 V2 字段与旧票据兼容方式。
5. **外部对标。** 固定 LightFlow 发布包和 Camera Raw 版本，先以同源可见画布建立逐控件对照，再按可匹配的工作流补齐精确读回、1:1 和成片。每项分别取两者中较快的 p50 和 p95，同原生像素与调度证据一起决定算子优化顺序。首次定稿按新状态分项采样，先复用已清空的点运算上下文，再拆解局部锐化、局部降噪的全幅归约与显示读回以及冷去雾引导图。JPEG 在正式计时前用两个产品各自重复的同配方 PNG16 校准保真度。[外部对标](validation.md#外部产品对标)

退出条件为摄影场景已通过真实 032 队列与旧票据回归，同构建的 60 MP 分项样本可复现，能据此决定编译、图执行、同步和编码的优先级。

### M1 · 去重

1. **复用瓦片准备。** 同一个交付目标复用 renderer、冻结 SceneProgram 与输出阶段。瓦片单独绑定纹理、原点和预算，冻结程序不保留瓦片间的像素和 coverage。计数 `rendererBuildCount`、`programCompileCount`、`libraryCompileCount` 已在 60 MP 三路实测。[目标内复用验收](validation.md#m1--去重)
2. **同输入共享。** 当前双目标组件已共用一次 mosaic 读取和上传。评估共享逐瓦片显影与 DAG，再各跑 DRT。两张全幅 F32 终端纹理已超过当前 1.5 GiB 图预算，先验证有界暂存和输出/编码峰值，再给通过的路由启用共享并核对 032 的独立目标、取消与续跑。其余路由沿用逐目标渲染。
3. **合并提交。** 瓦片 DRT 已直写同设备全幅目标。每块检查原点、纹理范围和 GPU 完成，整幅就绪后进入编码。合并图与 DRT 的同队列工作时，继续按生产者完成信号交接 Swift/CI/编码资源，逐段核对像素、取消和等待。[直写对照](evidence/m1-direct-drt-assembly.json)
4. **形状缓存。** 规范化节点形状、依赖与输出选择。设备级缓存复用 `MTLLibrary`/pipeline，并与每次绑定、结果缓存和资源身份解耦，为 M2 的 wgpu pipeline 接入保留同一键规则。

退出条件为等价像素，60 MP 暖态端到端 p95 ≤同路由 M0 的 105%，同渲染意图的瓦片和 DAG 派发计数至多等于基线，重复准备计数下降。满足条件的共享路由还要核对发布和重开。[M1 验收](validation.md#m1--去重)

### M2 · 首条 WGSL 场景 DAG 与融合

1. **先接一条实际场景链。** 首条独立组件已经接入 `DevelopmentSceneGraphV1.Scope` 对应的 039 文档，覆盖 AP1 F32 曝光、EV 曲线、线性 coverage 和有序 normal Layer，含零覆盖、禁用、顶层监看与冻结最终根。用 CPU 参考和同一 WGSL 融合计划绑定不同参数，Apple M4 Max 已实测。摄影前缀、ACES 2、组内监看和原生纹理传输从产品适配段接入。[实机结果与复跑](validation.md#m2--首条-wgsl-场景-dag-与融合)
2. **两端实机首验。** 同一提交、依赖锁、冻结图和校准 AP1 在 Apple M4 Max 的 wgpu/Metal 与 NVIDIA RTX 6000 Ada 的 wgpu/Vulkan 上通过。整幅和非居中 ROI 均覆盖监看与最终根，双端四通道、设备、驱动和零回退回执已经归档。原生纹理传输和端到端资源按 24/60 MP 产品用例验收。[双端回执](evidence/m2-ap1-cross-device-receipt.json)
3. **实现算子级优化。** 验证后裁剪恒等和禁用分支。同域、同精度和几何的点段生成有固定求值顺序的 WGSL。为曲线、coverage 及参数绑定设设备上限，超限时切段。改变计算顺序的代数折叠逐项验收，结构化 pipeline 缓存让改参只更新缓冲。
4. **验证产品传输。** macOS 在内部严格 `RAWMASTER_SCENE_BACKEND=wgpu` 下借用已完成生产的同设备 RGBA32F 输入。wgpu 提交图并等待该次提交索引，之后检查有效性标志并把输出交给现行 DRT。24/60 MP 的 FIT、原寸窗口、顶层和组内监看及 032 冻结交付均有原生回执。分开计量 DAG 的整帧 CPU 搬运、验证标量、命令等待和 GPU 驻留。Linux 的首条 DAG 使用固定 AP1 输入验证执行器，完整 RAW 和目标文件在 M5 签收。[同设备纹理](validation.md#macos-同设备纹理试验)
5. **扩大算子覆盖并复测。** 13 种 Layer 混合模式和 Add/Subtract/Adjust coverage 已通过两端实机及 039 像素对照。非 normal Layer 在去预乘和混合之前验证数值域。其余场景节点及 V3 点段按同一模式迁移。对比融合/未融合及 039，记录 6 MP 六节点、96 节点合成图和 60 MP 三节点的性能。[模式与准入回执](evidence/m2-layer-blend-coverage.json)

退出条件为两端严格 wgpu 实机、像素与 ROI 通过，macOS 产品路由通过。6 MP 暖态图 p95 至少 1.3× 提速，固定 96 节点图的吞吐 ≥2× 且峰值中间工作集 ≤50%，60 MP 图阶段 p50 较 M1 至少降 15%，038 既有门槛保持。严格 Metal 的完成等待先在 1 ms 窗口用同一提交索引查询，超时后继续阻塞等待该提交。60 MP 的两轮各 30 个暖样本共同通过四个图阶段门槛，成片摘要保持一致。后续继续合并图与 DRT 的队列工作，并以同一完成点验证像素、取消和恢复。[完成点复测](evidence/m2-native-metal-completion.json) · [有界等待验收](evidence/m2-native-metal-bounded-wait.json)

### M3 · 资源、模型与原寸窗口

1. **复用和准入。** 用计划生存期管理 wgpu 纹理/缓冲池，分开记账 working、cache、coverage、model、output 和 encode，报告总驻留的计算口径。平台特化单独验证所有权、释放与性能。
2. **模型分块。** 按每个模型的能力选择 tile+halo 或整幅路径，全图坐标拼装或绑定 coverage。超预算或未准入的组合给出可定位原因。
3. **1:1 取景。** 工具条和键盘用当前主画布的规范几何规划首窗。均衡单画布按源租约的位图容量为可见区加留边。RAW 基图池开启且当次为空时，点式原寸请求只保留一张已交付的同源同窗、实际字节合规的位图。现已测首窗、未缓存曝光、平移、缓存和两种基图池配置。继续在 5K/6K 实体屏幕、非点算子和完整多窗场景核对像素与峰值。[实拍 1:1](validation.md#原寸首窗与位图预算)
4. **异步与交互。** 画布合并到一个在途帧和一个最新待处理帧，交付在预算内排流水。原寸越界后折返会撤回排队窗口，已提交的窗口由现有发布代际撤销。切图、取消及迟到结果按身份拒绝，GPU 资源保留到最后一个消费者完成。[工作台折返走查](../../docs/ui/prototype/index.html?nativePanReview=1#edit/development) · [原生回归](../../Tests/RAWMasterUITests/EditingPreviewCoordinationTests.swift)

退出条件为 60 MP 总峰值下降，5K/6K 1:1 可用，受支持的 60 MP 模型通过，其他组合按阶段诊断，取消及竞态回归通过。

### M4 · 空间与输出算子

1. 沿用 036 固定输出瓦片作为像素对照。用相同 1:1 窗口评估 WGSL halo、可分离滤波和 `texture → clarity` 的 band 合成。用窗口、整幅及导出的像素和时间分别验收。
2. 测量 `dehaze`/`brilliance` 全幅阶段，给统计与应用定义归约顺序和输入域，再验证分块方案。
3. 九类调色按算子注册表逐类迁入。几何、蒙版和修饰沿用显式坐标与独立 coverage。模型＋几何通过 `validatePhotographicCoverage` 准入。
4. 将 ACES 2 输出数学和固定表按版本迁入 WGSL。LUT/胶片/OCIO 资源声明域、参考白和峰值，每个目标从同一母版成像一次。用 037 的像素及 CICP/ICC 基线验证实际输出。

退出条件为逐算子窗口、整幅、导出的证据齐备，50 配方矩阵 p95 至多为同路由 M0 的三分之二，产品入口通过。旧 V3 默认切换须通过 035 旧片回放及封存性能门。

### M5 · 041 产品放行

1. 在已通过 M2-04 组件验收的 Linux 实体 Vulkan 上增加实拍 RAW 的完整链路。固定 FlashRaw 和相机校准，验证 mosaic 到 AP1、场景图、每目标一次 ACES 2、编码与独立回读。型号、模型、配方和输出按能力逐项放行。
2. 将内存准入、取消、重试、续跑及执行回执接入 040/041 队列。按通过的组合启用 `image_scene_batch`，不可用的组合返回缺失的能力和原因。

退出条件为实机完整链路、文件信号和目录回执可核对，041 服务端能力表与实际支持一致。[041 验收](../041-server-image-editing/spec.md#5-验收场景)

## 4. 关键数据结构

### 4.1 Plan

```text
ExecutionPlan
  sourceRevision, calibrationVersion, roi, fullGeometry
  segments: [SegmentPlan]
  output: SegmentOutput
  budget: BudgetPlan
  cacheKeys: CacheKeySet
  producedBy: compilerVersion

SegmentPlan
  id, opVersions, domain, precision, tilePolicy
  inputs: [SurfaceRef]
  outputs: [SurfaceRef]
  executor: wgpu | legacyMetal | coreImage | cpuReference | host | passthrough
  graphicsAPI: metal | vulkan | none
  roiMapping, halo, requiredCapabilities
  estimatedBytes, estimatedDispatches
```

### 4.2 编译与像素缓存键

```text
PipelineKey
  deviceIdentity, graphicsAPI, requiredCapabilities, compilerVersion
  segmentStructureHash, opVersions, domain, precision, bindingLayout

PixelCacheKey
  sourceContentDigest, sourceRevision, calibrationVersion
  roi, fullGeometry, domain, precision
  segmentIdentity, upstreamContentKeys, parameterHash, resourceDigests
```

结构按算子、连接、分段和输出位置规范化。节点 UUID 用于配方和运行时参数绑定。有效参数、上游图和 LUT/模型摘要改变时，对应像素缓存失效。编译期特化参数进入 pipeline 键，其余参数保持独立缓冲。

### 4.3 ReceiptV2

旧 V1 沿用无 `schemaVersion` 的对象格式，其中摄影字段缺省或为 `null` 时按可选值读取。V2 使用 `schemaVersion: 2` 显式分流，缺少必要字段或出现未知版本时拒绝准备票据。Swift 和 Rust 同时支持 V2 准备、重开及恢复后才启用写入。已准备或已发布的 V1 保留版本、执行回执内容及发布权限。V2 仍与 032 的冻结版本、目标和文件摘要关联。

M2 同设备纹理试验在隔离目录写入 V1 的 `wgpu` 执行器值。与摄影段组合的回执为 `backend=mixed`、`dagBackend=wgpu`，命令、等待及拷贝计数进入分项记录。同期 Swift 与 Rust 目录可重开旧 V1 和试验票据。含新枚举的试验票据要求使用支持该值的构建重开，同构建可切回 039 执行后续任务。

```text
ReceiptV2
  schemaVersion = 2
  planHash?, planUnavailableReason?, compilerVersion
  route, sourceDigest, calibrationDigest?, workflowDigest, target
  wallClock: {scope, elapsedMilliseconds, queuedMilliseconds?, queueUnavailableReason?}
  stages: [{id, opVersions, executor, graphicsAPI, observations, wallMilliseconds,
            gpuMilliseconds?, gpuTimingUnavailableReason?, waitMilliseconds?, timingSource,
            tiles, dispatches, fallbackReason?}]
  rendererBuildCount?, programCompileCount?, libraryCompileCount?
  peakWorkingBytes, peakIntermediateBytes, peakCacheBytes, peakModelBytes
  peakOutputBytes, peakEncodeBytes, peakTotalBytes?, budgets, memoryMeasurement
  cacheHits: coverage / node / segment / pipeline
  fallbackCount
```

- V2 以顶层区间统计总墙钟。多个阶段可以重叠，GPU 执行、CPU 等待和嵌套回执各自按边界记录。不可见的时间以缺值和原因表达。图执行 ABI 返回的 `cpuMilliseconds` 归为执行墙钟。
- 图预算核算、Metal 分配边界采样和进程 footprint 分别记录。总峰值以同一时点的全工作集测量为准。无法观测时留缺值，保留已知的预算与范围。
- 派发、编译和缓存只在有执行证据时计数。片段执行者和图形 API 来自运行设备。计划外选用其他执行者时记回退段、理由及次数。

## 5. 迁移顺序

1. 先完成 032 兼容修复与原生分项基线，再按基线去重。
2. 让现有场景、摄影与输出经过同一计划，用首条 AP1 WGSL 场景链签收 macOS Metal 与 Linux 实体 Vulkan。通过的路径再切换默认执行。
3. 从场景点段扩展到摄影点段、模型和原寸取景。空间算子从 `texture/clarity` 到 `dehaze/brilliance` 逐类放行。
4. 将已签收的输出数学接入共用计划，在 041 用完整 RAW → 文件链路验证服务端能力。

## 6. 测试策略

- 单元测试覆盖 IR、域和参数校验、切段、缓存键、预算、回执版本及旧票据读取。
- 像素测试覆盖有符号 AP1、超白、alpha、恒等、coverage、13 种 blend 和非居中 ROI。按 [像素判据](validation.md#3-像素判据) 对照 CPU/039、两端严格 wgpu、空间接缝及旧配方。
- 队列测试由 032 工作台分别提交 PQ 与 SDR，覆盖摄影回执、文件摘要、重开、断点续跑及已发布目标。原生编辑测试从资料库进入 HDR Graph，打开监看后冻结最终根，核对 24/60 MP 的 FIT、ROI 和交付。
- 性能 A/B 固定同机、同源、构建、质量和测量区间，暖测前预热 5 次并记录至少 30 个样本。冷启动和实际峰值单列。两端各自提交 GPU、驱动及执行回执。
- 故障测试覆盖源离线、能力/预算不足、模型缺失、取消、设备/命令失败、迟到结果和编码失败。

## 7. 回滚

按路由用内部开关切回已验证的执行段。回滚沿用同一冻结源、配方和目标，回执记录该次实际执行者和原因。恢复按旧票据继续或重试，保留已发布文件和其摘要。

## 8. 交付检查表

- [ ] 摄影场景通过 032 准备、发布、重开与恢复，旧 V1 回执可读
- [ ] 同构建原生基线有来源、摄影/DAG/DRT/编码/等待和峰值分项
- [ ] 逐瓦片复用编译产物，验证双目标共享的预算和失败恢复
- [ ] pipeline 与像素缓存分别通过改参和源变更回归
- [ ] 首条 WGSL 场景 DAG 在 macOS Metal 和 Linux 实体 Vulkan 运行且零回退
- [ ] 96 节点/60 MP 性能门通过
- [ ] 模型分块通过或有具体能力/预算诊断
- [ ] 5K/6K 1:1 可用
- [ ] 空间和 ACES 2 输出段逐类放行
- [ ] 旧 v1–v3 通过原语义回放及 035 封存性能门
- [ ] 041 完整 RAW → 文件和队列恢复按能力验收
