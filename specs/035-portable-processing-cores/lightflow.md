# LightFlow 的调色 DAG 与 WebGPU 像素引擎

2026-11-22，实取构建 `20261111155800-2d41ab1`。在发布版引擎里把同一幅图送进两个曝光支路，再把两条边接入 Layer 的两个输入端口。交换端口后，整张 RGBA16F 图发生变化。恢复端口顺序后，图像逐字节恢复，第三次合成报告 `segments = 0`。RAWMaster 可以由此借鉴**有序输入端口、执行段缓存，以及独立于编辑配方的视图状态**。下文的 RAWMaster 取舍属于本项目设计。[菱形图探针](evidence/lightflow-graph.mjs) · [整帧读回和缓存计数](evidence/lightflow-graph.json)

## 取证范围

从官网下载首页、编辑器、许可页、图像与 AI Worker、FlashRaw、Rust 像素引擎的 JS 绑定与 WASM 等 65 个同源资源，共 43,901,147 字节。抓取在北京时间 23:11 完成，镜像保存在仓库的 `output/035-processing/lightflow/site/`。各文件有 URL、大小和 SHA-256，随文脚本已在第二个空目录重新下载并逐字节校验全部文件。Rust 构建清单的版本是 `4df20b5d916f8d0e`。镜像覆盖本文的渲染路径，外部 ONNX 权重与可选第三方服务未下载。发行页声明 Apache License 2.0，组件、编解码器和模型有各自的 notices。[下载清单](evidence/lightflow-release.json) · [官网](https://lightflow.dev/) · [Rust 版本清单](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/version.json) · [发布许可页](https://lightflow.dev/license)

REA 定向分析 Worker、inpaint 和 jobs 三份 JavaScript。编辑器的连线、Worker 的帧循环、AI 会话创建另沿实取发布字节人工追踪。REA/WABT 1.0.42 验证像素 WASM，有 134 个导出，缺少 debug-name section。可复核 `pixelengine_render`、`pixelengine_viewerFrame`、`pixelengine_exportTile` 等导出、内嵌 WGSL 片段及调用边界。内部 Rust 类型、完整调度算法和设备驱动编译结果仍未知。证据表给出 REA ID、WAT 哈希、零起算字节偏移和定位词。[取证记录](evidence/lightflow-locations.json)

## 从配方追到最终像素

| 问题 | 发布实现中查到的调用与约束 | RAWMaster 的设计取舍 |
| --- | --- | --- |
| 怎样表达复合调整 | `PhotoEdit` 包含 `source`、`base`、`grade`、`retouch`、`geometry`。`grade.nodes/edges` 支持 corrector、parallel、layer 与 group。`k5` 从 `@output` 逆向找祖先，`RO` 对这些节点按入度排序。`HO` 在连线时检查自连、回路与端点。`DO` 将同一前驱扇出再合流，混合器按 `edge.index` 取输入，layer 保存 `blendModes`。`_O` 将单入单出的连通片段收为子图。此证据覆盖调色子图，RAW 解码、模型和导出在外围另有入口。[发布编辑器](https://lightflow.dev/assets/index-zP4kU_H7.js) | 将端口类型和顺序写进配方规范。桌面与服务端共用可达性、连接校验和拓扑执行规则。给 LUT、蒙版、模型输出分配稳定内容身份，批处理只替换当前照片绑定。 |
| 一次编辑需要重新做哪些工作 | 常规 RAW 编辑路径 `decodeSensor` 优先请求归一化 F16 CFA，兼容分支接受 F32，由 `openRawSensor` 接收传感器数据、元数据和设置。保留传感器结果时，升级 full 可复用源数据。`editSeq` 变化才重发编辑 JSON。视图的缩放、中心、裁切工具叠加等另随帧输入提交。`render` 返回 handle、segments、cached、provisional，`release` 释放调用方持有的 handle。[图像 Worker](https://lightflow.dev/assets/worker-PmnZFHwu.js) · [像素引擎接口](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/web/lightflow_host_wasm.js) | 分开保存原片身份、配方版本和视图参数。节点输出键纳入上游内容、色域、几何和请求分辨率。设备相关资源由执行器掌握，取消或过期的请求只可发布自己版本的结果。 |
| GPU 如何调度 | Worker 每 tick 先调用 `compileDemanded(4)`，再尝试空闲预热。`viewerTick` 给出绘制和忙碌位，每个 viewer 同时最多提交一帧。`viewerFrame` 之后用 `idle()` 回调清除在途标记，再调用 `viewerDone`。发布绑定明确描述 provisional 帧等待融合程序，空闲预热每步单独编译并等待。因而“JS 返回”“GPU 完成”“读回完成”各有独立时间点。[Worker 帧循环](https://lightflow.dev/assets/worker-PmnZFHwu.js) · [编译与呈现接口](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/web/lightflow_host_wasm.js) | 将语义图编译成设备执行段，点运算可融合，邻域、模型、归约和需要保留的分支形成边界。为拖动帧留资源，在交互空闲时进行冷管线预热。分别统计首次编译、暖 GPU 时间、回读、显示或交付延迟。 |
| 如何处理颜色与精度 | 普通位图分条写入 sRGB 标记的 `rgba8unorm` 暂存纹理，`bitmapFinish` 执行线性化、颜色转换和方向处理。WASM 的 WGSL 片段能定位工作 ProPhoto 到线性 sRGB 的变换、`WORKING_TO_XYZ`、sRGB 编码以及 `rgba16float`、`rgba32float` 的写纹理声明。`exportTile` 的接口指定，8 位输出读回 F16 texel，较高位深路径读回 F32 后再组装。这里只能确定这些路径和接口对应的精度，无法推定每个内核都用同一格式。[WGSL 与绑定字节位置](evidence/lightflow-locations.json) · [导出接口](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/web/lightflow_host_wasm.js) | 把原色、白点、传递函数、alpha 语义与存储精度写进端口契约。沿用 RAWMaster 的兼容性色彩基线。改用 F16 的节点使用 HDR、负值、暗部和反复叠加样本对照 F32，导出单独验 ICC/编码和数值误差。 |
| AI 怎样进入渲染 | `installPlugs` 接受 matte、patch 及版本提供者，更换提供者会清渲染缓存。inpaint 桥从 full 源取同一 ROI 的图像与 matte，两份 ticket 并行读回后交给模型，返回候选以 `setPatch` 保留。图像 Worker 的导出路径会先 `ensureAssets`。ORT Worker 按模型、角色、后端缓存 session，前台队列优先，可取消排队任务，并实现 WebGPU 失效后的 WASM 后备。这里验证了供数和失效边界，模型质量及回退耗时需另测。[修复桥](https://lightflow.dev/assets/inpaintGpu-Cp3ARYYv.js) · [推理 Worker](https://lightflow.dev/assets/ortWorker-DaXiU2P4.js) · [像素接口](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/web/lightflow_host_wasm.js) | 模型动作生成可缓存的 matte/patch。图负责输入色彩、坐标、方向、重采样和混合。预览可显式标记等待素材，正式导出需要所有依赖就绪。模型名称、权重摘要、ROI 与源版本一起标识候选。 |
| 大图与故障如何处理 | `exportBegin` 接受源身份、同一 PhotoEdit 格式及输出规格。所查流式分支默认 tile 边长 1024，先等初始 GPU 工作完成，再按行取瓦片和 ticket，一整条带完成才交给编码器。瓦片间检查取消。失去设备时重新打开导出，在当前条带内重算，最多三次恢复，完成时 `exportEnd`。[导出 Worker](https://lightflow.dev/assets/worker-PmnZFHwu.js) | 将 GPU 条带重试与持久任务重试区分计数。由队列取得资源预算、管理租约与幂等输出，像素核心负责邻域 halo 和条带生命周期，编码器只接收完成的条带。 |

## 本轮 GPU 复演

**菱形图。** 新建 128 × 128 RGBA16F 不透明渐变，A 支路曝光 −0.75、opacity 0.55，B 支路 +1、opacity 0.70。两个支路均读同一源，以两个 normal 端口合成。每次等待 GPU 完成，再检查每个通道为有限数、每个 alpha 为 1，对完整读回字节计算 SHA-256。全部五次都是非 provisional 帧。最后引擎报告 4 条管线、9 个缓存条目、1,179,648 字节缓存，存活的 handle 和 ticket 均为 0。`segments` 和 `cached` 是引擎返回的字段，只用于说明这组请求的计算与复用。[固定配方、全哈希和引擎统计](evidence/lightflow-graph.json)

| 请求顺序 | 返回 segments | 返回 cached | 整帧 SHA-256 前 12 位 |
| --- | ---: | ---: | --- |
| 单独 A | 3 | 0 | `98937c095646` |
| 单独 B | 2 | 1 | `94222754a61c` |
| A 端口 0、B 端口 1 | 1 | 3 | `a5fd65970eda` |
| B 端口 0、A 端口 1 | 1 | 3 | `a4250f6c770c` |
| 恢复 A 端口 0、B 端口 1 | 0 | 3 | `a5fd65970eda` |

**真实 RAW。** Apple M4 Max，macOS 27.0.1，Chromium Headless 157.0.8103.78，WebGPU Metal。重新下载的引擎直接 `openRaw` 打开一张 9504 × 6336 的 Sony ILCE-7RM5 ARW，用时 1,143.105 ms。原片驻留后，在正常 viewer 调度中交替送入 A/B 各三次，核对最终 2400 × 1600 不透明 sRGB RGBA8 全幅哈希。下列计时从首个变化帧的 `viewerFrame` 入口到最终 CPU 可读帧，包含后续帧调度与回读。每次操作历经两帧，排除每组最初 A/B 两次后的统计样本数为四。该测量未包含物理输入、系统合成显示或文件编码。[原片哈希、每次状态与完整记录](evidence/lightflow-raw.json)

| 操作 | 前两次 A/B（ms） | 暖中位数（ms） | 像素核验 |
| --- | ---: | ---: | --- |
| 交换两张强度 100% 的 2³ LUT | 22.480 / 20.795 | 20.408 | 两个次序产生两个不同整帧哈希，各自重复三次完全一致 |
| 同一径向蒙版内曝光 +0.25 / +0.75 EV | 21.400 / 21.070 | 21.355 | 两组全帧及内圈 416 个样点有别，外圈 1,640 个样点在六次读回中均一致 |

以上验证了串行滤镜顺序、多支路合成、缓存复用和局部作用域。换机型、改工作色域、在 RAWMaster 执行 AI 推理、Linux 服务端吞吐和跨引擎像素兼容，都需要各自的实测。此处径向蒙版的测量只覆盖渐变区域的调色，未载入 AI 权重。[已有 AI 蒙版验证范围](../026-mask-ai-native/spec.md) · [既有大图与交互观察](../024-jpeg-display-proxy/lightflow-rea.md)

## 复核

从仓库根目录运行。`CHROME` 指定本机支持 WebGPU 的 Chromium 可执行文件，`RAW` 指定测试原片。本次 RAW SHA-256 为 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`。菱形图探针需要 Node 22+ 和支持 `Float16Array` 的浏览器，内置图样可独立复演。原片复演的 JSON 输出文件名需要尚未存在。[发布文件清单](evidence/lightflow-release.json) · [原片基准实现](../../scripts/performance/benchmark-lightflow.py)

```sh
SPEC=specs/035-portable-processing-cores/evidence
SNAP=output/035-processing/lightflow-replay
python3 "$SPEC/lightflow-fetch.py" "$SNAP"
ENGINE="$SNAP/site/_b/20261111155800-2d41ab1/rust/web"
node "$SPEC/lightflow-graph.mjs" "$ENGINE" "$CHROME"
python3 scripts/performance/benchmark-lightflow.py --engine "$ENGINE" --chrome "$CHROME" \
  --raw "$RAW" --paired-photo-operators --samples 4 \
  --operation grading-lut-manage --operation light-mask-exposure \
  --output "$SNAP/recipe-observations.json"
```
