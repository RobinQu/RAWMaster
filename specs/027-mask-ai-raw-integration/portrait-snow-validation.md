# 027 · 原生人像、雪景与竖拍方向复核

2026-11-22 · T08 独立功能验证 · Apple Silicon、CIRAWFilter、MaskAI 本地推理

四张作者公开提供的原生 RAW 补齐了旧套件缺少的人像、雪景和竖拍条件。一张街头人像的整人蒙版覆盖了人物；明亮和阴影雪景的响应相差很大，雪地继续留在实验范围。下表的覆盖率是全图中灰度 ≥128 的像素比例。每张图有单独的软遮罩均值、尺寸、实际模型 SHA 和原文件 SHA；样本没有逐像素人工真值。[数据](evidence/raw-fixture-results.json) · [原图与叠加对照](evidence/raw-fixture-review.jpg)

| 原生照片 | 操作与观察 | 覆盖率 |
| --- | --- | ---: |
| 竖幅逆光人物，ARW | 整人检测与分割选中了头、衣服和双腿，地面行李留在选区外。脸部皮肤分支另行输出小范围响应，五官和复杂发丝精度仍需人像留出集 | 整人 9.0235%，面部皮肤 0.1265% |
| 山谷村庄积雪，NEF | 明亮坡地和部分屋顶有响应，但大面积有雪的阴影仍漏选 | 5.2904% |
| 日落前景积雪，ARW | 画面下部雪地清楚可见，无像素达到 128，最大灰度 65 | 0% |
| 栈道猫像，NEF | 无雪对照。最大灰度 70，人物检测明确返回无人物 | 0% |

**方向修复。** 两张竖幅样图首先揭示旧验证工具将 EXIF 8 应用两次。CIRAWFilter 的输出已转正。修复后直接使用该输出，预览与原生裁切采用同一左上角坐标。ARW 人像在 4000×6000 的源坐标显示，分析图为 1600×2400。新增回归逐像素比较解码器参考预览与原生左上四分之一裁切，两项均一致。PNG 再进入独立探针时按原 CLI 上限缩到长边 2048。该流程不计作编辑器或窗口的性能验收。

**放行判断。** 真实人像证明此样本的人物模型链可用。雪地使用 ADE20K 地形先验和颜色启发式，明亮雪地能响应，阴影雪地漏选，无雪图也保留低强度噪声。默认交互可用手工选区；人物部位识别、多人实例和雪地摄影质量须分别建立足够的验证集。[旧版独立 RAW 套件](validation.md) · [编辑器验收](../031-preset-browser/integration-validation.md)

实验装配的场景 ONNX 与从作者权重重新导出的准入版本另做了对照。三张雪类别正反例共 8,392,704 个灰度像素，两次结果逐字节一致。这里的“准入版本”指可选模型包的权重身份，天空、水面和雪的质量仍然各自判定。[权重与逐图差异](evidence/raw-fixture-results.json)

## 来源与复现

照片版权归各自作者，四个原帖均采用 CC BY-SA 4.0。对照图由原始 RAW 显影、缩放并叠加蒙版而成，沿用相同许可。原帖首楼提供 RAW 下载与许可。按表的行序，作者为 Hung Pham、Cristian、Sean Liu、Tyler Smith。[人像](https://discuss.pixls.us/t/cinematic-portrait-in-golden-hour/54881) · [山谷雪地](https://discuss.pixls.us/t/need-help-with-snow-photos/62317) · [日落雪地](https://discuss.pixls.us/t/snow-and-sunset/55869) · [无雪对照](https://discuss.pixls.us/t/schoena-at-the-cottage/57266) · [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)

在包含方向修复的工作树，使用四张与 JSON 中 SHA 一致的原片。文件基名分别为 `person.ARW`、`bright-snow.NEF`、`snow.ARW`、`cottage.NEF`。以下命令从仓库根运行，`cases` 指向含这些原片的目录。模型根采用实验装配的固定版本，独立命令行读取其中的 ONNX Runtime。

```sh
cases="$PWD/output/preset-mask-fixtures"
export MASK_AI_MODELS="$PWD/experiments/MaskAI/Vendor/Models"
swift build --package-path experiments/MaskAI --product mask-ai-probe
probe="$(swift build --package-path experiments/MaskAI --show-bin-path)/mask-ai-probe"
for file in person.ARW bright-snow.NEF snow.ARW cottage.NEF; do
    id="${file%.*}"
    "$probe" raw-info "$cases/$file" "$cases/$id-oriented.png" > "$cases/$id-oriented.json"
done
for target in entirePerson faceSkin; do
    "$probe" people "$target" "$cases/person-oriented.png" "$cases/person-people-$target.png"
done
for id in bright-snow snow cottage; do
    "$probe" landscape snow "$cases/$id-oriented.png" "$cases/$id-landscape-snow.png"
done
MASK_AI_ORIENTATION_RAW="$cases/person.ARW" swift test --package-path experiments/MaskAI --filter RAWOrientationTests
python3 specs/027-mask-ai-raw-integration/evidence/review-raw-fixtures.py "$cases" "$MASK_AI_MODELS" "$cases/review"
```

最后一步使用带 Pillow 的 Python 3.11 或以上版本。文件和像素比较可离线完成。
