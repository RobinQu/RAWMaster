# 算子、配方与执行契约

**目标。** 同一版本的编辑操作可在当前照片交互、批量 worker 和最终导出中复用。版本记录冻结“应当怎么算”，运行回执记录“本次由什么实现算出”。评审可把[可运行 JSON](../../experiments/portable-processing/image/examples/local-look.json)和[原生输入输出](validation.md)逐项对照。[主规格](spec.md)

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

## 后端选择与验证代价

| 路线 | 适用条件与决定 |
| --- | --- |
| Rust + wgpu/WGSL，加独立 C++ CPU 参考 | 两端可共用类型检查、调度和 shader。已有 macOS Metal、Linux CPU 与软件 Vulkan 正确性实证。保留 CPU 处理短小、要求立即读回或无设备的图。GPU 程序缓存、Metal/Vulkan 纹理互操作、模型零拷贝、物理服务器 GPU 驱动属于生产集成的主要工作。[后端说明](https://docs.rs/wgpu/27.0.1/wgpu/) |
| Swift / Core Image 与专用 Metal | 作为旧版本的像素参考和 Apple RAW 适配器已有直接价值。对必须访问原生纹理、相机解码、特殊 kernel 的节点，使用 Rust 后端 trait＋C／Objective-C++ 边界。只有同机同图有端到端收益且 CPU／服务端能力已定义时才为某段增加专用实现。 |
| 为 Metal、CUDA、Vulkan 分别维护整套 graph／算子 | Alcedo 的特化路径适合研究 pass 划分、工作图复用和显示变换。多套编译器、色彩和 fallback 验证成本高。对新模型可先接 ONNX Runtime 等现有 provider，并用能力表隔离平台实现。[Alcedo 对照](alcedo.md) · [LightFlow 对照](lightflow.md) |
