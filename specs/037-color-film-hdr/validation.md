# 037 · HDR 实现与验收记录

2026-11-26 · 下文区分 HTML 走查、已验证的场景线性／实拍／诊断文件，以及未开放的原生产品流程。不将 JPEG 模拟、诊断命令或工程测试当作 HDR 产品发布、EDR 或整机性能验收。

## 集成原型走查

[摄影工作台](../../docs/ui/prototype/index.html) →「岸边的水鸟」→ 编辑 → 右栏色彩模式 → HDR。可从[基础](../../docs/ui/prototype/index.html#edit/basic)打开 HDR 示波器，从模式栏右侧打开「色彩与输出」。从草稿导出时先保存新版本；从作品版本界面进入则使用所选版本。换屏、预览分支和叠加不写历史；确认派生调整才产生一条历史。HDR 路线固定 ACES 2；SDR 胶片仅在独立派生试看与采用。032 的配对选项表示两个文件，不是兼容增益图。

```sh
npm exec --yes --package=agent-browser@0.26.0 -- python3 scripts/check-ui-prototype.py --hdr-only
```

- 1440×900：合格／不合格样片，场景采样的负值，叠加独立开关和 Escape 焦点，模拟换屏保留未提交字段，派生撤销，取消胶片试看，冻结版本的 AVIF＋JPEG，模拟一项失败后只重试未完成项。另核对原片离线、混批无母版、明确 SDR 备选、取消和返回选片。
- 390×844：浅色、深色设置及「色彩与输出」对话框和屏幕按钮可达。另用内置浏览器可信键盘与鼠标验证 HDR 准入、采样、叠加、Escape、换屏及输出信号文字。
- 另以「镜湖人像」先采用 SDR 胶片，验证进入 HDR 时列出冲突：取消不创建版本；明确创建候选会保留原 SDR 草稿，不携带旧胶片，也不自动改采用版本。当前四项专项的细节见下文。
- T02 尚未完整签收：现有示波器为固定样点与模拟轴，不是自由吸管、真实直方图或像素诊断；未完成全部编辑工具、对比模式和 VoiceOver 逐项走查。真实输出仍未接入 032；不可启用增益图或浮点归档。
- 最终全量回归开启 Graph 视觉证据：**65 个场景通过，退出码 0，无浏览器脚本错误**。短窗旧失败发生在隔离 Chrome 的隐藏标签：保留当前工作台、关闭测试会话内的旧标签并切回后，原短窗几何、可关闭和恢复断言全部通过，未增加超时。截图及复现见 [038 联合回归](../038-node-dag-workflow/validation.md#节点上下文菜单及-hdr-联合回归)。

## 右栏色彩模式与节点面板分区

右栏采用两个同列面板。上方「当前节点」独立于检查器，下方仅「基础」在示波器前显示照片级色彩模式与设置；曲线和照片标题不重复入口。模式用 2px 下划线和按下状态表达。模式只随当前版本配方改变，不随节点、缩放、屏幕或 Graph 开关改变。

1. 在完整工作台选「岸边的水鸟」，进入编辑 →「基础」→ HDR。拖动 HDR Limit 时即时更新 EV 数值，释放才写入历史；改到 +1.5 EV 后，屏幕余量标线与文件峰值保持不变。撤销后展开内联 SDR 派生，输入曝光并切换预览，字段不丢、历史不变，应用才产生一步。不合格片的拒绝原因在主图，可关闭。
2. 打开 [悬浮 Graph](../../docs/ui/prototype/index.html#edit/dag)，下拉查看可编辑节点，基础校正单列。用 Shift+F10 打开调色节点菜单、ContextMenu 打开空白画布菜单；两者分别显示节点与视图操作。Solo／临时旁路互斥，主图和监看均注明不用于导出，退出后配方字节和历史不变。
3. 在 HDR 上按右箭头到 B&W；焦点移动不提交。激活后取消回到按钮；确认后主图呈 SDR 黑白，图的节点、边与选中项不变。持久忽略节点与连续撤销不串改模式；节点下拉的 Escape 不清 HDR 分档。打开作品版本后不显示可写模式或节点栏。
4. 上述 HDR 专项四项通过（退出码 0），包含 390×844 深浅色、032 成对交付及部分失败重试。一次失败是脚本用切换曲线前的 DOM 测量间距；改用当前 DOM 后，间距与分隔线断言仍照常通过。未做原生同动作或原生读屏验收。

## 资格矩阵与放行边界

| 项目 | 现有证据 | 留待放行 |
| --- | --- | --- |
| 窄范围 Sony Bayer ARW | [两张固定实拍与各自摘要](evidence/scene-raw-m2.json)；人像与雪景，方向、超白与饱和位 | 缺标准色卡、高饱和灯光、黑电平和机型覆盖。不能推广到所有 ARW 或 RAW。 |
| 场景转换与标准分支 | 固定 OCIO 向量，见下文；不假定有色卡实测 | 未独立验证 DCP、X-Trans、HDR 合并、光栅 PQ／HLG／增益图。 |
| 交付 | [实拍 AVIF 回执](evidence/scene-arw-avif-end-to-end.json)与[独立回读](evidence/scene-avif-readback.json) | 没有从应用编辑到真实文件、混批和断点恢复的证据。 |
| 显示／安装 | 已测潜在 EDR 2.0，当时可用 1.0；最低系统为 macOS 15 | 缺实际 EDR＞1 与 SDR 对照、最低系统装包复验；当前默认包路径未找到固定 `catalog.json` 和 runtime ZIP。 |
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

Release **11 项通过，退出码 0**，包含节点身份与顺序的严格序列化、未知版本／节点和非法前缀拒绝、GPU 像素比较、临时预览与最终输出隔离。上文实拍命令改用临时新目录重新执行：雪景 +1 EV 通过新固定工作流，dav1d 解码 4000×6000、10 位、全范围 CICP 9/16/1，`cmp` 与历史产物逐字节相等，SHA-256 仍为 `a7d339cbd9a40acc218f965cf3f7f837ad25995cde176713804958ac06501045`。另以同一 Release 构建重跑色彩、旧 SDR 滤镜／Spektrafilm 与场景用例，共 **30 项通过，退出码 0**（含上述 11 项，不重复累计）。这是组件及诊断证明，不是产品版 032 或真实屏幕验收。固定阶段的产品接线、缓存失效及旧配方投影尚未验收。

### 剩余发布门槛

现有应用的显影与导出界面、版本配方、生产 DAG、显示器 ICC／EDR、HDR 编辑控件、输出工作台、双表示增益图、HLG、浮点归档和 HDR 胶片路线尚未接入或通过端到端验收。系统报告设备潜在 EDR 为 2.0、测量瞬间可用为 1.0，仅是环境读数，不是 EDR 窗口通过。现有九款胶片仍是 SDR 外观。
