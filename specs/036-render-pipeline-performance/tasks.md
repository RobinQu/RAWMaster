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

**原生扫描**

- [x] 通用原生有限值扫描接到分带归约传输（默认开，`RAWMASTER_QA_CANONICAL_BANDED_NATIVE_FINITE=0` 回退）：1:1 快 12–46%，输出逐字节不变，接受／拒绝集合有逐模式对照用例。

**测量**

- [x] 交互性能用例记录 `settledTransport`，提供 `RAWMASTER_INTERACTIVE_SETTLED_TRANSPORT=canonical` 复现旧口径。
- [x] 交互性能用例在 `viewport` 下另开 `canonical` 会话，把「定稿 vs 原生定稿」的逐通道差写回 `p99ChannelError` / `maximumChannelError`，避免质量门退化为恒零。
- [x] 交互性能用例新增 `RAWMASTER_INTERACTIVE_DETAIL=1` 的 1:1 探针，记录 `detailMilliseconds`。默认不跑，报文形状不变。
- [x] 50 个控件配方的同机前后实测，见[验证记录](validation.md)。

## 已否决

- [x] **定稿目标长边：保持 2400。** 4096 会把定稿中位从 6.81 ms 推回约 47 ms，越过 25.92 ms 门槛；换来的只是 1.0–1.7× 缩放的清晰度。
- [x] **视口尺寸跟随画布。** 与上一条同一决定：2400 已覆盖当前画布的设备像素；收窄窗口时多算的部分换不到可见收益，加宽显示器时再单独立项。
- [x] **1:1 按可见 ROI 裁剪。** 探针实测窗口占原生 6.38%，扫描 4.8×、物化 2.2×，但端到端只 1.8×（154.8 → ~87 ms）：算子自身在整幅上的邻域／全局归约不会因请求区块而下降。改造需要 pan/zoom 可见矩形、窗口缓存键、region 贯通阶段校验与非整帧 extent 不变量，不满足「有效且不大重构」的门槛。[决策与数据](spec.md#已否决11-按可见-roi-裁剪) · [探针证据](evidence/roi-probe.json)
- [x] **用 `cacheIntermediates` 合并「校验 + 物化」两次求值。** 实测只省 1–3%（`RAWMASTER_QA_CANONICAL_INTERMEDIATE_CACHE=1`，默认关）。

## 待办

- [ ] **解码端降分辨率。** 给 `Sources/CFlashRaw` 增加 `max_dimension` 透出（底层 `flashraw_decode_options.max_dimension` 已支持），让拖动与松手不必先解全尺寸 CFA。参考 Alcedo `DecodeRes`。需要单独的像素差记录，因为它是解码头而非重采样差。
- [ ] **段级缓存。** 现在参数变化会重跑整条后缀。参考 Alcedo `GraphImageCache` 的 `(节点, 端口) + RuntimeRevision`，以及 LightFlow `render` 自报的 `segments`/`cached`，把后缀切成可按内容键复用的段。核心图像（解码+白平衡+曝光）已由 `FlashRawCanonicalTexturePool` 承担。
- [ ] **`local-defringe` 无缓存重求值 33 ms。** 交互帧 12.6 ms，产品位图缓存下回落到 0.275 ms，说明额外成本在重求值。先看是否重复求值了后缀（`renderInteractiveProxy` 在非 `identityDisplay` 路径上会再走一次 `suffix`）。
- [ ] **1:1 的算子成本。** `texture` 约 0.3 s、`dehaze` 约 1.5 s 是整幅邻域／全局归约，只能逐算子做邻域分解与分带，与传输层无关。
- [ ] **Linux。** 本规格只覆盖 macOS。
- [ ] **原型与原生对照走查。** 需要按 AGENTS.md 在 `docs/ui/prototype/index.html` 的暗房视图标注视口定稿与 1:1 原生两态，并附走查截图。
