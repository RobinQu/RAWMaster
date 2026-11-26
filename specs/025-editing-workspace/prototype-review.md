# 编辑暗房 · HTML 交互走查

从资料库选择一张照片，打开顶栏「编辑」。暗房保留同一张照片、同一份草稿和同一个历史栈。右栏首次打开「智能编辑」中的「智能预设」。「作品版本」从文件名旁的命令进入，查看候选后可返回先前的调整面板。[打开暗房](../../docs/ui/prototype/index.html#edit/development)

## 自由缩放与原图取样

从[暗房画布](../../docs/ui/prototype/index.html#edit/development)点 `+` 或在图像上 Ctrl + 滚轮放大，停止后仍留在该倍率。`1:1` 单独进入 100%，`FIT` 或 `0` 返回适合窗口。设置 → 编辑切换「极速」再回来：缩放中状态显示「临时预览」，停止后显示「按倍率取样」，不改变倍率或所在照片。换片后回到 FIT。浏览器内已验证 `+` 到 15%、显式 1:1 和 FIT 的区分；对极速派发滚轮后，31% 的临时与最终状态使用同一倍率。在 560 × 800 窄窗的均衡模式下，29% 的倍率和滚动位置在手势结束前后相同；浅色与深色均可用 Enter 在工具条放大，再用 `0` 返回 FIT。原型使用样片模拟状态，不用于判断 RAW 清晰度，参见[原生验证](../036-render-pipeline-performance/validation.md#自由缩放与原图取样)。

| 区域 | 走查步骤 | 可观察结果 |
| --- | --- | --- |
| 左侧照片工具 | 从「预设」向下浏览至「快照」「历史」。在滤镜预览里悬停或用键盘聚焦一种胶片，再移开，随后点击采用、调整强度、撤销 | 三块垂直排列。胶片模拟作为特殊的 Adaptive Filter 使用本张照片预览。临时试看可退出，采用和调整强度各写入本张的一步历史，存储快照后可恢复 |
| 右侧调整工具 | 沿右栏左缘的图标列进入智能编辑、基础、曲线、混色、细节、光学、效果、分级、蒙版或修复 | 当前图标有选中态和可读名称，相邻的详情区只显示选中工具。在智能预设里按场景选意图、核对范围、采用或取消 |
| 智能编辑 | 在智能预设中点「交互式创作」，输入要求，查看对话提出的处理方案。通过「返回智能预设」退出，再次进入 | Agent 对话占用同一详情区。会话与草稿属于本张。需要模拟生成时可复核要求、执行位置和严格纪实限制，完成的作业作为独立候选进入作品版本。[智能预设](../../docs/ui/prototype/index.html#edit/smart) · [Agent 对话](../../docs/ui/prototype/index.html#edit/agent) |
| 底部浮动工具条 | 依次试前后翻片、缩小、放大、FIT、裁切、对比和背景。悬停或聚焦翻片按钮，走到范围边缘，再切回原片 | 底部只保留一条浮动命令栏。邻片预览随翻片键出现和消失，首尾禁用相应方向。翻片沿来源范围和排序，返回后可接着编辑原有草稿。FIT 为侧栏和工具条留出空间 |
| 快速 Prompt | 点底部「Prompt」，在原位置展开，填入编辑要求，圈选或保持整张，核对模型与候选 | 退出恢复暗房原工具条、比较和输入焦点。原型可演练本机、云端与未知结果。[快速 Prompt 走查](../034-quick-prompt-editing/prototype-review.md) |
| 裁切与对比 | 按 C 打开画布右上角的裁切面板，修改比例后退出。按 V 开关对比，在工具条选择模式与参考版本，再按 B 更换暗房背景 | 三分线跟随裁切，比较与背景只影响观看。已保存的快照、版本和导出仍能引用当前配方 |

本轮新增的胶片与 Agent 使用仓库 JPEG、示例参数和本地模拟回复。原生胶片成像及对话执行的研发状态分别见[滤镜与预设](../031-preset-browser/spec.md)和[智能编辑交互规格](../030-ai-retouching/ux-design.md)。浮动工具条与右栏几何参照[原生画布](../../Sources/RAWMaster/EditingImageCanvas.swift)和[工作区](../../Sources/RAWMaster/EditingWorkspace.swift)。

## 浏览器复验 · 2026-11-22

- 在 1440 × 900 深色窗口从「河谷拍摄」进入 DJI_0348.DNG。左右面板各 304 px，右栏的图标列在详情左侧。打开交互式创作、发送风光要求、返回智能预设再进入，对话与文件名一致。[默认暗房](../../docs/ui/evidence/editor.webp) · [本张 Agent 对话](../../docs/ui/evidence/editor-agent.webp)
- 在「暮色延时」只沿三张成员翻片，首尾按钮按方向禁用。采用银盐黑白、调至 45%、存储快照后换片再返回，胶片与强度仍在本张。用一个参考张做组照配平时，该张从目标清单中移除。打开裁切、调比例、Escape 退出，继续用同一张的当前几何做擦除与并排比较。[整机交互检查](../../scripts/check-ui-prototype.py)
- 1100 × 720 桌面保留三栏和居中的 292 px 浮动条。390 × 844 浅色窗口按画布、右栏工具、左栏照片工具的顺序纵向浏览；缩到 320 px 宽，工具条所有按钮仍在视口内。输入对话草稿时，字母键保留给输入框。[窄窗暗房](../../docs/ui/evidence/editor-compact.webp)

## 主窗口标题栏

在资料库左上角收起侧栏，再打开。核对当前项目与选片保持，顶部「资料库」「编辑」「导出」仍可切换。浏览器走查可用 Space 操作侧栏，在窄窗口以抽屉形式打开。主窗口左上角显示系统窗口按钮和侧栏开关，留出的空白区可拖动窗口。拖动边缘可以改变大小，双击标题栏空白处继续调用原生窗口缩放。

[打开资料库](../../docs/ui/prototype/index.html#library/project/river) · [浏览器回归脚本](../../scripts/check-ui-prototype.py)

2026-11-22 在 Release 31.4 的隔离资料库中用实际鼠标事件验证。旧版 31.3 标题栏空白处的拖动没有改变窗口位置。31.4 在资料库、编辑与导出分别通过空白处拖动、右边缘缩放、底边缩放和恢复原尺寸。标题栏空白处双击可缩放并恢复。侧栏收起和恢复后仍可打开同一张照片。原生回归还核对了工作流与窗口按钮的点击范围。[窗口测量](../../output/release-window-integration/native-window-verification.json) · [输入路由回归](../../Tests/RAWMasterUITests/TitlebarInputTests.swift) · [安装收据](../../output/release-window-integration/install-receipt.json)

## 编辑翻片与资料库胶片带

1. 在[河谷拍摄](../../docs/ui/prototype/index.html#library/project/river)选择 DJI_0348.DNG，切换单张查看。折叠、展开拍摄组，焦点不变。进入编辑，画布下方不再有水平照片列表；返回资料库后胶片带和选片保持。
2. 在[暮色延时](../../docs/ui/prototype/index.html#library/group/dusk)选择组内首张后进入编辑。点「下一张」或按 `→` 到组内末张，末张的「下一张」不可用。按 `←` 或点「上一张」回到首张，原草稿仍在，「上一张」不可用。
3. 从河谷拍摄的 DJI_0348.DNG 在编辑里点「下一张」，离线样片仍提示找回原片；取消后留在当前照片。

本次通过内置浏览器实际点击并投递方向键，验证了 1440 × 900 深色和 390 × 844 浅色窗口中的翻片，以及桌面窗口的首尾边界、离线取消和返回资料库后的胶片带与选片。[浏览器回归](../../scripts/check-ui-prototype.py) 37 组全部通过。

## 资料库胶片带上下留白

在[河谷拍摄](../../docs/ui/prototype/index.html#library/project/river)切换「单张 · E」。同时查看散片和带边框的拍摄组：卡片上沿和缩略图上沿在各自的同一水平线上，组名居中，分组边框在卡片上方和下方留等量空间。收起、展开组，胶片条高度和原选片不变。切回网格或进入编辑不改变选片。

用 1100 × 720 浅色窗口点击折叠／展开，再在 850 × 660 深色窗口滚动到胶片带核对边框。浏览器回归 37 组通过，含边距、缩略图位置和折叠高度的几何检查。[窄窗深色截图](evidence/library-filmstrip-spacing-browser.webp) · [浏览器回归](../../scripts/check-ui-prototype.py) · [原生验证](../011-browser-sequences/validation.md#资料库胶片带上下留白)

## 资料库胶片带边框与组头

在[河谷拍摄](../../docs/ui/prototype/index.html#library/project/river)选中组外的 DJI_0348.DNG，再切换「单张 · E」。选中框与分组外框等高且上下沿对齐，组内外缩略图上沿对齐。组头固定两行：第一行点箭头或组名均能折叠，第二行是张数和独立设置。折叠不改变外框高度或选片。

从胶片带打开「岸边连拍」的组属性，在示例库临时改名为「河谷日落延时拍摄 · Camera B 第 02 段」，保存后核对单行尾部省略，悬停标题或重新打开设置可看全名。用 Space 展开或收起，Tab 到设置并用 Enter 打开，按 Escape 取消，仍回到原选片。以窄窗和浅／深色复查。浏览器完整回归 37 组通过，包含鼠标折叠、长名省略与全名保留的检查。[窄窗长组名截图](evidence/library-filmstrip-two-row-browser.webp) · [原生证据](../011-browser-sequences/validation.md#资料库胶片带边框与组头)

## 胶片带与调整面板

以下为历史走查；当前胶片带只保留在资料库。

2026-11-23 在 Chrome 走查。1440 × 900 使用深色查看资料库与编辑布局，390 × 844 使用浅色复查 Prompt、焦点和操作边界。工作台 22 组场景均通过。[暗房面板](evidence/panels-browser.webp) · [桌面 Prompt](evidence/prompt-browser.webp) · [窄窗 Prompt](evidence/prompt-compact-browser.webp) · [回归脚本](../../scripts/check-ui-prototype.py)

| 入口 | 动作与采用结果 |
| --- | --- |
| [河谷拍摄](../../docs/ui/prototype/index.html#library/project/river) → 单张 → 编辑 | 比较组内外缩略图中心。点首张左侧组名折叠、再展开，选片保持。编辑胶片带点离线的 DSC_0713.JPG，可从找回提示取消并回原照。 |
| [暗房左栏](../../docs/ui/prototype/index.html#edit/development) → 滤镜、快照 | 核对 Adaptive、胶片模拟及 Imported 的顺序和分隔线，Adaptive 下展开 Sky 和 Subject。从标题区模拟导入 XMP，悬停观察效果，离开恢复。搜索无匹配的名称再清空。调整胶片强度，创建快照，撤销强度修改后用 Tab 聚焦快照。失焦结束试看，快照行仍在，点击后才恢复配方。 |
| [暗房基础](../../docs/ui/prototype/index.html#edit/basic) → 光效／分级 | 首次打开白平衡，手动展开光效，核对上方数值框与全宽滑块。切至分级后输入 35、停用、再启用，效果与数值恢复。撤销后返回基础，光效仍展开。 |
| [暗房画布](../../docs/ui/prototype/index.html#edit/development) → Prompt | 初始焦点在大输入区。用短句补充已有文字。点圈选，Escape 退出拖框，再从更多圈选操作通过键盘输入坐标。无效范围提示修正。点击全图恢复默认。以窄窗确认模型、生成、关闭可触达。 |

Chrome 的样片预览用 CSS 模拟色调。快速 Prompt 的生成和出站确认使用示例任务；对应原生效果、窗口焦点与交互见[原生验证](validation.md)。

## 2026-11-25 · 合并后的复验

`codex/editing-ui-polish` 与 `codex/portable-processing-acceptance` 合并到 `main` 后，用同一合并树的 Release 重跑浏览器走查与原生定向用例，确认两边的改动互不覆盖。

- 合并提交 `1b8ac88b`，基线 `1b7df6b6`。Release 应用 `f2bbe0c3…`、UI 测试 `cbd440cb…`、成像测试 `c5c25779…`、Prompt 测试 `90910d82…`。
- 浏览器：工作台 37 组场景全部通过，含资料库胶片带折叠与离线找回、暗房右栏展开与启停、快照试看与失焦、快速 Prompt 的窄窗、键盘和浅色。原始日志 `output/acceptance/editing-ui-merge-20261125/prototype-full*.log`。
- 并行构建时的首轮在「导入、续接、分组、初筛封存与历史恢复」的导入历史路由超时；同一脚本在无构建争用后连续两轮 37 组通过。首轮保留，不把构建争用计为界面回归。
- 原生定向：`EditingLayoutInteractionTests` 2、`EditingSnapshotTests` 1、`EditingWorkflowTests` 15、`PresetMaskEntryPointTests` 5、`SequenceBrowserLayoutTests` 11、`DevelopmentColorEngineV2Tests` 7、`QuickPromptProviderTests` 5、`EditingMaskCanvasOwnershipTests` 2（1 项按模型包条件跳过）。共 48 项执行、0 失败。逐套日志在同一目录。

两分支重叠的 `EditingController.swift`、`coverage.md`、`photos.js` 与回归脚本按双方改动共同保留：目录任务租约和 Prompt 归档路径来自可移植处理批次，右栏展开、快照试看和胶片带来自界面批次。文档索引 `build_report.py --check`、`build_performance_report.py --check --require-complete` 与 `verify-acceptance.py` 在合并树上通过。
