# 043 · 实施计划

2026-11-28 · 基于 `main@90b3780f`。本计划把[规格](spec.md)拆成可独立验收的工程阶段。每阶段先保留旧路径，再按实际回执切换；不把“组件通过”当作产品放行。[任务清单](tasks.md) · [验收基线](validation.md)

## 1. 当前代码边界

| 层 | 现有入口 | 043 的改动方式 |
| --- | --- | --- |
| 旧 V3 点配方 | `Modules/ImageEdit/src/graph.rs`、`gpu.rs`、`metal_ffi.rs` | 保留 C ABI；新增 IR lower，先让已支持的 point 段共用融合/缓存；未支持算子继续走 Core Image |
| 场景 DAG | `scene.rs`、`scene/metal_exec.rs`、`scene_ffi.rs` | 保留现有 JSON 文档 ABI；在执行器内部改为“先编译 plan，再按 plan 执行”，输出像素不变 |
| 摄影前缀 | `DevelopmentScenePhotographicV1`、`DevelopmentRendererV3.develop(scenePhotographicInput:)` | 短期作为 adapter 段进入 plan；中期把可融合点算子 lower 到 IR，空间/几何/蒙版/模型逐步迁移 |
| 预览/交付 | `DevelopmentScenePreviewV1`、`DevelopmentSceneTiledDeliveryV1`、`DevelopmentSceneDeliveryServiceV1` | 统一 source/plan/target 生命周期；tiled 交付复用 renderer；双目标共享一次图执行 |
| Swift 参考 | `DevelopmentSceneGraphRendererV1` | 保留为测试 oracle；产品路径只通过 actual receipt 判定后端 |

不改变：

- `DevelopmentSceneGraphV1` 的持久化 schema 与 038 的节点/命令语义；schema 3 的 `photographic` 仍由 038 定义。
- 037 的 AP1/ACES 2 输出契约和 035 的 v1–v3 回放语义。
- AppKit 呈现、文件发布、授权和模型适配边界。

## 2. 目标模块

```text
Modules/ImageEdit/src/
  engine/
    ir.rs           EngineGraph / EngineNode / PortDomain / OpID
    registry.rs     OpDescriptor、参数 schema、CPU/Metal/WGSL 注册
    lower.rs        V3 recipe / SceneGraph / Photographic → IR
    passes.rs       validate / fold / prune / domain / liveness
    fuse.rs         点段融合与切段
    tile.rs         halo、tileEdge、预算与目标布局
    plan.rs         ExecutionPlan、SegmentPlan、CacheKey、BackendPlan
    receipt.rs      ReceiptV2 与阶段计时
  scene/           现有解析器与兼容入口
  graph.rs         现有 V3 点配方入口
  gpu.rs           wgpu 后端
  metal_ffi.rs     Metal 点配方 ABI
  scene_ffi.rs     Scene ABI
```

原则：

- `engine` 不依赖 Swift/UI；只依赖图像域、资源和后端 trait。
- 现有 `scene.rs` 的 JSON 解析与校验保留；`parse` 之后 lower 到 IR，避免一次重写所有调用方。
- 现有 ABI 不破坏；新增 `rm_scene_program_plan_v2` / `rm_scene_program_render_plan_v2` 或等价入口，旧入口内部走同一 plan。
- `OpDescriptor` 的 CPU 参考和 Metal 内核放在同一个注册项，避免 Rust/Swift/CI 三份语义长期漂移。

## 3. 阶段设计

### M0 · 基线（约 1 周）

1. 在 60 MP 摄影+3 节点 DAG 上加入分项回执：摄影前缀、DAG segment、DRT、blit、decode、encode、等待。
2. 记录当前 tile 数、dispatch、峰值、`backend/dagBackend/photographicEngine`。
3. 对 6 MP 六节点图、038 FIT/组内监看、036 1:1 矩阵各留一份同机构建基线。
4. 先不做算法改动；只加观测和可复现脚本。

退出：同一构建可重复得到基线；能回答“1.75 s 中图执行、编码、等待各占多少”。

### M1 · P0 去重（约 1–2 周）

1. **Tiled renderer 复用**：`DevelopmentSceneTiledDeliveryV1.render` 在 tile 循环外创建一次 `Renderer`（以及其 Rust `SceneProgram`），每个 tile 只换 input/origin；`outputRenderer` 继续复用 DRT stage。
2. **双目标单次图**：每个 tile 的 scene master 只算一次；SDR/HDR 各自 `renderDelivery` 到两个目标，再分别 blit。若编码器要求整帧，保留两个 destination，但不再重跑图/解码。
3. **单 command buffer**：为 decoder/photographic/graph/DRT/blit 增加“编码到给定 command buffer”的内部接口；先合并 graph+DRT+blit，再评估 decode 合并。
4. **pipeline 形状缓存**：`RustSceneGraphRenderer.topology` 改为不含 UUID 的结构哈希；program 缓存 LRU；同一设备复用 `MTLLibrary`/pipeline。
5. **回执**：记录 `rendererBuildCount`、`programCompileCount`、`libraryCompileCount`，防止重复准备再次出现。

退出：像素不变；60 MP 双目标不慢于 1.751 s ±5%；tile/dispatch 不增加；重复编译计数下降；严格 Rust 回执可核对。

### M2 · IR 与点段融合 PoC（约 3–5 周）

1. **IR 定义**：`EngineGraph`、`EngineNode`、`PortDomain`、`OpID`；先覆盖现有 9 种 scene operation 和 V3 已支持点算子。
2. **Lower**：`DevelopmentSceneGraphV1.Scope` → `EngineGraph`；`DevelopmentAdjustmentsV3` 的已支持点段 → `EngineGraph`；摄影前缀保留 adapter 节点。
3. **Passes**：validation、neutral/零权重裁剪、曝光链/ normal layer 折叠、域转换插入、liveness。
4. **Fusion**：同域同精度同几何的 pointwise 段合成一个 segment；分支在点段内内联，否则在分支边界切段；每段最多 24–32 节点，超限自动切段。
5. **Metal codegen**：生成 straight-line MSL 或参数化 kernel；参数放 buffer；curve/coverage 作为输入；`fast_math=false`/`mathMode=.safe` 保持。
6. **Pipeline cache**：结构哈希 → `MTLComputePipelineState`；参数变化只更新 buffer，不重编译。
7. **Shadow test**：每个 segment 与当前 Rust/Swift 逐位对照；整图与旧执行器对照；96 节点合成图做性能 A/B。

退出：96 节点合成图吞吐 ≥2×、峰值 ≤50%；点段逐位一致；60 MP 三节点图阶段 ≥15%；038 门槛不退。

### M3 · 资源与模型（约 4–8 周）

1. **MTLHeap/别名**：按 liveness 为 segment 边界 surface 分配/别名；预算按实际 allocation 记账；保留无 heap 回退。
2. **模型分块**：`DevelopmentSceneModelPreviewV1` 接受 tile+halo；分割 mask 按全图坐标拼装或按 tile 视图绑定；不可分块模型显式拒绝并说明。
3. **1:1 大窗口**：`DevelopmentScenePreviewV1.sampled(.pixels)` 改为按预算/显示分辨率决定 tile；去掉 1,000 万像素硬上限；保证窗口帧与整幅 crop 等价。
4. **异步双缓冲**：一个 in-flight tile/frame + 一个 pending；decode/graph/encode 重叠；取消/迟到结果按请求身份拒绝。
5. **缓存分离**：working/cache/coverage/model/encode 分开；禁止因缓存挤占工作区而整批清空重试。

退出：60 MP 峰值下降；模型 60 MP 可用或明确拒绝；5K/6K 1:1 可用；取消与竞态回归通过。

### M4 · 空间算子与能力（季度级）

1. texture/clarity：显式 halo 的可分离高斯 + band 合成；替换 CI factor/restore/tile 的整幅 materialize；窗口/整幅/导出三组证据。
2. dehaze/brilliance：分块确定性归约；先 profile 整幅归约占比，再做 halo PoC；不假设 factor/restore 可复用。
3. 九类调色：按算子注册表逐类 lower；点段先融合，空间/全图单独切段；每类单独像素/性能门。
4. 几何/蒙版/修饰：几何作为显式边界；coverage 保持独立端口；模型遮罩与几何冲突沿用 `validatePhotographicCoverage` 拒绝。
5. LUT/胶片/OCIO：声明域/参考白/峰值；每支路只成像一次；不把 SDR-only 资产静默套到 HDR。
6. Linux/041：按能力表接入 CPU/Vulkan 场景执行；不复用 macOS 证据。

退出：逐算子窗口/整幅/导出证据；50 配方矩阵 P95 至少 1.5×；产品入口同动作验收。

## 4. 关键数据结构

### 4.1 Plan

```text
ExecutionPlan
  sourceRevision, roi, fullGeometry
  segments: [SegmentPlan]
  output: SegmentOutput
  budget: BudgetPlan
  cacheKeys: CacheKeySet
  producedBy: compilerVersion

SegmentPlan
  id, opIDs, domain, precision, tilePolicy
  inputs: [SurfaceRef]
  outputs: [SurfaceRef]
  backend: metal | wgpu | coreImage | cpu
  halo: Int
  estimatedBytes, estimatedDispatches
```

### 4.2 CacheKey

```text
CacheKey
  sourceContentDigest
  roi (origin/size, normalized where applicable)
  domain (encoding/primaries/white/transfer/alpha/precision)
  segmentStructureHash
  parameterHash
  resourceDigests (LUT/film/model)
  engine/compiler version
```

结构哈希只包含节点种类、连接、分段和输出位置，不含 UUID/名称；内容键包含 UUID 以区分不同节点身份。

### 4.3 ReceiptV2

```text
ReceiptV2
  planHash, compilerVersion
  backend, dagBackend, photographicEngine
  tiles, segments, dispatches
  gpuMilliseconds, decodeMilliseconds, encodeMilliseconds, waitMilliseconds
  peakWorkingBytes, peakCacheBytes, peakModelBytes, budgetBytes
  cacheHits: coverage/node/segment/pipeline
  fallbackReason
```

## 5. 迁移顺序

1. 先让 scene DAG 走 plan（不改变执行），确认回执与像素不变。
2. 让摄影前缀作为 adapter segment 进入 plan，统一预算/回执/tile 生命周期。
3. 先融合 scene DAG 的点段（曝光/曲线/强度/coverage/mixer），再接摄影前缀的点段。
4. 空间算子按 texture/clarity → dehaze/brilliance → 其余的顺序；每类先单独放行。
5. 九类调色在融合和资源计划稳定后接入；不要先加 UI 再补引擎。
6. Linux/041 最后接入，按能力表逐项放行。

## 6. 测试策略

- **单元**：IR 校验、pass 折叠、融合切段、缓存键、预算、回执字段。
- **逐位**：点算子/coverage/13 blend/零权重/中性节点；与当前 Rust 和 Swift 参考对照。
- **ROI**：1:1 窗口 vs 整幅 crop；空间算子按容差；接缝/halo。
- **旧配方**：v1–v3 固定成片回放；035 封存矩阵。
- **产品路径**：资料库→编辑→HDR→Graph→监看→冻结→032；同一签名包。
- **性能**：同机同源，预热 5、30 样本；冷/暖分开；记录 p50/p95、峰值、tile/dispatch、fallback。
- **故障**：预算不足、模型缺失、源离线、取消、迟到结果、命令缓冲失败、编码失败。

## 7. 回滚

每个 segment/路由保留旧执行入口；通过环境变量或内部特性开关切回。回滚必须保持同一配方、同一源、同一目标，不改变持久化格式。回滚后回执标记实际后端，不能把旧路径结果冒充新路径。

## 8. 交付检查表

- [ ] 基线回执包含摄影/DAG/DRT/编码/等待分项
- [ ] tiled 交付不再每 tile 新建 Renderer
- [ ] 双目标共享一次图执行
- [ ] pipeline 缓存不含 UUID，批量复用
- [ ] 点段融合 shadow test 通过
- [ ] 96 节点/60 MP 性能门通过
- [ ] 模型分块或明确拒绝
- [ ] 5K/6K 1:1 可用
- [ ] 空间算子逐类放行
- [ ] 严格 Rust 受支持组合零回退
- [ ] 旧 v1–v3 成片回放不变
