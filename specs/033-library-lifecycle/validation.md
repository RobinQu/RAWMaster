# 033 · 现有照片的回归与性能基线

阶段一至三的产品实测、窗口首屏、完整备份排除和五库迁入对账见[交付验收](delivery-validation.md)。下文保留技术选型时的测量和基线，便于比较。

2026-11-22 · Apple M4 Max，128 GiB 内存，macOS 27.0.1，arm64。基准使用本机已有目录、原片和仓库里的实拍代理。工作树以 `b89702e8714fd0fd23c809474e0fe581c613cb3b` 为基点，测量时冻结了当时的源文件，查询报告另存实际参与构建的核心源文件摘要。结果按各自的数据集解释，Lightroom 的多个历史目录可能包含相同照片，不累计为独立资产。[原始汇总](evidence/catalog-baseline.json) · [检索输入清单](../../experiments/library-lifecycle/retrieval-cases.json)

## 现有 RAWMaster 目录

以 SQLite 只读连接及 Online Backup 取得含已提交 WAL 的一致副本。只在独立目录中使用正式 `LibraryStore` 打开副本。schema v7 包含 6,928 个文件记录、7 个项目、7 个导入会话、49 个组和 587 个成员关系，1,408 个文件已纳入四个项目。该库已确认的双格式配对为 0，用户标签为 0。1 个文件为五星，其他纳入文件均为零星。因此评分、标签和配对的极端分布不能代表其他摄影师。

用 Swift 6.4 release 和正式 `LibrarySnapshot.read` 读取，Store 打开耗时 44.884 ms，首次完整快照读取 236.229 ms，后续 9 次 P50／P95 为 235.844／236.505 ms。首次测量未清空操作系统页缓存。随后使用正式排序、规范化和 `AssetSearchEngine` 过滤。对同一批已纳入文件建立独立的 B-tree + FTS5 trigram 投影，Python 3.9.6，SQLite 3.54.0，建索引和统计共 7.431 ms，库文件 430,080 B。计时从已有投影行开始，未计入首次 Swift 快照和行提取。

| 查询，均按拍摄时间降序 | 文件数 | 常驻 Swift 返回全部匹配 P95 | SQLite 首 60 行＋精确总数 P95 |
| --- | ---: | ---: | ---: |
| 所有已纳入文件 | 1,408 | 4.4524 ms | 0.0453 ms |
| 样本机型，时间在纳入文件中位数之后（含） | 704 | 5.9391 ms | 0.0491 ms |
| 四星以上（含） | 1 | 0.3487 ms | 0.0972 ms |
| 文件名包含从实拍文件取出的三字符子串 | 1 | 1.6367 ms | 0.0367 ms |

每项 31 次温态测量，P95 取最近秩。另用复合游标读完每一页，对全部有序 ID 和总数做相等断言，四项均通过。计时两列返回的工作量不同。实验说明数据库可为网格取较少的数据。真实窗口的输入调度、列计数、缩略图和绘制仍要单列。这里的四个谓词不足以证明全部搜索规则等价。[Swift 测量入口](../../experiments/library-lifecycle/catalog_baseline.swift) · [投影、查询计划与对账](../../experiments/library-lifecycle/catalog_baseline.py) · [分位数和执行计划](evidence/catalog-baseline.json)

**边导入边读取。** 另在原生 debug 测试构建中，以同一份 v7 快照的新副本独立跑 4 轮，每轮通过正常的会话入口、运行时元数据和分组回调引用导入同一批 6 张实拍 RAW。读写共用一个正式 `LibraryStore`。每次读完整 `LibrarySnapshot` 后筛选四星以上，完成后间隔 80 ms 再读。空闲期 20 次 P50／P95 为 622.019／643.538 ms，导入期间完整结束的 18 次为 637.368／835.155 ms，各次均命中 1 个文件。四轮导入分别耗时 3.735、3.044、3.279、3.871 秒。这组数可在相同 debug 配置下复测，不能与上表 release 计时作速度比。测试按“读完再等”的方式取样，尚未包含用户输入排队或网格绘制。[并发探针](../../experiments/library-lifecycle/CatalogDuringImportProbe.swift) · [每次采样](evidence/concurrent-import-baseline.json)

## 文件、导入与分组回归

从现有外置盘取连续六张 Sony ARW 的只读测试副本，共 423,075,840 B。核对六份副本和源盘文件的 SHA-256，测试后再次核对原文件修改时间。运行已有目录、搬迁、初筛、项目复核、分组、延时和相关 UI 模型测试，共 100 项，0 失败、0 跳过，测试体总计 15.597 s。常规功能回归内含已有的小型或合成夹具。下表的媒体性能只计实拍文件。[定向回归结果](evidence/real-regression.json)

| 既有测试／探针 | 实际执行与结论 |
| --- | --- |
| 六张 RAW 引用导入 | 含自动分组回调 1.703 s。登记 6 个文件、0 个正式组，诊断为该六帧证据不足。均读到 Sony AF 点选择、区域尺寸和位置字段。叠加坐标准确性和主体清晰度另需人工复核 |
| 六帧延时 | 实际编码并解码读回两段 H.264，各 6 帧、0.2 s，预览 960 × 540、正片 1920 × 1080。完整测试 11.710 s，包含哈希核对、两次渲染和读回。派生作品回库仍属阶段三 |
| HDR 与全景 | 三张实拍包围曝光的两组线性响应倍率为 3.967 和 3.989，理论值均为 4。另一个五档组验证短曝／长曝可覆盖中曝饱和／低信号区域。第三组三张原片的 640 像素代理全部参与，得到 863 × 451 全景。全尺寸融合、运动去鬼影和星轨画质仍待验收。[实拍源组、依赖与复跑命令](group-processing-research.md) · [正例与无重叠对照结果](evidence/group-baseline.json) |

冻结工作树的全测试目标构建在成像测试夹具 `PairedPhotoOperatorRecipes.swift` 第 90 行遇到 `Double` 传给 `Float` 的编译错误。为了取得本专项的回归结果，仅在临时源码副本将成像测试目标的源文件限定为 `RuntimeSequenceMetadataTests.swift` 和 `TimelapseRendererTests.swift`，其余有关测试目标和产品源保持原样。100 项是这次筛选的结果，归档、迁移和新增算子的产品验收见[后续任务](tasks.md)。[现有导入测试](../../Tests/RAWMasterImagingTests/RuntimeSequenceMetadataTests.swift) · [现有渲染测试](../../Tests/RAWMasterImagingTests/TimelapseRendererTests.swift)

## Lightroom 迁移盘点与空间索引

五份真实 Classic 目录按文件长度排序，在私有临时目录内分别对主目录及存在的预览数据库做只读一致备份。记录源图像与文件对象、虚拟副本、堆栈作用域、集合和显影行数。以 `ImageCacheEntry.imageId → Adobe_images.id_local` 找照片，再以 `uuid + digest → Pyramid` 找该照片对应的预览候选，不按文件名猜测。每份有预览的目录优先抽有候选的虚拟副本，共抽三项，按绑定到的层级实际解码 JPEG 并读回 PNG。脚本支持在该样本中观察到的独立 JPEG 层级及旧版 `AgHg` 打包层级，各自保留结果。[盘点脚本](../../experiments/library-lifecycle/lightroom_inventory.py) · [完整统计](evidence/lightroom-inventory.json) · [Adobe 预览提取说明](https://helpx.adobe.com/lightroom-classic/desktop/kb/extract-previews-for-lost-images-lightroom.html)

| Adobe_DBVersion | 源图像 / 虚拟副本 | 可关联预览候选（其中虚拟副本） | 抽样实际解码 |
| --- | ---: | ---: | --- |
| 1400000 | 2,342 / 2 | 118（0） | 3/3，独立 JPEG 层级 |
| 1300000，小目录 | 2,465 / 2 | 669（1） | 3/3，打包 `.lrprev` |
| 1200001 | 7,154 / 2 | 无相邻预览索引 | 未取样 |
| 1300000，大目录 | 9,053 / 3 | 无相邻预览索引 | 未取样 |
| 1504001 | 43,380 / 114 | 10,853（2） | 3/3，独立 JPEG 层级 |

最大目录中有 43,266 个文件对象、95 个集合类对象（含 10 个智能集合）、16,966 条集合成员、15,923 条文件夹堆栈成员和 2 条集合堆栈成员。五份目录均无失配的主片或文件外键。均有目录形式的 `.lrcat-data`。每库抽 24 个非空 Adobe 显影载荷，按原始字节写出再读回，120 次 SHA-256 核对通过。外观候选数量不代表已获相同历史渲染。源目录与缓存分别备份，修订绑定、缺项清单及整套依赖恢复仍需迁入器验收。正式迁移可要求 Lightroom 关闭或接受已冻结的目录包。[迁移规格](lightroom-migration.md)

同一最大目录有 10,960 个具有效 GPS 的图像，32,420 个无有效 GPS。在只读事务中提取原值，SQLite 3.53.4 内存 R-tree 对两种真实数据查询做候选剪枝，再按双精度原值精判。25 km 圆产生 5,102 个候选、3,833 个命中，31 次温态 P95 为 2.941 ms。含所选实拍坐标顶点的局部多边形产生 1,379 个候选、1,145 个命中，P95 为 1.366 ms。将索引结果和穷举结果按 ID 对账，两组均无差异。此处验证索引没有漏候选，坐标、围栏中心及个人地点未写入公开结果。跨经线与极区另有实现验收。[空间脚本](../../experiments/library-lifecycle/geofence_baseline.py) · [空间结果](evidence/geofence-baseline.json)

## 图文检索、人脸与可移植性

| 原型 | 实测 | 解释边界 |
| --- | --- | --- |
| 中文图文检索质量 | 53 张现有照片、11 条中文查询。Chinese-CLIP B/16 和 SigLIP2 B/16 的 Hit@1 均为 11/11，nDCG@5 分别为 0.976、1.000 | 标签在运行模型前目视冻结，有连拍近重复。需要按拍摄事件留出、独立复核。两种 Q8 均是第三方转换件，产品权重另做许可及浮点对照。[模型与许可](retrieval-research.md) · [各查询结果](evidence/retrieval-baseline.json) |
| SigLIP2 全量索引 | 1,265 张既有 JPEG，CPU 双线程，首建 78.73 s，约 16.1 张/s。重开重算文件摘要并命中全部向量 101.88 ms，0 次图像推理。全范围候选读取、精确排序 P95 各 3.169、0.222 ms | 首建含解码、哈希及分批 SQLite 提交，模型已预载。查询两段分开计时，另需文本编码和 UI。[完整实测](evidence/retrieval-index-baseline.json) |
| 人脸 | 目标窗口 11 个，负对照 40 张。YuNet+SFace 将长边从 640 改为 1024 后命中从 9/11 到 11/11，同组配对由 11/28 到 21/28。1024 档误并 0/17 | 加大输入是看到漏检后的探索复测。脸框命中、身份归组及人工确认各有自己的分母，17 对不足以证明生产误并率。[标注与人脸测量](retrieval-research.md) |
| Rust 与 C++／Swift | `rusqlite 0.40.1` 通过同一 C ABI 从 Swift 与 C++ 各读到 1,408 个纳入项和 1 个四星以上，均与 SQL 参照相符。空指针、非法评分、缺路径返回预期状态，未创建新库 | 本机 macOS arm64，用系统 SQLite 动态库。验证的是跨语言读取可行性。并发写入、稳定工具链与 Linux 同一数据夹具仍需实施。[ABI 汇总](evidence/ffi-probe.json) |

## 复现入口

从仓库根目录执行。事先将 `CATALOG` 指向允许只读的 RAWMaster 库，`LR_DIR` 指向已有 Classic 目录所在文件夹，`LR_CATALOG` 指向有 GPS 的单份目录。`SOURCE` 可用同一工作树的冻结副本。每轮使用新的工作目录，含个人文件名、坐标、目录副本、照片和模型的材料均留在忽略的本机输出目录。可传阅的汇总和证据在本规格的 `evidence/`。

```sh
mkdir -p output/library-033-research
RUN=$(mktemp -d "$PWD/output/library-033-research/replay-XXXXXX")
SOURCE=${SOURCE:-$PWD}
swift build --package-path "$SOURCE" --scratch-path "$RUN/build" --build-system native -c release --target RAWMasterCore
BIN=$(swift build --package-path "$SOURCE" --scratch-path "$RUN/build" --build-system native -c release --show-bin-path)
/usr/bin/python3 experiments/library-lifecycle/catalog_baseline.py --source "$SOURCE" --release "$BIN" --catalog "$CATALOG" --output "$RUN"
python3.13 experiments/library-lifecycle/lightroom_inventory.py --output "$RUN/lightroom.json" "$LR_DIR"/*.lrcat
python3 experiments/library-lifecycle/geofence_baseline.py --catalog "$LR_CATALOG" --output "$RUN/geo.json"
```

Lightroom 盘点的实测环境使用 Python 3.13.5／SQLite 3.49.1。两套客户端均以只读方式打开源文件。本机系统 SQLite 在部分旧 WAL 目录的只读打开步骤返回 `CANTOPEN`，上述 3.13 运行时可读取。正式迁移需保留 WAL 伴随文件及一致视图，按错误报告源状态。不得为读旧目录在用户源文件上强制 checkpoint 或切换 journal 模式。

ABI 复测时将 `INDEX` 指向上一条目录测量生成的 `query-*/index.sqlite`。两项程序的预期输出均为本次实库的两行计数。模型和分组合成的固定版本与命令分别在[检索专项](retrieval-research.md)及[分组专项](group-processing-research.md)。

```sh
PROBE="$PWD/experiments/library-lifecycle/ffi-probe"
cargo build --manifest-path "$PROBE/Cargo.toml" --locked --release --target-dir "$RUN/ffi"
clang++ -std=c++17 -I "$PROBE/include" "$PROBE/check.cpp" -L "$RUN/ffi/release" -lrm_catalog_probe -Wl,-rpath,"$RUN/ffi/release" -o "$RUN/check-cpp"
swiftc -O -I "$PROBE/include" "$PROBE/check.swift" -L "$RUN/ffi/release" -lrm_catalog_probe -Xlinker -rpath -Xlinker "$RUN/ffi/release" -o "$RUN/check-swift"
"$RUN/check-cpp" "$INDEX"
"$RUN/check-swift" "$INDEX"
```

实拍 XCTest 在私有源码副本中将 `RAWMASTER_RUNTIME_RAW_DIRECTORY` 和 `RAWMASTER_TIMELAPSE_RAW_SOURCE` 指向同一目录的六张已校验 RAW 副本，`RAWMASTER_RUNTIME_TOOL_ROOT` 指向应用包的 `Contents/Resources/MetadataTool`，`RAWMASTER_TIMELAPSE_RAW_OUTPUT` 指向单独的临时输出目录。使用原生 SwiftPM 的以下筛选表达式。完整版遇到的编译限制和临时成像测试目标范围见上。

```sh
swift test --package-path "$SOURCE" --build-system native --jobs 4 --filter 'LibraryCatalogTests|RelocationTests|TriageWorkflowTests|TriageWorkflowUITests|ProjectReviewTests|GroupEditingWorkflowTests|GroupPropertyCommandTests|TimelapseTests|testOptInActualRAWImportCallbackKeepsEveryFileAndSourcesUnchanged|testOptionalRealRAWPreviewAndFullReadback'
```

单独复跑并发实验时，将上面的研究文件 `CatalogDuringImportProbe.swift` 复制到**私有源码副本**的 `Tests/RAWMasterUITests/`。将 `RM_CATALOG_BACKUP` 指向经 Online Backup 取得、可独立开启的 v7 快照，`RM_CONCURRENT_REPORT` 指向尚不存在的 JSON 文件，保留上述真实 RAW 和元数据工具环境变量。用同一 `swift test` 命令将过滤器换成 `CatalogDuringImportProbe` 即可得到四轮完整读样本。它作为独立实验运行，不计入原有的 100 项。
