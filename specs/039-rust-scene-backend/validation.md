# 039 · Rust 场景后端验证

本轮从本地 `1e5a1ceb` 继续验收。60 MP 的 FIT、原寸取景和全图示波器均沿用产品内存上限。示波器携带本次图求值回执。032 将实际后端、瓦片和派发次数、峰值及预算与暂存文件票据写入同一目录事务，已交付后重开仍可核对。模型阶段随场景图 v2 冻结，要求整图输入的模型单独检查全分辨率预算。[实拍测量](../037-color-film-hdr/evidence/real-60mp-bayer-budget.json) · [冻结交付回执](../025-editing-workspace/evidence/editor-rails/release-acceptance.json)

下文保留 2026-11-27 的历史分阶段测试。`main@b238c0ab` 重新运行了 Rust 解析器、严格 Metal 影子对照、合成 60 MP、实拍暗房和冻结 032。实际执行的路径及本机数据见[联合复验](../035-portable-processing-cores/roadmap.md#本次-main-复验)。

## 组内监看与实际后端

原实现只在顶层调用 Rust，桥接层省略组路径，执行器也没有使用 ABI 中的 `groupPath`。此外，历史影子测试中标作 Swift 的一侧使用默认模式。修复后，同一份 038 图在两个显式指定的渲染器上运行。测试含两层嵌套、父组禁用、子组部分强度、组前曝光、组内解析覆盖以及非零原点 ROI。组输入、指定节点和组最终根逐通道比较，允许的绝对误差为 2×10⁻⁵ × max(1, |参考通道值|)。返回全图时像素逐值相同。非法组或覆盖目标会报错并清除上次回执。[严格后端回归](../../Tests/RAWMasterImagingTests/RustSceneGraphRendererTests.swift)

对实拍雪景用签名包重开，HDR drawable 记录了帧 ID、Rust 后端、一次图派发与 66,355,200 字节图峰值。切换查看目标时缓存帧保留原回执，根输入直通记录零派发。模型程序变化会清理预览后缀，带模型的执行暂时关闭源图节点的跨请求缓存，解析遮罩仍可复用。此轮只记录了预览帧，后续示波器、模型和 032 的验收见页首。[帧及测量记录](../032-export-workspace/grid-delivery-20261127.json) · [实拍预览回归](../../Tests/RAWMasterImagingTests/DevelopmentScenePreviewV1Tests.swift)

同一 M4 Max 上，600 万像素图各 15 个暖样本的 p95 为 Rust 14.26 ms、Swift 14.27 ms。61.44 MP 合成输入使用 6 GiB 图预算，分 6 瓦片，派发 42 次，图峰值 4.70 GiB。本轮真实相机 60 MP 在产品预算下的分项实测见页首。[039 放行条件](spec.md#编译瓦片和回执)

## Builds

```
swift build --product RAWMaster --jobs 4
Build complete! (0.58 sec)
```

```
cd Modules/ImageEdit && cargo build --release --offline --locked --jobs 4
(no warnings outside the pre-existing `block` future-compat notice)
```

## Rust parser/executor unit tests

```
cd Modules/ImageEdit && cargo test --release --offline --locked --jobs 4 --lib scene::tests
test scene::tests::accepts_a_bounded_image_and_coverage_graph ... ok
test scene::tests::rejects_cycles_and_incompatible_ports ... ok
test scene::tests::rejects_out_of_range_parameters_before_compilation ... ok
test scene::tests::rejects_duplicate_ids_disconnected_nodes_and_unknown_fields ... ok
test result: ok. 4 passed; 0 failed
```

## Swift shadow and contract tests

```
swift test --skip-build --filter \
  "RAWMasterImagingTests.DevelopmentSceneGraphRendererV1Tests|\
RAWMasterImagingTests.RustSceneGraphRendererTests|\
RAWMasterImagingTests.DevelopmentSceneModelPipelineV1Tests|\
RAWMasterImagingTests.DevelopmentSceneDeliveryServiceV1Tests|\
RAWMasterCoreTests.DevelopmentSceneGraphV1Tests"
Executed 25 tests, with 5 tests skipped and 0 failures
```

Coverage of the shadow suite:

- All 13 layer modes match the Swift executor for signed, superwhite and premultiplied pixels.
- Parallel weighted changes, ordered layers, groups, disabled branches, ROI and
  top-level node/bypass views match the Swift reference. At that revision group-path monitoring ran on
  Swift even in strict mode. Use the actual receipt to verify which backend executed a request.
- All analytic coverage ports (linear, radial, combine add/subtract/intersect, adjust) and
  external provider coverage are exercised.
- Malformed JSON, unknown/coverage previews, over-budget frames and stale revision handling are
  rejected.
- ACES 2 `sdr709` and `hdr2020` delivery plus EDR viewing output match the Swift executor; output
  textures remain `.private` (no CPU readback).
- Denoise, 2x super-resolution, segmentation ordering, model identity validation and the
  `externalCoverage` mask path are exercised with a deterministic Metal provider. A JSON document
  containing a `flux` stage fails to decode.

## Full imaging target

```
swift test --skip-build --filter RAWMasterImagingTests
Executed 1151 tests, with 101 tests skipped and 0 failures (0 unexpected) in 228.7 s
```

This includes the 037/038 delivery service tests, scene RAW/color/output tests and the existing
SDR/Core Image regression suites. The default auto cutover therefore did not change the reference
results.

```
swift test --skip-build --filter PhotosDevelopmentIntegrationTests
Executed 94 tests, with 1 test skipped and 0 failures (0 unexpected) in 35.9 s
```

The native editor integration suite still passes with auto cutover enabled.

## P2 tiling, cache and receipt tests

```
swift test --skip-build --filter RustSceneGraphRendererTests
Executed 13 tests, with 2 tests skipped and 0 failures
```

- `testTiledExecutionMatchesUntiledAndReportsReceipt` renders a 256×192 graph with a coverage
  mask, group, parallel mix and layered correction once untiled and once with a forced 64-pixel
  tile edge. The pixels are bit-identical and the receipt reports 12 tiles and more dispatches
  than tiles.
- `testSourceRevisionCacheReusesUnchangedPrefixAfterParameterEdit` edits only the suffix of a
  two-stage grade. The second render reports `nodeCacheHits = 1`; changing the source revision
  reports zero node hits but still reuses analytic coverage.
- `testCoverageCacheInvalidatesWhenMaskParametersChange` verifies that combine/adjust keys include
  their upstream mask parameters: a changed ramp re-renders exactly like a fresh engine instead of
  reusing stale coverage.
- `testAutoFallbackCarriesAReceiptAndReason` forces a Rust budget failure and asserts the Swift
  fallback receipt with a non-nil reason.
- The 60MP receipt test below asserts `tiles > 1`, `peakBytes <= budget` and a finite delivered
  pixel for both SDR and HDR.

## Production model adapters on a real asset

```
swift test --skip-build --filter DevelopmentSceneProductionModelProviderTests
Executed 4 tests, with 0 failures (0 unexpected) in 3.24 s
```

- `testRealAssetDenoiseAndSuperResolutionProduceDeterministicAP1Surfaces` loads
  `Fixtures/Spektrafilm/person.png`, converts the real pixels to AP1, runs the bundled PhotoVGG7
  denoiser and PhotoUpconv7 2x model, and verifies changed finite pixels plus doubled dimensions.
- `testVisionSegmentationFeedsARealSceneGraphMask` runs Vision foreground and person segmentation,
  verifies non-trivial full-size `R32Float` masks, then runs
  `denoise → super-resolution → externalCoverage corrector → ACES HDR delivery` in one render.
- `testLandscapeSegmentationUsesTheVerifiedMaskPack` runs the EfficientViT ONNX model from
  `experiments/MaskAI/Vendor` after the landscape integrity hash was corrected to the shipped
  `e6df30d...` artifact.
- `testAP1ToLinearRec709RoundTripsThroughTheModelDomain` verifies the inverse color matrix used by
  all model adapters.

场景预览服务已可接收显式模型程序，测试直接提供程序及资源。编辑控制器从 `adjustmentsV3` 推导去噪和超分，但持久 v4 配方要求该字段为空。示波器、冻结交付尚未消费模型。实拍 PNG 的组件证据覆盖提供者、遮罩端口和 HDR 分支，产品回放待补。[模型接线](spec.md#模型与资源)

## EDR headroom across real screens

```
RAWMASTER_SCENE_EDR_REPORT=/tmp/scene-edr.json \
  swift test --skip-build --filter DevelopmentSceneEDRCrossScreenTests
Executed 1 test, with 0 failures
```

The host reported two real screens:

| Screen | Current headroom | Potential headroom |
| --- | --- | --- |
| Built-in Retina Display | 1.2× | 16× |
| LG TV SSCR2 | 1.2× | 6.70× |

The numeric matrix rendered an 8.0 AP1 highlight through SDR and HDR paths. SDR highlight was
0.886; HDR highlight was 5.351; all headroom values above 1 selected `hdr2020`, and 1.0 selected
`sdr709`. Outputs were finite, `.private`, and highlight > middle at every headroom. This covers
every connected screen profile plus simulated 1.2/1.5/2/4/6.7/16 headroom values. Physical
simultaneous presentation on two EDR displays is still a manual/visual acceptance step; the test
records the actual screen inventory and headroom rather than pretending a single compositor run
is a cross-monitor visual pass.

## 60MP synthetic graph

Opt-in generated source, no RAW decode:

```
RAWMASTER_SCENE_60MP_PERFORMANCE=/tmp/scene-60mp.json \
  swift test --skip-build --filter testOptIn60MegapixelSceneBudgetAndReceipt
```

| Measure | Result |
| --- | --- |
| Resolution | 9600×6400 (61.4 MP) |
| Surface budget | 6,442,450,944 bytes (6 GiB) |
| Tiles | 6 |
| Dispatches | 42 |
| Graph, first render | 567.9 ms |
| Graph, warm render | 278.2 ms |
| ACES SDR delivery | 81.7 ms |
| ACES HDR delivery | 48.7 ms |
| Peak receipt bytes | 5,046,796,288 (4.70 GiB) |

Both delivery outputs remain `.private`. The test reads one pixel per target to check finiteness.
These receipts cover generated 61.4 MP input, a 6 GiB graph budget, and two separate ACES output
timings. The production export default is 1.5 GiB. A full RGBA32F input and output already exceed
that limit at this size. See the [production budget and tiling plan](spec.md#编译瓦片和回执).

## Performance

Opt-in six-node AP1 graph, 3000×2000, including two analytic coverage nodes and a two-branch
parallel mix; RAW decode, DRT and UI excluded. Final post-P2 run:

| Backend | p50 | p95 | cold |
| --- | --- | --- | --- |
| Swift reference | 14.46 | 15.76 | — |
| Rust strict | 14.53 | 15.83 | 21.19 |

At 6MP both backends are within noise of each other (roughly ±5%), consistent with a
memory-bandwidth-bound graph dominated by five full-resolution color surfaces. The benefit of
one submission and the coverage cache is visible at smaller working sets: at 960×640 the same
graph measured Swift p95 1.90–2.29 ms and Rust p95 1.34–1.68 ms. The opt-in gate therefore
enforces no more than a 20% 6MP regression, while the structural wins are the single completion,
reused surfaces and cross-frame analytic masks. Reports are written with
`RAWMASTER_SCENE_BACKEND_PERFORMANCE=/path/report.json swift test --filter testOptInRustBackendPerformance`.

## 待补证据

- 用真实 60 MP RAW 按产品配置测试冷暖预览、1:1 和冻结 HDR／SDR 成片。合成图已取得执行与瓦片回执，源解码、全链路预算和批量仍需实测。
- 在实际安装包中记录两个显示环境的换屏、亮度及关联帧。组件余量测试记录目标分支和纹理数值，实际显示按 [037](../037-color-film-hdr/plan.md)验收。
- 该轮组内监看由 Swift 执行，本轮已补严格后端对照。后续将回执延伸至示波器和 032 冻结任务。`externalCoverage` 随模型阶段及目标来源重绑，按[迁移顺序](spec.md#迁移顺序)验证。
