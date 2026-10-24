# 简化图标 · 2026-10-24

根据用户反馈减弱两种外观中的顶部强高光，保留两片叠层造型与青蓝紫配色。

- 使用内置 image_gen 编辑现有 Light / Dark 图片，完整提示词和原始生成文件位置见 `prompts.json`。
- 去掉图案中的亮边、倒角和玻璃反光，将背景改为接近纯色，保留平缓的颜色过渡和中央交叠区域。
- `Light.png`、`Dark.png` 是生成原图；标准化为 1024×1024 后接入 `assets/AppIcon.icon/Assets/LightMinimal.png`、`DarkMinimal.png`，原有 Light / Dark 保留，可回退。
- `.icon` 保持关闭额外玻璃、组高光和阴影；系统仍可能在最终外框施加细微边缘反光。图案中不再额外烘焙顶部强光。
- 原生 Assets.car / ICNS 与运行中 Dock PNG 均从这套源稿构建，继续保留 100 px Dock 外围留白。

参考：[Apple HIG · App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)，Visual effects 建议交由系统处理高光、阴影、光晕等效果。
