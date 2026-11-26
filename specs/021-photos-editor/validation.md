# 021 · 逐轴验证草稿（2026-11-01）

性能与最终集成验收进行中。原失败不覆盖，重叠测试不累加，API/原生draw/跨应用、元数据/像素、单例/整批、后端/前端各自计量。研究预览21.19已封存交付，仅独立QA图库、canonical默认/无QAflag，非正式安装；生产20.0不变。

| 轴 | 实际事实 | 边界 |
|---|---|---|
| 旧204回归 | 两轮146+178=324 unique PASS，4+7skip | 非单次全套；冷context53PASS/1skip与其重叠，含14nativepoint |
| 后续定点 | frontend78PASS/1skip；Auto v1.1 89/1；common v2.1 92/1 | 三轮也重叠，不加成新unique总数 |
| 最后指定回归 | Core/AI修后321PASS/5skip/0FAIL；final focused73PASS/0skip | 重叠22不相加；旧320PASS+1fixtureFAIL历史保留 |
| native21.14 | 强度.51648351648/Undo0/Redo标签/Color保Light；RAW3胶片ready，owned0 | 不由此证明性能 |
| native21.15 | 一张RAW真实饱和度交错/七次CmdZ恢复/正常退出；选定两暖interactive draw-return197/186ms，首次563ms、穿零后969ms | QA opt-in而formalOFF；非20warm样本/WindowServer/跨应用比较，GUI峰值未采样 |
| native21.19 | 实验label；−5Auto/UndoRedo/save F429/reopen/GUI16TIFF2212×1272；+5noResult记录精确不变；drag/hold与UndoRedo、两Undo回original；owned0 | 无自动采用；canonical默认，小图3.2MP interactive163.6ms/settle-trigger后109.6ms，仅AppKit返回，非大RAW/WindowServer/跨app |
| TIFF16源精度 | 60217344不透明像素，RGB p99/max0LSB、alpha65535，峰2442414720B | 固定病例3/4GiB通过，低alpha仅tiny |
| Photos效果 | 原20固定病例15PASS/5FAIL | 暖高光Brilliance/Light Summary、精确曲线、Sharpen、旧common-neutral外部差异保留 |
| 自然图九滤镜 | 原片+九种9504×6336全图/5ROI限定门通过 | 旧严格码值失败保留，非全域等价 |
| B7 | 两源各25实际resolved元数据，直接CPU/GPU/reserved/inflight/retired/union最终0 | 非50组像素PASS；RAW3GiB目标失败 |
| 设置/runtime | 六页实际界面、全局一键准备/关设置继续/重开ready | borrowed models只读、用户条款、无自动上传或收费调用 |

## 暗房右侧调整面板走查

[工作台 → 编辑 → 基础](../../docs/ui/prototype/index.html#edit/basic)，使用默认样片 `DJI_0348.DNG`。展开光效，方向键将曝光从 `0` 调到 `0.05`；输入 `0.137` 并回车。水平拖动名称 40 px，松手后一次撤销须恢复 `0.137`。停用并启用光效，核对数值保留；复位并撤销，核对组仍展开。输入 `99` 时不能提交，Escape 恢复输入前的值。切到曲线，再回基础核对光效仍展开。浅色检查整行、分隔线和启停图标；深色用设置 → 通用切换；窄窗检查文字、数值和焦点不互相覆盖。

Photos 的截图只用作控件外观参考；保留 RAWMaster 的工具分类、现有能力和草稿语义，不引入 Photos 专有算法，也不把原型模拟值当作 RAW 输出。浏览器实操已验证方向键、精确输入、真实拖动与一次撤销、停用保值、分组复位与撤销，以及深色下非法输入和 Escape；Tab 提交曝光后焦点进入对比度滑块。`scripts/check-ui-prototype.py` 的 37 组场景通过，包含窄窗、空库及离线照片回归。[390 × 844 深色调整面板](evidence/adjustments-compact-dark.png)。

原生用 `NSHostingView` 在测试图库打开暗房，验证展开光效、曝光控件和数值框的辅助功能标识、分级启停保值、切换曲线与退出裁切。控件测试覆盖一次拖动只打开及结束一个手势、双击单项复位、精确输入、非法值及 Escape；草稿测试覆盖单次撤销。原生专项共 25 项通过。[原生深色调整面板](evidence/adjustments-native-dark.webp)取自测试窗口渲染，未用于验证 RAW 像素。原生暗房沿用深色显示，原型另走查浅色；本会话未能操作 Photos 实机。

较宽的 Swift 回归中，未改动的 `testDevelopmentPreset1075MetadataDirectorySearchStableReferencesAndHiddenRows` 失败：其收藏首组与导入条目数量断言不符合当前预设目录。这不是右栏调整验收的一部分。

### 等距滑块、扁平菜单与工具提示

实机在 macOS Photos 的 Adjust 中展开 Light → Options 和 White Balance，并对照 Warmth、修饰大小、Neutral Gray、RGB 与取样按钮。未保存或修改 Photos 照片。RAWMaster 保留已有调整入口和草稿，采用同一行高和固定刻度空间、末端单色箭头、独立取样按钮；工具提示不使用系统默认气泡。

从[基础原型](../../docs/ui/prototype/index.html#edit/basic)展开光效：指针扫过曝光和对比度，主、次刻度显隐但两行位置不变；停用光效后刻度不显示。Tab 聚焦滑块可见刻度，输入仍交给数字框。在桌面悬浮曲线图标，提示在左侧且不截点击；在 390 × 844 中提示上下换位且始终在参数区之外。到修复面板选择「仿制」核对扁平下拉仍可更改选项，切回基础后保持同一草稿。浏览器回归 37 组通过，含刻度与提示的可见性及坐标断言。原生专项 27 项通过，覆盖滑块输入区、装饰刻度区域、满宽菜单的原生选择分发及既有编辑路径。见[原生右栏截图](evidence/adjustments-rhythm-native.webp)；截图为未悬浮状态。

## 饱和度后端、前端与common扩展

- 历史旧A：22质量PASS；18暖API中位6306→105ms约60×，2cold约6.2s、零值legacy约5.8s。不是原生UI60×。
- 9e新A：22质量PASS（0d264bb7），峰4278964832B，4GiB研发门通过/3GiB目标失败；冷7383/6911ms、零值5888ms。
- 旧B4.360GB及efaa新helper B4.592GB均越4GiB，原FAIL保留。QA哈希CPU临时生命周期修正未改数学/文件/门；ONE B3.478GB字节一致只是一例。
- 新Bfull22：独立22全帧严格字节一致（778bf45a）；峰3658238136B，4GiB通过/3GiB失败；cold906/877ms、零536ms、暖99–114ms，API数据不等UI。
- 冻结9e四生命周期ABA/持provider/取消压力/源失效真实join和final owned0；峰分别3.825/2.829/2.832/2.845GB。ABA仍3GiB失败，未知nativeTaskCount为null不得写0。
- frontend小交错A/B各9质量通过，峰3509948640/3684026600B；冷取消B1输出通过，峰3458680728B，fill1/hit1/preserved1与实际join，最终owned0。仍非全21point/OSpressure/跨应用资格。
- common v2严格FAIL保留。v2.1 A8/8质量PASS，grain fallback0LSB；B前2ColorPASS、第3grain fallback严格RGB p99 2/max5 FAIL停止，后续grain0/Light未比较。整体OFF、不再缩域/改门；旧模板commonV21Qualified=true由append-only erratum明确不是资格PASS。
- final outstanding中的B冷actualSummary4GiBFAIL继续保留；源配方单例重放PASS不覆盖此资源失败。
- formal defaultOFF；仅严格QA bundle/env opt-in研究profile。跨应用同图20warm+3cold未达，多项3GiB目标未达；4GiB是受控研发门，非用户通用承诺。

## Auto实验与测试资料恢复

v1.1真实Vision：固定−5照片candidate3.500000026°，typed±3roll residual max.125/conf1；固定+5 positive noHorizon，总体双向自然门65f4仍FAIL，不叫qualifiednegative。21.19实际研究入口“自动（实验）”，条件原生−5一Undo/Redo、保存候选F429/从此继续重开、原片仍采用与GUI16bitTIFF2212×1272（72cdd…）通过；+5noResult保work/version/export/配方不变。

原helper漏PNG白名单导致正常创建空项目/会话但0asset，失败现场保留。两原PNG→无损TIFF已独立全RGBA8/alpha255/有效ICC/up方向0LSB（a5f1d3a）；public恢复existing90A5项目，新session C6B7…、2assets/2neutral originals，原片采用未变；失败后新32表备份与所有旧行保持。此为输入容器/资料准备PASS，不能翻转原自然pairFAIL。

**源+保存配方strict TIFF重放：本固定病例PASS（37a24732…）。** 2212×1272、2813664像素/通道，stored straight RGBA16 max[0,0,0,0]、两侧6964 fractional-alpha像素同，文件字节同72cdd。GUI archivedPNG16→TIFF与source+savedrecipe→canonicalTIFF是不同链；原DB/WAL/SHM物理pins前后同，仅owned rawcopy/backupclone读、无新Vision/adopt。attempt1误用legacy尺寸guard的metadataSTOP保留，工具纠正后实际映射2212×1272通过，未改产品/门。只属3.2MP/8bit-origin样本，不给其他PNG32LSB翻牌。

## 证据入口

- `output/validation/021-photos-editor/native-pointwise-backend-9e-qualified-summary.json`：后端A/B与四生命周期；`imaging-p3bb/interactive-proxy-v1/native-f32-frontend-interleave/runs/`：A/B/冷取消。
- `native-preview-package-21.19.json`（signed28a7c336…、producer1fb27dc2…）；`native-qa/final21.19/actual-result.json`（5601d3…）与GUI export receipt；`native-qa/public21.14/actual-result.json`、`native-qa/profile21.15/actual-result.json`（cb2f）；AppKit held输入时长含主动按住，release指标null不能当2.5s渲染耗时。
- `native-pointwise-frontend-build-attempt1/`、`crop-auto-controlled-roll-build-attempt1/`、`native-point-common-v21-build-attempt1/`；`final-core-ai-regression-after-fixture-fix/`与`final-app-copy-abi-build-attempt1/`，旧失败与fixture checkpoint保留。
- `imaging-p3bb/interactive-proxy-v1/native-f32-common-v2-qualification/runs/A-compare-attempt1/result.json`；`native-f32-common-v2_1-qualification/runs/{A,B}-compare-attempt1/`及B append-only erratum。
- `crop-auto-natural-v11-qualification/runs/positives-attempt1/receipt.json`；`native-qa/crop-auto-tiff-recovery/{converted-001/equivalence.json,run-001/receipt.json,preflight-001/after-import-audit.json}`。
- 原完整源精度、效果账、B7、设置与REA证据仍由 `delivery.html` 逐行链接；REA静态/MCP可用不等于恢复私有算法。

以上相对证据均在 `output/validation/021-photos-editor/`。所有旧producer/失败保留；production20.0与个人库未因报告升级。研究预览交付与未完成性能/一致性分开；最后strict replay与append-only final-acceptance（97962f85…）已收；研究预览交付不等全部目标完成。

研究ZIP：`research-preview-21.19-package.json`，691422925B，SHA ef7cdf06…e89a，682项CRC通过/内binary28a7匹配；含offline runtime无模型权重，仅本机独立研究配置，其他机器fresh installer/portable生产release未资格。


## 紧凑检查器、白平衡与蒙版

- [基础原型](../../docs/ui/prototype/index.html#edit/basic)：展开光效，比较轨道两边与内容边界；悬停混色图标，在桌面检查气泡及箭头与图标分离，在 390 × 844 检查上／下避让。用方向键切换停靠示波器，量到 36 px／48 px；打开独立示波器，核对矢量绘图区仍为 130 px。[Chrome 浅色：箭头气泡、停靠示波器和白平衡](evidence/compact-tooltip-browser.webp)。
- 在同一 RAW 草稿应用「阴天」，复核示例 6500 K／10；改为中性灰只切换方式，历史不增加。开启取样，Escape 退出；重新取样后才出现暖色微调，撤销恢复上一步。原型使用示例值，不证明解码参数准确性。原生保留源绑定、RAW 近似预设和 JPEG/TIFF 近似单位。
- [蒙版原型](../../docs/ui/prototype/index.html#edit/masks)：新建径向后取消一次，再在画布拖出选区；主体示例可隐藏叠加，采用后才出现在图层；复核选区未改时不能再采用。保留一个主体蒙版再新建亮度范围，检查上下限约束、启停、删除和撤销；[已选径向图层](evidence/compact-mask-browser.png)。手动遮罩、语义画笔及局部渲染沿用各自原生实现；没有通用组件交集。
- 逐项核对原生扁平标签：示波器、裁切方向、曲线类型、HSL 组织、修复方式、全局分级、蒙版曲线通道、蒙版分级和精修画笔；旧编辑器的曲线／分级标签使用相同组件。资料库、对比、设置和 Prompt 的非调整标签不在本次更改之内。

本轮完整 Chrome 脚本 38 个场景通过，另在独立 Chrome 用真实悬停捕获箭头，并在嵌入浏览器实际拖出径向蒙版。此前一次跨视图导出等待超时，完整复跑通过。

原生专项 24 项：22 通过、1 跳过（需配置 `RAWMASTER_MASK_FIXTURES`）、1 失败。NSHostingView 中实测轨道左右各 12 pt，箭头完全位于按钮左侧且与未覆盖按钮的像素一致；从真实辅助功能入口切换两个示波器、展开新建菜单、取消径向、创建范围、启停并撤销。RAW 六种预设、非 RAW 拒绝光源预设、恢复原照保留暂存参数均通过。[原生蒙版分组](evidence/compact-mask-native.webp) · [原生示波器读取中与白平衡缺基准](evidence/compact-basic-native.webp)。截图来自测试宿主窗口，未验证 RAW 像素或安装包。

`testAutomaticTemperatureTintCanBeUndoneReopenedAndExported` 在调用自动分析前即无法建立会话：编辑界面 active、源 ready，但默认预览不可检查（`inspectable=false`）；独立重跑和挂载原生工作台复查均未解除，未验证实际自动分析后的撤销、重开和导出。较宽整合回归还记录了既有滤镜保存预览租约等待超时和缩略图计数差异，本轮未改滤镜或预览后端。

### 上述失败的复核

真实 PNG 自动白平衡端到端复验通过：采用分析得到的近似色温／色调，撤销与重做，关闭后读回同一草稿，并以真实 PNG16 渲染验证成片采样颜色确实变化。冷进程的真实滤镜归档约 7 秒完成，改用有上限的状态等待，未降低配方、归档和原片哈希断言。目录用例递归检查组内 1,075 条夹具、同名搜索和隐藏 Look／sidecar；区分 13 种可用滤镜和 10 张经典滤镜缩略图。

复验缩略图缓存时 macOS 崩溃回执确认 `Thread stack size exceeded`，发生在定稿回调内部再次进入配方校验。将配方校验和缩略图输入指纹提前至挂接回调前；回调只从当前原生图像物化缩略图。选择滤镜不重建候选、后续调色保留可见图直到新集到达、退出归零及黑白颗粒热复用／冷路径逐像素相同均通过。

扩大原生回归共选中 110 项：106 项通过、4 项因未配置真实 RAW 样片或专用 GPU 实验环境而跳过，零失败。已在 `/Applications/RAWMaster.app` 安装 ARM64 优化 Release（构建 `20261126.104948`），安装前后签名校验通过，保留旧构建 `20261126.0950`。从安装路径启动并成功初始化临时资料库（SQLite `quick_check` 为 `ok`），随后正常退出。此本机签名包不内置完整分发包要求的固定版本离线 AI 运行时。

### 示波器放大与平面控件复核

入口：[基础](../../docs/ui/prototype/index.html#edit/basic)、[蒙版](../../docs/ui/prototype/index.html#edit/masks)、[细节](../../docs/ui/prototype/index.html#edit/detail)。停靠绘图区改为 108／144 点，白平衡校正按钮逐行全宽，校正与微调额外间隔 12 点；checkbox 为平面描边与勾选。蒙版创建及候选操作使用图标配文字，图层类型、启停与管理分别表达不同含义。Alcedo 参考源为本机已有 `EditorAiMaskPanel.qml:297`、`EditorMaskGroupDelegate.qml:575`、`EditorMaskGroupMaskRow.qml:61`；未复制外部代码或图标，未新增图层组合或保护能力。

在内置浏览器执行了 `check-ui-prototype.py` 中「紧凑示波器、白平衡与蒙版分层」的同一组断言：高度、独立窗口、标签样式、按钮堆叠、微调间距、RAW 预设、取样取消、候选采用、范围限制、删除与撤销、七种不同工具图标、checkbox 互斥与撤销均通过。另以真实 Space 按键勾选超分开关，并检查 390 × 844 窄窗的肤色模式按钮全宽、间距与无横向溢出、浅色 checkbox 外观。原脚本整套入口因当前 PATH 无 `agent-browser` 未能执行，不将本次专项结果描述为整套浏览器回归通过。[基础证据](evidence/expanded-scopes-wb-browser.png) · [蒙版空状态](evidence/mask-empty-browser.png)。

原生专项 20 项全部通过，零跳过、零失败。实际挂载窗口的辅助功能框核对停靠绘图区为 108／144 点、白平衡两个操作各占整行并与下拉同宽；checkbox 保持 `AXCheckBox` 角色、0／1 状态、响应式绑定和禁用态，浅深色逐像素检查确认无渐变凸起；七种图标均可渲染且图形不同。原先新增 AX 用例中的文字状态和启用属性读取假设已按 macOS 的数字状态与 `isAccessibilityEnabled` getter 修正，未取消这些验证。白平衡实际分析、撤销、重开和导出及蒙版历史回归均通过。[原生基础](evidence/expanded-scopes-wb-native.png) · [原生新建工具](evidence/mask-tools-native.png) · [原生图层](evidence/mask-icons-native.png)。原生截图来自测试挂载窗口，包含模拟源的读取状态，不作为像素处理质量证据。最后一次完整专项重跑仍为 20 项通过，勾选框焦点状态由独立 View 持有。离屏 `ImageRenderer` 外观测试仍输出 FocusState 未挂载的运行时警告；真实挂载窗口的角色、状态和操作测试通过，但本轮没有作 VoiceOver 人工验收。本轮未重新构建 Release 或替换应用目录中的上一版安装。

### 文字节奏与颜色采样列表

从[基础](../../docs/ui/prototype/index.html#edit/basic)进入直方图下的颜色采样区，另从[细节](../../docs/ui/prototype/index.html#edit/detail)对照文字。以原生细节区的参数 4 点、说明 7 点、功能块 12 点分层，不改变滑杆 26＋6 点的控件与刻度高度。白平衡标题去掉额外顶部 padding，校正／微调边界保留 4＋12 点。曲线、分级和 Point Color 的连续参数另分成 4 点子组；光学、深度精修、蒙版、修复与去朦胧分别整理相关说明和组间距。普通说明使用 caption 并完整换行，类型、计数和图表短标注不一起放大。

采样新增按钮使用既有全宽平面样式；列表行沿用中性圆角、32 点最小高度，左侧 18 点色块与编号、RGB 读数并列，右侧管理菜单保留重新取样和移除。原生源绑定、九点上限、版本间持久化、画面外占位及非配方标注语义不变。原型读取本地 JPEG 的显示 RGB 并演示相同操作，不作为 RAW 或裁切映射证据。

浏览器走查使用内置浏览器及[可重复检查](inspector-prototype-check.js)：7／12 点的细节分组、白平衡标签到菜单、9 点满额后替换、删除后恢复新增、取消、离线空心色块及配方不变均通过；另实际点击新增和重新取样、按 Escape 取消，在浅色 390×844 布局检查无横向溢出。最初 checkbox 继承全局上下 8 点 margin，把说明间隔叠成 15 点，已在检查器内清除并保留 7 点断言。原型保存一份已加载、同来源的样片，仅用于组件重绘时保持读数稳定；不混用其他照片。第一次等待 Image.decode 的内置浏览器调用超时，已关闭该任务页，改用同步走查重新执行。浏览器元素截图报 Page.captureScreenshot 超时，未保存或宣称该截图成功；版式证据采用这些测量与复现步骤。原完整 agent-browser 脚本未在本轮执行。

原生独立宿主使用增强辅助功能树验证 4／7／12 点布局、210 点窄窗说明完整换行及浅深色外观；采样测试验证新增按钮高 26 点、三行各高 32 点且与按钮同宽、管理入口保留、满额仅禁用新增、替换和删除后恢复新增。色块按实际采样 RGB 对照宿主位图；位图带 Display P3 profile，比较前将期望 sRGB 转入位图色彩空间，保留每分量 0.025 容差及三个色块合计超过 600 平方点的匹配面积断言。真实源绑定用例仍使用原后端和公开取样入口，验证九点上限、替换、几何映射、重新打开持久化及配方／撤销历史不变；源准入改为单调、有界 20 秒等待并输出真实状态诊断，不替换后端或制造上下文。

证据为测试 `NSWindow`／`NSHostingView` 的真实渲染：[采样列表深色](evidence/samplers-native-dark.png)、[浅色](evidence/samplers-native-light.png)、[文字节奏深色](evidence/text-rhythm-native-dark.png)、[浅色](evidence/text-rhythm-native-light.png)。这些截图不作为 RAW 像素质量、GPU 性能或已安装应用的证明。尚未人工完成 VoiceOver 验收；编译仍有既有辅助功能 API、CFlashRaw header 和部分离屏 FocusState 警告。本轮未执行 Release 分发包构建或应用目录安装。

最终选中原生回归于 2026-11-26 14:24 完成：26 项、0 失败，包含完整工作台、文字／采样布局、真实采样持久化、光学、镜头模糊与精修、蒙版、白平衡预设、曲线通道复位和分级交互。工作台中真实测得白平衡标题到菜单 7 点、已应用说明到微调标题 16 点；采样新增与列表同宽、行高 32 点，切换面板、进入并完成裁切、翻片以及回资料库保留上下文的原有断言均保留并通过。使用私有 scratch `output/release-main.QkLYOoSe/build`、`CARGO_NET_OFFLINE=true`、`--jobs 3` 执行 Debug `swift test`，不是完整仓库测试或 Release 验收。见[最终回归日志](evidence/inspector-text-regression.log)及[切回基础后的测量现场](evidence/text-samplers-native-after-switch.png)。工作台现场图处于测试帧／过渡状态，主要用于定位控件，不作为完整照片呈现质量证据。

此前 26 项中有一个工作台用例失败；[诊断日志](evidence/inspector-text-ax-failure.log)保留了 131 个辅助功能节点、有效编辑上下文及实际标识。截图中两个标题可见，日志确认微调父分组的标识传播到标题和说明，覆盖了标题标识。最终将标题／已应用状态明确作为独立元素，将微调组明确作为容器，隔离标识；没有删除、跳过或放宽 7／16 点断言。测试在暂停时沿用已有公开 `beginDevelopmentInterface()` 入口恢复工具，并注册异步会话清理。此前失败中出现的 `InvalidTransition … failed(deinit)` 一并保留，不计作独立失败用例；最终回归未出现该错误。

### 无聚焦边框与滤镜标题区

入口为[工作台 → 编辑 → 基础](../../docs/ui/prototype/index.html#edit/basic)。左栏标题区采用与右栏相同的 32 点标题、独立复位、圆形启停、保存当前设置的 `+` 及末端平面 `…`。搜索与强度仍在标题下。普通说明用 caption 完整换行，控件、说明和独立功能块沿用 4／7／12 点间距；短版本、来源和计数保留微型字号。

原型走查使用河谷的 DJI_0348.DNG、Portra 400／Portra Endura 和强度 52：点击滑块不跳值，方向键步进，Tab 到数字输入，Enter 精确提交；点击滑块及数字时均实测 focused=true、outline=none、box-shadow=none。启停保留选择与强度，折叠后操作标题启停不展开；复位后撤销恢复选择、52 强度及启停状态。`+` 只打开保存；`…` 的模拟导入／导出各只提供自己的操作，取消或 Escape 返回原照片。菜单执行前关闭并以省略号作为返回焦点，避免取消后误把下次点击当作收起菜单。离线 DSC_0713.JPG 经正常编辑入口显示「原片待找回」，取消返回资料库原选片，不制造可编辑源。

浅色 1280×900 和深色 1024×768 已走查：[浅色滑块聚焦](evidence/filter-header/prototype-light-1280.png)、[深色数字聚焦](evidence/filter-header/prototype-dark-1024.png)。收窄复核发现自动网格列的最小内容宽度导致侧栏水平滚动，已使用 minmax(0, 1fr) 和可收缩的搜索区修正；1024 宽下左栏 clientWidth 与 scrollWidth 同为 234，scrollLeft=0，参数行宽 203.5。普通说明 margin=0、字号 12px，保留 7px 的容器间隔。`node --check` 的 editor.js、photos.js、ui.js 通过。仓库完整浏览器检查未启动：scripts/check-ui-prototype.py 因缺少 agent-browser 退出；这些记录来自实际内置浏览器操作，不冒称该脚本通过。

原生禁用 NSSlider／NSCell 与内嵌 NSTextField／NSCell 的 focusRingType，保留 first responder、刻度、鼠标相对拖动、辅助功能动作及原字段编辑所有权。滤镜标题由目录自身持有，折叠保留检索和条目状态，但撤销候选准备与所有非快照临时预览。合并菜单仍由 PresetExchangeControls 持有导入预检、批次撤销、XMP 查看／原始与投影导出和取消状态，个人条目的管理命令接入同一菜单；没有重写原有文件或权限流程。基础／胶片启停保留配方，复位不清除光效等其他组。

最终原生选中回归于 2026-11-26 16:47 完成：121 项，120 通过、1 项原有 WindowServer 准入跳过、0 失败，见[最终 Release 回归](evidence/filter-header/native-regression-final.log)。使用私有 scratch output/release-main.QkLYOoSe/build、CARGO_NET_OFFLINE=true、--jobs 3；最终代码先按 Release 编译，再对同一已编译版本 --skip-build 重跑。包括完整工作台、原字段 Tab／Backtab／Return／失焦与来源撤销、滑块相对拖动、颜色采样、滤镜保存／重开、候选取消和晚结果隔离。不是完整仓库测试。

新增宿主用例在浅深色下断言 NSSlider／NSCell 和数字 NSTextField／NSCell 的 focusRingType=none；真实点击只聚焦、不跳数，方向键及 AX 步进仍有效，非法 101 的 Return 保留编辑器、文本、选区和 Undo 所有权，合法 13.25 不被整数显示截断，Escape 不提交。见[滑块深色聚焦](evidence/filter-header/slider-focus-native-dark.png)、[浅色聚焦](evidence/filter-header/slider-focus-native-light.png)、[数字编辑深色](evidence/filter-header/number-focus-native-dark.png)、[浅色](evidence/filter-header/number-focus-native-light.png)。数字图保留此前非法提交的红色提示；这是原有校验反馈，不是蓝色聚焦边框。

标题用例使用隔离目录与带滤镜能力的既有测试后端，核对五个入口水平顺序、垂直中心、至少 26 点操作区域、原片时启停／复位禁用、唯一保存入口和唯一菜单。真实按标题启停、折叠、复位、Undo 及取消保存，验证滤镜选择／52 强度、非零曝光 0.375、其他参数、历史及目录没有被错误覆盖。见[标题区最终通过](evidence/filter-header/native-header-final.log)和[深色宿主](evidence/filter-header/native-header-dark.png)、[浅色宿主](evidence/filter-header/native-header-light.png)。这些位图来自测试宿主，部分层与文字处于缓存／过渡状态；布局与动作以 AX 测量和状态断言为准，不作为已安装应用、RAW 像素或整体色彩质量证据。

[首次回归](evidence/filter-header/native-regression-first.log)保留折叠后 fixture-light 临时预览未结束的实际失败，修复没有删除或放宽该断言。新测试还纠正了默认夹具未开启滤镜能力及 Optional.none 与 NSFocusRingType.none 的枚举比较。菜单的[尺寸诊断](evidence/filter-header/native-menu-size-failure.log)确认 macOS 只为图标标签提供 20×14 的区域；最终在菜单控件本身指定 26×28 的 frame 与 contentShape，并使用共享平面标签，原 26 点强断言通过。

未人工完成 VoiceOver，也未在本轮重新执行真实文件导入／导出及应用目录安装。仅做 Release 测试构建，不生成或安装新的分发包。浏览器最后一次补拍因 Page.captureScreenshot 超时未更新，保留已有布局／焦点截图和测量；任务标签页与本机 HTTP 服务已关闭。编译仍有既有 CFlashRaw、actor／deprecated API 和离屏 FocusState 警告，不声称零警告。
