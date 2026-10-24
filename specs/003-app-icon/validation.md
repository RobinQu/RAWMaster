# 验收记录 · 2026-10-23

环境：M4 Max / macOS 27.0.1，本机 Xcode 工具链。

- 发布构建成功，签名严格校验通过，Info.plist 校验通过。
- 从应用自身 `Assets.car` 检查：Aqua 仅显示 Light（C2），DarkAqua 仅显示 Dark（C1），两者图案摘要不同，均为 1024 像素图像。
- 保留 ICNS 与 16、32、64、128、256、512、1024 后备图标。
- 系统图标渲染工具 Default / Dark 分别导出目检通过；Icon Composer 内实际切换 Default → Dark 目检通过，图案与背景均对应正确，没有概念稿外框及外部杂点。
- 构建脚本每次自动执行 `scripts/check-app-icon.py`，外观缺失、两版误用同图或后备尺寸缺失会令构建失败。
- 重启更新后的应用，窗口正常恢复，153 张已登记素材、2 张保留以及当前照片和星级状态正常恢复。
- 仅修改图标资源与打包流程；应用业务源代码未修改，因此未重复运行图片解码性能基准。

本地可复查产物（忽略目录）：`output/icon-validation/light.png`、`dark.png`、`compiled.json`，应用：`output/RAWMaster.app`。

限制：没有修改用户的系统外观偏好来验证桌面全局切换。应用由系统按图标外观偏好选择；自动模式跟随明暗，固定或染色样式由系统控制。macOS 15 与其他机器未做本轮桌面验收；旧系统后备图标是静态浅色版。

正式图案由内置 image_gen 从已批准的 C1 / C2 准备满版资源；原概念稿保留，完整提示词见 `assets/app-icon-prompts.json`。

## Dock 主体尺寸修正 · 2026-10-23

- 阅读 Apple HIG App icons（2026-06-08 修订）及 Icon Composer 最新文档；源层仍保持满版，由系统生成圆角。
- 通过 NSWorkspace 获取本机备忘录、照片、计算器和 RAWMaster 原生图标，在 1024 画布上测量 alpha ≥ 0.5 的主体边界：均为 `[100, 100, 924, 924]`。旧运行中 PNG 为 `[0, 0, 1024, 1024]`，故手动明暗模式约大 24.3%。
- 修正后的 Light / Dark PNG 主体均为 `[100, 100, 924, 924]`，边缘透明；1024 输出分辨率保留。原生 Assets.car 和 ICNS 不加第二次留白。
- 发布构建、原生目录外观检查、ICNS 后备尺寸检查、签名严格校验、Info.plist 校验全部通过。旧满版 PNG 的反向验证按预期失败；尺寸检查现已接入每次构建。
- 6 项 AppearanceTests 通过，覆盖外观持久化、Dock 切换、系统跟随及业务状态保留。未修改应用业务代码。
- 应用正常退出并重新打开，仍为当前深色偏好，恢复 1,256 张素材及当前 `100MSDCF` 项目中的 `DSC01286.ARW`、未决定、0 星状态。
- 128 / 64 像素并排渲染目检：修正后的浅深图标主体与系统图标一致。证据在 `output/icon-validation/dock-sizing/comparison.png`，构建与测试日志在同目录。Dock 截图接口超时，未将此项记为桌面截图验收；未更改系统外观偏好。

参考：[App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)、[Icon Composer 制作说明](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

## 高光简化 · 2026-10-24

- 使用内置 image_gen 从原 Light / Dark 源图编辑，去掉素材中的强顶部高光、玻璃亮边、倒角和光晕，保留相同识别图形。生成稿及完整提示词保存在 `assets/icon-candidates/2026-10-24-minimal/`，旧源图未覆盖。
- `.icon` 接入 `LightMinimal.png` / `DarkMinimal.png`，两者标准化为 1024×1024。组高光、玻璃效果仍关闭；最终外框上的细微边缘反光来自系统渲染。
- 发布构建、实际 Aqua / DarkAqua 原生外观映射、不同内容摘要、ICNS 后备尺寸、两版 Dock 主体 `[100, 100, 924, 924]`、签名严格检查与 Info.plist 检查通过。
- 系统裁切后的新旧图在 224 与 64 像素画布并排目检，高光与材质明显简化，Dock 比例保持一致。对比证据在 `output/icon-validation/minimal-2026-10-24/comparison.png`，构建日志在同目录。此图为资源渲染对比，不是实际 Dock 截图。
- 本轮仅更换图案资源及校验器预期名称，未修改应用业务代码，未重复运行业务测试。
