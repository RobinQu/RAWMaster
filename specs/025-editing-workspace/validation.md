# 025 · 收敛与证据索引

## 判定

**Converged（仅限 025 已声明范围）**。后续 AI 正向质量、复杂蒙版性能、跨应用同口径测量和更广输入资格不属于该判定。

## 证据

- 完整功能报告与实现清单：[acceptance-20261121.md](acceptance-20261121.md)。
- 最终 Debug 日志：`output/tools/diagnostics/editing-workspace-full-tests-final-complete.log`；1,594 项、67 条件跳过、0 失败。
- 性能报告：`output/performance/editing-workspace-flashraw-20261121/editing-interaction-performance.json`。
- 性能门禁：`output/performance/editing-workspace-flashraw-20261121/comparison-summary.json`，`passed = true`。
- 编辑窗口：`output/acceptance/editing-workspace-20261121/editing-final.jpg`。
- 导出窗口：`output/acceptance/editing-workspace-20261121/export-workspace.jpg`。
- 旧版与数据备份：`output/acceptance/editing-workspace-20261121/pre-install-backup/`。

## 已修复且不得回归

- Retouch 新请求的分析路由和测试后端覆盖。
- 蒙版输入对象的观察绑定与视图生命周期取消。
- 非主体蒙版造成约 980 MB 整帧第二依赖的问题。
- 显式多选被默认焦点覆盖的问题。
- 旧 White 配方兼容、透明通道、蒙版持久化、Clone 与 Heal 语义混用风险。

## 安装结果

27.0 已安装到 `/Applications/RAWMaster.app`。严格 ad-hoc 签名通过；构建与安装二进制 SHA-256 为 `d6ecefde42e15ad8fe1c08fab93972812a7f7be32f48921b6a1892f47e9a1d88`。未以正式资料库执行开发写入。

## 流程说明

本目录按 Spec Kit 的规格、计划、任务、验收关系整理；未运行 `specify` CLI 或把已有实现伪称为 spec-first。剩余事项见 [tasks.md](tasks.md)。

## 2026-11-23 · 胶片带、快照与调整

[浏览器走查和截图](prototype-review.md#胶片带与调整面板) · [原生胶片带窗口截图](evidence/filmstrip-native.webp)

- **胶片带。** 原生暗房窗口挂载两张组片和一张散片。组名与收起按钮位于首张左侧，三张缩略图上沿和中心对齐。资料库与暗房共用胶片带组件。组模型回归覆盖原顺序、续段、折叠与 RAW+JPEG 伴随文件。 [窗口用例](../../Tests/RAWMasterUITests/EditingLayoutInteractionTests.swift) · [分组模型用例](../../Tests/RAWMasterUITests/SequenceBrowserLayoutTests.swift)
- **滤镜与快照。** 测试从 XMP 导入包含曝光及未知字段的预设。临时图像经原生成像链路渲染，中心采样的红通道随曝光上升。离开清除该帧，主图版本、配方和历史保持原值。对照片创建两条快照后，原生窗口的失焦通知撤销写入上下文，列表仍可读取。调曝光后试看和恢复快照，确认恢复可撤销。[预设原生用例](../../Tests/RAWMasterUITests/PresetMaskEntryPointTests.swift) · [快照用例](../../Tests/RAWMasterUITests/EditingSnapshotTests.swift)
- **右栏。** 展开光效时，曝光数值框和滑块各自可达。切换分级并再次返回，光效保持打开。关闭和打开分级均保留色轮强度。颜色引擎测试用浮点像素对照启用、停用及归档重读。[窗口用例](../../Tests/RAWMasterUITests/EditingLayoutInteractionTests.swift) · [引擎用例](../../Tests/RAWMasterImagingTests/DevelopmentColorEngineV2Tests.swift)
- **快速 Prompt。** 原生窗口打开输入条、切换圈选与全图，再收起并检查底部画布动作。生成、云端预检、候选和撤销沿用可控提供者回归。[Prompt 验证记录](../034-quick-prompt-editing/native-validation.md)

工作台浏览器 22 组通过。原生定向 Swift 测试共 96 项通过，其中 3 项通过 `RAWMASTER_CHECK_ADOBE_PRESET_FIXTURE=1` 补跑，覆盖本机 78 条 XMP、冻结导入重放、源文件变化和景深参数映射。
