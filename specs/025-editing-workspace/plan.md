# 025 · 技术实现与约束计划

## 当前架构

### Core：配方与事务

- `DevelopmentAdjustmentsV3` 聚合全局调整、几何、局部编辑、效果和蒙版；新增字段采用缺省兼容解码。
- `DevelopmentLightV3.whites` 为可选持久化语义的默认零值扩展，固定 Brilliance 旧版本拒绝新增非零 White，避免重解释旧配方。
- `DevelopmentMaskModelsV3` 定义最多 32 层、参数范围、唯一 ID 和 AI PNG 上限；`setMasks` 与既有命令共用原子配方事务。
- `DevelopmentLocalEdit.retouchMode` 缺省为 Heal；Clone 只增加新语义，不重命名旧操作。
- `LibraryStore+Editing` 保存实时配方；控制器负责历史、退出落库与当前上下文校验。

### Imaging：真实像素管线

- FlashRaw Metal 只负责受支持 RAW 的中性线性输入；经桥接进入既有 RGBA32F 代理，曝光／白平衡／降噪修改共享基图。
- `PreviewInteractiveProxyV3` 执行交互后缀，显式物化共享后缀并接入蒙版；`PreviewNativePointwiseV1` 仅覆盖限定快速路径。
- `DevelopmentColorEngineV3` 执行 White 与既有点运算；`DevelopmentLocalEngineV3` 分别执行纹理转移和 Clone。
- `DevelopmentMaskEngineV3` 按图层顺序执行线性、径向、范围和主体蒙版；非主体使用 1×1 占位采样源，避免完整 RAW 被重复声明为第二输入。
- `DevelopmentSubjectMaskGeneratorV1` 使用 `VNGenerateForegroundInstanceMaskRequest`，将结果限制到 512 长边并保存 PNG；回放不重新推理。
- `DevelopmentDisplayHistogramEngineV1` 在同一次 128 代理循环中生成 RGB 与亮度档位，不增加额外 RAW 解码。
- `PhotoBatchRenderExporter` 先渲染当前版本／实时配方，再按长边与质量编码；输出有独立暂存、源目录保护和禁止覆盖检查。

### App 与原生交互

- `EditingWorkspace` 负责全幅暗房与悬浮面板；`EditingController` 拥有编辑状态、历史、暗房偏好、局部与蒙版输入。
- `PhotosDevelopmentInspector` 使用固定类目列；`PhotosHistogramView` 按 0–10／10–30／30–70／70–90／90–100% 映射拖拽并复用单次手势历史。
- `PhotosMaskControls` 管理图层；`EditingMaskInputSession` 将画布坐标通过既有几何映射转换为源坐标。
- `WorkflowTabs` 统一资料库／编辑／导出状态；`ExportWorkspace` 保留进入前的显式多选，不再以模态框承载主导出流程。

## 数据流

```text
RAW → FlashRaw 中性输入 → 线性交互代理 → 全局／细节／蒙版后缀 → 原生画布
  ↘ Core Image canonical → settled／保存／导出 ↙

Vision（仅新建主体蒙版）→ PNG 配方数据 → 确定性渲染／历史／导出
显式选择 → 导出上下文冻结 → 逐张当前配方 → 暂存 → 唯一目标文件
```

## 性能与验收门

1. 全量 Debug 零失败，条件跳过逐项保留；最终为 1,594 项、67 跳过、0 失败。
2. 使用同一真实 RAW、Release、2400 × 1600 代理和 AppKit 画布执行 36 个交互样本；当前中位数 26.132 ms，既定门禁通过。
3. 保留冷启动、canonical 和源文件前后哈希；不把中位数当作全部体验，也不把跨应用不同边界换算成排名。
4. 原生窗口必须验证实际拖拽、图层恢复、工作流往返和退出；不能仅凭视图存在宣称功能通过。
5. 新增整帧依赖或蒙版阶段必须重新检查内存；已知 980 MB 瓦片问题不得回归。

## 后续实施顺序

1. 先补 AI 正向样本与蒙版交互／性能覆盖，再处理跨应用同口径性能。
2. 优先降低数秒级 canonical 与冷启动，但不能用近似帧替代最终输出。
3. 扩展相机、HDR、超色域和复杂组合配方资格。
4. 只有在实测显示新收益时，才重开 JPEG 代理或其他缓存层评估。
5. 画框、签名与发布配置作为新规格另行定义，不在 025 中追加未验收控件。
