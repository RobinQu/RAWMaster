# Reframe 的边框、画内署名与批量展签

本机安装的是 Reframe 1.4.2（88），标识为 `com.boringseries.Reframe`。发行包的引导文案列出了四侧边框、画内九宫定位、可独立显隐的文字行、Logo、间距和整体偏移。三张官方演示图展示了这些控件如何组合成不同的照片。为 RAWMaster 命名的样式和建议比例均为本项目设计。[本机版本清单](/Applications/Reframe.app/Wrapper/Reframe.app/Info.plist) · [简体中文界面资源](/Applications/Reframe.app/Wrapper/Reframe.app/zh-Hans.lproj/Localizable.strings) · [开发者发布的 App Store 图文](https://apps.apple.com/cn/app/reframe-%E7%9B%B8%E6%9C%BA%E6%B0%B4%E5%8D%B0/id6483865815)

| RAWMaster 样式 | Reframe 中可核对的例子 | RAWMaster 的排版规则建议 |
| --- | --- | --- |
| 双栏参数卡 | 商店第 2 图的照片下方有整宽白条。左列粗机型、细镜头；右侧先图标，再放参数和日期两行。598 × 1300 的宣传图中照片宽约 366 px，底条高约 55 px，约为照片宽的 15%。第 5 图放大了相同题注组合。[第 2 图](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/60/79/8a/60798a25-d373-21af-f8f6-da4442387ae1/sc2.png/600x1300bb.webp) · [第 5 图](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/0b/0f/75/0b0f7506-1dac-1f2d-e86e-196b3849ba06/sc5.png/600x1300bb.webp) | 底边预留题注带。主列放机型或署名，次行放镜头。右列放实际存在的焦距、光圈、快门、ISO 和日期。横向空间不足时先省略次行或切换为上下两组，确保画面不跨列。 |
| 相纸展签 | 第 3 图以浅色窄边托住三侧，底边留宽，图标、主标题和参数上下居中。图中照片宽约 329 px，左右边约 9 px，下方展签约 61 px。界面给了四侧独立数值和比例选项。[第 3 图](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/28/a0/ab/28a0ab86-03ef-f53d-6dae-c42af6b11b2b/sc3.png/600x1300bb.webp) | 拍摄参数降为次行，署名或机型成为主行。外边、字号和字距按最终照片短边换算。缺少署名时回退机型，空字段连同分隔符一起消失。 |
| 模糊留白 | 本机 `blur_desc` 和 `app_update_note_1_4_2_blur` 列出同图模糊、细内框、投影、背景亮度与暗角。版本文案还描述了在 4∶5 画布完整放入横竖照片。第 4 图另展示了背景、主次文字和图标的联合配色。[本机中文资源](/Applications/Reframe.app/Wrapper/Reframe.app/zh-Hans.lproj/Localizable.strings) · [第 4 图](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/95/de/48/95de4823-b30f-8076-bdea-66cb7930fc05/sc4.png/600x1300bb.webp) | 为每张照片独立生成填满 4∶5 画布的背景，前景按现有裁切完整放入并保持清晰。将阴影和文字绘在背景之上。预览与交付使用同一画布坐标。 |
| 画内署名、日期戳 | `placement_overlay` 与九个 `alignment_*` 值对应画内落点。`group_card_desc4` 描述复古日期字体，`group_card_desc1` 描述文字与标志可组合与旋转。公开样式页显示字号、间距、不透明度和阴影调节。[本机中文资源](/Applications/Reframe.app/Wrapper/Reframe.app/zh-Hans.lproj/Localizable.strings) · [样式面板](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/0b/0f/75/0b0f7506-1dac-1f2d-e86e-196b3849ba06/sc5.png/600x1300bb.webp) | 画内署名可以采用右下文字叠印。日期戳用系统等宽数字呈现每张的拍摄日期，保留内侧安全边距。保持照片原画布。缺少日期时省略该行，禁止以导出日补写拍摄日。 |

宣传图的测量对象是截图中可见的照片和底条，测量误差约 2 px。图中的滑杆值没有标注单位。原生实现应根据成品短边、文本测量和长宽比求几何，尤其要覆盖超长镜头名、竖图和缺失 EXIF。导出界面应使用同一张当前照片绘制候选卡，便于看清图像面积、两栏顺序、署名位置和日期戳的区别。

### 复核入口

- REA 对安装包 `Info.plist` 的证据 ID 为 `ev_7e4fd8aacdd3b58d6860034271d825d8f4b9335e95e69ae52b9c99c6924f0012`。对二进制 `zh-Hans.lproj/Localizable.strings` 的证据为 `ev_1eab25ce2aef26c6da40b5fbede1d45df135a51a14e5ae89a2421bb7d924c765`，共解析 623 个键。本机应用资源只读。[测量与字段记录](../../output/research/export-panel/reframe/observations.json)
- 安装包内 27 张 `local_*.jpg` 是演示底片。两种底栏的几何测量使用中文商店的第 2、3 图。下载图片仅用于本机比对。原型和产品自行绘制模板并选用有授权的底图。[截图顺序、来源和文件摘要](../../output/research/export-panel/reframe/screenshots.json)
