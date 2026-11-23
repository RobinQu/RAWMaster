# 031 · 统一滤镜目录交付

2026-11-22 · [规格](spec.md) · [摄影工作台](../../docs/ui/prototype/index.html#edit/development)

左栏使用文字目录浏览 Adaptive、胶片模拟、Imported 与基础滤镜。悬停和键盘聚焦使用原主图预览，离开恢复已采用效果。原片、旧滤镜收藏、快照和历史按原 ID 读取。目录加载、搜索及收藏均走元数据。Lightroom／Camera Raw 导入从滤镜标题下「导入预设…」选择 XMP 或 ZIP，显示原字段、依赖和冲突后入库。

## 一次性迁移

冻结批次实机核验并入库 78 份 XMP，共 1,881,440 字节。72 项可浏览，6 项为隐藏 Look。工程命令重跑新增 0 项，80 个目录文件字节相同，78 份源文件 SHA-256 逐项相同。应用安装包使用自有资源与规则。Adobe 原始 XMP 留在本机预设库。跨机器安装时可使用同一冻结清单验证当地原件。[冻结清单](contracts/migration-manifest-v1.json) · [迁移及真实散景回执](evidence/frozen-exchange/receipt.json)

从仓库根目录执行预检。需要把经过核对的文件入库时增加 `--apply`。计划和结果以 JSON 输出。暂存验证可用 `--catalog <目录>` 隔离于本机正式预设库。

```sh
swift run RAWMasterDiagnostics --migrate-frozen-presets specs/031-preset-browser/contracts/migration-manifest-v1.json
```

| 原件 | 当前能力 |
| --- | --- |
| 53 份 Adobe Adaptive | 1 项直接重置散景，4 项逐图重建主体，5 项逐图重建天空，4 项可用本机深度及主体焦距近似。39 项保留原字段和依赖供检查 |
| 25 份用户 ImportedSettings | 7 项可确认后采用已映射全局字段，12 项供检查，6 项隐藏 Look 供引用。原件依赖含 12 条内部 Look、1 条缺少外部 Look、6 条相机基底 |

38 份语义原件逐项检查，反选背景为 0。8 份风光原件同时包含水面和 6–7 个其他校正，需要同时复现多个语义层和局部字段。自适应配置文件、Adobe 景深曲线与复杂人物部位仍按条目说明。四款圆形散景使用本机算子近似，实照回放与 4000 × 6000 TIFF16 已验证。[兼容性及实照证据](evidence/frozen-exchange/receipt.json)

## Spektrafilm

Portra 400／Portra Endura、Velvia 100 及 VISION3 250D／2383 从固定 upstream revision 的原始光谱数据烘焙为 64³ RGBA Float32 表，在原生色彩图内按强度混合。三款的人像和雪景共六组实拍对照，原生 Metal 相对独立光谱参考的 RGB8 P99 差均为 1，最大为 2。来源、署名及资产许可随应用资源交付。[实拍与数值](evidence/spektrafilm/) · [烘焙脚本](../../scripts/bake-spektrafilm-filters.py)

## 走查与发布条件

- 工作台走查目录三组、无候选缩略图、Lightroom／Camera Raw 导入入口、主图悬停、键盘和采用后恢复。原生窗口测试覆盖搜索、同时展示 AI 蒙版、取消未完成的 Adobe 选区准备并重开。
- 既有普通预设同字段对照的窗口性能门继续跟踪。完整 Adobe 成片对拍、Lightroom Classic 实机回读、VoiceOver 和摄影师体验样本单列验收。[历史集成实测](integration-validation.md) · [完整验收条件](validation.md)
