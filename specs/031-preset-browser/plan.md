# 031 · 预设实施方案

2026-11-22 · 设计基线，独立实现及覆盖见[开发交付记录](feature-validation.md) · Swift 6、macOS 15+、SwiftUI/AppKit、Core Image/Metal · [产品目标](spec.md) · [执行任务](tasks.md)

左栏统一挂载文字目录。基础滤镜与胶片模拟复用原有收藏 ID、滤镜选择和主图临时呈现。Adobe Adaptive 复用导入条目的标识与来源。离开目录取消尚未采用的准备任务。[目录交付](directory-delivery.md) · [此前集成实测](integration-validation.md)

## 按当前工作树修正设计

| 实际接点 | 本次设计决策 |
| --- | --- |
| 主图提供独立的悬停预览，收藏由 `editing.filterFavorites.v1` 保存 | 目录仅消费条目元数据，全部滤镜行共用主图临时呈现。当前采用的滤镜在所属组提供启停、强度及复位。[左栏](../../Sources/RAWMaster/EditingLeftSidebar.swift) · [目录](../../Sources/RAWMaster/DevelopmentPresetBrowser.swift) · [编辑控制器](../../Sources/RAWMaster/EditingController.swift) |
| 新配方的 Selective Color 已有八个色槽，解码器接受旧六槽。已有按画面取色的 H/S/L 拖动 | 优先做八色字段、旧六槽升级行为和范围转换的金样对照。Orange/Purple 缺省时保留旧片值，修改这两槽时做显式兼容扩展。原生点色样本与 Adobe 八色字段分开映射。[色槽与解码](../../Sources/RAWMasterCore/DevelopmentAdjustmentsV3.swift) · [目标颜色调整](../../Sources/RAWMasterCore/DevelopmentTargetedColorAdjustmentV3.swift) |
| 主工程有线性、径向、亮度范围和合并的 Vision 主体，局部模型已包含冷暖、色相、曲线、纹理、去雾、锐化等字段 | 工时优先给语义描述、逐图快照、组合、单位和顺序对拍。复用已验证的局部算子。现有主体 PNG、旧调整及已有笔划走旧配方回放。[蒙版模型](../../Sources/RAWMasterCore/DevelopmentMaskModelsV3.swift) · [027 独立服务](../027-mask-ai-raw-integration/service-validation.md) |
| 已有程序焦平面、ImageIO 设备深度/视差、主体焦点、五种散景、猫眼/高光增强和修正笔划 | 13 项 Lens Blur 的第一步是辨认真实输入、对应字段和核。没有设备深度的普通 RAW 另验本地单目深度，Swirl 单独立项。术语相同还需要端点、散景轮廓、遮挡和成片对照。[配方](../../Sources/RAWMasterCore/DevelopmentLensBlurV3.swift) · [渲染器](../../Sources/RAWMasterImaging/DevelopmentLensBlurEngineV3.swift) · [主体焦点](../../Sources/RAWMasterImaging/DevelopmentLensBlurSubjectFocusV1.swift) |
| 支持域内的 RAW 交互代理取 FlashRaw F16，经 Metal 与既有调整渲染。全尺寸预览有独立 FlashRaw 配置，普通配方导出仍有 CIRAWFilter 路径，归档作品还有直接导出路径 | 按实际 decoder、有效源区域、坐标、色彩和管线版本登记能力。代理、全尺寸重新显影与既有归档分别回归。全质量不支持的资源保留诊断，杜绝把临时预览写成成片。[030 源码复核](../030-ai-retouching/source-review.md) · [V3 渲染器](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift) |

以上是本机工作树 2026-11-22 的代码事实，包含进行中的改动。Camera Raw 对照表用来定位已有入口。每项 Adobe 字段的数值和像素承诺以本规格的金样登记为准。基础编辑会话维护的实时矩阵位于主工作区 `docs/research/camera-raw-parity/feature-matrix.json`。接入时按已交付的修订核对。[集成验收单](integration-validation.md)

V3 的相关渲染顺序为 Global、Glow、Photo Filter、Lens Blur，随后经过细节/去雾、调整蒙版、有序局部修复与几何等阶段。把原生滤镜放在现有 Photo Filter 节点，把语义局部值写入调整蒙版，保留修复的顺序。RAW Profile 要求更早的基底数据，需要专门的前端接入点。[当前阶段顺序](../../Sources/RAWMasterImaging/DevelopmentRendererV3.swift)

## 数据与职责

| 对象（拟增或扩展） | 存储与身份 | 使用者与约束 |
| --- | --- | --- |
| 目录条目与不可变版本 | 全局 Application Support 的独立索引包含逻辑 ID、版本、来源、分组、类型、原始 UUID、内容 SHA、解析与映射器版本 | 浏览、收藏、替换共用逻辑 ID。按 SHA 去重，同 UUID 不同 SHA 进入冲突选择，重名可改名或复制。相同字节可记录多个来源。把原固定滤镜偏好一次性映到稳定 Classic ID，保留旧值以便切回 |
| 原始内容与支持报告 | `content/<sha256>.xmp`、原生版本文件、RDF 未消费节点、字段路径/值、源条件、依赖边、证据级别 | 分别表达已收录、文件/参数/行为/像素证据、当前照片是否可用、正在分析/可用/过期。版本升级重编报告。内部 Look 按 UUID 加版本解析，相机基底由渲染端解析 |
| 配方差量与应用会话 | 逐字段 presence，带类型、值、单位、声明的 Process Version、选中子集、顺序与 Amount 策略。会话绑定 photoID、base revision、baseRecipe、条目版本 | 原生保存、XMP 映射、右栏场景卡与参考张批量均编译成现有编辑命令、必要的语义请求与同一种采用操作。单次提交校验修订，命令 ID 去重 |
| 每张照片的采用记录 | 在现有配方/历史机制保存解析后的具体值、预设 ID/版本、采用/略过字段、源标识、分析与资源快照引用、策略及回执 | 重开可离线复现。更新目录、卸载模型、失去外部文件后，已采用版本持有其所需资产。删除预设只撤销目录引用，保留历史引用。资产损坏向用户指出并提供恢复路径 |
| 语义描述与结果 | 027/030 管理目标、人像实例、组合顺序、来源、模型版本、内容寻址 Gray8 快照。深度、Look 表和生成 Patch/Matte 分属各自类型 | 左右面板共用同一分析服务与采用记录。可移植配方只复用目标和参数，源绑定笔划、快照和已生成像素只在匹配照片/修订回放。新照片需要重新选中实例或准备选区 |

沿用现有编辑会话的事务、回滚和 Undo。目录与收藏独立于单个资料库。原生全状态导出遇到源绑定内容时列出本张专用资产、可打包/已固定的内容与可移植字段。严格保存只在所需资产可引用或可随包携带时成功。写入步骤先落资产并验 SHA，再原子发布索引或历史引用，失败不产生悬空引用。多窗口更新按版本比较，冲突时重选基线。共享文件只在全部引用和未完成事务均释放后回收。[现有命令](../../Sources/RAWMasterCore/DevelopmentAdjustmentCommands.swift) · [编辑会话](../../Sources/RAWMaster/EditingDevelopmentSession.swift) · [快照与回执](../030-ai-retouching/plan.md)

手势级 Undo 由编辑会话管理。跨重启复现依靠资料库中工作作品的配方/保存版本与冻结资产。T004 需在现有采用和备份路径登记新引用，并用空会话从备份恢复已采用版本，检查其 SHA 与导出像素。[资料库写入](../../Sources/RAWMasterCore/LibraryStore+Editing.swift) · [备份](../../Sources/RAWMasterCore/LibraryStore+EditingBackup.swift)

## 从预览到保存

1. **解析。** 用户手选 XMP／ZIP，工程诊断命令读取冻结清单。检查容器大小、展开上限、条目数和根内路径，解析 RDF 属性、结构、数组和本地化名称。保留原始字节，按内容区分 Preset、Profile、内部 Look 及 sidecar。记录非 XMP 或拒绝原因，未知内容按数据保留。
2. **编译。** 按字段连同父结构、Process Version、源限制、Profile/Look/ISO 节点编译。编译缓存用内容 SHA 和映射器版本，已解析依赖版本进入渲染指纹。Exposure 的目标单位/范围、旧色槽和曲线顺序逐项验证。超出当前范围显示具体值。任何缺少必要项、范围溢出或无可用字段的情况都不会被静默截断后计作完整应用。
3. **预览。** 从当前已提交的基线计算稀疏差量。临时 consumer 绑定 token、source generation、base revision、presentation ID，只有最新请求可发布。取消后回到当时有效的已提交显示。仅可预览当前已验证的路径，部分应用先由用户明确选择子集。普通 hover 与手调共用原生算子。语义 hover 读取 ready 快照，尚未准备时停在已提交帧。用户准备同一张照片的多个目标时，按依赖合并在途任务并限制并发，共享场景分析的成本记在该照片上。[预览协调器](../../Sources/RAWMaster/EditingPreviewCoordinator.swift)
4. **采用与强度。** 点击时重新检查源、当前修订、纪实策略与资产。原子采用整体，或采用已经确认的部分。Amount 始终从同一基线重算，固定滤镜保留自身强度算法。离散字段仅经验证才允许端点切换。混合字段找不到共同强度规则时隐藏连续滑杆。拖动中不重复推理，手动编辑后结束旧强度会话。
5. **保存与交换。** 原生格式携带 schema、版本、所选字段与资产依赖，可同名替换、复制、改名。新写 XMP 只输出验证过的 PV 和字段，导出前列出所有排除项。原始导入字节可原样导回。普通 writer 首批选择可配对的 Basic 字段和点曲线，逐组放行 HSL 等扩展。用 Lightroom Classic 回读验证 Name、Group、UUID、字段值和省略项。

## 本地迁移与恢复

系统源根为 `/Library/Application Support/Adobe/CameraRaw/Settings`，用户源根为 `~/Library/Application Support/Adobe/CameraRaw/ImportedSettings`。命令按同一完整清单对 53 + 25 个冻结相对路径验证长度和 SHA。出现缺失、变化或 UUID 冲突时整批停下并出预检报告，常规选文件导入仍可独立执行。[固定输入](contracts/migration-manifest-v1.json)

执行时以暂存事务 ID 标记本批文件，逐个验证后原子提交索引。中断时只清理未被引用的暂存内容，重跑同源去重。两次同时导入用 SHA 和版本校验合并。取消迁移或撤销批次以该批引用为单位处理，保留其他来源和照片历史所持有的共享内容。安装包仅携带映射规则和自有测试数据。

## Adaptive 采用三条渲染路径

交互分析从 027 的本地 ORT 基线接入。D-FINE-S 找出人物候选，SlimSAM 处理用户点/框并复用图像编码，EfficientViT-B2 ADE20K 为单张风景共享类别概率。人物部位涉及 YuNet、人脸关键点等额外依赖，按实际执行的全链条校验许可、权重哈希和内存。未安装模型时，可继续用已冻结结果、系统 Vision 或手工范围。场景卡沿用本地调整，显式确认的局部清理请求才进入生成队列。[模型证据与局限](../030-ai-retouching/mask-validation.md)

旧 V3 每张最多 32 个蒙版层，内嵌主体 PNG 单层上限 4 MiB。编译多区域预设时先核对当前剩余容量，容量不足时列出超限项并保留用户既有层。源中确实没有天空且仅请求天空时，以「已跳过，未发现天空」结算，成片与 Undo 均不新增变化。模型缺失、文件损坏或用户取消分别报告，能与真实空目标区分。[现有蒙版上限](../../Sources/RAWMasterCore/DevelopmentMaskModelsV3.swift)

| 路径 | 第一项能交付的结果 | 后续专项与开放条件 |
| --- | --- | --- |
| 38 项语义校正 | Subject/Sky 先各取一个代表文件做「区域 → 局部值 → 有序合成 → 冻结」的贯通测试。Vision 或手工范围可先交付原生人物提亮 | Subject 9、Sky 9 逐项登记，Landscape 8 与 Portrait 12 按所需类别/部位排队。共享场景概率、对象 embedding 和不可变快照各有独立键与资源预算。键含真实源/前缀依赖、方向、尺寸、实际调用的模型哈希及阈值。修边分支不触发重新检测，输入变更使新草稿过期，旧历史仍可回放。[分类实测](../030-ai-retouching/mask-validation.md) |
| 13 项 Lens Blur | 先验证 Reset 只清镜头模糊状态，深度请求数为 0。选设备深度和普通 RAW 各一张作输入对照 | 分别验焦点、BlurAmount、五形状、Swirl、近远景遮挡及 HDR 高光，再逐项启用。没有合格深度的照片保留手动原生路径。深度只在本张缓存或冻结，不随预设迁到下一张。[散景与修边实现](../../Sources/RAWMasterImaging/DevelopmentLensBlurRefinementEngineV3.swift) |
| 2 项 Adaptive Profile 及 6 个静态 Look 依赖 | AP0 冻结 DNG 与 Adobe 参考，AP1–AP2 解码静态 LookTable/RGBTable 并先测 6 个 RNI。可先放行依赖已齐且整体通过的普通预设 | AP3–AP8 验证 RAW/RIMM、BaselineExposure、ActiveArea/opcode、PGTM2 优先级、内部语义掩码和多表合成。AP9–AP11 验 SDR/HDR、Amount 及缓存。已有 DNG 表重放、自研逐图生成、AP12 写 DNG 分别出证据。逐机型验证非 DNG 前端，Profile 内部掩码独立于用户编辑蒙版。[AP0–AP12 调研](../../docs/research/lightroom-preset-browser-plan.md) |

胶片基础色调可在有版本的 LUT 对拍后进入左侧风格库。粒子、光晕和全尺寸扫描效果须独立标记预览与成片质量。生成式局部清理归 029/030 的异步采用流程，目录只解析其来源和可复用性。双模型的质量与耗时基线见[既有对照报告](../030-ai-retouching/research.md)。

每个分支按[验收矩阵](validation.md)登记来源、适用范围、失败样例和放行决定。跨团队依赖与失败后的可发布范围见[联合研发计划](../../docs/planning/24-mask-preset-retouch-roadmap.md)。
