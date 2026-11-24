# 局部黑位、白位的 Metal 舍入

在 Apple M4 Max、macOS 27.0.1 上，调整 Rust 着色器的三处乘加表达式后，两个正式 RAW、两个控件、每个控件两档参数均复现了原 Core Image 渲染。逐位比较覆盖 439,934,976 个原尺寸 RGBA32F 像素、109,983,744 个半幅 RGBA32F 像素，以及八张 2400 × 1600 的完整 sRGB8 画面。输入来自 FlashRaw 0.3.1 上传并核验的原片纹理，每个测试使用原引擎生成的全尺寸 Float32 蒙版。[逐状态记录、运行库与源片 SHA-256](evidence/native-mask-tone-metal-rounding.json)

| 原片与控件 | 参数 | Batch 28 原尺寸差异像素 | Batch 28 显示差异像素 | 调整后原尺寸 / 半幅 / 显示差异 |
| --- | --- | ---: | ---: | --- |
| 9504 × 6336 黑位 | −0.15 / −0.55 | 8,096,323 / 8,835,202 | 6 / 2 | 两档均为 0 / 0 / 0 |
| 8640 × 5760 黑位 | −0.15 / −0.55 | 521,211 / 8,727,260 | 0 / 2 | 两档均为 0 / 0 / 0 |
| 9504 × 6336 白位 | +0.15 / +0.55 | 0 / 0 | 0 / 0 | 两档均为 0 / 0 / 0 |
| 8640 × 5760 白位 | +0.15 / +0.55 | 1 / 1 | 0 / 0 | 两档均为 0 / 0 / 0 |

最终使用 Batch 29 应用封存的同一 Rust 动态库又复演了两张原图的全部八种局部控件，各取两档。32 个状态的原尺寸、半幅和正式显示都逐位相同。公开 Metal 缓冲区另复演 393,216 个原有输入，32 个输出文件的 SHA-256 均与 Batch 28 已验证的缓冲区结果相同。[最终运行库、两张图的逐态摘要与缓冲区回执](evidence/native-mask-tone-metal-rounding.json)

### 实际舍入边界

主片原生坐标 (3927, 1326) 的黑位样本曾将蓝通道的 Float32 位串从原版的 `0x3ba47cd2` 变为 `0x3ba47cd3`。相同的输入、覆盖和参数通过封存库的公开 IOSurface 接口可以复现。将 `0.05 × amount` 先作为 Float32 系数，再以 `fma(-scale, coverage, channel)` 和 `fma(-scale, coverage, 1)` 构造分子、分母，修正了这个样本，也通过了两张原图。软件对照支持旧的 IOSurface 编译结果改变了乘法的结合顺序。具体机器指令仍属推断。[着色器表达式](../../Modules/ImageEdit/src/mask_tone_v3.wgsl) · [原 Core Image 公式](../../Modules/ImageEdit/shaders/mask.ci.metal)

次片的两个白位反例位于 (6388, 4140) 和 (5766, 4397)。两处覆盖的位串分别为 `0x3f7ff90b` 和 `0x3e426542`。把显式乘加放在亮度或覆盖的末端，只能分别修正其中一个点。先计算 `fma(0.35, amount, 0.0)`，再按原顺序乘亮度权重与覆盖，两个点以及两张全图的所有像素均匹配。配方参数、烘焙蒙版格式和 C ABI 沿用既有版本。[反例输入、预期及旧输出位串](evidence/native-mask-tone-metal-rounding.json)

### 验证与复现

通过公开的 `rm_image_metal_frame_bind_v2` 绑定独立 IOSurface 图像与具名蒙版，每个原生带等待 GPU 完成后才比较数据。Core Image 整图正常入口和原有硬件半幅采样分别提供显示与半幅对照。主片每态 25 带，次片每态 23 带。完整 RAW 回放入口和所需原片哈希沿用已有封存方法。[原生回放源码包](evidence/portable-local-mask-tone-sources.tar.gz) · [局部色调配方](portable-local-mask-tone.md)

三个发生过偏差的真实像素已纳入 C ABI 回归。测试对 Metal 缓冲区和 IOSurface 两个入口的结果逐位断言，CPU 独立检查每个分量的绝对误差不超过 `2e−6`。在 Metal Mac 的仓库根目录执行以下命令可复现。[回归用例](../../Modules/ImageEdit/tests/metal_surface/c_abi.m)

```sh
Modules/ImageEdit/tests/metal_surface/check.sh output/035-development/metal-rounding-replay
```

另取 2,048 组不透明浮点颜色和覆盖，输入 RGB 从 −16 到 32。黑位测量 −2、−1、+1、+2，白位测量 −1、−0.55、+0.55、+1。以原始 `rmMaskTone` 和同一扩展线性 sRGB 工作空间为对照，16,384 个 RGBA32F 像素全部逐位相等，其中一个还原通道达到 43.2。这一组合覆盖负色值、HDR、控件端点以及部分覆盖。不透明蒙版算子的这项验证与透明输入处理、软件 Vulkan、交互延迟分别验收。[合成样本与原内核 SHA-256](evidence/native-mask-tone-metal-rounding.json)
