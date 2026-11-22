# 编辑性能与 Lightflow 对照

## 测量范围

- 同一 Sony RAW：9504 × 6336，SHA-256 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`。
- RAWMaster 使用 Release、2400 × 1600 交互代理、真实 `EditingController`、真实预览服务和原生 AppKit 画布。
- 指标从程序化配方提交计时到当前帧被画布接受并返回绘制。它不是物理鼠标输入到 WindowServer 呈现的时间。
- Lightflow 使用同一 RAW、相同画布尺寸和 GPU-idle 后的帧事件。两者计时边界不同，因此不计算严格百分比领先或统一 p95 排名。

报告：`output/performance/editing-ui-baseline-v3-20261120/editing-interaction-performance.json` 和 `output/lightflow-research/same-size-runtime.json`。

## 修改前基准

| 场景 | 交互帧中位数 | 交互帧 p95 | 手势结束后 canonical 中位数 |
| --- | ---: | ---: | ---: |
| 曝光 | 26.2 ms | 546.6 ms（含首次冷样本） | 1604.7 ms |
| 颜色 | 24.8 ms | 38.8 ms | 1627.6 ms |
| Texture | 40.2 ms | 48.0 ms | 3859.4 ms |
| Clarity | 40.7 ms | 42.2 ms | 4481.3 ms |
| 光效＋颜色＋Texture 复合 | 41.3 ms | 49.4 ms | 4911.6 ms |
| 全部 36 个交互样本 | 38.2 ms | 49.4 ms | — |

同尺寸 Lightflow 已有运行时样本：曝光 6.0–17.4 ms、Texture 12.8–14.9 ms、Clarity 9.9–10.1 ms、Dehaze 6.6–12.3 ms。基准证实用户反馈：不仅交互帧有差距，手势结束后的完整显影还产生了数量级更大的后台成本。

## REA 证据与实现差异

REA 对发布产物的静态分析继续使用以下证据：

- 应用包：`ev_95aa6154a536ea4340f4e9eb53b10aed6913eb1d1e4f784b82d3d322e3b15ce8`。
- 图像 Worker：`ev_64089236eb2d16d7253d6339c4a3d3cd4c3ad6182e501c9c6516f69b6b949ad3`。
- 像素引擎接口：`ev_4a81938dba394ab5287c52f9b8093d8d273a2d7c56338a023d721325c0276dc3`。
- 完整 WASM 验证与 WAT：`ev_15af35026d2bf80b94d255b0e68afed05e3af9bd76f5bd4b3f14630c543bfea3`。

静态分析不证明运行时调用；运行时样本与静态证据共同支持以下差异：

1. Lightflow 只在配方序号变化时发送配方 JSON；纯缩放和重呈现复用已有配方与纹理。
2. 渲染循环按 `need` 决定是否绘制，并使用 provisional fused programs；没有输入变化时不重复生成帧。
3. 交互、缩放、最终显示共享 GPU 源图、分级纹理与瓦片，不在每次手势结束时切换到另一条完整 Core Image 显影链。
4. RAWMaster 当前在代理后缀、有限值校验和输出之间执行多次完整画面任务；手势结束还会立即提交 canonical。
5. RAWMaster 的 AppKit 画布接受的是独立输出帧，而 Lightflow 的实测边界直接跟随其 GPU 帧完成。两者的显示路径成本不能混为解码成本。

## 本轮优化

- 代理后缀只物化一次；最终输出边界保留有限值校验，移除其前置的重复全图校验。
- 手势结束后等待 180 ms 空闲再提交 canonical；期间的新调整取消旧定时任务，确保只处理最新配方。
- 失焦、 teardown、新输入和保存边界取消延迟任务；保存与导出仍使用原有 canonical 渲染，不使用交互近似帧替代最终成片。

- 原生画布仅在新图片、变换、实际像素状态或背景变化时失效；相同输入不再重复标为待绘制。

## 第一轮复测

真实画布对照门禁 `scripts/check-editing-performance.py` 已通过，完整结果位于 `output/performance/editing-ui-optimized-v1-20261120/comparison-summary.json`。

| 场景 | 修改前交互中位数 | 修改后交互中位数 | 变化 |
| --- | ---: | ---: | ---: |
| 曝光 | 26.2 ms | 19.4 ms | -25.9% |
| 颜色 | 24.8 ms | 21.2 ms | -14.6% |
| Texture | 40.2 ms | 30.8 ms | -23.4% |
| Clarity | 40.7 ms | 37.9 ms | -6.9% |
| 复合调整 | 41.3 ms | 36.9 ms | -10.5% |
| 全部 36 个样本 | 38.2 ms | 30.8 ms | -19.5% |

独立引擎 API 复测位于 `output/performance/flashraw-interactive-operators-optimized-20261120/interactive-performance.json`：曝光＋颜色 11.3 ms、Texture 16.5 ms、Clarity 16.6 ms、几何 9.9 ms。该口径与 Lightflow 的 GPU-idle 帧事件仍不完全相同，但已进入相同数量级；真实画布仍慢于纯引擎返回，因此不能只用该表宣称端到端达标。

首次曝光样本的冷启动离群值从 546.6 ms 降为 154.1 ms，但样本量不足以单独声称冷启动改善幅度。Canonical 仍显著慢于交互路径，因此本轮延迟和合并的是重复工作，并没有把最终保存或导出替换为近似代理。


## 最终连续交互验收

为减少每个样本都执行 canonical 所造成的热负载，最终协议改为每组连续交互、仅在该组末尾执行一次合并 canonical。协议标识为 `interactive-burst-one-settled-per-case-v1`；它与旧协议的 `baselineCompared = false`，不计算伪同口径提升。

低延迟交互帧使用 AppKit 中档重采样；实际像素仍为 `.none`，settled 仍为 `.high`。原始 RAW 哈希在测试前后完全一致。

| 场景 | 最终交互中位数 | 本组一次 canonical |
| --- | ---: | ---: |
| 曝光 | 16.0 ms | 1755.9 ms |
| 颜色 | 17.9 ms | 1826.5 ms |
| Texture | 25.5 ms | 3921.2 ms |
| Clarity | 34.1 ms | 4439.3 ms |
| 复合调整 | 34.2 ms | 4467.2 ms |
| 全部 36 个交互样本 | 25.5 ms | — |

最终报告和门禁分别位于 `output/performance/editing-ui-burst-final-20261120/editing-interaction-performance.json` 与同目录 `comparison-summary.json`，结果为 `passed = true`。绝对中位数门槛为曝光／颜色 30 ms、Texture／Clarity 35 ms、复合 45 ms、整体 40 ms。本次首个曝光冷样本为 157.3 ms，仍计入整体统计；不能仅用中位数掩盖冷启动离群值。

旧协议在后续重复运行中也出现过 Clarity 相对首轮基准回升的门禁失败，因此不把单次低值当作稳定全面提升。最终协议和旧协议分开保存。与 Lightflow 的 6–17 ms 样本相比，当前曝光／颜色已经接近，但 Texture、Clarity 和复合帧仍有差距；本报告不宣称严格同水平或物理输入到屏幕领先。

## 最终应用验收

- 完整 Debug：1,622 项测试、67 项条件跳过、0 失败；完整 Release：1,573 项测试、67 项条件跳过、0 失败。两者包含的条件编译测试数量不同，不合并计数。
- 使用重新构建并严格验签的隔离应用副本和最终性能 fixture，实际完成曝光 0.35、饱和度 0.18、分区切换、窗口缩放、适合／实际像素切换、失焦恢复及保存候选版本。
- 保存结束后显示“所有调整已保存”，调整值保持不变；整个流程未再出现持续的“读取照片调整信息”。
- 验收截图：`output/acceptance/editor-final-20261120/editing-final.jpg`。

## 2026-11-21 双栏与实时编辑复测

实时配方持久化、历史面板和色彩渐变滑杆加入后，使用同一 RAW、同一连续交互协议重新运行 Release 基准。门禁仍为 `passed = true`，报告位于 `output/performance/editing-live-ui-20261121/`。

| 场景 | 交互中位数 | 本组一次 canonical |
| --- | ---: | ---: |
| 曝光 | 18.4 ms | 1785.2 ms |
| 颜色 | 20.2 ms | 1903.5 ms |
| Texture | 26.6 ms | 3978.7 ms |
| Clarity | 32.2 ms | 4384.9 ms |
| 复合调整 | 33.9 ms | 4476.6 ms |
| 全部 36 个交互样本 | 28.1 ms | — |

这次结果相对前次 25.5 ms 有波动，但所有分项和整体均通过既定绝对门槛；不能把两次运行解释为单调优化。跨应用口径限制保持不变。

- 第二轮完整 Debug：1,580 项测试、67 项条件跳过、0 失败。随后新增的退出前实时写入专项单独通过。
- 最终应用构建版本 26.0，严格验签通过。
- 实际窗口完成曝光 0.55、历史记录、裁切悬浮面板、返回资料库和重新进入；数值与左栏／胶片均保持，未出现持续读取提示。
- 验收截图：`output/acceptance/editing-live-20261121/editing-live.jpg`。
