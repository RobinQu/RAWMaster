# 039 validation

All commands run from the repository root on 2026-11-27, macOS arm64, Rust core built in release
mode by the SwiftPM build plugin.

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
- Parallel weighted changes, ordered layers, groups, nested scopes, disabled branches, ROI and
  node/bypass views match the Swift reference.
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

The scene preview now constructs the production provider and accepts a model program; the editor
derives denoise/super-resolution stages from a scene-compatible recipe. Subject/person masks are
Vision-native; landscape masks require the installed mask pack.

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

Both delivery outputs remain `.private`; the test samples one pixel through a small blit only to
prove the result is finite. This is the first 60MP scene-graph budget evidence, and it replaces
the previous "not available" boundary for the synthetic case. Real captured 60MP RAW decode and
cross-screen EDR verification remain separate hardware/fixture work.

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

## Boundaries and follow-up

- Production denoise/super-resolution adapters and Vision subject/person segmentation are wired
  and tested on a real PNG. Landscape segmentation is wired through the verified ONNX pack;
  model quality/performance on a broad asset corpus remains follow-up evidence.
- The full 60MP scene graph, real EDR cross-screen sweep and broad camera corpus remain
  environment-dependent acceptance work. The Rust executor enforces the same surface budget and
  region semantics as the Swift executor, but this run did not produce 60MP timing.
- Group-path preview selection remains on Swift. Delivery graphs, live previews and node targets
  use the Rust executor when eligible.
- `externalCoverage` ids are model-stage ids, not graph node ids. A preset that copies such a
  node must also copy/bind the corresponding stage id or the render fails with a missing
  coverage error.
- No user-visible interaction changed, so no HTML prototype or coverage-table entry is required.
  The backend switch is an environment/diagnostic seam; the shipping path keeps the same views.
