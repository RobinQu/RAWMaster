# 滤镜目录、采用与悬停走查

从[摄影工作台](../../docs/ui/prototype/index.html#library/project/river)选中水鸟，进入「编辑 → 基础」。本次左栏共用常规字重和相同文字色，文件夹用底色与缩进，已采用行用独立底色和标记。

1. 展开「自适应滤镜 → 主体」「基础滤镜」「胶片模拟」，分别悬停「柔和」、基础滤镜与「Velvia 100」。检查主图改变，离开或按 Escape 恢复。自适应的示意选区只覆盖相应区域。
2. 点击基础与胶片行套用，撤销一次恢复上一种外观。自适应先检查本张选区，再确认采用或取消。搜索不到结果时清空输入；关闭文件夹或滤镜后再展开，检查原选片、搜索和草稿。
3. 从同张照片的「色彩外观」切到 HDR，重复三类悬停，主图标明临时 SDR 预览。尝试取消自适应选区，从 HDR 采用可用的基础或胶片滤镜，再回到 HDR，检查此前的 HDR 调整。
4. 检查目录、提示和导入导出界面的文字。在「滤镜与预设操作」导出名称含第三方品牌的示例预设，核对主图提示使用中性名称。在原生应用的同一菜单打开「撤销导入批次」，核对最近提交和旧版批次摘要使用同一显示规则。
5. 在离线、暂缺选区及重新接回原片时检查可用性。用 Tab、↑／↓、回车和 Escape 重复操作，查看桌面与窄窗，并分别模拟深／浅系统外观。

## 2026-11-28 · 浏览器

- 1440 × 900 在水鸟 HDR 草稿悬停「柔和」，主图显示其局部效果和「SDR 滤镜预览」。基础滤镜与 Velvia 100 也会改变主图。移开即恢复，确认前草稿与历史一致。一次撤销恢复 SDR 基线，重新切到 HDR 读回原草稿。[桌面截图](evidence/filter-panel/browser-hdr.webp)
- 390 × 844、系统浅色模拟下搜索 Velvia，用 Tab 经过收藏和文件夹到滤镜，验证焦点和预览。工作台沿用固定深色。模拟原片离线时滤镜行禁用，启用原片后同一搜索结果可用。[窄窗截图](evidence/filter-panel/browser-narrow.webp)
- `scripts/check-ui-prototype.py` 的 `--hdr-only`、`--editing-only` 和 `--editor-rails-only` 覆盖目录、搜索空结果、失焦、HDR 往返、采用、撤销和导入失败。主体蒙版在原型的对话框里确认，原生用滤镜列表下方的选区控件。原型以仓库 JPEG 和模拟调整复核交互。
- 在「导出原生预设」输入 `Adobe Spektrafilm 走查 XMP`，提交后工作台关闭对话框，主图提示 `已导出「走查 XMP」。`。浏览器逐项核对下载文件名和 JSON 内的 `name` 仍为输入值。`--editing-only` 复核提示与关闭操作。[导出提示截图](evidence/filter-panel/browser-neutral-export.webp)

## 2026-11-28 · 原生

- Release 原生界面专项复验 17 项全部通过，0 失败、0 跳过。覆盖滤镜采用历史、晚到帧隔离、收起时取消选区准备、九款胶片目录及 SDR／HDR 往返。测试进程指定本机 FlashRaw 动态库，雪景 ARW 与兼容 JPEG 放在同一目录。[逐项结果](evidence/filter-panel/native-release-tests.txt)
- `testImportedPresetPreviewsMappedFieldsWithoutCommitting` 从预设库读取实际提交的 XMP 批次，确认存储保留原名，并验证最近提交与旧版批次共用的显示转换。
- 原生侧栏窗口缓存核对 11 点同色同字重、逐级缩进、文件夹底色及唯一采用标记。浅色窗口收窄至 620 点。[深色侧栏](evidence/filter-panel/native-dark.webp) · [浅色窄窗侧栏](evidence/filter-panel/native-light-narrow.webp)
- `PresetMaskEntryPointTests.testSceneFilterPanelPreviewsAndAppliesOnRealRAW` 使用本机已校验的「柔和」预设和 `person.ARW`，在独立资料库挂载原生侧栏与画布。对三类滤镜移动指针并读取实际预览帧，检查 SDR 提示与 HDR 草稿；胶片采用和逐图蒙版确认通过当前照片的 SDR 会话。测试核对退出预览、撤销、草稿往返与选区来源。
- Release `20261128.163440` 签名安装前重新跑完同一 17 项原生专项，场景滤镜悬停、采用及 HDR/SDR 恢复均通过。[安装与测试回执](../043-image-engine-unification/evidence/m3-budgeted-window-release-checkpoint.json)
- 深度散景继续由本张深度与焦点准备后显式确认。缺少风景局部映射、配置表或其他依赖的自适应条目保留可查看的原因。[能力边界](directory-delivery.md)
