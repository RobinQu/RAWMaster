# 快速 Prompt 的模型适配与实图验收

2026-11-22 在 Apple M4 Max、128 GiB、macOS 27.0.1 上，两种模型均从生产 Swift 适配器收到整张和局部两种 1024 × 1024 的 RGB PNG。四个候选都能由新建的 provider 实例凭原尝试恢复。本机适合异步候选，实测等待约两分半。北京 Seedream 5.5 的两次 Swift 请求分别为 9.93 和 9.37 秒。当前样本各范围各一张，足以验证调用与恢复，首次可用率、正式开放的摄影场景和最低硬件仍以 SC-02 留出集评审为准。[功能验收条件](spec.md) · [四次实测的完整摘要、参数和计数](poc/provider-results.json)

## 实图结果

本机与云端沿用两组既有授权样本。NASA 人像和 Pietro De Grandi 湖景的版本、局部裁框、提示文本及字节摘要均已冻结。两条路线使用各自的既有范围样本。以下时间包含 Swift 适配器接收、校验和保存模型候选。作品库采用、画布显示和原生分辨率合成另行验收。[样本来源](../030-ai-retouching/ux-design.md) · [重建四个模型输入](poc/prepare-provider-fixtures.py)

| 模型与范围 | 输入及观察 | Swift 端到端 | 独立入口复核 |
| --- | --- | ---: | ---: |
| FLUX 整张 | NASA 人像请求从画左进入的大面积柔光。面部确实变亮，眼缘、嘴部与领口纹理也发生变化。身份和受光方向需要逐张审阅 | 164.00 s | MLX CLI 158.25 s |
| FLUX 局部 | 从湖景的源像素矩形 (480, 496)–(992, 1008) 取背景上下文，放大为模型输入。牌面和支柱在候选中消失，两只船仍可辨。预先划定的牌面检测区中红色像素从 81.74% 降到 0% | 152.65 s | MLX CLI 148.23 s |
| Seedream 整张 | NASA 正常曝光人像请求画左柔光箱。脸部亮度分布和衣物暗部都改变，头盔高光形状也变化。整张采用前需要比较面部与反光细节 | 9.93 s | 直接调用 12.90 s |
| Seedream 局部 | 从景观源像素矩形 (112, 0)–(624, 512) 取上下文后生成。船只、岸线和主构图可辨。输入中心待消除的亮点不易定位，无法凭这张样片确认清理成功 | 9.37 s | 直接调用 11.53 s |

FLUX 的两份 Swift 输出与相同输入、种子及参数的独立 CLI 候选逐字节一致，MLX 活跃内存峰值分别为 8.10 与 7.96 GiB。Seedream 两次 Swift 实时请求各产生 1 次 POST，各自的回执均报告 1 张输入、1 张生成、4096 输出与总 token。接口未返回货币金额，回执费用保留为未知。实际请求使用 `watermark=false`。上述模型范围是送入模型的冻结图片。最终 Matte 为零的位置能否逐像素保持，还须通过本机影像合成及归档的验证。[FLUX 高分辨率前序调研](../030-ai-retouching/flux-validation.md) · [像素保护与归档合同](contracts/quick-prompt.md)

## 固定能力和恢复

- **本机配置。** 使用现有本地执行槽，只有 `black-forest-labs/flux-3-image-klein` 与 `rawmaster-flux3-klein-mlx-v1` 同时匹配时，控制器才应交给 LocalFluxProvider。用户选择本机 Python、MLX 代码目录及模型权重目录。本次冻结 MLX 0.32.4、16 步、图像和文本 Q8、FP16 VAE。模型输入两边为 64–4096 且均为 16 的倍数，本实现限制 4,194,304 像素，首轮样本预算约 1 MP。模型权重和 Python 环境由用户独立安装。执行器只加载校验过的本地代码、组件清单、词表与权重，并以离线环境运行。[Swift 适配器](../../Sources/RAWMasterAI/LocalFluxProvider.swift) · [进程和组件校验](../../Sources/RAWMasterAI/Resources/flux3_klein_worker.py) · [固定运行时源码](https://github.com/devin-lai/flux-3-image-klein-mlx/tree/a8a400745949770d4de3b18c31684169da4b0af5)
- **本机取消。** 在真实 Q8 任务启动后三秒请求取消，执行器终止并等待 MLX 与上游 CPU 噪声子进程。新 provider 对原尝试得到 `noResult`，接着成功产生上述两张候选。监督进程也观察原应用进程是否退出。作品重开时通过文件锁区分仍在处理、已有可验候选和无结果，完整回执绑定权重、运行时、输入和输出摘要。[取消与恢复入口](../../Sources/RAWMasterAI/LocalFluxProvider.swift)
- **云端配置。** 固定北京方舟图片生成地址、`doubao-seedream-5-5-261028` 与 `rawmaster-seedream-5-5-261028-v1`。冻结单张不透明 8-bit RGB PNG，显式传入宽高。5.5 的图片生成输出需满足 921600–4624220 像素、宽高比 1:16–16:1。当前适配器输入上限 15 MiB，发送单图 Base64，接收单张 Base64 PNG，使用 `background=opaque`。禁止重定向，流式接收 HTTP 字节时累计限制 140 MiB。旧版顺序组图字段仅由原有旧版模型分支使用。[方舟图片生成 API](https://console.volcengine.com/ark/region:cn-beijing/docs/image-generation-api) · [生产传输与请求参数](../../Sources/RAWMasterAI/CloudImageProvider.swift)
- **云端恢复。** 先记录提交意图，同一 run 的并发调用共享排他锁。成功响应须有实际固定模型、远端回执标识、单张可完整解码的 PNG、约定尺寸与全不透明像素。先持久化提供者证据及输出 SHA，再发布图像。断线、型号不符、响应缺损或远端取消未证实时保留结果未知。重开核对只接受与原尝试及文件匹配的证据。公用报告只记录数量与用量，单个服务请求标识保存在私有任务证据中。[验收用例](../../Tests/RAWMasterAITests/QuickPromptProviderTests.swift)

## 复验

1. 在仓库根目录运行 `swift test --filter QuickPromptProviderTests` 与 `swift test --filter CloudProviderTests`。本机用原生 XCTest 同跑这两组，4 项新用例和 8 项既有用例全部通过，覆盖模型与目的地、跨实例防重、输出画幅、透明度、拒绝错误权重、损坏回执和原有供应商路径。
2. 准备 030 已冻结的共有输入，运行下面的命令重建四张 1 MP 输入并将 Swift 驱动链接到本地刚编译的 RAWMaster。生成目录须为空。验证脚本重建的四个 PNG 与本次实际提交的文件逐字节相同。[共有输入制作](../030-ai-retouching/poc/fixtures.py) · [原生驱动](poc/provider-probe.swift)
3. `flux` 从本机已安装的环境生成。目录包含 `venv/bin/python`、`mlx`、`models/q8`。`seedream` 通过受保护的标准输入读取当前授权凭证，每范围最多提交一次，拒绝复用已有输出目录。只需核对已有远端证据时，使用 `seedream-replay`，输入目录需含原始候选 PNG 和各自实际回执。驱动在收到候选后用新的 provider 实例核对恢复和原命令重复调用。

```sh
python3 specs/034-quick-prompt-editing/poc/prepare-provider-fixtures.py \
  --shared-inputs "$SHARED_INPUTS" --out "$FIXTURES"
python3 specs/034-quick-prompt-editing/poc/build-provider-probe.py \
  --products .build/debug --out "$PROBE_BIN"
"$PROBE_BIN/provider-probe" flux "$FIXTURES/flux" "$NEW_FLUX_OUTPUT" both "$FLUX_ENV"
"$PROBE_BIN/provider-probe" seedream "$FIXTURES/seedream" "$NEW_CLOUD_OUTPUT" both <&3
```

最后一条命令采用调用方提供的安全文件描述符 3。正常应用通过已绑定目标的钥匙串读取凭证。以上用例专门覆盖模型适配层，产品的点击到采用、Matte 外保护与重新导出由集成验收分别记录。

本机独立 CLI 材料和肉眼对照位于 `output/quick-prompt-native/flux-provider-baseline/`。Swift 实时 FLUX 私有候选与本地取消记录位于 `output/quick-prompt-native/provider-functional/results/`，实时 Seedream 候选与每范围计数位于 `output/quick-prompt-native/provider-functional/seedream-live/`。这些目录按机器保留，仓库内的验收记录包含四个候选的完整 SHA-256。[可随版本复核的数据](poc/provider-results.json)
