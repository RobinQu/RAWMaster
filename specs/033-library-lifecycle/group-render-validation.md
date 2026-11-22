# 阶段三分组母版实拍验收

所有输入先按冻结清单逐项复核 SHA-256、长度与相机身份，复制到作业私有目录。Core Image 将原片解码到共享白平衡的线性浮点 RGB。C++ 负责配准、叠加、融合和 TIFF 编码。每次回归另外用 Python 标准库核对 TIFF 标签、ICC、条带长度、抽样像素、每帧来源及整文件 SHA-256。收据明示 `originalLinearRAW`，逐帧记录冻结的工作版本身份，像素由相应原件解码。实拍 HDR 校验了 3 个冻结版本标识；指定未实现的显影外观策略时作业拒绝发布。应用运行时只需系统框架，OpenCV 4.12.0 在构建时静态链接。[实测数据](evidence/group-native-render.json) · [原生构建入口](../../Modules/LibraryCatalog/GroupRender/build.sh)

| 真实输入 | 输出 | 观测 |
| --- | --- | --- |
| 已确认的 24 张星空 RAW | 8640 × 5760，冻结顺序中的 24 张均贡献像素 | 帧间起拍中位数 60.025 秒，各帧实际曝光 30 秒，最长未曝光间隔 240.793 秒。24 张原件的 SHA 集合为 `60c609eb…d3d3ecf1`。首次含地景诊断为 26.78 秒，复跑 32.48 秒、峰值 RSS 2105 MiB。 |
| 三档日出 HDR | 8640 × 5760 | 6.06 秒、3062 MiB。以实际快门中曝为参考，最大通道值 3.825，48,300 像素至少一通道超过 1，1,665,605 个零有效权重像素回到参考细节。 |
| 五档山景 HDR | 8640 × 5760 | 9.12 秒、3064 MiB。最大值 2.513，8,613,324 像素保留大于 1 的亮部。6,491,308 个像素因曝光归一后不一致使用参考帧，记录的蒙版反映实际判定。该组缺少运动轮廓真值。 |
| 同一机位三张 100 mm 全景 | 有效矩形 11519 × 5384 | 11.27 秒、4668 MiB。相邻两对 1513 / 1211 内点，两对柱面旋转残差 P95 为 0.77 / 1.14 个代理像素，首末另有 1004 个闭环内点。未裁切重叠区域共 48,689,397 像素。 |
| 同机同焦距另一实拍画面 | 没有发布作品或收据 | 16 个候选匹配只有 4 个内点，报告冻结序号及断开位置。 |

星轨组的前四帧（零起始 0–3）存在构图变化。工作人员在 1000 × 667 原机 JPEG 预览手工选取三条亮星轨迹，按相机时间在稳定的 20 帧逐点查找，再对照全幅线性母版。60 个位置均落在亮迹上，各轨迹定位残差 P95 为 1.24、1.02、0.92 像素。两处塔身模板在这 20 帧的最低归一化相关为 0.987 和 0.995，整像素位移均为 0。完整序列的默认取亮保留所有飞机/星点/背景及其间隙，前景会重影。收据逐帧返回下部特征位移，自动复核清单为 0–3。单独冻结后 20 帧没有位移告警。移除原序号 12 后，收据新增对应的节拍缺口。[独立星点和地景复核](../../Modules/LibraryCatalog/tests/group_star_anchors.py)

同一 24 帧选择参考序号 12，将从上方 58% 开始的区域逐步过渡为其前景。完整引用参考帧 20,157,120 像素，羽化 743,040 像素。两处塔身与原机参考 JPEG 的相关从 0.153 / 0.303 升至 0.977 / 0.985，位置偏移均为 0。该高度由本次样片人工选定，产品允许调整。天空比较始终使用冻结原帧。

HDR 使用相同 ISO、光圈和工作白平衡，以实际快门比例融合。饱和/低信噪权重根据解码后的线性样本估算，机型校准由平台 RAW 解码器处理。静态高光与暗区有真实测量，真实运动边界的误报、漏报和边缘光晕仍需独立标注。可控输入另有 96 个已知运动像素和 112 个全黑像素，当前算法分别精确选回参考时刻和零权重回退。全景用同焦距代理进行 SIFT 双向比率匹配、RANSAC 及标定旋转，检测次要一致运动层，按柱面坐标在全尺寸 RGB 浮点图块融合。两层具有不同偏移的可控夹具能触发视差诊断，已有实拍验证无重叠失败。真实近景视差量化仍缺实地标注。[数值用例](../../Modules/LibraryCatalog/tests/group_render_math.cpp)

## 复跑

在仓库根目录为 `RAWMASTER_RENDER_CACHE_DIR` 选一个可写构建缓存。首次下载固定 SHA-256 的上游源包，需要 Xcode 和 CMake。也可把 `RAWMASTER_OPENCV_PREFIX` 指向同架构、同版本的离线静态安装目录。把 `SCRATCH` 指向有足够空间的私有临时目录，`WORKER` 设为该目录下新建的 helper 路径，`RAW` 表示用户选定的有序原件数组。[只读原片回归脚本](../../Modules/LibraryCatalog/tests/group_render_replay.py) · [OpenCV 及随组件的许可证](../../Modules/LibraryCatalog/GroupRender/OpenCV-LICENSE.txt)

```sh
Modules/LibraryCatalog/GroupRender/build.sh "$WORKER" --verify-kernels
python3 Modules/LibraryCatalog/tests/group_render_replay.py --worker "$WORKER" --scratch "$SCRATCH" --case starTrail "${RAW[@]}"
```

HDR 与全景将 `--case` 换成 `hdr` 或 `panorama`。复核前景的星轨参数为 `--recipe '{"referenceIndex":12,"foregroundStartY":0.58}'`。原机星点复核的输入为同一私有作业的 `request.json`、`receipt.json`、`master.tiff` 和 ExifTool，通过 `uv run --python 3.12 Modules/LibraryCatalog/tests/group_star_anchors.py --help` 查看入口。收据可移交后续服务端，RAW 解码器替换仍需对同一来源和颜色空间做跨平台回归。
