# RAWMaster Adaptive：相机覆盖与融合方案（验证前）

2026-11-28 · 研究提案 · 不是产品 spec；先验证覆盖与分层，再决定是否立项。

本文接续 [Yellowmoon 与 Adaptive 调色：方案核验与差异分析](yellowmoon-vs-adaptive.md)。结论先行：

1. **覆盖是当前的第一问题，不是算法。** 037 的场景 RAW 入口目前只接受“解码器数据库里的单张 D65 矩阵”，比 yellowmoon 的 11 个 Sony 档更窄；Leica Q3 这类带文件矩阵的 DNG 连门都进不来。
2. **最便宜的一步不是测新相机，而是用文件里已有的矩阵。** FlashRaw 已暴露文件色彩来源、双照度 ColorMatrix、ForwardMatrix、Calibration；当前资格检查把它们全部拒绝。
3. **融合不是把两个算法拼在一起，而是分三层：** 可信输入（yellowmoon 的强项）→ 场景自适应基础（Adaptive 的强项，但低维、可编辑）→ 风格与局部（RAWMaster 的强项）。
4. **先做 L1a 全局自动 + L1b 语义区域，不要先做 PGTM 级空间表。** 前者复用 030 的掩膜和现有统计，能解释、能验收；后者是后续可选。

## 1. 相机覆盖：真正的阻塞

### 1.1 当前 037 场景入口的硬门槛

`Sources/CFlashRaw/CFlashRaw.c:261-270` 要求：

- `file_color_source == FLASHRAW_COLOR_SOURCE_CAMERA_DB`；
- `frame_color_matrix_count(COLOR) == 1`；
- `illuminant == 21`（D65）；
- `Forward == 0`、`Calibration == 0`。

这意味着：

- DNG 文件自带的 ColorMatrix（Q3）不被接受；
- 双照度（ColorMatrix1/2）不被接受；
- DCP 常见的 ForwardMatrix/Calibration 不被接受；
- 只有“解码器数据库里有 D65 矩阵”的机型能进场景路径。

这不是色彩算法问题，是**资格检查**问题；解码器已经提供了数据（`FLASHRAW_COLOR_SOURCE_FILE`、`FLASHRAW_MATRIX_FORWARD`、`FLASHRAW_MATRIX_CALIBRATION`）。把它接进来，是工程工作，不是新的色彩科学。

本机样本已确认：Leica Q3 43 和 DJI FC9313 的 DNG 都带 2 张 ColorMatrix（Standard Light A + D65）和 AsShotNeutral；它们不是缺数据，而是被这条检查拒绝。Sony A7R5／A1 II 则相反：ARW 没有文件矩阵，色彩来自解码器数据库，单张 D65 矩阵。

### 1.2 三台主力机的实际覆盖

| 相机 | 文件／色彩来源 | yellowmoon 的覆盖 | 当前 037 场景路径 | 低成本的下一步 |
| --- | --- | --- | --- | --- |
| Sony A7R5 | ARW；数据库 D65 矩阵 | A7R IV 代打，`white_scale=[1,1,1]`；同传感器检查失败（矩阵差 0.0934 > 0.02） | 数据库有 A7R5 条目则可进；否则不进 | T0b 数据库矩阵 + T3 色卡校准；不要静默用 A7R IV |
| Sony A1 II | ARW；数据库 D65 矩阵 | A7R IV 代打，`white_scale=[0.8675,1,1.0861]` | 同上 | T0b + 色卡验证；T2 只作估计 |
| Leica Q3 | DNG；文件 ColorMatrix | 不支持（Sony-only） | 不接受文件矩阵，不能进 | T0a 接受文件矩阵；T1 DCP（若有）；不需要 SSF |

yellowmoon 对这三台机器的**实测配置覆盖是 0/3**：A7R5、A1 II 用 A7R IV 代打，Q3 完全不支持。这不是否定 yellowmoon，而是说明它的覆盖模型不能直接搬。

### 1.2.1 V0 首轮实测（2026-11-28）

用 FlashRaw 0.3.1 的 Python 元数据接口读取本机授权样本：

| 样本 | 文件数 | `color_matrices.source` | ColorMatrix 数 | Forward／Calibration | 结论 |
| --- | ---: | --- | ---: | --- | --- |
| Sony ILCE-7RM5（A7R5） | 4,502（全库 ARW） | `camera-db` | 1（D65） | 无 | 色彩资格可过；其余几何／黑白检查另验 |
| Sony ILCE-1M2（A1 II） | 8,810（全库 ARW） | `camera-db` | 1（D65） | 无 | 色彩资格可过；其余几何／黑白检查另验 |
| Leica Q3 43 | 1,078（全库 DNG） | `file` | 2（Standard Light A 2,856 K + D65） | 无 | 当前 037 **拒绝**（file source + 双矩阵） |
| DJI FC9313 | 1,122（全库 DNG） | `file` | 2（Standard Light A + D65） | 无 | 当前 037 **拒绝**；另带 DNG 内嵌 profile、tone curve、HueSatMap、噪声 profile |

全库口径：**13,312 个 ARW + 2,200 个 DNG = 15,512 个文件**。ARW 占 85.8%，DNG 占 14.2%；当前场景路径的 DNG 缺口影响全部 Q3／DJI 文件。

首轮结论：

- **Sony ARW 的色彩来源是解码器数据库，不是文件。** 数据库确实有 A7R5／A1 II 的条目，单张 D65 矩阵；所以它们不是“没数据”，而是“数据在库里”。
- **Leica Q3 和 DJI 不是“没数据”，而是“数据在文件里被资格检查挡住”。** 两份 DNG 都带双照度 ColorMatrix 和 AsShotNeutral；接受 `FLASHRAW_COLOR_SOURCE_FILE` + 双矩阵，就能零测量覆盖它们。
- 因此，**最低成本的覆盖顺序是：T0a/T0c（文件矩阵 + 双照度）→ T1（DCP）→ T3（用户色卡）→ T2（同传感器）→ T4（SSF）**，而不是先测 SSF。

> 样本边界：这是本机授权库的全量元数据扫描，不代表所有用户；但足以证明“文件矩阵被拒”是系统性问题，不是个别机型。[元数据审计原始记录](evidence/camera-color-source-audit-20261128.json)


### 1.3 覆盖不是一列，是六个维度

| 维度 | 需要证明的事 | 低成本证据 |
| --- | --- | --- |
| 解码 | 文件能打开、黑／白电平、CFA、方向、裁切 | 现有 FlashRaw 回归 + 每机型样本 |
| 色彩来源 | 矩阵来自文件还是数据库，是否双照度 | `color_source`、矩阵数量／illuminant 清单 |
| 色彩质量 | 色卡 ΔE、肤色、天空、跨机型一致 | 24 色卡 × 3 光源 + 实拍 |
| 镜头 | 畸变／暗角／色差是否有 profile | 镜头数据库 + 样片 |
| 噪声 | 每 ISO 的噪声模型 | 暗帧／平场 + 实拍 |
| HDR／格式 | 压缩 RAW、HDR、DNG 变体 | 每模式一份样本 |

覆盖报告应按“机型 × 文件模式”列出，不按机型名推断。

### 1.4 DNG 文件矩阵的接入要点

- 接受 `FLASHRAW_COLOR_SOURCE_FILE`，不再只认 `CAMERA_DB`。
- 接受 2–3 张 ColorMatrix；用 `CalibrationIlluminant` 和 `AsShotNeutral` 选择或按 mired 插值。Q3／DJI 的两张是 Standard Light A（2,856 K）和 D65，正好覆盖钨丝与日光。两张矩阵的最大系数差：Q3 0.2908、DJI 0.3900；只取 D65 会在钨丝下明显偏色。
- 接受 `ForwardMatrix`／`CameraCalibration` 时按 DNG 规范顺序应用：Calibration → ColorMatrix → ForwardMatrix；不要把它们当噪声丢掉。
- 记录 `BaselineExposure`、`ProfileToneCurve`、`HueSatMap`、`NoiseProfile` 的存在与处理策略。DJI 的 DNG 带内嵌 profile 和 tone curve；忽略它会改变对比，套用它会改变“场景线性”的语义，必须先定政策再接线。
- `source`、矩阵数量、illuminant、是否应用 profile 都写进照片/导出元数据；用户能看到“这张照片的色彩依据是什么”。

### 1.5 T0c 最小验证（C 桥接）

在隔离 worktree `scene-dng-spike` 做了一个 opt-in 的最小改动，不改默认行为：

- C 桥接：`RAWMASTER_SCENE_DNG=1` 时接受 `FILE` 色彩来源、1–2 张 ColorMatrix、illuminant 17/21；`RAWMASTER_SCENE_MATRIX=0|1` 选择矩阵。
- Swift 入口：同一环境变量下允许 `.dng` 后缀。
- 先用独立 C 探针（链接修改后的 `CFlashRaw.c` 和 FlashRaw 0.3.1）验证场景元数据：

| 文件 | `scene_bayer` | 尺寸 | CFA | 黑/白 | As-shot WB | 矩阵 |
| --- | ---: | --- | --- | --- | --- | --- |
| Q3 43 DNG | 1 | 9536×6344 | RGGB | 512 / 16383 | 1.8125, 1, 2.3906 | 0 = A，1 = D65 |
| DJI FC9313 DNG | 1 | 8192×4608 | BGGR | 4096 / 65472 | 2.2727, 1, 1.59375 | 0 = A，1 = D65 |
| A7R5 ARW（对照） | 1 | 9728×6656 | RGGB | 512 / 16383 | 2.5391, 1, 1.7510 | 数据库 D65（单张） |

C 桥接层面已经证明：**Q3／DJI 的 DNG 不是“不能解码”，而是被色彩资格检查挡住；放宽后元数据完整，矩阵选择可控。**

Swift/Metal 渲染也已跑通（9 个 256×256 瓦片，覆盖画面 15%／50%／85% 位置；只切换矩阵，其他不变）：

| 文件 | 平均绝对差 | p95 | 最大 | >0.01 像素 |
| --- | ---: | ---: | ---: | ---: |
| Q3 43 DNG（A vs D65） | 0.00166 | 0.00621 | 0.2660 | 8,457 / 589,824（1.43%） |
| DJI FC9313 DNG（A vs D65） | 0.00139 | 0.00309 | 0.0133 | 86 / 589,824（0.015%） |
| A7R5 ARW（对照，单矩阵） | 0 | 0 | 0 | 0 |

解读：

- **全局平均差异不大**（0.1–0.2% AP1），说明两张样本的整体色调不会因为矩阵选择而剧变；如果真的只看均值，容易得出“单张 D65 也够”的错误结论。
- **局部差异真实存在**：Q3 的 p95 为 0.0062、最大 0.266，1.4% 的像素超过 0.01。最大差像素的 AP1 值：A 矩阵 (1.482, 0.517, 2.925) vs D65 (1.748, 0.591, 3.138)，是超白高蓝像素；差异集中在高亮饱和色，不是随机噪声。DJI 的局部差异小得多（最大 0.0133，最大差像素是暖色中间调）。
- 两张 DNG 的 AP1 均值约 0.04，样本整体偏暗；高调、天空或舞台场景可能给出不同的分布，V1 必须补。
- 因此，T0c 的双照度选择是**值得做、但需要按内容验证**的：不能宣称“换了矩阵就明显更准”，也不能用一张图的均值代替色卡验收。
- 下一步应该把这两张样本的差异区域（最大差像素、饱和色、肤色、天空）和 24 色卡 ΔE 对齐，再决定 v1 是“选最近照度”还是“按 mired 插值”。

测试入口：`Tests/RAWMasterImagingTests/DevelopmentSceneDNGSpikeTests.swift`，环境变量 `RAWMASTER_SCENE_DNG=1`、`RAWMASTER_SCENE_MATRIX=0|1`、`RAWMASTER_SCENE_DNG_FIXTURES`、`RAWMASTER_FLASHRAW_LIBRARY`。隔离 worktree 为 `scene-dng-spike`；改动不进入主工作区。[T0c spike 补丁](evidence/t0c-dng-spike.patch) · [Spike 测试源码](evidence/DevelopmentSceneDNGSpikeTests.swift)

回归：`DevelopmentSceneRAWV1Tests` 5 项（1 项 opt-in 实拍跳过）0 失败；spike 1 项通过。

### 1.6 DNG profile 语义：BaselineExposure 是必需项

T0c 不能只“接受矩阵”。DNG 文件还带 `BaselineExposure`、`ProfileToneCurve`、`HueSatMap`、`NoiseProfile`；它们不是可选装饰。

- Q3 43：`BaselineExposure=0`，无 tone curve／HueSatMap／噪声 profile；场景渲染与相机预览、Apple `sips` 渲染的明暗关系接近。
- DJI FC9313：`BaselineExposure=1.5`，带内嵌 profile、tone curve（36×10×1、2 组）和噪声 profile。**不应用 BE 时，场景显示均值约 0.13；应用 `2^1.5` 后约 0.29；相机预览／Apple `sips` 约 0.45。** 应用 BE 是必需的，否则默认渲染明显欠曝。
- 应用 BE 后，DJI 仍比相机／Apple 暗约 0.65 EV，且更平；剩余差异来自 `ProfileToneCurve`／`HueSatMap` 和默认显示 look，不是矩阵选择。

因此，正式 spec 必须把 DNG profile 分成两层：

1. **场景参考层**：`BaselineExposure` 必须进入输入变换；`AsShotNeutral` 已用于白平衡。
2. **相机外观层**：`ProfileToneCurve`／`HueSatMap` 是“相机默认 look”，应作为可开关、可 Amount 的外观，不应偷偷塞进场景线性基底；忽略时必须显示原因。

这一步没有产品决策就不能定稿：把 DNG tone curve 当“相机匹配”默认，还是当可选 look？两种都合理，但会影响 L1a/L1b 的输入和用户预期。


## 2. 覆盖阶梯

| 层 | 方法 | 单机成本 | 覆盖 | 质量 | 用途 |
| --- | --- | --- | --- | --- | --- |
| T0a | 文件内 DNG ColorMatrix + as-shot WB | 工程一次 | 所有带矩阵的 DNG | 基线 | Q3 等 DNG 的首选 |
| T0b | 解码器数据库 D65 矩阵 + as-shot WB | 工程一次 | 数据库有机型的 RAW | 基线 | Sony ARW 的现状 |
| T0c | 双照度 ColorMatrix + Forward／Calibration | 工程一次 | 带这些字段的 DNG | 较好 | DNG／DCP 兼容 |
| T1 | DCP 导入 | 工程 + 兼容测试 | 用户有 DCP 的机型 | 好 | 用户自带 profile |
| T2 | 同传感器代打 + white scale + 矩阵检查 | 每家族一次 | 同传感器机型 | 中；必须色卡复核 | Sony 家族 |
| T3 | 用户色卡校准（ColorChecker × 2 光源，端上拟合） | 用户约 10 分钟，计算秒级 | 任意机型 | 好；取决于拍摄 | 长尾覆盖 |
| T4 | 实测 SSF（实验室） | 高 | 重点机型 | 最好；可设 ΔE 门槛 | 战略机型 |

原则：

- **T0 必须永远可用**；不能因为缺 profile 就拒绝打开，或静默套一个不准的代打。
- **T2 只有在色卡上打败 T0 才发布**；否则标“估计”，让用户选 T0。
- **T3 是长尾的关键**：不依赖厂商数据，用户自己就能覆盖冷门机身；端上拟合，不上传 RAW。
- **T4 不是默认答案**；yellowmoon 的 81/99 失败说明“测了 SSF + 3×3”也不等于通用准确。

### 2.1 覆盖指标

- `decode`：支持格式的打开率。
- `color-baseline`：至少有 T0 矩阵的照片比例。
- `color-verified`：T1–T4 验证过的照片比例。
- `unknown`：没有矩阵／未验证的相机比例；必须可见。
- 目标：活跃照片 90% 至少 T0，50% verified，0 个静默代打。

### 2.2 为什么 T3 可行

- 一台相机 + 一张 ColorChecker + 两个光源（D65／钨丝，或 D65／LED），每个光源 3 档曝光。
- 端上拟合：先解 3×3 + 对角白平衡，再加一条低阶影调曲线；用留出色块做 ΔE00 交叉验证。
- 失败时明确告诉用户“样本不足／有剪切／光源不一致”，不生成 profile。
- 生成的 profile 记录相机、镜头、光源、日期、算法版本、留出误差；可导出／导入。
- 这比逐台测 SSF 便宜两个数量级，而且覆盖任何品牌。

## 3. 融合架构：三层，不是一个大模型

```text
L0 可信输入        L1 场景自适应基础        L2 风格与局部
相机／光 → ACEScg   全局 + 语义区域 + 可选粗场   look + 030 卡片 + 蒙版
(yellowmoon 的强项)  (Adaptive 的强项)          (RAWMaster 的强项)
```

### 3.1 L0 · 可信输入

- 目标空间：ACEScg AP1（不是 ALEXA／AWG）。
- 相机变换：T0／T1／T2／T3／T4 分级；记录 profile ID、版本、置信度。
- 光照估计：可选的 yellowmoon 式小模型（1/8 预览、拍摄白平衡先验、类别概率）；用于 WB 和 L1 的强度门控。
- 融合：校准 + WB + 曝光折叠成一个矩阵；色温／曝光变化只重算矩阵。
- 失败：不静默代打；显示“估计／未验证”，并限制 L1 强度。

### 3.2 L1 · 场景自适应基础

按代价从低到高：

**L1a 全局自动**（先做）

- 曝光：保留拍摄者曝光，只做高光保护 + 暗部地板；默认 ±0.35 EV 内，明显欠曝／过曝才放宽。spike 的“中位亮度到 18%”规则给出 Q3 +2.36 EV、A7R5 +0.84 EV、DJI +0.55 EV，说明单靠曝光保护不够，L1a 需要基础 tone curve 或相机 look。
- 白平衡：as-shot + 光照估计；肤色保护；保留刻意的冷暖。
- 影调：按直方图做高光压缩／阴影提升；对比按场景 key。
- 颜色：饱和／自然饱和，保护肤色和天空；不做全局色相偏移。
- 产出：一组可读的参数，不是像素；Amount 0 = 基线逐位一致。

**L1b 语义区域基础**（第二步，最像 Adaptive 的部分）

- 复用现有 sky／subject／people／background 掩膜；按区域统计相对全局的曝光、高光、阴影、色偏。
- 每个区域一条 1D 影调曲线 + 色温／色调偏移；强度可调；可手改掩膜。
- 规则示例：天空高于全局 1 EV 且有剪切 → 高光 −0.3 EV；主体比全局暗 1 EV 且有人脸 → 局部 +0.2 EV；背景比主体亮 → 轻微压暗。
- 与 030 卡片的关系：自适应基础是“自动起调”，卡片是“明确意图”；用户采用卡片时，卡片覆盖同区域的基础调整，不叠加两次。
- 这是“Adaptive Profile 的效果”，但不是 12k 曲线的黑盒。

**L1c 粗场**（可选，后做）

- 32×24 或 64×48 的亮度增益场；双边网格／导向滤波；只做低频影调，不做颜色；Amount 限制；门禁看光晕／剪切。
- 用于没有掩膜的逆光／大光比；有掩膜时让 L1b 优先。
- 这是 PGTM-lite；不做逐格单调曲线，避免复杂度和不可解释。

**L1d 小色表**（暂不做）

- 17³ LUT 或 3×3 + 曲线；只在 L1b 证明不够时考虑；默认拒绝，因为不可解释、难验收。

### 3.3 L2 · 风格与局部

- look：CDL + LUT，独立于 L1；SDR／HDR 共用场景母版，不做两套生成。
- 030 卡片 + 蒙版：明确意图、可编辑、可撤销。
- 顺序：L1 在摄影前缀；L2 在 DAG／look；不把 L1 塞进每个节点。

### 3.4 为什么这样融合

- yellowmoon 给不了局部；Adaptive 给不了可信输入；RAWMaster 两者都需要。
- L1b 复用现有掩膜和 030 的参数语言，验证成本最低，用户能看懂。
- L1c 只解决“没有掩膜的大光比”，不抢 L1b 的职责。
- 不追求 Adobe 的 12k 曲线；追求“可解释的 80% 效果”。

### 3.5 RAWMaster 的差异点

- **输入可信度可见**：每张照片知道自己的色彩来源（T0a/T0b/T1/T2/T3/T4）、版本和置信度；yellowmoon 只有“Sony 档 + 代打”，Adobe 不暴露。
- **自适应基础可编辑**：L1b 输出的是区域曲线／冷暖偏移，不是不可见的 PGTM/RGBT；用户可以改掩膜、改参数、关掉。
- **系列一致**：Series Lock 锁定参考张的全局曝光／WB，掩膜逐张重算；避免逐图自适应闪烁。
- **离线可复现**：L0/L1 端上计算，固定版本、固定输入；重开／导出不调用模型，和 030 的验收口径一致。

这三条合起来，才是“RAWMaster 自己的 Adaptive”：**可信输入 + 可解释的场景自适应 + 可编辑的局部/风格**，而不是 yellowmoon 的固定 cinema look，也不是 Adobe 的黑盒 Profile。

## 4. 产品形态

- **Neutral（Verified）**：只做 L0；相机可信、无自动风格。
- **Adaptive**：L0 + L1a／L1b；Amount；显示“改了什么”（全局／天空／主体）。
- **Look**：Adaptive + L2 look；ARRI／胶片／个人 LUT。
- 相机徽标：Verified／Estimated／Metadata／Unknown；导出记录 profile ID／版本／置信度。
- 未验证相机：默认 T0 + 保守 L1a；不自动上 L1b；提供“校准这台相机”向导。
- 批量：Series Lock（参考张锁定全局曝光／WB，掩膜逐张重算）；避免闪烁。
- 离线：L1 端上计算；重开／导出不调用模型；结果可复现。

### 4.1 强度门控

| 输入置信度 | L1a | L1b | 提示 |
| --- | --- | --- | --- |
| Verified（T1/T3/T4） | 全量 | 全量 | 无 |
| Estimated（T2） | 全量 | 上限 70% | “基于同传感器估计” |
| Metadata（T0） | 保守（±0.35 EV） | 关闭 | “未验证，可校准” |
| Unknown | 仅曝光保护 | 关闭 | “不支持该机型” |

这条规则的目的：**不要让 L1 遮住 L0 的错误**。输入越不可信，自适应越保守。

## 5. 验证序列（spec 之前）

| 阶段 | 问题 | 数据／方法 | Go／No-Go |
| --- | --- | --- | --- |
| V0 矩阵来源审计 | 每台相机到底有没有矩阵、从哪来、能不能进场景路径 | A7R5／A1 II／Q3 + 3 台其他品牌；记录 color_source、矩阵数／illuminant、DCP、当前准入 | 每台有明确来源；unknown 有 fallback |
| V1 T0／T1 质量 | 文件矩阵／数据库矩阵／DCP 到底差多少 | 24 色卡 × 3 光源（D65／钨丝／LED）× 3 曝光；ΔE00、肤色、天空 | 初始门槛 median ≤ 2、p95 ≤ 4；不过则上 T2／T3，不放宽 |
| V2 L1a／L1b 原型 | 自动基础是否真的比基线好 | 100–200 张跨机型／场景；A／B：基线／L1a／L1b／030 卡；盲评 + 指标 | 90% 不回归；偏好 ≥ 基线；Amount 0 逐位一致；确定性 |
| V3 L1c 粗场 | 没有掩膜的大光比是否值得 | 逆光／天空／舞台 30 张；光晕、剪切、肤色 | 只在 L1b 不足时立项；不达标就砍 |
| V4 批量／性能 | 系列是否闪、是否够快 | 12 张混合光序列；p95、缓存、重开／导出 | 无可见闪烁；p95 达标；导出逐位可复现 |
| V5 spec | 以上都过 | 汇总证据 | 才进入产品 spec |

V1 的门槛是**初始压力值**，不是行业标准；如果 T0 普遍超过，说明必须上 T1／T2／T3，而不是放宽门槛。

## 6. 风险

- **输入错误被自适应掩盖**：L1 越强，越难看出相机矩阵错了；必须先过 V1，再开 L1。
- **掩膜失败**：L1b 依赖 sky／subject；低置信时退回 L1a，并显示原因。
- **批处理闪烁**：逐图自适应会漂；Series Lock + 参考张。
- **数据许可**：DNG 矩阵随文件；DCP 用户自带；Weta SSF Apache-2.0；CIE 数据 CC BY-SA；用户校准端上。
- **复杂度／可解释性**：L1c／L1d 是可选，不是默认；每加一层都要有 Ablation。
- **产品预期**：不要宣称“Adobe Adaptive 兼容”；只宣称“RAWMaster Adaptive，可解释、可复现”。

## 7. 开放问题

1. T0 的目标空间是 ACEScg，还是“相机中性 + look”？前者可验证，后者更接近用户预期。
2. DCP 导入做到什么程度：只读矩阵，还是 tone curve／ForwardMatrix？
3. 用户色卡校准的 UX：端上拟合还是服务器？如何防伪／防坏样本？
4. L1b 与 030 卡片的优先级：自动基础先、卡片覆盖，还是反过来？
5. Series Lock 是默认开还是手选？
6. 是否给 L1 一个“强度”总滑杆，还是每个区域独立？

## 8. 参考

- YM 核验：[yellowmoon-vs-adaptive.md](yellowmoon-vs-adaptive.md)
- 当前 037 入口：`../../Sources/CFlashRaw/CFlashRaw.c:261-270`；`../../Sources/RAWMasterImaging/DevelopmentSceneRAWV1.swift`
- 037 计划 T06：`../../specs/037-color-film-hdr/plan.md:42`
- Spec 就绪度评审：[adaptive-spec-readiness.md](adaptive-spec-readiness.md)
- 相机基线：`../planning/06-validation-baseline.md`
- 030 卡片：`../../specs/030-ai-retouching/scene-presets.md`
- Adobe Adaptive 结构：[lightroom-preset-browser-plan.md](lightroom-preset-browser-plan.md)
