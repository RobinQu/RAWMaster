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

### M2 · 首条 WGSL 场景 DAG 与融合

| 验收项 | 必须提供的证据 |
| --- | --- |
| 固定输入 | 同一源码提交、锁定依赖、算子版本、冻结场景图和资源摘要。固定实拍 RAW 及其校准产生的 AP1 F32 夹具，记录 AP1 表面、全图及非居中 ROI。首条包含曝光、EV 曲线、coverage 和有序 Layer |
| macOS 实机 | 物理 GPU，执行回执 `executor=wgpu`、`graphicsAPI=metal`，严格 WGSL 段回退为零。记录型号、系统、图形驱动环境和设备能力 |
| Linux 实机 | 物理 GPU，执行回执 `executor=wgpu`、`graphicsAPI=vulkan`，严格 WGSL 段回退为零。记录 GPU、驱动版本和设备能力。软件 Vulkan 结果作为额外正确性证据 |
| 两端像素 | 参考 CPU、039 原生 Metal 和两端 WGSL 的同输入对照。覆盖负值、超白、alpha、零覆盖、禁用、非居中 ROI 与整幅裁块；核对监看根与冻结最终根 |
| macOS 产品路径 | 24/60 MP 原生 FIT 到 drawable、组内监看、原寸取景与 032。核对同设备纹理借用、同步、等待、整帧上传/读回和实际峰值 |

首条场景路径必须有以上双端实机证据再启用。M5 继续签收 Linux 的 RAW 到成片产品闭环。

- **6 MP。** 同机以 M0 的 039 当前执行器为参照，暖态图 p95 至少 1.3× 提速。
- **96 节点。** 冻结图结构、ROI、缓存条件和未融合对照。吞吐 ≥2×，峰值中间工作集 ≤50%。中间工作集计量求值期间的临时纹理和缓冲，固定输入、终端输出及总峰值单列。
- **60 MP。** 对同一 60 MP 摄影加三节点和同一输出路由，DAG 阶段 p50 较 M1 下降至少 15%，核对瓦片数、DAG 派发及峰值。038 交互继续通过原生既有门槛。

### M3 · 资源、模型与原寸窗口

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

2026-11-28 在 Mac16,5、macOS 27.0.1（26A434）重跑这六项。RAWMaster Release `e419c425` 与 LightFlow `2d41ab1` 各有 5 次未计分预热、2 次 A/B 校准及 30 次暖测，照片 2368×1579。两份原始像素时间戳均通过离线复算。Camera Raw 当前仍用上表的历史样本，等独立测试副本完成新采集后再判定三产品结果。[逐次样本、回放摘要与构建指纹](evidence/m0-screen-photo-response.json) · [验收比较器](../../scripts/performance/compare-043-visible-canvas.py)

| 控件 | RAWMaster p50 / p95 | LightFlow p50 / p95 | 对本轮 LightFlow |
| --- | ---: | ---: | --- |
| 曝光 | 28.70 / 39.31 | 27.40 / 47.78 | 两项均在容差内 |
| 对比度 | 29.31 / 39.00 | 29.41 / 39.77 | 两项均在容差内 |
| 高光 | 51.98 / 75.85 | 29.58 / 37.78 | 两项超出容差 |
| 阴影 | 53.47 / 79.34 | 28.66 / 39.02 | 两项超出容差 |
| 黑色 | 30.87 / 37.19 | 29.03 / 35.62 | 两项均在容差内 |
| 色调 | 30.83 / 41.26 | 27.93 / 36.83 | p50 超出容差 |

用同一个 Release 测试二进制串行跑了 0.8、1.8、0.8 秒三组诊断，每组高光、阴影和色调各 6 次，原始画布帧均独立复算。两轮 0.8 秒里，高光和阴影各 6 次回零均遇到上一笔直方图。提交到旧任务返回分别等待 42.69–61.29 ms 和 40.56–57.35 ms，旧任务返回后 0.33–0.39 ms 内启动当前预览。1.8 秒组的回零均在旧任务返回后提交，两个成功的慢直方图总耗时 1029、1044 ms，显影结束到任务返回占 786、800 ms。两轮 0.8 秒的稳定 ROI 指纹一致，1.8 秒组与它们最多差一个 RGB8 码值。长间隔只用于定位排队。 [诊断结果](evidence/m0-histogram-worker-diagnostic.json)

`1ebf4e0a` 复用两个最近的直方图结果，命中时保留预览上下文。14 项 Release 回归通过。按原 0.8 秒协议复测时，六项的目标像素指纹均一致。曝光、对比度、黑色和色调的两项指标进入新 LightFlow 容差，高光和阴影回零长尾仍在。[RAWMaster 复测](evidence/m0-screen-photo-response-retest.json)

| 控件 | RAWMaster 复测 p50 / p95 | LightFlow p50 / p95 | 对本轮 LightFlow |
| --- | ---: | ---: | --- |
| 曝光 | 29.02 / 36.24 | 27.40 / 47.78 | 两项均在容差内 |
| 对比度 | 25.99 / 39.98 | 29.41 / 39.77 | 两项均在容差内 |
| 高光 | 50.89 / 75.13 | 29.58 / 37.78 | 两项超出容差 |
| 阴影 | 51.94 / 77.75 | 28.66 / 39.02 | 两项超出容差 |
| 黑色 | 27.33 / 35.86 | 29.03 / 35.62 | 两项均在容差内 |
| 色调 | 29.32 / 40.80 | 27.93 / 36.83 | 两项均在容差内 |

LightFlow 的 24.35/25.92 ms 为 74 配方 2400×1600 RGBA8 精确读回的首次精确与最终结果中位上限。Camera Raw 的 9504×6336 Photoshop 文档打开在独立区间记录。三方同口径精确读回、1:1 窗口与 032 RAW 到成片的最快水平仍需取证。[035 封存矩阵](../035-portable-processing-cores/acceptance.md) · [Camera Raw 工作流原始数据](../../docs/research/camera-raw-parity/performance-data.json)

## 5. 放行边界

- 产品路径通过需同时具备同构建、真实设备、像素、性能和该次执行回执。独立组件和合成夹具只记录各自测量区间。
- 严格 wgpu 的支持段按计划执行且回退为零，声明的平台适配段记录其实际执行者。自动模式回退记录段位、原因和次数。
- 回滚用同一配方、来源和目标重放，回执记录实际执行。旧 V1 票据及已发布目标能通过目录重开验证。
- 035、036、037、038 既有验收门继续按对应产品路径复验。M2 以双端实机的首条 WGSL DAG 签收执行器，M5 按完整 RAW 到文件链路开放 041 能力。

2026-11-28 的本机 Release `20261128.104222` 已安装到 `/Applications/RAWMaster.app`。构建和安装包均通过严格签名校验，应用与三个运行库摘要一致。用隔离资料库启动至主窗口并验证数据库。旧应用、偏好及默认目录数据库已备份。本包交付 032 回执修复、031 滤镜与当前原生性能改动，后续阶段按本页矩阵继续签收。[安装与构建证据](evidence/m0-release-checkpoint.json)

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

## 7. 待补证据

- [x] M0 摄影场景 032 准备、发布、目录重开与队列中断恢复
- [x] M0 60 MP 三路同构建分项，固定校准和运行库
- [x] M0 6 MP 5 次预热、每执行器 30 次，原生 FIT/监看及 1:1 复跑
- [ ] M0 Camera Raw 当前版本的同机基线与三产品外部通过
- [ ] M1 瓦片与双目标的像素、性能、预算和发布恢复
- [ ] M2 首条 WGSL 场景 DAG 的 macOS Metal 和 Linux 实体 Vulkan 实机回执
- [ ] M2 6 MP、96 节点、60 MP A/B 和 macOS 原生产品路径
- [ ] M3 模型、5K/6K 原寸窗口、异步取消与峰值
- [ ] M4 空间和输出算子证据、50 配方矩阵及 035 封存复跑
- [ ] M5 041 Linux 完整链路与能力表
