# Camera Raw 19 后台处理与编辑窗口的测量边界

测试机安装 Photoshop 28.0.0、Camera Raw 19.0（2794）和 Lightroom Classic 16.0.1。检查覆盖 Camera Raw 的 1,022 个 XMP 预设、Lightroom 的 1,075 个 XMP 文件、插件公开声明的 175 项 Apple Event 术语，以及本次 Sony ILCE-7RM5 原片返回的 XMP。源 RAW 为 9504 × 6336，SHA-256 为 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`。[原始 Adobe 基线](adobe-enhance-baseline.json) · [预设与脚本术语盘点](camera-raw-grading-schema.json)

## 按 EXIF 自动匹配镜头配置

这张照片搭配 Sony FE 14mm F1.8 GM 镜头。Adobe 将镜头设置的 `Auto`、`LensDefaults` 和 `Custom` 定义为三个独立选项。四份 `Auto` 输入均保持配置校正启用，畸变与暗角均为 100，且未提供任何镜头名称、配置文件名或摘要。四次返回的文档都同时给出 `Auto`、原片的镜头 EXIF、实际解析出的 14 mm LCP 文件和指纹。另以错误的 Sony FE 20mm F1.8 G 和正确的 Sony FE 14mm F1.8 GM 分别作手动对照。[每次输入、返回与耗时](camera-raw-profile-match.json) · [20 份原始 XMP](camera-raw-profile-match-xmp.zip)

自动选择与两次独立手选 14 mm 产生了相同的 180,652,032 字节原生 RGB8 光栅。四次错选 20 mm 的光栅稳定，其中有 56,027,352 个像素与自动结果不同，共比较 60,217,344 个像素。三次热打开分别为 1070.263、968.255 和 1163.560 ms，包括 Camera Raw 完整处理原片并将文档交给 Photoshop。计时截止后才保存返回的 XMP 和 BMP。[重复运行脚本](../../../../scripts/performance/benchmark-acr-lens-match.py) · [离线重放校验](../../../../scripts/performance/profile_match_witness.py)

## 参数曲线与八色混合器

`curve-parametric` 指面板中的参数曲线编辑模式。已安装 Camera Raw 的提示文字是“单击以编辑参数曲线”。其 Apple Event 词汇给出四个区域值和三个分隔位置。2,097 个安装的预设文件也只出现这七个参数名，没有编辑选项卡的输入。独立改变四个区域、单独移动分隔点和同时调整整个函数，分别能产生真实的图像响应。要测选项卡仍需从切换事件计到四滑杆或曲线画面出现。[四个独立参数及分隔点的原始计时](camera-raw-open.json)

同一原片的八色色域各有 Hue、Saturation 和 Luminance 三个 XMP 数值。中性文档的 24 项均为 0。分别将每个数值改到 +40，91 次完整打开都按预期写回 24 项。每次单项更改都保留其余 23 个中性值，24 个编辑结果的整幅像素摘要各异。21 项新增参数各保留首次及三次热打开。Blue 三项时间沿用先前的三次热打开，本轮另外核对了这三项的 23 个邻项、整幅像素和先前稳定直方图。热打开中位范围为 771.713–3298.026 ms。96 × 64 的固定取样共有 6144 点，各项分别改变其中 10–2673 点。按色域切换面板、选择 H/S/L 组织方式及定向调整工具仍需从原版编辑器界面取证。[24 项原始数据与逐次观测](camera-raw-hsl-bands.json) · [182 份输入和返回 XMP](camera-raw-hsl-bands-xmp.zip) · [先前 Blue 三项](camera-raw-open.json) · [独立重放校验](../../../../scripts/performance/hsl_band_witness.py)

## 仍需编辑窗口、其他来源或额外的 Adobe 处理结果

下表逐项记录当前参数重开协议能够证明的内容，以及该操作仍需观察的回执。Camera Raw 完整 RAW 打开、面板计算、可视叠层和交互手势各有不同的起止点。

| 操作 | 现有输入与仍需观察的结果 |
| --- | --- |
| `light-auto-single` | Apple Event 列有 AutoExposure、AutoContrast、AutoBrightness 和 AutoShadows，PS 公开选项也有整组 AutoTone。该矩阵项要求现代色调中一个指定滑杆独立自动并保留其余五项，当前没有该手势后的五项保留回执。 |
| `light-histogram-drag` | XMP 能存最终的曝光、白色、黑色等数值。命中直方图五区及对应的拖动响应发生在编辑窗口。 |
| `light-clipping-indicators` | 红蓝溢出标记是预览叠层，导出的照片不含标记。需要抓取指示切换后的画布。 |
| `light-clipping-modifier` | 需要在滑杆拖动期间按住 Option，观察临时溢出图和松开后的恢复。 |
| `light-numeric-reset` | 配方只保存重设后的数值。应分别测数字输入、微调或双击到指定滑杆响应。 |
| `color-wb-picker` | Temperature/Tint 是取样后的结果。公开输入没有从照片指定坐标并让 Adobe 求取白平衡的命令。 |
| `color-vectorscope` | 需读取实际示波器图和样本更新。最终图像的 RGB 不能给出面板刷新时间。 |
| `color-skin-indicator` | 肤色线绘制在矢量镜视图，需要观察开关后的线段。 |
| `color-lab-readouts` | Lab 数值依赖当前指针与面板显示模式，最终 TIFF 不记录指针或读数。 |
| `color-floating-scopes` | 独立面板的位置、尺寸和复开恢复属于窗口状态。 |
| `color-rgb-readout` | 应在实际指针移动后获取直方图显示的 RGB 数字。 |
| `color-samplers` | 应跟踪实际放置与移除的九个标记及各自读数。普通图像像素不能证明编辑器标记状态。 |
| `curve-parametric` | 模式选项卡没有独立 XMP 字段。四区和分隔点的显影已单测。 |
| `curve-input-output` | ToneCurve 的节点数据可重开。选中节点、编辑输入与输出数值以及面板反馈属于不同操作。 |
| `curve-reset-channel` | 序列化线性曲线是重置后的结果，需要观察实际 Reset Channel 只更改当前通道。 |
| `curve-tat-parametric` | 四区数值不能证明由 Adobe 照片取样定位了哪一区，需要真正拖动和回读。 |
| `curve-tat-point` | 保存好的控制点没有保留下落取样位置和手势过程。 |
| `curve-keyboard` | 导航、步进和取消选择属于输入焦点状态，需要跟踪节点与键盘。 |
| `mixer-hsl-mode` | HSL 模式组织相同的一组 24 个值。照片不能反映编辑器当前的组织方式。 |
| `mixer-color-mode` | 按色分组与按参数分组共享同一配方，需要直接确认原版面板。 |
| `mixer-eight-colors` | 24 个独立色域参数可在后台测量。此主表项的选色回执需要原版编辑器。 |
| `mixer-tat` | 多个色域的最终变化无法反推出照片取样和拖动处理的起止时间。 |
| `mixer-isolate-hue` | Option 形成临时彩色/灰阶预览，正常显影文档不包含该叠层。 |
| `mixer-point-picker` | PointColors 可表示保存后取样数据。创建色样时 Adobe 自身的屏幕取样仍需实际点击。 |
| `mixer-point-swatches` | 已有 PointColors 序列可重放，但选中或切换不带修正的色样不会改变照片，需要检查活动色样。 |
| `mixer-visualize-range` | 观察范围是当前选色的编辑器预览，需要取得范围彩色/灰阶画面。 |
| `grading-lut-select` | 已查到九个原厂 CUBE。已确认的 Look / RGBTable 属于相机配置文件，当前缺少新版 Grading LUT 选择的已验证序列化输入。 |
| `grading-lut-amount` | LookAmount 只证明配置文件的强度，仍需新版 LUT 各层自己的 Amount。 |
| `grading-lut-stack` | 需要顺序交换同两份工厂 LUT 后取得不同且稳定的照片，现有文档未暴露三层的序列化结构。 |
| `grading-lut-manage` | 需观察层的排序、替换、删除或眼睛开关，配置文件选择不能代替层管理。 |
| `grading-lut-mask` | 已验证局部色轮和普通局部上色。现有 ACR 写回数据未给出可独立解析并改变蒙版内像素的局部 LUT 选择。 |
| `grading-lut-import` | 打开 `.cube` 或写库文件不能证明 Color Grading 导入器接受文件并更新列表，需要原版导入结果。 |
| `detail-mask-preview` | 锐化 Masking 可写入图像，按住 Option 的黑白锐化遮罩仅供编辑时观察。 |
| `detail-denoise` | 普通 LuminanceNoiseReduction 可后台显影。神经增强需要该原片由 Adobe 创建的增强结果，现有侧车和参考图中没有。 |
| `detail-raw-details` | 公开 CameraRAWOpenOptions 没有增强去马赛克开关。应取得同源 Adobe Raw Details 输出及未增强对照。 |
| `detail-super-resolution` | 普通尺寸设置能放大文件。合格参考需要 Adobe 自身的 Super Resolution 结果和真实 19008 × 12672 像素。 |
| `optics-profile-defaults` | 保存新默认会改变该用户后续的镜头选择。隔离的单份 XMP 不能验证应用默认表的写入与恢复。 |
| `optics-defringe-picker` | Defringe 强度和色带可写回，编辑器从所点边缘估算紫/绿区间的结果仍需真实取样。 |
| `blur-subject-focus` | 需要有效的 Adobe 深度和主体图，并观察自动选择的焦段。显式指定一个 FocalRange 无法证明主体检测。 |
| `blur-point-focus` | 生成深度后点击主体的选焦回执需要 Adobe 的照片坐标和深度。 |
| `blur-area-focus` | 需要从真正拖出的区域求焦并确认范围。手写一个焦段只固定最终结果。 |
| `blur-visualize-depth` | 近、远及焦内颜色属于深度预览，需要带有效深度的原版叠层。 |
| `blur-refine-focus` | 需要已有 Adobe 深度及有效 Focus 笔触。普通局部蒙版的像素变化不能证明深度已精修。 |
| `blur-refine-blur` | 需要实际 Blur 笔画能重复改变指定深度区域，当前原片没有可重开的有效深度精修成果。 |
| `blur-refine-amount` | 应固定真实的深度笔触和初始深度，只变精修强度。 |
| `blur-brush-size` | 半径是笔刷下一次输入笔画的工具状态，需要观察笔迹或工具回执。 |
| `blur-feather` | 需要同一深度笔画在两个羽化设置下的边缘对照。 |
| `blur-flow` | 流量按笔划累计，需要相同轨迹和笔触次数。 |
| `blur-auto-mask` | 自动边缘检测需真实笔画、图像边缘和生成的精修掩模。 |
| `blur-reset-refinement` | 需先建立可见的深度精修，再观察相同深度图上的实际重置。 |

六项 Lens Blur 已运行独立 XMP 试验。`blur-apply` 在本次 ARW 的原生分辨率重读中，两种设置的空间像素和直方图都未稳定分开。`blur-amount`、`blur-bokeh`、`blur-cat-eye`、`blur-boost`、`blur-focus-range` 都依赖可重放的实际 Adobe 深度结果。这五项沿用各自采样的不确定状态。[逐项记录](camera-raw-spatial.json) · [Apply 原生像素检查](camera-raw-lens-blur-native.json)

三项的来源需要单独记录。`color-temp-rendered` 需要 JPEG 或 TIFF 图像才能测相对温度。`detail-denoise-formats` 需要有真实像素的各种已渲染容器，并单独确认 Adobe 的增强结果。`blur-device-depth` 需要随设备深度通道交付的图像，当前 Sony ARW 没有该平面。[已渲染输入的 RAWMaster 测量](photo-denoise.json) · [Adobe 增强基线与待补参考](enhance-capabilities.md) · [局部色轮与 LUT XMP 对照](camera-raw-grading-candidates.json)
