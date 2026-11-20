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
