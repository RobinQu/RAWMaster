# 跨日期、跨机身的人脸检索

RawMaster 将人脸编码器升级为 Intel Open Model Zoo 的 face-reidentification-retail-0095。在「智能检索 → 人物复核」中，选中一个已经确认的人物即可查找相似人脸，查看来源照片和脸框，再确认或排除候选。常规人物过滤只读取人工确认记录。

67 张现有原片提供了 73 个人工确认框，涉及 3 人、10 个拍摄日。通过原件 EXIF 的内部序列号或机身序列字段确认了 4 台机身。YuNet 的 72 个检测框中有 61 个能与人工框一对一关联。未检出和几何歧义的 12 个真值框计入端到端召回。除模型卡规定的对齐尺寸、颜色和归一化外，各模型使用同一份正向代理及冻结的检测记录。[对照数据与复跑入口](evidence/face-retrieval-upgrade.json) · [制品和几何等价验证](face-encoder-distribution.md)

## 选型

下表使用同一批跨拍摄日且不同物理机身的配对测试。候选检索均采用最多八张参考、同一套排名与复核门槛。公开模型分数不共用概率含义，表中的统一门槛复演用于观察在发行操作点附近的取舍。报告另记录各模型独立校准的对照和不同门槛下的误配。

| 候选 | 跨日跨机身配对 AUROC | 已有同人参考时，正确候选 | 移除本人参考后的误报 | CPU 单脸 P50 | 权重或推理文件 |
| --- | ---: | ---: | ---: | ---: | ---: |
| SFace | 0.9898 | 20/34 | 0/38 | 9.1 ms | 38.7 MB |
| InsightFace buffalo_l | 0.9922 | 24/34 | 0/38 | 70.4 ms | 174.4 MB |
| InsightFace antelopev2 | 0.9916 | 26/34 | 0/38 | 133.5 ms | 260.7 MB |
| FaRL ep64，对齐裁切 | 0.8673 | 20/34 | 9/38 | 32.6 ms | 652.2 MB |
| dlib ResNet29，余弦 | 0.9658 | 7/34 | 8/38 | 4.4 ms | 22.5 MB（另需关键点模型） |
| **Intel 0095 ONNX** | **0.9949** | **24/34** | **0/38** | **8.0 ms** | **4.47 MB** |

Intel 与系列中更重的 InsightFace 模型接近，同时在现有本地运行时中保持较小的制品和耗时。SFace 仍是有意义的对照，它在同一复核规则下查回 20/34，上一版产品的 0.80 门槛为 0/34。FaRL 原始视觉编码器在此处用作描述性对照，官方的主要验证场景是通用脸部理解。公开 InsightFace 权重限非商业研究，FaRL 研究权重未用于交付。Intel 的模型清单明确列出对应权重的 Apache-2.0 许可。[InsightFace 权重条款](https://github.com/deepinsight/insightface/blob/master/python-package/docs/model_zoo.md) · [FaRL 上游](https://github.com/FacePerceiver/FaRL) · [Intel 权重清单](https://github.com/openvinotoolkit/open_model_zoo/blob/master/models/intel/face-reidentification-retail-0095/model.yml)

## 匹配行为

- 用本库已确认人脸作为参考。每人至多选择八个有代表性的拍摄，先选清晰的脸，再选覆盖不同外观的脸。共享内容、RAW+JPEG 同一拍摄及虚拟副本共用一份参考资格。同一拍摄的原片也不会作为自己的候选。
- 以同一人物两张得分最高的参考照的平均余弦排序，只有一张可用参考时使用该分数。候选需达到 0.62，并领先第二位人物至少 0.08。只有一位可比较人物时使用 0.66。候选列表按选定资料库范围查询，已确认的其他人物、被排除的相似候选及无可用特征的脸不会被认定为匹配。
- 平衡留出在跨日且不同机身的 34 个有参考探针中找到 24 个，0 个错人，10 个弃权。在较早拍摄日作参考的压力回放中找到 14/29，0 个错人。移除查询对象参考后的模拟误配分别为 0/38、0/48。不限机身的跨日平衡留出仍有 1 个错人。两种拆分共享部分拍摄日，门槛在这批样本上定稿，三个已登记人物的结果无法估计陌生人物或大图库的误报。少数双参考来自一分钟内的相邻拍摄。
- 未命名脸分组保留更严的分组规则。跨日期查找从某个已确认人物开始，检索候选须人工确认才进入人物过滤。

新版 256 维特征使用独立模型标识。旧模型作业和向量不会计入新版覆盖。首次开启时按原有同意状态重新索引。旧人工确认、拒绝、名称和撤销仍存于原库。只有能核实同一作品输入版本及唯一脸框的旧确认才会用于新版向量匹配。旧模型包仍可处理画面索引和读取已确认的人物关系。

## 性能与验证

固定发行包在 Apple Silicon 上的单脸推理 P50/P95 为 7.98/8.16 ms，含五点对齐为 8.11/8.31 ms。经 67 张相同代理做端到端子进程对照，含读图、校验、检测、编码和 IPC 的 P50/P95 由 SFace 的 22.87/31.96 ms 降到 21.34/30.37 ms。性能数字有各自的测量边界。[模型与真实宿主数据](evidence/face-retrieval-upgrade.json)

正式 Swift 流程用 2 张原始 RAW 和由其余 65 张原片生成的代理导入资料库，67 项人脸作业约 3 秒完成。实际应用使用完整已确认图库，跨日、跨机身的 34 个有参考目标中仍查回 24 个。三个按人查询各约 7 ms。在该次不限机身的产品路径上，复核列表有 1 张已标注的误配和 3 张无可对账真值的脸。确认后才进入已确认结果，撤销后从中移除。排除、关闭人脸、旧模型未更新仍可查画面的测试均通过。

最终 Release 应用通过签名校验，在已有 v7 库的副本上启动可见窗口并建立 v8 网格索引。实际应用包内加载 Intel 权重，生成 256 维人脸特征，同时通过 768 维画面搜索模型的本机运行测试。[应用包验证](evidence/face-retrieval-upgrade.json)

实拍复跑分为两个入口。先由 `prepare-face-benchmark.py` 生成私有夹具，再用 `compare-face-retrieval.py` 复演同一批向量、库模板和留出。`--native-fixture` 输出只在本机使用，含原片路径与脸框。真实 Release 测试导入夹具后运行正式 Swift 子进程、Rust 事务和人物候选查询。[裁切与真值](../../Modules/LibraryCatalog/Tools/prepare-face-benchmark.py) · [比较脚本](../../Modules/LibraryCatalog/Tools/compare-face-retrieval.py) · [InsightFace 和 FaRL 研究执行器](../../experiments/library-lifecycle/compare-face-research-weights.py) · [官方制品来源](evidence/face-research-provenance.json) · [真实应用链路](../../Tests/RAWMasterUITests/FaceRetrievalRealTests.swift)

~~~sh
RAWMASTER_FACE_RETRIEVAL_FIXTURE="$PRIVATE_FIXTURE" \
RAWMASTER_FACE_RETRIEVAL_PACK="$MODEL_PACK" \
RAWMASTER_FACE_RETRIEVAL_REPORT="$NEW_REPORT" \
swift test -c release --filter FaceRetrievalRealTests
~~~
