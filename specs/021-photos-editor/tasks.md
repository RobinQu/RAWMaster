# 021 · 实施追踪

当前：主体功能与多个隔离场景已验证，性能与最终集成验收进行中。研究预览21.19已封存，canonical默认/无QAflag；生产20.0未升级、不是正式发布；各批次测试重叠不混加。

- [x] Photos完整13组/Filters/Crop与统一六设置设计；344pt布局、源码owner、验证合同。
- [x] typed V3/source facts/原子命令/旧配方兼容/source-branch-epoch/唯一Controller。
- [x] 13组主体、九滤镜/原片、完整手动裁切/投影、真实已有Auto/picker和高级参数接线。
- [x] 修饰/手动与整图红眼、源坐标/删除/复位、候选保存重开；原片与手动采用分离。
- [x] 有界Undo/Redo、字段文本Undo优先、analysis-only真join；Summary强度随历史恢复。
- [x] 真实摘要/滤镜胶片和可访问Retry；21.14强度标签、RAW三组实际ready。
- [x] 六页应用设置、全局一键runtime/进度/取消恢复/用户条款/Keychain，关闭照片不取消全局准备。
- [x] 60.2MP不透明TIFF16源精度0LSB；固定自然图十滤镜限定质量通过。
- [x] 旧204基线324无重叠PASS；冷context53PASS/1skip重叠定点单列；新frontend78/Auto89/common92分阶段记。
- [x] B7双源50组实际配方解析/冻结与直接ledger0（仅元数据，不是50像素通过）。
- [x] 冻结9e饱和度后端A/B各22质量通过，B22严格字节一致；四生命周期真join/final owned0。
- [x] 前端small A/B各9输出质量、B冷取消1输出限定通过；QA21.15实际RAW饱和度/七次Undo恢复/正常退出。
- [x] Auto typed/session/UI/analysis-only join与v1.1 ±3roll证据实现；研究按钮标“自动（实验）”。
- [x] 原PNG不支持导入失败现场保留；固定两图转TIFF，独立RGBA/alpha/ICC/up0LSB，public existing-project恢复，32表旧行不变。
- [ ] Photos原20病例15PASS/5FAIL的5项失败与未覆盖设置收口，不用源保真替外部效果匹配。
- [ ] common v2/v2.1整体OFF：v2.1 A8/8PASS，B第3grain fallback严格p99 2/max5 FAIL、前2ColorPASS；其余B未比较，不再缩域/改门。
- [ ] Auto自然双向门仍FAIL：−5 candidate、+5 positive noHorizon；只允许条件原生episode，不能改称negative或全通过。
- [x] 21.19条件原生：−5 Auto→UndoRedo→保存F429候选→重开继续→GUI16bitTIFF2212×1272，未采用；+5 noResult，work/version/export精确不变、无配方写入。
- [x] 固定3.2MP/8bit-origin源+保存配方strict重放：2813664像素/通道storedRGBA16 max[0,0,0,0]，6964 fractional alpha同、文件同72cdd；GUI archivedPNG16→TIFF为不同链，不覆盖其他PNG32LSB/自然门。
- [ ] B7五十组独立像素/组合质量和内存资格；formal defaultOFF维持。
- [x] Core/AI fixture修后实际321PASS/5skip/0FAIL；final focused73PASS/0skip，重叠22例不相加，旧320+1FAIL记录保留。
- [ ] 同图同画布Photos/ACR 20warm+3cold原生对照；首次/穿零/settled阻塞与AppKit/WindowServer分开。
- [ ] 多场景3GiB目标、GUI完整进程/未知CI-private与更广压力组合；限定4GiB通过不能覆盖旧失败。
- [x] 研究预览21.19 signed28a7c336…/producer1fb27dc2…，实际原生正常关闭owned0，生产/个人库不动；ZIP691422925B/ef7cdf06…已682项CRC通过，含offline runtime无模型，仅本机研究配置非通用release。
- [ ] 性能与一致性未完成，不能把研究预览交付当正式安装或所有用户目标完成。

旧A约60×仅历史18暖API数据；新21.15选定两暖draw-return约197/186ms，首次563ms、穿零后969ms，不能称全面UI60×或更快。新A峰4.279GB/3GiB失败、旧B两次4GiB失败保留。21.19小图3.2MP canonical interactive163.6ms/settle-trigger后109.6ms仅AppKit返回，不是大RAW、WindowServer或跨app优势。所有结果见validation.md与本地delivery.html，不宣布任务完成。
