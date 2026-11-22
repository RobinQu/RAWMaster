# 026 · 任务与当前状态

- [x] T01 建立独立 Swift Package、原生 ONNX Runtime 和固定模型目录。
- [x] T02 实现 MaskImage、NativeImage、ONNXTensor 和 ONNXSession。
- [x] T03 实现 Subject／Background 与 IS-Net。
- [x] T04 实现八类 Landscape、ADE20K 映射和场景缓存；Snow 标记为兼容实验。
- [x] T05 实现 SlimSAM 点／框／负点、候选选择和 encoder 缓存。
- [x] T06 实现人物检测、整人、部位分割和五官几何。
- [x] T07 建立公开 fixture、来源哈希、CLI 和离线单元测试。
- [x] T08 逐模型 inspect 与真实图像集成验证。
- [x] T09 检查输出蒙版、缓存次数、空结果和失败边界。
- [x] T10 形成验证报告与是否合并／合并范围的决策建议。

最终证据：13 项测试、0 失败；28 条真实模型输出；详见 `validation.md`。结论仅限本轮样本与执行范围，未合并到 RAWMaster。
