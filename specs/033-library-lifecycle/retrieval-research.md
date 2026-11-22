# 资料库检索、图文向量与人物聚类技术调研

2026-11-22 · 供审阅的阶段二、三技术基线。建议先交付 SQLite 结构化筛选及文本检索，再用 SigLIP2 双编码器提供中文按画面找图。原片已纳入、用户已启用人物索引后，用 YuNet 检测和 SFace 特征生成可纠正的分组建议。现有 1,265 张照片可以用精确余弦排序，足以把它作为以后优化的正确性参照。[产品行为](search.md) · [小样实测](evidence/retrieval-baseline.json) · [整批索引实测](evidence/retrieval-index-baseline.json)

SFace 是首版对照。Release 31.4 使用 YuNet 五点对齐和 Intel 0095 的 256 维脸部向量，按模型版本重建建议索引，保留人工确认与排除。[跨日、跨机身复测](face-retrieval-upgrade.md)

## 实测素材与口径

- **检索质量**取仓库的六段实拍序列，每段沿既有顺序均匀取 8 张，再加已有的车辆、肖像、足球、山湖和雪景五张摄影夹具，共 53 张。11 条中文查询涵盖近似画面与单个目标。运行模型前，本次调研根据照片联系表目视标记相关照片、目标脸窗口及无人脸对照，冻结清单和 SHA-256。这些标签尚待独立摄影师复核。注释与结果只使用片段、帧代号和匿名分组。[冻结清单](../../experiments/library-lifecycle/retrieval-cases.json) · [实拍代理来源](../../docs/fixtures/sequence-grouping-schema-v1.md) · [五张夹具出处](../../experiments/MaskAI/Fixtures/Sources.md)
- **索引性能**取上述六段的全部 1,265 张现存 JPEG 代理，最长边 1024 像素，有 1,265 个不同文件哈希。全量照片用于索引与查询计时，相关性仍只在有标注的 53 张上评价。一个连拍内有许多近似帧，泛化评估需换用按拍摄事件隔离的留出集。
- **运行环境**为 Apple M4 Max、128 GiB、macOS 27.0.1。ONNX Runtime 1.23.2 明确选择 CPU EP，算子内 2 线程、算子间 1 线程。OpenCV 4.12 CPU 路径设 2 线程。Python 3.12.11，批量大小 1。每个编码器单列首张和剩余 52 张，文本暖态为剩余 10 条查询，各阶段单独计时。运行次序固定在同一台共享机器。此处记录单次运行分布，Core ML、GPU、Linux、实际 RAW 解码和前台 UI 时延另行测量。

## 选择文本和图像编码器

图像输入按 EXIF 方向转正、转 RGB，再严格按对应预处理配置重采样至 224 × 224、缩放及归一化。文本使用对应 tokenizer 的中文原句，SigLIP2 固定填充至 64 token。每个模型分别对池化图像、文本向量做 L2 归一，使用同模型的精确点积。Q8 指本轮 ONNX 权重量化，落库向量为 float32。

| 同一批 53 张 / 11 条中文查询 | Chinese-CLIP ViT-B/16 | SigLIP2 Base/16 |
| --- | ---: | ---: |
| 向量维度 / 每份向量 | 512 / 2,048 B | 768 / 3,072 B |
| 图像与文本 ONNX 文件合计，不含 tokenizer | 190.84 MB 原始联合图 | 377.99 MB 分离双塔 |
| tokenizer / 双塔会话初始化 | 4.63 / 133.96 ms | 350.95 / 152.33 ms |
| 首张 / 暖图编码 P50 / P95 | 54.84 / 54.51 / 55.03 ms | 56.51 / 56.64 / 57.25 ms |
| 中文分词与编码暖态 P50 / P95 | 4.14 / 6.11 ms | 17.19 / 17.37 ms |
| Hit@1 / 宏平均 AP / nDCG@5 | 11/11 / 0.984 / 0.976 | 11/11 / 0.993 / 1.000 |
| 宏平均 Recall@5 | 0.787 | 0.812 |

Hit@1 计算首图是否相关。AP 使用完整排名，nDCG@5 使用二值相关标签。部分查询有 8 个正样本，前五张最多覆盖其中 5 张。库内精确排序用于复核模型、缓存和候选过滤的变化。Chinese-CLIP 在倒影人物与暗地平线两条查询的前五张中混入其他场景，SigLIP2 在本组标注的前五名表现较好。此差异来自少量场景，只支持选择试用候选。[逐查询得分、各阶段分位数](evidence/retrieval-baseline.json)

**推荐以 SigLIP2 作为可移植基准，保留 Chinese-CLIP 作中文速度对照。** Google 原始模型卡标注 Apache-2.0，支持多语言图文嵌入。Chinese-CLIP 是专门的中文双塔，本文固定的官方代码使用 MIT 许可，所查官方权重卡及第三方转换卡未单列具体权重分发许可。两组实测都是第三方发布的 ONNX 转换件。产品打包前从选定原权重固定导出、tokenizer、量化和依赖清单，逐图／逐句比对向量与召回，保存再分发依据。Chinese-CLIP 联合图拆成独立双塔，本轮在首图与首句上同联合图的归一化向量最大绝对差为 0。原始浮点权重与 Q8 的误差仍需独立验证。[Google 权重及许可](https://huggingface.co/google/siglip2-base-patch16-224/tree/75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2) · [SigLIP2 论文](https://arxiv.org/abs/2502.14786) · [OFA 原始模型](https://huggingface.co/OFA-Sys/chinese-clip-vit-base-patch16/tree/36e679e65c2a2fead755ae21162091293ad37834) · [OFA 代码许可](https://github.com/OFA-Sys/Chinese-CLIP/blob/31863c707501bf1605d36842f43deb78793dbc5d/MIT-LICENSE.txt) · [SigLIP2 实测转换件](https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX/tree/ba1f3b0843f24bc5417d38e19c37b287d719b2f4) · [Chinese-CLIP 实测转换件](https://huggingface.co/Xenova/chinese-clip-vit-base-patch16/tree/f26904860903e70e050b8f48255e5f48401816e9)

## 增量索引与查询执行

全量实测使用 SigLIP2。在临时 SQLite 3.49.1 目录写入照片作用域和向量，唯一键由模型／预处理指纹及内容哈希组成，每 32 件提交。重开后重新读取全部 JPEG 字节、计算哈希、核对相应索引键。查询先用 SQL 选有资格的行，按稳定照片 ID 读取 BLOB 再评分。试验产物仅汇总统计，临时向量库在完成后清理。

| 现有数据上的操作 | 测量值 |
| --- | ---: |
| 1,265 张首建，含哈希、解码、预处理、图像编码及写入，模型预先加载 | 78.73 s，约 16.1 张/s |
| 单张预处理 P50 / P95，图像编码 P50 / P95 | 2.93 / 3.76 ms，56.61 / 59.50 ms |
| 重开后 1,265 件重新哈希及命中校验 | 101.88 ms，新增模型调用 0 次 |
| 向量净字节 / 含作用域表的 SQLite 文件 | 3,886,080 B / 5,681,152 B |
| 1,265 个候选，读取 BLOB / 精确排序 P95 | 3.169 / 0.222 ms |
| 同一条 SQL 限定为 38 个候选，读取 BLOB / 精确排序 P95 | 0.123 / 0.013 ms |

后两行各用 11 条已编码查询，分别统计两段耗时，排除文本编码、UI 和模型加载。下一步用同一数据、同一排序和同样的范围比较 Rust／C++ 实现。现有测量优先优化图像排队、预处理缓存和重复计算。若候选增多导致精确计算超预算，再在新增真实照片上比较 HNSW 的召回、候选读取、内存和重建成本，精确检索作为对照。[完整索引记录](evidence/retrieval-index-baseline.json) · [hnswlib 实现](https://github.com/nmslib/hnswlib)

阶段一只需在可移植数据层预留内容版本、派生资产／索引版本和任务状态。阶段二将库、项目、集合、导入纳入、GPS、日期、星级等硬条件下推到 SQL，在同一文件上求交。分层标签匹配保留规范化原值与等值索引，标题／说明按词查与子串查分开。SQLite FTS5 trigram 对不足三个 Unicode 字符的 MATCH 查询没有命中，中文常用的“湖”“雪山”必须另经标签等值或小范围子串路径验证。GPS 以 R*Tree 包围盒产生候选，再对圆形大地距离／多边形作精确判定。按地名输入与 GPS 缺失保留独立语义。[SQLite FTS5](https://sqlite.org/fts5.html) · [SQLite R*Tree](https://www.sqlite.org/rtree.html)

阶段三将查询范围与对应内容版本传给向量计算，严格按资格集评分。若采用近似索引，窄筛选仍要有精确候选回退。每项特征记录对象、输入内容／代理版本、裁切与方向规则、模型及预处理 SHA、维度和数据类型，文本向量另含 tokenizer 版本。索引按增量队列分批提交，启动后重试中断项，迟到的旧版结果只对应原修订。新模型使用新命名空间，切换前显示覆盖度。查询结果解释来自文件名、标签、人物、空间或画面。封存排除的原件不会因相似命中、配对或队列重试而进入项目或归档。

## 人脸检测、表征与聚类

首个基线沿用项目已有 YuNet 2023mar 模型，输出脸框、置信度与五个关键点。检测前等比缩小，坐标按轴映射回已校正方向的原分辨率照片，从该图对齐裁切到 SFace 的 112 × 112 输入，再生成 128 维单位向量。两者直接通过 OpenCV CPU API 调用。候选聚类以完整链接的最小两两余弦 ≥0.50 合并，分数相同时按输入顺序确定，单例保留。完整链接可避免仅因 A 接近 B、B 接近 C 就把差异很大的 A、C 连在一起，代价是姿态和分辨率变化可能拆开同一人物。此阈值是预置实验参数，产品阈值需另行标定。[OpenCV 检测与对齐／特征接口](https://docs.opencv.org/4.x/d0/dd4/tutorial_dnn_face.html) · [YuNet 文件与 MIT 许可](https://github.com/opencv/opencv_zoo/tree/48b10fa505aeb51fbd127fc60a5c660040e823b7/models/face_detection_yunet) · [SFace 文件与 Apache-2.0 许可](https://github.com/opencv/opencv_zoo/tree/48b10fa505aeb51fbd127fc60a5c660040e823b7/models/face_recognition_sface)

以 11 张照片预先指定的脸中心窗口作为检测目标，另有 40 张无可见人脸的对照。身份评估限于 10 个有匿名标签的目标，即同一连拍主体的 8 帧与两个不同摄影夹具的主体。已知同组配对 28 个、不同组配对 17 个，漏检也计入端到端漏配。F1 在检测真值内，但跨场景的身份未知。照片里的其他人、反射与人群背景没有穷尽标注，窗口命中不能换算成通用检测 AP。

| 同一 53 张照片 | 640 像素长边基线 | 1024 像素长边探索复测 |
| --- | ---: | ---: |
| 指定目标窗口命中 / 40 张对照内返回框数 | 9/11，0 | 11/11，0 |
| 同组配对找回 / 已知不同组误合并 | 11/28，0/17 | 21/28，0/17 |
| 缩放＋检测暖态 P50 / P95 | 7.13 / 8.26 ms | 9.41 / 10.71 ms |
| 单脸对齐＋编码 P50 / P95 | 9.65 / 14.80 ms | 8.92 / 13.39 ms |

长边 640 时漏掉 A2 与 F1。1024 档是在发现漏检后，保持置信度 0.90、NMS 0.30 及聚类阈值不变的一次同样本复测。640 档的 17 个不同组配对中有两对涉及漏检，能实际比较向量的是 15 对。1024 档可比较全部 17 对，即使检测到全部目标，仍漏掉 7 对已知同组关系。阶段三可让用户选择较高分辨率重扫低覆盖照片，并提供未知、确认、合并、拆分与撤销。人脸索引由库所有者开启，模型建议与人名、人工合并／排除约束分别保存。换模型后新观察通过照片内容版本和原图区域匹配，冲突交给用户。人物名称按已确认关联检索，跨连拍、年龄、机型、侧脸和多人同框需新的独立样本。[人脸结果与混淆计数](evidence/retrieval-baseline.json)

当前分组试验仅含 9 或 11 个检测框。产品全库复核可用近邻检索生成每脸少量候选，再逐对精算并执行人工限制。对图片检索与人物归类使用独立模型和索引。InsightFace 的代码与训练模型采用不同条款，其仓库明确标示所发布训练模型限非商业研究。可将算法作为对照，产品模型应逐权重核实授权。[InsightFace 许可声明](https://github.com/deepinsight/insightface/tree/c6c3af7bd2d0a0bf4b78c78437357f3521aa5d52#license)

## 可移植接口与后续验证

建议 Rust／C++ 核心接收预处理版本、定向像素和内容身份，返回带模型身份的向量或脸部观察。ORT C API 作为跨语言推理边界。OpenCV 负责已实测的 YuNet/SFace 对齐和推理，若统一迁到 ORT，应用同一批输入逐项对齐框、五点、裁切像素、向量和聚类。macOS 的 Core ML EP 与未来 Linux CPU／GPU 实现按同一接口描述支持算子、数值类型及回退原因。形状、量化算子和执行分区须实际验证。兼容交付以稳定内容／模型／作业版本和可重算的特征为依据。[ORT C API](https://onnxruntime.ai/docs/get-started/with-c.html) · [Core ML 执行提供器](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)

阶段三实现时应在用户现有的其他拍摄事件中冻结新的中文细粒度查询、近义词、未出现主题、两字关键词、人物与围栏交叉条件。重新给全体候选作相关性标注，按事件分组报告召回与误合并。在应用的后台导入、索引取消／重启、用户关闭人物索引及模型替换期间验证操作时延、可见范围和人工纠错。100 TB 或百万级模拟库未进入本轮试验。

## 复测

以下命令在仓库根目录运行。既有五张附加照片的来源与哈希见夹具清单，缺少时可使用仓库现有的[夹具获取脚本](../../experiments/MaskAI/Scripts/download-fixtures.sh)。`--prepare` 下载固定摘要的模型，随后两次运行在本地读取既有照片。中间向量不随报告保存。

```sh
uv venv --python 3.12 output/library-033-research/retrieval/venv
uv pip install --python output/library-033-research/retrieval/venv/bin/python onnxruntime==1.23.2 onnx==1.19.1 opencv-python-headless==4.12.0.88 numpy==2.2.6 pillow==11.3.0 tokenizers==0.22.1
output/library-033-research/retrieval/venv/bin/python experiments/library-lifecycle/retrieval_baseline.py --prepare
output/library-033-research/retrieval/venv/bin/python -W error experiments/library-lifecycle/retrieval_baseline.py
output/library-033-research/retrieval/venv/bin/python -W error experiments/library-lifecycle/retrieval_baseline.py --catalogue
```

脚本核对 53 个图像文件、配置及模型摘要。全量基线另有 1,265 个代理路径与内容哈希生成的总清单指纹。输出中保留分位数、逐查询得分、聚类计数和样本限制，以便比较下一次运行。[研究脚本](../../experiments/library-lifecycle/retrieval_baseline.py) · [冻结用例](../../experiments/library-lifecycle/retrieval-cases.json)
