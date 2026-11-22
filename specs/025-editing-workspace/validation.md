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
