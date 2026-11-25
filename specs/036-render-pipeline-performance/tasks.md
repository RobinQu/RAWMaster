# 036 任务

状态：`实现中`。全部条目以 macOS + FlashRaw 0.3.1 + Core Image/Metal 为验收环境。

## 已完成

- [x] 取证 LightFlow 发布包的引擎接口与帧循环、Alcedo 的编译计划／节点缓存／渲染意图、FlashRaw 的 C ABI 开关，写入 [参考实现对照](../../docs/research/gpu-pipeline-references.md)。
- [x] REA `analyze_javascript_application` 复核发布镜像，取 21 个引擎方法的模块 SHA 与源码区间，发现此前未覆盖的多线程绑定 `web-mt/`。[符号取证](evidence/lightflow-rea-symbols.json)
- [x] `PreviewSettledTransport`（`canonical` / `viewport`）进入 `PreviewResourcePolicy`；`default` 保持 `canonical`。
- [x] 产品 `DevelopmentPreviewService` 构造改用 `viewport`；交互评估与定稿评估共用同一 `PreviewInteractiveProxyV3` 计划与缓存键。
- [x] 无法按视口缩放的算子继续 fail closed 到原生渲染，并在帧上不标记近似。
- [x] 画布叠加、裁切、吸管接受定稿视口帧（`EditingController`）。
- [x] 状态行区分 `原生像素` / `预览 … · 原生 …` / `快速预览 … 待完整预览`。
- [x] 新增 `PreviewSettledTransportTests`：默认策略不变、视口定稿与交互帧逐字节相同、不可缩放算子回退原生、`detail` 保持原生。
- [x] 交互性能用例记录 `settledTransport` 并提供 `RAWMASTER_INTERACTIVE_SETTLED_TRANSPORT=canonical` 复现旧口径。
- [x] 50 个控件配方的同机前后实测，见[验证记录](validation.md)。

## 待办

- [ ] **1:1 只渲染可见 ROI。** 现在 `detail` 仍是整帧原生构图。参考 Alcedo `RenderType.DETAIL_ROI_PREVIEW`：按视口 `{x, y, scale, target}` 求源 ROI，邻域算子按 halo 外扩。需要先决定 `canonicalPixelSize` 之外的 ROI 身份如何进入缓存键。
- [ ] **解码端降分辨率。** 给 `Sources/CFlashRaw` 增加 `max_dimension` 透出（底层 `flashraw_decode_options.max_dimension` 已支持），让视口帧不必先解全尺寸 CFA。参考 Alcedo `DecodeRes`。需要单独的像素差记录，因为它是解码头而非重采样差。
- [ ] **视口尺寸跟随画布。** 现在固定 2400 px。收窄窗口或外接显示器时应在合理的 1×/2× 档位内跟随，避免放大。
- [ ] **`local-defringe` 无缓存重求值 33 ms。** 交互帧 12.6 ms，产品位图缓存下回落到 0.275 ms，说明额外成本在重求值。先看是否重复求值了后缀（`renderInteractiveProxy` 在非 `identityDisplay` 路径上会再走一次 `suffix`）。
- [ ] **段级缓存。** 现在参数变化会重跑整条后缀。参考 Alcedo `GraphImageCache` 的 `(节点, 端口) + RuntimeRevision`，以及 LightFlow `render` 自报的 `segments`/`cached`，把后缀切成可按内容键复用的段。当前核心图像（解码+白平衡+曝光）已由 `FlashRawCanonicalTexturePool` 承担。
- [ ] **原生定稿的重复求值。** 原生路径仍然先 `validateFinite` 再 `createCGImage`，整棵图算两遍。改为一次物化到私有纹理、在纹理上归约。这条只影响不可缩放算子与导出。
- [ ] **Linux。** 本规格只覆盖 macOS。
- [ ] **原型与原生对照走查。** 需要按 AGENTS.md 在 `docs/ui/prototype/index.html` 的暗房视图标注视口定稿与 1:1 原生两态，并附走查截图。
