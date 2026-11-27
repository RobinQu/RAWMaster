# Server PoC · first result

2026-11-27 · isolated PoC, not production.

## Environment

- Docker `rust:1.85` on Linux x86_64.
- Host GPU: NVIDIA RTX 6000 Ada, 49 GB; no Vulkan tooling was used in this slice.
- No Swift, PostgreSQL or S3 dependency.

## Commands

```sh
docker run --rm -e CARGO_TARGET_DIR=/tmp/server-poc-target \
  -v "$PWD":/work -w /work rust:1.85 cargo test
```

## Result

```text
running 10 tests
test queue::tests::scene_batch_identity_survives ... ok
test queue::tests::cancel_then_retry ... ok
test queue::tests::idempotent_submission_and_conflict ... ok
test queue::tests::publish_once_and_stale_token_rejected ... ok
test queue::tests::library_lane_wins ... ok
test scene::tests::accepts_minimal_graph ... ok
test scene::tests::rejects_disconnected_node ... ok
test scene::tests::rejects_cycle ... ok
test scene::tests::parses_group_and_coverage_fixture ... ok
test scene::tests::parses_json_fixture ... ok

test result: ok. 10 passed; 0 failed
```

CLI:

```json
{"output":"mix","receipt":{"backend":"cpu-contract-poc","budgetBytes":0,"coverageNodes":0,"cpuMs":1.0120660000000001,"dispatches":3,"nodes":3,"peakBytes":0,"tiles":1},"schemaVersion":1}
{"pending":1,"submit":"created"}
```

## What this result means

- The 038 scene JSON can be parsed and bounded by a headless Rust host.
- Queue idempotency, lane priority, lease/stage/publish, stale token rejection, cancel/retry and scene-batch identity can be regression-tested without PostgreSQL or gRPC.
- This is a contract/state-machine result only.

## Not covered

- Linux/Vulkan scene execution, tiling, prefix cache, ACES output, HDR AVIF.
- Real 60MP RAW decode and performance.
- S3/RustFS, PostgreSQL, gRPC, authentication.
- `SceneWorkflowBatch` remote mapping and `sceneProxy`.
- Model prefix Linux provider and Flux.

## Next slice

P1 should add a feature-gated headless Vulkan scene harness on this contract, then run a real 60MP RAW against the macOS reference. It must not substitute the synthetic 60MP graph or this CPU-only contract test.

---

# P1/P2 · real 60MP RAW result

2026-11-27 · additional isolated results. The P0 contract/queue result above is unchanged.

## P1 · Linux/Vulkan scene graph

- Source: `DSC00413.ARW`, Sony A7R V, 9504 × 6336, SHA-256
  `38e48a6e71bd741e1c0b9c5f28dc55347c5aa8d69da5a29dea90bc347c3e4140`.
- macOS reference: M4 Max, Rust scene executor on Metal, 20 tiles at 2048 px, 6 GiB budget.
- Linux: wgpu 24 on Mesa llvmpipe 22.3.6 (Vulkan software device), 20 tiles, 16 GiB budget.
- Real AP1 RGBA32F comparison: 240,869,376 channel samples; max absolute error
  **9.54e-7**, max relative **5.26e-7**, mean **6.93e-9**, zero samples over 1e-5.
- Linux cache sequence: warm 80 node + 80 coverage hits / 0 dispatches; edited group
  80/80 hits and 20 dispatches (one per tile); new source 80 coverage hits, 0 node hits,
  120 dispatches.
- NVIDIA Vulkan is blocked on this host: the 610.43.02 ICD returns `NULL` from
  `vk_icdGetInstanceProcAddr` for `vkCreateInstance`; the GPU is also 95% occupied by a
  long-running sglang process. No hardware performance claim is made.

## P2 · ACES 2 and HDR AVIF

- Linux OpenColorIO 2.5.0 fixed ACES 2 prefix vs macOS Metal delivery on the full 60MP frame:
  HDR max abs **7.63e-6**, SDR max abs **3.46e-6**; zero samples over 1e-5.
- Same PQ16 frame encoded with libavif 1.0.4, q95, speed 8, 32 jobs:

| Encoder | YUV | Bytes | Encode | Peak RSS | PSNR | Compatibility |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| AOM | 420 | 26,164,226 | 4.38 s | 1.34 GB | 41.75 dB | FFmpeg + avifdec; CICP correct |
| SVT-AV1 | 420 | 32,029,707 | 14.74 s | 19.71 GB | 42.02 dB | FFmpeg sees limited range/no color tags |
| rav1e | 420 | 29,648,964 | 25.76 s | 2.11 GB | 41.89 dB | FFmpeg + avifdec; CICP correct |
| macOS ImageIO | 420 | 26,538,691 | 1.33 s | — | 41.69 dB | avifdec only; FFmpeg/libdav1d parse failure |
| AOM | 444 | 42,797,003 | 5.55 s | 2.29 GB | 51.93 dB | FFmpeg + avifdec; High profile |
| rav1e | 444 | 46,778,269 | 45.06 s | 3.62 GB | 52.56 dB | FFmpeg + avifdec; High profile |
| SVT-AV1 | 444 | — | — | — | — | unsupported |

Recommendation: AOM 10-bit 4:2:0 is the current HDR AVIF baseline; 4:4:4 is a
quality option; SVT-AV1 needs a color-signaling/4:4:4 fix before 8K HDR delivery;
macOS ImageIO output needs independent container compatibility evidence.

Full receipts and gate status: [041 validation](../../specs/041-server-image-editing/validation.md).

## P1b · NVIDIA VRAM / concurrency (CUDA fallback)

After the resident sglang server was stopped, the RTX 6000 Ada had 48,537 MiB free, but the
NVIDIA Vulkan ICD still returned `VK_ERROR_INCOMPATIBLE_DRIVER` (-3) for ICD interface
versions 1–8. CUDA was therefore used to measure the same 9-node, tiled 60MP graph; it matches
the macOS AP1 master to max abs 7.15e-7. This is a VRAM measurement, not the Vulkan gate.

| Scenario | Per job | Max concurrent | Used at max |
| --- | ---: | ---: | ---: |
| Scene, tile 1024 | 1.95 GiB | 24 | 46.2 GiB |
| Scene, tile 2048 | 2.29 GiB | 21 | 47.3 GiB |
| Scene, tile 4096 | 3.63 GiB | 13 | 46.5 GiB |
| Full decode+scene+display, tile 1024 | 4.30 GiB | 11 | 46.7 GiB |
| Full, tile 2048 | 4.64 GiB | 10 | 45.8 GiB |
| Full, tile 2048, 2 GiB cache/job | 6.69 GiB | 7 | 46.2 GiB |
| Full, tile 2048, 4 GiB cache/job | 8.74 GiB | 5 | 43.1 GiB |

At 21 scene jobs the GPU used 48,485 MiB of 49,140 MiB; the 22nd allocation failed. Aggregate
scene throughput saturated around 45 jobs/s while per-job latency rose from 20 ms to 462 ms.
Production admission should reserve headroom (scene 18–20, full 8–9) and avoid 2–4 GiB
per-job caches. Full stage includes decode surfaces, HDR/SDR and PQ, but not a GPU AV1 encoder
or model-prefix stages. Raw receipts: `specs/041-server-image-editing/evidence/cuda-vram/`.

---

# P1c · NVIDIA hardware Vulkan with the EGL ICD

2026-11-27 · follow-up after the root cause was found. The earlier CUDA section remains the
strict-admission model; this section is the hardware Vulkan functional/pixel/cache result.

## Root cause

- Packaged `/usr/share/vulkan/icd.d/nvidia_icd.json` points to `libGLX_nvidia.so.0`.
- Its Vulkan initialization calls `XOpenDisplay(NULL)`; headless returns
  `VK_ERROR_INCOMPATIBLE_DRIVER` (-3) for ICD interface versions 1–8.
- `libEGL_nvidia.so.0` exports the same ICD interface and negotiates Vulkan 1.4.341 headless.
- `libegl1`/Xvfb do not fix the GLX path; `libnvidia-vksc-core` is Vulkan SC.
- Containers need `NVIDIA_DRIVER_CAPABILITIES=graphics,compute,utility`.

## Fix used

`tools/nvidia_egl_icd.json` + `VK_DRIVER_FILES`; probe with `tools/check_vulkan_egl.sh`.
The packaged ICD was not edited.

## Hardware Vulkan 60MP results

- `vulkaninfo`: RTX 6000 Ada, API 1.4.341, driver 610.43.02.
- Pixel parity vs macOS Rust/Metal: 240,869,376 channel samples, max abs **7.1525574e-7**,
  >1e-5 **0**, non-finite 0. All cache/tile configs produced the same output SHA-256.
- tile 2048, cache 0: 2,424 MiB actual peak, warm 426.6 ms.
- tile 2048, cache 12 GiB: 12,560 MiB actual peak, warm **33.2 ms**, 80/80 node and coverage hits,
  0 dispatches; edited group 75.0 ms / 20 dispatches; new source 294.6 ms / 120 dispatches.
- tile 1024/4096 cache 0: 2,040/3,960 MiB actual peak; warm 443.9/398.2 ms.
- 4 GiB cache is too small for the 60MP full-frame prefix (0 hits); 12 GiB is the useful scale.

## Concurrency

N independent single-pass scene jobs, tile 2048, cache 0, with a barrier after input/output
allocation:

| N | barrier | high-water | completed |
| ---: | ---: | ---: | ---: |
| 1 | 1,912 MiB | 2,424 MiB | 1 |
| 4 | 7,623 MiB | 9,671 MiB | 4 |
| 8 | 15,242 MiB | 19,340 MiB | 8 |
| 16 | 30,481 MiB | 38,678 MiB | 16 |
| 20 | 38,103 MiB | 48,347 MiB | 20 |
| 21 | 40,006 MiB | 48,532 MiB | 21 |
| 22 | 41,911 MiB | 48,525 MiB | 22 |
| 26 | 47,677 MiB | 48,538 MiB | 26 |

Vulkan can schedule 26 single-pass jobs at a 48.5 GiB high-water, but this is not a safe
resident-admission limit. CUDA strict allocation OOMs at 22 scene jobs (max 21). Use scene
18–20 / full 8–9 for production planning and reserve headroom.

Full receipts: [041 validation](../../specs/041-server-image-editing/validation.md) ·
[hardware Vulkan evidence](../../specs/041-server-image-editing/evidence/p1-vulkan-nvidia-egl-60mp.json).
