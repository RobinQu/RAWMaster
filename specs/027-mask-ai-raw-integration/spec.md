# 027 · Mask AI 与 RAWMaster 的集成及真实 RAW 验证

## 状态与目的

- 产品编辑器已经接入 Camera Raw 基础编辑交付。真实 RAW 方向、候选速度、旧作品逐像素兼容和新编辑器导出按同一构建记录。[联合验收](../031-preset-browser/integration-validation.md) · [首轮验证](validation.md) · [人像与雪景追加验证](portrait-snow-validation.md)
- 前置证据：026 独立模块的原生 ONNX 推理、公开图像测试与有限摄影质量检查。
- 目的：定义 Mask AI 与现有配方、编辑控制器、预览、持久化和导出的集成边界，并验证真实 RAW 输入上的蒙版及实际局部像素效果。

## 集成原则

1. **推理与渲染解耦**：模型只在新建、同步或显式刷新时运行；渲染、历史和导出读取已确认快照。
2. **稳定分析输入**：AI 使用定向、固定中性显影、显示参考 sRGB 的源图，不读取已包含当前 Mask 的输出。
3. **分析代理跟随作品的解码器。** 新 RAW 作品用固定的 FlashRaw 0.3.1 线性 sRGB 输入做方向校验、缩放和颜色转换。历史 RAW 配方沿用 CIRAWFilter。当前源、解码器或坐标变化时失效，同一输入的后续请求复用分析图。[实现](../../Sources/RAWMasterImaging/DevelopmentSemanticMaskService.swift)
4. **向后兼容**：旧 `subjectPNG` 配方继续可读；新字段采用缺省解码，不改变旧像素结果。
5. **有界资源**：模型、session、embedding、场景概率、快照和后台任务均有明确预算与淘汰规则。

## 目标组件

| 组件 | 建议归属 | 职责 |
| --- | --- | --- |
| `SemanticMaskDescriptor` | `RAWMasterCore` | 目标、人物实例、prompt、模型版本、分析输入版本与快照引用 |
| `MaskSnapshotStore` | 独立存储服务 | 内容寻址 Gray8／Gray16 快照、尺寸、ROI、源与哈希验证 |
| `MaskAnalysisInputProvider` | 独立适配层 | 生成并缓存稳定的中性定向分析图，不提供当前 Mask 输出 |
| `MaskAIClient` | `RAWMasterMaskAI` 或等价独立 target | IS-Net、EfficientViT、SlimSAM 与人物模型的原生推理 |
| `MaskAICoordinator` | App 控制器侧 | 异步任务、取消、进度、过期、刷新、上下文与模型生命周期 |
| `MaskResolver` | Imaging | 将手工组件与快照解析为 matte；不进行 AI 推理 |
| `DevelopmentMaskEngineV3` | Imaging | 在既有管线位置执行局部调整；缺快照时明确失败，不静默换图 |

## 配方与事务要求

- 当前 `setMasks` 原子事务继续负责用户可见图层的创建、撤销、重做和持久化。
- AI 任务不得直接修改正在编辑的数组；先完成快照，再以当前 context／request ID 校验后提交。
- 快照缺失或模型变化不得自动替换已确认作品；UI 显示需要重算或重新下载。
- 跨照片复制只复制语义描述；每张照片生成自己的快照，不复制源照片灰度像素。
- 模型 SHA-256、算法版本、源内容 ID、方向、分析尺寸和采样版本必须可追踪。

## RAW 坐标与像素要求

1. 模型、prompt、MaskImage 均使用 top-left 归一化坐标。
2. CIImage／CIRAWFilter 源空间必须显式处理 EXIF、extent origin 和 bottom-left 坐标转换。
3. 预览缩放不改变语义；原生分辨率裁切须验证 mask resize、crop 和实际像素效果。
4. 真实效果验证至少输出原图、灰度蒙版、局部调整成片，以及选区／非选区平均绝对变化。
5. 当前曝光合成仅用于验证集成路径，不宣称与 RAWMaster 现有四个局部滑杆或 Camera Raw 数学等价。

## 模型与内存策略

- 默认最多一个当前照片的 AI 前台任务；后台预取必须受独立预算和取消控制。
- SlimSAM 只缓存当前照片的 encoder／positional embedding；场景分析只缓存当前照片概率。
- 不为所有功能预加载全部模型。按用户第一次使用加载，退出上下文或超过预算时释放。
- 026 全套测试最大 RSS 约 2.75 GiB，不能直接作为生产常驻预算；合并前必须测量单模型和释放后内存。
- ONNX Runtime 是已验证运行时；Core ML／Core ML EP 需要单独数值与性能 spike，不能隐式切换。

## 功能验收范围

| 类别 | 必须验证 |
| --- | --- |
| Subject／Background | 有明确主体的 RAW、互补、方向、重放与导出 |
| Landscape | 天空、植被、水、山体、自然／人工地面、建筑；无目标负样本 |
| Objects | 点、框＋中心、候选、负点、缓存与prompt坐标 |
| People | 无人负样本、单人、多人、部位；缺少原生人像 RAW 时必须标未验证 |
| Snow | 无雪负样本和真实雪景；当前启发式不得作为普遍能力 |
| 实际效果 | 选区响应大于非选区、无错向、无空mask伪成功、原生分辨率裁切一致 |
| 生命周期 | 取消、切照片、退出、重启、旧任务、模型缺失、下载失败与快照丢失 |

## 开发版本的产品范围

用户在编辑器内准备主体、背景、前景实例、画笔或已安装的天空、水面、物体选区。菜单提供键盘选择实例，也支持画布上的点选和框选。选区采用前可以检查红色覆盖、添加画笔、减去画笔或取消。每次采用只增加一笔历史。个人预设从受支持的语义目标在目标片重新计算。

本机系统能力随编辑器可用。可选运行库及权重由用户显式安装。人体部位、自动雪地和山体仍在独立验证阶段。公开发布及与 Camera Raw 基础编辑联合签收另行安排。[编辑器功能实测](editor-validation.md) · [可选模型包](model-pack.md) · [联合验收](../031-preset-browser/integration-validation.md)
