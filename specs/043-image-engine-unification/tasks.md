# 043 · 任务清单

2026-11-28 · 基于 `main@90b3780f`。状态：`待办` / `进行中` / `完成` / `否决`。完成必须有同构建的像素或性能回执，不以代码合并代替验收。[规格](spec.md) · [计划](plan.md) · [验收基线](validation.md)

## M0 · 基线与观测

- [ ] **M0-01** 在 60 MP 摄影+3 节点 DAG 上记录摄影前缀、DAG、DRT、blit、decode、encode、等待分项。
- [ ] **M0-02** 记录当前 60 MP 双目标基线：`elapsedMs`、35 tiles、105 dispatches、图峰值 1.4589 GB / 1.5 GiB。
- [ ] **M0-03** 记录 6 MP 六节点图、038 FIT/监看、036 1:1 矩阵的同机构建基线。
- [ ] **M0-04** 增加 `ReceiptV2` 草案：plan、segments、GPU 时间、encode、等待、峰值分项、fallback。
- [ ] **M0-05** 写可复现脚本；固定 SHA、运行库、构建摘要和报告路径。
- [ ] **M0-06** 明确 1.751 s 中图执行/编码/等待各占多少，并据此确认 P1/P2 优先级。

## M1 · P0 低风险去重

- [ ] **M1-01** `DevelopmentSceneTiledDeliveryV1` 在 tile 循环外创建一次 `Renderer`/`SceneProgram`，复用 pipeline 与 output stage。
- [ ] **M1-02** 每个 tile 只解码 + DAG 一次，SDR/HDR 共享 scene master，分别 DRT 和 blit。
- [ ] **M1-03** 合并 graph+DRT+blit 到单 command buffer；评估 decode 合并。
- [ ] **M1-04** topology 结构哈希去掉 UUID；program 缓存改 LRU；同一设备复用 `MTLLibrary`/pipeline。
- [ ] **M1-05** 回执增加 `rendererBuildCount`、`programCompileCount`、`libraryCompileCount`。
- [ ] **M1-06** 像素回归：tiled vs untiled、双目标 vs 单目标、60 MP 对应像素。
- [ ] **M1-07** 性能回归：60 MP 不慢于基线 ±5%；tile/dispatch 不增加；严格 Rust 回执可核对。

## M2 · IR 与点段融合

- [ ] **M2-01** 定义 `EngineGraph`/`EngineNode`/`PortDomain`/`OpID`，覆盖现有 9 种 scene operation。
- [ ] **M2-02** 定义 `OpDescriptor` 与注册表：域、端口、pointwise/spatial/reduction、参数 schema、CPU 参考、Metal/WGSL、成本模型、缓存键。
- [ ] **M2-03** `DevelopmentSceneGraphV1.Scope` → IR lower；保持 schema/语义不变。
- [ ] **M2-04** `DevelopmentAdjustmentsV3` 已支持点段 → IR lower；摄影前缀 boundary 先作为 adapter segment。
- [ ] **M2-05** passes：验证、neutral/零权重裁剪、曝光链/normal layer 折叠、域转换、liveness。
- [ ] **M2-06** 点段融合：同域同精度同几何；分支内联或切段；每段最多 24–32 节点。
- [ ] **M2-07** Metal codegen：straight-line MSL/参数化 kernel；参数 buffer；coverage/curve 输入；`fast_math=false`。
- [ ] **M2-08** pipeline cache：结构哈希 → pipeline；参数变化只更新 buffer。
- [ ] **M2-09** shadow test：每 segment 与当前 Rust/Swift 逐位对照；96 节点合成图 A/B；60 MP 3 节点 A/B。
- [ ] **M2-10** 门：96 节点吞吐 ≥2×、峰值 ≤50%；点段逐位一致；60 MP 图阶段 ≥15%；038 门槛不退。

## M3 · 资源、模型与高分辨率

- [ ] **M3-01** `MTLHeap` + liveness 别名；预算按实际 allocation；无 heap 回退。
- [ ] **M3-02** working/cache/coverage/model/encode 预算分离；禁止因缓存挤占而整批清空重试。
- [ ] **M3-03** 模型前缀 tile+halo 推理；分割 mask 按全图坐标拼装；不可分块显式拒绝。
- [ ] **M3-04** 1:1 `.pixels` 去掉 1,000 万像素硬上限，按预算/显示分辨率自适应 tile；5K/6K 验证。
- [ ] **M3-05** 异步双缓冲：一个 in-flight + 一个 pending；decode/graph/encode 重叠。
- [ ] **M3-06** 竞态/取消：换片、切组、迟到结果、预算失败、命令缓冲失败。
- [ ] **M3-07** 门：60 MP 峰值下降；模型 60 MP 可用或明确拒绝；5K/6K 1:1 可用。

## M4 · 空间算子与产品能力

- [ ] **M4-01** texture/clarity：可分离高斯 + 显式 halo + band 合成；窗口/整幅/导出三组证据。
- [ ] **M4-02** dehaze/brilliance：分块确定性归约；先 profile 再 PoC；不假设 factor/restore 可复用。
- [ ] **M4-03** 九类调色按算子注册表逐类 lower；点段先融合，空间/全图切段。
- [ ] **M4-04** 几何/蒙版/修饰：显式边界；coverage 独立端口；模型遮罩+几何冲突拒绝。
- [ ] **M4-05** LUT/胶片/OCIO：域/参考白/峰值声明；每支路只成像一次；SDR-only 资产不静默进 HDR。
- [ ] **M4-06** 50 配方矩阵：逐类设门，矩阵 P95 至少 1.5×；产品入口同动作验收。
- [ ] **M4-07** 旧 v1–v3 成片回放与 035 封存矩阵复跑；未过不得替换旧路径。

## M5 · 跨端

- [ ] **M5-01** 041 能力表增加 scene 执行项；CPU/Vulkan 场景后端。
- [ ] **M5-02** Linux 真实 RAW/场景图/模型/编码逐项验收；不复用 macOS 证据。
- [ ] **M5-03** 服务端资源预算、取消、重试、回执与 040/041 队列对齐。

## 横切

- [ ] **X-01** 严格 Rust 受支持组合零回退；auto 回退计数/原因/诊断。
- [ ] **X-02** 票据记录 plan、segment 后端、tile、峰值、编码、文件摘要；重开后核对。
- [ ] **X-03** 每个新算子先写像素契约（逐位或容差），再写性能门。
- [ ] **X-04** 每个路由保留旧入口和回滚开关；回滚保持配方/源/目标不变。
- [ ] **X-05** 文档同步：035/036/037/038/039 只链接 043，不在多处复制同一实现细节。
