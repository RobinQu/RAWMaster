# 局部色调节点与冻结蒙版

`mask_tone_v3` 把一张已编辑或原始图像、一个具名 Float32 蒙版和一个局部控件接入版本 2 配方。图像采用预乘 alpha 的扩展线性 sRGB。蒙版值在 `[0,1]` 内，曝光、对比度或色相的计算在每个像素直接使用覆盖值。例如曝光使用 `exp2(2 × amount × coverage)`。节点沿用现有的具名绑定和 C ABI。可运行的配方、按状态核对的 SHA-256 和软件 Vulkan 的单像素反例见[独立回执](evidence/portable-local-mask-tone.json)。

```json
{
  "version": 2,
  "working": "extended-linear-srgb-premul-f32",
  "output": "local",
  "nodes": [
    {"id": "input", "op": "source"},
    {"id": "ellipse", "op": "mask"},
    {"id": "local", "op": "mask_tone_v3", "image": "input", "mask": "ellipse", "control": "exposure", "amount": 0.125}
  ]
}
```

| `control` | 配方中的 `amount` |
| --- | --- |
| `exposure` | −2 至 2。示例在覆盖值为 1 时增加 0.25 EV |
| `contrast` | −1 至 2 |
| `blacks` | −2 至 2 |
| `highlights`、`shadows`、`saturation`、`whites`、`hue` | −1 至 1 |

每个节点表达一层中的一个控件。控件数量、取值、端口类型、具名覆盖和源像素在解释配方或绑定帧时校验。中性层、零覆盖和合法透明输入保留原始像素。非零覆盖下的颜色按原 `rmMaskTone` 的顺序执行，包括有符号 sRGB 编解码和末尾的饱和度计算。可在[配方解析器](../../Modules/ImageEdit/src/graph.rs)、[WGSL](../../Modules/ImageEdit/src/mask_tone_v3.wgsl) 和 [C++ CPU 执行器](../../Modules/ImageEdit/src/reference.cpp) 核对。

## 真实照片验证

正式画布的两张 Sony RAW 分辨率为 9504×6336 和 8640×5760。每张从经过来源核对的 FlashRaw 0.3.1 私有不透明 RGBA16F 图像开始。八个控件各取正式归档的两档参数，使用原尺寸冻结 Float32 蒙版。逐一比较原生 RGBA32F、同一硬件采样器产生的半幅 RGBA32F、同一 Core Image 输出路径产生的 2400×1600 整张 sRGB8。独立控制路径也必须完整复现正式应用归档的显示 SHA-256。[逐项数值](evidence/portable-local-mask-tone.json)

零羽化椭圆在归一化半径 1 之外仍有宽度 0.00001 的过渡。独立重建几何在首张照片的两个曝光状态各改变 117 个原生像素。采用原引擎的冻结覆盖后，独立 Rust/Naga 着色器正确保留 `h / 6 - floor(h / 6)` 的八个控件在两张照片的上述三个层级均逐位一致。色相改用 `fract(h / 6)` 仍能通过归档显示 SHA，但在原生层改变 23,949 至 107,053 个像素。[几何与色相对照](evidence/portable-local-mask-tone.json)

从封存的 Batch 28 应用载入真实 Rust 运行库，通过公开 IOSurface C ABI 逐带提交原始 F32 图像与具名 F32 蒙版。32 个状态中，原生和半幅各有 26 个逐位相同，整张 sRGB8 有 29 个逐位相同。黑位的四个状态均有原生差异，主片的两个状态最终分别改变 6 和 2 个像素，次片高档改变 2 个像素，最大均为一级。次片两个白位状态各有一个原生像素差异，最终显示均逐位相同。全部原生差异绝对值至多 1.1920929×10⁻⁷，所有 alpha 未变。[运行库快照和逐态实测](evidence/portable-local-mask-tone.json)

独立抽取两图共 393,216 条真实源像素、冻结覆盖和原生期望值，经公开缓冲区版具名 C ABI 复演。macOS Metal 的这批缓冲区样本全部逐位相同。macOS 与 Linux ARM64 CPU 逐状态输出 SHA-256 相同，对原生显影的最大绝对误差为 1.60933×10⁻⁶。Linux 的 Mesa 22.3.6 软件 Vulkan 在首张照片色相 +0.45 的一个绿色分量超过 2×10⁻⁶，最大误差为 2.0861626×10⁻⁶。对采用该预算的服务端显影，已有通过的 Linux CPU 路径。[后端回执与复现像素](evidence/portable-local-mask-tone.json)

原始照片的 alpha 均为 1。另用覆盖值 1、正的最小非正规 Float32 alpha（位串 0x00000001）和最大有限红分量测试曝光，CPU 拒绝反预乘溢出，并保留原输出缓冲区。Metal 缓冲区后端接受输入并返回源像素位。对需要在该数值范围重现 CPU 错误行为的服务，请使用 CPU 路径。[单像素输入与返回值](evidence/portable-local-mask-tone.json)

这 16 个主照片状态在 Batch 27 正式归档中的首次精确画面中位为 74.93 ms。在原 74 个样本内将其耗时全部设为零，其余样本沿用实测值，整体中位仍为 81.40 ms，目标为 24.35 ms。该计算表达这一组控件能影响的范围。节点的真实表现另需通过正常入口的调度和物化计时。[测量与反事实计算](evidence/portable-local-mask-tone.json)

## 双端复验入口

```sh
cargo test --locked --release --no-default-features --manifest-path Modules/ImageEdit/Cargo.toml
cargo test --locked --release --manifest-path Modules/ImageEdit/Cargo.toml --test mask_tone_v3 -- --ignored
```

第一条覆盖 CPU、严格参数与现有配方。第二条在 Metal 或 Vulkan 设备上使用同一程序重绑定八种控件，并核对融合和分阶段执行。[针对性测试](../../Modules/ImageEdit/tests/mask_tone_v3.rs)

完整的源文件和两张照片各 16 项配方已打包。使用原 RAW、对应的正式归档和封存运行库即可重放。包内说明列出了需要的输入、构建命令和两个正式入口。[独立原生与服务端复现源码](evidence/portable-local-mask-tone-sources.tar.gz)

## Batch 29 封存运行库复验

黑位在分子和分母使用原内核对应的融合乘加。白位先把 `0.35 × amount` 舍入为 Float32，再沿原顺序应用亮度权重和蒙版覆盖。公开 IOSurface C ABI 用两张 RAW 原尺寸重测 32 个状态，原生 Float32、硬件采样半幅和最终 sRGB8 全部逐位相同。另有三个归档像素和 16,384 个负值、高动态范围及端点样本通过。旧版差异保留在上节，供核对修复前后的量级。[黑白位公式、输入和验证](portable-mask-tone-metal-rounding.md)

Vulkan CPU 适配器使用数值修正后的色相编码，在现有有符号 sRGB 传递函数中校正幂函数误差。真实两图共 393,216 个窗口像素全部达到 `2e-6` 绝对误差门，原反例的最大差降至 `1.78814e-6`。Metal 沿用原色相编码并通过四个整图色相状态。硬件 Vulkan 也沿用原编码，待目标设备实测。[后端选择、逐项样本及源码](evidence/portable-mask-hue-vulkan.json)

对正的次正规 alpha，GPU 从 Float32 位串执行反预乘和再预乘，每一步只舍入一次。公开缓冲区与 IOSurface 均通过最小正值下的溢出拒绝、正负零覆盖和合法小值测试。借入输出遇到无效输入、算子溢出或请求失效时，调用者继续按现有状态码丢弃私有帧。公开缓冲区在失败时保留调用者的原内容。65,536 个带正次正规 alpha 的生成样本经 macOS CPU／Metal 和 Linux CPU／软件 Vulkan 验证，四份完整结果逐字节相同。[Float32 内核](../../Modules/ImageEdit/src/mask_tone_v3.wgsl) · [公开接口回归](../../Modules/ImageEdit/tests/metal_surface/c_abi.m)

SwiftUI 实时蒙版定稿沿用现有 Core Image 路径。Rust 节点已通过原始覆盖图和已归档 AI 覆盖的双端执行验收。[编辑与功能验收](acceptance.md)
