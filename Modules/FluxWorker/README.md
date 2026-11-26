# RAWMaster FLUX worker

Native Rust implementation of the FLUX.3 Image Klein edit pipeline. It uses
`mlx-rs` for Metal execution, a Rust tokenizer, the real Q8 safetensors, a
native VAE and a Rust RNG. Python, torch and ComfyUI are not required.

## Build

```sh
Modules/FluxWorker/build-worker.sh \
  "$PWD/Modules/FluxWorker" \
  "$PWD/Modules/FluxWorker/target" \
  "$PWD/Sources/RAWMasterAI/Resources/FluxWorker/flux-worker"
```

`scripts/build-app.sh` runs this before `swift build`; the binary and its
precompiled `mlx.metallib` are copied into the `RAWMasterAI` resource bundle.
The app passes the bundled metallib path as `RAWMASTER_MLX_METALLIB` so the
worker never depends on the build machine's `~/.mlx` directory. Development
builds may instead use `Modules/FluxWorker/target/release/flux-worker`, or set
`RAWMASTER_FLUX_WORKER=/absolute/path/to/flux-worker`.

## Worker protocol

The app starts the binary with `--worker` and the current directory set to a
scratch attempt directory. The worker:

- reads `request.json` (`prompt`, `seed`, `width`, `height`,
  `weightsDirectory`) and `input.png`;
- holds `worker.lock` with an exclusive flock;
- polls the sibling `<attempt>.cancel` file and the parent process;
- writes `candidate.png` and `worker-receipt.json` on success;
- exits 130 when the cancel file appears or the parent exits, and 64/other
  nonzero on model or runtime failure.

The receipt records the fixed model/weights/runtime revisions, `mlxVersion`,
RNG identity, steps, seed, timings, peak MLX bytes and output SHA-256.
