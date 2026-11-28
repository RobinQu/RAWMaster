# CoreAI · Intel 0095 原生验收

2026-11-28 在 Mac16,5 上验收第一条 CoreAI 路径。现有 Discovery 提供正向 sRGB 照片与五点参考，Rust 执行五点相似变换、128×128 BGR 输入、Intel 0095 ONNX 推理及 256 维单位化。Swift 调用 C ABI，在工作线程等待原生结束。当前 C ABI 要求全图 ROI，五点以整幅宽高归一化。图像和模型缓冲分别有固定大小上限，同一进程使用一个环境、一个活动调用及一个可清退会话。[C ABI](../../Modules/CoreAI/include/rawmaster_core_ai.h) · [固定模型契约](../../Modules/CoreAI/ModelContracts/intel-0095-v1.json)

两张冻结照片与旧 Python、OpenCV 4.12 和 ONNX Runtime 1.23.2 比较。每张裁片的 49,152 个 BGR 通道值逐位相同。另用 32 组含反射和边缘的合成输入核对了 1,572,864 个通道值，差异为零。两张照片的 256 维向量余弦相似度分别为 0.999999999999523 和 0.999999999999418，均通过 0.999 门槛。向量和原始照片留在本地验证目录。[逐项回执](evidence/core-ai-intel-0095.json)

| 照片尺寸 | 清退会话后首个向量 | 暖态向量 p50 / p95 | 样本 |
| --- | ---: | ---: | ---: |
| 1365×2048 | 21.15 ms | 3.12 / 3.24 ms | 30 |
| 1024×1024 | 16.20 ms | 3.07 / 3.20 ms | 30 |

计时从 Swift 调用开始，覆盖实际对齐和 256 维结果回传。冻结参考已提供五点，YuNet 检测和图库索引分别验收。Apple Development 签名的 arm64 资格包启用 Hardened Runtime 与 App Sandbox，包内库通过嵌套验签，测试进程拒绝打开包外私有夹具。ONNX Runtime 实际返回 1.27.0 与 API 27，`ort` 以禁用默认 feature 的方式通过离线锁定构建。签名验证、加载与建立环境共 37.26 ms，全试验进程最高 RSS 70.55 MiB。[ONNX Runtime 发布件](https://pypi.org/project/onnxruntime/1.27.0/) · [ort API 27 配置](https://github.com/pykeio/ort/blob/v2.0.0-rc.15/Cargo.toml#L542)

缺少内置运行库时，即使外部环境变量指向有效库也拒绝开启。替换为单件有效签名、与外层封印不符的库时拒绝加载。有效签名中的错权重按摘要拒绝。构建也拒绝错误张量清单或篡改过的 wheel。C ABI 的短缓冲、越界末像素、错误行跨度、超预算、非有限点和预取消均保留输出哨兵。七项 Release 单元回归和独立的在途取消用例通过。已附着的原生请求占用唯一会话直到返回，随后可在同源重试得到逐值相同的向量。[逐项失败与清退回执](evidence/core-ai-intel-0095.json)

本地 RAWMaster Release `20261128.222547` 已安装。包内固定资源和六个程序逐件核对摘要，签名、隔离 SQLite 自检、原生窗口及 44 次 Metal C ABI 检查通过。CoreAI C ABI 以实拍分别走构建包和安装包，结果与独立资格包一致。前一版本已保留用于回滚。[安装回执](evidence/core-ai-intel-release-checkpoint.json)

当前检查点覆盖模型清单和 ABI 的 Intel 0095 部分。YuNet 原图固定声明为 640×640，旧 OpenCV 实际按最长边缩至 1024，并向右下补零到 32 的倍数。内部探针确认原图拒绝 512×768。只调整张量空间维度声明后，12 个输出在 640×640 逐值一致，另外两种矩形尺寸输出符合 stride 形状。该确定性制品仍需绑定独立摘要、实拍缩放及 NMS 证据，再用完整图库验收。分割、SigLIP2、代次切换、M1 8 GB 混合负载及完整商店签名候选各有独立签收条件。[现行人脸路径](../../Modules/LibraryCatalog/Swift/Resources/discovery/worker.py) · [033 人脸库验收](../033-library-lifecycle/face-retrieval-upgrade.md)
