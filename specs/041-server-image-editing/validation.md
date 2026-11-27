# 041 · 规划验证记录

2026-11-27 · 本轮为编辑云端与队列设计，不是产品验收。

> **2026-11-27 更新：** P0–P2 PoC 已执行，结果见第 3 节。生产实现、NVIDIA 硬件 Vulkan 和发布门仍未完成；第 2、4、5 节的未完成项仍然有效。

## 1. 已完成

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 阅读点配方图、scene executor、C ABI、后端 feature | 完成 | [ImageEdit/src](../../Modules/ImageEdit/src) · [039 spec](../039-rust-scene-backend/spec.md) · [Cargo.toml](../../Modules/ImageEdit/Cargo.toml) |
| 阅读 035 跨端重放、037 色彩／HDR、038 DAG、039 scene backend | 完成 | [035](../035-portable-processing-cores/spec.md) · [037](../037-color-film-hdr/spec.md) · [038](../038-node-dag-workflow/spec.md) · [039](../039-rust-scene-backend/spec.md) |
| 阅读 028 本地交互、024 代理边界 | 完成 | [028](../028-filter-experience/spec.md) · [024](../024-jpeg-display-proxy/plan.md) |
| 阅读 CatalogTaskQueue、SceneWorkflowBatch、ProcessingJob | 完成 | [CatalogTaskQueue.swift](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift) · [SceneWorkflowBatch.swift](../../Sources/RAWMasterCore/SceneWorkflowBatch.swift) · [SceneWorkflowBatchView.swift](../../Sources/RAWMaster/SceneWorkflowBatchView.swift) |
| 确认编辑云端边界：无 Server 交互，仅代理／批处理／生成式 | 完成 | [spec](spec.md) |
| 设计客户端队列（复用 SceneWorkflowBatch）、Server 队列、协同 | 完成 | [queues](queues.md) |
| 设计 sceneProxy、Vulkan／scene 能力、CUDA 生成式、能力清单 | 完成 | [plan](plan.md) |
| 相对链接检查 | 完成 | 本目录及 040／035／037／038／039／024 入口；断链为零 |

## 2. 未完成

- **没有实现。** 没有客户端队列、Server 队列、图像 worker、生成式 worker、代理生成。
- **没有 editProxy／sceneProxy 实测。** 分辨率、位深、HDR 语义、色彩、存储预算、预取时延未测。
- **没有队列实测。** 重启、离线、抢占、去重、取消、未知、公平、场景批次 head 未执行。
- **生产 Linux／Vulkan scene executor 未实现。** PoC 已在 llvmpipe 软件 Vulkan 上用真实 60MP RAW 验证同一图的 tiling、前缀缓存、receipt 和 macOS 像素对拍；NVIDIA 硬件 Vulkan 门仍阻塞。`image_scene_batch` 仍关闭。
- **NVIDIA Vulkan Server 未实测。** 释放 sglang 后 GPU 已空闲（48,537 MiB free），但 ICD 仍对接口版本 1–8 返回 `VK_ERROR_INCOMPATIBLE_DRIVER`（-3）；llvmpipe 功能已测，CUDA 已做同图显存／并发测量，但都不能代表 Vulkan 生产路径。
- **没有 CUDA/Flux 实测。** 模型、许可、显存、质量未执行。
- **生产色彩门未完成。** PoC 已用 OCIO 2.5.0 在 60MP 上对比 Mac ACES 2 SDR／HDR 前缀（max abs 3.46e-6／7.63e-6）；尚未接入 Server scene final、队列和真实播放器矩阵。
- **没有 UI 原型。** sceneProxy、场景批次、队列、作业、候选状态未进入摄影工作台。
- **没有 10TB／10GbE 基线。**


## 3. P0–P2 PoC 结果（2026-11-27，非生产）

原始回执：[P0](../../experiments/server-poc/RESULTS.md) · [P1](evidence/p1-linux-vulkan-60mp.json) · [NVIDIA Vulkan 阻塞](evidence/p1-nvidia-vulkan-blocked.log) · [P2](evidence/p2-aces2-avif-60mp.json)。

### 3.1 P0 · 契约与队列

- `experiments/server-poc` 的 038 场景图校验和内存队列状态机 **10 项测试通过**，`cargo fmt --check` 通过。
- 覆盖幂等提交、同 ID 冲突、lane 优先、claim／lease／stage／publish、stale token、cancel、retry、reconcile、scene batch／head 身份。
- 只证明契约与状态机；不证明 PostgreSQL、gRPC、S3、崩溃恢复或公平。

### 3.2 P1 · 真实 60MP RAW、Linux／Vulkan、macOS 对拍

样片：Sony A7R V `DSC00413.ARW`，9504 × 6336，SHA-256 `38e48a6e71bd741e1c0b9c5f28dc55347c5aa8d69da5a29dea90bc347c3e4140`，授权本地样片，未提交、未修改原片。

| 项 | macOS Rust／Metal | Linux wgpu／Vulkan（llvmpipe） |
| --- | --- | --- |
| 瓦片 | 20 | 20 |
| 冷 dispatches／nodes | 200／180 | 200／180 |
| 冷图时间 | 628.9 ms | 6074.3 ms（软件 Vulkan） |
| 温图时间 | 131.6 ms | 636.9 ms |
| 改 group 参数 | 138.0 ms | 1190.8 ms |
| 改 sourceRevision | 141.1 ms | 4059.3 ms |
| 冷峰值 | 5.30 GB（6 GiB budget） | 7.71 GB（16 GiB budget） |

逐通道像素比较 240,869,376 个样本：**max abs 9.54e-7，max relative 5.26e-7，mean abs 6.93e-9，>1e-5 为 0，非有限为 0**。最大绝对误差 9.54e-7，符合不同 f32 数学库的舍入差异，远低于 1e-5 门。结论：Linux WGSL 端口与 macOS Rust／Metal 在同一份真实 60MP AP1 输入上通过像素门。

Linux 12 GiB 缓存的四轮回执：

| 轮次 | nodes | dispatches | coverage 命中 | node 命中 | 峰值 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 冷 | 180 | 200 | 0 | 0 | 7.71 GB |
| 温 | 160 | 0 | 80 | 80 | 7.77 GB |
| 只改 group strength | 180 | 20 | 80 | 80 | 8.69 GB |
| 改 sourceRevision | 180 | 120 | 80 | 0 | 13.49 GB |

改 group 参数时只重算每瓦片 1 次混合，前缀节点和分析 coverage 全部命中；改 sourceRevision 时颜色节点全部失效，coverage 仍命中。macOS 生产 Rust cache 固定 768 MiB，60MP 全帧约 4.8 GiB 中间面，整帧前缀会被逐出，所以 Mac 温跑也是 0 命中；这是缓存预算问题，不是键错误。

**NVIDIA Vulkan 硬件门阻塞。** RTX 6000 Ada（驱动 610.43.02）的 ICD 让 `vk_icdGetInstanceProcAddr` 对 `vkCreateInstance`／`vkGetInstanceProcAddr` 都返回 `NULL`；释放 sglang 后 `vk_icdNegotiateLoaderICDInterfaceVersion` 对 1–8 仍全部返回 **-3**。Vulkan loader 1.4.341 与 1.3.275 均失败，因此不是显存不足。GPU 释放后已用 CUDA 做同图显存／并发测量（见 3.2.1）。因此：

- P1 功能／像素／缓存结论成立；
- P1 NVIDIA Vulkan 性能结论仍不成立；llvmpipe 时间不能外推。CUDA 同图显存／并发测量见 3.2.1，但 CUDA 不是 Vulkan，不能替代 Vulkan 门；
- `image_scene_batch` 仍关闭，直到硬件 Vulkan、生产 executor 和色彩门完成。


### 3.2.1 NVIDIA Vulkan 仍阻塞；CUDA VRAM／并发测量

释放 sglang 后 GPU 空闲（48,537 MiB free），但 NVIDIA Vulkan ICD 仍返回 `VK_ERROR_INCOMPATIBLE_DRIVER`：

- `vk_icdNegotiateLoaderICDInterfaceVersion` 对请求版本 1–8 全部返回 **-3**。
- `vkCreateInstance`／`vkGetInstanceProcAddr` 仍为 `NULL`；不是显存不足。
- 记录见 [p1-nvidia-vulkan-blocked.log](evidence/p1-nvidia-vulkan-blocked.log)。

因此用 CUDA 对**同一 9 节点图、同一 60MP AP1 输入**做显存和并发测量。CUDA 端口与 macOS Rust／Metal 对拍：max abs **7.15e-7**，max relative 4.08e-7，>1e-5 为 0。CUDA 不是生产 Vulkan 路径，只用于回答显存需求；完整原始数据见 [p1-cuda-vram-concurrency-60mp.json](evidence/p1-cuda-vram-concurrency-60mp.json)。

**瓦片大小与最大并发（cache 0）：**

| tile | scene 每 job | scene 最大并发 | full 每 job | full 最大并发 |
| ---: | ---: | ---: | ---: | ---: |
| 1024 | 1.95 GiB | 24 | 4.30 GiB | 11 |
| 2048 | 2.29 GiB | 21 | 4.64 GiB | 10 |
| 4096 | 3.63 GiB | 13 | 5.98 GiB | 8 |

**scene-only，tile 2048，随并发度：**

| 并发 | 总显存（含 context） | wall | 每 job 流时间 |
| ---: | ---: | ---: | ---: |
| 1 | 2.72 GiB | 20.1 ms | 19.7 ms |
| 2 | 5.01 GiB | 43.4 ms | 43.0 ms |
| 4 | 9.59 GiB | 87.7 ms | 87.1 ms |
| 8 | 18.74 GiB | 177.2 ms | 176.5 ms |
| 12 | 27.89 GiB | 265.6 ms | 263.5 ms |
| 16 | 37.05 GiB | 354.4 ms | 352.6 ms |
| 20 | 46.20 GiB | 443.0 ms | 440.2 ms |
| 21 | 48.49 GiB | 465.3 ms | 462.3 ms |
| 22 | OOM（21 成功） | — | — |

**full stage（decode + scene + HDR/SDR + PQ 缓冲），tile 2048：**

| 每 job cache | 每 job | 最大并发 | 最大时总显存 | 下一并发 |
| ---: | ---: | ---: | ---: | --- |
| 0 | 4.64 GiB | 10 | 45.82 GiB | 11 OOM |
| 2 GiB | 6.69 GiB | 7 | 46.20 GiB | 8 OOM |
| 4 GiB | 8.74 GiB | 5 | 43.12 GiB | 6 OOM |

**显存估算公式（60MP 实测拟合）：**

- 一张 AP1 全幅面 `S = W × H × 16 bytes`（9504×6336 时约 918.9 MiB）。
- scene-only：`2S + 112 × tile² bytes`（输入＋输出＋6 张 tile 图像＋4 张 tile coverage）。
- full stage：`4.5625S + 112 × tile² bytes`（再加 mosaic 2 B/px、饱和图 1 B/px、HDR/SDR 各 16 B/px、PQ16 6 B/px）。
- cache 再按每 job 配置 MiB 叠加；并发上限约为 `floor((可用显存 - context) / 每 job)`，再留 10% 左右余量。

按此公式，tile 2048 时 24MP 约 1.2 GiB（scene）／2.1 GiB（full），45MP 约 1.8／3.5 GiB，60MP 实测 2.29／4.64 GiB。24MP／45MP 是公式估算，未单独实测。

**解读：**

- 60MP scene 的固定成本是输入＋输出 AP1 约 1.84 GiB／job；每 job 瓦片工作区约 0.45 GiB（tile 2048），所以 scene-only 约 2.29 GiB／job。full stage 再加 RAW mosaic／饱和图／HDR／SDR／PQ 约 2.35 GiB，约 4.64 GiB／job。
- 最大并发基本由 49,140 MiB 线性决定：21 个 scene job 用 48,485 MiB，第 22 个失败；10 个 full job 用 46,917 MiB，第 11 个失败。生产准入必须留出 context、碎片、监控和峰值余量，不能按“刚好最大”调度。建议 scene 按 18–20、full 按 8–9 规划。
- 并发度提高后，单 job 延迟从 20 ms 升到 460 ms，但总吞吐约 45 job/s，说明 GPU 已饱和；不要用单 job 20 ms 乘并发数当延迟承诺。
- 每 job 2–4 GiB cache 会显著降低并发（full 从 10 降到 7／5）。缓存应共享或限制在 0.5–1 GiB／job；不能把 12 GiB 单 job cache 直接乘并发。
- full stage 的 full 是**分配模型**：包括 decode 和 HDR/SDR/PQ 表面，不包括 GPU AV1 编码器和模型前缀。P2 的 AOM／SVT／rav1e 编码在 CPU，占用主机内存（1.34／19.71／2.11 GiB），不占上述 VRAM；若改用硬件 AV1 编码器，需另加其显存。

### 3.3 P2 · ACES 2 与 HDR AVIF

Linux 使用 OpenColorIO 2.5.0 固定配置 `studio-config-v4.0.0_aces-v2.0_ocio-v2.5`（SHA-256 `3a48…c99e`），取与 037 相同的 DisplayViewTransform 前缀，对 60MP 全帧比较：

| 分支 | 比较 | max abs | max relative | mean abs | >1e-5 |
| --- | --- | ---: | ---: | ---: | ---: |
| HDR 1000 nits Rec.2020 | Mac AP1 → Mac 显示线性 | 7.63e-6 | 6.94e-6 | 1.34e-7 | 0 |
| HDR 1000 nits Rec.2020 | Linux AP1 → Mac 显示线性 | 7.63e-6 | 7.09e-6 | 1.32e-7 | 0 |
| SDR 100 nits Rec.709 | Mac AP1 → Mac 显示线性 | 3.46e-6 | 3.46e-6 | 9.09e-8 | 0 |
| SDR 100 nits Rec.709 | Linux AP1 → Mac 显示线性 | 3.46e-6 | 3.46e-6 | 8.94e-8 | 0 |

AVIF 使用同一份 PQ16 RGB48（9504 × 6336，SHA-256 `bacc4d…609e`），libavif 1.0.4，q95，speed 8，32 jobs：

| 编码器 | YUV | 字节 | 编码 | 峰值 RSS | PSNR | 兼容性 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| AOM 3.8.2 | 420 | 26,164,226 | 4.38 s | 1.34 GB | 41.75 dB | FFmpeg＋avifdec；CICP 正确 |
| SVT-AV1 1.7.0 | 420 | 32,029,707 | 14.74 s | 19.71 GB | 42.02 dB | FFmpeg 报 limited range／无颜色标签 |
| rav1e 0.7.1 | 420 | 29,648,964 | 25.76 s | 2.11 GB | 41.89 dB | FFmpeg＋avifdec；CICP 正确 |
| macOS ImageIO | 420 | 26,538,691 | 1.33 s | — | 41.69 dB | avifdec 可解；FFmpeg／libdav1d 解析失败 |
| AOM 3.8.2 | 444 | 42,797,003 | 5.55 s | 2.29 GB | 51.93 dB | FFmpeg＋avifdec；High profile |
| rav1e 0.7.1 | 444 | 46,778,269 | 45.06 s | 3.62 GB | 52.56 dB | FFmpeg＋avifdec；High profile |
| SVT-AV1 1.7.0 | 444 | — | — | — | — | 不支持 4:4:4 |

补充失败：SVT-AV1 在 speed 6 拒绝 9504 宽输入（8K+ 仅 M8 及更快）；SVT 420 码流未写 full-range／CICP；macOS ImageIO 容器带 `irot` 等属性，FFmpeg 6.1／libdav1d 无法解析。建议：AOM 10-bit 4:2:0 作为当前默认；4:4:4 作为已知客户端支持 High profile 时的高质量选项；SVT-AV1 修好颜色信号和 4:4:4 前不用于 8K HDR；macOS 产物发布前必须做独立容器／码流回读。

### 3.4 门状态

| 门 | 状态 | 说明 |
| --- | --- | --- |
| P0 契约／队列 | 通过（PoC） | 10 项测试 |
| P1 瓦片／缓存／receipt | 通过（PoC，llvmpipe） | 真实 60MP，20 瓦片，四轮回执 |
| P1 像素对拍 | 通过（PoC） | max abs 9.54e-7，>1e-5 为 0 |
| P1 NVIDIA Vulkan 性能 | **阻塞** | GPU 已释放，ICD 仍返回 -3；不能外推 |
| P1 CUDA VRAM／并发（fallback） | 已测，非 Vulkan | scene 21／full 10 个 60MP job；见 3.2.1 |
| P2 ACES 2 SDR／HDR | 通过（PoC，CPU OCIO） | max abs 3.46e-6／7.63e-6 |
| P2 HDR AVIF 选型 | 通过（组件） | AOM 默认；SVT／ImageIO 有兼容性问题 |
| `image_scene_batch` 生产门 | **仍关闭** | 需硬件 Vulkan、生产 executor、色彩门与服务端集成 |
| Q3–Q6 生产任务 | 未开始／未验收 | 本文件不改变 [tasks](tasks.md) 的未完成状态 |

## 4. 进入 Q1 前必须补齐

1. 按 [AGENTS](../../AGENTS.md) 更新摄影工作台，覆盖 sceneProxy、场景批次、队列、Server 作业、取消、重试、候选、能力禁用。
2. 冻结 editProxy／sceneProxy 契约：SDR／HDR、分辨率、10-bit／FP16、色域、编码、缓存键、失效、存储预算。
3. 冻结客户端／Server 队列状态机、`SceneWorkflowBatch` 集成、jobID、能力清单、错误码。
4. 决定 Linux／Vulkan scene executor：实现或明确关闭 `image_scene_batch`；不能用 legacy SDR 冒充。
5. 用真实 `rawmaster-image` + Vulkan 在 NVIDIA 上跑 legacy／scene 样本，记录吞吐、显存、精度。
6. 用真实客户端 SQLite 跑队列重启、离线、抢占、取消、未知、场景批次 head。
7. 用 037 色彩规格跑 scene final／HDR AVIF／SDR 派生对照；未过门只候选。
8. 把 039 的 tiling、前缀缓存、execution receipt 带到 Linux／Vulkan；用真实 60MP RAW 复核，不用合成图代替。

## 5. 口径

- 本文件只证明设计已对齐现有代码／验证，不证明功能可用。
- 浏览器原型只证明交互，不证明代理、队列、Vulkan、CUDA、色彩。
- 服务端测试必须使用真实 GPU、真实 S3、真实 PostgreSQL；mock 不能替代。
- 性能数字必须注明硬件、GPU、Vulkan/CUDA、分辨率、编码、缓存、队列深度；API 返回不能冒充端到端。
- 未通过项保留在任务和发布门中。
