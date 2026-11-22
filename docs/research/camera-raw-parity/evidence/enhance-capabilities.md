# 系统 RAW 神经解码与 2× 超分能力

测试机为 M4 Max、macOS 27.0.1（26A434），输入为 Sony ILCE-7RM5 的 9504 × 6336 ARW。完整源哈希、系统报告的解码版本和尺寸组合可查阅原始记录。[能力探测结果](enhance-capabilities.json) · [独立复现脚本](../../../../scripts/performance/ProbeEnhanceCapabilities.swift)

## RAW 9

Core Image 对这张 ARW 提供 7、8、9 三个解码器，默认版本为 8。切换 9 后，源支持亮度降噪量，色度降噪由模型自动处理。Apple 将 RAW 9 描述为从传感器采样联合去马赛克和降噪的模型。RAWMaster 将神经解码器和每次编辑的降噪量分别写入配方，关闭后恢复原来的解码方式。原生颜色噪点、亮度和细节控件继续使用各自的处理路径。[Apple 的 RAW 9 讲解](https://developer.apple.com/videos/play/wwdc2026/305/) · [图像引擎实现](../../../../Sources/RAWMasterImaging/DevelopmentNeuralRaw9.swift)

首轮 Release 测量从 FlashRaw 默认状态切换到 RAW 9，并用同一真实工作负载反复设置原生 Amount。0、100 以及恢复原始解码得到三种可区分的画面。重复设置 0 时与原 0 像素摘要完全相同，关闭后也能重新得到原始像素。全幅 TIFF 经读取验证为 9504 × 6336、每通道 16 位。一次首次设置 0 耗时 5140 ms，接着设置 100 耗时 3089 ms，第二次输入 0 耗时 3038 ms。原始文件的大小为 69488640 字节，测试结束时哈希一致。[首轮完整请求与导出记录](history/raw9-denoise-before-cache.json) · [Release 测试日志](history/raw9-denoise-before-cache.log)

现在为同一张原片保留最近两个已计算的神经输入。每个输入键包含源会话、模型和精确 Amount。首次选择 0、100、50 分别耗时 3061、3074、3116 ms，三次都启动了新的真实推断。返回 0 两次分别耗时 8.13 和 7.93 ms，返回 50 耗时 8.61 ms，三次都直接命中对应输入。两轮中的六个相同预览状态和整幅 16 位 TIFF 的 SHA-256 逐项一致。[逐次性能、缓存及像素证据](raw9-denoise.json) · [Release 测试结果](raw9-denoise.log)

测试保留上一张已显示的图片。两个 2400 × 1600 的线性 RGBA32F 代理共占 122880000 字节。另一窗格申请 100000000 字节时，账本即时回收一个代理，剩余 61440000 字节。关闭会话后代理驻留为零。包括全幅显影和 TIFF 输出在内的进程 RSS 高水位约为 2.06 GiB。100 的全质量显影预览用时 9.88 秒，整幅 16 位 TIFF 写入及验证用时 9.33 秒。以上时间每个状态各取一次。[完整实测](raw9-denoise.json)

在 800 × 534 的 sRGB 样本上，还对比了真实 50 和两个端点在线性光空间中的中间值。1281600 个色彩通道的平均误差为 0.125 个 8 位码值，最大误差为 1。正式编辑中的 50 来自模型推断。其他相机、噪声水平、原生像素细节和所有中间值仍待验证。[取样与误差计算](../../../../Tests/RAWMasterImagingTests/DevelopmentNeuralRaw9Tests.swift)

## 已渲染照片的 AI 降噪

RAWMaster 内置 nagadomi 训练的摄影 VGG7 noise2 模型。Metal 在原生像素上执行七层卷积，每块读取七像素的邻域。模型的输入是按源 ICC 转入显示 sRGB 的三个颜色通道。输出沿用原图的透明度，超出模型颜色范围的像素保留原始值。作者明确将 MIT 授权覆盖到模型权重。包内记录了原始提交、源 JSON 及转换后权重的 SHA-256。[原始摄影权重](https://github.com/nagadomi/waifu2x/blob/cc385f97a9debfe611316aabfd5d8bb30ba2dbeb/models/vgg_7/photo/noise2_model.json) · [作者的权重授权确认](https://github.com/nagadomi/waifu2x/issues/478#issuecomment-5003816684) · [应用内署名](../../../../Sources/RAWMasterImaging/Resources/PhotoDenoise/NOTICE.txt)

测试从同一张 Sony ARW 提取相机自身生成的 1616 × 1080 sRGB JPEG，并通过色彩转换产生同尺寸的 16 位 Display P3 TIFF。关闭恢复原始显示数据。新版 Amount 0 保留原图亮度并应用完整模型色度。另用这张照片生成 PNG、HEIC、AVIF、JPEG XL、WebP、PSD 和 PSB，逐个检查 Image I/O 识别的真实容器、开启和关闭、配方重开、16 位导出和导出后的像素。PSB 与 PSD 都读取合成画面。[逐条原始记录](photo-denoise.json) · [Release 测试日志](photo-denoise.log)

新配方以 BT.709 权重计算显示 sRGB 空间的亮度 Y′，保持模型预测的 R′−Y′ 和 B′−Y′。Amount 0、50、100 分别选择原亮度、源与预测的亮度中点、完整预测。反向兼容的两个旧模型标识继续混合完整 RGB。十种输入包括输出参照 DNG。每种输入按 256 × 192 网格独立校验，排除非不透明或任一状态接近 8 位输出边界的点后，每图保留 37,418–48,422 点。各图的亮度 0 相对原片、亮度 50 相对中点、0 与 50 的色差相对 100，三项 P95 上界分别为 0.643、0.464、0.928 个 RGB8 码值。合成浮点输入的透明度误差为 0，HDR 和负通道在三档的最大误差为 1.2 × 10⁻⁷。旧模型的 0、35、100 在所有十种输入上与升级前的同源像素摘要逐字节一致。[Adobe 的强度说明](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/sharpening-and-noise/enhance.html) · [九种摄影容器](photo-denoise.json) · [输出参照 DNG](output-referred-dng.json) · [旧摄影版本](history/photo-denoise-rgb-v1.json) · [旧 DNG 版本](history/output-referred-dng-rgb-v1.json)

原生尺寸不超过 2400 像素长边、单张 FP32 预测表面不超过 32 MiB 时，交互预览可在同一次捕获中复用不可变的 VGG7 输出。模型预测与最近两档完整预览共用物理内存预算。内存不足时仍按原生像素推理。超过尺寸限制的照片在划定的瓦片上求取模型输出。关闭十个测试源后，缓存账本的输入驻留量均为 0。在 Sony JPEG 连续首次请求 100、50、35 时，三档均输出各自稳定的像素，GPU 监控记录的新增 VGG7 卷积为 0 次。测试中不带该复用时，照片 JPEG / P3 TIFF 输入新强度的中位分别为 98.80 / 97.16 ms。本版分别为 9.32 / 11.69 ms，重放中位为 4.45 / 4.29 ms；输出参照 DNG 为 14.91 / 2.33 ms。正式比较使用与旧版本相同的设备、来源、权重与十个数值。[摄影性能门](photo-denoise-comparison.json) · [DNG 性能门](output-referred-dng-comparison.json) · [优化前的实际回归](history/photo-denoise-full-chroma-before-prediction-check.json) · [最初旧配方不匹配的记录](history/photo-denoise-initial-v2-legacy-failure.json)

性能回归分别输入十个此前没出现的 Amount。每次先切换到另一个已有值，再重放刚计算的值。报告分别保留首次值与重放的 P50、P95 以及校验源、权重和稳定帧的脚本。正式发布从 `RAWMASTER_PERF_CAMERA_JPEG` 取固定相机 JPEG。可用 `RAWMASTER_PERF_RENDERED_FORMATS` 指定扩展格式样本目录，或用 ImageMagick 与 cjxl 根据该相机 JPEG 生成。[采样与回归结果](photo-denoise-comparison.json) · [发布校验器](../../../../scripts/check-photo-denoise-performance.py)

候选模型 RealPLKSR 也在这张 JPEG 的中心区域做过对照。其 Core ML 转换与作者的 ONNX 每通道平均绝对误差为 0.000350。32 和 64 像素的分块重叠仍分别出现 0.0664 和 0.0768 的峰值差。VGG7 的局部感受野支持跨块一致的输出，测试另以独立计算的定点颜色和坐标核对了 Metal 的卷积顺序。[候选模型实验](photo-denoise-realplksr.json) · [RealPLKSR 作者权重卡](https://huggingface.co/Phips/1xDeNoise_realplksr_otf/tree/829b63fdbf8b1271595893bdaee6818bdada46bb) · [生产模型像素检验](photo-denoise-pixels.log)

## Super Resolution

本机公开的 VideoToolbox 单图模型使用 revision 1，报告的可选倍率为 4。下表为同一进程实际创建配置的结果。[VideoToolbox 的公开配置 API](https://developer.apple.com/documentation/videotoolbox/vtsuperresolutionscalerconfiguration)

| 输入尺寸 | 配置为 2× | 配置为 4× |
| --- | --- | --- |
| 512 × 512 | 不支持 | 可创建 |
| 1920 × 1080 | 不支持 | 可创建 |
| 9504 × 6336 | 不支持 | 不支持 |

我们用系统 4× 模型放大原片中央的 512 × 256 像素，再在线性光空间平均每组 2 × 2 输出像素。该路径得到实际的 1024 × 512 图像。模型运行时使用带线性 sRGB 和 BT.709 原色标记的 RGBA16F 输入、输出。探针还对读取的全部 60217344 个源像素求极值，并在处理前后核对 ARW 的 SHA-256。[原始数据](super-resolution-tiles.json) · [模型资源就绪记录](super-resolution-model-resource.json) · [复现脚本](../../../../scripts/performance/ProbeSuperResolutionTiles.swift)

这张 ARW 线性红通道的范围为 −0.00310 至 1.32520，绿色为 −0.00142 至 1.31641。模型将校准图中的 −0.125 输出为 0，将 1.5 和 3 都输出为 1。输入 0.18 和 0.5 则分别得到 0.18042 和 0.50195。直接使用该路径会丢失可从原片恢复的高光。[校准图与原片的测量值](super-resolution-tiles.json)

我们在同一原片区域中央分成两块，从各块边缘剔除重叠像素，再把输出与整块推断比较。下表记录拼接处左右约 32 个输出像素内，每个像素最差 RGB 通道的绝对线性差。[分块和逐像素比较](../../../../scripts/performance/ProbeSuperResolutionTiles.swift)

| 单侧重叠宽度（源像素） | 接缝 P95 误差 | 接缝最大误差 |
| ---: | ---: | ---: |
| 0 | 0.004883 | 0.020538 |
| 16 | 0.002930 | 0.006836 |
| 32 | 0.001984 | 0.004028 |
| 64 | 0.001953 | 0.004028 |

Camera Raw 的 Super Resolution 对每条边放大 2 倍，对这张原片即 19008 × 12672、240869376 个像素。实测中 64 像素重叠仍有约 264 个线性 16 位码值的峰值差。该模型组合尚未通过高光和接缝验证。因此系统 4× 组合只保留裁块实验。正式编辑、配方和全幅 2× TIFF 输出使用下述摄影模型。[完整裁块记录](super-resolution-tiles.json) · [Adobe 的 Enhance 定义](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/sharpening-and-noise/enhance.html)

摄影模型 upconv_7 的最后一层以步长 2 预测四个子像素。其上游权重使用 MIT 许可，SHA-256 为 `deb2c288f635bed4a0ffc0be9ca8f6a735233b530ad5b2c392c5b2e6c5fe30ad`。测试在每个通道上保留源像素的四格均值，并把高频变动限制在原生 3 × 3 邻域的范围。Sony ARW 的完整线性 FP16 诊断 TIFF 为 19008 × 12672，推理并写入用时 27.499 秒，文件 1,445,232,640 字节。重读整图后的线性范围仍为 −0.003096 至 1.325195，每组四格恢复源像素的最大误差为 0.00036621。128 像素块与四块 64 像素拼接的所有通道完全相同。进程峰值 RSS 为 2,138,800,128 字节，进程内 Metal 分配采样峰值 234,225,664 字节，Core ML 系统服务占用另计。[原始数据及像素证据](super-resolution-learned-full.json) · [上游模型](https://github.com/nagadomi/waifu2x/blob/cc385f97a9debfe611316aabfd5d8bb30ba2dbeb/models/upconv_7/photo/scale2.0x_model.json) · [权重许可](https://github.com/nagadomi/waifu2x/issues/478#issuecomment-5003816684)

编辑器的“超分辨率 2×”随配方保存，支持撤销和重做。模型在现有调整、蒙版、裁剪和裁剪后暗角都完成后运行。输出使用当前导出面板选择的色彩空间和整数编码。每个 2 × 2 子像素单元保留一个原生线性像素的均值，因此低于原生分辨率的 FIT 可直接读取这一层均值，超过原生分辨率的预览和输出使用网络预测。实测小图的透明度、坐标、任意跨块裁剪以及 JPEG8、PNG16、TIFF16 的 ICC 和尺寸。完整 Sony RAW 以正常开发服务导出 19008 × 12672 的 sRGB TIFF16。同一 GPU FlashRaw 源在独立 Core ML 实现中生成 FP16 参照图，逐个重读常规 TIFF 的 240,869,376 个像素，722,608,128 个通道的平均线性绝对误差 0.00001250，P95 小于 0.0000542，最大 0.00026209。[正常预览与导出记录](super-resolution-native.json) · [全部像素对照](super-resolution-output-pixels.json) · [分块与格式测试](super-resolution-small.log) · [保存与撤销测试](super-resolution-undo.log)

最初独立渲染采用 FlashRaw 的 CPU 后处理，应用采用 GPU 后处理，整张约 7.23 亿个颜色通道中有 2 个相差超过 0.001。在最偏离的传感器坐标（7278，3100），CPU 与 GPU 红值相差一个 FP16 ULP。让两个超分辨率实现接收同一 GPU 解码结果后，三个通道在该位置的最大误差降为 0.0000119。[该位置的输入和像素](super-resolution-flashraw-backends.json) · [同输入的完整浮点参照](super-resolution-gpu-input-reference.json)

超出单张 GPU 纹理宽度时，正式 TIFF16 逐条写入，并保留四个通道与嵌入 ICC。Sony 输出的像素缓冲从整图的 1,926,955,008 字节降至 58,392,576 字节，每次持有 384 行。全图 963,477,504 个 RGBA16 值与原先整幅 Image I/O 编码完全相同。单次保存从 11.849 秒变为 12.849 秒。新路径正式保存期间采样峰值为驻留内存 1.537 GB、物理占用 3.536 GB、进程内 Metal 分配 2.859 GB。独立地重新解码并核对成品图时，驻留内存达到 7.306 GB。发布脚本分别记录预览、导出及复读，并校验正常导出的性能与容量。[两种编码逐值对照](super-resolution-strip-transport.json) · [正式发布基线](super-resolution-comparison.json) · [发布校验器](../../../../scripts/check-super-resolution-performance.py)

RAW 9 发版检查分别对照三个首次 Amount、三次重放及全尺寸 TIFF16 的独立耗时，重新核对非零与零强度的像素以及内存回收。指定的历史基线缺失会终止对照。[RAW 9 回归指标](raw9-denoise-comparison.json) · [发版校验器](../../../../scripts/check-raw9-performance.py)

## 相同 Sony RAW 的 Adobe 16 位参照

Camera Raw 19.0（2794）已在 Photoshop 28 的公开 `CameraRAWOpenOptions.SELECTEDIMAGE` 入口静默打开未编辑的副本。原 RAW 与工作副本 SHA-256 相同，macOS 前台应用在打开和保存前后相同。实际 TIFF 由 Image I/O 再次确认是 9504 × 6336、三通道、每通道 16 位，嵌入 sRGB IEC61966-2.1。一次文档打开耗时 773.079 ms，单独保存 TIFF 耗时 155.393 ms。两次独立打开后读取 TIFF 的无压缩 16 位光栅，361,304,064 字节逐字节相同。该文件为直接 Adobe 渲染的未增强基线。三项 Adobe 增强分别需要同一照片由 Adobe 实际生成的增强结果，目前没有对应输出可评估模型质量。[原始尺寸、摘要与 ICC](adobe-enhance-baseline.json)

临时会话已备妥四个相同 SHA 的独立副本，分别对应未编辑、降噪 50、Raw Details 和 Super Resolution。正式导出器要求后三项先具有实际生成的非空 XMP 或 ACR 旁车。它只在已运行的 Photoshop 中打开这些副本，同时复核未编辑基线的整幅 16 位像素、增强后的实际尺寸与像素变化、原片与旁车摘要，并保存 Photoshop 写回的 XMP。若设置在 Lightroom 中生成，导出清单将设置来源与最终 Photoshop Camera Raw 渲染宿主分别记录。新的 2× 参考必须实际达到 19008 × 12672。[可重放的导出入口](../../../../scripts/performance/adobe-enhance-reference.py) · [独立会话清单](history/adobe-enhance-session.json)

本机 Lightroom Classic 16.0.1 的 Develop SDK 导出 `setEnhance`、`getEnhancePanelState` 和 `changeDenoiseAmount`。已扫描的 Camera Raw 1,022 个和 Lightroom Classic 1,075 个公开 XMP 预设没有这三项非破坏性增强的输入模板，Camera Raw 的公开 Apple Event 词汇只给出普通颜色/亮度噪声项。Lightroom 的官方插件装载依赖应用的插件管理器或用户/系统 Modules 目录。该机没有已经启用的通用自动化宿主，未能确认在临时目录内独立启动 Develop、同时隔离当前桌面和插件状态的公开接口。三个增强参考仍待独立会话录制。[Lightroom SDK](https://developer.adobe.com/lightroom-classic/) · [Adobe 的插件装载规则](https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-presets-settings-plug-ins.html) · [Adobe 的增强说明](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/sharpening-and-noise/enhance.html)

用同一张 Sony RAW 在 Photoshop 已运行的机器上复现未增强基线。第二条命令会在会话目录中生成 `baseline.tif`。

```sh
python3 scripts/performance/adobe-enhance-reference.py prepare --source "$RAW" --session "$SESSION"
python3 scripts/performance/adobe-enhance-reference.py export --session "$SESSION" --states baseline --settings-author "Camera Raw 19"
```
