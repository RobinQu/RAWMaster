# LightFlow 图像引擎实测

测量使用 LightFlow 发布构建 `2d41ab1` 的 Rust/WebGPU 像素引擎。浏览器只从本机回环地址读取该构建和 ARW。初次打开采用引擎的 `PixelEngine.openRaw` 全尺寸入口。测试先等待源图进入 GPU，再逐项修改配方。每次输入直接调用 `PixelEngine.render`，计时到 `PixelEngine.idle` 完成。该列回答的是指定尺寸下生成画面纹理需要多少时间。浏览器界面事件、合成器提交及屏幕显示需要另外计时。[真实 RAW 样本和逐次记录](lightflow.json)

## 代码如何决定计时边界

| 发布代码 | 影响 |
| --- | --- |
| 编辑器的 `applyEdit`、Worker 的 `decodeSensor`、`decodeRaw` 和 `frame` | 常规编辑器先用 FlashRaw 读取归一化的半精度 CFA，向 `openRawSensor` 交付尺寸、方向、传感器数据和显影设置。首次草稿升级到全尺寸时可以复用已保留的传感器数据。后续拖动复用已打开的源图。独立基准用相同发布引擎提供的 `openRaw` 入口，单列打开时间。 |
| Worker 的 `build`、`viewerFrame`、`engine.idle`、`viewerDone` 和 `tap` | UI 视图和编辑配方独立。Worker 在 `editSeq` 变化时重发配方，并在 GPU 完成后广播帧。引擎测试用精确的整图目标，记录各算子直接生成工作纹理的耗时。历史 `frames.onFrame` 数据保留其各自的等待边界。 |
| 编辑器的节点工具默认值、`syncLuts` 及 `installPlugs` | 局部调整固定同一张径向蒙版，改变一个节点参数。锐化半径、阴影色轮饱和度等从属控件保留各自所需的前置设置。只有实际取回的像素发生变化才接受该项。 |
| WGSL 的传感器分块、金字塔采样、细节处理和蒙版片段 | 分块去马赛克保留 CFA 对齐。纹理和引导图跨帧复用。读回被移动到每次计时结束以后，并在下次操作前等待完成。 |

可从[发布版编辑器](https://lightflow.dev/assets/index-zP4kU_H7.js)、[图像 Worker](https://lightflow.dev/assets/worker-PmnZFHwu.js) 和[像素引擎公开接口](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/web/lightflow_host_wasm.js) 定位上述代码。已核对的像素引擎 JS/WASM 文件摘要记录在证据 JSON 中，可和本机发行包逐字节核查。FlashRaw 的输入输出格式另见[上游源码](https://github.com/ybouane/flashraw)。

## 复跑

在仓库根目录运行下列命令。`--engine` 指向同一构建的本机 `rust/web` 目录。目录应包含 `lightflow_host_wasm.js` 和 `lightflow_host_wasm_bg.wasm`。脚本拒绝混用其他构建，可以通过 `--raw` 和 `--chrome` 指定真实文件及浏览器的路径。输出文件需要使用新的名称。

```sh
python3 scripts/performance/benchmark-lightflow.py \
  --raw output/performance/acr-benchmark.ARW \
  --output output/performance/lightflow-controls-run.json \
  --size 2400 --samples 20
```

计时对象是 2400 × 1600 的完整输出。每个控件记录首次试调和 20 个后续输入，各次输入使用互异的数值。这里的首次试调发生在同一个已打开的进程和原片会话中。每次计时后，测试读取 RGBA16F 纹理，在 96 × 64 个固定位置检查有限 RGB、有效 Alpha 以及 RGB 摘要变化。该检查用于识别空帧、相同帧和无效输入。不同应用的视觉一致性还需要同色彩空间的参考图。原片 SHA-256 在运行前后各计算一次。

LUT 选取、强度、叠加、排序和蒙版另有五组逐次记录。选取固定两份 2³ 色表，排序保留相同色表和数量，只交换节点边。选取、叠加和排序在两个明确配置间交替，每个配置都有独立输出摘要。可核对的工具与参数清单也列出了这个发行版缺少同义操作的项目，例如单张学习型超分、独立发光方向和取色器式去紫边。[LUT 引擎实测](lightflow-lut.json) · [发行版逐项功能依据](lightflow-availability.json)

## 黑白、原片白平衡与暗角样式

四个离散操作在相同全尺寸 Sony RAW、2400 × 1600 工作纹理、原版 Rust/WebGPU 引擎下逐项运行。先取一个固定参考，每项再记录首次更改及 20 次后续输入。每次切换都改变实际 RGB，回到任一设置都能复现该设置的像素摘要。[全部输入、像素证据与引擎指纹](lightflow-supplement.json)

| 操作 | 交替输入 | 暖态中位 ms | p95 ms |
| --- | --- | ---: | ---: |
| 裁切后暗角样式 | Highlight Priority / Paint Overlay | 0.667 | 1.155 |
| 黑白处理 | Standard / Monochrome | 1.308 | 1.640 |
| 白平衡预设 | 日光 5500 K、+10 / 钨丝灯 2850 K、0 | 1.518 | 1.645 |
| 拍摄时白平衡 | 钨丝灯 / 原片 As Shot 6330 K、+22 | 1.353 | 1.550 |

暗角样式固定 Amount −70 和 Highlights 80。早期在 Highlights 0 下切换 Highlight Priority 与 Color Priority，两者在这张照片的采样网格上相同，该组合仍保留为未验证。[暗角首轮试验](history/lightflow-style-unverified-initial.json)

原版编辑器的 Auto Tone 和 Auto White Balance 调用 Worker 的 `query.autoBase`。Worker 用同一张源图、修复笔触与几何设置复用分析样本，再调用 Rust 的 `analysisAuto`。本次从源图获得 384 × 256 RGBA32F 样本花了 5.250 ms。后续每项交替设置两套起始值，检查实际返回的字段、是否改变输入，以及同一输入的 11 个结果摘要。

| 自动操作 | 计时终点 | 暖态中位 ms | p95 ms |
| --- | --- | ---: | ---: |
| Auto Tone | 返回曝光、对比、高光、阴影、白点和黑点数值 | 2.797 | 2.970 |
| Auto White Balance | 返回 8326 K、Tint +27 及自动模式 | 8.870 | 9.155 |

采样准备与两项自动计算分别计时。用前述命令加 `--auto-analysis` 可复跑这两个数值端点。每个离散菜单可用重复的 `--operation` 指定功能 ID。[数值结果、逐次时间与真实分析样本摘要](lightflow-analysis.json)

当前逐项盘点依据完整的编辑配方、正确器与蒙版工厂、编辑器控件及 Worker 调度，记录了 48 个没有同义操作的 Camera Raw 控件和 19 个有相关实现的控件。LightFlow 的单目深度模型为节点生成 Depth Range 蒙版，画笔具有大小、流量、羽化与 Auto Mask，Detail 节点另有 Blur/Sharpen。发布版没有将这些参数连接成带焦平面、散景形状和深度精修笔触的 Lens Blur。镜头校正可以使用原片内嵌数据，其中包含部分机型的色差、畸变和暗角。面板将其组合为一个开关。[对应控件、发行源码位置与证据](lightflow-availability.json)

## 原版编辑器的控件手势

同一张原片在后台编辑器占 2368 × 1579 像素。Chromium 发送受信指针事件，从首次按下计到实际手势已释放、屏幕控件公布的字段与应用配方吻合。时间包括驱动发送整组点击或拖动的间隔。每个操作记录两次初始输入和十次后续输入，同时保留起始数值、落点、释放次数和最终数值。[手势样本与原始编辑器指纹](lightflow-gestures.json)

| 操作 | 实际结果 | 暖态中位 ms | p95 ms |
| --- | --- | ---: | ---: |
| 双击曝光名称复位 | 从 +1.25 或 −1.75 EV 回到 0 | 17.825 | 18.755 |
| Shift 双击曝光名称，单字段 Auto | 两个起始曝光均经分析得到 +0.50 EV | 35.423 | 36.645 |
| 拖动直方图的曝光区 | 向右或向左 24 像素，从零分别变为 +0.36 或 −0.36 EV | 21.250 | 21.820 |
| W 后在照片取白平衡 | 两个位置返回 10630 K、+27 和 4080 K、−2 | 21.800 | 22.385 |

启动下文的原版后台会话后，可运行 `python3 scripts/performance/lightflow-ui.py gestures --session /tmp/lightflow-stock-session.json --raw output/performance/acr-benchmark.ARW --output output/performance/lightflow-gesture-retest.json`。白平衡取样前把两个实际控件设为 5500 K 和 +16，检查器接纳两项起始值后才启动手势计时。

同一版本的颜色混合器切换 Hue / Saturation 后，八个实际字段的名称、值、量程就绪，中位耗时 1.525 ms。对 Aqua / Magenta 的色相数值框提交并核实八色配方中仅目标字段更改，中位耗时 17.377 ms。素材导入使用原版文件选择器与打开这张 ARW 的编辑会话。12 份各 132725 字节的 17³ CUBE 都有独立 SHA-256。选中文件至解析、入库、其内容地址与标题写入当前节点，中位 32.202 ms、p95 33.085 ms。计时后还实拍画布，两个色表变换各自产生稳定且不同的照片。该入口只接受单个 .cube 文件。可用同一后台会话的 `panel-tools` 子命令复跑这三项。[逐项计时、素材校验和预览证据](lightflow-panel-tools.json)

## 显示缓冲中的剪切和锐化打样

各操作固定一张 2400 × 1600、sRGB RGBA8 的无边框照片，从提交原版 Viewer 设置计到 CPU 可读取整幅显示缓冲。校验在计时结束后进行。两个初始设置之后各有十次交替试验。[原版 Viewer 设置、每帧像素与计时](lightflow-viewer-tools.json)

| 操作 | 输入与像素验证 | 暖态中位 ms | p95 ms |
| --- | --- | ---: | ---: |
| 剪切指示 | 曝光 +1.5 EV，切换全局显示后 21 个接近剪切的位置改变，警示 RGB 为 255、0、86 | 4.167 | 4.815 |
| 临时剪切预览 | 保持高光调节，切换 Option 的 clip-high 视图并验证 A/B 摘要 | 4.252 | 4.345 |
| 锐化蒙版预览 | 固定锐化设置，按住 Option 时 6144 个位置均为中性灰，并包含黑、白蒙版细节 | 4.245 | 4.625 |
| 锐化半径 | 数量和细节固定，两端半径 0.5 / 3.0 输出不同且各自复现 | 4.345 | 4.720 |

早期对全局剪切只采纯红或纯蓝位置，漏掉原版实际使用的粉红警示。早期对锐化蒙版要求整图摘要完全相同，遇到两幅有效灰度打样有局部差异。随后独立运行按近剪切区域的变化比例和蒙版显示的颜色与明暗分布验收。用前述引擎命令加 `--viewer-tools --samples 10` 可复跑。[早期完整观测](history/lightflow-viewer-tools-first.json)

## 照片取样、曲线、镜头配置与示波器

同一张 Sony ARW 在原版编辑器中交替取两个位置，向上拖动 60 个像素。一处只将蓝色饱和度提高 30，另一处提高橙色 24、黄色 6。源数据、原版控件值和照片位置均保存在记录中。局部 Hue 使用独立的径向蒙版，416 个内圈采样像素对应的摘要随参数改变，1640 个外圈采样像素的摘要在全部 21 个输入中相同。[原版编辑器手势](lightflow-photo-tools.json) · [GPU 蒙版内外像素](lightflow-mask-hue.json)

| 操作 | 暖态样本数 | 中位 ms | p95 ms | 计时终点 |
| --- | ---: | ---: | ---: | --- |
| 局部 Hue | 20 | 2.362 | 2.575 | 2400 × 1600 线性纹理的 GPU 队列完成 |
| 矢量示波器 | 20 | 0.770 | 1.205 | 原版 GPU 统计与 256 × 168 RGBA8 色度轨迹读回 |
| 照片上的 HSL 拖动 | 10 | 19.823 | 20.215 | 释放指针、八色可见值与正确器配方一致 |
| 矢量图肤色线 | 10 | 2.095 | 2.325 | 原版开关、辅助功能状态与 SVG 参考线一致 |
| 曲线方向键 | 10 | 1.708 | 5.557 | 当前点纵坐标实际移动一个 8 位等级 |
| 曲线 Input / Output | 10 | 3.922 | 7.542 | 输入两项数值、确认、读回原版图表与配方坐标 |
| 复位单个曲线通道 | 10 | 16.357 | 16.832 | 红色或绿色恢复线性、未选蓝色曲线保留 |
| 参数曲线选项卡 | 10 | 25.904 | 31.046 | 四项数值与已准备参考匹配，读回完整 282 × 282 曲线画布 |
| 启用内嵌镜头配置 | 10 | 482.691 | 482.925 | 原版 RAW 开关提交、查看器空闲并取得合成器中的照片 |

两种饱和度的矢量图分别从 699392 个源像素累加，得到 481、1475 个有色轨迹像素，原版标尺另行绘制。肤色线的 31 个离中心半径 50%–86% 的校准像素在十二张合成器截图中均符合两态，包含截图传输的暖态中位数为 33.100 ms。首轮在靠近中心的色度密集处取样时出现了轨迹干扰。镜头开关使用相机内嵌数据，十二次输入的结果在同一状态下重复、两个状态之间不同。[矢量轨迹及计时](lightflow-vectorscope.json) · [肤色线首轮](history/lightflow-skin-tat-first.json) · [各控件、两个原版曲线会话及校准坐标](lightflow-photo-tools.json)

### 相机 JPEG 的相对色温

Sony ARW 的第 196770 字节起包含相机生成的完整 JPEG，长度为 258192 字节。采用原始 JPEG 字节打开同一幅实拍场景后，原版编辑器提供 −100…100 的色温字段。测试在 1616 × 1080 原生显示面积输入 −28 和 +28，检查自定义白平衡、零 Tint、控件数值和照片画面，十二次均按两态复现。主 RAW 矩阵中的相对色温标为源类型不适用，此组单列。

| 文件与操作 | 暖态样本数 | 中位 ms | p95 ms | 计时终点 |
| --- | ---: | ---: | ---: | --- |
| 相机 JPEG，色温 −28 / +28 | 10 | 252.999 | 254.004 | 提交原版数值框，等候查看器内建空闲检查，取得完整照片区域的 96 × 64 compositor RGB |

其中原版 `waitForRender` 用 100 ms 间隔两次确认空闲，表中时间包含该等待和截图传输。附档记录原片和 JPEG 的各自哈希、字节范围、十二次照片摘要与配方。[JPEG 色温全部观测](lightflow-rendered-temperature.json)

## 原版查看器的首帧与稳定帧

原版 Rust 查看器的 31 个控件各提交两种输入、读取 22 次完整显示缓冲，682 次输入均由查看器请求两帧。首末全幅像素在 58 次输入中逐字相同，所有控件的稳定画面均能按 A/B 严格复现。该组分别报告首次引擎调用到首帧、到首个匹配最终全幅的缓冲、到实际末帧的时间，并另列包含首个动画帧的参数提交时间。[各控件的 P50、p95 和精确首末匹配比例](lightflow-panel-schedule.md)

## 原版编辑器的后台画布响应

独立的 Chromium Headless Shell 在内存中合成整套 LightFlow 编辑器。它从本机载入原版页面、Worker、Rust/WASM 及测试用 ARW。视口为 3200 × 2000，设备像素比为 1。根据编辑器返回的全尺寸源图、画布和视图仿射变换，照片占据 2368 × 1579 个合成器像素。脚本聚焦原版滑块数值框，等待一次 requestAnimationFrame 以全选并准备新值，从宿主发送 Return 时开始计时，到照片中心 60% 区域第一次向目标颜色移动至少 20% 的合成器帧为止。每次按键都核对控件接受的实际数值。先取两个 A/B 校准帧，再交替测量十次，使用三个应用共享的 96 × 64 RGB 采样和收敛判据。[逐次输入、目标色差和帧时间戳](lightflow-compositor.json)

`Page.screencastFrame` 给出浏览器合成帧的时间戳，脚本将其转换到输入所用的同一台机器单调时钟。帧传输使用 960 × 600 的无损 PNG。编辑器的渲染尺寸保持为 3200 × 2000。首轮试用整幅 PNG 时，传输积压达 0.6 至 1.4 秒，出现跨输入漏帧，因此正式数据统一采用缩小传输图。输入准备与浏览器刷新周期有相位关系，这会影响同组延时的离散程度。原始记录保留帧的投递延时、A/B 参考像素摘要、十次响应轨迹和末帧误差。运行没有桌面窗口，Camera Raw 和 RAWMaster 的 ScreenCaptureKit 窗口帧属于另一种采集边界。这两组窗口帧可验证照片已进入 WindowServer。物理显示器扫描输出需要另外测量。

复跑需要同一份离线发布页面、真实 ARW、独立 `chrome-headless-shell`，以及 Python 的 `websocket-client`、`Pillow`。先运行 `start`，直到输出 `Ready` 后，在另一个终端运行 `compositor`。两个路径参数都应指向当前运行的新文件。

```sh
python3 scripts/performance/lightflow-ui.py start \
  --raw output/performance/acr-benchmark.ARW --width 3200 --height 2000 \
  --session /tmp/lightflow-stock-session.json

python3 scripts/performance/lightflow-ui.py compositor \
  --session /tmp/lightflow-stock-session.json --raw output/performance/acr-benchmark.ARW \
  --photo-width 2368 --photo-height 1579 --transport-width 960 --samples 10 --settle .65 \
  --output output/performance/lightflow-compositor-retest.json

python3 scripts/performance/lightflow-ui.py close --session /tmp/lightflow-stock-session.json
```
