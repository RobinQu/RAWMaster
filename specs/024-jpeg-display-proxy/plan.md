# JPEG 显示代理评估与管理方案

## 结论

采用“RAW／线性浮点代理为主，JPEG 仅作可丢弃显示缓存”的双层策略。

JPEG 不替代 RAW、线性 RGBAf 交互代理、完整显影、保存或导出输入。当前连续缩放性能问题来自重复提交原生渲染，修复后，JPEG 对连续缩放手势本身不再提供同量级收益。它主要缩短首次显示、切换照片和缓存未命中的等待。

FlashRaw Metal 适合作为独立显示代理的加速候选，但其颜色和默认显影尚不兼容 Core Image；线性 F32 的 Metal 内存代价也高于 SIMD。编辑热操作继续复用缓存基图与现有 GPU 后缀，不按滑杆重新解码 RAW。

## 实测依据

样本为 9504 × 6336 的 Sony RAW，代理输出为 2400 × 1600、sRGB、JPEG 质量 0.90。

| 项目 | 冷样本 | 后续 4 次中位数 |
| --- | ---: | ---: |
| RAW 解码并缩放 | 569.6 ms | 566.4 ms |
| JPEG 解码 | 50.8 ms | 47.8 ms |

- JPEG 文件大小为 833,166 字节，生成耗时约 581 ms。
- 解码阶段加速约 11.9 倍。
- 该测量不包含完整编辑操作，也不证明 JPEG 与线性 HDR 显影具有相同像素语义。
- 纹理、清晰度、去朦胧、自适应鲜明度等后续 GPU 运算仍需执行；当前干净环境下，完整交互操作约为 33–158 ms，因此不能把 11.9 倍解码收益直接等同于整体编辑加速。

报告：`output/performance/jpeg-proxy-evaluation-20261120/jpeg-proxy-evaluation.json`。

## 使用边界

### 第一阶段：只作中性显示缓存

用于资料库单张浏览、编辑模式进入时的占位图，以及线性代理尚未准备好时的快速呈现。

- 使用中性显影结果，烘焙 EXIF 方向和输出尺寸。
- 统一为 8 位、sRGB、质量 0.90 的 JPEG；长边按显示挡位选择，基准验收尺寸为 2400 像素。
- 明确标记为近似预览；线性代理完成后替换。
- 不用于最终调整结果、色域敏感校验、像素级审片、100% 实际像素、保存或导出。
- 含 Alpha、HDR 或其他无法由该 JPEG 契约无损表达的输入，继续走现有路径。

### 第二阶段：调整预览候选，需另行验收

只有在第一阶段证明稳定后，才评估将 JPEG 作为部分点运算的输入。任何此类路径必须重新进行颜色、曲线、白平衡和直方图一致性测试，不能直接复用 RAW 的 `sourceIsRAW` 参数语义。

局部调整仍按当前线性代理执行，JPEG 不得作为这些算子的输入捷径。

### 原生缩放与金字塔

单张 2400 像素 JPEG 不满足 100% 原生像素查看。若后续仍需优化高倍缩放，应另行评估分级瓦片缓存，例如 2400、4800 和原生尺寸瓦片，而不是放大一张 JPEG。瓦片方案不属于第一阶段。

## 缓存键与版本

中性代理使用以下字段共同确定身份：

- 原文件内容 SHA-256；
- 解码器版本与解码参数契约；
- EXIF 方向和代理算法版本；
- 输出长边、像素格式、色彩空间及 JPEG 质量。

建议格式版本为 `display-proxy-v1`。版本号变化即使用新缓存命名空间，旧文件只参与 LRU 回收，不进行原地改写。

若未来支持调整结果代理，必须额外包含完整配方指纹，不能与中性代理混用。

## 存储布局

缓存位于系统 Caches 下的应用专属目录，例如：

```text
io.robinqu.RAWMaster/DisplayProxy/v1/<内容哈希前两位>/<完整内容哈希>/2400-q90.jpg
io.robinqu.RAWMaster/DisplayProxy/v1/<内容哈希前两位>/<完整内容哈希>/manifest.json
```

清单记录源文件指纹、代理契约、尺寸、字节数、创建时间、最近使用时间及文件校验信息。缓存不是资料库事实来源，删除后必须能够重新生成，不随项目导出，也不上传。

## 写入与验证

1. 在独立临时文件中完成编码和解码复核。
2. 校验 JPEG 魔数、可解码性、输出尺寸、字节数和清单字段。
3. 使用原子重命名发布，禁止其他读取者看到半文件。
4. 每次使用前验证源文件身份和代理清单；损坏或不匹配的文件删除并重新生成。
5. 文件变化、解码契约变化或方向变化必须使用新身份，旧代理不得继续显示。
6. 生成任务支持取消、同键去重及失败退避，避免重复解码同一照片。

## 批量吞吐与 LRU 抖动

使用 3 张不同的 RAW 按真实并发闸门生成 2400 × 1600、质量 0.90 的 JPEG，并逐张释放资源：

| 实际并发 | 3 张总耗时 | 吞吐 | 驻留内存增长峰值 |
| ---: | ---: | ---: | ---: |
| 1 | 1999.6 ms | 1.50 张／秒 | 约 406 MB |
| 2 | 1197.0 ms | 2.51 张／秒 | 约 551 MB |
| 3 | 776.0 ms | 3.87 张／秒 | 约 724 MB |

- 后续并发受系统文件缓存预热影响；内存采样间隔为 20 ms，可能漏掉更短峰值。
- 三张代理平均约 1.07 MB。1 万张约占 9.94 GiB，按并发 3 估算需约 43 分钟，按并发 1 估算需约 111 分钟。
- 固定 2 GiB LRU 只能保留约 2000 张。若反复顺序遍历更大的工作集，纯 LRU 会在反向遍历时反复重建，因此不能只靠 LRU 或后台提速解决。

报告：`output/performance/jpeg-batch-throughput-v2-20261120/jpeg-batch-throughput.json`。第一版未限制实际并发的测量已废弃，不作为依据。

## 格式与转换实现复审

### 编解码成本

使用同一张已显影 PNG 比较格式。下表为 3 张图片的均值；命令行进程启动时间包含在内，不能与 Core Image 的 47.8 ms JPEG 解码结果直接比较绝对值。

| 格式 | 编码中位数均值 | 解码中位数均值 | 平均文件大小 | 结论 |
| --- | ---: | ---: | ---: | --- |
| JPEG | 64.9 ms | 184.9 ms | 约 1.07 MB | 解码最快，继续作为交互显示缓存 |
| HEIF | 123.7 ms | 259.7 ms | 约 1.04 MB | 体积收益不稳定，编码与解码更慢 |
| JPEG XL（effort 3） | 212.7 ms | 314.6 ms | 约 0.55 MB | 约减半体积，但编解码均更慢 |
| WebP（method 4） | 236.3 ms | 455.7 ms | 约 0.54 MB | 约减半体积，但解码最慢 |

JPEG XL 的并行、渐进解码和压缩效率在标准设计上具有优势，但当前实现与样本并未转化为交互收益。[JPEG XL 官方说明](https://jpeg.org/jpegxl/)和[白皮书](https://ds.jpeg.org/whitepapers/jpeg-xl-whitepaper.pdf)可作为后续复测依据，不用于替代本次实测结论。报告：`output/performance/image-format-evaluation-v2-20261120/image-format-evaluation.json`。

### RAW 解码路径

| 路径 | 中位数／范围 | 像素与兼容性结论 |
| --- | ---: | --- |
| Core Image 全尺寸 | 约 552 ms | 当前基准 |
| Core Image 半尺寸 | 约 438 ms | 约快 21%，但 p99 误差为 2–5 级 |
| 半尺寸＋草稿模式 | 约 443 ms | 没有进一步提速，误差反而更高 |
| 四分之一尺寸＋草稿模式 | 约 415 ms | p99 误差为 5–15 级，不作为默认路径 |
| 相机内嵌预览 | 约 12–15 ms | 最快，但画幅与色彩契约不同，只作首屏占位 |
| FlashRaw CPU 多线程 | 约 297 ms | 速度有吸引力，但颜色与显影结果不兼容 |

Apple 允许在较小解码比例下通过草稿模式提速，但本次样本没有产生额外收益，因此不默认启用。[allowDraftMode](https://developer.apple.com/documentation/coreimage/cirawfilteroption/allowdraftmode)、[isDraftModeEnabled](https://developer.apple.com/documentation/coreimage/cirawfilter/isdraftmodeenabled)。

FlashRaw 的官方 PyPI wheel 使用 NEON 多线程时约为 297 ms，但其输出与 Core Image 的 p99 通道差异达到 63–72 级，不能直接替换现有显影。官方 wheel 没有可用 Metal 后端；单线程反而需要约 1.37 秒。其融合显影、区域解码、MIT／Apache 许可和公开测试语料仍值得作为独立候选继续评估，但必须先完成颜色契约验证，不能引用公开基准的加速倍数代替本机验收。[FlashRaw 项目](https://github.com/ybouane/flashraw)、[官方基准](https://github.com/ybouane/flashraw/blob/main/docs/benchmarks.md)。

报告：`output/performance/raw-decode-path-v3-20261120/raw-decode-path-evaluation.json`、`output/performance/flashraw-evaluation-20261120/flashraw-evaluation.json`。内嵌预览因画幅比例差异，不引用逐像素误差。

### Metal 版本复核

从官方 0.3.1 源码以 `gpu,jpegxl` 构建后，Metal 后端在 Apple M4 Max 上实际可用，不能将 wheel 缺少 GPU feature 误判为 FlashRaw 没有 Metal 版本。

| 验证项 | 实测结果 |
| --- | --- |
| 3 张 RAW 的 Metal 解码中位数 | 约 33–41 ms |
| C++ C ABI 首次 Metal 解码 | 约 99 ms |
| C++ C ABI 后续 Metal 解码 | 约 38–40 ms |
| Metal 峰值 RSS | 约 699–837 MB |
| NEON 峰值 RSS | 约 386–460 MB |
| Core Image 显影差异 | p99 仍为 63–72 级，未消除 |

`gpu_available()` 返回 true，证明可以通过其 C99 C ABI 或 C++17 RAII wrapper 接入，无需 Python 或命令行进程。Entropy decoding 仍由 CPU 执行，GPU 负责数据并行的后处理；Metal 比 NEON 后处理更快，但峰值内存约高 1.8 倍。[GPU 架构与限制](https://github.com/ybouane/flashraw/blob/main/docs/gpu.md)、[C ABI](https://github.com/ybouane/flashraw/blob/main/docs/c-api.md)。

报告：`output/performance/flashraw-metal-evaluation-20261120/flashraw-metal-evaluation.json`。

### 去马赛克与线性输出的资源复核

以下均为 3 张 Sony RAW 的本机实测，不是上游公开基准。RGBA8 使用各档去马赛克；线性测试使用 bilinear。时间为解码中位数，不包含 JPEG 编码或应用后续调整。

| 输出与后端 | 去马赛克 | 解码中位数范围 | 选择结论 |
| --- | --- | ---: | --- |
| Metal RGBA8 | bilinear | 33.0–41.6 ms | 显示代理首选候选 |
| Metal RGBA8 | auto／AHD | 53.8–66.1 ms | 质量候选，仍需像素验收 |
| Metal RGBA8 | edge-aware | 76.4–91.5 ms | 暂不默认启用 |
| SIMD RGBA8 | bilinear | 42.9–51.8 ms | 无 GPU 或内存受限时回退 |
| SIMD RGBA8 | auto／AHD | 100.0–125.8 ms | 明显慢于 Metal |
| SIMD RGBA8 | edge-aware | 734.2–902.7 ms | 不采用 |
| Metal linear RGB F32 | bilinear | 37.9–49.9 ms | 峰值 RSS 约 1.39–1.68 GiB，不默认采用 |
| SIMD linear RGB F32 | bilinear | 39.8–48.6 ms | 峰值 RSS 约 0.73–0.88 GiB；若做线性实验优先此档 |

Metal 的浮点输出没有形成速度优势，反而显著提高内存代价。即使后续接入线性代理，也必须按输出格式分别选择后端，不能把“Metal 更快”作为全局策略。

报告：`output/performance/flashraw-linear-demosaic-20261120/rgba8-demosaic.jsonl`、`output/performance/flashraw-linear-demosaic-20261120/linear-rgb.jsonl`。

### 线性像素与 Core Image 默认显影差异

对 3 张样本分别将 Core Image 默认 RAW 输出和 FlashRaw Metal bilinear 线性输出缩放至 2400 × 1600，再在线性 sRGB、RGBAf 中逐像素比较：

- 线性通道绝对误差的 p99 为 0.297–0.426（0…1 标度）；这不是 8 位色阶误差。
- 每通道最小二乘增益达到 1.51–2.63，但增益匹配后的 p99 仍为 0.0428–0.2497，说明不是统一曝光倍数即可对齐。
- 样本的 Core Image 默认基线曝光为 0.35–0.40 EV，`boostAmount = 1`、`boostShadowAmount = 0.9`、`shadowBias = 3`，并带非零锐化及降噪默认值。这些默认处理与 FlashRaw 的色度学显影不是同一契约。
- 对照图确认 FlashRaw 结果整体更暗；残差仍可能包含去马赛克、相机颜色校准、白平衡和局部色调处理差异，不能把全部误差归因于单一颜色矩阵。
- FlashRaw 的线性输出保持传感器方向，而当前 `CIRAWFilter` 输出已应用方向；接入时必须显式统一方向、裁切和原生坐标映射。
- 本次比较通过带线性 sRGB ICC 的 16 位 TIFF 传输，只验证量化并裁切到 `[0,1]` 后的样本。它不能证明超色域、HDR 或高于 1 的浮点值兼容。FlashRaw CLI 的 `.raw` 也会把 `linear-rgb` 量化为 RGB16，生产接入应使用 C ABI 的 F32 frame，而不是把该文件误读为 Float32。

报告：`output/performance/flashraw-linear-demosaic-20261120/01-linear-comparison.json`、`02-linear-comparison.json`、`03-linear-comparison.json`；首份对照图为同目录 `core-linear.png` 与 `flashraw-linear.png`。

### 各项编辑操作能否借助 FlashRaw 提速

当前交互路径已经把 RAW 解码、原生曝光／白平衡／降噪构成前缀，并缓存为长边 2400 的线性 RGBAf 代理；绝大多数其他滑杆只执行后续 GPU 算子。因此，**不能为每次调整重新运行 FlashRaw**。这样会把一次点运算变成完整 RAW 解码，既更慢又改变颜色契约。

现有代理描述键包含原生曝光、色温／色调和降噪参数，所以这些参数变化可能使基图缓存失效。优先工作是把可等价表达的操作移到缓存后的线性后缀，或复用稳定的中性基图，并重新验证 settled／save 一致性；仅更换解码器而保留逐参数重建，无法解决根本问题。

| 操作 | FlashRaw 覆盖与限制 | RAWMaster 建议 |
| --- | --- | --- |
| 曝光 | 可在显影中融合 EV；GPU 支持 | 可进入未来的基础代理契约，但热调整继续在线性代理上做点运算 |
| 黑点、白点 | 有通用线性 levels，GPU 支持；不等同于当前界面所有黑白点语义 | 不直接映射现有滑杆；先做参数与直方图等价验证 |
| 白平衡 | as-shot 可走 Metal；自定义 RGB multipliers、自动及 Daylight 当前回退 CPU | 暂不放进 Metal 热路径；保留现有原生／GPU 实现，必要时再评估上游补 GPU custom WB |
| 高光、阴影、亮度、对比度 | 没有与当前空间算子等价的编辑实现；highlight 模式也不是这些滑杆 | 继续现有 GPU 后缀 |
| 饱和度、自然饱和度、色偏、黑白 | 无对应编辑器算子 | 继续现有 GPU 后缀 |
| 曲线、Levels、HSL／选择性颜色、滤镜 | 无对应编辑器算子；通用 black／white point 不代表曲线或 Levels 已覆盖 | 继续现有 GPU 后缀，优先合并点运算与查表 |
| 纹理、清晰度、去朦胧、自适应鲜明度 | 无对应实现 | FlashRaw 不会加速这些热操作；直接优化现有 Metal 算子、金字塔和缓存 |
| RAW 降噪、锐化、细节 | FlashRaw 没有与 Apple 默认 NR／锐化等价的实现；edge-aware smoothing 不是同语义替代 | 保留 Core Image 前缀与既有验收，不用速度换默认显影差异 |
| 暗角、定义、局部调整、修复、红眼、颗粒 | 无对应编辑器算子 | 继续现有 GPU 后缀 |
| 裁切、旋转、透视 | 有传感器 active crop、方向和 region／tile，但不是用户几何变换 | 区域解码仅作为高倍查看候选；不得改变当前原生坐标和用户几何映射 |
| 保存、导出、最终显影 | 输出颜色、默认处理和格式语义尚未对齐 | 继续 Core Image canonical 路径 |

融合参数的附加验证中，同一 CLI 冷进程条件下，普通 RGBA8 与同时加入曝光／黑／白点的解码中位数分别为 83.343 ms 和 83.625 ms，说明这些参数本身几乎没有额外计算成本；自定义 RGB 白平衡则实际回退到 `CPU x16`。该绝对耗时包含独立进程和 GPU 初始化，不能与长生命周期 C ABI 的 38–40 ms 直接比较。报告：`output/performance/flashraw-options-20261120/options.jsonl`。

当前干净环境的暖交互中位数为：曝光／颜色 49.5 ms、Texture 78.2 ms、Clarity 70.2 ms、Dehaze 46.6–60.1 ms、自适应 Brilliance 157.8 ms、几何 33.3 ms。它们已经复用线性代理；FlashRaw 只可能缩短冷基图生成，不能从上述数字中再“减去一次 RAW 解码”。这些为 API 返回时间，不是 WindowServer 呈现或跨应用同画布成绩。报告：`output/performance/interactive-final-clean-20261120/interactive-performance.json`。

C ABI 当前暴露的是主机侧 frame；Rust 的 GPU-resident 输出和零拷贝设备互操作并未经 C ABI 暴露。若未来需要把 FlashRaw 线性结果直接接入 Metal／Core Image，需要另行实现共享 device、RGB 到 RGBAf、Alpha、方向和内存所有权桥接，并测量上传／转换成本，不能假定已具备零拷贝 Swift 接入。

### 推荐实施顺序

1. **首屏使用内嵌预览**，避免无意义的完整 RAW 解码；其仅作近似占位，随后替换为统一显影结果。
2. **标准显示缓存继续使用 JPEG**，不为追求压缩率切换到 HEIF、JPEG XL 或 WebP。
3. **保留现有线性 RGBAf 编辑路径**，避免颜色、HDR 和局部调整语义变化。Core Image 全尺寸仍是兼容性基线。
4. **FlashRaw Metal 优先用于独立显示代理**，通过 C ABI 接入并复用长生命周期 GPU context／buffer pool，避免每帧创建进程或重复初始化。代理键必须包含 FlashRaw 版本、后端、去马赛克和显影契约；不受支持或校验失败的文件回退到 Core Image。
5. **线性 FlashRaw 仅做隔离实验**。优先评估 SIMD F32 的内存优势，完成逐相机颜色、白平衡、方向、裁切、默认降噪、超色域／HDR、Alpha 和错误语义验证；未通过前不得进入保存、导出或最终调整。
6. **编辑热路径继续复用缓存代理和现有 GPU 后缀**。性能工作优先投向自适应 Brilliance、Texture、Clarity 和 Dehaze 的算子融合、金字塔复用及中间结果缓存，而不是按滑杆重复显影 RAW。
7. **高倍缩放另行评估区域／瓦片解码**。只有缓存未命中且 ROI 稳定时才解码原生区域；连续手势仍采样现有纹理，避免每个缩放事件重启 RAW 工作。

## 成熟软件的策略

### Lightroom Classic

- Minimal／Embedded 预览用于快速显示，Standard 和 1:1 预览按需或主动批量生成；高成本 1:1 预览不应在整个资料库中无差别常驻。
- 最新的缓存上限策略在达到上限后清理旧预览，但最近 30 天的预览不删除，并在空闲时执行清理；达到 90% 时提前通知，而不是等到用户操作时立即淘汰。
- 1:1 预览按最近访问时间定期丢弃；Standard 预览尺寸应与屏幕长边匹配，避免无意义的生成。
- Camera Raw 缓存与预览文件分开，默认 5 GB；Adobe 建议根据磁盘情况提高容量并使用快速 SSD。
- Smart Previews 是独立的 lossy DNG 离线编辑代理，支持原片离线时编辑并在重连后同步，不应与普通 JPEG 显示缓存混为一谈。

来源：[Lightroom 性能指南](https://helpx.adobe.com/lightroom-classic/desktop/technical-support/performance-guidelines/optimize-performance-lightroom.html)、[目录与缓存设置](https://helpx.adobe.com/lightroom-classic/desktop/manage-catalogs-and-files/create-catalogs.html)、[Smart Previews](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/lightroom-smart-previews.html)。

### Capture One

- 预览尺寸应匹配显示器；尺寸不合适、时间戳异常、目录锁定或磁盘写满都会导致反复重建。
- 这意味着代理身份必须稳定，不能因为窗口小幅缩放或元数据读取差异就换键；写入失败必须进入退避，不能每次打开都重试。
- 新预览格式还提供质量与速度选项，说明压缩成本应纳入调度，而不只看解码速度。

来源：[预览反复重建的原因](https://support.captureone.com/hc/en-us/articles/360002800517-Why-do-my-previews-constantly-regenerate)、[预览尺寸与格式](https://support.captureone.com/hc/en-us/articles/360002484457-Capture-One-Preferences-Settings-Image-tab)。

## 生命周期与预算：工作集优先，而非纯 LRU

### 热、温、冷三层

- **热数据**：当前照片、可见行及相邻 1–2 张，在交互期间不得淘汰。
- **温数据**：最近 30 天访问或修改的照片，以及当前项目的工作集。默认不自动删除；若预算不足，暂停后台预生成并提示用户，而不是把活跃数据挤出。
- **冷数据**：超过 30 天且不属于当前工作集的代理，只在应用空闲时参与回收。

### 容量与高低水位

- 初始预算为 2 GiB；目标容量提高为 `max(2 GiB, 温数据工作集 × 1.25)`，但不超过 20 GiB，也不超过当前可用空间的 10%，并始终保持至少 20% 磁盘空闲。
- 温数据目标超过硬上限时，不自动删除温数据。暂停后台生成并提示增加预算或手动整理，防止活跃数据抖动。
- 冷数据达到 90% 高水位后，在空闲时清理至 80% 低水位，避免刚触及上限就再次生成和淘汰。
- 被淘汰的冷数据**不得自动重新入队**。只有用户再次查看时才按单张生成，且不再执行全库反向预取。
- 用户明确选择的离线保留代理属于独立持久存储，不受显示缓存 LRU 影响；这与 Lightroom Smart Previews 的角色相似。

### 生成背压

- 交互期间默认并发 1；接通电源且应用空闲时最多并发 2；只有用户主动发起批量任务时才评估并发 3，并受内存预算限制。
- 队列只包含可见区域和相邻照片，最多 32 项，不建立全库后台队列。同键任务去重，解码失败使用短时效负缓存和指数退避。
- 项目切换、窗口变化、内存压力或用户开始编辑时，取消冷数据任务，优先保证当前照片。
- 预览尺寸按显示挡位量化，不为每次窗口缩放重新生成。挡位应覆盖实际屏幕长边，而不是固定生成 2400 像素。
- 解码后的内存图片纳入现有位图预算，默认最多保留当前、上一张和下一张。
- 用户清理缓存不得删除原片、配方、版本或项目记录。

### 抖动监控

除命中率、生成耗时和磁盘字节数外，额外记录每 100 次打开的重建次数、同键 10 分钟内重复生成次数、队列深度和冷数据回收次数。重建率超过打开次数 5%，或同键 10 分钟内生成超过 2 次时，停止后台预热并暴露诊断信息。

## 验收指标

- 同一张 RAW 首次中性显示的冷缓存中位数不高于 100 ms，并记录 p95。
- 连续缩放不得重新提交完整显影；当前回归要求连续事件不增加渲染请求。
- 后续 GPU 调整耗时不因代理分支回退而增加超过 5%。
- 近似帧与最终线性预览的替换时机清晰，编辑结束、保存和导出不得停留在 JPEG 路径。
- 颜色、白平衡、曲线、Alpha／HDR 拒绝域、缓存损坏、源文件变化和取消行为均有专项测试。
- 记录缓存命中率、生成耗时、首次显示耗时、磁盘字节数和回收次数，确认收益覆盖生成与维护成本。
