# RAWMaster 图像后端：安装与云 API 设计

## 2026-10-30 原生前端与后续范围

用户明确：ComfyUI可以作为后台服务，但RAWMaster不嵌入或暴露其网页/节点编辑界面。安装、服务状态、模型方案、云配置、候选比较、采用与导出全部由RAWMaster原生界面提供；重要的本机/云端位置、上传目标、费用和实际输出尺寸仍可见。Comfy网页只保留在独立开发诊断环境。

最新分段计划见[20](20-native-ai-editing-next-batch.md)。Comfy→MLX q4工作流级适配已在独立环境通过API/前端/恢复/卸载验证，但内置/free尚未统一管理外部worker，旧runtime-pack也未覆盖该适配；产品生命周期和新包验收仍需实施。下方安装原型及研究任务保留各自完成范围，不能把旧包成功当成新MLX组合已可分发。三家云编辑按本次提案纳入本批，各自真实联调和费用/未知结果门独立验收；当前未产生云图片编辑调用。

日期：2026-10-30。范围：独立实验环境和后续实现方案，不接入正式 RAWMaster、不迁移真实资料库。本文的设计项不代表已完成的软件能力；本地实测结果另见实验报告。

## 1. 产品边界

采用同一作品版本、输入快照、任务记录和候选采用流程，分别连接 ComfyUI 本地实例与供应商云 API。云 API 应由独立供应商适配器调用，不依赖 ComfyUI 能否启动，也不要求把凭证写进工作流。ComfyUI 图形编辑器保留为调试工具。

首轮本地服务只监听 loopback。单任务 GPU 执行，前台翻片优先。ComfyUI、节点、Python、wheel 与模型各自版本化；GPU 内存和整机压力指标分别记录。

## 2. 自动安装方案

推荐主应用 DMG + 可选的版本化运行时包 + 独立模型包。首次启用本地 AI 时，用户看到完整下载量、展开空间和目标盘。云功能可独立启用。

运行时包包含固定版本 uv、arm64 CPython、ComfyUI 源码、平台专用 wheelhouse、带哈希的依赖锁、节点清单、许可与签名清单。模型单独下载，不重复装进每次应用更新。不要在客户端实时求解最新 requirements；不要复制开发机带绝对路径的 venv。

安装步骤：

1. 检查 arm64、最低 macOS、剩余展开空间、目录可写性、代理与 TLS 连通性。
2. 下载签名的运行时清单，再下载匹配版本包。对压缩包与解压后文件分别校验；防止路径越界和链接逃逸。
3. 解压到 Application Support 下的新版本 staging 目录；不修改已签名主应用 bundle，不写系统 Python、Homebrew 或全局 site-packages。
4. 使用包内 uv 和 CPython 在最终版本目录创建 venv，从 wheelhouse 执行 `uv pip sync --offline --no-index --find-links <wheelhouse> --require-hashes <lock>`。环境清单必须覆盖平台与 Python ABI；禁止客户端临时编译 sdist。
5. 执行依赖检查、torch/MPS 算子冒烟、ComfyUI loopback 健康检查、节点能力校验；小型算子测试与真实模型生成测试分开。
6. 健康检查成功后原子更新 active-runtime 指针。失败保留旧版本、脱敏诊断和可重试阶段，不让半安装目录成为活动环境。
7. 下载独立模型包：断点/分段、大小和 SHA-256 校验、临时文件完成后原子发布。门控模型遵循原站授权，不绕过访问条件。

将 venv 建在最终版本目录并用 active 指针切换，避免先建 staging venv 再重命名引起 shebang 路径失效。运行时与模型可以有多版本；清理必须检查活动任务、作品引用和可回滚版本。

开发期可以使用联网 uv 安装；正式安装应优先走离线 wheelhouse。用户无需打开终端执行 pip。带完整 CPython/wheelhouse 的离线包作为网络受限环境的可选交付；其签名、公证、全新 Mac 与 Gatekeeper 验收单独完成。

### pip/uv 安装失败的分类与处理

| 故障 | 恢复策略 |
|---|---|
| DNS、连接超时、连接中断、限速 | 阶段性重试；包下载断点；经签名清单认可的备用源；哈希仍以发行清单为准 |
| TLS/公司代理证书错误 | 使用受管 CA/系统信任配置，允许显式配置组织 CA；不关闭验证、不使用 insecure/trusted-host 绕过 |
| Python/架构/ABI 不匹配 | 选择正确运行时包；避免探测到系统 Python 后继续装错环境 |
| 缺 wheel/触发源码编译 | 停止该组件安装；在构建机产出匹配 wheel；不给用户装 Xcode/Rust/CUDA 来修补 |
| 依赖冲突或节点要求变更 | 固定节点集合与 lock；安装到新版本，不修补正在使用的环境 |
| 磁盘满、目录权限、只读卷 | 预检下载+解压+模型临时空间；允许选择模型盘；失败不动旧环境 |
| wheel、模型校验失败 | 隔离损坏文件，仅重新取该文件；不把校验失败降级为警告 |
| MPS 算子/精度不支持 | 显示准确组件与 dtype；使用已测兼容配置；CPU 回退需明确披露，不能冒充 GPU 结果 |
| 系统安全机制拦截 | 修复分发签名、公证和包布局；不指导用户全局关闭安全机制 |

本机已经观察到：系统 Python 3.13 urllib 的证书链错误；Hugging Face 直连较慢；独立 Python 可用；ModelScope 范围请求明显改善模型下载。最终权重仍须逐文件与固定 HF revision 的 LFS SHA-256 一致。以上只是本机观察，不代表所有地区和网络表现。

### 分发边界

ComfyUI 为 GPL-3.0，运行时分发应保留许可与对应源代码交付安排。独立进程不是自动免除许可义务的结论。模型、编码器、节点与 uv/CPython 分别列许可和版本。签名、公证与许可证发布核对是未来正式安装包的交付项，当前实验没有宣称完成。

## 3. 云端供应商与配置

| 供应商 | 接入形态 | 必须单独表达的配置与能力 |
|---|---|---|
| Seedream / 火山方舟 | 对应区域的 `/api/v3/images/generations`，参考图与文本组成 JSON 请求 | 中国/国际区域、base URL、API key 引用、模型或 endpoint ID、输出尺寸、单图/组图、URL/base64、流式能力按版本登记 |
| GPT Image / OpenAI | Images `/v1/images/edits`；需要多轮上下文时另选 Responses 路径 | 模型 ID、输入图/蒙版支持、尺寸/质量、输出格式；不能把 Images 请求 ID 当作可轮询异步任务 ID |
| Nano Banana / Gemini | 对应 Gemini 模型的 `generateContent` 图文 parts 请求，解析 image parts | 精确模型 ID、API 区域/项目路径、比例/分辨率、参考图数量、会话上下文及返回的元信息 |

Nano Banana 是产品系列名，配置中保存实际模型 ID。GPT Image 与 Seedream 同理，用户可选支持的版本，任务冻结所选值，避免默认别名更新后改变既有配方。中国方舟与 BytePlus 国际 endpoint 不混用。

配置结构建议：

```json
{
  "id": "user-profile-id",
  "provider": "openai|seedream|gemini|comfyui",
  "enabled": false,
  "baseURL": "https://provider.example",
  "region": "explicit-region",
  "modelID": "explicit-supported-model-id",
  "credentialRef": "macOS-Keychain-item-id",
  "capabilityProfileVersion": "pinned-version",
  "limits": {"maxConcurrentJobs": 1, "requestTimeoutSeconds": 600},
  "budget": {"currency": "provider-currency", "perRequestLimit": null}
}
```

原始 key 存 macOS Keychain；普通配置、导出的工作流、日志、备份清单不包含 key。改动 base URL 必须重新选择对应凭证，不能把已有供应商凭证自动发给新域名。实验阶段只构建请求与配置规范，没有调用 Seedream/GPT Image/Gemini 图片编辑 API。

统一接口只统一用户意图、版本和任务生命周期，不伪造所有供应商共有的参数。`mask`、reference、strength、seed、LoRA、尺寸、流式、轮询、取消均按能力提供；不支持就不展示或在执行前明确拒绝。各供应商的 mask 坐标、透明语义、软约束与硬合成行为单独验证。

### 任务与恢复

- 输入包含已保存作品版本、实际渲染图 hash、色彩/尺寸/位深变换、Prompt、可用 mask/reference 和配置快照；不直接上传 RAW 或整组资料。
- 记录本地 jobID、attempt、供应商 requestID、可用时 remoteJobID、实际模型版本、返回内容、用量与估算/实际费用。
- 状态区分 queued / submitting / running / outcomeUnknown / succeeded / failed / cancelRequested / cancelled。本地关闭 HTTP 连接不等于远端取消或停止计费。
- 提交超时先按供应商实际能力核对；没有远端查询或幂等保证时保留 outcomeUnknown，不自动重复生成。退避重试适合明确未提交的连接故障和已确认可重试的限流；不要对生成 POST 盲重试。
- URL 结果及时下载、解码并校验，归档后再标记成功；保留模型实际输出尺寸及重采样记录。不能只存有时效的链接。
- 云端上传范围和目标供应商在生成动作前可见；本地失败不自动切云。首次启用云配置不等于允许后台上传整个项目。
- 工程验收包含脱敏、错误解析、费用未知、部分返回、超时与取消，不以 HTTP 200 作为作品成功。

## 4. 后续实现任务

1. 先完成本次两模型 MPS 实测、图像复核与胜出模型 MLX 对照。
2. 制作 arm64/macOS/Python ABI 固定的离线 runtime-pack 原型；在新目录、无缓存、断网条件验证创建、启动与回滚；损坏 wheel 的负例必须失败且不影响旧环境。
3. 形成运行时安装状态机、签名下载清单及分段模型下载器；测代理、证书、无 wheel、磁盘满和中断。
4. 形成供应商能力注册表、Keychain 配置与请求构造测试；用 fake transport 测未知结果与重试，另行提供真实 API 联调凭证后再联调。
5. 与 008 T08/T09/T13/T14 对齐任务和版本合同；完成独立环境验收后再规划正式客户端接入。

## 官方参考（2026-10-30 查阅）

- ComfyUI：https://github.com/Comfy-Org/ComfyUI
- uv 锁与同步：https://docs.astral.sh/uv/pip/compile/
- uv Python：https://docs.astral.sh/uv/concepts/python-versions/
- uv/PyTorch：https://docs.astral.sh/uv/guides/integration/pytorch/
- OpenAI Images edits：https://developers.openai.com/api/reference/python/resources/images/methods/edit
- Gemini 图片编辑：https://ai.google.dev/gemini-api/docs/image-generation
- 火山方舟图片生成：https://docs.volcengine.com/docs/ark/image-generation-api?lang=en
- BytePlus 国际接口：https://docs.byteplus.com/en/docs/modelark/image-generation-api

文档中的接口和配置方案需在实施时固定供应商版本并联调，不据此宣称账号有访问权限、价格已冻结或云端画质已通过。

## 本轮已形成的安装证据

未签名 runtime-pack 原型约 297 MiB，包含独立 CPython/uv、完整平台 wheelhouse、哈希依赖锁、ComfyUI 源码及 MPS 缩放兼容补丁，不含模型和照片。新目录、空缓存、离线安装、带空格路径、MPS 算子、ComfyUI API/节点健康检查均通过；损坏 wheel 与缺少代码模块的安装均没有切换旧活动版本。正式签名、公证、全新 Mac 和最低配置验收未进行。

实验目录：`/Users/robinqu/Workspace/RAWMaster-Lab/comfy-20261030`。见 `installer-final-receipt.json`、`distribution/`、`provider-profiles.example.json` 及[模型选型报告](18-comfyui-ai-backend-evaluation.md)。云配置示例全部禁用，凭证是 Keychain 引用占位符，没有向这些云图片编辑接口提交样本或产生相关付费调用。

开发阶段应补齐：模型/工作流相关算子冒烟（通用矩阵计算通过并不代表 Qwen 参考缩放可用）；模型包分段验证后逐文件清理临时块，控制安装展开峰值空间；签名、公证与嵌套 native 代码验证；带有完整依赖和公开许可的离线分发包。

即使新的 uv 提供可迁移环境选项，任意 native 二进制与外部解释器路径仍需验证。本方案先在最终版本目录创建环境并用 active 指针切换，已用当前固定 uv 版本实测。

补充官方参考：

- [Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple 嵌套代码签名](https://developer.apple.com/documentation/Xcode/using-the-latest-code-signature-format)
- [uv 存储与解释器路径](https://docs.astral.sh/uv/reference/storage/)
