# 030 · 本地检测与智能蒙版 PoC

2026-11-22 · 决策依据 · 对应产品规格 US1、US2、US3、FR-01、FR-04、SC-01、SC-02。

**新增的语义蒙版优先试用逐人选择、点选物体、天空和水面。** 用户得到能继续调曝光、白平衡和对比度的普通蒙版。多人合影必须选实例，山脊、发丝和重叠轮廓必须能放大检查。在本轮公共标注样本中，水面的区域重合度最高。给模型一个准确的人物框仍会把相邻人的身体选进去。纪实批量只传“保护所选人物”等意图，各照片单独生成并确认范围。[产品规格](spec.md) · [像素标注测试记录](evidence/pedestrian-results.json) · [风景测试记录](evidence/landscape-results.json)

## 现有编辑器与设备分工

主工作区已经支持线性、径向、亮度范围和 AI 主体。后者对定向源图运行 Apple Vision，合并前景实例，缩到长边 512，写入 RGBA8 PNG。每层能控制启停、反转、不透明度及局部曝光、曲线、色彩、纹理、去雾、降噪等，代理预览和最终显影都调用同一个蒙版阶段。旧调研中所列的四个局部参数已被扩展。目前单层 `subjectPNG` 上限 4 MiB，整张最多 32 层，模型输出须接入现有历史和渲染。[当前工具](../../Sources/RAWMaster/PhotosMaskControls.swift) · [生成和保存](../../Sources/RAWMaster/EditingController.swift) · [Vision 实现](../../Sources/RAWMasterImaging/DevelopmentSubjectMaskGeneratorV1.swift) · [配方](../../Sources/RAWMasterCore/DevelopmentMaskModelsV3.swift) · [代理](../../Sources/RAWMasterImaging/PreviewInteractiveProxyV3.swift) · [最终显影](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift)

| 摄影师的操作 | 设备与选型 | 已验证的边界 |
| --- | --- | --- |
| 选择主体或背景 | Vision 随系统提供。IS-Net FP16 可作为独立的主体对照，背景可从已确认主体逐像素取反 | 实验包已在车和水鸟上运行 IS-Net。仅验证过部分真实主体。Vision 与 IS-Net 优劣仍需同一组摄影 RAW 盲评 |
| 点物体，框选，修正范围 | SlimSAM Q8 在本地编码一次，同图新提示只运行解码器。提供排序后的三份候选及画笔加减，框选自动附加中心正点 | 裸框曾返回背景，负点在汽车样本将范围缩至 2.76%。预测 IoU 仅供排序。交叠人像即使使用真值框也有明显串选 |
| 合影中选人，提亮单个人 | 本地 D-FINE-S COCO 产生人物框，再用 SlimSAM 生成该实例蒙版。全身按需。检测框本身不能用作调色或贴回边界 | 现有代码只取 COCO 人物类别，置信阈值 0.45、NMS 0.5、最多 20 人。一旦发现人还会运行 YuNet 找脸。通用杂物继续由用户点或框 |
| 压天空、调水面或前景 | EfficientViT-B2 ADE20K 本地生成 150 类概率，按类别组求和。同图多项目标共享场景分析 | 天空和水面可试用。山体、植被、建筑先让用户确认。雪由地形和颜色估计，无雪日落 RAW 的软覆盖率仍为 3.10% |
| 皮肤、头发、五官 | Selfie Multiclass 按人物框分割皮肤、头发、衣服。YuNet 和 478 点模型定位脸。眼眉唇以几何生成，牙齿叠加亮度/中性色先验 | 有单人及球场 JPEG 运行证据。缺不同肤色、遮挡、逆光及露齿人像 RAW 的部位真值。默认保护五官，支持回退手绘 |

推理和叠加放在设备端，使断网选区、连续点选和滑杆编辑可用。图像编辑模型处理经确认的局部生成请求，选区的查找、修边、撤销和再导出均读取本地资产。首次下载模型包应显示体积，断网缺包时仍可用系统主体和手动蒙版。[实验模型清单](../../experiments/MaskAI/Sources/MaskAI/ModelCatalog.swift) · [人物检测](../../experiments/MaskAI/Sources/MaskAI/PersonDetector.swift) · [人物部位](../../experiments/MaskAI/Sources/MaskAI/PeopleMasker.swift) · [对象候选](../../experiments/MaskAI/Sources/MaskAI/ObjectMasker.swift) · [场景分组](../../experiments/MaskAI/Sources/MaskAI/SceneMasker.swift)

## 新实测一 · 谁被选中了

使用 Penn–Fudan 公布的街景照片和人工实例蒙版，两地各预先固定六张，共 12 张、34 个标注行人。运行独立 Swift CLI 和本地 ONNX 权重。检测框按 IoU 从大到小一对一匹配，门槛 0.5。蒙版按 Gray8 ≥128 计面积，逐图算交并比再取算术平均。边界 F1 对称计算边界精确率和召回率，容许原图 2 像素的切比雪夫距离。[数据与标注范围](https://www.cis.upenn.edu/~jshi/ped_html/) · [固定样本与评估脚本](evidence/evaluate-pedestrians.py)

| 任务 | 实测 | 摄影操作的含义 |
| --- | --- | --- |
| 自动找人 | 62 个框匹配 34/34 个标注行人。另有 28 个未匹配框 | 标注会略过过小、严重遮挡的人，额外框应展示给用户选择，不能据此把这 28 个全计作误检 |
| 自动选择“所有人物” | 12 张平均 IoU **0.780**，范围 0.602–0.933，平均边界 F1 **0.725** | `PennPed00050` 把标注目标身后的行人也纳入。保护选中人物时需区分“这个人”和“所有人” |
| 给最大标注人物的精确外接框 | 12 个独立实例平均 IoU **0.842**，范围 0.562–0.947，平均边界 F1 **0.764** | `PennPed00090` 中相邻行人的腿被串入。此项使用真值框和框中心正点，目标与上行不同，不能当成普通用户画框的提升幅度 |

公开行人图里的标注对象都是直立者。这里证明了选人链路可以复测并暴露失败，尚需真实合影、近景头发、服装透空处和人脸细节，才能判定首批人像预设的修边成本。[逐图数字](evidence/pedestrian-results.json)

## 新实测二 · 天空、水面和山脊

使用 Gould、Fulton、Koller（ICCV 2009）的 Stanford Background 人工像素标签。对每类按固定哈希顺序取覆盖已标注面积至少 1% 的四个正例、完全缺席的四个负例，三类共 24 个图像与类别组合，跨类别复用后为 12 张不同照片。忽略未知标签，以 Gray8 ≥128 统计区域。样本约 320×240，下表适用于预览轮廓评估。[数据定义](https://dags.stanford.edu/projects/scenedataset.html) · [分层取样与阈值](evidence/evaluate-landscape.py)

| 目标 | 四个正例的 IoU，依采样顺序 | 均值 | 四个负例被选区覆盖的比例 | 产品决策 |
| --- | --- | ---: | --- | --- |
| 天空 | 0.570、0.850、0.927、0.942 | **0.822** | 均为 0 | 候选可用，树梢、电线、支架和楼顶应优先提示核对 |
| 水面 | 0.940、0.961、0.959、0.964 | **0.956** | 均为 0 | 可进入用户试用，另用带倒影和碎浪的高分辨率 RAW 验证边缘 |
| 山体 | 0.392、0.000、0.000、0.981 | **0.343** | 均为 0 | 两张帆船照片远岸狭窄山体完全漏掉。首批可保护用户已确认的山脊。自动“提亮山体”保留在实验范围 |

软蒙版仍可能有低于阈值的尾部概率。对生成式补丁的硬保护区应明确置零。此表的零误选只适用于这些样本和阈值。[逐例结果](evidence/landscape-results.json)

## 开源权重与可复建性

逐一对照实验清单，本机使用的八个 ONNX 文件 SHA-256 全部匹配。执行引擎为 ORT 1.27.0 默认 CPU EP、四个 intra-op 线程，缩放使用 Core Image。Core ML、ANE 以及基础款 Mac 的吞吐仍待验证。以下体积为实际权重的 MiB。[下载来源与固定版本](../../experiments/MaskAI/Scripts/download-dependencies.sh) · [ORT 会话](../../experiments/MaskAI/Sources/MaskAI/ONNXRuntime.swift)

| 功能及大小 | 上游许可与实际产物 |
| --- | --- |
| SlimSAM 8.47 + 4.68 | 原作者 Uniform-77 权重与 Xenova ONNX 卡均标 Apache-2.0，已跑固定 Q8 编解码器。[原权重](https://huggingface.co/Zigeng/SlimSAM-uniform-77) · [ONNX 发布](https://huggingface.co/Xenova/slimsam-77-uniform/tree/5850ab45f587c112167512ffef949107115e26a0/onnx) |
| D-FINE 10.67，YuNet 0.22 | D-FINE 的 COCO 基础权重卡标 Apache-2.0，ONNX 卡指向该基础模型。锁定 COCO 版本。OpenCV YuNet 目录的许可为 MIT，分发时保留其声明。[检测器](https://huggingface.co/ustc-community/dfine-small-coco) · [转换来源](https://huggingface.co/onnx-community/dfine_s_coco-ONNX) · [YuNet 许可](https://huggingface.co/opencv/face_detection_yunet/blob/3cc26e7f1014a5ee5d74a42acee58bafc9d0a310/LICENSE) |
| EfficientViT 58.53 | 作者发布的 B2 ADE20K 权重卡标 Apache-2.0。从该权重自行导出的 ONNX 已用相同 Swift CLI 跑通横竖图。生产包可以从作者权重构建。[作者权重](https://huggingface.co/han-cai/efficientvit-seg) · [上游语义分割](https://github.com/mit-han-lab/efficientvit/blob/master/applications/efficientvit_seg/README.md) |
| Selfie 15.69，Face Landmarks 4.69 | 两份转换卡将 Google MediaPipe 原模型和 ONNX 权重列为 Apache-2.0。Selfie 按人框裁为 256 方图。眼唇掩模来自人脸点和栅格化。保留转换来源、权重声明和 SHA。[Selfie](https://huggingface.co/senty-au/selfie_multiclass_256x256-ONNX) · [478 点](https://huggingface.co/senty-au/face_landmarks_detector-ONNX) |
| IS-Net 84.06 | ONNX 转换者标注 Apache-2.0 并列出 rembg 和 DIS 来源。DIS 原仓单独说明代码和评测用 Apache-2.0、数据集另有条款。随应用分发前核对原权重授权链。Vision 可继续覆盖免下载主体入口。[ONNX 权重卡](https://huggingface.co/Ko033/isnet-general-use-onnx) · [DIS](https://github.com/xuebinqin/DIS) |

从作者权重（SHA-256 前缀 `fabfa716`）和 B2 代码 `5c423e51ba97` 生成动态宽高、opset 17 的 FP32 ONNX。在本机相同工具链导出两次，得到同一哈希 `bdbe3961…`。与先前 LightFlow 实验产物 `e6df30d2…` 在上表 24 个输出逐像素比较，共 **1,832,960** 个 Gray8 值，仅 12 个相差 1 个灰度级，跨过 128 阈值的像素为 0。这个比对覆盖了导出、Swift 前后处理和实际加载。[导出脚本](evidence/export-efficientvit.py) · [权重、模型、源码指纹和逐例差异](evidence/landscape-upstream-parity.json)

## 继承的 RAW 与性能证据

027 对三张 Sony RAW 做过独立 `CIRAWFilter` 分析和局部 +0.75 EV 验证。水鸟原片 8640×5760 的 2593×1728 原生裁切，选区与非选区平均亮度变化分别为 0.1360、0.00112。历史测试还覆盖快照原子写、损坏检测、取消回滚和显式释放。完整套件 27 项、0 失败、59.67 秒。[独立模块](../../experiments/MaskAI/README.md) · [RAW 验证](../027-mask-ai-raw-integration/validation.md) · [完整日志](../../experiments/MaskAI/Validation/final-suite.log)

| 最终性能记录 | 单次耗时 |
| --- | ---: |
| 水鸟分析图 2400×1600，主体首次 / 同描述快照命中 | 1,580.28 / 1.77 ms |
| 首个场景 / 同图共享场景概率后切类别 | 727.47 / 27.14 ms |
| 首次点物体 / 复用 encoder 后改提示 | 1,261.33 / 96.65 ms |
| 读取并校验快照 | 1.52 ms |
| 取消独立汽车样本的主体任务，含发出取消前 100 ms 延迟 | 393.71 ms |

以与完整日志一致的最终 JSON 为准。服务说明另记载了一轮独立性能数字。最终性能子测试峰值 RSS 为 3,542,401,024 字节。整套件进程峰值为 4,674,584,576 字节。主体冷计时从已有分析图开始，不含 RAW 解码，当前主机为 Apple M4 Max、128 GiB。单次结果不能推算 p95、最低内存或手动修边节时。[最终性能 JSON](../../experiments/MaskAI/Validation/Performance/performance-results.json) · [计时边界](../../experiments/MaskAI/Tests/MaskAITests/PerformanceAcceptanceTests.swift) · [服务验收](../027-mask-ai-raw-integration/service-validation.md)

## 接入决策与验收

1. **以定向中性代理作为模型输入。** 在 RAWMaster 复用 FlashRaw 显影后的稳定输入，固定线性工作域到显示参考 sRGB 的转换、分析尺寸及方向。显示编辑和蒙版叠加不进入这份输入。显式保存原图标识、尺寸、方向、分析/解码版本及原图到裁切坐标的变换。相同的分析图只编码一次。
2. **将已确认结果接入现有层。** 在旧 PNG 读取路径旁增加语义描述和内容寻址 Gray8 引用，保留已有 PNG 的逐像素回放。添加/减去/相交与用户修边在该层内可撤销。相同描述的快照、场景概率和 SlimSAM embedding 用各自的缓存键。模型或代理版本变更后，新建及显式刷新使用新版本。旧历史继续读原快照。缺资产时提示恢复或重建，避免历史悄悄更新。
3. **按实际加载的模型记录依赖。** 包安装按真实字节验哈希。实验 `require` 只判文件存在，`SemanticMaskDescriptor.models` 由调用方填写，人物路径在检测到人后会额外加载 YuNet，而全身/皮肤的 `modelIDs` 没有列出它。生产清单由实际执行路径生成，防止换包后复用错误快照。[描述与绑定](../../experiments/MaskAI/Sources/MaskAI/SemanticModels.swift) · [协调与取消](../../experiments/MaskAI/Sources/MaskAI/MaskAICoordinator.swift) · [已知依赖路径](../../experiments/MaskAI/Sources/MaskAI/PeopleMasker.swift)
4. **按摄影任务准入。** 合影测串选、细发边缘和修正秒数，风景测直立/镜像、树枝、倒影和小目标，纪实组照测换位、漏检、取消和断点恢复。用主程序验证代理、100% 裁切、原尺寸多层导出、撤销重开和不同 OS。无可用模型时仍能手动完成。获得基础款设备冷暖 p50/p95 和编辑器进程峰值后，再设置随设备变化的预取与内存预算。[用户验收标准](spec.md)

## 复现

在仓库根目录执行。Python 评估脚本使用 NumPy 和 Pillow。归档仅用于本机测试，脚本校验归档指纹并把原图、标注与临时蒙版写到指定输出目录。

```sh
swift build --package-path experiments/MaskAI
mkdir -p output/research/030-mask-quality
curl -fL https://www.cis.upenn.edu/~jshi/ped_html/PennFudanPed.zip -o output/research/030-mask-quality/PennFudanPed.zip
curl -fL https://dags.stanford.edu/data/iccv09Data.tar.gz -o output/research/030-mask-quality/iccv09Data.tar.gz
python3 specs/030-ai-retouching/evidence/evaluate-pedestrians.py output/research/030-mask-quality/PennFudanPed.zip output/research/030-mask-quality/people
python3 specs/030-ai-retouching/evidence/evaluate-landscape.py output/research/030-mask-quality/iccv09Data.tar.gz output/research/030-mask-quality/landscape
```

初次准备运行库、权重按实验 README。验证作者权重时，用上述固定源码和检查点运行 `export-efficientvit.py UPSTREAM CHECKPOINT MODEL_ROOT`，再为风景脚本传入 `--models MODEL_ROOT`。导出环境为 Python 3.12、CPU Torch 2.14.1、ONNX 1.20.1。导出脚本只跳过训练用的 scheduler 导入，模型前向来自作者源码。[环境与安装](../../experiments/MaskAI/README.md) · [固定源码](https://github.com/mit-han-lab/efficientvit/tree/5c423e51ba97e5fb2ccbda4ee4814b208fc42f62) · [固定检查点](https://huggingface.co/han-cai/efficientvit-seg/blob/cf3ccaf9cbaf670a2cb283612773546824ca0aa1/efficientvit_seg_b2_ade20k.pt)
