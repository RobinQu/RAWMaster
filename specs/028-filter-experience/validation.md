# 028 · 生产验证记录

Camera Raw 交付版本上的 Classic 窗口、十候选及全尺寸导出实测见[联合验收记录](../031-preset-browser/integration-validation.md)。下面保留 028 原始测量。

2026-11-22 更新。031 的独立开发版已将左栏风格入口接入元数据目录，并保留经典滤镜。以下数值对应 028 历史构建；后续联合窗口验证沿用相同绘制边界。[031 交付](../031-preset-browser/feature-validation.md) · [对齐后验收](../031-preset-browser/integration-validation.md)

## 028 独立版本的结论

固定九滤镜 + 原片的交互代理、独立缩略图、内容键、last-known-good、有界恢复、hover、收藏和键盘导航已经实施。真实 RAW 的十组 canonical settled、全尺寸 PNG16 导出、暖十候选吞吐、滤镜相关 Debug/Release 回归均通过。

**M0/M1 尚未 Converged**：真实 AppKit 暖路径仍为 p50 27.367 ms、p95 34.061 ms，未达到 p50 ≤ 20 ms、p95 ≤ 33 ms；实际 VoiceOver／物理键盘窗口验收未完成。不得用 Service 成绩或模型层零空白替代这两个门。

## 固定样本与版本证据

- RAW：Sony ILCE-7RM5，9504 × 6336。
- 源 SHA-256：`8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`。
- 设备：Apple M4 Max；性能均为 Release。
- 主图／settled 输出：2400 × 1600；缩略图代理 256 × 171；滤镜目标 192 px。
- Git HEAD：`b89702e8714fd0fd23c809474e0fe581c613cb3b`；工作区含并行未提交修改，关键源码逐文件 SHA 保存在 `output/performance/filter-validation-source-20261121.json`。
- 所有性能运行后源 SHA 均保持不变。

### 最终原始证据

| 项目 | 文件 |
| --- | --- |
| 生产 Service | `output/performance/filter-service-final-20261121-v2/production-filter-interactive.json` |
| 真实 AppKit | `output/performance/filter-canvas-final-20261121-v3/editing-interaction-performance.json` |
| 十候选与暖整组 | `output/performance/filter-thumbnail-final-20261121/filter-thumbnail-direct-validation.json` |
| 十组 settled 与导出 | `output/performance/filter-canonical-final-20261121-v3/real-raw-filter-canonical.json` |
| 全尺寸导出 | `output/performance/filter-canonical-final-20261121-v3/filter-vivid-37.png` |

早期失败和中间版本目录保留，不覆盖；它们不作为最终通过证据。

## 已实施的正确性契约

- 近整数尺寸吸附仅处理 `1e-9` 内浮点噪声，其余保持 `ceil`；9504 宽、192 target 不再产生 193 px。
- 支持域 filter 进入 2400 px 代理；Photo Filter 在 Global 后、advanced/mask 前，主图与缩略图共享 suffix，LUT 不重复应用。
- 缩略图 managed 路径一次渲染 F32，再逐像素检查 finite/alpha 并转换 sRGB RGBA8；F32/RGBA8 临时存储计入 ledger。
- 新旧缩略图路径已对拍 Original + 九滤镜，覆盖 Mono/Noir、alpha 0/0.5/1、HDR、负值和 37.5% 非目录强度；最大 8 位通道误差门为 3，测试通过。
- NaN、无穷值、负 Alpha、Alpha > 1（未获明确 RAW transport 修复时）继续失败。
- 主图有限值检查改为 16 × 16 并行分块归约，仍检查全部像素；边界、不完整尾块、透明 NaN 和非法 Alpha 回归通过。

## canonical RAW Alpha 阻断与修复

最终验收首先复现了真实阻断：Original settled 成功，九个有效滤镜全部 `DevelopmentError.invalidEncoding`，导出同样失败。分阶段实测得到：

- 滤镜前 `nonfiniteMaximum = 0`，最大 RGB 约 1.068，不是 HDR 溢出。
- 滤镜前最大 Alpha 为 `1.0000004`，对应实测 1–3 ULP transport 上界。
- 未修复时滤镜后 `nonfiniteMaximum = 1`；严格归一化该有界域后降为 0。

修复仅在 canonical RAW 滤镜调用显式开启：Alpha bit pattern `0x3f800001...0x3f800003` 归一为 1。普通图片、第 4 ULP、负值、NaN 和无穷值不放行；没有使用普遍 clamp。

最终十组 settled 均为 `approximate = false`、2400 × 1600，单组约 2354–2984 ms。Vivid 37% 全尺寸 PNG16 导出成功：

- 尺寸：9504 × 6336。
- 文件字节：330,504,557。
- 导出耗时：11.501 s。
- LUT 资源 union：0。
- 原文件 SHA：不变。

真实 UI 保存回归另外归档 Noir 配方和 canonical PNG，重新从数据库读取版本一致，源文件不变。

## 性能结果

### 生产 Service

计时为 API 调用到 frame return，不含 AppKit draw 或物理输入到屏幕。

| 指标 | T-006 后 | 最终 |
| --- | ---: | ---: |
| 暖滤镜中位数 | 18.352 ms | **15.898 ms** |
| p95 | 22.078 ms | **17.705 ms** |
| proxy fills / hits | 1 / 7 | 1 / 7 |
| canonical fallback | 0 | **0** |
| 输出 | 2400 × 1600 | 2400 × 1600 |

最终六样本为 15.050、16.027、15.768、17.705、17.673、15.734 ms。该路径达到 Service 目标，但不是 AppKit 交付门。

### 真实 AppKit 画布

口径为 programmatic recipe commit → accepted AppKit canvas draw return；不是 WindowServer presentation 或物理 input-to-photon。原始 22 样本全部保留，每类首个样本另列为冷样本。

| 指标 | 结果 | 门槛 | 判定 |
| --- | ---: | ---: | --- |
| 暖路径样本数 | 19 | — | — |
| 暖路径 p50 | **27.367 ms** | ≤ 20 ms | **未通过** |
| 暖路径 p95 | **34.061 ms** | ≤ 33 ms | **未通过** |
| 暖路径范围 | 22.895–34.061 ms | — | — |
| 冷 look / compound 首样本 | 723.730 / 714.394 ms | 单独报告 | 未消除 |
| intensity 首样本 | 28.723 ms | 单独报告 | 非冷管线离群 |

所有 interactive 帧均为 approximate。trace 显示实际 `NSImage.draw` 约 0.03 ms，差距主要在渲染完成前的协调／发布路径。提前发布 mailbox 快照的实验没有收益，已撤回；没有为追求数字删除校验或修改门槛。

LightFlow 参考文件只包含 exposure/texture/clarity/dehaze，且边界为 frame event follows GPU idle，不包含同口径滤镜序列。因此不能据此宣称 RAWMaster 已与 LightFlow 滤镜完全一致或给出严格百分比排名。

### 真实 RAW 十候选

独立进程不创建主图 settled 帧，直接调用生产代理与 managed tile：

- Original + 九滤镜全部成功，资源 union 0。
- 冷 256 × 171 代理：695.462 ms。
- 含冷代理首次整组：804.851 ms；不能写成暖路径成绩。
- 8 次暖整组：89.182–104.279 ms。
- 暖整组中位数约 91.188 ms，p95 **104.279 ms**，通过 ≤ 250 ms。
- 当前十项均在可见集，固定 Original 首位顺序足够；不实施额外线程批任务／GPU atlas。

## 生命周期、hover 与收藏

真实 Service + 控制器回归已验证：

- filter selection／intensity 为唯一差异时，十候选内容键不变，完成批次数不增加，重建为 0。
- 连续 8 次颜色变化期间旧图始终存在，模型采样空白计数 0；最终内容键改变并原子替换十张图。
- 上述“空白 0”是模型／租约层观测，不是 WindowServer 物理空白帧计数。
- 暂时错误采用最多 5 次 50/100/200/400/800 ms 退避；隐藏、替换、新配方和手动重试取消旧恢复任务。
- 保留旧图时若最终失败，错误和手动重试入口仍可见；不支持与暂时源／资源错误分类。
- hover 使用独立 consumer，不改 committed recipe、历史或缩略图内容键；交叉 hover、比较切换和晚到帧不能覆盖当前呈现。
- hover 返回时复核 token、context、recipe、主图 revision、presentation、比较／裁切／原片和手势状态。
- 收藏稳定优先排序并跨控制器持久化；未知 ID、Original 和重复项被清理并回写。
- 键盘方向键按两列网格移动焦点，焦点触发临时预览，确认走现有提交命令，Escape 恢复。

## 回归状态

- 滤镜相关 Debug：80 项执行，1 项按条件跳过，0 失败。
- 滤镜相关 Release：80 项执行，1 项按条件跳过，0 失败。
- 滤镜 UI／真实 Service 专项：6 项执行，0 失败；包括真实保存、内容键、零空白、收藏、交叉 hover 和晚到帧。
- 全项目 Debug：**1684 项执行，71 项按条件跳过，0 失败**；UI 468、SequenceProbe 30、Imaging 821、Diagnostics 19、Core 326、AI 20，各测试 bundle 均正常结束。

## 028 独立验收结束时的遗留项

1. **T-023**：AppKit 暖路径 p50／p95 未达标。
2. **T-021**：未做实际 VoiceOver 朗读和物理键盘完整窗口验收；代码标签、焦点和控制器行为已测试。
3. 冷代理／首次 look 仍有约 0.7 s 成本，未与暖路径混合隐藏。
4. 未做物理 input-to-photon、WindowServer 空白帧计数或与 LightFlow 的同口径滤镜严格排名。
5. Camera Matching、DCP/XMP、Adaptive、完整用户配方预设仍不在本规格范围。

## 复现命令

生产 Service（输出目录必须不存在）：

```bash
RAWMASTER_FILTER_SERVICE_PERF=1 \
RAWMASTER_FILTER_SERVICE_PERF_SOURCE="$PWD/output/performance/acr-benchmark.ARW" \
RAWMASTER_FILTER_SERVICE_PERF_OUTPUT="$PWD/output/performance/<new-service-run>" \
swift test -c release --test-product RAWMasterImagingTests \
  --filter FilterPerformanceValidationTests/testOptInProductionServiceFilterInteractivePerformance
```

十候选：

```bash
RAWMASTER_FILTER_THUMBNAIL_PERF=1 \
RAWMASTER_FILTER_THUMBNAIL_PERF_SOURCE="$PWD/output/performance/acr-benchmark.ARW" \
RAWMASTER_FILTER_THUMBNAIL_PERF_OUTPUT="$PWD/output/performance/<new-thumbnail-run>" \
swift test -c release --test-product RAWMasterImagingTests \
  --filter FilterPerformanceValidationTests/testOptInDirectRealRAWFilterThumbnailsWithoutSettledGate
```

十组 settled 与导出：

```bash
RAWMASTER_FILTER_CANONICAL_VALIDATION=1 \
RAWMASTER_FILTER_CANONICAL_SOURCE="$PWD/output/performance/acr-benchmark.ARW" \
RAWMASTER_FILTER_CANONICAL_OUTPUT="$PWD/output/performance/<new-canonical-run>" \
swift test -c release --test-product RAWMasterImagingTests \
  --filter FilterPerformanceValidationTests/testOptInRealRAWFilterSettledAndExportValidation
```

真实 AppKit：

```bash
RAWMASTER_EDITING_PERF=1 \
RAWMASTER_EDITING_PERF_FILTER_ONLY=1 \
RAWMASTER_EDITING_PERF_INTERACTIVE_BURST=1 \
RAWMASTER_EDITING_PERF_SOURCE="$PWD/output/validation/019-preview-ux/adobe/DSC05994-ACR-benchmark.ARW" \
RAWMASTER_EDITING_PERF_OUTPUT="$PWD/output/performance/<new-canvas-run>" \
RAWMASTER_LIGHTFLOW_REFERENCE="$PWD/output/lightflow-research/same-size-runtime.json" \
swift test -c release --test-product RAWMasterUITests \
  --filter EditingInteractionPerformanceTests/testOptInRealRAWCompoundEditingCanvasPerformance
```
