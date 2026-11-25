# GPU 渲染 Pipeline 与编辑 DAG 的三份参考实现

2026-11-25。为把 RAWMaster 的显影链路拉到 LightFlow / Camera Raw 的响应水位，定向复查了三份实现：AlcedoStudio 与 FlashRaw 的源码（浅克隆到 `output/research/perf-refs/`），以及 LightFlow 发布包的既有镜像与论文级取证（`output/035-processing/lightflow/`，见 [035 取证](../..//specs/035-portable-processing-cores/lightflow.md)）。

本文只记与**渲染分辨率、执行计划、节点缓存、调度**有关的事实。色彩科学、模型质量与 UI 不在范围内。每节末尾的「RAWMaster 现状」是本次要改的地方。

## 0. 复核方式

```sh
mkdir -p output/research/perf-refs && cd output/research/perf-refs
git clone --depth 1 https://github.com/zidage/AlcedoStudio alcedo    # 68a2c2356825c5b4d5187f6e668b09c9f731aa75
git clone --depth 1 https://github.com/ybouane/flashraw flashraw    # bee2ca1a2a9f4e044fddd37616a244bb1f370789
```

LightFlow 用既有发布镜像 `output/035-processing/lightflow/site/`（构建 `20261111155800-2d41ab1`，65 个同源资源，逐字节校验见 [035 下载清单](../../specs/035-portable-processing-cores/evidence/lightflow-release.json)）。本轮 REA 复核见第 7 节。`output/` 被 git 忽略，克隆与镜像不入库。

---

## 1. 三份实现的共同结构

三者用不同的语言和 GPU API，但把一次编辑变成最终像素的流程是同构的：

```
配方 (recipe / PhotoEdit / PipelineDocument)
   │
   ├─ ① 编译静态计划 ─────── 只看拓扑、源布局、后端能力   ← 参数与视口不参与
   │      → 计划键 (StaticPlanKey / EditKey)
   │      → 段列表 (segments / GpuPassKind[])
   │
   ├─ ② 绑定本帧参数 ─────── 视口、ROI、裁切、CCT、控件值  ← 不重编译
   │      → 参数缓冲写入 (parameter arena / uniform)
   │      → 每帧内容键 (ContentKey / editKey)
   │
   ├─ ③ 查节点缓存 ──────── 按 (节点, 端口) + 修订/内容键
   │      → 命中：复用已发布的 GPU 纹理
   │      → 未命中：只重算该节点及其下游
   │
   └─ ④ 提交设备工作 ────── 点运算融合成少数 compute pass
          → 目标 = 有界长边（2400 / 2560 / 4096），不是原图像素
          → 完成后 fence 才发布；过期结果整体丢弃
```

**三者的预览都在整幅上渲染，只是把目标长边压到远小于原图。** 只有进入深度缩放时才切成可见 ROI。这是与本项目改动前实现的主要结构差异（改动前是整幅原生）。

---

## 2. LightFlow（FlashRaw 作者的另一款产品，WebGPU）

镜像：`_b/20261111155800-2d41ab1/rust/web/lightflow_host_wasm.js`（引擎接口）与 `assets/worker-PmnZFHwu.js`（帧循环）。

### 2.1 引擎接口直接带视口与目标

| 接口 | 关键字段 | 说明 |
| --- | --- | --- |
| `render(id, edit_json, target_json, options_json)` | 返回 `{ handle, width, height, rect, offset, pxPerUnit, segments, cached, provisional, pending }` | `target` 是显式的 RenderTarget；输出纹理留在 GPU 直到 `release(handle)` |
| `viewerFrame(id, source, inputs, edit, before, before_source)` | `edit` **只在 `inputs.editKey` 变化时传入**，否则传 `""` | 缩放/平移走 `inputs`，不重发配方 |
| `viewerTick` / `viewerDone` / `idle()` | 每个 viewer 同时在途最多一帧 | `idle()` 回调清在途标记后才 `viewerDone` |
| `compileDemanded(max)` → `compileQueued(max)` | 每 tick 先 `compileDemanded(4)`，再空闲预热 | 需求优先编译，空闲才预热 |
| `bitmapBegin` / `bitmapBand` / `bitmapFinish` | 分带上传 + 一次线性化/色彩/方向转换 | 上传不产生整帧中间图 |
| `commitSource(id)` | 「every row of **every level** written」 | 源是**多级（mip）驻留**，任意视口尺度都从合适层级取样 |
| `exportBegin` / `exportTile` | 默认 1024 px 瓦片，按行取带 | 整条带完成才交编码器 |

`render` 返回的 `segments` 与 `cached` 是引擎自报的执行段数与缓存命中数。实测（128×128 合成的双支路菱形图，见 [035 复演](../../specs/035-portable-processing-cores/lightflow.md#本轮-gpu-复演)）：

| 请求顺序 | segments | cached |
| --- | ---: | ---: |
| 单独 A | 3 | 0 |
| 单独 B | 2 | 1 |
| A→端口0, B→端口1 | 1 | 3 |
| B→端口0, A→端口1 | 1 | 3 |
| 恢复 A→0, B→1 | **0** | 3 |

最后一行是全篇最重要的数据：配方与端口顺序回到已知状态时，引擎报告 **0 个新执行段**，整帧直接来自缓存。真实 RAW 上 LUT 交换与径向蒙版曝光的暖中位数为 20.4 / 21.4 ms（2400×1600 全幅含读回）。

### 2.2 RAWMaster 现状

- `PreviewViewport.maxPixel` 只进缓存键与最终 FIT，`DevelopmentRendererV3.develop` 全程按原生 60 MP 构图。
- 没有段/节点缓存：`cacheIntermediates: false` 且每次渲染前后 `clearCaches()`。
- 配方每次都重新解析并重建整棵 `CIImage` 树。
- 好消息：已有的 `FlashRawCanonicalTexturePool` 等价于 LightFlow 的「源驻留」，只是没有多级。

---

## 3. AlcedoStudio（C++/Metal/CUDA/OpenCL + QML）

源码：`output/research/perf-refs/alcedo/alcedo_studio/`。

### 3.1 编译计划与参数绑定分离

`src/include/edit/runtime/graph_compiler.hpp`：

> The static plan key covers graph topology, adjustment types and order, source layout, and backend capability version. … **Viewport, crop, CCT, Grade values, and DRT values are bound per frame and do not recompile the static pass list.**

`static_execution_plan_cache.hpp` 按 `StaticPlanKey` 缓存整份 `ExecutionPlan`；命中返回副本，随后 `BindFrameGeometry(plan, document, request)` 只改几何，不动段列表。`NeedsRecompile` 只比较拓扑、源布局、后端能力。

### 3.2 段（pass）是少数几个具名 GPU 项

`src/include/edit/runtime/pass_kind.hpp` 的 `GpuPassKind` 只有 16 项：
`UploadRaw, UploadRgb, Linearize, CfaClamp, Demosaic, HighlightRecover, InverseCamMulPack, Lens, GeometryResample, CameraToAp1, MaskEvaluate, PrimaryColorGrade, Drt, MaskUnion, DiffusionFilter, DisplayToAp1`。

即整条「解码 → 去马赛克 → 镜头 → 几何 → 相机色彩 → 蒙版 → 调色 → 显示变换」被压到十余个设备提交，而不是每个控件一个 pass。

### 3.3 两级缓存

| 层 | 类型 | 键 | 位置 |
| --- | --- | --- | --- |
| 图像结果 | `GraphImageCache` | `GraphValueId`（节点+端口）+ `RuntimeRevision` + `ResultRepresentation` | `edit/runtime/graph_image_cache.hpp` |
| 非图像结果 | `NodeResultCache` | 同上，用于 LLF 平面等 buffer | `edit/runtime/node_result_cache.hpp` |
| 内容身份 | `ContentKey` | FNV-1a 混入输入值与**实现版本常量** | `edit/runtime/content_key.hpp` |

`content_key.hpp` 的关键设计：实现版本是显式常量，改像素规则必须提版本。

```cpp
inline constexpr std::uint32_t kSensorDevelopImplementationVersion = 2;
inline constexpr std::uint32_t kCameraColorImplementationVersion   = 5;
inline constexpr std::uint32_t kPrimaryGradeImplementationVersion  = 7;
```

`result_content_key.hpp` 的 `FrameResultContentKeys` 把一帧拆成若干段键：
`sensor_linear, geometry_scene_source, develop_image, primary_grade, drt_display, mask, film_uv_table, film_print_table`。
改一个 Grade 只让 `primary_grade` 及其下游失效，`sensor_linear`、`develop_image` 继续命中。这正是 RAWMaster 缺的粒度。

### 3.4 渲染意图（RenderType）与解码分辨率（DecodeRes）

`renderer/pipeline_scheduler.cpp`：

```cpp
constexpr int kFastPreviewMaxLongEdge    = 2560;
constexpr int kFullResPreviewMaxLongEdge = 8192;

enum class RenderType { FAST_PREVIEW, QUALITY_BASE_PREVIEW, DETAIL_ROI_PREVIEW,
                        FULL_RES_PREVIEW, FULL_RES_EXPORT, THUMBNAIL };
enum class DecodeRes  { FULL, HALF, QUARTER, EIGHTH };
```

- `FAST_PREVIEW`：**整帧**，目标长边 **2560**。
- `QUALITY_BASE_PREVIEW`（松手定稿）：**整帧**，目标长边 **4096**，`source_roi_norm = {}`、`DecodeRes::FULL`、`ResultPersistenceScope::SensorDevelopOnly`（只保留传感器结果）。见 `include/edit/runtime/pipeline_apply_request.hpp:67,84-93`。
- `DETAIL_ROI_PREVIEW`：目标长边 = **视口目标尺寸**，只渲染可见 ROI；`use_viewport_region_` 只在 `quality == Detail` 或 `reason == ScopeRefresh` 时为真（`editor_session_render_scheduler_port.cpp:106`）。
- `FULL_RES_PREVIEW`：整帧 8192；`FULL_RES_EXPORT`：`max_edge = 0`（不缩）。
- `DecodeRes` 让解码本身可降到 1/2、1/4、1/8 像素。

zoom 跨过 1.0 才切 Detail：`emitViewChange(zoom() > 1.0f + 1.0e-4f ? .DetailRefresh : …)`（`ui/editor_rhi/editor_interaction_controller.cpp:61`）。`ViewportMapper::ComputeViewportRenderRegion`（`ui/edit_viewer/viewport_mapper.cpp:132-210`）把 widget 尺寸 + dpr + zoom + pan 变成 `{x, y, scale_x, scale_y, reference_w/h, target_w/h}`，随每帧请求下发。

即：**松手定稿仍在整幅上算，只是长边压到 4096；只有深度缩放才切成 ROI。**

### 3.5 调度

- 单一 `PipelineScheduler` 线程池 + 每 sink 的 `request_id` 单调号；`IsStaleForSink` 丢弃迟到的旧请求（`pipeline_scheduler.cpp:220`）。
- `thread_pool_(1)`：默认一条渲染线程，交互帧串行，不互相争 GPU。
- `preview_performance.hpp`：诊断热路径只在 Off 时做一次 relaxed 原子读，不分配字符串、不写文件。

### 3.6 RAWMaster 现状

- 有 `PreviewQuality { interactive, settled, detail }`，但没有把分辨率意图带进 DAG。
- `settled` 恒为原生全尺寸，`detail` 也是原生全尺寸（不是 ROI）。
- 没有静态计划缓存，也没有按节点/端口的结果缓存。
- 已有的 `ImagePerformanceTelemetry` 与 `PreviewStatistics` 等价于 Alcedo 的诊断层。

---

## 4. FlashRaw（Rust，解码层）

源码：`output/research/perf-refs/flashraw/`；本项目通过 `Sources/CFlashRaw/` 链接 0.3.1 的 C ABI。

### 4.1 单趟融合解码

README 明确：**「To produce an sRGB image FlashRaw develops in one fused pass (demosaic, white balance, colour matrix and sRGB encoding per pixel, straight into the output), so it never holds the full-size intermediate images of a classic pipeline.」**
拆成三步的传统管线要多出 16-bit 工作图、16-bit RGB 副本和 8-bit 输出；FlashRaw 只保留源与输出。

声称的中位数（62 台机身，同机同文件）：对 LibRaw `dcraw_process()` 快 11.8×（Linux）/ 22.1×（macOS），内存少 1.8×/1.5×；Metal GPU 路线快 25.3×。

### 4.2 C ABI 里已经可用的「少算」开关

`Sources/CFlashRaw/include/flashraw.h` 的 `flashraw_decode_options`：

| 字段 | 含义 | 本项目是否已用 |
| --- | --- | --- |
| `max_dimension` | 输出最大宽或高（0 = 打开上限） | **否** |
| `max_samples` | 最大样本数 | 否 |
| `threads` | 0 = 全核 | 默认 |
| `use_region` + `region` | 只解指定矩形（sensor 坐标） | 是（`rm_flashraw_decode` 已透出） |
| `demosaic = FLASHRAW_DEMOSAIC_HALF_SIZE` | 2×2 超像素合并，**半分辨率，最快** | 否（生产固定 bilinear） |
| `output = FLASHRAW_OUTPUT_LINEAR_RGB_F16` | 半浮点线性 RGB，内存减半 | 是 |
| `exposure` / `black_point` / `white_point` | 解码阶段就套线性曝光与黑白点 | 否（在 CI 里做） |
| `preview_fallback` | 解不了时回退内嵌全尺寸预览 | 否 |

`max_dimension` 与 `HALF_SIZE` 是 Alcedo `DecodeRes` 的等价物，当前完全没用。
`exposure` 放在解码里有额外价值：RAWMaster 现在的原生曝光已经走 `CIRAWFilter`/FlashRaw 输入调整，但 `FlashRawImageFactory.applyInputAdjustments` 之后仍是 CI 点运算；把纯曝光的拖动留在解码端可少一趟 60 MP 读写。

### 4.3 DAG 概念

FlashRaw 是解码库，没有编辑 DAG。它只提供 `source → linear RGB` 这一段，以及 preview/tile 两种取数方式。RAWMaster 的 `DevelopmentRendererV3` 承接其后全部算子。

---

## 5. 对照表：差异与收益

| # | 手法 | LightFlow | Alcedo | RAWMaster 改动前 | 实测 / 结论 |
| --- | --- | --- | --- | --- | --- |
| 1 | 整幅渲染，目标长边压到远小于原图 | 整帧 2400 | 整帧 ≤2560 / ≤4096 | 整帧原生 60 MP，末端 FIT | **50 个配方定稿中位 255 → 6.8 ms**（已落地） |
| 2 | 1:1 只渲染可见 ROI | `rect`/`offset` | `DETAIL_ROI_PREVIEW`（zoom > 1 才切） | 整幅原生 60 MP | **中位 2.62×**（传输层已实现，画布待接） |
| 3 | 解码端降分辨率 | 多级源 | `DecodeRes` | 仅全尺寸 | **FlashRaw 0.3.1 没有此开关**：`max_dimension` 是安全上限，`HALF_SIZE` 只减尺寸不减时间。唯一剩下的是区域解码 |
| 4 | 静态计划缓存 | `editKey` 门控 | `StaticExecutionPlanCache` | 每帧重建 | 待做 |
| 5 | 按节点结果缓存 | `segments`/`cached` | `GraphImageCache` + `Revision` | `cacheIntermediates:false` + 每帧 `clearCaches` | 待做 |
| 6 | 点运算融合 | 融合程序 | 16 个 `GpuPassKind` | 每控件一棵 CI 树 | 不做（CI 已融合点运算） |
| 7 | 需求优先编译 + 空闲预热 | `compileDemanded` | — | `ImageEnginePrewarming`（仅启动） | 待做 |
| 8 | 瓦片/分带 + halo | `exportTile` 1024 | `pass_encoder` | 分带已用于锐化/去雾/半幅 | 已扩展到通用原生扫描 |
| 9 | 单帧在途 + 过期丢弃 | `viewerTick` | `IsStaleForSink` | 已有 | — |

---

## 6. 本轮采用的取舍

1. **#1 已落地**：定稿帧改为整幅按 2400 目标求值，交互与定稿共用同一计划与缓存键。50 个控件配方的定稿中位 255.47 → 6.81 ms、P95 842.57 → 20.24 ms。
2. **#2 传输层已实现**：请求可带归一化窗口，`detail` 只物化可见那块。50 个配方实测 1:1 中位 191.8 → 73.1 ms（2.62×），点运算档 4.2–4.9×，邻域档 1.1–1.2×（邻域归约仍在整幅）。画布接线需要新的绘制与平移路径，待真实窗口走查。[规格](../../specs/036-render-pipeline-performance/spec.md#11-可见窗口传输层已实现画布待接)
3. **#8 已扩展**：通用原生有限值扫描接到分带归约，1:1 快 12–46%，输出逐字节不变。
4. **#6 不做**：Core Image 已在单个 kernel 内融合点运算，自研融合要重写全部算子，收益与风险不匹配。
5. **像素契约不变**：导出、保存、1:1 详细视图继续走原生全尺寸与既有有限值证明。定稿预览明确标记为近似，并在帧上报告尺度，和 Alcedo 的 `FAST_PREVIEW`、LightFlow 的 `provisional` 同义。

---

## 7. 本轮 REA 复核（2026-11-25）

用 REA `analyze_javascript_application` 对既有发布镜像整目录重建应用图（43 个 JS 文件、2,980,705 字节、670,783 个 AST 节点），再按符号取函数节点与其精确源码区间。结果落在 [lightflow-rea-symbols.json](../../specs/036-render-pipeline-performance/evidence/lightflow-rea-symbols.json)，每项带模块路径、该模块的 SHA-256 与起止行列。

覆盖到的 21 个引擎方法印证了第 2 节的接口分工：`render`／`renderForExport`、`viewerFrame`／`viewerTick`／`viewerDone`／`viewerInvalidate`、`compileDemanded`／`compileQueued`／`compileLog`／`warmStep`、`bitmapBegin`／`bitmapBand`／`bitmapFinish`／`commitSource`／`dropSource`、`exportBegin`／`exportTile`／`exportEnd`、`copyHandle`／`readTicket`／`release`、`scopeAccumulate`。

**新发现：**镜像里还有一份此前 035 未覆盖的多线程引擎绑定 `_b/20261111155800-2d41ab1/rust/web-mt/lightflow_host_wasm_mt.js`（SHA-256 `4ba8bdddca77d75c12d57f9822cfa854dd602c696c98ba0375f9ff9b8d89461d`）。它导出同一套方法名，说明 LightFlow 把「同一 DAG／段缓存契约」同时编译到单线程与多线程宿主，而不是为两者各写一套调度。这对本项目的启示是：渲染意图与段缓存的契约应当与执行线程数解耦。

**限制：**WABT 未配置，本轮没有对像素 WASM 做 WAT 级验证；内部 Rust 类型与完整调度算法仍未知。035 已有的 WABT 1.0.42 导出核对见[取证记录](../../specs/035-portable-processing-cores/evidence/lightflow-locations.json)。REA 的图覆盖不完整（`entry.client` 因堆耗尽未解析，HTML 内联脚本未解析），不能把缺失读作不存在。
