# 阶段二实拍检查器验收

在新建的私有 SQLite 副本中，使用生产 Swift 检查器读取 16 张 RAW，经 C ABI 写入 Rust 资料库，再从正式只读接口取回结果。样本包括原有 6 张日出 RAW、两组各 3 张的 10 fps 眼部连拍、3 张 30 秒夜空原片和 1 张用于核验另一机身几何的实拍。6 张日出属于同一景物的连续拍摄，原导入器未将它们自动归组。回归为局部比较显式建组。[去标识实测记录](evidence/inspection-native-real.json)

16 张都读到相机、镜头、ISO、快门、光圈、焦距、尺寸和方向。每张的机内 JPEG 直方图实际采样 175,104 个像素，三个通道各 256 桶，桶计数总和与来源摘要全部通过。ILCE-7RM5、ILCE-1 和 ILCE-1M2 三种机身中共取得 13 个合格 Sony 对焦坐标。3 张夜空的坐标都恰为中心，系统记录相机回放回退并隐藏标记。眼部连拍中，相机标记附近能见另一侧眼睛，个别标记靠近眼缘或眼睑，不能当作瞳孔中心真值。[ExifTool 13.59 原始标签定义](https://github.com/exiftool/exiftool/blob/13.59/lib/Image/ExifTool/Sony.pm)

| 区域来源 | 样本及结果 |
| --- | --- |
| 人工选择同一眼部 | 两组各 3 帧，逐帧在原尺寸 192×192 环境内审看绿色标识的 96×96 实际窗口。6 个眼部区域可辨认眼缘和反光轮廓，机器均给出清晰。相机标记区域另外测量，6 次均给出清晰。两套测量来自同一组原片。 |
| 静止河岸纹理 | 以河岸及树枝为固定目标，在机内预览上匹配到其余 5 帧，再到原尺寸取样。目视有 5 帧纹理清楚，机器均给出清晰。第一帧相对柔软，机器返回未知；相机偏焦、抖动与其他光学因素无法独立分离。将该帧人工标记为“疑似失焦”后重新分析，系统保留人工标记、原机器结论及库内纳入资格。 |
| 光线或纹理不足 | 日出天空 6 次、较暗的低对比河岸 6 次、夜空深色区域 3 次均返回未知。实际日出相机 AF 区域中，4 张指向纹理不足的天空，另 2 张缺少同条件参照，也返回未知。暗部验证促成低亮度与低对比联合弃判，规避将细粒度噪声当成清晰细节。 |

独立目视标记的 11 个清晰区域（眼部 6、河岸 5），假报疑似失焦为 0。若只把机器“疑似失焦”作为复核入口，1 个肉眼相对偏软的河岸区域会漏入未知。该小样中可独立确认由光学失焦造成的正例为 0，无法计算该类别的漏判率。两组眼部样本来自同一主体，评价不能延伸到其他机型、人物、动物或拍摄光线。样片与包含私人路径的单次明细均留在临时目录。

## 复跑

从仓库根执行以下命令。在 `SOURCES` 数组按匿名清单顺序传入本机选择的原件，测试首先逐组核验内容摘要。`RUNTIME` 指向当前构建的 `librawmaster_library.dylib`；`EXIFTOOL` 可用应用资源中的 ExifTool。`SCRATCH` 指向独立临时目录。添加 `--save-private-patches` 可在该目录留存供目视审查的局部裁片。[输入顺序与区域](evidence/inspection-raw-fixture.json) · [运行脚本](../../Modules/LibraryCatalog/tests/inspection_real_replay.py) · [实际 Swift/SQLite 调用](../../Modules/LibraryCatalog/tests/InspectionRawProbe.swift)

```sh
python3 Modules/LibraryCatalog/tests/inspection_real_replay.py \
  --manifest specs/033-library-lifecycle/evidence/inspection-raw-fixture.json \
  --scratch "$SCRATCH" --runtime "$RUNTIME" --exiftool "$EXIFTOOL" --sources "${SOURCES[@]}"
```
