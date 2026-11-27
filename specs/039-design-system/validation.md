# 039 · 验证记录（2026-11-26）

本批建立界面规范、令牌层、通用原语、原生控件画廊和可操作的 HTML 画廊。旧面板的批量迁移按 [spec.md](spec.md#现状与迁移清单) 分阶段进行，不在本批交付范围内。

2026-11-27 在 `main@b238c0ab` 复跑 5 个 Release `DesignSystemTests`，含浅深色离屏画廊截图。现有摄影工作台 60 个浏览器场景通过，含界面画廊。真实产品焦点、VoiceOver、降低透明度和 macOS 15 证据仍按[联动验收](spec.md#hdrgraph-与-032-的验收)补齐。[本次复验](../035-portable-processing-cores/roadmap.md#本次-main-复验)

## 已落地

| 内容 | 位置 |
| --- | --- |
| 令牌：尺寸、间距、字级、圆角、墨色、动效 | `Sources/RAWMaster/DesignLanguage.swift`（`AppDesign`） |
| 原语：图标按钮、分组头、说明、读数 | `Sources/RAWMaster/DesignControls.swift` |
| 原生画廊 | `Sources/RAWMaster/DesignGallery.swift` |
| 浏览器画廊 | [摄影工作台 #tools/design](../../docs/ui/prototype/index.html#tools/design)（`design.js` / `design.css`） |
| 回归 | `Tests/RAWMasterUITests/DesignSystemTests.swift`、`scripts/check-ui-prototype.py` 新增“界面规范画廊”场景 |

共享控件保持原有外观，改为从令牌取值：

- `PhotosControlLayout` 的 26 / 6 / 4 / 7 / 12 全部委托给 `AppDesign`；`photosAdjustmentTextColor` 委托给 `AppDesign.Ink.primary`。
- `PhotosFlatButtonStyle`、`PhotosFlatCheckboxStyle`、`PhotosFlatMenu`、`PhotosFlatTabs` 的字号、内边距、圆角、填充和禁用不透明度改为令牌。
- `PhotosScrubbingSlider` 的轨道、填充、指针、刻度颜色改为令牌。
- 菜单的常态/悬停/禁用填充由 8% / 13% / 4% 收敛为规范值 7% / 12% / 4%；其余视觉不变。

## 原生证据

```sh
swift build --target RAWMaster
RAWMASTER_DESIGN_GALLERY_OUTPUT=specs/039-design-system/evidence swift test --filter DesignSystemTests
```

`DesignSystemTests` 共 5 项通过（2026-11-26 13:45，0 失败）：

- 令牌数值与规范表一致。
- 旧入口 `PhotosControlLayout` 与 `AppDesign` 同值。
- 参数行高度等于 26 + 6，刻度带始终占位。
- 图标按钮 26×26 命中区。
- 画廊浅色/深色渲染成功，浅色平均亮度 > 0.5、深色 < 0.5。

渲染尺寸 760 × 1500，取自 `NSHostingView` + `cacheDisplay`： [浅色](evidence/gallery-light.png) · [深色](evidence/gallery-dark.png)。

## 浏览器走查

环境：macOS 27.2.1，内置浏览器，本机静态服务器；入口 `#tools/design`。

| 步骤 | 观察 |
| --- | --- |
| 进入画廊 | 工具导航出现「界面规范」；令牌、标本、版式、迁移清单和评审清单完整 |
| 拖动曝光 | 轨道中点填充随值移动，数值同步；悬停时下方 21 格刻度出现，行高不变 |
| 数字输入 `99` 回车 | 红框、`aria-invalid=true`，配方值未变 |
| Escape | 恢复 `0.35` 并清除红框（首次走查发现未恢复，已修复 `design.js` 的 Escape 分支并复验） |
| 勾选 | `aria-checked` 由 true 切到 false，方框、对勾与标签同步 |
| 分段 | 「波形」切为选中，下划线移动，其余取消；聚焦标签后方向键左右切换 |
| 分组头 | 折叠后正文隐藏，箭头状态同步 |
| 键盘 | 从数字框按 Tab 进入下一滑杆，`:focus-visible` 为真，1.5pt 强调色焦点环与刻度可见 |
| 深色 | 设置 → 通用 → 深色后返回，墨色、填充、边框与照片检查器一致 |
| 390 × 844 | 原则卡与控件改为单列；参数行标题与数值不重叠；工具导航横向滚动（既有工作台行为） |

证据：[浅色整页](evidence/design-gallery-browser-light.png) · [深色整页](evidence/design-gallery-browser-dark.png) · [键盘焦点](evidence/design-gallery-browser-focus.png) · [390pt 窄窗](evidence/design-gallery-browser-narrow.png)。

## 未验证与边界

- 未在 macOS 15 实机运行；本机为 macOS 27.2.1。Liquid Glass 下原生控件与自绘控件并排的观感未做逐屏对照，只按系统控件不重绘的原则实现。
- `DesignGallery` 只用于测试与诊断，没有接入应用菜单；原生画廊的浅色/深色证据来自离屏渲染，不是交互录制。
- 首轮在浏览器手工走查。2026-11-27 的全量脚本回归已包含画廊。
- VoiceOver 朗读顺序、减少动态效果与降低透明度未在画廊逐项验证；原语已读取 `accessibilityReduceMotion`，其余沿用既有控件。
- 旧初修面板、导出数字输入、蒙版/AI 蒙版、预设浏览器与图标按钮尺寸尚未迁移；规范已列出顺序与目标。

## 复现

```sh
python3 -m http.server 8770 --bind 127.0.0.1
# 打开 http://127.0.0.1:8770/docs/ui/prototype/index.html#tools/design
```

浏览器入口与覆盖表：[功能覆盖表](../../docs/ui/coverage.md) · [界面设计与研发流程](../../docs/ui/README.md) · [规范](spec.md)。
