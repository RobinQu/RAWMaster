# CUDA VRAM / concurrency probe (P1 fallback)

This probe exists because the NVIDIA Vulkan ICD on the validation host returns
`VK_ERROR_INCOMPATIBLE_DRIVER` for ICD interface versions 1–8, even after the GPU was freed.
CUDA is the only working GPU API on that host. The probe measures the **same tiled 9-node
scene graph** and the same 60MP AP1 input through CUDA, so the surface count and VRAM demand are
representative; it is **not** the production Vulkan backend and does not close the Vulkan gate.

## Build

```sh
docker run --rm \
  -v "$PWD":/work:ro -v /tmp/scene-cuda:/out \
  nvidia/cuda:12.6.3-devel-ubuntu24.04 \
  nvcc -O3 -std=c++17 -arch=sm_89 /work/scene_bench.cu -o /out/scene-bench
```

## Run

```sh
docker run --rm --gpus all \
  -v /tmp/scene-cuda:/opt/bench:ro \
  -v /path/to/poc-data:/data:ro \
  nvidia/cuda:12.6.3-devel-ubuntu24.04 \
  /opt/bench/scene-bench \
    --input /data/scene-input.f32 \
    --reference /data/scene-output.f32 \
    --width 9504 --height 6336 --tile 2048 --jobs 1
```

`--full` adds the RAW decode and HDR/SDR delivery allocation model. `--cache-mb N` reserves a
per-job cache budget. `--jobs N` allocates N independent input/output/workspace sets before
running them on N CUDA streams; if allocation fails, the JSON reports `success:false` and
`allocatedJobs`.

## What the numbers mean

- `logicalMB` is the exact sum of this probe's `cudaMalloc` surfaces.
- `usedMB` is `total - free` after allocation, including the CUDA context (~435 MiB).
- `perJobLogicalMB` is the per-job VRAM baseline, excluding the shared context.
- `jobMs` is per-job stream time; `wallMs` is the concurrent wall time. At saturation, per-job
  latency rises while aggregate throughput stays roughly constant.
- Scene stage: input/output AP1 + tile input + 5 tile image surfaces + 4 tile coverage surfaces.
- For planning: `S = W*H*16 bytes`; scene ≈ `2S + 112*tile² bytes`; full ≈ `4.5625S + 112*tile² bytes`; add the configured cache per job. At 60MP/tile 2048 this gives 2.29 GiB scene and 4.64 GiB full.
- Full stage: scene stage + RAW mosaic U16 + saturation R8 + HDR display + SDR display + PQ16.
  It does **not** include a GPU AV1 encoder or model-prefix stages. CPU AVIF encoders use host
  RAM (AOM 1.34 GiB, SVT-AV1 19.71 GiB, rav1e 2.11 GiB in the P2 bake-off), not VRAM.

## Result snapshot (RTX 6000 Ada, 49,140 MiB)

| Scenario | Per job | Max concurrent | Used at max |
| --- | ---: | ---: | ---: |
| Scene, tile 1024 | 1.95 GiB | 24 | 46.2 GiB |
| Scene, tile 2048 | 2.29 GiB | 21 | 47.3 GiB |
| Scene, tile 4096 | 3.63 GiB | 13 | 46.5 GiB |
| Full, tile 1024 | 4.30 GiB | 11 | 46.7 GiB |
| Full, tile 2048 | 4.64 GiB | 10 | 45.8 GiB |
| Full, tile 2048, 2 GiB cache/job | 6.69 GiB | 7 | 46.2 GiB |
| Full, tile 2048, 4 GiB cache/job | 8.74 GiB | 5 | 43.1 GiB |

Use headroom below the exact maximum: 21 scene jobs used 48,485 MiB of 49,140 MiB, and the 22nd
allocation failed. Production admission must reserve driver/context, fragmentation and telemetry
space. See `specs/041-server-image-editing/evidence/p1-cuda-vram-concurrency-60mp.json` for every
row and the raw receipts in `evidence/cuda-vram/`.

## Caveats

- CUDA fallback, not Vulkan.
- The full stage is an allocation model, not an end-to-end decode + AVIF measurement.
- The 60MP input is a macOS-decoded AP1 dump; Linux RAW decode is a separate gate.
- A GPU AV1 encoder, model-prefix workers, or a shared multi-job cache change the VRAM budget.
