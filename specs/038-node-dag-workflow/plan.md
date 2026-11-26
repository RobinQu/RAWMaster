# Implementation Plan: 038 · Node DAG 工作流与暗房界面

**Date**: 2026-11-26 · **Spec**: [功能规格](spec.md) · **Prototype**: [摄影工作台](../../docs/ui/prototype/index.html) · **Evidence**: [验证记录](validation.md)

## Summary

先稳定现有显影配方、照片预览、不可变版本及导出契约，再分阶段把图结构和交互接入原生暗房。首个可发布切片是「打开旧片 → 一个 Corrector → 调整／撤销 → 查看终稿 → 保存候选 → 导出」。默认视角 100% 可读居中，图与主图独立；多节点编辑和中间输出须通过 T04 的预览与交付隔离验收后才开放。HTML 已用于交互评审，本文是原生研发计划，不是原生实现或像素验收。未初始化或执行仓库中不存在的 Spec Kit CLI。当前研发授权已包含原生开发与验收，不包含提交或发布。与 [037 计划](../037-color-film-hdr/plan.md#调度与判定)统一顺序：先开发固定阶段和旧配方只读投影，再接暗房、冻结最终输出与多节点；并行推进各自独立的输入、模型和 HDR 文件测试。原生默认行为和发布状态仍须凭独立验收证据放行。

## Technical Context

| 层 | 复用边界 | 拟增加内容 |
| --- | --- | --- |
| SwiftUI / AppKit | [EditingWorkspace](../../Sources/RAWMaster/EditingWorkspace.swift)、[EditingImageCanvas](../../Sources/RAWMaster/EditingImageCanvas.swift)、[PhotosDevelopmentInspector](../../Sources/RAWMaster/PhotosDevelopmentInspector.swift) | 当前节点工具条、非模态 Graph、可读取景与同色系状态；复用现有独立窗体机制能满足非模态和焦点要求时不再建第二套 |
| 编辑会话 | [EditingController](../../Sources/RAWMaster/EditingController.swift)、[EditingDevelopmentSession](../../Sources/RAWMaster/EditingDevelopmentSession.swift) | 绑定照片／组路径／节点／配方修订的命令与历史；单一发布配方；Graph 表现状态不写照片历史 |
| 渲染 | [EditingPreviewCoordinator](../../Sources/RAWMaster/EditingPreviewCoordinator.swift)、[ImageEdit crate](../../Modules/ImageEdit/Cargo.toml)、[036](../036-render-pipeline-performance/spec.md) 与 [037](../037-color-film-hdr/spec.md) | 固定阶段编译入口、显式查看目标；全图、节点、ROI、颜色域和代际进入请求身份；取消后拒收旧输出 |
| 滤镜 / 交付 | [EditingLeftSidebar](../../Sources/RAWMaster/EditingLeftSidebar.swift)、[DevelopmentPresetBrowser](../../Sources/RAWMaster/DevelopmentPresetBrowser.swift)、[PresetExchangeControls](../../Sources/RAWMaster/PresetExchangeControls.swift)、[WorkbenchDeliveryCatalog](../../Sources/RAWMaster/WorkbenchDeliveryCatalog.swift) | 复用现有存入／导入／导出命令，避免新建预设格式；保存、批量与 [032](../032-export-workspace/spec.md) 仅接收冻结最终版本 |

## Constitution Check

- 遵循仓库原型优先、真实浏览器走查、同输入原生复验的顺序。覆盖表、规格和原生行为同改；模拟与真实证据严格分开。
- 单一配方权威。图查看状态不得成为配方或导出输入；未确认的新交互、未支持的底稿或素材保持禁用与明确原因，不降级成错误像素。
- 不增加第三方前端框架或改变旧预设交换语义。Rust / Swift 跨界复用现有请求和取消契约；只在相应阶段验证后开放新命令。

## Project Structure

本次交互交付位于 `docs/ui/prototype`、`scripts/check-ui-prototype.py` 和本特性目录。未来原生 UI 与会话测试留在现有 RAWMaster Swift 目标及其测试目标；图执行和像素夹具留在 ImageEdit Rust 测试边界。优先增量修改上表所有者，仅为图的持久化、图形交互或渲染接线增加必要单元。不要建立另一套暗房、预设数据库或导出任务入口。

## 实施顺序与放行条件

| 阶段 | 依赖 | 研发动作与检查点 |
| --- | --- | --- |
| T01 · 冻结视图/命令契约 | 原型评审 | 确认导航、100% 可读取景、单节点提示隐藏、主图缩放不受 Graph 影响。固化真实样片、四套桌面/窄窗浅深色证据、键盘与减少透明/动态交互。滤镜菜单与正在维护 028/031 的会话合并时复用当前命令，复查取消、离线及导入后不自动应用。 |
| T02 · 固定图与兼容配方 | T01；与 036/037 对齐 | 先定义 `recipeVersion`、照片阶段、Corrector 参数和稳定节点身份；旧配方先读适配，不在打开 Graph 时重写持久层。用旧版本/候选/撤销栈夹具验证读取与回放、缺字段和未知版本拒绝；固定图与原链共享相同颜色域及输出根。 |
| T03 · 原生壳与首条闭环 | T02；滤镜菜单可独立推进 | SwiftUI 检查器只呈现所属参数。AppKit 非模态窗体做屏幕安全边界、可读取景/全图/手动、键盘焦点回流；窗口状态与节点路由按照片及组路径读取。主图叠加不改变视口，单节点终稿不提示；最终结果以真实样片完成调整、撤销、保存重开和 032 导出。 |
| T04 · 多节点与查看目标 | T02、T03 | 按串行 → Parallel → Layer → Group/模板依次接入图验证。验证必需图像/覆盖端口、回路、拆组和模板重映射。查看请求显式携带最终或节点目标，与交付请求分离；用两节点不同曝光、旧结果晚到、切片/切组及失败重试夹具，证明不会污染不可变版本或导出根。 |
| T05 · 工具、批次与性能放行 | T04；模型、导出可独立验证 | Mask 绑定稳定拥有者，Remove／Crop 属于照片阶段；接回、超时或丢失素材不写错误上下文。资料库批量检查 20 张全部成功和 200 张部分成功/取消/重试；目标版本冲突不得覆盖。用 036 报告中的同一测量口径对比基线、新图与节点监看，冻结门槛后实测，不以 HTML 或单次截图当性能证据。 |

## 验证与发布边界

- **自动检查**：保留 [浏览器用例](../../scripts/check-ui-prototype.py) 和旧兼容导入流程；原生阶段将图结构/序列化、适配、会话/焦点、预览身份、保存/交付与像素一致性分别加入项目现有 Swift／Rust 测试及 CI。运行仓库既定的测试命令，不以脚本通过代替视觉或像素验收。
- **交叉测试**：单节点、长串行、分支、多选、组内路径；桌面和最低窗口、浅/深色、四种照片背景、减少透明，检查节点字高、标题可达、图可平移、状态对比和 VoiceOver。最终、节点临时输出、失败保留、用户返回四种画布状态必须可辨。
- **放行**：每个阶段都要有命令退出码、真实数据/截图和可复现动作；遇到未支持图配方、旧数据不对等或错误导出，保持该能力关闭，旧单照片链仍可工作。原生开发和数据迁移纳入实施；发布不在当前授权内。
