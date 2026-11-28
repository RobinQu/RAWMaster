# 顶栏、启动与深色界面

在[摄影工作台](../../docs/ui/prototype/index.html#library/project/river)用顶栏的「资料库」「编辑」「导出」切换同一批照片。这个主导航恢复原来的胶囊样式。胶囊内按钮高 28pt、左右各留 15pt，选中项有独立的圆角底色。方向键在可用项之间移焦，按空格或 Return 进入。资料库浏览模式、检查器和导出各自使用带内部分隔线的分组按钮。

从 Dock、Finder 或已有库包启动，进入工作台。已知资料库按常规恢复选片，首次打开时进入[资料库开始页](../../docs/ui/prototype/index.html#welcome)。应用菜单的「设置…」、⌘, 和功能页的设置入口可以打开指定设置页。关闭设置后回到当前工作台。资料库切换也沿用当前工作流程。

应用的窗口、菜单、弹窗和设置固定采用深色。升级时忽略已保存的界面外观偏好。[通用设置原型](../../docs/ui/prototype/index.html#settings/general) · [系统图标](../003-app-icon/spec.md)

## 走查

1. 在项目中多选两张照片，依次进入编辑、导出、资料库。用鼠标与键盘核对胶囊、当前项、焦点、选片接续。缩窄后核对库名、三项导航及工具入口。
2. 模拟系统浅色与深色，复验资料库、编辑、导出、Graph、弹窗与设置的深色外观。从同一工作台主动打开设置，关闭后继续选片。
3. 在本机使用无可打开资料库和有库包两种启动方式。核对默认打开的窗口，随后用 ⌘, 打开设置。让设置处于打开状态后退出，重启复验。通过明确的本机 AI 设置入口核对目标设置页。

## 浏览器验证

2026-11-28 使用摄影工作台和嵌入的 032 导出原型。多选两张，方向键在胶囊内移焦并按 Return 进入编辑。导出显示 2 / 2，返回资料库后保留双选和当前照片。主动打开通用设置，返回后继续选片。系统外观模拟为浅色和深色，顶栏、设置及独立和嵌入的导出均使用深色。窄至 390px 后标题、胶囊与工具入口仍可操作。[桌面顶栏](evidence/workbench-chrome/browser-toolbar.png) · [390px 顶栏](evidence/workbench-chrome/browser-toolbar-390.png) · [通用设置](evidence/workbench-chrome/browser-settings.png)

运行 `python3 scripts/check-ui-prototype.py`。默认 60 个场景通过，`--local-library-only` 的 15 个场景通过，`--appearance-parity-only` 和 `--grid-export-only` 的补充走查通过。

## 原生验证

在 macOS 27.0.1 的系统浅色外观中启动签名测试包，提供旧版浅色偏好。工作台、设置、兼容 Graph 和资料库选择面板使用深色。原生窗口缩至 1100pt 后三项导航可见。[原生胶囊](evidence/workbench-chrome/native-toolbar.png) · [通用设置](evidence/workbench-chrome/native-settings.png) · [兼容 Graph](evidence/workbench-chrome/native-compatibility-graph.png)

最终 Release 使用 `Portrait.ARW` 与 `MountainLake.jpg` 双选。右方向键移焦到编辑，按 Return 打开当前 RAW。点击导出看到 2 / 2，聚焦资料库后按空格返回，仍可对两张执行操作。[键盘焦点](evidence/workbench-chrome/native-toolbar-focus.png) · [导航记录](evidence/workbench-chrome/native-navigation.txt)

保留旧版设置窗口状态后升级，冷启动只打开工作台。主动打开设置后退出，再次启动只打开工作台。启动路径指向不可用资料库时显示开始页，随后通过 Finder 打开测试库包。⌘, 打开通用设置，快速 Prompt 的模型配置打开本机 AI 设置，关闭后回到当前照片。[启动与设置窗口记录](evidence/workbench-chrome/native-startup.txt)

Swift 回归覆盖外观、资料库会话、设置路由、工作台模型、界面规范和 Graph。44 个用例中 41 个通过，3 个需显式启用的截图或固定样片用例跳过。
