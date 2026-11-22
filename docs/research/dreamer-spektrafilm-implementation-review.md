# Dreamer 与 SpektraFilm 实现复核：Patch＋Matte、胶片吞吐与五类场景预设

日期：2026-11-21。目的：在继续扩大 RAWMaster 智能修图产品方案前，核对两个参考产品的真实实现，而不是只依据官网功能描述。本文区分静态源码证据、可执行探针和本机性能测量；没有把 Photoshop 真机、真实付费生成或 RAWMaster 生产画布验收写成已经完成。

## 执行结论

1. **Patch＋Matte 成立。** Dreamer 同时存在“局部算法输出＋蒙版合成”和“生成图置入＋冻结选区／灰度蒙版”两条真实实现。RAWMaster 可以采用完整候选图＋Matte 作为首版合同，ROI 裁剪只是后续优化。
2. **SpektraFilm 参考实现不能直接满足滤镜即时交互。** 本机 640px 预览暖中位数约 194ms，6MP 完整处理约 10.0s，24MP 约 42.4s。需要烘焙 LUT／GPU 快速路径和异步完整渲染。
3. **独立 LUT 应用具有足够吞吐潜力。** 同一项目中 Numba 并行的 33³ LUT 热执行，640px 约 4.7ms、6MP 约 83ms、24MP 约 310ms。该结果只证明逐像素 LUT 计算吞吐，不代表完整胶片效果或 RAWMaster 画布已经通过。
4. **Dreamer 没有五类场景都已结构化的智能修图预设。** 人像实现最完整；风光和建筑主要是 Agent 角色／Prompt 约束；纪实有确定性风格配方但没有独立 Agent 场景；街拍旅行没有独立实现。RAWMaster 的五类预设必须建立自己的原生操作与蒙版合同。

## 1. 研究对象与证据等级

| 对象 | 固定版本 | 实际证据 | 未覆盖 |
| --- | --- | --- | --- |
| Dreamer | 文档仓 `16393534312c8c7ee1704da08f05b8256a6223e4`；macOS 2.2.2 预发布包 SHA-256 `b027ad3e54e21d695d0d1d3a8287d142dcc4549453b208a5633425e3025f4aea` | 发布包内未混淆 JavaScript、Profile、Skill 与模型目录静态阅读；局部算法 Node.js 像素探针 | Photoshop 真机贴回、付费生成、跨版本兼容性 |
| SpektraFilm | `3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`，包版本 0.3.4 | 完整 Python 源码、测试、参数裁剪逻辑；M4 Max 本机吞吐测量 | RAWMaster Metal／AppKit 集成、摄影画质、所有胶片与纸张组合 |

Dreamer 的公开 GitHub 仓只有 README，因此本文没有把官网描述当作实现证明，而是继续分析其公开发布包。SpektraFilm 的性能环境使用独立 Python 3.13.3 运行时；输入为确定性的合成线性 RGB 数据，不包含 RAW 解码、文件 I/O、GUI 或显示转换。[完整胶片吞吐记录](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektra-benchmark.json&text=%22status%22%3A%20%22complete%22 "citation") [LUT 吞吐记录](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektrafilm-lut-throughput.json&text=%22protocol%22 "citation")

## 2. Patch＋Matte 的真实实现

### 2.1 局部确定性配方：编辑图与 Matte 合成

Dreamer 的底层 `composite` 明确执行 `base + amount × mask × (edited − base)`，保留输入尺寸并验证 Mask 长度和值域。局部配方还把未改变的像素设为透明，避免对原图进行不必要的色彩往返；Photoshop 宿主随后创建带蒙版的新效果层。[合成函数](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpanel%2Fretouch%2Fcore%2Fretouch-core.js&text=function%20composite%28image%2C%20edited%2C%20mask%2C%20amount%20%3D%201%29 "citation") [宿主范围处理](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpanel%2Fretouch%2Fuxp%2Fhost%2Fphotoshop.js&text=const%20unchanged%20%3D%20result.data%5Bi%5D%20%3D%3D%3D%20source.data%5Bi%5D "citation")

本次直接执行了发布包中的柔润人像、皮肤色块均匀和保纹理平滑三项配方。64×64 RGBA 输入只在左半区应用，三项结果的右侧区域外最大 RGB 差异和 alpha 最大差异均为 0，同时区域内确有像素变化。这证明 Patch＋Matte 不只是文档概念，至少其局部像素实现具有可执行的范围保护。[探针结果](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-patch-probe.json&text=%22allPassed%22%3A%20true "citation")

### 2.2 生成式结果：新图层＋冻结选区／灰度 Mask

生成结果首先经 `placeImageToSpecificDoc` 置入目标 Photoshop 文档，并绑定冻结的文档与位置锚点；`createGroupAndMask` 再建立任务组，根据保存的坐标重建选区并创建蒙版，可执行羽化。光效路径还显式设置并回读 `linearDodge`、不透明度和可见性，而不是把请求参数当作已经成功的事实。[置入与锚点](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fhost%2Fps-io.js&text=async%20function%20placeImageToSpecificDoc%28 "citation") [任务组与蒙版](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fhost%2Fps-io.js&text=async%20function%20createGroupAndMask%28 "citation") [光效贴回](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fhost%2Fps-io.js&text=blendMode%3A%20%22linearDodge%22 "citation")

复合图层包还支持每个派生组件自己的灰度 Mask，再在最外层应用冻结选区。这说明 RAWMaster 不需要把“Patch”限定为物理裁剪后的小图：首版可以保存完整候选帧和 Matte，由渲染器只合成允许区域；后续再按 ROI 裁剪候选以降低存储和内存。

### 2.3 与历史／回放的关系

Dreamer 的局部会话保存有序步骤、引擎版本、参数和 RLE 蒙版；重放要求输入尺寸完全一致，不会静默缩放蒙版或跨图对齐。[会话回放合同](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpanel%2Fretouch%2Fcore%2Fsession-v3.js&text=%E9%87%8D%E6%94%BE%E5%B0%BA%E5%AF%B8%E4%B8%8D%E4%B8%80%E8%87%B4%EF%BC%9B%E4%B8%8D%E4%BC%9A%E7%BC%A9%E6%94%BE%E8%92%99%E7%89%88%E6%88%96%E8%87%AA%E5%8A%A8%E8%B7%A8%E5%9B%BE%E5%AF%B9%E9%BD%90 "citation")

RAWMaster 可把生成候选留在生成记录中，只有“应用到照片”才写入线性历史。历史项引用不可变候选资产和 Matte 快照；恢复历史不重新运行模型。切换候选或修改 Matte 是新的历史操作，不需要重新生成。

## 3. SpektraFilm 执行吞吐与滤镜资格

### 3.1 参考管线的实际测量

测试使用 Kodak Portra 400＋Portra Endura，启用 GUI 使用的内部 enlarger／scanner LUT。`coldProcessSeconds` 与暖运行分开；吞吐是 `Simulator.process` 的墙钟结果，不包含 RAW 解码和界面呈现。

| 模式与尺寸 | 像素量 | 暖运行中位数 | 暖吞吐 | 结果解释 |
| --- | ---: | ---: | ---: | --- |
| GUI 预览，640×427 | 0.273MP | **193.7ms** | 1.41MP/s | 不满足即时 hover；只够低速预览 |
| 完整管线，1200×800 | 0.96MP | **1.546s** | 0.62MP/s | 单张小图仍需明显等待 |
| 完整管线，3000×2000 | 6MP | **10.004s** | 0.60MP/s | 只能异步处理 |
| 完整管线，6000×4000 | 24MP | **42.355s** | 0.57MP/s | 应作为后台高质量渲染任务 |
| `lut_mode`，3000×2000 | 6MP | **3.498s** | 1.72MP/s | 仍运行逐像素数学，不是烘焙 LUT 热路径 |
| `lut_mode`，6000×4000 | 24MP | **13.936s** | 1.72MP/s | 同样不能承担滤镜交互 |

24MP 完整案例所在进程的 lifetime RSS 高水位约 21.8GB；它包含此前案例且不是独立的逐案例峰值，因此只能作为资源风险信号，不能写成该尺寸的精确最低内存。[原始记录](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektra-benchmark.json&text=%22full_24mp_gui%22 "citation")

6MP 完整处理中，`filming.develop` 约 5.99s，`scanning.scan_print` 约 2.84s，是主要热点。源码显示该路径包含多层随机颗粒、空间 coupler 与扫描阶段，而不是单一颜色矩阵。[Filming Stage](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektrafilm%2Fsrc%2Fspektrafilm%2Fruntime%2Fstages%2Ffilming.py&text=def%20develop%28self%2C%20log_raw%3A%20np.ndarray%29 "citation") [颗粒实现](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektrafilm%2Fsrc%2Fspektrafilm%2Fmodel%2Fgrain.py&text=def%20apply_grain_to_density_layers "citation")

### 3.2 预览和 LUT 模式都不是完整胶片质感

`preview_mode` 会关闭颗粒、DIR coupler 扩散、扫描锐化和若干模糊阶段；`lut_mode` 为保证逐像素可表示性，进一步关闭所有空间、随机和全图效果，包括 halation、grain、自动曝光与高光 boost。[参数裁剪](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektrafilm%2Fsrc%2Fspektrafilm%2Fruntime%2Fparams_builder.py&text=if%20params.settings.preview_mode%3A "citation") [LUT 模式合同](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektrafilm%2Ftests%2Ftest_lut_mode.py&text=A%203D%20LUT%20can%20only%20represent%20a%20function%20of%20a%20single%20pixel%27s%20value. "citation")

因此不能把上述预览耗时当成完整效果的预览成本，也不能把 `lut_mode` 结果当成完整胶片风格。产品上必须明确区分“颜色与明暗预览”和“颗粒／光晕／扫描质感”。

### 3.3 烘焙 LUT 的吞吐潜力

使用项目自身的 `apply_lut_cubic_3d`，对 33³×3 LUT 做 Numba 并行三次插值，得到：

| LUT 热执行 | 暖中位数 | 暖吞吐 | 备注 |
| --- | ---: | ---: | --- |
| 640×427 | **4.68ms** | 58.4MP/s | 首次包含编译约 534ms；需预热 |
| 3000×2000 | **83.4ms** | 71.9MP/s | 逐像素 LUT，不含空间效果 |
| 6000×4000 | **309.6ms** | 77.5MP/s | 不是完整胶片管线 |

这说明“胶片外观作为滤镜”在工程上有可行快速路径，但必须经过 LUT 烘焙、预热和缓存；直接将参考 Python 管线接入 hover 不合格。该纯函数结果也不能替代 RAWMaster 的生产 AppKit 画布、LUT 资源生命周期和 canonical 一致性验收。[LUT 实现](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fspektrafilm%2Fsrc%2Fspektrafilm%2Futils%2Ffast_interp_lut.py&text=def%20apply_lut_cubic_3d%28lut%2C%20image%29 "citation")

### 3.4 对滤镜准入的修正结论

RAWMaster 当前滤镜规格要求生产画布暖切换／强度 p50≤20ms、p95≤33ms，并对整组候选另有性能门。[028 性能门](kimi-cite://md-line?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Fspecs%2F028-filter-experience%2Fspec.md&line=165&text=%E6%80%A7%E8%83%BD%E4%B8%8E%E8%B5%84%E6%BA%90%E9%AA%8C%E6%94%B6%E9%97%A8 "citation")

**胶片可以继续作为左侧滤镜的产品分类，但当前参考实现不能直接获得该资格。** 推荐结构为：

1. hover／强度使用预热 LUT 或 Metal 等价快速路径，只承诺颜色与明暗预览；
2. 点击后保留快速结果，并异步生成带颗粒、halation 和扫描质感的 settled 预览；
3. 导出使用固定参数、固定随机种子和固定数据包的 canonical 路径；
4. 如果快速路径与完整结果差异未通过验收，则该胶片配方只进入“智能修图”的异步操作，不进入普通滤镜目录。

## 4. 五类核心场景的实际实现核对

### 4.1 Dreamer 的职业 Profile 不是结构化修图操作表

发布包只包含空白、人像、风光、Coser、电商、插画和建筑七类 Profile。人像、风光和建筑的 `profile.json` 提供角色 ID、展示名、Beta 状态和 skill tag；`role.md`、`soul.md` 与 `final-prompt-inject.md` 描述分析重点、保护项和最终 Prompt 编写规则。[人像 Profile](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpython%2Fprofiles%2Fphotography_portrait%2Frole.md&text=%E4%BA%BA%E7%89%A9%E8%BA%AB%E4%BB%BD%E3%80%81%E4%BA%94%E5%AE%98%E6%AF%94%E4%BE%8B%E3%80%81%E8%87%AA%E7%84%B6%E7%9A%AE%E8%82%A4 "citation") [风光 Profile](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpython%2Fprofiles%2Fphotography_landscape%2Frole.md&text=%E4%BF%9D%E6%8C%81%E5%9C%B0%E5%BD%A2%E3%80%81%E5%BB%BA%E7%AD%91%E3%80%81%E5%9C%B0%E5%B9%B3%E7%BA%BF "citation") [建筑 Profile](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpython%2Fprofiles%2Farchitecture_design%2Frole.md&text=%E5%85%88%E5%8C%BA%E5%88%86%E7%BA%AF%E6%96%87%E7%94%9F%E5%9B%BE "citation")

其预设模式确实包含 `role / preserve / strength / modify / quality_check` 等结构化字段，但这些字段最终被编译为 Prompt 内容；它们不是 RAWMaster 意义上的原生 Recipe Patch、Mask Component 或可执行操作列表。[预设结构](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpanel%2Fcore%2Fbasic-mode-state.js&text=REQUIRED_FIELDS%20%3D%20Object.freeze "citation")

### 4.2 五场景矩阵

| 场景 | Agent 角色与约束 | 可执行本地配方 | 蒙版／模型 | 对 RAWMaster 的结论 |
| --- | --- | --- | --- | --- |
| 人像 | 有，保护身份、五官、皮肤、身体与服装 | 有：保纹理平滑、Lab 肤色均匀、小斑点修补、局部提亮、牙齿／眼部等 | 较完整：BiRefNet、Sapiens、SAM、ViTMatte 等目录 | 可优先做原生＋自适应蒙版智能预设 |
| 风光 | 有，保护地形、地平线、透视与光向 | 未发现风光专属像素配方；只有通用层次与风格工具 | 未发现专用天空／山体／植被语义链 | 需要 RAWMaster 自建风景解析与原生 Recipe |
| 纪实 | 无独立 Profile | 有清爽纪实、中性层次、银调黑白三条确定性风格 | 无独立内容真实性策略 | 可做参数／风格预设，但严格模式须由 RAWMaster 实现 |
| 街拍／旅行 | 无独立 Profile；风光描述覆盖旅行 | 使用通用风格、局部层次与清理工具 | 通用对象与深度能力可复用 | 不必另造引擎，可组合风光＋纪实策略 |
| 建筑／城市 | 有，但面向建筑设计、白模与效果图，不只是摄影后期 | 未发现建筑摄影专属像素配方 | 通用对象／深度，不等于直线与透视保护 | 必须增加几何与文字验收，不能仅靠 Agent 约束 |

人像配方是真实可执行的，但它们大多要求用户先确认皮肤或五官范围，并明确“不自动找痘、不判断皮肤、不改变身份”。智能分析扩展只生成观察、参数参考和候选 Mask，不自动改写一键动作。[人像配方](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpanel%2Fretouch%2Fcore%2Fportrait-v3.js&text=No%20skin-color%20template%2C%20model%2C%20DR5%20code "citation") [分析只读边界](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpanel%2Fretouch%2Fsmart%2Fretouch-smart.js&text=Optional%2C%20analysis-only%20extensions.%20These%20never%20modify%20image%20pixels%20or%20recipe%20defaults. "citation")

风格配方也有真实实现：单调曲线、色差缩放、阴影／高光色差和可选柔光，并支持范围混合。清爽纪实、中性层次和银调黑白不是 Agent 场景理解结果，而是固定视觉配方。[风格实现](kimi-cite://text?path=%2FUsers%2Frobinqu%2FWorkspace%2Fgithub%2Frobinqu%2FRAWMaster%2Foutput%2Fresearch%2Fai-retouching-rea%2Fdreamer-release%2Fextracted%2FDreamer%2Fpanel%2Fretouch%2Fcore%2Fstyle-recipes.js&text=const%20DEFINITIONS%20%3D%20%5B "citation")

## 5. 对 RAWMaster 产品方案的调整

### 5.1 右侧按场景直接选择预设

2026-11-22 的产品范围采用右侧单一「智能预设」入口。每张卡直接绑定目标、范围、保护项、可编辑字段与检查方法。摄影师可明确选人、修边、勾选参数和确认采用。参考张与换光例外由纪实批量卡处理。[当前场景规划](../../specs/030-ai-retouching/scene-presets.md)

五类场景不应承诺同等成熟度。人像和纪实可优先；街拍旅行复用两者；风光依赖风景语义蒙版；建筑依赖几何保护。预设卡必须标明包含的原生调整、AI Mask 和生成步骤，不把多步方案伪装成一个普通滤镜。

### 5.2 Patch＋Matte 与历史可以按统一合同实施

```text
PixelEditOperation
  operationID / intent / sourceContentID / sourceRevision
  candidateArtifactRef          // 首版可为完整候选帧
  matteDescriptor / matteSnapshotRef
  roi / blendMode / amount
  modelIdentity / promptTemplateVersion / qualityReview
```

分析、对话和候选生成不写照片历史；应用操作才写历史。参数型预设可以原子写入一条组合历史；异步 Agent 方案允许每个实际成功操作分别写入，并用方案 ID 关联，避免部分失败时虚构整体原子成功。恢复历史只读取配方、Matte 和候选资产，不重新运行 AI。

### 5.3 胶片滤镜从“直接集成”改为“双速渲染资格”

胶片仍在左侧滤镜面板，但发布单元不是“Python 管线已跑通”，而是“特定胶片＋相纸＋输入输出色彩空间＋参数集的 LUT／GPU 预览已通过，并且完整质感 settled／导出一致性已通过”。LUT 烘焙与 QA 成本应在配方发布或首次准备时承担，不应发生在用户连续 hover 时。

对包含颗粒与光晕的配方，可显示“基础预览 / 完整质感”的状态；不能用关闭这些效果的 LUT 预览冒充最终完全一致。若完整效果必须异步，滤镜仍可提供快速外观选择，但需要在界面中保持 settled 状态和旧图可见，不产生空白帧。

## 6. 最终技术判断

Patch＋Matte 可以进入 RAWMaster 的正式产品合同，且与现有蒙版、历史和快照兼容。胶片模拟可以进入滤镜面板，但只能以双速实现获得资格，参考 Python 实现本身不合格。五类场景预设不能从 Dreamer 直接移植为五套 Prompt；真正可复用的是其范围保护、候选资产、可编辑贴回和本地配方思路，RAWMaster 需要自行建立场景到原生工具、语义蒙版和质量门的映射。
