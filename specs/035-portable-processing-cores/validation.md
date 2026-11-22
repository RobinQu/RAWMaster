# 035 · 原生验证、实测边界与复现

2026-11-22，Apple M4 Max、16 核 CPU、128 GiB、macOS 27.0.1。图像实验使用 Rust Release、C++17、wgpu 27.0.1。服务端实验在 Docker 的 Linux arm64 中运行。固定输入、编译器、镜像摘要、各轮时间和输出摘要已归档。[图像计时原始数据](evidence/image-benchmarks.json) · [端到端与 Linux 回执](evidence/image-replay.json) · [资料库与队列验证](catalog-queue.md)

## 性能结论如何影响架构

**单图常驻 GPU 值得做。** 3840 × 2160 的同一图包含两个曝光分支、一个颜色矩阵滤镜和一次蒙版合成。逐节点执行需要 4 次 dispatch、4 个 RGBA 槽，融合执行需要 1 次 dispatch、2 个槽。预置输入与覆盖、更新参数并等待 GPU 真正完成，融合路径的 P50 是 1.56 ms。反过来先测融合路径，P50 是 1.63 ms。完整回传到主存时，轻量算子由 CPU 直接处理更快。

| 输入和测量边界 | CPU 参考 P50 / P95 | 逐节点 GPU P50 / P95 | 融合 GPU P50 / P95 |
| --- | ---: | ---: | ---: |
| 2048 × 1536，驻留图每次更新＋等待 | — | 3.11 / 3.18 ms | 1.55 / 2.12 ms |
| 2048 × 1536，新缓冲、上传、计算、读回、有限值检查 | 2.59 / 5.10 ms | 16.64 / 19.53 ms | 15.27 / 16.48 ms |
| 3840 × 2160，驻留图每次更新＋等待 | — | 4.21 / 7.70 ms | **1.56 / 3.83 ms** |
| 3840 × 2160，8 次提交后等待，每帧摊销 | — | 3.05 / 3.29 ms | **0.80 / 1.00 ms** |
| 3840 × 2160，新缓冲、上传、计算、读回、有限值检查 | **4.92 / 10.34 ms** | 46.96 / 51.15 ms | 37.58 / 38.58 ms |

数字单位是宿主墙钟时间。每个后端先跑一帧，随后 15 个暖样本。驻留实验交替改一条支路的 EV。8 帧一组的指标计量连续处理一张照片多个修订时的吞吐。每帧独立等待那一行更接近串行交互。上传实验从已校验的主存 RGBA 和 coverage 开始，截止读回并逐像素检查有限值。CPU 行从同一已校验输入开始，包含新结果分配、16 个 Rayon 线程可用的 C++ 计算和有限值检查。配方、解码、首建设备、编码及画布呈现分别计量。各路对照的最大通道绝对误差为 `4.77e-7`。[基准程序](../../experiments/portable-processing/image/src/bin/image-probe.rs) · [每一轮与交换顺序的对照](evidence/image-benchmarks.json)

交换 4K 测量顺序后，逐节点和融合的完整读回 P50 分别为 44.39 和 36.63 ms。较早的一次探索运行分别量到 90.63 和 56.13 ms。固定机器上的墙钟数值有波动，放量时需在发布构建、目标硬件和混合负载上重新测 P95。PoC 的 C ABI 当前返回主存像素，Swift 画布验证会走读回和编码。生产预览要接通 GPU 纹理直接呈现，才能把驻留结果兑现为用户可见时延。此前 V3 的原生测量从配方提交一直量到画布接收及绘制，二者计时边界不同。[既有原生应用基线](../024-jpeg-display-proxy/editing-performance-comparison.md)

**60 MP 需要同时约束 GPU 工作区和宿主内存。** 9504 × 6336 的合成 FP32 图包含负值、超白和变化的 alpha。设置 256 MiB 显式 GPU 缓冲预算后，点运算图被切成 12 条，5 个暖样本的整帧上传、渲染、读回、校验 P50/P95 为 290.12/301.44 ms。对照 CPU 为 31.07/34.50 ms。再用 macOS `time -l` 独立运行同样的完整程序，最大 RSS 为 3,525,623,808 B，峰值 footprint 为 3,970,583,696 B，其中包括 CPU 输入、参考和返回帧。临近瓦片接缝的奇数尺寸、单行超预算、同图修改参数及恢复原值也有测试。空间滤镜、几何变换及模型需分别验证 halo、归约和工作区。[分条与绑定实现](../../experiments/portable-processing/image/src/gpu.rs) · [契约测试](../../experiments/portable-processing/image/tests/contract.rs)

## 真实照片、AI、SwiftUI 和服务端

| 场景 | 实际走通的路径 | 结果 |
| --- | --- | --- |
| 山湖 JPEG，1600 × 1067 | 运行仓库 MaskAI 的 EfficientViT ADE20K 天空模型，产出同尺寸灰度 coverage。Swift 按原图与蒙版摘要匹配绑定，将权重身份随作业入队。从 Core Image 取得已定向 FP32，通过 C ABI 交给图像核心。完成时登记 sRGB PNG 并交给工作台所用的 `ZoomableImageView`。 | 模型本轮 817.45 ms。跟踪到该帧的原生 draw 回调。1,329,457 个零覆盖像素精确等于全局曝光分支。覆盖大于 0.5 且发生变化的像素有 305,295 个。GPU 与 CPU 最大绝对差 `1.19e-7`。[原生画布](evidence/swift-jpeg-canvas.jpg) · [蒙版与模型来源绑定](evidence/sky-bindings.json) |
| Sony ILCE-7RM5 ARW，9504 × 6336 | 用 `CIRAWFilter/8` 从真实原片读取，关闭 draft。与 Spec 027 的已定向 2400 × 1600 天空快照对齐。同一份图和同一个画布探针走完领取、显影、发布、状态读回和绘制。 | 1,773,866 个零覆盖像素精确等于 base。覆盖大于 0.5 且发生变化的像素有 1,983,873 个。GPU 与 CPU 最大绝对差 `1.79e-7`。这项测的是实际 RAW 的预览，上一节的 60 MP 压测使用独立的合成输入。[原生画布](evidence/swift-raw-canvas.jpg) · [SwiftUI 测试](../../Tests/RAWMasterUITests/PortableProcessing035Tests.swift) |
| Linux 无 GPU 批处理 | 关闭 Rust 的默认 GPU feature，以一个进程、一个已编译图接收以上两份已定向 FP32 输入和各自的 coverage。校验输入和配方摘要，逐张写回 FP32。 | 两张分别产生 27,315,200 B 和 61,440,000 B。Linux CPU 输出的**整帧 SHA-256** 逐张匹配 macOS CPU 参考。每个条目保留自己的来源、尺寸和输出身份。[Linux 批处理](../../experiments/portable-processing/image/src/bin/batch-replay.rs) · [两张回执](evidence/image-replay.json) |
| Linux 直接解 RAW | 同一 Sony 原片由固定提交 FlashRaw 0.3.1 的 Linux `.so` 读取。编译仓库已有的 CFlashRaw C 桥，取 (3500, 1800) 的 512 × 384 传感器方向裁块，验证方向为 1，以 linear-sRGB F32 接入 Rust 曝光，写出 RGBA32F。 | 3,145,728 B 输出，+1 EV 与逐通道乘二的最大差为 0。这是 FlashRaw 解码契约的成立证据。与 Apple 系统显影的视觉与相机色彩等价性需另行校准。[C 客户端](../../experiments/portable-processing/image/examples/raw-ingress.c) · [固定 FlashRaw 提交](https://github.com/ybouane/flashraw/tree/2994e8c550bec70ab78a938ab28a74d7762124f4) |
| Linux Vulkan | 在 Mesa llvmpipe 软件 Vulkan 设备上编译同一 WGSL，运行分支、参数重绑、不能重绑的拓扑、拆条与 CPU 对照。 | Linux CPU-only 4 项测试通过。启用 Vulkan 或在 Mac 使用 Metal，均有 5 项通过。软件 Vulkan 的时间不用于物理 GPU 吞吐。C ABI 另验证错误输入不发布半成品、所有权释放及未知后端。[回执](evidence/image-replay.json) |
| 目录与三视图任务 | 经真实 v8 库副本查询 60 张并批取任务状态。8 个进程竞争租约，再对运行中的 worker 发送 SIGKILL，注入 ENOENT、事务中断和应答丢失。 | 6,928 条资产的库中，60 张加状态 P95 为 5.915 ms。竞争按额度给出 4 个不同任务，重领后拒绝旧 token。故障重放后只登记一次真实 JPEG。跨资料库、跨设备及不可撤销云服务的恢复另有验收条件。[资料库／调度实测](catalog-queue.md) |

画布图片是从原生测试的 bitmap capture 缩小得到的 JPEG。测试也保留完整 PNG、原始浮点帧、内容摘要和目录收据。蒙版使用来源绑定和零覆盖／内部分区核对。这两张样片不能确定模型的总体分割质量。完整的生产 `EditingController` 拖动、实际 032 写盘、不同 ICC 工作流和物理 Linux GPU 的混合负载在下一阶段验收。[带生产入口的切换条件](spec.md)

## 从仓库根目录复现

**macOS 图像库。** 需要 Rust、C++ 编译器及可用 Metal 设备。下列命令把所有构建产物放在已有的忽略目录。4K 独立进程可用 `RM035_FUSED_FIRST=1` 交换后端测量顺序。

```sh
img=experiments/portable-processing/image
build="$PWD/output/035/image-target"
cargo test --release --locked --manifest-path "$img/Cargo.toml" --target-dir "$build" -- --include-ignored
cargo build --release --locked --manifest-path "$img/Cargo.toml" --target-dir "$build"
"$build/release/image-probe" compare 2048 1536 15
"$build/release/image-probe" compare 3840 2160 15
RM035_FUSED_FIRST=1 "$build/release/image-probe" compare 3840 2160 15
/usr/bin/time -l "$build/release/image-probe" bounded 9504 6336 5
```

**SwiftUI、真实 AI 与跨平台批处理。** 运行原生画布需可用的 macOS 图形登录会话和仓库 SwiftPM 原有依赖。默认 JPEG 与经核验的蒙版已随仓库提供。脚本为每次验证新建实验目录并在最后一行打印路径。第二个场景需要 Spec 027 的 Sony 原片及其天空蒙版。Linux 各命令使用 Docker 和固定 Rust 镜像，Linux GPU 功能验证会在一次性容器内安装 Mesa。宿主上以 C++ 编译 CPU 参照，无窗口运行服务端 worker。

```sh
set -euo pipefail
runner=experiments/portable-processing
jpeg_record=$("$runner/swift-host/run.sh" | tail -n 1)
"$runner/verify-linux.sh" cpu
"$runner/verify-linux.sh" vulkan
raw_file="$PWD/experiments/MaskAI/Fixtures/RAW/sony-landscape.ARW"
raw_mask="$PWD/experiments/MaskAI/Validation/RAW/8f96d2fd-landscape-sky-mask.png"
raw_record=$("$runner/swift-host/run.sh" "$raw_file" "$raw_mask" | tail -n 1)
"$runner/verify-linux.sh" batch "$jpeg_record" "$raw_record"
"$runner/verify-linux.sh" raw "$raw_file"
```

只有 JPEG 样片时，也可直接运行 `"$runner/verify-linux.sh" batch "$jpeg_record"`。若要重新生成 JPEG 天空蒙版，按 MaskAI 的说明准备 ONNX Runtime 和已锁定权重，并从其包目录运行下列命令。随文清单记录本轮实际权重摘要，天空图以数值覆盖读取。[模型准备](../../experiments/MaskAI/README.md) · [实际覆盖图](evidence/sky-mask.png)

```sh
mkdir -p output/035/mask-replay
(cd experiments/MaskAI && swift run mask-ai-probe landscape sky \
  ../../specs/030-ai-retouching/evidence/mountain-lake.jpg ../../output/035/mask-replay/sky.png)
```

**目录与参考应用。** 目录用例有自己的 macOS／Linux 入口和真实库分页复现说明。Alcedo 的 C++ 图规则探针链接固定提交。LightFlow 的固定清单可在新的空目录重建编辑器和像素引擎的公开站点镜像，并用文中的浏览器脚本重新读回最终帧。[目录复现](catalog-queue.md#复现) · [Alcedo 复现](alcedo.md#可重复的源码探针) · [LightFlow 复现](lightflow.md#复核)

## 实施前仍需验证的项目

- **颜色与算法兼容。** 现有 V1／V2／V3 的 RAW 曝光与白平衡、各 LUT 强度平面、曲线、局部修复、半透明、负通道与高光需逐算子和逐组合对照。CPU 跨平台逐字节一致限于这两个固定输入与图。为广色域和 HDR 输出另加实测色卡、ICC、量化及 ΔE 测试。
- **实际预览与调度。** 将驻留 GPU 纹理接到生产画布，并用当前滑杆请求替代机制防止过期交付。测真实输入到显示、交互中夹带 AI／导出的 P95、60MP 卷积／降噪时峰值、取消完成时延、设备丢失恢复和外接存储读写。给各步骤配置可测的资源申请与释放。
- **发布与服务端。** 现有生产模块、此前的本地改动属于本次研究基线。两库默认接管桌面、跨机租约、x86_64／物理 Vulkan、多租户负载、真实目标文件系统故障，以及可回退的旧库迁移，须按主规格分阶段验收。实验固定的 wgpu 依赖树在当前 nightly 上报告 `block 0.1.6` 的未来兼容性告警，选发布工具链时一并复验。
