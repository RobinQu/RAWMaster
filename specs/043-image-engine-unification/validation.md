# 043 · 验收基线

2026-11-28 · **尚未实施。** 本页只登记 043 开始前的基线、证据来源和放行口径，不把计划中的结果写成已通过。每次切换路由后，按同一构建、同一源、同一目标追加实际回执。[规格](spec.md) · [计划](plan.md) · [任务](tasks.md)

## 1. 当前基线

| 场景 | 当前数据 | 来源 |
| --- | --- | --- |
| 60 MP 摄影+3 节点 DAG，PQ AVIF + SDR JPEG | `elapsedMs=1750.98`；每目标 35 tiles、105 dispatches；图峰值 `1,458,929,664 B` / 预算 `1,610,612,736 B`；`backend=mixed`、`dagBackend=rust` | [回执](../037-color-film-hdr/evidence/2026-11-27-photographic-60mp.json) |
| 6 MP 六节点 AP1 图 | Rust/Swift p95 约 14.26/14.27 ms；5 个全幅 F32 surface | [039 验证](../039-rust-scene-backend/validation.md#performance) |
| 038 FIT / 组内监看 | 22.07/23.30 ms；19.43/20.78 ms；最终 18.23/19.34 ms | [038 验证](../038-node-dag-workflow/validation.md#原生可编辑-graph) |
| 036 1:1 50 配方 | 中位 111.4 ms；P95 1,474.3 ms；texture 482.3、dehaze 1,586.2、brilliance 3,883.8 ms | [036 规格](../036-render-pipeline-performance/spec.md#画布自由缩放与取样) |
| 035 发布门 | 首次精确/定稿中位 77–81 ms，对 24.35/25.92 ms 上限；缩放平移 P95 ~21 ms，对 8 ms 上限 | [035 路线图](../035-portable-processing-cores/roadmap.md#当前实现和签收缺口) |

这些数字只说明 043 的起点，不表示 043 已通过。

## 2. 每阶段必须记录

### M0 · 基线

- 60 MP 分项：photographic prefix、DAG segments、DRT、blit、decode、encode、wait。
- 同构建的 tile、dispatch、峰值、backing texture 数、pipeline/library 编译次数。
- 6 MP 六节点、038 FIT/监看、036 1:1 的同机构建基线。
- 报告写明 commit、构建摘要、FlashRaw 版本、样片 SHA、系统/屏幕、实际后端和跳过原因。

### M1 · P0

- tiled vs untiled、单目标 vs 双目标、复用 renderer 前后的像素对照。
- `rendererBuildCount`/`programCompileCount`/`libraryCompileCount`。
- 60 MP 双目标墙钟、图阶段时间、tile/dispatch、峰值。
- 门：像素不变；60 MP 不慢于 1.751 s ±5%；tile/dispatch 不增加；严格 Rust 回执可核对。

### M2 · IR/融合

- 每个 segment 与当前 Rust/Swift 的逐位对照；13 blend、零权重、中性节点、coverage。
- 96 节点合成图：吞吐、峰值、segment 数、dispatch 数。
- 60 MP 三节点图：图阶段时间、tile 数、峰值。
- 门：96 节点 ≥2×、峰值 ≤50%；点段逐位一致；60 MP 图阶段 ≥15%；038 门槛不退。

### M3 · 资源/模型/高分辨率

- 60 MP 峰值分项：working/cache/model/encode。
- 模型 tile+halo 的 mask 对齐、边界、取消、预算拒绝。
- 5K/6K 1:1 窗口与整幅 crop；非居中窗口；平移半步。
- 异步双缓冲的取消、迟到结果、换片、切组。
- 门：峰值下降；模型 60 MP 可用或明确拒绝；5K/6K 1:1 可用。

### M4 · 空间/能力

- 每个算子：窗口 vs 整幅、1:1 vs 导出、零覆盖、边缘/接缝。
- 50 配方矩阵：中位、P95、峰值、fallback。
- 九类调色逐类门；几何/蒙版/修饰的坐标与历史。
- 门：逐算子像素契约；矩阵 P95 至少 1.5×；未过不得替换旧路径。

## 3. 像素判据

| 对象 | 判据 |
| --- | --- |
| 点运算、coverage、13 blend | 与当前 Rust/Swift 逐位一致；若必须放宽，采用 038 的 `8×10⁻⁷ × max(1, |reference|)` 并逐项说明 |
| 1:1 窗口 vs 整幅 crop | 逐位一致；空间算子按既有容差单独定义 |
| 零 coverage / 禁用 / 零权重 / 中性 | 对象或像素保持原值 |
| 旧 v1–v3 | 按原配方、原解码、原几何、原成片回放 |
| 模型遮罩 + 几何 | 坐标不一致时提交前拒绝；预览、示波器、交付一致 |
| 交付文件 | AVIF 位深/CICP/矩阵/PQ 回读；SDR ICC/位深；文件 SHA 与重开核对 |

## 4. 性能判据

- 同机、同源、同分辨率、同质量；冷/暖分开；预热 5、至少 30 样本；报告 p50/p95、峰值、tile/dispatch、fallback、实际后端。
- 只有同测量区间的数据用于切换判断；不同分辨率/目标不得拼接成一条曲线。
- 60 MP 必须分别记录 photographic prefix、DAG、DRT、encode；不能只报总墙钟。
- 交付吞吐与交互尾延迟分开；批处理另列首件、整批、失败/取消。

## 5. 放行边界

- 任何“已通过”必须同时有：同构建、实际执行、像素证据、性能证据、回执字段。
- 组件探针、合成图、单算子不能替代产品入口；原型不能替代原生。
- 严格 Rust 受支持组合回退必须为 0；auto 回退必须记录原因并在诊断可见。
- 旧路径未退役前，回滚必须保持同一配方、同一源、同一目标；回滚结果不得冒充新路径。
- 035/036/037/038 的既有未通过项继续保留原状态，不因 043 合并而自动通过。

## 6. 复现命令（初始）

```sh
# 60 MP 摄影+DAG 交付回执（现有测试入口；043 后应输出 ReceiptV2）
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
export RAWMASTER_SCENE_RAW_FIXTURES="$PWD/output/spec037-raw-fixtures"
swift test -c release --skip-build --jobs 4 -Xswiftc -enable-testing \
  --filter 'DevelopmentSceneDeliveryServiceV1Tests|DevelopmentScenePhotographicV1Tests|DevelopmentSceneRAWV1Tests'

# Rust 场景解析器/执行器
cargo test --release --offline --locked --manifest-path Modules/ImageEdit/Cargo.toml --lib scene::tests

# 038 原生图与监看（按 038 验证页的参数）
swift test -c release --skip-build --jobs 4 -Xswiftc -enable-testing \
  --filter 'EditingSceneGraphWindowTests|EditingSceneDarkroomTests|DevelopmentScenePreviewV1Tests'

# 036 1:1 矩阵（按 036 验证页的参数；需真实 9504×6336 样片）
```

命令中的测试名以实施时仓库为准；任何被跳过的用例必须在报告中保留跳过原因。

## 7. 待补证据

- [ ] M0 60 MP 分项报告
- [ ] M1 tiled/双目标像素与性能对照
- [ ] M2 点段融合 shadow test 与 96 节点 A/B
- [ ] M3 模型分块/5K-6K 1:1/异步取消
- [ ] M4 空间算子逐类证据与 50 配方矩阵
- [ ] 035 封存矩阵在同包复跑
- [ ] 041 Linux 场景能力（M5，单独放行）
