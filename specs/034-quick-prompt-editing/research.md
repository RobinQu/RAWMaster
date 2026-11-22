# 034 · 产品参考与技术证据

2026-11-22 · 本轮复用先前 PoC 并核对产品入口、模型文档与本机源码。样本不足以推断公开延迟承诺。当前可操作的界面用仓库样片和本地模拟任务。

| 来源 | 实际核对到的行为 | RAWMaster 决定 |
| --- | --- | --- |
| Dreamer 本地发行包的 `userGuide/guide.html:751–769` 与 `panel/core/selection-fast-flow.js:29–49,94–152` | 手册区分框选浮条 Fast、Agent 与预设。Fast 接可编辑指令及模型／尺寸，普通直生独立于 Chat。提交前锁定文本版本和 SHA，回执不明先恢复既有请求，同一浮条可结束显示。源码的成功流程可直接贴回 PS | 采用单次指令、模型选择、任务与输入冻结。RAWMaster 先给可比较的候选，经用户点击才采用到作品版本。 |
| LibTV 的公开产品页与工具库 | 公开页面分别提供画布、Agent、模型与创作工具。LiblibAI 社区的「动态分镜大师」作者示例按输入条件组合可编辑文本，再链接到独立的单帧修改工具 | 按摄影任务原创四个起稿模板和六条辅助短句，插入后直接编辑。 |
| Apple Liquid Glass 和 HIG | 官方 SwiftUI 文档提供容器共享、形态匹配和交互效果等 API，外观系统支持透明度、对比和运动偏好 | 用一个浮动表面展示原工具与 Prompt，保持画布的锚点和层级。降级路径复用项目已有材质决策。 |
| 030 双模型 PoC | 1024² 单输入下，FLUX.3 MLX Q8 三次写图约 153–210 秒，Seedream 5.5 北京 HTTP 至解码落盘约 10–15 秒。湖面清理的模型裸图都有范围外漂移，本机 Matte 合成后保护区差为 0。人像补光两边都重画面部细节 | 明示生成阶段和审阅，硬范围由本机保障。首批按实际操作、输入条件及可用模型独立签收。 |

Dreamer 本机手册 SHA-256 为 `130415375c9adc5629fba164faed9299bd03c594fcb981cd500669018f16c5c6`，浮条流程源码为 `0e2dd76996d0ff82d44d1a197dea2c606129502bb146ca38b5afa1168b4349f9`。其他现有来源、样本和接缝结果留在 030。[Dreamer 证据索引](../030-ai-retouching/evidence/generative-followup/dreamer-release-index.json) · [LibTV 官方入口](https://www.liblib.tv/) · [社区作者的分镜模板与使用方法](https://www.liblib.art/modelinfo/4d084267bfaa4eb58f3846fe3cf1eb5f?versionUuid=0fe6ddc8f12e4613bbc75ffc15e9c875) · [Apple SwiftUI 指南](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) · [双模型实测](../030-ai-retouching/research.md)

## 模型接入前的两个问题

**FLUX.3 Image Klein。** 正式型号为 FLUX 3 Image Klein，现有 030 使用蒸馏 checkpoint 的 MLX Q8 移植。BFL 的框坐标引导不能限制模型重绘，模型本身需要包含场景、构图和保留对象的完整描述。官方 pipeline 默认用独立的 Prompt upsampler。历史对照使用人工准备的完整英文描述，不能据此判断短中文。P1 对照原样短指令、原生模板生成的完整描述与固定的离线视觉扩写。按同图测指令服从、人物保护、首字响应与峰值内存。正式支持短指令的本地配置须完成该验证，并将有效的处理文本回写作业。部署和商业用途以所选权重的实际许可及设备资格核准。[BFL 模型卡与许可](https://huggingface.co/black-forest-labs/flux-3-image-klein) · [本机模型与原始计时](../030-ai-retouching/flux-validation.md)

**Seedream 5.5。** 方舟的官方版本号为 `doubao-seedream-5-5-261028`，北京图片生成 API 支持单图编辑。API 支持分辨率档及符合范围的显式尺寸。本次复用 030 的单图回执与 PNG。P1 用单图、非流式、单候选，确认实际像素、计费口径、取消与拒收。当前工程适配器已经保存提交意图、读取 Base64 以及表示未知结果，输出字节边界和端点须以实际能力合同验收。[火山方舟模型教程](https://console.volcengine.com/ark/region:cn-beijing/docs/seedream-5-5) · [图片生成 API](https://console.volcengine.com/ark/region:cn-beijing/docs/image-generation-api) · [项目适配器](../../Sources/RAWMasterAI/CloudImageProvider.swift)

文档沿用 Spec Kit 的用户故事、需求和成功标准，再以 plan、tasks、data-model 和 contracts 落到工程与验收。[Spec Kit 规格模板](https://github.com/github/spec-kit/blob/main/templates/spec-template.md) · [实施规划约定](https://github.com/github/spec-kit/blob/main/templates/commands/plan.md)
