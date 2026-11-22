# 031 · 核验记录与发布验收

2026-11-22 · 清单与既有 PoC 已核对 · 新目录、互操作和用户测试待实现

## 已经核验的输入

从本机两个实际 Adobe 源目录只读打开清单中的文件，逐项复算 SHA-256 和长度。另运行已有研究校验器，独立检查研究副本、目标路径和引用。两次均得到 **78 个不同内容、1,881,440 字节、72 个可见条目**。此次固化的是原始清单的 84,038 字节 JSON。SHA-256 为 `a5e60e133e26b859539b1a14521f81a306907e0cbabb2243879b7720fd421f58`。仓库内的合同夹具只含元数据。[冻结清单](contracts/migration-manifest-v1.json) · [调研原件](../../output/lightroom-preset-research/migration-manifest-v1.json)

| 核验对象 | 结果 | 对实施的影响 |
| --- | --- | --- |
| 来源与类型 | 系统目录 53，用户目录当日 25。语义校正 38、Lens Blur 13、Adaptive Profile 2、普通预设 19、隐藏 Look 6 | 两个根采用不同选择规则。首次打开编辑器即可使用内置 Classic Filters，限定迁移由用户发起 |
| 普通预设依赖 | 19 个文件各有一条必要依赖。12 条指向 6 个内部 RNI Look，6 条声明 Camera Standard 或 Adobe Standard，1 条缺外部 Adobe Color | 19 个文件全部入库也不能直接判为 19 个完整可渲染。用独立自制 Basic XMP 验证首批读写，用这 19 个检验完整/部分/受阻的真实行为 |
| PV 与命名 | 此 78 项中缺省 PV 37、11.0 有 20、15.4 有 16、6.7 有 5。名称含 Adaptive 的 Leica Q3 是带 ISO 分支和外部 Look 的 Normal | PV 10.0 和未知值需另造自有样本。版本缺省时按字段和已验证适用范围分类。名称、`PresetType` 或单个标志都不足以决定渲染路径 |
| 派生分析标记 | 53 条条目级 `derivedAnalysis`，三类资源各有自己的依赖 | Reset Blur 仍按原清单登记，运行时以「只复位镜头模糊」的专门测试决定是否跳过分析。清单中的标志不能触发悬停推理 |

在仓库根执行以下只读核验。第一段核对固定元数据和原始引用。第二段需要带相应 Adobe 资源的机器，核对本机实际源文件。

```sh
python3 - <<'PY'
import hashlib, json
from collections import Counter
from pathlib import Path

fixture = Path("specs/031-preset-browser/contracts/migration-manifest-v1.json").read_bytes()
assert hashlib.sha256(fixture).hexdigest() == "a5e60e133e26b859539b1a14521f81a306907e0cbabb2243879b7720fd421f58"
entries = json.loads(fixture)["entries"]
by_id = {entry["id"]: entry for entry in entries}
assert len(by_id) == len(entries) == len({entry["sha256"] for entry in entries}) == 78
assert sum(entry["display"]["visible"] for entry in entries) == 72
assert sum(entry["bytes"] for entry in entries) == 1_881_440
deps = [d for entry in entries for d in entry["dependencies"]]
assert Counter(d["resolution"] for d in deps) == {"internal": 12, "missingExternal": 1, "rendererBaseRequired": 6, "generatePerPhoto": 53}
for d in deps:
    if d["resolution"] == "internal":
        target = by_id[d["targetID"]]
        assert target["uuid"] == d["uuid"] and target["capability"] == "staticLook"
print("78 个内容，72 个可见条目，12 条内部引用均闭合")
PY
```

```sh
python3 - <<'PY'
import hashlib, json
from pathlib import Path

m = json.loads(Path("specs/031-preset-browser/contracts/migration-manifest-v1.json").read_bytes())
roots = {k: (Path.home() / v["path"] if v["kind"] == "homeRelativePath" else Path(v["path"]))
         for k, v in m["sourceRoots"].items()}
for entry in m["entries"]:
    path = roots[entry["sourceRoot"]] / entry["sourceRelativePath"]
    content = path.read_bytes()
    assert len(content) == entry["bytes"] and hashlib.sha256(content).hexdigest() == entry["sha256"], path
print("两个实际源根的 78 项长度和 SHA 均匹配")
PY
```

## 已有 PoC 对排期的约束

| 证据与口径 | 已测结果 | 开放前仍需验证 |
| --- | --- | --- |
| 028，Sony 9504×6336，M4 Max，2400 px，Release | 暖 Service p50/p95 为 15.898/17.705 ms。真实 AppKit 提交至 draw 返回的 19 个暖样本为 27.367/34.061 ms。原十候选暖整组 p95 104.279 ms | 在真实窗口测 20/33 ms、物理键盘和 VoiceOver。新增目录测零候选任务以及与手调同口径的主图延迟。[028 原始验收](../028-filter-experience/validation.md) |
| 11 月 22 日真实 RAW 的原生成像回归，Engine API 口径 | 46 个操作首轮因 local-detail 中位数 50.68 ms 超过 50 ms 失败，复测为 48.93 ms 并通过。目标 HSL 两轮交互中位数各为 11.63/13.80 ms，交互/settled 的 p99 通道差均为 2/255 | 复用原生八色和现有回归样片。XMP 字段范围、Lightroom 还原和窗口性能需分别再测。[首轮](../../output/performance/targeted-hsl-release-gate-20261122/interactive-comparison.json) · [复测](../../output/performance/targeted-hsl-release-gate-repeat-20261122/interactive-comparison.json) |
| 027 独立服务，Sony 水鸟 RAW，2400×1600，数值取所链接 JSON 的同一次运行 | 从已有分析代理起算，主体冷建/快照命中 1580.28/1.77 ms。场景首类/共享概率 727.47/27.14 ms。对象首个提示/复用编码 1261.33/96.65 ms。独立套件 27 项通过 | 主工程点选到呈现、峰值 RSS、取消与资源回收、相同照片跨入口只算一次、全尺寸导出。服务处理时间不能用作画布帧时。[计时 JSON](../../experiments/MaskAI/Validation/Performance/performance-results.json) · [套件日志](../../experiments/MaskAI/Validation/final-suite.log) |
| 030 小样本与人工标注 | 12 张标注行人图的全人物平均 IoU 0.780。风光每类 4 张正样本的天空/水面/山体平均 IoU 为 0.822/0.956/0.343，另各有 4 张负样本 | 天空、水面先积累原尺寸 RAW 对照。山体和人物部位保留手工范围。逐类记录边界、空场误选、修边时间与盲评。[蒙版实测](../030-ai-retouching/mask-validation.md) |
| 030 图像编辑，两种任务、每模型三次 1024² | M4 Max 128 GiB 上 FLUX.3 Q8 独立 MLX 运行至 PNG 为 153.45–210.29 秒。北京 Seedream 5.5 从 HTTP 请求至解码落盘为 10.304–14.763 秒。两侧湖面清理可用，人像补光改动面部细节 | 普通风格与人像提亮走原生。两引擎仅供异步、可拒绝的清理候选，须在独立任务留出集通过后开放。[双模型效果与计时](../030-ai-retouching/research.md) |

## 待执行的发布矩阵

| 编号 | 样片、操作与留证 | 放行条件 |
| --- | --- | --- |
| V1 目录与可访问性 | 1,075 条本地元数据或同规模自制目录，含中文、重名和隐藏 Look。真实窗口搜、折叠、星标、快速交叉 hover、滚动、换片、关窗，记录请求计数、UI 录像、VoiceOver 和 Undo | 031 SC-01/02。目录注册的 `.filters` 请求 0，误采用与错片 0。普通胶片带滚动仍能出图 |
| V2 稀疏应用 | 带曝光、同组阴影、裁切、蒙版及旧六槽的照片，只应用显式零曝光。连续 Amount 0/25/50/100/25，再手改白平衡、撤销、切片 | 未选字段语义相同、两次 25 像素相同、Amount 0 恢复基线、手改保存，实际的每次采用/手势可一次撤销。Profile 和 Classic 强度独立 |
| V3 文件与参数 | 自制基础 XMP 及至少 20 个跨组代表文件。覆盖 PV 6.7/10.0/11.0/15.4/缺省/未知，RAW/JPEG、单色、SDR/HDR、ISO、外部依赖、sidecar、用户重名。将每个拟开放字段导回固定版本 Lightroom Classic，记录输入值、两端 UI 值与缺省字段 | 按文件、参数、行为、像素四栏记证。可应用子集严格回读，无可用字段则禁用采用。一次预览、点击、Undo、重开、XMP 重新写出都遵循相同的包含项 |
| V4 迁移与恢复 | 冻结样本全量，分别模拟一项缺失/更版、同时导入同文件、同 UUID 异 SHA、坏条目、取消、磁盘不足和重启，再添加一个用户 XMP 复扫 | 031 SC-04，源从未改写。首次、复跑、恢复、刷新和撤销批次分别有逐项回执。已有历史从自身冻结资产重放 |
| V5 主图与导出 | 同一 Sony 61MP RAW 和纵向 RAW、JPEG、SDR/HDR 样片。相同基线交替运行手调和预设，每种支持组合至少 30 次暖操作，另记冷启动、p50/p95、fallback、RAW 解码、资源释放 | 031 SC-02。原生固定滤镜保留 028 全尺寸对拍。自有稀疏调整在同一管线与等价手调逐像素一致。Adobe 像素等级须先冻结参考版本、机型/Profile、ICC、位深、误差度量与容差，再由独立 RAW 留出集验证 |
| V6 语义与纪实 | 同图左右两入口，双人互换位置、无天空、有倒影、缺模型、旋转/裁切及 12 张换光序列。模拟晚到返回、更新模型、失去预设库、离线重开导出 | 031 SC-05 和 030 SC-01/02/03/05。记录使用何种缓存、目标空集、每张采用或跳过。严格纪实内容改写执行数和越权上传数为 0 |
| V7 景深与 Profile | 对 Reset、五形状及 Swirl、设备深度与普通 RAW 分别拍焦外光斑/遮挡边缘。对相同 DNG 保存静态表、已有动态表重放、输出 SDR/HDR、Amount 端点与过范围样本 | 依实际通过的资源、输入、输出组合更新支持报告。某一路失败只回退该能力。在报告中分别记静态 Look、表重放、自研生成器和 DNG 回读的覆盖范围 |

QA 发布记录写清源与夹具 SHA、应用/解码器修订、设备及内存、输出配置、冷暖定义、样本数、原始结果、失败例、评审人与放行项。031 的功能测试在对应实现落地后执行。项目当前可以复现的是本页的清单核验与上表链接的既有实验。
