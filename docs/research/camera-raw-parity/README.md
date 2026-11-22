# Camera Raw × RawMaster 功能一致性报告

这是九个图像编辑面板的长期维护基线。正式阅读入口是 `index.html`；唯一内容事实源是 `feature-matrix.json`，不要只修改生成后的 HTML。

## 更新流程

1. **更新 Camera Raw 基线**：检查 Adobe 官方手册、当前 Release Notes 和必要的实机界面。证据不足的项目先加入 `verificationBacklog`，不要直接计为确定缺口。
2. **更新 RawMaster 实现**：按稳定功能 ID 修改 `status`、`rawMaster`、`difference`、`codeRefs`、`priority` 和 `acceptance`。新增功能使用新的语义化 ID，不复用旧 ID。
3. **保留证据**：每个对照项必须有 Adobe 官方来源和 RawMaster 代码位置。代码移动后同步更新行号；自有扩展放入 `rawMasterExtras`，不进入对齐统计。
4. **重新生成并校验**：

   ```bash
   python3 docs/research/camera-raw-parity/build_report.py
   python3 docs/research/camera-raw-parity/build_report.py --check
   ```

`--check` 会验证数据、来源、图片、代码文件及行号，并在 HTML 与 JSON 不一致时失败，适合纳入研发 CI 或提交前检查。

## 状态口径

- `aligned` / 已具备：主要界面、配方或渲染链路存在；**不表示 Adobe 算法或像素结果等价**。
- `partial` / 部分一致：已有可用入口，但子参数、模式、局部能力或关键交互不完整。
- `different` / 有差异：存在明确的范围、单位、色域、面板归属或处理语义差异。
- `missing` / 缺失：当前面板、配方和渲染链路均无对应能力。

## 完成验收

功能从非 `aligned` 状态改为 `aligned` 前，至少应验证：实时预览、配方保存与重开、撤销/重做、导出、源类型能力回退，以及对应自动化测试。若研发目标还包括视觉一致性，需另建固定 RAW/JPEG 样本、Camera Raw 参考输出、统一色彩管理、数值映射与容差；本报告不替代该像素级门禁。

## 研发计划维护

`developmentPlan` 保存全量补全的工作分解、依赖、人周估算、阶段路线、风险和关闭门禁。工作量按 WP0–WP8 工作流估算，不按控件逐个重复计算；修改任一工作流的 `weeks` 时，必须同步更新 `estimate.personWeeks`，构建器会检查两者一致。

估算目标是“自有算法实现完整功能并通过验收”，不包含 Adobe 私有算法或像素级复刻。R0 的 AI、镜头配置和深度模型原型是后续排期的 go/no-go 依据；原型结论变化时，应同时调整工作量、日历和依赖。

## 复核触发条件

- Adobe 发布新的 Camera Raw 版本或修改官方手册。
- RawMaster 修改面板导航、调整配方、渲染顺序、源类型能力或蒙版模型。
- 一个功能 PR 声称关闭本清单中的缺口。
- 代码重构使 `codeRefs` 失效；构建器会检查行号是否仍落在文件范围内，但语义仍需人工复核。

当前统计和详细结论以 HTML 中由 JSON 自动计算的结果为准。

## 镜头配置维护

- `DevelopmentLensProfileCatalogV3` 只包含 RawMaster 自有近似系数，不代表 Adobe 配置或实测镜头标定数据。
- 自动匹配只接受 EXIF `LensModel` 与目录型号的规范化精确匹配；未知镜头必须返回无匹配并允许手动选择，不得按文件名或相机型号猜测。
- 新增目录项必须验证畸变、晕影、中点和强度缩放，并执行配方兼容、代理一致性、保存／撤销／重做及真实 RAW 回归。
- 当前基准 RAW 的实测元数据为 SONY ILCE-7RM5 + FE 14mm F1.8 GM；对应目录项为 `sony-fe-14-gm`，其系数仍需光学样本标定。

## 真实 RAW 性能与发版回归

[真实 RAW 性能报告](performance-report.html)按功能清单列出三款应用的采样边界、像素验证、单项中位数和 p95。采集文件与历史数据保存在 [evidence](evidence/)。源图 SHA-256 随报告保存。各计时程序使用工作副本或只读源图；Adobe 在临时目录内配对写入 XMP。三款应用的引擎阶段、文档打开、离屏绘制和照片实际显示各有独立的计时边界。

在 RAWMaster 的**诊断 → 图像性能监控**（⌥⌘P）中可查看正在运行、排队和已完成的任务，各队列最近的耗时、处理速度及 FlashRaw 解码阶段。编辑工作区通过 `ImageEngine` 访问预览、分析和源会话，监控通过 `ImageEngineMonitoring` 获取快照。支持的 RAW 在新建作品时记录 FlashRaw 0.3.1 的解码选择。代理与高质量路径复用线性图像，GPU 执行调整。已保存作品保留原有显影解释。该选择与 SwiftUI 窗口的生命周期独立。[引擎契约](../../../Sources/RAWMasterImaging/ImageEngine.swift) · [FlashRaw 选择](../../../Sources/RAWMasterImaging/FlashRawImageFactory.swift)

### 在本机复现

在专用的 Apple Silicon macOS 图形登录会话使用仓库固定的 FlashRaw 构建。以下命令从仓库根目录运行。把 `RAW_DIR` 指向有至少 15 张不同 RAW 的目录，把 `SAMPLE` 指向报告使用的单张实拍文件。测试输出目录必须为空。

```sh
scripts/build-flashraw.sh
scripts/test-image-performance.sh --source "$RAW_DIR" --operator-source "$SAMPLE" --measure-only --output "$BASELINE"
scripts/test-image-performance.sh --source "$RAW_DIR" --operator-source "$SAMPLE" --baseline-dir "$BASELINE" --output "$RESULT"
```

同一台电脑正在用于其他工作时，可在命令中添加 `--background`，运行真实 RAW、离屏画布、组合操作和逐控件测试。完整发版检查还会运行使用桌面会话的卡片交互测试。真实可见画布使用 `scripts/performance/benchmark-rawmaster-canvas.py`、`benchmark-acr-canvas.py` 与同一份 `CaptureCanvas.swift`。每个控件前两次切换用于校准，正式画布记录每项至少十次。Adobe 数字输入需要编辑窗口保有焦点。后台文档打开通过 Photoshop 的 Camera RAW 设置接口运行。[Adobe 的 RAW 打开与设置说明](https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/navigate-open-save-images-camera.html)

```sh
python3 scripts/performance/benchmark-camera-raw.py --source "$SAMPLE" --campaign main --output "$RESULT/camera-raw-open.json"
python3 scripts/performance/benchmark-camera-raw.py --source "$SAMPLE" --campaign points --output "$RESULT/camera-raw-points.json"
python3 scripts/performance/benchmark-camera-raw.py --source "$SAMPLE" --campaign supplement --spatial-witness --output "$RESULT/camera-raw-supplement.json"
python3 scripts/performance/benchmark-camera-raw.py --source "$SAMPLE" --spatial-witness --operations optics-profile-distortion optics-profile-vignetting optics-remove-ca optics-manual-distortion blur-apply blur-amount blur-bokeh blur-cat-eye blur-boost blur-focus-range --output "$RESULT/camera-raw-spatial.json"
python3 scripts/performance/benchmark-camera-raw.py --source "$SAMPLE" --native-witness --operations optics-remove-ca --output "$RESULT/camera-raw-native-ca.json"
# 此项采集需要 NumPy。首对在原尺寸选择位置，后三对独立核验同位置 RGB 变化。
python3 scripts/performance/benchmark-camera-raw.py --source "$SAMPLE" --native-pixel-pairs --operations optics-remove-ca --output "$RESULT/camera-raw-native-pixels.json"
python3 scripts/performance/benchmark-lightflow.py --help
python3 docs/research/camera-raw-parity/build_performance_report.py
python3 docs/research/camera-raw-parity/build_performance_report.py --check
```

两款引擎还可输出同一尺寸的 sRGB RGBA8 缓冲区，专门测量界面值提交至 CPU 能读取整张图片的时间。LightFlow 使用发布版的 `viewerFrame` 和 `viewerReadback`，RAWMaster 使用发布版预览服务。完整样本包含回到旧值以及连续输入新值。两组结果采用相同的原片、控件、输入数值和输出尺寸。[逐控件报告](performance-report.html)

```sh
python3 scripts/performance/benchmark-lightflow.py --raw "$SAMPLE" --display-readback --samples 20 --output "$RESULT/lightflow-display-readback.json"
RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib" \
RAWMASTER_PAIRED_READBACK_RAW="$SAMPLE" RAWMASTER_PAIRED_READBACK_REPORT="$RESULT/rawmaster-display-readback.json" \
  swift test -c release -Xswiftc -enable-testing --filter IndividualControlPerformanceTests/testPairedDisplayReadback
```

发布测试会自动记录 `display-readback.json`。它分别验证八个控件的 20 次往返与 20 个新值，检查完整 RGBA8 缓冲区中的照片像素，并与上一个含此项的同机基线比较中位数和 p95。单项可用 `scripts/check-display-readback.py` 复核。

白平衡、效果、曲线、HSL、分级和细节的另 31 个控件使用固定的两态值和前置设置。两端顺序运行，逐项校验完整输出尺寸。报告保留单边有信号、重复测量不稳定和达标的行。八个基础控件还另列跨进程中位数与尾延迟。[面板设置](../../../scripts/performance/paired-panel-controls.json) · [跨进程复测](evidence/interactive-readback-repeatability.json)

```sh
python3 scripts/performance/benchmark-lightflow.py --raw "$SAMPLE" --panel-readback --samples 20 --output "$RESULT/lightflow-panel-readback.json"
RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib" \
RAWMASTER_PANEL_READBACK_RAW="$SAMPLE" RAWMASTER_PANEL_READBACK_REPORT="$RESULT/rawmaster-panel-readback.json" \
  swift test -c release -Xswiftc -enable-testing --filter IndividualControlPerformanceTests/testPanelDisplayReadback
python3 scripts/check-display-readback.py "$RESULT/rawmaster-panel-readback.json" --output "$RESULT/panel-comparison.json"
```

菜单监控和离屏测试共享引擎阶段。原生照片分析的正式回归还覆盖点、区域、主体选焦后的照片像素，导入 LUT 后的新画面，以及浮动示波器的离屏显示。非 RAW 神经降噪使用 `RAWMASTER_PERF_CAMERA_JPEG` 指定实拍 JPEG，并从该摄影素材准备其余容器。每个格式都验证正常目录导入、同位置的预览像素和 16 位 TIFF 导出。[五项照片交互](evidence/rawmaster-inspection-focus.json) · [已显影照片的发布门禁](../../../scripts/check-photo-denoise-performance.py)

`v*` 标签和手动触发均会运行 [Release image performance](../../../.github/workflows/image-release-performance.yml)。实验机需要 `rawmaster-performance`、`macOS`、`ARM64` 标签、Metal、已登录的专用桌面、Swift 与 Rust 构建环境。仓库变量 `RAWMASTER_PERF_CORPUS`、`RAWMASTER_PERF_OPERATOR_RAW`、`RAWMASTER_PERF_BASELINE` 分别指向该机器的 RAW 照片目录、单张固定 RAW 与上一个获准的完整报告目录，`RAWMASTER_RUNTIME_ARTIFACTS_DIR` 指向已有的离线运行时归档。时间测试串行运行。逐控件检查对上个基线的中位数允许 10% 或 1 ms 的较大值，p95 允许 20% 或 2 ms 的较大值。配方、解码选择、输出尺寸、操作丢失和 A/B 像素验证失败均会阻止通过。回归通过后才进入应用打包。生成的 JSON 可用于下一次获准的基线。

发布机的固定操作原片使用系统支持 RAW 9 的 Bayer 文件。另以仓库变量 `RAWMASTER_PERF_XTRANS_RAW` 指定一个实际 X-Trans RAF。发版时会验证两种 CFA 的细节增强、RAW 9 的强度重放和 16 位 TIFF 导出，以及场景深度随配方重开后的全尺寸导出。本地可以设置 `RAWMASTER_PERF_NEURAL_RAW` 和 `RAWMASTER_PERF_XTRANS_RAW` 重跑这两类专用素材。检查器同时验证自动调整、取色、示波器与检查器交互的逐次输出。旧版基线如果尚无 inspection.json，本次先记录这些控件的完整像素或返回值验证，下一版开始比较时延。

### 固定测试二进制与 LightFlow 对照

发版脚本在 Release 构建结束后复制两份 XCTest 包及其内嵌模型，保存二进制 SHA-256 到本次输出目录的 `test-build.json`。各阶段从同一份副本运行。开发机可用 `RAWMASTER_PERF_BUILD_PATH` 选择独立的 SwiftPM 构建目录。使用 `--background` 时，最终 `summary.json` 记录离屏结果，`hostedUI` 标为 `not-run`。

同机发布基线包含 37 项照片操作时，脚本另外比较每个操作 20 次往返输入的三个终点，以及 74 次首次输入混合负载的中位数和 p95。历史基线缺少整组操作时，`photo-operators-v2-comparison.json` 记录本次像素核验并将 `baselineCompared` 设为 false。发版工作流使用完整的同机基线。每个失败阶段的指标、操作名和原始文件名保存在 `summary.json` 的 `failureDetails`。

三方屏幕取样使用同一张 RAW、相同照片尺寸和同一像素变化判据。LightFlow 的后台宿主、原版编辑器校验及离线重放可按[窗口测量说明](../../../scripts/performance/lightflow-window/README.md)复现。

`RAWMASTER_PERF_LIGHTFLOW_REFERENCE` 指向本机硬件、系统和原片相符的 LightFlow 原始报告目录。八个基础控件分别测试两态和连续新值。另有 31 项面板操作和 37 项照片操作测量首帧、首次与最终画面一致、最终读回三个终点。每项均比较中位数与 p95，并保留最初两次输入。每帧为 2400 × 1600 的 sRGB8。LightFlow 保留原版查看器的帧调度，RAWMaster 首帧读回后立即请求定稿。第二组逐项验证两款引擎收到的配方，18 项局部蒙版另核对中心与外部像素。发布时另对这 37 项共 74 次首次输入的固定工作负载检查中位数与 p95，每个控件的 A 和 B 各出现一次。[同尺寸回归检查器](../../../scripts/check-lightflow-performance.py) · [31 项原始调度](evidence/lightflow-panel-schedule.md) · [37 项档位和局部像素](evidence/paired-photo-operators-v2.md)

性能监控窗口按队列、算子、阶段和计时边界显示最近成功样本的中位数与 p95。窗口导出的 JSON 可直接执行 `python3 scripts/check-image-performance.py baseline.json candidate.json`。比较结果记录保留样本数与已完成总数。图构建阶段显示 CPU 耗时，实际处理像素的阶段另计算 MP/s。[监控导出和发布比较](../../../scripts/check-image-performance.py)

摄影降噪发布机还配置 `RAWMASTER_PERF_OUTPUT_DNG` 和 `RAWMASTER_PERF_SCENE_DNG`。下列命令使用 Pillow、NumPy 与 tifffile，把同一张实拍 JPEG 编成两份相同的 16 位线性数据，分别标记为输出参考与场景参考。检查器核对真实导入、源域分类、强度重放、恢复原图及 16 位导出。[DNG 检查器](../../../scripts/check-output-dng-performance.py)

```sh
python3 scripts/performance/prepare-output-dng.py path/to/camera.jpg path/to/new-fixtures
```
