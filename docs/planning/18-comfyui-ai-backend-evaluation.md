# ComfyUI 独立实验与图像后端选型

日期：2026-10-30。用户已批准独立测试 Klein 4B、Qwen-Image-Edit-2511，并要求对相对优胜模型进行 MPS/MLX 对照，同时研究自动安装和云图片 API。正式 RAWMaster 源码、安装应用和真实资料库不在本轮修改范围。

最新验证见第11节：Qwen2.1 Turbo MLX 4-bit 的 ComfyUI 工作流级集成已通过 API、前端出图、像素一致性、队列、取消、故障恢复和显式卸载验证。单鸟主要2像素周期网格定位到VAE解码路径/权重；同latent改用texture-fix解码器后岸边幅度下降约85%，仍非无损修复。实验与正式客户端继续隔离，第10节保留模型比较结果。

实验根目录：`/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030`。

## 1. 本轮范围

- M4 Max、40 核 GPU、128 GB 统一内存，macOS 27.0.1、arm64。
- uv 0.7.4 管理独立 Python 3.12.11；ComfyUI 固定 `b5a432157de6b8884f81104cd02926adf4d597e4`，PyTorch 2.15.0。
- mflux 0.24.0 独立 `.mlx` 环境，不与 ComfyUI 的 `.venv` 混装。
- 六个现有摄影代理样本：人像、鸟群、水边单鸟、岸边单鸟、航拍日出、地面日出。共同比较选择人像、岸边单鸟、航拍日出，每张自然增强和暖色电影调色两种指令。
- 输入是既有 RAW 分组测试的 JPEG 代理，最大边约 960–1024 像素；经明确裁切/缩放，模型输入统一为 832×1216 或 1216×832。没有将其称为完整 RAW 显影或原尺寸摄影成片验收。
- 六个代理均无嵌入 ICC；本轮按普通 RGB/sRGB 工作假设解释，没有完成相机色彩和 ICC 一致性评价。原代理 SHA-256 已逐项复核不变。

独立环境和模型下载已完成。六个基础权重文件合计 73,831,552,434 字节，另有 849,608,296 字节 Lightning LoRA；全部对照固定来源 SHA-256 校验。ModelScope 用作下载源，内容身份仍以固定 Hugging Face revision 的 LFS SHA-256 为准。原片、005 分组真值和基线未改写。

## 2. 已完成的 MPS 结果

| 配置 | 完成范围 | 进程首张，含模型加载 | 暖运行中位数 | 峰值物理 footprint |
|---|---|---:|---:|---:|
| Klein 4B BF16，4 步，ComfyUI MPS | 六张×两指令，另两次暖重复，共 14 张 | 80.8 秒 | 38.6 秒 | 24.8 GiB |
| Qwen-Image-Edit-2511 BF16，20 步，CFG4，MPS SDPA | 一张完整人像质量参考 | 652.0 秒 | 未测 | 62.4 GiB |
| Qwen-Image-Edit-2511 BF16 + Lightning，4 步，CFG1，MPS native attention | 三张×两指令，共 6 张 | 105.4 秒 | 71.7 秒 | 91.0 GiB |

物理 footprint 与 RSS 分开记录，不相加。每 0.2 秒采样；这些是观测峰值，不是驱动分配量或系统整体内存。API 提交至结果校验/落盘为请求耗时；服务启动另计，操作系统文件缓存没有清空。Klein 暖统计含扩展场景与重复，共同子集另在 `results/summary.json` 列出。

Qwen 的 40 步初次尝试在取得成片前因协议调整取消，另有 MPS 参考缩放失败与两步注意力诊断，均保留记录；没有混入成片统计。20 步来自官方 ComfyUI 模板的建议配置；Lightning 是单独的加速适配器，不能把其速度当成未加速 20 步模型的速度。

## 3. 画面观察与候选选择

本轮相对优胜候选为 **Qwen-Image-Edit-2511 + Lightning 4 步**，用于后续后端对照。该结论是小样本工程选择，尚未通过产品发布画质门。

- Klein 的自然修图人像新增两只狗；航拍自然修图新增人物和动物，并把大尺度景观改成近景场景。保留内容的指令没有被可靠遵守。
- Qwen 在共同人像、单鸟和航拍自然修图里更好地保留主体数量和主要构图；人像仍出现肤质、头发、衣物细节重绘，鸟类羽毛也不能视为原始细节恢复。
- 两者均能产生暖色风格变化；Klein 的部分结果调色、颗粒和重绘幅度明显超过“subtle”指令。
- 本轮风格来自 Prompt。Lightning 是加速 LoRA，本轮没有验证专门的风格 LoRA 或 IP-Adapter。
- 以上为对实际输出和局部裁图的研究者观察，未宣称盲测、用户采用率或普遍模型排名。未经进一步研究，不能把生成式整图重绘当成无损基础调色。

## 4. MLX 对照

MLX 实验在 MPS 成片比较及候选选择记录完成后开始。使用相同基础 transformer、text encoder 和 Lightning 文件，不量化。VAE 为原始 Diffusers 布局；194 个张量按 dtype、字节数和内容 SHA-256 的多重集合核对，与 ComfyUI VAE 完全一致，允许命名及 reshape 差异。

MLX 直接调用 mflux；尚未验证社区 ComfyUI-MLX 节点的进度、取消和兼容性。Metal 缓存上限为 8 GiB，模型内存上限沿用运行时默认。相同 seed 不代表两套随机数实现产生相同初始噪声；采样调度、预处理和数值运算也存在实现差异。这是应用处理链对照。

六张 MLX 结果已经完成：模型加载 15.9 秒；首张生成 165.3 秒，加上加载为 181.2 秒；其余五张暖运行中位数 **161.2 秒**，范围 161.0–170.9 秒；包含加载阶段的峰值物理 footprint **68.1 GiB**，峰值 RSS 33.6 GiB。

与同一六张 MPS Lightning 配置相比，本轮 MLX 暖耗时约为 2.25 倍，物理内存峰值约少 25%。当前实现下优先保留 ComfyUI/MPS，MLX 可作为内存优先的候选，不宣称 MLX 普遍更快或更慢。

mflux 在 CFG1 下仍计算条件和无条件两次前向，ComfyUI 的采样路径可省略无条件模型前向，这是两条实现链的重要差别。本轮保留 mflux 原实现，没有为改善结果而修改其采样循环。mflux 也提示 BF16 LoRA 烘焙约保留 85% 的更新幅度、存在舍入限制；原始日志保留。两条链共享原始权重和适配器文件，不保证合并后的数值和像素逐位一致。

MLX 的三种自然修图结果仍保持主体数量，画面与 MPS 不完全相同，细节依然发生生成式重绘。此次为固定顺序的单机应用实验，未做随机交叉顺序、热稳态控制和统计置信区间，不推广为所有 Mac 或其他模型的后端排名。

## 5. Mac 兼容性与运行时安装

Qwen 在 MPS 上触发非整除尺寸 adaptive pooling 不支持错误。仅在独立 ComfyUI 副本的 `TextEncodeQwenImageEditPlus` 中，将参考图 area resize 移至 CPU；模型仍在 MPS 执行。保存了失败 history、源码 patch 和非整除尺寸的数值一致性检查。

已制作约 297 MiB 的未签名离线 runtime-pack 原型，不含模型和用户照片。包内含固定 uv、CPython、平台 wheelhouse、哈希锁、ComfyUI 源码及兼容 patch。通过：

1. 新目录、空缓存、离线 wheel 安装及依赖检查。
2. MPS 算子冒烟与 ComfyUI API/节点健康检查。
3. 带空格的安装路径。
4. 损坏 wheel 被拒绝，活动版本不变。
5. 打包漏掉嵌套 `comfy_api/input` 时，服务启动失败阻止激活；修正后健康检查通过。该失败作为回滚证据保留。

正式方案采用主应用 + 版本化 runtime-pack + 独立模型包。客户端使用预构建 wheelhouse，不现场求解最新依赖、不源码编译、不使用系统 pip；新版本在最终目录建立 venv，全部健康检查通过后原子切换 active 指针。正式 Developer ID 签名、公证和全新 Mac 验收尚未进行。

## 6. 云 API 与配置

Seedream、GPT Image、Nano Banana 采用独立供应商适配器，与 ComfyUI 共享作品和任务合同。云功能不依赖本地 Python 安装成功。

- Seedream：分别配置中国方舟/国际 BytePlus 区域、endpoint、模型或 endpoint ID、凭证和输出能力。
- GPT Image：Images edits 为基础图片编辑入口；多轮 Responses 路径另设能力配置。
- Nano Banana：保存实际 Gemini 模型 ID，采用 Gemini 原生图文接口，保留所选版本要求的会话元信息。
- key 存 Keychain，配置只存引用；新 endpoint 不自动继承旧凭证。mask、参考图、尺寸、seed、流式、轮询和取消按供应商/模型分别提供。
- 提交超时保留“结果未知”，不盲重试可能已执行的生成请求；关闭 HTTP 不等于远端取消或不计费。结果 URL 及时下载校验，归档后才成功。
- 本地失败不自动切云；上传当前明确选择的渲染副本。没有执行付费图片编辑 API、读取用户 API key 或将样本发给 Seedream/GPT Image/Gemini 图片编辑接口。

详细设计见 [19 安装与云 API](19-ai-runtime-and-cloud-providers.md)，实验目录另有 `deployment-and-providers.md`、`provider-profiles.example.json`。实际账号访问、云画质、延迟和费用仍待凭证配置后的单独联调。

## 7. 证据与后续边界

- [交互式图片对照](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/comparison.html)
- [逐图结果与统计](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/summary.json)
- [安装和云 API 详细设计](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/deployment-and-providers.md)
- [运行时原型包](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/distribution/RAWMaster-AI-Runtime-arm64-lab.tar.gz)

008 R04/T07 尚需完整 RAW/高分辨率、色彩、更多机型/场景、资源预算和实际离线边界验收；本轮没有把其整体标为完成。正式客户端接入、模型自动安装 UI、Keychain 和云 API 实现另行安排。

下一步按用户最新要求，优先筛选更轻量的本地编辑模型（见第 8 节）。Qwen-Image-Edit-2511 保留为画质参考，前文的“相对优胜”仅适用于已测两模型，不作为客户端默认模型推荐。当前约 91 GiB 的 MPS 进程不适合无预算地长驻在摄影客户端后台；首轮保持单任务，按需启停专用 worker。云 API 的账号联调独立于本地环境实施。

## 8. 轻量模型补充调研（2026-10-30）

本节保留候选调研时的判断；用户随后批准补测，实际结果见第 9 节。参数标签通常只描述图像去噪网络，编码器、VAE、激活和注意力缓存均需另外计入；Mac 使用统一内存，CUDA 的显存数据不能直接换算为本机进程 footprint。量化主要降低权重内存，不能预先保证同比加速或保持画质。

| 候选 | 图像模型与编码器，标称规模 | 推理与编辑入口 | 本轮判断 |
|---|---|---|---|
| LongCat-Image-Edit-Turbo | 6B + Qwen2.5-VL-7B 级编码器 + VAE | 8 步、CFG1；官方确认 ComfyUI 支持；Apache-2.0 | 首选新增候选。图像模型远小于 Qwen 20B，但全套 BF16 仓库仍约 29.3 GB，不应称为“整套 6B”。MPS 兼容、内存和耗时待测。 |
| OmniGen2 | 4B 图像网络 + Qwen2.5-VL-3B 级编码器 + VAE | 指令编辑；ComfyUI 已支持；Apache-2.0 | 第二候选，总体权重更小。普通多步采样未必比 4 步 Qwen 更快，须同时测步数、画质与耗时。 |
| 现有 FLUX.2 Klein 4B 的 MLX 轻量配置 | 4B + 实验性 0.6B 编码器 + 220M 适配器 + VAE | 4 步；mflux 支持编辑、4/8-bit 和 small-text-encoder | 可复用基础权重作资源对照；小编码器有细节漂移和 256-token 限制，不能假定能修复已测的主体新增错误。 |
| FLUX 3 Image Klein | 5.6B + Qwen3-VL-4B + VAE | 蒸馏版 16 步，单/多参考图编辑；MLX 已有实现 | 备选。官方要求完整场景描述，默认提示词扩写器另有 9B，不能漏算；可由其他 LLM 提供场景描述。权重为自定义 Kommunity 许可。 |
| Fibo 2.0 Edit Turbo | 约 8B（mflux 记为 8.1B）+ Qwen3-VL-4B + VAE | 4 步；mask、多参考图；ComfyUI 与 MLX 入口 | 掩膜编辑备选；权重 CC BY-NC，商业产品需另行授权。官方 bria-vgl 示例还调用 Gemini，离线测试须改为本地提供结构化提示，不可默认称整条链离线。 |

LongCat 官方示例的约 18 GB 显存来自 CUDA + CPU offload，既不是本机实测，也不是系统总内存需求。mflux 给出的 Klein 小编码器权重内存和其他机器速度同样不能填入本机成绩表。两者都只是测试优先级依据。

### Ideogram 的定位

- Ideogram 4.0 已有开放量化权重，并非只能调用云 API。官方图像模型为 9.3B，另用 Qwen3-VL-8B 编码器；HF NF4 页面显示的“5B”不能当作模型裁剪至 5B 的依据。官方 NF4 路径面向 CUDA，Mac 可考察 mflux 的 MLX 转换量化路径。
- 然而当前开放版本主要是文生图。mflux 明确列出 image-to-image 尚不支持；已有 ComfyUI 模型支持和 scheduler 也不等于存在经过验证的指令修图流程。因此不进入当前照片编辑对照的首批。
- Ideogram 4.5 主打精准编辑，已在官方应用和 API 提供。截至本次核查，官方 HF 组织只列出 4.0 的三个量化仓库，未找到可下载的 4.5 权重；当前归入云编辑候选，权重发布后再评估本地版本。
- 4.0 权重不是 Apache-2.0：公开权重有非商业条款，商业客户端分发/客户使用需核对相应授权；不能把推理代码许可等同于模型许可。

### 下一轮实验建议

先在现有独立实验环境，以同三张人像/鸟类/航拍、同两种编辑意图、约 1MP 输出，比较 LongCat Turbo、OmniGen2 和 Klein MLX 量化配置；先做每模型一张内容保持冒烟，再决定是否展开六图。新模型使用各自推荐的提示与调度，同时保存完整配置，不能通过压到同样 4 步来制造公平。对出现内容新增的样本另外试短指令/参考图控制，并单列结果。

建议把“1MP 峰值进程 footprint ≤24 GiB、暖耗时 ≤30 秒、无新增主体”作为待讨论的轻量配置筛选目标，不是已验证能力，也不代表已能支持 16/24GB Mac。先记录模型加载、编码、去噪、解码的内存与时间，再决定量化和逐阶段卸载；保持已有 Qwen 成片作为画质参考，暂不接入正式客户端。

本节来源：

- [LongCat 官方仓库](https://github.com/meituan-longcat/LongCat-Image)、[Turbo 模型卡](https://huggingface.co/meituan-longcat/LongCat-Image-Edit-Turbo)、[完整文件规模](https://huggingface.co/meituan-longcat/LongCat-Image-Edit-Turbo/tree/main)。本机已固定 ComfyUI 的 `supported_models.py` 和 `text_encoders/longcat_image.py` 也存在相应实现，尚未执行该模型。
- [OmniGen2 论文](https://arxiv.org/html/2506.18871v4)、[官方代码](https://github.com/VectorSpaceLab/OmniGen2)、[模型与许可](https://huggingface.co/OmniGen2/OmniGen2)。
- [Klein MLX 小编码器](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/flux2/README.md)、[FLUX 3 官方模型卡](https://huggingface.co/black-forest-labs/flux-3-image-klein)、[Fibo Edit Turbo 官方模型卡](https://huggingface.co/briaai/Fibo-2.0-edit-turbo)。
- [Ideogram 官方代码与 9.3B 规模](https://github.com/ideogram-oss/ideogram4)、[MLX 能力边界](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/ideogram4/README.md)、[4.5 官方编辑页](https://ideogram.ai/models/4.5/)、[官方权重目录](https://huggingface.co/ideogram-ai)、[许可说明](https://ideogram.ai/licensing/)。

## 9. 轻量候选实测完成（2026-10-30）

### 范围与统计

新增 31 张主测成片：LongCat Turbo 六张，OmniGen2 一张完整 20 步预筛，Klein 标准/小编码器 × 原/短指令各六张，共 24 张。另保留七张成功的冒烟/诊断输出与一轮 LongCat 缩放失败；它们不混入主测指标。OmniGen2 两步 native 注意力输出仅作算子与资源诊断，不作画质或完整 20 步耗时依据。

沿用同三张人像、岸边单鸟、航拍 JPEG 代理，同一中心裁切和 Lanczos 归一化到 832×1216 或 1216×832，seed 20261030。原/短指令都分别完成自然增强、暖色电影调色两种意图。原长指令完全沿用第一轮；短指令是观察到主体新增后单列的提示词敏感性实验，不能把改善独自归因于量化或后端。三个原图场景很少，结果不是跨图库可靠性或盲测排名。

继续使用同一 M4 Max 128GB、ComfyUI 固定 commit、PyTorch 2.15.0、mflux 0.24.0（MLX 0.32.4）；没有新装依赖或更新正式客户端。GPU 串行执行。Klein 主测统一为 4-bit 量化配置、4 步、2 GiB Metal 缓存上限；标准编码器为 Qwen3-4B，小编码器为 0.6B + 220M 适配器，适配器保留 FP32。并非所有组件张量都以 4-bit 计算/保存。模型加载与现场量化另外记录，首张冷耗时包含两者，服务启动不计入请求耗时；暖统计为剩余五张，涵盖图像和指令变更。系统没有隔离其他日常应用，起始已有约 9.6 GiB swap，结束约 9.3 GiB；没有清空文件缓存或做随机交叉顺序。

| 配置 | 主测成片 | 首张含加载 | 暖中位数 | 峰值进程 footprint |
|---|---:|---:|---:|---:|
| LongCat Turbo BF16，MPS，8 步，PyTorch attention | 6 | 81.1 秒 | 90.2 秒 | 36.5 GiB |
| OmniGen2 FP16，MPS，20 步，双 CFG 5/2，PyTorch attention | 1 | 577.5 秒 | 未测 | 47.3 GiB |
| Klein MLX q4，标准编码器，原长指令 | 6 | 27.8 秒 | 30.0 秒 | 9.9 GiB |
| Klein MLX q4，小编码器，原长指令 | 6 | 33.1 秒 | 29.1 秒 | 9.3 GiB |
| **Klein MLX q4，标准编码器，短指令** | **6** | **30.7 秒** | **30.2 秒** | **9.7 GiB** |
| Klein MLX q4，小编码器，短指令 | 6 | 29.1 秒 | 28.6 秒 | 9.1 GiB |

footprint 和 RSS 分开保存在 `summary.json`，不能相加，也不能把 footprint 称为独立 GPU 显存。MLX 加载阶段的观测峰值也计入表内峰值。不同模型步数、精度、提示和实现不同，本表比较应用处理配置，不隔离某一种硬件或量化因素。第一轮 Qwen Lightning 的 71.7 秒 / 91.0 GiB 仍可在对照页查看，但不能把新短指令效果当成与旧长指令严格相同的实验条件。

### 画面观察与取舍

- **LongCat Turbo**：六张均未见明显新增人物/动物，主要构图和河道尺度保持较好。人像脸部、头发和服装，鸟类羽毛/腿部以及地面纹理仍被重绘。电影指令生成明显暖色和颗粒。内存小于 Qwen Lightning 当前配置，但暖耗时更长，不能因“6B”称其更快。
- **OmniGen2**：完整 20 步人像新增一只大型动物，并明显改变脸部、地面和背景观感；577.5 秒 / 47.3 GiB 不符合本轮轻量方向。随后两步 native attention 诊断为 44.8 秒 / 32.3 GiB，说明注意力实现有影响，但不是 20 步画质或速度结果。因首张内容保持与资源筛选未通过，不展开六图；没有鸟类/航拍、暖运行或短指令画质结论。这是当前 MPS 配置的排除依据，不是所有后端上的模型排名。
- **Klein 标准编码器、原长指令**：人像和单鸟自然增强保留主体，但航拍仍新增人物/动物并改变尺度；电影调色有强烈暖色、暗角和颗粒。量化没有可靠解决第一轮内容新增问题。
- **Klein 小编码器、原长指令**：人像新增狗，鸟类图新增其他动物/人物，航拍也新增人物/动物。是完整六图中的实际失败，全部保留，不能只展示改好提示词后的样本。
- **两套 Klein 短指令**：在本轮六张中均未见上述新增人物/动物，航拍主要尺度保留。小编码器自然增强偏暖，电影调色更强；标准编码器也有纹理/面部重绘，电影调色远超“subtle”。同一模型/seed 改提示词后结果改变，支持存在明显的提示词敏感性，尚不足以证明长指令中某一个词是唯一原因。

因此，轻量后续验证优先选 **标准编码器 + q4 + 短指令**。小编码器相对该配置只少约 0.6 GiB、快约 1.7 秒，却对原长指令表现出更严重的内容新增，不作为默认候选。该取舍不是宣布标准编码器适合无人审核的整图精修；如果要求原始脸部/羽毛、精确颜色和几何不被改变，这批生成式整图编辑均未完成验收。应继续验证受控局部编辑、原尺寸合成或仅生成显影参数的方案。

### 资源与安装发现

1. 将标准 Klein q4 的 Metal 缓存上限从 8 GiB 改为 2 GiB，同一人像/原指令/seed 的解码 RGB 像素 SHA-256 完全一致，单张峰值从约 16.1 降为 9.9 GiB。耗时分别约 31.0 与 26.8 秒，但单次顺序试跑不作为加速比例结论。主测两套编码器均采用 2 GiB 上限。
2. LongCat 的完整八步注意力冒烟中，native 为 98.8 秒 / 39.1 GiB，PyTorch 为 97.9 秒 / 36.0 GiB，选择后者展开主测。冒烟与主测的模型/文件缓存状态不同，均原样记录。
3. LongCat 在 `TextEncodeQwenImageEdit` 也触发 MPS 非整除 area resize 不支持。实验副本新增同一窄范围 CPU 缩放修复，按 PyTorch 2.15.0 命名原因；与 CPU 参考数值完全相同，模型继续在 MPS 推理。旧 runtime-pack 没有自动重打包，不能据此宣称旧安装包已通过 LongCat 冒烟。
4. 新增八个权重文件均按固定 HF revision 的 LFS SHA-256 校验；小编码器 config 另对照固定 Git blob 身份。LongCat 复用上一轮已校验的 7B 编码器；Klein MLX 使用固定官方 Diffusers transformer/VAE，标准编码器链接已有权重。来源、布局、量化和实现都有记录，不宣称与 MPS 像素/噪声逐位一致。
5. MLX 仍直接运行独立 mflux，不是已验证的 ComfyUI MLX 节点。9–10 GiB 的本机进程峰值不等于已证明 16GB Mac 可用。此次也未测试预量化分发包、完整 RAW/高分辨率输出、ICC 一致性或正式客户端接入。

### 证据

- [更新后的图片对照与模型列开关](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/comparison.html)
- [全部主测指标与逐图文件](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/summary.json)
- [补测完整性校验](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/candidate-validation.json)：新增 31 张、报告合计 58 张成片哈希/尺寸、151 个本地引用、六个来源代理不变；结束无实验推理进程。
- [OmniGen2 预筛决策](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/candidate-research/omnigen2-screen-decision.json)、[缓存配置像素一致性](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/candidate-research/klein-cache-selection.json)。
- [原指令航拍对照](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/candidate-review/shared/dji187-context376.jpg)、[短指令航拍对照](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/candidate-review/short/dji187-context376.jpg)、[短指令人像局部对照](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/candidate-review/short/portrait-details.jpg)。

所有补测推理在独立环境执行，未调用付费云图片编辑 API，没有修改正式客户端源码、安装应用、真实资料库或样本原件。报告与原始输出仍存本机。

官方来源（第一轮）：

- https://github.com/Comfy-Org/ComfyUI
- https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_qwen_image_edit_2511.json
- https://huggingface.co/Comfy-Org/Flux-2-Klein-4B
- https://huggingface.co/Comfy-Org/Qwen-Image-Edit
- https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning
- https://github.com/mflux-community/mflux
- https://docs.astral.sh/uv/pip/compile/
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developers.openai.com/api/reference/python/resources/images/methods/edit
- https://ai.google.dev/gemini-api/docs/image-generation
- https://docs.volcengine.com/docs/ark/image-generation-api?lang=en

## 10. Qwen-Image-2.1-Turbo 独立评估（2026-10-30）

### 模型与集成路径

该模型同时支持生成与参考图编辑，不是只支持文生图。约 7.1B 图像 transformer 之外，还使用独立的 8B 级 Qwen3-VL 编码器；原始 transformer、编码器和 VAE 四个权重文件合计 32,440,133,648 字节，不能只按图像 transformer 的规模估算安装或运行需求。

现有固定版本 ComfyUI 已有 `TextEncodeQwenImage21`、`QwenImage21Cache` 和原生采样支持，可在独立客户端服务模式下使用。原生固定八步、CFG1、参考前缀 KV 缓存与专用 sigma 调度；没有复用 2511 Lightning LoRA。本轮关闭提示词增强，不下载额外的提示词增强模型，不使用 mask、小编码器、降低编辑强度或自动验证/重试。MLX 使用独立 mflux 的 `QwenImage21Edit`，不是已验证的 ComfyUI MLX 节点。

**许可直接影响产品选择。** 本模型采用 Qwen Research License，第 2 节限定非商业研究/评估，商业使用需要另行商业许可。本机独立研究不代表已经取得正式商业客户端的使用、打包或分发授权。不要沿用 2511 的 Apache-2.0 假设，也不要把推理代码的许可当成模型许可。本轮没有联系许可方或分发新模型包。

来源：[官方模型卡](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo)、[官方 LICENSE](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo/blob/main/LICENSE)、[官方 ComfyUI 编辑工作流](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_qwen_image_2_1_turbo_image_edit.json)、[Comfy 权重](https://huggingface.co/Comfy-Org/Qwen-Image-2.1)、[mflux Qwen21 说明](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen21/README.md)。

### 测试口径

继续使用同一 M4 Max / 40 核 GPU / 128GB 统一内存、三张既有 JPEG 代理和自然增强/电影调色两种原长指令，seed 20261030；没有修改正式客户端、已安装应用或资料库。GPU 串行执行，不更新现有 Python 依赖。模型固定到 `fc13ba1986fcb905854dc8de2f52eee395f49b5b`，Comfy 权重固定到 `aacf31a6d48e707f352ecba714cee0680da3479b`。

2.1 主测按 32 像素对齐归一化为 832×1248 / 1248×832（约1.04MP）。新增 MPS / MLX 配置的输入 RGB 像素一致；旧 2511/Klein 为 832×1216 / 1216×832，面积相差约2.6%、中心裁切略有差异，不能声称与旧结果归一化像素完全相同。代理最长边只有约960–1024像素，无 ICC，本轮仍不是原尺寸 RAW、相机色彩或原始细节验收。

MPS 主测为 BF16 图像 transformer、运行时 FP16 文本编码器、BF16 VAE；MLX 全精度参考保留 BF16 图像/编码器与 FP32 VAE。MLX q4/q8 量化符合条件的图像与完整文本/视觉编码器层，VAE 保持 FP32；并非整个链路都以4/8位计算。MLX Metal 缓存上限2GiB。加载及现场量化计入首张冷请求，服务/Python启动另计；暖中位数来自余下五张，含图像/指令变更。每0.2秒观测进程 footprint/RSS，包含加载峰值，两者不相加，不称为独立显存。未清空 OS 缓存或隔离日常应用，本机起始已有 swap；不能把后端差异单独归因于硬件或量化。

### 已完成结果与取舍

本轮新增24张实际输出：三套配置各六张主测、q8一张完整八步参考、另五张冒烟/诊断。报告纳入19张新增主测/参考，与旧58张合计77张；冒烟和分辨率诊断单列。q8因首图资源代价没有优势而保留单张参考，不宣称其他场景画质或暖中位数。

| 配置 | 成片 | 首张含加载 | 暖中位数 | 峰值进程 footprint |
|---|---:|---:|---:|---:|
| 旧 Qwen2511 + Lightning，MPS，4步参考 | 6 | 105.4秒 | 71.7秒 | 91.0GiB |
| Qwen2.1 Turbo，MPS，8步 | 6 | 69.8秒 | 69.3秒 | 38.4GiB |
| Qwen2.1 Turbo，MLX BF16，8步 | 6 | 69.1秒 | 63.6秒 | 42.8GiB |
| Qwen2.1 Turbo，MLX q4，8步 | 6 | 69.1秒 | 69.2秒 | 22.1GiB |
| Qwen2.1 Turbo，MLX q8，单张8步参考 | 1 | 96.0秒 | 未测 | 28.7GiB |

1. **MPS 是现有 ComfyUI 的直接可行路径。** 本轮约69.3秒/38.4GiB，相对旧2511 Lightning配置的71.7秒/91.0GiB，最明显改善是内存。两者注意力实现、模型、调度、精度和裁切有差异，不是隔离变量的架构速度比较。
2. **MLX BF16 本轮稍快，q4 内存最低。** BF16暖中位数63.6秒、峰值42.8GiB；q4为69.2秒、22.1GiB，不能称量化带来了加速。q4六张的宏观内容保持接近BF16，但脸部/布料/纹理不同，没有盲测或“量化无损”结论。q8首张含加载96.0秒、28.7GiB，未显示本机资源优势，因此没有展开六图。
3. **三套六图主测均未见明显新增人物/动物，主要主体和场景尺度保留。** 2.1人像自然增强比旧2511样本更接近原图的整体观感，电影调色也较克制；这只是本轮样本观察，不是普遍排名。脸部、头发、衣物褶皱、羽毛、腿部、地面和云层仍有生成式重绘，不能当作原始摄影细节恢复。
4. **1MP 单鸟有规则网格纹理。** MPS改用FP32 VAE后仍存在，MLX BF16/q4也可见；不能归因为单一VAE精度问题。改到约4.15MP后纹理减轻，但仍有重绘，不证明根因或原始细节恢复。以下均为含加载的单次完整八步请求，不混入暖统计：

| 单鸟诊断 | 请求耗时 | 峰值 footprint | 解释 |
|---|---:|---:|---|
| 1.04MP，MPS FP32 VAE | 71.8秒 | 42.1GiB | 规则纹理仍存在 |
| 4.15MP，MPS FP32 VAE | 440.6秒 | 57.6GiB | 规则纹理减轻，仍有重绘；输入只是同一代理放大 |

技术研究优先保留 **Qwen2.1 Turbo / MLX q4** 作为约1MP、低于本轮全精度内存占用的候选，同时保留 **ComfyUI MPS** 作为直接集成参考。它仍比 Klein q4 短指令的30.2秒/9.7GiB更重；Klein则有已记录的长指令新增主体问题。不能宣布某一个配置已经胜任所有摄影精图场景。正式客户端默认模型暂不替换：2.1尚有研究许可、规则纹理、细节保持，以及MLX服务桥接未验收的问题。


### 安装与证据边界

原始四个权重与额外 Comfy VAE 均按固定 HF revision 的 LFS SHA-256 校验。Comfy transformer 通过重排原始 BF16 张量头部与拼接 gate/up 行取得，没有数值转换；文件 SHA-256 与官方 Comfy 文件完全相同，避免额外下载约14.2GB。两套 VAE 的238个张量按 dtype、字节数及内容 SHA-256 多重集合完全对应，允许命名/reshape差异。实验有两套布局供交叉验证，不能把本目录总磁盘占用当成最终安装包最低体积；预量化包与新 runtime-pack 尚未制作或验收。

MLX 原始输出含接近不透明的 RGBA，逐图 alpha 范围及不透明像素比例保存在校验记录，不能称为严格不透明。原始 PNG 不做改写；拼图只在查看时合成白底。正式接入前还需要明确 RGB/alpha 输出策略、ICC/相机色彩、原尺寸合成、身份/纹理保持与内存较小机型的验收。128GB 本机观测峰值不能证明24/32/64GB Mac的可用性。

- [图片对照及后端列开关](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/comparison.html)
- [逐图指标](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/summary.json)、[本轮协议](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/qwen21-research/protocol.json)
- [本轮完整性校验](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/qwen21-validation.json)、[画面观察](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/qwen21-research/quality-progress.json)
- [人像对照](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/qwen21-review/burst123.jpg)、[单鸟局部/分辨率诊断](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/qwen21-review/bird-detail-diagnostics.jpg)、[航拍对照](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/results/qwen21-review/dji187-context376.jpg)

历史第9节的58张/151引用校验保留为当时记录，不被本轮覆盖。没有付费云图片编辑调用，没有改写原样本或正式客户端，也未把这些权重放入已有安装原型。

## 11. ComfyUI / MLX 4-bit 集成与单鸟网格诊断（2026-10-30）

### 集成范围与实测

新增独立目录 `/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21`，不修改 ComfyUI 核心或 mflux 安装源码，也不接正式客户端。ComfyUI 作为 CPU 工作流宿主，白名单加载本次实验节点；整个 Qwen2.1 MLX 推理在已有 `.mlx` 环境的独立常驻子进程中执行，使用本机 JSON 管道及 PNG/latent 文件交换。没有新增推理端口、依赖安装或付费云图像调用。

这是工作流级适配，**不是把原生 KSampler 的 MODEL/CLIP/VAE 改为 MLX**。实验节点输出原生 RGBA、用于再次解码的自定义 latent 句柄和 receipt；标准 LoadImage / SaveImage 与队列仍由 ComfyUI 执行。固定八步、CFG1、完整编码器、q4符合条件层、2GiB Metal缓存、参考KV缓存及FP32 VAE均沿用前轮配置。Comfy中间结果缓存关闭，以保证测试实际执行；MLX模型常驻可复用。

| 请求 | API提交至history | worker请求 | worker峰值footprint |
|---|---:|---:|---:|
| 单鸟首张，含加载 | 66.29秒 | 64.44秒 | 22.42GiB |
| 人像暖请求 | 63.62秒 | 63.26秒 | 21.30GiB |
| 航拍排队请求 | 131.84秒，含等待 | 68.05秒 | 21.30GiB |
| 单鸟相同输入/seed重复 | 68.01秒 | 67.68秒 | 20.12GiB |

三个暖请求worker中位数67.68秒。API包含子进程启动、图像交换及SaveImage，Comfy服务启动另计；worker冷请求包含加载与现场量化。两份独立0.2秒采样可能错过短暂峰值；逐请求另存宿主+worker同步footprint求和，但共享页未去重，不能称为系统唯一占用或独立显存。与前轮运行顺序/缓存不同，不据此宣称桥接更快。

已验证：

- 人像、单鸟、航拍自然增强三张，与原独立MLX q4脚本的RGBA像素完全一致；标准SaveImage也保持四通道。单鸟重复、取消后重载、异常退出后重载均复现相同像素。
- 两张独立API请求在同一worker排队串行执行；实际history中的前一张结束时间早于后一张开始时间。
- 不支持的双图batch明确返回执行错误；取消请求会终止worker，后续请求可重新加载。额外外部杀死worker后，Comfy返回错误，队列和宿主继续可用。
- 显式卸载节点终止MLX进程；独立启动器通过健康检查、节点注册、前端HTTP和退出测试。
- 前端实际导入 `workflow.ui.json`，核对固定seed与1024设置，点击Run，原版/texture-fix双分支均生成1248×832图像；API记录与截图保留。

当前Comfy内置 `/free` 没有管理这个外部worker；需使用 `Qwen21MLXUnloadLab` 或关闭本实验服务释放MLX。正式产品前仍需统一模型生命周期/空闲卸载、内存预算及与原生MPS任务的调度，不能把这个原型当成已完成通用后端替换。

### 网格的受控定位

先保存同一单鸟请求的最终去噪latent，再用原版和texture-fix解码，参考编码、提示、噪声、调度均不变。原版再次解码与生成输出RGBA逐像素相同。另将归一化原图转为不透明RGBA，用原版VAE编码，并用两个解码器分别重建；该控制完全不经过DiT，参考编码器保持原版。两套解码均为FP32，没有增加去噪步数、放大输出或施加去网格滤镜。

测量为高通亮度按2×2像素相位折叠后均值图的标准差，按0–255单位表示；另存水面、岸边、鸟类ROI与FFT邻频比。它是周期纹理指标，不是主观画质分数；更大周期的相位折叠可能包含2像素谐波，不据此宣称存在多个独立网格。

| 图像 | 全图P2幅度 /255 | 岸边P2幅度 /255 | 原图重建RGB PSNR |
|---|---:|---:|---:|
| 归一化原图 | 0.0005 | 0.0224 | — |
| 编辑latent，原版解码 | 0.7727 | 1.0979 | — |
| **同一编辑latent，texture-fix解码** | **0.1381** | **0.1642** | — |
| 原图编码后，原版重建 | 0.3197 | 0.4853 | 43.42dB |
| 同一原图编码，texture-fix重建 | 0.0320 | 0.0231 | 43.24dB |

单鸟编辑结果全图P2幅度降低约82.1%，岸边降低约85.0%，局部图中规则网格明显减轻，但仍有残余。原图编码/解码控制也显示原版解码器可引入该周期成分，因此本样本主要网格来源指向**VAE解码路径及权重**，不需要DiT才会出现；尚未确认具体层或训练原因，也不排除其他配置有DiT伪影。此前仅切FP32精度未解决，并不能排除VAE权重的问题。

texture-fix是非官方生成式微调解码器，改变了细节重建方式。该原图重建PSNR略降，而MAE由0.8900降至0.8745，说明误差分布也改变了；不能称为无损修复或原始摄影细节恢复。补充复用已保存的人像/航拍latent只做修复版解码，未见明显新增主体，脸部、布料、地面/云层细节仍会变化，没有盲测或跨图库可靠性结论。实验保留原版结果与可选修复分支，不自动覆盖原版。

### 交付与证据

- [新的集成/网格对照报告](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/report.html)、[界面出图截图](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/results/workflow-completed.jpg)、[同latent局部2倍对照](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/results/grid/before-after-2x.png)
- [独立启动器](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/Start-ComfyUI-MLX-Lab.command)、[界面工作流](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/workflow.ui.json)、[API工作流](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/workflow.api.json)
- [API验证](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/results/api-main-checks.json)、[故障/解码/卸载验证](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/results/api-extra-checks.json)、[周期纹理测量](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/results/grid/measurements.json)、[最终审计](/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030/integration-qwen21/results/validation.json)

texture-fix固定到 `9a10df811f183323e4e94d255c18add1924ce340`，FP32 Diffusers权重1,350,989,544字节，SHA-256 `9c4a3e6b970fe82e99fae227b70529646427333c4378a51b2e853c93f492a6a8`。原始HF下载较慢，改用ModelScope镜像后按固定HF LFS身份验证再使用；没有关闭TLS验证。许可/NOTICE与配置保留。模型仍受研究许可约束，新节点/权重未进入旧安装包；正式源码、安装应用、资料库和六个来源代理均未修改。原第10节77图结果与历史校验记录保留。

来源：[Comfy官方VAE纹理说明](https://github.com/Comfy-Org/docs/blob/main/tutorials/image/qwen/qwen-image-2-1.mdx)、[texture-fix作者模型卡](https://huggingface.co/madebyollin/texture-fix-vae-for-qwen-image-2.1)、[mflux参考编辑实现](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/qwen21/variants/edit/qwen_image_21_edit.py)。其他推理实现也有网格报告，但不能直接替代本机受控实验的根因结论。
