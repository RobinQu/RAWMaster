# 027 · 编辑器蒙版功能实测

Camera Raw 交付后的 GPU 分析、自然开关、全尺寸 TIFF 和窗口复测见[联合验收记录](../031-preset-browser/integration-validation.md)。以下为独立版本的历史基线。

2026-11-22，在独立开发版本的编辑器、配方和离线 TIFF 输出路径验证。运行环境为 Apple Silicon、macOS 27.0.1、Swift 6.4。五组定向回归共 19 项。与 Camera Raw 基础编辑的联合验收执行前，还需在双方对齐的目标版本上测首屏、交互与高分辨率导出的耗时、峰值和退出后的内存。[功能测试记录](evidence/editor-functional.log) · [联合验收单](../031-preset-browser/integration-validation.md)

## 摄影师可完成的操作

| 操作 | 编辑器行为与检查点 |
| --- | --- |
| 准备选区 | 「调整 → 蒙版」提供主体、背景、前景实例和空白画笔。安装相应模型后显示天空、水面或点选／框选物体。图层在用户采用前保持原样 |
| 多主体 | 点击目标或拖框选择框内覆盖最多的前景实例，也可以用键盘打开「按实例选择」，按原片左／中／右定位。候选来自同一张图的 Vision 实例标签 |
| 检查和修正 | 红色叠加显示实际 Gray8 覆盖；裁切、翻转、透视后沿源坐标映射。添加／减去画笔与笔径在选区下方。反转蒙版时画笔仍按屏幕所见的选区工作。Escape 或关闭放弃待采用修改 |
| 采用及回放 | 一次采用形成一个可撤销的图层编辑。回到已有图层可以重新查看、修正。配方保存源内容哈希、方向与原尺寸、生成器、权重哈希、提示点和冻结 PNG。画笔修边写入标记。旧版主体 PNG 继续可读 |
| 重新选片或换模型 | 迟到的识别须同时匹配操作编号、工作上下文和配方修订。更换源文件会使已有语义选区出现来源校验错误。已确认的选区随原片配方重开，移除模型后仍可回放 |
| 供个人预设使用 | 共享服务允许按目标片重新准备主体、背景、天空或水面。服务只返回候选。提交个人预设与跨片字段规则由 031 的单次历史事务处理。[031 方案](../031-preset-browser/plan.md) |

## 产品路径的观察

| 检查 | 结果 |
| --- | --- |
| 山湖 JPEG | 作者权重导出的 EfficientViT 在 1536×1025 分析图上，天空与水面分别覆盖 17.93% 和 46.34%。口径为像素值 ≥128，只描述本图覆盖 |
| 确认无水样本 | Stanford Background 编号 6000079 的水面请求返回未检出。没有产生可采用的空白结果。[人工标签取样](../030-ai-retouching/evidence/evaluate-landscape.py) |
| 竖拍 RAW | Sony 雪景原片 EXIF 8，画布源为 4000×6000，产品分析图为 1024×1536。同批人像 RAW 上，系统主体与背景每个像素恰好相加为 255。键盘实例菜单可选中有效前景 |
| 人像点／框 | 在同一人物内部坐标处，Vision 点选及框选的覆盖值均为 255。SlimSAM 点选为 210，框选为 223。这是内部点命中检查。人体边界、五官及雪景识别的额外观测见[原生 RAW 分项验证](portrait-snow-validation.md) |
| 灰度与恢复 | 0…255 全阶逐像素往返一致。画笔增减、快照哈希损坏、错误来源、UI 撤销／重做、关闭工作区后从资料库读取均有断言。中途取消、修改配方、切换照片时，刻意延迟返回的候选均未写入 |
| 比较与原片 | 测试向编辑器发送 V、M 按键，在候选就绪、请求尚未返回两种时机分别进入比较和原片。当前选区立即撤销。解除显示后旧结果仍无法占用画布或写入历史，可再次发起新选区 |
| 同图精确命中 | 实际 Vision 主体和水面请求各重复一次，断言命中已计算的 Gray8。键包含当前文件内容／方向／尺寸、意图、点框、分析图版本、生成器、权重 SHA。至多缓存 4 项，总计上限 12 MiB。处理中收到取消时释放照片解码、Vision 观测、ORT 会话等分析资源，已完成的同图选区可继续命中。切换来源、退出工作区会清空两者。此项测试检查计数和资源状态 |
| 安装取消与修复 | 在真实模型包准备发布时人为暂停并取消，验证旧文件保持原内容、运行库未发布。并发安装场景和物体后两者均通过校验；改写已验证的模型后移出可用状态，已有推理会话和命中缓存也不能绕过检查。重新安装可恢复。编辑器取消按钮的任务传播有单独用例 |
| 实际导出 | 从序列化配方恢复，通过 DevelopmentService 输出 16 位 TIFF，验证方向、尺寸以及涂画区与保护区的明暗差。替换为同尺寸但内容不同的原片后，旧语义图层被拒绝 |
| 可选模型 | 从离线包复制到临时安装位置后实际推理，移除该目录再回放快照。otool 检查编辑器可执行文件，无 ONNX Runtime 链接项或开发机 Vendor rpath。打包只接纳固定运行库及权重指纹。[模型包与安装](model-pack.md) |

## 旧作品开关图层的两组对照

在主图以画笔选出一小片区域，采用后把局部曝光设为 +0.4。关闭编辑器，按作品 ID 读回配方并写出 120×80、16 位 TIFF。使用同一冻结 Gray8，对有效遮罩等于零的 9,484 个像素比较四通道，覆盖 ≥0.5 的像素共 112 个。三份成片、原图和冻结蒙版随规格保存。[测量和哈希](evidence/legacy-renderer-toggle/measurements.json) · [原图](evidence/legacy-renderer-toggle/input.png) · [冻结蒙版](evidence/legacy-renderer-toggle/frozen-mask.png)

| 对照方式 | 保护区最大差（16 位通道） | 选区情况 |
| --- | ---: | --- |
| 同一 V3 渲染器、相同局部曝光，使用全零覆盖作为对照 | 0 | 112/112 像素变亮。[采用成片](evidence/legacy-renderer-toggle/reopened-subject.tiff) · [零覆盖对照](evidence/legacy-renderer-toggle/same-renderer-zero-coverage.tiff) |
| 自然关闭该图层，旧作品从 V3 返回历史渲染器 | 2 / 65,535 | 112/112 像素变亮。重复导出关闭状态自身的差为 0。[关闭图层对照](evidence/legacy-renderer-toggle/disabled-layer-control.tiff) |

逐通道读取 TIFF 原始样本复算，重复导出关闭状态自身的最大差为 0。另做了一次试验，仅让开启蒙版的旧作品沿用历史 CIContext，保护区最大差增至 5/65,535，因此交付版保留原有上下文选择。基础引擎集成时将同时追踪旧/新显影前缀和写出量化，并复测有旧色调配方的作品及 RAW。[两次路线试验](evidence/legacy-renderer-toggle/route-diagnostics.json)

此差异归入基础引擎集成时的旧作品回归。联合 Release 探针同时检查自然开关图层的保护区零差及局部增亮。开发版蒙版已补充具体请求的画布所有权。真实窗口验证了旧画布 A 延迟退出时，同一照片上的新请求 B 继续运行，退出当前 B 会取消。真实 Vision 服务同时核对了冷生成、精确命中、画笔、取消与失败的计数。[联合检查和运行命令](../031-preset-browser/integration-validation.md)

## 复跑

`RAWMASTER_MASK_FIXTURES` 指向包含 `mountain-lake.jpg`、`no-water-6000079.jpg`、`person.ARW` 和 `snow.ARW` 的目录。`RAWMASTER_MASK_PACK` 指向上述离线运行库及两个模型组件的根目录。真实素材及大模型独立保存。缺少两项环境变量时，照片与真模型用例会报告跳过，其他定向用例仍可运行。山湖图来自[026 样本脚本](../../experiments/MaskAI/Scripts/download-fixtures.sh)，人物和雪景的作者及许可见[样片清单](portrait-snow-validation.md)。

```sh
RAWMASTER_MASK_FIXTURES="$PWD/output/preset-mask-fixtures" \
RAWMASTER_MASK_PACK="$PWD/output/preset-mask-fixtures/portable-mask-models" \
swift test --filter 'DevelopmentSemanticMaskTests|PhotosSemanticMaskInteractionTests|PhotosMaskWorkflowTests|DevelopmentMaskEngineV3Tests|EditingMaskCanvasOwnershipTests'
```

真实样片里的识别值没有人工逐像素边界标注。选区边界质量另参考独立标注集试验，水面和天空均保留人工复核，其他风景类别、负点和人体部位留在实验环节。[标注与质量分项](../030-ai-retouching/mask-validation.md)
