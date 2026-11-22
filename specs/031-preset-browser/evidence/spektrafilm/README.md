# 胶片模拟的原生色彩和调性验证

三款配置使用同一份固定版本的 Spektrafilm 分色、显影和扫描实现烘焙。Portra 400 配 Portra Endura 相纸，Velvia 100 直接扫描反转片，Vision3 250D 配 2383 电影发行正片。固定修订提供彩色负片、彩色反转片与彩色相纸／拷贝片配置。其逐像素 LUT 模式关闭自动曝光、颗粒、光晕、空间扩散及扫描锐化。[原始配置](https://github.com/andreavolpato/spektrafilm/tree/3bb2c2d2801ff68b92019cf1dbcbb133d60832bc/src/spektrafilm/data/profiles) · [烘焙参数和原始文件 SHA-256](../../../../Sources/RAWMasterImaging/Resources/PhotoFilters/Spektrafilm/provenance.json)

## 色彩与模型对应

原生显影传入未预乘的线性 sRGB。64³ 采样网格按 sRGB 传递函数分配精度，先把 64 个舍入后的 16 位显示码逆变换到线性光，再交给参考处理器。扫描输出也是线性 sRGB，RGBA32F 图集记录每个节点的输出减去输入。运行时复用 RAWMaster 的 Metal 三线性采样，在线性光中连续调节 0–100 强度。扩展动态范围像素保留越过网格边界的原始有符号残差。原生代码保留输入 Alpha。每款单张图集 4 MiB。[烘焙脚本](../../../../scripts/bake-spektrafilm-filters.py) · [原生滤镜](../../../../Sources/RAWMasterImaging/DevelopmentPhotoFilterEngineV3.swift)

旧 PoC 接收线性 ProPhoto，返回显示编码的 sRGB。复测先将同一线性 sRGB 样片转换到 ProPhoto，再运行旧合同，并单独测量直接使用线性 sRGB 的新合同。在两张实拍、三款配置中，两条输入合同的显示码平均绝对差为 0.051–0.249，局部最大差为 4.93／255。生产图集的精度以直接 sRGB 参考为准。[逐项差异](direct-comparison.json)

## 实拍样本

每行的四列从左到右为原图、Portra 400 / Portra Endura、Velvia 100、Vision3 250D / 2383。每格 160 × 240 像素。下表记录强度 100 时，相对输入原图的 RGB 平均绝对差，以 8 位显示码计。

| 照片 | Portra 400 / Portra Endura | Velvia 100 | Vision3 250D / 2383 |
| --- | ---: | ---: | ---: |
| 逆光人像 | 12.40 | 11.20 | 11.14 |
| 雪地日落 | 10.44 | 11.83 | 11.85 |

在人像上，Velvia 和 Vision3 两者的均值差为 2.31／255，雪地上为 5.14／255。Portra 和另外两者在两张样片上的差异为 8.84–12.47／255。这组数值记录具体照片上的差异，风格偏好与实物胶片匹配度需要另外的观片评审。[人像参考色带](../../../../Tests/RAWMasterImagingTests/Fixtures/Spektrafilm/person.png) · [雪地参考色带](../../../../Tests/RAWMasterImagingTests/Fixtures/Spektrafilm/snow.png)

原生 Metal 实际输出的六组对照均达到 8 位单通道 P99 差 1。平均绝对差 0.021–0.038，最大差 2，出现在人像的 Velvia 输出。Portra 的树影与地面保留了较多暗部层次，Velvia 的红衬衫更饱和，Vision3 / 2383 的雪地天空偏暖。原生用例同时核对 13 组独立显影色样、0–100 六档强度、HDR 边界残差、透明与半透明像素和损坏图集隔离。[原生人像成片](person-native.png) · [原生雪地成片](snow-native.png) · [Metal 逐图差异](native-vs-direct.json)

人像作者 Hung Pham，雪地作者 Sean Liu。RAWMaster 将原作者 RAW 显影到 sRGB 后缩小并制作参考与原生色带，沿用 CC BY-SA 4.0。胶片配置原作者 Andrea Volpato，RAWMaster 贡献者完成采样和图集编码。资源随包包含未经改动的上游授权与独立变更记录。[人像原帖](https://discuss.pixls.us/t/cinematic-portrait-in-golden-hour/54881) · [雪地原帖](https://discuss.pixls.us/t/snow-and-sunset/55869) · [照片许可](https://creativecommons.org/licenses/by-sa/4.0/) · [胶片授权](../../../../Sources/RAWMasterImaging/Resources/PhotoFilters/Spektrafilm/SPEKTRAFILM_LICENSE.txt) · [派生说明](../../../../Sources/RAWMasterImaging/Resources/PhotoFilters/Spektrafilm/CHANGELOG.txt)

## 复现

使用固定修订的 Python 环境运行离线生成器。第二步所需的 sRGB PNG 来自 027 的已定向 RAW 样本。仓库内有两张小型参考色带与直接扫描色块，定向 Swift 测试可离线执行。[参考生成与验证](verify-reference.py) · [027 样片显影方法](../../../027-mask-ai-raw-integration/portrait-snow-validation.md) · [原生验收](../../../../Tests/RAWMasterImagingTests/DevelopmentSpektrafilmTests.swift)

```sh
python scripts/bake-spektrafilm-filters.py "$SPEKTRAFILM_CHECKOUT"
python specs/031-preset-browser/evidence/spektrafilm/verify-reference.py "$SPEKTRAFILM_CHECKOUT" "$RAWMASTER_MASK_FIXTURES"
RAWMASTER_SPEKTRAFILM_OUTPUT="$PWD/output/spektrafilm-native" swift test -c release -Xswiftc -enable-testing --filter DevelopmentSpektrafilmTests
```
