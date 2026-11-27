# 算子、配方与执行契约

本页记录 035 旧 SDR 点配方执行、实验和实拍证据。版本冻结编辑语义，执行回执记录实际后端。场景 AP1 配方和端口由 [037](../037-color-film-hdr/spec.md)／[038](../038-node-dag-workflow/spec.md) 定义，macOS 场景执行由 [039 Rust 场景后端](../039-rust-scene-backend/spec.md) 定义。两个入口共享的演进目标见[联合实施和验收](roadmap.md)。[035 可运行 JSON](../../experiments/portable-processing/image/examples/local-look.json) · [原生输入输出](validation.md)

## 配方与端口

每个配方包含 schema、算子规格版本、工作颜色配置、唯一节点 ID、有序的命名输入端口、参数和输出根。资产 URI 指向被授权的内容身份。生产算子由引擎登记，配方只声明操作及数据。预设或批量模板通过 `source`、`coverage` 和目标修订等槽位实例化。控件展开状态、画布缩放、选择哪个节点、当前视窗、任务 ID 存在宿主／提交清单中，独立于配方像素身份。

| 类型 | 必需信息 | 例子 |
| --- | --- | --- |
| Sensor / Image | 来源摘要、校准与解码版本、尺寸、原点与方向。颜色原色／白点、传递函数／ICC、参考亮度（涉及 HDR 时）、alpha、格式、行距、有效区域 | RAW/CFA → 去马赛克与输入变换 → 已定向图像。桌面系统 RAW 与服务端解码应有不同能力和结果键。 |
| Coverage / Depth / Tensor | 几何映射、值域／单位、格式、采样与边缘规则。模型输入另含布局、通道顺序、归一化、缩放与补边 | 标量覆盖 0–1。距离图和概率图须由显式算子转换。8 位灰度快照读作覆盖，绕过 ICC。 |
| LUT / Model / Patch | 内容摘要、版本、角色、输入／输出色域、网格与插值或模型预处理、结果 ROI | 滤镜 LUT 与其强度平面。指定模型和权重。修复补丁及有效 matte。 |
| RenderIntent | 输出分辨率／ROI、代理或全质、可接受精度、ICC、显示／导出变换和编码 | 拖动代理、稳定预览、直方图、打印／导出。要求不同可共享满足条件的上游结果。 |

```text
                     ┌─ global exposure +0.25 EV ────── base ─┐
oriented source ─────┤                                       ├─ masked blend → output
                     └─ local exposure −0.5 EV → RGB matrix ─ layer ─┤
immutable coverage ───────────────────────────────────── mask ─┘
```

示例的 JSON 列表刻意把输出写在输入前。编译器从根回溯、检查重复 ID、连接与端口类型、环、数量和未知字段，随后为共享上游分配一次计算。实验支持一个来源、至多一个覆盖输入、64 个节点、有序的 base/layer/mask，拒绝脱离输出的节点。生产版预检还需验证模型、滤镜资源、坐标变换、缓存／内存预算与后端能力。批次先冻结条目清单，以同一结构共享编译结果，每张独立绑定 source、mask、解析后的相机／白平衡与目标版本。把一张照片的分析蒙版放进另一张，必须在任何像素运算前以来源／几何不匹配失败。[编译器](../../experiments/portable-processing/image/src/graph.rs) · [绑定校验和双库测试](../../Tests/RAWMasterUITests/PortableProcessing035Tests.swift)

## 色彩控件与精度

SwiftUI 和服务端从同一 `OperatorSpec` 取得稳定参数 ID、单位、默认值、启用条件、有效范围、映射曲线、运算色域和版本。UI 可本地化名称或选择显示刻度，保存值由 Rust 进行规范化。浮点参数保存可无损还原的数值或位模式。缓存键按规范化编码计算，拒绝 NaN／Inf，按算子约定把负零归一化。既有配方的 Double 精确端点判断须保留到编译阶段，避免转为 Float 后改变 100% 等边界分支。

| 当前控制或处理 | 生产图处理规则 | 本轮证据 |
| --- | --- | --- |
| 曝光／白平衡 | 新线性曝光用 EV，RGB 乘以 `2^EV`，alpha 透传。已有 V3 light 字段限 `-2…2`，legacy EV 可达 `-10…10`。RAW 原生曝光与温度／色调含解码器基准。迁移器读取原版本、源能力和已解析 WB，分别映射。解码后 RGB 曝光不能替代所有相机原生运算。 | 两条线性曝光和混合有 C++ 参照、WGSL 与端点样例。PoC 接受的 EV 范围是实验 IR 的范围，Swift 现有控件范围由旧规格决定。[V3 校验](../../Sources/RAWMasterCore/DevelopmentAdjustmentsV3.swift) · [RAW 参数](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift) |
| 滤镜／LUT／曲线 | 逐项声明输入域、轴、强度插值、曲线端点、透明度、负值与超白边界。当前 Photos 风格滤镜使用 delta64、强度平面、手工三线性采样及特定 HDR 残差。把查表时的编码／解码作为明确边界，保留旧表摘要和 0/1/25/50/100 平面语义。 | 本轮滤镜样例是三通道矩阵，证明分支、参数绑定和融合。产品 3D LUT、曲线及全套滤镜的像素验收安排在批次 C。[当前滤镜算子与独立参考](../../Sources/RAWMasterImaging/DevelopmentPhotoFilterEngineV3.swift) · [已有资源](../../Sources/RAWMasterImaging/Resources/PhotoFilters/catalog-v1.json) |
| AI 蒙版与修复／其他 AI | 输入适配节点显式把指定上游转换成模型需要的 RGB、tensor 和尺寸。覆盖回到已定向原图源平面，点选和局部编辑带 source/version/ROI。分割输出 Coverage，降噪输出 Image，深度输出 Depth，修复输出 Patch＋Coverage，超分输出带新尺度的 Image。只有改变模型输入、参数或权重时才重推理。模型缺失、空选区、取消、候选待采用要有各自的结果。 | 当前 MaskAI 实跑天空模型。JPEG 和真实 RAW 的绑定快照进入同一混合算子。在蒙版为零处逐像素对照 base 分支。深度、补丁和超分为后续算子。[MaskAI 快照](../../experiments/MaskAI/Sources/MaskAI/SemanticModels.swift) · [真实验收](validation.md) |
| 精度与交付 | 兼容工作域 extended-linear sRGB / D65 / FP32 premultiplied。线性算子保留负 RGB、HDR 和原 alpha。非线性算子声明何时解预乘／复乘以及近零 alpha 的规则。透明黑端点须精确。FP16 存储或混合精度须逐节点校准动态范围、微弱渐变、光晕与软边。累计／直方图等另定宽度。显示 P3、sRGB、输出 ICC、HDR 映射及整数量化在明确的 sink 或转换节点执行。 | Rust 入参校验有限值，C++/WGSL FP32 对照。Swift 使用扩展线性 RGBAf 读入、只在测试交付时转标记 sRGB 的 PNG。Adobe RGB、P3、CMYK、打印 ICC、PQ/HLG 及显示 EDR 仍需实图和色卡验证。[既有工作空间](../../Sources/RAWMasterImaging/DevelopmentColorEngineV2.swift) |

## 从图编译到设备提交

1. **编译与缓存。** 拓扑顺序和连接、算子／编译器版本、端口格式、融合域和后端能力形成计划键。控制值进入单独的参数缓冲区，改变结构／能力或参数决定的执行路径时重新编译。内容结果键为算子版本＋规范化参数＋有序上游结果摘要＋资源／模型＋解码配置＋几何／颜色／精度／质量／ROI。跨设备复用最终结果还包含实现与数值兼容级别。缓存命中须满足质量要求及最后一次写入已完成。本轮实现会话持有编译计划、参数可重绑，持久子图缓存属于后续实现。
2. **点运算融合。** 数据已在同一工作空间、同采样位置且没有邻域依赖时，可把分支、矩阵、曝光与混合编译为一次 compute dispatch。先按顺序生成局部值，共享节点只算一次。逐节点对照后端同样按拓扑执行。最后一个消费者之后才复用中间槽，输入与本次输出不得别名。设备每 pass 的资源转换由 wgpu 跟踪，宿主等 fence 后再回收。实测的驻留更新只写参数。CPU 读回与 GPU 时间分别报告。[GPU 实现](../../experiments/portable-processing/image/src/gpu.rs) · [Shader](../../experiments/portable-processing/image/src/kernels.wgsl)
3. **非局部与 AI。** 卷积／羽化从输出 ROI 反推邻域 halo。透视、旋转和裁切用逆几何求源区域并处理边缘采样。全局直方图、自动曝光等先归约，再将小结果广播给瓦片。模型推理是独立资源作业，以可追溯资产返回。需要前缀像素的节点必须在该前缀完成后执行。融合不能跨越色域变换、量化、随机种子、全局归约、模型回调或改变采样坐标的边界，除非新计划独立验证等价。
4. **内存预算。** 计划列出并发存活的纹理／缓冲、分辨率和格式，合并 GPU fence 之前仍被引用的上代资源。按设备预算做入场、瓦片、spill 或延迟。CPU 页锁定内存、驱动内部分配、模型峰值和读回 staging 分项计量。PoC 的有界路径按行切条，对点算子没有 halo。同样尺寸在融合模式每像素的显式数据为源和结果各 16 B、覆盖 4 B、读回 16 B。固定参数另计。当前有界实例先带回每条结果，生产画布应直接使用可呈现纹理。
5. **故障。** 编译前的无效图返回节点和端口，交互请求过期时在入队、提交和回调时检查修订。已提交的 GPU 执行等待 fence 后丢弃过期结果。设备丢失清空设备域缓存，重新创建资源或路由到有对应规则的 CPU 后端，旧票据失效。导出固定全质输入和目标配置，每个阶段输出可校验摘要。能力不匹配须报告原因，保持原版本可以打开。

## 已实现的命名蒙版配方

生产 Rust 图的 `version: 2` 支持一个图像输入、128 个节点和最多 32 个 `mask` 节点。`masked_exposure` 和 `blend` 各引用一个命名蒙版，同一个节点可供多个下游使用。宿主按 `mask` 的 ID 提供有限的 `[0,1]` FP32 覆盖平面，平面采用原图已定向的同尺寸、零原点网格，按上至下行紧密排列。ID 按 UTF-8 字节匹配，宿主可任意排列描述符。缺失、重复和多余 ID、错误尺寸和无效数值都会拒绝。合成保持扩展线性 sRGB、预乘 RGBA FP32 和原 alpha。零覆盖处精确保留该节点的基底输入。[图与输入校验](../../Modules/ImageEdit/src/graph.rs) · [CPU 执行器](../../Modules/ImageEdit/src/reference.cpp)

ABI 1 增加 `rm_image_plan_open_v2`、`rm_image_plan_render_v2` 和 macOS 的 `rm_image_metal_frame_bind_v2`。v1 配方及其单蒙版符号继续提供原来的接口。Swift 宿主使用显式 ID 数组传入覆盖。已保存的语义蒙版进入图之前，Swift 验证原件捕获、方向、网格、快照及 PNG 摘要，沿用原显影的覆盖和不透明度。取消和来源授权检查覆盖物化前、逐平面等待后及返回时。此次接入提供原生和无界面的重放入口，日常显影及导出继续调用既有 V3 渲染路径。[C 栅格契约](../../Modules/ImageEdit/include/rawmaster_image.h) · [Metal 借入契约](../../Modules/ImageEdit/include/rawmaster_image_metal.h) · [Swift 来源绑定](../../Sources/RAWMasterImaging/DevelopmentPortableFrozenCoverage.swift)

wgpu 缓冲区后端将同一条带的各个覆盖平面按图编译顺序写入一个缓冲区。切带依据实际平面数、存储绑定大小、派发范围和预算计算。C 栅格 GPU 入口为显式设备缓冲区分配 256 MiB 预算，宿主数组与驱动占用另算。Metal 借入路径绑定各自的 R32Float IOSurface，与输入及输出使用不同的底层存储。设备纹理绑定限制、宿主分配预算和完成后修订检查仍适用。2400×1600 的两张 R32Float 平面需 30.72 MB 像素数据，32 张 9504×6336 平面需约 7.71 GB，两者都需另计行对齐。计划上限只约束图结构，实际入场由设备能力和预算决定。[wgpu 缓冲区](../../Modules/ImageEdit/src/gpu.rs) · [Metal 表面](../../Modules/ImageEdit/src/gpu/metal_surface.rs)

### 冻结蒙版的局部调色节点

`mask_tone_v3` 为配方 v2 节点，读取 `image` 图像和引用命名覆盖的 `mask`。每个节点用 `control` 选一项，再给对应 `amount`。曝光和黑位范围为 `[-2,2]`，对比度范围为 `[-1,2]`，高光、阴影、饱和度、白位及色相范围为 `[-1,1]`。参数以配方原精度校验后转为 FP32。曝光 `amount` 采用旧局部调整存储单位，完整覆盖时 `0.125` 对应 `+0.25 EV`。宿主保存色相细调时，按原 Float32 系数计算有效量后传入。[配方校验](../../Modules/ImageEdit/src/graph.rs)

执行在扩展线性 sRGB／预乘 RGBA FP32 域中沿用原 V3 局部调色顺序和有符号 sRGB 转换。零覆盖、零 alpha 和中性节点逐位直通。v2 的 C 栅格和 Metal 符号继续接收按名称绑定的相同覆盖。节点可串接胶片等图像操作，也可在同一个图中使用多张冻结覆盖。径向覆盖对照使用从原渲染器实际读回的 FP32 平面，直接算解析边界的对照在部分边缘像素产生差异。已存 AI 蒙版由 Swift 继续核验输入和快照后再提供覆盖。[着色器](../../Modules/ImageEdit/src/mask_tone_v3.wgsl) · [实际 Swift 冻结重放](../../Tests/RAWMasterImagingTests/PortableFrozenCoverageTests.swift)

GPU 对正次正规 alpha 使用整数有效数完成反预乘与再预乘，舍入到最近的 Float32，平局取偶。反预乘溢出由原发布校验拒绝。Metal 按位校验输入，接受正负零，拒绝负覆盖、负 alpha 和透明像素中的非零 RGB。软件 Vulkan 的有符号 sRGB 色相编码在幂函数环节做一次牛顿校正，适配器选择按 Vulkan CPU 类型确定。两张 RAW 的局部调色状态与扩展 Float32 边界分别验收。[跨后端数值与成片](portable-local-mask-tone.md#batch-29-封存运行库复验)

## V3 基础调色节点

`version: 2` 的 `basic_v3` 节点读取命名 `image` 端口。`light`、`color` 和 `blackAndWhite` 三组可分别提供，存在即代表启用，次序与 Swift V3 点运算相同。亮度和黑点接受 `[-2,2]`，反差、饱和度和自然饱和度接受 `[-1,2]`，白点、色偏、中性色和黑白色调接受 `[-1,1]`，黑白强度接受 `[0,1]`。参数先在配方原精度核验，再转为 FP32。黑白强度为 0 的启用组仍会转灰。单独启用的全零光线或色彩组直通原像素。透明像素原样保留，其他像素在算子内部解预乘、调色和重新预乘。节点可以参与曝光、滤镜和命名蒙版分支。v1 拒绝这一节点。[配方校验](../../Modules/ImageEdit/src/graph.rs) · [CPU](../../Modules/ImageEdit/src/reference.cpp) · [GPU](../../Modules/ImageEdit/src/basic_v3.wgsl)

`RAWMASTER_QA_PORTABLE_BASIC_PREVIEW=1` 让符合条件的交互请求借用已经持有的完整代理纹理。图编译后可对同一槽位重新绑定参数。完整代理网格及纯点调色在同一声明中核验，包含空间光线、颗粒、活动黑白混合器或几何变换的配方进入现有渲染路径。完成等待和画布授权继续贯穿借入与交付。此开关默认关闭。CPU 重放的跨平台摘要一致性与相对 V3 的数值误差各有实际回执。[Swift 接入](../../Sources/RAWMasterImaging/PreviewPortableBasic.swift) · [真实 RAW 像素回执](evidence/native-dehaze-and-portable-basic.json)

同一预览服务按实际 `MTLDevice` 身份为纯曝光、基础调色、曲线和色阶三种拓扑各保留一个已编译程序。程序可跨原件会话复用，每帧按当前照片重新绑定参数、纹理和修订，再等待 GPU 并核对发布授权。渲染失败清退对应程序后可重试。设备变更、预览服务重配、内存压力或关闭服务时清退程序，资源清理服从原有工作者等待边界。[程序所有权](../../Sources/RAWMasterImaging/PreviewPortableBasic.swift) · [原生调用与回退](../../Sources/RAWMasterImaging/PreviewInteractiveProxyV3.swift) · [跨片验证](acceptance.md#batch-23-跨片程序复用与去雾授权)

### V2 全局色轮

配方 v2 的 `color_grading_v2` 节点从命名 `image` 输入读取预乘 FP32 图像。`grading` 沿用原色轮的 `shadows`、`midtones`、`highlights`、`global`、`blending` 和 `balance`。每个色轮有 `hueDegrees`（`[0,360)`）、`saturation`（`[0,100]`）与 `luminance`（`[-100,100]`）。混合与平衡分别为 `[0,100]`、`[-100,100]`。四个色轮的饱和度及亮度均为零时，直接透传源像素。[原控件](../../Sources/RAWMasterCore/DevelopmentColorModels.swift) · [配方准备](../../Modules/ImageEdit/src/color_grading.rs)

编译以输入双精度准备色轮系数，随后写入可重绑的 Float32 参数表。像素在有符号 sRGB 域计算暗部、中间调、高光权重及全局偏移，转换回扩展线性 sRGB 后按原 alpha 预乘。透明端点和反预乘溢出遵循原有验证合同。CPU、融合 GPU 和分阶段 GPU 使用同一配方，C ABI 无需增加符号。[GPU 实现](../../Modules/ImageEdit/src/color_grading_v2.wgsl) · [C++ 执行器](../../Modules/ImageEdit/src/reference.cpp) · [双端回归](../../Modules/ImageEdit/tests/color_grading_v2.rs)

色轮准备阶段分别保存已舍入的阴影区下边界与原半径。由中点减去下边界重新求宽度可能改变 Float32 舍入，进而改变借入 Metal 纹理的阴影权重。阴影使用同一参数表与三次平滑曲线。[参数准备](../../Modules/ImageEdit/src/color_grading.rs) · [着色器](../../Modules/ImageEdit/src/color_grading_v2.wgsl)

软件 Vulkan 的 CPU 适配器对曲线色阶、色轮和基础节点单色分支的有符号 sRGB 编码做一次立方根残差校正。基础节点的光线及色彩分支使用 `libm 0.2.16` 的正正规幂算法做传递和对比度运算。独立、融合和分阶段计划执行各节点时采用相同的算法。Metal、CPU 参考和实体 Vulkan 适配器保留各自的实现。实片色轮与复合曲线的精度按线性 FP32 绝对误差检验。[编码实现](../../Modules/ImageEdit/src/basic_v3.wgsl) · [适配器选择](../../Modules/ImageEdit/src/gpu.rs) · [精度与性能复验](evidence/native-spatial-cache-and-software-parity.json)

`RAWMASTER_QA_PORTABLE_GRADING_HALF_FIT=1` 试用独立 V2 全局色轮的主画布定稿。要求同一已核验的 FlashRaw 0.3.1 原件、不透明原生纹理、默认白平衡与曝光，以及已有物理半幅的设备和画幅条件。Swift 绑定原显影图的实际末端对象，核对 FIT 提交计划、原件及当前修订，再以 Rust 四带程序生成半幅交给原显示转换。曲线、其他光学操作和不获准入的布局继续显影。开关默认关闭。[Swift 准入](../../Sources/RAWMasterImaging/PreviewPortableGrading.swift) · [Rust 原生计划](../../Modules/ImageEdit/src/gpu/metal_surface/native_half.rs)

## V3 点曲线和色阶

配方 v2 的 `curves_levels_v3` 读取单个 `image`。`curves` 可含 `rgb`、`red`、`green`、`blue`，每个通道提供 `points`、`inputBlack`、`inputWhite`。曲线限 2 至 16 个 `[0,1]` 点，首尾横坐标为 0 和 1，相邻点使用现有 `1e-4` 间距校验。输入黑白点的先后需在原精度和 FP32 中都成立。`levels` 可含 `luminance`、`rgb`、`red`、`green`、`blue`，每个通道提供 `black`、`shadows`、`midtones`、`highlights`、`white`、`outputBlack`、`outputWhite`。FP32 重合的色阶点按端点、中间调、阴影和高光的既有优先级合并。同级保留先到者。[节点校验与系数](../../Modules/ImageEdit/src/curves_levels.rs) · [原生曲线和色阶](../../Sources/RAWMasterImaging/DevelopmentColorEngineV3.swift)

Rust 用 FP64 准备 PCHIP 系数，执行使用共享的 FP32 表。解预乘后做一次有符号 sRGB 编码，依次应用总曲线与 RGB 单通道曲线、亮度色阶、总色阶和单通道色阶，再解码并恢复原 alpha。两端延拓的斜率为 1。透明像素、无有效调整的节点直通。有效手动色阶按保存的语义参与完整运算，合成分支的零覆盖像素继续直通。[CPU 运算](../../Modules/ImageEdit/src/reference.cpp) · [GPU 运算](../../Modules/ImageEdit/src/curves_levels_v3.wgsl)

每个节点的参数表固定为 150 个 `vec4<f32>`，随同一图的参数缓冲上传并计入分块预算。调整点数量、通道与手柄值时可重绑原程序。`RAWMASTER_QA_PORTABLE_CURVES_PREVIEW=1` 试用原生代理纹理，将已支持的基础调色、点曲线和色阶融合到同一个图。自然三次、参数曲线、饱和度细化以及其余未接入的编辑继续由原生引擎处理。此开关默认关闭。[GPU 资源与重绑](../../Modules/ImageEdit/src/gpu.rs) · [Swift 绑定与范围](../../Sources/RAWMasterImaging/PreviewPortableCurvesLevels.swift)

独立的 `native-half-probe` Cargo 特性试验从已完成上传的私有 RGBA16F 纹理直接读取。Rust DAG 先用同一套 FP32 点算子产生最多 256 行的暂存纹理，再用 GPU 线性采样写入 RGBA32F 半幅。调用期间输入不可变，输出由该调用独占。同一设备上按带等待结束、检查全源和输出实写以及当前修订，再读回。两张 RAW 的十二组半幅 Float32 与显式 Core Image 半幅逐位一致。主片的基础调色、曲线和色阶混合配方在显式半幅进入后续 FIT 时仍改变 1,677 个显示像素。接入最终渲染前须核验原图的 FIT 提交形态。该试验接口由独立构建提供。[Metal 适配](../../Modules/ImageEdit/src/gpu/metal_surface/native_half.rs) · [试验 C 接口](../../Modules/ImageEdit/tests/native-half/probe.h) · [半幅及显示实测](evidence/native-banded-finish.json)

每次 GPU 提交可编码两个或四个这样的带。每带使用独立参数和实际写入计数，也在原顺序核查尾带。组内的后一带在前一带完成点运算和采样后复用暂存纹理。请求失效时等待已提交的整组，然后放弃本次输出。四带方案把主原片从 25 次提交减到 7 次，把次片从 23 次减到 6 次。[正反序时钟与位型回执](evidence/native-grouped-scalar-finish.json)

### 主画布的 Rust 半幅试用

`RAWMASTER_QA_PORTABLE_CANONICAL_HALF_FIT=1` 将四带程序接入主画布 2400×1600 定稿。准入使用已验证的 FlashRaw 0.3.1 原件、EXIF 方向 1、9504×6336 或 8640×5760 原生网格、单一 M4 Max GPU、macOS 27 和 512 MiB Core Image 上下文。支持独立的 legacy PCHIP 曲线或手动色阶，保持原几何和原采样网格。实际原图对象须从完成上传的同一个原件进入曲线和色阶阶段，并与全局验证边界的输出图绑定。先在原 Core Image 上下文核对完整 FIT 计划，支持的无额外绘制计划才开始候选渲染。资源没有准入或计划不匹配时由原定稿完成。[宿主准入与图绑定](../../Sources/RAWMasterImaging/PreviewPortableHalfFIT.swift) · [同一最终图校验](../../Sources/RAWMasterImaging/PreviewCanonicalHalfFIT.swift)

ABI 1 增加 `rm_image_metal_half_program_open_v1`、`rm_image_metal_half_render_v1` 和 `rm_image_metal_half_program_close_v1`，原有 IOSurface 入口保持兼容。Swift 按设备保留编译程序。每帧借入已证明有限且不透明的私有 RGBA16F 源纹理，独占一份私有 RGBA32F 半幅目标。宿主先等待目标清零完成，再把已初始化的源和目标借给 wgpu。纹理和中间工作预算一起准入，每带参数和回执独占，发起提交前的参数准备随本帧释放。四带一组按顺序等待完成，核对原生有限值、实写计数以及修订。提交后失去授权时先等已提交的组收尾，再丢弃半幅。剩余 FIT、sRGB8 量化和画布交付保持原协议，交付前再次核对文件、源纹理及工作者。试用开关默认关闭，定稿候选使用独立缓存键。[借用 C ABI](../../Modules/ImageEdit/include/rawmaster_image_metal.h) · [Rust 执行与完成回执](../../Modules/ImageEdit/src/gpu/metal_surface/native_half.rs) · [SwiftUI 预览服务](../../Sources/RAWMasterImaging/DevelopmentPreviewService.swift)

`RAWMASTER_QA_CANONICAL_HALF_CONTEXT_REUSE=1` 将已知曲线、色阶和冻结径向调色半幅纳入每次清理的上下文复用。继续要求同一原件和工作者、当前修订、原内存上限及八次连续使用的上限。`RAWMASTER_QA_CANONICAL_OWNED_BITMAP=1` 可在已验证 RAW 的 2400×1600 主画布定稿中，将同一 FIT 图直接写入独占的 sRGB RGBA8 内存。Core Image 任务结束并复查授权后，像素才交给 CGDataProvider，由 AppKit 图像持有至释放。两项均默认关闭。[准入](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [显示缓冲及所有权](../../Sources/RAWMasterImaging/V3PreviewMaterializer.swift) · [实片](evidence/native-owned-bitmap.json)

`RAWMASTER_QA_NATIVE_DEHAZE_JOINED_SCALAR=1` 仅用于原环形最小值路径上已受校验且紧密打包的 R32F 引导图。成对提交原 256 行的绝对图块，分别写入私有引导平面。所有任务完成后逐行核对完整写入、有限范围和发布资格。`RAWMASTER_QA_CANONICAL_LOCAL_NOISE_BANDS=1` 对已核验的原尺寸单项硬径向降噪执行全幅检查。`RAWMASTER_QA_CANONICAL_TEXTURE_REGION_BANDS=1` 复用原校验区域，仅处理达到原分组条件的正向纹理。三项默认关闭。[去雾任务与行合并](../../Sources/RAWMasterImaging/DevelopmentResidentDehazeGuide.swift) · [蒙版校验选择](../../Sources/RAWMasterImaging/DevelopmentMaskEngineV3.swift) · [去雾实片](evidence/native-dehaze-joined-guides.json) · [局部处理实片](evidence/native-local-spatial-transports.json)

`RAWMASTER_QA_CANONICAL_SPATIAL_MASK_CACHE=1` 为符合原分组准入的正向局部清晰度与纹理建立单次请求缓存。分组方式和容量在上下文创建前确定，清理发生在原分组边界、成功返回和异常退出时。`RAWMASTER_QA_CANONICAL_POINT_COMPOSITE_REGION=1` 对同一已核验的原始半浮点纹理，仅在保守的硬径向区域校验单项色温、色调和色轮。操作数为预乘 RGBA，框外覆盖为零，原件的有限范围和合成回退保证框外结果有限。两个试用均默认关闭，显示前后校验当前请求。[定稿准入与生命周期](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [局部合成与原区域](../../Sources/RAWMasterImaging/DevelopmentMaskEngineV3.swift)

## 后端选择与验证代价

| 路线 | 适用条件与决定 |
| --- | --- |
| Rust + wgpu/WGSL，加独立 C++ CPU 参考 | 两端可共用类型检查、调度和 shader。已有 macOS Metal、Linux CPU 与软件 Vulkan 正确性实证。保留 CPU 处理短小、要求立即读回或无设备的图。GPU 程序缓存、Metal/Vulkan 纹理互操作、模型零拷贝、物理服务器 GPU 驱动属于生产集成的主要工作。[后端说明](https://docs.rs/wgpu/27.0.1/wgpu/) |
| Swift / Core Image 与专用 Metal | 作为旧版本的像素参考和 Apple RAW 适配器已有直接价值。对必须访问原生纹理、相机解码、特殊 kernel 的节点，使用 Rust 后端 trait＋C／Objective-C++ 边界。只有同机同图有端到端收益且 CPU／服务端能力已定义时才为某段增加专用实现。 |
| 为 Metal、CUDA、Vulkan 分别维护整套 graph／算子 | Alcedo 的特化路径适合研究 pass 划分、工作图复用和显示变换。多套编译器、色彩和 fallback 验证成本高。对新模型可先接 ONNX Runtime 等现有 provider，并用能力表隔离平台实现。[Alcedo 对照](alcedo.md) · [LightFlow 对照](lightflow.md) |

## 首次全局输出的半浮点源校验

主画布 2400 像素定稿使用已验证的 FlashRaw 0.3.1 原件。原始方向为 1、显影节点接收到的仍是同一张原生图像时，默认直接检查已经完成上传的私有 RGBA16F 纹理。使用同一扩展线性 sRGB 工作域和 RGBA FP32 上下文，图像输入只有原来的整数垂直翻转。Metal 逐像素检查 RGB 的指数和 alpha 的精确位型，逐组回报覆盖数量，GPU 完成后核对所有分组。任何未完成或不受支持的检查回到既有 Core Image 校验。[纹理校验及原始着色器](../../Sources/RAWMasterImaging/FlashRawNativeFiniteCheck.swift)

已验证的 RAW 预览会话可复用原件的局部调整来源绑定。构造绑定时持有已校验的私有捕获文件描述符，按完整分辨率和非草稿设置从同一 RAW 解码器读取原方向和尺寸。消费凭据时再次核验文件与任务的有效性，然后按原顺序校验冻结蒙版、局部调整和白平衡。普通导出、分析和缺少凭据的调用沿用原来的文件读取和摘要核验。[预览凭据](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [两张 RAW 的绑定复验](evidence/native-exact-source-and-sharpen.json)

校验在符合条件的定稿首次需要它时发起。缓存中的证明关联仍持有的同一图像、原件和完成的检查。先开主画布时，随后同条件的比较视图可以复用已完成的结果。先开比较视图时，由该请求完成原 Core Image 检查。可用 `RAWMASTER_CANONICAL_F16_SOURCE_CHECK=0` 回退，强制串行和 `RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE=1` 也保留原校验路线。来源检查与取消贯穿提交、完成和证明登记。全局后续节点和显示仍使用原显影图。[原生纹理归属](../../Sources/RAWMasterImaging/FlashRawImageFactory.swift) · [定稿证据缓存](../../Sources/RAWMasterImaging/FlashRawCanonicalTexturePool.swift)

## 原生定稿的请求内中间缓存

`RAWMASTER_QA_CANONICAL_REQUEST_CACHE=1` 在 macOS 27 的统一内存设备上为单次定稿建立可缓存中间值的 Core Image 上下文。准入要求已验证的 FlashRaw 0.3.1 原件、实际持有的源纹理、主画面 2400 像素定稿、已列入原生有限值归约的点运算配方、512 MiB 上下文目标，以及足够的宿主内存和 Metal 余量。输入使用零原点整数横幅画布，任务独占该请求的上下文。滤镜缩略图同时生成、RAW 细节算法和空间处理等请求走既有准入路径。

有限值检查和高质量 FIT 依次使用同一扩展线性 sRGB／RGBA FP32 上下文。给定配方的全域检查、RGBA8 sRGB 整帧量化和缓存键沿用原生定稿规则。资源不足时使用普通上下文。取消及源校验贯穿归约和读回，完成或失败后清理上下文再释放源纹理。开关默认关闭，候选与默认运行分别计量。[准入与资源生命周期](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [Core Image 的缓存选项](https://developer.apple.com/documentation/coreimage/cicontextoption/cacheintermediates)

## 原生定稿的半幅浮点试验

`RAWMASTER_QA_CANONICAL_HALF_FIT=1` 为符合条件的主画布 2400×1600 定稿启用独立缓存键。候选键只写入定稿结果，主画布交互可读取其中同一配方的精确帧。对照和细节请求沿用各自的既有键。输入为已核验的 FlashRaw 0.3.1 原件，EXIF 方向 1，零原点、偶数边长的 3:2 画幅，且有正在持有的原生纹理。配方限独立的 legacy PCHIP 曲线或单个可验证的径向点运算。候选使用 macOS 27 的 RGBA FP32、扩展线性 sRGB、512 MiB Core Image 配置，并核对原图的提交计划统计。其他配方、资源不足和计划未识别的请求走原定稿路径。

Core Image 按最多 256 行将算后原生像素写进复用的 Metal 纹理。Metal 对每组四个像素校验全部 RGBA 分量，再按原坐标采样生成半幅浮点纹理。每条带先写入 NaN，可检测未覆盖的像素，必须等待 GPU 完成并核对所有分组标志。仅与最终显影图为同一对象的半幅纹理可以继续做剩余 FIT、sRGB 量化和画面读回。径向蒙版保留独立的前置全局有限值证明。纹理的内存预算随最后持有者释放，源和取消校验贯穿处理和画面交付。开关默认关闭。逐帧证据覆盖同一台 M4 Max 和两种原图尺寸，扩大系统、GPU 或尺寸范围时需重新对照完整首帧与定稿。[候选边界](../../Sources/RAWMasterImaging/PreviewCanonicalHalfFIT.swift) · [两张 RAW 的提交图](evidence/native-half-fit-study.json)

灰阶锐化预览使用原来的整幅有限值检查和 Core Image 显示路径。与普通锐化相比，它的完成节点有明确的灰阶蒙版语义，两者仍可得到相同的渲染计划统计。把灰阶图直接分带缩小会随锐化参数改变半幅 F32 和最终 sRGB8。在另一种尺寸的半浮 HDR 夹具上，半幅 F32 一致时最终画面也可能有差异。半幅验证需要同时检查中间像素与实际显示端点。[灰阶锐化半幅对照](evidence/native-sharpen-overlay-half-study.json)

## 原生锐化的均值纹理

`RAWMASTER_QA_CANONICAL_SHARPEN_MEAN=1` 允许主画布的 2400 像素精确定稿复用经过全幅校验的原生 R32Float 均值。准入条件包含已验证的 FlashRaw 0.3.1 原件、方向 1、零原点至 9504×6336 的整数画布、实际持有的原生 RGBA16F 纹理、512 MiB Core Image 目标，以及 macOS 27 上支持 FP32 滤波的单一统一内存 GPU。配方限指定半径的全局锐化和灰阶锐化，或纯正向锐化的单个硬边径向蒙版。配方或资源未准入时继续整幅有限值校验。[范围和预算](../../Sources/RAWMasterImaging/PreviewNativeSharpenMean.swift) · [宿主准入](../../Sources/RAWMasterImaging/PreviewNativeSource.swift)

在同一工作色域和 FP32 中间精度下，将原 Gaussian 均值按绝对坐标每 256 行写入同一张私有 R32Float 纹理。Gaussian 图保持全幅范围，带内像素继续使用原来的邻域。写入前用 NaN 填充全纹理，末带完成时核对每组实写像素数及有限范围。每带等待 Core Image 和 GPU，并检查同一原件和请求授权。任务已创建后发生撤销，也会等待该带收尾。锐化着色器继续读取同一源和同一均值纹理，由原 FIT 路径物化显示图。均值纹理和预算预留保留到物化结束，交付前再核验授权。此开关默认关闭。[分带实现](../../Sources/RAWMasterImaging/PreviewNativeSharpenMean.swift) · [两张 RAW 的内存、时钟与像素回执](evidence/native-banded-finish.json)

## 原生正向去雾的最小值预计算

`RAWMASTER_QA_NATIVE_DEHAZE_HALF_EROSION=1` 在主画布 2400 像素定稿中试用此路径。准入限定为 macOS 27.0.1 的单一 M4 Max GPU、已校验的 FlashRaw 0.3.1 原件、EXIF 方向 1、同一受持有的原生 RGBA16F 纹理和实测的 9504×6336 或 8640×5760 画幅。纹理须在 Metal 上证明 RGB 有限且不透明，去雾空气光须在有界正数域内。白平衡改变输入的配方进入原始路径。[入口与预算](../../Sources/RAWMasterImaging/DevelopmentNativeDehazeErosion.swift) · [来源与缓存](../../Sources/RAWMasterImaging/DevelopmentResidentDehazeGuide.swift)

两种实际采样区域分别可分解成五级九点最小值。原始 RGBA16F 的每通道最小值直接选择已有的半浮点位型。正向归一化在已批准的输入域内单调，因而可以在五级最小值完成后再求值。原始图像边缘复制一次，分带交界保留剩余级的完整邻域。每个 64 行分带在 GPU 完成后核对各级工作组实写像素数，再释放临时纹理。整幅结果继续进入原来的 Gaussian 与 256 行 R32F 验证，缓存以预计算版本和原件凭据绑定。布局、源签名、预算和任务权限贯穿生成与读取。试用开关默认关闭。[独立孔径证明、四通道对照和正常入口](evidence/native-dehaze-and-portable-basic.json)

`RAWMASTER_QA_NATIVE_DEHAZE_GROUPED_EROSION=1` 在上述资格内把最多四个 64 行最小值分带顺序编码到同一个 Metal 命令缓冲。各带有独立的写入标志分区，两个 tracked 临时纹理按原 encoder 顺序复用，完整组等待完成后逐带核对写入数量和请求授权。已提交组失效时先等 GPU 完成。现有 256 行 R32F Gaussian 物化边界继续使用；直接放大该带在两种原片尺寸均改变引导值。开关默认关闭，组版本参与缓存身份。[分带任务及布局](../../Sources/RAWMasterImaging/DevelopmentNativeDehazeErosion.swift)

R32F 的每带至多 256 行。带内仍逐行检查取消和现有请求状态，只写本次的私有缓冲。完整的工作者和原件授权检查覆盖提交前、已提交及等待完成、拷贝结束和缓存发布。若已提交后失效，先等待该任务，再清退未发布数据。已完成的暖缓存可继续由当前授权请求读取。[原生私有带与发布检查](../../Sources/RAWMasterImaging/DevelopmentResidentDehazeGuide.swift) · [原件失效和两源实测](evidence/native-program-ownership.json)

`RAWMASTER_QA_NATIVE_DEHAZE_RESTORE_PROOF=1` 在上述半浮点侵蚀候选的同一设备和尺寸域内试用还原范围证明。原始 RGBA16F 的 RGB 绝对值须不超过 1024，alpha 须精确为 1。R32F 提交前用 NaN 填充目标，等待完成后验证每行实写，再核对全部引导值的绝对值不超过 2。两份活的缓存借用、原件、空气光、固定覆盖归一化与还原着色器共同绑定本次还原。还原的透射率下限为 0.2，有界输入使每项中间值和输出都处于有限范围。匹配该证明的图可以交给原 FIT 直接物化，发布前继续核验来源和提供者故障。有限值超出证明域或其他非适用条件继续进入原全幅验证。默认关闭。[证明与实写核验](../../Sources/RAWMasterImaging/DevelopmentDehazeRestoreProof.swift) · [生产调用和回退](../../Sources/RAWMasterImaging/DevelopmentResidentDehazeGuide.swift)

`RAWMASTER_QA_NATIVE_DEHAZE_RESTORE_HALF_FIT=1` 将已验证的同一 F16 来源和 R32F 引导用于主画布 2400×1600 定稿。最终图须是本次返回的原还原对象，且符合两种实测的提交计划之一，计划的 overdraw 为零。Metal 复用原还原方程，每 256 行写 FP32 暂存并使用硬件线性采样。两阶段分别核对读写覆盖和有限值，共用半幅工作预算，半幅保留到原显示物化完成。每带等待完成并重查原件、引导和请求授权。此开关默认关闭。[还原、采样及预算](../../Sources/RAWMasterImaging/DevelopmentNativeDehazeHalfFIT.swift) · [原生实片和撤销回执](evidence/native-banded-finish.json)

## 径向纹理与清晰度的定稿校验

主画布 2400 像素定稿默认使用符合资格的区域校验。配方限一个正向纹理或清晰度调整的硬边径向蒙版，不透明度为 100%，且未反相。入口持有来源已验证、EXIF 方向 1 的完整 FlashRaw 0.3.1 纹理。渲染器检查同一张原生 RGBA16F 图的前置全域校验证明，且蒙版接收的仍是该对象。其他请求沿用整幅校验。

径向范围按着色器的 Float32 坐标外扩，额外留出末端蒙版和有限值着色器各一像素的取样边界，再向外对齐绝对 1024 像素校验网格。保留瓦片用原 Gaussian 输入、绝对坐标、有限值归约、逐格等待和清理。边缘残瓦片使用原来与原图的交集。全幅显示图继续走原定稿物化。`RAWMASTER_CANONICAL_SPATIAL_MASK_TILES=0` 恢复整幅路径。显式分带校验和强制串行选择按原用途优先。[准入与瓦片选择](../../Sources/RAWMasterImaging/DevelopmentMaskEngineV3.swift) · [原生证据](evidence/native-spatial-mask-tiles.json)

`RAWMASTER_QA_CANONICAL_GRAIN_MASK_TILES=1` 额外允许单层正向颗粒使用相同的区域校验。颗粒强度满足 `0 < a ≤ 1`，尺寸和粗糙度分别固定为 0.25 和 0.5。使用原生颗粒生成器和既有复合着色器，噪声位于约 −0.5 至 0.5，零覆盖直接返回源像素。最终检查复用同一组原有瓦片。指定代理颗粒缩放时回到全域检查。局部锐化和降噪使用全域校验。[区域准入](../../Sources/RAWMasterImaging/DevelopmentMaskEngineV3.swift) · [噪声生成](../../Sources/RAWMasterImaging/DevelopmentGrainSamplingEngineV1.swift) · [颗粒合成](../../Modules/ImageEdit/shaders/mask_grain_transfer.ci.metal)

`RAWMASTER_QA_CANONICAL_GROUPED_SCALARS=1` 在已核验的 FlashRaw 原件、M4 Max、两种已验证的原生尺寸和 512 MiB 主画布上下文中，允许对局部校验分组等待。范围由原请求决定，降噪和局部曲线仍使用全幅，启用区域校验的纹理、清晰度和颗粒沿用原瓦片。每组至多持有 12 份已用 NaN 初始化的 RGBAf 标量，顺序启动原 `CIAreaMaximum` 任务并等所有任务结束，再按原瓦片顺序归约。完成前保持原图与目的地址有效，重新核验原件和工作者授权，并用原图完成显示。显式串行选项优先。此试验开关默认关闭。[分组等待及释放](../../Sources/RAWMasterImaging/DevelopmentCheckedMaximumV3.swift) · [同一上下文的拒绝验证](evidence/native-grouped-scalar-finish.json)

`RAWMASTER_QA_CANONICAL_FULL_VALIDATION_CACHE=1` 只在原来的分组全幅校验已经准入时，为当前定稿建立可缓存中间结果的 512 MiB 上下文。整个显影、全部绝对 1024 格的 `CIAreaMaximum` 及最终 FIT 都使用该上下文中的原图。已开始的任务按原顺序完成并检查四通道，缓存保留到该定稿成功、失败或取消退出。区域归约继续选用原上下文及原来的每组清理。历史故障夹具在启用缓存的上下文中改变了一个区域归约判定，故当前试用范围限于全幅。该开关默认关闭，显式串行及逐格诊断优先。[上下文准入](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [分组完成和缓存寿命](../../Sources/RAWMasterImaging/DevelopmentCheckedMaximumV3.swift)

## 2× TIFF16 的 FlashRaw 分带上传

2× TIFF16 导出在显影图构造期间可使用分带上传，并绑定本次原件捕获。准入检查包括 FlashRaw 0.3.1、至少 64 MiB 的完整 RGB F16 源帧、EXIF 方向 1、零原点、与解码器报告一致的原生尺寸，以及同一统一内存设备的私有 RGBA16Float 目标纹理。

每次转换借用 C 帧并独占一个最多 256 行、最多 16 MiB 的共享缓冲。Metal 读取带内的紧排 RGB F16，转换为 RGBA16Float，按带起始行写入完整原生纹理。提交后等待 GPU 完成、确认状态并检查取消，随后复用缓冲。完整纹理才交给显影图。模型、TIFF 编码和发布由现有作业继续执行。满足准入条件时默认使用分带上传。设备未获准入或分带管线无法创建时使用全幅上传，也可用 `RAWMASTER_QA_SUPER_RESOLUTION_BANDED_UPLOAD=0` 显式回退。[导出请求与捕获](../../Sources/RAWMasterImaging/DevelopmentService.swift) · [Metal 上传](../../Sources/RAWMasterImaging/FlashRawMetalConverter.swift)
