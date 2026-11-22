# 033 · 星轨、多曝光 HDR 与全景制作基线

2026-11-22 · 阶段三技术方案，待审阅。交付顺序沿用延时入库、星轨、HDR、全景。当前已有拍摄组操作、HDR／星空目录筛选与延时渲染，在产品源中未找到后三类的成片引擎或按组登记的生产调用。现有延时参考图输出为 sRGB RGBA8，普通成片的 TIFF 校验只接受 16 位。从组选帧、可靠发布可复用已有模式，场景线性像素、高动态范围成片与多输入来源需另行实现。[分组规格](../015-group-editing/spec.md) · [资料库类型](../../Sources/RAWMaster/LibraryCatalogModels.swift) · [延时渲染](../../Sources/RAWMasterImaging/TimelapseRenderer.swift) · [既有导出登记](../../Sources/RAWMasterCore/LibraryStore+RenderedExports.swift)

## 现有照片能验证什么

库内冻结的 1,265 个文件来自四个连拍和两个间隔用例。后续人工标注绑定其中 JPEG 单表示集合的 1,077 个身份，记录连拍、间隔及一般序列。它们适合验证配对去重、顺序、漏帧和失败提示，没有针对这三种成片的画质标签。[冻结用例](../../Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/index.json) · [人工修订](../../Tests/Fixtures/SequenceGroupingAnnotations/v1/README.md)

本次另在已挂载的 Lightroom 相片年份目录找到 31 个以 HDR 命名、17 个以 Pano 命名的 DNG 候选。在现有 Classic 目录只读关联文件、照片与文件夹堆栈，核对原片存在、相机元数据、成片和实像后选取以下三组。31 个 HDR 堆栈中有 4 组满足固定 ISO、光圈且至少三个实际快门档。其余候选没有逐组验收。堆栈可由用户更改，迁移时保留其来源证据与核实程度。星轨在冻结标注和该目录的文件名、关键词、集合名、文件夹名中都没有找到可确认的序列，未对未标注原片逐张判读。[Adobe 的 HDR 堆栈](https://helpx.adobe.com/ie/lightroom-classic/desktop/process-and-develop-photos/hdr-photo-merge.html) · [Adobe 的全景堆栈](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/panorama.html)

| 实拍样本与原件顺序 | 本轮正确性探针 | 尚待验收 |
| --- | --- | --- |
| Sony α1，2026-02-12，`_DSC0801–0803.ARW`，ISO 100、f/8。快门依次为 1/160、1/640、1/40 秒 | Bayer 可视区域从左上每 17 行、列采一个位置，共 173,910 点。用每通道黑电平 512、白电平 15,360 归一化。每一对两帧都处于 (0.01, 0.90) 的位置，分别有 13,794、80,545 点。中曝/短曝与长曝/中曝的中位数分别为 3.967、3.989，理论值均为 4。三张 640 × 428 内嵌 JPEG 的亮度中位数为 46、11、106，AlignMTB 给出的整数位移均为零 | 现有结果能验证曝光归一化。没有标注运动区域，不能据此判定去鬼影效果 |
| Sony α1，2024-07-06，`_DSC3527–3531.ARW`，ISO 200、f/8。五档实际快门为 1/320、1/2500、1/40、1/8000、1/5 秒 | 同样采 173,910 点。中曝近饱和的 6,006 个位置有 6,005 个在至少一张短曝落入 (0.01, 0.90)。中曝低信号的 52,434 个位置有 52,433 个在至少一张长曝进入有效区间。近饱和取 ≥0.98，低信号取 <0.01。最暗档的 EXIF 补偿为 −6 EV，实际快门和中曝仅相差约 4.64 档 | 这两个数衡量原片可提供的信息。完整输出还要对齐，核验噪声、高亮细节及浮点 TIFF 回读 |
| Sony α1 II，2026-10-06，`DSC07063–07065.ARW`，100 mm。堆栈内有三帧与已生成的 11,704 × 6,147 DNG | 每帧取 640 × 428 内嵌 JPEG。相邻两对 ORB/RANSAC 内点为 608/638 和 474/503，内点重投影误差中位数 0.63、0.67 代理像素，P95 为 1.82、2.03。OpenCV 全景模式成功，返回成员 0、1、2，产出 863 × 451 代理图 | 相邻重叠已有实证。全尺寸接缝、近景视差、色调一致性、登记及从成片反查三帧均应再测 |

**复现条件。** 读取既有相片只在本机进行。传感器采样使用 rawpy 0.26.1／LibRaw 0.22.0 的 `raw_image_visible`，使用机型的分通道白电平。代理探针用 OpenCV 4.12.0 单线程、随机种子 333，按长边 640 用面积插值缩小。全景测 ORB 2,000 个候选特征，Hamming 最近邻比率 <0.75、RANSAC 阈值 3 代理像素。独立的 `Stitcher::PANORAMA` 使用 0.25/0.10/0.25 MP 的配准、接缝、成片尺度。本次探针没有生成或登记用户作品。[rawpy 读取接口](https://letmaik.github.io/rawpy/api/rawpy.RawPy.html) · [OpenCV 单应性估计](https://docs.opencv.org/4.12.0/d9/d0c/group__calib3d.html)

复现前按表中帧序计算每个原件的 SHA-256，再对拼接后的二进制摘要做一次 SHA-256。三组依次为 `23d1d1cfc25d7a2421adb73bf820decb39a2a538b0417fd6b7e78b6a041b384b`、`ac345c0b67f73825bd36df18d5c50aeca086e6bd94372ef7a7c7a6710776585e`、`fc7e2dca98c9220d59329361ef3bafd26edb55c407ac1d8a20f1bc508b0afffd`。数值用于同数据回归，代理像素误差不能直接折算成原尺寸的人工观感。

## 三种制作配方

### 星轨

固定机位、面向地面的坐标系下，星点随时间移动。第一版采用逐像素取亮叠加，逐帧在共享线性 RGB 工作空间计算亮度，保留该位置亮度最大帧的完整 RGB。同亮度按冻结帧序取先到者。任一时刻只保留当前帧与累积图块。固定前景可以从指定参考帧及人工蒙版取样。发生机身抖动时，仅用可靠的静止地景估计位移。缺乏锚点则提示排除或保留原几何。按星点配准会消去要表现的轨迹。缺帧产生的间隙要显示，飞机、云和热像素可在预览中标记，由用户剔帧、局部遮罩或选择暗场校正。[Siril 像素最大值叠加](https://siril.readthedocs.io/en/stable/preprocessing/stacking.html#pixel-maximum-stacking) · [StarStaX 开发者的模式说明](https://markus-enzweiler.de/software/starstax/)

**最小补样。** 一组固定机位、可见静止地景的真实星空 RAW，建议 30–60 帧，并在原始序列标出三条星轨、两处前景锚点及一帧异常光迹。对同一组再移除一帧以产生已知缺口。核对三条轨迹与每帧实星位置对应、前景锚点无双边、排除异常帧后对应亮迹消失、缺口及实际输入编号一致。真实星轨样本到位前，该项保持待测。

### 多曝光 HDR

1. 按拍摄身份去重，读取真实快门、光圈、ISO、黑白电平和方向。先支持固定 ISO、光圈的曝光包围。可用中曝作参考。用亮度代理和 AlignMTB 估计粗平移，静态纹理可进一步做亚像素对齐。记录残差、有效覆盖和每帧变换。混合 ISO 要额外验证有效增益和噪声响应，光圈变化还会改变景深，缺乏标定时报告不受支持的输入档。上表样本显示，直接用曝光补偿标签代替快门会得出错误比例。[OpenCV AlignMTB](https://docs.opencv.org/4.12.0/javadoc/org/opencv/photo/AlignMTB.html) · [Debevec 与 Malik 的辐照度恢复](https://people.eecs.berkeley.edu/~malik/papers/debevec-malik97.pdf)
2. 统一白平衡和颜色变换，在无显示曲线的场景线性 RGB 计算。用原始通道的黑电平、白电平及近饱和状态产生有效性掩膜。设 `zᵢ` 为校正后的线性值、`tᵢ` 为实际曝光秒数，静区采用 `Σ[wᵢ × (zᵢ / tᵢ)] / Σwᵢ`。低信噪、近饱和、遮挡和变换无效处权重降低至零。零有效权重像素标为无法恢复并披露覆盖率。参考曝光用于定义相对白点，浮点成片可保存大于 1 的有效亮部。OpenCV 4.12 的 MergeDebevec 对输入断言为 8 位，适用于 JPEG 响应标定的对照试验，MergeMertens 可出显示预览。[OpenCV 合并实现](https://github.com/opencv/opencv/blob/4.12.0/modules/photo/src/merge.cpp#L57-L85) · [OpenCV HDR 教程](https://docs.opencv.org/4.6.0/d2/df0/tutorial_py_hdr.html)
3. 在已对齐且曝光归一化的图像间测局部结构和亮度残差，以噪声阈值和空间连通区域生成运动掩膜。运动区优先选参考时刻同一源帧，另记该选择和掩膜。参考区过曝、运动或遮挡而无可靠对应时暴露冲突。用户可改参考帧或接受缺失的局部细节。预览叠出去鬼影范围。补一组同场景三档 RAW，画面有移动人物或枝叶并留有静止背景。人工标注运动轮廓和阴影、高光、静区各一块。核查双边、边界光晕、静区噪声和成片高亮能否在降低显示曝光后恢复。上表线性响应和覆盖率提供独立的静态参照。[Hu 等的饱和与去鬼影研究](https://www.cv-foundation.org/openaccess/content_cvpr_2013/papers/Hu_HDR_Deghosting_How_2013_CVPR_paper.pdf) · [Adobe 的去鬼影预览](https://helpx.adobe.com/ie/lightroom-classic/desktop/process-and-develop-photos/hdr-photo-merge.html)

### 全景

在方向与镜头畸变统一的低分辨率代理提取 ORB 特征，按相邻帧及可能闭环的候选做比率检验、RANSAC 和重叠图检查。由连通匹配拟合相机旋转及内参，做光束法平差。首版支持同机位旋转的单行全景，默认柱面或球面投影，按实际视角预览边界和裁切。在重叠区估计受限的曝光增益与接缝，最终在原尺寸线性浮点像素上重投影，按同一接缝做分块多频段融合。保留覆盖掩膜和空白边界。OpenCV 示例会筛掉最大连通分量以外的帧，正式作业须列出每个缺失成员、交由用户决定后冻结新清单。4.12 的 MultiBandBlender 图像输入接受 8U 或 16S 三通道，高精度成片须使用经过验证的浮点融合实现。[Brown 与 Lowe 的全景算法](https://www.cs.ubc.ca/~lowe/papers/07brown.pdf) · [OpenCV 拼接示例](https://github.com/opencv/opencv/blob/4.12.0/samples/cpp/stitching_detailed.cpp#L492-L555) · [融合输入约束](https://github.com/opencv/opencv/blob/4.12.0/modules/stitching/src/blenders.cpp#L324-L340)

以实测三张 100 mm 原片复核全尺寸几何及原件到成片双向追溯，再增加一组三张含近处栏杆、远处建筑且有手持平移的实拍。人工标记近、远景对应点和易重影区域，分区报告重投影误差、对照可见双边、接缝亮度跳变、裁切损失及所有输入覆盖率。单一投影无法同时解释近远景时，提示视差与问题帧，允许调整接缝或重新选择。另取一张真实无重叠照片加入已知组，验收断开帧提示及未确认时禁止登记。

## 输入、产物与登记

- **执行接口。** Swift 只提交冻结的组与成员修订。原生 C++ 算法可经稳定 C ABI 由资料库核心调用，输入为有内容版本的帧、目标尺寸、颜色空间／白点、配方、取消令牌与输出位置。代理用于几何、筛帧和预览。最终渲染解码对应的已纳入原件，逐帧固定解码器、方向、镜头校正和颜色配置。RAW+JPEG 每次快门最多贡献一个输入。原件冷存或缺失时等待取回／提示替代，经选择使用 JPEG 才记录来源与精度限制。本期仅本机执行。[分组输入契约](../015-group-editing/spec.md) · [后续计算契约](server.md)
- **基线成片。** 建议三类派生照片采用带线性 ICC 的浮点 RGB TIFF 作母版，生成独立显示 JPEG。核验 TIFF 的 IEEE 浮点样本、每通道 32 位、方向、大小与像素值，HDR 增加保留大于参考白的亮部值及独立解码回读。让库内编辑、预览、备份及恢复都能再次打开母版。现有 TIFF 扩展名已获导入支持，16 位普通导出的校验仍有独立用途，须为新派生媒体补全写入与回读路径。[现有导入格式](../../Sources/RAWMasterCore/ImportService.swift) · [TIFF 颜色、采样和位深标签](https://libtiff.gitlab.io/libtiff/functions/TIFFSetField.html)
- **来源与可靠性。** 在暂存位置渲染并校验母版摘要，使用与作业身份绑定的幂等登记。作品保存冻结的组、原始拍摄/文件/内容版本、有序成员、替代/排除原因、帧变换、对齐或去鬼影参数、掩膜摘要、投影/裁切及引擎版本。从成片能返回每个输入，从拍摄组可列出全部作品。回归包含原片外置盘离线、分组重排、一个文件参加两组、取消、渲染完成后登记中断并重试。新作业版本与原作区分，每次成功作业只登记一张作品。[制作与登记验收](../015-group-editing/spec.md)
- **依赖边界。** 本次可执行探针使用的 OpenCV 4.12.0 与可移植 C++ 接口一致，项目 4.5.0 起采用 Apache-2.0，部分源文件保留既有版权说明。分发前列出实际启用模块和第三方依赖。本次 rawpy／LibRaw 作为独立传感器测量工具。Siril、StarStaX、Adobe 文档与论文用于算法或行为对照。本轮没有新增随包库、样片或权重。[OpenCV 项目许可](https://opencv.org/license/) · [rawpy 项目与随包组件](https://github.com/letmaik/rawpy#license)

## 复跑实拍基线

从仓库根目录运行。将 `HDR3_DIR`、`HDR5_DIR`、`PANO_DIR` 指向上表三组原片所在目录。脚本内固定 NumPy 2.2.6、OpenCV 4.12.0.88 和 rawpy 0.26.1，本次使用 Python 3.12、LibRaw 0.22.0、ExifTool 13.59。若系统已安装 ExifTool，可把 `--exiftool` 后的路径改为 `exiftool`。[实拍探针](../../experiments/library-lifecycle/group_baseline.py)

```bash
probe=(uv run --python 3.12 experiments/library-lifecycle/group_baseline.py
       --temp-dir "${TMPDIR:-/tmp}" --exiftool output/RAWMaster.app/Contents/Resources/MetadataTool/exiftool)
"${probe[@]}" hdr "$HDR3_DIR"/_DSC080{1,2,3}.ARW
"${probe[@]}" hdr "$HDR5_DIR"/_DSC35{27,28,29,30,31}.ARW
"${probe[@]}" panorama "$PANO_DIR"/DSC0706{3,4,5}.ARW
```

每次在指定临时目录新建私有子目录，终端打印汇总文件的相对路径。`summary.json` 只记录组摘要、帧序号、算法版本和聚合测量。原片与代理全程只读，代理和拼接图只留在内存。本次重新运行三组，组摘要、两项响应倍率、四个覆盖计数、全景相邻对的内点及误差、成片尺寸均复现上表数值。

另取三个 ISO 不一致的实拍帧，HDR 探针按输入条件返回退出码 2。将两张相互无关的真实原片交给全景探针，汇总记录 OpenCV 状态 1 和未能拼齐全部成员，进程返回退出码 1。
