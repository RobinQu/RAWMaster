# 原始分辨率去马赛克

在“细节”中启用“RAW 细节”会根据当前文件的马赛克布局切换去马赛克算法。Bayer 使用 FlashRaw 0.3.1 的 AHD。该算法分别估计水平和垂直方向上的颜色，再从局部色彩更均匀的方向重建细节。6×6 X-Trans 使用 FlashRaw 的边缘感知算法。两种算法都在传感器原始采样网格上重建颜色。Adobe 将自己的增强实现列为 Raw Details，公开说明的目标包括细节、边缘和颜色以及保持原尺寸。双方的像素一致性仍需 Adobe 参考结果验证。[FlashRaw 固定源码](https://github.com/ybouane/flashraw/blob/2994e8c550bec70ab78a938ab28a74d7762124f4/crates/flashraw/src/options.rs) · [AHD](https://github.com/ybouane/flashraw/blob/2994e8c550bec70ab78a938ab28a74d7762124f4/docs/design/ahd-demosaic.md) · [边缘感知算法](https://github.com/ybouane/flashraw/blob/2994e8c550bec70ab78a938ab28a74d7762124f4/docs/design/edge-aware-demosaic.md) · [Adobe 说明](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/sharpening-and-noise/enhance.html)

FlashRaw 读取文件的实际传感器布局。Quad Bayer、其他 CFA、单色、线性 RGB、Foveon 及非 RAW 输入没有这个选项。布局、方向和原片像素尺寸均通过校验后，配方会保存库版本和具体算法。交互预览、缩略图与原始尺寸渲染都使用该选择，各自的解码输入缓存键包含算法。历史配方和关闭选项的操作会恢复原有解码选择。[配方](../../../../Sources/RAWMasterCore/DevelopmentAdjustmentsV3.swift) · [资格与原始尺寸解码](../../../../Sources/RAWMasterImaging/FlashRawImageFactory.swift) · [交互代理](../../../../Sources/RAWMasterImaging/PreviewInteractiveProxyV3.swift)

## 实拍样本

| 相机 | 传感器布局 | 文件尺寸 | 原始样本 SHA-256 |
| --- | --- | ---: | --- |
| Sony ILCE-7RM5 | 2×2 Bayer | 9504 × 6336 | `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c` |
| Fujifilm X-T1 | 6×6 X-Trans | 4896 × 3264 | `e994a1fd6e87e392432fe146a35b0b88584dc2bd50bee2c8c7e886ac2b59fcde` |

Sony ARW 与三应用性能测试使用同一文件。Fujifilm RAF 来自 raw.pixls.us 的 CC0 样本 2421。库读出的布局分别为 Bayer 和 X-Trans。[Fuji X-T1 样本](https://raw.pixls.us/getfile.php/2421/nice/Fujifilm%20-%20X-T1%20-%2014bit%2014bit%20uncompressed%20%283%3A2%29.RAF) · [数据集](https://raw.pixls.us/)

## 实拍结果

两台相机的增强预览均改变了像素，再次切回普通去马赛克后，预览见证与初值一致。中心 192 × 192 Float16 RGB 的颜色数据在两种算法下亦不同。FlashRaw 对两台相机均报告 Metal 后处理。Sony ARW 的传感器解包使用 CPU NEON 16 线程，Fuji RAF 使用 GPU 解包。[原始测量与见证](raw-details.json)

| 相机 | 原始／增强／还原的 2400 像素适配预览 | 全幅 16 位 TIFF 导出 | 导出尺寸 |
| --- | --- | ---: | --- |
| Sony ILCE-7RM5 | 153.08 / 143.24 / 85.11 ms | 871.83 ms | 9504 × 6336 |
| Fujifilm X-T1 | 130.73 / 270.38 / 20.23 ms | 260.80 ms | 4896 × 3264 |

每个条件执行一次，包含首次解码及该会话已有缓存的影响。文件导出统计覆盖编码和输出文件验证。Sony 和 Fuji 均成功校验 16 位深度、输出像素尺寸和 TIFF 的 SHA-256；实际照片的视觉质量仍需带参照图的评测。[真实原片验证程序](../../../../Tests/RAWMasterImagingTests/DevelopmentRawDetailsImageTests.swift)

## 复跑

在仓库根目录指定两个原片及新的 JSON 路径，并设置 `RAWMASTER_FLASHRAW_LIBRARY` 为固定 0.3.1 动态库路径。样本测试在同一照片会话中依次产生普通、增强、普通三个 2400 像素适配预览。每次预览结束后取得 RGB 像素见证。另取中央 192 × 192 线性 Float16 RGB 区域校验去马赛克的直接输出。设置 `RAWMASTER_RAW_DETAILS_EXPORT=1` 还会从重新打开的配方导出整幅 16 位 TIFF，并验证文件哈希与尺寸。[图像测试](../../../../Tests/RAWMasterImagingTests/DevelopmentRawDetailsImageTests.swift) · [配方测试](../../../../Tests/RAWMasterCoreTests/DevelopmentRawDetailsTests.swift)

```sh
RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib" \
RAWMASTER_RAW_DETAILS_BAYER="$PWD/output/performance/acr-benchmark.ARW" \
RAWMASTER_RAW_DETAILS_XTRANS="$PWD/output/fixture-staging/raw-details-fuji-xt1.raf" \
RAWMASTER_RAW_DETAILS_OUTPUT="$PWD/output/performance/raw-details-qualification-run.json" \
RAWMASTER_RAW_DETAILS_EXPORT=1 \
swift test -c release --filter testRealBayerAndXTransMetadataDispatchPreviewAndExport
```
