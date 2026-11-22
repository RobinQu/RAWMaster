# 028 · 任务清单

T-021、T-023、T-025 的原始验收口径保留。031 切换默认入口时要在同一设备复测 Classic Filters 的窗口呈现和辅助功能，并独立检查目录产生的滤镜缩略图请求为零。新增工作在 [031 任务清单](../031-preset-browser/tasks.md) 领取。

## A. 正确性前置

- [x] **T-001** 增加共享近整数像素尺寸计算及单元测试，覆盖 9504 → 192 的 `192.00000000000003` 边界。依赖：无。
- [x] **T-002** 将主图/缩略图代理布局迁移到共享计算，验证 transform、layout、canvas 一致且不超过 target。依赖：T-001。
- [x] **T-003** 用真实 Sony RAW 验证 Original + 9 filters 均能独立生成，记录尺寸、有限值和资源释放。依赖：T-002。

## B. 主图快速路径

- [x] **T-004** 移除支持域内 filter 的 canonical fallback 拒绝，保留其他不支持域。依赖：T-001。
- [x] **T-005** 在 suffix 的 Global 后、advanced/mask 前应用 Photo Filter，并传入可选资源租约。依赖：T-004。
- [x] **T-006** 移除缩略图 suffix 后的重复滤镜调用，保留 LUT 记账和持有生命周期。依赖：T-005。
- [x] **T-007** 改写 filter fallback 测试，覆盖九 look、强度、复合阶段、alpha/HDR/NaN 对拍；新增 managed/legacy RGBA8 对拍及 RAW 1–3 ULP transport 边界。依赖：T-005、T-006。
- [x] **T-008** 扩展真实画布性能测试，覆盖 look 切换、连续强度和复合配方；是否达到性能门由 T-023 单独判定。依赖：T-007。

## C. 缩略图生命周期

- [x] **T-009** 实现 `FilterCandidateSetContentKeyV1`，对十份实际解析候选配方计算集合指纹。依赖：T-003。
- [x] **T-010** 解除缩略图对主图 settled 的强制依赖，保留匹配 settled hook 快路径。依赖：T-003。
- [x] **T-011** 将 Service adopt/start 的当前性校验改为交付身份 + 内容键，保持 sourceAuthority fail-closed。依赖：T-009、T-010。
- [x] **T-012** UI 按内容键决定复用/刷新，保留 last-known-good 并原子替换；终态错误在旧图保留时仍显示重试入口。依赖：T-009。
- [x] **T-013** 用有界 50/100/200/400/800 ms 退避替代同 key/witness 仅一次自动重试，分类错误终态。依赖：T-011、T-012。
- [x] **T-014** 增加 revision、focus、重进、连续调整、派生配方、晚到帧、压力和 close 测试；真实 Service 回归断言 filter-only 重建 0、模型层空白 0。依赖：T-013。

## D. 重复工作

- [x] **T-015** 移除每 tile 强制 LUT trim，验证细粒度 autoreleasepool、有界 LRU 和 32 MiB charge。依赖：T-006。（功能与预算回归通过；冷整组未观测到提速。）
- [x] **T-016** 当前固定十项在面板中均属于可见集，保留 Original 首位的固定生产顺序；首项与整组均已测量，暖整组 p95 104.279 ms，无需额外选中项/atlas 调度。依赖：T-003、T-015。
- [x] **T-017** 不实施独立批任务/GPU atlas：暖整组 p95 已低于 250 ms；冷 256 px 代理成本独立记录。依赖：T-016。

## E. M1 功能体验

- [x] **T-018** 实现 transient hover token 与主图临时预览，不写 committed recipe/历史/持久化。依赖：T-008。
- [x] **T-019** 完成 hover 退出恢复、交叉 hover、比较/裁切/原片按住和晚到帧防护；返回时复核 revision、presentation 和交互状态。依赖：T-018。
- [x] **T-020** 实现版本化收藏偏好、稳定排序、损坏 ID 清理回写、键盘方向键和辅助功能标签。依赖：T-012。
- [ ] **T-021** 原生窗口验收 hover、确认、Escape、收藏持久化和 VoiceOver 标签。依赖：T-019、T-020。（控制器及真实 Service 测试已通过；实际 VoiceOver/物理键盘窗口验收仍未完成。）

## F. 交付门

- [x] **T-022** 真实 RAW 受控 probe 已复测并保存新 raw JSON；Service、十候选、十组 settled 和全尺寸导出均记录固定源 SHA，不覆盖旧证据。依赖：T-008、T-014、T-016。
- [ ] **T-023** 真实 AppKit 画布达到 p50 ≤ 20 ms、p95 ≤ 33 ms，支持域 filter fallback/RAW 重解码为 0。依赖：T-022。（最终暖路径 p50 **27.367 ms**、p95 **34.061 ms**，未达到门槛；全部 interactive 为 approximate，冷样本单列。）
- [x] **T-024** 真实 RAW 十候选全部成功，滤镜阶段差异重建 0，模型观测刷新空白 0，暖整组 p95 104.279 ms；冷代理和物理窗口空白不作已通过宣称。依赖：T-022。
- [ ] **T-025** 完整 Debug/Release 回归、实际保存/导出、原文件 SHA、资源 union0 和正常退出验收。依赖：T-023、T-024、T-021。（全项目 Debug 1684 项与滤镜 80 项 Release 均 0 失败；真实保存/导出、SHA、union0 和正常退出通过；T-021/T-023 未关闭，因此本项不勾选。）
- [x] **T-026** `validation.md` 已更新为生产验收结果并明确未验证边界；未把未完成门禁宣称成 M0/M1 Converged。
