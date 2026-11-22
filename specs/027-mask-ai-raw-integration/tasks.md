# 027 · 任务状态

2026-11-22 接续。T08–T10 的生产工作与 030 T005/T006/T010/T011 共用一套快照、源坐标和分类验收。031 的语义预设读取这套服务。跨团队依赖与使用同一批样片的安排见[联合研发计划](../../docs/planning/24-mask-preset-retouch-roadmap.md)。

- [x] T01 定位并复制三份真实 Sony RAW，记录内容哈希。
- [x] T02 实现独立 CIRAWFilter 显影、方向与源元数据。
- [x] T03 实现局部曝光合成和选区／非选区像素指标。
- [x] T04 验证天空、风景、水鸟主体、背景、点／框物体和无人负样本。
- [x] T05 修复原生裁切整数像素与 top-left／bottom-left 坐标契约。
- [x] T06 输出 RAW 原图／蒙版／成片、结构化结果和对照图。
- [x] T07 形成 RAWMaster 集成架构、资源约束和分阶段方案。
- [x] T08 取得并验证原生人像、明暗雪景与无雪负例四张 RAW，补齐 People 正向和 Snow 负／正样本，修复竖拍方向与原尺寸裁切。阴影雪地漏选，雪类别仍留实验。[逐项证据](portrait-snow-validation.md)
- [x] T09 候选、手修、采用与快照回放已接入基础编辑交付版。两张真实 RAW 在正式编辑器完成冷建、30 次精确命中、背景切换和重开。[联合验收](../031-preset-browser/integration-validation.md)
- [x] T10 跨照片预设重新准备语义，旧回调不能在切换后采用。同一候选的历史与取消回归、编辑器关闭前后的常驻内存、冻结蒙版的原尺寸 TIFF16 输出、保护区逐通道差和导出峰值均已归档。[功能回归](../031-preset-browser/evidence/camera-raw-integration/functional.json) · [联合验收](../031-preset-browser/integration-validation.md)
- [x] T11 实现语义描述、不可变快照、异步协调、原生取消、取消回滚和资源释放。
- [x] T12 完成真实 RAW 性能门槛、快照冷热隔离与内存验收。
- [x] T13 同时启用全部模型／RAW／服务／性能测试，27 项通过、0 失败；详见 `service-validation.md`。
