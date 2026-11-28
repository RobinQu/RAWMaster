# 028 · 滤镜体验、预览生命周期与交互性能

## 状态与目的

- 状态为 **Validating**。固定滤镜、生命周期、hover 与收藏已实现。canonical、暖缩略图和 Classic Filters 的原生 AppKit 暖态门已通过。物理键盘与 VoiceOver 走查仍待验收。[当前验证](validation.md#11-月-28-日联合构建复验)
- 目的：在保留 canonical 保存、导出和最终质量契约的前提下，让固定滤镜的主图交互接近 LightFlow 的暖路径体验，并消除滤镜缩略图的可复现布局失败、过度失效和重复生成。
- 输入证据：[`docs/research/lightflow-camera-raw-filter-rendering.md`](../../docs/research/lightflow-camera-raw-filter-rendering.md)、本目录 `validation.md`、`FilterPerformanceValidationTests`。
- 规格结构：本文件定义交付契约，`plan.md` 定义实施顺序，`tasks.md` 定义可勾选任务，`validation.md` 定义已验证事实和未验证边界。

**2026-11-22 范围更新。** 028 的十候选网格是固定滤镜的既有交付和回归样本。默认左栏采用 031 的无缩略图预设目录，原片与九个 Delta64 风格可从 Classic Filters 访问。目录复用本规格的主图临时预览、撤销和收藏行为。[031 预设产品规格](../031-preset-browser/spec.md) · [联合研发次序](../../docs/planning/24-mask-preset-retouch-roadmap.md)

## 问题陈述

实施前，有效滤镜被 `PreviewInteractiveProxyV3` 排除并回退完整 canonical 显影。受控 Release 原型在同一 Sony 9504 × 6336 RAW、2400 × 1600 输出、同一 CIContext 和输出纹理下，canonical 中位数为 2040.068 ms；采用单次物化 suffix 与生产交互校验器后，完整滤镜代理中位数为 16.201 ms、p95 为 27.153 ms。T-004–T-006 实施后，直接调用生产 `DevelopmentPreviewService` 的暖滤镜帧中位数为 18.352 ms、p95 为 22.078 ms，canonical fallback 为 0；这仍不是生产 AppKit 画布成绩。

真实 RAW 缩略图还有独立的 P0 正确性缺陷：9504 × 6336 源在 192 px 滤镜目标下，浮点乘积为 `192.00000000000003`，`ceil` 后布局宽度成为 193，随后被最大 192 的布局 guard 拒绝。第 0 张“原片”即失败，错误为 `DevelopmentThumbnailError.invalidEncoding`。因此，生命周期、重试和 LUT 优化本身不足以恢复该样本的预览。

UI 同时把 revision、主图 settled 见证、候选像素内容和展示代次耦合。任意配方变化先取消并撤下旧图，新图必须等待匹配主图 settled 帧，一次自动重试后可能停留在人工重试态。这些行为需要按内容层与交付层拆分，而不是简单增加重试次数。

## 用户场景

1. **连续试滤镜**：用户依次悬停或点击十个候选，主图即时更新；当前已提交配方、历史记录和缩略图内容不因 hover 改变。
2. **调整滤镜强度**：用户连续拖动强度，支持域内不重新解码 RAW、不进入 canonical fallback；滤镜候选网格不因强度本身重建。
3. **边调整边看候选**：用户修改曝光、颜色或曲线，旧候选在新结果生成期间保持可见并标记更新中；新内容按最新请求原子替换，不出现空白闪烁。
4. **真实 RAW 重进面板**：9504 × 6336 Sony RAW 的原片和九个滤镜均能生成；离开并重进面板时，内容键命中可直接复用。
5. **异常恢复**：暂时忙碌、内存压力或晚到结果不会永久停留在“等待当前照片预览完成”；不支持的配方和真实源错误有明确、可诊断的终态。
6. **键盘与辅助功能**：不使用鼠标的用户可以通过焦点、方向键和确认键完成预览与应用，hover 不是唯一入口。

## 功能差距的交付分层

| Camera Raw 相关能力 | 本规格交付决策 | 里程碑 |
| --- | --- | --- |
| 固定创意滤镜、强度、网格候选 | 保留 RAWMaster 九滤镜与原片，修复正确性、性能与生命周期 | M0 |
| 主图悬停预览 | 交付临时预览，不写配方、历史或持久化 | M1 |
| 收藏 | 交付固定滤镜收藏与跨启动持久化，不支持自定义排序 | M1 |
| 可搜索目录、收藏与场景入口 | 031 在左侧提供 Presets / Profiles 两棵树，030 在右侧按摄影场景提供可直接试用的智能预设 | 031 / 030 |
| 用户配方 Preset、子集保存、更新/删除 | 031 交付逐字段补丁、原生格式、Amount 和冻结应用记录 | M2 接续至 031 |
| Camera Matching / Adobe Raw 基础 Profile | 031 逐项报告相机基底依赖，以逐机型和显影路径对照决定可用范围 | M3 分项验证 |
| 外部预设与资源 | 031 交付限定 XMP 迁移、普通子集读写和 Look 依赖报告。DCP、cube 与其余内置资源在迁移白名单之外 | M3 接续至 031 |
| Adaptive 语义、Lens Blur、Adaptive Color/B&W | 语义校正复用 027/030，景深与 RAW Profile 分别验收 | 031 专项 |
| ISO adaptive defaults、推荐预设和作者体系 | 不在本轮范围 | 后续 |

## 里程碑范围

### M0 · 正确性、主图代理和缩略图生命周期

必须完成 FR-001 至 FR-012。只有真实 RAW 原片及九滤镜全部可生成、生产画布性能通过、完整回归无失败后，M0 才可关闭。

### M1 · Hover 与收藏

完成 FR-013 至 FR-016。M1 不改变 M0 的像素键、canonical 输出或滤镜目录格式。

### M2/M3 · 后续独立规格

031 承接目录、原生配方、XMP 子集与限定迁移。静态 Look、语义蒙版、Lens Blur、Adaptive Profile 各自登记依赖和像素验收。旧网格的 FR-007 至 FR-012 继续约束调用该服务的路径。031 目录的条目、收藏、搜索和滚动产生的滤镜缩略图任务数须为零。[031 实施与分工](../031-preset-browser/plan.md)

## 功能需求

| ID | 需求 | 验收摘要 |
| --- | --- | --- |
| FR-001 | 引入统一的代理输出像素尺寸计算；近整数浮点结果先吸附到最近整数，其余情况保持向上取整 | 9504 源 target=192 输出宽度为 192，不是 193；9505 等行为不变 |
| FR-002 | 布局修复应用于共享代理/缩略图布局路径，不用事后裁掉多出的 1 px 掩盖错误 | transform、layout 和实际 canvas 一致；canonical 原生几何不被改写 |
| FR-003 | 有效滤镜在支持域内进入 2400 px 交互代理，不再以 `.filter` 为理由 canonical fallback | 统计中 `interactiveProxyLastFallbackReason == "filter"` 不再出现于支持域 |
| FR-004 | Photo Filter 位于 Global 后、Texture/Clarity/Dehaze/Mask/Local 前；主图和缩略图共享同一阶段实现 | 复合配方阶段顺序对拍；不重复应用 LUT |
| FR-005 | 滤镜输入必须满足现有有限值与 alpha 契约；保留代理的 transport alpha 归一化，不把非法输入静默放行 | 真实 RAW、低 alpha、1+ULP、负值/HDR、NaN 注入测试 |
| FR-006 | settled、保存和导出继续使用 canonical 全尺寸权威渲染 | 交互近似帧不得替代最终成片；既有导出对拍通过 |
| FR-007 | 256 px 缩略图代理可在没有主图 settled 见证时从已验证源独立生成；settled hook 仅作避免重复 RAW 工作的优化 | 真实 RAW 无 settled 帧仍完成原片与九滤镜；冷/热代理逐位对拍 |
| FR-008 | 候选内容键基于十份实际解析后的候选配方，而不是当前 revision 或单独中性化 filter 字段 | 滤镜阶段为唯一差异时重建次数为 0；派生去朦胧等变化正确触发重建 |
| FR-009 | 交付身份与像素内容身份分离；revision 只负责 latest-request-wins，不直接使位图失效 | focus restoration、相同配方新 revision 和面板重进可命中内容缓存 |
| FR-010 | 新内容未就绪时保留 last-known-good 并显示轻量更新状态；新组或已完成块原子替换 | 快速连续调整无空白帧，旧结果不带“当前”标记 |
| FR-011 | `awaitingSource` 和资源暂时不可用采用事件驱动、有界退避；稳定不支持与真实错误采用不同终态 | 无无限重试；无“一次自动失败后只能手动”的常态路径 |
| FR-012 | LUT 与候选任务按帧/候选收束自动释放所有权；跨批使用有界缓存，不在每个 tile 后强制清空 ready LUT | 不超 32 MiB LUT 与 14 MiB 缩略图既有预算；暖路径无重复 payload 读取 |
| FR-013 | Hover 使用独立 transient preview token，不修改 committed recipe、草稿、历史、撤销栈或滤镜候选内容键 | hover 退出恢复当前 committed frame；点击才提交实际命令 |
| FR-014 | Hover 晚到帧不得覆盖新的 committed recipe、另一 hover、原片按住、比较或裁切呈现 | token、sourceGeneration、base revision 和 presentationID 全部校验 |
| FR-015 | 收藏仅保存固定滤镜 ID 集合，按现有稳定顺序展示“收藏”区；不改变照片配方 | 跨启动持久化；损坏/未知 ID 忽略并记录，不影响其他收藏 |
| FR-016 | 键盘焦点可预览，确认键应用，Escape 恢复 committed frame；所有状态具有可访问标签 | 无鼠标完成完整流程；VoiceOver 不播报短暂刷新为错误 |

## 数据与身份契约

### `FilterCandidateSetContentKeyV1`

首版采用保守的同源代次复用，至少包含：

```text
sourceContentID
sourceGeneration                 // V1 保守边界；跨代次复用另行验证
thumbnailNativeInputFingerprint // 解码器、原生 WB/EV/NR、方向和代理版本
candidateRecipeFingerprints[10] // resolveCandidate 后的实际配方，包含派生状态
nativeGeometryMapping           // 输出尺寸与正向矩阵
targetMaximumPixel = 192
filterOrderVersion
thumbnailPipelineVersion
photoFilterCatalogVersion
```

不得包含主图 `frameID`、preview revision、visibleGeneration、presentationID、当前 hover、选中态或 settled frame 的存储身份。`quality` 只有在实际像素生产契约不同的时候才允许进入内容键；V1 的独立冷代理不依赖主图 quality。

### `FilterThumbnailDeliveryKeyV1`

```text
sessionID + sourceGeneration + consumerID + revision + registrationID
```

仅用于请求是否仍为最新、结果是否可交付和资源 join，不用于判断相同像素能否复用。

### `PhotoFilterLUTCacheKeyV1`

```text
deviceRegistryID + catalogVersion + look + intensityPlane + encodingVersion
```

LUT ready/active/retiring 总量继续受 32 MiB 上限约束。M0 不通过提高预算掩盖所有权泄漏；确需调整预算时必须另附峰值证据。

### `FilterHoverSessionV1`

```text
token + committedRecipeFingerprint + basePreviewRevision
+ sourceGeneration + presentationID + look
```

Hover 是显示意图，不是 `DevelopmentRecipe` 的新事实来源。提交点击时才走现有 `DevelopmentAdjustmentCommand`、历史和实时持久化。

### `PhotoFilterFavoritesV1`

```text
schemaVersion = 1
favoriteFilterIDs: Set<DevelopmentPhotoFilterV3>
```

收藏属于用户偏好，不进入照片配方、版本、导出或源内容键。

## 缩略图状态机

```text
idle
  → preparing(sourceAuthority, contentKey)
  → ready(contentKey, displayedSet)
  → refreshing(contentKey', displayedSet = lastKnownGood)
  → ready(contentKey', newSet)

preparing/refreshing
  → retryScheduled(transientError, backoff)
  → unavailable(unsupportedGraph)
  → failed(source/resource/encoding failure)
```

约束：

- `ready → refreshing` 不得先移除 displayedSet。
- 只有 sourceAuthority 不成立时才显示“等待源”；正常主图渲染忙碌不是源失效。
- `retryScheduled` 由源代理就绪、资源恢复或新的显式请求唤醒，不依赖 SwiftUI 高频 refresh。
- 新 revision 可以取消旧交付，但若内容键相同应直接采用已有/在途内容，不重复像素工作。
- 关闭页面、切照片、失焦和内存压力按现有资源安全规则退休；晚到结果不得重新发布。

## 错误语义

| 错误 | 新状态与行为 | 是否自动恢复 |
| --- | --- | --- |
| 主图 settled 尚未到达 | 不再作为独立冷代理错误；直接构建 256 px 代理 | 不适用 |
| sourceInvalidated / staleSource | 停止旧交付，重新验证源；旧内容不得标为当前 | 源恢复后 |
| superseded / cancelled | 静默丢弃旧交付，同内容键可复用 | 最新请求驱动 |
| budgetUnavailable / memory pressure | 保留可显示的 last-known-good，退避并等待资源恢复 | 是，有界 |
| unsupportedGraph | `unavailable`，说明当前组合不支持 | 仅配方变化后重估 |
| invalidEncoding | `failed`，保留布局/阶段诊断，不伪装为等待源 | 仅新内容键或显式重试 |
| catalog/payload fault | 禁止故障资源进入缓存重放；仅显示受支持滤镜 | catalog generation 变化后 |

## 性能与资源验收门

以下为生产交付门，不把原型成绩直接当作通过：

| 场景 | 必过门 | 备注 |
| --- | --- | --- |
| 真实 AppKit 画布暖滤镜切换/强度 | p50 ≤ 20 ms，p95 ≤ 33 ms | programmatic commit → accepted draw return；另记录 GPU completion |
| 物理输入到屏幕 | 单独测量并报告，不与上述口径混用 | 发布前实际窗口验收 |
| 支持域主图滤镜路由 | filter canonical fallback = 0；全尺寸 RAW 重解码 = 0 | 含滤镜 + 已支持复合算子 |
| 冷 shader / 首次 look | 单独报告；不得出现多秒冷等待 | 预热后仍需保留冷样本 |
| 滤镜阶段为唯一差异 | 缩略图候选重建 = 0，256 px proxy fill = 0 | 派生配方变化除外 |
| 真实 RAW 十候选 | 原片与九滤镜全部生成，尺寸不超过目标，有限值通过 | 9504 × 6336 为固定回归样本 |
| 候选刷新体验 | 空白帧 = 0；旧内容有更新中标记 | 连续调整与 settled 并存 |
| 暖路径整组候选 | 目标 p95 ≤ 250 ms，可见项优先；未达标前不宣称完成 | 当前真实 RAW 基线因 193 px 缺陷而不存在 |
| LUT 热路径 | 同键 payload 重复读取 = 0；无预算超限 | 保留 cold/warm/outlier 数据 |
| 资源 | LUT ≤ 32 MiB；缩略图 ≤ 14 MiB；任务全部 join | 记录实际 charge 与 retired owner |

Stretch goal：生产画布 p50 ≤ 16 ms。不得为达到数字删除有限值校验、降低 canonical 精度或把 API return 冒充屏幕呈现。

## 必测矩阵

- 源：Sony 9504 × 6336、9505 宽近边界样本、横拍、竖拍、JPEG、含 alpha 图、HDR/超色域。
- 尺寸：target 128、192、256、2400；近整数、普通小数和极大源尺寸。
- 滤镜：Original、九个 look、0/1/25/37/50/62/75/100%。
- 组合：滤镜 + Texture/Clarity/Dehaze/Mask/曲线/几何；不支持组合 fail-closed。
- 生命周期：连续手势、快速切换、hover 交叉、面板重进、失焦、原片按住、比较、裁切、实际像素、切照片。
- 异常：LUT 缺失/损坏、源变化、内存压力、晚到帧、任务取消、重复 release。
- 输出：交互与 settled 误差、保存/导出 canonical 不变、原文件 SHA 不变。

## 明确不在 M0/M1 范围

- Camera Matching、Adobe Raw Profile 或普遍 ACR 像素等价。
- DCP/XMP 解析与导入、第三方预设商店、作者/推荐系统。
- Adaptive AI、PGTM、主体/天空 RGBT 和 SDR/HDR 自动 look。
- 完整用户配方 Preset 的数据库迁移与子集应用；另开 M2。
- 默认把 LUT 改为 F16、3D texture 或新 Metal presenter。只有 profile 证明必要才另开实验。
- 全相机、全 RAW、全组合的性能或像素等价保证。
