# 技术计划

1. 将已批准 C1 / C2 转为无外框、无外部留白的满版图案，保持前景设计，保存于 `assets/AppIcon.icon/Assets/`。
2. 用原生 `.icon` 文档定义两套图案的外观透明度：浅色只显示 Light，深色只显示 Dark。关闭额外玻璃和透光，避免重复施加生成稿已经包含的材质。
3. 使用 Xcode `actool` 生成 `Assets.car` 与旧系统 `AppIcon.icns`。同时设置 `CFBundleIconName` / `CFBundleIconFile`。
4. 构建后检查实际编译目录，而非只检查源 JSON。防止编译工具静默忽略外观字段，导致两种外观实际显示相同图片。
5. 使用系统渲染工具分别导出并目检 Default / Dark。完整记录验证范围与限制。

## Dock 尺寸修正 · 2026-10-23

Apple HIG 于 2026-06-08 更新，要求源图层满版、由系统裁切。`.icon` 与编译目录继续遵循此要求。

应用手动明暗外观会用 `applicationIconImage` 替换运行中图标。`ictool` 的 macOS 导出图虽有圆角，却没有系统图标画布外围的留白。不能将该导出图直接作为运行中 Dock 图标：主体铺满 1024，较原生主体 824 大约 24.3%。

`scripts/prepare-dock-icons.swift` 仅对两张运行中 PNG 做构建时布局：1024 画布中居中放置 824 主体，四边各 100 像素透明区。此值来自本机 macOS 27 原生备忘录、照片、计算器及自身编译图标的实测，不是 HIG 中声明的固定像素要求。跟随系统路径继续交给原生图标目录，源稿不加留白。构建检查同时校验两版运行中 PNG 的实际主体边界，防止再次出现满版导出或重复缩小。

参考：[Apple 图标制作](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)、[Icon Composer](https://developer.apple.com/icon-composer/)。文档结构还参考公开格式示例 [agency-agents-app](https://github.com/msitarzewski/agency-agents-app/blob/main/docs/icon/AppIcon.icon/icon.json)，未引入第三方运行时依赖或图案。
