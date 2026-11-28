# 043 · 验收基线

2026-11-28 · **M0 进行中。** 本页登记现状证据和 Rust + wgpu/WGSL 的放行条件。每次切换路径时追加冻结输入、实际设备、像素与性能回执。[规格](spec.md) · [计划](plan.md) · [任务](tasks.md)

## 1. 当前基线

| 场景 | 当前数据 | 来源 |
| --- | --- | --- |
| 60 MP 摄影加三节点 DAG 双目标组件 | 单次 `elapsedMs=1750.98`，每目标 35 个瓦片、105 次 DAG dispatch。图核算峰值 `1,458,929,664 B` / 预算 `1,610,612,736 B`。`backend=mixed`、`dagBackend=rust` | [回执](../037-color-film-hdr/evidence/2026-11-27-photographic-60mp.json) |
| 6 MP 六节点 AP1 图 | 039 一轮各 15 个暖样本，原生 Rust Metal/Swift p95 为 14.26/14.27 ms | [039 图执行实测](../039-rust-scene-backend/validation.md#组内监看与实际后端) |
| 038 FIT 与组内监看 | FIT p50/p95 为 22.07/23.30 ms。节点监看为 19.43/20.78 ms，复跑 p95 为 21.61 ms。主跑返回最终根为 18.23/19.34 ms | [038 原生监看](../038-node-dag-workflow/validation.md#原生可编辑-graph) |
| 036 1:1 50 配方 | 中位 111.4 ms，p95 1,474.3 ms。局部样本 texture 482.3、dehaze 1,586.2、brilliance 3,883.8 ms | [036 规格](../036-render-pipeline-performance/spec.md#画布自由缩放与取样) |
| 035 发布门 | 首次精确/定稿中位 77–81 ms。LightFlow 2400×1600 精确读回的旧对标上限为 24.35/25.92 ms。缩放平移 p95 约 21 ms，对 8 ms 上限 | [035 路线图](../035-portable-processing-cores/roadmap.md#当前实现和签收缺口) · [正式比较器](../../scripts/check-lightflow-performance.py) |
| 035 wgpu 点算子 | 已有 macOS 真实 Metal、同设备纹理借用与 Linux 软件 Vulkan 的点运算对照 | [035 点算子证据](../035-portable-processing-cores/validation.md) · [纹理交接](../035-portable-processing-cores/evidence/image-metal-iosurface.md) |

60 MP 的 1.751 秒是组件样本，还包含文件核对和证据复制。`cpuMilliseconds` 采集 Rust `SceneProgram.render` 区间的墙钟，含 GPU 等待。图峰值含 192 MiB 摄影预留，AVIF 的整帧缓冲需另计。M0 以同构建的 032 和组件分项数据建立各自基线。[组件测量区间](../../Tests/RAWMasterImagingTests/DevelopmentSceneDeliveryServiceV1Tests.swift#L211) · [Rust 计时](../../Modules/ImageEdit/src/scene/metal_exec.rs#L387) · [编码缓冲](../../Sources/RAWMasterImaging/DevelopmentSceneAVIFV1.swift#L42)

## 2. 每阶段必须记录

### M0 · 回执修复与基线

- **协议回归。** 修复前，原生目录接口解析旧 V1 `prepareItem`，带 `photographicEngine` 或 `dagBackend` 的同一请求在打开目录前被拒绝。修复后 Rust 队列 Release 35 项通过，覆盖旧 V1、带摄影字段的 V1、未知字段以及准备、发布、确认后的 `SIGKILL`。恢复时复核同一执行回执并拒绝替换已冻结的 DAG 后端。[Swift 编码入口](../../Sources/RAWMaster/WorkbenchDeliveryCatalog.swift#L437) · [Rust 反序列化](../../Modules/LibraryCatalog/src/scheduler/batch/items.rs#L53) · [Rust 恢复测试](../../Modules/LibraryCatalog/tests/scheduled_processing/workbench_item_delivery.rs#L196)
- **产品回归。** 在 `main@e419c425` 的原生 Release 中，固定 60 MP 原片的 HDR 场景以全图饱和度 0.23 和 DAG 曝光 +0.5 EV 冻结。032 分两个批次发布 PQ AVIF 与 SDR JPEG，重新打开目录并核对版本、文件摘要和 9504×6336 尺寸。每个目标实际执行 35 个瓦片和 35 次 DAG 派发，回执保留 `backend=mixed`、`photographicEngine=scene-photographic-v1-f32-metal`、`dagBackend=rust`。联合原生回归 19 项通过。实际 032 成片与进程中断状态机分别提供产品输出和恢复证据。[原生队列用例](../../Tests/RAWMasterUITests/EditingSceneDarkroomTests.swift#L54) · [目录提取回执](evidence/m0-032-photographic-receipt.json)
- **同构建计量。** 60 MP 分别测量 032 单目标和双目标组件，拆分来源校验/读取、FlashRaw 解码、mosaic 上传、摄影/模型、DAG 准备及执行、DRT/blit、编码读回、发布和等待。每段记录墙钟、可用 GPU 时间、纹理分配、瓦片、派发和编译计数。另记录工作集、缓存、模型、输出、编码和总峰值。
- **分项记录口径。** 原生队列与双目标组件现在可以写隔离 JSON。032 从新编码尝试计到发布确认，独立组件共享一次来源捕获和 mosaic。Swift Metal 只从现有完成点读取 GPU 时间戳。Core Image、ImageIO、模型提供者和 Rust ABI 的不可见阶段注明原因。每项 CPU 墙钟、阻塞和 GPU 区间可能重叠。进程 footprint 和 Metal 已分配大小在现有阶段边界采样，图预算保持单独的保守核算。[分项记录](../../Sources/RAWMasterImaging/DevelopmentSceneDeliveryTraceV1.swift) · [复跑脚本](../../scripts/performance/measure-043-scene-delivery.py)
- **基线报告。** 取得 6 MP 六节点、038 FIT/监看和 036 1:1 的同构建基线。记录提交、锁定依赖、构建与运行库摘要、样片和校准 SHA、设备/驱动/屏幕及阶段时间边界，说明缺失或跳过的量。V2 草案应有版本、实际执行者、图形 API 和旧票据兼容策略。[回执草案](plan.md#43-receiptv2)

同一生产渲染源码的 Release 实跑通过 6 MP、038 编辑窗口和 036 原寸窗口用例。6 MP 六节点在同一次新测试构建中各预热 5 次并计量 30 次，Rust Metal p50/p95 为 12.75/13.76 ms，Swift Metal 为 15.14/16.48 ms。038 原生窗口的组内节点监看和最终根切换各采 30 次，p50/p95 分别为 23.34/26.07 和 22.05/24.08 ms。036 的 50 配方原寸窗口为 122.02/1,538.16 ms，p95 取配方之间的分布。三项长尾依次为自适应 Brilliance 4,259.76 ms、正向去雾 v2 1,804.34 ms 和局部纹理加清晰度 1,538.16 ms。[6 MP 现行实测](evidence/m0-6mp-warm-baseline.json) · [038 与 036 结果](evidence/m0-scene-and-detail-matrices.json)

60 MP 夹具经固定 FlashRaw C ABI 的 `rawU16` 和现行 Swift 校准读取。证据固定 Bayer 区域、CFA、黑白电平、白平衡、XYZ→相机矩阵和相机→AP1 三行，供首条场景 DAG 固定输入使用。[校准证据](evidence/m0-60mp-calibration.json)

`1ebf4e0a` 的 Release 用同一 9504×6336 原片、摄影曝光 +0.25 EV、饱和度 0.32、自然饱和度 −0.15，以及 coverage、+1 EV Corrector 和有序 Layer 三节点测量。每路由一次首跑、五次预热、三十次计量。032 使用同一个工作台和冻结草稿，每轮申请新的两个批次和输出位置。目录重开后核对 72 个实际成片的状态和执行回执，两种格式各自的 36 份成片摘要一致。[三路分项、构建指纹和内存检查点](evidence/m0-60mp-stage-baseline.json)

| 路由 | 首跑 ms | 暖态 p50 / p95 ms | DAG 瓦片 / 派发 |
| --- | ---: | ---: | ---: |
| 032 PQ AVIF | 1,377.68 | 1,354.67 / 1,409.24 | 35 / 105 |
| 032 SDR JPEG | 566.62 | 588.70 / 601.35 | 35 / 105 |
| 双目标组件 | 1,785.87 | 1,732.95 / 1,804.68 | 每个目标 35 / 105 |

032 PQ 的 AVIF 编码 p50 为 877.13 ms，约占该路径的 65%。Rust DAG 求值及等待为 55.73 ms，逐瓦片打开程序为 4.12 ms，DRT 和落瓦片的主机等待分别为 36.90 和 30.54 ms。SDR JPEG 编码 p50 为 104.94 ms。M1 单独验证图和提交复用对时延的贡献。PQ 总时延另测编码器并维持原位深、PQ 信号和回读判据。

每个目标的图核算峰值为 1,458,929,664 B，预算 1,610,612,736 B。整幅暂存 AVIF 为 481,738,752 B，SDR 位图为 240,869,376 B。032 计时内最大采样为 Metal 设备分配约 7.33 GB、进程 footprint 约 3.72 GB。两项目标之间的 Metal 设备分配保持在 5.61–5.62 GB，释放工作台和资料库所有者后降至 0.14 GB。首次每轮新建工作台的试验曾出现 7.25→9.11 GB，已改用单一工作台和独立批次固定基线。各值的时间点与核算边界分别详见报告。

M0 以带摄影调整的真实 032 队列发布、重开与恢复通过，并能复现同构建的分项基线为完成条件。

### M1 · 去重

- 对照瓦片与整幅、单目标与双目标、复用前后及 60 MP 成片。记录 `rendererBuildCount`、`programCompileCount`、`libraryCompileCount` 和实际等待。
- 共享场景瓦片时实测输出与编码暂存的并行峰值，同时回归独立目标的取消、编码失败和 032 恢复。符合预算的路由启用共享，其余按逐目标执行复验。
- 通过条件为像素等价，60 MP 暖态端到端 p95 ≤M0 同路由基线的 105%，相同渲染意图的瓦片和 DAG 派发数至多等于基线，重复准备次数下降。

M1-01 在相同实拍与 FlashRaw 运行库上完成三条路径各一次首轮、五次预热和三十次计量。每个暖态目标的 renderer 从 36 次减至 1 次，Rust program 从 35 次减至 1 次。新路径调用 Metal library API 3 次，包含 Swift DAG、Rust DAG 和 DRT。该计数按宿主 API 调用记录。每目标维持 35 个瓦片、105 次派发和 1,458,929,664 B 图核算峰值。032 的 PQ AVIF 和 SDR JPEG 各 36 份文件在前后构建的摘要完全一致。旧库缺符号时仍用原 Rust 路径，实机探针核对了一次曝光调度和有符号 AP1 像素。 [M1-01 报告](evidence/m1-60mp-frozen-tile-preparation.json)

| 路径 | M0 p50 / p95 (ms) | M1-01 p50 / p95 (ms) | M1 p95 上限 (ms) |
| --- | ---: | ---: | ---: |
| 032 PQ AVIF | 1354.67 / 1409.24 | 1353.70 / 1397.08 | 1479.70 |
| 032 SDR JPEG | 588.70 / 601.35 | 576.11 / 607.07 | 631.42 |
| 双目标组件 | 1732.95 / 1804.68 | 1724.14 / 1790.61 | 1894.91 |

M1-03 的瓦片 DRT 在同一 Apple M4 Max、同一 Release 测试构建、同一 60 MP RAW 和 FlashRaw 运行库下对照。039 的三条路由各执行一次首轮、五次预热和三十次计量。终端 RGBA32F 纹理由瓦片渲染器独占，各瓦片以绝对原点直接写入，所有瓦片通过完成、有限值和取消检查后交给编码。每个目标依旧执行 35 次 DRT，独立 blit 由 35 次降到零，图派发、缓存和预算计数保持一致。032 与双目标组件的 PQ、JPEG 各有 36 份成片在两臂逐字节一致。12 项原生用例覆盖输出边缘、透明及部分 alpha、越界和别名拒绝，以及首块完成后取消与重试。[分项、样本和文件摘要](evidence/m1-direct-drt-assembly.json)

| 60 MP 路由 | 039 blit → 直写 p50 / p95，ms |
| --- | --- |
| 032 PQ AVIF | 1342.63 / 1452.00 → 1301.12 / 1341.78 |
| 032 SDR JPEG | 576.39 / 603.87 → 546.22 / 569.15 |
| 双目标组件 | 1640.34 / 1699.83 → 1590.58 / 1644.78 |

039 的三路直写 p95 都在同路由 M0 的 105% 内。原路径的独立 blit 每目标主机等待中位约 30–35 ms。两臂沿用同一保守图预算，两个 032 路由采样设备峰值下降约 197 MB。瓦片直写默认启用，`RAWMASTER_SCENE_DIRECT_DRT=0` 可选择逐瓦片 blit。图与 DRT 的同队列提交仍待签收。原始报告保留 wgpu 修复前的历史采样，严格 wgpu 直写路由的现行数据来自实际提交的复测。Release `20261128.134122` 安装后通过严格验签、隔离库启动和 Metal ABI 探针。[复跑入口](../../scripts/performance/measure-043-scene-delivery.py) · [安装回执](evidence/m1-direct-drt-release-checkpoint.json) · [完成点复测](evidence/m2-native-metal-completion.json)

### M2 · 首条 WGSL 场景 DAG 与融合

| 验收项 | 必须提供的证据 |
| --- | --- |
| 固定输入 | 同一源码提交、锁定依赖、算子版本、冻结场景图和资源摘要。固定实拍 RAW 及其校准产生的 AP1 F32 夹具，记录 AP1 表面、全图及非居中 ROI。首条包含曝光、EV 曲线、coverage 和有序 Layer |
| macOS 实机 | Apple M4 Max，系统构建 26A434。`executor=wgpu`、`graphicsAPI=metal`，严格 WGSL 段零回退。[Metal 回执](evidence/m2-ap1-real-metal.json) |
| Linux 实机 | NVIDIA RTX 6000 Ada，PCI ID `10de:26b1`，驱动 `610.43.02`，设备 Vulkan 1.4.341。`executor=wgpu`、`graphicsAPI=vulkan`，严格 WGSL 段零回退。[Vulkan 回执](evidence/m2-ap1-real-vulkan.json) |
| 两端像素 | 参考 CPU、039 原生 Metal 和两端 WGSL 的同输入对照。覆盖负值、超白、alpha、零覆盖、禁用、非居中 ROI 与整幅裁块；核对监看根与冻结最终根 |
| macOS 产品路径 | 24/60 MP 原生 FIT 到 drawable、组内监看、原寸取景与 032。核对同设备纹理借用、同步、等待、整帧上传/读回和实际峰值 |

首条场景路径必须有以上双端实机证据再启用。M5 继续签收 Linux 的 RAW 到成片产品闭环。

冻结源 RAW 9504×6336 生成 2400×1600 线性 AP1，非居中 ROI 为 `(1771, 1093, 629, 507)`。最终根和监看根各跑整幅与 ROI，两端共八次，均为一次派发与零回退。独立复算的双端缩放 RGB 误差最大 `2.65×10⁻⁷`，alpha 逐位相同。对 CPU 和 039 的误差均在门槛内。两端各自的 ROI 对整幅裁块四通道逐位相同。两台机器的合成硬件测试覆盖部分 alpha、透明像素、零 coverage、禁用和参数重绑定。该证据签收 CPU 上传的 AP1 缓冲区组件。 [双端证据](evidence/m2-ap1-cross-device-receipt.json)

接入同设备纹理后，从 `7ccbefc4` 复跑两台实体 GPU。独立计算的引擎源码指纹一致。两端各四份读回摘要和两份生成的 shader 摘要均与本设备的首条组件证据一致。[组件复验](evidence/m2-native-metal-textures.json)

Linux 使用同一 Rust 工具链和经 PAX 提交 ID、SHA-256 校验的源码归档。工作站的物理 GPU 身份另经 PCI 和 `vulkaninfo` 核对。Vulkan loader 与 NVIDIA EGL ICD 配置位于独立测试目录，调用现有 610.43.02 驱动。 [NVIDIA EGL ICD 说明](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/installedcomponents.html)

首条组件的冻结输入来自 `DevelopmentSceneRAWV1Tests/testOptInFrozenAP1SceneWGSLFixture`。用 `RAWMASTER_SCENE_60MP_ARW` 指定本节同源授权原片，`RAWMASTER_SCENE_WGSL_FIXTURE_DIR` 指定新目录。夹具写入 2400×1600 线性 AP1 F32、校准、冻结 039 图、右下 ROI 和四份严格 Rust Metal 参考。`manifest.json` 保存输入、输出及校准摘要。两端用同一份冻结输入。

```sh
cargo run --release --locked --manifest-path Modules/ImageEdit/Cargo.toml \
  --no-default-features --features gpu --example ap1_scene_probe -- \
  --backend metal --graph "$fixture/graph.json" --input "$fixture/input.rgba32f" \
  --width 2400 --height 1600 --roi 1771,1093,629,507 \
  --monitor 04300000-0000-4000-8000-000000000002 \
  --legacy-dir "$fixture/legacy" --output-dir "$metal_report"
```

Linux 实测选择 `--backend vulkan --adapter` 绑定已确认的物理适配器，设置独立 `--output-dir`，并用 `--peer-dir` 传入 Metal 回执及读回结果。随报告保留 `vulkaninfo --summary` 和物理设备、驱动信息。组件比较同后端 RGBAf 裁块位模式，跨实现比较 RGB `2×10⁻⁵ × max(1, |reference|)` 和 alpha 位模式。报告分别标明 CPU 上传、GPU 完成等待、读回及核算缓冲区。 [首条组件入口](../../Modules/ImageEdit/examples/ap1_scene_probe.rs)

#### 混合与覆盖算子

13 种 Layer 模式及 Add、Subtract、Adjust coverage 用 34 组固定 AP1 图比较。覆盖全权重、部分权重、互换输入、自混合、混合顺序和反转遮罩。Apple M4 Max Metal 与 NVIDIA RTX 6000 Ada Vulkan 比较整幅及非居中 ROI 的最终根和监看根，最大缩放 RGB 误差 `2.31×10⁻⁷`，alpha 逐位一致，两端的 ROI 均与各自整幅裁块逐位一致。macOS 同一私有输入纹理上比较严格 wgpu 与 039，最大缩放 RGB 误差 `1.70×10⁻⁷`，通过相同 alpha 和 ROI 门。[两端与原生回执](evidence/m2-layer-blend-coverage.json)

RTX 实机曾在全权重 Add 溢出后被后续 normal 替换时返回有效的原像素。WGSL 允许运行时溢出产生不定结果，因此新增非 normal Layer 在去预乘和混合前先检查安全范围。越界使用现有验证标志的 `0x8`，Metal ABI 返回状态 `7`。两端验证了拒绝和同一程序重试，也保留了选中支仍有限的全权重 Darken 极值。保守范围会拒绝部分 039 仍可求值的有限极值。该证据覆盖新增 Layer 的数值域，旧算子的极值仍需独立验收。[WGSL 浮点规则](https://www.w3.org/TR/WGSL/#finite-math-assumption)

#### macOS 同设备纹理试验

Release 候选 `20261128.140826` 的安装前检查发现，旧路径等待的是在 wgpu 重放图命令之前打开的 HAL 命令缓冲，主机可能提前读取验证标志。80 次 C ABI 复现有 9 次把非法输入误报为成功。`f408410f` 等待 `queue.submit` 返回的实际提交索引，随后才读标志或交付纹理。旧候选保留为定位证据。修复后 120 次独立 C ABI 进程通过，覆盖单像素、全瓦片、不同纹理、非有限输入、拒绝后同一程序重试。14 项原生回归及 IOSurface 真实超时清理用例通过。34 组固定 AP1 也在实体 Metal/Vulkan 复验，保留同设备 ROI 裁块和跨设备像素比较。[完成点复测](evidence/m2-native-metal-completion.json)

Release `20261128.143506` 在打包后二进制上再次执行 80 次拒绝与恢复探针。安装版逐项核对四个 ABI 变体、包签名与四个二进制摘要。隔离资料库和真实窗口启动通过，031 的 17 项原生回归同轮复验通过。[安装回执](evidence/m2-native-metal-release-checkpoint.json) · [031 原型与原生验收](../031-preset-browser/filter-panel-validation.md)

完成点修复后，在 Apple M4 Max 上复跑严格 wgpu 的 24/60 MP 实拍。两种尺寸各跑 FIT 和非居中原寸窗口的最终根、顶层监看，八帧的显示线性 RGBA32F 各在两个 32×32 区域核对 039。最大缩放 RGB 误差 `1.94×10⁻⁶`，alpha 逐位一致。24 MP 实拍曝光到 AppKit drawable 预热 5 次后测 30 次，p50/p95 为 16.85/18.84 ms，达到 038 既有 FIT 门槛。24 MP SDR 队列发布和回读也通过。[完成点复测](evidence/m2-native-metal-completion.json)

24/60 MP 分别从正常 Graph 窗口切换组内节点与全局最终图，均提交到 AppKit drawable，监看时保存和队列冻结取最终根。修复后每种尺寸与选择各预热 5 次、计量 30 次。24 MP 的节点及最终 p50/p95 分别为 22.14/23.72 和 20.68/22.11 ms，60 MP 为 22.08/22.70 和 20.56/21.40 ms。两组均达到 038 既有门槛。节点 p95 仍高于 043 的 20 ms 优化目标。两层禁用祖先的 Metal ABI 对照验证父输入、组内 bypass 和返回保存的最终根。固定实拍 AP1 的两层组最终图另在实体 Metal/Vulkan 验证，最大缩放 RGB 误差 `2.27×10⁻⁷`，alpha 逐位一致。[窗口与双端回执](evidence/m2-group-monitor.json) · [完成点复测](evidence/m2-native-metal-completion.json)

60 MP 以同一 Release 测试二进制、FlashRaw 和瓦片 DRT 直写分别跑严格 wgpu 与严格 039。每条路径一次首轮、五次预热、三十次计量。每个 wgpu 目标保持 35 个瓦片，图派发从 105 次降到 35 次，35 次提交与等待，1 次 pipeline build。图段整帧 CPU 搬运为 0 B，合计回收 140 B 有效性标志。图核算峰值 1,411,744,084 B，039 为 1,458,929,664 B。wgpu 的录制重放、提交及真实完成等待合计 p50 每目标为 55.70–57.26 ms。DRT、编码及发布分别计时。[分项与逐次样本](evidence/m2-native-metal-completion.json)

| 同机 60 MP 路径 | 039 端到端 p50 / p95，ms | wgpu 端到端 p50 / p95，ms | wgpu DAG p50，ms | M2 DAG p50 上限，ms |
| --- | ---: | ---: | ---: | ---: |
| 032 PQ AVIF | 1338.66 / 1418.06 | 1333.70 / 1370.46 | 64.79 | 53.19 |
| 032 SDR JPEG | 544.93 / 566.59 | 549.78 / 625.95 | 65.15 | 53.97 |
| 双目标组件 | 1605.59 / 1736.46 | 1650.43 / 2164.62 | PQ 65.10，JPEG 67.02 | PQ 53.33，JPEG 56.18 |

032 新回执在隔离资料库核对冻结版本、文件摘要和重开。Rust 目录进程中断回归覆盖旧值和 `wgpu` 值。各执行器每格式 36 个成片分别摘要一致，并与此前同后端直写成片逐字节一致。跨执行器的独立全图解码得到同尺寸、10-bit full range CICP 9/16/1 的 PQ AVIF 和 8-bit、ICC 摘要相同的 SDR JPEG。PQ 的 Y/U/V 绝对码值差 p95 各为 1、最大 13/13/12，JPEG 最大 2/3/1。保留这组实际偏差供放行评审。[输出与回执证据](evidence/m2-native-metal-textures.json) · [新旧成片摘要](evidence/m2-native-metal-completion.json)

复跑 60 MP 使用 [原生分项脚本](../../scripts/performance/measure-043-scene-delivery.py) 的 `--backend wgpu` 与 `--backend rust`，两轮各用独立新目录及 `--drt-assembly direct`。严格 wgpu 的四个图阶段中位均超出 M2 上限，双目标组件端到端 p95 超出 M0 的 105%。以下 6 MP 与 96 节点实测及上表替代旧的同设备 wgpu 性能数据。macOS 默认 032 继续使用 039。

- **6 MP。** 原 3000×2000 六节点图接入径向 coverage、交集和有序 Parallel。严格 039 和 wgpu 在 Apple M4 Max 复用同一份已完成初始化的私有 RGBA32F 纹理，分别预热 5 次、交替计量 30 次，只计 `prepareFinal` 到完成。039 p50/p95 为 11.73/12.86 ms，wgpu 为 4.67/4.72 ms，p95 提速 2.72×，达到同构建 1.3× 和历史 10.58 ms 两项门槛。完整 6 MP 读回对 039 的最大缩放 RGB 误差为 `7.45×10⁻⁷`，alpha 逐位一致。两端另用六节点图和同一实拍派生 AP1 验证整幅、非居中 ROI 和两个根，最大跨端缩放 RGB 误差为 `8.95×10⁻⁷`，八次均单派发、零回退。[跨端像素](evidence/m2-six-node-operators.json) · [完成点复测](evidence/m2-native-metal-completion.json)
- **96 节点。** 固定 6 MP 私有输入，96 个节点访问 97 个算子步骤。每次限定一瓦片，039 用冻结程序且无节点和 coverage 缓存命中。039 97 次派发，wgpu 单次派发。各预热 5 次并交替计量 30 次。吞吐按总像素量除以图执行墙钟之和，wgpu 为 039 的 6.05×。p50/p95 为 9.21/10.74 ms，039 为 53.85/56.70 ms。wgpu 中间核算为 32,772 B，039 保守下界为 462,028,800 B，达到 50% 门。两端总核算峰值分别为 194,347,012 和 656,343,040 B。完整输出缩放 RGB 误差最大 `1.67×10⁻⁶`，alpha 逐位一致。[完成点复测](evidence/m2-native-metal-completion.json)
- **60 MP。** 对同一 60 MP 摄影加三节点和同一输出路由，DAG 阶段 p50 须较 M1 下降至少 15%，核对瓦片数、DAG 派发及峰值，维持 038 既有交互门槛。下节验收有界完成等待。

#### Metal 提交完成等待

严格 wgpu 继续等待实际提交索引。提交后的 1 ms 窗口先查询该索引是否完成，每次超时后休眠至多 100 µs，窗口结束后继续阻塞等待同一索引。完成后才读 4 B 有效性标志、核对请求并交接纹理。每瓦片仍只提交一次，`hostWaits` 计完成交接次数。严格 Metal 默认使用此方式，`RAWMASTER_AP1_METAL_LOW_LATENCY_JOIN=0` 可用一直阻塞的路径做对照。开关两臂各 120 次 C ABI 验证通过。全幅 039 像素对照和拒绝后复用的原生回归通过。[逐次回执](evidence/m2-native-metal-bounded-wait.json)

同一 Release 测试构建测严格 Metal 的阻塞对照和两轮有界等待。每轮每路各一次首跑、五次预热、三十次暖测。两个候选轮次共享原片、运行库与测试二进制，汇总 60 个暖样本的结果如下。每轮产生 032 与双目标组件的 PQ、JPEG 各 36 份，所有成片与修复后的直写输出逐字节一致。[分项、峰值、成片及测试二进制摘要](evidence/m2-native-metal-bounded-wait.json)

| 60 MP 路由 | 有界等待端到端 p50 / p95，ms | M0 p95 上限，ms | 阻塞 → 有界等待 DAG p50，ms | M2 DAG p50 上限，ms |
| --- | ---: | ---: | ---: | ---: |
| 032 PQ AVIF | 1319.50 / 1369.85 | 1479.70 | 65.88 → 50.46 | 53.19 |
| 032 SDR JPEG | 541.95 / 626.74 | 631.42 | 65.13 → 50.75 | 53.97 |
| 双目标组件 | 1622.91 / 1693.82 | 1894.91 | PQ 64.80 → 50.67，JPEG 66.70 → 53.91 | PQ 53.33，JPEG 56.18 |

首轮 JPEG p95 为 632.63 ms，追加轮为 626.74 ms。两轮合计通过 M0 的 105% 门槛，四项图阶段 p50 均通过 M2 的 15% 提速门。使用有界等待复测时，6 MP 的 p95 为 5.74 ms，较同构建 039 提速 2.33×。96 节点吞吐为同构建 039 的 5.79×，继续满足中间工作集门槛。macOS 默认交付使用已覆盖完整场景的 039 路径。[原生性能门](evidence/m2-native-metal-bounded-wait.json)

默认有界等待的严格 wgpu 复验中，24 MP FIT 曝光到 drawable 的 p50/p95 为 16.99/18.86 ms。24 MP 和 60 MP 的组内节点 p95 分别为 23.89 和 27.22 ms，返回最终根的 p95 为 21.35 和 26.22 ms。各项维持 038 既有门槛，组内监看继续优化到 043 的 20 ms 目标。[原生窗口复验](evidence/m2-native-metal-bounded-wait.json)

Release `20261128.151111` 安装到 `/Applications/RAWMaster.app`，构建与安装的主程序及三个运行库摘要一致。包签名、隔离目录完整性和真实窗口均通过。安装前对默认有界等待执行 80 次 ABI 拒绝及恢复探针，安装后复验四个变体。031 的 17 项原生滤镜回归通过。[发布回执](evidence/m2-bounded-wait-release-checkpoint.json) · [031 滤镜验收](../031-preset-browser/filter-panel-validation.md)

### M3 · 资源、模型与原寸窗口

Release `20261128.155215` 已安装到 `/Applications/RAWMaster.app`。原寸平移折返控制发布身份的回归、43 项浏览器场景、17 项滤镜原生专项及实拍原图取样均通过。非居中 60 MP 原寸曝光用 ScreenCaptureKit 采样六次，已独立复算。应用严格签名、隔离资料库、原生窗口和安装前后 80+4 次 ABI 拒绝与恢复通过。[Release 回执](evidence/m3-native-pan-release-checkpoint.json) · [原寸交互验收](../036-render-pipeline-performance/validation.md#原寸平移折返) · [滤镜验收](../031-preset-browser/filter-panel-validation.md)

Release `20261128.163440` 已安装并复核严格签名、主程序及三个运行库摘要。原寸、源校验、缓存与协调专项通过 61 项，另有一项既有的显式整幅基图探针保持选跑。实际画布通过工具条首窗、平移、清退与均衡／极速自由缩放验证。滤镜 17 项及安装前后 80+4 次原生 ABI 复验通过。测试使用独立资料库。[安装回执](evidence/m3-budgeted-window-release-checkpoint.json) · [1:1 实测与验收差值](#原寸首窗与位图预算)

- 记录 60 MP 的工作集、缓存、模型、输出和编码及同时驻留的总峰值，按同路由验证总峰值下降。
- 模型逐项验证 tile+halo 的尺度、蒙版对齐、边界、取消和预算诊断。5K/6K 运行真实 1:1 窗口，并检查非居中区域与移动半步。
- 验证异步取消、换片、切组、设备失败、迟到结果和资源释放。受支持的 60 MP 模型通过运行，其他组合给出具体原因。

### M4 · 空间与输出算子

- 各算子提供全图、窗口和导出对照，覆盖零 coverage、接缝、边缘及几何映射。逐类签收双带纹理/清晰度和两遍全图归约。
- 用 037 的输出资产、像素和色彩信号验证 ACES 2 SDR/PQ。旧 v1–v3 通过原成片回放和 035 封存性能门后启用等价路由。
- 对实际 1:1 产品入口复验 50 配方矩阵，报告中位、p95、峰值、实际执行者和回退。矩阵 p95 至多为 M0 同路由基线的三分之二。

### M5 · 041 产品放行

- 在 Linux 实体 Vulkan 用相同冻结素材验证 FlashRaw 输入、相机校准、场景像素、模型适配、每目标一次 ACES 2 输出、编码及回读。
- 按支持的型号、配方、模型和格式覆盖 040/041 队列的预算、取消、续跑、重试和回执重开。服务端能力表与通过的实际组合一致。[041 交付验收](../041-server-image-editing/spec.md#5-验收场景)

## 3. 像素判据

| 对象 | 判据 |
| --- | --- |
| 点运算、coverage 与 blend | 同后端融合与未融合优先逐位对照。逐算子冻结跨后端误差。039 现有 13 种 blend 的 Rust/Swift 对照采用 `2×10⁻⁵ × max(1, abs(reference))`，`8×10⁻⁷` 适用于既有 Swift/CPU 小夹具的绝对误差断言 |
| AP1 与 ROI | F32 保留负值、超白和预乘 alpha。1:1 窗口与整幅对应区域逐位相同，有既有误差的空间算子单独签收 |
| 零 coverage / 禁用 / 零权重 / 中性 | 像素保持原值。可直通路径记录实际直通及零派发 |
| 旧 v1–v3 | 按原配方、原解码、原几何、原成片回放 |
| 模型遮罩和几何 | 全图坐标不一致时提交前拒绝，预览、示波器、交付同判定 |
| 交付文件 | 独立回读 AVIF 位深/CICP/矩阵/PQ 和 SDR ICC/位深，与冻结目标匹配。重开核对实际发布文件的 SHA |

像素报告随算子版本记录最坏通道、位置及输入。跨 GPU 使用已确认的算子误差，颜色和几何分别核对。[039 跨后端测试](../../Tests/RAWMasterImagingTests/RustSceneGraphRendererTests.swift#L54) · [Swift/CPU 夹具](../../Tests/RAWMasterImagingTests/DevelopmentSceneGraphRendererV1Tests.swift#L13)

## 4. 性能判据

- 同机、同源、同质量、同分辨率和同测量区间才能比较性能。冷启动单列，暖态预热 5 次并取至少 30 个样本。记录 p50/p95、分项和总峰值、瓦片、派发、回退和实际后端。
- 阶段墙钟、GPU 时间和等待分别报告，标记区间重叠及 GPU 计时缺失原因。预算报告标明实际分配、采样峰值或保守估算，输出和编码暂存计入总驻留。
- 交付与交互分别报告，批量另列首件、整批及失败/取消。038 FIT 与监看既有门槛为 p50 ≤25.92 ms、p95 ≤210.23 ms，节点监看 p95 ≤20 ms 是 043 后续优化目标。[现有原生门槛](../../Tests/RAWMasterUITests/EditingSceneGraphWindowTests.swift#L241)

### 外部产品对标

每个可比场景分别以 LightFlow 与 Adobe Camera Raw 中较低的 p50 和 p95 为目标。p50 容差为 `max(目标 × 10%, 1 ms)`，p95 为 `max(目标 × 20%, 2 ms)`。对照报告保留版本、设备、系统构建、原片与输出尺寸、交互动作、稳定目标像素和原始计时。暖态每个控件做至少 5 次预热，计量至少 30 次有效变化。软件 GPU、缺测、丢失像素见证及测量边界不同的行单独记录。[035 对照规则](../../scripts/check-lightflow-performance.py) · [三产品采集证据](../../docs/research/camera-raw-parity/evidence/)

下表是同一 Mac16,5、同一 9504×6336 RAW、画布照片 2368×1579 的历史 `screen-photo-response-v1` 复算。计时从各产品的输入标记到 ScreenCaptureKit 中首次达到目标像素变化 20% 的帧，稳定目标帧另经校验。输入分别为原生编辑控制器提交、准备好的 LightFlow 字段按 Return，以及 Camera Raw 字段输入数字后按 Tab。每项各 10 次，表中单位为毫秒，p95 在这个样本量取最大值。六项的历史 p50 和 p95 均在容差内。当前构建须重新采样。[RAWMaster](../../docs/research/camera-raw-parity/evidence/rawmaster-canvas.json) · [LightFlow](../../docs/research/camera-raw-parity/evidence/lightflow-canvas.json) · [Camera Raw](../../docs/research/camera-raw-parity/evidence/camera-raw-canvas.json)

| 控件 | RAWMaster p50 / p95 | LightFlow p50 / p95 | Camera Raw p50 / p95 |
| --- | ---: | ---: | ---: |
| 曝光 | 14.89 / 22.53 | 30.18 / 60.20 | 107.02 / 125.54 |
| 对比度 | 24.16 / 32.71 | 27.67 / 40.37 | 91.72 / 118.53 |
| 高光 | 22.47 / 43.97 | 28.79 / 38.08 | 109.09 / 122.07 |
| 阴影 | 19.51 / 34.52 | 25.34 / 37.70 | 105.84 / 136.32 |
| 黑色 | 22.30 / 29.50 | 28.86 / 40.36 | 98.13 / 138.86 |
| 色调 | 22.88 / 26.89 | 28.89 / 35.60 | 104.91 / 145.59 |

2026-11-28 在 Mac16,5、macOS 27.0.1（26A434）重跑这六项。RAWMaster Release `e419c425` 与 LightFlow `2d41ab1` 各有 5 次未计分预热、2 次 A/B 校准及 30 次暖测，照片 2368×1579。两份原始像素时间戳均通过离线复算。该次 Camera Raw 沿用上表的历史样本。[逐次样本、回放摘要与构建指纹](evidence/m0-screen-photo-response.json) · [验收比较器](../../scripts/performance/compare-043-visible-canvas.py)

| 控件 | RAWMaster p50 / p95 | LightFlow p50 / p95 | 对本轮 LightFlow |
| --- | ---: | ---: | --- |
| 曝光 | 28.70 / 39.31 | 27.40 / 47.78 | 两项均在容差内 |
| 对比度 | 29.31 / 39.00 | 29.41 / 39.77 | 两项均在容差内 |
| 高光 | 51.98 / 75.85 | 29.58 / 37.78 | 两项超出容差 |
| 阴影 | 53.47 / 79.34 | 28.66 / 39.02 | 两项超出容差 |
| 黑色 | 30.87 / 37.19 | 29.03 / 35.62 | 两项均在容差内 |
| 色调 | 30.83 / 41.26 | 27.93 / 36.83 | p50 超出容差 |

用同一个 Release 测试二进制串行跑了 0.8、1.8、0.8 秒三组诊断，每组高光、阴影和色调各 6 次，原始画布帧均独立复算。两轮 0.8 秒里，高光和阴影各 6 次回零均遇到上一笔直方图。提交到旧任务返回分别等待 42.69–61.29 ms 和 40.56–57.35 ms，旧任务返回后 0.33–0.39 ms 内启动当前预览。1.8 秒组的回零均在旧任务返回后提交，两个成功的慢直方图总耗时 1029、1044 ms，显影结束到任务返回占 786、800 ms。两轮 0.8 秒的稳定 ROI 指纹一致，1.8 秒组与它们最多差一个 RGB8 码值。长间隔只用于定位排队。 [诊断结果](evidence/m0-histogram-worker-diagnostic.json)

将清缓存从每块移到每行末尾后，高光和阴影完整直方图的 48 次同步采样分别从 735.84、747.32 ms 降到 226.33、219.43 ms。三组实拍采样的 RGBAf 和全量分箱摘要相同，分数 ROI 的 RGB 与蒙版夹具逐位相同。配对样本的内存采样高水维持约 2.81 GB Metal、3.70 GB 进程 footprint。每块同步返回与取消检查继续生效。0.8 秒短跑中，两项分别各三次回零均未与旧直方图重叠。 [逐行 A/B](evidence/m0-display-histogram-row-ab.json)

`1ebf4e0a` 先复用了两个最近的直方图结果，四项进入 LightFlow 容差，高光、阴影 p95 分别为 75.13 和 77.75 ms。逐行采样落地后，关闭诊断按 0.8 秒、五次预热和三十次计量重新采集。全部 180 次独立复算通过，十二个稳定目标像素摘要与上一构建相同，六项的 p50 和 p95 均进入 LightFlow 容差。[上次复测](evidence/m0-screen-photo-response-retest.json) · [逐行后正式复测](evidence/m0-screen-photo-response-row-retest.json)

| 控件 | RAWMaster 复测 p50 / p95 | LightFlow p50 / p95 | 对本轮 LightFlow |
| --- | ---: | ---: | --- |
| 曝光 | 26.84 / 38.26 | 27.40 / 47.78 | 两项均在容差内 |
| 对比度 | 24.87 / 35.93 | 29.41 / 39.77 | 两项均在容差内 |
| 高光 | 28.22 / 37.51 | 29.58 / 37.78 | 两项均在容差内 |
| 阴影 | 25.69 / 39.11 | 28.66 / 39.02 | 两项均在容差内 |
| 黑色 | 25.45 / 34.50 | 29.03 / 35.62 | 两项均在容差内 |
| 色调 | 27.13 / 39.04 | 27.93 / 36.83 | 两项均在容差内 |

当前三方 FIT 使用同一 9504×6336 RAW、同一 Mac16,5 和 2368×1579 物理画布。RAWMaster Release 候选、LightFlow `2d41ab1` 和 Camera Raw 19.0 每个控件各有 5 次预热、2 次校准和 30 次暖测，540 个正式样本都经原始像素及时间戳回放。六项的较快对手均为 LightFlow，RAWMaster 各项 p50/p95 均进入容差。共同终点为首次达到目标像素变化 20% 的帧。Camera Raw 从首字符发送起计时，包含逐字符输入及 Tab。LightFlow 从已填入完整值的 Return 起计时，RAWMaster 从原生控制器提交完整值起计时。[当前三方报告、逐样本与回放摘要](evidence/m0-current-fit-three-way.json)

| FIT 控件 | RAWMaster p50 / p95，ms | LightFlow p50 / p95，ms | Camera Raw p50 / p95，ms |
| --- | ---: | ---: | ---: |
| 曝光 | 25.85 / 40.29 | 27.40 / 47.78 | 90.18 / 113.73 |
| 对比度 | 24.46 / 36.14 | 29.41 / 39.77 | 90.34 / 122.08 |
| 高光 | 27.06 / 37.05 | 29.58 / 37.78 | 90.55 / 122.00 |
| 阴影 | 25.77 / 37.55 | 28.66 / 39.02 | 99.55 / 127.82 |
| 黑色 | 25.60 / 39.28 | 29.03 / 35.62 | 87.67 / 115.78 |
| 色调 | 28.55 / 40.78 | 27.93 / 36.83 | 90.06 / 127.15 |

与已安装版本 `20261128.212312` 同源的 Release XCTest 原生窗口补测全局纹理、清晰度和去雾，三项均交替采用 0 与 +30。三方使用同一 RAW，物理照片都是 2368×1579，核对了全窗口截图与实际渲染边界。每项每侧有 5 次预热、两次校准和 30 次正式样本，共 270 次经原始帧复算。Camera Raw 另有 90 次独立键入样本，两轮校准像素摘要相同。首次到达各产品自身目标像素变化 20% 的计时结果如下，三项的 p50 和 p95 都超出 LightFlow 容差。[输入、截图与原始帧回放](evidence/m0-current-spatial-fit-three-way.json)

| 全局 FIT 控件 | RAWMaster p50 / p95，ms | LightFlow p50 / p95，ms | Camera Raw 键入 p50 / p95，ms | RAWMaster p95 上限，ms |
| --- | ---: | ---: | ---: | ---: |
| 纹理 | 38.37 / 58.68 | 27.58 / 38.54 | 127.45 / 176.51 | 46.25 |
| 清晰度 | 36.66 / 53.25 | 28.93 / 38.92 | 121.86 / 155.81 | 46.70 |
| 去雾 | 58.77 / 94.94 | 28.53 / 36.98 | 128.80 / 161.10 | 44.37 |

同轮用标定的物理滑杆点击采集 Camera Raw 曝光 0 和 +0.5 EV，从鼠标按下起算。三侧分别复算 30 次，p50/p95 为 RAWMaster 27.40/34.62、LightFlow 29.02/42.98、Camera Raw 38.18/44.77 ms。RAWMaster 达到当前曝光容差。结果保留三种输入的实际开始点，滑杆点击接线独立校验坐标和曝光范围。[曝光逐样本与标定](evidence/m0-current-spatial-fit-three-way.json) · [三方画布核验器](../../scripts/performance/compare-043-visible-canvas.py)

自用 Release `20261129.013459` 的同源码测试构建重新采集同机 60 MP 的四组真实 FIT 画布。每项预热 5 次，独立回放 30 个有效帧记录。LightFlow 与 Camera Raw 使用已冻结的同机同片对照。RAWMaster 曝光 p50/p95 为 25.58/37.41 ms，通过最快对手容差。纹理 38.96/54.59、清晰度 34.66/51.50、去雾 55.99/86.61 ms 仍超出 LightFlow 容差。三项空间控件的 Adobe 对照从第一枚数值键起算，曝光使用物理滑杆。首个精确读回继续使用独立验收。[当前 Release 画布与冻结对照](evidence/m0-current-release-fit-retest.json)

三项空间控件各另采 8 次输入，将画布实际绘制时钟与成像任务关联。12 次回零都提交于上一笔全尺寸直方图运行期间，旧任务返回后 1.1 ms 内开始新预览。从提交至旧任务返回，纹理等待 20.16–26.40 ms、清晰度 18.95–30.98 ms、去雾 66.58–80.82 ms。正向输入的 12 次未遇到上一笔直方图。这组诊断定位了回零等待，后续仍以原 0.8 秒间隔和完整对标签收。[真实画布及任务时序](evidence/m0-spatial-display-histogram-blocking.json)

对 12 次回零逐帧重算显影图退出和直方图返回的两个边界。回零时纹理和清晰度均已进入有限值检查，显影图分别在 0.71–5.71 ms、0.97–6.02 ms 内退出。去雾四次在图内均无这个归约跨度，显影图退出耗时 48.92–60.90 ms。三项显影图退出后至旧直方图返回另耗 17.40–26.32 ms。后续分别计量去雾引导任务的提交与同步，以及分析上下文和暂存资源退出，再复测可见画布。[按帧拆分的取消时序](evidence/m0-spatial-display-histogram-blocking.json)

新增的逐帧诊断仅供显式开启的 XCTest 使用。Release `20261128.220315` 已安装并通过严格验签、隔离资料库自检、真实窗口和 44 次原生 Metal C ABI 检查。前一版本已备份，三份降噪着色器资源与前一版逐件一致。五项跟踪回归、45 项预览协调和诊断回归通过。[安装回执](evidence/m0-spatial-fit-trace-release-checkpoint.json) · [031 原生窗口分段](../031-preset-browser/evidence/camera-raw-integration/viewport-worker-phases.json)

另用同个 Release 测试构建依次关闭、开启、开启、关闭直方图全幅 F16 驻留。四轮各保留三项各 8 个暖输入，原始可见画布复算均通过，各档的稳定 ROI 摘要相同。开启的两轮各实际保留首次解码一次、命中 23 次，全图 FlashRaw 解码次数从对照的 31、30 降到 7、8。四轮每轮的 12 次回零均遇到旧直方图。去雾 p95 在两轮对照为 80.91、110.17 ms，开启时为 100.73、106.44 ms。纹理和清晰度也没有稳定的画布收益，当前采用原路径。[按轮回放与分项](evidence/m0-histogram-resident-f16-abba.json)

对照的 24 次回零都遇到尚未返回的显影图。开启后有 10 次纹理或清晰度回零在显影图返回后仍等待直方图。开启时去雾的 8 次回零全部仍在等待显影图。纹理和清晰度后续可分别核对已物化图的同步采样时间，去雾优先核对原引导与全域验证。性能继续使用可见画布与完整精确两项独立验收。[真实提交与任务时序](evidence/m0-histogram-resident-f16-abba.json)

另用签名发布包的 FlashRaw 0.3.1 和全尺寸 F32 显影测试横向合并采样块。两张 60 MP、24 MP 的实拍 RAW 分别跑纹理、清晰度、全幅和分数 ROI，共 64 次，RGBAf 与所有直方图分箱逐位一致。宽度从 16 增至 128 时，采样 p50 由 65.71 降至 42.91 ms，新建显影任务从进入到析构的 p50 由 515.59 降至 503.45 ms。观察到的最长同步返回由 7.04 增至 8.20 ms。首块返回时取消的单次对照为 4.89、6.85 ms。生产路径仍用 16 像素块，本试验只签收组件计时，画布性能沿用原实测记录。[逐组计时与位比较](evidence/m0-display-histogram-horizontal-batches.json)

37 项精确读回以同一实拍、同机 2400×1600 不透明 sRGB RGBA8 重测。RAWMaster 用显式 canonical 定稿，LightFlow 用锁定的 `2d41ab1`。每项 20 个暖态样本，首次变化、首个精确和最终读回三列均进入 LightFlow 容差。37 组输入各取两次首次状态。RAWMaster 首次变化 p50/p95 为 5.50/18.75 ms，LightFlow 为 7.19/175.22 ms。RAWMaster 首个精确与最终同为 87.36/413.02 ms，LightFlow 同为 24.77/184.44 ms，这两项仍超线。[分项与首次状态](evidence/m0-lightflow-canonical-readback.json)

同一测试构建试用既有的局部蒙版分带、点蒙版区域、锐化分带和去雾分组开关后，首个精确 p50/p95 降到 80.23/355.12 ms。全部 814 对首次与最终 RGBA8 摘要相同，试验进程峰值约 5.26 GB。分项追踪还记录了冷去雾引导生成、局部锐化与降噪的全幅归约。正式口径使用 `RAWMASTER_PANEL_READBACK_SETTLED_TRANSPORT=canonical`。生产视口定稿返回带近似标记的结果，按自己的像素和时延口径验收。[试验数据](evidence/m0-lightflow-canonical-readback.json) · [精确读回入口](../../Tests/RAWMasterImagingTests/PanelDisplayReadbackTests.swift)

另用同一阶段探针按关、开、开、关复测正向去雾的半浮点最小值。两次开启均实际命中原生算子，冷引导图由关闭时的 562 和 874 ms 降至 225 和 369 ms。四轮两档定稿均匹配归档的完整 RGBA8 摘要。此为单控件阶段诊断，37 项首次精确和定稿仍按完整矩阵验收。[实机阶段样本](evidence/m0-native-erosion-qualification.json)

正式 37 项用同一原片、2400×1600 RGBA8 和 LightFlow `2d41ab1` 重跑。每项计两次首次态、保留六次预热和三十次暖测。36 项的三阶段暖态达到容差。局部颗粒的首次变化和首个精确 p95 分别为 7.97、8.61 ms，目标均为 6.73 ms。74 个首次精确状态的 RAWMaster p50/p95 为 86.63/417.86 ms，LightFlow 为 9.52/58.97 ms。收窄试验开关后，RAWMaster 首次精确为 70.79/283.84 ms，局部颗粒首个精确 p95 为 6.92 ms。1184 对首次或计量帧与 222 对预热帧的两份完整 RGBA8 摘要全部一致。[30 次暖测与试验回执](evidence/m0-lightflow-exact-warm30.json)

单独启用 `RAWMASTER_QA_SETTLED_LOCAL_GRAIN_REPLAY=1` 后，同构建按原口径复跑，暖态由 36/37 项通过变为 37/37 项通过。局部颗粒首个精确 p95 由 7.65 ms 降至 2.84 ms，上限 6.73 ms。同一原片与配方已完成精确定稿后，六个预热和三十个暖样本的首帧直接复用该精确像素。两次首次请求仍按原流程取像素。全部 1184 对首次或计量帧与 222 对预热帧的最终 RGBA8 摘要一致。本次两个试验组的 74 个首次精确 p50/p95 分别为 90.78/421.88 和 82.43/473.81 ms，LightFlow 为 9.52/58.97 ms。该试验签收 canonical 暖态重放，生产画布的 viewport 路径继续按自己的像素与时延签收。[精确重放验收](evidence/m0-local-grain-exact-replay.json)

37 项首次状态以相同 Release 阶段探针依次关、开、开、关复测上下文复用。每轮重新打开来源，74 个新状态各走一次交互和精确定稿。四轮交互与定稿的 148 个全幅 RGBA8 摘要逐项一致，两次开启各实际复用 43 次。每臂汇总 148 次定稿，p50/p95 从 80.75/406.20 ms 降至 63.06/398.08 ms，最高进程物理内存从 5.27 GB 升至 5.49 GB。默认启用限于既有的已验证横幅 RAW、原几何和点运算准入范围。每次清理上下文，最多使用八次，授权失效后清退。首次定稿仍超出 LightFlow 容差。局部锐化与降噪一次全域归约仍约 238–253 ms，之后显示位图约 136–145 ms。该轮正向去雾首次引导图约 592 ms。[逐状态与阶段样本](evidence/m0-cleared-context-cold-abba.json) · [复现探针](../../scripts/performance/run-settled-stage-profile.sh)

后续每次只切换一个空间算子的传输，仍按关、开、开、关重开来源并比对完整显示摘要。局部降噪全宽分带将 60 MP 和 50 MP 的两档首次精确定稿 p50 分别从 403.34 和 372.92 ms 降到 221.77 和 221.96 ms。035 已记录同样 334 行分带会放行旧全域校验拒绝的零覆盖极值。当前补测的 21 组注入输入两路一致，旧反例的精确夹具缺失。本轮保留降噪分带试用。正向去雾候选两次冷定稿从 921.48 和 936.99 ms 变为 767.42 和 627.79 ms。其余慢态仍令整体 p95 高于外部门槛，半浮点最小值继续试用。[独立计时与像素](evidence/m0-canonical-spatial-stage-abba.json) · [035 极值原回执](../035-portable-processing-cores/evidence/native-local-detail-full-bands-study.json)

局部锐化改用校验过的原生 R32F 均值。只在 M4 Max 的 9504×6336 或 8640×5760 原方向 FlashRaw 照片上，为 2400 主画布 canonical 定稿启用硬径向单层正锐化。以同一有效的 RGBA16F 源验证 RGB 有限和 α=1，均值逐组验证绝对值不超过 16。受约束的锐化、复合及中性尾段处于 Float32 有限范围。均值在提交、消费与交付前核对源和请求授权，预算不足时沿用原校验。共用的均值纹理额度为 256 MiB。撤销、丢弃旧源和容量上限的原生回归通过。[路径和数值域](../../Sources/RAWMasterImaging/PreviewNativeSharpenMean.swift) · [故障回归](../../Tests/RAWMasterImagingTests/NativeSharpenMeanTests.swift)

同构建按显式关闭、默认、默认、显式关闭复测。四轮分别核对 60 MP 全矩阵的 148 个显示摘要和 50 MP 的 8 个摘要。默认臂每轮只在局部锐化的两个定稿状态实际运行均值。两张原片局部锐化 p50 分别为 418.39→187.87 ms 和 359.45→161.58 ms。60 MP 全矩阵 p50/p95 为 70.64/408.10→67.81/324.96 ms，每臂 148 个定稿，最高进程物理占用 5.47→5.87 GB。此处时钟从定稿请求到完整读回。普通视口按独立画布时钟验收。[原生默认分项与像素](evidence/m0-canonical-spatial-stage-abba.json)

另按正式端到端时钟重跑 37 项，每项两次首态、六次预热和三十次暖测。两版 RAWMaster 的 1184 对正式帧和 222 对预热帧完整 RGBA8 摘要一致。74 次首态的交互输入到首个可见帧为 5.92/19.27 ms，同机 LightFlow 基线为 8.92/22.72 ms。输入到首次精确为 71.78/310.70 ms，LightFlow 为 9.52/58.97 ms，仍超出容差。暖态三项均通过 36/37，剩余局部颗粒的首个可见和首次精确 p95 分别为 7.47 与 7.99 ms，上限 6.73 ms。[同口径分项、逐状态和对照指纹](evidence/m0-canonical-spatial-stage-abba.json)

Release `20261128.170300` 已安装并通过严格验签。安装包的主程序和三个运行库摘要与构建产物一致。24 项锐化与有限值测试、17 项滤镜测试和实拍自由缩放回归全部通过。隔离资料库通过 SQLite 自检并显示 AppKit 窗口，Metal C ABI 在安装前后通过 40+4 次完成点检查。[签名、安装与测试回执](evidence/m0-local-sharpen-release-checkpoint.json)

局部颗粒的精确重放默认用于 2400 主画布 canonical 的合格硬径向单层。当前版本的定稿结果可交付时才授予资格，重放核对完整键、配方、租约和来源代际。由显式定稿缓存返回的结果也会按当前代际授予资格。压力清退未完成时暂停申请重放位图。真实 RAW 回归覆盖了 GPU 完成后被取代、同源第二租约、同源换代、内存压力和来源失效。普通 AppKit 视口采用单独的显示口径。[原生授权回归](../../Tests/RAWMasterImagingTests/PreviewInteractiveProxyTests.swift)

同一 Release 测试构建依次显式关、默认、默认、显式关，两组默认各有 37/37 项暖态通过，两组关闭各有 36/37 项。局部颗粒的暖态首次精确 p95 由关闭组 8.03 和 8.48 ms 降到默认组 1.20 和 1.28 ms，上限 6.73 ms。四轮完整定稿摘要逐项一致，开启组各 30 个暖样本及 6 个预热样本的首帧实测来自同态精确位图。首次新态仍实际渲染，两组默认的端到端首次精确 p95 为 342.08 和 323.98 ms，同一 LightFlow 基线为 58.97 ms。[计时、实机重放阶段及像素](evidence/m0-authorized-local-grain-replay.json)

Release `20261128.172756` 已安装并严格验签。两个交付授权回归、24 项锐化与有限值检查、17 项滤镜和实拍自由缩放均通过。隔离资料库自检和窗口启动通过，安装前后另有 40+4 次原生 Metal ABI 检查。[安装证据](evidence/m0-authorized-grain-release-checkpoint.json)

局部颗粒首次定稿复用 035 的原始 1024 像素校验格。范围是 M4 Max 上两种已测原片尺寸（9504×6336、8640×5760）、原方向 FlashRaw、2400 主画布 canonical 和单独的硬边径向颗粒。先从实际 RGBA16F 上传验证 RGB 有限和 α=1，再依据当前源 pin 缩小归约范围。验证后及显示交付前继续核对请求和来源。比较通道的首次实际渲染、缺少源证明、强制串行和显式关闭均执行全域校验。[原格数值与旧极值](../035-portable-processing-cores/evidence/native-grain-mask-tiles.json) · [源证明与回滚回归](../../Tests/RAWMasterImagingTests/PreviewInteractiveProxyTests.swift)

同构建四轮分别在 60 MP 核对 296 个定稿、在 50 MP 核对 32 个定稿，完整 2400×1600 RGBA8 均匹配归档。60 MP 颗粒 p50 从 290.93 降至 176.53 ms，有限值归约从 206.45 降至 93.55 ms。整矩阵 p50/p95 为 74.37/296.00 和 83.51/299.62 ms，进程物理峰值 5.85 和 5.88 GB。50 MP 初次四轮的候选一轮在多个控件上同时变慢，保留该轮数据。随后八轮带局部降噪对照的交叉复测，每臂八个颗粒定稿，p50/p95 从 239.61/246.84 降至 165.35/196.58 ms。缩小 R32F 颗粒生成范围的独立探针减少了实际派发像素，60 MP 两种强度的完整显示摘要均改变，候选已撤回。[分段、全幅摘要与反例](evidence/m0-opaque-local-grain-validation.json)

正式端到端两轮各验收 37/37 项暖态。每轮核对 1184 对正式帧和 222 对预热帧的完整定稿摘要。74 个首次精确状态的 p50/p95 分别为 71.95/319.35 和 72.91/311.75 ms，同机 LightFlow 为 9.52/58.97 ms，首次精确仍超出容差。当前最慢项是正向去雾首次引导和局部降噪。[正式对标与逐状态证据](evidence/m0-opaque-local-grain-validation.json)

Release `20261128.180152` 已安装并通过严格验签。19 项蒙版与交付授权、3 项原生回滚、24 项锐化与有限值、17 项滤镜和实拍自由缩放均通过。隔离资料库通过 SQLite 自检并显示实际窗口。安装前后通过 40+4 次 Metal C ABI 完成点复验。[构建与安装回执](evidence/m0-opaque-local-grain-release-checkpoint.json)

M4 Max 的 9504×6336 和 8640×5760 已验证 FlashRaw 主画布在 2400 canonical 定稿按原 1024 格归约。局部降噪仍覆盖整个原片，纹理、清晰度和颗粒各用原区域。每组至多 12 个 Core Image 任务，等待每个任务结束，再按原顺序检查标量。单层硬边径向降噪在同源准入后按设备实际内存余量建立一次请求专用上下文，供最终校验和 FIT 共用。完成读回或退出请求时清理。比较通道、低资源、强制串行、标量诊断及显式关闭的实际入口已复验。[运行条件与回执](evidence/m0-grouped-local-validation.json)

四轮同构建对照的 60 MP 296 个定稿及 50 MP 32 个定稿匹配完整 RGBA8。60 MP 局部降噪请求到读回 p50 从 401.79 降至 298.65 ms，有限值和显示分项分别从 242.00 和 143.25 降至 157.95 和 105.00 ms。整矩阵阶段 p50/p95 从 70.57/300.34 降至 62.72/282.27 ms，进程物理峰值 5.877→5.834 GB。50 MP 局部降噪 p50 从 373.97 降至 279.02 ms，峰值 3.217→3.241 GB。两张样片的局部清晰度、纹理和颗粒 p50 也下降。[逐状态像素、分项与阶段时钟](evidence/m0-grouped-local-validation.json)

实际 RAW 的下游准入探针复验了拒绝保留上下文、创建前撤销、源 pin 缺失和正常保留。晚期拒绝继续走原上下文的串行全域校验，各完成分支的 FIT 摘要一致。私有 Metal 纹理在首格和裁尾格分别注入四通道 NaN 或无穷，三种完整校验均拒绝，区域对照可接受。重建的 `rmMaskComposite` 加中性尾段在蒙版内的极值也由三者拒绝。当前重建首格在旧路径通过，035 的历史首格拒绝与原全域等判沿用其归档。[当前拒绝、撤销与资源降级](evidence/m0-grouped-local-validation.json) · [035 归档全域等判](../035-portable-processing-cores/evidence/native-full-validation-cache.json)

同机两轮 37/37 项暖态各达到 LightFlow 容差。每轮 1184 对正式帧及 222 对预热帧的完整定稿摘要与归档一致。74 个首次精确状态的 p50/p95 分别为 70.44/297.78 和 68.44/294.47 ms。同机 LightFlow 为 9.52/58.97 ms，首次精确仍超出门槛。[正式端到端比较](evidence/m0-grouped-local-validation.json)

Release `20261128.182855` 已安装并通过严格验签。48 项蒙版、归约与请求回归、4 项显式回滚、24 项锐化与有限值、17 项滤镜和实拍自由缩放均通过。隔离资料库 SQLite 自检、AppKit 窗口启动与安装前后的 40+4 次 Metal C ABI 完成点检查通过。[安装回执](evidence/m0-grouped-local-validation-release-checkpoint.json)

正向去雾 V2 在已验证的 M4 Max、9504×6336 和 8640×5760、原方向不透明 FlashRaw RGBA16F 及有限空气光范围内启用半浮点最小值和四带 Metal 提交。生成的 R32F 引导和两档全幅 RGBAf 恢复均逐位匹配。原片和引导的 pin 在 FIT 前后均须有效。实机覆盖四带提交后撤销、冷引导发布前失效、暖引导在 FIT 前失效和同源重新取得 pin。硬件、内存和数值准入仍执行实际检查，超出准入时使用原引导路径。两项原生优化分别可用 `RAWMASTER_QA_NATIVE_DEHAZE_HALF_EROSION=0` 和 `RAWMASTER_QA_NATIVE_DEHAZE_GROUPED_EROSION=0` 回滚。[原生阶段及完整数值证据](evidence/m0-native-dehaze-default.json)

同构建按原路径、默认、默认、原路径采四轮，60 MP 的 296 个定稿与 50 MP 的 16 个定稿均匹配完整 RGBA8。冷去雾请求到读回 p50 分别从 985.91、815.09 ms 降至 600.80、452.26 ms，60 MP 的引导图从 640.85 降至 256.06 ms。60 MP 全阶段矩阵 p50/p95 为 68.58/286.38 和 67.90/293.21 ms。正式两轮仍各有 37/37 项暖态达到 LightFlow 容差，分别验证 1184 对正式帧和 222 对预热帧。74 个首次状态的首个精确 p50/p95 分别为 73.96/336.88 和 77.45/298.62 ms，当前首次精确仍超出同机 LightFlow 的 9.52/58.97 ms。[逐状态时钟、阶段及回滚](evidence/m0-native-dehaze-default.json)

Release `20261128.190636` 已安装并通过严格验签。默认源纹理、引导与回退 61 项，直写引导选跑 1 项，锐化和有限值 24 项，滤镜面板 17 项及实拍自由缩放 1 项全部通过。隔离资料库通过 SQLite 自检并显示 AppKit 窗口，安装前后完成 40+4 次 Metal C ABI 复验。[构建、签名与安装回执](evidence/m0-native-dehaze-release-checkpoint.json)

在相同实拍和设备准入范围内，正向去雾的 2400×1600 canonical 定稿默认启用还原范围证明及硬件半幅。两种尺寸各查验六档强度的完整 FP32 半幅和 RGBA8 定稿，完整 R32F 引导及两档全幅 RGBAf 还原也逐位匹配。占满共享半幅预留时，首带零提交，回到经范围证明的原 FIT。两种尾带、原图与引导退役、首带提交及最终读回后的取消均通过实机检查，故障后可重新取得预留并成功重试。同构建复测确认关闭半幅和关闭范围证明各自的回滚路径。[像素、回退和取消回执](evidence/m0-native-dehaze-restore-half.json)

四轮同构建 A/B 的 60 MP 296 个完整定稿及 50 MP 8 个完整定稿像素相同。两张 RAW 的冷去雾定稿 p50 分别由 645.69、521.71 ms 降到 316.36、309.34 ms，复用已生成引导后分别由 297.71、218.71 ms 降到 38.17、35.02 ms。60 MP 全套阶段 p50/p95 为 68.12/297.25 和 65.51/279.57 ms。另两轮正式对标各 37/37 暖态通过，每轮验证 1184 对正式帧与 222 对预热帧。首次精确 p95 分别为 299.47 和 341.38 ms，仍高于 LightFlow 的 58.97 ms。局部降噪、全局降噪、纹理和清晰度仍有全幅重复计算。[逐轮时钟与正式对标](evidence/m0-native-dehaze-restore-half.json)

在所有试验臂均显式开启分组的条件下，分别试用局部空间缓存和纹理分带。两张 RAW 各有 72 个完整画面摘要一致。每种走法对每个控件各有四个定稿样本。60 MP 局部纹理的原路径、空间缓存和纹理分带 p50 分别为 340.95、296.98、304.28 ms，50 MP 对应为 357.78、293.24、325.56 ms。局部清晰度的空间缓存将两张 RAW 的 p50 从 300.88 和 312.60 ms 降至 284.42 和 261.52 ms。两项试用继续按极值、取消和正式矩阵验收。[两源分项与实际命中](evidence/m0-native-dehaze-restore-half.json)

Release `20261128.195700` 已安装并通过严格验签。104 项定向回归全部通过，包含 17 项滤镜与实拍自由缩放。滤镜悬停用例在开关两侧均出现过窗口失焦，保留原失败日志，完整套件复跑通过。隔离资料库、实际 AppKit 窗口和安装前后 40+4 次 Metal C ABI 复验通过。[签名、安装和原生回执](evidence/m0-native-dehaze-restore-half-release-checkpoint.json) · [焦点观察](evidence/m0-native-dehaze-restore-half.json)

局部正向纹理与清晰度的 canonical 定稿现在在已核验的 M4 Max、macOS 27.0.1 和两种原方向 RAW 尺寸上启用单请求上下文缓存。显影器确认原图与源纹理身份后，再核对请求、纹理 pin、至少两个绝对 1024 格和设备余量。局部归约沿用原区域和分组清理，FIT 完成或撤销后清理该上下文。`RAWMASTER_QA_CANONICAL_SPATIAL_MASK_CACHE=0` 可恢复原路径。纹理分带和独立位图等诊断保留各自准入。普通 AppKit 视口按实际绘制另行计量。[代码与准入](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [两源验证](evidence/m0-native-spatial-request-context.json)

两张 RAW 共 16 个强度和位置组合的原尺寸 RGBAf 与 2400×1600 RGBA8 逐位一致。26 组实际 GPU 注入在两种上下文的区域校验得到相同裁决。原区域范围外的四份坏像素仍由原全域对照拒绝。256 MiB、单格、显影器资格不足和晚期容量拒绝均走原上下文。原生归约后、实际位图写回后撤销，以及源 pin 在写回后退役均拒绝交付，后续同源重试通过。[像素、故障及回滚](evidence/m0-native-spatial-request-context.json)

同构建按关闭、默认、默认、关闭各跑一轮。两张 RAW 的交互与定稿共 1184 幅完整像素一致，默认各轮只在正向纹理与清晰度各两档命中。阶段计时从定稿请求至完整像素读回，每个算子、每张 RAW、每侧开关各四个样本。[逐态原始报告与物理内存](evidence/m0-native-spatial-request-context.json)

| 2400×1600 canonical 定稿 | 9504×6336 p50 | 8640×5760 p50 |
| --- | ---: | ---: |
| 局部纹理 | 268.13 → 214.76 ms | 253.61 → 235.97 ms |
| 局部清晰度 | 270.98 → 247.43 ms | 257.20 → 228.03 ms |
| 37 项各两首次状态的全部定稿 p95 | 288.92 → 264.54 ms | 259.13 → 242.86 ms |

两轮无阶段追踪的正式 37 项暖态均通过 LightFlow 门槛，各轮 1184 对正式帧与 222 对预热帧匹配上版。74 个首次状态的输入到精确读回 p50/p95 分别为 76.02/309.97 与 68.25/302.29 ms，LightFlow 为 9.52/58.97 ms。正式首次门继续开放。[正式时钟](evidence/m0-native-spatial-request-context.json)

在上版 Release 上另用两张 RAW 对照全局降噪的原路径、同上下文缓存、已知输入范围证明及两者组合，三项降噪的 192 幅完整画面一致。主片色彩降噪第一次单独建立证明时，从总计 418.45 ms 的证明阶段分离出 62.01 ms 的实际分带归约。这次完整定稿为 672.43 ms。两次组合测量未复现该尖峰，保留试用并继续定位首次建立开销。[四种走法及原始阶段区间](evidence/m0-native-spatial-request-context.json)

独立程序首次加载降噪范围着色器时，运行期编译为 377.93 ms，预编译的 stitchable 库装载为 51.49 ms。后续每侧四个进程的中位数为 29.10 和 26.95 ms。两路实际 GPU 对七个范围边界和非有限输入给出相同结果。这组测量只覆盖着色器装载和小样本正确性，完整 RAW 回放仍待验证。[装载测量与像素](evidence/m0-native-spatial-request-context.json) · [Apple Core Image 内核构建](https://developer.apple.com/videos/play/wwdc2021/10159/)

Release `20261128.203238` 已安装并通过严格验签、隔离资料库自检与真实窗口启动。105 项定向原生回归通过，安装前后完成 40+4 次实际 Metal C ABI 检查。修正后的绘制回执报告实际位图尺寸。经典滤镜两轮 AppKit 测量均达门槛，普通预设两轮中有一轮慢于等价手调。最终测试构建另跑完整 37 项，两轮暖态均全过，首次精确 p95 为 255.74 和 306.27 ms。[构建、窗口及正式回执](evidence/m0-native-spatial-request-release-checkpoint.json) · [滤镜与预设验收](../031-preset-browser/integration-validation.md#11-月-28-日画布回执与窗口复测)

同一 Release 探针用 32 个新进程在两张冻结 RAW 上对照原校验、运行期编译、预编译和预编译加全局缓存。384 幅完整交互和定稿画面逐态一致。主片一次运行期编译耗时 360.06 ms，该次定稿为 708.05 ms。仅预编译的 8 次首次合格库装载为 0.19–9.13 ms，进程重启沿用系统 shader 缓存。最终接线对两张 RAW 完成 1184 幅完整 RGBA8 对照。主片色彩细节和亮度对比首次定稿的中位数分别从 312.94 和 322.52 ms 降至 272.49 和 281.20 ms，原校验和预编译各两次。[阶段与像素证据](evidence/m0-precompiled-raw-noise-proof.json)

Release 将同一 Metal 源及编译回执放进 Imaging 资源包。M4 Max、macOS 27.0.1、原几何已验证的两种 RAW 尺寸，在 2400 canonical 定稿中确认源 pin、实际输入和预算后，才可用预编译内核证明 RAW、基础输入和高斯邻域都满足原下游算子的有限范围。16 组完整 RGBAf 与 FIT 回读，24 个末像素范围检查，以及已提交后取消、源 pin 失效和同源重试均通过。源纹理上传校验结束时的 pin 退役由实拍回归验证，失效请求在回退前停止。资源缺失、摘要不符、内核装载失败及显式关闭等十个条件沿用旧校验，80 幅完整画面与归档一致。[准入、故障和复验](evidence/m0-precompiled-raw-noise-proof.json)

生产接线两轮无阶段追踪的正式测试各有 37/37 项暖态通过 LightFlow 门槛。每轮逐笔核对 1184 对正式帧和 222 对预热帧的交互与定稿摘要。74 个首次状态的精确读回 p50/p95 为 77.50/302.11 和 74.08/300.94 ms，同机 LightFlow 为 9.52/58.97 ms。首次门仍超线，主要慢项包括局部降噪、清晰度和正向去雾。[正式数据](evidence/m0-precompiled-raw-noise-proof.json)

Release `20261128.212312` 已安装，旧包已备份。构建与安装后的可执行文件、运行库和三份着色器资源逐个核对摘要，严格签名、隔离资料库自检、实际窗口和 44 次 Metal C ABI 检查通过。从已安装签名包复制资源到原生探针验证，预编译内核运行和缺失回执回退各有八幅完整画面一致。定向回归共 105 个不同用例通过，其中实拍滤镜悬停在取得焦点的独立宿主中通过。普通预设 SC-02 独立复测仍超线。[安装及逐项回执](evidence/m0-precompiled-raw-noise-release-checkpoint.json)

两张实拍另按关、开、开、关复跑直接位图输出，局部降噪保留同一个 1024 格全域归约流程，清晰度两侧均关闭空间请求缓存。全部 64 幅交互和定稿 RGBA8 摘要逐帧一致。两源的局部降噪端到端定稿 p50 从 332.48、278.48 ms 变为 336.09、270.35 ms，每侧每照四个定稿。双源收益不一致，继续使用现有 CGImage 路径，优先定位原归约和完整图求值的重复工作。[分项与完整像素对照](evidence/m0-local-noise-terminal-qualification.json)

60 MP 单张工作流用同一 Sony RAW、+0.5 EV、9504×6336、8-bit baseline JPEG、4:2:0 和 q95 各取一次首次出片、五次预热及三十次计量。共同计时从产品提交到独立 15 ms 观察第一次看到唯一最终 JPEG 及完整尾标记。RAWMaster 032 默认 039 和直写 DRT 为 441.66/463.92 ms，LightFlow 的原版导出队列为 1819.59/1859.82 ms，实际执行回执为 `rust web-mt 12t`。两边嵌入 ICC 的 4096 色网格转换到 sRGB 后给出相同 RGB 码值。两产品的 JPEG 量化表不同，本轮签收同设置工作流时钟，等质量编码门另外验收。[逐次计时与成片参数](evidence/m0-single-jpeg-lightflow.json)

同设置正式复测保留了新构建与 LightFlow 原版队列各 36 份 JPEG。两边各有两份同配方 PNG16。验证真实位深、4:2:0、ICC、完全不透明及各产品重复解码摘要，再用统一 ICC 转为 RGB16 比较 JPEG 与各自参考图。对 LightFlow q95 锚预定绝对差 ≤0.25 dB PSNR 且 ≤0.001 SSIM。RAWMaster 测过的九档均未满足双门，q95 相对各自无损参考的两个分数更高。同设置时钟通过 LightFlow 本项标准，等保真与 Camera Raw 仍待验收。[逐次计时、成片摘要与九档校准](evidence/m0-jpeg-fidelity-reference.json) · [保真比较器](../032-export-workspace/benchmark/qualify-jpeg-fidelity.py)

| 60 MP q95 | 首次，ms | 暖态 p50 / p95，ms | 对各自 PNG16 的 PSNR / SSIM |
| --- | ---: | ---: | ---: |
| RAWMaster 032 | 535.50 | 439.98 / 486.68 | 45.869 dB / 0.968124 |
| LightFlow 2d41ab1 | 3074.66 | 1825.77 / 1838.37 | 42.793 dB / 0.958384 |

Camera Raw 19.0 通过原生 Save Options 将同源、+0.5 EV 保存为原尺寸 8-bit sRGB baseline JPEG。数值档 4–6 为 4:2:0，7–12 为 4:4:4。两份独立原生 TIFF16 的规范 RGB16 摘要一致。最高已测 4:2:0 档的 PSNR / SSIM 为 41.139 dB / 0.951336，LightFlow q95 锚为 42.793 dB / 0.958384，当前未进入等保真门。Adobe 第 6 档另做 5 次预热和 30 次暖测，从原生 Save 提交到独立 15 ms 观察最终 JPEG 尾标记，p50/p95 为 352.65/405.72 ms。全部文件的图像编码流、ICC 和量化表均与校准样本一致。三方等保真时钟和 Adobe 同口径精确读回仍待验。Photoshop 9504×6336 文档打开继续沿用独立区间。[Adobe 实际头部、保真度与逐次出片时钟](evidence/m0-camera-raw-jpeg-qualification.json) · [Camera Raw 文档打开原始数据](../../docs/research/camera-raw-parity/performance-data.json)

#### 物理 1:1 曝光

同一 Sony 9504×6336 RAW 选非居中源区 `(4096, 3072, 1536, 1024)`，一源像素对应一个屏幕背板像素。两个应用交替提交 0 与 +0.5 EV。每组 5 次预热、2 次像素校准和 30 次暖测，ScreenCaptureKit 计量区域中心 60% 首次达到目标变化 20% 的时刻。所有暖测均以各自的稳定目标帧验证，独立程序复算像素和时间。[各组原始样本及完整截图摘要](evidence/m0-physical-1to1-exposure.json)

| 原寸路径 | 暖态 p50 / p95，ms | RAWMaster 显影窗口 |
| --- | ---: | --- |
| LightFlow `2d41ab1` | 27.99 / 40.60 | |
| RAWMaster 均衡默认 | 118.01 / 135.46 | 7722×3960 |
| RAWMaster 均衡窄窗试验 | 27.29 / 43.28 | 3861×1980 |

窄窗进入 LightFlow 的 30.79/48.73 ms 容差。两个 RAWMaster 路径各以两档曝光核对 3680×1804 完整可见区，RGB 摘要相同。窄窗暖态可在现有缓存留住两档原寸位图，本轮交互和截图合计从 0 次命中变为 39 次命中。该轮基图池关闭，`RAWMASTER_QA_NARROW_ACTUAL_PIXEL_WINDOW=1` 保留供历史对照。[独立回放](../../scripts/performance/replay-rawmaster-screen.py) · [实测几何、像素及缓存](evidence/m0-physical-1to1-exposure.json)

Camera Raw 19.0 在同一 Mac16,5 的 2× 屏上用原生 100% 画布取同一源区。两档曝光分别用七个分散纹理块和 Adobe 原生 9504×6336 TIFF16 配准。两轴都是一个源像素对应一个背板像素，指定源区在采集窗内完整落于 `(544, 868, 1536, 1024)`。两次数字键入被确认窗打断后，改用经标定的两处原生曝光滑杆点击。每次从鼠标按下起计时，下次动作前读回当前曝光，另验稳定目标帧。当前 RAWMaster Release 同源构建的两个基图池配置、Adobe 及 LightFlow 同机封存样本各回放 30 个暖样本。按各产品原生输入到共同显示终点计量，LightFlow 决定 30.79/48.73 ms 的验收限值，两组 RAWMaster 均通过。[三方原寸坐标、回放与逐次时间](evidence/m0-current-three-way-1to1.json)

| 单屏物理 1:1 曝光 | 暖态 p50 / p95，ms |
| --- | ---: |
| RAWMaster，关基图池 | 26.80 / 38.30 |
| RAWMaster，启用空基图池 | 30.23 / 46.01 |
| LightFlow `2d41ab1` | 27.99 / 40.60 |
| Camera Raw 19.0 | 50.86 / 91.17 |

#### 原寸首窗与位图预算

工具条和快捷键的原寸入口在确认当前主画布来源、帧、配方和像素几何后，直接请求物理 1:1 首窗。旧入口在一轮实拍中先处理了 60,217,344 像素的全幅，再处理可见窗。开启实际应用的 RAW 基图池配置后复测，第一份真实请求就使用 5842×2864，提交到首个有效 AppKit 绘制的两次独立观测为 132.57、124.45 ms，旧入口为 243.81 ms。另两档此前未访问的曝光在宽窗分别为 76.73、76.31 ms，预算窗为 60.16、49.34 ms。时钟终点为 AppKit 绘制返回。[请求、原生阶段与两份窗口](evidence/m3-budgeted-actual-pixel-window.json)

均衡、FlashRaw V3 原几何、单主画布使用源租约的位图预算。当前物理视口 3680×1804，两张实际 5842×2864 位图共 133,851,904 B，每侧留边约为可见域的 29%。配置了 RAW 基图池时，在渲染取得许可后检查池当前未占用、来源代际、点运算和设备余量。一次 miss 前最多保留一张同租约同窗口的已交付普通位图。第二租约使记录的位图缓存降到 66,925,952 B，施加内存压力后缓存为 0。普通 FlashRaw 原片纹理的驻留另记为 481,738,752 B。真实 AppKit 平移在留边内及越界立即折返保持同一帧，越界停住后只接受一张覆盖新区域的精确帧。[缓存、压力及平移回执](evidence/m3-budgeted-actual-pixel-window.json)

两种基图池配置各按宽、预算、预算、宽运行，每组五次预热、两个像素校准和三十次计量。各窗口路径汇总六十次，仍使用同源、同非居中 ROI、同 ScreenCaptureKit 时钟。预算窗各轮合计 39 次实际缓存命中，两档曝光的 3680×1804 完整可见区 RGB 摘要与宽窗一致。池关闭组达到 LightFlow 容差。池开启组 p95 进入容差，p50 距 30.79 ms 上限 0.73 ms。[逐次样本和完整可见区见证](evidence/m3-budgeted-actual-pixel-window.json)

| 配置 | 宽窗 p50 / p95，ms | 预算窗 p50 / p95，ms |
| --- | ---: | ---: |
| RAW 基图池关闭 | 126.10 / 144.65 | 27.67 / 40.23 |
| RAW 基图池启用且为空 | 124.74 / 150.06 | 31.52 / 43.38 |

Release `20261128.172756` 同源码复测基图池开启且为空。每臂两轮共 60 次暖态，宽窗 127.49/148.67 ms，默认预算窗 30.18/41.46 ms。LightFlow 基线为 27.99/40.60 ms，默认预算窗两项均进入容差。两档曝光的 3680×1804 完整可见区 RGB 摘要与已归档宽窗一致。同一宽窗轮的 ScreenCaptureKit 流曾中断，整轮重跑后计入，未计入中断数据。[最新四轮与独立像素见证](evidence/m3-budgeted-1to1-retest.json)

5K/6K 实体屏幕、非点算子及多窗在实际 RAW 基图已驻留时的峰值继续验收。

## 5. 放行边界

- 产品路径通过需同时具备同构建、真实设备、像素、性能和该次执行回执。独立组件和合成夹具只记录各自测量区间。
- 严格 wgpu 的支持段按计划执行且回退为零，声明的平台适配段记录其实际执行者。自动模式回退记录段位、原因和次数。
- 回滚用同一配方、来源和目标重放，回执记录实际执行。旧 V1 票据及已发布目标能通过目录重开验证。
- 035、036、037、038 既有验收门继续按对应产品路径复验。M2 以双端实机的首条 WGSL DAG 签收执行器，M5 按完整 RAW 到文件链路开放 041 能力。

2026-11-28 的本机 Release `20261128.131149` 已安装到 `/Applications/RAWMaster.app`。构建与安装包通过严格验签，主程序和三个运行库摘要一致。隔离资料库启动至主窗口，SQLite `quick_check` 通过。安装包内的运行库通过严格原生纹理与嵌套组 ABI 验证。上一版应用包已保存并通过验签。[现行安装回执](evidence/m2-group-release-checkpoint.json) · [首次原生纹理安装回执](evidence/m2-release-checkpoint.json)

## 6. 现有原生基线复现

以下路径来自本机复跑。其他构建使用同 SHA 的授权原片与固定运行库，记录测试实际使用的路径、摘要和跳过原因。历史双目标组件的三节点图与两条 032 队列测试分别留证。

```sh
# 60 MP 摄影加 DAG 的双目标组件，以及现有原生队列入口
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
export RAWMASTER_SCENE_60MP_ARW="$PWD/output/validation/020-development-controls/final-fit-burst/attempt1/DSC05995-authorized-copy.ARW"
export RAWMASTER_SCENE_DELIVERY_EVIDENCE="$(mktemp -d)"
export RAWMASTER_EDITOR_ACCEPTANCE_DIR="$(mktemp -d)"
RAWMASTER_SCENE_BACKEND=rust swift test -c release --jobs 4 -Xswiftc -enable-testing \
  --filter 'testOptInPhotographic60MPFrozenGraphPublishesPQTogetherWithTheEditedSDRDerivative|testOptIn60MP(EditorAndPublishedBatchReceipts|PhotographicPublishedBatchReceipts)'

# 同一三节点工作负载。032 的 PQ/JPEG 与双目标组件各取一次首跑、五次预热和三十次计量。
python3 scripts/performance/measure-043-scene-delivery.py \
  --raw "$RAWMASTER_SCENE_60MP_ARW" --flashraw-library "$RAWMASTER_FLASHRAW_LIBRARY" \
  --output "$PWD/output/spec043-stage-profile-$(date +%Y%m%d-%H%M%S)"

# Rust 场景解析器/执行器
cargo test --release --offline --locked --manifest-path Modules/ImageEdit/Cargo.toml --lib scene::tests
RAWMASTER_SCENE_BACKEND_PERFORMANCE="$PWD/output/spec043-6mp-$(date +%Y%m%d-%H%M%S).json" \
  swift test -c release --jobs 4 -Xswiftc -enable-testing --filter testOptInRustBackendPerformance

# 现有 WGSL 点算子和 Metal 纹理借用
cargo test --release --offline --locked --manifest-path Modules/ImageEdit/Cargo.toml \
  --test named_gpu --test curves_levels_gpu -- --include-ignored --test-threads=1
cargo test --release --offline --locked --manifest-path Modules/ImageEdit/Cargo.toml \
  --features surface-fence-probe --test metal_surface_replay \
  named_surface_timeout_drains_before_retry -- --ignored --exact
```

038 的原生 FIT/监看和 036 的 1:1 分别沿用各自夹具和口径。M2 将首条场景链的锁定输入及两端命令、报告一同归档。[038 原生验证](../038-node-dag-workflow/validation.md#原生可编辑-graph) · [036 1:1 实测](../036-render-pipeline-performance/validation.md#画布接线后的出厂窗口)

画布诊断在 `benchmark-rawmaster-canvas.py` 加 `--diagnostics` 和 `--frames`，并设置 `RAWMASTER_INTERACTION_TRACE` 为新的绝对文件路径。用相同测试包串行跑 `--settle 0.8`、`1.8`、`0.8`，各 `--warmup 5 --samples 6 --operations Highlights Shadows Tint`。输入诊断同时记录 Core Media 和 Dispatch 时钟，画布动作按已确认帧的 ID 和修订与 AppKit 追踪对齐。`*.telemetry.json` 为结束时的现有遥测快照。正式对标关闭这些诊断并使用 30 次计量。

Adobe 原寸测量先在独立 RAW 副本的 100% 画布配准整像素坐标，并检查两档目标的完整区域。`benchmark-acr-canvas.py` 用 `--photo-rect` 传该源区的窗口像素，用 `--exposure-slider` 传零档、+0.5 档的横坐标和滑杆纵坐标。更换窗口或显示器后须重新标定。保留 `--warmup 5 --samples 30 --settle 0.8 --frames` 的帧和输入记录，通过 `replay-acr-screen.py` 复核。[采集脚本](../../scripts/performance/benchmark-acr-canvas.py) · [回放脚本](../../scripts/performance/replay-acr-screen.py)

## 7. 待补证据

- [x] M0 摄影场景 032 准备、发布、目录重开与队列中断恢复
- [x] M0 60 MP 三路同构建分项，固定校准和运行库
- [x] M0 6 MP 5 次预热、每执行器 30 次，原生 FIT/监看及 1:1 复跑
- [x] M0 当前 Camera Raw 和 LightFlow 的同机 FIT 六项，从各自原生输入到共同显示终点，各 30 次暖测进入 LightFlow 容差
- [x] M0 三方物理 1:1 单屏曝光，RAWMaster 关基图池和启用空基图池均进入最快对手容差
- [ ] M0 Adobe FIT 完整值提交的可比时钟、冷态首个精确及等保真成片外部验收
- [ ] M1 瓦片与双目标的像素、性能、预算和发布恢复
- [x] M2 首条 WGSL 场景 DAG 的 macOS Metal 和 Linux 实体 Vulkan 实机组件回执
- [x] M2 6 MP、96 节点、60 MP A/B 和已覆盖算子的 macOS 原生产品路径
- [ ] M3 模型、5K/6K 原寸窗口、异步取消与峰值
- [ ] M4 空间和输出算子证据、50 配方矩阵及 035 封存复跑
- [ ] M5 041 Linux 完整链路与能力表
