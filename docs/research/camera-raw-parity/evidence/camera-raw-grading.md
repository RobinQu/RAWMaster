# Camera Raw 19 的 LUT 与蒙版色轮

测试机使用 Adobe Camera Raw 19.0（2794）与 Photoshop 28.0。Adobe 的界面支持全局最多三层 LUT，每蒙版一层，允许调强度、修改顺序和从 CUBE / ZIP 导入。安装目录有 6 个 16³ 彩色 CUBE 和 3 个 33³ 黑白 CUBE。报告保存文件名、尺寸和 SHA-256，引用 Adobe 的原始安装资源。[Adobe 的 LUT 操作说明](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/tone-and-color/apply-luts-to-photos-in-camera-raw.html) · [本机公开资源与返回元数据](camera-raw-grading-schema.json)

读取了 1,022 份 Camera Raw 安装 XMP 和 1,075 份 Lightroom Classic 安装 XMP，以及 Camera Raw 插件自己公开的 Apple Event 脚本词汇。已有 profile 提供 `Look`、`LookTable`、`RGBTable` 和 `RGBTableAmount`。Adobe DNG SDK 描述了 `Table_<digest>` 数据以及 DNG 1.6 的 `RGBTables`。这些字段能识别配置文件、表数据或 DNG 渲染设置。已读取的接口没有给出 19.0 全局新 LUT 栈或局部 LUT 的独立设置记录。[Camera Raw XMP 命名空间](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/) · [Adobe DNG SDK](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html) · [脚本来源与检验方法](../../../../scripts/performance/probe-adobe-grading-metadata.py)

在临时目录复制 9504 × 6336 Sony ARW，并给副本写入 XMP。通过公开的 `CameraRAWOpenOptions.SELECTEDIMAGE` 静默打开，用 Photoshop 的 `document.xmpMetadata.rawData` 只读取得 Camera Raw 自行写回的设置，随后关闭该副本文档。源 RAW 的 SHA-256 和前台应用在两次元数据测试前后相同。已知的全局中间调色相与局部曝光成功写回，人为未知的 `RAWMasterUnrecognizedMetadataWitness` 被丢弃。第二次测试嵌入一个有效的 RGB 表和摘要，给候选的独立表引用与有序栈设置赋值。没有任何候选项按新的 LUT 组件写回，因此该实验没有可登记的 Adobe LUT 速度。[中性对照](camera-raw-grading-schema.json) · [候选赋值与 Adobe 实际写回路径](camera-raw-grading-candidates.json)

Camera Raw 在蒙版的 `MaskGroupBasedCorrections` 中写回阴影、中间调、高光和全局的局部色轮字段，包括色相、饱和度、亮度、混合与平衡。像素实验固定中央径向蒙版和局部中间调色相 142°，只切换中间调饱和度 0 / 65。每次重开得到 9504 × 6336 的 8 位 sRGB 文档，计时结束后读取直方图及 1024 × 683 的空间采样。[写回的具体字段](camera-raw-grading-candidates.json)

17:33 的独占测量共 8 次打开。首个 A/B 对作为校准，随后三次饱和度 65 的打开耗时为 953.981、868.895、984.413 ms，中位 953.981 ms。对应的三次饱和度 0 为 909.235、855.960、879.948 ms，中位 879.948 ms。各状态的直方图和整张 1024 像素宽的图像摘要在四次打开中完全一致，两个状态之间的两项摘要各自不同。此前 17:29 的采集与另一任务重叠 7.7 秒，已单独归档。[独占测量与像素数据](camera-raw-grading-mask.json) · [较早的重叠采集](history/camera-raw-grading-mask-overlap.json)

固定 16 × 16 网格在蒙版中央覆盖 24 个位置，远离蒙版区域覆盖 108 个。首次判断要求 80% 的中央位置变化至少两个 RGB8 码值，该次实得 18 / 24（75%），故原始判定为未确认。为检验中间调色轮可选择性改变中央像素的情况，在保留的 8 份采样上复用了项目已有的像素验证规则。校准对冻结至少 16 个位置、变化最大的通道及方向，随后至少三组独立打开须在 ≥90% 的这些位置持续相差至少两个码值。18 / 18 个中央位置在这三组打开中均满足条件，108 / 108 个外围位置在所有 8 张图的 RGB 字节完全相同。本次复核在采集后进行，其原始判定和重算脚本均已保存。[首次规则与未修改的采集](history/camera-raw-grading-mask-exclusive-first-metric.json) · [蒙版空间复核](../../../../scripts/performance/mask_grading_witness.py) · [既有冻结取样规则](../../../../scripts/performance/histogram_witness.py)
