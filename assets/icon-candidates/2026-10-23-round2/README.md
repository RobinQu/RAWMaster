# RAWMaster 图标第二轮 · 2026-10-23

用户选择首轮 C（原色叠层）与 D（取景山景），要求按当前 Mac 图标设计方向继续演绎，包含 hyper minimal。

后续确认：C2 用作浅色图标，C1 用作深色图标。正式满版资源与外观配置已接入 [AppIcon.icon](../../AppIcon.icon/)，概念稿原样保留。参见 [实现与验证](../../../specs/003-app-icon/validation.md)。

## 设计依据

- [Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)：明确可识别的主体与层次；图标是应用身份的一部分。
- [Apple Icon Composer](https://developer.apple.com/icon-composer/)（2026-10-23 查阅）：当前支持分层 Liquid Glass，包含高光、折射、半透明，以及 Default / Dark / Mono 外观。页面介绍当前更清晰的边缘高光与从上方照射的光线。
- 本轮将“hyper minimal”作为创意选择：减少几何元素、扩大留白、减轻材质。没有将其表述为 Apple 官方指定风格或全市场统计结论。

## 候选

| 编号 | 文件 | 演绎 |
| --- | --- | --- |
| C1 | [C1-chromatic-minimal.png](C1-chromatic-minimal.png) | 深色极简；两片原色层，突出中央重叠。 |
| C2 | [C2-chromatic-glass.png](C2-chromatic-glass.png) | 浅色轻玻璃；清晰的青蓝紫薄层。 |
| D1 | [D1-viewfinder-minimal.png](D1-viewfinder-minimal.png) | 深色极简；取景框、山脊线和琥珀色太阳。 |
| D2 | [D2-viewfinder-glass.png](D2-viewfinder-glass.png) | 浅色轻玻璃；取景框与简化的蓝色山形。 |

这些是供选择的静态 PNG 概念稿。浅色版外部使用中性浅灰背景，确保预览边缘整洁；它们不是已拆分的 Icon Composer 分层工程。深色版保留透明外部。最终选择后再制作正式资源、校准小尺寸和外观变体。

## 生成与保存

使用内置 image_gen，未使用 CLI。以第一轮 C / D 为图形概念参考，各候选独立生成；浅色版增加一次仅清理外部背景的处理。完整提示词见 [prompts.json](prompts.json)。

首轮文件保留。本轮未接入应用、未修改应用代码。
