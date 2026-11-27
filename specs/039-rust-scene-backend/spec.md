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
| P2 | One submit per render, bounded tiles for 60MP masters, transient surface pool, source-revision-keyed intermediate cache, analytic coverage cache, shared surface budget, completion receipts |
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
- **Tiling:** `DevelopmentSceneGraphRendererV1` asks for bounded tiles when five full-resolution
  intermediates would not fit the remaining budget. The Rust executor crops the source and
  provider masks into each tile, evaluates the same DAG with tile-global coverage coordinates,
  and blits each result back into the full master. All tiles stay in one command buffer, so the
  caller still waits once. A 60MP graph uses six 4096-wide tiles on the current budget.
- **Node cache:** every reachable node gets a content key over the source revision, node id,
  operation parameters, surface size, frame geometry and dependency keys. With a non-zero
  source revision, unchanged image prefixes survive a parameter edit because the Swift owner
  reuses the compiled program and updates its graph in place. A cache hit prunes the ancestor
  nodes for that frame. Provider coverage keys include the mask texture identity; analytic
  coverage is keyed without the source and survives source revisions.
- A surface pool recycles retired intermediates. Cached textures stay charged to the budget until
  evicted, so the peak receipt includes them.
- The input, live intermediates, pool and caches share the caller's surface budget. A strict Rust
  over-budget frame returns `surfaceBudget`; auto mode lets the Swift executor decide whether its
  zero-allocation path can satisfy the frame.
- **Completion receipt:** `RMSceneReceiptV1` reports backend, tiles, evaluated nodes, dispatches,
  coverage/node cache hits, peak bytes, budget and CPU time. `DevelopmentSceneGraphRendererV1`
  exposes the last receipt, including `swiftFallback` with the Rust failure reason.

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
both the Swift and Rust executors.

`DevelopmentSceneProductionModelProvider` is the shipping adapter:

- **Denoise:** the bundled PhotoVGG7 full-chroma network, invoked without a source URL or RAW
  capability check. AP1 is converted to linear Rec.709, display-encoded for the network, composed,
  rendered back to a texture and converted to AP1.
- **Super-resolution:** the bundled PhotoUpconv7 Core ML package on the same linear Rec.709
  domain; the returned image is twice the input size and is converted back to AP1.
- **Segmentation:** Vision foreground instances for `.subject`, Vision person segmentation for
  `.people`, and the verified EfficientViT landscape pack for `.landscape`. Masks are scaled to
  the full scene surface as `R32Float`.
- **Recipe wiring:** `DevelopmentSceneModelProgramV1.derived(from:)` maps scene-compatible legacy
  denoise and super-resolution settings; `DevelopmentScenePreviewV1.render` accepts the program and
  installs the production provider beside the graph renderer. RAW-domain/mosaic denoisers and
  generative candidates are not inferred.

The deterministic test provider remains for contract tests. The production provider is exercised
on a real photographic PNG through denoise, 2x super-resolution, Vision segmentation, the
`externalCoverage` graph port and ACES HDR delivery.

## Files

- `Modules/ImageEdit/src/scene.rs`, `scene/metal_exec.rs`, `scene_ffi.rs`,
  `include/rawmaster_image_scene.h`
- `Modules/ImageEdit/Swift/RAWMasterImageKernel.swift`
- `Modules/ImageEdit/Bridge/{include/ImageEditLoader.h,ImageEditLoader.c}`
- `Sources/RAWMasterCore/DevelopmentSceneGraphV1.swift`,
  `Sources/RAWMasterCore/DevelopmentSceneModelV1.swift`
- `Sources/RAWMasterImaging/RustSceneGraphRenderer.swift`,
  `DevelopmentSceneGraphRendererV1.swift`, `DevelopmentSceneModelPipelineV1.swift`,
  `DevelopmentSceneProductionModelProvider.swift`, `DevelopmentSceneExecutionReceiptV1.swift`
- `Tests/RAWMasterImagingTests/RustSceneGraphRendererTests.swift`,
  `DevelopmentSceneModelPipelineV1Tests.swift`
