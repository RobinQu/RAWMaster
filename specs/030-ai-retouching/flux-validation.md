# FLUX.3 Image Klein 本机编辑验证

2026-11-22 · `030-ai-retouching` · Apple Silicon 离线推理

**FLUX.3 Q8 可以在离线 Mac 上生成供摄影师审阅的局部清理候选。** 湖面标牌首张即被清除，限定蒙版后保住了附近船只。人像提亮则重画了眼缘、牙齿和肤色。建议保留本机异步“生成局部候选”，由用户对比后应用。“只提面光”默认交给本地人物蒙版与曝光控制。两张照片提供了操作级证据，首次可用率与最低支持机型仍需独立验收。

## 测试对象与摄影任务

本机运行 Black Forest Labs 的 FLUX.3 Image Klein 蒸馏模型，经 `devin-lai` 打包为 MLX Q8。图像 transformer 的 5.6B 参数与 Qwen3-VL-4B 文本编码器分开计数。模型卡列出 16 步、最多 10 张参考图、布局框，并提示框外内容也可能变化。独立 CLI 接收完整场景描述与参考图，输出 8-bit RGB PNG。本次给两个供应方相同的人工定稿英文描述，未运行 BFL 默认的 prompt upsampler。官方推理链、其他量化与本机 Q8 的表现应分别记录。[BFL 模型卡](https://huggingface.co/black-forest-labs/flux-3-image-klein) · [BFL 参考实现](https://github.com/black-forest-labs/flux-3-image-klein) · [MLX 管线源码](https://github.com/devin-lai/flux-3-image-klein-mlx/blob/a8a400745949770d4de3b18c31684169da4b0af5/flux_klein_mlx/pipeline.py)

| 固定项 | 本机配置 |
| --- | --- |
| 设备 | Apple M4 Max，128 GiB 统一内存，macOS 27.0.1，Metal 可用 |
| 权重 | `devin-lai/flux-3-image-klein-mlx-q8@d9790a1ceaba200e8b773fb236f7c9fa754283a7`，组件约 9.58 GiB。该模型包记录 BFL 权重 revision `1755314e2216b2a2c5cc0dd899d4e49ee3404d2c` |
| 引擎 | MLX 0.32.4，`flux-3-image-klein-mlx` 0.1.0，提交 `a8a400745949770d4de3b18c31684169da4b0af5`，`q8-16`，图像与文本均 Q8，VAE FP16，16 步无 CFG |
| 编辑输入 | 单张 1024×1024，保留原始构图。真值、基线与侧车蒙版只用于本地评分和合成。两种模型共用同一份输入 PNG 及指令 |
| 输出与贴回 | 本机原始输出 1024×1024。输入与输出均为 16 的整数倍，此次无填边或缩放。确定性合成使用独立侧车蒙版，可分别审查裸候选及最终照片 |

湖景任务在公开照片右下方水面叠加红色 STOP 牌及立柱，要求清除标牌、保留船只、山脊及湖底纹理。局部蒙版非零区域占全图 1.95%，向内 10 px 羽化，有干净照片作为参照。人像任务在公开宇航员照片的面部人为压暗 1 EV，要求只补亮脸部，眼睛、表情、徽章文字与头盔维持原样。软蒙版非零区域占 5.51%。人像原图为 512²，放大后适合比较局部明暗与结构，毛孔级细节仍需相机原片验收。首轮都使用 seed 8521，然后以 8522 对湖景提出同一请求。[样本与固定提示](poc/cases.json) · [真值、蒙版和原生对照制备](poc/fixtures.py)

## 1024² 同图编辑的实际表现

| 顺序与任务 | seed | CLI 耗时 | 其中模型管线 / 去噪 | 峰值 MLX 活跃内存 / 进程 footprint |
| --- | ---: | ---: | ---: | ---: |
| 1 · 湖面移除标牌 | 8521 | 210.29 s | 205.66 / 201.90 s | 7.99 / 8.78 GiB |
| 2 · 局部面光 | 8521 | 173.71 s | 173.70 / 169.59 s | 7.99 / 8.82 GiB |
| 3 · 湖面移除标牌，再次生成 | 8522 | 153.45 s | 153.44 / 150.51 s | 7.99 / 8.87 GiB |

CLI 耗时从调用入口到返回，包括校验、初始化、模型推理和 PNG 写入。首张在新进程中执行，权重检查花了 4.36 s。后续请求在同一 Python 进程顺序提交。实现为每张图重新加载并释放文本编码器、图像编码器、transformer 和解码器，复用了进程及文件校验缓存。MLX 活跃内存峰值每次运行时清零，系统进程 footprint 是截至该时刻的整个进程最高值。测量时开发机保持日常负载，未清空系统文件页缓存或控制温度。稳定分位数、最低机型和模型常驻收益需要更多独立实验。[运行计时、输入与输出哈希](evidence/flux/timings.json) · [首张 MLX 原始计数](evidence/flux/lake.metrics.json)

第一张湖景候选清除了牌面和立柱，100% 裁切中能看到连续水纹与湖底。裸候选的水面色调偏暖，近船与乘客的局部纹理改变。保护区内有 74.62% 像素的至少一个通道改变超过 8 个码值。端侧按蒙版以线性光合成后，蒙版外最大差归零，原标牌 8,786 个像素相对干净照片的 RGB MAE 为 13.03/255。它可以作为用户可选的局部修复素材。相近水纹在物理上允许多种解，MAE 需要配合 100% 接缝审阅。[首轮湖景原图](evidence/flux/lake.png) · [共同评分算法](poc/evaluate.py)

第二个 seed 也移除了牌和立柱，补入纹理有所变化。合成后的目标 MAE 为 13.20/255，接缝带 MAE 为 1.55/255，首张分别为 13.03 与 1.38。第二张裸候选的保护区中有 78.24% 像素至少一个通道改变量超过 8，贴回后保护区最大差仍为 0。两张来自同一片水面。要判断修复工具对更多题材的首次可用率，仍须分别测试电线、发丝和重复建筑纹理。[复测湖景原图](evidence/flux/lake-repeat.png)

人像候选提亮了面部，100% 下可见眼缘变锐、牙齿轮廓与原图有别，面颊泛红，宇航服上圆形徽章的小字被重画。贴回蒙版能恢复徽章，却会保留发生在脸内的重画。在蒙版 `alpha ≥ 0.5` 的 37,039 像素上，合成结果对真值的 RGB MAE 为 25.91/255。共同评分的线性亮度指标显示，相对干净照片仍欠曝约 0.56 EV。对于“只提面光”，本地人物蒙版和曝光参数能直接满足可控范围、纹理保持与后续再调的需求。[人像原图](evidence/flux/portrait.png) · [共同评分算法](poc/evaluate.py)

## 从真实 RAW 到 61MP 合成的已有证据

| 既有 A7R5 用例，各运行一次 | 模型 / 进程耗时 | 峰值进程 footprint | 用户可见结果 |
| --- | --- | --- | --- |
| 1024² 原生 ROI 加五只飞鸟 | 188.01 / 188.46 s | 8.91 GiB | 实际出现六只，云与地平线被重画，宽羽化矩形在全景可见。61MP 合成、选区外像素差 0 和回放哈希吻合均通过，候选被拒收 |
| 1008×672 整图代理调暖 | 96.12 / 96.27 s | 7.92 GiB | 将平滑色差场加回原生纹理后，画面变暖且总体构图保持。一个 1024² 检查窗在最终量化 8-bit RGB 上的归一化高频 MAE 为 0.0000653，p99 为 0.001419。Python 后处理和 61MP PNG 写出约 50 s，首轮收据为 52.74 s，留存的独立计时文件为 49.73 s |

本次另外解码两份旧 9566×6374 PNG，逐行重算 RGB 像素 SHA-256，均与原收据吻合。原生 ROI 输出为 `22c68062ad2b8ed221fd71d2566111e890b0c2f7c8e7dfb0f45364e802b7ca86`，低频光色输出为 `07c9a4bebf7462dd42e17aa31bf43cde340d0732745e076b64558d957d141bde`。这些高分辨率结果由原片与模型贡献共同构成。ICC、HDR、16-bit 线性回放、生产画布与 canonical 导出仍需在真实链路对齐。[既有协议及实测](../../docs/research/flux3-klein-highres-poc.md) · [全景接缝](../../docs/research/assets/flux3-pixelpatch-overview.jpg) · [光色成片](../../docs/research/assets/flux3-detail-transfer-overview.jpg)

## 接入边界与复测

当前 `LocalComfyProvider.edit` 要求实验配置为 `Qwen-Image-2.1-Turbo` 并检查其研究许可。现有 `RAWMasterMLXEdit` 图的输入载入、提交收据、取消和任务恢复可复用。需要另行增加固定版本的 FLUX 节点、权重清单、归一化 / 坐标收据与安装健康检查。当前 Q8 CLI 会为单张参考图按 4×1024² 像素上限缩放并填到 16 的倍数，多张参考图逐张按 1024² 上限缩放并裁切。如实记录这些变换才能将候选贴回源图。生产硬蒙版要由本地合成器执行。[现有本地 provider](../../Sources/RAWMasterAI/LocalComfyProvider.swift) · [现有 worker](../../Sources/RAWMasterAI/Resources/mlx_worker.py) · [MLX `prepare_reference` 与 `generate`](https://github.com/devin-lai/flux-3-image-klein-mlx/blob/a8a400745949770d4de3b18c31684169da4b0af5/flux_klein_mlx/pipeline.py)

模型权重沿用 FLUX Kommunity License。条文将商业输出生成限于满足条件的使用者，其中含使用者与关联方年化总收入合计低于 500 万美元。商业客户端捆绑或分发权重需要单独确认权利。运行时代码与文本编码器采用 Apache-2.0。本机使用独立量化包并未改变权重许可。[模型权重许可 §§1–3](https://huggingface.co/black-forest-labs/flux-3-image-klein/blob/main/LICENSE.md) · [MLX 代码与权重说明](https://github.com/devin-lai/flux-3-image-klein-mlx/tree/a8a400745949770d4de3b18c31684169da4b0af5)

如需从空环境复测，可按固定提交安装 Apple Silicon 版 MLX 运行时，并按表中 revision 准备同一 Q8 模型包。仓库内已有原始候选，用共同评分脚本复算画质时可以直接读取。从仓库根目录，在已准备好共同输入、权重与固定环境的本机运行下列命令。`--out` 使用新目录，从而保留原始候选、每次请求、原始运行时指标与摘要。[固定 MLX 安装说明](https://github.com/devin-lai/flux-3-image-klein-mlx/blob/a8a400745949770d4de3b18c31684169da4b0af5/USAGE.md) · [固定 Q8 权重](https://huggingface.co/devin-lai/flux-3-image-klein-mlx-q8/tree/d9790a1ceaba200e8b773fb236f7c9fa754283a7) · [复测脚本](evidence/flux-run.py)

```bash
output/research/flux3-klein/venv/bin/python specs/030-ai-retouching/evidence/flux-run.py \
  --model-dir output/research/flux3-klein/models/q8 \
  --inputs output/research/030-ai-retouching/inputs \
  --out /tmp/rawmaster-flux-retouch-replay
```
