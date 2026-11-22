# 030 · 智能修图研发交接

2026-11-22 · 产品与技术研究已归档，应用开发待启动

当前交付顺序是先完成滤镜预设与 AI 蒙版，再在 Camera Raw 基础编辑完成对齐的版本上集成和验收。两项基础功能为后续场景卡提供可复用的参数与范围。本轮不排对话式 Agent。智能修图产品编码留待后续启动，其设计稿、失败样本和验收条款均可从本目录离线查阅。[两项基础功能的集成验收单](../031-preset-browser/integration-validation.md)

## 下一批要解决的摄影任务

| 任务 | 摄影师怎样使用 | 研发开工前的依据 |
| --- | --- | --- |
| 人像、风光、纪实的七张自适应卡 | 局部人物提亮或黑白塑形，风光压天空或控制暮色，纪实选中性、黑白或参考张配平。采用后可编辑范围与参数 | 七卡定义、社区样例、状态设计、严格纪实限制、摄影师走查和成片验收。[产品规格](spec.md) · [场景目录](scene-presets.md) · [交互与视觉](ux-design.md) · [设计稿 PDF](assets/preset-ux-review.pdf) |
| 跨场景去干扰 | 在照片上核对污点、旁人或物体的位置。支持保留、修正选区、预览补全和拒绝候选 | Adobe 各子工具的行为、Dreamer 的选区工作流和污点注入试验。细小污点、遮挡补全、反光须分别验收。[生成专项规格](generative-editing.md) · [产品和实测报告](../../docs/research/generative-retouching-field-review.md) |
| 人像换光与风光参考 | 选择灯位或参考照片，检查光向、五官和衣纹。风光先按雪山、森林、城市、湖泊、海边选择适用风格，再核对地形、建筑和人物 | 留存错光、重画和权重消融案例。摄影师参考、授权状态、底模与 LoRA 配对信息供内容与成像共同审核。[交互样稿](assets/generative-workflows.html) · [社区与配置登记](../../docs/research/landscape-photographers-and-lora.md) |

## 工程接手路径

1. 产品和设计先走查单张预览、草稿取消、换片、无模型和拒绝候选，逐项登记 T020/T025。严格纪实仅运行已登记的原生变换。[需求与成功标准](spec.md) · [任务与依赖](tasks.md)
2. 成像和编辑器基于已经集成的 027/031 版本对接源坐标、稀疏参数、不可变蒙版和采用事务。在同图重开与离线导出时重放冻结结果。生成候选涉及重画时由用户核对原图和作用范围。[技术方案](plan.md) · [源码与上游实现](source-review.md) · [蒙版模型验证](mask-validation.md)
3. 模型工程按用途复核 FLUX.3 Image Klein 和北京 Seedream 5.5 的候选、耗时、受保护区域与失败样张。一次补全成功只支持该样本的结论，人像换光需新的同机位实拍留出集。单输入基准和后续双图／LoRA 对照分开复算。[双模型评估](research.md) · [本机执行配置](flux-validation.md) · [复现命令](quickstart.md)
4. QA 以每个任务和后端为单位记录首候选接受率、等待、重试、100% 原图与导出对照。G1 去干扰、G2 换光、G3 风光风格各有独立准入标准。付款或联网重跑属于新的推理实验，既有证据复核可完全离线。[任务 T026–T031](tasks.md) · [生成专项质量标准](generative-editing.md)

冻结材料包含原始输入身份、提示、候选、分析脚本及评分。先读两份测量文件，再根据其中的任务名查看同目录图像。[单输入配对指标](evidence/paired-metrics.json) · [北京双输入指标](evidence/generative-followup/beijing/paired-measures.json) · [LoRA 配对指标](evidence/generative-followup/lora/comparison.json)
