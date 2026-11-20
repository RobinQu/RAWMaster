# 019 · 项目初修、常见调整能力与交互性能评估

2026-10-30。用户最新范围：初修仅已导入并纳入的项目；不进入导入初筛。右上入口整理与当前初修提速直接实施；用户列出的追加参数本轮逐项评估，未实现的控件不放进界面冒充可用能力。本文的成本等级是工程判断，不是工期或Adobe算法等价声明。

## 产品流程与分工

标题栏保留“编辑照片 / 导出成片 / 更多”这类明确操作，编辑中移除重复入口；任务、AI设置、复制原文件和外部副本放在更多。初修/AI/版本只在右栏出现。保存、采用和导出明确分开；正在显示RAW草稿时，不得静默导出隐藏选择的AI版本。项目之外不展示或迟到弹出编辑/导出。

## 功能可行性矩阵

这些功能均有实现路径；区别主要在摄影语义、空间算法和验证成本。Exposure与WB现有；其余是后续增量候选。Adobe文档作为行为目标参考，不能把相似滤镜参数称为兼容Adobe的处理结果。[Adobe影调、曲线及分级说明](https://helpx.adobe.com/camera-raw/desktop/using/make-color-tonal-adjustments-camera.html)

| 控制 | 推荐实现路径与边界 | 相对成本 / 性能策略 | 建议顺序 |
|---|---|---|---|
| Exposure 曝光 | 继续使用CIRAWFilter原生EV，保留RAW解码/高光处理；不改成对JPEG预览后乘亮度 | 已实现；复用RAW开发器与独立显示缓存，曝光改动不重新捕获原片，context按实测内存策略替换 | 现有能力先提速 |
| Contrast 对比度 | 自定义中性默认的感知亮度曲线或CIColorControls原型，再校准阴影/高光与色相；CIRAWFilter.contrastAmount是局部边缘对比，不能直接当作全局对比度 | 低至中；单pass/小LUT，适合缓存后的GPU颜色链 | 第1批 |
| Highlights 高光 | 亮度范围权重与平滑肩部压缩，保留扩展线性值；高光重建与普通压亮不同，需要RAW/相机样本验证 | 中至高；全局曲线可快，但不能宣称找回已丢数据 | 第1批基础语义，RAW重建另验 |
| Shadows 阴影 | 独立暗部权重与toe/中间调保护；不把简单提曝光或boostShadowAmount标为同一控制 | 中；先全局连续映射，局部自适应后做、保护噪声和色相 | 第1批 |
| Whites 白色 | 单独控制白端映射/剪裁，保留与Highlights不同的行为；提供白端剪裁提示 | 中；合并进全局tone/LUT，不另开解码 | 第1批 |
| Blacks 黑色 | 单独控制黑端映射/剪裁，与Shadows分离；黑端中性、渐变和暗部色彩需验证 | 中；合并同一tone链 | 第1批 |
| Vibrance 自然饱和度 | CIVibrance可作为原型，自研按现有饱和度/色相/肤色保护的映射需独立校准；不自动声称Adobe肤色保护一致 | 中；在明确的工作色域中逐像素处理，测高饱和与肤色 | 第1批 |
| Saturation 饱和度 | CIColorControls或明确色彩空间的饱和度变换，零值/去色/最大值语义固定，保留亮度和色域策略 | 低至中；可与contrast融合，先验证灰阶/饱和色 | 第1批 |
| 曲线 | RGB总曲线与独立通道；优先CIColorCurves/自定义1D LUT支持可变控制点，而不是受限于五点CIToneCurve。固定输入域/插值/端点/溢出策略 | 中；小LUT仅在控制点变化时更新，GPU逐像素；不每次重解码 | 第2批 |
| Color Grading 色彩分级 | Shadows/Midtones/Highlights及Global的色相/饱和度/亮度，混合与平衡；按亮度范围平滑权重，实现中性默认和端点保护 | 中；自定义颜色kernel/小LUT，色相与亮度解耦；不能用整图ColorMatrix替代三向分级 | 第2批 |
| Texture 纹理 | 中尺度细节的增强/抑制，需要多尺度/边缘保留分解。CIRAW.detailAmount或锐化不能直接当作Adobe Texture | 高；空间半径依原生像素，预览/导出缩放一致，100%验证皮肤/毛发/噪声 | 第3批独立摄影门 |
| Clarity 清晰度 | 中间调局部对比，多尺度/边缘约束，负值与正值对称性、光晕与亮度改变需验证 | 高；空间滤波中间缓存、ROI含overscan，不能只将大半径锐化改名 | 第3批 |
| Dehaze 去雾 | 透射/大气光估计与颜色恢复，或明确限定效果的多尺度方法；单纯S曲线不是去雾能力证明 | 高；全图统计低分辨率估计+全分辨率边缘引导，验证天空噪声/色偏/反向加雾 | 第3批 |

Texture与Clarity的目标频段不同；需要独立样本与误差/光晕分析，不能把一枚unsharp滑杆拆成两个名字。[Adobe ACR团队Texture说明](https://blog.adobe.com/en/publish/2019/05/14/from-the-acr-team-introducing-the-texture-control)

## 为什么可以做，但不能直接塞进当前配方

初修的未来处理顺序需固定为：相机解码/原生WB与EV → 经过明确色彩定义的扩展线性处理 → tone/曲线/色彩映射 → 空间细节（其具体位置由算法验证）→ 几何 → 显示或输出变换。CIRAWFilter提供linearSpaceFilter，但它只是接入位置，不说明默认RAW tone处理可逆；任何新顺序都应作为新引擎版本，不重解释已有core-image-v1版本。

数据合同需要中性默认、单位/范围、操作顺序、内核版本与色彩空间、逐项/整体复位、保存重放和预览/导出一致性。新配方须显式版本化；旧v1解码和指纹保持原状，不因新增默认字段改写历史请求fingerprint。未知版本拒绝执行，不能忽略参数后继续出片。是否需要DB迁移由字段持久化方式决定，不为UI列表提前升级schema。

现有端点仍需保留拍摄白平衡；恢复as-shot要恢复RAW开发器初始状态，不能只是把温度写成6500K。剪裁、方向、ICC、alpha、8/16-bit容器与原生精度不混淆。

## 性能架构判断

当前性能改造先解决确定的重复工作：每次preview的多遍原片hash、复制/fsync、新filter与全scale请求、取消后native并发及重复100%事件。改为一次验证的不可变源会话、复用RAW filter、有界latest-wins和紧凑的显示图片缓存；保存/AI输入/导出保留完整源验证，不拿stat替代hash。实际实验发现长期保留同一preview context会积累数GiB原生几何资源，因此生产G方案每次native渲染替换context（cacheIntermediates=false），仍保留RAW开发器。当前context保留到下一次替换或关闭；图片在返回前拷贝为独立紧凑sRGB RGBA8，拷贝耗时计入测量。

Apple对交互RAW建议保留filter/context、开启中间缓存、缩尺显示并可直接绘制Metal；导出则使用不同缓存策略。这为本次提速提供公开的系统API路径；是否保留context缓存仍由本机内存与耗时实测决定。[Apple RAW交互与输出建议](https://developer.apple.com/videos/play/wwdc2026/305/)

未来将调整按阶段分key：RAW参数改变只使相关阶段失效；曲线/分级等颜色链改变不重做源捕获；空间细节的半径与原生像素关联，不能在预览和全图使用同一“显示像素半径”。尽量融合逐像素操作，控制中间纹理和带宽，不为每个滑杆创建全图CPU bitmap。

## 验收顺序与质量门

先交付当前曝光/WB/几何的低延迟和干净入口，再增加基础影调/自然饱和度/饱和度，随后曲线与三向分级，最后纹理/清晰度/去雾的独立算法与摄影质量验收。每批都测中性参数与旧版本重放、RAW高光/阴影、肤色、天空渐变、毛发/文字/直线、噪声、剪裁和不同缩放；原片不写入，生成不自动采用。

对新增颜色链，先冻结高精度参考与可见误差界限，再测GPU合并版本；不能先把效果做得很弱来满足速度，也不能用低清预览的速度宣传最终全尺寸成片性能。

## 与Camera Raw的速度对照

本机检测：macOS27.0.1，Photoshop27.11.0、LightroomClassic15.6。使用独立RAW副本，原片SHA不变。必须分别测冷启动、同一分辨率暖预览、连续调整到实际绘制、松手收敛、100%细节和完整保存；记录视口/背屏像素、GPU设置与处理配置。Adobe本身也使用GPU显示及图像处理加速，因此不能靠“我们用了GPU”推出更快。[Adobe GPU说明](https://helpx.adobe.com/camera-raw/desktop/troubleshoot/acr-gpu-faq.html)

REA已查阅官方README，其原生分析需额外provider/调试配置；当前自有源码热点与公开API已足够确定首轮修复，未安装或修改全局agent配置。若后续有无法从行为和公开API解释的具体问题，再用它做带证据的定点分析。[REA官方项目](https://github.com/morluto/rea)

实测数字与是否优于Camera Raw将在019验证记录追加；目前不声称已证明胜出。仅有单次冷样本不计算p95；自有API计时和第三方GUI采样分开，测量分辨率不足则保留未证实结论。


## 019已实现部分的阶段实测

生产G同2400预览：真实RAW21配方暖态中位236.43ms/p95243.58ms，21组canonical通道p99误差0/255、最大1/255。匹配交替的旧版p95640–653ms、新G247–249ms；未证明冷打开稳定变快。保留全部运行而不是只选最好一次。

生产双源与两native显示图的周期采样高水位2678.25MiB，约20ms采样可能漏短峰，不能称连续精确峰值或硬上限。关闭后的OS资源占用可异步下降。长期复用context、关闭其缓存、几何清缓存、重建filter、eager图片或单独CPU拷贝等A–F变体均未通过事先固定的3GiB afterframe采样门；G替换context才通过。完整实验与限制在019验证记录。

早期检查点（待验事项已由下方19.2最终状态取代）：项目内界面接线51项回归、双真实RAW保存/9504×6336JPEG/比较/100%控制器流程通过；原片与原业务记录未改。当时真实窗口待解锁，1200/1600仍在独立验证；随后两档质量未过门而拒收，生产未启用缩尺，不使用低分辨率速度冒充canonical2400改善。


## 19.2 渐进交付与最终代码检查点

持续输入下不能把active每次撤销，否则计算完成的图也永远到不了画布。19.2保留旧strict默认，仅editable RAW初修FIT可经独立registration逐步展示有效完成帧，pending仅保最新；单调epoch与源/版本/几何/viewport隔离，终值不回退。该方案不改G像素、不降解码质量。

实际前端控制器300次约20Hz输入期间接受61张唯一progress，最终配方/忙态正确，shutdown全回收；程序化停止→观察终值约386.7ms，不是GUI/draw。最新同2400 API暖p95263.13ms（超250目标），全部轮次保留；755项集成31skip/0fail。H0同epoch缓存因1600viewport时4095MiB拒收，H1/oversampling未run。正式build19.2已完成原生窗口UX验收、升级前备份、安装与实际个人资料库启动校验。曝光0.5、草稿返回保留、导出三选取消、几何折叠/overlay、比较后立即100%无永久错误、键盘文字安全、浅深色/最小窗口与项目范围均经CUA确认。当前755项/31skip/0fail计数不变。

两次真实拖动日志的Oracle独立分析仅覆盖前132955B/209行：33参数操作中29关联native时间戳、4缺事件；21唯一发布帧中19记录draw-return、2缺测不记0。可关联native input→AppKit draw-return仅n6，中位259.71ms、范围117.22–436.73ms（仅1个interactive与2个手势settled，不报告稳定p95）；release→draw n2为396.66–436.73ms。终点是image.draw返回而非WindowServer呈现，不能证明66ms/250ms或快于ACR。

标准版安装和备份回执见[installation-19.2.json](../../output/validation/019-preview-ux/installation-19.2.json)与[installation-backup.json](../../output/validation/019-preview-ux/installation-backup.json)：完整应用support3034913823B、prefs与旧app已备份，外部模型权重保留原处且不在备份内。32表计数全不变、31表内容SHA不变，唯一现有项目浏览状态grid→single/revision13→15因GUI验收，非审阅/采用/资产改动。6928资产/7项目/49组/588membership保持。后续基础颜色链/曲线/分级/空间算法仍是评估路线图，本批未实现这些新控件；顺序维持上表。


## 020 增量状态（2026-10-31，尚在最终验收）

基础影调七项、RGB/独立通道PCHIP曲线、阴影/中间调/高光/全局Color Grading已实现；只在已导入项目内开放。旧019.2交付状态仍保留为历史，本节更新其后续研发状态。新算法明确版本为schema2/rawmaster-color-v2，不重解释旧schema1配方。Texture/Clarity/Dehaze仍待后续独立算法。

高精度全尺寸F32基底缓存已通过63组配方、117固定区域严格质量资格。第一轮6000万像素/2400预览的连续颜色调整公开API中位数约690→175–179ms，首次预览约1秒；这不是原生屏幕延迟，也不是与CameraRaw的速度比较。原3GiB内部目标未达；本机M4Max128GiB采用前瞻4GiB资格，最大采样约3.32GiB。当前正验证resident descriptor精确复用、捕获文件失效恢复与最终工作流，默认缓存仍关闭。最终交付状态和安装记录以后续[020报告](../../output/validation/020-development-controls/delivery.html)为准。


## 020 最终交付记录（2026-10-31）

20.0 已安装至 `/Applications/RAWMaster.app` 并在原个人资料库打开项目内初修。基础影调、RGB/独立通道曲线及 Color Grading 已交付；导入初筛与全局资料库不提供初修。完整 MAIN Release 809 实际通过、49 opt-in 跳过、0 失败；63 配方/117 区域质量、双源生命周期、300 输入、native 七步、真实窗口保存与重启均通过独立复核。

同图连续调色公开 API 中位 122–130ms，匹配未缓存版本约 5.4 倍提升；实际原生低频 CUA 输入至 AppKit draw-return：短拖最终帧 321/402ms（中位/p95），曲线 232/272ms，色轮 228/270ms，各20不同值。包含观察开销，不是 WindowServer、20Hz UI 压测或 ACR 比较；66/100/250ms目标和快于ACR仍未达或未证实。曝光/白平衡变更及跨照片仍有RAW重处理/缓存填充成本，不能外推暖态颜色收益。后续性能工作需分解事件提交、渲染与绘制交接，并建立匹配的Adobe实测基线。

本机精确profile已显式启用；独立最终Preview真实shared填充3/复用70，两次退出资源计数全0。正常App未开trace，不能冒称再次测了相同fill/hit。升级前完整support约3.60GB、SQLite一致性快照、偏好、19.2应用备份在 `~/Library/Application Support/RAWMaster Backups/before-020-20261031-151600`；旧包两份保留。升级后实际PID/lsof确认原库，全部32表内容哈希及行数与备份相同，schema7/integrityok，EV .25候选保留，除两个profile偏好其它配置未变。

最终报告及证据：`output/validation/020-development-controls/delivery.html`、`installation.json`、`native-final/appkit-latency.json`、`application-cache-profile/source-phase-manifest.json`。所有原失败、探针限制和恢复记录保留，不重写为通过。
