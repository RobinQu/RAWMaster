# 031 · 滤镜预设交换与本机迁移功能验证

下文源码和测试对应独立功能提交 `d0091997`。在任一工作树执行 `git show d0091997:路径` 可读取指定文件。[独立版本与构建收据](feature-validation.md)

2026-11-22 对应 US3、FR-004 至 FR-007、SC-03 与 SC-04。测试使用开发构建、临时目录库和用户显式选择的本地文件。下列结果记录文件、参数、目录事务与逐图重建资格。Camera Raw 基础编辑对齐后的 Lightroom Classic 实机回读、成片像素与交互性能另行签收。[规格](spec.md) · [联调验收](integration-validation.md)

## 用户入口

编辑器左侧预设目录的「XMP 交换」菜单提供 XMP / ZIP 导入和本机 Camera Raw 迁移。迁移先选择系统内置、个人 ImportedSettings 两种来源，再显示逐文件预检。相同 UUID 的不同字节默认跳过，用户可明确选择保留两个版本。确认后显示新增、共享已有内容和已跳过的条目，可保存带逐项结果的 JSON。选择外部预设后，可查看字段路径、原值、影响采用的条件和内部 Look 来源。`Sources/RAWMaster/PresetExchangeControls.swift`

「查看 XMP 字段与依赖」显示可映射和略过的字段。普通预设在其照片条件、Process Version 和可用参数满足要求时提供「确认仅采用列出的映射参数」。可重建的主体或天空条目提供「在本张重建选区」，经同一原生逐图生成、预览和确认会话采用。打开详情时冻结照片和配方修订，编辑基线变化后需要重新选择。`Sources/RAWMasterCore/DevelopmentPresetExchange.swift` · `Sources/RAWMaster/DevelopmentPresetBrowser.swift`

## 当前映射与交换

| 资料或参数 | 实际行为 |
| --- | --- |
| 曝光 | 本张调整和个人预设共用同一投影，物理曝光等于旧版显影基底 EV 加两倍 V3 Light 曝光。个人预设保留所选字段的显式零。本张非零调整导出只收录非零结果。XMP 导入时，明确的 Exposure2012 同时将旧基底曝光置零并把 EV / 2 写入 V3。省略曝光则继承两个阶段。支持 −4 至 +4 EV 的参数导入，写新 XMP 要求可用 0.01 EV 表达。 |
| 基础百分比 | Contrast2012、Highlights2012、Shadows2012、Whites2012、Saturation、Vibrance 使用 −100 至 +100 和原生归一化参数之间的换算。显式零会覆盖目标参数，省略项继承目标原值。超出范围或精度的值进入排除清单。 |
| 点曲线 | RGB、红、绿、蓝的 ToneCurvePV2012 各自解析 RDF 序列。每通道支持 2 至 16 个点，坐标取 0 至 255，输入端点为 0、255，横轴严格递增。采用单通道时保留其余通道及输入范围。导出完整原生曲线时单列原生插值、参数曲线与精细饱和度等差异。 |
| 版本与未知字段 | 基础参数对 Process Version 6.7、11.0、15.4 登记参数映射。未识别的版本、相机或图像条件进入待核对状态。未知标量和结构保留原始字节，详情支持按路径或值筛选。显影基底、ISO 分档、表数据和逐图算子各有独立诊断。 |
| 导出 | 用户原生预设和本张非零全局调整可以新写 PV 15.4 XMP。保存前列出可写入参数，以及超出 Adobe 滑杆范围、固定 LUT、原生算法或源绑定状态等排除项。个人来源的原始 XMP 采用独立的权限确认命令。核准的 53 个内置 SHA 即使经手工导入仍受本地使用限制。 |

自制测试文件在 RAWMaster 内完成解析、参数采用、生成新 XMP、再次解析，并核对每个已声明字段。旧基底 +1 EV 与 V3 +1 EV 合计写出 +2 EV，单独旧基底 +1 EV 和单独 V3 +1 EV 都写出 +1 EV，两种导出入口在三组上均一致。导入明确零的样例保留原有裁切、阴影及白平衡。旧目录中已收录的 Exposure2012 在重开时也采用双阶段规则。未映射的旧色调、曲线和分级列出实际字段路径。新写 XMP 的像素结果及 Lightroom Classic 参数回读尚待联合验收。`Sources/RAWMasterCore/CameraRawPresetMapping.swift` · `Sources/RAWMasterCore/CameraRawXMP.swift`

## 已安装样本

运行时系统根只访问 53 条已核准相对路径，同时匹配文件大小和 SHA-256。另一个用户根递归枚举本次安装中的 XMP。2026-11-22 的冻结快照总计 78 份、1,881,440 字节，其中内置 53 份、个人 25 份。临时内容库逐份回读，与源文件比较完全一致。72 项可浏览，6 项作为 Look 依赖，重复执行新增 0 项。[冻结样本](contracts/migration-manifest-v1.json) · `Sources/RAWMasterCore/Resources/AdobePresetMigration-v1.json`

| 类别 | 已收录 | 当前可执行动作与证据 |
| --- | ---: | --- |
| 个人 Normal | 19 | 7 项具有可单独确认的基础参数或点曲线。12 项以库内 Look 为核心，6 项依赖渲染器相机基底，1 项引用缺失的 Adobe Color。19 项均保留整项采用的阻塞原因。 |
| 内部静态 Look | 6 | 通过 UUID 找到上述 12 条内部引用，可在详情中查看来源及内容哈希。 |
| 主体 | 9 | 9 项均解析出单个有序主体请求。Cool Soft、Soft、Vibrant、Warm Pop 共 4 项可以显式重建本张选区。Soft 的局部 Texture 值为 −0.304315。 |
| 天空 | 9 | 9 项均解析出单个有序天空请求。Blue Drama、Dark Drama、Storm Clouds、Sunrise、Sunset 共 5 项可以显式重建。Sunrise 的局部饱和度为 +0.196334，清晰度为 −0.295703，色温为 +0.20192。 |
| 风景分区与人像部位 | 8 + 12 | 记录实际校正数量、区域组件及原始字段。多类别、人物部位、顺序与画面一致性进入逐项对拍。 |
| Lens Blur | 13 | 经核准的 Reset Blur 只清除当前 Lens Blur 状态，保留同一效果组中的颗粒等设置。原本没有镜头模糊时产生 0 条命令，这条路径的深度分析请求数为 0。其余 12 项保留深度、焦点和散景待验证状态。 |
| Adaptive Profile | 2 | 在 Profiles 中展示，记录逐图增益表需求。RAW 前端、增益表与多表合成另验。 |

此次冻结样本中整项直接可执行的条目是 Reset Blur。另有 7 个普通预设可显式部分采用、9 个语义条目可在本张用原生算法重建。主体、天空剩余的条目涉及局部曝光换算、独立曲线、曲线饱和度、色相、着色或超过 1 的校正强度。显示本地重建的条目保留原始 Adobe 条目的采用限制与来源。`Sources/RAWMasterCore/PresetSemanticIntent.swift` · `Sources/RAWMaster/DevelopmentPresetMaskPreparation.swift`

## 事务、输入边界与安装包

- 暂存阶段解析字节并计算 SHA。确认时先校验内容文件，再在文件锁内原子发布目录、批次引用和提交顺序。同 SHA 的不同来源保留历史路径。同 UUID 且不同哈希的选择会在提交锁内再次核对。
- 「撤销导入批次」默认选中最后成功提交的批次，显示该次涉及的条目。按预检相反顺序提交、同一秒并发预检或重试较早请求，均以实际提交顺序决定最近批次。旧索引中历史顺序缺失的批次供用户显式选择。撤销只移除所选引用，保留其他批次和已冻结内容。重复撤销与延迟重试均有回归覆盖。`Sources/RAWMasterCore/DevelopmentPresetCatalog.swift`
- 单个 XMP 上限 8 MiB，单个 ZIP 上限 64 MiB，批次上限 96 MiB、2,048 项。UTF-8 RDF 支持命名空间别名、元数据属性、Alt、Seq 和嵌套校正。ZIP 校验目录、常规文件类型、路径、大小以及解压后的 CRC，仅在内存中读取 stored/deflate 条目。迁移通过目录文件描述符逐级打开核准路径。`Sources/RAWMasterCore/PresetExchangeArchive.swift`
- 正式打包脚本把 Core 资源包复制到 `RAWMaster.app/Contents/Resources/RAWMaster_RAWMasterCore.bundle`，逐项对照冻结清单中的 53 个路径、大小与 SHA，再比较复制后的资源字节。已从本次编译的 SwiftPM 资源包在临时 app 目录独立执行该步骤，结果为 53 条。[打包脚本](../../scripts/build-app.sh)

## 可复现命令

从仓库根目录运行独立功能集。读取真实 Adobe 安装的测试需要显式传入环境变量。应用的正常迁移也由用户发起。

```sh
RAWMASTER_CHECK_ADOBE_PRESET_FIXTURE=1 swift test --jobs 3 \
  --scratch-path /tmp/rawmaster-031-exchange-build --filter PresetExchangeTests
zsh -n scripts/build-app.sh
git diff --check
```

本次执行 15 项，全部通过，失败 0 项。用例覆盖稀疏零值和分通道曲线、两阶段物理曝光在两种导出入口的三组往返、导入零和省略的区别、旧映射升级及逐字段导出排除清单、命名空间和本地化、未知字段值、原始来源权限、相同 SHA 来源留存、重复批次和 UUID 冲突、限定目录及更版文件、ZIP 校验、反序提交和旧版批次选择，以及实际 78 个文件、9 个重建候选和 Reset Blur 命令。测试在临时目录创建用户库，源文件逐个核对字节。`Tests/RAWMasterCoreTests/PresetExchangeTests.swift`
