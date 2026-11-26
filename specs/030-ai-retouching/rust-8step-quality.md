# FLUX.3 Rust 8 步与 16 步画质研究

2026-11-26 · `030-ai-retouching` · Rust Q8 worker / seed 8521

## 范围与结论

本报告回答“8 步子集能否作为本机 FLUX.3 的速度候选”。测试使用 030 已冻结的湖面局部清理和人像补光两张输入，分别跑 Rust worker 的 8 步子集与 16 步完整 schedule，再按 030 的 Matte、干净参考和评分定义复算。

**这不是 SC-04 的通过声明。** SC-04 要求每个任务族冻结 ≥30 张留出图，并由两位独立审阅者同时接受第一张候选；本报告只有两张已归档样本，也没有人工盲审。

## 固定条件

| 项目 | 值 |
| --- | --- |
| Worker | `rawmaster-flux-rust-mlx-v1`，`mlx-rs 0.34` / MLX 0.32.2 / Metal |
| 权重 | `devin-lai/flux-3-image-klein-mlx-q8@d9790a1ceaba200e8b773fb236f7c9fa754283a7` |
| 输入 / 尺寸 | 030 `lake-input.png`、`portrait-input.png`，1024×1024 |
| 16 步 | BFL 均匀 16 步 schedule，seed 8521 |
| 8 步 | 同一 16 步 schedule 的 9 个端点/中间点：`0,2,4,6,8,10,13,15,16` |
| 评分 | 8-bit RGB code values，按 sRGB 解释；合成使用 `poc/pixels.py` 的线性光 Matte |

## 指标

- `raw_target_mae`：裸候选在目标区（湖景为牌面/立柱遮住的像素，人像为 Matte ≥128）对干净参考的 RGB MAE。
- `applied_target_mae`：按 Matte 线性光贴回后的目标区 MAE。
- `raw_exterior_any_channel_gt8_pct` / `raw_exterior_max`：Matte 完全为零的保护区中，任一通道变化超过 8 级的像素比例与最大差。
- `applied_exterior_max`：贴回后保护区最大差，必须为 0。
- `applied_boundary_mae`：Matte 边缘内外约五像素带对干净参考的 MAE。
- `step8_vs_step16`：两张裸候选或两张贴回结果之间的 PSNR / SSIM，以及目标区 MAE 的差值（8 步减 16 步）。

## 实测

| 用例 | 步数 | denoise | 全链路 | 裸候选目标 MAE | 贴回目标 MAE | 保护区 >8 级 | 保护区最大差 | 边界带 MAE |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 湖面清理 | 16 | 146.43 s | 149.81 s | 12.817 | 12.817 | 75.911% | 169 | 1.442 |
| 湖面清理 | 8 | 72.35 s | 76.51 s | 13.365 | 13.365 | 81.218% | 171 | 1.537 |
| 人像补光 | 16 | 144.48 s | 147.56 s | 12.165 | 12.947 | 37.053% | 121 | 0.599 |
| 人像补光 | 8 | 73.41 s | 76.68 s | 12.442 | 13.147 | 37.982% | 129 | 0.600 |

| 用例 | 裸候选 PSNR / SSIM（8 vs 16） | 贴回 PSNR / SSIM | 目标 MAE 差（8−16） |
| --- | --- | --- | ---: |
| 湖面清理 | 45.91 dB / 0.99761 | 61.50 dB / 0.99992 | +0.548 |
| 人像补光 | 48.92 dB / 0.99767 | 63.14 dB / 0.99992 | +0.277 |

![湖面 8 步与 16 步](rust-quality/lake-8v16.jpg)

![人像 8 步与 16 步](rust-quality/portrait-8v16.jpg)

## 判读

- **速度。** 8 步 denoise 为 72.35 / 73.41 s，16 步为 146.43 / 144.48 s，约 **2.0×**；含加载、编码、解码和 PNG 的全链路从约 148–150 s 降到约 76.5–76.7 s。峰值 MLX 内存两次都约 9.00 GiB，没有因为减步数降低。
- **目标区。** 8 步相对 16 步的目标 MAE 只高 0.55 / 0.28 个码值；人像贴回后的脸部 EV 为 −0.242，16 步为 −0.239，几乎一致。
- **整体差异。** 裸候选 PSNR 45.91 / 48.92 dB，SSIM 0.99761 / 0.99767；贴回后 PSNR 61.50 / 63.14 dB，SSIM 0.99992。裸候选最大单通道差为湖景 32、人像 30，贴回后为 10 / 14；本组没有出现早前单样本的 157 级极端差。
- **保护区。** 两者裸候选都会改动 Matte 外像素；贴回后 `applied_exterior_max` 都为 0，符合 030 的合成边界。8 步的裸候选漂移比例略高（湖景 81.2% vs 75.9%），但这不是可单独接受的依据，仍要看 100% 图。
- **100% 目检（内部单人，不替代双人盲审）。** 湖景两组都清除了牌面和立柱，8 步水纹连续，船只、乘客和山脊保持，接缝带无明显断层；8 步与 16 步的可见差异主要在水纹细节。人像两组都提亮了脸，8 步同样出现眼缘、牙齿和宇航服圆章小字的重画，没有新增物体；这是模型本身的已知边界，不是 8 步新增。8 步在脸上没有出现比 16 步更明显的结构错误。
- **结论。** 8 步是可以进入人工盲审的速度候选，但**不能直接作为默认或发布配置**。16 步继续作为默认；8 步只有在 SC-04 的 ≥30 张/任务族留出集和两位独立评审通过后，才考虑作为“速度模式”暴露。

## 复现

```sh
WORKER=Sources/RAWMasterAI/Resources/FluxWorker/flux-worker
MODEL=output/research/flux3-klein/models/q8
INPUTS=output/research/030-ai-retouching/inputs
OUT=specs/030-ai-retouching/evidence/rust-quality

for case in lake portrait; do
  "$WORKER" --full --model-root "$MODEL" --input "$INPUTS/$case-input.png" \
    --prompt-file "$OUT/$case-prompt.txt" --width 1024 --height 1024 --seed 8521 \
    --steps 8 --grid 0,2,4,6,8,10,13,15,16 \
    --out "$OUT/$case-8.png" --metrics "$OUT/$case-8.metrics.json"
  "$WORKER" --full --model-root "$MODEL" --input "$INPUTS/$case-input.png" \
    --prompt-file "$OUT/$case-prompt.txt" --width 1024 --height 1024 --seed 8521 \
    --steps 16 --out "$OUT/$case-16.png" --metrics "$OUT/$case-16.metrics.json"
done

output/research/ai-retouching-rea/spektra-venv/bin/python \
  specs/030-ai-retouching/evidence/evaluate-8v16.py \
  --inputs "$INPUTS" --evidence "$OUT" --out "$OUT"
```

## 限制

- 两张样本只覆盖单一湖面和水面纹理、单一人像和软 Matte；不能外推电线、发丝、建筑直线、文字、多人遮挡或不同肤色。
- 目标 MAE 不评价水纹是否自然，也不证明人物身份保持；必须看 100% 图并做人工盲审。
- 8 步使用 16 步 schedule 的子集，不代表重新训练的 8 步蒸馏模型。
- 本报告没有替代 SC-04；正式开放 8 步或任何“速度模式”前，仍需 30 张/任务族留出集和两位独立审阅者。
