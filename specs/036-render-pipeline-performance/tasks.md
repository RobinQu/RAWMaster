# 036 任务

状态：`实现中`。全部条目以 macOS + FlashRaw 0.3.1 + Core Image/Metal 为验收环境。

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
- [x] 尝试代理基图半分辨率解码：一次性省 34 ms，永久改变基图像素（最大 72–99/255），**不采纳**。

## 已否决

- [x] **透出 `flashraw_decode_options.max_dimension` 做解码降采样。** 该字段是安全上限而不是降采样：传 4800 会直接报错。`HALF_SIZE` 去马赛克只把输出减到 25% 像素、耗时几乎不变（39.6 vs 43.5 ms），没有收益。C 包装的改动已撤回。[实测](evidence/flashraw-decode-cost.json)

- [x] **定稿目标长边：保持 2400。** 4096 会把定稿中位从 6.81 ms 推回约 47 ms，越过 25.92 ms 门槛；换来的只是 1.0–1.7× 缩放的清晰度。
- [x] **视口尺寸跟随画布。** 与上一条同一决定：2400 已覆盖当前画布的设备像素；收窄窗口时多算的部分换不到可见收益，加宽显示器时再单独立项。
- [x] **ROI 的可行性先按 2 个配方估算为 1.8×，实测后更正为 2.62×。** 早期探针只测了扫描与物化两个子项，低估了物化在 1:1 中的占比；真正接通窗口后 50 个配方的中位倍数是 2.62×，因此改为实现（传输层已完成）。[实测](spec.md#11-可见窗口传输层已实现画布待接) · [探针](evidence/roi-probe.json)
- [x] **用 `cacheIntermediates` 合并「校验 + 物化」两次求值。** 实测只省 1–3%（`RAWMASTER_QA_CANONICAL_INTERMEDIATE_CACHE=1`，默认关）。

## 待办

- [ ] **区域解码（`use_region`）配合 1:1 窗口。** 解码端没有降采样开关可透出（见[已否决](#已否决)）；唯一剩下的是只解可见区域，省掉一次约 78 ms 的全幅解码。要等窗口接到画布后再评估。
- [ ] **`rawDetails` 的 AHD 代价。** 选 RAW 细节算法时解码从 43.5 ms 升到 118.9 ms（2.7×）；需要确认这条只在显式选择时生效，且 UI 有可见的代价提示。
- [ ] **段级缓存。** 现在参数变化会重跑整条后缀。参考 Alcedo `GraphImageCache` 的 `(节点, 端口) + RuntimeRevision`，以及 LightFlow `render` 自报的 `segments`/`cached`，把后缀切成可按内容键复用的段。核心图像（解码+白平衡+曝光）已由 `FlashRawCanonicalTexturePool` 承担。
- [ ] **`local-defringe` 无缓存重求值 33 ms。** 交互帧 12.6 ms，产品位图缓存下回落到 0.275 ms，说明额外成本在重求值。先看是否重复求值了后缀（`renderInteractiveProxy` 在非 `identityDisplay` 路径上会再走一次 `suffix`）。
- [x] **把窗口接到画布（出厂窗口 = 可见矩形 + 50% 外扩）。** 50 个配方 1:1 中位 191.8 → 111.4 ms（1.72×）。`ImageCanvas` 增加 `window` 与 `canvasPixelSize`：`pixelSize` 仍按整幅画布算（缩放、命中、叠加层坐标不变），位图绘进 `window` 对应的子矩形；`ZoomableImageView` 透传并发布可见窗口。控制器按「可见矩形 + 50% 外扩、量化到 1/32」求服务窗口，仅当可见矩形越出当前窗口时重发 `.detail`，并合并 120 ms 内的连续平移。窗口帧不再能充当整幅缩略图见证，吸管取样时请求整幅帧。
- [ ] **真实窗口走查。** 平移、缩放、叠加层、吸管、裁切在窗口帧上的视觉与手感仍需桌面签收；几何与绘制由 `ImageViewportWindowGeometryTests` 覆盖（含「位图只绘进窗口子矩形」）。
- [x] **窗口化后把有限值扫描也收窄：不做。** 三次连测显示热态 1:1 只有约 12 ms，分带扫描在其中的份额只有十几毫秒；收窄它要把证明从「整幅有限」缩成「窗口有限」，不划算。[热态样本](evidence/native-detail-warm-samples.json)
- [ ] **1:1 的算子成本（下一步的主战场，需要算子重写）。** `DevelopmentAdvancedDetailEngineV3.materialize` 的注释写明它是为了「让 Core Image 对同一个图只选一条 Gaussian 路径」——也就是说这张整幅 F32 纹理是**像素一致性**的前提，窗口帧与整幅帧逐字节相同正依赖它。因此不能靠缩小或改存储模式来省：`.private` 与 `.shared` 实测无差异（`texture` 576/475 → 553/470 ms，噪声内）。要压缩它必须把模糊改成可确定复现的分带实现并带 halo，属于算子级工程。三次连测已经稳定复现：`texture` 480 ms、`dehaze-v2` 1.5 s、`adaptive-brilliance` 3.9 s，热态不降；`dehaze` 与 `adaptive-brilliance` 各自有同形的整幅归约，需要同样的处理。
- [ ] **1:1 首次进入的约 90 ms 冷启动。** 一次性内核编译与全幅原片解码；若只解可见区域（FlashRaw `use_region`）可以摊掉，但只在每张照片第一次进 1:1 时发生，优先级低于算子成本。
- [ ] **Linux。** 本规格只覆盖 macOS。
- [ ] **原型与原生对照走查。** 需要按 AGENTS.md 在 `docs/ui/prototype/index.html` 的暗房视图标注视口定稿与 1:1 原生两态，并附走查截图。
