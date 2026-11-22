# 本地人物编码器的权重来源与验证

Intel 发布的 `face-reidentification-retail-0095` 能由官方 FP32 权重重建为 4,466,624 字节的 ONNX，直接运行在 RAWMaster 现有的离线 ONNX Runtime 1.23.2。真实照片跨机身、跨拍摄日的相似度排序优于原 SFace。人物建议仍需用完整检索流程评价，因为高相似的错配也能排在第一位。[脱敏测量及文件摘要](evidence/face-encoder-distribution.json)

## 权重和训练来源

| 候选 | 权重证据及使用条件 | 可执行输入 |
| --- | --- | --- |
| Intel Open Model Zoo 0095 | 官方模型清单逐个列出 XML/BIN、大小、下载地址、摘要和 Apache-2.0 许可。发布仓另载明材料的使用须符合其人权承诺。模型卡报告 LFW 验证准确率 0.9947，未列出该权重的训练数据集。包随附上游许可、原始摘要和格式转换说明。[模型清单](https://github.com/openvinotoolkit/open_model_zoo/blob/2c9b5c563ab3a202d085a42e2bbfc48f77961f4b/models/intel/face-reidentification-retail-0095/model.yml) · [模型卡](https://github.com/openvinotoolkit/open_model_zoo/blob/2c9b5c563ab3a202d085a42e2bbfc48f77961f4b/models/intel/face-reidentification-retail-0095/README.md) · [发布条款](https://github.com/openvinotoolkit/open_model_zoo/tree/2c9b5c563ab3a202d085a42e2bbfc48f77961f4b) | MobileNetV2 派生网络，约 111 万参数。对正向图像上的五个点拟合无镜像的相似变换，映射到模型卡的 128 像素模板。BGR 顺序，FP32 NCHW，范围 0–255，输出 256 维，再作 L2 归一。 |
| Davis King dlib ResNet | 作者直接将其模型文件发布为 public domain。29 层模型自训，自述约 300 万脸、7,485 人，来源含 FaceScrub、VGG 和网络采集。用于对齐的五点模型也是其发布物，作者描述了自行标注的 7,198 个脸。原训练图像权利属于另一层材料。[作者的模型发布与训练说明](https://github.com/davisking/dlib-models/blob/fd81b6308a6a73d4ce08859eb2f4b628a21e27a2/README.md) · [原生用例](https://dlib.net/dnn_face_recognition_ex.cpp.html) | 使用同一 YuNet 边框，在 EXIF 转正的 RGB 代理上运行 dlib 五点模型。原生 `get_face_chip` 产出 150 × 150、padding 0.25 的输入。128 维，禁用随机抖动。原作者通过未归一向量的欧氏距离判断，实测另保留 0.6 阈值结果。 |
| Taguchi dlib ResNet | 作者的模型仓使用 MIT，版权声明指明模型作者。作者压缩包与 dlib 上游收录的另一种压缩包解压后逐字节相同。作者描述训练使用超过 650 万张脸、1.6 万人，来源包括公开数据集和网络照片；缺少逐数据集清单。[原作者的模型和训练说明](https://github.com/TaguchiModels/dlibModels/blob/17bafbffaa63aacea3de17f109d67ca9189ad88f/README_EN.md) · [许可](https://github.com/TaguchiModels/dlibModels/blob/17bafbffaa63aacea3de17f109d67ca9189ad88f/LICENSE.txt) | 与原生 dlib 使用同一五点处理、150 像素 RGB 输入和 128 维输出。需同时携带五点定位器。 |
| OpenCV Zoo SFace | 模型目录指定 Apache-2.0。OpenCV 成员在 INT8 权重商业使用的提问下援引该许可。FP32 2021dec 导出的精确训练检查点和数据集，模型目录未明确对应。当前钉住的 Zoo 人脸模块包括 YuNet 检测、EDiffIQA 质量评估及 SFace 识别。[官方模型目录](https://github.com/opencv/opencv_zoo/tree/48b10fa505aeb51fbd127fc60a5c660040e823b7/models) · [SFace 说明](https://github.com/opencv/opencv_zoo/tree/48b10fa505aeb51fbd127fc60a5c660040e823b7/models/face_recognition_sface) · [维护者关于 INT8 的回复](https://github.com/opencv/opencv_zoo/issues/318#issuecomment-5924130418) | 112 × 112 经 `FaceRecognizerSF.alignCrop` 对齐，128 维。用现有产品权重运行对照。 |
| Idiap EdgeFace | Idiap 的 XXS 和 S-Gamma 权重卡均明确采用 CC BY-NC-SA 4.0。论文描述用 WebFace260M 中的 WebFace 4M、12M 子集训练该系列。商业发行需要覆盖商业用途的额外权利。[XXS 权重卡](https://huggingface.co/Idiap/EdgeFace-XXS/tree/e710f4647ac4dde011c13f82224539d24800ab92) · [S-Gamma 权重卡](https://huggingface.co/Idiap/EdgeFace-S-GAMMA/tree/a1c171036159e94bd4c766088370a37d0899d31f) · [作者论文](https://arxiv.org/html/2307.01838) | 轻量 CNN/Transformer 混合网络。此次从发布方 LFS 清单记录两个权重摘要。 |
| DeepFace FaceNet 128、512 | DeepFace 模型仓写明转换权重继承原模型许可。其 TensorFlow 模块分别下载两个 H5；ONNX 后端另下载对应的两个导出。David Sandberg 的 TensorFlow 仓列出 `20180402-114759` 对应 VGGFace2、`20180408-102900` 对应 CASIA-WebFace，并要求注明训练数据来源。现有发布材料不足以将这四个 DeepFace 文件逐一绑定至具有明确商业分发授权的原始检查点。本轮仅记录发布者提供的 SHA。[DeepFace 权重许可说明](https://github.com/serengil/deepface_models/blob/b55240f7c4f9884f0e381bd02310d00e7d8de82b/README.md) · [TF 加载器](https://github.com/serengil/deepface/blob/8cec026045be164e14b510c55c1264e743dc4999/deepface/models/facial_recognition/tf/Facenet.py) · [ONNX 加载器](https://github.com/serengil/deepface/blob/8cec026045be164e14b510c55c1264e743dc4999/deepface/models/facial_recognition/onnx/Facenet.py) · [发布者文件](https://huggingface.co/serengil/deepface/tree/df8ced3a15155094d222d577e70fc3050c54ad8e) · [Sandberg 检查点表](https://github.com/davidsandberg/facenet/blob/096ed770f163957c1e56efa7feeb194773920f6e/README.md) | Inception-ResNet v1，160 × 160，分别输出 128、512 维。TensorFlow、PyTorch、ONNX 发行文件有独立的摘要。 |

另有 CMU OpenFace，项目声明同时覆盖代码及训练好的 Torch、Python 权重，许可为 Apache-2.0。其 96 像素默认模型以 FaceScrub 和 CASIA-WebFace 训练，使用外眼角及鼻的对齐方式。SeetaFace6 作者明确允许开放版用于商业产品，发布的是 TenniS 和 CSTA 模型。两者在本次资料库样本上均未跑分。[CMU 权重声明](https://github.com/cmusatyalab/openface/blob/99b7241a8748421e2c5e32ccf7581c08e513e79e/README.md#licensing) · [CMU 模型说明](https://github.com/cmusatyalab/openface/blob/99b7241a8748421e2c5e32ccf7581c08e513e79e/docs/models-and-accuracies.md) · [SeetaFace6 发布说明](https://github.com/seetafaceengine/SeetaFace6)

## 同一组实拍照片上的对照

67 份原片，10 个拍摄日，3 位匿名人物，4 个由设备序号核对的机身。73 个人工确认框中，61 个与 YuNet 唯一对应并生成向量，12 个没有可计分向量。按拍摄日划分参考集和留出集，保持人物分布尽可能均衡。下表取留出照片对参考照片、同时跨日且跨机身的 254 对同人和 445 对异人；AUC 描述成对排序，单人查询还受到参考数量、候选人物和弃答阈值影响。[基准程序](../../Modules/LibraryCatalog/Tools/compare-face-retrieval.py) · [候选实测数字](evidence/face-encoder-distribution.json)

| 编码器 | 维数 | 跨日、跨机身 AUC |
| --- | ---: | ---: |
| Intel 0095，已打包 ORT 1.23.2 | 256 | 0.994895 |
| Taguchi ResNet | 128 | 0.991940 |
| 现有 SFace | 128 | 0.989826 |
| dlib 原版 | 128 | 0.965832 |

原版 dlib 使用作者的 0.6 欧氏距离阈值时，跨日、跨机身且图库里有本人的 34 次查询中，27 次正确接纳、7 次弃答。移除本人后又出现 21 次错误接纳。由此可见，前一项的命中数不足以选择家庭图库的自动确认阈值。12 个未映射框仍纳入端到端查询覆盖的统计。真实检测样本没有五点裁切至图边的情况，退化几何须另用明确构造的用例检查。

## 制品和回归

Intel 官方 XML 与 BIN 的 SHA-384 均与 `model.yml` 的发布清单相符。固定 Python 与转换器后，独立进程分别走联网及离线输入，得到相同的 4,466,624 字节和 SHA-256 `53349972f8899c86d7afe7f585f3be76f2303f458893679ae42baafc59be6373`。模型采用 ONNX IR 9、opset 17。构建脚本同时复制原文许可和转换声明。[可复现转换](../../Modules/LibraryCatalog/Tools/convert-intel-face-model.py) · [随包说明](../../Modules/LibraryCatalog/Swift/Resources/discovery/licenses/Intel-0095-NOTICE.txt)

在实际发布目录的 macOS arm64 Python 3.12.11、OpenCV 4.12.0、ONNX Runtime 1.23.2 上，生产照片处理进程读入全部 67 份代理，返回 72 个检测。61 个可核对面部的五点和框均与夹具一致，生产和独立研究实现的 128 × 128 BGR 输入全部逐字节相同。生产进程与独立 ORT 会话的单位向量逐分量相同。Intel 原生 OpenVINO FP32 与 ORT 之间，最低同图余弦为 0.999999999998；任意两图之间的余弦差最大为 0.000000588。[逐帧与进程校验](../../experiments/library-lifecycle/face_candidate_parity.py)

单线程 ORT 编码器初始化约 32 毫秒，首张推理约 8.6 毫秒，后 60 张 P50/P95 为 8.0/8.2 毫秒。启动随包进程到第一张含人脸的照片返回约 162 毫秒；其余 66 张整图请求 P50/P95 为 21.6/31.6 毫秒，包含读图、校验、YuNet、对齐、编码和 JSON 往返。子进程峰值约 196 MiB，OpenCV 配置为两线程。不同样本数和后端配置需要分别计时。[测量方法及原始汇总](evidence/face-encoder-distribution.json)

在仓库根运行以下命令即可重建模型。转换器使用专用环境，依赖版本列在脚本的 `VERSIONS` 中。`MODELS` 指定输出模型目录，`LICENSES` 指定随包许可目录。若已有官方文件，在命令末追加 `--source-dir "$IR_DIRECTORY"` 即可离线执行。

```sh
uv venv --python 3.12.11 "$CONVERT_ENV"
uv pip install --python "$CONVERT_ENV/bin/python" openvino2onnx==1.1.0 onnx==1.17.0 \
  numpy==2.1.3 protobuf==7.36.2 networkx==3.7 colorlog==6.12.0 tabulate==0.10.0 termcolor==3.3.0
"$CONVERT_ENV/bin/python" Modules/LibraryCatalog/Tools/convert-intel-face-model.py \
  --output "$MODELS" --licenses "$LICENSES"
```

私有回归输入为统一的人脸清单。先用独立 OpenVINO 2026.4.1 与发行包相同版本的 OpenCV/Pillow 输出原生向量，再用发行包编码和校验。所有裁片、向量及原始照片路径留在私有工作目录，逐图结果不会写进版本库。[编码器回归入口](../../experiments/library-lifecycle/face_candidate_embeddings.py)

```sh
"$OPENVINO_PY" experiments/library-lifecycle/face_candidate_embeddings.py --model intel \
  --manifest "$MANIFEST" --weights "$IR_DIRECTORY" --output "$PRIVATE/native.json"
"$PACK/runtime/bin/python3.12" -I experiments/library-lifecycle/face_candidate_embeddings.py --model intel-ort \
  --manifest "$MANIFEST" --weights "$IR_DIRECTORY" --onnx "$MODELS/face-reidentification-retail-0095.onnx" --output "$PRIVATE/packed.json"
"$PACK/runtime/bin/python3.12" -I experiments/library-lifecycle/face_candidate_parity.py \
  --worker "$PACK/discovery/worker.py" --models "$MODELS" --manifest "$MANIFEST" \
  --native "$PRIVATE/native.json" --packed "$PRIVATE/packed.json" --output "$PRIVATE/parity.json"
```
