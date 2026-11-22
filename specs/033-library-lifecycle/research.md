# 033 · 目录、索引和可移植内核选型

2026-11-22 · 本次比较覆盖五种实际操作，包括边导入边浏览、给一批照片打分、重连卷、找回照片的不同版本，以及按描述或人物搜索。下列选择供前三阶段实施审阅。[实施顺序](plan.md) · [基线和复现](validation.md)

## 两款参考实现带来的决定

| 核查对象 | 可借鉴的实现 | RAWMaster 的取舍 |
| --- | --- | --- |
| LightFlow 公开构建 `20261111155800-2d41ab1` | 65 个同源资源的发布镜像、Rust／SQLite 持久化、受管文件与外部引用、可按需装载的模型。离线 Chromium 实际验证导入、搜索、重复导入与重开 | 改名可产生重复，相同名／长度／修改时间的不同字节又会被折叠。用快速属性找候选，归档／重连确认用全文件摘要。该版有 SQL 接口，但网格在 JS 内存里过滤。必须从实际网格验收分页。Lightroom 路径兜底会跳过虚拟副本，本产品按源对象 ID 和版本对账。[发布包与操作证据](lightflow-research.md) |
| AlcedoStudio 源码 `61d59bc` | C++／DuckDB 的目录、版本化缩略图缓存和按卷扫描。固定编辑快照后调用 Rust 推理组件。按模型键存向量，先缩搜索范围再精确排序 | 借用卷离线语义、输入版本和模型清单。首尾指纹适合发现潜在移动。包中仅有目录时，恢复报告须列出原片位置。上游中性短语校正和阈值依赖其模型与语料。本地先测未校正的余弦基准。People 蒙版与人物身份库有不同输入、输出与验收。[固定提交的调用链](alcedo-research.md) |

## 本地数据库与实现语言

**推荐 SQLite + Rust。** v7 目录和 SQLite Online Backup 已在项目中使用。现有网格的主要开销来自整库解码与物化，改数据库或改语言本身不会消除这条路径。真实目录上的原型先验证将过滤、排序、计数和游标分页推入 SQLite，四组查询全部有序 ID 与旧路径一致。常用字段采用关系列，来源文档和不透明显影资源保留原始载荷。枚举已纳入项、编辑或备份对权威库取一致读视图。[当前快照](../../Sources/RAWMaster/LibrarySnapshot.swift) · [现有查询](../../Sources/RAWMasterCore/AssetSearchEngine.swift) · [SQLite 游标比较](https://www.sqlite.org/rowvalue.html) · [备份 API](https://www.sqlite.org/backup.html)

| 方案 | 取舍依据 |
| --- | --- |
| Rust 内核，C ABI，Swift 调用 | 将事务、迁移、查询、清单、索引生成和作业状态机放在独立 Cargo 包内。Swift 调用分页、命令、取消、快照等批量接口，保留文件选择、权限书签和 UI。实测同一 Rust 动态库由 Swift 与 C++ 在 arm64 macOS 正确读回 1,408／1 个结果，链接系统 SQLite。正式工程使用稳定工具链、固定依赖、向后读写夹具和 Linux 的纯内核测试。目前只验证了本机 ABI 和只读 SQL。[实验代码](../../experiments/library-lifecycle/ffi-probe/Cargo.toml) · [Rust FFI](https://doc.rust-lang.org/nomicon/ffi.html) · [rusqlite](https://github.com/rusqlite/rusqlite) |
| C++ 目录内核 | 可用 RAII 封装 SQLite、编译为桌面及 Linux 原生库。已有成像库与 OpenCV 的接入成本低。也需设计对象寿命、异常、所有权、线程与 ABI 边界。当前读负载没有给两种语言分出胜负。推荐把 C++ 放在像素处理适配层，若团队工具链更适合 C++，同一套中立接口及数据夹具允许替换实现。[Swift C++ 互操作](https://www.swift.org/documentation/cxx-interop/) |
| 继续全 Swift／改用 DuckDB | Swift 可保留 UI 和参考读路径。将目录规则留在依赖 AppKit、Vision 或文件书签的实现里，增加未来移植面。DuckDB 在 AlcedoStudio 展示了分析列和精确向量查询。本项目已有事务目录、WAL 备份与小批编辑，替换权威库会增加迁移和一致性验证工作。独立离线分析仍可按需试用 DuckDB。[DuckDB 并发模型](https://duckdb.org/docs/stable/connect/concurrency) · [SQLite WAL](https://www.sqlite.org/wal.html) |

在 macOS 进程内只保留一套经过校验的 SQLite。Rust、Swift 和依赖扩展的 SQLite 加载方式应在打包时核对。启动检查实际 SQLite 版本及 FTS5、trigram、R-tree 能力。在不支持相应分词器的系统上，短文本／子串保留正确的回退查询，标明重建或升级条件。Linux 将来使用同一文件格式与案例验证。图像解码、文件权限和加速后端由适配器提供。[FTS5](https://www.sqlite.org/fts5.html) · [R-tree](https://www.sqlite.org/rtree.html)

## 结构化、空间与相似度索引

- **元数据。** 以查询谓词确定 B-tree 的顺序，如范围内的拍摄日期与稳定身份、机身和日期、集合和手动位置。保留缺值、单位、时区和原始文本。现有名字子串先规范化大小写和折音，再按实际语义复核，短于三字符的中文子串仍可查。FTS5 的词文档服务关键词、标题与说明。用户输入按字面转义，智能集合使用类型化规则树。真实样本中四星以上只有一条。查询计划实际使用时间索引扫描，不能据这次计时认定评分索引都有效。[目录查询原型](../../experiments/library-lifecycle/catalog_baseline.py) · [FTS5 子串索引](https://www.sqlite.org/fts5.html#the_trigram_tokenizer)
- **GPS。** 经纬度保留双精度原值，空间树只存候选包围盒。包含边界的最终谓词用原值计算，避免 R-tree 单精度近似决定真值。对现有 10,960 个有效点，用圆与多边形逐 ID 对比全扫。有 32,420 个无有效坐标的图像对象仍可单独检索。[空间测量](validation.md) · [SQLite 空间索引精度](https://www.sqlite.org/rtree.html#roundoff_error)
- **文搜图。** 图像与文字必须经同一模型族和预处理映射到共享空间。建议用 ONNX Runtime CPU 作可移植参照，另以相同输入对照 Core ML 加速。先按库、集合、人物、围栏等取合资格 ID，用归一化向量作精确点积。现有 1,265 张代理上精确搜索足以作正确性参照。SQL 读出候选向量的时间也要计入用户等待。标签检索和画面相似度在界面上可分别操作。[本地两模型实验与授权](retrieval-research.md)
- **向量存储与规模升级。** 第一版可用 SQLite BLOB（固定维度、元素类型和端序）加 Rust 批量点积。派生索引整代可重建。可选 `sqlite-vec` 将精确距离下推到 SQLite，须先验证部署、硬范围过滤和稳定分页。若实库测得精确检索超出交互预算，再用相同查询测 USearch/HNSW 或 Faiss 与精确 Top-K 的召回、冷启动、增删成本和索引大小。高选择性范围优先精确搜。近似候选不足时回退或扩候选，发布前始终复核过滤和删除。仅增加向量维度或增加媒体字节数都不足以触发切换。[sqlite-vec](https://github.com/asg017/sqlite-vec) · [USearch](https://github.com/unum-cloud/USearch) · [Faiss](https://github.com/facebookresearch/faiss)
- **人脸与连拍质量。** 人脸检测回答哪里有脸，脸向量提出可能的同一人，命名由用户确认。AF 点回答相机瞄准的位置，主体清晰度用实际像素及其来源评估。两条工作流独立，模型阈值、错误代价和人工修订各有记录。当前脸部小样提高输入分辨率能减少漏检，跨日身份和误并率仍需要独立标注。[脸部样本与误差](retrieval-research.md) · [清晰度与检查器](search.md)

## 保留和重建的成本

目录、人工决定、挂接到作品的文件、Adobe 原始配方和经验证的历史外观属于需恢复的数据。可重新计算的缩略图、结构化投影、机器向量和近似索引分开计量，并记录可用于重建的输入是否离线。冷照片可按有来源的 JPEG 代理查图。需要原片级清晰度或全质量渲染时检查原件可用性。恢复目录后可先打开元数据，随后补齐代理、原件及机器索引。选择完整归档时只枚举有资格的逻辑文件。[数据模型和恢复次序](data-model.md) · [逐文件归档资格](spec.md#每个导入原件的归档资格)
