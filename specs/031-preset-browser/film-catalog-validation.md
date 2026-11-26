# 九款胶片目录：来源、范围与验证

2026-11-26 · 胶片外观目录由三款扩展到九款。本记录区分目标、原型与实际原生验证；未执行的检查不列为通过。HDR 的目标工作流另见 [037](../037-color-film-hdr/spec.md)。

## 本次交付范围

新增六款使用 Andrea Volpato 的 Spektrafilm 官方胶片／相纸模型和固定默认显影参数。它们不是 bazdesh 等社区作者调制的命名 Look，也不宣称准确复制实体胶片。固定源提交为 `3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`，模型未经修改；烘焙派生资产按 CC BY-SA 4.0 归属和记录变更。

| 目录名称 | 模型路线 | 原始模型标识 |
| --- | --- | --- |
| Portra 400 / Portra Endura | 负片 → 相纸 → 扫描 | `kodak_portra_400` / `kodak_portra_endura` |
| Velvia 100 | 反转片直接扫描 | `fujifilm_velvia_100` |
| VISION3 250D / 2383 | 负片 → 电影拷贝片 → 扫描 | `kodak_vision3_250d` / `kodak_2383` |
| Gold 200 / Ultra Endura | 负片 → 相纸 → 扫描 | `kodak_gold_200` / `kodak_ultra_endura` |
| Portra 800 / Supra Endura | 负片 → 相纸 → 扫描 | `kodak_portra_800` / `kodak_supra_endura` |
| Ektar 100 / Portra Endura | 负片 → 相纸 → 扫描 | `kodak_ektar_100` / `kodak_portra_endura` |
| Provia 100F | 反转片直接扫描 | `fujifilm_provia_100f` |
| Ektachrome 100 | 反转片直接扫描 | `kodak_ektachrome_100` |
| VISION3 500T / 2383 | 负片 → 电影拷贝片 → 扫描 | `kodak_vision3_500t` / `kodak_2383` |

全部是线性 sRGB 输入／输出的 SDR 色彩和调性外观。固定 LUT 模式关闭自动曝光、全图扫描中和、颗粒、光晕、空间扩散与锐化。保留超网格有符号残差只表示数值合同，不代表 HDR 显影、HDR 电影拷贝或 EDR 显示。每款 4 MiB；目录不同时加载九张图集，继续遵守进程共享 32 MiB LUT 缓存预算。

## 从正常入口走查

从[摄影工作台](../../docs/ui/prototype/index.html#edit/development)的资料库选片进入暗房，左栏展开「胶片模拟」。作用于当前照片的当前版本；悬停／聚焦仅临时试看，点击／回车才采用。移除只清除胶片，关闭目录或退出编辑保留原照片、缩放和选片范围。原型的 CSS 色调是交互示意，不作为模型像素证据。

本次复验场景：

1. 九款目录及「Spektrafilm 官方模型 · SDR 色彩外观」均可见；搜索 Gold、Provia、500T 能找到对应项，无匹配时显示空状态，清除搜索恢复目录。
2. 在已调曝光、已裁切或已有蒙版的照片上悬停新款，移开及 Escape 恢复，没有新历史；方向键换焦点、回车采用一次，撤销恢复。
3. 采用新款后强度 0、37.5、100 连续变化，移除或复位不改曝光、裁切、蒙版；保存与重开保留稳定 ID、强度与同一资源身份。
4. 无采用项时强度有禁用原因；资源缺失／损坏不提供假回退像素，其他已验证条目仍可用。资源不依赖联网，取消临时预览不提交；修复资源后的重新启动作为明确重试路径。
5. 窗口收窄、浅／深色外观、长名称、键盘焦点与返回资料库检查。原型与原生使用相同名称和动作。
6. 每款独立参考色样与人像／雪地原生输出比较。逐款核对 0–100 强度、alpha、超网格残差、损坏隔离、便携 CPU／GPU 路线与资源打包，不将历史三款的成绩写成新增六款的成绩。

## 当前验证状态

工作台原型已更新并通过本次内置浏览器的操作走查：九款与 SDR 声明可见，Gold 搜索和无匹配空状态、Escape 取消不写历史、Provia 回车采用、37.5／0／100 强度、移除与撤销、曝光 0.5 保留，以及返回原河谷项目的单张选片均已核对。方向键换焦点后只在回车采用时增加胶片历史。

切换浅／深外观的 `data-theme` 已核对；请求 1440 × 900 和 1000 × 760 视口后，长名称条目仍可搜索与键盘采用。后台 `Page.captureScreenshot` 4 秒超时，未获得本轮浏览器像素截图，故不将长名称视觉裁切、焦点描边或浅深色对比度写成已通过。可从上述入口和动作复现。

九款图集、来源记录和独立参考色样已生成并接入。每张图集严格为 4 MiB，RGB 有限且符合差分范围、alpha lane 为 1，大小与 SHA-256 全部通过；首批三款图集 SHA 与独立参考色样未改变。新目录 SHA-256 为 `73c220dfae5e1a88abf219f48977c58ac7014f70f57ee7e77342b0c4a84644ed`，未修改进程 32 MiB LUT 预算。

便携 `photo_filter` 常规测试通过 5 项；其中默认忽略的真实 GPU 测试另以 `--ignored --exact` 显式执行并通过，因此不是用忽略状态代替 GPU 验收。十八款（九个既有基础滤镜加九款胶片）的图集采样与资源隔离得到覆盖。首次 Swift 复验发现 Gold 200／Ultra Endura 的一个色样误差约 0.000992、Ektar 100／Portra Endura 的一个色样误差约 0.000836，高于既定 0.0007；连续切换还触发共享 LUT 预算。测试阈值、九款输入和 32 MiB 上限均未放宽。

修复分开处理：新增六款用完整 127³ 网格、均匀编码 RGB 域的 Simpson 积分权重拟合 64³ 三线性图集，固定全部立方边界；原有三款保留原始直接节点。独立三线性函数不变、曲面误差降低及全部六个边界的数学回归通过 2 项。九款独立色样的 CPU 最大误差范围为 0.000054–0.000620，仍按 0.0007 验收。CI 图构造和已完成的浮点读回任务在自己的 autoreleasepool 内释放 SDK 临时别名；真正逃逸的图像与未完成的 Metal 命令仍持有实际后备存储。连续切换、CI 图退休别名及未完成 Metal 命令三项原生回归通过。证据色带以已读回的实际像素拼接，不同时保留九个 4 MiB 惰性 LUT 图。

原型自动回归通过包含九款目录、搜索、采用、取消、强度及撤销在内的 15 组相关场景；随后另一个并发变更新增的 Node DAG 场景在导出文档上只改 hash、未返回工作台，报 `Unavailable: [data-act="photo"][data-val="r1"]`。该脚本整体仍失败；本次未修改或跳过该场景。Swift 最终全组复验通过 61 项：目录 3 项、九款胶片 4 项、原生滤镜 13 项、标准渲染接入 6 项、便携集成 6 项，以及涉及浮点读回的局部引擎／分析／资源 29 项。未跳过失败项，亦未修改精度门槛。九款 × 两张照片的真实 Metal 输出相对独立参考，RGB8 均值误差 0.0139–0.0404、P99 为 1、最大为 2。新增六款的所有实拍最大差均为 1。[逐项实拍差异](evidence/spektrafilm/catalog-v2-native/native-vs-direct.json) · [人像原生成片](evidence/spektrafilm/catalog-v2-native/person-native.png) · [雪地原生成片](evidence/spektrafilm/catalog-v2-native/snow-native.png)。

[浅色窄窗原生视图缓存](evidence/spektrafilm/catalog-v2-ui/native-light-narrow.png)能核对九款、来源说明、长名称与撤销后唯一采用项。深色视图缓存未包含正确窗口表面，不能据此验收深色对比度；独立应用正常入口与深色窗口的复验尚未完成。两份视图缓存使用临时资料库和界面测试后端，像素质量结论只取上述真实成像测试。Release 可执行文件已构建成功，但完整 App 打包退出 1：缺少通过固定摘要校验的离线 AI 运行时目录。本轮在默认产物目录、项目 output 中的 v4 归档以及已安装应用的 RuntimeArtifacts 资源目录均未找到可用归档。所需运行时为 `rawmaster-comfymlx-v4-arm64-py312`，catalog SHA-256 仍固定为 `6ae90188e67edc237a0a90ac7bf2d5acf26afcbdff697a4355f599dd9e85ec37`；未放宽校验、下载替代版本或覆盖已安装应用。已生成的部分 `.app` 不作为可运行交付包。补齐经验证的固定归档后，仍须完成独立应用的正常入口与浅／深色真实窗口验收。胶片相关已跟踪变更的 `git diff --check` 通过；本轮未提交或推送。

## 社区作者候选与许可边界

查到了真正调制过的作品，不能用同名 stock 默认组合代替其参数：

- **P800 Vintage**：bazdesh，Portra 800 → Supra Endura，带扫描白校正、不同染料通道 gamma、预闪和滤光等调参。[首发及原始包](https://discuss.pixls.us/t/spektrafilm-presets-share-thread-darktable-styles/59686/1) · [Negs 分享](https://discuss.pixls.us/t/spektrafilm-can-now-run-in-the-browser/61820/1)。作者曾怀疑旧扫描白校正有 bug，不能只把 stock 名复制到新引擎。
- **Clean 修正版**：bazdesh，包括 Ultramax、Ektachrome、Kodachrome、Split-toned 等；应优先于原版，因为作者修正了错误导出的高对比参数。[修正版发布](https://discuss.pixls.us/t/spektrafilm-presets-share-thread-darktable-styles/59686/24)。
- **Velveetia**：bazdesh，Velvia 100 直扫；耦合剂和较高 gamma 有明确创作意图，作者警告黄橙向绿偏移及肤色风险。[发布与限制](https://discuss.pixls.us/t/spektrafilm-presets-share-thread-darktable-styles/59686/8)。

实际包是旧 experimental 分支 GUI-state JSON，输入标为线性 ProPhoto，输出 sRGB；不是 cube。没有独立资产 LICENSE、App 分发授权或准确引擎提交。[论坛默认用户内容许可](https://discuss.pixls.us/tos#3)为 CC BY-NC-SA 4.0，带非商业限制；与官方模型的 CC BY-SA 不是同一范围。因此本次没有把它们或其派生 LUT 纳入可一般分发的 App。非商业本机使用与一般产品内置分发应分别判断，不能将这项限制表述为作者禁止一切使用。

后续内置作者 Look 需要明确的分发／派生授权、实际完整参数映射及原版本参考图。Spektrafilm 的 `digest_params(... lut_mode=True)`会重置胶片和印相曝光、关闭扫描白／黑校正与空间效果；直接把上述 JSON 的少数参数塞进现有烘焙器会丢掉作者效果。必须定义有版本的适配或保留不适合点 LUT 的节点，不能静默近似。

历史 Gold200/Supra Endura v0.3.2 测试 LUT 的 README 明确不是创意 grade，包内携带旧限制性许可，讨论还报告橙红伪影。本次未采用。[历史发布](https://discuss.pixls.us/t/spektrafilm-luts/57879/29)。
