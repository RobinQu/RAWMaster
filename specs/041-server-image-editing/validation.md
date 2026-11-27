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
- **NVIDIA Vulkan Server 未实测。** 本机 ICD 无法初始化，GPU 95% 被长期 sglang 服务占用；llvmpipe 功能已测，但不能代表 NVIDIA 性能／显存。
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
| 冷图时间 | 628.9 ms | 6158.1 ms（软件 Vulkan） |
| 温图时间 | 131.6 ms | 620.9 ms |
| 改 group 参数 | 138.0 ms | 1131.1 ms |
| 改 sourceRevision | 141.1 ms | 4141.9 ms |
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

**NVIDIA Vulkan 硬件门阻塞。** RTX 6000 Ada（驱动 610.43.02）的 ICD 让 `vk_icdGetInstanceProcAddr` 对 `vkCreateInstance`／`vkGetInstanceProcAddr` 都返回 `NULL`；Vulkan loader 1.4.341 与 1.3.275 均失败。GPU 同时被 41 天 sglang 服务占用 45.2／49.1 GB。因此：

- P1 功能／像素／缓存结论成立；
- P1 NVIDIA 性能、显存和 49 GB 预算结论不成立，不能用 llvmpipe 外推；
- `image_scene_batch` 仍关闭，直到硬件 Vulkan、生产 executor 和色彩门完成。

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
| P1 NVIDIA Vulkan 性能 | **阻塞** | ICD 初始化失败；GPU 95% 被占用 |
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
