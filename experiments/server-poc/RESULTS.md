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
