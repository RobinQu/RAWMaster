# 036 任务

以下既有结果针对 macOS、FlashRaw 与旧 V3 的 Core Image／Metal 路径。场景 AP1 的 Rust／Swift 双跑以及旧 V3 兼容替换采用[联合验收矩阵](../035-portable-processing-cores/roadmap.md#实施顺序与退出条件)。

## 已完成

**取证**

- [x] 核对 LightFlow 发布包的引擎接口与帧循环、Alcedo 的编译计划／节点缓存／渲染意图／解码分辨率、FlashRaw 的 C ABI 开关，写入 [参考实现对照](../../docs/research/gpu-pipeline-references.md)。
- [x] REA `analyze_javascript_application` 复核发布镜像，取 21 个引擎方法的模块 SHA 与源码区间，发现此前未覆盖的多线程绑定 `web-mt/`。[符号取证](evidence/lightflow-rea-symbols.json)
- [x] 更正早前总结：Alcedo 的松手定稿是**整帧 ≤4096**（`kQualityBaseMaxLongEdge`、`source_roi_norm = {}`），ROI 只用于 `Detail`／`ScopeRefresh`；LightFlow 的实测目标也是**整帧 2400**；仓库内 Adobe 基线是整幅 RAW 打开，没有逐控件分辨率证据。

**定稿帧传输**

- [x] `PreviewSettledTransport`（`canonical` / `viewport`）进入 `PreviewResourcePolicy`；`default` 保持 `canonical`。
- [x] 产品 `DevelopmentPreviewService` 构造改用 `viewport`：整帧按 2400 目标求值，交互与定稿共用同一计划与缓存键。
- [x] 无法按视口缩放的算子继续 fail closed 到原生渲染，帧上不标记近似。
- [x] 画布叠加、裁切、吸管接受定稿帧（`EditingController`）。
- [x] 状态行区分 `原生像素` / `预览 … · 原生 …` / `快速预览 … 待完整预览`。
- [x] `PreviewSettledTransportTests`：默认策略不变、定稿帧与交互帧逐字节相同、不可缩放算子回退原生、`detail` 保持原生。

**1:1 可见窗口传输**

- [x] `PreviewViewport.window`（归一化、左上原点）贯通到 `V3PreviewMaterializer`；只在 `detail` 生效，其余质量拒绝窗口。
- [x] `DevelopmentPreviewFrame.window` 让调用方知道这张位图覆盖画布的哪一块；`canonicalPixelSize` 保持整幅。
- [x] 窗口参与缓存键；`testDetailWindowIsExactlyTheCropOfTheWholeNativeFrame` 断言窗口帧与整幅帧同区域逐字节相同。
- [x] 50 个配方的 1:1 矩阵实测：中位 191.8 → 73.1 ms（2.62×），合计 1.51×。[证据](evidence/native-detail-window-scoped.json)

**原生扫描**

- [x] 通用原生有限值扫描接到分带归约传输（默认开，`RAWMASTER_QA_CANONICAL_BANDED_NATIVE_FINITE=0` 回退）：1:1 快 12–46%，输出逐字节不变，接受／拒绝集合有逐模式对照用例。

**测量**

- [x] 交互性能用例记录 `settledTransport`，提供 `RAWMASTER_INTERACTIVE_SETTLED_TRANSPORT=canonical` 复现旧口径。
- [x] 交互性能用例在 `viewport` 下另开 `canonical` 会话，把「定稿 vs 原生定稿」的逐通道差写回 `p99ChannelError` / `maximumChannelError`，避免质量门退化为恒零。
- [x] 交互性能用例新增 `RAWMASTER_INTERACTIVE_DETAIL=1` 的 1:1 探针，记录 `detailMilliseconds`。默认不跑，报文形状不变。
- [x] 50 个控件配方的同机前后实测，见[验证记录](validation.md)。

**极速模式**

- [x] `PreviewPerformanceMode`（均衡/极速）+ `PreviewQualityPolicy`，设置 → 编辑 → 渲染速度，`UserDefaults` 持久化，启动时应用。
- [x] 1:1 拖动降档：极速下拖动使用画布分辨率代理帧，松手回原生。判定由 `PreviewQualityPolicyTests` 固定（均衡不降级、仅叠加层变化不降级）。
- [x] 极速下 1:1 松手先渲染紧贴现可见窗口，250 ms 后后台补齐 50% 外扩。
- [x] 探针 `GaussianRectIndependenceProbe`：证明 `CIGaussianBlur` 与 3σ halo 裁剪在本机逐位矩形无关（半径 4/18/60，307,200 样本最大差 0）。
- [x] 尝试去掉高级细节的整帧冻结：1:1 `texture` 快 1.75×、`clarity` 快 1.37×，但 `DevelopmentSemanticMaskTests` 报 21,635 处蒙版零覆盖像素差异，**撤回**并记录原因。
- [x] **1:1 落帧合并（极速模式）。** 邻域算子每次改参数都付全额（texture 561、clarity 455、brilliance 3800 ms），松手后延迟 250 ms 再渲染原生 1:1，连续调整只付一次。
- [x] **1:1 真实编辑序列测量。** 点运算首次 174 ms、其后 39–41 ms；邻域算子无预热效应。
- [x] **首次 1:1 的空闲预热（极速模式）。** 冷帧 182 ms 里 118 ms 是整幅 RAW 解码+上传；空闲 750 ms 后预热基图，首次 1:1 降到 82 ms，稳态不变。[证据](evidence/detail-prewarm.json)
- [x] 尝试代理基图半分辨率解码：一次性省 34 ms，永久改变基图像素（最大 72–99/255），**不采纳**。

## 已否决

- [x] **透出 `flashraw_decode_options.max_dimension` 做解码降采样。** 该字段是安全上限而不是降采样：传 4800 会直接报错。`HALF_SIZE` 去马赛克只把输出减到 25% 像素、耗时几乎不变（39.6 vs 43.5 ms），没有收益。C 包装的改动已撤回。[实测](evidence/flashraw-decode-cost.json)

- [x] **定稿目标长边：保持 2400。** 4096 会把定稿中位从 6.81 ms 推回约 47 ms，越过 25.92 ms 门槛；换来的只是 1.0–1.7× 缩放的清晰度。
- [x] **视口尺寸跟随画布。** 与上一条同一决定：2400 已覆盖当前画布的设备像素；收窄窗口时多算的部分换不到可见收益，加宽显示器时再单独立项。
- [x] **ROI 的可行性先按 2 个配方估算为 1.8×，实测后更正为 2.62×。** 早期探针只测了扫描与物化两个子项，低估了物化在 1:1 中的占比；真正接通窗口后 50 个配方的中位倍数是 2.62×，因此改为实现（传输层已完成）。[实测](spec.md#11-可见窗口传输层已实现画布待接) · [探针](evidence/roi-probe.json)
- [x] **用 `cacheIntermediates` 合并「校验 + 物化」两次求值。** 实测只省 1–3%（`RAWMASTER_QA_CANONICAL_INTERMEDIATE_CACHE=1`，默认关）。

## 待办

- [ ] **区域解码（`use_region`）配合 1:1 窗口。** 画布已接窗口。先在冷窗测实际被节省的解码和上传，确认 CFA、方向、边缘及校准与整幅一致后才接入。热窗继续复用驻留源。
- [ ] **RF 映射写入。** 历史 CIRAW 样本 60 MP brilliance 8.4→6.1 s、dehaze 3.69→3.47 s。已合入有预分配与清理的 QA 路径，当前 Release 复验逐像素、取消、预算和实拍性能后决定默认值。
- [ ] **Brilliance map 缓存。** 历史 CIRAW 夹具首帧 map 0.66 s，随后缓存命中。QA 按来源捕获和上游配方复用，复验缓存失效和像素后决定默认值。
- [ ] **Brilliance 上下文池 / tile 调度。** 当前 context 0.85 s/帧、render ~2 s/帧；先做 2–4 上下文池的 QA A/B，验证内存上限。
- [ ] **Dehaze guide 缓存。** scalar guide 与 amount 无关；按 source/upstream/airlight 缓存单通道 plane。
- [ ] **Texture/clarity guided filter / domain transform PoC。** 用 O(N) 边缘保持滤波替代大半径 Gaussian，先测 9504 画质与 4 配方。
- [ ] **`rawDetails` 的 AHD 代价。** 选 RAW 细节算法时解码从 43.5 ms 升到 118.9 ms（2.7×）；需要确认这条只在显式选择时生效，且 UI 有可见的代价提示。
- [ ] **段级缓存。** 现在参数变化会重跑整条后缀。参考 Alcedo `GraphImageCache` 的 `(节点, 端口) + RuntimeRevision`，以及 LightFlow `render` 自报的 `segments`/`cached`，把后缀切成可按内容键复用的段。核心图像（解码+白平衡+曝光）已由 `FlashRawCanonicalTexturePool` 承担。
- [ ] **`local-defringe` 无缓存重求值 33 ms。** 交互帧 12.6 ms，产品位图缓存下回落到 0.275 ms，说明额外成本在重求值。先看是否重复求值了后缀（`renderInteractiveProxy` 在非 `identityDisplay` 路径上会再走一次 `suffix`）。
- [x] **把窗口接到画布（出厂窗口 = 可见矩形 + 50% 外扩）。** 50 个配方 1:1 中位 191.8 → 111.4 ms（1.72×）。`ImageCanvas` 增加 `window` 与 `canvasPixelSize`：`pixelSize` 仍按整幅画布算（缩放、命中、叠加层坐标不变），位图绘进 `window` 对应的子矩形；`ZoomableImageView` 透传并发布可见窗口。控制器按「可见矩形 + 50% 外扩、量化到 1/32」求服务窗口，仅当可见矩形越出当前窗口时重发 `.detail`，并合并 120 ms 内的连续平移。窗口帧不再能充当整幅缩略图见证，吸管取样时请求整幅帧。
- [ ] **补足真实窗口走查。** 既有原生 DNG 已复验自由缩放和两个模式的最终像素。实体触控板、平移、叠加、吸管、裁切、窄窗及场景 EDR 的设备矩阵仍需签收。[原生自由缩放](validation.md#自由缩放与原图取样)
- [x] **窗口化后把有限值扫描也收窄：不做。** 三次连测显示热态 1:1 只有约 12 ms，分带扫描在其中的份额只有十几毫秒；收窄它要把证明从「整幅有限」缩成「窗口有限」，不划算。[热态样本](evidence/native-detail-warm-samples.json)
- [x] **引导图窗口化原型：否决（逐字节硬门）。** 引导图本身矩形无关（0.0）、纹理往返无损（0.0），但 band 核输出随输入 extent 变化：texture 最大差 1.6e-5、clarity 最大差 7.0e-4（11.1M 分量）。halo 0→110 全试过。结论：CI 求值的 band 核无法做逐字节窗口化，必须连 band 合成一起接管。
- [x] **窗口化冻结原型：否决。** 探针证明高斯本身矩形无关（整幅 vs 窗口最大差 0.0），但整条 band 图不是（最大差 5.7e-4，11.5M/15.4M 分量有差异）——CI 对子窗口的内部分块改变了取样。要 ROI 安全必须同时自写高斯与 band 合成，属算子级重写。[探针](evidence/advanced-detail-freeze-probe.json)
- [x] **factor/restore 窗口化 PoC：通过。** 真实 9504×6336 ARW：整幅 factor/restore、窗口 restore、texture→clarity 串联、窗口内重算 factor 全部 0 差异（240.9M / 15.36M 分量）。窗口 factor + restore：texture 31.4+43.2 ms，clarity 64.8+50.0 ms；对比整幅 531/609 ms，首帧 5.3–7.1×、改参数约 12×。整幅 factor/restore 只省 15%，因为整幅 materialize 仍在，所以生产化必须窗口化 factor。证据 [advanced-factor-window-probe.json](evidence/advanced-factor-window-probe.json) · [规划](../../docs/research/library-first-screen-and-operator-next-steps.md)。
- [x] **严格全幅 factor 服务级验收。** 整幅/窗口共用全幅 factor，texture band 先物化；3000×2000 TIFF whole vs window 0 差异，9504 ARW 引擎级 0；首次整幅 114 ms、窗口 48 ms（6 MP）。双 band 首帧约 2×，因此仍由 QA 开关控制。
- [x] **固定输出 tile（仅 QA）。** 逐字节 0 差异。真实 4800×3200 窗口 inline/tiled 为 texture 1322/1341、clarity 1365/1321、local 2806/2727 ms，2400 窗口 tiled 更慢。生产继续用 inline，固定 tile 用于像素对照。
- [ ] **扩展 factor 与窗口 restore 的覆盖。** 键包含来源、band、半径和窗口加 halo。双带验证 texture 到 clarity 的依赖与失效，并补蒙版、边缘和 50 配方矩阵。切换以像素等价和同窗收益为条件。
- [ ] **dehaze / adaptive-brilliance 的分块确定性归约。** 先 profile 整幅归约占比，再做带 halo 的分块统计 PoC；不要假设 factor/restore 可直接复用。
- [ ] **1:1 的算子成本（下一步的主战场，需要算子重写）。** `DevelopmentAdvancedDetailEngineV3.materialize` 的注释写明它是为了「让 Core Image 对同一个图只选一条 Gaussian 路径」——也就是说这张整幅 F32 纹理是**像素一致性**的前提，窗口帧与整幅帧逐字节相同正依赖它。因此不能靠缩小或改存储模式来省：`.private` 与 `.shared` 实测无差异（`texture` 576/475 → 553/470 ms，噪声内）。要压缩它必须把模糊改成可确定复现的分带实现并带 halo，属于算子级工程。三次连测已经稳定复现：`texture` 480 ms、`dehaze-v2` 1.5 s、`adaptive-brilliance` 3.9 s，热态不降；`dehaze` 与 `adaptive-brilliance` 各自有同形的整幅归约，需要同样的处理。
- [x] **1:1 首次进入的冷启动。** 已由极速模式的空闲预热解决（182 → 82 ms）。剩余约 50 ms 是规范上下文首次创建与内核编译，属一次性成本。
- [ ] **Linux。** 本规格只覆盖 macOS。
- [x] **原型与原生自由缩放对照。** 现有暗房入口覆盖 FIT、倍率和 1:1。后续真实窗口签收沿用同一路线。[覆盖表](../../docs/ui/coverage.md#编辑与交付) · [走查](validation.md#自由缩放与原图取样)
