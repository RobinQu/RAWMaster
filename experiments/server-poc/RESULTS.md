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
