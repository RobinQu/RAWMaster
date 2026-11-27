# 037 · HDR 实现与验收记录

本页保留各次签名包的原始操作和测量。2026-11-26 至 11-27 的确认表单、独立「色彩与输出」、画布顶预览卡及仅提供曝光的检查器为当时的实现。当前外观共用整幅摄影工具，屏幕分支和余量内联，旧结果从快照更多找回。[当前工作台与六图对照](../025-editing-workspace/appearance-parity.md) · [早期两种引擎的实拍回归](evidence/appearance-roundtrip-20261127.md)

记录从 2026-11-26 原型、诊断文件，到 `main@b238c0ab` 的默认 HDR 入口和 032。应用阶段、显示物理证据及文件交付各自归档。[本次 main 实拍复验](../035-portable-processing-cores/roadmap.md#本次-main-复验)

## 同一签名 Release 首条闭环

2026-11-27，在 Apple M4 Max、macOS 27.0.1（26A434）上用 `main@b238c0ab` 加本轮改动构建一个本地签名 Release。用同一包和隔离资料库完成暗房、Graph、保存、进程重开、两次 032 交付及窗口跨屏。重开前复核 `codesign --verify --deep --strict` 和可执行文件、Rust 图像库、FlashRaw 的 SHA-256。[实拍、包、屏幕与交付回执](evidence/signed-release-20261127.json)

1. 打开固定 `snow.ARW` 和 `person.ARW`。在基础面板选择 HDR，按 Escape 可取消并回到 HDR 按钮。重新打开后确认。雪景在 Graph 添加第二个串行节点，输入 +1.5 EV，撤销到 0，再重做。监看第一节点时保存候选，界面保留监看，冻结版本的输出为第二节点。人像单节点改为 +0.75 EV 后另存。从「作品版本」分别明确采用，退出应用，再打开同一包和资料库。重开的暗房读到各自的曝光，雪景返回完整图。
2. 保存雪景后，在内建屏查看 HDR。临时关闭 LG TV SSCR2 的 HDR，从「窗口」菜单移到 LG，再移回内建屏。窗口 55407 的轨迹依次是内建屏（ID 1）`hdr2020`、LG（ID 5）`sdr709`、内建屏 `hdr2020`。当前 EDR 余量依次为 5.46×、1×、5.46×，LG 的潜在余量为 1×。观察到回退与恢复，回到内建屏时复用同一 HDR 帧 ID。LG HDR 随即恢复开启。记录覆盖实际窗口画面、ICC 与 GPU drawable 完成。面板光度和跨应用显色另验。[AppKit EDR 余量说明](https://developer.apple.com/documentation/AppKit/NSScreen/maximumExtendedDynamicRangeColorComponentValue)
3. 在资料库选这两张，从雪景暗房进入 032。选择「HDR 成片」，预检列出两个已保存版本。确认冻结到独立目录。保留同一选区，切到 SDR、原始尺寸、JPEG 8 位、净图，在第二目录发布。两批完成标记均与各自的清单摘要一致，四项收据各发布一次。逐个验证原片 SHA、两个目标的同一冻结配方对象、版本 ID、输出 SHA 和文件尺寸。dav1d 读回两份 4000×6000、10 位全范围 Rec.2020/PQ AVIF（CICP 9/16/1）。两份 4000×6000、8 位 JPEG 完整解码，均含 sRGB ICC。

**复现中修复的问题。** OpenCV 的缓存静态库在而头文件缺失，打包误认为缓存齐全。现在验证所需头文件及库，重建残缺的自动缓存，并对指定残缺路径返回明确错误。暗房原先由失焦后暂停的旧显影视图承载 HDR 确认，创建和取消同时被禁用。确认工作表改由稳定的检查器承载。保存入口按不可变候选是否存在判断，避免自动保存后禁用首次候选保存。FlashRaw 运行库、原片读取和传感器校准分别报错。显示器 ID、ICC 与余量一并采样并异步发布，旧屏的 drawable 完成回调失效。本轮签名包日志未再出现 SwiftUI 视图更新期间发布状态的警告。

**复跑。** 使用 `scripts/build-app.sh release` 的正常打包和验签。用 `--library` 指向隔离目录，`--interaction-trace` 采集 `scene.drawable.completed`，按上述路径重新运行。原型默认 60 项通过，`--scene-native-only` 和 `--native-graph-only` 各四项通过，覆盖 Escape、运行库失败、连接封锁及 390px 浅色和深色。原生暗房、跨屏和兼容／可编辑 Graph 共七项通过。严格 Rust 与强制 Swift 各通过七项实拍预览、ROI 和交付组件测试。另复跑下文的 PQ 进程中断恢复，首份文件 inode 和第二份暂存摘要均保持。[038 原生闭环](../038-node-dag-workflow/validation.md#与-037-同包的首条-graph-闭环)

**网格直达。** 本次在资料库网格直接点击「批量导出」时触发目录修订已变更，切换范围并重新选择后仍可复现。暗房入口保持这两张选片，分别完成 PQ 和 SDR。此记录对应上一包。修复后的网格直达、选择冲突及四份实拍文件见 [032 网格交付](../032-export-workspace/spec.md#资料库网格直接交付)。[032 范围冻结代码](../../Sources/RAWMaster/WorkbenchActions.swift)

## 集成原型走查

[摄影工作台](../../docs/ui/prototype/index.html) →「岸边的水鸟」→ 编辑 → 右栏色彩模式 → HDR。可从[基础](../../docs/ui/prototype/index.html#edit/basic)打开 HDR 示波器，从模式栏右侧打开「色彩与输出」。从草稿导出时先保存新版本；从作品版本界面进入则使用所选版本。换屏、预览分支和叠加不写历史；确认派生调整才产生一条历史。HDR 路线固定 ACES 2；SDR 胶片仅在独立派生试看与采用。032 的配对选项表示两个文件，不是兼容增益图。

```sh
npm exec --yes --package=agent-browser@0.26.0 -- python3 scripts/check-ui-prototype.py --hdr-only
```

- 1440×900：合格／不合格样片，场景采样的负值，叠加独立开关和 Escape 焦点，模拟换屏保留未提交字段，派生撤销，取消胶片试看，冻结版本的 AVIF＋JPEG，模拟一项失败后只重试未完成项。另核对原片离线、混批无母版、明确 SDR 备选、取消和返回选片。
- 390×844：浅色、深色设置及「色彩与输出」对话框和屏幕按钮可达。另用内置浏览器可信键盘与鼠标验证 HDR 准入、采样、叠加、Escape、换屏及输出信号文字。
- 另以「镜湖人像」先采用 SDR 胶片，验证进入 HDR 时列出冲突：取消不创建版本；明确创建候选会保留原 SDR 草稿，不携带旧胶片，也不自动改采用版本。当前四项专项的细节见下文。
- 此处记录第一轮 T02 原型。固定样点和模拟轴用于交互走查。后续原生示波器和 PQ 队列分别见下文。完整编辑工具、对比模式及 VoiceOver 仍待逐项签收。
- 最终全量回归开启 Graph 视觉证据：**65 个场景通过，退出码 0，无浏览器脚本错误**。短窗旧失败发生在隔离 Chrome 的隐藏标签：保留当前工作台、关闭测试会话内的旧标签并切回后，原短窗几何、可关闭和恢复断言全部通过，未增加超时。截图及复现见 [038 联合回归](../038-node-dag-workflow/validation.md#节点上下文菜单及-hdr-联合回归)。

## 右栏色彩模式与节点面板分区

右栏采用两个同列面板。上方「当前节点」独立于检查器，下方仅「基础」在示波器前显示照片级色彩模式与设置；曲线和照片标题不重复入口。模式用 2px 下划线和按下状态表达。模式只随当前版本配方改变，不随节点、缩放、屏幕或 Graph 开关改变。

1. 在完整工作台选「岸边的水鸟」，进入编辑 →「基础」→ HDR。拖动 HDR Limit 时即时更新 EV 数值，释放才写入历史；改到 +1.5 EV 后，屏幕余量标线与文件峰值保持不变。撤销后展开内联 SDR 派生，输入曝光并切换预览，字段不丢、历史不变，应用才产生一步。不合格片的拒绝原因在主图，可关闭。
2. 打开 [悬浮 Graph](../../docs/ui/prototype/index.html#edit/dag)，下拉查看可编辑节点，基础校正单列。用 Shift+F10 打开调色节点菜单、ContextMenu 打开空白画布菜单；两者分别显示节点与视图操作。Solo／临时旁路互斥，主图和监看均注明不用于导出，退出后配方字节和历史不变。
3. 在 HDR 上按右箭头到 B&W；焦点移动不提交。激活后取消回到按钮；确认后主图呈 SDR 黑白，图的节点、边与选中项不变。持久忽略节点与连续撤销不串改模式；节点下拉的 Escape 不清 HDR 分档。打开作品版本后不显示可写模式或节点栏。
4. 上述 HDR 专项四项通过（退出码 0），包含 390×844 深浅色、032 成对交付及部分失败重试。一次失败是脚本用切换曲线前的 DOM 测量间距；改用当前 DOM 后，间距与分隔线断言仍照常通过。未做原生同动作或原生读屏验收。

## 早期组件资格矩阵

以下为首条签名应用闭环之前的环境记录。目前的实体跨屏、24 MP 与 60 MP 文件、摄影调整和全尺寸分块预算见本页的后续实测。

| 项目 | 现有证据 | 留待放行 |
| --- | --- | --- |
| 窄范围 Sony Bayer ARW | [两张固定实拍与各自摘要](evidence/scene-raw-m2.json)；人像与雪景，方向、超白与饱和位 | 缺标准色卡、高饱和灯光、黑电平和机型覆盖。不能推广到所有 ARW 或 RAW。 |
| 场景转换与标准分支 | 固定 OCIO 向量，见下文；不假定有色卡实测 | 未独立验证 DCP、X-Trans、HDR 合并、光栅 PQ／HLG／增益图。 |
| 交付 | [24MP 冻结版 AVIF／JPEG／PNG 独立回读](evidence/frozen-renditions-20261127.json)、[灰阶 PQ 回读](evidence/scene-avif-readback.json) | 组件证据不是从应用编辑到 032 混批和断点恢复的产品证据。 |
| 显示／安装 | [2026-11-27 AppKit 环境记录](evidence/edr-environment-20261127.json)：一块内建 Retina，潜在 EDR 2.0、当前 1.20；最低系统为 macOS 15 | 余量是环境读数，尚无原生 HDR 查看与 SDR 对照、跨屏或最低系统装包验收；当前默认包路径无固定 `catalog.json` 和 runtime ZIP。 |
| 性能 | 以下列独立门槛衡量 scene F32 融合、OCIO 精度、编码；保留未通过的 10 对 RAW 小样本尾延迟 | 同质视口沿用 [036 验收](../036-render-pipeline-performance/spec.md#验收) p50 ≤25.92 ms／p95 ≤210.23 ms；松手不得重跑 GPU。真实 HDR 同质量口径按 [037 计划](plan.md#调度与判定)至少 30 组交错样本。完整端到端内存、ROI 和尾延迟门槛仍待冻结。 |


## 实现范围

- 输入必须由生产者确认是场景参考，声明原色／白点、线性曝光标定和 alpha 形式。支持线性 Rec.709（D65）、ACES2065-1（AP0／ACES 白）、ACEScg（AP1／ACES 白）；相同原色的显示线性输入也会被拒绝，不执行逆 DRT。
- Swift F32 CPU 参考和真实 Metal `rgba32Float` 路径使用同一固定变换。可生成 ACEScg 工作像素，也可在 AP1 与 AP0 间交换。场景曝光为 `2^EV`，与输入归一化、矩阵和预乘融合在一个 GPU pass。保留正常范围内的有符号浮点和超 1 值，不对 RGB 预先钳制；输出透明像素规范化为零。输入或结果非有限、alpha 越界、区域非法、格式不匹配时拒绝输出。
- ROI 在输入纹理的像素坐标中声明；结果携带原点且只分配该尺寸的 F32 输出。实现等待 GPU 完成与验证后才交出纹理，不将未验证表面送给后续算子。
- 工程入口为 [CPU 合同](../../Sources/RAWMasterImaging/DevelopmentSceneColorV1.swift)与 [Metal 阶段](../../Sources/RAWMasterImaging/DevelopmentSceneMetalV1.swift)，当前只供内部接线和验收，不增加应用控件。OCIO 2.5.0 的 ACES 2 Studio 内置配置固定到 `3a48b0421e51d4284ec07187f86b74387321550b65f5a2f237885bf269dbc99e`；首阶段实现所选线性输入变换，后续固定输出分支见下文。

## 复现方法与判据

```sh
uv run --isolated --no-project --python 3.13 --with opencolorio==2.5.0 \
  python scripts/check-scene-color-reference.py --check Tests/RAWMasterImagingTests/Fixtures/scene-color-v1-ocio.json
swift test -c release --jobs 4 -Xswiftc -enable-testing --filter 'DevelopmentSceneColorV1Tests|DevelopmentSpektrafilmTests|DevelopmentPhotoFilterCanonicalTests|DevelopmentColorIntegrationTests'
mkdir -p output
RAWMASTER_SCENE_COLOR_PERFORMANCE_JSON="$PWD/output/scene-color-metal.json" \
  swift test -c release --jobs 4 -Xswiftc -enable-testing --filter DevelopmentSceneColorPerformanceTests
```

- [功能测试](../../Tests/RAWMasterImagingTests/DevelopmentSceneColorV1Tests.swift)读取 OCIO 独立生成的 128 组向量。每通道允差 `max(2e-7, abs(expected) × 2e-6)`，alpha 要求完全一致。覆盖彩色轴、灰阶、暗部、负值和高曝光、直通与预乘 alpha、显示参考拒绝、Metal 回读、AP1／AP0 往返、ROI 和非法像素。融合阶段与两段执行另做像素对照。
- [性能测试](../../Tests/RAWMasterImagingTests/DevelopmentSceneColorPerformanceTests.swift)在同一设备、同一输入上测单次融合、两次独立阶段，以及一次已在 AP1 的恒等运输。每种尺寸热身 5 次，30 组按次序轮换计时；包含纹理分配、提交、GPU 完成和有限值检查，不包含源上传、磁盘、预览或读回。门槛：融合相对两段的配对中位至少节省 20%，且 p95 不比两段高。该对照检验有无额外 GPU pass，不是旧 SDR 渲染器的提速比。

## 首轮结果

仓库 Release 功能回归 **19 项全部通过**，无跳过：新增场景线性 6 项、现有色彩集成 3 项、标准滤镜 6 项、Spektrafilm 4 项。独立生成的 128 组 OCIO 向量重算与仓库夹具逐字节一致，CPU 与 Metal 均通过像素门槛。真实照片在这一轮只用于现有 SDR 胶片回归，不是新主干 RAW 验收。

性能使用 Apple M2（macOS 27.2.1，26B131）。首轮仓库构建开始时尚未收录新性能文件，直接复用旧测试包未匹配到该用例。正式测量使用同为 Release 的隔离测试包，两个实现文件和性能用例均与仓库逐字节一致；测量时项目 Release 构建及相关回归均已结束。

| 尺寸 | 单次融合 p50／p95 | 两段执行 p50／p95 | 恒等运输 p50／p95 | 配对中位耗时节省 |
| --- | ---: | ---: | ---: | ---: |
| 960 × 640 | 0.76／3.20 ms | 1.54／5.28 ms | 0.78／2.72 ms | 48.1% |
| 3000 × 2000 | 9.93／16.79 ms | 18.30／29.91 ms | 10.78／16.14 ms | 51.5% |

两个尺寸均达到预设门槛。[性能原始样本](evidence/scene-color-metal-m2.json)包含初始化和 60 组热测记录。融合省去一张中间 F32 表面；6 MP 下该表面逻辑大小 96 MB，不等于实际峰值显存减少量。

## 第二轮：真实 RAW、标准成像与文件编码

### 合格 ARW 的场景线性入口

[RAW 入口](../../Sources/RAWMasterImaging/DevelopmentSceneRAWV1.swift)以固定 FlashRaw 0.3.1 只解码 Bayer U16 马赛克，不经过原有会限制部分高光的 RGB 输出。仅接纳一份数据库 D65 矩阵、明确拍摄白平衡、支持的黑白电平与传感器几何；DNG、X-Trans、非 Bayer、已应用白平衡、未知校准以及无法验证的黑电平变化均不冒充合格输入。当前算法为双线性去马赛克、按 CFA 相位黑白归一化、逆相机矩阵及 Bradford→ACES 白→AP1。白平衡只确定中性轴，不调用逐通道高光钳制。另生成每个输出像素的 R/G/B 传感器饱和位，不将其与 `AP1 > 1` 混淆。这不是跨相机质量验收，也未实现传感器高光重建或包围曝光合并。

仓库 Release 的 17 项相关回归均通过，其中 4 项新 RAW 用例覆盖独立 Float64 色样、所有 EXIF 方向、裁切与 ROI、非法输入及两张固定 SHA 的实拍；现有色彩、Spektrafilm 回归也通过。两张皆为 4000×6000（EXIF 8），全尺寸裁出的 ROI 与直接 ROI 逐像素相等，ROI 的 +4 EV 为精确的 16 倍。两张原片 SHA 均未改变。[实拍及耗时原始样本](evidence/scene-raw-m2.json) · [照片来源及许可](../027-mask-ai-raw-integration/portrait-snow-validation.md#来源与复现)

| 样片 | 未触发传感器饱和的 AP1 超 1 像素 | AP1 最小／最大 | 新入口 p50／p95 | 旧入口 p50／p95 |
| --- | ---: | ---: | ---: | ---: |
| 逆光人像 | 19 | −0.0107／1.3696 | 61.35／87.48 ms | 70.14／81.31 ms |
| 日落雪地 | 124,304 | −0.1190／2.4149 | 62.20／81.03 ms | 76.61／108.51 ms |

Apple M2，各图热身 2 次后顺序轮换测 10 对；包括解码、上传、去马赛克及输出完成，不包括应用画布、导出、读回和新引擎初始化。新路线是 F32 加饱和图，旧路线是 F16，两者语义不同。小样本 p95 为最大值；逆光人像较旧入口慢约 6.17 ms，不能宣称尾延迟无回退或达到整机性能门槛。当前 ROI 只缩小 GPU 输出，不减少文件解码或传感器面上传。

### 固定 ACES 2 输出与 AVIF

新增 [ACES 2 Metal 分支](../../Sources/RAWMasterImaging/DevelopmentSceneOutputV1.swift)：Rec.709 SDR 100 nits 和 Rec.2020 HDR 1000 nits 均从同一 ACEScg 母版渲染；各一次 DRT，结果为显示线性，1 对应 100 nits。固定的 OCIO 配置生成 MSL 和两张查表纹理；运行时核对摘要，显示编码另算。独立 Release 测试中的 3 项输出用例通过；每目标 16 组 OCIO CPU 色样及其半透明、全透明形态，覆盖暗部、饱和色、负值和高光。尚未加载通用 OCIO Runtime 或 CLF。

[AVIF 编码器](../../Sources/RAWMasterImaging/DevelopmentSceneAVIFV1.swift)仅接受不透明 HDR 显示线性输入，不静默摊平 alpha 或把 SDR 重标记为 PQ。Metal 执行 ST 2084 转换，ImageIO 写出文件；读取 AVIF 容器的 AV1、像素位深与 CICP 元数据，再核对尺寸。2 项隔离 Release 用例通过，包括伪造标记及截断文件拒绝。独立 FFmpeg 解码确认输出为 10 位 AV1、Rec.2020 原色、PQ、全范围；本机 ImageIO 写的是 **BT.709 Y′CbCr 矩阵**，不是 BT.2020 矩阵，解码按文件实际标记执行。两组灰阶内部 R/G/B 对照的最大码值误差为 0.00227，小于 3／1023；分别解码为 14.38、524.03 nits。[外部回读证据](evidence/scene-avif-readback.json)

全尺寸诊断入口已由仓库 Release 构建；真实雪景 ARW 经 +1 EV、ACES 2 HDR 分支、PQ 编码写出了 5,486,263 字节的 AVIF。`avifdec`／dav1d 实际解码 4000×6000、10 位、Rec.2020／PQ 单帧，同一目标重复写入被拒绝。一次进程墙钟 4.67 s，峰值进程 footprint 约 1.96 GB，未测多张发布的分位数或 UI 响应；编码器填入 CLLI 为 1000／64，未将其当作实测 MaxCLL／MaxFALL。[全尺寸回执](evidence/scene-arw-avif-end-to-end.json)

```sh
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
swift build -c release --jobs 4 -Xswiftc -enable-testing --product RAWMasterDiagnostics
bin="$(swift build -c release -Xswiftc -enable-testing --show-bin-path)/RAWMasterDiagnostics"
RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib" \
  "$bin" --scene-hdr-avif "$PWD/output/spec037-raw-fixtures/snow.ARW" "$PWD/output/snow-hdr.avif" 1
avifdec --info "$PWD/output/snow-hdr.avif"
```

真实样片用前述来源下载、按证据核对 SHA。`RAWMASTER_SCENE_RAW_FIXTURES` 指向含 `person.ARW`、`snow.ARW` 的目录，`RAWMASTER_SCENE_RAW_REPORT` 指向新 JSON 路径，再以 `swift test -c release -Xswiftc -enable-testing --filter DevelopmentSceneRAWV1Tests` 重跑实拍比较。输出和编码用例以同一命令筛选 `DevelopmentSceneOutputV1Tests|DevelopmentSceneAVIFV1Tests`，本次专项在隔离 Release 测试包执行；固定着色器、表数据、参考夹具已由 [生成器](../../scripts/bake-scene-output.py)逐字节复算。

### HDR 曲线与局部曝光算子

[场景调性算子](../../Sources/RAWMasterImaging/DevelopmentSceneToneV1.swift)以 AP1 亮度的曝光档为横轴、同域曝光档为纵轴。在控制点之间线性插值，端点外保持曝光偏移，不把超白像素截在端点。局部曝光以独立 R32F coverage 在场景线性混合；零覆盖不增加局部曝光、alpha 不作为 mask、不同 ROI 原点和非法 coverage 被拒绝。隔离 Release 已运行 4 项输出／编辑用例及 2 项 AVIF 用例，均通过。曲线与 mask 仍未接入配方、画布、历史或诊断命令，未测应用交互性能。

### 原生输出状态契约与复验

[状态契约](../../Sources/RAWMasterCore/DevelopmentSceneOutputStateV1.swift)由 Metal 渲染和上层共享固定目标；分别表示可编码的版本输出参数、非持久的查看状态和不可变交付快照。查看时读实际余量，不能重设快照中的目标或 nits。此处没有修改旧配方、资料库迁移或把新状态装入产品版本；完整 T03 仍需原生读写与回放。

```sh
swift test -c release --jobs 4 -Xswiftc -enable-testing \
  --filter 'DevelopmentSceneOutputStateV1Tests|DevelopmentSceneOutputV1Tests|DevelopmentSceneAVIFV1Tests'
```

仓库 Release 共 8 项通过（2 项状态、4 项输出与编辑、2 项 AVIF），没有跳过上述用例。以固定 FlashRaw 再次导出雪景 +1 EV，dav1d 完整解码 4000×6000 单帧；10 位、全范围、CICP 9/16/1，产物 SHA 与上轮逐字节相同。这个复验仍是诊断命令，不是原生暗房或 032 交付。

### 固定场景工作流的原生组件复验

[工作流值](../../Sources/RAWMasterCore/DevelopmentSceneWorkflowV1.swift)定义 v1 的有界串行曝光 Corrector、稳定节点 ID、启停与输出状态；无预览或屏幕状态字段。仅该曝光算子可融合相加；每个中间前缀必须处于本阶段的有效范围。[执行层](../../Sources/RAWMasterImaging/DevelopmentSceneWorkflowRendererV1.swift)只接收同设备的场景 AP1 F32 工作图，预览入口接受节点／旁路，交付入口只接受从最终图准备的母版。两目标保留各自单次成像；基础 SDR 曝光不改 HDR 母版。未实现的柔和映射、高光压缩和胶片由 SDR 分支明确拒绝，不静默替换。

```sh
swift test -c release --jobs 4 -Xswiftc -enable-testing \
  --filter 'DevelopmentSceneWorkflowV1Tests|DevelopmentSceneOutputStateV1Tests|DevelopmentSceneOutputV1Tests|DevelopmentSceneAVIFV1Tests'
```

Release **11 项通过，退出码 0**，包含节点身份与顺序的严格序列化、未知版本／节点和非法前缀拒绝、GPU 像素比较、临时预览与最终输出隔离。上文实拍命令改用临时新目录重新执行：雪景 +1 EV 通过新固定工作流，dav1d 解码 4000×6000、10 位、全范围 CICP 9/16/1，`cmp` 与历史产物逐字节相等，SHA-256 仍为 `a7d339cbd9a40acc218f965cf3f7f837ad25995cde176713804958ac06501045`。另以同一 Release 构建重跑色彩、旧 SDR 滤镜／Spektrafilm 与场景用例，共 **30 项通过，退出码 0**（含上述 11 项，不重复累计）。这是组件及诊断证明，不是产品版 032 或真实屏幕验收。[038 兼容 SDR 投影](../038-node-dag-workflow/validation.md#原生兼容图与冻结-sdr-导出)已有原生重开和成片等价证据；它保持旧渲染语义，不是场景输入。新的 HDR 固定阶段产品接线、缓存失效和原生查看仍未验收。

### 冻结场景的 HDR／SDR 文件交付组件

[冻结内容](../../Sources/RAWMasterCore/DevelopmentSceneDeliveryV1.swift)包含来源、版本 ID、严格式工作流、输出目标和格式。交付组件先做独占的已验证源捕获，再对同一冻结版本准备一份场景母版；AVIF 10 位 PQ、JPEG 8 位 sRGB、PNG 16 位 sRGB 可分别求值、落盘和返回回执。每张媒体独立预检和准备发布；任一发布准备失败不发布该文件，已准备的暂存项按现有单文件契约保留供所有者处理，其余输出不受影响。取消按准备发布的边界处理，目标同名不覆盖。SDR 分支当前只支持 balanced 映射与独立曝光；不把尚未放行的高光压缩、胶片或软映射当作 SDR 派生成功。该组件未绑定产品编辑版本和 032 租约，不等于队列重启、可移动卷接回或批量交付。

2026-11-27，雪景 ARW（4000×6000，+1 EV）完成三种真实交付。[独立回读](evidence/frozen-renditions-20261127.json)确认 dav1d 解码的 AVIF 为 10 位 Rec.2020／PQ、全范围 CICP 9/16/1，与原诊断产物逐字节相同；`ffprobe` 对该容器报告 1024×1024 编码网格块，整图尺寸以 dav1d 完整解码为准。JPEG 8 位和 PNG 16 位经 FFmpeg 完整解码，ExifTool 从文件各自提取了与仓库 sRGB 配置相同的 ICC。初轮 ImageIO 只写了 sRGB 标记，解码器创建的色彩空间不能证明实际嵌入 ICC；现复用 032 的 Rust 像素编码，保留 F32 求值至末端，新增非对称灰阶用例核对扫描行与单次 DRT。ImageIO 的 AVIF CLLI 1000／64 仍不是样片 MaxCLL／MaxFALL 的独立测量，保留为发布前需验证项。

定向 Release 主回归退出码 **0**，**123 项通过、2 项默认跳过**。[测试摘要](../038-node-dag-workflow/evidence/compatibility/native-release.log)包含旧 SDR 像素、旧版导出、032 像素编码与两张固定 SHA 实拍源；还核对了成功目标不覆盖、发布准备失败保留可核验暂存、其余 SDR 继续、预取消不落盘及原片摘要不变。

随后在同一 Release 构建补跑前一命令默认跳过的两项，退出码 **0**；两轮合计 125 项通过。两种尺寸的 [Metal 单算子复测](evidence/scene-color-component-20261127.json)达到既定融合门槛；[旧显影的真实 RAW 深度与重开回归](evidence/legacy-depth-regression-20261127.json)使用固定本地 Core ML 模型通过。前者不测产品视口，后者不证明 HDR 母版的模型接线或 HDR 像素能力。

复现（使用上文同一来源及固定摘要的 RAW，目的目录不可复用旧文件）：

```sh
evidence="$(mktemp -d)"
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
RAWMASTER_SCENE_DELIVERY_SNOW_ARW="$PWD/output/spec037-raw-fixtures/snow.ARW" \
  RAWMASTER_SCENE_DELIVERY_EVIDENCE="$evidence" \
  swift test -c release --jobs 4 -Xswiftc -enable-testing \
    --filter 'DevelopmentSceneDeliveryServiceV1Tests|DevelopmentSceneOutputV1Tests'
avifdec --info "$evidence/snow.avif"
exiftool -ImageWidth -ImageHeight -BitsPerSample -BitDepth -ProfileDescription \
  "$evidence/snow-share.jpg" "$evidence/snow-share.png"
```

### 持久场景图的冻结版本交付

新场景图使用 `DevelopmentRecipe` schema 4，保存进现有 `LibraryStore` 草稿与不可变版本；未重写旧 v1/v2/v3 字节。工作流、版本及原片准入绑定，不携带屏幕 ICC、EDR 余量或节点监看。旧引擎拒绝这种配方，不能把它显示成“原片未调整”。目录按已存版本 ID 读取冻结票据，校验原片准入与关联；渲染器仍独立验证字节、RAW 校准和几何。两路输出都由同一已保存最终根求值；不是把其中一路逆变换回另一条。

[实拍集成测试](../../Tests/RAWMasterImagingTests/DevelopmentSceneDeliveryServiceV1Tests.swift)用授权雪景 ARW 写入含线性蒙版与非中性 Layer 的版本，另存不同的实时草稿，验证过期修订拒绝，再重开目录、恢复冻结票据并依次写 PQ AVIF 与 sRGB JPEG。此闭环尚无暗房和 032 批次入口；兼容版本和早期串行交付票据均仍可回读。2026-11-27，同一 [70 项 Release 定向回归](../038-node-dag-workflow/evidence/scene-graph/release.log)通过重开及真实交付。[独立回读](evidence/persisted-scene-graph-readback-20261127.json)核验两个 4000×6000 文件：10 位全范围 PQ/Rec.2020 AVIF（CICP 9/16/1）与带实际 sRGB ICC 的 8 位 JPEG，旧诊断 AVIF 仍逐字节相同。

### 原生场景查看与显影阶段

[评审工作台](../../docs/ui/prototype/index.html?sceneNativeReview=1)先验交互，原生在 Release 默认进入；`RAWMASTER_EXPERIMENTAL_SCENE_DARKROOM=0` 可临时隐藏做诊断。浏览器三项阶段走查通过：资料库选片、确认／取消、曝光及撤销、SDR 回退、预览失败重试、390px 浅深色、离线、方向键仅移焦。[浏览器输出](evidence/scene-native-browser.log) · [桌面](evidence/native-scene-review/scene-review-fit.png) · [390px 浅色](evidence/native-scene-review/scene-review-390-light.png) · [390px 深色](evidence/native-scene-review/scene-review-390-dark.png)。默认完整 HDR 原型仍独立运行：`python3 scripts/check-ui-prototype.py --hdr-only` 四项通过。模拟像素不作 EDR 证据。

原生预览先验证捕获的 ARW 内容、方向、裁切和相机校准，再保留一张未平衡的 16 位 Bayer 纹理。FIT 在原图坐标逐像素显影为有符号 AP1 F32，按覆盖面积求平均后执行图。1:1 直接在请求窗口显影，以整幅尺寸和原点计算覆盖。HDR 与 SDR 保留各自的显示后缀。切换原片会释放已取样的图像和示波器栅格，过期或取消的任务无法发布画面。[预览服务](../../Sources/RAWMasterImaging/DevelopmentScenePreviewV1.swift) · [Bayer 显影](../../Sources/RAWMasterImaging/DevelopmentSceneRAWV1.swift)

[暗房 AppKit 画布](../../Sources/RAWMaster/EditingSceneCanvas.swift)取同一画布变换和 FIT 安全边界，显示采用独立的 `rgba16Float` Metal layer、扩展线性 Rec.2020 或扩展线性 sRGB；系统根据明确色彩空间管理屏幕转换。没有把 PQ 文件码值交给浮点画布，也没有把主图读回 RGBA8。屏幕当前余量不足走 SDR 派生；此处只有单屏阶段测试，不是实测亮度或跨屏通过。已保存版本保留场景配方作为像素权威，不用 SDR 代理取代。原生走查使用、创建和另存行为见 [测试](../../Tests/RAWMasterUITests/EditingSceneDarkroomTests.swift)；完整工具、跨屏和目标端见下节。

2026-11-27 · [Release 验收摘录](evidence/native-scene-review/release-test-excerpt.log)，**66 项通过，0 跳过**，另单独复跑一次原生实拍闭环通过。实拍雪景在隔离资料库，通过原生控制器驱动曝光、撤销、重做、另存与重开；AppKit 中实际提交浮点 drawable，SDR 回退不改配方。真实 500×750 ROI 与同一 RAW 的独立区域显影逐像素一致。切换 HDR→SDR、改派生曝光、再回 HDR 共观测到 1 次 RAW、1 次场景图、3 次末端运算，同一 HDR 后缀原样复用。替换同路径同体积源文件必须拒绝缓存。首次 FIT 实拍出现非法像素；将原 Lanczos 路线改成 AP1 F32 面积加权后通过原来的有效性和像素断言。原生窗口切换断言同步等候同一帧与正确 compositor 模式，不以旧帧 ID 作为完成条件。

另以此保存的 HDR 场景候选，经现有 **032** 选片、SDR 预检、缩至长边 600 的 JPEG、Rust 冻结与发布回执通过。测试验证任务中保存的是已存版本（含同一 v4 图），不是当前监看或临时草稿。此接线同时提供 JPEG／PNG 的 SDR 求值；未将 TIFF 当浮点交换，也没有开放产品版 PQ 批量出片或卷重挂验收。

原生热态：用授权雪景、1240×660、2× 背板、单 Corrector 在 1.75／2.25 EV 间交错。每轮 30 个样本，从命令到相应 drawable GPU 完成（SDR 派生）。p50/p95 分别是 **22.85/23.94 ms**、**23.39/25.00 ms**，符合阶段门槛 25.92/210.23 ms。[首轮](evidence/native-scene-review/fit-round-1.json) · [单独复跑](evidence/native-scene-review/fit-round-2.json)。不包含 HID、屏幕发光时延、冷 RAW、真实 HDR 输出、连续拖拽、比对和 1:1 平移放行。命令级复现（资料库为测试临时路径，不使用用户资料库）：

```sh
evidence="$(mktemp -d)"
export RAWMASTER_EXPERIMENTAL_SCENE_DARKROOM=1
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
export RAWMASTER_SCENE_DELIVERY_SNOW_ARW="$PWD/output/spec037-raw-fixtures/snow.ARW"
RAWMASTER_SCENE_DARKROOM_REPORT="$evidence/fit.json" \
  swift test -c release --jobs 4 -Xswiftc -enable-testing \
    --filter 'EditingSceneDarkroomTests|DevelopmentScenePreviewV1Tests|ExportWorkspaceTests'
```

原生可编辑 Graph 接线后按原雪景与 FIT 门槛复验，修复数值输入重建引起的延迟，并将呈现 drawable 限于可见照片区域。最终 **22.07/23.30 ms**（p50/p95）；不缩减取样质量或放宽门槛。节点监看缓存与原始性能回退保留在 [038 阶段证据](../038-node-dag-workflow/validation.md#原生可编辑-graph)，不当作跨屏或完整 UI 放行。

### 真实 60 MP Bayer 的预览和示波器预算

签名 Release 的正常 HDR 入口、实体屏幕 drawable、+0.50 EV 冻结候选及 032 两个实际交付批次均已复验。下列成像测量按阶段记录内存和时间；两份最终文件的尺寸、色彩标记、版本与执行回执见工作台记录。[签名包与双格式成片](../025-editing-workspace/evidence/editor-rails/release-acceptance.json)

Sony ILCE-7RM5 的授权 DSC05995.ARW 有 9728×6656 个传感器位置，成像裁切为 9504×6336。用 `main@1e5a1ceb` 的 Release 解码器读取同一 SHA 后，打开 FIT 报 `surfaceBudget`。当时在读取取景请求前，就为全图 AP1 F32 加传感器饱和标志估算 1,023,694,848 字节，超过 440 MiB。新路径一次保留 16 位 mosaic。960×640 FIT 连同 mosaic 和标志实占 144,179,200 字节，在 (5940, 1584) 的 1188×792 原寸窗口实占 150,405,120 字节。后者在有符号 AP1 和处理后 HDR 两处都与独立原生对照逐像素一致。[Release 实片数据](evidence/real-60mp-bayer-budget.json)

M4 Max 上第一次显示 FIT 用时 436.68 ms，第一次切至该窗口用时 2.36 ms，首次计算全图示波器用时 135.58 ms。+4 EV 的 HDR FIT 峰值是参考白的 8.695 倍。192×128 栅格记录 104 个传感器饱和格点，最终图有当次 Rust 回执，旁路返回直通回执。各预热 5 次再取 30 个样本，60 MP 示波器 p95 为 5.98 ms，24 MP 雪景为 11.79 ms。切回雪景得到 4000×6000 原图尺寸，累计原片采集为两次。完整回归进程中复跑，服务初次 FIT 为 120.25 ms，60 MP／24 MP 的暖态示波器 p95 分别为 1.22／1.44 ms。上述时延止于预览服务返回。八种方向和非整数缩放的面积平均另以独立双精度参考核对。60 MP 整幅 AP1 的最小／最大分量为 −0.002659／2.599685，88 个像素含负分量，433,446 个像素含超白分量。两张 24 MP 实片也保留了负值和超白，雪景 AP1 极值为 −0.119 和 2.415。[原生取样与回归](../../Tests/RAWMasterImagingTests/DevelopmentScenePreviewV1Tests.swift) · [Bayer 数值对照](../../Tests/RAWMasterImagingTests/DevelopmentSceneRAWV1Tests.swift)

场景模型先按原图尺寸运行。尺度回归用确定性 Metal 测试提供器，去噪、2× 超分和分割的输入依次为 8×6、8×6 和 16×12。FIT 和示波器对结果及遮罩按面积取样，偏移的 1:1 窗口在原寸输出取像素并按完整遮罩坐标执行 DAG。三个视图与独立的全图模型结果和逐格参考值一致，切换视图不会重新推理。640 MiB 的模型预览图面预算覆盖 mosaic、传感器标志、模型输出和取样。固定 24 MP 雪景加全图去噪时，这三条路径均返回全尺寸模型超预算。五个 Release 测试类共 28 项，正常环境通过 27 项，禁用 FlashRaw 的单独进程验证了余下一项。[模型尺度与覆盖对照](../../Tests/RAWMasterImagingTests/DevelopmentSceneModelPipelineV1Tests.swift) · [预览与示波器](../../Sources/RAWMasterImaging/DevelopmentScenePreviewV1.swift)

从仓库根目录提供固定的 24 MP、60 MP ARW 和 FlashRaw 0.3.1。报告路径必须是新文件。

```sh
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
export RAWMASTER_SCENE_60MP_ARW="$PWD/output/validation/020-development-controls/final-fit-burst/attempt1/DSC05995-authorized-copy.ARW"
export RAWMASTER_SCENE_DELIVERY_SNOW_ARW="$PWD/output/037-038-product-3g3KH4/photos/snow.ARW"
RAWMASTER_SCENE_60MP_PREVIEW_REPORT="$PWD/output/real-60mp-preview.json" \
  swift test -c release -Xswiftc -enable-testing --filter testOptInReal60MPPreviewBudgetAndReturnTo24MP
```

### 原尺寸分块交付

同一授权 60 MP 原片的已保存候选包含渐变蒙版、曝光校正和图层。测试写入另一份实时草稿，重新打开目录，再冻结原候选并同时请求 PQ AVIF 和 SDR JPEG。每个目标按原图坐标分 35 块执行，共 105 次 Rust 派发。每块在同一校准 mosaic 取数，按整图几何计算蒙版并写入最终 F32 纹理。两个目标共享原片与冻结配方，分别逐块计算各自的输出。每份 Rust 回执覆盖本次 DAG 执行。Bayer 显影、ACES 目标变换与文件编码仍由宿主调用对应的 Metal 或成像组件。图面预算维持 1,536 MiB。计入输出、传感器、设备对齐和图内表面，两次峰值上界均为 1,297,711,104 字节。含编码器的测试进程峰值 footprint 是 3,221,670,504 字节。[执行回执、预算与文件摘要](evidence/real-60mp-bayer-budget.json) · [分块执行](../../Sources/RAWMasterImaging/DevelopmentSceneTiledDeliveryV1.swift)

dav1d 完整解码出 9504×6336 的单帧 10 位全范围 Rec.2020/PQ AVIF，CICP 为 9/16/1。FFmpeg 完整解码同尺寸 JPEG，ExifTool 读出 8 位及嵌入的 sRGB ICC。测试另用旋转裁切、局部蒙版和 SDR 曝光在 12 个瓦片逐像素核对两种目标与整图。实拍交付复现时，将 `RAWMASTER_SCENE_DELIVERY_EVIDENCE` 设为新的空目录，再运行 `swift test -c release -Xswiftc -enable-testing --filter testOptIn60MPFrozenGraphExportsFullPQAndSDRWithinBudget`。[冻结与重开回归](../../Tests/RAWMasterImagingTests/DevelopmentSceneDeliveryServiceV1Tests.swift)

### HDR 示波器与诊断

在[阶段工作台](../../docs/ui/prototype/index.html?sceneNativeReview=1&scopesNativeReview=1)选水鸟、创建 HDR 草稿、展开示波器。用 `python3 scripts/check-ui-prototype.py --scene-scopes-only` 复跑两项，涵盖阶段切换、锁定取样、屏幕标线、取消、窄窗和原片不可用。沿用浏览器代理及模拟数值。

`main@b238c0ab` 的 Release `DevelopmentSceneScopesV1Tests` 三项通过。固定雪景长边 192 的全图栅格包含图、限域前信号、HDR／SDR 目标及小规模回读，p50／p95 为 3.03／3.19 ms。实拍测试确认诊断不清退主图缓存，并核对传感器与目标的独立计数。数值用例未包含 UI 的 180 ms 防抖或实际屏幕光输出。真实窗口诊断、跨屏 ICC 和包含模型的完整回放按 T15／T16 续验。[原生示波器](../../Sources/RAWMaster/EditingSceneScopes.swift) · [本次复验](../035-portable-processing-cores/roadmap.md#本次-main-复验)

### 032 PQ 队列与回读

从 [PQ 评审工作台](../../docs/ui/prototype/index.html?pqReview=1) 多选「日落河湾」和「岸边的水鸟」，在暗房保存后者的 HDR 候选，再在 032 选「HDR 成片」。核对弹窗：前者无 HDR 母版，不能确认。返回选片不新建任务；明确取消勾选不合格行后，确认只冻结 `.avif`。`python3 scripts/check-ui-prototype.py --pq-queue-only` 的三项隔离浏览器检查通过（含 390px、离线和恢复可确认）。[日志](evidence/pq-queue-browser.log) · [混选](evidence/pq-queue/pq-mixed-1280.png) · [窄窗合格项](evidence/pq-queue/pq-ready-390.png)。原型使用样片与模拟，不证明像素或硬件能力。

原生评审默认可见；`RAWMASTER_EXPERIMENTAL_SCENE_DARKROOM=0` 可临时隐藏。确认前显示保存版本和不可用项目；提交前用目录读快照再核对版本 ID、来源和配方摘要，不满足时不会注册批次。Rust 032 保存同一 schema 2 版本资源和 `avif10` 设置，沿用原目录授权、命名冲突、暂存摘要、排他发布和恢复。PQ 的文件限已保存母版全尺寸；不自动缩放，不把 SDR 水印或元数据设置套到 PQ，不将队列目标写回 SDR 可移植预设。10 位 CICP 保留；对 ImageIO AVIF `clli` 自动给出的图片光量字段置为「未指定」（见 [libavif 对零值的定义](https://github.com/AOMediaCodec/libavif/blob/main/include/avif/avif.h)），不改像素数据或把 100/1000 nits 目标当作各照片实测光量。

2026-11-27 · [Release 回归](evidence/pq-queue/release-test-excerpt.log)：28 项通过；需要独立进程的用例另行运行。Rust [队列回归](evidence/pq-queue/rust-batches.log) 21 项通过。实拍人像和雪景 ARW 从导入、已采用场景版本、原生模型逐张预检到 032 的配方资源落盘：混选 SDR／HDR、核对后改采用一个同配方不同 ID 的版本，均在注册前拒绝，没有文件或批次。作者授权及原片 SHA 见[实拍源证据](evidence/scene-raw-m2.json)。

[进程恢复](evidence/pq-queue/restart-summary.json)：第一项已发布、第二项成片暂存并持久化摘要时杀掉隔离写入进程；另起 XCTest 进程。拒绝同路径不同目录；按原目录接回。移走第二张原片触发待找回，不发布暂存；不同原片被拒绝，精确字节重新授权后继续。首文件 inode/摘要未改、次文件匹配中断前暂存摘要，版本 ID 和新资料库选片保留。两个真实文件均由 dav1d 解码为 **4000×6000、10 位、Rec.2020/PQ、全范围 CICP 9/16/1**，且 `clli` 未声明图片光量上限：[人像](evidence/pq-queue/person.pq-0001.avif.readback.txt) · [雪景](evidence/pq-queue/snow.pq-0002.avif.readback.txt)。该测试不等于卷重挂、全部目的地竞争、真 HDR 客户端观片或队列吞吐验收。回执单次墙钟包含测试准备，不是性能分位数。

```sh
export RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib"
swift test -c release --jobs 4 -Xswiftc -enable-testing --filter testWorkbenchPQSettingsLeavePortableSDRPresetsUnchanged
python3 specs/037-color-film-hdr/verify-pq-restart.py \
  --products-dir .build/release --fixtures output/spec037-raw-fixtures --output "$(mktemp -d)/pq"
```

### 剩余发布门槛

固定目标已通过签名包实拍闭环和一组实体 HDR／SDR 跨屏。不同亮度和屏幕组合、同窗比较以及完整视口矩阵仍需在签名应用验收。多机型、完整显影和诊断、同次提交多目标、实际卷重挂、客户端显色和后续格式沿用[放行清单](plan.md#当前实现与验收边界)。九款胶片维持当前 SDR 资产资格。[签名包闭环](#同一签名-release-首条闭环)

## 同一套摄影工具在 HDR 与 B&W 中的成像验收

从资料库打开可标定的 Sony ARW，在编辑器「基础 → 色彩外观」切换 HDR 或 B&W。「基础」「色调」「颜色」「细节」「效果」「色彩分级」「光学」「蒙版」沿用照片工具。摄影参数作用于整图，浮动 Graph 选中的调色节点另有 EV、强度、曲线和覆盖。切回、命名快照和撤销各恢复对应呈现的完整配方。[工作台走查](../025-editing-workspace/appearance-parity.md)

HDR 使用同一份 Bayer 捕获，按相机标定得到带符号的 AP1。全图摄影前缀将其转换到扩展线性 Rec.709，按摄影工具的原生顺序处理，再转回 AP1 供 DAG、显示、SDR 派生和 032 使用。以原图坐标计算邻域、几何和蒙版，FIT 与细节窗口在其后取样。成熟算子沿用 Swift/Core Image 和 Metal，Rust DAG 另有独立执行回执。旧场景归档继续按原版工作，新场景的摄影设置写入 graph 的 schema 3。[成像实现](../../Sources/RAWMasterImaging/DevelopmentScenePhotographicV1.swift)

| 原生输入和操作 | 测量 |
| --- | --- |
| 4000 × 6000 雪景 ARW，取非中部 17 × 11 个原寸像素 | 中性前缀与同一区域的 Bayer AP1 直接输出逐像素差低于 0.003。增加一档曝光后，R 通道相对两倍原值的最大绝对误差低于 0.005。 |
| 同源 64 × 47 原寸块。分别启用颜色、白平衡、清晰度，在近角落区域另测暗角 | 相对中性设置的最大 AP1 通道差依次为 0.389692、0.482704、0.128778、0.073986。提亮的真实通道可以超过 1。 |
| B&W 下调整自然饱和度和饱和度 | 颜色输入改变黑白输出亮度，测试区域最大亮度差超过 0.001，灰阶通道偏差低于 0.001。新选 B&W 的配方在摄影调色、蒙版及修饰之后进行黑白转换，历史配方保留原有算子顺序。 |
| 同一照片在 HDR 滑动自然饱和度三次后松手 | 一次撤销退回拖动前整份配方，重做恢复。SDR 的饱和度保持原值。HDR 命名快照、重新打开后恢复的两种外观、源不受支持或取消切换均有实拍覆盖。 |
| 在 24MP 实拍 HDR 上点击中性灰，再拖动裁切并取消 | RAW 元数据和场景原寸映射共同绑定吸管，解析白平衡写入当前 HDR 配方，撤销恢复且独立 SDR 配方一致。裁切期间取完整画面作参考，裁切参数保存于 HDR，取消时恢复进工具前的状态。 |
| ILCE-7RM5 9504 × 6336。冻结同一版摄影曝光、饱和度、自然饱和度及三节点 DAG 后成对输出 | Rec.2020 PQ AVIF 为 10-bit，SDR JPEG 有 ICC。每份 35 个全分辨率 tile 和 105 次 DAG 调度。两份的资源核算峰值均为 1,458,929,664 B，预算 1,610,612,736 B，含摄影中间资源预留 192 MiB。单次双交付耗时 1.751 秒。原文件哈希在输出前后一致。 |

图中算子及真实差分可用摄影测试复跑，完整 032 版本往返、目标尺寸、编码和哈希可用交付测试复跑。[摄影像素](../../Tests/RAWMasterImagingTests/DevelopmentScenePhotographicV1Tests.swift) · [编辑往返](../../Tests/RAWMasterUITests/EditingAppearanceRoundTripTests.swift) · [冻结并交付](../../Tests/RAWMasterImagingTests/DevelopmentSceneDeliveryServiceV1Tests.swift) · [实测回执](evidence/2026-11-27-photographic-60mp.json)

已准入的模型先以原尺寸执行，再供摄影、图与采样使用。60MP 全图推理超过已声明的预算时会报告原因。传感器饱和叠加仅在能对应原片坐标时显示。拍摄原片、屏幕 HDR 余量以及输出目标属于独立条件。

模型分割在原图坐标中生成蒙版。当最终输出或当前监看的调色节点实际使用该蒙版时，裁切、旋转、透视和有效的镜头畸变校正会移动坐标。编辑器在提交前提示先断开模型蒙版，保留当前草稿和撤销位置。没有连入当前运算的模型、已停用的节点、零权重分支以及不改变坐标的光学校正都能继续使用。预览、示波器和全分辨率交付共用这项判定。

24MP 实拍测试重新打开 SQLite 后读取了两个命名快照。旧快照同时含有裁切和主体蒙版，尝试恢复它时，编辑器解释冲突，SQLite 中的可用草稿仍与打开前逐项相同。另一个快照只含有效的主体蒙版。恢复后拖动裁切被拒绝，松手后的一次撤销直接回到恢复快照之前的配方。[图的输入与准入测试](../../Tests/RAWMasterCoreTests/DevelopmentSceneGraphV1Tests.swift) · [实拍草稿与快照回归](../../Tests/RAWMasterUITests/EditingAppearanceRoundTripTests.swift)
