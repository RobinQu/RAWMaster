# 039 Rust scene backend

## Goal

Move the deterministic 037/038 scene pipeline onto a Rust-owned executor without creating a
second graph schema or a second color contract. The 038 `DevelopmentSceneGraphV1` document and
the 037 scene-linear ACEScg/AP1 surfaces remain authoritative. Swift keeps the reference Metal
executor, platform display/encoding adapters and the model-provider adapters.

The five slices:

| Slice | Result |
| --- | --- |
| P0 | `RMSceneProgram` C ABI, `ImageEditLoader` host shim, Swift `RAWMasterImageKernel.SceneProgram`, `RustSceneGraphRenderer` seam |
| P1 | Rust parser/validator plus a single-command-buffer Metal executor for corrector, parallel, layer (13 modes), group and all four analytic coverage ports |
| P2 | One submit per render, transient surface pool, source-independent coverage prefix cache, shared surface budget, region/origin support |
| P3 | Deterministic full-image model prefix for denoise/2x super-resolution/segmentation, provider protocol, `externalCoverage` graph port for provider masks, explicit exclusion of generative candidates |
| P4 | Rust result textures feed the existing ACES 2 SDR/HDR output stages and `EditingSceneCanvas` direct `CAMetalLayer` presentation without CPU readback |
| P5 | Auto cutover: Rust is attempted by default on eligible graphs and falls back to the Swift executor; strict `RAWMASTER_SCENE_BACKEND=rust` is used by shadow tests |

## Backend selection

`DevelopmentSceneGraphRendererV1` owns the seam:

- unset / any value other than the overrides: **auto**. Eligible graphs (no group-path preview)
  execute in Rust. If the core, shader, budget or a render call fails, the same frame is retried
  with the Swift executor.
- `RAWMASTER_SCENE_BACKEND=rust`: strict Rust. Used by the shadow tests and performance runs so a
  regression cannot silently fall back.
- `RAWMASTER_SCENE_BACKEND=swift` (also `off`, `0`): forced reference path.

Group-path previews stay in Swift because the public view selection walks nested scopes; this is
a presentation concern and not part of the delivery graph. Model stages run before the graph, so
the Rust executor only sees the post-model image and coverage textures.

## Rust executor

- `Modules/ImageEdit/src/scene.rs` parses the 038 JSON (`schemaVersion: 1`), enforces the same
  node/depth/layer budgets, parameter ranges, port compatibility and reachability as
  `DevelopmentSceneGraphV1`.
- `Modules/ImageEdit/src/scene/metal_exec.rs` compiles two Metal kernels (`rmDagColorV1`,
  `rmDagCoverageV1`) and encodes the reachable DAG into **one command buffer** with one completion
  wait. The Swift reference still submits one command buffer per node.
- Image surfaces are premultiplied AP1 `RGBA32Float`; coverage surfaces are `R32Float`. The
  `geometry` and `origin` fields in the view JSON preserve source-edge coverage coordinates for
  ROI renders.
- A surface pool recycles retired intermediates. Analytic coverage (ramps, ellipses, combine,
  adjust) is cached across frames, keyed by node, parameters, surface size and frame geometry.
  Provider/segmentation coverage is never cached because it depends on the source.
- The input, live intermediates, pool and coverage cache share the caller's surface budget. A
  strict Rust over-budget frame returns `surfaceBudget`; auto mode lets the Swift executor decide
  whether its zero-allocation path can satisfy the frame.

## Model prefix contract

`DevelopmentSceneModelV1` is the deterministic model surface:

- `denoise` accepts only full-chroma, non-mosaic denoisers and an amount in `0...100`.
- `superResolution` accepts the pinned PhotoUpconv7 2x model and may appear once.
- `segmentation` returns `R32Float` coverage at the final image size.
- Stages are ordered `denoise* → superResolution? → segmentation*`, at most four. Duplicate ids,
  duplicate super-resolution, unknown model ids and mosaic/RAW-domain denoisers are rejected.
- There are no prompts, candidates or patch outputs in this type. FLUX/Seedream generation stays
  in `RAWMasterAI` and must continue to produce separate proxy-resolution candidates.

`DevelopmentSceneModelProvider` is the platform adapter. The renderer runs the prefix inside the
same `prepareFinal`/`preparePreview` call and passes segmentation masks into the graph through
`externalCoverage(id:)` nodes, so a corrector can be masked by a deterministic provider result on
both the Swift and Rust executors. The test provider uses Metal kernels; production Core ML/ONNX
adapters remain explicit platform code.

## Files

- `Modules/ImageEdit/src/scene.rs`, `scene/metal_exec.rs`, `scene_ffi.rs`,
  `include/rawmaster_image_scene.h`
- `Modules/ImageEdit/Swift/RAWMasterImageKernel.swift`
- `Modules/ImageEdit/Bridge/{include/ImageEditLoader.h,ImageEditLoader.c}`
- `Sources/RAWMasterCore/DevelopmentSceneGraphV1.swift`,
  `Sources/RAWMasterCore/DevelopmentSceneModelV1.swift`
- `Sources/RAWMasterImaging/RustSceneGraphRenderer.swift`,
  `DevelopmentSceneGraphRendererV1.swift`, `DevelopmentSceneModelPipelineV1.swift`
- `Tests/RAWMasterImagingTests/RustSceneGraphRendererTests.swift`,
  `DevelopmentSceneModelPipelineV1Tests.swift`
