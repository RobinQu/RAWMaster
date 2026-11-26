# FLUX.3 本机链路 Rust 化与内核性能验证（S1–S4）

2026-11-26 · Apple M4 Max / 128 GB / macOS 27.0.1 · 单张 1024² ROI、seed 8521、官方 16 步 q8-16。本文只记录本轮工程测量，不构成画质、最低机型或发布门结论。原始数据在 `output/research/flux3-native-spike/`，原型代码同目录。

## 结论

1. **当前 FLUX.3 不是 torch 推理。** 模型跑在 MLX 上；torch 只在 `noise.py` 里生成初始噪声和 schedule，实测 0.51–0.99 秒，基本被当前约 0.67 秒的文本/参考图编码遮住（最多露出约 0.3 秒），**不占关键路径**。真正可对比的是 Rust+MLX 与 Python+MLX。
2. **Rust+MLX 的固定开销收益只有约 2–3 秒（1.5–2.3%）。** 16 步 denoise 占端到端 97–99%；文本、参考图、VAE、校验、PNG 合计约 3 秒。换语言不能改变这部分 GPU 计算。本轮全链路 Rust 实现与 Python 基本持平（142.8s 对 141.8s），因为文本/VAE 还没用 `mx.compile`，实际多花约 1 秒；2–3 秒是加入缓存/去掉校验后的上限。
3. **Rust+MLX 全链路在数学上与 Python 一致：** tokenizer 的 160 个 token ID 完全相同，文本编码 cosine 0.99999999，参考 VAE 0.999982，全链路输出 PSNR 51.63 dB / SSIM 0.99996。`env -i PATH=/usr/bin:/bin` 可完整运行，不再依赖 Python。
4. **分发收益显著：** Rust 全链路是 19 MB 单二进制，另带 175 MB 预编译 MLX metallib，总计约 194 MB，只依赖系统 Metal/Accelerate/Foundation。对照 Python venv 892 MB（其中 torch 543 MB、MLX 235 MB、metallib 204 MB）。
5. **Q8 GEMM 没有明显的自研 Metal 空间，但 FP16 权重是真实的第二杠杆。** 单 block 的 in_proj Q8 GEMM 约 0.114–0.130s；反量化到 FP16 后约 0.098–0.111s。全 DiT 用 FP16 dense 权重（加载时从 Q8 反量化，下载量不变）实测暖步 7.44s、计时步 7.65/7.87/7.91s，对 Q8 的 8.37/8.78/8.90s 约快 9–11%；全链路 16 步 137.2s 对 144.3s，约快 5%。代价是峰值 physical footprint 15.3GB（Q8 10.4GB），32GB 机器风险较高。Q4 与 Q8 同速，只省内存。
6. **attention 也没有明显的自研空间。** 单 block 的 attention 约 0.071–0.079s；按 4·H·L²·D = 857 GFLOP 计算，有效算力约 10.9–13.3 TFLOPS，接近 MLX FP16 实用峰值的 75–92%。`mx.fast.scaled_dot_product_attention` 已是融合 kernel：手写 `softmax(QKᵀ)V` 为 0.181s（约 2.8× 慢），query 分块 512 为 0.074s（更慢）。因此本轮没有继续写自研 flash attention；它的理论上限也只有约 10%。
7. **8 步子集是最大的性能杠杆：** 同一用例 denoise 63.64s 对 132.0s，**2.06×**；与 16 步输出相比 PSNR 36.12 dB、全局 SSIM 0.99798、平均绝对差 1.94/255。单样本只能作为候选，仍需 030 的 ≥30 张留出集和两位评审。

## S1 · 固定成本

同一会话内 CLI 端到端 141.80s、峰值 physical footprint 9.44 GB；更早的 188s 记录是热/负载状态差异，不作为本轮 A/B 的基线。

| 阶段 | 实测 |
|---|---:|
| 16 步 denoise | 132.0s（S1）/ 135.2s（CLI metrics） |
| 文本编码 | 0.305s |
| 参考图 VAE 编码 | 0.366s |
| 噪声 + schedule（torch） | 0.507s（与编码重叠） |
| 冷校验（9.6 GB 权重） | 1.463s |
| DiT 加载 / prepare | 0.222s / 0.106s |
| VAE 解码 | 0.549s |
| PNG 写出 | 0.066s |
| 缓存后重复（denoise + decode + PNG） | 132.55s |

即使 Rust 把文本、参考图、噪声、校验、VAE、PNG 全部优化掉，理论上限也只有约 3.1s（2.3%）；现实收益更小。S1 同时确认了手工流水线与 CLI 输出**逐字节一致**（PNG SHA-256 相同），为 S3 提供了可信 fixture。

## S2 · 内核与 block 分解

首轮与热态复测差异较大（热/功耗），下表同时保留两组：

| 项目 | 首轮 | 热态复测 |
|---|---:|---:|
| 完整单步 | 8.44–8.66s | 7.61–8.26s |
| 单 block（8352 token） | 0.272s | 0.240s |
| in_proj Q8 GEMM | 0.132s | 0.114s |
| attention（1×24×8352×128） | 0.079s | 0.071s |
| attention 有效算力（857 GFLOP） | 10.9 TFLOPS | 12.1–13.3 TFLOPS |
| out_proj Q8 GEMM | 0.058s | — |
| qkv_rope + attention_mlp_pack + norm + residual | ~0.004s | ~0.004s |

关键对照：

| 配置 | in_proj 时间 | 说明 |
|---|---:|---|
| Q8 affine g64 | 0.114–0.130s | 生产配置 |
| Q8 → FP16 dense | 0.098–0.111s | 快 14–15%，但权重内存 ×2 |
| Q4 g64 | 0.116s | 与 Q8 同速，只省内存 |
| Q4 g32 / Q8 g32 / Q8 g128 | 0.115–0.116s | group size 无明显影响 |
| MLX FP16 8192³ | 14.4–14.5 TFLOPS | 实用峰值参考 |
| DiT Q8 in_proj | 10.9–12.4 TFLOPS | 约实用峰值的 75–85% |

**解释：** 该 GEMM 在 8352 token 下是计算/反量化受限，不是内存带宽受限（90 MB / 0.114s ≈ 790 MB/s，远低于统一内存带宽）。因此 Q4 不会更快；FP16 权重可换 14–15%，但会把 DiT 权重从 5.0 GB 抬到 10 GB。MLX 的 Q8 kernel 已在实用峰值附近，自研 GEMM 最多争 15–25%，不值得作为第一优先级。

attention 同样接近实用峰值：857 GFLOP / 0.071s ≈ 12.1 TFLOPS，/ 0.0645s ≈ 13.3 TFLOPS；手写 softmax 版本 0.181s，query 分块 512 为 0.074s。MLX 的 SDPA 已是融合 kernel，自研 flash attention 的理论上限约 10%，不足以抵消实现与维护风险。

## S3 · Rust+MLX 全链路（无 Python）

实现：`s3/rust-mlx`（`mlx-rs` 0.34 / MLX 0.32.2；`tokenizers` 0.22；`image` 0.25；`safetensors` 直接读取原 Q8 权重）。全链路包含 Rust tokenizer、32 层文本编码（逐层流式加载）、VAE encoder/decoder、DiT denoise、PNG 输出和 ChaCha12 RNG。用 `env -i PATH=/nonexistent` 运行 tokenizer 和文本编码成功；全链路用 `env -i PATH=/usr/bin:/bin` 运行成功；`otool -L` 只列系统 Metal/Accelerate/Foundation/libc++，无 Python/torch/ComfyUI。

### 数值一致性（fixture 噪声和 schedule，同一输入/prompt/seed）

| 阶段 | 结果 |
|---|---|
| tokenizer | 160 个 token ID 与 Python 完全相同 |
| 文本编码 | cosine 0.99999999，平均绝对差 0.00105 |
| VAE encoder | cosine 0.999982，RMSE 0.00479 |
| VAE decoder（同一 latent） | PSNR 51.13 dB，最大 8-bit 差 3 |
| 全链路输出 vs Python | **PSNR 51.63 dB，SSIM 0.99996，平均绝对差 0.42/255** |

### 全链路性能（1024²，16 步）

| 阶段 | fixture 噪声 | Rust RNG | Python CLI |
|---|---:|---:|---:|
| tokenize | 0.109s | 0.095s | ~0.09s |
| 文本编码 | 0.607s | 0.619s | 0.305s |
| 图像预处理 | 0.008s | 0.008s | ~0.01s |
| VAE encoder | 0.432s | 0.437s | 0.366s |
| DiT 加载 + prepare | 0.624s | 0.636s | 0.328s |
| denoise | 141.6s | 140.1s | 135.2s |
| VAE decoder | 0.790s | 0.789s | 0.549s |
| 总时长 | 144.3s | 142.8s | 141.8s（CLI real） |

Rust 的文本/VAE 因为未使用 `mx.compile` 和融合 group norm，比 Python 慢约 1.0–1.5s；denoise 的热波动更大，所以全链路总时长与 Python 在 1–2% 内。生产路径默认使用 `chacha12+standardnormal+bf16`；fixture 模式只用于数值对照，不是运行时依赖。无 fixture 的完整运行输出有效图像（均值/标准差 106.5/60.2，61k 种颜色）；与 Python 同 seed 的 PSNR 22 dB 是因为 RNG 不同，不是链路缺陷。

### DiT 单步速度对照

| 指标 | Rust JIT | Rust 预编译 | Python 快路径 |
|---|---:|---:|---:|
| 冷/暖首步 | 9.55s | 8.11s | — |
| 前 3 个计时步 | 8.46 / 8.81 / 9.31s | 8.37 / 8.78 / 8.90s | 8.17 / 8.26s |
| 完整 16 步中段 | 9.03–9.53s | 8.70–9.49s | 8.25s |
| 二进制 | 19 MB | 19 MB | 892 MB venv |
| 运行时 shader | 1.4 MB JIT 缓存（研究） | 175 MB 预编译 metallib（应用随包） | 204 MB metallib |

Rust 宿主没有可测量的额外开销；未启用 `mx.compile`/融合内核时，Rust 与 Python 未编译路径同为 8.4–9.4s。Python 快路径的 8.2s 来自 block 级 `mx.compile`（以及少量自定义 kernel）。预编译 metallib 的 Rust 冷/暖步可到 8.1–8.4s，持续热态 8.7–9.5s；保留图融合的 Python 仍有约 0–10% 的优势。生产 Rust 移植必须把 `mx.compile`/图融合和 fused kernels 一起移植，目标应是**持平**。

### FP16 dense 权重实验

把 DiT 的 Q8 权重在加载时反量化成 FP16 dense（下载文件不变），`--fp16-weights`：

| 指标 | Q8 | FP16 dense |
|---|---:|---:|
| 暖步 | 8.1–8.4s | **7.44s** |
| 前 3 个计时步 | 8.37 / 8.78 / 8.90s | **7.65 / 7.87 / 7.91s** |
| 全链路 16 步 | 144.3s | **137.2s** |
| 全链路 PSNR vs Python | 51.63 dB | **51.51 dB** |
| 峰值 physical footprint | 10.4 GB | **15.3 GB** |

步级约快 9–11%，全链路约快 5%；代价是峰值内存增加约 4.9GB。加载时反量化需要额外时间，但 16 步的净收益仍为正。适合 ≥64GB 机器作为“速度模式”；32GB 机器继续 Q8。8 步 + FP16 在本次热状态下为 67.5s，对 Q8 的 64.3s 在波动内；8 步的主要收益仍来自步数。

## S4 · flash attention 探索

用真实形状（1×24×8352×128，FP16）对照了三种实现：

| 实现 | 时间 | 备注 |
|---|---:|---|
| `mx.fast.scaled_dot_product_attention` | **0.0645s** | MLX 融合 kernel |
| 手写 `softmax(QKᵀ)V` | 0.1814s | 2.8× 慢 |
| query 分块 512 + SDPA | 0.0742s | 比整段慢 |

attention 的实际 FLOPs 为 \(4 \cdot H \cdot L^2 \cdot D = 857\) GFLOP；0.0645s 对应 **13.3 TFLOPS**，约为 MLX FP16 实用峰值 14.5 TFLOPS 的 92%。block 内 0.071s 对应 12.1 TFLOPS（83%）。**结论：MLX 的 SDPA 已经是接近峰值的融合 kernel，自研 flash attention 的理论上限约 10%，不值得投入。** 此前把 attention 算成 5.7 TFLOPS 是漏掉了 QKᵀ 和 PV 两个矩阵乘的系数 2；本轮已修正。

### 030 两例 8 步复核（2026-11-26）

用 030 冻结的湖面清理和人像补光输入，按同一 16 步 schedule 的 9 个端点/中间点跑 8 步，Rust worker、seed 8521：

| 用例 | 8 步全链路 | 16 步全链路 | 裸候选 PSNR / SSIM | 贴回 PSNR / SSIM | 目标 MAE 8−16 |
| --- | ---: | ---: | --- | --- | ---: |
| 湖面清理 | 76.51 s | 149.81 s | 45.91 dB / 0.99761 | 61.50 dB / 0.99992 | +0.548 |
| 人像补光 | 76.68 s | 147.56 s | 48.92 dB / 0.99767 | 63.14 dB / 0.99992 | +0.277 |

8 步约 **2.0×**，目标区 MAE 只高 0.28–0.55 码值，人像脸部 EV 为 −0.242 对 −0.239；两张都未出现早前单样本的 157 级最大差。它是可进入人工盲审的速度候选，但**不是 SC-04 通过**：只有两例、无 30 张/任务族留出集和两位独立评审，16 步仍是默认。完整指标见 [`specs/030-ai-retouching/rust-8step-quality.md`](../../specs/030-ai-retouching/rust-8step-quality.md)。


### 应用集成（2026-11-26 后续）

原型已接入正式应用代码；首次启动提示已在 M4 Max / macOS 27 上实际出现（见 `specs/034-quick-prompt-editing/evidence/first-run-native.png`）：

- `Sources/RAWMasterAI/LocalFluxProvider.swift` 改为启动 Rust worker；请求只写 `prompt/seed/width/height/weightsDirectory`，不再要求 Python 或运行时目录。
- `Sources/RAWMasterAI/FluxModelManager.swift` 读取随包的 102 文件清单，管理下载、暂停、继续、校验、删除和许可；`FluxModelManifest.json` 由 `scripts/build-flux-manifest.py` 生成。
- `Sources/RAWMaster/FluxLocalAISettings.swift` 把设置窗口的「本机 AI」改为 FLUX 模型卡和下载任务；旧的 Qwen/ComfyUI 运行时收进「实验功能」。
- 首次启动提示由 `WorkbenchView` 在首次有资料库服务且无就绪模型时展示；Quick Prompt 的本机模型设置只显示状态和「打开设置」。
- `Modules/FluxWorker` 是应用内的 Rust 源码；`scripts/build-app.sh` 在打包前构建并复制到 `RAWMasterAI` 资源包；`swift build` 的开发态可由 `Modules/FluxWorker/target/release/flux-worker` 回退。
- Rust worker 使用 `worker.lock`、cancel 文件和父进程检查，回执字段与 Swift 校验对齐；`peakMLXBytes` 使用 MLX 峰值内存。
- 应用 worker 使用预编译 MLX metallib（175 MB），由 `build-worker.sh` 从固定 MLX 构建复制到 `RAWMasterAI` 资源包；`LocalFluxProvider` 通过 `RAWMASTER_MLX_METALLIB` 指向随包文件，避免二进制里硬编码的构建机 `~/.mlx` 路径。删除本机 `~/.mlx` 预编译库后，worker 和 Swift provider 仍通过随包 metallib 跑通。
- Swift `LocalFluxProvider` → Rust worker 的 64×64、16 步 live test 已通过（约 3.1–3.6s，回执、PNG、尺寸和 RNG 身份均校验）；真实 HF 单文件下载 + SHA-256 测试通过（1.31s）。
- `Modules/FluxWorker/src/main.rs` 的 worker 模式写 PNG（不是裸 RGB），回执哈希按 PNG 字节计算；这是本轮发现并修正的实际集成缺陷。
- 下载改为 32 MiB 分块 HTTP Range 追加写入 `.part`，不再把整个文件读入内存；续传会跳过已完成文件、从当前文件断点继续、不会重复累计进度，并对网络中断做 3 次退避重试。`FluxModelManagerStateTests` 覆盖许可门、暂停/继续、Range 断点、跨管理器重开、关闭设置后无观察者仍完成、重复累计回归、网络重试、校验失败移除和首次提示。
- 完整 9.58 GiB 下载已通过：102 个文件、10,281,769,642 bytes，前两次下载分别在中途因 CDN 断连失败；第三次从 62% 续传，跳过已完成文件并在 346s 内完成逐文件 SHA-256 校验（此次为逐文件下载；本轮 Range 路径另用 130 MB 真实文件验证）。记录见 `specs/034-quick-prompt-editing/evidence/local-ai-download-validation.md`。

仍需完成正式签名/公证包、应用内真实下载进度截图和 030 的 ≥30 张/任务族留出集与双人盲审；两例 8 步机器复核见[质量研究](../../specs/030-ai-retouching/rust-8step-quality.md)，本轮没有把「已接入」或 8 步写成「已发布」。

## 8 步子集

同一输入、seed、prompt，取官方 16 步时间表的 9 个端点/中间点（`0,2,4,6,8,10,13,15,16`）：

| 指标 | 16 步 | 8 步 |
|---|---:|---:|
| denoise | 132.0s | 63.64s |
| 含 decode + PNG | 132.55s | 64.25s |
| 相对 16 步 | — | **2.06×** |
| 与 16 步输出 PSNR | — | 36.12 dB |
| 全局 SSIM | — | 0.99798 |
| 平均/最大 8-bit 绝对差 | — | 1.94 / 157 |

8 步的 36 dB 与 0.998 SSIM 说明整体结构保持得不错，但最大差 157 表示局部仍可能有明显变化。后续用 030 湖面/人像两例复跑 Rust 8 步与 16 步，PSNR 45.91/48.92 dB、SSIM 0.9976，目标 MAE 仅高 0.55/0.28；仍是**画质门候选**，不是已通过的发布配置，见[两例质量研究](../../specs/030-ai-retouching/rust-8step-quality.md)。

## 验收记录（2026-11-26）

- `swift test --skip RAWMasterImagingTests --jobs 4`：退出 0。UI 552 个（32 跳过）、Core 398 个（9 跳过）、AI 40 个（6 个 live opt-in 跳过）、Diagnostics/SequenceProbe 均 0 失败。
- `RAWMasterImagingTests` 在当前环境和干净 HEAD worktree 中都会以 signal 5 中止（`testProfileImageThumbnailProxyPressureAndLeaseCloseRetireSameAllocation` 等 thumbnail pressure 测试）；这是本机/既有测试问题，不由本轮改动引入，也未计为通过。
- live：Rust worker 64×64、16 步通过；130 MB 文件从 1 MiB 处 HTTP Range 续传通过（首响应 206，25–26s，最终 SHA-256 一致）；小文件 HTTPS 下载通过。
- `python3 scripts/check-ui-prototype.py`：38 个场景通过。
- `output/RAWMaster.app`：debug 包重建，`codesign --verify --deep --strict` 通过；包内 worker 与源文件 SHA-256 一致，175 MB `mlx.metallib` 随包，启动 smoke 通过。
- 030 画质：Rust 8 步与 16 步两例机器复核通过，PSNR 45.91/48.92 dB、SSIM 0.9976；仍不是 SC-04 通过。

## 建议

- **如果目标是分发与稳定性：** Rust+MLX 值得做。19 MB 二进制、无 Python/torch/ComfyUI、单进程树、原生取消和回执都成立；但性能目标是持平，需移植 `mx.compile` 与 fused kernels，不能把 Rust 当加速器。
- **如果目标是性能：** 8 步子集实测约 2.0×，030 两例机器指标接近 16 步，但尚未过 SC-04 人工门，只能作为候选速度模式；其次 FP16 dense 权重（步级快 9–11%，全链路快 5%，峰值内存 +4.9GB，适合 ≥64GB）；不要投入自研 Q8/Q4 GEMM 或 flash attention——两者实测都已接近 MLX 的 14.5 TFLOPS 实用峰值。
- **Linux Vulkan：** 可以后置，但 backend trait 现在就要留；MLX 是 Apple-only，Linux 需要独立 kernel 层。模型/管线/回执层可共享，不能假设 MLX 在 Linux 可用。
- **torch 对照：** 本轮没有构建 FLUX.3 的 PyTorch/MPS 图；仓库里只有 Qwen2.1 的 ComfyUI/MPS 对照，不能外推到 FLUX.3。若需要“Rust vs torch”这个口径，应另做 FLUX.3 MPS 工作流，而不是复用本轮数字。

## 限制

- 单机、单张、单 seed；热/功耗导致的步时波动可达 7.6–13.4s/step，高于本轮大部分差异。A/B 应交替、重复并记录热状态。
- Rust 全链路已覆盖 tokenizer、文本编码、VAE、DiT、PNG 和 RNG；尚未接入正式 Swift worker、安装/模型管理、回执/取消协议，也未覆盖 EXIF/ICC/16-bit 输出。
- RNG 从 torch 改为 `chacha12+standardnormal+bf16`；同 seed 不再与旧 Python 候选逐字节一致。Provider 回执需要记录新的 RNG 身份，已归档候选保持不变。
- `mlx-rs` 0.34 对应 MLX 0.32.2，Python 环境是 0.32.4；未逐算子核对版本差异。
- JIT 与预编译 metallib 的冷启动、内存和体积不同；本轮已分别记录，但尚未做连续多任务的热稳定性测试。
- flash attention 只做了测量评估（SDPA / 手写 softmax / query 分块），没有写自研 MSL kernel；结论基于 MLX 0.32.2 的 SDPA 实现。
- 8 步的 36.12 dB / 0.998 SSIM 不能替代摄影质量评审；任何发布配置仍需按 030 的留出集与两位评审验收。

## 证据与代码

- S1 流水线与 fixture：`output/research/flux3-native-spike/s1/bench_pipeline.py`、`results/s1-roi/s1-cached.json`
- S2 block 分解：`output/research/flux3-native-spike/s2/profile_block.py`、`results/s2-block.json`、`results/s2-block-after.json`
- Python 关闭 `mx.compile` 对照：`output/research/flux3-native-spike/s2/measure_uncompiled.py`、`results/s2-uncompiled.json`
- Rust+MLX 全链路：`output/research/flux3-native-spike/s3/rust-mlx/`、`results/full-rust.metrics.json`、`results/full-rust-rng.metrics.json`
- 全链路数值对照：`results/tokens-rust.json`、`results/text-rust.npy`、`results/vae-rust/reference-rust.npy`、`results/vae-rust/vae-decoded.png`、`results/full-rust-vs-python.jpg`
- DiT 单步对照：`results/s3-rust-perf.json`、`results/s3-rust-full.json`、`results/s3-rust-precompiled.json`、`results/s3-rust-precompiled-full.json`
- FP16 dense 权重：`results/s3-rust-fp16-eval.json`、`results/full-rust-fp16.metrics.json`、`results/full-rust-fp16.png`、`results/full-rust-8step-fp16.metrics.json`
- flash attention 对照：`output/research/flux3-native-spike/s4/attention_bench.py`、`results/s4-attention.json`
- 8 步：`results/s1-8step/s1-cached.json`、`results/8step-vs-16step.jpg`
- 基线：`results/baseline-roi-1.log`、`results/baseline-roi-1.metrics.json`
