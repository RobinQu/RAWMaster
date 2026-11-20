# 020 · 验证记录

## 当前已验收状态（2026-10-31）

- Core v2、旧版本编码/指纹保持、共享颜色引擎及82项UI定点测试已通过独立审查。
- 原始照片控制63组/117区域冻结；F32 WHOLE缓存Release63组严格RGBA/Alpha/ICC与本机4GiB资格全部通过，逐通道p99最高0、最大[2,1,1,0]。最高3400.94MiB；原3GiB目标51项失败，未回填为通过。
- 第一轮真实公开API六组：各20warm，tone median/p95 691.83/733.14→176.18/189.52ms，curve 683.66/705.69→178.73/184.92ms，grading 695.74/714.87→174.10/182.19ms。126实际帧严格通过；缓存1fill20hit，各组关闭owned0。API返回不代表AppKit屏幕呈现，不宣称CameraRaw优势。
- 前一冻结源码完整Release回归778实际通过、43optin跳过、0失败。真实Controller三照片/保存/导出/复开与pre-cache原生交互通过；Release深色/窄窗口静态验收通过。
- A1 resident descriptor快命中与capturefault闭环已通过56项定点、重新63/117严格资格与六组性能复测：tone median/p95 667.97/757.82→121.65/141.31ms，curve705.95/761.10→129.84/144.43ms，grading680.67/780.37→127.88/147.50ms；126帧严格通过。默认缓存仍0，最终新源码资格、dual/native/300快速输入、应用默认启用、个人库/完整support/prefs/旧19.2备份已完成，安装待最终工作流验收。

详见 `output/validation/020-development-controls/delivery.html` 与各原始receipt；后续不覆盖历史失败。

## 历史过程记录（下列“尚未”均指当时检查点）

2026-10-31，M4Max128GiB/macOS27.0.1。019.2冻结预编译测试skip-build运行1项真实60.2MP/同2400benchmark通过；20warm中位258.921146ms、nearest-rankp95270.192459ms，coldopen+first811.984416ms。21canonical对照p99通道误差0、最大≤1。API时间不包含UI/draw/呈现，冷样本不是OScachepurge。证据output/validation/020-development-controls/baseline-019/。

旧Core.o直接执行Swiftprobe冻结5份sorted/withoutEscapingSlashes实际encoder字节和EditingFingerprint：neutral/非中性v1配方、EditingVersion、AIEditRequest、ArchivePublicationReceipt。包含source/object/probeSHA，不由新实现产生expected。appendVersion command使用同fullVersion fingerprint，已被覆盖。

现有六类照片RAW均在线并匹配历史samplemanifestSHA（含portrait/skin、白鸟、逆光景观、DNG）。全部只读；性能仍用固定DSC05994，不将低清JPEG/其他机型速度冒充60MP。

实现、缓存质量、原生窗口与安装尚未验收。

Core focused检查点：36项通过；五旧encoder golden逐字节/fingerprint保持。首次测试literal语法编译失败已修复，失败与成功日志均保留；不把未编译当执行通过。尚待独立Core复核和Imaging/UI验证。

App阶段A focused79/79通过（新11+既有68），主应用与全部测试可编译。修复0尺寸曲线过渡绘制异常、色轮颜色空间警告，日志ui-phase-a-{tests,retry-tests,fixed-tests}.log保留。新020隔离三照片fixture只编译未执行。实际GPU、真实RAW像素与原生窗口仍待后续验收。

Canonical阶段：Core38、6GPU合成+3fileintegration+19strict+14progress=42联合通过，强化9项重复运行不累加为新测试。Oracle核验11源/测试exactsnapshot与finite/最小点距修复后批准35case真实参考生成；尚无cache授权。

UI数值格式P2与小bounds焦点mask修复后82/82通过（ui-numeric-fix-tests.log），不将旧79PASS当新修验证。实际窗口/真实照片fixture仍待运行。

真实canonical reference attempt1按内存门失败并停止：首5994neutral(旧v1绕行，非新增颜色/缓存)RGBA8阶段周期3637.99MiB>3072门；afterframe2368MiB、clear+2s48MiB，不能用后者遮峰。completedReferences0，partialPNG/rgba8与receipt保留。当前不得声称真实照片参考已冻结、缓存通过或提速达标，需资源归因修正后独立复核。

资源归因A/B/C/F：A原始中性控制重现3638.81MiB，B生产Gneutral1741.50MiB过门（RGBp990/max1）；C只target512首张1721但old15时3217.16MiB失败。F1逐次fresh512完成old21资源1949.50MiB过门、known5PNG过门；F2前5FIT最高3054.56MiB，第6native0粗readback峰5800.08MiB失败，7未跑/QC0。未改生产，不将局部FIT/内存PASS冒充整条颜色/native流程达标。


## 020 最终交付记录（2026-10-31）

20.0 已安装至 `/Applications/RAWMaster.app` 并在原个人资料库打开项目内初修。基础影调、RGB/独立通道曲线及 Color Grading 已交付；导入初筛与全局资料库不提供初修。完整 MAIN Release 809 实际通过、49 opt-in 跳过、0 失败；63 配方/117 区域质量、双源生命周期、300 输入、native 七步、真实窗口保存与重启均通过独立复核。

同图连续调色公开 API 中位 122–130ms，匹配未缓存版本约 5.4 倍提升；实际原生低频 CUA 输入至 AppKit draw-return：短拖最终帧 321/402ms（中位/p95），曲线 232/272ms，色轮 228/270ms，各20不同值。包含观察开销，不是 WindowServer、20Hz UI 压测或 ACR 比较；66/100/250ms目标和快于ACR仍未达或未证实。曝光/白平衡变更及跨照片仍有RAW重处理/缓存填充成本，不能外推暖态颜色收益。后续性能工作需分解事件提交、渲染与绘制交接，并建立匹配的Adobe实测基线。

本机精确profile已显式启用；独立最终Preview真实shared填充3/复用70，两次退出资源计数全0。正常App未开trace，不能冒称再次测了相同fill/hit。升级前完整support约3.60GB、SQLite一致性快照、偏好、19.2应用备份在 `~/Library/Application Support/RAWMaster Backups/before-020-20261031-151600`；旧包两份保留。升级后实际PID/lsof确认原库，全部32表内容哈希及行数与备份相同，schema7/integrityok，EV .25候选保留，除两个profile偏好其它配置未变。

最终报告及证据：`output/validation/020-development-controls/delivery.html`、`installation.json`、`native-final/appkit-latency.json`、`application-cache-profile/source-phase-manifest.json`。所有原失败、探针限制和恢复记录保留，不重写为通过。
