# 分组按钮

采用 Photos 曲线取色控件的组合方式。每组从外形上显示为一个控件，内部分隔线标出相邻命中区。适用范围是工作台里成组出现的模式、标签和作用一致的短命令。

顶栏的工作流入口使用[独立的胶囊样式](../025-editing-workspace/workbench-chrome.md)。

| 入口 | 作用与返回 |
| --- | --- |
| [主工作台 → 河谷拍摄](../../docs/ui/prototype/index.html#library/project/river) | 在项目、拍摄组或初筛的浏览方式中选择网格、单张、比较。当前范围、选片与 G/E/C 快捷键随视图切换保留。排序仍是相邻的菜单。顶栏在资料库、编辑与导出之间接续同组照片。 |
| [编辑 → 基础](../../docs/ui/prototype/index.html?sceneNativeReview=1#edit/basic) | 色彩外观作用于当前草稿。方向键在可用选项间移焦，按空格或 Return 应用。派生预览和示波器只切换本张判读方式。资料库和导出接续原选片。 |
| [编辑 → 影调](../../docs/ui/prototype/index.html#edit/tones) · [编辑 → 修复](../../docs/ui/prototype/index.html#edit/repair) · [界面规范画廊](../../docs/ui/prototype/index.html#tools/design) | 曲线类型、颜色通道、修复方式、精修画笔、裁切方向、颜色分区与候选对比各自成组。原生曲线的黑点、中间调与白点同组，添加控制点单独呈现。画廊可试操作这组取样命令。现有编辑提交、取消和撤销仍由各工具处理。 |
| [摄影工作台 → 导出](../../docs/ui/prototype/index.html#export) · [032 独立样本](../032-export-workspace/prototype.html) | 导出成片与复制原文件共用交付方式分组。选片清单中的全选与清除勾选共用命令组，仅作用于当前列表范围。切交付方式保留已选照片，退出回到进入时的工作区。 |

## 走查场景

1. 在资料库多选两张，切比较再回网格。用键盘在组内换模式，检查焦点落点和选片是否保留。
2. 从水鸟进入编辑。逐项切换 SDR、HDR、B&W，再撤销。进入修复，选择仿制，完成或取消后返回当前照片。色彩外观的方向键只移焦。
3. 在画廊用 Tab 到达分组，用方向键切换示波器。测试取样命令与独立的添加控制点。在深色桌面和 390px 窄窗查看连续底板、细分隔线、选中、聚焦和禁用状态。
4. 从选片进入导出。在两种交付方式之间切换，在筛选后清除勾选，检查空结果时命令不可用，再恢复勾选。加入离线原件，检查提交失败提示、取消和重试；返回并核对选片。

## 2026-11-28 验证

Chrome 的工作台回归通过 60 个场景，本地库包专项通过 15 个，色彩外观专项通过 14 个。额外用实际键盘从河谷拍摄两张选片进入水鸟的编辑草稿，切换色彩外观并撤销，再进入 032 清空和恢复勾选。导出返回资料库时焦点和原选片一致。390px 下检查共享底板、分隔线和中性焦点，离线、空选片、生成失败后的重试与取消沿用对应流程。

[浏览器资料库](evidence/grouped-buttons/browser-library-light.png) · [浏览器色彩外观](evidence/grouped-buttons/browser-editor-dark.png) · [390px 浅色](evidence/grouped-buttons/browser-gallery-light-narrow.png) · [390px 深色](evidence/grouped-buttons/browser-gallery-dark-narrow.png)

在 macOS 27.0.1 的隔离工作库中选中 `Portrait.ARW` 与 `MountainLake.jpg`。工作台收窄到 1100pt 后，方向键在「网格」「单张」「比较」之间切换，Home 返回网格。从编辑的 SDR 移焦到 HDR 后按 Return，原生显示场景处理的禁用状态并进入 HDR。移焦到 B&W 并按 Return 应用黑白，⌘Z 恢复 HDR。曲线的三种取样和独立添加点具有各自可访问名称。导出用方向键从成片切到原件，勾选从 2/2 清为 0/2 后可以恢复，返回资料库仍保留两张选片与原焦点。焦点在分组内时，组内按键优先于工作台的翻片与工作流快捷键。

[原生浏览方式](evidence/grouped-buttons/native-library-segments.png) · [原生色彩外观](evidence/grouped-buttons/native-appearance-segments.png) · [原生交付方式](evidence/grouped-buttons/native-export-segments.png)

`swift test --jobs 4 --filter 'DesignSystemTests|ApplicationLibrarySessionTests'` 通过 12 项。画廊浅深色渲染通过，120pt 宽的浏览分组保持 24pt 高。
