# 三种色彩外观与工作流图窗

在[摄影工作台](../../docs/ui/prototype/index.html)打开「河谷拍摄」，从网格选择可校准的 RAW，按「编辑照片」。右栏「基础 → 色彩外观」选择 SDR、HDR、B&W。当前照片或虚拟副本是编辑对象。返回资料库保留该呈现的选片，工作流图窗关闭后焦点回原 Graph 按钮。

| 参考 | 正常入口与完成方式 |
| --- | --- |
| 图 1、2 · 调色 | 三种外观均使用可操作的白平衡、光照、颜色、曲线、细节与效果。HDR 另外提供白点以上的 1 EV 刻度、高光限制及 SDR 派生。直方图白点内的五个区段分别调节黑色、阴影、曝光、高光和白色。白点以上四档（0–1、1–2、2–3、3+ EV）分别可调 ±0.5 EV，方向键可微调，释放提交一次历史。高光限制单独控制整幅天花板。摄影调整属于本呈现，Graph 节点独立管理其曝光、曲线、混合和覆盖。 |
| 图 1 · 查看亮度 | HDR 的光照组内勾选「可视化 HDR」。图例按相对 SDR 白点的 EV 标识亮度。SDR 白点以下显示中性灰，四个超白区段分别用蓝、绿、琥珀、红。取消勾选或 Escape 回之前的预览，点任一派生预览也可退出伪色。诊断、屏幕及目标预览选择仅影响查看，快照或 032 成片不包含叠加。 |
| 图 3、6 · 图窗 | 右上「当前节点 → Graph」打开有紧凑系统式标题的玻璃工具窗。标题空白处移动整个窗口，窗口边缘调整大小。「工作流 Graph」内可拖空白平移节点，使用添加、更多、百分比和适合全图。旧显影配方进入「只读兼容图」，可缩放查看三个固定阶段。「图窗操作」菜单提供键盘入口。左上关闭或 Escape 还焦当前作品的 Graph 按钮。 |
| 图 4、5 · 输出与提示 | 画布不常驻 HDR 预览卡。「色彩外观」下方并排全宽放置纯文字「预览 SDR 派生」「预览 HDR 派生」选项。来源、工作空间、成片目标与屏幕余量内联显示在本组底部。照片上短暂显示最近一条信息或错误，可手动关闭。两类都留存在本库的「窗口 → 后台信息 → 通知」。 |

工作台使用仓库样片和模拟状态。实际浮点像素、输出目标、屏幕余量及原生图窗材质需在签名应用中核验。直方图的 SDR 白分界、每档 1 EV 和分档可视化参考 [Adobe Camera Raw 官方 HDR Optimization](https://helpx.adobe.com/camera-raw/desktop/hdr-and-advanced-output/hdr-output.html)。

[037 色彩规格](../037-color-film-hdr/spec.md) · [038 节点规格](../038-node-dag-workflow/spec.md)

## 浏览器验收

2026-11-27，Chrome 从「河谷拍摄」网格打开水鸟 `DSC_0712.ARW` 和河湾 `DJI_0348.DNG`。浅色工作台为 1440 × 1000，深色窄窗为 390 × 844。照常选片、编辑、返回后重新进入，另从 Finder 直接打开本地 HTML 复测亮度诊断。故障复现使用带评审开关的[同一工作台](../../docs/ui/prototype/index.html?sceneNativeReview=1)，在「HDR 示波器与诊断 → 模拟显示与故障」触发。

| 在工作台复现 | 浏览器检查与画面 |
| --- | --- |
| 水鸟 → 编辑 → 基础 → HDR | 直方图由五个 SDR 区扩展为九个区。高光限制与下方两个文字预览选项同宽，来源、AP1、PQ、SDR 派生及屏幕余量在组内直接可读。白平衡、光照、颜色、曲线、质感、去雾和颜色分级均能写入当前呈现。[色彩外观](evidence/appearance-parity/01-hdr-appearance.webp) · [共用光照控件](evidence/appearance-parity/02-shared-tools.webp) |
| 在直方图拖 1–2 EV，再用方向键减小 3+ EV | 单次拖动只增加一条历史。3+ EV 可单独调到 −0.05 EV，Shift 加方向键按 0.25 EV 调整。Home 只复位所在档。另调白点以内的曝光或全局高光限制，四档保留原值。光照内勾选「可视化 HDR」可在照片上看见灰与四种分档色的图例。Escape 返回先前派生，点任一派生退出诊断。底部 1:1 与 FIT 只改变查看倍率。[亮度诊断](evidence/appearance-parity/03-visualize-hdr.webp) |
| HDR → B&W → 颜色 → 黑白混色 | 八个色相分别可调，蓝色减至 −45 后照片仍为中性灰。切回 SDR 恢复彩色，重开 HDR 保留原有白平衡和阴影值。[黑白混色](evidence/appearance-parity/04-bw-mixer.webp) |
| 当前节点 → Graph → 拖标题，再拖图内空白 | 标题向右 38、向下 24 像素，节点相对窗体未动。随后拖画布使节点向右 28、向下 18 像素，窗口位置保持。节点曝光和全图摄影曝光可以独立修改。关闭还焦原按钮，重开恢复窗位。[工作流 Graph](evidence/appearance-parity/05-scene-graph.webp) |
| 模拟 HDR 预览失败 → 后台信息 → 通知 → 返回重试 | 画布显示单条带关闭的错误。重绘保持同一个通知，6 秒后消退。后台仍可查原错误，重试成功后仅出现新信息。编辑进入 032 会冻结局部亮度强度，诊断伪色属于当前视图。[错误提示](evidence/appearance-parity/06-error-toast.webp) |
| 窄窗中打开河湾 → Graph，再返回水鸟 | 旧显影配方经普通编辑入口显示三个只读阶段。菜单可收起或展开，Escape 回到原按钮。HDR 的双预览、底部信息与工具可滚动到达，无横向溢出。[深色兼容图](evidence/appearance-parity/07-compatibility-narrow.webp) · [深色 HDR 侧栏](evidence/appearance-parity/08-appearance-narrow.webp) |

通过 [专项脚本](../../scripts/check-ui-prototype.py) 的 `--appearance-parity-only` 可重做上表。13 组浏览器检查共执行 129 个场景，其中本轮专项 14 个、完整工作台 60 个，各组共享的回归场景分别计数。[逐组回执与截图校验值](evidence/appearance-parity/browser-acceptance.json)

浏览器使用仓库 JPEG 代理模拟目标亮度。真实图窗的标题拖动、边缘调整、两个缩放路径和关闭还焦已在独立 macOS 应用复验。真实 RAW 像素、输出文件和物理屏幕记录见相应特性验收。[AppKit 图窗与原始测量](../038-node-dag-workflow/validation.md#系统图窗与真实拖动) · [HDR 验证记录](../037-color-film-hdr/validation.md)

## 签名应用实拍验收

2026-11-27 在 macOS 27.0.1 的 Release 应用中，从资料库打开 Sony 雪景 `snow.ARW`。本地签名 CDHash 为 `7482e3672c234a023614462ddc131ee962707faf`。安装后的主窗正常重开。以下操作通过实际窗口、鼠标拖动、键盘和辅助功能控件完成。[签名、窗口坐标与回归计数](evidence/appearance-parity/signed-release.json)

| 操作 | 原生结果 |
| --- | --- |
| 从 SDR 切换黑白，连续来回切换并打开后台信息 | 画布一次只出现一条 SimpleToast，正文左缘到关闭按钮右缘为 155 点。信息配置为 3.5 秒，实测自动消失，也可点关闭。新通知替换旧通知，后台保留两次外观变更。[实际提示](evidence/appearance-parity/native-toast.webp) |
| 进入 HDR，切换直方图、矢量示波器与派生预览 | 两个图的绘制区域均高 96 点。两个文字预览按钮各宽 113 点，连同间隔与上方轨道两端对齐。在 2–3 EV 档拖动得到 +0.11 EV，右方向键微调至 +0.16 EV，Shift 加左方向键调至 −0.09 EV，Home 复位。其余三档都为零。打开、关闭后台窗口后保留测量图。[HDR 右栏](evidence/appearance-parity/native-hdr.webp) |
| 光照 → 可视化 HDR，从诊断返回派生 | 雪景实际画面按目标亮度显示灰与四色。选取任一派生可退出，Escape 恢复进入前所选的 SDR 派生。逐像素对照、缓存和原寸实拍另见成像测试。[雪景分档](evidence/appearance-parity/native-visualize.webp) · [037 摄影与成片](../037-color-film-hdr/validation.md#同一套摄影工具在-hdr-与-bw-中的成像验收) |
| 从 HDR 和兼容编辑分别打开 Graph | 两者均为系统浮动窗。HDR 标题实际移动 66 × 44 点，拖内部画布只移动节点，拉窗口边缘使宽度由 640 变为 608 点。关闭回到对应按钮，重开恢复位置和尺寸。[系统图窗](evidence/appearance-parity/native-graph.webp) |
| 用资料库卡片分别编辑、重开与导出 | 彩色原片、黑白副本各有自己的命名快照与修图。在 032 分三次交付 1、1、2 个全尺寸文件。[资料库双选](evidence/appearance-parity/native-library.webp) · [导出清单](evidence/appearance-parity/native-export.webp) · [文件像素和重开回执](evidence/virtual-copies/photographic-release.json) |

颜色采样点直接读取当前显示线性浮点帧。雪景在 640 × 960 FIT 的细节位置实测 45.72 nits，同一位置在旧 128 × 192 示波器网格约为 330.13 nits。原寸视口外或诊断期间保留标记并说明状态。两块连接的实体显示器之间的窗口和 ICC 切换也已原生复验。实体 LG 临时切到 SDR 的往返测量归档于 037。[原寸采样回归](../../Tests/RAWMasterUITests/PhotosColorSamplerTests.swift) · [实体 HDR／SDR 跨屏回执](../037-color-film-hdr/evidence/signed-release-20261127.json)

## 持久颜色采样点与模型蒙版

从编辑右栏「基础 → 直方图 → 添加颜色采样点」在照片上点击，最多保存九个源坐标。每行的更多菜单可重新取样或移除，拾取时按 Escape 取消。切换派生、放大或缩回 FIT 后，位置仍属于这张照片，读数随有效帧更新。

| 操作 | 行内结果 |
| --- | --- |
| HDR 目标或 SDR 派生的 FIT 帧 | 采样位置从原片映射到已经裁切、转向的当前帧。原生分别按 Rec.2020 或 Rec.709 读取浮点像素与亮度。普通 SDR 草稿仍显示 0–255 的 R、G、B。 |
| 切换到 1:1，把边缘样点移出取景范围 | 该行显示「当前画面外」，中心样点仍可读。回到 FIT 或平移到该坐标时重新读数。 |
| 在光照中打开「可视化 HDR」或等待新预览 | 诊断期间显示「退出亮度诊断后可读数」。重算或当前帧不可用时显示「等待读数」。两种状态都清空旧色块和旧数值，位置仍保留。 |

浏览器从当前仓库照片代理读取所选像素，标出 JPEG 代理和实际预览分支，使用 SDR 显示回退时也会注明。真实浮点 RGB 与 nits 由原生预览帧读取。整体直方图的稀疏统计与九个持久读数有不同用途。[037 HDR 验证](../037-color-film-hdr/validation.md)

在有效 HDR 调色节点上设置曝光，再从底部「Mask → 主体」采用主体覆盖。裁切、旋转、透视或镜头畸变会改变模型蒙版坐标。提交这类改变时显示「当前调色使用模型蒙版。请先断开它，再裁切、旋转或校正镜头畸变。」可以取消工具草案，返回原节点停用或移除覆盖后重试。中性节点、已忽略的节点和零权重支路不拦截输出中的无关编辑。浏览器另检验将整图模板应用到另一张照片时保留接收照片的裁切、全图摄影调整和输出目标，模板应用可撤销。[038 工作流验证](../038-node-dag-workflow/validation.md)
