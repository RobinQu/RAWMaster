# Adaptive 融合与相机覆盖：spec 就绪度评审

2026-11-28 · 验证收口 · 依据 `docs/research/adaptive-fusion-and-camera-coverage.md` 与其证据文件。

## 0. 结论

**不作为“完整 Adaptive 融合”的正式产品 spec：验证不足。**

可以作为 **Phase 0「相机输入覆盖与 DNG 资格」** 的 spec 候选，但必须先满足两个条件：

1. 用 24 色卡 × 3 光源完成 V1 绝对色准验收；
2. 先定 DNG `ProfileToneCurve`／`HueSatMap` 的产品政策（相机默认 look，还是可选 look）。

在条件满足前，不应把 L1a／L1b、PGTM/RGBT、语义自适应写进同一份正式 spec。

## 1. 验证矩阵

| 验证项 | 状态 | 证据 |
| --- | --- | --- |
| V0 全库矩阵来源审计 | **通过** | 15,512 个文件；ARW 13,312（A1 II 8,810 + A7R5 4,502），DNG 2,200（Q3 1,078 + DJI 1,122）；全部 DNG 为 `file` + 双矩阵，全部被当前 `CAMERA_DB` 门槛拒绝 |
| T0c 解码与场景渲染 | **通过** | Q3 `scene_bayer=1`（9536×6344 RGGB），DJI `scene_bayer=1`（8192×4608 BGGR）；A7R5 对照通过；spike 测试 1 项通过 |
| 双照度矩阵差异 | **通过（已量化）** | Q3：mean 0.00166、p95 0.00621、max 0.2660、1.43% 像素 >0.01；DJI（含 BE）：mean 0.00394、p95 0.00874、max 0.0376、2.36% >0.01；A7R5 单矩阵差异 0 |
| DNG `BaselineExposure` | **通过（已修复）** | Q3=0.0；DJI=1.5；应用 `2^1.5` 后 DJI 显示均值 0.131→0.291 |
| DNG `ProfileToneCurve`／`HueSatMap` | **未决** | DJI 应用 BE 后仍比相机/Apple 暗约 0.65 EV，且更平；Q3 无该 profile |
| V1 绝对色准（24 色卡） | **阻塞** | 本机库无色卡样本；相机 JPEG 与 Apple `sips` 只是外观代理，不是色度参考 |
| L1a 默认影调 | **部分（spike 规则）** | 场景 Neutral 明显暗于相机/Apple；EV sweep 显示需 +1.0～+2.5 EV 才接近；“中位亮度到 18%”规则给出 Q3 +2.36、A7R5 +0.84、DJI +0.55 EV，仍不能统一匹配 |
| L1b 语义区域 | **部分** | 复用 030 掩膜证据：天空 IoU 0.822、水面 0.956、远山 0.343；远山与无掩膜场景仍是风险 |
| V4 批量/性能 | **部分（预览通过）** | release M4 Max：Q3 prepare 56.7 / develop 23.4 / display 1.2 ms；DJI 43.3 / 8.1 / 1.0 ms；A7R5 42.9 / 10.8 / 1.0 ms（1620 px FIT）。全尺寸导出、批量序列闪烁未测 |
| V5 正式 spec | **未开始** | — |

## 2. 关键发现

### 2.1 覆盖瓶颈是资格检查，不是解码

`Sources/CFlashRaw/CFlashRaw.c:261-270` 只接受 `CAMERA_DB` + 单张 D65 矩阵。Q3／DJI 的 DNG 是 Bayer、黑/白电平、CFA、AsShotNeutral 齐全；放宽后 `scene_bayer=1`，能真实出图。**最低成本的覆盖入口是 T0a/T0c，不是先测 SSF。**

### 2.2 `BaselineExposure` 是必需项

DNG 不是“矩阵 + 白平衡”就完了。DJI 的 `BaselineExposure=1.5`；不应用时场景渲染明显欠曝，应用后才接近相机/Apple 的明暗。正式 spec 必须把 `BaselineExposure` 放进输入变换，并把 `ProfileToneCurve`／`HueSatMap` 定义为“相机外观层”，不能静默忽略。

### 2.3 固定 D65 矩阵对 Q3 是错的

用 AsShotNeutral + 矩阵估算拍摄 CCT：

| 相机 | 估算 CCT | 更近的矩阵 | 结论 |
| --- | ---: | --- | --- |
| Q3 43 | 3,710–3,950 K | Standard Light A（2,856 K） | 固定 D65 会偏冷；应选 A 或按 mired 混合 |
| DJI FC9313 | 4,900–5,476 K | D65（6,500 K） | 选 D65 或高比例 D65 混合 |
| A7R5 | 5,466 K | 数据库单矩阵 | 无需双照度 |

因此 v1 至少要做“按 AsShotNeutral 估 CCT → 选最近照度”，更好的是按 mired 插值；两者都要用 V1 色卡决定。

### 2.4 场景 Neutral 不是相机 JPEG 的替代品

EV sweep（sRGB 编码均值）：

| 文件 | EV 0 | EV +1.0 | EV +2.0 | EV +2.5 | 相机/Apple 约 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Q3 43 | 0.148 | 0.240 | 0.353 | 0.414 | 0.45 |
| DJI（含 BE） | 0.293 | 0.428 | 0.572 | 0.642 | 0.45 |
| A7R5 | 0.187 | 0.300 | 0.432 | 0.501 | 0.45 |

这说明“Neutral 场景线性 + ACES 2”默认会比相机 JPEG 暗/平；需要默认 look 或更强的自动影调。**L1a 不能只是 ±0.35 EV 的曝光保护；它需要一个基础 tone curve，或者产品明确接受“Neutral 是暗的、由用户加 look”。** 这是产品决策，不是算法细节。

### 2.5 L1a 的简单规则不够

在 spike 里加了一个最小 L1a 规则：把 AP1 中位亮度推到 0.18，带 0.5% 高光保护，然后走 ACES 2 SDR。结果：

| 文件 | 中位 AP1 | 自动 EV | 自动后显示均值 | 相机预览均值 |
| --- | ---: | ---: | ---: | ---: |
| Q3 43 | 0.0351 | +2.36 | 0.388 / 0.361 / 0.347 | 0.341 / 0.304 / 0.286 |
| DJI（含 BE） | 0.1228 | +0.55 | 0.363 / 0.360 / 0.374 | 0.439 / 0.453 / 0.461 |
| A7R5 | 0.1007 | +0.84 | 0.279 / 0.289 / 0.322 | 0.442 / 0.469 / 0.518 |

结论：**一个通用中位亮度规则不能同时匹配三台相机/三种场景。** Q3 被推得比相机预览更亮，A7R5/DJI 仍明显更暗。L1a 不是“自动曝光”一个数，而是“默认 tone curve / 相机 look + 曝光保护”的组合；这正是需要用户研究和产品决策的地方。

### 2.6 预览性能不是阻塞

release 构建、M4 Max、1620 px FIT（`prepare` 含 RAW 解码与上传；`develop` 为 Metal AP1；`display` 为 ACES 2 SDR）：

| 文件 | prepare | develop | display |
| --- | ---: | ---: | ---: |
| Q3 43 | 56.7 ms | 23.4 ms | 1.2 ms |
| DJI FC9313 | 43.3 ms | 8.1 ms | 1.0 ms |
| A7R5 | 42.9 ms | 10.8 ms | 1.0 ms |

预览路径没有性能阻塞。全尺寸 DNG 导出、批量序列和 60 MP 内存峰值仍未测，不能把这张表外推到导出。

### 2.7 外观代理：没有明显整体偏色

把相机预览、Apple `sips` 和场景渲染归一到同一尺寸，比较 Lab 平均色度（a/b；只作外观代理，不是 ΔE）：

| 文件 | 相机 a/b | Apple a/b | 场景 m0 a/b | 场景 auto a/b |
| --- | --- | --- | --- | --- |
| Q3 43 | 0.517 / 0.518 | 0.512 / 0.513 | 0.508 / 0.506 | 0.513 / 0.514 |
| A7R5 | 0.506 / 0.475 | 0.511 / 0.477 | 0.506 / 0.477 | 0.507 / 0.482 |
| DJI | 0.498 / 0.495 | 0.506 / 0.490 | 0.505 / 0.493 | 0.505 / 0.493 |

三台相机的场景渲染与相机/Apple 的平均色度差都在 0.013 以内，没有明显整体偏色。**但平均色度会掩盖互补误差**（一部分偏红、一部分偏绿可以抵消），所以这只能证明“没有 gross cast”，不能替代 24 色卡 ΔE。亮度差（L）仍然明显，见 2.5。

### 2.8 绝对色准仍无证据

相机 JPEG 和 Apple `sips` 都有厂商 tone curve／色彩偏好；它们可以证明“没有明显偏色/漏光”，但不能给出 ΔE。没有 24 色卡，就不能宣称 T0a/T0b/T1 的色准，也不能决定“最近照度 vs mired 插值”。这是当前唯一的硬阻塞。

## 3. 建议的 Phase 0 spec 范围

如果现在要立一份正式 spec，建议只立 **「相机输入覆盖与 DNG 资格」**：

- 范围：T0a（文件 ColorMatrix）、T0c（双照度／Forward／Calibration）、T1（用户 DCP）；`BaselineExposure`；矩阵选择；profile 元数据。
- 非范围：L1a/L1b、PGTM/RGBT、语义预设、ARRI look、SSF、批量自适应。
- 验收：
  - Q3／DJI／A7R5 各 3 张实拍解码 + 场景渲染；
  - 24 色卡 × 3 光源 ΔE00 median/p95（初始门槛待 V1 基线确定）；
  - `BaselineExposure` 与 profile 处理可解释；
  - 未验证相机显示 `Metadata/Unknown`，不静默代打；
  - 默认行为回归（现有场景测试 5 项 0 失败）。

L1a／L1b 另立研究 spike，不并入这份 spec。

## 4. 需要用户提供的输入

1. **色卡 RAW**：Q3、A7R5、A1 II，各在 D65／钨丝／LED 三种光下拍 24 色卡，每种 3 档曝光；或明确同意使用“合成色卡 + 厂商参考”作为替代（不建议作为发布门槛）。
2. **DNG profile 政策**：`ProfileToneCurve`／`HueSatMap` 作为相机默认 look、可选 look，还是忽略并提示？
3. **默认影调政策**：接受 Neutral 场景线性偏暗，还是提供相机-like 默认 look／L1a 基础曲线？
4. **L1b 用户研究**：至少 6 名摄影师对“自动语义起调 vs 030 卡片”做盲评；这决定 L1b 是否值得立项。

## 5. 证据索引

- [覆盖与融合方案](adaptive-fusion-and-camera-coverage.md)
- [元数据审计 + spike 结果 JSON](evidence/camera-color-source-audit-20261128.json)
- [T0c spike 补丁](evidence/t0c-dng-spike.patch)
- [Spike 测试源码](evidence/DevelopmentSceneDNGSpikeTests.swift)
- [Yellowmoon 与 Adaptive 差异核验](yellowmoon-vs-adaptive.md)
