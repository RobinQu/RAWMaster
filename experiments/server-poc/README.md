# RAWMaster Server PoC · 040／041 backbone

This is an isolated PoC, not production code. It validates the Server control/job contracts and the first Linux/Vulkan scene-graph slice before the production executor exists.

1. **Scene contract** — parse and validate the 038 `DevelopmentSceneGraphV1` JSON shape (bounded nodes, layers, cycles, ports, coverage, parameters). The default build does not render pixels.
2. **Job queue contract** — idempotent submission, lane priority, claim/lease, stage/publish exactly once, cancel, retry, reconcile, scene batch/head identity.
3. **Vulkan scene harness (P1)** — feature-gated wgpu 24 executor that evaluates the same graph in bounded tiles, keeps an analytic-coverage and node prefix cache, and emits the 039 receipt fields.
4. **ACES 2 / AVIF tools (P2)** — an OpenColorIO 2.5.0 CPU reference for the fixed ACES 2 view prefix, PQ16 export, and a libavif bake-off harness.

## Run

Default contract and queue tests (no GPU, network or database):

```sh
cargo test
cargo run -- scene fixtures/scene-basic.json
cargo run -- queue
```

Vulkan scene harness (requires a Vulkan loader/ICD in the container or host):

```sh
cargo build --release --features vulkan --bin scene-vulkan
scene-vulkan --input scene-input.f32 \
  --graph fixtures/scene-60mp-v1.json --graph-v2 fixtures/scene-60mp-v2.json \
  --reference scene-output.f32 --output scene-output-linux.f32 \
  --report report.json --width 9504 --height 6336 --tile-edge 2048 \
  --budget-bytes 17179869184 --cache-bytes 12884901888
```

`scene-input.f32` / `scene-output.f32` are RGBA32F AP1 dumps produced by the macOS
`DevelopmentScenePOCDiagnostics` PoC helper in `macos/`. The Linux harness compares every
channel against the reference and reports max/mean error, plus cold/warm/edited/new-source
receipts.

## What this proves

- The contract is small enough to freeze independently of the UI and the Metal executor.
- Queue semantics can be tested before PostgreSQL/gRPC exist.
- Scene batch identity (`batch_id`, `target_head`, scene/output/model hashes, compatibility route, target/format) can survive submission, claim, publish and retry.
- On a real 60MP RAW, the WGSL port matches the macOS Rust/Metal AP1 master within 1e-6 (max absolute error 9.54e-7).
- Tiling, analytic-coverage caching, node prefix caching and receipts can be exercised on the same graph.
- Linux OpenColorIO ACES 2 SDR/HDR matches the macOS Metal delivery prefix on the same 60MP master.
- libavif/AOM, SVT-AV1 and rav1e can be compared on the same PQ16 frame with container and bitstream receipts.
- The CUDA fallback shows the 60MP scene graph fits 21 concurrent jobs at 2.29 GiB/job, and the full decode+scene+display model fits 10 jobs at 4.64 GiB/job on a 49,140 MiB RTX 6000 Ada.

See [validation.md](../../specs/041-server-image-editing/validation.md) for the P0–P2 evidence and gate status.

## What this does not prove

- NVIDIA hardware Vulkan performance: the RTX 6000 Ada ICD returns `VK_ERROR_INCOMPATIBLE_DRIVER` even with the GPU idle; the P1 run used Mesa llvmpipe. CUDA was used only for VRAM/concurrency measurement.
- Linux RAW decode parity (the 60MP AP1 input was decoded on macOS and transferred).
- Production scene executor, S3/PostgreSQL/gRPC, authentication, queue crash recovery or fairness.
- `SceneWorkflowBatch` integration, `sceneProxy`, model prefix on Linux, or Flux.
- A production HDR AVIF encoder choice. AOM is the current recommendation, but the bake-off ran on host CPU and still needs a hardware/player matrix.

## Layout

- `src/scene.rs` — 038 JSON contract and validator.
- `src/queue.rs` — in-memory job queue state machine.
- `src/scene_vulkan.wgsl` — WGSL color/coverage kernels.
- `src/bin/scene_vulkan.rs` — tiled wgpu/Vulkan executor and comparison harness.
- `macos/` — PoC-only Swift diagnostic source used in the isolated macOS worktree; not wired into production.
- `cuda/` — CUDA fallback that measures the same 60MP tiled graph's VRAM and concurrency; not the production Vulkan backend.
- `tools/aces2.py` — fixed OCIO ACES 2 prefix, PQ16 export, macOS reference comparison.
- `tools/avif_bakeoff.sh`, `tools/avif_metrics.py` — libavif encoder matrix and quality receipts.
- `tools/vk_icd_probe.c` — direct ICD negotiation probe used to document the NVIDIA Vulkan block.
- `fixtures/scene-60mp-v1.json`, `fixtures/scene-60mp-v2.json` — 9-node graph used for P1/P2.

## Next

1. Re-run the same 60MP graph on NVIDIA Vulkan after the ICD/driver and GPU occupancy are fixed; do not use llvmpipe timings as the hardware gate.
2. Add Linux RAW decode and compare its AP1 input with the macOS decode separately from executor parity.
3. Add a fake S3/PostgreSQL adapter and gRPC contract once the queue semantics are accepted.
4. Extend the client side with `SceneWorkflowBatch` remote mapping; do not create a second batch model.
