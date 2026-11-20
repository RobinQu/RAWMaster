# Lightflow REA 与 FlashRaw 原生演进研究

## 范围与证据等级

目标是解释 Lightflow 在浏览、缩放和编辑中的速度来源，并据此确定 FlashRaw 与 RAWMaster 的技术演进顺序。本报告不包含生产代码改动。

分析对象为 `https://lightflow.dev/` 在 2026-11-20 返回的构建 `2d41ab1 · 2026-11-11`。REA 只静态读取下载的发布产物；浏览器实测使用同一张 Sony ILCE-7RM5 RAW（9504 × 6336，SHA-256 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`）。

| 产物 | SHA-256 |
| --- | --- |
| 编辑器 `index-zP4kU_H7.js` | `0ca67eaec7788ac79439d6700c6791cff845bbb8938d6b2d295831871afc678e` |
| 图像 Worker `worker-PmnZFHwu.js` | `1c1203c0e3d6e4329d9ac2892b61fc4e3fca4e805c73b919ab17f72cf240d2fc` |
| 像素引擎 JS glue | `abfbf794fd93d16630a9a4427b73ae1ee0d6a370f5ecd496a00c0ea261aee055` |
| 像素引擎 WASM | `bf00cd83e6ef03014878f83dc235dcf46f7e408c052cef48240a764268227674` |

REA 证据：

- 应用包：`ev_95aa6154a536ea4340f4e9eb53b10aed6913eb1d1e4f784b82d3d322e3b15ce8`。
- 图像 Worker：`ev_64089236eb2d16d7253d6339c4a3d3cd4c3ad6182e501c9c6516f69b6b949ad3`。
- 像素引擎 JS 接口：`ev_4a81938dba394ab5287c52f9b8093d8d273a2d7c56338a023d721325c0276dc3`。
- 完整 WASM 的 WABT 验证／WAT：`ev_15af35026d2bf80b94d255b0e68afed05e3af9bd76f5bd4b3f14630c543bfea3`。WAT 文本 SHA-256 为 `14344f25416ed6ce19d15823eb688a3f4cb70eea28fc85b9cbeea155ed44ab72`；完整 REA 报告 SHA-256 为 `5d0890fc04c3237222423b5289c3a3b9f204650f1768739d27c2c4a14cf06873`。

WABT 1.0.42 使用官方 macOS arm64 发布包，并通过其 SHA-256 文件校验。WASM 验证结果为 `valid`，有 134 个导出。发布包没有 debug name section，因此内部函数没有可靠原名；本报告不把数字 WAT 调用栈当作原始 Rust 源码。WASM 中保留了 WGSL、部分 Rust 路径和诊断文本，可用来证实渲染结构，但不能据此声称已恢复全部实现。

## 总结论

Lightflow 的核心不是“每个操作都调用一次快速 FlashRaw RGBA 解码”，而是：

```text
FlashRaw Worker：RAW → normalized f16 CFA，只在需要源数据时执行
                         ↓
Lightflow Rust／WebGPU：自有去马赛克、颜色、镜头与高光处理
                         ↓
RGBA16F 源图／分级纹理 + 渲染缓存 + 原生细节瓦片
                         ↓
视图变换与编辑配方分离；按帧决定是否需要绘制；GPU 完成后结算
```

因此 RAWMaster 应优先吸收其**数据生命周期、帧调度、纹理呈现和缓存设计**。FlashRaw 的完整 RGB 显影仍只作为独立代理候选，不能替代当前 Core Image 兼容性基线。

## FlashRaw 在 Lightflow 中的实际职责

### 输入格式

Worker 的 `decodeSensor` 请求：

```js
{ output: "normalized", sampleType: "f16" }
```

即黑电平扣除、白电平归一化后的 CFA 传感器数据，而不是已去马赛克 RGB。旧版本不支持 `sampleType` 时才回退到 F32。返回缓冲区有显式 `release()`，并校验通道数、样本数和文件损坏警告。

FlashRaw 使用 Worker 池；跨源隔离时启用线程。应用设置允许关闭 RAW 多线程。池有 12 秒空闲回收策略，避免每张照片重建 Worker／WASM。

### 草稿、全尺寸与传感器复用

源缓存条目区分 draft 和 full：

1. 首次可先执行 `quality: "preview"` 并保留传感器结果。
2. 需要 full 时复用已保留的 RAW 元数据／传感器，不重复 FlashRaw 熵解码。
3. `openRawSensor` 把传感器送入 Lightflow 自己的像素引擎。
4. 预取只请求 draft；切换照片、源缓存淘汰和设备丢失均有显式路径。

这解释了“编辑操作快”与“首次打开快”必须分开测量：前者通常不触碰 FlashRaw，后者才包含解码。

## Lightflow 自有显影与 WGSL 证据

发布 WASM 中包含 `crates/lightflow-source/src/raw/develop.rs`、`raw/plan.rs`、`raw/lens.rs` 及多个 `lightflow-render` 模块路径。恢复出的 WGSL 片段证明其自有实现覆盖：

- CFA 周期、传感器区域与边界 fold；
- 双线性、方向统计、绿色插值、RCD 等去马赛克内核；
- 白平衡、颜色矩阵、EXIF 方向；
- 镜头 warp／gain 与高光修复；
- RGBA16F／RGBA32F 中间纹理；
- 按 2 × 2 或其他比例生成分级源图；
- 对区域、瓦片和整图采样一致性的专门处理。

这意味着 Lightflow 并未受限于 FlashRaw 当前的 RGB 输出选项。它把 FlashRaw 当作传感器解码器，而不是完整编辑器。

恢复片段位于 `output/lightflow-research/wgsl/`；它们是发布 WASM 中的文本片段，不是原始源码仓库文件，也不保证模板展开后的完整编译单元。

## 编辑帧与着色器调度

### 视图与配方分离

`viewerFrame` 接收 `FrameInputs`，其中包含缩放、中心、显示尺寸和比较状态。配方 JSON 只在 `editSeq` 改变时发送；纯缩放继续复用引擎已有配方。

这与 RAWMaster 当前需要继续保持的约束一致：视图变化不得使源图、原生代理或配方缓存失效。

### 按需绘制

Worker 每帧执行：

1. `compileDemanded(4)`，优先满足当前帧等待的程序；
2. 空闲预热一步；
3. `viewerTick`，返回是否需要绘制及 busy 位；
4. 仅在需要时执行 `viewerFrame`；
5. `engine.idle()` 后记录完成并调用 `viewerDone`。

没有输入变化时，rAF 循环可以运行，但不会重复生成图像帧。

### 融合程序与预热

JS 接口明确提到 provisional frame 的 fused programs。`warmStart` 会把各控制可能需要的程序排队，`warmStep` 在空闲时一次编译一个。调度器在交互结束后等待，再按实际编译耗时设置 20–500 ms 的下一步间隔；有在途 GPU 帧或 busy 状态时不预热。

因此首次使用某控制仍可能出现冷编译，不能把暖路径成绩外推到所有首次操作。

## 缩放、重呈现与原生瓦片

- 预览帧报告包含 `rung`、`tiles`、`detailPpu`、`provisional`、`need` 和 `full` 等字段，表明显示按分级和细节瓦片组织。
- `viewerRepresent` 可在窗口尺寸改变时重呈现已有帧；只有没有已绘制内容或缓存层已被淘汰时才失败。
- 100% 查看按当前区域补原生细节，而不是每次手势重解码完整 RAW。
- 呈现 WGSL 同时引用预览纹理和细节纹理，并有 before／compare 的独立细节层。

## 导出策略

`exportBegin` 返回任务和瓦片坐标；`exportTile` 逐块渲染并回读 RGBA16F 或 RGBA32F。首个瓦片前需要等待 guide render 完成。WGSL 注释明确要求区域、瓦片和整图在像素网格上保持一致，避免双线性舍入造成接缝。

这与 RAWMaster 的 canonical 输出原则一致：交互近似可以分层，但保存／导出必须走同一验证过的最终图，不能直接把屏幕 JPEG 当作成片。

## 浏览器运行时实测

### 方法与边界

使用内嵌 Chromium、WebGPU Metal 后端，通过 Lightflow 的公开调试接口导入上述 RAW。缩放和编辑使用状态接口，不是物理鼠标拖拽。记录 viewer 指标到达及 `frames.onFrame` 的 GPU-idle 事件；不是 WindowServer 等价的 input-to-photon 测量，也不是与 Camera Raw 的同画布基准。

完整数据：`output/lightflow-research/runtime-summary.json`。

| 操作 | 指标到达 | Rust 帧编码字段 | 帧完成事件 |
| --- | ---: | ---: | ---: |
| 首次 100% | 7.2 ms | 3.7 ms | 165.6 ms |
| 后续 100% | 8.6 ms | 0.8 ms | 11.7 ms |
| Fit／200% 各次 | 1.2–7.2 ms | 0.3–0.6 ms | 3.5–8.0 ms |
| 曝光 4 次 | 5.2–10.8 ms | 1.3–2.7 ms | 6.8–12.7 ms |
| 暖 Texture／Clarity／Dehaze | 2.2–9.6 ms | 0.5–1.6 ms | 3.5–15.0 ms |

首次 UI 驱动的细节调整出现了多秒冷等待；该次不作为合格的操作耗时样本，但证明首次编译不能省略验收。

### 资源观测

测试后引擎报告：94 个管线、约 1.0 GiB 池驻留、约 332 MiB 渲染缓存、约 65 MiB guide 数据。渲染缓存预算为 1 GiB。源列表另有 2.5 GiB 的默认预算，并在回收时降到约 80%。

这些数值是当前样本和操作序列的观测，不是 Lightflow 对所有设备的固定内存占用。

## FlashRaw 原生输出复测

使用正式 C ABI、同一进程内重复解码，3 张 Sony RAW，每个输出 7 次，暖中位数排除第一次。完整报告：`output/performance/flashraw-native-outputs-20261120/summary.json`。

| 后端与输出 | 暖墙钟中位数 | 3 个独立进程的最大 RSS |
| --- | ---: | ---: |
| SIMD raw-u16 CFA | 23.4 ms | 204.9 MiB |
| SIMD normalized F32 CFA | 34.6 ms | 450.5 MiB |
| SIMD linear RGB F16 | 45.6 ms | 548.9 MiB |
| Metal linear RGB F16 | 38.8 ms | 1138.9 MiB |
| SIMD RGBA8 | 50.0 ms | 433.5 MiB |
| Metal RGBA8 | 36.4 ms | 794.5 MiB |

注意：macOS `getrusage` 的 RSS 原始单位是字节，报告已从字节转换为 MiB。不同输出不能只看 GPU 名称；F32／F16 全尺寸输出的内存尤其高。

### 区域解码

在 01.ARW 的传感器坐标 `(4000,3000)` 解码方形区域，暖句柄结果：

| 输出 | 512 × 512 | 1024 × 1024 | 2048 × 2048 |
| --- | ---: | ---: | ---: |
| SIMD raw-u16 | 2.0 ms | 2.0 ms | 3.6 ms |
| SIMD normalized F32 | 1.6 ms | 1.9 ms | 4.1 ms |
| Metal RGBA8 | 2.2 ms | 2.6 ms | 5.5 ms |

这些只包含 FlashRaw 解码，不包含 RAWMaster 几何、后续 GPU 调整、呈现或导出。它们证明区域解码值得优先试验，但不等于端到端帧耗时。

## 原生集成仍缺少的能力

### C ABI 与颜色契约

- C ABI 当前只返回主机 frame，不暴露 Rust 的 GPU-resident 输出。
- GPU-resident 的零拷贝互操作要求与调用方共享同一个 wgpu device。wgpu 的 Metal HAL 虽有原生句柄，但这不是当前 FlashRaw C ABI 的稳定 Swift／Metal 接口。
- C ABI 的 raw 输出不会隐式裁切；使用 CFA 输入时必须显式处理 active area、推荐 crop、origin 和 EXIF 方向。
- FlashRaw 线性输出保持传感器方向，与当前 `CIRAWFilter` 的已定向输出不同。
- 当前没有 C ABI 取消接口。后台任务只能在文件／区域边界合作取消，不能假定进行中的同步 decode 可被立即中止。

### 自定义白平衡与后端选择

`gpu.rs` 当前把自定义 RGB multipliers、Daylight 和 Auto WB 排除在 GPU RGB 路径之外。自定义乘数和 Daylight 的显影计算可前置到 plan，属于相对集中的上游改进；Auto WB 还包含图像分析，不能与前者等同估计工作量。

### F16 与零拷贝不应成为第一步障碍

当前 raw-u16 已是最快、最小主机输出。第一版 CFA 实验可以直接上传 u16，在 Metal 中归一化，避免等待上游增加 normalized-f16。若以后证明 Worker／主机传输仍是瓶颈，再评估 F16 和 GPU-resident ABI。

## 建议的 FlashRaw 演进顺序

### 阶段 0：先修呈现与测量，不改变显影

- 用 Metal 纹理呈现层承载当前预览，缩放／平移只更新变换。
- 保留当前 Core Image canonical 和线性代理语义。
- 同时记录输入事件、draw return、GPU 完成与 WindowServer 可观测呈现，避免只看 API 返回。
- 为每个自定义 Metal／CIKernel 记录首次编译和暖编译。

### 阶段 1：FlashRaw Metal 只用于独立显示代理

- 通过 C ABI 使用 RGBA8 Metal，保留 JPEG 作为可丢弃磁盘缓存。
- 明确标记近似颜色，失败回退 Core Image；不得进入最终显影。
- 每张照片最多一个完整在途 decode，按内存预算限制后台并发。

### 阶段 2：原生 ROI 与纹理缓存

- 利用现有 region decode，不等待新 ABI。
- 先服务 100%／局部查看；当前小尺寸线性代理继续负责正常编辑。
- 区域坐标、方向、裁切、配方版本和源内容身份必须进入瓦片键。
- 瓦片只在缓存未命中且 ROI 稳定时生成，连续缩放只采样现有纹理。

### 阶段 3：隔离的 CFA／Metal 显影实验

```text
FlashRaw raw-u16／normalized
  → Metal 归一化与 CFA 纹理
  → 自有去马赛克、白平衡、颜色矩阵
  → 线性 RGBA 代理
  → 现有调整后缀与 Metal presenter
```

- 初版优先保留当前 F32 精度与扩展线性 sRGB 契约，再单独评估 RGBA16F。
- 逐相机验证 CFA、active crop、白平衡、颜色、镜头、超色域、HDR、损坏文件和错误语义。
- 未完成前不得替换保存、导出或 settled canonical。

### 阶段 4：仅把真实瓶颈带回上游

优先级建议：

1. 异步取消与更细的进度／资源统计；
2. 自定义 WB／Daylight 的 GPU 路径（若仍使用完整 FlashRaw 显影）；
3. normalized-f16 或其他减少主机传输的输出；
4. 只有在证明零拷贝收益覆盖桥接复杂度后，才设计 GPU-resident C ABI。

## 内存策略不能照搬

9504 × 6336 原生 RGBA16F level 0 约 459 MiB，完整 4/3 金字塔约 613 MiB；当前 2400 × 1600 RGBAf 代理约 59 MiB。Lightflow 式全尺寸金字塔若直接常驻，会显著超过现有交互代理预算。

RAWMaster 应采用“小代理常驻＋当前 ROI 瓦片＋明确高／低水位”，而不是默认保留整库全尺寸金字塔。当前照片、相邻照片、后台预取和已淘汰冷数据仍需遵守前述工作集策略。

## 许可与再利用

FlashRaw 为 MIT／Apache-2.0。Lightflow 的发布许可页声明 Apache-2.0；第三方组件仍需按应用内 notices 逐项核对。[Lightflow 许可](https://lightflow.dev/license)。

本次没有取得其原始源码仓库。即使许可允许再利用，也应保留版权与许可通知，并把恢复出的 WGSL 与原始源码、独立推导和自有实现区分管理。

## 仍未验证的边界

- 竖拍、镜像、非 Bayer、四通道 CFA、DNG opcode 组合尚未做本轮运行时实测。
- 未做物理连续拖拽的输入到屏幕测量，也未完成与 Camera Raw 的同画布、同参数统计基准。
- 未测量 FlashRaw 到 Metal 的纹理上传、后续调整和呈现总成本。
- 未验证自有 Metal 去马赛克与 Core Image 的像素兼容性。
- 未验证大资料库下 Lightflow 源预算与 RAWMaster 预算的直接可比性。

这些边界应进入实施验收，而不是用当前样本的毫秒数外推。
