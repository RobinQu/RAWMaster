# 036 · 渲染 Pipeline 与编辑 DAG 的性能水位

**实现中。** 目标是把显影链路拉齐 LightFlow 与 Camera Raw 的响应水位。分栏对比与参考实现取证见 [GPU Pipeline 与编辑 DAG 的三份参考实现](../../docs/research/gpu-pipeline-references.md)。[实测记录](validation.md)

## 问题

2026-11-25 在 `main@d77d099e` 上，用 9504×6336 的 Sony ARW 跑既有交互性能用例（`EditingInteractivePerformanceTests`，每态 3 次交互帧 + 1 次定稿帧）：

| 配方 | 交互帧中位（2400×1600） | 定稿帧 |
| --- | ---: | ---: |
| neutral | 1.6 ms | 104.8 ms |
| exposure+color | 4.2 ms | 96.8 ms |
| texture | 4.7 ms | 494.8 ms |
| clarity | 4.1 ms | 471.0 ms |
| adaptive-brilliance | 22.0 ms | 4,480.9 ms |
| local-texture-clarity | 19.8 ms | 1,756.0 ms |

同一份代码里，交互帧已经在参考水位（LightFlow 2400×1600 实测 20.4／21.4 ms），定稿帧却慢 10–200 倍。遥测显示 `DevelopmentRendererV3.develop` 的像素数是 60,217,344，而输出的画布只有 3,840,000 像素，其中 `显影有限值检查`（全域归约）单独占 26–56 ms。

**根因：定稿帧在原生 60 MP 上构图，最后一步才缩到 2400。** 画布尺寸自 2022 年起固定为 2400 px 上限，因此这 25 倍像素从未显示过。参考实现都不这样做：

- LightFlow 的 `render(source, edit, target, options)` 显式接收 `RenderTarget`，`viewerFrame` 按视口尺寸出帧，源按「每一级」驻留。
- Alcedo 的 `RenderType.FAST_PREVIEW` 目标长边 2560，`DETAIL_ROI_PREVIEW` 只渲染可见 ROI，`DecodeRes` 还能把解码降到 1/2、1/4、1/8。

## 决定

引入 `PreviewSettledTransport`，把**画布定稿帧**从原生构图改为按请求视口构图：

| 值 | 行为 |
| --- | --- |
| `canonical` | 既有行为。原生 60 MP 构图，末端 FIT，全域归约在原生尺寸。`PreviewResourcePolicy.default` 保持此值。 |
| `viewport` | 同一算子序列在请求视口上求值，按视口像素做完整有限值校验。产品构造使用此值。 |

生效条件（`DevelopmentPreviewService.settledUsesViewport`）：`quality == .settled`、`schemaVersion == 3`、`role == .primary`、`0 < maxPixel ≤ 2400`，且 `policy.interactiveEvaluation == .proxyV1`。其余请求逐条沿用原路径。

不变的部分：

- **1:1（`detail`）继续原生构图**，且仍是 `viewport.maxPixel == 0` 的全尺寸物化。
- **保存、导出、缩略图、直方图、分析**继续走各自的原生路径。
- **回归面受控**：`PreviewResourcePolicy.default` 仍是 `canonical`，所有既有测试与既有证据不受影响；只有产品 `DevelopmentPreviewService` 的构造与显式传入 `.viewport` 的用例走新路径。

viewport 传输沿用已经通过的交互代理图（`PreviewInteractiveProxyV3`）：邻域半径按 `native→proxy` 缩放，代理基图按内容身份常驻，末帧由 `PreviewMetalFrameValidator` 在视口像素上做全帧 F32 校验后转 sRGB8。因此**定稿帧与松手前最后一帧是同一次求值**：缓存键一致，产品 128 MB 位图缓存直接命中，松手不再触发任何 GPU 工作。

无法按视口缩放的算子（`definition`、`sharpen.intensity`、`localEdits`、`grain`、`superResolution`、投影几何等）继续 fail closed 到原生渲染，帧上不带近似标记。判定沿用 `PreviewInteractiveProxyV3.support` 的单一清单。

## 原生扫描改用分带归约

原生帧（1:1、导出、不可缩放算子的回退）原先对 60 MP 浮点图单独铺一张全幅有限值遮罩，再对遮罩做整幅归约。这与锐化输出已经在用的分带传输是同一件事，只是入口不同：分带路径把遮罩写进有界的 r8 纹理，并在同一个命令缓冲里归约，每组只用 `0xa0` 表示「全部有限」。

现在通用原生扫描走分带传输（`DevelopmentCanonicalFiniteGPU.bandedNativeValidation`，默认开，`RAWMASTER_QA_CANONICAL_BANDED_NATIVE_FINITE=0` 回退）。准入条件与原锐化路径一致：统一内存设备、`workingSetLimit` 预算、逐带等待并核对每组实写。任何带无法入场时回落到原来的整幅扫描。

扫描不写图，因此输出像素不变：5 个配方（neutral、texture、dehaze-v2、optics-lens-profile、local-detail）的 1:1 成片 PNG 在两种传输下逐字节相同。接受／拒绝集合由 `DevelopmentCheckedFiniteV3Tests.testBandedNativeAdmissionAgreesWithTheLegacyFullFrameScan` 逐模式对照（valid、NaN、两个无穷、NaN alpha）。

| 1:1 配方 | 整幅扫描 | 分带归约 | 变化 |
| --- | ---: | ---: | ---: |
| neutral | 281.1 ms | 154.8 ms | −45% |
| optics-lens-profile | 317.4 ms | 171.9 ms | −46% |
| texture | 660.1 ms | 536.6 ms | −19% |
| local-detail | 922.5 ms | 808.0 ms | −12% |
| dehaze-v2 | 2,116.8 ms | 1,820.0 ms | −14% |

1:1 仍按原生像素出帧，没有做 ROI 裁剪；上表的剩余成本主要来自算子本身，`dehaze-v2` 的 1.8 s 即为代表。

## 1:1 可见窗口（传输层已实现，画布待接）

`detail` 原本整幅物化 60 MP，而 1:1 画布只显示 2400×1600。现在请求可以带一个归一化窗口（`PreviewViewport.window`，左上原点），物化只覆盖该窗口；`canonicalPixelSize` 仍是整幅，叠加层、裁切与吸管继续用原来的归一化坐标。

只在 `detail` 生效：`PreviewSettledTransport` 的定稿帧和 `interactive` 帧都是整幅 2400 代理，带窗口会被 `validate` 拒绝。窗口参与缓存键，不同的窗口不会互相命中。

9504×6336、50 个控件配方，同一二进制：

| | 整幅物化 | 窗口物化 |
| --- | ---: | ---: |
| 1:1 中位 | 191.8 ms | **73.1 ms** |
| 1:1 合计 | 20,596 ms | **13,678 ms** |
| 逐配方中位倍数 | — | **2.62×** |

点运算为主的配方 4.2–4.9×（`exposure-color` 120.0 → 26.3、`defringe` 115.0 → 23.3），邻域为主的配方 1.1–1.4×（`texture` 539.2 → 482.3、`dehaze-v2` 1836.7 → 1586.2、`adaptive-brilliance` 4470.4 → 3883.8）。原因是邻域／全局归约仍在整幅上完成，窗口只省掉物化。

**画布已接线，窗口是「可见矩形 + 每边 50% 外扩、量化到 1/32」**，所以实际窗口约为画布的 0.505×0.505（25.5% 面积）。按这个真实窗口重测 50 个配方：

| 指标 | 整幅物化 | 出厂窗口 | 倍数 |
| --- | ---: | ---: | ---: |
| 1:1 中位 | 191.8 ms | **111.4 ms** | **1.72×** |
| 1:1 合计 | 20,596 ms | 15,434 ms | 1.33× |
| 1:1 P95 | 1,742.7 ms | 1,474.3 ms | 1.18× |
| 逐配方中位倍数 | — | — | 1.80× |

紧贴视口的 0.2525×0.2525 窗口能到 2.62×，但那样平移半步就要重算；50% 外扩把平移余量做到约半个屏宽，同时保留 1.72×。

窗口化不改有限值证明的范围：扫描仍是整幅。把扫描也收窄到窗口是下一步，实测还能再省一部分，但它把证明从「整幅有限」缩小为「显示窗口有限」，需要单独审计 `thumbnailCanonicalWitness` 与 `FlashRawNativeFiniteCheck` 的复用域。

## 解码端：没有可用的降采样开关

原计划给 `CFlashRaw` 透出 `flashraw_decode_options.max_dimension`，把预览的解码降到 1/2 或 1/4（对应 Alcedo 的 `DecodeRes`）。实测后撤回：

| 手段 | 结果 |
| --- | --- |
| `max_dimension = 4800` | **直接报错** `limit exceeded: dimension 9728x6656 exceeds 4800`。源码 `crates/flashraw-capi/src/frame.rs:156` 把该字段写进 `limits`，是安全上限而不是降采样。 |
| `demosaic = HALF_SIZE` | 输出 4752×3168（原生 25% 像素），耗时 39.6 ms vs bilinear 43.5 ms。**只减尺寸不减时间**，因为解码与去马赛克的工作量不变。 |
| `demosaic = EDGE_AWARE` | 118.9 ms，是 bilinear 的 2.7 倍。`rawDetails` 选 AHD 时会付这个代价。 |

因此 FlashRaw 0.3.1 上唯一还剩的解码杠杆是**区域解码**（`use_region`，已在 C 包装里），它的用法与 1:1 可见窗口绑定：窗口帧可以只解那一块，省掉一次约 78 ms 的全幅解码。这项要等窗口接到画布之后再评估，因为窗口帧的纹理通常已经由定稿帧的解码驻留。

代理基图仍用 bilinear 全幅解码，再经 Metal 采样到 2400×1600。

## 1:1 剩余成本：冷启动与算子内部整幅工作

同一配方连测三次 1:1（窗口帧，各次均重新请求）：

| 配方 | 第 1 次 | 第 2 次 | 第 3 次 |
| --- | ---: | ---: | ---: |
| neutral | 104.4 ms | **11.7 ms** | 12.6 ms |
| exposure-color | 27.7 | 32.0 | 30.5 |
| texture | 474.8 | 490.9 | 486.3 |
| dehaze-v2 | 1,554.2 | 1,490.2 | 1,505.1 |
| adaptive-brilliance | 3,878.0 | 4,226.4 | 3,942.7 |

两件事因此可以定性：

1. **点运算配方的 1:1 首次成本主要是一次性准备**（约 90 ms：私有上下文的首次内核编译与全幅原片解码/上传），热态只有约 12 ms。这也解释了扫描不是大头——分带扫描在热态里只占十几毫秒，收窄它换不到多少，却要把证明从「整幅有限」缩成「窗口有限」。因此**窗口化扫描不做**。
2. **邻域配方的成本是算子内部的整幅工作**，与请求区块无关。`DevelopmentAdvancedDetailEngineV3.materialize` 把整幅 9504×6336 渲染进一张 RGBA32F 纹理（约 964 MB）并同步等待，`texture`/`clarity` 的 480 ms 主要来自这里；`dehaze` 与 `adaptive-brilliance` 的 1.5 s / 3.9 s 同理来自各自的整幅归约。要吃掉它们必须逐算子做邻域分解、把内部物化改成窗口＋halo，那是算子级工程，不是传输层能解决的。

## 画布自由缩放与取样

在[编辑暗房](../../docs/ui/prototype/index.html#edit/development)以触控板捏合（浏览器原型也可用 Ctrl + 滚轮）、滚轮缩放或底部 `+` / `−` 查看当前照片与版本。手势前后保留落点与显示倍率；原图帧交付只替换像素，不修改画布变换。低于 100% 时按屏幕物理像素密度取样，例如 6000 × 4000 的照片在 50% 时对应整幅 3000 × 2000，按可见窗口请求；100% 取原生像素，超过 100% 不再生成额外细节。显式 `1:1` 才切到 100%，`FIT` / `0` 返回适合窗口。

均衡在缩放中请求按倍率渲染的细节；极速可暂用现有预览，结束后两种模式请求同一种最终帧。取消、缩回 FIT 或换片均不接受过时的细节帧。若原片不可用或渲染失败，使用既有离线或预览重试入口，不把代理帧当成最终结果。[原型走查](../025-editing-workspace/prototype-review.md#自由缩放与原图取样) · [原生验证](validation.md#自由缩放与原图取样)

## 极速模式（用户可选）

设置 → 编辑 → 「渲染速度」提供 `均衡` / `极速`。默认 `均衡`，行为与上一版完全相同；`极速` 才启用降级项。选择保存在 `UserDefaults` 的 `editing.preview.performanceMode`，启动时应用到 `PreviewPerformancePreferences`，无法识别的值回落到 `均衡`。

| 项 | 均衡 | 极速 |
| --- | --- | --- |
| 1:1 拖动中 | 每帧完整原生渲染 | 画布分辨率代理帧（`PreviewQualityPolicy.quality`） |
| 1:1 松手首帧 | 可见 + 50% 外扩窗口 | **先紧贴现可见**，250 ms 后后台补齐外扩 |
| 裁切叠加单独变化 | 原生 | 原生（不降级） |
| 导出 / 保存 / 缩略图 / 直方图 / 分析 | 原生 | 原生 |

1:1 拖动从「每 tick 一次原生渲染」降到「每 tick 一次代理帧」：同一组配方的交互帧中位 7.2 ms，而 1:1 原生帧中位 111.4 ms、`texture` 285.9 ms、`adaptive-brilliance` 3961 ms。级联判定抽成 `PreviewQualityPolicy` 并由 `PreviewQualityPolicyTests` 固定：均衡模式下即使拖动也保持 `.detail`；极速模式下只有「1:1 + 正在拖动 + 不是仅叠加层变化」才降级。

### 1:1 真实编辑序列：每次改参数都付全额

模拟真实调整（同一类编辑连续提交 5 次、每次换一个值，避免缓存命中），1:1 在 4800×3200 窗口上的单次落帧：

| 配方 | 第 1 次 | 第 2–5 次 |
| --- | ---: | --- |
| 曝光（点运算） | 173.9 ms | 38.6–41.2 ms |
| texture | 642.8 ms | 561.2–577.3 ms |
| clarity | 519.5 ms | 455.0–463.1 ms |
| adaptive-brilliance | 4,047.1 ms | 3,780.8–4,305.1 ms |

点运算配方第一次之后稳定在约 40 ms（首次差额是上下文与基图准备）。**邻域算子没有任何预热效应**：每次改参数都重付全额。这与「1:1 稳态约 30 ms」并不矛盾——那个数字是点运算配方的稳态。

因此极速模式在松手后先等 250 ms 再渲染原生 1:1 帧（`PreviewQualityPolicy.delaysDetailSettle`）：期间画布继续显示手势代理帧，连续调整只付一次原生渲染。均衡模式不延迟。

### 极速模式：空闲预热 1:1 基图

把「首次进入 1:1」拆开测量后，成本结构和之前的假设不同：

| 组成 | 耗时 |
| --- | ---: |
| FlashRaw 全幅解码 | 78.4 ms |
| F16 上传 | 40.0 ms |
| 图构建 + 有限值扫描 | 14.5 ms |
| 物化 + 自有位图拷贝 | 23.0 ms |

**首次 1:1 的 182 ms 里有 118 ms 是整幅 RAW 解码与上传**，不是图和算子。稳态只有约 30 ms。

极速模式因此在画布空闲 750 ms 后，用一次后台步骤把该原件的全幅基图解码进纹理池，并标记该代已完成。之后任何 1:1 请求都是缓存命中：

| 首次 1:1（0.505×0.505 窗口） | 三次实测 |
| --- | --- |
| 均衡（不预热） | 182.8 / 182.1 / 181.8 ms |
| 极速（预热） | 83.0 / 83.4 / 79.2 ms |

稳态不变（约 30 ms）。预热会占用唯一的原生工作线程约一次解码的时间，所以：只在极速模式启用、idle 阈值 750 ms（普通静默是 150 ms）、每个原件代次只做一次、可由 `RAWMASTER_QA_DETAIL_PREWARM=0` 关闭。均衡模式完全不走这条路径——无条件启用时整张矩阵出现约 6% 波动且最重的配方反而变慢，因此收进极速。

### 已试并撤回：去掉高级细节的整帧冻结

`DevelopmentAdvancedDetailEngineV3` 会把整幅结果冻结进 RGBA32F 纹理。探针证明 `CIGaussianBlur` 与「带 3σ halo 的裁剪输入」在本机是逐位矩形无关的（半径 4/18/60，307,200 个样本最大差 0），所以曾尝试去掉冻结：1:1 的 `texture` 快 1.75×、`clarity` 快 1.37×，像素差只有 1/255（`texture` 0.001%、`clarity` 0.44% 通道）。

但完整回归立刻否掉：`DevelopmentSemanticMaskTests.testHistoricalColorAndCropKeepProtectedCodesInLosslessExports` 出现 **21,635 处差异**。原因不是高斯路径，而是**蒙版合成会从多个分支读取同一结果**——没有冻结时每个分支各自重算模糊，零覆盖区不再逐位不变。因此冻结保留，`RAWMASTER_QA_ADVANCED_DETAIL_UNFREEZE=1` 只作为测量口。

### 已试并撤回：窗口化冻结（ROI 原型，决定性否决）

要让 1:1 的邻域算子真正降到十倍量级，唯一正确的形态是「窗口 + halo 的一次性物化，并让全部下游消费同一窗口结果」。先做了这个方向的决定性探针 `AdvancedDetailWindowFreezeProbe`（真实 9504×6336 ARW，`RAWMASTER_ADVANCED_FREEZE_PROBE=1`）：

| 探针 | 结果 |
| --- | --- |
| 引导图高斯：整幅物化 vs 只物化 2400×1600 窗口 | **最大差 0.0**，所有分量逐位相同 |
| 整条 band 图（texture + clarity）：同上 | **最大差 5.7e-4，15.4M 个分量里 11.5M 有差异** |

也就是说：`CIGaussianBlur` 本身在原生尺寸上确实是矩形无关的，但把它接进 `rmAdvancedBandV1` 之后，Core Image 对子窗口的**内部分块**改变了高斯的取样结果，边缘附近逐位不同。这与之前"去掉冻结"的实验结论一致（去掉冻结后蒙版零覆盖区出现 21,635 处差异）——根因不是高斯公式，而是**分块边界**。

结论：**当前的 advanced-detail 图无法只靠调节 materialize 的覆盖范围变成 ROI 安全**。要走到十倍量级，必须同时接管两件事：

1. 自写可分离高斯（显式 halo，不依赖 CI 的分块）；
2. 自写 band 合成，同样显式 halo，并在窗口化时把 halo 纳入请求。

两者都会改变像素（因为离开了 CI 的高斯路径），需要重新基线，并且要给「窗口帧 == 整幅帧同区域」逐字节证据。这是算子级重写，不是传输层调整。`texture`/`clarity` 之外，`dehaze`、`adaptive-brilliance`、`local detail`、`lens blur` 各自有同形的整幅归约，都要各自处理。

本轮到此为止：传输层与画布已经拿到 1.72×（1:1 出厂窗口）、2.62×（紧贴窗口）、51.6×（定稿），剩下的十倍量级属于算子重写项目。

### 算子重写调研：引导图窗口化也过不了逐字节硬门

上一轮否掉了「窗口化 band 输出的冻结」。本轮按「冻结引导图而不是冻结输出」重新验证，因为高斯作为**最终输出**时探针显示矩形无关。三个探针（`AdvancedDetailWindowFreezeProbe`，真实 9504×6336 ARW，每次物化都用全新 `CIContext`，避免渲染缓存污染）：

| 探针 | 结果 |
| --- | --- |
| 引导图高斯：整幅 vs 2400×1600 窗口 | 最大差 **0.0** |
| 引导图经 RGBA32F 纹理往返（halo 0/8/32） | 最大差 **0.0**，15.36M 分量全同 |
| band 用**冻结引导图**（窗口 + halo）vs 用内联引导图 | texture 最大差 1.6e-5（3,957–15,009 分量）；clarity 最大差 7.0e-4（**11.1M 分量**） |

也就是说：引导图的**值**在两种构图下完全相同，纹理往返也无损，但 `rmAdvancedBandV1` 的输出仍然随**输入 image 的 extent** 变化。核本身是同坐标取样（`src.sample(src.transform(d))`），`roiCallback` 也返回原矩形，所以这不是核的数学问题，而是 Core Image 对「输入是图还是纹理、extent 多大」的内部分块与取样边界。

结论：**只要 band 核仍由 Core Image 求值，就无法用它做逐字节的窗口化**。要让邻域算子 ROI 安全，必须连 band 合成一起接管（把引导图冻结后，用自写的 compute pass 做合成，而不是 CIKernel），这等于重写整个算子。`halo` 从 0 到 110 都试过，`texture` 在 halo=0 时恰好为 0 只是同尺寸直通的巧合，halo≥2 就出现差异。

量级参考（供取舍）：`texture` 的 1.6e-5 在 8 位显示上约 0，影响 0.03% 分量；`clarity` 的 7.0e-4 约 0.2/255，影响 72% 分量。若把硬门放宽为「≤1 个显示码值且 ≤0.5% 分量」，`texture` 可通过、`clarity` 不能。

### 已试并撤回：代理基图半分辨率解码

用 `FLASHRAW_DEMOSAIC_HALF_SIZE` 解码代理基图（4752×3168 再采样到 2400）只省一次性 34 ms（neutral 首次帧 130.1 → 96.5 ms），却永久改变基图像素（相对均衡基图 p99 2–4、最大 72–99/255 的高对比边缘差异）。一次性收益换永久画质代价，不采纳。

## 交互与像素契约

| 从哪里进入 | 对象、完成与退出 |
| --- | --- |
| 暗房画布，适应窗口 | 拖动任一控件显示视口帧；松手后画布立即停在最后一帧，不再出现「快速预览 · 待完整预览」。状态行显示 `预览 2400 × 1600 · 原生 9504 × 6336`。 |
| 暗房画布，放大到 100% | 切到 `detail`，原生构图与原生像素；状态行显示 `原生像素 9504 × 6336`。 |
| 局部调整、裁切、吸管 | 使用当前定稿帧（视口像素）作为叠加与取样底图；坐标仍按归一化画布，构图映射不变。 |
| 保存版本、导出、缩略图 | 不受影响，继续原生。 |

定稿帧的 `approximation` 记录 `PreviewInteractiveProxyV3.version` 与 `native→proxy` 尺度，`canonicalPixelSize` 仍是原生画布，供叠加层与几何映射使用。

## 验收

| 项 | 门槛 | 结果 |
| --- | --- | --- |
| 50 个控件配方的定稿中位 | ≤ 25.92 ms（Camera Raw 同机口径） | 6.81 ms |
| 50 个配方的定稿 P95 | ≤ 210.23 ms（LightFlow 同机 P95） | 20.24 ms |
| 单配方最慢定稿 | 不高于同配方交互帧的 1.5 倍 | 33.11 ms（local-defringe，交互 12.60 ms，2.6×；产品位图缓存下 0.275 ms，见验证记录） |
| 松手后的定稿成本 | 重放同一视口帧，不重跑 GPU | 中位 0.250 ms，最大 0.505 ms |
| 视口帧与原生定稿的重采样差 | p99 ≤ 8/255，最大通道差只出现在几何与锐化边缘 | p99 中位 2/255、最大 18/255；最大通道差中位 20/255 |
| 1:1（`detail`）行为 | 保持原生像素，不改语义 | 未改；测得 258–2177 ms，作为下一轮目标 |
| 原生路径未被削弱 | `detail`、导出与 `PreviewResourcePolicy.default` 逐位不变 | 由既有回归与新增用例覆盖 |

## 取证与参考

- [GPU Pipeline 与编辑 DAG 的三份参考实现](../../docs/research/gpu-pipeline-references.md)：LightFlow 发布包引擎接口与帧循环、Alcedo 的编译计划／节点缓存／渲染意图／解码分辨率、FlashRaw 的 C ABI 开关。
- [LightFlow REA 符号取证](evidence/lightflow-rea-symbols.json)：本轮 `analyze_javascript_application` 的 21 个引擎方法、模块 SHA-256 与精确源码区间；含此前未覆盖的多线程绑定 `web-mt/lightflow_host_wasm_mt.js`。

## 算子 factor/restore 窗口化（PoC 通过）

上一轮结论是 band 核由 Core Image 求值时无法逐字节窗口化，必须连 band 合成一起重写。本轮找到了不重写高斯的替代路径：现有引擎里已有未被 `apply` 使用的 `rmAdvancedBandFactor` / `rmAdvancedBandRestore`，两者都是逐像素的；把 factor 冻结成纹理，restore 只读窗口，就可以把高斯留在 Core Image，同时跳过 60 MP 的整幅 materialize。

真实 9504×6336 ARW 探针（`AdvancedFactorRestoreProbe`，`RAWMASTER_FACTOR_PROBE=1`）：

| 检查 | 最大差 | 差异分量 |
| --- | ---: | ---: |
| texture inline vs factor/restore（整幅） | **0.0** | 0 / 240,869,376 |
| texture window restore vs crop | **0.0** | 0 / 15,360,000 |
| clarity inline vs factor/restore（整幅） | **0.0** | 0 / 240,869,376 |
| clarity window restore vs crop | **0.0** | 0 / 15,360,000 |
| texture25 → clarity40 串联 | **0.0** | 0 |
| 窗口内重算 factor：texture / clarity | **0.0** | 0 / 15,360,000 |

耗时：

| 项 | texture | clarity |
| --- | ---: | ---: |
| 整幅 inline（当前） | 531 ms | 609 ms |
| 整幅 restore（factor 冻结） | 457 ms | 456 ms |
| 窗口 inline | 32.8 ms | 47.0 ms |
| **窗口 factor + restore** | **31.4 + 43.2 ms** | **64.8 + 50.0 ms** |

整幅 factor/restore 只省约 15%，因为整幅 materialize 还在；**窗口内重算 factor + restore** 才是 5.3–7.1× 首帧、约 12× 改参数。`halo = ceil(12*radius + 8)`：texture 31 px、clarity 313 px。factor 区域约 65/108 MB，而不是 964 MB。

渲染器接线时发现一个边界：3000×2000 TIFF 上“窗口内 factor”与整幅 factor 的 crop 有 **1 LSB / 0.55% 分量** 差异，而整幅重复渲染为 0。9504 ARW 探针恰好为 0，但这是数据相关的 1 ULP。

**严格全幅 factor 模式通过服务级逐字节验收：** 整幅与窗口都用同一张全幅 factor，并在 texture band 后先物化全幅 texture 输出；3000×2000 TIFF 的 whole vs window crop 为 **0**，9504 ARW 引擎级也为 0。3000×2000 首次整幅 114 ms、随后窗口 48 ms。代价是双 band 首帧约 2×；单 band 首帧与 inline 接近，改参数只 restore。该模式仍由 QA 开关控制。**固定输出 tile 已实施并默认用于单 band 1:1：** 每个 1024² 输出 tile 单独物化，整幅和窗口共享 tile 纹理；60 MP ARW 整幅/窗口 **0 差异**，窗口 **101.8 ms**（inline 471 ms，4.6×），整幅 1375 ms（全 tile 重建）。单 band 默认启用；双 band 仍走原 inline 路径，下一步再 tile 化 texture→clarity 串联。

证据：[advanced-factor-window-probe.json](evidence/advanced-factor-window-probe.json) · [再调研与下一步规划](../../docs/research/library-first-screen-and-operator-next-steps.md)。

生产化顺序：

1. `AdvancedDetailFactorCache` 键 `(sourceGeneration, band, radius, quantizedWindow+halo)`；1:1 `.detail` 走窗口 factor/restore，整幅/导出/缩略图保持现状。
2. texture factor 从输入源算；clarity factor 从 texture restore 后的窗口输出算；改 clarity amount 只 restore，改 texture amount 使 clarity factor 失效。
3. 生产路径逐字节测试 + `DevelopmentSemanticMaskTests` 零覆盖回归 + 50 配方矩阵；导出路径暂不切换，直到蒙版/裁切/吸管全部通过。
4. `dehaze` / `adaptive-brilliance` 的整幅归约另做分块确定性归约 PoC。

## 任务

见[任务清单](tasks.md)。剩余项：

1. 播放尺度的 1:1 查看目前整帧原生构图，尚未按可见 ROI 裁剪（Alcedo `DETAIL_ROI_PREVIEW`）。
2. 解码端降分辨率（FlashRaw `max_dimension` / `DecodeRes`）尚未接入，视口帧仍消耗一次全尺寸解码。
3. 视口尺寸仍固定 2400 px，未随实际画布与窗口收窄调整。
4. `local-defringe` 的定稿是交互帧的 2.6 倍，需单独定位。
