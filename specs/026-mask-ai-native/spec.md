# 026 · Lightflow 自动蒙版算法的原生独立验证

## 状态与目的

- 状态：独立模块与真实模型验证已完成（有限范围）；未合并到 RAWMaster。详见 `validation.md`。
- 目的：在 macOS 原生 Swift 进程中验证 Lightflow `2d41ab1` 的多模型 Mask 方案，判断其是否覆盖 Camera Raw 的自动创建能力，并以实际结果决定后续合并范围。
- 模块：`experiments/MaskAI`，具有独立 `Package.swift`、CLI、测试、模型目录和输出目录。

## 覆盖口径

1. **接口覆盖**：模块存在可调用入口和明确参数模型。
2. **执行覆盖**：固定模型在真实图像上完成推理，输出尺寸正确、数值有界的灰度蒙版。
3. **语义覆盖**：样本中存在目标时，输出位置与目标具有可审查的对应关系；无目标时允许空蒙版并明确报告。
4. **摄影质量**：需要更多标注样本、边缘和人工修正评估，不能由前3项自动推导。

## 功能需求

| ID | 需求 | 验证证据 |
| --- | --- | --- |
| FR-001 | 原生 Swift 库和 CLI 使用 ONNX Runtime 1.27.0 C API；运行库和模型以 SHA-256 固定 | 安装日志、运行时 API 探测、模型加载 |
| FR-002 | Subject／Background 使用 IS-Net；背景与主体逐像素互补 | 汽车样本、PNG、互补断言 |
| FR-003 | Landscape 提供 Sky、Snow、Architecture、Vegetation、Water、Natural Ground、Artificial Ground、Mountains 八类 | 场景样本、八类输出、类别映射测试 |
| FR-004 | ADE20K 场景分析按照片缓存，多个风景目标不重复推理 | `inferenceRunCount` 断言 |
| FR-005 | Objects 支持点、框、正／负点；SlimSAM encoder 按照片缓存，decoder 支持三候选与 IoU 选择 | 点／框样本、encoder／decoder 次数 |
| FR-006 | People 支持全部／指定人物，以及整人、面部皮肤、身体皮肤、眉、眼白、虹膜瞳孔、唇、牙、头发、衣服 | 人像与全身样本、逐部位 PNG |
| FR-007 | 统一输出 top-left、row-major、Gray8 MaskImage；记录耗时、覆盖率、模型与备注 | 单元测试、结构化结果 |
| FR-008 | 无模型时测试可离线运行；模型测试必须显式启用 | 默认 `swift test` 与 `MASK_AI_MODEL_TESTS=1` |

## 明确边界与兼容策略

- ADE20K 没有 Snow 类别。当前 Snow 是“地形语义＋高亮低饱和像素”的兼容实验，**不是已验证的 Adobe 等价 AI**。
- SlimSAM Q8 的纯框初始验证偏向背景；当前矩形输入自动增加框中心正点，并记录 `addedBoxCenter=true`。这是实测驱动的补偿策略，不能描述为原样复刻 Lightflow。
- Teeth 使用内唇关键点和明亮／低饱和先验；闭嘴或无牙时应允许空结果。
- 人物五官依赖人脸检测与 478 点网格；侧脸、遮挡和小脸质量需单独验收。
- 当前运行的是 Lightflow 对应的 ONNX 权重，不是已经完成 Core ML 转换的模型。
- 结果是功能与工程可行性验证，不宣称 Camera Raw 的检出率、边缘、速度或普遍输入等价。

## 硬约束

| ID | 约束 |
| --- | --- |
| C-001 | 不导入或修改 RAWMaster 主 Package、配方、渲染器和 UI；合并讨论必须另开变更。 |
| C-002 | 模型和运行库必须经固定 SHA-256 校验；不完整或超尺寸临时文件不得加载。 |
| C-003 | 推理在本机完成，照片不上传；只有模型和公开测试 fixture 使用网络。 |
| C-004 | 输入统一应用 EXIF 方向并转为显示参考 RGBA8；输出保留原分析图尺寸。 |
| C-005 | 模型测试记录冷／暖路径、缓存命中、失败与空结果，禁止只报告成功样本。 |
| C-006 | 下载内容、构建产物和验证输出不进入 Git；公开 fixture 记录来源和实际内容哈希。 |

## 不在本模块范围

- RAWMaster 配方迁移、蒙版组件布尔 UI、局部调整参数、预览／导出集成。
- Core ML 模型转换、生产模型下载器、应用签名与分发。
- Depth Range、ViTMatte、Remove／Heal／Clone。
- 全相机、全 RAW、全人物姿态和普遍摄影质量资格。

## 合并前必须回答

1. 哪些目标在本机原生运行中稳定完成，哪些存在模型或后处理缺口？
2. SlimSAM 的 encoder 缓存和场景复用是否真实降低重复工作？
3. Snow、Teeth、五官和多主体是否达到可接受的语义覆盖，还是需要替代模型？
4. 冷／暖耗时、峰值内存和模型体积是否适合 RAWMaster？
5. 是否应保留独立 `RAWMasterMaskAI` 目标，以及合并时如何转换成语义配方＋已确认快照？
