# CoreAI · YuNet 与 Intel 0095 联合验收

Mac16,5 上的 Apple Development 签名 arm64 App Sandbox 通过 Swift、C ABI、Rust 和 ONNX Runtime 1.27.0 执行完整人脸组件。输入为同一份正向 RGBA8，Rust 完成动态缩放、补边、12 个具名输出验证、检测与排序，再用返回的五点运行 Intel 0095。四个用例覆盖一张矩形实拍、一张正方形实拍、由两张实拍生成的双脸夹具及空帧。[逐样本、来源与签名回执](evidence/core-ai-yunet.json)

| 输入 | 检出 | 首次检测 | 检测暖态 p50 / p95 | 检测及全部向量暖态 p95 |
| --- | ---: | ---: | ---: | ---: |
| 1365×2048 | 1 | 29.74 ms | 16.86 / 17.24 ms | 20.58 ms |
| 1024×1024 | 1 | 26.59 ms | 19.91 / 20.28 ms | 23.56 ms |
| 1024×640 双脸 | 2 | 16.32 ms | 12.23 / 12.59 ms | 19.10 ms |
| 321×239 空帧 | 0 | 4.96 ms | 1.69 / 1.76 ms | 1.76 ms |

每种输入清退会话后测一次首次检测，再保留五次预热和 30 次暖测。阶段计时含 Swift 调度、Rust 预处理、推理、NMS 和结果回传。实拍检测均低于 50 ms 门。框坐标与旧 OpenCV 4.12 逐项相同，五点最大误差为 0.0000611 像素，置信度最大误差为 0.0000000597。四个向量的余弦相似度都达到 0.999，最小值为 0.9999999337。逐个清退的进程最高 RSS 为 355.55 MiB。另一轮在同一对会话内交替输入四种形状，最高为 366.41 MiB，清退后采样的进程 RSS 与清退前持平。[旧 Discovery 路径](../../Modules/LibraryCatalog/Swift/Resources/discovery/worker.py) · [公开检测实现](https://github.com/opencv/opencv/blob/4.12.0/modules/objdetect/src/face_detect.cpp)

两个独立进程从固定的 YuNet 原权重生成了相同的 232,726 字节动态制品。仅变更 ONNX 的尺寸声明，640×640 的两组实拍输入在原图和动态图的 12 个输出逐位一致。生产尺寸视图的 5,308,416 个 F32 输入与 OpenCV 逐值相同。实测发现 2×1536 缩至 1×1024 的标量尾通道有舍入差，修正按旧 arm64 OpenCV 的四通道分组处理，原误差像素现输出 104。旧 OpenCV 的 .9 初筛与 NMS 等号分支、整数 IoU、同分先截 5000 和裁边前排序也有独立验证。转换记录、原模型摘要和 MIT 原文随资产清单核验。[固化转换及许可证](../../Modules/CoreAI/ModelContracts/yunet-2023mar-dynamic-v1.json) · [转换器](../../Modules/CoreAI/Tools/derive-yunet.py)

C 容量不足、容量超上限和预取消皆保留数组与计数哨兵。空帧成功返回零项，清退与重试可恢复同样的双脸结果。Intel-only 包对缺失 detector 由模型错误分支返回。十四项默认 Rust 回归和一次 Intel 原生在途撤销回归通过。完整图库索引切换另需验证 033 的人物锚点、确认和重建，分割、SigLIP2、M1 8 GB 混合负载及商店候选继续按 044 验收。[首次 Intel 验收](core-ai-validation.md)

本地 Release `20261128.225813` 已安装。构建包与安装包的六个程序、两种模型、清单、转换回执和许可证摘要一致。两种 CoreAI C ABI 在安装前后均通过，正常窗口、隔离 SQLite 和 44 次原生 Metal C ABI 检查也通过。上版已签名备份。[Release 验收回执](evidence/core-ai-yunet-release-checkpoint.json)
