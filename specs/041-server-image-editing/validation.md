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
- **生产 Linux／Vulkan scene executor 未实现。** PoC 已在 llvmpipe 和 NVIDIA Vulkan（EGL ICD）上用真实 60MP RAW 验证同一图的 tiling、前缀缓存、receipt 和 macOS 像素对拍；生产 executor、队列和色彩门仍未完成。`image_scene_batch` 仍关闭。
- **NVIDIA Vulkan 部署未固化。** PoC 已用 EGL ICD 在 RTX 6000 Ada 上完成 60MP 像素／缓存／并发实测；生产服务尚未固化 `VK_DRIVER_FILES`、`graphics` capability 和启动能力探测，也未接入生产 executor。
- **没有 CUDA/Flux 实测。** 模型、许可、显存、质量未执行。
- **生产色彩门未完成。** PoC 已用 OCIO 2.5.0 在 60MP 上对比 Mac ACES 2 SDR／HDR 前缀（max abs 3.46e-6／7.63e-6）；尚未接入 Server scene final、队列和真实播放器矩阵。
- **没有 UI 原型。** sceneProxy、场景批次、队列、作业、候选状态未进入摄影工作台。
- **没有 10TB／10GbE 基线。**


## 3. P0–P2 PoC 结果（2026-11-27，非生产）

原始回执：[P0](../../experiments/server-poc/RESULTS.md) · [P1](evidence/p1-linux-vulkan-60mp.json) · [NVIDIA Vulkan 根因](evidence/p1-nvidia-vulkan-blocked.log) · [NVIDIA Vulkan EGL 硬件复测](evidence/p1-vulkan-nvidia-egl-60mp.json) · [CUDA 严格显存模型](evidence/p1-cuda-vram-concurrency-60mp.json) · [P2](evidence/p2-aces2-avif-60mp.json)。

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

**NVIDIA Vulkan 硬件门已解锁。** 根因不是显存，而是 headless 环境选错了 ICD：包管理的 `nvidia_icd.json` 指向 `libGLX_nvidia.so.0`，其 Vulkan 初始化调用 `XOpenDisplay(NULL)`，无 X 时返回 `VK_ERROR_INCOMPATIBLE_DRIVER`（-3）。改用 `libEGL_nvidia.so.0` 作为 ICD 后，RTX 6000 Ada 正常枚举 Vulkan 1.4.341，60MP 像素对拍 max abs **7.15e-7**。详见 3.2.1。

- P1 功能／像素／缓存结论成立，且已在 NVIDIA Vulkan 上复测；
- NVIDIA Vulkan 的功能、像素、缓存门通过；PoC harness 的时间不是生产 executor 性能；
- `image_scene_batch` 仍关闭，直到生产 Linux scene executor、队列和色彩门完成。

### 3.2.1 NVIDIA Vulkan：根因、修复与硬件复测

释放 sglang 后 GPU 空闲（48,537 MiB free），但包管理的 NVIDIA Vulkan ICD 仍失败。根因已定位：

- `/usr/share/vulkan/icd.d/nvidia_icd.json` 指向 `libGLX_nvidia.so.0`。
- `libGLX_nvidia` 的 Vulkan 初始化调用 `XOpenDisplay(NULL)`；headless 没有 X 时初始化失败，`vk_icdNegotiateLoaderICDInterfaceVersion` 对请求版本 1–8 全部返回 **-3**，`vkEnumerateInstanceVersion` 也返回 -3。
- `libEGL_nvidia.so.0` 导出同样的 Vulkan ICD 入口，且不需要 X；协商返回成功，`vkEnumerateInstanceVersion` 报告 Vulkan **1.4.341**。
- 只安装 `libegl1` 不能修复 GLX ICD；`Xvfb` 不提供 NVIDIA GLX；`libnvidia-vksc-core` 是 Vulkan SC，不是普通 Vulkan。
- 容器侧 `NVIDIA_DRIVER_CAPABILITIES=compute,utility` 不会挂载 `libEGL_nvidia`／`libGLX_nvidia`；必须包含 `graphics`。

**修复（per-service，不修改包文件）：**

```json
{"file_format_version":"1.0.1","ICD":{"library_path":"libEGL_nvidia.so.0","api_version":"1.4.341"}}
```

```sh
VK_DRIVER_FILES=/opt/vulkan/nvidia_egl_icd.json
NVIDIA_DRIVER_CAPABILITIES=graphics,compute,utility
```

PoC 配置与探测脚本：[nvidia_egl_icd.json](../../experiments/server-poc/tools/nvidia_egl_icd.json) · [check_vulkan_egl.sh](../../experiments/server-poc/tools/check_vulkan_egl.sh)。`vulkaninfo` 原始输出：[nvidia-vulkan-egl-summary.txt](evidence/nvidia-vulkan-egl-summary.txt)。

**60MP 硬件 Vulkan 配置扫描（tile 2048 除注明外；cache 0 的 4 GiB budget，cache 4 GiB 的 8 GiB，cache 12 GiB 的 16 GiB）：**

| tile | cache | 实际峰值 | 逻辑峰值 | 冷 | 温 | 改 group | 改 source | 温 cache 命中 | parity max abs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1024 | 0 | 2,040 MiB | 1,950 MiB | 1471.5 ms | 443.9 ms | 412.4 ms | 415.6 ms | 0/0 | 7.15e-7 |
| 2048 | 0 | 2,424 MiB | 2,286 MiB | 1542.8 ms | 426.6 ms | 407.4 ms | 413.7 ms | 0/0 | 7.15e-7 |
| 4096 | 0 | 3,960 MiB | 3,630 MiB | 1511.7 ms | 398.2 ms | 395.6 ms | 393.9 ms | 0/0 | 7.15e-7 |
| 2048 | 4 GiB | 6,302 MiB | 6,122 MiB | 1533.6 ms | 459.7 ms | 424.7 ms | 428.5 ms | 0/0 | 7.15e-7 |
| 2048 | 12 GiB | 12,560 MiB | 12,868 MiB | 1491.4 ms | 33.2 ms | 75.0 ms | 294.6 ms | 80/80 | 7.15e-7 |

冷时间包含 shader 编译；温／编辑／新 source 是稳态。4 GiB cache 对 60MP 全帧前缀太小（20 tile × 5 节点 × 64 MiB ≈ 6.4 GiB），所以 0 命中；12 GiB 才能让温跑 0 dispatch。三个 tile 和所有 cache 配置的 AP1 输出 SHA-256 完全一致；像素门为 240,869,376 个通道样本，max abs **7.1525574e-7**，>1e-5 为 **0**，非有限为 0。原始回执：[p1-vulkan-nvidia-egl-60mp.json](evidence/p1-vulkan-nvidia-egl-60mp.json) · [config](evidence/vulkan-nvidia/config)。

**Vulkan 并发（tile 2048，cache 0，4 GiB budget，单 pass；barrier 表示所有进程已完成输入/输出分配）：**

| 并发 | barrier 显存 | 运行峰值 | 完成 reports |
| ---: | ---: | ---: | ---: |
| 1 | 1,912 MiB | 2,424 MiB | 1 |
| 2 | 3,815 MiB | 4,839 MiB | 2 |
| 4 | 7,623 MiB | 9,671 MiB | 4 |
| 8 | 15,242 MiB | 19,340 MiB | 8 |
| 12 | 22,862 MiB | 29,009 MiB | 12 |
| 16 | 30,481 MiB | 38,678 MiB | 16 |
| 20 | 38,103 MiB | 48,347 MiB | 20 |
| 21 | 40,006 MiB | 48,532 MiB | 21 |
| 22 | 41,911 MiB | 48,525 MiB | 22 |
| 24 | 45,720 MiB | 48,538 MiB | 24 |
| 25 | 47,625 MiB | 48,538 MiB | 25 |
| 26 | 47,677 MiB | 48,538 MiB | 26 |

26 个单 pass 进程在 48.5 GiB 高水位完成，说明 Vulkan 驱动会调度／超额提交短生命周期的 tile 表面；这不等于 26 个 job 可以安全常驻。27 个进程到达 barrier（47,729 MiB）后，运行阶段被停止，未计入成功。逐并发原始回执在 [concurrency](evidence/vulkan-nvidia/concurrency)。

**严格分配模型（CUDA，作为准入上限）：**

CUDA 对每个 job 显式 `cudaMalloc`，22 个 scene job 时直接 OOM，因此严格上限是 **21**，不是 Vulkan 的 26。full stage（decode＋scene＋HDR/SDR/PQ 缓冲）每 job 约 4.64 GiB，最大 10；每 job cache 2／4 GiB 时降到 7／5。

| 模型 | scene 每 job | scene 最大 | full 每 job | full 最大 |
| --- | ---: | ---: | ---: | ---: |
| tile 1024 | 1.95 GiB | 24 | 4.30 GiB | 11 |
| tile 2048 | 2.29 GiB | 21 | 4.64 GiB | 10 |
| tile 4096 | 3.63 GiB | 13 | 5.98 GiB | 8 |

full stage 每 job cache 0／2／4 GiB 时分别 4.64／6.69／8.74 GiB，严格最大并发 10／7／5。详细逐并发数据在 [CUDA 回执](evidence/p1-cuda-vram-concurrency-60mp.json)。

**显存估算公式：**

- `S = W × H × 16 bytes`（9504×6336 约 918.9 MiB）。
- scene-only：`2S + 112 × tile² bytes`。
- full stage：`4.5625S + 112 × tile² bytes`（mosaic 2 B/px、饱和图 1 B/px、HDR/SDR 各 16 B/px、PQ16 6 B/px）。
- cache 再按每 job 配置 MiB 叠加；准入上限 `floor((可用显存 - context) / 每 job)`，再留约 10% 余量。

60MP 实测／严格分配：scene 2.29 GiB、full 4.64 GiB；24MP 约 1.2／2.1 GiB，45MP 约 1.8／3.5 GiB（公式估算）。

**准入建议：**

- 不要把 26（Vulkan 单 pass 高水位）当生产并发；按严格模型并留余量：scene **18–20**，full **8–9**。
- tile 1024 提高 scene 并发到 24，但 dispatch 数从 200 增到 700；tile 2048 是平衡点。
- 每 job 2–4 GiB cache 会显著降低 full 并发；缓存应共享或限制在 0.5–1 GiB／job。
- full stage 是分配模型，不含 GPU AV1 编码器和模型前缀；P2 的 CPU 编码器占主机内存（AOM 1.34／SVT 19.71／rav1e 2.11 GiB）。
- CUDA 严格分配数据见 [p1-cuda-vram-concurrency-60mp.json](evidence/p1-cuda-vram-concurrency-60mp.json)。

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
| P1 瓦片／缓存／receipt | 通过（PoC，llvmpipe＋NVIDIA Vulkan） | 真实 60MP，20 瓦片，四轮回执；Vulkan 12 GiB cache 温跑 80/80 |
| P1 像素对拍 | 通过（PoC） | llvmpipe 9.54e-7；NVIDIA Vulkan 7.15e-7；>1e-5 为 0 |
| P1 NVIDIA Vulkan 功能／缓存 | 通过（EGL ICD） | 60MP，20 tiles；warm 33 ms；见 3.2.1 |
| P1 VRAM／并发 | 已测 | 严格：scene 21／full 10；Vulkan 26 单 pass 高水位 48.5 GiB，不作准入上限 |
| P2 ACES 2 SDR／HDR | 通过（PoC，CPU OCIO） | max abs 3.46e-6／7.63e-6 |
| P2 HDR AVIF 选型 | 通过（组件） | AOM 默认；SVT／ImageIO 有兼容性问题 |
| `image_scene_batch` 生产门 | **仍关闭** | 硬件 Vulkan 已解锁，但生产 executor、队列、色彩门与服务端集成未完成 |
| Q3–Q6 生产任务 | 未开始／未验收 | 本文件不改变 [tasks](tasks.md) 的未完成状态 |

## 4. 进入 Q1 前必须补齐

1. 按 [AGENTS](../../AGENTS.md) 更新摄影工作台，覆盖 sceneProxy、场景批次、队列、Server 作业、取消、重试、候选、能力禁用。
2. 冻结 editProxy／sceneProxy 契约：SDR／HDR、分辨率、10-bit／FP16、色域、编码、缓存键、失效、存储预算。
3. 冻结客户端／Server 队列状态机、`SceneWorkflowBatch` 集成、jobID、能力清单、错误码。
4. 决定 Linux／Vulkan scene executor：实现或明确关闭 `image_scene_batch`；不能用 legacy SDR 冒充。
5. 用真实 `rawmaster-image` + Vulkan 在 NVIDIA 上跑 legacy／scene 样本，记录吞吐、显存、精度；headless 部署必须使用 EGL ICD（`VK_DRIVER_FILES`）并加 `graphics` capability，启动时探测失败则关闭 `image_scene_batch`。
6. 用真实客户端 SQLite 跑队列重启、离线、抢占、取消、未知、场景批次 head。
7. 用 037 色彩规格跑 scene final／HDR AVIF／SDR 派生对照；未过门只候选。
8. 把 039 的 tiling、前缀缓存、execution receipt 带到生产 Linux／Vulkan；PoC 已用真实 60MP RAW 复核，生产 `rawmaster-image` 端口仍未完成。

## 5. 口径

- 本文件只证明设计已对齐现有代码／验证，不证明功能可用。
- 浏览器原型只证明交互，不证明代理、队列、Vulkan、CUDA、色彩。
- 服务端测试必须使用真实 GPU、真实 S3、真实 PostgreSQL；mock 不能替代。
- 性能数字必须注明硬件、GPU、Vulkan/CUDA、分辨率、编码、缓存、队列深度；API 返回不能冒充端到端。
- 未通过项保留在任务和发布门中。
