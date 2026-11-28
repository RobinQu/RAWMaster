# 图像编辑算子优化：调研、实施与验证（2026-11-27）

## 结论

本轮在 `perf/operator-tiled-verification` 分支完成：

1. **RF 传输从逐行 `pwrite` 改为 `mmap` + `msync`。** 60 MP 的 adaptive-brilliance 从 **8.4 s 降到 6.1 s**；dehaze 从 3.69 s 降到 3.47 s（单次，约 6%）。
2. **adaptive-brilliance 的 31×31 map 按上游身份缓存。** 首帧 6.1 s，后续调 strength 的 5 次稳定在 **5.7–6.0 s**；map 阶段从 0.66 s 降到 0。
3. **高级细节的固定输出 tile 经验证逐字节正确，但没有性能收益**，默认回退 inline。真实 4800×3200 窗口 inline/tiled：texture 1322/1341 ms、clarity 1365/1321 ms、local-texture-clarity 2806/2727 ms，差异在 ±3% 内；2400 窗口 tiled 101.8 ms 对 inline 25–40 ms 更慢。
4. 资源库首屏维持 v8 迁移 0.26–0.30 s、首次打开（含建缓存）694/958 ms、温态 160/161 ms，已达标。

上述数据来自历史 CIRAW 构建。合入后的映射写入和原寸 map 缓存分别由 `RAWMASTER_QA_RF_MMAP=1` 和 `RAWMASTER_QA_BRILLIANCE_MAP_CACHE=1` 启用。映射写入先预分配完整工作文件。高级细节固定瓦片继续用于 QA。[合入后的路径和验收](../../specs/036-render-pipeline-performance/spec.md#rf-传输与-adaptive-brilliance-缓存2026-11-27)

## 工业与学术界方法

### 边缘感知滤波

- **Guided filter**（He et al., ECCV 2010 / PAMI 2013）：局部线性模型，O(N) 且与核大小无关；适合 texture/clarity、去雾透射率细化、joint upsampling。是替换“多次大半径 Gaussian”的首选低成本方向。
- **Domain transform**（Gastal & Oliveira, SIGGRAPH 2011）：可分离的边缘保持滤波，递归实现，适合 CPU/GPU 流式处理。
- **Fast local Laplacian**（Aubry et al., 2014; Paris et al., CACM 2015）：用金字塔和重映射替代逐像素 Laplacian，质量好但实现重；2024 年仍有 FPGA 加速工作（arXiv:2402.12407，7.5× CPU）。
- **Bilateral grid**（Chen et al., SIGGRAPH 2007）与 **bilateral solver**（Barron & Poole, 2016）：把双边滤波变成低维网格/稀疏优化；适合需要精确保边的大半径滤波。
- **Deep bilateral / FCN**（Gharbi et al., SIGGRAPH 2017；Chen et al., ICCV 2017）：用轻量网络学习局部算子，适合固定风格的近似；模型/权重和可复现性是代价。
- 2024 年的 **bilateral regularized optimization**（Image and Vision Computing 146, 2024）把空间支持写进正则项，固定点迭代；说明“全局优化 + 快速近似”仍是活跃方向。

对 RAWMaster 的含义：如果 texture/clarity 要继续提速，优先做 **guided filter / domain transform 的 PoC**，用固定 halo 的局部均值/递归实现替代两次全幅 Gaussian；不要继续在 CI 的 band kernel 外围做 tile 拼接。

### 去雾

- **Dark Channel Prior**（He et al., CVPR 2009）：经典、可解释，但透射率需要边缘保持细化；工业实现通常把 airlight/透射率统计放在 proxy，最终 restore 在全分辨率。
- **Color-line / non-local**（Fattal 2014；Berman et al. 2016）：质量更好，但计算/内存更重。
- 2024–2025 的轻量网络：LID-Net（1280×720 125 fps）、Fast no-reference deep dehazing（2K 1000 fps 级别）、FALCON（CVPRW 2025）等；它们把“去雾”变成固定网络推理，适合视频/固定域，不适合需要可解释参数和任意 RAW 的桌面编辑器。
- 对 RAWMaster：现有 `DevelopmentDehazeNativeRfV1` 的 scalar guide + RF restore 已经是“proxy/半全局统计 + 全分辨率 restore”的工业形态；本轮 mmap 直接降低了它的传输成本。下一步应缓存 **与 amount 无关的 scalar guide**，而不是换模型。

### 局部色调映射 / Brilliance

- **Local Laplacian**、**adaptive local tone mapping**（onsemi ALTM 2024 的传感器内实现）、**3D LUT + local Laplacian**（NeurIPS 2023）、2025 的感知优化 TMO：共同点是“低频全局映射 + 高频局部细节”，并把最重的金字塔/映射放在低分辨率或分块。
- RAWMaster 的 adaptive-brilliance 已经是 31×31 map + native tiled joint；剩余成本在 tile 渲染、上下文和 RF 传输，而不是算法公式。先做传输/上下文/缓存，收益确定；换算法只应在质量目标明确后做。

### 系统层方法

- LightFlow 的 `RenderTarget`/segment cache、Alcedo 的 `GraphImageCache`（节点+端口+RuntimeRevision）、FlashRaw 的 region decode：都在做 **按内容键缓存、按目标 ROI 求值、算子融合**。
- 对 RAWMaster：RF 文件传输、map 缓存、tile/context 生命周期是可复用的系统层杠杆；单个算子的数学重写应放在这些都吃完之后。

## 本轮实施与验证

### 1. RF plane：pwrite → mmap

`DevelopmentDehazeRfTransportV1.file` 原来每行一次 `pwrite`；60 MP RGf 平面约 70k 次系统调用。现在：

- `ftruncate` 后 `mmap(MAP_SHARED)`；
- 每个 tile 的行直接 copy 到映射；
- 全部 tile 后 `msync(MS_SYNC)` + `fsync`；
- `RAWMASTER_RF_PWRITE=1` 可回退逐行 pwrite 做 A/B。

60 MP adaptive-brilliance（5 次 strength 变化）：

| | 改前 | 改后 |
|---|---:|---:|
| 单次 total | **8.4 s** | **6.1 s** |
| RF write 合计（5 次） | 9.6 s | 0.7 s |
| context 合计 | 4.3 s | 4.2 s |
| render 合计 | 10.3 s | 9.9 s |

dehaze-v2（4800×3200 detail，单次）：

| | pwrite | mmap |
|---|---:|---:|
| total | 3.69 s | **3.47 s** |

证据：[operator-transport-20261127.json](../../specs/036-render-pipeline-performance/evidence/operator-transport-20261127.json)。

### 2. Brilliance map 缓存

`makeMap` 的 31×31 map 只依赖 brilliance 之前的图像，不依赖 strength。现在 `DevelopmentRendererV3` 用 source identity + 上游 recipe fingerprint 作为 `interactiveMapKey` 传给 `DevelopmentBrillianceAdaptiveV1.apply`；canonical 也命中同一个 `interactiveMaps` 缓存。

5 次 strength 变化：

| | 第 1 次 | 第 2–5 次 |
|---|---:|---:|
| map | 0.66 s | **0** |
| total | 6.1 s | **5.7–6.0 s** |

### 3. 高级细节 tiled：逐字节正确但不采纳

- 1024² 输出 tile + `mmap`/R32F factor，60 MP 整幅/窗口 0 差异；
- 3000×2000 服务级 whole 79 ms / window 27 ms，0 差异；
- 但真实 4800×3200 窗口 inline/tiled 无明显收益，2400 窗口 tiled 更慢；
- 默认已回退 inline；tiled 仅在 `RAWMASTER_QA_ADVANCED_FACTOR_WINDOW=1` 下保留。

## 所有编辑算子的现状

| 算子 | 当前主路径 | 本轮状态 |
| --- | --- | --- |
| exposure / color / curves / LUT | 点运算 + 缓存 | 已接近点运算成本；不重写 |
| texture / clarity | 两次 Gaussian guide + band + full materialize | 1.3 s @4800；tile 不赢，下一步 guided filter/domain transform PoC |
| dehaze v1/v2 | scalar guide + RF restore | mmap 生效；下一步缓存与 amount 无关的 guide |
| adaptive-brilliance | 31×31 map + native tiled joint + RF | **8.4→5.7–6.0 s**；下一步 context 池、finite validation、tile 调度 |
| local detail / lens blur | 局部图 + 现有 tile | mmap 对 RF 路径生效；其余保持 |
| masks | CI + 区域验证 | 已被语义蒙版回归覆盖；不本轮改 |
| grain / vignette / geometry | 点/几何/末段 | 不在瓶颈 |

## 下一步优先级

1. **Brilliance 上下文池**：当前每 tile 新建 CIContext（0.85 s/帧）；用 2–4 个上下文池 + 每 tile `clearCaches` 做 QA A/B，先验证内存上限。
2. **Brilliance tile 调度**：render 仍约 2 s/帧；评估 1024 tile 的并发/流水（当前串行）和 finite validation 的分带成本。
3. **Dehaze guide 缓存**：scalar guide 与 amount 无关；按 source/upstream/airlight 缓存 1 通道 plane，省掉每次 restore 前的 guide 构建。
4. **Texture/clarity 的 guided filter / domain transform PoC**：用固定 halo 的 O(N) 边缘保持滤波替换两次大半径 Gaussian，先在 9504 上测质量和 4 个配方，再决定是否重写。
5. **不要继续 tile CI band**：本轮已证明逐字节门可以过，但 4800 窗口无收益。

## 复现

```sh
# RF mmap / pwrite A/B + brilliance 5 次改参数
RAWMASTER_DETAIL_PROFILE=1 RAWMASTER_DETAIL_PROFILE_HEAVY=brilliance \
RAWMASTER_REGION_PROBE_SOURCE=$PWD/output/performance/acr-benchmark.ARW \
swift test -c release --filter DetailStageProfileProbe

# 高级细节 tiled QA（默认关闭）
RAWMASTER_QA_ADVANCED_FACTOR_WINDOW=1 RAWMASTER_QA_ADVANCED_FACTOR_FULL=1 \
RAWMASTER_QA_ADVANCED_FACTOR_WHOLE=1 ...
```

## 验证

- `swift test -c release --filter RAWMasterImagingTests`：**1,107 项，94 跳过，0 失败**（含 mmap/map 缓存后的完整回归）
- `swift build -c release --product RAWMaster`：通过
- RF profile：60 MP brilliance 5 次 total 6.1/6.0/6.2/6.2/6.2 s（mmap）；map 0.66 s 首帧、0 后续
- dehaze A/B：pwrite 3.69 s，mmap 3.47 s
- tiled advanced detail：60 MP whole/window 0 差异，但默认 inline

## 参考

- He, Sun, Tang. [Guided Image Filtering](https://ieeexplore.ieee.org/abstract/document/6319316) (PAMI 2013; ECCV 2010).
- Gastal, Oliveira. Domain Transform for Edge-Aware Image and Video Processing (SIGGRAPH 2011).
- Paris, Hasinoff, Kautz. [Local Laplacian Filters](https://cacm.acm.org/research/local-laplacian-filters) (CACM 2015).
- Khandelwal et al. [Accelerating Local Laplacian Filters on FPGAs](https://arxiv.org/abs/2402.12407) (2024).
- Yang et al. [Bilateral regularized optimization model for edge-preserving image smoothing](https://www.sciencedirect.com/science/article/abs/pii/S0262885624001355) (Image and Vision Computing 146, 2024).
- He, Sun, Tang. Single Image Haze Removal Using Dark Channel Prior (CVPR 2009).
- Fattal. Dehazing Using Color-Lines (SIGGRAPH 2014); Berman et al. Non-local Image Dehazing (CVPR 2016).
- Qin, Belyaev. [Fast no-reference deep image dehazing](https://link.springer.com/article/10.1007/s00138-024-01601-8) (2024).
- Kim et al. [FALCON: Fast Image Haze Removal](https://openaccess.thecvf.com/content/CVPR2025W/NTIRE/papers/Kim_FALCON_Fast_Image_Haze_Removal_Leveraging_Continuous_Density_Mask_CVPRW_2025_paper.pdf) (CVPRW 2025).
- [Lookup Table meets Local Laplacian Filter](https://proceedings.neurips.cc/paper_files/paper/2023/file/b3a08d179347e33414badadf100e4e8d-Paper-Conference.pdf) (NeurIPS 2023).
- onsemi. [Adaptive Local Tone Mapping](https://www.onsemi.com/company/news-media/blog/industrial/en-us/enhancing-high-dynamic-range-through-adaptive-local-tone-mapping) (2024).
- [GPU Pipeline 与编辑 DAG 的三份参考实现](gpu-pipeline-references.md)：LightFlow / Alcedo / FlashRaw 的系统层缓存与 ROI 设计。
