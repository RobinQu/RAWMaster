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
Executed 1140 tests, with 100 tests skipped and 0 failures (0 unexpected) in 207.8 s
```

This includes the 037/038 delivery service tests, scene RAW/color/output tests and the existing
SDR/Core Image regression suites. The default auto cutover therefore did not change the reference
results.

```
swift test --skip-build --filter PhotosDevelopmentIntegrationTests
Executed 94 tests, with 1 test skipped and 0 failures (0 unexpected) in 35.9 s
```

The native editor integration suite still passes with auto cutover enabled.

## Performance

Opt-in six-node AP1 graph, 3000×2000, including two analytic coverage nodes and a two-branch
parallel mix; RAW decode, DRT and UI excluded. Three fresh runs:

| Run | Swift p50 | Swift p95 | Rust p50 | Rust p95 | Rust cold |
| --- | --- | --- | --- | --- | --- |
| 1 | 12.97 | 13.47 | 12.96 | 13.74 | 21.86 |
| 2 | 14.18 | 15.17 | 14.07 | 15.29 | 22.68 |
| 3 | 13.38 | 14.09 | 13.54 | 14.45 | 22.08 |

At 6MP both backends are within noise of each other (roughly ±5%), consistent with a
memory-bandwidth-bound graph dominated by five full-resolution color surfaces. The benefit of
one submission and the coverage cache is visible at smaller working sets: at 960×640 the same
graph measured Swift p95 1.90–2.29 ms and Rust p95 1.34–1.68 ms. The opt-in gate therefore
enforces no more than a 20% 6MP regression, while the structural wins are the single completion,
reused surfaces and cross-frame analytic masks. Reports are written with
`RAWMASTER_SCENE_BACKEND_PERFORMANCE=/path/report.json swift test --filter testOptInRustBackendPerformance`.

## Boundaries and follow-up

- Real Core ML/ONNX denoise, super-resolution and segmentation adapters are not part of this
  change. The contracts, ordering, budget and graph binding are verified with deterministic Metal
  providers; model quality/performance and model-file admission still need their own evidence.
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
