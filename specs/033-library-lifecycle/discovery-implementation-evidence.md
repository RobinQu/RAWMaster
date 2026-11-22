# 本地智能检索与跨库查询实施验证

本文记录首版发布时的 SFace 及画面检索基线。当前人脸模型、升级兼容与复跑入口见[跨日期、跨机身的人脸检索](face-retrieval-upgrade.md)。

2026-11-22，在 Apple M4 Max、128 GiB、macOS 27.0.1 上验证了 Rust 资料库核心、Swift 原生调用与已打包的离线推理进程。已有实拍照片通过引用导入，运行过程使用本地 JPEG 或由 RAW 制作的代理。本文记录阶段三的实现与质量边界。阶段一的 1,265 张序列压力基线和候选算法比较另见[技术调研](retrieval-research.md)。

## 中文按画面检索

生产模型使用 Google SigLIP2 Base/16 固定源版本，导出图像和文本两座 ONNX 编码器。权重以 FP16 储存，算子在 CPU 上以 FP32 执行。图像按 EXIF 方向转正并按模型配置处理，文本以原始中文句子输入，得到的 768 维向量归一化后作精确点积。结果同时返回模型、作品输入版本、可检索范围、缺失数和下一页游标。[固定权重及预处理摘要](../../Modules/LibraryCatalog/Swift/Resources/discovery/models.json) · [导出程序](../../Modules/LibraryCatalog/Tools/convert-discovery-model.py)

独立于早期调研与导出校准的 12 个拍摄事件共选 24 张。先目视冻结 10 条有匹配照片的中文描述、3 条无匹配描述及对应照片，再比较官方模型与三个 ONNX 版本。相邻帧一直留在同一事件。此次目视判断由本轮调研者完成。[匿名样本、照片摘要及冻结标签](evidence/discovery-heldout-cases.json) · [逐查询排名、分数和数值误差](evidence/discovery-scene-validation.json)

| 24 张照片、10 条有匹配的描述 | 首位命中 | mAP | Recall@5 | 图像／文本与官方向量的最低余弦 |
| --- | ---: | ---: | ---: | --- |
| 生产 FP16 权重 | 10/10 | 0.9833 | 1.000 | 0.999996 / 0.9999996 |
| 对照动态 INT8 | 6/10 | 0.6923 | 0.750 | 0.5663 / 0.8732 |

默认画面阈值 0.07 拒绝了 3 条无匹配描述中的 2 条。“摆满书的室内图书馆”把木质放射状屋顶排在首位，分数 0.07378。结构化测试独立核对人物、围栏、评分和画面排序的交集。当前现有实拍集对“红色雨伞”仅有无匹配的标注，湿地、特定人物、四星及以上与红伞同现的实拍正例仍待核验。[画面质量复测程序](../../Modules/LibraryCatalog/Tools/validate-discovery-model.py) · [组合条件回归](../../Modules/LibraryCatalog/tests/discovery.rs)

## 人物复核

取一份 Lightroom 冻结快照，只使用用户明确确认且未拒绝的人物框。67 份原片的 EXIF 拍摄日时均与目录对应，涉及 10 个拍摄日、5 种机型和 3 个匿名人物。73 个人工框中，YuNet 产生 72 个检测框，有 61 个人工框在 IoU ≥0.35 时与检测结果唯一对应，12 个漏检或无法唯一对应。17,772 条未经人工确认的候选关联未用于计算身份真值。框坐标方向的校准与身份相似度试验分别留出了拍摄日。[数据口径和逐阈值结果](evidence/discovery-faces-validation.json) · [只读复测程序](../../Modules/LibraryCatalog/Tools/validate-discovery-faces.py)

| SFace 余弦 ≥0.80，按不同原片配对 | 同人对中被建议匹配 | 异人对中被错误匹配 |
| --- | ---: | ---: |
| 全部 61 个可比较人工框 | 69/690 | 0/1,137 |
| 五日审计样本 | 43/118 | 0/259 |
| 审计样本中同时跨拍摄日、跨机型 | 0/41 | 0/178 |

此前预置的 0.50 阈值在 1,137 对异人中误联 27 对。五日校准选出的 0.60 阈值在另五日仍误联 7/259 对。首版为人工复核建议采用整体敏感性分析后的 0.80，每一候选组的成员均需满足两两相似度。这个阈值已参考审计数据，下一轮应在另一批有人工确认的拍摄事件中独立复核。跨日跨机型召回仍不足以作为身份自动判定的依据。界面保留未知人物，按人物检索使用人工确认记录。确认、拆分、拒绝、合并与撤销在权威库，模型特征可独立重建。[候选组和人工记录](../../Modules/LibraryCatalog/src/discovery/people.rs)

## 离线运行与覆盖

- Swift 通过 Rust 接口领取带内容版本和租约的作业，校验受管源内容或已验证代理，生成最长边 1024 的 JPEG，再交给本机推理进程。索引任务可暂停、恢复、重试与重建。模型缓存切换新代保留已有文件，损坏或外来内容不会丢失。机器观察、可重建向量和人工确认各自关联模型及输入版本。[作业与缓存](../../Modules/LibraryCatalog/src/discovery/jobs.rs) · [Swift 本地 worker](../../Modules/LibraryCatalog/Swift/LibraryDiscoveryWorker.swift)
- 一份全新 v8 测试库实际纳入两张 JPEG 和两份 RAW，首次运行完成 8/8 个画面与人脸作业，4 张覆盖齐全，检测到 1 个脸框。查询“人用手喂驯鹿”首位命中标注照片，叠加排除性的评分条件返回 0 张。代理制作、校验和两类推理共 2.43 秒。冷态第一个文本请求含 tokenizer、文本推理与目录查询，共 1.20 秒。原片移走后仍可读取校验通过的 192,689 字节代理。这是同台机器一次端到端观测，不能代替界面首屏或长期吞吐统计。[原生调用结果](evidence/discovery-native-validation.json) · [复测入口](../../Modules/LibraryCatalog/Tools/validate-discovery-native.py)
- 圆和多边形使用空间索引缩减候选，随后按精确几何规则核对。测试包含凹多边形、日期变更线、极区、边界、无坐标、改坐标以及清空坐标后的查询。发现旧索引水位时，使用当前坐标得到结果。人物、范围、元数据与评分均先限定候选。[几何实现](../../Modules/LibraryCatalog/src/discovery/geometry.rs) · [围栏实拍目录基线](evidence/geofence-baseline.json)
- 发布包文件合计约 1.045 GiB，随附 CPython 3.12.11、ONNX Runtime 1.23.2、OpenCV 4.12.0.88 和固定权重。构建时核实模型 SHA-256 及已安装发行包的文件完整性。库的索引范围和作业可在没有模型包时查询，模型缺失会在本机索引页显示。已测设备为 macOS arm64、CPU 两线程。Linux、Core ML 和 GPU 推理另行验证。[离线打包工具](../../Modules/LibraryCatalog/Tools/package-discovery-runtime.py) · [依赖锁及许可证](../../Modules/LibraryCatalog/Swift/Resources/discovery/NOTICE.txt)

## 跨库只读查询

在“智能检索 → 跨库检索”勾选目录或资料库包。每份资料库可分别选择已授权的人物或已保存围栏，当前项目条件仅在当前目录生效。每个来源分别显示 libraryID、目录水位、包代次、作品和输入版本、命中与可用语义覆盖。外部来源使用 macOS 只读安全书签；备份包在添加及底层文件发生变化时验证目录摘要。[跨库浏览入口](../../Modules/LibraryCatalog/Swift/LibraryDiscoveryLibraryPicker.swift) · [查询协调及书签](../../Modules/LibraryCatalog/Swift/LibraryDiscoveryFederation.swift)

验证使用两份分别建立并确实纳入摄影文件的 v8 资料库，一份为 4 张活库，另一份为 3 张的仅目录备份包。相同文件名与相同 workID 各命中 1 张，覆盖各为 4/4、0/3。源 B 关闭人物功能，来自源 A 的人物条件被拒绝，B 自己的人物查询也遵守本库授权。勾选变化后迟到的另一库结果被丢弃。单库离线时另一库继续返回结果；重连恢复原代次。同长异内容的备份目录被拒绝，查询过程没有在备份包创建向量库。原输入与包在恢复故障夹具后逐字节核对一致。[带隔离故障的回归结果](evidence/discovery-federation-validation.json) · [两库复测入口](../../Modules/LibraryCatalog/Tools/validate-discovery-federation.py)

## 复测入口

1. 用固定的 Google 源权重运行 `convert-discovery-model.py`，并准备清单指定的 tokenizer、预处理、YuNet 与 Intel 0095 ONNX。复跑首版 SFace 数字时，使用独立的比较程序和首版 SFace 权重。运行 `package-discovery-runtime.py --python <独立解释器> --models <权重目录> --output <新目录>/LibraryDiscovery`。可将成品放入应用 Resources 或本机 Application Support/RAWMaster，运行时按清单校验模型。[上游来源与授权](../../Modules/LibraryCatalog/Swift/Resources/discovery/NOTICE.txt)
2. 以 `validate-discovery-model.py --help`、`validate-discovery-faces.py --help` 和 `validate-discovery-native.py --help` 查看本地输入约定。成对的跨库夹具分别用同一语义正例和控制图创建 4 张与 3 张的新目录，再将两份 scratch、运行包与新的输出目录传给 `validate-discovery-federation.py`。私人原片、目录、人名、脸框、向量与联系表留在本机，只提交匿名照片代号和汇总数。
3. Rust 专项可在模块所在仓库运行 `cargo test --locked --offline -j1 --manifest-path Modules/LibraryCatalog/Cargo.toml --test query_pages --test query_organization --test discovery`。本次共通过 20 项，其中目录分页与重建 9 项、作品与组织 6 项、地理及智能检索 5 项。
