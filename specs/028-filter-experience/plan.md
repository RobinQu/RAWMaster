# 028 · 实施计划

2026-11-22 更新。本计划记录固定滤镜的 A–E 阶段。新左栏的目录、原生保存和限定 XMP 迁移由 031 排期。两者共用 AppKit 主图呈现与键盘验收，十候选吞吐只在旧调用路径复测。[预设实施计划](../031-preset-browser/plan.md) · [三模块研发计划](../../docs/planning/24-mask-preset-retouch-roadmap.md)

## 实施原则

1. 先修真实 RAW 的 193 px 正确性缺陷，再讨论缩略图吞吐；失败集合没有合格性能基线。
2. 主图接入现有代理，不新建第二条 RAW 显影链；保留单次 suffix 物化和 `PreviewInteractiveProxyV3.validate`。
3. 像素内容键与交付键分离，但不放松 sourceAuthority、实际候选配方和资源版本验证。
4. settled hook 从正确性前置条件降为可选优化；canonical settled/save/export 不变。
5. 每阶段独立可回退，不同时引入 F16、3D texture、Metal atlas 和新 presenter。
6. 保留当前工作区其他未提交修改，不做格式化全文件、批量重写或无关重构。

## 阶段 A · 真实 RAW 布局正确性

### 代码

- 在 `PreviewInteractiveProxyV3.swift` 增加内部统一的近整数像素尺寸计算。
- 将 `geometry`、`inputLayout` 及共享的代理输出布局调用迁移到该函数；`PreviewNativePointwiseV1.layout` 如仍独立计算相同公式，也复用同一实现。
- 不修改 `DevelopmentGeometryEngineV3` 的 canonical 映射；只在显示代理像素网格取整层修复。

建议语义：

```swift
let value = Double(nativeDimension) * scale
let nearest = value.rounded()
let dimension = abs(value - nearest) <= 1e-9 ? nearest : ceil(value)
```

最终仍需验证输出不超过请求 target，且 transform 与实际 canvas 一致。不能直接把 193 裁成 192，因为那会掩盖 layout 与 transform 不一致。

### 测试

- `DevelopmentThumbnailCompactTests` 增加 9504 × 6336、target=192，断言宽度 192。
- 增加 9505、128/192/256/2400、横竖拍和普通非整数案例。
- `FilterPerformanceValidationTests.testOptInDirectRealRAWFilterThumbnailsWithoutSettledGate` 从第 0 张失败变为十张全部成功。

## 阶段 B · 主图滤镜代理

### 代码

- `PreviewInteractiveProxyV3.support` 不再仅因有效 filter 返回 canonical；其他不支持原因保持原优先级。
- `PreviewInteractiveProxyV3.suffix` 在 `DevelopmentGlobalEngineV3.apply` 后立即调用 Photo Filter，再进入 advanced detail 和 mask。
- 给 suffix 增加可选的 `photoFilterResourceLease` 回调。主图不传，缩略图传入现有记账闭包。
- `DevelopmentThumbnailEngine.withSuffix` 删除 suffix 后的第二次 Photo Filter 调用，但保留 LUT 预算预留在 `held` 生命周期，并把资源租约传给 suffix。
- 保留代理输入的 transport alpha；不放宽 `rmPhotoFilterV1` 对非法 alpha/NaN 的拒绝。

### 测试

- 将 `testWholeRecipeFilterFallbackIsChargedCanonicalAndReportsClosedReason` 改为支持域代理断言，保留非支持域 fallback 测试。
- 九个 look、节点/非节点强度、滤镜 + advanced/mask 的阶段顺序和像素对拍。
- 主图与缩略图不得双重应用 filter。
- 真实 RAW alpha 1+ULP、NaN 注入、HDR residual 和低 alpha bypass。
- 运行受控性能 probe，再扩展 `EditingInteractionPerformanceTests` 增加 filter look/intensity case。

## 阶段 C · 缩略图内容键与独立冷代理

### Service

调整 `DevelopmentPreviewService.swift`：

- `thumbnails(_:)` 只要求 sourceAuthority 和请求仍为当前，不再要求 `thumbnailIsSettled || matchingSettledFlight`。
- `startThumbnailStep` 用当前请求校验替代 settled guard；无匹配 hook 时走既有 `prepareThumbnailProxy` 冷路径。
- `makeThumbnailSettledHook` 保留，在 revision、recipe 和 source 完全匹配时复用主图 native image。
- adopt 时验证内容键、实际请求和当前交付身份，不再把“主图已 settled”当作冷代理结果是否正确的条件。
- 代理退休采用短 grace period 或内容键 LRU；revision 变化不直接释放同内容代理。

### UI

调整 `EditingThumbnailPresentation.swift`、`EditingController.swift`、`EditingPreviewCoordinator.swift`：

- 移除缩略图请求对 `thumbnailCanonicalWitness` 的强制依赖。
- `cacheKey` 改用 `FilterCandidateSetContentKeyV1`；通过十份实际候选配方计算集合指纹。
- `recipeChanged` 先比较内容键：相同则保留 sets 和在途内容；不同则进入 refreshing，保留 last-known-good。
- `mayAttempt` 不再以 witness 变化决定唯一一次自动重试。
- 瞬态错误由明确事件与退避驱动；`unsupportedGraph`、`invalidEncoding` 和资源错误使用不同终态。

### 测试

- 无 settled 主图、同配方新 revision、focus restoration、面板重进。
- filter-only 内容键命中；滤镜命令导致 preparedDehaze 派生变化时必须 miss。
- 快速连续调整无空白，晚到结果不能覆盖新内容。
- 内存压力、取消、close 和 repeated release 全部 join。

## 阶段 D · LUT 与候选任务成本

### 最小实施

- 删除 `DevelopmentThumbnailEngine.withSuffix` 每个 active tile 后的 `DevelopmentPhotoFilterResourceStore.shared.trimReady()`。
- 继续使用 `DevelopmentPhotoFilterResourceStore` 内部 readyTarget/LRU 和全局 32 MiB charge；内存压力与 close 的显式 trim 保留。
- 每个 tile/帧使用独立 autoreleasepool，确保旧 CI graph 不把 retiring LUT 留到下一批。
- 固定十项目前均属于可见集，保留 Original 首位的固定生产顺序；若后续候选增多或出现分页，再实施选中/可见优先。Service 保持有界单 worker。

### 后置条件

只有真实数据表明整组候选仍超过 p95 250 ms，才实施单 worker 批任务或 GPU atlas。只有 LUT 本体成为主图瓶颈，才另开 `texture3d`/F16 实验。不得用这些后续项阻塞 M0 的正确性和路由收益。

## 阶段 E · M1 Hover 与收藏

- `PhotosThumbnailViews.swift` 增加 hover/focus 意图、收藏区和键盘操作。
- `EditingController.swift` 管理 `FilterHoverSessionV1`；committed recipe 不变，点击才调用现有 `changeDevelopmentFilter`。
- `EditingPreviewCoordinator.swift` 增加临时滤镜显示请求或复用符合语义的 draft presentation；所有晚到帧校验 hover token 和 base revision。
- 退出 hover 优先重呈现 committed outputKey 的缓存帧，不重新 canonical。
- 收藏使用现有隔离 UserDefaults 存储版本化 JSON；不写照片配方和资料库版本。

## 全量验收

1. 新增 Debug/Release 专项全部通过。
2. `DevelopmentThumbnailTests`、`DevelopmentThumbnailCompactTests`、`PreviewInteractiveProxyTests`、`DevelopmentPhotoFilterEngineV3Tests`、`DevelopmentPhotoFilterCanonicalTests` 无回归。
3. 真实 RAW 主图和缩略图 probe 成功，原始 JSON 与汇总保存到新目录，不覆盖旧证据。
4. `EditingInteractionPerformanceTests` 增加滤镜案例并达到 spec 门禁；计时边界不变。
5. 实际原生窗口完成 hover、点击、强度、连续调整、面板重进、失焦、保存和导出。
6. 完整 Debug/Release 回归与资源 union0；确认无遗留进程和原文件变化。
