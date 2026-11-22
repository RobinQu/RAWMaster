# 026 · 技术计划

## 独立架构

```text
mask-ai-probe / XCTest
        ↓
MaskAIClient
  ├─ SubjectMasker → IS-Net → Subject / Background
  ├─ SceneMasker → EfficientViT ADE20K → cached softmax → 8 landscape targets
  ├─ ObjectMasker → cached SlimSAM encoder → prompt decoder → 3 candidates
  └─ PeopleMasker
       ├─ D-FINE person boxes → SlimSAM entire person
       ├─ Selfie Multiclass → hair / skin / clothes
       └─ YuNet → 478 face landmarks → eye / brow / lip / teeth geometry
        ↓
MaskImage（Gray8、top-left、source analysis size）
        ↓
PNG + coverage + selected pixels + elapsed + model IDs + notes
```

## 模块边界

- `CONNXRuntime`：仅暴露官方 C API 头文件和动态库链接。
- `MaskAI`：原生图像、张量、模型、算法与统一蒙版输出；不依赖 RAWMaster。
- `mask-ai-probe`：独立 CLI，用于 inspect 和单项能力验证。
- `MaskAITests`：默认离线测试与显式启用的真实模型测试。

## 数据与坐标契约

1. `NativeImage` 在读取时应用 EXIF 方向，并限制验证分析长边；模型输入使用其 RGBA8 像素。
2. 所有 prompt 和检测框使用 top-left 归一化坐标。
3. IS-Net 固定拉伸到 1024²；EfficientViT 短边 512、长边向 32 对齐；SlimSAM 长边 1024 并补齐到 1024²。
4. 模型输出经明确的 sigmoid／softmax、尺度还原和 Gray8 量化，不直接保存未解释 logits。
5. 缓存以完整 RGBA 内容的 SHA-256 为身份；相同内容复用，不同内容不得复用。
6. Q8 SlimSAM 点使用 rank 4 坐标／rank 3 标签；矩形框在实测补偿策略下加入中心正点，并保留原始框角标签 2／3。

## 验证顺序

1. 编译、动态库 API 和离线几何／组合测试。
2. 逐模型 `inspect`，确认输入／输出名称，再执行真实样本。
3. Subject／Background、Landscape、Objects、People 分组运行，保留全部结果。
4. 检查 PNG、目标覆盖和缓存次数，记录失败而不是隐藏失败。
5. 形成 `validation.md` 和合并建议；未通过项不得进入合并范围。
