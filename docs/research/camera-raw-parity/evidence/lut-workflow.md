# CUBE 导入和图像渲染

RAWMaster 在全图色彩分级中提供三个顺序 LUT，每个蒙版可以使用一个 LUT。每层保存自己的强度。菜单提供暖色、黑白和已导入的查找表。拖动手柄和上下移动按钮可以调整顺序，选择菜单可以替换，移除按钮可以删除，眼睛按钮可以切换整组效果。[Camera Raw 的操作说明](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/tone-and-color/apply-luts-to-photos-in-camera-raw.html)

导入器读取 2³ 到 64³ 的 UTF-8 三维 CUBE，可以使用 `DOMAIN_MIN` / `DOMAIN_MAX` 或 `LUT_3D_INPUT_RANGE`。ZIP 中的子目录和多张表均可读取。查找表的数据和空间范围纳入 SHA-256。配方内嵌所选表的 Float32 数值，已应用的 LUT 随配方重新打开和备份恢复。当前实现的输入和输出编码为 sRGB，内置两张表由 RAWMaster 自行提供。[模型和解析器](../../../../Sources/RAWMasterCore/DevelopmentColorLUT.swift) · [素材库](../../../../Sources/RAWMasterCore/DevelopmentLUTLibrary.swift)

## 导入耗时

Apple M4 Max，macOS 27.0.1，Release 构建。每次从空目录开始，由应用实际使用的素材库完成文件读取、解析、校验和索引发布。首次另记，下表取之后十次的 p50/p95。计时结束后逐张从磁盘打开，校验内容摘要。ZIP 的两次测量使用相同的 CUBE 成员，优化后的基准固定了 ZIP 文件头的时间。导入耗时独立于打开的照片。[逐次样本](lut-import.json) · [优化前样本](lut-import-before.json)

| 输入 | 优化前 p50 | 优化后 p50 | 优化后 p95 |
| --- | ---: | ---: | ---: |
| 33³ CUBE | 136.38 ms | 4.90 ms | 5.09 ms |
| 64³ CUBE | 603.34 ms | 29.16 ms | 29.30 ms |
| 同时含 33³、64³ 的 ZIP | 733.24 ms | 68.37 ms | 72.43 ms |

解析器按字节识别数值与行边界，将已验证的 RGB Float32 三元组顺序写入一次分配的缓冲区。素材库按表暂存 ZIP 成员，整包均通过校验后发布。复跑可设置 `RAWMASTER_LUT_IMPORT_REPORT` 为新的 JSON 路径，再运行 `swift test -c release --filter DevelopmentLUTImportPerformanceTests`。[独立导入基准](../../../../Tests/RAWMasterCoreTests/DevelopmentLUTImportPerformanceTests.swift)

## 像素与回放验证

Metal 核心在归一化域上采样八个节点进行三线性插值，再在线性工作空间混合强度。相同的 GPU 算子用于交互代理、原始尺寸渲染和蒙版合成。测试覆盖恒等表、通道置换、非默认输入域、半透明像素、零强度、层次顺序、蒙版边界和预览对 16 位导出的像素误差。[图像算子](../../../../Sources/RAWMasterImaging/DevelopmentGradingLUTEngine.swift) · [像素和导出测试](../../../../Tests/RAWMasterImagingTests/DevelopmentGradingLUTTests.swift)

核心测试实际创建 ZIP，重新打开素材库，再删除源 CUBE 和素材库，验证配方可以独立恢复所用查找表。界面会话测试通过正常的配方提交、撤销和重做入口。Adobe 的内置表目录、渲染色彩匹配以及原生手势到画面呈现的延迟仍需单独取证。[配方与导入测试](../../../../Tests/RAWMasterCoreTests/DevelopmentColorLUTTests.swift) · [编辑会话测试](../../../../Tests/RAWMasterUITests/EditingDevelopmentSessionTests.swift)

## LightFlow 的真实 RAW 结果

在独立的 Chrome Headless Shell 157.0.8103.78 中运行 LightFlow 构建 2d41ab1，WebGPU 报告 Apple Metal 3 硬件适配器。输入为 Sony ILCE-7RM5 的 9504 × 6336 ARW，工作纹理为 2400 × 1600。一次首次编辑单记，以随后 20 次计算 p50/p95。计时从提交编辑配方到 `PixelEngine.idle()` 返回，每次在计时结束后还读取 96 × 64 个位置的线性 RGB 样本。[完整样本和二进制摘要](lightflow-lut.json)

| 实际编辑 | warm p50 | warm p95 |
| --- | ---: | ---: |
| 暖色表与黑白表之间切换 | 1.085 ms | 8.090 ms |
| 单层 LUT 强度 | 33.157 ms | 44.115 ms |
| 增加或移除第三层 | 1.535 ms | 3.320 ms |
| 交换暖色表与黑白表的处理顺序 | 1.738 ms | 6.290 ms |
| 径向蒙版内的 LUT 强度 | 26.815 ms | 41.605 ms |

两个强度项目各提交 21 个不同数值并验证图像随数值变化。离散控件交替提交两个真实状态，每次均验证像素改变及恢复的摘要。LightFlow 可在重复离散状态时复用其缓存。浏览器进程未创建前台窗口。[采集脚本](../../../../scripts/performance/benchmark-lightflow.py) · [编辑配方和像素验证](../../../../scripts/performance/lightflow-probe.mjs)

```sh
python3 scripts/performance/benchmark-lightflow.py \
  --chrome output/tools/chrome-157.0.8103.78/chrome-headless-shell-mac-arm64/chrome-headless-shell \
  --raw output/performance/acr-benchmark.ARW --size 2400 --samples 20 \
  --operation grading-lut-select --operation grading-lut-amount --operation grading-lut-stack \
  --operation grading-lut-manage --operation grading-lut-mask \
  --output output/performance/lightflow-lut-repeat.json
```
