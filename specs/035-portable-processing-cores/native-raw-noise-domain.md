# 原生 RAW 降噪的输入验证

全局降噪的「亮度对比」和「色彩细节」都读取 FlashRaw 九点降噪输出，以及用半径 1.5 从它生成的 Core Image 高斯图像。改变上述两个末端控件时，这两个输入可以保持相同。桌面端新增默认关闭的 QA 路径，在正常主编辑器的 2400 像素定稿中验证这两个实际输入，随后用同一对图像处理同一相机降噪设置的强度变化。[像素、故障与设备回执](evidence/native-raw-noise-domain.json)

## 允许复用的边界

准入先使用已有的物理 FlashRaw 上传检查。它返回 false 时由原图的验证和显示路径接手，本次请求没有候选证书。取得准入后，首次使用按原有 128 MiB 工作预算核对全分辨率每个像素。第三个输入是已经核实 FD 和物理纹理的原始 FlashRaw 图像。三个输入每个 RGB 分量的 IEEE 位模式必须对应绝对值不超过 8 的有限数，alpha 必须恰为 1。原有分带归约的每组都须交回完成码。数值超出范围会使用原来的全图有限值验证。候选分带已提交后，未写标记、格式异常、Metal 失败和撤销会结束本次请求。所有已提交的命令都会等待完成。

原 `rmNoiseDetail` 读到的两个 alpha 都是 1。两个输入的亮度绝对值上界为 8.01，两侧色度分量绝对值的上界为 16.01。两个强度均在 0 到 1 内。带入原有亮度系数 0.35 和色度系数 0.25，最终颜色分量的绝对值小于 40。代码在运行时核对这段 Metal 函数和亮度函数的 SHA-256，并核对本次函数收到的参数和两张图的对象身份。[计算和验证实现](../../Sources/RAWMasterImaging/PreviewNativeNoiseDomain.swift) [原始降噪核](../../Sources/RAWMasterImaging/DevelopmentGlobalEngineV3.swift)

原显示像素读回成功并再次通过版本、捕获和 pin 身份检查后，才允许在当前 FlashRaw 缓存条目中保留这对输入。缓存只持有已有的不可变图像描述和完整捕获键。不同相机降噪设置会重新建立证书。捕获退出、纹理驱逐、拍摄方向变化、其他编辑叠加或工作内存设定改变，都要求重新取得资格。导出、缩略图和分析使用现有路径。[正常编辑入口](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) [原生缓存及所有权](../../Sources/RAWMasterImaging/FlashRawCanonicalTexturePool.swift)

## 复验

在 macOS 27.0.1（26A434）、Apple M4 Max、已核实的 FlashRaw 0.3.1 RGBA16F、EXIF 方向 1、512 MiB 预览内存下，以两张 RAW 交叉验证四个状态。尺寸分别为 9504×6336 和 8640×5760。色彩降噪和亮度降噪两组分别调节 0.1 和 0.7。每档均与既有 2400×1600 sRGB8 整帧归档相符。原尺寸 RGBAf 逐带核对，主片有 25 带、末带 192 行，次片有 23 带、末带 128 行。四个冷态和四个热态的生产图均与原图的每带及全幅摘要一致。另单独读取了自然缩放到一半的完整 RGBAf 四通道，每个状态的主片比对 60,217,344 个分量，次片比对 49,766,400 个分量。[每档原片、半幅和显示摘要](evidence/native-raw-noise-domain.json)

异常对照覆盖两个控件、两种顺序和 12 个输入条件。48 次接受或拒绝结论与原有限值验证相同。单独注入无效归约码会抛错。中途撤销、发布回查撤权、同一物理纹理换源键、驱逐再装，以及随后重新取证的成片均已复验。首个强度在主片执行 61 次权限回查，次片 51 次。两个相机设置各自第二次强度只需两次回查。上述数字用于证明冷热路径实际命中。[异常和逐请求回执](evidence/native-raw-noise-domain.json)

分带助手用真实 Metal 命令模拟计算编码器在第二带的 Core Image 任务编码后不可用。已有两个命令均在返回错误前完成，同一个上下文随后成功重试。实体设备丢失仍待实测。[回归用例](../../Tests/RAWMasterImagingTests/CanonicalFiniteGPUTests.swift) · [修正版同包回执](evidence/native-finite-transport-join.json)

用 `RAWMASTER_QA_NATIVE_RAW_NOISE_DOMAIN=1` 开启试验。常规构建可独立运行 `swift test -c release --filter PreviewNativeNoiseDomainTests` 检查参数资格、归约码和当前着色器签名。独立重放可将原片、该片归档 JSON、输出 JSON 和两个控件 ID 传给仓库的 `scripts/performance/profile-settled-photo.swift` 入口。控件 ID 为 `detail-nr-color-detail` 和 `detail-nr-lum-contrast`。正常服务验收还应核对两张原片的归档摘要和 `NativeRawNoiseDomain` 冷、热事件。[直接回归测试](../../Tests/RAWMasterImagingTests/PreviewNativeNoiseDomainTests.swift)

## 正常编辑器定稿耗时

同一 Release 在两个原片上分别按关闭、开启、开启、关闭运行全部 37 个控件。所有 1,184 个交互与定稿帧的显示摘要均一致。下表只取两个全局降噪控件的正常定稿，从请求开始计至完整显示读回。每张原片的每个开关状态有 8 个定稿，冷态和热态各 4 个。冷态表示该相机降噪设置首次建立输入证书，热态表示在同一输入对上更改末端强度。[逐次定稿、归约命中和 Release 指纹](evidence/native-raw-noise-domain.json)

| 原片 | 两控件合计 P50，关闭 → 开启 | 冷态 P50，关闭 → 开启 | 热态 P50，关闭 → 开启 | 两控件合计 P95，关闭 → 开启 |
|---|---:|---:|---:|---:|
| 9504×6336 | 241.52 → 208.41 ms | 241.52 → 232.12 ms | 238.71 → 163.86 ms | 251.60 → 580.59 ms |
| 8640×5760 | 195.16 → 175.31 ms | 189.25 → 189.88 ms | 196.28 → 138.31 ms | 205.35 → 210.60 ms |

热态的四次定稿都复用了同一输入对，没有再次提交全图归约。主片热态验证阶段的中位数从 74.61 ms 降至 0.015 ms，次片从 56.07 ms 降至 0.014 ms。主片首次开启「色彩细节」时，输入验证花了 392.31 ms，整帧耗时 580.59 ms。所有样本均计入 P95。保留默认关闭，后续须单独验证首次建立输入证书的尾延迟。[分状态原始样本](evidence/native-raw-noise-domain.json)
