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
VK_DRIVER_FILES="$PWD/tools/nvidia_egl_icd.json" \
  scene-vulkan --input scene-input.f32 \
  --graph fixtures/scene-60mp-v1.json --graph-v2 fixtures/scene-60mp-v2.json \
  --reference scene-output.f32 --output scene-output-linux.f32 \
  --report report.json --width 9504 --height 6336 --tile-edge 2048 \
  --budget-bytes 17179869184 --cache-bytes 12884901888
```

On headless NVIDIA hosts, use the EGL ICD, not the packaged GLX ICD:

```sh
VK_DRIVER_FILES=/opt/vulkan/nvidia_egl_icd.json
NVIDIA_DRIVER_CAPABILITIES=graphics,compute,utility
./tools/check_vulkan_egl.sh
```

The packaged `nvidia_icd.json` points at `libGLX_nvidia.so.0`, which calls
`XOpenDisplay(NULL)` and returns `VK_ERROR_INCOMPATIBLE_DRIVER` without X. The EGL library
exports the same ICD interface and works headless. See
[validation](../../specs/041-server-image-editing/validation.md).

Optional harness flags: `--single-pass` runs only the cold pass (used by the concurrency matrix);
`--hold-file <path>` waits after input/output allocation until the barrier file exists, so N
processes can be measured while resident.

`scene-input.f32` / `scene-output.f32` are RGBA32F AP1 dumps produced by the macOS
`DevelopmentScenePOCDiagnostics` PoC helper in `macos/`. The Linux harness compares every
channel against the reference and reports max/mean error, plus cold/warm/edited/new-source
receipts.

## What this proves

- The contract is small enough to freeze independently of the UI and the Metal executor.
- Queue semantics can be tested before PostgreSQL/gRPC exist.
- Scene batch identity (`batch_id`, `target_head`, scene/output/model hashes, compatibility route, target/format) can survive submission, claim, publish and retry.
- On a real 60MP RAW, the WGSL port matches the macOS Rust/Metal AP1 master within 1e-6: llvmpipe max 9.54e-7, NVIDIA Vulkan max 7.15e-7.
- Tiling, analytic-coverage caching, node prefix caching and receipts can be exercised on the same graph.
- Headless NVIDIA Vulkan works with the EGL ICD: 60MP warm render 33 ms with a 12 GiB cache, 80/80 node and coverage hits.
- 26 single-pass 60MP Vulkan processes complete at a 48.5 GiB high-water; strict CUDA allocation admits 21 scene jobs. Production admission should use the strict bound.
- Linux OpenColorIO ACES 2 SDR/HDR matches the macOS Metal delivery prefix on the same 60MP master.
- libavif/AOM, SVT-AV1 and rav1e can be compared on the same PQ16 frame with container and bitstream receipts.
- The CUDA fallback shows the 60MP scene graph fits 21 concurrent jobs at 2.29 GiB/job, and the full decode+scene+display model fits 10 jobs at 4.64 GiB/job on a 49,140 MiB RTX 6000 Ada.

See [validation.md](../../specs/041-server-image-editing/validation.md) for the P0–P2 evidence and gate status.

## What this does not prove

- Production NVIDIA Vulkan executor performance: the PoC harness is not the production scheduler; its per-tile submit/wait overhead is visible. The functional, pixel and cache gates pass on hardware Vulkan.
- Production deployment has not yet frozen the EGL ICD config or startup capability probe.
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
- `tools/vk_icd_probe.c` — direct ICD negotiation probe used to document the original GLX ICD failure.
- `tools/nvidia_egl_icd.json`, `tools/check_vulkan_egl.sh` — headless NVIDIA Vulkan ICD override and probe.
- `fixtures/scene-60mp-v1.json`, `fixtures/scene-60mp-v2.json` — 9-node graph used for P1/P2.

## Next

1. Integrate the production Linux scene executor/worker with the EGL ICD deployment and startup capability probe; do not use the PoC harness as the production scheduler.
2. Add Linux RAW decode and compare its AP1 input with the macOS decode separately from executor parity.
3. Add a fake S3/PostgreSQL adapter and gRPC contract once the queue semantics are accepted.
4. Extend the client side with `SceneWorkflowBatch` remote mapping; do not create a second batch model.
