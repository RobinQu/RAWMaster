# RAWMaster Server PoC · 040／041 backbone

This is an isolated PoC, not production code. It validates the parts of the Server design that can be tested before the Linux/Vulkan scene executor exists:

1. **Scene contract** — parse and validate the 038 `DevelopmentSceneGraphV1` JSON shape (bounded nodes, layers, cycles, ports, coverage, parameters). It does not render pixels.
2. **Job queue contract** — idempotent submission, lane priority, claim/lease, stage/publish exactly once, cancel, retry, reconcile, scene batch/head identity.
3. **Receipt shape** — the same fields the production scene worker must record: backend, tiles, nodes, dispatches, coverage cache hits, peak/budget bytes, CPU time.

## Run

From this directory:

```sh
cargo test
cargo run -- scene fixtures/scene-basic.json
cargo run -- queue
```

No network, database, GPU or S3 is required. The PoC uses only `serde` and `serde_json`.

## What this proves

- The contract is small enough to freeze independently of the UI and the Metal executor.
- Queue semantics can be tested before PostgreSQL/gRPC exist.
- Scene batch identity (`batch_id`, `target_head`, scene/output/model hashes, compatibility route, target/format) can survive submission, claim, publish and retry.
- Idempotency and single publication can be regression-tested without a server process.

## What this does not prove

- Linux/Vulkan scene execution, tiling, prefix cache, ACES output, HDR AVIF encoding.
- Real 60MP RAW decode or performance.
- `SceneWorkflowBatch` integration, `sceneProxy`, S3, PostgreSQL, gRPC, authentication.
- The production queue's fairness, GPU admission or crash recovery.

Those are the next PoC slices. In particular, P1 must use a real 60MP RAW and compare against the macOS Rust/Metal and Swift references; this crate deliberately does not substitute a synthetic image.

## Next

1. Add a CPU/Vulkan scene execution harness behind a feature flag, reusing this scene contract.
2. Add a real 60MP RAW fixture descriptor and decode path.
3. Add a fake S3/PostgreSQL adapter and gRPC contract once the queue semantics are accepted.
4. Extend the client side with `SceneWorkflowBatch` remote mapping; do not create a second batch model.
