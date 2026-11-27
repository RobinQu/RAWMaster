# 编辑侧栏、画布通知与 Graph 浮窗

从资料库点选一张照片，进入「编辑」→「基础」。左上显示该照片的 RAW 摘要，左下依次显示滤镜、快照、历史。右上选择节点、忽略或打开 Graph，右下调整当前节点。同一侧的两块面板等宽，以 8 px 空隙分开。目录和参数分别滚动。切到其他窗口后再回来，四块面板恢复玻璃材质，选片、输入、滚动和草稿照常保留。窄窗先显示照片，再显示可滚动到的工具。[暗房原型](../../docs/ui/prototype/index.html#edit/basic)

在「滤镜」下先调强度，再输入搜索词。搜索框紧靠同一棵文字目录，四个根目录依次是「自适应滤镜」「基础滤镜」「胶片模拟」「用户导入滤镜」，根目录间留白。自适应目录显示 Lightroom 简中分组和条目名。个人导入保留作者所写的名称。清空搜索恢复先前展开状态。用 Tab、方向键、Enter 或 Escape 走查滤镜与快速 Prompt，键盘焦点用中性底色、下划线或已有刻度表示，输入框保留插入点。[滤镜目录](../031-preset-browser/spec.md)

进入「基础」→「HDR」，确认从原片建立草稿。会话内的处理消息和错误按照片保留在主图上方，每条有独立关闭按钮。普通消息使用信息图标，错误使用警告图标并优先向辅助技术播报。两类提示可以同时存在。切换照片时只显示新照片的提示，返回后可接着处理原提示。关闭单条提示保留同张照片的其他消息、草稿和选区。[HDR 原型](../../docs/ui/prototype/index.html?sceneNativeReview=1#edit/basic)

在右上点击 Graph 打开独立画布。编辑图和只读兼容图均没有标题栏。角落提供关闭、移动和缩放窗口的操作，移动和调整大小支持方向键。在可编辑图内可选择节点、缩放和平移内容。较矮窗口仍可操作画布。Esc 或右栏 Graph 开关关闭浮窗，焦点回到开关。进入裁切或蒙版时暂时让出主图，完成或取消工具后恢复原有图窗。[编辑图](../../docs/ui/prototype/index.html?graphNativeReview=1&sceneNativeReview=1#edit/basic) · [只读兼容图](../../docs/ui/prototype/index.html?compatibilityGraph=1#edit/basic)

## 2026-11-27 走查

### 浏览器原型

| 入口和动作 | 观察 |
| --- | --- |
| 资料库选择河湾和水鸟两张照片，重新加载工作台 | 两张都保持选中，当前照片仍为最后点选的水鸟。搜索「暖光」能找到主体滤镜。滤镜菜单导入示例模拟读取失败时，提交表单关闭，错误出现在水鸟主图上。关闭错误后可继续使用快速 Prompt |
| 水鸟 → 基础 → HDR → 创建草稿 → 色彩与输出 → 模拟 HDR 预览失败 | 普通消息和错误各出现一条，等待超过旧提示的 2.9 秒期限、切换工具和照片，两条记录仍属于水鸟。关闭普通消息后能在错误上重试。[画布通知](evidence/editor-rails/rails-and-notices.webp) |
| 水鸟 HDR 草稿 → Graph，移动、调整大小、适合全图，缩短窗口再按 Esc | 主图与图窗并存。缩到 900 × 360 仍有可用的图内容，Esc 回到右上 Graph 开关，配方与节点保持原值。[可编辑画布](evidence/editor-rails/graph-canvas.webp) |
| 河湾旧配方 → Graph，在 390 × 844 深色窗口用键盘缩放、复位并关闭 | 三个只读阶段可读。关闭后仍在河湾照片上，未建立图配方。[只读兼容图](evidence/editor-rails/compatibility-390-dark.webp) |

原型以仓库的 6000 × 4000 水鸟照片模拟进入 HDR 与重试。使用 `python3 scripts/check-ui-prototype.py --editor-rails-only` 可复跑上表。完整工作台的 60 个既有走查也已通过。

### 原生 AppKit 与 Release 窗口

| 输入与动作 | 原生可见结果 |
| --- | --- |
| 在 AppKit 测试窗口浏览胶片，搜索、采用，再撤销 | 使用临时资料库的 PNG。原有曝光保留，取消搜索后九个胶片条目仍以原 ID 出现。[原生滤镜侧栏](evidence/editor-rails/appkit-filters.webp) |
| 在同一个 AppKit 测试窗口给同一照片发送一条普通消息和一条错误 | 两类通知在主图上方同时可见，可分别关闭。此例直接调用编辑控制器；下方两个 Release 场景由用户操作触发。[两类通知同屏](evidence/editor-rails/appkit-notices.webp) |
| 在原生侧栏打开无法读取的预设目录，再选择另一张照片 | 读取失败进入发起照片的错误通知。返回原照片仍可看到该错误，单独关闭后，原有普通消息继续保留。用例 `testUnreadablePresetCatalogReportsToItsPhotoAndPreservesExistingNotices` 同时检查没有弹出模态错误窗口 |
| 打开 `compatibility.jpg` 输入「Fuji」，以及打开雪景 `snow.ARW` 的 HDR 草稿。分别切到其他窗口再回来 | 两张照片都恢复四块玻璃面板，兼容照片仍保留「Fuji」。在 1480 × 940 pt 的主窗口中，辅助功能树读得左右各两块均为 304 pt 宽，各侧上下间距均为 8 pt。[兼容照片回焦](evidence/editor-rails/release-ui-legacy-reactivated.webp) · [HDR 雪景回焦](evidence/editor-rails/release-ui-hdr-reactivated.webp) |
| 分别从两张照片打开 Graph，再使用角落的关闭按钮 | 主窗口和独立无标题图窗同时可见。关闭后焦点回到原照片的 Graph 开关。[兼容图与照片](evidence/editor-rails/release-ui-legacy-graph.webp) · [HDR 图与照片](evidence/editor-rails/release-ui-hdr-graph.webp) |
| 在 JPEG 上选择 HDR，或从雪景 HDR 切回彩色编辑 | 第一种操作提示「此原片未通过 HDR 场景校准准入」，第二种操作提示「已切换到彩色编辑模式」。分别关闭对应通知后，保留当前照片及上下文。[准入错误](evidence/editor-rails/release-ui-legacy-notice.webp) · [切换模式消息](evidence/editor-rails/release-ui-hdr-notice.webp) |

上述 Release 窗口走查在 18:10 构建的优化可执行文件上执行，测试副本以隔离标识 `io.robinqu.RAWMaster.qa.editorchrome` 重新签名。关闭首次启动提示后，逐张核对六份截图和对应的 AppKit 辅助功能树。两张照片的四块面板与底部工具条在失焦时各有明暗变化，回焦后五处取样均恢复到编辑时的原值。截图按原始显示配置转换为带 sRGB 配置的 WebP，用于阅读界面与窗口状态。AppKit 专项向原生图窗派发按键，另行验证键盘关闭与还焦。

目录显示名以 Lightroom Classic 的 `zh_cn.lproj/TranslatedStrings.txt` 和 Camera Raw 的 XMP 名称为依据。对照迁移清单核验了 51 个预设与 2 个自适应配置文件的中文名与原 ID。在原生侧栏搜索和采用胶片、撤销、查看语义蒙版，以及包含 1,075 条记录的检索与收藏均通过。用户导入和原始 XMP 名称保留原文。[迁移清单](../031-preset-browser/contracts/migration-manifest-v1.json) · [Adobe 简中预设帮助](https://helpx.adobe.com/cn/lightroom/web/edit-photos/use-presets/apply-presets.html)

### 最终签名 Release 与实拍原片

最终签名应用的构建、安装、重新启动，以及同一签名包的选片恢复、60 MP 原片和 Spec 032 冻结交付回执，按可执行文件身份记录。[最终安装与实拍验收](evidence/editor-rails/release-acceptance.json)

普通 HDR 取景和全分辨率神经模型使用不同的内存路径。Sony ILCE-7RM5 的 DSC05995.ARW 为 9504 × 6336，FIT 和 1∶1 ROI 已通过实测，查看这张原片无需先展开全幅 AP1 浮点画面。若当前版本包含要求整图输入的神经模型且所需表面超过预算，主图顶部的错误应指出模型需要全分辨率处理，并保留原照片与当前草稿。用户可回原图调整该模型，再重新尝试预览或从更新后的版本交付。模型运行结果单独验收。[60 MP 预算与取景记录](../037-color-film-hdr/evidence/real-60mp-bayer-budget.json)
