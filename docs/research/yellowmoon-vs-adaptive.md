# Yellowmoon 与 Adaptive 调色：方案核验与差异分析

2026-11-28 · 研究记录 · 核验 yellowmoon `1c33814`（`0.2.5-beta.1`）与 RAWMaster 当前工作区 `90b3780f` + 未提交改动。

本文回答两个问题：yellowmoon 的“自适应”到底做了什么；它和 RAWMaster 左栏的 Adaptive 滤镜（Adobe 语义预设、Adaptive Profile、030 七卡）是不是同一类能力。结论先行：**不是同一层。yellowmoon 在基础显影层做“光照归一化 + 传感器→目标相机映射”，Adaptive 在外观层做“内容感知的局部／逐图表变换”。**

## 1. 核验范围与方法

| 项目 | 做法 | 结果 |
| --- | --- | --- |
| yellowmoon 源码 | 浅克隆 `https://github.com/ngriaznov/yellowmoon`，HEAD `1c33814`（2026-11-27），版本 `0.2.5-beta.1` | 与 README／docs 对照 |
| yellowmoon 测试 | `cargo test -p ym-color --test chain`、`--test exposure`、`--test chain_spectral`、`--lib sensor_map`、`--test logc`、`--test look_signature` | chain 19、exposure 31、chain_spectral 6、sensor_map 7、logc 12、look_signature 20，共 95 项全部通过（2026-11-28，macOS arm64） |
| yellowmoon 传感器映射门槛 | 未重跑 Python `training.sensor_map.gate`（需要 colour-science 全栈）；数字取自仓库自带的 `training/sensor_map/README.md`、`docs/03-camera-profiles.md` 与 CI 口径 | 标记为“仓库自报，未独立重跑” |
| RAWMaster 现状 | 阅读 `Sources/RAWMasterImaging`、`specs/031`、`specs/037`、`specs/038`、`specs/030` 与当前工作区 | 与规格、代码一致 |
| Adobe 侧 | 只复核仓库已有调研（公开博客、DNG 规范、XMP 实测）；未接触 Adobe 私有实现 | 结构可信，像素不可复现 |

未验证项：yellowmoon 的 GPU 对拍、ARRI 真实 Look Library 导入、Apple／Claude／Antigravity Auto 的实际行为；Adobe Adaptive Profile 的 PGTM／RGBT 生成模型与像素结果。本文只在“公开结构 + 仓库自报”层面使用这些结论。

## 2. 术语

| 名称 | 具体指什么 | 作用层 |
| --- | --- | --- |
| **YM** | yellowmoon 的整条 Sony→ALEXA 色彩链 | 输入／基础显影 |
| **A-语义** | Adobe Adaptive 语义预设：Portrait 12、Sky 9、Subject 9、Landscape 8，共 38 项；Lens Blur 13 项 | 基础显影后的局部层 |
| **A-Profile** | Adobe Adaptive Color／B&W 两个 Profile：逐图 PGTM（128×96，12,288 条亮度曲线）+ 全局／天空／主体 RGBT + 内部近似掩膜 | 基础显影本身 |
| **RM-030** | RAWMaster 自有七张场景卡：逆光人物提亮、明暗黑白人像、天空压高光、暮色冷暖、中性还原、克制黑白、同组参考配平 | 基础显影后的局部层 |

“Adaptive 滤镜调色”在日常语境里常把这四者混称；本文按上表拆开，因为它们的差异并不相同。

## 3. YM 的实测事实

| 事实 | 证据 | 核验状态 |
| --- | --- | --- |
| 仅 Sony ARW；11 个实测配置文件；注册表 46 个机型，其中 25 个回退到 A7R IV | `crates/ym-raw` 的 `.arw` 限制；`data/cameras/sony/` 11 份 SSF；`data/cameras/registry.json` 计数 | 已核对 |
| 每机型光照估计 13,197 个张量值 + 2 个标量（模型卡写 13,199）；11 份模型 | `data/models/illum/*.json`、`MODEL_CARD.md` | 已核对 |
| 合成测试集上，带拍摄白平衡先验的中位角误差 1.22–1.30°；仅直方图 1.79–1.98° | `MODEL_CARD.md` 表 | 仓库自报 |
| 传感器映射是白点保持的 3×3；A7R IV 配置文件含 45 个矩阵（405 个浮点），按光源类别和 mired 插值、凸组合 | `crates/ym-color/src/sensor_map.rs`；`data/cameras/profiles/sony-ilce-7rm4/profile.json` | 已核对 |
| 3×3 的目标不是 ALEXA 原始响应，而是“经过 ARRI 矩阵后”的 Lab 误差 | `docs/02` C2；`training/sensor_map/README.md` | 已核对 |
| A7R IV 的 9 个门槛光源只有 2 个通过；11 个配置文件 × 9 个光源共 81/99 对超限 | `training/sensor_map/README.md:202-231`；`docs/03-camera-profiles.md:250` | 仓库自报 |
| 失败是 3×3 表达能力的上限：在门槛光源本身拟合的 3×3 仍有 6/7 超限；根多项式也只能救回 2/7 | `training/sensor_map/README.md:223-225` | 仓库自报 |
| Auto 曝光不是场景自适应：常数 +1.11 EV，高光保护最多 −1 EV；场景 key 只作诊断 | `crates/ym-color/src/exposure.rs:77-99`；`docs/02` C5 | 已核对 |
| Auto 白平衡把场景白点落到中性；用户 Kelvin 只改“ALEXA 被平衡到的光” | `crates/ym-color/src/chain.rs`；`docs/02` C3–C4 | 已核对（19 项 chain 测试） |
| Look 是静态的：CDL + 3D LUT，按强度在 LogC4 中混合；默认 Signature 是 15 点亮度曲线 + saturation 1.45 | `data/looks/builtin/signature.json`；`crates/ym-color/src/look.rs:1-20` | 已核对（20 项 look 测试） |
| 外部 Auto 只调 12 个全局字段（曝光、高光、阴影、黑场、对比、冷暖、色调、饱和、阴影色／强度、高光色／强度），没有蒙版或空间表 | `docs/22-auto-providers.md:246-257` | 已核对 |
| 外部 Claude／Antigravity 非确定性，发送 768 px 长边缩略图，需用户同意；Apple 端上模型不出本机 | README “Auto grading”；`docs/22` | 仓库自报 |
| 节点／蒙版（形状、颜色范围、亮度范围、画笔、背景、SAM2 物体、人物、深度）是用户显式添加的局部工具，不是 YM 色彩核心的自适应来源 | `crates/ym-color/src/mask.rs`；`docs/23-nodes.md` | 已核对 |

### 3.1 关键机制

YM 把 C1–C6 全部线性阶段折叠成**每张照片一个 3×3**：

```text
M = 2^EV · M_AWG3→AWG4 · M_ARRI(CCT_user) · diag(g_user) · diag(w_A(E_scene)) · M_map(scene) · diag(g_res)
```

- 光照估计给 `w_scene`、类别概率、CCT／Duv；
- `M_map` 按类别概率加权、类内按 mired 插值；
- Auto 白平衡让 C3·C4 精确抵消，场景白点落中性；
- 之后才进入 LogC4、节点、look、显示。

这条设计的真正优点是**把“相机差异”和“现场光”压成极小的状态**：每张照片约十几个数，色温／曝光改变只重算一个矩阵，交互非常快。

### 3.2 它的“自适应”边界

- 自适应对象：现场光（二维色度 + 类别），全局。
- 不自适应：人脸、天空、主体、局部明暗；这些只能靠用户加节点／蒙版。
- Auto 曝光是固定增益，不按画面 key 移动；这是刻意的“相机曝光优先”选择。
- Look 是作者预设，不是逐图生成；Signature 的常数是“按眼睛选的”，没有拟合任何 LUT。

## 4. RAWMaster 的现状

| 事实 | 证据 | 含义 |
| --- | --- | --- |
| 037 的合格 ARW 入口只解码 Bayer U16；接纳“一份数据库 D65 矩阵 + 明确拍摄白平衡”，Bradford 适应到 ACES 白，再进 AP1 | `Sources/RAWMasterImaging/DevelopmentSceneRAWV1.swift`；`DevelopmentCameraCalibrationV1.swift`；`specs/037-color-film-hdr/validation.md:93-95` | 没有逐相机 SSF、没有光照估计、没有 DCP 双光源；与 YM 的输入层差距最大 |
| 038 的 corrector 在**线性 AP1**：先曝光，再按曝光档求曲线增益，最后节点强度 × coverage 混合 | `specs/038-node-dag-workflow/spec.md:191`；`DevelopmentSceneToneV1.swift` | 与 YM 的 LogC4 域不同 |
| 整图摄影前缀在**扩展线性 Rec.709**，处理完再转回 AP1 | `specs/037-color-film-hdr/validation.md:264`；`DevelopmentScenePhotographicV1.swift` | 现有工具链不是 Log 域 |
| 031 的 Adaptive Profile 仍是“可查看、依赖已记录”；严格套用需要 RAW 基底 + 增益表 | `Sources/RAWMasterCore/CameraRawPresetMapping.swift` 的 `adaptiveProfile` 分支；`specs/031-preset-browser/spec.md:52` | PGTM／RGBT 是独立大工程 |
| 031 的语义预设需要逐张语义蒙版 + 验证 Adobe 局部映射；当前按目标逐项开放 | 同一映射文件的 `semanticCorrection` 分支；`specs/031-preset-browser/spec.md:50` | 与 RM-030 同类，不是 YM 的强项 |
| 030 七卡：掩膜 + 固定局部参数，离线、可编辑、逐图重算；重开和导出不调用模型 | `specs/030-ai-retouching/scene-presets.md:27-41`；`specs/031-preset-browser/spec.md:43` | 这是 RAWMaster 自己的“语义自适应” |
| `Sources/` 中没有 LogC／ARRI／ALEXA 实现 | 全局检索无匹配 | 不能直接吃 YM 的 LogC4 look |

## 5. 差异矩阵

| 维度 | YM | A-语义 | A-Profile |
| --- | --- | --- | --- |
| 作用层 | 输入／基础显影 | 基础显影后的局部层 | 基础显影本身 |
| 自适应对象 | 现场光：色度 + 光源类别 | 画面语义：天空、主体、人像部位 | 画面内容 + 全局统计 |
| 每图自由度 | 一个 3×3（6 个自由系数）+ 少量标量 | 掩膜（百万像素级）+ 固定参数向量 | 12,288 条亮度曲线 + 3 张 RGBT + 内部掩膜 |
| 空间性 | 全局 | 局部、离散区域 | 空间连续（128×96 网格） |
| 参照 | ALEXA／ARRI 公开矩阵 + 自估 SSF | Adobe 的场景审美 | Adobe 的生成模型 |
| 可解释性 | 高 | 中 | 低 |
| 可复现性 | 高：确定性、CPU／GPU 对拍 | 高：参数固定，掩膜可冻结 | 低：模型／版本相关，会过期 |
| 失败模式 | 光源估错→全局偏色；3×3 同色异谱误差 | 掩膜错→局部改错，可手修 | 生成过度／不一致，需 Update AI Settings |
| 批处理 | 逐张独立，但目标一致 | 逐张找掩膜，意图一致 | 逐张生成，风格可能漂移 |
| 相机范围 | Sony ARW，11 个实测配置文件，25 个机型回退 A7R IV | Lightroom／Camera Raw 资源 | Adobe RAW 生态 |

## 6. 四个本质差异

**① 自适应的变量不同。**
YM 的潜变量是“光”：一个二维色度 + 类别概率。它假设“同一束光下，颜色应该一致”，所以能解决系列照片的偏色与相机差异，但解决不了“这张脸背光”“这片天空过曝”。Adaptive 的潜变量是“内容”：它不关心光是否准，只关心画面里有什么、哪里该压、哪里该提。

**② 参数化方式相反。**
YM 用物理约束的低维模型：3×3 行和为 1、白点保持、曝光不变、按光源类别凸组合。约束越强，越稳定、越可解释，但表达能力越弱。Adaptive 用高维学习模型：空间增益表、RGB LUT、语义掩膜，表达力强，但不可解释、不可移植、难以复现。

**③ 参照物不同。**
YM 有一个可测量的目标：ALEXA 的公开矩阵和自估 SSF，所以它能设 ΔE 门槛、能公布失败。Adaptive 没有公开参照，“好看”只能盲评。这也是为什么 YM 的文档能写到每个常数，而 Adobe 只能写到结构。

**④ 管线位置不同，而且会争同一个槽位。**
Adobe 推荐的 AI 编辑顺序里，Adaptive Profile 在全局调整和蒙版之前，属于“基础显影”；YM 的传感器映射也在同一段。两者是**竞争关系**：把 ALEXA 模拟叠在 Adaptive Profile 上，等于两次 tone rendering。语义预设则在蒙版阶段，和基础显影正交，可以和任意 base 共存。

```text
                 基础显影层                     局部外观层
物理/相机建模    YM 光照 + 传感器映射            —
学习/内容分析    A-Profile（PGTM + RGBT）        A-语义；RM-030
```

## 7. 对 RAWMaster 的可执行建议

### 7.1 优先做“037 输入变换 v2”，不要做“Adaptive 版 yellowmoon”

YM 的对位是 037 的相机前端，不是 031 的 Adaptive 滤镜。建议把它拆成一个独立专项：

1. **目标**：给合格 RAW 一个可解释、可复现的相机→ACEScg 变换；目标不是 ALEXA，而是“正确的场景线性颜色 + 可选 look”。
2. **数据**：逐相机 SSF（Weta／rawtoaces 的 Apache-2.0 数据可起步）；没有 SSF 的机型继续用现有 D65 矩阵 + 拍摄白平衡，不猜。
3. **模型**：先做 3×3 + 类别／色温混合；用 99 个 CES 反射率 × 9 个留出光源设门槛。阈值应按“到 ACEScg 的目标误差”另定；若沿用 YM 的 0.5／1.2 ΔE00 口径，先把它当作压力测试，而不是通过标准。如果 3×3 过不了，再上根多项式或小型 LUT，并在文档里公布失败，不偷偷放宽阈值。
4. **实时性**：把“校准 + 白平衡 + 曝光”的线性部分融合成一个矩阵；色温／曝光变化只重算矩阵，不重跑前级。这是 YM 最值得抄的工程点。
5. **验收**：CPU／GPU 对拍；固定种子、固定输入、逐位可复现；与现有 037 的 19 项 Release 回归并存；真实色卡（钨丝／日光／LED）另列，不用“看起来像”代替 ΔE。
6. **非目标**：ARRI 模拟、Sony-only 产品化、逐图生成 look、用 LLM 当默认 Auto。

### 7.2 031 的 Adaptive 继续独立立项

- A-Profile 需要 PGTM／RGBT、SDR/HDR、Amount、RAW 前端和内部掩膜；YM 的 3×3 无法替代。
- A-语义 与 RM-030 同类：掩膜 + 固定局部参数；YM 的节点／掩膜只是通用工具，不是它的核心。
- 两者不要在同一个“自适应滤镜”开关下混做；基础显影层与局部外观层分开验收，否则既说不清像素责任，也说不清失败原因。

### 7.3 可借的三件事

1. **把“场景光”和“用户色温”分开**：Auto 白平衡让场景白落中性，手动 Kelvin 只改用户意图。
2. **线性阶段融合成单矩阵**：每图一个矩阵，色温／曝光变化不重跑前级。
3. **base 与 look 分层**：基础显影负责“是什么相机、什么光”，look 负责“什么风格”；look 用 CDL + LUT + 强度，可导入、可替换、可版本化。

### 7.4 不该照搬的四件事

1. **把 ARRI 当成所有用户的默认目标**。它是一个明确的风格选择，不是色彩正确性。
2. **把 3×3 当成通用传感器映射**。YM 自己的门槛就证明它不够：A7R IV 只有 2/9 通过，11 个配置文件共 81/99 对超限；换成更丰富的模型才谈得上“相机匹配”。
3. **把 LLM Auto 当成默认自适应**。它非确定性、要把缩略图发给外部程序，和 030“七卡离线、可复现”的验收口径冲突。
4. **把 LogC4 的 look 直接塞进 AP1 的 DAG**。038 的 corrector 在线性 AP1、曲线按曝光档；LogC4 的 CDL/LUT 是另一个域，必须先定义转换和阶段顺序。

## 8. 本次核验对首轮判断的修正

| 首轮说法 | 核验后 | 影响 |
| --- | --- | --- |
| “11 个 Sony 机型” | 11 个实测配置文件，注册表 46 个机型，25 个回退到 A7R IV | 支持面比“11 个”宽，但回退机型的色彩精度另说 |
| “A7R IV 7/9 光源失败” | 还有 11 个配置文件共 81/99 对超限 | 3×3 的局限是系统性的，不是单机型偶发 |
| “13,199 参数” | 13,197 个张量值 + 2 个标量 | 量级不变，模型卡口径需注明 |
| “Auto 曝光常数 +1.11 EV” | 代码确认，且场景 key 只作诊断 | 不要把 YM Auto 当成 Adobe Auto |
| “RAWMaster 只有 D65 矩阵 + 拍摄白平衡” | 准确说是一份 D65 校准矩阵 + 拍摄白平衡，Bradford 到 AP1；DCP 双光源仍是 037 T06 计划 | 输入层差距明确 |
| “RAWMaster 在线性 AP1 调色” | 038 corrector 在 AP1；整图摄影前缀在扩展线性 Rec.709 | 与 YM 的 LogC4 域差异更具体 |

## 9. 未决问题

1. **目标空间**：037 的最终目标是 ACEScg 交付，还是也给“cinema camera look”留一个可选 look pack？前者是色彩正确性，后者是风格。
2. **相机范围**：只做 Sony，还是把“逐相机 SSF”作为多品牌能力？后者需要持续的数据与许可投入。
3. **模型上限**：3×3 过不了门槛时，是否接受根多项式／LUT 的复杂度？YM 自己的根多项式也只救回 2/7，说明不能把它当万能解。
4. **真实片验收**：没有 ground truth 时，用色卡、双光源实拍、Capture One／Adobe 参考三路交叉；不要把“看起来更像 ALEXA”当成通过。
5. **A-Profile 的边界**：继续只做兼容与依赖诊断，还是投入 PGTM／RGBT 的独立大型项目？YM 对这个决定没有帮助。

## 10. 参考

- yellowmoon 色彩管线：<https://github.com/ngriaznov/yellowmoon/blob/1c33814/docs/02-colour-pipeline.md>
- yellowmoon 模型：<https://github.com/ngriaznov/yellowmoon/blob/1c33814/docs/07-ml-models.md>
- yellowmoon looks：<https://github.com/ngriaznov/yellowmoon/blob/1c33814/docs/08-looks.md>
- 传感器映射门槛：<https://github.com/ngriaznov/yellowmoon/blob/1c33814/training/sensor_map/README.md>
- 机型注册表：<https://github.com/ngriaznov/yellowmoon/blob/1c33814/data/cameras/registry.json>
- 光照模型卡：<https://github.com/ngriaznov/yellowmoon/blob/1c33814/data/models/illum/MODEL_CARD.md>
- RAWMaster 031：`../../specs/031-preset-browser/spec.md`
- RAWMaster 037：`../../specs/037-color-film-hdr/spec.md`、`validation.md`
- RAWMaster 038：`../../specs/038-node-dag-workflow/spec.md`
- RAWMaster 030：`../../specs/030-ai-retouching/scene-presets.md`
- Adobe Adaptive 公开结构与迁移边界：[lightroom-preset-browser-plan.md](lightroom-preset-browser-plan.md)
- 后续的相机覆盖阶梯与三层融合方案：[adaptive-fusion-and-camera-coverage.md](adaptive-fusion-and-camera-coverage.md)
