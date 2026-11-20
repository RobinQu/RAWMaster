# RAWMaster 交互结构评估

## 判断

当前主要问题在导航层级：会话、序列、操作记录与项目被同时列为顶层项，且条目随资料增加。将对象列表移入主区域后，左侧只负责去哪里，卡片负责识别内容，照片工具负责处理当前文件。

Apple 的 macOS 规范强调合理密度、利用宽屏、可调整窗口及键盘/菜单支持；侧栏规范建议稳定的集合入口和浅层结构。这支持保留三个资料库目的地，而不增加一个中转首页。[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)

## 任务与视图

网格适合查找和批量组织；单张适合细节检查与编辑；比较适合逐候选判断。这三种模式属于同一组照片，切换时应保留查询和选择。对象目录属于更高一层，不显示照片模式切换。目录返回与照片模式切换是不同操作，应有明确标签。

照片工具按作用范围区分：项目导出在网格，单文件导出与编辑在单张，比较评分在候选内部。搜索限定当前集合，使用清晰占位提示和可清除条件。[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)

## Liquid Glass 的范围

采用系统材质增强浮动多选工具与内容的分层，保持图片、EXIF 和直方图为中性实体表面。复杂图片背景上使用 regular 更利于阅读；避免给每张照片、每个徽标都叠加玻璃。macOS 26 及以上使用原生 Glass，macOS 15–25 使用 regular material；降低透明度或增强对比度任一开启时选用不透明面板。[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

## 参考与验证状态

实际查看了 Tobias Reich 的 [Photo Management](https://dribbble.com/shots/18526739-Photo-Management)。作品呈现了大面积照片、紧凑路径、条件标签及靠近内容的少量菜单。本次借鉴的是照片占比与层级组织；并未验证该作品的真实交互，也不以作品展示代替可访问性测试。

也检索了 sanchay verma 的 [Photo Viewer & Organiser](https://www.behance.net/gallery/79288347/UIUX-Project-Photo-Viewer-Organiser)，但设计位于未能载入的视频模块中，因此没有将其作为已查看的视觉依据。Apple 规范仍是行为与平台一致性的主要依据。

## 本次取舍

| 区域 | 发现 | 采用的处理 |
| --- | --- | --- |
| 左侧栏 | 对象、日志、操作混排，条目随资料增长 | 三类稳定信息，具体对象转到主区 |
| 导入与序列目录 | 缺少便于扫读的集合概览 | 封面、名称、状态/类型、真实数量；搜索有独立范围 |
| 网格 | 会话和序列导航挤占照片空间 | 保留搜索、信息栏、序列边框与批量工具，清理全局导航 |
| 单张 | 进入照片后缺少明显的返回层级 | 显示照片上下文、返回网格与所属目录；保留照片编辑与底部列表 |
| 比较 | 上轮已完成逐图操作及信息比较 | 保留无右栏、固定 EXIF 表头、底部模式工具与照片列表；统一返回方式 |
| 材质 | 全面透明会干扰照片评估 | 仅浮动多选工具使用系统 Glass，提供实体回退 |

未在本次加入新主题、重排照片顺序或多窗口工作流；这些不影响本次导航问题的解决。

## 验证边界

原生窗口中的浮动面板已检查；离屏 `NSHostingView.cacheDisplay` 截图不会完整记录系统 Glass 合成效果，因此玻璃外观以原生截图为准。辅助功能回退通过材质策略的 8 种输入组合及共享生产组件截图验证；未修改系统辅助功能设置，不能将该组件截图称为系统高对比模式实测。旧系统回退已编译并验证策略，尚未在 macOS 15–25 的设备上运行。
