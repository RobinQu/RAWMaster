# 035 · 生产验收与回执索引

基线为包含 031、034 和 035 调研的 `main@1b7df6b61434f243cc98a17fbcaa7d91d0e88b30`。在相同机器上分别构建基线、候选两个 Release，保存提交、未提交差异、测试二进制及动态库 SHA-256、系统／设备、原片／模型／LUT 摘要，再逐项比较。窗口计时独占图形会话，固定条件后先记录首次，再记录全部暖样本及独立确认轮。功能测试、着色器对拍、GPU 完成、CPU 读回、主线程绘制返回、屏幕像素变化分别有自己的边界。[原生窗口协议](../031-preset-browser/integration-validation.md) · [发版工作流](../../.github/workflows/image-release-performance.yml)

## Camera Raw 的 161 个稳定功能 ID

从仓库根目录运行。第一条导出每行的原验收条件、实现状态、代码定位、三产品处理和画布的采样边界与原始数据。第二条适合审阅单一操作。提供候选完整发版目录时，工具用官方 `controls.json` 校验器逐样本检查状态交替、像素摘要、次数及输出尺寸，并对照该目录 `test-build.json` 的 Imaging 二进制。随后按同一源 SHA 读取 33 个 `inspection.json` 原生事件，对照 UI 二进制，并核验正常 2× TIFF16 的来源、尺寸、编码、模型和实际封存的 Imaging 测试二进制。各专项取数仍沿用它们原有的时钟边界。[索引程序](verify-acceptance.py) · [官方逐控件校验](../../scripts/check-control-performance.py)

```sh
python3 specs/035-portable-processing-cores/verify-acceptance.py --json /tmp/rawmaster-035-feature-index.json
python3 specs/035-portable-processing-cores/verify-acceptance.py --feature light-exposure
python3 specs/035-portable-processing-cores/verify-acceptance.py --release-dir "$RESULT" --json "$RESULT/035-feature-index.json"
python3 docs/research/camera-raw-parity/build_report.py --check
python3 docs/research/camera-raw-parity/build_performance_report.py --check --require-complete
```

| 面板 | ID 数 | 面板 | ID 数 | 面板 | ID 数 |
| --- | ---: | --- | ---: | --- | ---: |
| Light | 18 | Color | 21 | Effects | 23 |
| Curve | 15 | Color Mixer | 18 | Color Grading | 14 |
| Detail | 17 | Optics | 16 | Lens Blur | 19 |

Camera Raw 19.0 功能基线标为 158 项 aligned、3 项 partial。三项分别为 `detail-denoise`、`detail-raw-details`、`detail-super-resolution`。保留原项目的区别、源类型约束、5 个待核查项和 6 个 RAWMaster 扩展。每个 ID 的功能签收包括真实入口、两种输入值的像素响应、撤销与重开、成片，以及该行指定的源类型或模型条件。已标 aligned 只表达历史功能覆盖程度。项目未采集 Adobe 参考像素的算子，仍须对旧显影引擎保真和 Adobe 独立样本分开记录。[原始功能矩阵](../../docs/research/camera-raw-parity/feature-matrix.json) · [原始测量矩阵](../../docs/research/camera-raw-parity/performance-data.json)

| 历史证据 | 有数据的范围 | 比较与验收 |
| --- | --- | --- |
| RAWMaster 控件处理 | 161 measured | 以每行的解码器与实际边界对照。单个 resident-controls 工作负载覆盖 124 项，检查器 33 项，学习型 2× 导出 1 项，另 3 项由已显影 JPEG／TIFF 与设备深度工作负载覆盖。其余需按原行 `evidence` 追到检查、点色或专项报告 |
| Camera Raw | 102 measured，50 unmeasured，6 inconclusive，3 inapplicable | 有完整打开到 Photoshop 文档、空间响应与可见画布等不同协议。未测和不确定保留原判定 |
| LightFlow | 93 measured，48 缺少等价项，19 只有相关项，1 inapplicable | 同输入／分辨率／边界的 GPU 完成、viewer readback、实际可见画布分别比较 |
| 三产品 | 71 行都有处理读数，6 行都有可见画布读数 | 历史总门 `not-qualified`。74 个 firstAppearanceMix 样本的 firstExact、final 两项 RAWMaster p95 均为 477.94 ms，LightFlow 为 210.23 ms。事件、首个变化和最终正确帧分别保留 |

全量发布跑既有 workflow 的专用 macOS／Metal 工作站。至少 15 张不同 RAW，另设 X-Trans、相机 JPEG、输出参照／场景参照 DNG、神经降噪与超分辨率输入及固定 LightFlow 证据，精确环境变量以 workflow 为准。比较同机同源同算子，既有 resident-controls 门的中位数容差是 `max(10%, 1 ms)`，p95 是 `max(20%, 2 ms)`。需要正式发版时保留 `summary.json`、`test-build.json`、各子报告及可见窗口结果。后台模式和 `--measure-only` 适用于单独诊断。[环境合同](../../.github/workflows/image-release-performance.yml) · [性能取数说明](../../docs/research/camera-raw-parity/README.md)

```sh
scripts/build-flashraw.sh
scripts/test-image-performance.sh --source "$RAW_CORPUS" --operator-source "$OPERATOR_RAW" \
  --baseline-dir "$PERF_BASELINE" --output "$RESULT"
```

## 功能与成片

| 入口与输入 | 必须观察的数据和判据 | 既有验证与候选验证入口 |
| --- | --- | --- |
| 027 AI 蒙版，真实 RAW 中的主体／背景、天空／水、点／框、人物、雪。带 EXIF 8 和裁切的工程 | 源摘要、选中解码器、方向、模型 SHA、Gray8 尺寸与覆盖。同图换目标能复用场景，同目标命中精确快照。晚到、取消、换片、无目标、缺模型保持历史不变。打开冻结工程／导出均零推理。遮罩有效值为 0 的 TIFF16 像素逐通道最大差 0。记录旧 V3 切回 legacy 的单独对照，历史切换曾有 2/65535 误差 | [独立模型与限时](../027-mask-ai-raw-integration/service-validation.md) · [原生编辑及像素](../027-mask-ai-raw-integration/editor-validation.md) · [真实人像／阴影积雪漏选](../027-mask-ai-raw-integration/portrait-snow-validation.md) |
| 028 Classic，Original 加 9 款及 Vivid 37%，原生主图、缩略图、收藏、悬停、保存、导出 | 2400×1600 settled，9504×6336 PNG16。十个 192 px 目标暖整组 p95 ≤250 ms。暖窗口 p50 ≤20 ms、p95 ≤33 ms。记录 19 个暖交互绘制、回退、RAW 解码、过期帧、原始源文件 SHA。半透明／低 alpha、负值、HDR 保留。canonical RAW 的 +1 至 +3 ULP 修复单列 | [028 实图协议、四组专项命令](../028-filter-experience/validation.md) · [原生窗口校验器](../031-preset-browser/verify-integration.py) |
| 031 普通预设，左栏选同一曝光与等价手调 | 交替 AB/BA，首对另外记录，30 个暖样本／臂，每对配方一致、每轮 Undo，2400×1600 的 settled 绘制返回。SC-02 两轮各自要求 preset p95 ≤ manual p95。不能通过合并、去掉慢样本或改用部分绘制来签收 | [031 窗口原始数据与门](../031-preset-browser/evidence/camera-raw-integration/window-gates.json) · [复核方法](../031-preset-browser/integration-validation.md) |
| 031 Adobe Adaptive 迁移 | 冻结 78 源 XMP，53 内置、25 用户，校验所有 1,881,440 B。72 可浏览、6 隐藏依赖。原始字节可恢复、重跑零新增、旧记录／收藏／批次不丢。锁定 4 Subject／5 Sky 可逐图重建、7 个普通子集、4 个景深近似、1 个 Reset，其余沿 031 原判定 | [冻结清单](../031-preset-browser/contracts/migration-manifest-v1.json) · [78 项实际回执](../031-preset-browser/evidence/frozen-exchange/receipt.json) · [支持边界](../031-preset-browser/exchange-validation.md) |
| Subject Soft 与 Sky Sunrise 各自应用于两张真实 RAW | 每种预设两片，逐片实际跑 Vision／已校验 ONNX，证实新建、源与解码器身份、两份独立 Gray8、另一片结果被拒。生成阶段不改历史，明确采用只记一笔，写入 XMP SHA、照片 ID 与图层 SHA。新 controller 用空模型目录打开、等待正常 settled、全尺寸 TIFF16 写盘、读取全图校验保护区且有选中 RGB 变化。两片 SHA 前后一致 | [新增真实重放](../../Tests/RAWMasterUITests/AdaptivePresetReplay035Tests.swift) · [共用 TIFF16 对拍](../../Tests/RAWMasterUITests/EditingMaskAcceptanceProbe.swift) |
| 三款 Spektrafilm（Portra 400/Endura、Velvia 100、Vision3 250D/2383） | 13 色块 × 三款 × 0、0.5、25、37.5、50、100%。线性 RGB 绝对误差 ≤0.0007。保留预乘 alpha、过界有符号残差和低 alpha。同一人物、雪景的 6 个 160×240 参考图比较 8-bit RGB。每张 mean <0.25、p99 ≤1、max ≤2。损坏某端点仅影响对应资源。0% 不额外成像 | [直接扫描、色卡、两组样片](../031-preset-browser/evidence/spektrafilm/README.md) · [原生数值／坏资源测试](../../Tests/RAWMasterImagingTests/DevelopmentSpektrafilmTests.swift) · [Rust LUT 对拍](../../Modules/ImageEdit/tests/photo_filter.rs) |
| 版本兼容和颜色 | 在旧 V1/V2、promoted V3 和新 V3 工程逐图验证 RAW 解码内曝光／白平衡与已解码像素变换的位置，避免重复增益。比较线性扩展 sRGB、RGB 与 alpha 各自语义、合成前后阶、滤镜强度恰好 100 与相邻 Double、分支色域、输入／输出 ICC、实际编码位深。每条路记录命中的后端及读回次数 | [管线合同](pipeline.md) · [Swift 原生成像](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift) · [Rust 编译图合同行为](../../Modules/ImageEdit/tests/contract.rs) |

027 独立服务的上限分别为冷主体／首类风景／首个物体 prompt 6,000 ms、主体快照 250 ms、同图第二类风景 1,500 ms、复用 encoder 的第二框 2,000 ms、快照读取校验 100 ms、取消 2,000 ms。性能专项的进程峰值预算 4,000,000,000 B。应用级另存 30 次主体暖命中、首次解码与模型调用计数、采用至 settled、离线重开与 TIFF16。服务测量不得充当窗口读数。[独立服务](../027-mask-ai-raw-integration/service-validation.md) · [原生两张 RAW](../031-preset-browser/integration-validation.md)

### 复现 Adaptive 与滤镜

使用独立输出目录。固定 Sony 原片见 027，`RAWMASTER_MASK_FIXTURES` 指向含 `person.ARW` 的样片目录，`RAWMASTER_MASK_PACK` 指向含 `Models` 和 `ONNXRuntime` 的经核验产品模型包。两种冻结预设从 031 既有 Adobe 安装读取，迁移写到本次私有 catalog。可用 `RAWMASTER_035_RAW_ROOT` 指向包含 `sony-landscape.ARW`、`sony-sample-02.ARW` 的目录。测试拒绝不匹配的原片和重复使用的输出子目录。索引工具最后重新计算四个实际 TIFF 以及所有对照 TIFF 的文件摘要。同时传 `--release-dir` 和 `--adaptive-dir` 时，还会核对两侧使用的 UI 测试二进制 SHA。[源及运行时摘要](../031-preset-browser/evidence/camera-raw-integration/inputs.json) · [第二张天空样片](../027-mask-ai-raw-integration/validation.md)

```sh
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
export RAWMASTER_035_ADAPTIVE_OUTPUT="$(mktemp -d)"
export RAWMASTER_035_ADAPTIVE=1
swift test -c release -Xswiftc -enable-testing --test-product RAWMasterUITests --filter 'EditingInteractionPerformanceTests/testOptIn035Adaptive'
python3 specs/035-portable-processing-cores/verify-acceptance.py --adaptive-dir "$RAWMASTER_035_ADAPTIVE_OUTPUT"

catalog_out="$(mktemp -d)"
manifest=specs/031-preset-browser/contracts/migration-manifest-v1.json
swift run -c release RAWMasterDiagnostics --migrate-frozen-presets "$manifest" --catalog "$catalog_out/presets" > "$catalog_out/inspect.json"
swift run -c release RAWMasterDiagnostics --migrate-frozen-presets "$manifest" --catalog "$catalog_out/presets" --apply > "$catalog_out/first.json"
swift run -c release RAWMasterDiagnostics --migrate-frozen-presets "$manifest" --catalog "$catalog_out/presets" --apply > "$catalog_out/replay.json"
RAWMASTER_CHECK_ADOBE_PRESET_FIXTURE=1 swift test -c release -Xswiftc -enable-testing --filter PresetExchangeTests

RAWMASTER_SPEKTRAFILM_OUTPUT="$(mktemp -d)" swift test -c release -Xswiftc -enable-testing --filter DevelopmentSpektrafilmTests
swift test -c release -Xswiftc -enable-testing --filter 'DevelopmentSemanticMaskTests|PhotosSemanticMaskInteractionTests|PhotosMaskWorkflowTests|EditingMaskCanvasOwnershipTests'
```

031 发布门在独占窗口两轮分别采集 classic 和 paired，另采集 bird、portrait。把每次的 `editing-interaction-performance.json` 对应保存为 `classic.json`、`paired.json`、`bird.json`、`portrait.json`、`confirm-classic.json`、`confirm-paired.json`，执行 `python3 specs/031-preset-browser/verify-integration.py "$WINDOW_RECEIPTS" --confirm`。采集所需环境变量和准确 action 见 [031 原生采集命令](../031-preset-browser/integration-validation.md) 与 [028 的四个专项](../028-filter-experience/validation.md)。

## 快速 Prompt

快速 Prompt 从原生编辑器冻结当前版本与实际合成构图，范围为整图、左上原点矩形或已确认蒙版。每个 provider 的整图和 ROI 各建一条记录。历史机器为 M4 Max、128 GiB、macOS 27.0.1。以下两个历史报告的模型输入、测试问题和边界分别保留。索引工具离线核对两份报告的 case 身份、摘要、恢复、原片保护和 ROI 断言。[真实模型单独回执](../034-quick-prompt-editing/poc/provider-results.json) · [原生全链回执](../034-quick-prompt-editing/poc/archive-results.json)

| 路径 | 观测与判定 | 证据 |
| --- | --- | --- |
| 冻结／ROI | 来源 photo/work、父版本、recipe hash、EXIF/镜像、裁切、matte 摘要、实际提交 PNG SHA 和尺寸绑定。全图、矩形、软蒙版、边缘填充分别取样。预览复核取同一上传字节。局部合成按 TIFF16 原维度，matte=0 的通道含隐藏 RGB 均逐像素相等 | [原生几何与成片](../../Tests/RAWMasterImagingTests/QuickPromptImagePreparationTests.swift) |
| FLUX.3 Image Klein Q8（本机） | 离线匹配权重与运行时，保存固定种子、模型／输入／输出摘要，取消后终止子进程并释放槽。历史 transport 两份输出与独立 MLX CLI 的 SHA 相同。原生历史整图／局部含归档、采用、撤销、重开分别 180.28 / 150.47 s | [本机模型与真实取消](../034-quick-prompt-editing/provider-validation.md) · [适配器验证](../../Tests/RAWMasterAITests/QuickPromptProviderTests.swift) |
| Seedream 5.5（北京方舟） | UI 取消出站确认应计 0 次，授权一次提交以原 attempt 收到 1 张。待确认、断网、返回不明与归档失败保留原状态，核对原收据，不能自动 POST 第二次。固定模型、地址、图片数及用量。费用以提供者回执为准。原生历史整图／局部 10.22 / 9.32 s | [原生云／本机四份回执](../034-quick-prompt-editing/native-validation.md) · [可控传输和版本核验](../../Tests/RAWMasterAITests/QuickPromptProviderTests.swift) |
| 候选与交付 | 接收、入库与显式采用是不同操作。取消、换照片／草稿、严格纪实、重复采用、晚到结果都复核归属。撤销撤回采用，重开仍可核对历史。离线原片能从已有归档导出，已收到的输出在发布失败后只重试归档。历史两个相同 ROI 各读到 786,432 个受保护像素，通道差均为 0，选区确有改变 | [原生控制器工作流](../../Tests/RAWMasterUITests/EditingWorkflowTests.swift) · [候选、归档与重试合同](../034-quick-prompt-editing/contracts/quick-prompt.md) |

在候选 Release 执行下述测试。提供者测试使用可控本地传输校验发送次数。5.5 的新增断网用例在已存提交意图后注入 `URLError.notConnectedToInternet`，以新 provider 核对原尝试并再调一次提交，累计 transport 调用数必须为 1。完整真实提供者比较使用上表冻结历史证据。视觉质量门还需六名摄影师、每种模型／范围各至少 12 张留出照片，30 次暖动效与 VoiceOver 按 034 原规格评审。[034 画面与工单回执](../034-quick-prompt-editing/native-validation.md) · [原生入口](../../Tests/RAWMasterUITests/PresetMaskEntryPointTests.swift)

```sh
swift test -c release -Xswiftc -enable-testing --filter 'QuickPromptProviderTests|QuickPromptImagePreparationTests'
swift test -c release -Xswiftc -enable-testing --test-product RAWMasterUITests --filter 'EditingWorkflowTests|PresetMaskEntryPointTests/testQuickPrompt'
python3 scripts/check-ui-prototype.py --editing-only
```

### 当前版本的本机 FLUX 实机重放

035 使用 RC2 的 11 个生产对象和原生测试包资源，新链接的 Release 定向 XCTest 于本机完成一次真实 Q8 局部去标牌。总用时 180.798 s，MLX pipeline 179.367 s、峰值 8,501,400,908 B。已占内存配额期间工单停在 preparing，提交意图数为 0，另一照片的首个 settled 画布用 51.59 ms 绘完。释放配额后，MLX 推理中该照片的曝光变化在 22.47 ms 绘完。这两个数字各为单次绘制。实际提交的 PNG、模型返回的 PNG、最终归档 TIFF16 的 SHA 与 034 同一 ROI 的对应文件完全相同。选区的 262,144 个像素均发生变化，其外的 786,432 个 RGBA16 像素逐通道相同。采用、撤销的持久 revision 为 0→1→2，新打开仍指向原图，并保留同一候选与唯一一次尝试。真实数据在 `output/035-development/flux-controller-rc2-run1`。此前 034 的对应原生局部总用时 150.47 s，当前仅采了一次。[本次构建、SHA、工作进程与窗口回执](evidence/quick-prompt-production-flux.json) · [034 对应历史回执](../034-quick-prompt-editing/poc/archive-results.json)

在装有 034 固定 MLX 环境和 Q8 权重的 Mac 上，以独立空目录保存照片、SQLite 和归档。用 034 局部湖泊原片，SHA-256 为 `17e0c427790397572821339d541e9169b67a4dbb76123bd8d146a441d81c2034`。由编辑器从原始版本提交 (480,496,512,512) 矩形，实际模型 PNG 为 1024×1008。测试先占住物理内存配额，读取真实工单还处于 preparing、尚无提交意图，再让另一张入库 JPEG 在独立编辑窗口画出 settled 帧。释放配额后等待本机 MLX 实际运行，再次改变另一个窗口的曝光并等待 AppKit 返回。候选归档为 1024×1024 TIFF16。测试验证原片、输入、局部底图、模型返回及成片 SHA，检查手动采用、撤销、关闭与重新打开后的持久版本。目录下的独立校验直接读 SQLite 和四组图像字节，解析 TIFF strip，比较所有 786,432 个保护像素和 262,144 个选区像素。[编辑器定向用例](../../Tests/RAWMasterUITests/LiveFlux035Tests.swift) · [独立校验](verify-acceptance.py)

```sh
export RAWMASTER_035_LIVE_FLUX=1
export RAWMASTER_035_FLUX_ROOT="$FLUX_INSTALL"
export RAWMASTER_035_FLUX_PNG="$FROZEN_034/native-flux/region/originals/lake-input.png"
export RAWMASTER_035_FLUX_OUTPUT="$(mktemp -d)/flux-region"
swift test -c release -Xswiftc -enable-testing --test-product RAWMasterUITests --filter 'EditingInteractionPerformanceTests/testOptIn035LocalFluxRegionThroughEditor'
python3 specs/035-portable-processing-cores/verify-acceptance.py --flux-dir "$RAWMASTER_035_FLUX_OUTPUT"
```

`FLUX_INSTALL` 包含 034 固定的 `venv/bin/python`、`mlx` 和 `models/q8`。由产品离线子进程校验权重，`FROZEN_034` 对应先前原生验证的 `output/quick-prompt-native`。也可用仓库 030 的 `poc/fixtures.py --lake specs/030-ai-retouching/evidence/mountain-lake.jpg --out "$FIXTURES"` 从公开湖景复现带牌面的原片，将 `RAWMASTER_035_FLUX_PNG` 指向所得 `lake-input.png`。用例会验证预先冻结的 PNG SHA。本机重放只选择 FLUX。Seedream 实际出站数据见 034 封存回执。[公开样片制备](../030-ai-retouching/poc/fixtures.py)


## 服务、队列及实际渲染路线

| 签收对象 | 操作与硬条件 |
| --- | --- |
| Rust 无 GPU | 在 Linux 环境构建生产 crate `Modules/ImageEdit`，关闭默认 GPU feature，记录目标平台、依赖树和实际 worker 后端。用真实只读 JPEG、相机 RAW 及各自的 frozen coverage，一个进程重放同一 DAG。每帧对照 macOS CPU 独立参考，保留解码器、源／配方／覆盖／输出 SHA、尺寸、浮点格式、ICC。另测 Linux FlashRaw 从原始 RAW 开始解码。已定向 FP32 回放、RAW 裁块与整图直接解 RAW 分别签收。[原始跨平台数据](evidence/image-replay.json) · [PoC 复现](validation.md) |
| 编辑驻留与退回 | 原生 `AppModel.editing` 的当前照片、版本、revision 必须与实际提交、完成栅栏及最终呈现一致。报告后端、precision、ICC／alpha、完整图像上传／读回次数、冷暖及峰值。设备故障、取消、过期帧应明确退回／丢弃。同一计算配方 CPU、真实 Metal、软件 Vulkan 与物理 Vulkan 各记录自己的能力。[图与颜色合同](pipeline.md) |
| 资料库／原生编辑／导出的共享任务 | 同一目录数据库并行认领、资源额度与 release。持久工作应续租、过期重领、取消、中断／恢复、有限重试。对旧 token 在无新 worker 时也要拒绝发布。新 owner 不能接收旧 owner 的已写数据。覆盖断盘／写满、同名冲突、旧版本重开、远端已发送结果待核对、相同输出只登记一次。实图库导入＋滑杆＋蒙版＋032 导出并发时记录每类任务等待、完成数、内存、最终成片与队列空闲状态。[队列验收协议](catalog-queue.md) · [032 原导出性能](../032-export-workspace/performance.md) |

```sh
cargo test --locked --release --manifest-path Modules/ImageEdit/Cargo.toml --no-default-features
cargo test --locked --release --manifest-path Modules/ImageEdit/Cargo.toml -- --include-ignored
cargo test --locked --release --manifest-path Modules/LibraryCatalog/Cargo.toml
```

前三条须按目标宿主区分执行。已有 PoC 的 `experiments/portable-processing/verify-linux.sh cpu|batch|raw|vulkan` 和 [两个平台的原始回执](validation.md) 保留为已知可复现的执行合同。C ABI 从实际生产 crate 加载、当前 Linux worker 消费持久工单，以及当前生产 SwiftUI 帧／渲染交付必须各自留下可追溯的执行回执。

在 Linux 无 GPU 宿主复现真实天空覆盖的独立工作负载，使用 Python 3 和 Pillow 从仓库的 JPEG 与蒙版准备输入，随后 Python 通过 C ABI 载入生产 `librawmaster_image.so`。这一步使用 JPEG 原片中间隔 10 像素的 160×107 点阵。完整批处理另跑上表的多图、原尺寸协议。[实际采样与返回值比较](../../Modules/ImageEdit/tests/replay_mask.py)

```sh
run="$(mktemp -d)"
cargo build --release --locked --no-default-features --manifest-path Modules/ImageEdit/Cargo.toml --target-dir "$run/target"
python3 Modules/ImageEdit/tests/replay_mask.py prepare "$run/input"
python3 Modules/ImageEdit/tests/replay_mask.py verify "$run/input" "$run/target/release/librawmaster_image.so" cpu \
  --pixels "$run/output.rgba32fle" > "$run/linux-cpu.json"
```

实际相机输入使用 `experiments/portable-processing/verify-linux.sh production-raw "$OPERATOR_RAW"`。固定 FlashRaw 0.3.1 与 C 桥读取 SHA 为 `8f96d2fd…` 的原片，生产库以无 GPU Release 执行 +1 EV。512×384 的原尺寸传感器坐标裁块输出 3,145,728 B，线性通道与乘二最大差 0。两端独立输出的整块文件 SHA-256 均为 `d45565a9a183f357dfaa0f76d33525f1c0d47d40dc198d14b21c1a09122615fc`。本轮回执在 `output/035/linux-production-raw.LvIiH5/run.json`，与 macOS 对照文件列在 `output/035-development/macos-production-raw.6Auib3/` 下。[生产 RAW 输出及双平台回执](evidence/image-production-raw.json) · [Linux C ABI 与解码复现](../../experiments/portable-processing/verify-linux.sh)

## 本次构建的结果位置

| 构建或数据 | 当前读取结果 |
| --- | --- |
| 035 以前的 031 最终确认 | 第一次普通预设 p95 59.40 ms，手调 61.86 ms。独立确认 58.02 ms 对手调 55.52 ms，SC-02 未过。[原始回执](../031-preset-browser/evidence/camera-raw-integration/window-gates.json) |
| `da5d1ca2` 较早开发基线 | 61 MP Classic p50/p95 为 12.10 / 25.13 ms。031 普通预设 59.76 ms，手调 51.95 ms。该组在 `output/035-development/baseline/{classic,paired}/editing-interaction-performance.json`，用于定位旧尾延迟 |
| 合并基线 `1b7df6b6` | `output/035-development/main-1b7df6b6/` 内含原测试二进制摘要及 `classic`、`paired`、`mask-subject` 的 JSON。按 031 原验收器复核首次 Classic p50/p95 10.56 / 14.57 ms，成对预设 p95 52.26 ms、手调 55.19 ms。竖幅主体冷 202.42 ms、30 暖 p95／最大 14.32 / 14.36 ms。4000×6000 TIFF16 的 21,538,706 个保护像素最大差 0，重开／导出均 0 次推理 |
| 合并基线与候选的真实 031 迁移 | 分别用本机 78 个已安装原件和私有空目录跑 inspect、apply、再次 apply。两次构建都是 78／0 新增、78 原件共 1,881,440 B 验证通过、重放前后 80 个文件的逐文件 SHA 相同。基线 `output/035-development/frozen-1b7df6b6-z7ti_s26/proof.json`。候选 `output/035-development/frozen-candidate-jlznfmxe/proof.json`，诊断二进制 SHA `c7d521c122e24041dcfd7067bfd24e2aa26dac17c40837493c47071d4814e924` |
| 生产 Rust 图的实际本地结果 | 在同一真实湖景 JPEG 和来源绑定的天空蒙版上取 160×107 点阵。macOS CPU 与 Linux CPU 各自对独立参考的局部曝光最大差 1.76×10⁻⁷、分支 LUT 差 6.26×10⁻⁸，两个 CPU 平台的输出缓冲区 SHA-256 同为 `5d0798c89e442478789136c5be1181dd4365e35ddcc92387ec48587cce26ad56`，均有 13,329 个零覆盖像素逐值相同，3,791 个分数覆盖像素改变。Mac Metal、Linux 软件 Vulkan 另有报告。见 `output/035-development/{image-mask-macos-cpu.json,image-mask-metal.json,linux-image/cpu-mask.json,linux-image/vulkan-mask.json}`。[生产 C ABI 重放](../../Modules/ImageEdit/tests/replay_mask.py) · [已封存平台和构建数据](evidence/image-production-parity.json) |
| 候选快速 Prompt 的断网恢复 | 当前 Release 原生 Seedream 5.5 测试在模拟传输抛出断网后，用新 provider 对原 attempt 执行核对并再次调用提交。总共发起一次 transport 调用，源 PNG 一致。定向 XCTest 1 项通过，整个提供者套件 5 项通过，执行的测试二进制 SHA 为 `3e646f18b55d446174184b21eedf85f0378eed8bcf7e2320cdb8b9588f16bdad`。见 `output/035-development/quick-prompt-offline.log`、`quick-prompt-providers.log` |
| 合并基线正式发布脚本 | `output/035-development/main-1b7df6b6/formal/` 的 124 项 resident control＋33 项原生 inspector＋1 项整图 2× TIFF16 已按稳定 ID 合并，158/161 个测量行。该 Sony 样片另外 3 项按源类型不适用，分别为 `color-temp-rendered`、`detail-denoise-formats`、`blur-device-depth`。逐 ID 索引见同级 `035-feature-index.json`。RAW9、X-Trans、2×、37 项 photo operators 及其余专项在本轮通过各自校验。首次输出参考 DNG 夹具未通过域判定，原 `summary.json` 保留 `passed=false` 和两项失败。同批封存测试二进制用正确 tag 1／0 原件复跑成功，成片和独立校验在 `output-referred-dng.json`、`output-referred-dng-corrected.log`、`output-referred-dng-corrected-comparison.json`。本轮属于基线取数，`timingGatesRequired=false` |
| 全工作台原型 | 本机 21 项走查通过，含资料库、编辑、导出、已有与过期 Prompt 候选、云提交核对、蒙版、窄窗与减少动效。记录 `output/035-development/prototype-full.log`。[可操作工作台](../../docs/ui/prototype/index.html) |
| RC1 原生 031／027 窗口 | 六个成功回执经 031 校验器通过，汇总在 `output/035-development/candidate-rc1/035-window-verified.json`，UI 测试二进制 SHA `d2b8cce75313ae10d3c54fb600f015eacaa43e00d5f3b5b8ffcb0e62693659c8`。Classic 两轮 p50/p95 为 11.39/17.36、10.81/15.00 ms。两轮普通预设／手调 p95 为 79.86/113.55、80.11/82.76 ms，均满足成对 SC-02。与合并基线首轮 52.26/55.19 ms 相比，候选两臂的绝对值均上升。人像／61 MP 首个主体为 197.37/305.15 ms，30 暖 p95 为 14.47/33.49 ms。两个 TIFF16 各有 21,538,706 和 60,003,066 个保护像素，最大通道差均为 0，重开及写出调用次数均为 0。初次 61 MP 运行的 `mask-61mp` 路径缺文件，使用正确冻结原片的 `mask-bird` 另存成功回执 |
| RC1 滤镜与快速 Prompt | `filters.log` 共 26 项通过。六张 Spektrafilm 成片对直接参考的平均误差为 0.0214–0.0383 个 8-bit RGB 码值，各图 p99 均为 1，最大差为 2（人像 Velvia）。`quick-prompt-imaging.log` 3 项、`quick-prompt-provider.log` 5 项全过，覆盖两端合同、错误／断网、输入几何和受保护像素。原生 `workflow.log` 的四项归档／快速 Prompt 工作流和 Prompt 入口均通过。该组合日志还记录一次独立的多选导出 `archiveMismatch`，保留为 032/035 交付失败，候选修复后另验 |
| RC1 真实 Adaptive 快照与成片 | 两个 XCTest 均通过，Sky 43.865 秒，Subject 36.234 秒。独立 Python 校验重新读取所有已归档 TIFF 和对应控制图，并核对 SHA。四次各运行一次真实推理、一次 FlashRaw 分析解码，错误照片快照两次均被拒，四张新打开与写出实际推理调用数均为零。完整数据在 `output/035-development/candidate-rc1/adaptive/{sky,subject}/receipt.json`，独立验收在同级 `adaptive-verified.json` |
| Batch 34 已显影控件 | `output/035-development/candidate-batch34-rendered-controls/` 为封存 Release（Imaging `ba40e4c5…`、UI 测试 `f0c88f78…`）。正式两轮在同级 `-enabled`／`-confirm`。三源回执 `rendered-controls.json` 绑定该 Imaging 二进制，逐 ID 索引在封存目录的 `camera-raw-acceptance.json`：161 measured，含 124＋33＋1＋3 四类来源 |

RC1 每个预设先在编辑器采用并保存，然后重开、写出全尺寸 TIFF16。下表的保护像素为有效覆盖恰好等于零的全部像素。选择内实际变化按覆盖 ≥0.5 的像素比较 RGB，纹理预设只改变部分有纹理的像素。

| 冻结 XMP | RAW SHA 前缀 | TIFF16 尺寸 | 冻结 Gray8 PNG SHA 前缀 | 保护像素／最大通道差 | 已覆盖像素中 RGB 实际变化 | 成片 SHA-256 |
| --- | --- | --- | --- | ---: | ---: | --- |
| Sky Sunrise | `8f96d2fd4fa0` | 9504×6336 | `88dcf52f4afc` | 27,782,156 / 0 | 31,044,225 / 31,044,237 | `5b9d5f9af7e59f571dcc69d006673655cb3ae7372042339d64bdf96f6881ca70` |
| Sky Sunrise | `4e7e80f4e34e` | 8640×5760 | `bee00933b5ea` | 36,880,936 / 0 | 10,330,977 / 10,330,977 | `c3205e776bdcaf322a390f3adf40daf02fc06563099635baa940a2cd6b99207e` |
| Subject Soft | `8f96d2fd4fa0` | 9504×6336 | `2cc832d98dbf` | 60,003,066 / 0 | 34,674 / 152,274 | `787104ca8e7c77d1dd0a569975c15a13c1b1df7ef2a080ab5d54956928ced1b5` |
| Subject Soft | `0a0775e6f803` | 4000×6000 | `31e961e78926` | 21,538,706 / 0 | 2,192,459 / 2,211,893 | `995934691d2b01c1b9670c0feffcbd17bafa4bef74c8c84c59bc7bb7c4aebd84` |

### 驻留 GPU 与导出吞吐

Metal 在 1600×1067 原始 JPEG 网格上，融合与分段执行的正序 P50 分别为 1.610 / 1.643 ms，反序 1.603 / 1.639 ms。取该图 1600×900 裁切并以同一映射将像素和天空覆盖扩展到 3840×2160，融合与分段正序 3.133 / 4.669 ms，反序 3.145 / 4.674 ms，两次均达到规定的驻留参数更新 P50 至少降低 25%。每个系列先预热 3 次再取 21 个样本。完整上传、完成栅栏后的读回及新绑定端到端均单独计时。另一组 macOS IOSurface 原型在 160×107 的实际图与覆盖上共享三个原生纹理，单次分派、逐帧上传／读回各 0 次，超时帧等待物理 fence 且发布次数为 0。这些数字对应各自的计算边界，SwiftUI 画布时间另见 031 窗口实测。[两轮完整 GPU 数据](evidence/image-production-performance.json) · [IOSurface 数据](evidence/image-metal-iosurface.json)

032 工作台用同一批源照片独立写出文件，五项均读取尺寸和 ICC。合并基线、RC1 和 RC2 的原始每次耗时在 `output/035-development/export-{main,rc1,rc2}/rawmaster/results.json`。下表为每项重复运行的中位秒数。RC2 真实原生多选导出已通过，见 `candidate-rc2/workbench-sandbox.log`。RC2 的 JPEG 200 张依旧超出合并基线。

| 输入与数量 | 合并基线 | RC1 | RC2 |
| --- | ---: | ---: | ---: |
| JPEG 1 | 0.073 | 0.098 | 0.093 |
| JPEG 20 | 0.493 | 1.069 | 0.823 |
| JPEG 200 | 4.720 | 10.117 | 7.955 |
| RAW 1 | 0.056 | 0.078 | 0.083 |
| RAW 20 | 0.362 | 0.687 | 0.726 |

### RC2 原生窗口与正式发布脚本

原 031 校验器读取 RC2 的三个 AppKit 窗口回执。Classic 暖 p50／p95 为 10.65／18.05 ms。普通预设与逐项手调的两轮暖 p95 分别为 52.18／54.99 ms、54.87／55.78 ms，每臂每轮 30 次，均满足预设同配方成对门。原始文件摘要与二进制 SHA 记录在 `output/035-development/candidate-rc2/035-window-verified.json`。RC2 `integration.log` 的 3 个用例通过，覆盖应用曝光的线性运算、系统滤镜容差和新核心的滤镜资产绑定。

正式脚本在 `output/035-development/candidate-rc2-formal/` 生成与合并基线同样的 158 个源适用功能 ID。逐 ID 对照在 `035-feature-index.json`。首轮 `summary.json` 报 4 个失败阶段，含 5 个 resident control 中位数、两类原生 inspector 的 4 个中位／p95、综合交互比较 15 个超线项，以及 LightFlow 夹具误设的路径错误。在相同二进制与同一份 native 输出上用仓库 `docs/research/camera-raw-parity/evidence/` 重新独立比较后，`lightflow-comparison-corrected.json` 的 basic、panels、direct 及 photoOperators 均通过各自的比较，只余 74 个组合样本的首个精确结果与最终结果两项超线。两者 RAWMaster p50／p95 为 102.08／512.99 ms，LightFlow 分别为 22.13／210.23 ms 和 23.56／210.23 ms。原始失败保留。各专项后续重新测量须绑定自己的构建与输出。[正式比较器](../../scripts/check-lightflow-performance.py)

### RC3 借纹理的原生窗口

在同一 Release 测试包、同一 9504×6336 Sony RAW、2400×1600 画布，上下两路各做八次真实编辑拖动和一次松手后完整渲染。打开 `RAWMASTER_PORTABLE_METAL_PREVIEW` 的八个交互帧全部记录 Rust 提交及完成，没有回退。默认 Core Image 和试验 Metal 路线的首次绘制分别为 106.86 和 217.38 ms，七个暖帧的 P50 分别为 8.70 和 8.27 ms，P95 为 10.49 和 9.51 ms。停止拖动后的两次 settled 结果单列。Rust 借用已准备的输入和输出 IOSurface，完整画布计时包含后续显示步骤。首次开销与有限的暖态样本支持继续采用实验开关。[双路径样本、构建与源摘要](evidence/native-metal-exposure.json) · [纹理格式、取消与栅栏](evidence/image-metal-iosurface.md)

RC3 真实资料库首屏测量以 v8 快照为源，四份独立副本各导入六张 RAW。空闲／真实导入期间从筛选输入到首张可见照片的 P95 分别为 91.37／91.49 ms，分别有 24／36 个样本，满足 ≤300 ms 门。首次打开含 v9 升级，首图 P95 1,202.41 ms。重开复用已建索引，首图 P95 192.38 ms。测试的原始回执在 `output/035-development/candidate-rc3/library-window.json`。同机 `main` 首次命令在启动阶段抛出 `InvalidTransition`，原日志保留，当前 RC3 首屏结果单独签收。[原生首屏采集](../../Tests/RAWMasterUITests/LibraryGridPerformanceTests.swift)

RC3 的工作台五组成功写盘并关闭编码器。每项中位数在 `output/035-development/export-rc3/rawmaster/results.json`。200 张 JPEG 整批 7.223 秒、首件 0.134 秒。同机合并基线 4.720 秒、首件 0.080 秒。20 张 DNG 整批 0.629 秒，合并基线 0.362 秒。RC3 普通预设相对手调的 P95 为 53.41／52.00 ms，单次结果超出成对门。RC3 的 Classic 暖 P50／P95 为 10.81／15.93 ms。两组窗口各保留原始结果，计时与功能覆盖各自判定。

### RC4 跨视图交付与回归

在[统一导出原型](../../docs/ui/prototype/index.html#export)提交同一张样片的成片，关闭详情回到工作台，检查焦点回到「任务详情」。切回资料库，在任务页打开原收据，核对同一个文件名。22 项整工作台走查通过，含窄窗、浅深色和键盘。日志位于 `output/035-development/prototype-delivery-background.log`。[场景脚本](../../scripts/check-ui-prototype.py)

原生应用会话持有成片批次。从工作台交付两张后立刻去资料库改选第三张，再返回「导出」，仍看到同一个批次。两个文件各自有已完成的 Rust 收据。应用退出或清理已切走的资料库会话时取消并等待原任务。读取批量版本用同一目录快照，实际源文件哈希在快照外校验，版式和编码阶段共享已冻结的原片元数据副本。71 项 Release 定向测试通过，其中工作台与版本交接 4、目录调度 12、成像／版式 34、Prompt 流程与入口 16、提供者与断网 5。原始日志及动态库摘要在 `output/035-development/candidate-rc4/`。[跨视图原生回归](../../Tests/RAWMasterUITests/ExportWorkspaceTests.swift)

RC4 的五组交付均逐轮核对输出件数、尺寸和 ICC。两个构建的首轮暖态各读取 242 个成片，按文件名和 SHA 对拍逐字节相同。总耗时采用一轮预热后三轮中位数。[输入、全部暖样本和成片目录摘要](evidence/workbench-delivery-performance.json)

| 输入 | 合并基线整批／首件（秒） | RC4 整批／首件（秒） |
| --- | ---: | ---: |
| JPEG × 1 | 0.073／0.073 | 0.099／0.099 |
| JPEG × 20 | 0.493／0.077 | 0.803／0.119 |
| JPEG × 200 | 4.720／0.080 | 7.560／0.136 |
| Bayer DNG × 1 | 0.056／0.056 | 0.072／0.072 |
| Bayer DNG × 20 | 0.362／0.059 | 0.614／0.087 |

RC4 工作台把提交与认领、成片核验与最终收据分别合到同一事务，并从实际文件和票据对账。该阶段能恢复已经写出的单张成片。批导出性能仍未达到合并基线。[导出工作台规格](../032-export-workspace/spec.md) · [发布与认领合同](../../Modules/LibraryCatalog/Swift/CatalogTaskQueue.swift)

单线程诊断使用同一 v9 候选动态库，对 10 张相同字节量的独立暂存文件调用 C ABI，单独记录数据准备之外的成本。暖态中位数为提交与领取 3.08 ms、核验及同步暂存 9.70 ms、核验及同步最终文件并提交收据 13.16 ms。此处直接执行事务，不含 SwiftUI、成像或正常排他发布所用的栅栏。原始样本见 `output/035-development/catalog-delivery-abi-profile-idle.json`。

### RC5 文件交付与目录复测

以 RC4 封存的工作台测试包记录 Time Profiler 和 System Call Trace。五组分别预热并运行一次，共捕获 484 次有租约栅栏的排他发布。路径保护共调用 `stat64` 653,400 次。200 张 JPEG 暖态批次的近似时间窗中，栅格化、路径保护和编码的线程样本权重分别为 8,305、2,471 和 1,001 ms。各线程可重叠，权重与系统调用时长均单独记录。[采集边界与调用分布](evidence/workbench-delivery-profile.json)

RC5 在一次目录读快照内收集原始、有效、受管和历史路径，按字节去掉完全相同的路径。准备和实际发布时仍解析每个不同别名。每次调度器开库在同一个快照内核对目录版本并单遍校验已注册的精确 SQLite 定义。ImageIO 已解码的中性 JPEG 缩略图在 I/O 许可释放后进入原有栅格阶段。四 GPU 槽设备可让最多四件符合条件、命名唯一且输出长边不超过 2048 的中性 JPEG 在途，后台仍只占至多三个 GPU 槽。RAW、带框、使用归档成片或有编辑的批次沿用原工作数。ImageIO 按捕获文件的实际类型选择缩略图或完整显影。[目录检查](../../Modules/LibraryCatalog/src/domains.rs) · [工作台调度](../../Sources/RAWMaster/WorkbenchPhotoExport.swift) · [图像阶段](../../Sources/RAWMasterImaging/PhotoBatchRenderExporter.swift)

同设备按 RC5、合并主干、RC4、RC5 的顺序串行运行。每个构建预热一轮，再记录三轮，五组共 3,872 份成片。每组均按文件名核对所有试次的内容摘要、尺寸和 ICC。下表单位为秒，列内为整批／首件的中位数。[构建摘要、成片目录摘要与各轮记录](evidence/workbench-delivery-rc5.json)

| 输入 | RC5 第一轮 | 合并主干 | RC4 | RC5 复测 |
| --- | ---: | ---: | ---: | ---: |
| JPEG × 1 | 0.084／0.084 | 0.076／0.076 | 0.097／0.097 | 0.087／0.087 |
| JPEG × 20 | 0.647／0.113 | 0.522／0.080 | 0.795／0.123 | 0.673／0.114 |
| JPEG × 200 | 5.747／0.129 | 4.795／0.082 | 7.167／0.141 | 6.126／0.134 |
| Bayer DNG × 1 | 0.063／0.063 | 0.059／0.059 | 0.076／0.076 | 0.066／0.066 |
| Bayer DNG × 20 | 0.589／0.074 | 0.361／0.061 | 0.646／0.099 | 0.636／0.093 |

200 张 JPEG 的两轮整批比同场 RC4 分别快 19.8% 和 14.5%，峰值常驻分别为 829,024 和 828,016 KiB，合并主干为 816,432 KiB。首件和整批均仍高于合并主干。快照迁移、别名在准备后改指、无覆盖检查、版式、元数据、工作台和编辑交接共 23 项 RC5 定向 XCTest 通过。macOS／Linux 的 Rust 目录测试分别有 69／68 项通过、各 5 项外部输入用例按环境跳过。原始报告见 `output/035-development/{candidate-rc5,catalog-rc5-macos.log,catalog-rc5-linux.log}`。

单独把 `J001.jpg` 制作成保留 ICC 的 EXIF 方向 8 输入。两个构建的冷暖成片均为 1365×2048、方向已应用，ICC 和成片 SHA 均相同。五组共 968 个成片逐字节一致。原始回执在 `output/035-development/export-rc5-rotated-comparison.json`。隔离的 C ABI 交叉采样中，`capabilities` 中位数由 RC4 的 1.685／1.744 ms 降为 RC5 的 1.432／1.446 ms。其余提交和文件操作同时受数据库和文件系统影响，保留各次实测在 `output/035-development/abi-candidate-rc{4,5}.*`。

以同一批 200 张 JPEG 缩略图直接比较 Core Image 与 Core Graphics 两种 8 位栅格化。RGB 码值一致，计时中位数分别为 3.67 和 4.95 ms，当前仍用 Core Image。该专项在独立进程串行运行，包含首帧，不含解码和编码。原始数据在 `output/035-development/jpeg-raster-probe/compare.json`。

RC7 使用同一输入清单、预热一轮和三轮记录复测。200 张 JPEG 的整批／首件中位数为 5.976／0.131 秒，合并主干为 4.795／0.082 秒，仍未达到基线。五组共 1,936 份冷暖产物按文件名和摘要完全相同。[RC7 默认交付复测](evidence/workbench-delivery-rc7.json)

RC7 依同一采集协议再次跟踪到 484 次排他发布。跟踪时暖态 200 张 JPEG 为 5.928 秒，RC4 为 7.590 秒。五组路径保护的 `stat64` 从 653,400 次降到 223,608 次。暖态 200 张的路径保护／目录注册表校验线程样本权重从 2,471／237 ms 降到 860／64 ms，ImageIO 缩略图和栅格化合计仍为 8,219 ms。[两次跟踪的相同采样口径和文件调用](evidence/workbench-delivery-profile.json)

逐栈归因显示，暖态 200 张的 ImageIO 缩略图、Core Image 位图和输出布局分别为 7,665、532 和 22 ms。另用独立探针核对 200 个真实文件。直接重排指定 XRGB8 缓冲与 Core Image 输出的 1,677,312,000 个 RGB 分量相同，成片摘要全部相同。相同两种 sRGB 色彩描述通过全 RGB8 色表，Display P3 替换为同一重排时有 47,411,629 个分量不同。四 worker 分阶段实验保留源捕获和末端哈希，将已读取的压缩数据交给纯 CPU 缩略图阶段，A/A 为 3.636／3.692 秒，B/B 为 2.913／2.986 秒，800 个文件摘要相同。该耗时测量覆盖了图像阶段与资源队列。正式工作台时长还包括目录事务和外部发布。[调用栈、性能及像素对照](evidence/workbench-raster-diagnostic.json)

### RC4 正式发布套件

用 `--test-products-dir` 重放同一份封存 Release，当前 `test-build.json` 的两个测试二进制摘要与定向测试构建完全一致。正式目录 `output/035-development/candidate-rc4-formal/` 的逐 ID 校验仍为 158 个适用项，包含真实输出参照／场景参照 DNG、37 个 photo operators、RAW9、X-Trans 和整图 2× TIFF16。正式 `summary.json` 保留四组性能未过门。Resident controls 的 `effects-dehaze` 中位数 13.53 ms，门槛 12.66 ms。检查器的 `light-clipping-modifier` P95 11.15 ms，门槛 9.65 ms。FlashRaw 综合交互还有 10 个中位数超线项。74 组对齐输入的首个精确缓冲和最终缓冲 P95 均为 518.96 ms，LightFlow 为 210.23 ms。首个出现变化的完整 sRGB 缓冲 P95 为 18.91 ms，对应参照为 188.08 ms。[全流程命令](../../scripts/test-image-performance.sh) · [逐 ID 检查](verify-acceptance.py)

RC5 用封存主干与候选测试包，在同一 9504×6336 RAW 上交替测量中性、目标 HSL 和局部曲线。每个构建和日志模式运行两轮，每轮三帧。关闭阶段日志时，主干／RC5 中位数分别为 1.67／1.80、4.59／4.28、7.00／6.67 ms。打开日志时分别为 1.71／1.75、4.19／4.22、7.33／7.26 ms。输出尺寸以及交互相对精确帧的 P99 与最大通道误差在各轮相同。该专项单独复验两项曾在全序列超线的操作，正式阶段结论仍以完整工作负载为准。[构建、RAW 摘要和阶段样本](evidence/interactive-targeted-crossover.json)

同一 RAW 和正式局部纹理／清晰度的四个冻结状态，全幅有限值校验在实际正常入口占 270–336 ms。独立探针对原惰性图使用正反顺序比较，每格十次。全宽分带的归约中位数为 105–147 ms，串行分块为 269–330 ms。峰值由 2.05–2.11 GiB 升至 2.84–3.08 GiB。160 次显示读回均使用原图，命中各自的正式 SHA。将完整 RGBA32F 中间图改作显示源会改变四个状态的显示 SHA。

维持 1024×1024 分块和逐块等待，仅将清理上下文的频率改为每两块一次，四态归约中位数分别从 268.7、268.4、320.1、349.5 ms 降至 243.8、231.8、290.9、288.2 ms。双任务在途的另一组实测没有稳定的额外收益。4 轮交叉实验中，560 个分块结果逐位相等，20 处非有限值和 8 次取消通过。当前结果是边界一致的独立 PoC，完整首次精确帧及混合负载仍需使用生产调用复验。[完整分带与原分块实验](evidence/finite-spatial-probe.json)

RC7 以同一封存 Release 交替开关试验，仅限主画布、原生 FlashRaw、2400 FIT 定稿及单一径向纹理或清晰度。在正常 `ImageEngines.editing` 入口读取完整 sRGB 缓冲，每态每开关有 24 个独立进程。四态首次精确帧 P50 从 455.39／447.17／854.56／510.52 ms 降至 425.92／418.85／811.86／471.60 ms，所有首帧与最终像素摘要及蒙版分区摘要一致。开关两组的进程物理峰值最大值分别为 3,393,915,040／3,387,951,240 B。阴性颗粒用例、所有校验的块数顺序、边界撤销和 C ABI 校验均通过。当前通过 `RAWMASTER_QA_LOCAL_BAND_PAIR_CLEAR=1` 试用，默认继续逐块清理。[RC7 正常入口、样本及峰值](evidence/paired-clear-rc7.json)

最终目录 Rust 套件在 macOS 有 68 项通过，在 Linux arm64 有 67 项通过，均包含 10 项队列测试。冷读历史快照升级保持 6,928 个资产、1,408 个选片 ID 的完整顺序和 11 个编辑版本。真实备份内容还原及失败场景单列。[目录与双端回执](evidence/catalog-production.md)

最终两组 Adaptive 复跑由同一冻结 RC4 UI 测试包执行，四张实际输出和对照 TIFF 的来源、蒙版与文件摘要通过独立核对，蒙版外最大差为 0。把 `--release-dir` 与 `--adaptive-dir` 一起传给校验器，会确认渲染、回执和正式测量都引用同一 UI 二进制。组合回执在正式目录的 `035-feature-and-adaptive-index.json`。[校验程序](verify-acceptance.py)

`035.4` 的独立 macOS 候选包已通过 `codesign --verify --deep --strict`。用独立 bundle ID 重签的启动副本加载自己的两套 Rust 动态库，并在隔离位置创建 v9 资料库与调度器。启动副本的动态库字节与候选包一致，主程序的 Mach-O UUID 一致。[签名、构建与启动回执](evidence/release-package.json)

跨进程整批续做已按同一回执完成工作台原型。31 项浏览器回归通过，其中 9 项涉及中断、已发布待确认、卷离线、逐张失败及重试、同名冲突、终态取消、焦点和回到原工作台。[续做操作与浏览器回执](../032-export-workspace/batch-continuation.md)

原生工作台也通过从出票前、出票后、排他发布后待确认三个断点重启。独立校验核对原版本顺序、当前选片、目标目录替换拒绝、原片接回、旧成片及九份最终输出。新候选通过 12 项原生工作台、版本交接和预设用例，包括两批同时导出同名照片并取得各自文件名。引入逐项回执后首轮 200 JPEG 中位整批为 12.317 秒，首件为 4.027 秒，同源产物摘要相同。Instruments 首件前可归因的配方暂存线程样本权重为 771 ms，正式登记为 36 ms。此轮新增真实恢复证据及性能回退均计入后续验收。[原生重启](evidence/workbench-native-restart.json) · [同批文件摘要和跟踪](evidence/workbench-delivery-batch3.json)

后续候选把 1 MiB 内的中性批次配方内联冻结，200 张 JPEG 暖态整批／首件中位数为 8.206／0.162 秒。此前逐张暂存为 12.317／4.027 秒，同机主干为 4.795／0.082 秒。主干和候选五组共 1,936 份输出逐文件一致。中性内联的三个重启场景也达到逐字节一致，只有内联记录的编辑备份恢复为历史记录。最新版通过 12 项工作台、39 项资料库及备份测试，后者包含从实际 v8 快照升级。[导出比较](evidence/workbench-delivery-batch5.json) · [新版重启及备份回执](evidence/workbench-native-restart.json)

两个含草稿编辑的 v2 重启系列中，已准备与已发布再打开的成片摘要一致，各系列真实文件均匹配自身 Rust 票据。把出票前中断并恢复这一路径与另两个独立运行相比，每个系列各有一张全尺寸 JPEG 的摘要不同，分别涉及 215 和 99 个 RGB8 分量，最大绝对差为 4 和 2。独立解码显示每张存在差异的照片中只有一个 JPEG 量化块有变化。跨运行逐字节验收仍未通过。[原路径票据、SHA 与像素差](evidence/workbench-restart-advanced-precision.json)

两次出票前中断留下的第二张暂存文件与各自续做时重渲染的成片逐字节相同。上述差异发生在独立运行之间。用同一成像图和 Rust 编码器复现含曝光调整的两份 JPEG，2,801,664 个编码前 RGBA8 字节中有两个绿色分量各差 1。默认 GPU、显式同一 Metal 设备和软件 Core Image 的定向试验仍不足以确定差异的触发条件。[编码前像素和同批回执](evidence/workbench-restart-advanced-precision.json)

把已验证的中性小 JPEG 压缩数据在 CPU 阶段解码后，新工作台 200 张暖态两次均值从 8.239 秒降到 7.306 秒。EXIF 方向 8 和 ICC 样本为 8.431／7.484 秒。相同封存构建的六轮共 2,904 个冷暖文件与各自对照、合并主干逐一相同，RAW 组也核对通过。程序显式持有的压缩输入全程限定 8 MiB，超额沿用原路径。专项通过 `RAWMASTER_QA_CPU_JPEG_THUMBNAIL=1` 运行。[同构建开关计时及输出对照](evidence/workbench-thumbnail-split.json)

普通入口对 20 张及以上符合条件的中性 JPEG 从第二张起启用缓冲解码，输出长边不超过 2048。封存候选的 200 张整批／首件中位数为 7.047／0.172 秒，968 份文件逐字节对应主干。另测在完成编码与出票后扩大在途范围，4／6／8 项的整批均值为 7.234／7.038／6.999 秒，首件均值为 0.160／0.185／0.206 秒，2,904 份文件相同。当前实施选择四个在途项。[默认交付数据](evidence/workbench-delivery-default-batch7.json) · [在途范围试验](evidence/workbench-queue-depth-probe.json)

### RC6 原生混合负载

以同一封存 Release 运行真实本机 Quick Prompt、200 张 JPEG 成片和 20 张 Bayer DNG 入库。等到首件成片实际发布及第一张 DNG 写入目录后，在另一原生画布输入 +0.42 EV。精确画布绘制耗时 16.78 ms，完成时两组文件任务尚在处理。导出从冻结完毕到全部收据确认耗时 7.063 秒，首件为 0.118 秒。独立复核逐路径匹配 200 个成片和 Rust 最终收据，全部字节也与单独运行的合并主干相同。

FLUX Q8 子进程的模型流水线耗时 157.24 秒，峰值 MLX 活跃内存 8,501,400,908 B。XCTest 宿主的进程常驻高水位为 970,539,008 B。实际结果经原生控制器保存、采用、撤销并重新打开，786,432 个保护像素保持原值。此轮包含一份画布样本，混合负载的多轮尾延迟、语义蒙版及物理卷拔插另行验收。[同一时间轴、构建及逐文件复验](evidence/mixed-workload-flux.json) · [原生用例](../../Tests/RAWMasterUITests/LiveFlux035Tests.swift)

同份 RC6 封存测试包也完成正式套件、四次真实 Adaptive 重放和本机 FLUX 的合并核验。158 项适用 Camera Raw 功能有对应实测，四张 Adaptive 成片的冻结蒙版、原片及 TIFF16 保护像素通过。正式性能报告的四个失败阶段为画布缩放平移、综合交互、控件，以及 LightFlow 首次精确与最终读回。两张照片缩放平移 P95 为 12.02／11.32 ms，阈值为 8.00／8.44 ms。74 个组合状态的第一个变化帧 P95 为 15.48 ms，首次精确和最终读回均为 477.94 ms，后两项阈值为 252.27 ms。颜色检查器这轮通过。[封存构建、逐项失败和功能核验](evidence/native-release-rc6.json)

### RC7 原生 Sky 与三视图混合负载

相同的封存 Release 连续启动 8 个独立原生进程。每进程运行一次新建 Sky 蒙版、20 张 Bayer DNG 入库、200 张 JPEG 导出以及另一张照片的 30 个曝光调节。60 次调节从输入到实际 AppKit 绘制返回完整落在三项任务的活动窗口，中位数 17.84 ms，P95 为 47.81 ms，最大值为 53.08 ms。每次 Sky 均调用 FlashRaw 与一个本机景观模型，冻结覆盖摘要一致。独立进程读取 1,600 份输出，逐路径、逐文件名核对 Rust 回执和主干输出，目录均无待处理任务。[时间轴、掩模诊断及逐次实测](evidence/mixed-workload-sky.json) · [原生用例](../../Tests/RAWMasterUITests/LiveFlux035Tests.swift)

缩略图阶段在新版持久工作台上用同一 Release 的八个独立进程交替复测。关闭／开启的导出中位数为 8.189／7.251 秒。重叠画布有 42／44 帧，输入到实际 AppKit 绘制的中位数为 17.01／17.56 ms，P95 为 35.50／36.70 ms。首件中位数为 120.6／141.9 ms。峰值 RSS 为 2,596,028,416／2,609,168,384 B。每轮生成新的 Sky 覆盖，1,600 个实际文件都与新版 Rust 票据和合并主干相符。[缩略图阶段的原生混合对照](evidence/mixed-workload-thumbnail-split.json)

正式发布仍需在目标 Linux 物理 Vulkan 设备验证 GPU，复验原机可移动卷重新挂载，并通过各交互及交付性能门。快速 Prompt 的试拍质量按 034 的摄影师、留出样本和可访问性流程签收。[034 发布门](../034-quick-prompt-editing/native-validation.md#发布门)

### 降噪优化前的正式性能

在最终封存构建中，整组画布性能用例通过，综合交互、单项控件和 LightFlow 对照仍有超线。74 个组合状态中，第一个变化帧 P95 为 22.83 ms，首次精确帧和最终读回均为 517.47 ms，后两个指标的上限为 252.27 ms。综合交互的七项失败包括目标 HSL、镜头模糊泡泡和两项局部颗粒计时。控件失败项包括去雾中位数 13.36 ms 对 12.66 ms 上限。

同一封存构建已核验 158 项适用 Camera Raw 功能、四次真实 RAW Adaptive 重放和一次本机 FLUX Q8。FLUX 在当前原生工作台运行时，另一张照片的曝光调节到 AppKit 绘制耗时 15.28 ms，200 张 JPEG 和 20 张 Bayer DNG 的实际任务都尚未结束。FLUX 保护区域的 786,432 个像素均保持原值，200 张导出逐路径匹配原 Rust 票据和主干。[正式性能和功能联合回执](evidence/native-release-batch9.json) · [本机 FLUX 与混合工作](evidence/mixed-workload-flux-batch9.json)

当前默认 200 张 JPEG 的整批／首件时间中位数为 6.688／0.174 秒。同机合并主干为 4.795／0.082 秒。五个负载组各自预热一次、测三次，候选与主干各有 968 份冷暖产物，按名称和 SHA 逐文件一致。[正式候选默认导出比较](evidence/workbench-delivery-default-batch9.json)

### 首次精确画面的分段复验

在 Apple M4 Max 上，对同一张 9504×6336 Sony RAW 的正式配方逐段计时。已驻留源上的曲线、蒙版曝光和 LUT 强度每帧约花 37 ms 生成 sRGB `CGImage`。纹理、去雾和降噪的这一阶段约花 140 ms。独立位图复制约花 2.4 ms。复用 `CIContext` 使重型配方变慢，最高进程物理内存升至约 5.00 GB。直接写入独立位图的四轮共 296 个状态通过完整首帧与定稿 SHA 核对，三组合成 HDR、透明度、方向和旧帧读回也逐字节一致。其完整定稿 P95 与原路径接近。这两种试验均停留在 PoC。[分段数据和完整像素核验](evidence/first-exact-native-stages.json)

原生预览现在默认在符合条件的 FlashRaw 纯降噪定稿使用分带归约。入口要求主画布 2400 像素、默认几何、已驻留原图、512 MiB 上下文和至少 32 GiB 系统内存，原图上限为 67,108,864 像素。FlashRaw 的九点降噪、Core Image 的固定半径 Gaussian 细节分支和最终显影都沿用原图。每个任务用完整显影图生成有限性标记，Metal 检查每个像素。分带的工作集计费上限为 128 MiB，完成后读取分组标记。异常、取消和源变更沿原入口返回，已提交工作完成后释放资源。资源不足时使用原逐块校验。`RAWMASTER_CANONICAL_RAW_NOISE_BANDS=0` 可做同包对照。[分带实现](../../Sources/RAWMasterImaging/DevelopmentCanonicalFiniteGPU.swift) · [原生预览接入](../../Sources/RAWMasterImaging/PreviewNativeSource.swift)

| 原片 | 四个降噪状态的定稿到完整读回 | 逐像素与内存核验 |
| --- | --- | --- |
| 9504×6336 Sony RAW | 每轮中位数 472–502 ms 降至 242–261 ms | 整组 74×4 状态的首帧和最终 RGBA8 均匹配。A/B 最大进程物理内存相差 416,661,432 字节。每次目标归约检查 60,217,344 个像素 |
| 8640×5760 Sony RAW | 每轮中位数 389–414 ms 降至 190–195 ms | 对照组和启用组的首帧和最终 RGBA8 均匹配。两次启用组的峰值低于两次对照组。每次目标归约检查 49,766,400 个像素 |

Gaussian 夹具在分带边界两侧和末像素注入 NaN、正无穷和负无穷，两条校验路径均拒绝。两带提交后取消，清退后同一进程重试成功。表中耗时从单次定稿请求到完整像素读回。正式 LightFlow 门使用一次时钟记录首次互动提交至可读的精确缓冲，另行判定。[逐状态回执](evidence/first-exact-native-stages.json) · [分段复现入口](../../scripts/performance/run-settled-stage-profile.sh) · [正式计时入口](../../Tests/RAWMasterImagingTests/PanelDisplayReadbackTests.swift)

### 降噪优化后的封存 Release

正式 74 个状态的首帧和定稿均与上一候选逐状态匹配。四个降噪状态从首次互动到精确画面用时为 241–282 ms，上一候选为 475–500 ms。组合首次精确及最终读回 P95 从 517.47 ms 降至 456.85 ms，上限为 252.27 ms，中位数为 102.63 ms。首个变化 P95 为 16.89 ms。综合交互、单项控件、检查器和 LightFlow 比较门仍有超线项，正式脚本退出 1。[正式性能及逐状态结果](evidence/native-release-batch10.json)

同一封存构建通过 4 项有限值与原生源证明测试、12 项工作台测试、158 个适用 Camera Raw 功能 ID、天空和主体各两次真实 RAW Adaptive 重放，以及本机 FLUX Q8 的编辑、采用、撤销和重开。FLUX 选区外的 786,432 个保护像素逐一相等。另一张照片的曝光到 AppKit 绘制耗时 16.22 ms，此时 200 张 JPEG 导出和 20 张 Bayer DNG 导入都在进行。导出逐文件与 SQLite 交付票据及合并主干匹配。[同包功能回执](evidence/native-release-batch10.json) · [FLUX 与并行文件任务](evidence/mixed-workload-flux-batch10.json)

### 局部蒙版分带试验

在同一张 9504×6336 Sony RAW 上，取局部颗粒、降噪、锐化、纹理和清晰度各两个已验配方，比较原逐块校验与 64／128 MiB 分带。50 次独立归约的定稿都匹配原始显示摘要。128 MiB 的两轮里，局部降噪用时为 35–39 ms，原逐块为 228–248 ms。六组分带故障各拒绝八处注入的非有限值，并完成取消与恢复。纹理和清晰度的部分浮点中间值随取样区域而变化，最终显示沿原显影图求值。[独立探针与故障回执](evidence/limited-local-mask-bands.json)

用链接到同一 Release 实现的探针从正常编辑入口跑四轮 74 状态。十个目标定稿每轮中位数由 418–427 ms 降至 246–253 ms。全部 296 个状态的首帧和定稿 RGBA8 匹配。启用组的每个目标定稿各执行一次最终蒙版合成的 60,217,344 像素归约。启用两轮的进程物理内存峰值为 5.20–5.26 GB，对照为 4.68–4.89 GB。两对进程分别增加 575,700,920 和 301,940,736 字节。此路径以 `RAWMASTER_QA_CANONICAL_LOCAL_MASK_BANDS=1` 试用，范围限于主画布定稿、单径向和已验证的局部算子。较高的实测内存峰和浮点分带边界仍需复核。[正常入口和逐状态时间戳](evidence/limited-local-mask-bands.json) · [资格与最终合成校验](../../Sources/RAWMasterImaging/DevelopmentMaskEngineV3.swift)

另用同一 XCTest Release 运行 37 项完整画面读回，两组各 814 个首次及暖态样本的首帧和定稿摘要匹配封存参照。计时从首次互动请求到精确缓冲可读，十个目标状态中位数从 450.41 ms 降至 285.87 ms，组合 P95 从 456.93 ms 降至 403.02 ms。12 项原生有限性、蒙版和源证明测试通过。总串行开关阻止局部分带，两个局部试验同时指定时每个定稿只执行一次分带归约。[同包 XCTest 对照](evidence/limited-local-mask-bands.json)

### 去雾与锐化的原生预览

在启用原生去雾、至少 512 MiB 预览上下文且支持统一内存的设备上，正常 RAW 开片会保留一份已逐字节核验的私有副本凭据。驻留去雾定稿核对只读文件描述符、当前路径、文件身份及纳秒级时间戳，以本次开片取得的 RAW 解码事实和当前 Classic 资源版本重新核对已准备配方。复用上下文核验约需 1 ms，原来约需 74–79 ms。独立进程替换私有测试包的 Classic 目录后，正常入口拒绝旧配方。同一源的租约共享一份描述符，最后一次关闭和捕获失效均回收。用 `RAWMASTER_NATIVE_DEHAZE_VERIFIED_CAPTURE=0` 做同包对照。[来源核验与隔离资源测试](evidence/native-dehaze-sharpen-transport.json) · [捕获证明](../../Sources/RAWMasterImaging/DevelopmentService.swift) · [真实开片测试](../../Tests/RAWMasterImagingTests/DevelopmentVerifiedDehazeCaptureTests.swift)

至少 32 GiB 统一内存、尺寸不超过 9504×6336 的正向 RAW 驻留去雾使用原 256 行带，逐带完成、校验、复制，每两带清理一次上下文缓存。末带或退出时立即清理。主样片 240,869,376 B 的 R32F 引导图完整摘要一致，独立跑四轮的填图中位数从 688.20 降至 561.46 ms。`RAWMASTER_NATIVE_DEHAZE_PAIR_CLEAR=0` 恢复每带清理。带符号 V1 继续使用每带清理。[分带计时、全幅回读与取消重试](evidence/native-dehaze-sharpen-transport.json) · [驻留引导图实现](../../Sources/RAWMasterImaging/DevelopmentResidentDehazeGuide.swift)

共享 R32F 纹理作为 `RAWMASTER_QA_RESIDENT_DEHAZE_TEXTURE=1` 试验，仅用于主画布、2400 像素定稿、512 MiB 校验上下文内已准入的正向 RAW 去雾。写入前按 Metal 行距和页对齐计费，每带完成且整幅校验通过后才导入纹理，按缓冲区物理行的方向校正纹理视图。原 512 MiB 显示路径在首张试片的两档强度分别造成 1,118 和 1,205 个实际像素产生至多 1 个 RGB 码值偏差。两张 RAW 各两档强度在独立 640 MiB 显示上下文中恢复原摘要。实际显示前释放校验上下文的缓存并核对设备剩余容量，原图和引导图保持至真实读回结束。正常入口验证过取消、等待清退、重试和比较视图。[不同显示内存目标的读回与偏差](evidence/native-dehaze-sharpen-transport.json) · [主画布准入](../../Sources/RAWMasterImaging/DevelopmentPreviewService.swift)

| 原片与计时边界 | 两项默认去雾优化显式关闭 | 两项默认去雾优化启用 | 加开共享纹理试验 |
| --- | ---: | ---: | ---: |
| 9504×6336，引导图已驻留，新强度的定稿请求到完整读回 | 340–347 ms | 261–284 ms | 106–109 ms |
| 8640×5760，正常准备后，第二档首次互动请求到完整精确读回 | 273–282 ms | 205–220 ms | 106–122 ms |

封存 Release 的第一张 RAW 有八轮三控件对照。96 张互动首帧或定稿逐张匹配参考。开启共享纹理后，37 个算子的 814 对首次及暖态首帧与定稿均匹配。第二张 RAW 每轮重新准备，关闭、默认、共享纹理各两次，合计 132 对完整读回相同。[逐状态摘要与时钟边界](evidence/native-dehaze-sharpen-transport.json)

纯全局锐化与灰阶锐化蒙版的两个定稿状态用 `RAWMASTER_QA_CANONICAL_SHARPEN_BANDS=1` 试验 64 MiB 分带归约。每次检查全部 60,217,344 个原生像素，校验约需 63–72 ms，原路径约需 210 ms，定稿摘要一致。定向进程的最大峰值增加约 569 MB，试验默认关闭。[锐化校验及进程峰值](evidence/native-dehaze-sharpen-transport.json) · [分带预算](../../Sources/RAWMasterImaging/DevelopmentCanonicalFiniteGPU.swift)

可使用正式报告里的冻结配方复现正常预览。分别设置以上开关，每次使用新的输出文件。完成后的读回摘要应与同一原片的 `photo-operators-v2.json` 对照。[逐阶段探针](../../scripts/performance/run-settled-stage-profile.sh)

```sh
RAWMASTER_QA_CANONICAL_STAGE_TIMING=1 \
  scripts/performance/run-settled-stage-profile.sh \
  "$OPERATOR_RAW" "$RESULT/photo-operators-v2.json" "$NEW_REPORT" effects-dehaze detail-mask-preview
```

### 去雾优化后的封存 Release

封存候选 `batch11r` 的 74 个组合状态各有完整首帧与定稿，37 项的 814 对读回均匹配前一候选。第一变化帧 P95 为 18.14 ms，通过 LightFlow 对照。首次精确帧和最终读回的 P50 为 102.14 ms，P95 为 465.35 ms，P95 上限为 252.27 ms。正式套件退出 1，失败阶段涵盖画布缩放平移、综合交互、单项控件、面板读回、LightFlow 精确读回、检查器和超分辨率的导出内存。[正式门槛和各阶段回执](evidence/native-release-batch11r.json)

同包交替复测关闭和开启三项预览试验。每轮 814 对完整首帧与定稿均匹配。两轮对照的首次精确 P95 为 483.36／514.51 ms，两轮试验为 307.29／327.43 ms，试验组中位数为 98.61–99.58 ms。另对两项默认去雾优化做关闭和启用各两轮，画布每组各一次通过、一次超线，四轮超分辨率专项通过。诊断轮和原正式失败均归档。[同包交替对照](evidence/native-preview-release-diagnostics.json)

同一封存包通过 158 项适用 Camera Raw 功能索引核验、真实 RAW 的天空及主体 Adaptive 各两次，以及本机 FLUX Q8 的编辑、采用、撤销和重开。786,432 个未选中像素逐一一致。另一张照片的曝光输入到 AppKit 绘制为 17.12 ms，20 张 Bayer DNG 导入和 200 张 JPEG 导出当时均在进行。独立检查将 200 张 JPEG 逐一匹配到 Rust 交付票据及合并主干的文件摘要。[封存功能回执](evidence/native-release-batch11r.json) · [本机 FLUX 并行验收](evidence/mixed-workload-flux-batch11r.json)

### 冷去雾直接写入 GPU 的 PoC

从同一封存实现链接独立探针。保持正向引导图和 256 行带，改为逐带写入私有 R32F 纹理。两张真实 RAW 各做四轮交替。主样片的引导图生产分别用时 544–597 ms 和 513–518 ms，第二张分别用时 497–503 ms 和 438–445 ms。两者都计至生产任务完成。原路径计入逐值校验和复制，试验在计时前分配纹理并初始化哨兵，在计时后做 Metal 全幅读回及逐值校验。两张 R32F 引导图及两档共 16 张显示输出逐字节匹配。67×519 夹具含 7 行尾带，34,773 个有效像素均匹配，NaN 哨兵全部被覆盖。单次整图提交用时 273 ms，完整 R32F 摘要发生变化，停用该试验臂。[两张 RAW、短尾带和反例](evidence/native-preview-release-diagnostics.json)

### 原生去雾直写与蒙版校验

`batch12` 从正常主画布定稿入口接入默认关闭的 `RAWMASTER_QA_RESIDENT_DEHAZE_DIRECT_TEXTURE=1`。按 256 行填充有预算的私有 R32F 纹理，GPU 扫描全部样本，拒绝哨兵漏写、NaN 和正负无穷。CPU 仅读取每组校验码，全部 GPU 工作结束且来源和请求仍有效后才能发布缓存。以 67×519 验证缺带、七行尾带与最后一行。实机预览在初始化命令完成后取消，清退后重试，定稿摘要匹配，比较视图走原路径，会话关闭后没有驻留条目。两张真实 RAW 的完整引导图分别通过 240,869,376 B 与 199,065,600 B 的字节摘要核验。[实际纹理与取消回执](evidence/native-direct-guide-and-point-mask.json) · [Metal 生产与校验](../../Sources/RAWMasterImaging/DevelopmentDirectDehazeTexture.swift)

两张 RAW 各交替跑四个原生进程。与共享缓冲纹理试验相比，主样片的冷态首次精确读回由 994–1,019 ms 变为 904–969 ms，第二张由 898–927 ms 变为 739–787 ms。每轮对同一 RAW 的两档去雾取 22 对首帧与定稿，共 176 对，逐字节匹配。[真实读回时钟与独立分段](evidence/native-direct-guide-and-point-mask.json)

`RAWMASTER_QA_CANONICAL_POINT_MASK_REGION=1` 仅在实际主画布定稿中使用，适用于源为同一个已通过全域校验的驻留 FlashRaw 图、配方仅有单个合格径向点式蒙版的场景。按照原着色器的 Float32 坐标为可能覆盖的区域留出边界，在完整图上建立标记，按原生绝对坐标进行归约。主样片的归约由 60,217,344 个像素缩至 25,340,348 个像素，同包阶段中位耗时为 17.35–18.81 ms 与 12.22–12.87 ms。主样片 16 态首次精确中位为 73–76 ms 与 68–70 ms。第二张的亮部和白场在两臂都没有通过固定中心取样区的空间判据，完整首帧、定稿及取样区摘要仍逐对相同。两项试验同时开启时，完整 37 算子的 814 对读回均与上一候选一致。[区域资格、像素与计时](evidence/native-direct-guide-and-point-mask.json) · [区域实现](../../Sources/RAWMasterImaging/DevelopmentMaskEngineV3.swift)

同源中性底图与当前蒙版图的外围比较出现 25,766 和 44,366 个像素差异，最大为 1 个 RGB 码值。两个样本复用上一张已验定稿并保留原左上角后，后续各 15 张完整输出匹配，显示阶段只节省约 3 ms，保留为独立探针。直接单点和四邻点 FIT 的 128 次输出均与原始缩小不同。显式高质量缩小的 8 张输出与默认逐字节一致，显式低质量缩小均变化。全尺幅 RGBA32F 落纹理再缩小在主样片仍有约 3,000 个像素变化，亦停留在独立对照。[显示采样与中间纹理对照](evidence/native-direct-guide-and-point-mask.json)

### Batch 12 正式门与功能回执

默认关闭两项试验，用同一封存构建跑正式性能套件。37 算子的 814 对完整首帧、定稿和取样区摘要都与 Batch 11r 匹配。74 态首次可见变化的中位和 P95 为 5.00／16.10 ms，门槛为 8.28／225.69 ms。首次精确与定稿均为 98.03／500.67 ms，首次精确门槛为 24.35／252.27 ms，定稿门槛为 25.92／252.27 ms。`image-pipeline`、`interactive-comparison`、`control-comparison`、`lightflow-comparison` 和 `inspection-comparison` 共五项超线，发布性能门未通过。[默认正式套件](evidence/native-release-batch12.json)

同一封存构建复核了 158 个适用的 Camera Raw 功能 ID。两张真实 RAW 各跑一次天空和主体 Adaptive，四份实际成片通过核验。本机 FLUX Q8 的局部编辑经过采用、撤销与重开，786,432 个选区外像素逐一保持一致，选区内 262,144 个像素有变化。20 张 RAW 导入及 200 张 JPEG 导出同时进行时，另一张照片的曝光输入至 AppKit 完成绘制定稿用时 15.53 ms。200 张 JPEG 全部匹配 Rust 交付票据与合并主干的单独导出文件。此处的 AppKit 绘制计时和 74 态正式对比使用各自的既定边界。[功能核验](evidence/native-release-batch12.json) · [实际模型与文件混合负载](evidence/mixed-workload-flux-batch12.json)

### APFS 卸载与重挂

在工作区自建的 APFS 磁盘镜像上，用正常导出入口提交三张照片，在第二张成片已发布、Rust 收据待确认时终止测试进程。两轮均实际卸载原卷，Rust C ABI 得到目录缺失。在同一挂载点换用不同 UUID 的卷并放入前两张成片的相同字节，Rust 拒绝授权。原卷以同一个设备号重挂的对照完成了全部三项，批次推进至第 3 代，前两张成片的 SHA-256、inode 与出生时间均保留。[实际卷、C ABI 与完整续接回执](evidence/workbench-apfs-remount-batch12.json)

另一轮由占位镜像使原卷重挂后的 `st_dev` 从 16,777,246 变为 16,777,250。原挂载点、APFS 卷 UUID、目录 inode 与出生时间均一致。Rust 拒绝重新授权，原生入口返回 `targetOffline`，批次停在第 1 代 `interrupted`。三项收据和前两张成片均保留，第三张未写出。此缺陷阻塞设备号变化时的导出续接。实体外置卷的断电或物理拔插仍待验收。[改号用例与单项收据](evidence/workbench-apfs-remount-batch12.json) · [当前目录身份实现](../../Modules/LibraryCatalog/src/scheduler/batch/directory.rs)

对同两份镜像做只读 PoC。用 `fgetattrlist` 从卷根、导出目录和已发布 JPEG 的文件描述符分别读取 `ATTR_VOL_UUID`。原卷改号后 UUID、对象 inode 和出生时间一致，替代卷复用旧 `st_dev` 与 `fsid` 时返回自身 UUID。该结果证实本机 APFS 夹具可从持有的文件描述符取得卷身份。目录授权、票据确认及文件名占位的格式尚未引入该值。[描述符 PoC 与原始返回](evidence/workbench-apfs-remount-batch12.json) · [Darwin `getattrlist(2)`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlist.2)

Batch 13s 的 v10 构建在真实 APFS 镜像上通过三种续接。第二张已发布待确认时断开原卷，重挂原卷以新设备号完成三项，前两张的 SHA-256、inode、出生时间不变。同一路径放入另一卷和相同字节的 JPEG 时，目录授权被拒。另一次在第二张准备完成后断开，原卷同时更改设备号和挂载路径，重开后从中断前票据发布第二张，使用的是原暂存文件 inode。最后一次将 SQLite 资料库也放在原卷，资料库和目录一同改号后能重新授权和完成。三组都保留原批次所用的配方、顺序和当前选片。[五组原生回执与卷身份](evidence/workbench-apfs-remount-batch13s.json) · [浏览器与原生对照](../032-export-workspace/batch-continuation.md)

用封存的 v9 写入者再做两轮。原设备号保留时，升级把既有票据与旧占位保留，通过重新授权及正常续接。故意移除一条旧占位时，升级整体回滚，原 v9 目录与已发布文件保持一致。改号对照升到 v10 后仍返回 `targetOffline`，两个已有文件及第三张的待办都保留。实际 v8 库副本升到 v10 后 6,928 个资产与 1,408 个有序选片 ID 保持一致。Rust macOS 90 项与 Linux arm64 89 项通过，各有 5 项原有忽略测试。[旧写入者、升级快照和测试日志](evidence/workbench-apfs-remount-batch13s.json)

原生回执覆盖应用独占暂存目录时的重开与接回、普通恢复副本、同路径不同卷与原卷改号。实体外置卷断电或拔插仍待实测。运行中的 SQLite 路径被原始数据库字节副本替换，以及同用户进程在系统调用前并发改写私有暂存项，仍需独立核对实际执行句柄与发布源。[当前资料库授权](../../Sources/RAWMaster/WorkbenchDeliveryAccess.swift) · [排他发布](../../Modules/LibraryCatalog/src/scheduler/batch/directory.rs)

### AI 蒙版取消与胶片参考复测

用 031 冻结摘要恢复四个样本，重跑 Batch 12 的真实场景、实例和对象蒙版。首次运行复现了准入前取消后分析资源未释放的故障。修复后，蒙版生成和实例查询都在准入取消时按来源和解码器释放分析图、分割对象和模型资源，保留已确认的 Gray8 和缓存计数。已获准入的操作仍由分析 actor 在返回前清理。新增实例查询用例分别在调用前取消另一张图和当前图的请求，验证异源资源保留、同源资源释放。真实模型用例在取消后重取水面 Gray8，验证无需解码或加载模型。请求已经排队或刚获准入时的竞态仍待定向验证。[蒙版服务](../../Sources/RAWMasterImaging/DevelopmentSemanticMaskService.swift) · [真实照片与取消断言](../../Tests/RAWMasterImagingTests/DevelopmentSemanticMaskTests.swift) · [冻结输入](../031-preset-browser/evidence/camera-raw-integration/inputs.json)

同一修复构建的 27 个成像、9 个蒙版交互和 5 个 Prompt 提供者定向用例通过。AppModel 计数用例先走资料库正常导入，再用真实人像检查生成、暖命中、取消和拒绝异源。三款胶片模拟在人物和雪景的六个 Metal 参考输出均通过，RGB 码值平均误差 0.021–0.038，P99 均为 1，最大为 2。Prompt 的 Seedream 用例使用受控传输验证确认、离线恢复及单次提交。[原生交互与来源](../../Tests/RAWMasterUITests/EditingMaskCanvasOwnershipTests.swift) · [胶片参考夹具](../031-preset-browser/evidence/spektrafilm/README.md) · [提供者传输断言](../../Tests/RAWMasterAITests/QuickPromptProviderTests.swift)

修复候选 Batch 12m 的正式套件复核了 158 个适用功能 ID、四次天空与主体 Adaptive RAW 重放，以及一次真实 FLUX Q8 局部成片。FLUX 选区外 786,432 像素保持一致。20 张 RAW 入库与 200 张 JPEG 导出同时在运行时，另一张照片从曝光输入到 AppKit 完成定稿绘制为 15.34 ms。200 张成片逐份匹配 Rust 票据及主干独立输出。[同包功能和文件核验](evidence/native-release-batch12m.json) · [混合负载时间轴](evidence/mixed-workload-flux-batch12m.json)

两项预览试验在正式运行中默认关闭，37 算子的 814 对首帧和定稿均与 Batch 12 匹配。74 态首次可见变化的中位和 P95 为 4.95／18.13 ms，通过该项门槛。首次精确与定稿均为 99.43／519.35 ms，首次精确门槛为 24.35／252.27 ms，定稿门槛为 25.92／252.27 ms。交互、控件、LightFlow 对比及画面检视四个阶段共有 11 条断言超线。本轮发布性能门未通过。[默认发布报告与失败明细](evidence/native-release-batch12m.json)

### v10 封存构建的功能与性能

Batch 13s 的目录迁移、工作台、成像、蒙版交互和 Prompt 提供者定向套件共 69 项，68 项通过。真实 v1 目录专项因缺该版本的快照跳过。正式套件和独立核验覆盖 158 个适用的 Camera Raw 功能 ID、四次天空与主体 Adaptive RAW 重放及六个胶片参考输出。37 算子的 814 对首帧、定稿和取样区摘要与 Batch 12m 一致。[封存功能回执](evidence/native-release-batch13s.json)

同包运行本机 FLUX Q8 后，786,432 个选区外像素保持一致。20 张 RAW 入库与 200 张 JPEG 在执行时，另一张图从曝光输入到 AppKit 完成定稿绘制耗时 15.30 ms。200 张成片逐份匹配 Rust 票据和主干独立成片，批次完成后所有名称占位均清退。[混合负载原始时间轴](evidence/mixed-workload-flux-batch13s.json)

默认关闭两项预览试验。74 态首次可见变化中位／P95 为 5.10／19.74 ms，通过门槛。首次精确和定稿均为 101.92／497.27 ms，首次精确门槛为 24.35／252.27 ms，定稿门槛为 25.92／252.27 ms。交互、控件、LightFlow 对比、画面检视及超分辨率内存共五个阶段、14 条断言超线。发布性能门未通过。[正式报告](evidence/native-release-batch13s.json)

### 原生定稿请求内缓存

原生探针用两张实际 RAW 和同一 Core Image 显影、全域有限值检查及 FIT 读回，以关、开、开、关顺序在独立进程对照。160 次整帧读回逐态相同。显式全域缓存节点在主 RAW 四态保持像素一致，进程物理峰值从 2.60 GB 升至 5.23 GB。显式分块节点的四态像素均有差异，物理峰值达 7.21 GB。两个节点方案退出。每个独立探针均拒绝注入的 RGB NaN、RGB 正无穷和末带 alpha 负无穷，取消后全域检查可以重试。[原生探针回执](evidence/native-request-ci-cache-batch14.json)

Batch 14 的主 RAW 首次精确 P50 从 99.88 ms 降至 88.26 ms，P95 从 447.25 ms 升至 457.53 ms。审查发现旧上下文在部分冷解码仍被保留。Batch 14b 恢复解码前替换旧上下文的顺序，并将试验上下文限制在单次定稿内，随后重跑两张 RAW 的 37 算子，每张四轮，每轮 74 首次状态和 740 暖态重复。各轮全部 814 对可见首帧和最终读回摘要逐态相同。主 RAW 的全幅和局部见证全部通过。次 RAW 的高光与白色色阶两个蒙版算子两态有不同的全幅输出，原固定区域采样在开关两档均未满足独立空间见证。该两项只计开关前后完整读回的一致性。[封存算子与读回回执](evidence/native-request-ci-cache-batch14.json)

| Batch 14b 首次精确预览 | 缓存关闭 P50／P95 | 缓存开启 P50／P95 |
| --- | ---: | ---: |
| 主 RAW，148 次／档 | 99.57／445.13 ms | 97.20／466.62 ms |
| 次 RAW，148 次／档 | 85.18／405.08 ms | 89.74／418.88 ms |

两张 RAW 各做两次开关对照，共八次由冷源直接请求曲线定稿。全部会话只解码一次，曲线和后续蒙版重试都匹配同源完整画面。开启缓存的四次取消发生在后续饱和度蒙版请求的原生全幅归约内，该请求停止在画面读回前。同配方重试实际重新渲染，关闭后源纹理占用归零。冷启动未测得稳定加速。恢复上下文生命周期后，两张 RAW 的 P95 都上升，开关保持默认关闭。[冷源、取消与性能对照](evidence/native-request-ci-cache-batch14.json)

Batch 14b 的 46 项定向原生测试通过，覆盖有限值、AI 蒙版、胶片模拟及 Prompt 提供者。Camera Raw 19.0 清单中有 158 个功能 ID 能关联同一封存构建的测量。默认运行的 74 态首次可见 P50／P95 为 5.27／18.08 ms，通过门槛。首次精确与定稿均为 100.89／472.17 ms，首次精确要求 24.35／252.27 ms，定稿要求 25.92／252.27 ms。交互、控件、LightFlow 对照和检视共四个阶段、九项断言超线。发布性能门未通过。[正式门槛与定向测试](evidence/native-request-ci-cache-batch14.json)

### 超分辨率导出内存时间轴

Batch 14b 的正式 50 ms 采样记录导出 RSS 峰值 1,540,210,688 B，通过 1,657,071,206 B 上限。另用两个独立进程按 20 ms 采样实际导出，RSS 最高样本分别为 1,692,123,136 B 和 1,692,303,360 B，均落在 FlashRaw 的 F16 原生纹理上传阶段，距导出调用约 191–192 ms，此时 TIFF 暂存尚未建立。Metal 和物理占用的最高样本出现在稍后的 TIFF 生成阶段。两次输出的尺寸、文件 SHA-256、字节数和 ICC 匹配既有证据。上传事件同时包含完整内存复制和 GPU 等待，时间轴支持检验分带上传。[正式结果与独立时间轴](evidence/native-request-ci-cache-batch14.json)

独立原生探针以关、开、开、关顺序与生产转换器对照。两张真实 RAW 的八次完整 RGBA16Float 纹理读回逐字节一致。主 RAW 的上传阶段 RSS 峰值由 1.564–1.565 GB 降至 1.218 GB，次 RAW 由 1.306–1.307 GB 降至 1.020–1.021 GB。两张 RAW 的单带共享缓冲分别为 14,598,144 B 和 13,271,040 B。另以两个奇数宽高的输入核对一行与十七行的末带。十个取消或注入故障用例中，已提交命令都在释放 C 帧前完成，重试的整幅纹理与对照一致。[分带上传原生证据](evidence/flashraw-banded-superresolution.json)

Batch 15 在正常导出入口用两张实际 RAW 完成六次 2× TIFF16。每张图的预览、完整 TIFF SHA-256、尺寸、位深、ICC 和独立重开的模型采样均与同源对照相同。主 RAW 的两个候选均通过原 50 ms 内存和耗时比较门。隔离的 5 ms 时间轴以关、开、开、关复测，正常导出进程 RSS 峰值从 1.692–1.693 GB 降至 1.370–1.371 GB。实际导出在分带上传期间取消后返回取消结果，目标和暂存目录为空。重试交付的 TIFF 与原摘要一致。[实际导出的成片、内存和取消回执](evidence/flashraw-banded-superresolution.json)

Batch 15b 冻结后独立确认默认请求发出分带上传事件，显式设为 0 的请求发出全幅上传事件，两者的最终 TIFF SHA-256 相同。默认路径的取消与重试再次通过。完整发布套件的超分辨率门通过，采样导出 RSS 为 1,379,024,896 B。Camera Raw 功能索引关联 158 个本次封存测量 ID。[默认、回退和超分辨率发布门](evidence/flashraw-banded-superresolution.json)

Batch 15b 的 74 态首次可见 P50／P95 为 5.66／17.52 ms，通过门槛。首次精确与定稿均为 100.66／485.41 ms，首次精确门槛为 24.35／252.27 ms。图像流水线、交互、LightFlow 对照和画面检视共四个阶段、18 项断言超线。[同一构建的完整发布回执](evidence/flashraw-banded-superresolution.json)

封存后补充了首次分带管线初始化失败时、回退全幅上传前的取消检查。成像目标独立重建并运行默认导出取消与重试，完整 TIFF 摘要再次一致。完整发布数值使用 Batch 15b，补充检查使用单独的原生回执。[补充复验](evidence/flashraw-banded-superresolution.json)

### 原生预览的半幅浮点边界

两张真实 RAW 的提交图都先以 0.5 倍缩小线性 RGBA FP32，再由剩余仿射采样表达式处理 sRGB 和 alpha。保留原坐标的物理半图在曲线与径向曝光的八个状态逐字节匹配原显示。写入和导入各翻转一次时，主样片出现 3,074–5,053 个 RGB 一码差异。[原生提交图和整帧摘要](evidence/native-half-fit-study.json) · [Apple 渲染图诊断](https://developer.apple.com/videos/play/wwdc2020/10089/)

分带着色器从算后的四个原生像素核验 RGBA 的浮点指数，并用硬件采样生成同一个半像素。带边的 NaN、正负无穷、透明像素中隐藏的 RGB NaN 和漏写末行均被拒绝。取消发生在第一带完成后，后续请求可重新完成。逐次读回的 16 个状态中，两张 RAW 各有 12 个状态的完整半幅 FP32 与直接半幅一致。纹理和清晰度的四个状态仍需复现原图的邻域求值。[全平面与故障对照](evidence/native-half-fit-study.json)

扩大至 33 个算子的 66 态后，主样片有 38 态需要整幅尾段、17 态需要四个 1200×800 象限、11 态在两种布局中均有差异。次样片有 57 态在两种布局中均一致、9 态仍有差异。保留主样片尾段的象限边界，能消除色温、曲线蒙版、局部锐化与降噪等复合图中的一码差异。估算接口只提供总计，试用范围依据已经核对的单原生通道提交图。[配方矩阵和末段对照](evidence/native-half-fit-study.json)

Batch 16b 在真实编辑入口对照通道曲线、点曲线和径向曝光，每张 RAW 每档六态。开启时 12 态均实际运行候选并匹配完整定稿摘要。两张 RAW 的局部色温、色彩分级与局部降噪共 12 个控制状态使用原路径并匹配对照。请求总耗时含画面读回。[原生请求回执](evidence/native-half-fit-study.json)

| 2400×1600 原生定稿 P50 | 主 RAW 关闭／开启 | 次 RAW 关闭／开启 |
| --- | ---: | ---: |
| 独立定稿请求及整帧读回 | 67.56／45.21 ms | 64.24／38.30 ms |
| 最终 Core Image sRGB8 画面生成 | 35.31／3.35 ms | 32.05／3.30 ms |

两张 RAW 各做两次默认与候选的冷源对照。各次只解码一次。四个候选会话均在饱和度蒙版处理中取消，只有同配方的重试进入画面生成并交付匹配的摘要。关闭会话后 FlashRaw 池的源纹理占用归零。首个候选的暖态首帧有 10 个算子退回近似帧，随后修正主画布对完成定稿的单向读取。修正后，两个对照打开顺序及主画布的代理和普通交互都能读回自己的精确结果。主样片两次候选冷源用时分别为 331.67 与 197.15 ms，对照为 221.03 与 225.50 ms。进程 RSS 还计入同进程后续请求。[取消、重试与缓存回放](evidence/native-half-fit-study.json)

同一封存的 Batch 16b 以关、开、开、关的顺序复跑每张 RAW 的 37 算子。每轮 74 次首次与 740 次暖态重复，共 6,512 对首帧和定稿完整摘要，与各自留存的同源对照逐态一致。主 RAW 的全部空间见证通过。次 RAW 的高光和白色色阶蒙版仍缺独立空间见证，两项已核对完整读回。[封存整帧对照](evidence/native-half-fit-study.json)

| 批次内 148 次／档 | 关闭 P50／P95 | 开启 P50／P95 |
| --- | ---: | ---: |
| 主 RAW 首次精确预览及定稿 | 99.73／486.96 ms | 100.21／453.48 ms |
| 次 RAW 首次精确预览 | 86.62／421.04 ms | 86.65／399.73 ms |
| 次 RAW 定稿 | 93.49／421.04 ms | 89.34／399.73 ms |

候选在独立曲线和径向配方上缩短读回，主样片整套首次精确预览的 P50 仍约 100 ms，P95 仍超过 252.27 ms 门槛。半幅开关默认关闭。主样片较慢的局部纹理、清晰度和去雾仍走各自的原生处理路径。[混合配方计时](evidence/native-half-fit-study.json)

Batch 16b 的默认发布套件再次核对主样片的 814 对完整首帧与定稿摘要。50 项定向原生测试通过，覆盖调度、进度通道、有限值检查和局部蒙版。Camera Raw 19.0 功能索引关联 158 个测量 ID。默认 2× TIFF16 与上次封存成片的 SHA-256、尺寸、位深和 ICC 一致，导出 RSS 为 1,378,369,536 B，通过超分门槛。[默认发布回执](evidence/native-half-fit-study.json)

默认发布的 74 态首次可见 P50／P95 为 5.12／18.75 ms，通过门槛。首次精确与定稿均为 101.82／487.63 ms。首次精确要求 24.35／252.27 ms，定稿要求 25.92／252.27 ms。交互、控件、LightFlow 对照和画面检视共四个阶段、11 项断言超线，发布性能门仍未通过。[默认发布门槛](evidence/native-half-fit-study.json)

### 径向空间蒙版的原生瓦片校验

默认构建的主样片上，清晰度和纹理的最终蒙版全域校验用时为 280–357 ms，后续生成 sRGB8 画面用时为 131–149 ms。保持完整调整采样范围，只把读取移到非零覆盖分支时，两张 RAW 的八个整帧摘要均匹配。缩小调整分支的请求范围或裁切其输出，八个状态各有 1,485–31,739 个像素发生一码偏差，差异位于蒙版支持区域。两种裁切方案均退出。Core Image 的 ROI 需要包含实际采样所用的全部源坐标。[分段和缩小 ROI 的反例](evidence/native-spatial-mask-tiles.json) · [Apple Core Image ROI 契约](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_custom_filters/ci_custom_filters.html)

只减少最终检查的原有瓦片，主样片从 70 格减到 28 格，次样片从 54 格减到 28 格。两张 RAW 各按全幅、区域、区域、全幅对照，每轮取纹理和清晰度各两态，32 张整帧摘要均匹配。主样片的每轮校验中位数从 297–324 降至 125–126 ms，次样片从 239–240 降至 125–129 ms。两张片的保留瓦片坐标和四通道归约值都与原瓦片一致。128 MiB 的区域 Metal 分带在独立探针中进一步缩短归约，其进程物理峰值高于保留原瓦片的两轮。接线采用原瓦片。[各校验路径的计时与峰值](evidence/native-spatial-mask-tiles.json)

用 3074×2050 的半浮点原生夹具测试最小半径、跨双网格边界、四个图像边角以及有残行的末格。实际着色器在被略去瓦片的覆盖均为零，原全域检查仍拒绝该区域中的坏源。保留末像素注入 NaN、负无穷 alpha 和透明 RGB 正无穷，两种校验均拒绝。未写入的归约值被拒绝，第一格完成后取消，再次执行成功。[边缘、异常值和取消回执](evidence/native-spatial-mask-tiles.json)

Batch 17 从正常主画布入口确认，每次区域校验读取 29,360,128 个原生像素。四个开启的独立会话在选区校验中取消，取消后的重试和只用全域校验的对照画面都匹配归档。主画布能够复用已完成的同配方结果，关闭后 FlashRaw 池的源纹理占用归零。每张 RAW 37 算子四轮，共 6,512 对首帧和定稿完整摘要一致。次样片的高光和白色色阶蒙版沿用完整输出见证，独立空间见证仍未通过。51 项原生定向测试通过。[正常入口、取消和封存读回](evidence/native-spatial-mask-tiles.json)

| Batch 17 首次精确读回 P50／P95 | 全幅校验 | 保留原瓦片 |
| --- | ---: | ---: |
| 主 RAW 的纹理与清晰度，8 态／档 | 540.49／551.32 ms | 308.80／327.55 ms |
| 次 RAW 的纹理与清晰度，8 态／档 | 433.62／468.87 ms | 286.85／311.40 ms |
| 主 RAW 的 37 算子，148 态／档 | 97.53／503.13 ms | 101.55／412.78 ms |
| 次 RAW 的 37 算子，148 态／档 | 85.09／414.05 ms | 84.81／345.79 ms |

Batch 17b 将区域校验设为合格定稿的默认路径。合格请求在未设置开关时实际只读 28 格，`RAWMASTER_CANONICAL_SPATIAL_MASK_TILES=0` 实际回到全幅校验。强制串行和显式 Metal 分带均按原范围检查。四次默认区域校验中止与重试、对照画面与主画布复用和 51 项定向测试通过。新构建的八轮共 6,512 对首帧与定稿摘要再次匹配。主、次样片的纹理与清晰度首次精确 P50 分别由 502.15、423.92 ms 降至 295.50、291.77 ms，整套 37 算子 P95 分别由 485.49、411.91 ms 降至 413.24、346.19 ms。[默认、回滚、优先级和精确读回](evidence/native-spatial-mask-tiles.json)

默认发布实测的 74 态首次可见 P50／P95 为 5.24／20.46 ms，通过门槛。首次精确和定稿均为 100.59／409.15 ms，P95 门槛为 252.27 ms，整套发布仍有四个阶段、16 项断言超线。主样片 814 对完整首帧和定稿摘要再次匹配，2× TIFF16 的成片 SHA-256、尺寸、位深和 ICC 一致，导出 RSS 为 1,380,401,152 B，超分门槛通过。[正式性能与成片回执](evidence/native-spatial-mask-tiles.json)

同一封存构建复核了 158 个 Camera Raw 功能测量 ID。语义蒙版、胶片模拟和滤镜单元组共 27 项通过，蒙版交互 9 项、Quick Prompt 提供者 5 项通过。天空和主体 Adaptive 各在两张实际 RAW 上重新生成并重放。本机 FLUX Q8 的保护区 786,432 个像素逐一一致，选区的 262,144 个像素均变化。另一张照片从输入到 AppKit 完成绘制用时 16.30 ms，当时 20 张 RAW 导入和 200 张 JPEG 导出都在进行。200 份文件逐件匹配实际 Rust 队列票据和单独运行的合并主干成片。[同包 AI、滤镜和任务验收](evidence/native-spatial-mask-tiles.json)

### 径向颗粒的区域校验

两张 RAW 的局部锐化、降噪与颗粒按全域、区域、区域、全域的顺序对照，48 个原显示图的整帧摘要一致。三种操作合计，主样片的末次校验 P50 从 240.53 ms 降至 103.74 ms，后续画面读回仍约 151 ms。两张样片保留的 28 个原网格瓦片，每个的 RGBA FP32 归约值均匹配全域检查。[分段计时和原瓦片回执](evidence/native-grain-mask-tiles.json)

用 3074×2050 opaque RGBA16F 夹具和实际 Core Image 着色器注入 FP32 极值、NaN 与无穷。通用复合的首个省略格覆盖为零，但全域检查拒绝了该图，区域检查通过。抽查该行的八个像素仍与源一致，判断差异以实际归约为准。颗粒复合在四个注入位置始终与全域检查作出相同判断，源全域检查也拒绝了省略格里的坏源。实际三条处理图的保留末像素注入四类异常后，两种归约均拒绝。Release 候选只通过显式开关放行由项目着色器生成有界噪声的局部颗粒。[极值、异常与零覆盖反例](evidence/native-grain-mask-tiles.json)

封存构建有 52 项原生定向测试通过。实际主画布上的区域校验各读取 29,360,128 个原生像素。八个独立会话在关闭和开启两档分别验证校验中取消、重试、对照视图的全域路径以及主画布复用。关闭会话后源池占用归零。八轮完整回放共 6,512 对首帧与定稿摘要匹配归档。显式全域回滚、强制串行和分带检查也按其原有范围运行。[Release 逐帧与生命周期回执](evidence/native-grain-mask-tiles.json)

| 原生首次精确预览 P50／P95 | 全域校验 | 颗粒区域校验 |
| --- | ---: | ---: |
| 主 RAW 的径向颗粒，4 次／档 | 301.61／308.96 ms | 193.13／212.49 ms |
| 次 RAW 的径向颗粒，4 次／档 | 244.57／244.87 ms | 172.06／177.37 ms |
| 主 RAW 的 37 个算子，148 次／档 | 103.37／423.13 ms | 103.12／409.23 ms |
| 次 RAW 的 37 个算子，148 次／档 | 87.70／348.17 ms | 88.19／355.25 ms |

两张 RAW 的颗粒中位数各缩短约 108 和 73 ms，整套算子的 P95 两个方向都有变化。颗粒开关默认关闭，局部锐化、局部降噪与灰阶预览保留全域校验。[两源同构建交叉计时](evidence/native-grain-mask-tiles.json)

使用同一封存构建启用颗粒候选后，正式 74 态的首次可见 P50／P95 为 5.26／16.89 ms，达到门槛。首次精确和定稿均为 101.25／423.55 ms。首次精确要求 24.35／252.27 ms，定稿要求 25.92／252.27 ms。交互、单控件与 LightFlow 对照共有 13 项断言超线。额外 814 对首帧和定稿摘要匹配归档。完整 2× TIFF16 成片的 SHA-256、尺寸、位深和 ICC 一致，导出 RSS 为 1,381,548,032 B，通过超分门槛。[正式性能、回归和成片回执](evidence/native-grain-mask-tiles.json)

同包关联 158 个 Camera Raw 功能测量 ID。语义蒙版、胶片模拟及滤镜 27 项，蒙版交互 9 项，Quick Prompt 提供者 5 项均通过。天空与主体各在两张实际 RAW 上重新生成并重放。FLUX Q8 的成片与混合负载回执仍以默认构建 Batch 17b 的实测为准。[同包功能与实片回执](evidence/native-grain-mask-tiles.json) · [默认构建的本机 FLUX 回执](evidence/native-spatial-mask-tiles.json)

### 灰阶锐化预览的半幅对照

两张实际 RAW 的归档灰阶状态在半幅 F32 和完整 RGBA8 上均逐字节相同，半幅各比对 15,054,336 和 12,441,600 个像素。普通锐化状态也满足同一渲染计划统计。增加参数范围后，半径 3 的半幅分别有 21、39 个像素的浮点表示变化，最终显示摘要一致。半径 1.75、强边缘筛选的半幅变化扩大到 76,725、33,411 个像素，分别有 692、300 个显示像素发生一码差异。[两张 RAW 的配方、计划和摘要](evidence/native-sharpen-overlay-half-study.json)

独立的 5100×3400 半浮 HDR 夹具上，两条半幅路径的 F32 逐像素相同，两者重新生成的画面都比原显示路径多 975,552 个差异像素。跨带 NaN、正负无穷和末行漏写被拒绝，首带完成后取消并重试成功。这轮只验证精度和异常处理，灰阶预览继续使用原路径。[HDR 与故障回执](evidence/native-sharpen-overlay-half-study.json)

### 局部锐化与降噪的全幅分带复验

在两张 RAW 上分别做两轮全幅瓦片、全幅 Metal 分带、全幅 Metal 分带、全幅瓦片对照。两种方法均保留原显示图，64 个完整显示摘要匹配归档。主样片的局部降噪、局部锐化端到端 P50 分别从 404.6、416.2 ms 降至 213.1、267.4 ms，次样片从 341.2、346.5 ms 降至 194.4、221.9 ms。主样片进程物理峰值增加约 137 MB。[实际核验范围、计时和峰值](evidence/native-local-detail-full-bands-study.json)

两个独立进程输入同一组半浮点和浮点异常夹具，两次均得到相同结果。通用蒙版合成的首格以及颗粒合成的内部极值，原全幅瓦片检查拒绝，实际运行的全幅分带检查通过。颗粒反例在独立浮点读回中含有无穷值。逐通道异常、漏写末行及分组标记和取消重试的夹具均按预期处理。局部锐化和降噪的默认定稿保留原全幅瓦片检查。[两次故障探针和浮点位型](evidence/native-local-detail-full-bands-study.json)

### 冷原片的私有纹理校验

两张 RAW 上传后分别检查实际 60,217,344 和 49,766,400 个 RGBA16F 像素。Metal 与独立 Metal blit 读回的聚合结果一致，两张照片分别有 701 和 5 个负色值像素。单测既有 Core Image 检查的中位数为 149.28、109.61 ms，直接纹理检查为 2.07、2.24 ms。夹具覆盖半浮点次正规数、负零、有限极值、NaN、正负无穷、异常 alpha、上传缺格和未写的校验记录。GPU 完成后的取消和干净纹理重试均通过。[私有纹理和故障回执](evidence/native-raw-source-finite.json) · [Metal 纹理读取](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)

默认构建在两个实际打开顺序中确认冷源只建立一次。主画布先开时，比较视图复用同一纹理已完成的校验。比较视图先开时，实际执行既有 Core Image 源校验。两张 RAW 的主画布首次定稿耗时中位数分别由 554.65、506.04 ms 降至 447.71、388.62 ms，每档各两次。包含 Metal 管线初始化的一次主样片校验耗时为 70.95 ms。四个交互会话在实际校验期间提交更新的交互请求，旧定稿均被替代，同配方重试的完整画面匹配归档。关闭会话后驻留源纹理均释放，三个回退入口实测通过。[两个打开顺序、抢占和回退](evidence/native-raw-source-finite.json)

Batch 19b 的 53 项定向测试通过。默认和显式回退在两张 RAW 上完整对照，6,512 对首帧和定稿摘要均匹配。正式 74 态的首次可见 P50／P95 为 5.21／20.01 ms，通过门槛。首次精确与定稿均为 99.18／409.00 ms，P95 门槛为 252.27 ms。四个阶段共有 11 项断言超线。正式主样片的 814 对摘要再次匹配，完整 2× TIFF16 的 SHA、尺寸、位深和 ICC 一致，导出 RSS 为 1,379,106,816 B，超分门槛通过。[默认构建与正式性能门](evidence/native-raw-source-finite.json)

同一默认构建关联 158 个 Camera Raw 功能测量 ID。语义蒙版、胶片模拟和滤镜 27 项，蒙版交互 9 项，Quick Prompt 提供者 5 项通过。天空与主体 Adaptive 各在两张实际 RAW 上重新生成并重放，验证器核对成片与封存二进制。实际 FLUX Q8 成片仍使用前序默认构建的原生回执。[同包功能复验](evidence/native-raw-source-finite.json) · [FLUX 与任务混合负载](evidence/native-spatial-mask-tiles.json)

### Batch 20 双语义蒙版的跨平台重放

从 Batch 19b 已保存的两份 Adaptive 作品提取同一张 9504×6336 Sony RAW 的天空和主体快照。Swift 通过已验证的私有原件使用 FlashRaw 0.3.1 解码，在 2400×1600 同一网格生成两张上至下排列的 R32Float 覆盖图。配方先应用 37.5% Spektra Velvia 100，再按天空 +0.75 EV、主体 −1.25 EV 依次叠加。Swift 回归用例验证同尺寸异源图、错误方向、错误尺寸、损坏 PNG、预算不足和等待后撤销授权。[原生用例](../../Tests/RAWMasterImagingTests/PortableFrozenCoverageTests.swift) · [冻结来源及像素回执](evidence/portable-named-coverage.json)

整图 3,840,000 个像素中，共同零覆盖的 1,772,225 个像素与各自的滤镜基线逐分量逐位相等。2,054,121 个像素仅天空覆盖，13,654 个像素两者重叠。这张原片的主体区域完全落在天空图的非零范围内。独占主体覆盖、32 张蒙版及共享蒙版边由独立夹具验证。macOS 和 Linux CPU 的 61,440,000 B 输出逐字节一致，相对现有 Core Image 配方的最大通道差为 `3.58×10⁻⁷`。macOS wgpu 缓冲区与借入 IOSurface 的输出也逐字节一致。Linux arm64 软件 Vulkan 相对 CPU 的最大通道差为 `8.34×10⁻⁷`。本次复合配方覆盖胶片与局部曝光，Adaptive 原有的其他局部调节见各自实图用例。[跨平台回执与像素摘要](evidence/portable-named-coverage.json) · [无界面 C ABI 重放](../../Modules/ImageEdit/tests/replay_named_coverage.py)

macOS 的 18 项 Rust 用例、Linux CPU 的 14 项和软件 Vulkan 的两项具名用例通过。Objective-C 对 2 和 32 张蒙版实际绑定 Metal 纹理，验证底层 IOSurface 别名、末像素 NaN、过期完成与重试。强制零截止时间的单独测试等待真实 wgpu 栅栏结束，保留原先已发布的输出，下一次提交成功。[原生 ABI 和栅栏回执](evidence/portable-named-coverage.json)

同一 2400×1600 配方在 M4 Max 上先预热 3 次，再交替切换两档滤镜强度，每系列取 21 帧并在主机比较完整输出。正反顺序各跑一次。融合将三次派发合为一次，减少一个整帧 RGBA FP32 中间槽，显式驻留分配少 61.44 MB。驱动和宿主副本另计。借入纹理路径另有正确性回执。驻留计时从参数更新开始，重新绑定计时从取得本次已校验输入开始。[计时程序](../../Modules/ImageEdit/examples/gpu_performance.rs) · [两轮原始样本与输出摘要](evidence/portable-named-coverage.json)

| Metal 计时，分段 → 融合 | 先融合的一轮 P50／P95 | 先分段的一轮 P50／P95 |
| --- | ---: | ---: |
| 驻留参数更新至 GPU 完成 | 3.14／3.17 → 1.62／3.12 ms | 3.16／3.20 → 1.62／3.17 ms |
| 驻留参数更新至主存读回 | 10.54／11.16 → 9.53／10.02 ms | 10.53／11.36 → 9.68／11.07 ms |
| 每帧重新绑定、上传与读回 | 23.98／25.21 → 18.92／20.78 ms | 23.11／24.62 → 18.68／19.94 ms |

带原件绑定的封存构建重新执行发布脚本。74 态首次可见 P50／P95 为 5.22／19.77 ms，通过门槛。首次精确和定稿均为 100.29／435.01 ms，P95 门槛为 252.27 ms。互动、驻留控件和 LightFlow 对照共三个阶段、15 项断言超线。814 对完整首帧及定稿摘要匹配上一版，2× TIFF16 的摘要、尺寸、位深和 ICC 均匹配，峰值 RSS 为 1,378,582,528 B，超分门槛通过。具名图的计算和读回计时是独立验收边界，日常编辑的发布判定以原生正式脚本为准。[正式报告与构建摘要](evidence/portable-named-coverage.json)

旧 ABI 提前拒绝新版配方的检查落地后，最终封存再跑整套脚本。74 态首次可见为 5.52／18.09 ms，首次精确与定稿为 102.36／416.66 ms。五个阶段共 17 项断言超线。814 对完整首帧与定稿及 2× TIFF16 继续匹配，超分专项通过，导出 RSS 为 1,380,286,464 B。该构建的 18 项 macOS Rust 用例、5 项 Swift 集成用例和 Linux CPU 的 14 项用例通过。[最终正式回执](evidence/portable-named-coverage.json)

同一构建对照 158 个适用的 Camera Raw 测量 ID。语义蒙版、胶片模拟和滤镜 27 项、蒙版交互 9 项、Prompt 提供者 5 项通过。两张真实 RAW 各自完成天空和主体 Adaptive 的生成、重开和 TIFF16 导出。再提取新保存的两张蒙版重放，节点 ID 更新，CPU 和两个 Metal 后端的整图输出仍分别匹配原回执。[功能索引、新蒙版和旧 ABI 复验](evidence/portable-named-coverage.json)

真实本地 FLUX Q8 完成一次提交，重开资料库后仍只有一次尝试。TIFF16 的 786,432 个保护像素逐一一致，262,144 个选区像素均变化。另一个编辑窗口从输入到 AppKit 完成绘制用时 17.38 ms，其间进行 20 张 RAW 导入和 200 张 JPEG 导出。200 份文件逐件匹配 Rust 队列票据和合并主干的独立导出。[本地模型与队列复验](evidence/portable-named-coverage.json)

复现时先完成两个 Adaptive XCTest。对其输出运行 `verify-acceptance.py --adaptive-dir <Adaptive 输出> --named-coverage-fixtures <新目录>`，校验器从已关闭的资料库按照片摘要取出持久层。`PortableFrozenCoverageTests` 用 `RAWMASTER_035_FROZEN_FIXTURES` 读取该目录，用 `RAWMASTER_035_FROZEN_RAW` 和 `RAWMASTER_FLASHRAW_LIBRARY` 指定原片与解码器，向新的 `RAWMASTER_035_FROZEN_OUTPUT` 目录写入 FP32 输入和成片。无界面重放读取同目录的 `manifest.json`，按清单校验每份文件后经生产 C ABI 提交。[原生环境变量与用例](../../Tests/RAWMasterImagingTests/PortableFrozenCoverageTests.swift) · [Adaptive 测试](../../Tests/RAWMasterUITests/AdaptivePresetReplay035Tests.swift) · [验收工具](verify-acceptance.py)

在 Linux 的仓库根目录构建 CPU 工作进程所用的库。`FRAME_DIR` 指上一步写出的输入和成片目录。

```sh
cargo build --release --locked --no-default-features --manifest-path Modules/ImageEdit/Cargo.toml --target-dir .build/image-worker
python3 Modules/ImageEdit/tests/replay_named_coverage.py "$FRAME_DIR" .build/image-worker/release/librawmaster_image.so Sources/RAWMasterImaging/Resources/PhotoFilters --backend cpu
```

### 原件绑定与首次精确预览

同一封存构建按关、开、开、关的顺序对两张真实 Sony RAW 复跑。成功的原件绑定仍逐项校验冻结蒙版、局部编辑和已解析白平衡。定稿使用经过私有文件描述符核验的原件摘要，以及按原设置读取的 RAW 方向和尺寸。文件替换、同尺寸异源或编辑工作被撤销时校验失败。无该凭据的入口执行原核验。`RAWMASTER_VERIFIED_LOCAL_SOURCE_BINDING=0` 恢复原路径。[宿主校验](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [原生测试](../../Tests/RAWMasterImagingTests/DevelopmentVerifiedLocalSourceTests.swift)

两张 RAW 各有六个带来源绑定的定稿样本／档。所有定稿逐帧匹配归档。主片绑定校验的 P50 为 75.48／0.06 ms，整个定稿从 120.53 降至 43.00 ms。次片绑定校验为 67.60／0.08 ms，定稿从 107.41 降至 41.11 ms。单独的中性对照保持原输出。这个计时边界从定稿请求到完整 RGBA8 读回。[按原片和档位的回执](evidence/native-exact-source-and-sharpen.json)

### 原生定稿的锐化均值验证

同一封存 Release 在真实 Sony RAW 上按关、开、开、关的顺序逐进程运行。每次读取 37 个配方状态对，共 814 个缓冲。两张 RAW 合计 6,512 个缓冲的整帧摘要均与各自归档一致。次片的两个亮部径向用例仍以同片像素摘要复核，其局部分区判定为 inconclusive。分段记录另确认开启时 16 个锐化样本均校验了源图全幅标量均值，后续使用同一张均值纹理。局部降噪和曲线对照继续执行整幅有限值校验。[封存摘要、整帧对照和原生分段](evidence/native-exact-source-and-sharpen.json)

| 原件 | 局部锐化定稿 P50（关／开） | 全局与灰阶锐化定稿 P50（关／开） | 分段进程峰值（关／开） |
| --- | --- | --- | --- |
| 9504×6336 | 456.80／266.91 ms | 315.88／181.82 ms | 4.34／5.61 GB |
| 8640×5760 | 368.29／244.88 ms | 284.00／175.68 ms | 4.32／5.28 GB |

每个锐化分组每档四个分段定稿样本。主片完整重放的定稿 P95 由关闭时的 406.67–415.08 ms 降至开启时的 302.23–342.82 ms。候选仍高于 252.27 ms 的正式门槛，分段进程峰值也上升，`RAWMASTER_QA_CANONICAL_SHARPEN_MEAN` 默认关闭。独立的 Core Image 请求缓存试验对局部降噪将中位数从 374.35 ms 降至 261.05 ms。显式缓存中间图的分段进程峰值从 3.50 GB 升至 5.17 GB，降噪仍使用正式定稿的全域校验。[两档性能与缓存试验](evidence/native-exact-source-and-sharpen.json)

两档各通过十项定向测试，包含真实 RAW 的取消、重试、不同输出目标及同尺寸错误源。测试通过阶段遥测注入取消，`startTask` 报错也可能触发该注入点。另以真实 Metal 校验验证少读一个像素、漏掉末组和末像素未写入时均拒绝结果。[取消用例](../../Tests/RAWMasterImagingTests/NativeSharpenMeanTests.swift) · [三种 GPU 故障回执](evidence/native-exact-source-and-sharpen.json)

### 去雾引导图的形态学采样

在同一台 M4 Max 上对两张实际 RAW 分别计量完整原生归一化、加入 `CIMorphologyMinimum`、再加入原 Gaussian 和标量输出。相反顺序各测一轮。主片三个阶段的中位数为 82.89、321.26 和 511.01 ms，次片为 54.84、284.67 和 464.16 ms。完整 R32Float 平面在两轮都重现各自归档的摘要。[去雾原生分段与输入](evidence/native-exact-source-and-sharpen.json)

按实测孔径核验三种像素相位及随机图、斜坡和实拍块，RGB Float32 逐位一致。主片半径 76.032 的实测孔径有 15,613 个采样点及 52 行内部空洞，次片半径 69.12 的孔径有 13,017 个采样点及 46 行内部空洞。直接采用理想圆盘或每行单一区间会改变采样。当前出图继续使用 Core Image 的原侵蚀算子。[孔径和完整引导图摘要](evidence/native-exact-source-and-sharpen.json)

### 本次默认配置的发布复验

封存构建启用已验证的原件绑定，关闭锐化均值候选。正式脚本对同一主片的 74 态测得首次可见 P50／P95 为 4.93／18.73 ms，两项通过。首次精确及定稿均为 91.00／411.15 ms，P95 上限为 252.27 ms。驻留控件、原生检查器、综合交互和 LightFlow 对照四个阶段，共 15 项性能断言未通过。814 个完整读回摘要匹配前次归档。19008×12672 的 2× TIFF16 在尺寸、位深、ICC 和文件 SHA-256 上匹配前次发布测量，峰值 RSS 专项通过。[正式报告和首次输出分布](evidence/native-exact-source-and-sharpen.json)

默认路径最慢的正向去雾状态为 1,068.35 ms，正式 P95 对应的局部降噪状态为 411.15 ms。开启锐化候选的较快一轮重放中，最慢四态依次为正向去雾、两态局部降噪和局部颗粒。正式门槛仍需覆盖这些配方的完整精确输出。[各次重放的超线样本](evidence/native-exact-source-and-sharpen.json)

同一测试包重新核对 158 个适用的 Camera Raw 测量 ID，27 项蒙版、胶片模拟和滤镜用例、9 项蒙版交互及 5 项 Prompt 提供者用例通过。两张真实 RAW 各通过天空、主体 Adaptive 的生成、重开和 TIFF16 导出。[实图用例与逐功能索引](evidence/native-exact-source-and-sharpen.json)

同一测试包的本地 FLUX Q8 完成实际推理、候选归档、采用、撤销和重开。仍只有一次提交。TIFF16 的 786,432 个保护像素逐通道相同，262,144 个选区像素均变化。另一个编辑窗口在 20 张 RAW 导入和 200 张 JPEG 导出的重叠区间内完成一次 15.39 ms 的选定画面绘制。200 份成片逐件匹配队列票据和独立主干导出。[模型、队列和窗口回执](evidence/native-exact-source-and-sharpen.json)

## Batch 22 的基础调色与去雾验证

### 桌面和无界面的基础调色

同一张来源已核验的 Sony RAW 在 2400×1600 FP32 画布上运行三组 V3 基础调色。独立 Swift V3、Rust C ABI 和 GPU 均消费同一份像素缓冲。Metal 缓冲后端的 FP32 和 RGBA8 三态均与 Swift V3 逐位相同。macOS 和 Linux CPU 的三个完整 FP32 摘要也分别相同。CPU 相对 Swift V3 的复合配方有 27 个 RGB 分量超出 `2×10⁻⁶`，最大差 `2.563×10⁻⁶`。另两配方在门槛内。三个 CPU 画面的差均至多一个显示码值，alpha 逐位相同。[逐配方输出、跨端摘要与误差](evidence/native-dehaze-and-portable-basic.json)

macOS 和 Linux CPU 各通过 16 项，Linux 软件 Vulkan 上的三项基础调色测试也通过，包含分段、融合与同参数槽重绑定。SwiftUI 的正常预览服务以黑白及曲线实图状态对拍开关两组，首帧及定稿摘要均等于归档。追踪确认黑白状态实际借入代理纹理并等待 GPU，首次编译加处理约 132.20 ms。`RAWMASTER_QA_PORTABLE_BASIC_PREVIEW` 保持默认关闭。[测试与实际预览轨迹](evidence/native-dehaze-and-portable-basic.json)

### 正向去雾的原生预计算

两个实测孔径的原始 15,613 和 13,017 个坐标均能用五级九点最小值精确生成。64 行候选在两张 RAW 的完整 240,869,376 和 199,065,600 个 RGBA FP32 分量上分别与原图逐位一致，后续 Gaussian 与 R32F 透射率也重现同一摘要。[孔径、四通道与 R32F 独立对照](evidence/native-dehaze-and-portable-basic.json)

同一封存 Release 的正常入口按关、开、开、关运行，每档每片两次冷定稿。四次开启的冷定稿均记录实际 Metal 预计算。第二态复用已经生成的引导图。两片全部定稿与归档逐帧一致，局部降噪为同场对照。18 项定向测试通过，候选默认关闭。[封存、分段和像素回执](evidence/native-dehaze-and-portable-basic.json)

| 原件 | 冷定稿 P50，关／开 | 引导图冷生成 P50，关／开 | 分段进程物理峰值，关／开 |
| --- | --- | --- | --- |
| 9504×6336 | 1002.50／799.85 ms | 600.30／411.06 ms | 4.01／3.65 GB |
| 8640×5760 | 837.64／611.72 ms | 527.69／288.28 ms | 3.57／3.34 GB |

用封存实现对两张 RAW 复验实际授权边界。第 20 个 64 行分带已等待 GPU 完成后，分别撤销请求和移走测试捕获副本。两者都中止并清退未完成的引导图。取消后同源重试成功，热态取消也保留此前已完成的引导图。超额预算和同尺寸异源对象在提交前被拒绝。[实际 GPU、缓存和原件权限用例](evidence/native-dehaze-and-portable-basic.json)

### 局部降噪的求值边界

整幅一次物化在主片的两个状态各改变 1,079 和 1,045 个显示通道，最大相差一个码值。按旧 1024 格物化再缩成半幅，四个 RAW 状态也出现显示差异。256 行全宽加原四窗布局能重现四个实拍显示摘要，但与 1024 格物化一样，对一幅原全域检查拒绝的极值夹具给出通过。局部降噪定稿继续使用原校验。[全幅、分块和极值回执](evidence/native-dehaze-and-portable-basic.json)

### 去雾候选开启的发布复验

正式套件用同一封存 Release 开启去雾候选。74 态首个可见帧的 P50／P95 为 5.35／18.79 ms，两项通过。首次精确与定稿为 85.88／402.13 ms，P95 上限仍为 252.27 ms。正向去雾最慢状态为 682.50 ms。四个阶段有 20 项性能断言未通过，其中综合交互 12 项，检查器 5 项，LightFlow 对照 2 项，画布缩放与平移 1 项。814 对完整显示摘要与上一次的归档相同，整图 2× TIFF16 的文件摘要、尺寸、位深和 ICC 也匹配。[正式门、成片与超分回执](evidence/native-dehaze-and-portable-basic.json)

画布缩放和平移的正式 P95 为 19.46 ms，比较上限为 8.00 ms。用同一测试包按关、开、开、关单独复采该阶段，P95 为 5.36、8.37、5.78、4.72 ms。该项仍有一轮超线，保留正式失败和全部复采。四轮不足以归因。[画布逐轮对照](evidence/native-dehaze-and-portable-basic.json)

同一测试包复验 Camera Raw 的 158 个适用测量项。27 项语义蒙版、滤镜和胶片模拟用例、9 项蒙版交互、5 项 Prompt 提供者用例均通过。天空和主体 Adaptive 在两张真实 RAW 上完成四次生成、重开和 TIFF16 导出。[实图与逐项索引](evidence/native-dehaze-and-portable-basic.json)

## Batch 23 跨片程序复用与去雾授权

### 两张 RAW 的 Metal 点运算

从正常预览服务依次关闭第一张 RAW、打开第二张，再发出内存压力通知并重开第二张。每次会话以四组参数分别渲染纯光线、复合调色、正和负曝光。候选与原实现各做四轮，每种打开顺序各两轮。两档 Rust/Metal 路径共 96 个完整画面，按来源与配方核对摘要全部一致。候选在换片后复用两个 GPU 程序，内存压力后分别重新编译。每轮关闭照片后增加的 Metal 分配为 1 MiB，内存回收后降到同一打开顺序的对照值。两档均拒绝已关闭会话的请求。[原生阶段、会话与内存回执](evidence/native-program-ownership.json)

| 换片后的第一次该类调整，4 次／档 | 原点运算阶段 P50 | 复用候选点运算阶段 P50 | 原整帧／候选整帧 P50 |
| --- | ---: | ---: | ---: |
| 基础光线 | 6.91 ms | 5.78 ms | 109.91／111.96 ms |
| 纯曝光 | 4.09 ms | 3.03 ms | 6.21／5.04 ms |

各阶段花费以设备已有着色器编译缓存的交叉测量为准。另一个首次基础调色样本耗时 120.98 ms，采集时宿主仍在编译，该样本单独归档。同一候选二进制与默认 Core Image 逐像素对照时，两个曝光配方在两源上逐字节相同。纯光线的两张 2400×1600 画面各改变 9 个像素，复合调色各改变 1 和 2 个像素，RGB 最大差 1 码，alpha 全同。两个 Rust/Metal 预览开关继续默认关闭。[逐像素与冷编译回执](evidence/native-program-ownership.json)

### CPU 基础调色的分段误差

从同一 RAW 恢复 2400×1600 的 Swift V3 全帧线性中间值。现有 C++ 黑白步骤读取这份光线与色彩结果时，最大 RGB 误差为 `1.311×10⁻⁶`，全部分量在 `2×10⁻⁶` 门槛内。原复合配方超线的 27 个分量来自 9 个像素。用实际 Metal 中间值逐级核对 FP32 点积、倒数和融合乘加后，macOS 隔离候选让原三种配方全部通过，其中复合配方最大误差为 `1.848×10⁻⁶`。[原始像素、阶段回读与试验](evidence/basic-v3-cpu-stage-isolation.json)

把同一复合配方的光线与色彩步骤单独重放，候选仍有 1 个红分量达到 `2.146×10⁻⁶`。该合法配方保留为数值反例。既有生产 C++ 和 ABI 保持原版本，隔离候选的全帧回执限 macOS arm64。[独立全帧反例与试验源码](evidence/basic-v3-cpu-stage-isolation.json)

### 正向去雾的分带授权

在原有半浮点侵蚀候选中，每带最多 256 行，私有复制逐行检查取消。完整原件授权在提交前、已提交和等待完成、带完成及发布时核对。两张 RAW 在停编后各做两次原实现和候选的交叉测量。16 张定稿的显示摘要逐帧匹配。实际工作者撤销和移走原件捕获分别在第一带的第 32 行触发，两种失败都在私有带结束时被发现，随后同源重试成功。暖缓存继续可用。[独立授权次数与故障回执](evidence/native-program-ownership.json)

| 原件 | 冷态定稿 P50，原／候选 | 冷态引导图 P50，原／候选 | 暖态定稿 P50，原／候选 |
| --- | ---: | ---: | ---: |
| 9504×6336 | 772.27／652.14 ms | 347.39／244.91 ms | 284.14／305.03 ms |
| 8640×5760 | 622.74／578.39 ms | 284.29／233.46 ms | 212.00／215.18 ms |

两源生成引导图期间的完整原件及工作者授权检查各从 6,695 降至 409 次、从 6,088 降至 374 次。暖态复用引导图且无新写入，耗时未下降。候选沿用已验证的原件、设备和尺寸准入，默认关闭。[两源完整分段与对照](evidence/native-program-ownership.json)

两源另外在标量 GPU 任务提交后立即撤销。任务等待完成，CPU 复制行和可用缓存条目均为零。在冷缓存条目已安装、尚未交付时撤销会清退新条目，同源可以重新生成。撤销暖缓存消费者只释放其借用，下一次获取继续命中原引导图。[提交、交付与热缓存故障回执](evidence/native-program-ownership.json)

### 默认配置的发布复验

正式 74 态首个可见帧 P50／P95 为 5.24／18.74 ms，达到门槛。首次精确与定稿均为 92.50／412.11 ms，各自的 P50 上限是 24.35 和 25.92 ms，P95 上限均为 252.27 ms。正式发布有七个阶段共 45 项性能断言未通过。报告保留窗口缩放与平移、控件、检查器和摄影降噪等原始项目。[发布套件与逐项失败](evidence/native-program-ownership.json)

814 对完整首帧和定稿摘要与 Batch 22 归档匹配。实际 2× TIFF16 的 19,008×12,672 成片、16 位编码、ICC 和文件摘要一致，编码阶段峰值 RSS 为 1,379,745,792 B，通过该项门槛。同一封存构建复核 Camera Raw 的 158 个适用 ID。27 项语义蒙版、滤镜和胶片模拟用例、9 项蒙版交互、5 项 Prompt 提供者用例通过。天空和主体 Adaptive 在两张 RAW 上完成四次生成、重开和 TIFF16 导出。[功能、成片与 Camera Raw 逐项结果](evidence/native-program-ownership.json)

同包本机 FLUX Q8 完成局部 Quick Prompt，耗时 176.19 s。选区的 262,144 个 RGBA16 像素发生变化，保护区的 786,432 个像素逐通道相同，采用和撤销的持久修订为 0→1→2。20 张 RAW 导入与 200 张 JPEG 导出同时进行期间，另一照片从输入到 AppKit 绘制返回为 24.70 ms，采集一次。200 份文件分别与其任务收据及单独运行的合并主干输出匹配。[实际模型、窗口事件与逐件任务回执](evidence/native-program-ownership.json)

## Batch 24 曲线、色阶和去雾还原

### 曲线和色阶的跨平台重放

两张来源已核验的 RAW 各用六份配方重放同一组 2400×1600 像素，包含四个归档点曲线状态、手动色阶和色彩曲线色阶的组合。借用 IOSurface 的 Metal 输出 12 组全部与 Swift V3 的 FP32 逐位相同。Metal 缓冲区后端的两份输出存在至多 `1.025×10⁻⁸` 的浮点差异，12 份 RGBA8 显示均相同。macOS 和 Linux CPU 的 12 份完整输出逐字节相同。两端各通过 22 项 Release CPU 测试，Metal 与软件 Vulkan 均通过融合、分阶段、参数重绑和预算分块测试。[系数、曲线边界与服务器重放回执](evidence/curves-levels-cpu-qualification.json)

CPU 相对 Swift V3 的 11 份输出满足 `2×10⁻⁶` 门槛。主片复合配方有 1 个红色分量达到 `2.02656×10⁻⁶`。将 Swift 的基础调色中间值交给同一 CPU 曲线与色阶后缀时，该像素的红色分量逐位一致，整帧最大误差为 `1.43051×10⁻⁶`。应用的合成精度门槛继续使用原值。[像素与中间值](evidence/curves-levels-cpu-qualification.json)

每张 RAW 以两种开关顺序各跑两轮。正常预览服务交付 104 帧，比较中的交互和定稿摘要均相同，候选有 24 帧实际提交曲线着色器。两张图的 12 个状态各独立检查完整交互读回。主片第一个点曲线状态从 13.30 降至 7.60 ms，次片相同状态从 7.11 到 7.56 ms。主片其余单曲线和手动色阶拖动大多增加约 1–2 ms。候选继续默认关闭。[原生预览的逐帧、冷编译和暖交互回执](evidence/native-curves-levels-and-dehaze.json)

在同一主 RAW 的 2400×1600 画布，将色彩、曲线、色阶、Velvia 100 胶片 LUT 和该图冻结的天空蒙版接成一张图。融合与分阶段按两种顺序运行，每档每轮保留 21 次暖样本。两个色阶参数状态各自匹配完整 FP32 摘要，1,772,225 个零覆盖像素逐通道保持原位型。[真实覆盖、融合与分阶段计时](evidence/native-curves-levels-and-dehaze.json)

| Metal P50 | 四次分阶段派发 | 一次融合派发 |
| --- | ---: | ---: |
| 参数更新至 GPU 完成，两种顺序 | 5.95／6.21 ms | 4.67／4.68 ms |
| 参数更新至完整 RGBA32F 读回，两种顺序 | 13.46／13.91 ms | 12.45／12.48 ms |

### 去雾还原的原生范围证明

同一封存构建以两个相反顺序各跑两张 RAW，原本的半浮点侵蚀保持开启。候选的 16 帧定稿摘要与对照相同。独立整幅检查核对实际 RGBA FP32 原图、R32F 引导和两个强度的还原，逐分量匹配原实现。两源的故障回执覆盖提交并等待之后撤销、来源或缓存授权撤销、同尺寸异源、异引导图和暖缓存重用。尾像素、正负零、正负无穷和 1024 附近的边界使用真实着色器执行。[范围、全图和撤销回执](evidence/native-curves-levels-and-dehaze.json)

| 2400 像素原生定稿 P50 | 原全幅还原检查 | 范围证明候选 |
| --- | ---: | ---: |
| 9504×6336 源冷态 | 913 ms | 811 ms |
| 9504×6336 源暖态 | 309 ms | 315 ms |
| 8640×5760 源冷态 | 827 ms | 628 ms |
| 8640×5760 源暖态 | 275 ms | 160 ms |

范围证明避开原有的重复全幅还原验证，检查阶段与原 FIT 耗时分别归档。主源的两次候选暖态分别为约 208 和 422 ms，其中生成 sRGB8 的阶段为 181 和 389 ms，整帧收益不稳定。候选继续默认关闭。[分段计时与峰值](evidence/native-curves-levels-and-dehaze.json)

### 合并候选的正式套件

同一原生包开启曲线借纹理、去雾半浮点侵蚀和还原证明。74 态的首个可见帧 P50／P95 为 5.40／18.78 ms，达到该项门槛。首次精确和定稿均为 86.30／423.84 ms，P95 门槛为 252.27 ms。启用曲线候选改变了交互代理协议版本，正式脚本拒绝直接比较该阶段。控件、检查器和 LightFlow 比较保留各自的原始结果。814 对首帧与定稿摘要与 Batch 23 默认包匹配，2× TIFF16 的尺寸、位深、ICC 和文件摘要也一致。[候选配置、正式原始结果与成片](evidence/native-curves-levels-and-dehaze.json)

### 同一封存包的默认发布复验

默认配置采用同一二进制并使用原交互代理协议。74 态首个可见帧 P50／P95 为 5.25／15.76 ms，达到门槛。首次精确和定稿均为 86.37／408.55 ms，P50 上限分别为 24.35 和 25.92 ms，P95 上限均为 252.27 ms。四个阶段共 27 项性能断言未通过。814 对首末显示摘要和完整 TIFF16 摘要匹配 Batch 23，编码阶段 RSS 为 1,377,173,504 B，达到内存门槛。[默认配置、性能断言与文件回执](evidence/native-curves-levels-and-dehaze.json)

同包的 15 项点算子、去雾和原件边界用例，27 项语义蒙版、滤镜和胶片用例，9 项蒙版交互和 5 项 Prompt 提供者用例均通过。两张 RAW 的天空和主体 Adaptive 完成四次真实生成、重开和 TIFF16 导出。两档正式结果各核对 158 个 Camera Raw 测量 ID。本机 FLUX Q8 的最新实机回执来自 Batch 23。[Batch 24 的功能及实片回执](evidence/native-curves-levels-and-dehaze.json) · [本机 FLUX 和三视图并行交付](evidence/native-program-ownership.json)

## Batch 25 分带定稿及原生半幅

### 锐化均值

两张原片各用全局锐化、灰阶覆盖及两种局部锐化强度对照整幅、256 行和 768 行写入。各组原生均值的完整 R32Float 摘要逐位匹配，最终 2400×1600 显示摘要也匹配。独立进程按整幅、256 行、256 行、整幅测量。覆盖均值生成和最终读回的进程峰值在主片由 4.44 降至 2.97 GB，在次片由 4.15 降至 2.54 GB。[整幅与分带原始回执](evidence/native-banded-finish.json)

同一封存 Release 的正常预览服务按关、开、开、关运行。每档每原件各有四个局部锐化样本和四个全局／灰阶样本。关闭档使用既有完整图校验，开启档校验全幅均值并复用同一纹理。局部降噪和单点曲线作为对照继续走既有路径。[正常入口的计时与阶段回执](evidence/native-banded-finish.json)

| 原件 | 局部锐化 P50（关／开） | 全局与灰阶锐化 P50（关／开） | 分段进程峰值（关／开） |
| --- | --- | --- | --- |
| 9504×6336 | 432.51／215.15 ms | 327.52／123.97 ms | 4.31／4.58 GB |
| 8640×5760 | 365.51／182.97 ms | 272.26／114.08 ms | 4.32／4.27 GB |

开启后，两张 RAW 独立复跑各 814 对首帧与定稿，完整显示摘要逐对匹配其归档。两档各通过十项定向测试。首带或中间带开始后撤销时先收尾再重试。尾行漏写及均值来源被清退均拒绝交付。候选默认关闭。[阶段、完整显示摘要及取消复验](evidence/native-banded-finish.json)

### Rust 点算子直接消费原生纹理

单独编译的 Rust Metal 探针直接读取私有 RGBA16F 原件。四种方案中，三种单次着色器显式组合四点的半幅 FP32 均产生不同位型，也会改变显示像素。先计算有效 FP32 DAG 再走硬件双线性采样时，两张 RAW 各六种配方的半幅摘要全部逐位匹配显式 Core Image 参考。八个归档曲线状态及两种手动色阶完整显示均匹配，次片的基础调色、曲线和色阶混合配方也匹配。主片同配方有 1,677 个显示像素差一档，原 Core Image 显式半幅进入同一 FIT 时亦复现该差异。该方案留在独立试验接口，保留原定稿作为验收对照。[两源四种方案和失败反例](evidence/native-banded-finish.json)

### 正向去雾半幅

在原范围证明仍生效的情况下，关、开半幅试验分别从正常预览入口复跑两种去雾强度。两张 RAW 共 16 张定稿的像素摘要逐帧匹配。一种真实原图每次核对 60,217,344 个原生像素，另一种核对 49,766,400 个像素。暖态定稿 P50 在主片由 154.69 降至 38.87 ms，在次片由 130.28 降至 36.20 ms。主片对照冷态两次分别约 1,591 和 487 ms，单列回执保留该波动。[去雾分段与发布边界](evidence/native-dehaze-hardware-half.json)

用冻结构建在两张 RAW 各核对六个强度，覆盖 0.001 到 100。每个状态的自然半幅与候选逐分量相同，2400×1600 的 sRGB8 显示逐字节相同。实际提交后撤销工作者、引导图或原件描述符时，等待第八带结束，未发布半幅，重试重新准入。异图和共享预算已占满分别以零提交退出。最终读回完成后撤销仍禁止交付。候选默认关闭。[完整半幅、失败和重试](evidence/native-dehaze-hardware-half.json)

### Linux 目录队列恢复

真实杀死主管与持有 SQLite 事务的工作进程后，同一启动和挂载内的受信重启恢复了未做检查点的已确认任务。13 项试验覆盖完整 WAL、内核写入限制留下的不完整未确认尾、真 SHM 的索引重建、已确认前缀截断和同字节异文件替换。持有同一挂载和目录的 Linux 私有服务试验通过，生产目录的 macOS 书签、远程卷和跨系统重启仍需原生验证。[Linux 队列事务与发布证据](evidence/catalog-wal-recovery.json)

### 同包正式性能及功能复验

正式包同时开启分带锐化、去雾半浮点最小值、还原范围证明和硬件采样半幅。沿用既有的交互代理协议。74 态首次可见 P50／P95 为 5.38／23.55 ms，达到该项门槛。首次精确及定稿均为 89.02／310.29 ms。首次精确 P50 上限为 24.35 ms，定稿 P50 上限为 25.92 ms，两项 P95 上限为 252.27 ms。四个阶段共 19 项性能断言未通过，13 个状态高于 P95 上限。最慢两态是局部降噪，其后是冷启动正向去雾和局部清晰度。[正式断言和尾延迟](evidence/native-banded-finish.json)

814 对首帧与定稿的完整显示摘要匹配上次归档。实际 2× TIFF16 输出的 19,008×12,672 尺寸、位深、ICC 和文件摘要全部一致，编码阶段峰值 RSS 为 1,379,352,576 B，通过该项门槛。13 项原件与定稿边界、27 项语义蒙版／滤镜／胶片、9 项蒙版交互和 5 项 Prompt 提供者用例通过。两张原片各完成天空、主体 Adaptive 的生成、重开和 TIFF16 导出。Camera Raw 对齐表核对了 158 个适用测量 ID。[像素、成片和功能回执](evidence/native-banded-finish.json)

同包本机 FLUX Q8 的选区生成与归档耗时 156.48 s。选区的 262,144 个像素发生变化，保护区的 786,432 个像素在 TIFF16 中逐通道匹配。采用及撤销将修订由 0 推进到 1、再到 2，重开只保留一次提交。20 张 RAW 导入和 200 张 JPEG 导出的实际文件时间窗内，另一编辑窗口的输入到绘制返回为 16.40 ms。200 张成片逐件匹配 Rust 收据和主干的独立导出。[真实模型、选区保护与三视图重叠](evidence/native-banded-finish.json)

## Batch 26 分组归约与 APFS 互操作

### 局部校验

归约继续查询原来的绝对 1024 像素网格，边缘残格保持原边界。每个请求保留原 Core Image 上下文和 `CIAreaMaximum` 图，每组至多备妥 12 个独立的 1×1 RGBAf 标量目的地。组内任何任务开始或等待失败都先收尾已登记任务，再释放目的地。按原顺序核对四通道有限性。定稿继续物化原图。[实现](../../Sources/RAWMasterImaging/DevelopmentCheckedMaximumV3.swift) · [原生回执](evidence/native-grouped-scalar-finish.json)

两张 RAW 的六种局部配方共 96 帧用串行、分组、分组、串行重放。每格四通道标量和完整 2400×1600 显示匹配。独立进程内，主片局部降噪校验 P50 从 231.89 降至 169.83 ms，次片从 191.92 降至 140.28 ms。两档进程峰值均约 2.73 GB。原反例的真实上下文重放覆盖 8 项蒙版夹具和 12 项末端非有限值。串行和分组都拒绝了零覆盖首格的旧反例。换用独立上下文会让两种归约都接受该反例，因此使用同一上下文作判断对照。[像素、时钟和故障回执](evidence/native-grouped-scalar-finish.json)

同一封存 Release 的正常预览服务按关、开、开、关运行，两张原片的四类局部配方均有实际分组回执。局部曲线和径向曝光作为并行对照。定稿摘要逐帧匹配。33 项定向测试通过，实际重新调用验证器时覆盖组中撤销、末格和重试。显式串行开关和分组开关同时启用时，复跑局部降噪及清晰度没有触发分组事件。[实片分段和串行优先](evidence/native-grouped-scalar-finish.json)

| 原件 | 局部降噪 P50（关／开） | 局部清晰度 P50（关／开） | 局部纹理 P50（关／开） | 局部颗粒 P50（关／开） |
| --- | --- | --- | --- | --- |
| 9504×6336 | 438.54／380.58 ms | 300.31／269.08 ms | 300.00／252.64 ms | 279.12／219.01 ms |
| 8640×5760 | 364.07／338.21 ms | 282.74／258.46 ms | 278.16／269.00 ms | 234.15／199.03 ms |

### Rust 半幅的分带提交

按工作组汇总线程计数使实片半幅位型一致，两种顺序的计时差异会反转。在同一个探针中，随后分别把两带和四带编码到一次 GPU 提交。每带参数及回执独立，仍依序执行原 FP32 点运算和硬件采样。两张 RAW 按正反序各测六个配方，共 24 个输入状态，三种提交方式的半幅和最终显示在每个状态逐位匹配。主片混合配方相对旧整图仍有已记录的 1,677 个显示像素偏差。[图像和错误边界](evidence/native-grouped-scalar-finish.json)

| 原件 | 单带／两带／四带提交数 | 借纹理到等待完成 P50 | 加最终显示 P50 |
| --- | --- | --- | --- |
| 9504×6336 | 25／13／7 | 49.30／37.71／33.72 ms | 57.15／45.08／41.35 ms |
| 8640×5760 | 23／12／6 | 44.37／35.23／28.38 ms | 52.09／42.74／35.33 ms |

测得的是调用方经过 Rust 提交及等待的时钟。两带和四带方案也改用不可变的带参数，耗时差包含提交与参数绑定两处变化。在参数绑定相同的两带与四带方案之间，四带的配对中位数再省 6.09 ms。用于唤醒的 Metal 命令缓冲时间戳没有覆盖实际着色任务，证据未用该时间戳计算内核耗时。分带提交通过独立探针验证，普通 Release 提供 16 个既有公共 ABI 符号。[提交次数与两源测量](evidence/native-grouped-scalar-finish.json)

### 冷去雾的引导图写入

两张 RAW 的引导图写入对照均匹配全幅 R32F、两个强度的 RGBAf 还原和两条显示路径。29 项有限值、漏写、撤销和重试检查通过。两带组相对同缓冲串行写入的收益不稳定。两张原片逐带 `startTask` 累计约 126／108 ms，23–25 次等待累计约 0.03 ms。后续优化需针对任务创建及原 Gaussian 图的准备，本轮保留原引导写入。[冷态分段、完整像素和故障](evidence/native-grouped-scalar-finish.json)

### macOS 队列互操作

Apple 系统 SQLite 3.54.0 与独立进程中的 SQLite 3.53.2 在本机 APFS 副本上验证了双向写锁、重试、读快照和提交可见性。原 v10 C ABI 的九个场景执行 61 次调用及 148 次事务内对照，73 次核对零字节 WAL。七次预期拒绝保留原票据，随后九张 JPEG 由原暂存交付，两次确认结果相同。实测 Darwin 在最后一个进程独占原 SHM 映射时报告私有映射，仍拒绝该形态。生产接入还需证明安全书签、附件换代、重挂及崩溃恢复。[APFS 事务、同字节替换和恢复证据](evidence/catalog-macos-interop.json)

### 组合候选的正式复验

封存构建同时开启分组校验、既有颗粒区域校验、分带锐化和正向去雾候选。74 态的首次可见 P50／P95 为 5.07／23.52 ms，通过该项门槛。首次精确及定稿为 84.03／284.82 ms，首次精确 P50 上限为 24.35 ms，定稿 P50 上限为 25.92 ms，两项 P95 上限均为 252.27 ms。四个阶段共 13 项断言未通过，9 态高于 P95 上限。最慢状态为两个局部降噪，其后是冷去雾、局部清晰度和局部纹理。[正式门槛和逐状态回执](evidence/native-grouped-scalar-finish.json)

814 对首帧及定稿摘要匹配前次归档。实际 2× TIFF16 的尺寸、位深、ICC 和完整文件摘要一致，编码峰值 RSS 为 1,378,189,312 B，通过该专项。[完整像素和成片证据](evidence/native-grouped-scalar-finish.json)

同包通过 33 项原生归约、锐化和去雾用例，27 项语义蒙版、滤镜及胶片模拟用例，9 项蒙版交互用例和 5 项 Prompt 提供者用例。两张原片各完成天空、主体 Adaptive 的生成、重开和 TIFF16 导出，Camera Raw 对齐表复核 158 个适用测量项。[功能回执](evidence/native-grouped-scalar-finish.json)

同包本机 FLUX Q8 完成选区生成和归档，耗时 147.45 s。选区 262,144 个像素发生变化，TIFF16 中的 786,432 个保护像素逐通道匹配。采用、撤销及重开保留正确修订和唯一提交。20 张 RAW 导入及 200 张 JPEG 导出的实际文件时间窗内，另一编辑窗口的输入到绘制返回为 14.96 ms。200 张成片的摘要逐件匹配 Rust 收据和主干独立导出。[实机模型与并行交付](evidence/native-grouped-scalar-finish.json)

## Batch 27 Rust 半幅定稿与 APFS 附件换代

### 主画布定稿

通过正常 SwiftUI 预览服务，在两张 RAW 上按关、开、开、关运行同一构建。64 幅 2400×1600 定稿的完整 sRGB8 摘要全部匹配。开关启用时，四个 legacy PCHIP 曲线状态与一个手动色阶状态共 20 次实际进入 Rust 四带程序，并记录 GPU 完成。混合基础调色、曲线和色阶及两个局部曲线对照状态继续由原显影完成。用同一个 Swift 探针换入两份旧版运行库，各验证了六次原路径定稿。运行库一份缺少 v2 配方接口，另一份支持 v2 配方且缺少半幅接口。[两源对照与跨运行库回退](evidence/native-portable-half-finish.json)

| 原件 | 暖态定稿 P50（关／开） | 每个进程第一次定稿 P50（关／开） |
| --- | --- | --- |
| 9504×6336 | 70.39／47.22 ms | 162.87／152.74 ms |
| 8640×5760 | 72.43／43.46 ms | 134.34／144.22 ms |

暖态统计每种尺寸四个后续配方，含真实定稿请求和完整 RGBA8 读回。进程内首次测量包含原生 RAW 解码、上传及候选程序编译。最终构建中四次编译耗时 2.04–3.03 ms，首次定稿尚未获得稳定收益。两个原生用例覆盖配方准入、目标清零后撤销及四带提交后撤销，随后用同一程序重试成功。独立 C ABI 夹具分别初始化两个目标，核验三次重绑各自的 35,020 个半幅 FP32 分量、提交前连续撤销 32 次的设备分配、提交后和等待后撤销、六行尾带的非不透明输入和曲线溢出拒绝。新接口默认关闭。[主画布时钟、显存与撤销](evidence/native-portable-half-finish.json) · [独立 C ABI 夹具](evidence/portable-native-half-api.json)

### 局部清晰度和纹理

提前物化 R32F 高斯因子后单态最多出现 22,853 个显示像素偏差，最大差一个 8 位码值。惰性因子版本在两张真实 RAW 的八个配方状态逐位匹配 1,759,739,904 个 Float32 分量、224 个原校验格和八幅完整显示。独立进程从构图到读回的中位数分别从 251.25 增至 288.08 ms、从 233.68 增至 293.46 ms。清晰度故障夹具在相同取样位置和覆盖输入下也有 94／128 个原生输出分量不同。产品保留现有高斯图和归约。[完整浮点、显示和故障证据](evidence/local-spatial-guide-crossover.json)

### macOS 附件首次创建与换代

在本机 APFS 的九个隔离场景中，系统 SQLite 3.54.0 正常建库，私有 SQLite 3.53.2 从独占主管借入实际主库、WAL 和 SHM 描述符。首次和换代后的 18 次激活均验证了事务使用的文件描述，并在原 keeper 收回借用副本后复核锁。63 次现有 Rust C ABI 调用和 135 次事务内核验通过，其中 60 次核对从真实文件读取的 0B WAL。换代后拒绝旧授权的九个场景均由原票据交付同一 JPEG，两次确认保持一致。[九案锁和收据](evidence/catalog-macos-bootstrap.json)

四个系统默认关闭对照都保留附件。显式将 `PERSIST_WAL` 从 1 改为 0 后，最后一次正常关闭可得到附件缺失的初始状态。系统读者仍在时，即使 TRUNCATE 检查点成功且 WAL 已清空，主管也须继续等待活读者退出。生产采用前还需验证主管崩溃、热 WAL、真实沙箱授权和卷重挂。[主管协议与证据范围](catalog-queue.md#macos-私有目录内首次创建和换代授权)

### 同包正式性能和功能复验

封存的 Release 开启 Rust 曲线和色阶半幅，以及 Batch 26 的分组归约、颗粒、锐化和去雾候选。74 态首次可见的 P50／P95 为 5.24／24.19 ms，通过该项门槛。首次精确及定稿均为 81.97／291.88 ms，首次精确 P50 上限为 24.35 ms，定稿 P50 上限为 25.92 ms，两项 P95 上限均为 252.27 ms。四个阶段共 16 项时延断言未通过。10 个状态高于 P95 上限，最慢的三个状态为两个局部降噪和冷去雾。此次试用保留默认关闭。[正式门槛和逐状态报告](evidence/native-portable-half-finish.json)

814 对完整首帧和定稿摘要匹配 Batch 26。实际 2× TIFF16 的 19,008×12,672 尺寸、位深、ICC 和完整文件摘要匹配，编码峰值 RSS 为 1,378,172,928 B，通过该专项。35 项原生校验及边界用例、27 项语义蒙版／滤镜／胶片模拟用例、9 项蒙版交互和 5 项 Prompt 提供者用例通过。[像素、导出与原生用例](evidence/native-portable-half-finish.json)

两张原片各完成天空、主体 Adaptive 的生成、重开及 TIFF16 导出，Camera Raw 对齐表复核了 158 个适用测量项。同包本机 FLUX Q8 在 180.98 s 内完成选区生成和归档，选区 262,144 个像素发生变化，TIFF16 中 786,432 个保护像素逐通道匹配。采用和撤销后按修订 0、1、2 核验，重开保留一次提交。实际 20 张 RAW 导入和 200 张 JPEG 导出的时间窗内，另一编辑窗口的输入到绘制返回为 18.15 ms。200 张成片逐件匹配 Rust 收据和主干独立导出。[真实模型、画布与批量交付](evidence/native-portable-half-finish.json)

## Batch 28 分组定稿与冻结蒙版调色

### 全幅分组校验的请求内缓存

两个实际 RAW 会话各以关、开、开、关重放九组控件。144 幅定稿的完整显示摘要都匹配。八次局部降噪定稿实际使用缓存，纹理、清晰度和颗粒仍使用原区域上下文。局部曲线、曝光和全局降噪作为实际入口对照，串行开关覆盖缓存试用。[分段时钟、完整成片和串行对照](evidence/native-full-validation-cache.json)

| 原件 | 局部降噪定稿 P50（关／开） | 原分组校验 P50（关／开） | 显示图生成 P50（关／开） |
| --- | --- | --- | --- |
| 9504×6336 | 349.97／277.51 ms | 189.87／150.09 ms | 145.47／99.73 ms |
| 8640×5760 | 288.98／240.51 ms | 152.92／128.07 ms | 117.57／84.44 ms |

同一 Release 的实际校验函数重放了八例蒙版中间图及十二例末端非有限值。全部全幅判定和取得的浮点样本与原归档相同。缓存上下文在原区域外有一个由接受转为拒绝的 `rmMaskComposite` 案例，因此区域校验保留原上下文和清理时机。缓存试用只在全幅入口准入。[绝对格标量、故障与限制](evidence/native-full-validation-cache.json)

### 冷去雾的最小值分带

两张 RAW 对照同一 64 行整数最小值实现的单带和四带提交。提交数分别从 99 降至 25、从 90 降至 23，增加的独立回执缓冲为 245,760 和 212,992 B。完整 RGBA16F 最小图、R32F 引导图、两档全幅 RGBAf 还原及最终显示逐位相同。提交前编码失败、已有提交后的编码失败、在 GPU 运行时撤销以及尾部漏写等六案均验证了丢弃与原请求重试。加宽原 256 行 Gaussian 物化会改变两张原片的引导值，继续沿用原分带。[全幅浮点、故障与分带报告](evidence/native-dehaze-grouped-erosion.json)

正常编辑服务用相同的两张原片按关、开、开、关重放，16 幅去雾定稿的完整显示摘要匹配。最小值阶段 P50 分别从 73.54 降至 59.83 ms、从 58.32 降至 51.14 ms。主片冷态整体定稿关闭时分别为 473.40 和 295.28 ms，开启时为 279.92 和 275.33 ms。次片分别为 266.56、235.55，以及 219.46、226.48 ms。冷态整体时钟包含引导图和最终读回，保留各次波动。两种开关配置的 24 项原生归约和去雾用例均通过。[实际应用对照](evidence/native-dehaze-grouped-erosion.json)

### 受限资料库助手

本机 APFS 隔离实验使用内核对端审计身份和动态签名检查，通过受限助手执行真实 v10 Rust C ABI。五个场景覆盖同标识异签名、附件换代、定点读写权限、目标只读失败和原票据重试。32 次真正受 Seatbelt 限制的进程运行及 26 次 C ABI 请求中，四张 JPEG 均保留原暂存 inode 和摘要，重复确认一致。查询卷 UUID 还需要实际挂载根本身的元数据权限。正式 App Sandbox、Powerbox 书签和 XPC 生命周期仍待实际验证。[签名、权限、事务和成片](evidence/catalog-macos-signed-helper.json)

### 冻结蒙版调色节点

新增的 `mask_tone_v3` 使用原来的配方 v2 和命名覆盖 C ABI。两张真实 RAW 的八种单控件各测两个值。原生按带对照的完整原尺寸 Float32、物理半幅与最终 sRGB8 共 32 态逐位一致，覆盖来自原渲染器的冻结 Float32 蒙版。真实生产 Metal C ABI 对 393,216 个原片窗口像素的结果也逐位匹配。两端 CPU 窗口输出逐字节一致，相对原 V3 的最大绝对误差为 1.60933e−6。软件 Vulkan 的一处色相绿色分量误差为 2.08616e−6，超过 2e−6 的约定，物理 Linux Vulkan 仍待验证。[配方、两原件和失败坐标](evidence/portable-local-mask-tone.json)

直接调用封存运行库的公共 IOSurface 执行器再做全幅对照，32 态中原尺寸和半幅有 26 态逐位一致，最终 sRGB8 有 29 态逐像素一致。所有原生误差均不超过 1.1920929e−7，三幅显示分别有 6、2、2 个像素相差一码。曝光、高光、阴影、对比度、饱和度和色相在此次全幅 Metal 对照中逐位一致，黑位和白位仍有反例。正的 FP32 次正规 alpha 也存在 CPU 与 Metal 错误判定差异。新图继续用于文档中已核验的冻结输入，实时蒙版定稿沿用现有渲染。[封存运行库全幅与精度边界](portable-local-mask-tone.md)

封存的 Swift 用例重放已持久化的天空和主体快照。两道调色节点串接 Spektra Velvia 胶片，将 2400×1600 实片交给 CPU、wgpu 和借入 Metal 纹理。后两者的完整 Float32 输出和原显影一致，1,772,225 个零覆盖像素在各自的共同胶片基底上逐位保留。Linux CPU 通过同一生产 C ABI 执行相同配方、两张覆盖与滤镜资源，完整 61,440,000 B 与 macOS CPU 逐字节相同。当前编辑器仍从既有路径生成实时蒙版。[Swift 与 Linux 的实际冻结重放](evidence/native-grouped-and-tone-release.json)

### 同包正式性能和功能复验

组合候选运行 74 个状态。首次可见 P50／P95 为 5.09／25.53 ms，通过 LightFlow 对照门槛，内部基线的 25.00 ms P95 档仍超线。首次精确及定稿均为 82.04／281.21 ms，首次精确 P50 上限为 24.35 ms，定稿 P50 上限为 25.92 ms，两项 P95 上限均为 252.27 ms。五个阶段共 10 项断言未通过，八个定稿状态仍高于 P95 上限。冷去雾与两个局部降噪状态的耗时最高。两项分组试用保持默认关闭。[正式门槛与逐状态结果](evidence/native-grouped-and-tone-release.json)

814 对完整首帧与定稿匹配 Batch 27。实际 2× TIFF16 的尺寸、位深、ICC 和完整文件摘要一致，编码峰值 RSS 为 1,377,173,504 B，通过该专项。36 项原生归约、锐化和去雾用例、27 项语义蒙版／滤镜／胶片模拟用例、9 项蒙版交互和 5 项 Prompt 提供者用例通过。[像素、成片、内存和功能回执](evidence/native-grouped-and-tone-release.json)

两张 RAW 各完成天空与主体 Adaptive 生成、重开及 TIFF16 导出，Camera Raw 对齐表核对 158 个适用测量项。同包本机 FLUX Q8 在 157.46 s 内完成选区生成和归档，选区 262,144 个像素变化，保护区 786,432 个像素逐通道保持。采用、撤销与重开验证了修订 0、1、2 和唯一提交。20 张 RAW 导入与 200 张 JPEG 导出的实际文件时间窗内，另一窗口输入至 AppKit 绘制返回为 16.98 ms。200 张成片逐件匹配 Rust 收据和主干独立导出。[模型和并行交付回执](evidence/native-grouped-and-tone-release.json)

## Batch 29 跨后端精度与定稿上下文

### 冻结蒙版的跨后端校验

同一封存的 `rawmaster-image` 运行库通过公开 IOSurface C ABI 重放两张 RAW 的 32 个状态。原生 Float32、硬件采样半幅和最终 sRGB8 均逐位匹配原 V3。Metal 的公开缓冲区入口也通过全部 393,216 个真实采样。Linux ARM64 软件 Vulkan 的相同采样全部在 `2e-6` 内。原色相反例绝对误差降至 `1.78814e-6`。物理 Vulkan 设备需按目标平台复验。[Metal 黑白位公式及整图](evidence/native-mask-tone-metal-rounding.json) · [软件 Vulkan 数值及配方](evidence/portable-mask-hue-vulkan.json)

九个正负次正规值、透明像素和覆盖端点通过公开 C ABI。Mac Metal 与软件 Vulkan 的各 65,536 个正次正规 alpha 像素，分别与两端 CPU 的完整输出逐字节一致。反预乘溢出、无效覆盖和发布前失效分别检查状态码、私有输出与重试。原接口与版本化配方沿用既有合同。[数值范围与实现](portable-local-mask-tone.md#batch-29-封存运行库复验) · [C ABI 回归](../../Modules/ImageEdit/tests/metal_surface/c_abi.m)

### 主画布点运算上下文复用

`RAWMASTER_QA_CANONICAL_CONTEXT_REUSE=1` 试用同一已验证横幅 RAW 的 2400 像素主画布定稿。仅复用原几何、受支持的点算子和默认解码细节。`cacheIntermediates` 保持关闭，每次进入和退出均清理缓存。同一个上下文最多执行八次连续已完成请求。授权失效后清退，重试从新实例开始。分析、特殊缓存、缩略图、去雾和空间配方分别使用原上下文。试用默认关闭。[准入和生命周期](../../Sources/RAWMasterImaging/PreviewNativeSource.swift) · [故障与八次上限验证](../../Tests/RAWMasterImagingTests/DevelopmentVerifiedLocalSourceTests.swift)

两张真实 RAW 各按关、开、开、关重放 37 个控件的两档配方。交互帧和定稿共 1,184 个完整显示摘要匹配。每张原片的每个启用轮中，74 次定稿有 39 次使用同一个已清空上下文。两臂各 148 次定稿的比较时钟从单独的定稿请求到完整像素读回。

| 原片 | 关闭 P50／P95 | 开启 P50／P95 | 最高进程物理内存变化 |
| --- | ---: | ---: | ---: |
| 9504×6336 | 76.16／272.96 ms | 67.17／279.98 ms | −4,571,064 B |
| 8640×5760 | 76.11／246.22 ms | 63.03／245.21 ms | −475,016 B |

### 正式性能与出图

开启本次试用后，同包正式 74 态的首次可见 P50／P95 为 4.99／25.84 ms。LightFlow 对照达到该项门槛，内部 25.00 ms 的 P95 上限仍超线。首次精确和定稿均为 73.82／287.03 ms。两者在 Batch 28 为 82.04／281.21 ms。首次精确 P50 上限为 24.35 ms，定稿 P50 上限为 25.92 ms，两项 P95 上限为 252.27 ms。正式脚本退出 1，五个阶段共有 14 项超线，六个定稿状态高于 P95 上限。慢态主要来自冷去雾、局部降噪、局部清晰度和纹理。

814 对完整首帧和定稿摘要与 Batch 28 一致。2× TIFF16 的 19008×12672 成片在位深、ICC 与完整文件摘要上匹配，编码峰值 RSS 为 1,379,041,280 B，达到该专项门槛。36 项原有原生归约、锐化和去雾用例，以及新增的上下文撤销和复用上限用例均通过。27 项语义蒙版、滤镜和胶片、9 项编辑交互及 5 项 Prompt 提供者用例通过。

同包核对 158 项适用 Camera Raw 测量和四次真实 Adaptive 重放。Linux CPU 与 macOS CPU 重放冻结天空、主体及 Spektra Velvia 合成的 61,440,000 B 输出摘要匹配。实际本机 FLUX Q8 选区流程耗时 157.75 s，选区 262,144 个像素变化，保护区 786,432 个像素保持原值。采用、撤销和重开连续验证修订 0、1、2。20 张 RAW 导入和 200 张 JPEG 导出同时有文件在途时，另一画布从曝光输入到 AppKit 绘制为 15.38 ms。200 张成片逐件匹配 Rust 收据和主干的独立导出。[正式性能、功能和成片回执](evidence/native-cross-backend-release.json)

### 真实 App Sandbox 与交付票据

独立签名的 XPC 服务在真实 App Sandbox 下通过同 UID 错签名拒绝、只读原片 FD、目标目录权限拒绝、原 inode 排他发布及双 ACK。涉及真实 Powerbox、生产签名和外置卷的资格单独验收。[受限权限与原生队列](catalog-queue.md#受签名约束的-macos-xpc-服务与临时文件权限)

## Batch 30 全局色轮、冻结局部调色与冷去雾

### 可移植全局色轮

配方 v2 新增 `color_grading_v2`，接入 Rust DAG 的 CPU、融合 GPU 及分阶段 GPU。除单节点外，回归测试覆盖中性曲线节点后接色轮，并核验同一图的参数重绑。分阶段计划保留所有一元节点的源资源至最后一次读取。两张 RAW 的平衡、过渡和亮度各重放两档，共 12 态。Metal 缓冲区的 147,456 个原片取样像素与原色轮逐位一致，两端 CPU 的输出摘要一致。对原 V3 的逐通道绝对误差在两端 CPU 最大为 `7.15e-7`，在软件 Vulkan 最大为 `1.31e-6`，通过 `2e-6` 门槛。

借入 IOSurface 的 659,902,464 个原尺寸像素均有限，alpha 逐位保持，最大通道绝对误差为 `1.19e-7`。最终显示 12 态有 10 态逐像素匹配，原件一的低过渡档与原件二的高亮度档分别差 5 与 2 个像素，最大为一个 8 位码值。半幅最大通道绝对误差为 `7.45e-8`。借入纹理的抽样分段回溯中，所有 2,418 个输出不同的样本都经过出现舍入差的阴影权重，亮度与高光权重逐位匹配。桌面主画布定稿沿用 Core Image V3 色轮。物理 Linux GPU 仍待复验。[参数、整图与后端回执](evidence/portable-color-grading.json) · [探针源码](evidence/portable-color-grading-sources.tar.gz)

### 两种主画布试用

经过原件身份与不透明性核验后，八种单控件径向局部色调可经原蒙版生成冻结 R32F 覆盖并由 Rust Metal 四带定稿。两张 RAW 的 32 个状态在独立全幅 C ABI 对照中原尺寸、半幅和最终显示逐位一致。使用同一 Swift 宿主更换两份旧运行库，各重放四个状态，均成功回到原显影并匹配归档。错误覆盖名称、错误覆盖纹理格式、非有限覆盖和提交后撤销均有原生故障检查，另核验同进程重试。[实现、适用范围和回执](portable-frozen-mask-half.md)

同尺寸原件的冷正向去雾可复用相邻带的最小值中间行。两张 RAW 的 GPU 中间像素写入分别减少 60.06% 与 57.12%。完整半浮点最小图、R32F 引导图、两档 RGBAf 还原以及最终显示逐位匹配。七次注入故障均验证停止发布并在同进程重试。[实现和故障回执](native-dehaze-ring.md)

每张 RAW 由同一正常编辑入口按关、开、开、关重放 74 态。1,184 幅交互和定稿的完整显示摘要全部匹配。启用轮共 64 个局部色调与 4 个冷去雾状态实际命中新路径。

| 原件 | 局部色调定稿 P50（关／开） | 去雾最小值 P50（关／开） | 冷去雾定稿 P50（关／开） |
| --- | ---: | ---: | ---: |
| 9504×6336 | 49.97／60.15 ms | 65.06／53.28 ms | 301.94／326.98 ms |
| 8640×5760 | 51.44／55.72 ms | 58.49／43.07 ms | 248.93／236.19 ms |

局部时钟包含 R32F 覆盖物化、定稿请求及显示读回。每种尺寸与开关组合共 32 次局部色调定稿，两次冷去雾。新路径在两张原片上的局部定稿中位数均上升，去雾阶段收益只在次片传到端到端。两个试用均默认关闭。

### 批量交付登记与持久票据

生产批次登记改为一次编码，沿用 1 MiB 内联清单上限和大清单资源回退。同 Swift 程序更换资料库运行库的四轮原生实测中，保留两侧目录同步的 200 张 JPEG 整批中位为 6.853 秒，试省一次源目录同步为 6.927 秒。保留完整目录同步。两个运行库各复查全部 200 份票据，从准备、排他发布到确认均保留同一份票据，成片逐件匹配原暂存 inode、SHA-256 与字节数。导出整批及首件仍落后于存档中的主干对照。[原生数据、包指纹与回执](catalog-queue.md#工作台登记与逐项文件同步)

### 同包正式性能与出图

封存候选开启本次两项试用。74 态首次可见 P50／P95 为 5.32／25.28 ms，通过 LightFlow 首次可见门槛，内部首次可见 P95 上限为 25.00 ms。首次精确与定稿均为 79.16／284.91 ms。首次精确 P50 上限为 24.35 ms，定稿 P50 上限为 25.92 ms，两项 P95 上限均为 252.27 ms。正式脚本退出 1，五个阶段共 17 项断言超线。九个状态高于定稿 P95 上限，主要为冷去雾、局部降噪、局部清晰度、局部纹理与全局降噪亮度对比。原始正式轮的单窗离屏缩放平移 P95 为 8.91 ms，高于 8.00 ms 相对门槛。同包单独复跑为 4.84 ms，随后用上一批候选复跑为 7.32 ms，两次均通过。正式结果保留首轮超线。

814 对完整首帧和定稿与 Batch 29 逐对一致。实际 2× TIFF16 在 19008×12672 尺寸、位深、ICC、字节数和成片 SHA-256 上一致。编码阶段常驻内存峰值为 1,378,156,544 B，通过该专项门槛。39 项原生定稿、数值与来源用例，27 项语义蒙版／滤镜／胶片模拟用例，9 项蒙版交互和 5 项 Prompt 提供者用例通过。图像 crate 在 Mac Metal、Linux CPU 和软件 Vulkan 分别通过 37、27、37 项用例。

同包核对 Camera Raw 对齐表的 158 个适用测量项。天空与主体 Adaptive 在两张真实 RAW 上完成四次生成、重开和 TIFF16 导出。冻结合成中的天空、主体与 Spektra Velvia 胶片在 Linux CPU 和 macOS CPU 上重放 61,440,000 B 一致，1,772,225 个零覆盖像素保持原值。

本机 FLUX Q8 在 180.38 秒完成局部生成和归档。选区内 262,144 个像素发生变化，选区外 786,432 个像素逐通道匹配。采用、撤销和重开核验修订 0、1、2 及唯一一次提交。实际 20 张 RAW 导入及 200 张 JPEG 导出均有文件在途时，另一张照片从曝光输入到 AppKit 绘制返回为 15.50 ms。200 张 JPEG 逐件匹配 Rust 交付票据和主干的独立导出。[正式性能、功能与成片回执](evidence/native-color-grading-and-mask-ring-release.json)

## Batch 31 色轮定稿、区域蒙版和读快照

### 色轮与复合曲线

Rust 在色轮参数表中分别保存已舍入的阴影下边界和半径，使用两者计算阴影权重。两张 RAW 的 12 个归档独立色轮状态及另四个控件端点状态通过公开 Metal 接口。完整原尺寸 RGBAf、物理半幅 RGBAf 和最终 sRGB8 在这 16 个状态中逐位一致。正常 Swift 主画布以默认关闭的试用开关准入独立色轮。两份旧运行库的回退另有原生核对。[像素及后端回执](evidence/portable-color-grading-exact.json) · [探针源码](evidence/portable-color-grading-exact-sources.tar.gz)

给相同两张 RAW 的色轮叠加非中性 RGB 与红通道曲线后，12 个状态的原尺寸和硬件半幅全部逐位匹配原显影。次片六个最终显示也一致。主片用显式半幅完成显示时，原显影的同样半幅即出现 1,165–1,521 个像素相差一码。复合曲线的桌面显示继续走完整原图。Mac Metal 缓冲区针对纯色轮及复合配方各重放 147,456 个窗口像素，两组均与原显影逐位一致。两端 CPU 在组内摘要相同，最大误差分别为 `7.15e-7` 和 `1.31e-6`。在软件 Vulkan 上精化非线性编码后，纯色轮与复合组最大误差分别为 `9.54e-7` 和 `1.31e-6`，原有 11 个超差分量通过 `2e-6` 上限。实体 Linux GPU 的资格仍开放。[逐源、逐态与数值门槛](evidence/portable-color-grading-exact.json)

共享编码也改进了软件 Vulkan 的既有基础调色与曲线色阶。两片共 172,032 个实际原片窗口像素重放了中性、基础光线、颜色、黑白、曲线、色阶和基础调色后接曲线。中性状态逐位直通，独立节点与 CPU 的最大误差为 `1.19e-6`。基础调色后接曲线的超差分量从 74 减到 9，剩余最大误差为 `2.32e-6`，仍超过专项 `2e-6` 门槛。有调整的旧软件 Vulkan 输出会随编码精化发生数值变化。[公共 C ABI 逐态对照](evidence/portable-shared-color-vulkan.json)

### 冻结径向区域与两种原生降噪控制

径向覆盖按原坐标裁至保守外框。两张原片的归档外框占原面积 45.49% 和 46.91%。首次仍检查完整原件并保存零覆盖区半幅，后续同来源、同几何只重算框内，框外来自已完成显示的私有半幅回执。区域 C ABI 的暖态成功表示完成矩形写入，最终发布还要由 Swift 核验完整目标。正反向改几何、旧运行库和撤权后重试各有原生回执。修正版为独立 Metal 缓冲按 VM 页预收并校验实配大小，主、次片所需空间为 533,413,888 B 和 448,462,848 B，均低于原 512 MiB 上限。[准入、预算和整图对照](portable-frozen-mask-region.md)

全局降噪亮度对比与色彩细节的试用复用已校验的同一相机输入与 Gaussian 1.5 邻域。宿主以实际原件、算子和原输入图为绑定；相机降噪参数变更后重新扫描。两张 RAW 的八个实际状态包含四次暖命中，原尺寸、半幅和最终显示均与原显影逐位相同。非有限值、尾部漏写、撤销和同名不同来源的异常均有独立复跑。[实际图、撤销和失败边界](native-raw-noise-domain.md)

### 工作台导出的读快照

中性批次在已经建立的 SQLite 读事务内复用原片及准入。200 张的两类读取分别从 400 次变为 200 次，六组事务对照生成同一完整来源快照摘要。两套 200 张 JPEG 的首件中位数分别从 169.26 降到 159.71 ms、从 123.16 降到 115.53 ms。整批耗时分别从 6.951 升到 7.798 秒、从 6.474 降到 6.368 秒。每个组合两个样本，保留各轮波动。80 个原生批次的 3,872 个成品逐件匹配原来源、持久票据、摘要和 APFS 文件身份，八库完整且无遗留占位。[原生交叉与快照合同](catalog-queue.md) · [周期内的完整票据](evidence/workbench-snapshot-receipts.jsonl.gz)

### 正常编辑入口的交叉试验

同一个封存宿主在两张 RAW 各按关、开、开、关重放 37 个控件的两档参数。三项新试用同开同关，原冻结蒙版半幅和去雾行缓冲在两臂都开启。独立定稿请求计到完整 sRGB8 读回。1,184 幅交互和定稿摘要及近似标记全部匹配，全部定稿还与各自归档相等。

| 控件组 | 9504×6336 定稿 P50，关／开 | 8640×5760 定稿 P50，关／开 |
| --- | ---: | ---: |
| 独立色轮 | 47.00／35.50 ms | 47.84／35.29 ms |
| 径向局部色调 | 61.27／37.66 ms | 54.72／33.28 ms |
| 全局降噪亮度对比与色彩细节 | 241.52／208.41 ms | 195.16／175.31 ms |
| 每臂完整 148 次定稿 | 68.67／62.21 ms | 68.68／62.36 ms |

每片每次启用运行五个独立色轮实际进入便携半幅，另一档读到同参数的既有精确帧。20 次色轮、4 次区域冷态、60 次区域暖态、8 次降噪范围建立和 8 次复用均有真实事件。区域每片每轮 15 次只处理框内。主、次片区域暖态 P50 为 37.44、33.11 ms。主片色轮开启 P95 由 72.48 升到 114.99 ms，主片降噪开启出现一次 580.59 ms 的冷态定稿。主、次片的最高进程物理内存比关闭臂分别增加 175,407,008 和 173,572,096 B。三项均保持默认关闭。

### 同包正式性能和功能复验

封存 Release 在 74 态下的首次可见 P50／P95 为 5.34／23.79 ms，通过 LightFlow 对照和内部 25.00 ms P95 门槛。首次精确及定稿均为 67.74／281.45 ms，上批为 79.16／284.91 ms。本轮仍高于首次精确 24.35 ms 的 P50、定稿 25.92 ms 的 P50，以及共用的 252.27 ms P95 门槛。正式脚本退出 1，交互、控件和 LightFlow 对照共 12 项断言超线。七个状态超出定稿 P95 上限。最慢的是冷色彩降噪细节 651.27 ms，随后是两档局部降噪、冷去雾和局部清晰度、纹理。[逐态性能与发布门槛](evidence/native-optical-snapshots-release.json)

814 对完整首帧与定稿摘要与 Batch 30 一致。实际 2× TIFF16 的 19008×12672 尺寸、位深、ICC、字节数和完整文件摘要相同。编码阶段常驻内存峰值为 1,378,762,752 B，通过该专项门槛。41 项原生定稿及边界、27 项语义蒙版／滤镜／胶片模拟、9 项蒙版交互和 5 项 Prompt 提供者测试通过，另有 10 项区域和降噪专项及 28 项资料库实库测试通过。图像 crate 在 Mac Metal、Linux CPU 和软件 Vulkan 分别通过 38、27、37 项用例。[完整成片及测试构建指纹](evidence/native-optical-snapshots-release.json)

Camera Raw 对齐表复核了 158 个适用测量项。两张 RAW 各完成天空和主体 Adaptive 的生成、重开与 TIFF16 导出。冻结的天空、主体和 Spektra Velvia 胶片在 Linux CPU 与 macOS CPU 上重放的 61,440,000 B 逐字节一致，1,772,225 个零覆盖像素保持原值。[实片 Adaptive 和跨端重放](evidence/native-optical-snapshots-release.json)

本机 FLUX Q8 在 162.08 秒完成选区生成与 TIFF16 归档。选区内 262,144 个像素发生变化，选区外 786,432 个像素逐通道匹配。采用、撤销和重开核对了修订 0、1、2 及一次提交。20 张 RAW 导入和 200 张 JPEG 导出的文件同时在途时，另一张照片的 AppKit 输入到绘制返回为 15.70 ms。200 份成片逐件匹配 Rust 持久票据和主干独立出图。[真实模型和并行文件交付](evidence/native-optical-snapshots-release.json)

### 分带失败后的释放和重试

分带归约遇到计算编码器无法创建时，会先提交已由 Core Image 编码的部分，等候该 Metal 命令及 Core Image 任务，再返回归约失败。Metal 命令进入错误状态后也等候关联的 Core Image 任务，并保留原 Metal 错误。已提交的其他分带由现有请求清理顺序等候。测试在 M4 Max 上保留同一队列的两个真实命令，于第二带的 Core Image 编码后注入编码器创建失败，核对两个命令在错误返回前均已完成，再用同一个上下文通过完整归约。包含该回归的 Swift 专项共 14 项通过。实体设备丢失和恢复的资格仍开放。[失败路径](../../Sources/RAWMasterImaging/DevelopmentCanonicalFiniteGPU.swift) · [原生回归](../../Tests/RAWMasterImagingTests/CanonicalFiniteGPUTests.swift)

修正版的同包 74 态复验测得首次可见 P50／P95 为 5.59／25.38 ms，略高于内部 25.00 ms P95 门槛。首次精确及定稿均为 73.07／281.66 ms。正式脚本退出 1，四阶段共 14 项断言超线。两轮均超定稿 P95 上限的是两档局部降噪、两档局部清晰度、一档局部纹理和冷去雾。初轮冷色彩降噪细节也超线。两轮的 814 对完整首帧与定稿摘要、实际 2× TIFF16 的文件摘要、位深与 ICC 一致，次轮编码阶段常驻内存峰值为 1,377,484,800 B。

修正版再次通过原生定稿、语义蒙版／滤镜／胶片模拟、蒙版交互和 Prompt 提供者用例。Camera Raw 对齐表的 RAWMaster 实测范围仍为 158 项，天空和主体 Adaptive 在两张真实 RAW 上完成四次验证。本机 FLUX Q8 在 163.20 秒完成生成与归档，选区内 262,144 个像素改变，选区外 786,432 个像素逐通道保留。采用、撤销、重开和逐件票据复验通过。20 张 RAW 导入和 200 张 JPEG 导出同时有文件在途时，另一张照片的 AppKit 输入到绘制返回为 18.10 ms，200 份成片逐件匹配 Rust 持久票据和主干独立出图。[修正版正式性能与功能回执](evidence/native-finite-transport-join.json)

## Batch 32 显示缓冲、去雾引导与批次完成

### 定稿直接写入显示缓冲

同一正常编辑宿主在两张 RAW 上各按关、开、开、关重放 37 组控件的两档参数。开启组实写 280 个拥有独立像素内存的 sRGB8 缓冲。1,184 帧的完整摘要与近似标记跨臂一致，592 幅定稿各自匹配归档。主、次片从请求到完整读回的定稿 P50 分别从 64.52 降到 58.36 ms、从 63.59 降到 58.81 ms。生产显示缓冲的 P50 分别从 29.61 降到 27.80 ms、从 30.61 降到 26.38 ms。次片定稿 P95 从 236.03 升到 236.61 ms。原生用例覆盖真实 Core Image 任务结束后撤销、同一上下文重试，以及清理后从 AppKit 读回原画面。[逐帧摘要、时钟和生命周期](evidence/native-owned-bitmap.json)

GPU 半幅的采样对照在四种带布局上测得两轴权重恰为 0.5。290,304 个常规样本中，Float32 四点求和有 219,690 个分量不同，补偿求和并在平局时向远离零舍入得到零差异。同样数量的跨指数样本仍有 16 个分量不同。定稿采用硬件采样。[Metal 对拍与反例](evidence/metal-half-rounding.json) · [复现源码](evidence/metal-half-rounding-sources.tar.gz)

### 去雾引导图的两带写入

保持原 256 行绝对区域、现有 Gaussian 图、R32F 精度及环形最小值。两个 Core Image 任务可在同一上下文中各写一段私有引导缓冲。只有两任务均结束、全组实写及有限范围已核验并再次取得请求授权后，才推进到下一组或发布。原生实片对照核对了两个尺寸的完整 R32F 引导图、两档全幅 RGBAf 还原及原 FIT 和半幅 FIT 的 sRGB8。单独计时每种方式、每张原片各两轮。

| 原件 | 原引导填充 P50 | 直接写入，顺序发出 P50 | 直接写入，两条同时发出 P50 |
| --- | ---: | ---: | ---: |
| 9504×6336 | 172.90 ms | 160.42 ms | 151.25 ms |
| 8640×5760 | 129.77 ms | 124.70 ms | 117.29 ms |

实测独立路径从冷引导获取到半幅显示的中位数分别从 277.92 降到 256.27 ms、从 210.92 降到 202.89 ms。正式编辑入口另行记时。[实片对照与分带时钟](evidence/native-dehaze-joined-guides.json)

### 局部降噪、纹理及清晰度

先将全幅分带应用到三种局部操作。主片的局部降噪定稿中位数由约 287 降到约 200 ms，其中一档局部清晰度升至 419.64 ms。随后用原校验区域验证区域分带。96 幅完整显示的摘要一致，局部纹理定稿中位数由 237.88 降到 223.71 ms、由 245.52 降到 211.97 ms。主片的局部清晰度从 296.24 升到 322.87 ms。封存候选只对已验证的硬径向单项降噪启用全幅分带，对符合原区域校验条件的正向纹理启用区域分带。清晰度沿用原生分组归约。[切换边界、实片摘要与逐段时钟](evidence/native-local-spatial-transports.json)

### 工作台领取与批次完成核验

纯数据库领取在取得写事务后读取当前目录和子项，再核验父租约和时间。批次收尾先在覆盖索引核对是否已有足够的已登记子项，具备全部子项时逐个验证物理键、冻结序号、清单摘要和可结束状态。macOS 与 Linux ARM64 各通过 33 项 Rust 回归。在回归用例中，第二件测试文件确认后若原票据被移到非规范键，第一件的确认会回滚。恢复原键后，批次可正常完成，重复确认也成功。

同一个 Swift 宿主在两组输入交叉运行两份 Rust 库。80 批的 3,872 件成片逐件核对来源、票据、APFS 身份和文件摘要，八份库全部匹配各自既有输出。200 JPEG 的首件中位数分别为 175.18→167.48 ms 和 118.04→140.72 ms，整批为 7.003→6.968 秒和 6.266→7.021 秒。每组每臂两轮，保留该波动。独立 C ABI 对照的领取中位数为 4.46→4.49 ms，确认为 19.02→19.47 ms。SQLite 单独回放验证前筛减少了 JSON 读取次数，工作台整批仍待达到原性能目标。[运行库、计时和票据核验](evidence/workbench-terminal-rows.json) · [逐件归档](evidence/workbench-terminal-rows-tickets.jsonl.gz)

### 封存候选的联合对照与发布门槛

同一宿主对两张 RAW 分别进行关、开、开、关交叉重放。1,184 幅画布的完整摘要与近似标记一致，592 幅定稿也逐一匹配各自归档。候选实际直接写入 280 幅显示，主、次片每轮各有 43 次上下文复用，关闭时为 24 次。全幅降噪、区域纹理各命中 8 次。四次冷引导命中两带写入。用同一轮编译的 Swift 模块另作全幅读回，两张原片的完整 R32F 引导图及两档 RGBAf 还原均逐位一致。双任务撤销后重试和旧 R32 纹理方案的独立撤销用例也通过。

| 同宿主定稿统计，每片每组 148 个状态 | 关闭 P50／P95 | 开启 P50／P95 |
| --- | ---: | ---: |
| 9504×6336 | 58.89／258.18 ms | 53.31／222.72 ms |
| 8640×5760 | 59.20／238.86 ms | 53.05／206.67 ms |

正式 74 态的首次可见为 5.42／21.07 ms，两项达到门槛。首次精确与定稿均为 59.31／225.94 ms，上批为 73.07／281.66 ms。两者的 P95 均低于既定的 252.27 ms 上限，P50 仍高于 24.35 和 25.92 ms。两档局部清晰度与冷去雾仍各有状态高于 252.27 ms。交互、控件、检查器及 LightFlow 对照共 19 项断言超线，整套发布门仍未通过。正式 814 对完整显示摘要与上一批相同，19,008×12,672 的 TIFF16 成片摘要、尺寸、位深和 ICC 一致，编码阶段 RSS 为 1,348,321,280 B，通过内存门槛。[封存二进制、逐项性能及成片摘要](evidence/native-desktop-transport-release.json)

使用同一封存二进制，在正式 74 态入口再按关、开、开、关各运行一次。四轮均通过逐帧摘要核对。关闭两轮的定稿 P95 为 275.41 和 305.50 ms，开启两轮为 246.57 和 231.10 ms。开启两轮的定稿 P50 为 62.59 和 60.98 ms，仍高于发布门槛。

Camera Raw 对齐表有 158 个 RAWMaster 实测条目。两张 RAW 的天空和主体共四个 Adaptive 用例通过，原生蒙版、胶片模拟、蒙版画布交互和 Prompt 提供方用例也通过。同一封存版本用本机 FLUX Q8 完成一项真实 Prompt，耗时 158.64 秒。262,144 个选区像素发生变化，786,432 个受保护像素保持一致，采用、撤销、重开后的尝试回执均通过校验。20 张 RAW 导入与 200 张 JPEG 导出同时在途时，实际 AppKit 画布从输入到绘制用时 17.16 ms，全部导出文件与逐路径票据、独立 main 输出一致。

最终目录源码按 `rustfmt` 换行后重建了签名运行库。在两个原 Swift 宿主重跑 41 项目录及迁移用例与工作台实片，484 件新成片逐件匹配原工作台输出和票据。真实 v8 快照迁移保留 6,928 个资产、11 个版本和 1,408 个有序文件标识。[格式变更与重建回执](evidence/native-desktop-transport-release.json)

同一 Rust 图像运行库保留 23 个公开 C ABI 符号。Linux 软件 Vulkan 的五次方根修正试验在两张 RAW 已采样的复合色轮上均通过 `2×10⁻⁶` 精度门，在基础调整与曲线串接上仍分别有 9 和 11 个分量超差。封存使用 Batch 31 的图像运行库。实体 Linux GPU、生产 Powerbox 授权及物理外置卷仍待验收。

## Batch 33 空间蒙版请求缓存与跨平台精度

### 保留原局部图的单次请求缓存

裁切局部调整分支及限制变化采样器的 ROI 分别只匹配 28 个状态中的 10 个，八个清晰度和纹理状态均发生变化。候选继续评估原完整图、原高斯尺度和绝对区域。通过同一台设备的交叉计时后，合格的单项正向清晰度与纹理在一个请求中使用专用缓存上下文。验证按原分组清理，显示完成或中止后退出该上下文。只有当前已核验 RAW 的主画布定稿、原始纹理已固定、同一设备的缓存容量达标时才启用。试用默认关闭。

| 操作 | 9504×6336 定稿 P50 | 8640×5760 定稿 P50 |
| --- | ---: | ---: |
| 局部清晰度 | 245.91 → 223.81 ms | 231.90 → 194.18 ms |
| 局部纹理 | 191.35 → 157.82 ms | 191.37 → 152.70 ms |

两片各自的对照组和候选组每个操作各四次。开启缓存后，两张 RAW 的独立进程峰值分别增加 58.79 MB 和 58.05 MB。两张 RAW 共 32 个调整与几何状态的全尺寸 RGBAf、单次 2400×1600 FIT RGBAf 和最终 sRGB8 均逐位相同。同一上下文中的历史反例在原缺首格、边缘、内外蒙版和尾部非有限值上保留原有限值裁决。

同样的硬径向边界可限制单项局部色温、色调及色轮的有限值校验。验证使用已核验且 alpha 为 1 的原始 RGBA16F 纹理，完整保留合成与显示图。只有当前修订、原件、GPU 与纹理授权一致时才启用。试用默认关闭。

在最终封存的原生编辑服务中，两片各按关、开、开、关重放，1,184 帧完整摘要一致，592 幅定稿也匹配原归档。实际使用 16 次空间请求缓存和 24 次点式区域归约。主片所有定稿的 P50／P95 从 57.80／253.28 降到 53.86／224.47 ms。次片 P95 从 218.37 降到 193.08 ms，P50 从 56.65 升至 56.77 ms。次片局部色轮的中位数由 101.56 升至 106.08 ms。两项候选合并后，次片整进程峰值增加 14.83 MB，主片峰值降低 0.33 MB。

对两张 RAW 的清晰度、纹理、局部色温和局部色轮各撤销一次请求。撤权位于真实显示缓冲写入结束后，入口返回取消。原工作器重试时完整显示匹配归档。

最终候选要求区域入口读取同一活纹理的硬件上传回执。两张 RAW 分别先留下 Core Image 的全域有限值回执，再从正常定稿入口执行局部色温。两次均实际使用全幅校验，显示摘要与具有上传回执的路径一致。活纹理、候选权限和原件都在显示后重新核验。

对色温、色调和色轮另测了 48 个状态，覆盖两张 RAW、两个强度、原位置及三种贴边位置。区域校验组和全幅校验组的全尺寸 RGBAf、单次 FIT RGBAf 和最终 sRGB8 逐位一致。[几何、回退与取消回执](evidence/native-spatial-cache-and-software-parity.json)

### 软件 Vulkan 基础调色精度

公开 C ABI 对照两张 RAW 的 14 个基础与曲线组，共 172,032 个采样像素。基础调整串接曲线有 9 个分量超差。追踪首个 Float32 分歧，其中五个来自编码、两个来自对比度幂、两个来自亮度解码。软件 Vulkan 的 WGSL 基础节点在光线及色彩分支采用 `libm 0.2.16` 的正正规浮点数幂算法。曲线及色阶表沿用现有求值。修正后，实片串接的最大绝对误差分别为 `1.1921×10⁻⁶` 和 `1.6689×10⁻⁶`，14 个基础与曲线组及 24 个色轮组均通过 `2×10⁻⁶`。融合、分段及独立节点调用在同一软件适配器中得到相同 Float32 字节。

72 个浮点边界状态的返回状态和 alpha 位型一致。包含 HDR 的边界样本仍有 44 个分量超线，其中 40 个来自 Float32 极值。Metal 试用同一幂运算后，实片超差总数从 21 增至 24。封存沿用既有 Metal 路径，记录 21 个待处理的超差分量。当前已核验的软件适配器为 Linux ARM64 llvmpipe，实体 Linux GPU 的误差及性能仍待测量。

在相同 512×512 实片采样上，以两个 llvmpipe 线程和固定四个虚拟 CPU 重测。每个配方每臂 80 次，运行库顺序交叉，第二组反转配方顺序。基础调整串接曲线的暖态 P50／P95 从 30.34／31.01 增至 42.29／43.74 ms，独立基础光线和色彩调整的 P50 分别从 12.12 增至 24.80 ms、从 12.63 增至 24.50 ms。独立曲线的 P50 为 20.71 和 20.57 ms。[实际运行库、采样和独占计时](evidence/native-spatial-cache-and-software-parity.json)

### 容量故障后的原文件重领和确认

在 Linux ARM64 的 Rust v10 ABI 上，用两个私有 tmpfs 和原工作台快照复现三种真实容量错误。准备票据时和成片已在目标目录后，WAL 追加均由内核返回 `ENOSPC`。目标仍有约 2.7 MiB 数据空间时，因 inode 用尽，排他发布的 `linkat` 返回 `ENOSPC`。观察层记录系统调用返回值。原样 ABI 对照复现了相同的回滚和恢复。

释放配额后，重领可发布原暂存文件。对于成片已发布的批次，取消后遇到同名、同 SHA-256 但不同 inode 的文件会返回冲突。恢复原文件后可重复确认成功，父批次仍为取消状态。新成片与一直持有的原文件描述符同设备、同 inode、同摘要。10 批旧任务和 484 个旧项目的记录逐字节一致。实体卷断电、延迟写回和生产 Powerbox 授权仍待实机走查。[Linux ARM64 内核错误、回滚、恢复与复现脚本](evidence/workbench-filesystem-capacity.json)

### 正式发布验收

加入上传回执检查前的封存中，74 态首次可见 P50／P95 为 5.11／24.05 ms，达到门槛。首次精确和定稿均为 62.70／251.51 ms，P95 在 252.27 ms 上限内。P50 高于各自 24.35 和 25.92 ms 的上限，也高于上轮的 59.31 ms。冷去雾和两档局部清晰度仍有状态高于 252.27 ms。这次正式发布门共 10 项断言超线。814 对显示摘要一致，19,008×12,672 TIFF16 的尺寸、位深、ICC 和文件 SHA-256 一致，编码阶段 RSS 为 1,346,060,288 B，通过内存门槛。

最终封存的 74 态首次可见为 5.20／21.73 ms，首次精确和定稿均为 65.50／238.80 ms。首次精确和定稿的 P95 均通过，P50 均超线。一次局部清晰度和一次冷去雾超过 252.27 ms。综合交互、检查器和 LightFlow 对照共 14 项性能断言超线。814 对画面和完整 2× TIFF16 与上一批一致，编码阶段 RSS 为 1,347,010,560 B，通过门槛。

用同一封存二进制将本批两个试用开关按关、开、开、关复验，74 态定稿分别为 63.47／233.81、60.10／236.48、59.95／242.48、60.99／234.49 ms。四轮的 P95 均通过，P50 均超线。每轮 814 对显示摘要均与正式记录匹配。曲线、去雾与定稿边界 41 项，蒙版、滤镜与胶片模拟 27 项，蒙版交互 9 项，Prompt 提供者 5 项均通过。两张 RAW 的天空和主体共完成四次 Adaptive 生成、重开及 TIFF16 导出。[正式测试与同包复验](evidence/native-spatial-cache-and-software-parity.json)

同包用本机 FLUX Q8 完成真实 Quick Prompt 生成与归档，耗时 149.93 秒。262,144 个选区像素改变，786,432 个保护像素逐通道保持，采用、撤销和重开验证修订 0、1、2 及一次提交。20 张 RAW 导入和 200 张 JPEG 导出实际有文件在途时，另一画布的输入至 AppKit 绘制用时 19.79 ms。全部 200 张成片与逐路径票据和 main 独立导出一致。[模型、画布和逐件交付回执](evidence/native-spatial-cache-and-software-parity.json)

Camera Raw 对齐表共列出 161 个条目。本批已为 JPEG／TIFF 色温、扩展非 RAW 降噪和设备深度生成逐控件计时回执，RAWMaster 侧的 161 项均有同一封存构建的实测。三方处理时钟仍为 71 行，三软件都有人机画布时钟的条目仍为 6 行。[对齐表](../../docs/research/camera-raw-parity/index.html) · [性能边界](../../docs/research/camera-raw-parity/performance-report.html)

## Batch 34 已显影控件与发布验收

### 三个已显影来源的控件回执

新增的原生用例从正常预览服务测量此前只用功能记录覆盖的三项。每个操作在已提交的两种配方间交替 22 次（2 次首帧、20 次暖态），192 px sRGB 见证在计时外读取，两态见证各自唯一且互不相同。报告绑定封存 Release 测试二进制的 SHA-256，并由统一发布脚本在提供相机 JPEG 时生成。[用例](../../Tests/RAWMasterImagingTests/RenderedFileControlPerformanceTests.swift) · [封存回执](evidence/rawmaster-rendered-controls.json) · [校验程序](../../scripts/check-rendered-control-performance.py)

| 控件与来源 | 两种已提交状态 | 暖态 P50／P95 | 首次编辑 |
| --- | --- | ---: | ---: |
| JPEG 色温，`mountain-lake.jpg` 1600×1067 | 近似偏移 −28 与 +28 | 58.31／59.77 ms | 61.59 ms |
| 同上，由该 JPEG 重编码的 TIFF | 近似偏移 −28 与 +28 | 34.85／36.43 ms | 35.18 ms |
| 摄影降噪强度，同一相机 JPEG | 0 与 100，VGG7 全色度模型 | 191.89／199.48 ms | 209.94 ms |
| Lens Blur 设备深度，派生 HEIC 1600×1067 | 焦点 0.25 与 0.75，`Depth` 512×384 | 52.20／56.49 ms | 48.34 ms |

TIFF 由同一 JPEG 逐像素重编码，深度 HEIC 由同一 JPEG 写入真实 Float32 深度附属数据，两者摘要与派生来源都记入回执。测试拒绝非 JPEG 输入和已存在的输出路径。

逐 ID 索引现在由 124 项 resident controls、33 项检查器、1 项学习型 2× 和这 3 项已显影控件组成。封存目录的 `camera-raw-acceptance.json` 与正式目录的 `035-feature-index.json` 都报 `candidateMeasuredFeatureIDs = 161`、`renderedControls = 3`，没有目录外的 ID。

```sh
export RAWMASTER_PERF_CAMERA_JPEG="$MAIN/output/preset-mask-fixtures/mountain-lake.jpg"
out="$(mktemp -d)/rendered-controls.json"
RAWMASTER_RENDERED_CONTROL_IMAGE="$RAWMASTER_PERF_CAMERA_JPEG" \
RAWMASTER_RENDERED_CONTROL_REPORT="$out" RAWMASTER_CONTROL_SAMPLES=20 \
  swift test -c release -Xswiftc -enable-testing --test-product RAWMasterImagingTests \
  --filter RenderedFileControlPerformanceTests
python3 scripts/check-rendered-control-performance.py "$out" --output "${out%/*}/comparison.json"
```

提供 `RAWMASTER_PERF_CAMERA_JPEG` 时，`scripts/test-image-performance.sh` 会自动运行这一阶段；未提供时该阶段不运行，候选索引也就不含这三项。

### 同一封存构建的两次正式运行

两次都用同一个封存 Release（Imaging 二进制 `ba40e4c5…`、UI 测试二进制 `f0c88f78…`）和同一份基准目录。原始报告在 `output/035-development/candidate-batch34-rendered-controls-{enabled,confirm}/`。

| 指标 | 第 1 轮 | 第 2 轮 | 门槛 |
| --- | ---: | ---: | ---: |
| 首个可见 P50／P95 | 5.14／17.04 ms | 4.81／17.84 ms | 8.28／225.69 ms |
| 首次精确 P50／P95 | 77.00／382.66 ms | 80.83／423.27 ms | 24.35／252.27 ms |
| 定稿 P50／P95 | 77.00／382.66 ms | 80.83／423.27 ms | 25.92／252.27 ms |
| 画布 1 缩放平移 relative P95 | 21.14 ms | 21.13 ms | 8.00 ms |

功能与像素：面板逐态与 37 摄影算子的比较器、学习型 2× TIFF16 比较器、输出参考 DNG 比较器均通过，说明完整首帧与定稿摘要、成片尺寸、位深、ICC 与文件摘要仍与前次封存一致。已显影控件的四次测量均取得稳定且不同的见证。

稳定未过门的是首次精确与定稿的 P50／P95、画布 1 缩放平移的 relative P95，以及 LightFlow 对照的 `firstExact`／`final`。其余随轮次变化：第 1 轮交互 2 项、检查器 2 项、面板读回 1 项；第 2 轮交互 1 项、检查器 8 项、控件 1 项（`blur-refine-amount` 的 P95 为 21.70 ms，上限 21.00 ms）。两次运行中 `targeted-hsl` 的交互中位数都高于基准，分别为 16.95% 与 31.77%。检查器的 `light-auto` 两轮都超线。画布缩放平移两次的 P95 几乎相同，属稳定尾延迟而非单次尖峰。

### 发布判定与待评审项

功能侧可以签收：Camera Raw 19.0 的 161 个稳定 ID 在 RAWMaster 侧全部有本轮封存的逐控件或专项回执，三种源类型各按自己的解码器与画布边界核对。性能侧不能签收：正式脚本两轮都退出 1，首次精确与定稿的中位时延是门限的 3 倍以上，P95 在好轮次内曾单独通过。

**请评审首次精确与定稿的门限口径。** 现有门把 LightFlow 的 GPU 完成读数（P50 22.13 ms）当作 RAWMaster 的完整 sRGB8 画面读回上限（24.35 ms）。当前实现的 74 态中位数稳定在 77–81 ms，其中包含全幅有限值校验、蒙版合成和显示转换，而对照产品在同一边界上不执行这些工作。可选口径：一是把「首个精确画面」与「完整定稿」分开设门，二是按状态类型（点算子／空间／去噪／去雾）分别设门，三是维持现门并明确记录该项不通过、以功能签收和逐状态原始数据交付。任一选择都需要独立评审，不能靠合并样本或去掉慢状态来达成。

外部资格仍未完成：物理 Linux Vulkan GPU、实体外置卷断电或拔插、生产 Powerbox 与签名助手。它们与本次功能签收互不替代。

