# 风光风格与可复用 LoRA · 雪山、森林、城市夜景、湖泊、海边

2026-11-22 · 摄影作品、社区版本卡与公开权重检查 · 对应 [030 生成式精修](../../specs/030-ai-retouching/generative-editing.md)

最值得先做的是**城市夜雨**与**冷暖湖泊**。前者既有 Liam Wong 的具名作品，也有两个可精确定位的同名 LoRA；后者有 500px 的现场用光案例、Instagram 的实景倒影和 Liblib 作者给出的完整配方。森林和雪山有鲜明的表现手法，但现成通用模型容易额外画出雾、山峰或树木。海边更应先问摄影师要「冻结浪形」还是「表现拖影」，两个目标需要不同的素材和判定。

## 从摄影师的作品选效果

这里收录数码摄影时代的作者及其本人发布、受访或署名的作品。以作品说明、地理与光照线索定性选型，未按点赞量排名。Instagram 部分实际读了 Albert Dros 公开帖的嵌入图注；其他作者的社交账号用其官网确认，作品证据在各行列出。摄影师姓名用于研究溯源；面向用户的卡名描述光线、尺度与材质，署名合作款另行取得许可。

| 场景／面向用户的风格名 | 作者与具体作品语言 | 在用户原片上保留什么，何时换方案 |
| --- | --- | --- |
| **雪山 · 山脊侧光** | Max Rive 的巴塔哥尼亚和多洛米蒂作品突出峰脊尺度、前后景深度与局部晨昏光。在 500px，他解释过用画面里很小的人物交代巨大的山体尺度。 | 可以重塑已有坡面的明暗与冷暖。峰线、雪线和原有登山者是保护对象。平光天若只需增加层次，先给原生明暗方案；已有光向不足以支撑时，创作版单独出候选。[作品集](https://maxrivephotography.com/pages/gallery) · [500px 作者访谈](https://iso.500px.com/max-rive-shares-his-story-and-tips-for-shooting-tiny-people-in-massive-landscapes/) |
| **森林 · 晨雾分层** | Albert Dros 反复拍摄同一片荷兰 Speulder 森林，季节色、薄雾、第一束光与树列共同形成纵深。其 Instagram 有秋季林间车道和荷兰晨雾的独立例子。 | 原生版降低远处局部反差；生成版试做穿过现有树列的雾光。检查树干数量与分叉、路径走向和近处黑位，允许关掉「增加雾光」。[同林四季项目](https://www.albertdros.com/post/the-same-forest-through-different-seasons) · [Instagram 林间车道](https://www.instagram.com/p/CAk5oODHNpu/) · [Instagram 晨雾](https://www.instagram.com/p/B_Z81o2nxew/) |
| **城市夜景 · 雨夜霓虹** | Liam Wong 的 *Tokyo After Dark / Rain* 以既有灯源、雨夜街道、彩色反射组织纵深。 | 允许重新分配光晕与湿地反光，招牌文字、车辆、行人和透视是硬检查项。干燥街道默认走原生色调；用户选择模拟湿地才进入创作版。[摄影师的雨夜系列](https://www.liamwong.com/tokyo-after-dark-rain/) · [作者账号](https://www.instagram.com/liamwong/) |
| **湖泊 · 蓝调倒影** | 500px 用 Daniel Gastager 在 Emerald Lake 拍摄的冷环境和暖灯解释蓝调时刻。Albert Dros 在 Instagram 说明自己拍的是巴塔哥尼亚 Laguna Amarga 的清水倒影。 | 以一个光源同时约束山体、水岸及倒影。禁止凭风格词增加木屋或灯火；船、人、尾流和岸线分别对照。只有色温目标时原生版已足够。[500px 蓝调案例](https://iso.500px.com/what-is-the-blue-hour-and-how-to-make-the-most-of-it/) · [Instagram 实景倒影](https://www.instagram.com/p/CBDOEnen5Ze/) |
| **海边 · 风暴浪形／慢门回流** | Rachael Talibart 的 *Sirens* 把实际浪峰拍成具有雕塑感的形态；Michael Shainblum 的海景教学给出宽角前景、水流和快门时机的处理。 | 冻结浪形依赖源片本身，保留浪顶和飞沫位置，优先用局部明暗；「模拟慢门」允许重绘水流，只发生在海水软范围内，岩石、栈桥与地平线锁定。没有可匹配的浪形时提示跳过。[Talibart · Sirens](https://rachaeltalibart.com/portfolio/sirens/) · [Shainblum 海景实拍教学](https://shainblumphoto.com/2022/11/21/seascapephotography/) |

## 可定位的社区配置

下表区分**以作者命名的权重**和**按视觉属性匹配的候选**。参数来自发布者，未知项留空。它们大多展示从文字出图；用户已有 RAW 的保形编辑另需图生图或编辑底模、遮罩与质量门。其中两套 SDXL 具名权重已逐文件核 SHA 并在两档重绘强度下实际启用／禁用，共得到八张未筛选候选。另七套保留版本卡或头部检查记录。作者署名、权重分发和训练素材许可单独登记。[两套权重的成片与固定参数](generative-retouching-field-review.md#社区-lora-在匹配底模上的实测)

| 配置及定位 | 版本、触发与作者建议 | 用在何处／目前核到了哪一层 |
| --- | --- | --- |
| **Liblib 山川湖海** · hill1010，多作者灵感 | 指定版本 UUID `afee5e24f34949c9a0120156f77cd089`。作者建议 F.1 FP8 11G 的 FLUX.1 Schnell，`schh`，权重 0.6–0.9、起点 0.8，Euler、20–30 步、768×1024，高清修复放大 2–3.5 倍。 | 雪山、湖泊候选。作者称训练集近 600 张，列 Ansel Adams、Galen Rowell、Peter Lik、David Muench 为风格参考；未列逐张来源或四套独立权重。用其方法建立本项目配方时保留原片比例，不自动改成示例竖构图。已读版本说明，权重和商业分发未验。[用户指定版本](https://www.liblib.art/modelinfo/24227f25b28146d0b959da9b6a80d007?versionUuid=afee5e24f34949c9a0120156f77cd089) |
| **Civitai · Liam Wong** · Adel_AI，具名 | 模型 1760021，版本 1991856，FLUX.1 D；`LiaWon style`，约 0.75，25 步，guidance 3.5，DPM++ 2M 或 Heun++2，sgm_uniform。 | 城市夜景优先。作者称训练 72 图，列出 Fluxmania。官方 API 返回模型卡及文件 SHA，匿名取权重返回 401。平台字段为 Image、RentCivit；外部付费服务与捆绑均无本次证明。[模型版本](https://civitai.com/models/1760021?modelVersionId=1991856) |
| **Civitai · Liam Wong Style** · Kappa_Neuro，具名 | 73318／153894，SDXL 1.0；API 的原样触发串是 `Liam Wong Style page`。强度未取得明确作者建议。 | 同一城市主题的 SDXL 对照。匿名读到 safetensors 头，2,958 个张量，metadata 标为 SDXL、rank 32、alpha 8。此 SDXL 文件完整 SHA 已核，按 0.7 加载；两档重绘均出图，较强档把列车窗改成灯带。上一行 FLUX.1 D 为另一作者的文件。[模型版本](https://civitai.com/models/73318?modelVersionId=153894) |
| **Civitai · Aurel Manea Landscape/Nature Photography Style** · NobodyButMeow，具名 | 2082205／2355973，平台标 Qwen；`aurelmanea2q photography`。作者声明 73 张训练图、rank 24、alpha 12。 | 湖泊、海岸备选。作者为独立上传者；输出示例包含暖天、水面与栈桥。权重头 2,520 个张量；头中缺少 SDXL 候选具有的架构字段，需核对精确 Qwen 版本。平台字段只有 RentCivit。[模型版本](https://civitai.com/models/2082205?modelVersionId=2355973) · [摄影师作品](https://aurelm.com/category/photography/) |
| **Civitai · Ansel Adams Zone System style** · wfarer，历史参照 | 747293／835690，SDXL 1.0；`anseladams`，V1，未取得固定推理强度。 | 雪山黑白可与原生分区曲线盲比。权重头 2,958 个张量，SDXL、rank 32、alpha 16。整文件 SHA 已核，按 0.7 加载。两档山湖成片均残留颜色，较强档重画峰形并丢失船客。作为历史摄影语言与现代数码样片的对照。[模型版本](https://civitai.com/models/747293?modelVersionId=835690) |
| **TensorArt · Realistic Photo Forest** · Nerissa Olivia，通用 | 版本页 792881805272536052，SD 3.0。触发栏包含 `dense evergreen forest`、`sunlight streaming through trees` 等场景词，页面显示训练 3 epoch，未给出推理强度。 | 森林气氛候选。模型还描述高山、河流，原图没有的元素应从提示中排除并检查结果。无证据可称为 Dros 同名模型。已核模型卡。[模型版本](https://tensor.art/models/792881805272536052) |
| **TensorArt · PhotoReal Landscape** · Ai Art Vision，通用 | 644129036064335972，V1.0，SD 1.5；触发栏 `Nature Landscape PhotoReal Photography Raw photo`。作者列 DPM++ 2M Karras、20／30／40 步、CFG 5／7，高清修复 denoise 0.3／0.4／0.5。 | 通用山水／海边对照。高清修复的 denoise 与编辑原图的强度应分别校准。页面明示禁止转载；公开文字权限项目未逐个证实勾选状态。只登记配置。[模型版本](https://tensor.art/models/644129036064335972) |
| **Civitai · Long Exposure Style** · RalFinger，通用 | 210952／899837，FLUX.1 D，`ral-exposure`。 | 给海边「模拟慢门」试用；用它会改变水流时间感，不能代替 Talibart 的瞬间浪形。官方元数据可读，匿名文件请求 401。[模型版本](https://civitai.com/models/210952?modelVersionId=899837) |
| **Liblib · 雪山风景** · 团子，通用 | 卡明确为 FLUX.1 系列，作者称用 172 张川西素材训练，建议权重 0.1–0.6；页面给出示例关键词，未核实唯一触发词或具体 dev/schnell 变体。 | 作者将用途表述为给场景加雪山，适合测试生成器是否会改写峰线。原片保形路线只把它当负面对照。作者关于成图商用的说明不足以证明权重可捆绑。[模型卡](https://www.liblib.art/modelinfo/4badfe7a1cc342f290aabfe37347ae52) |

另检索了 Max Rive、Albert Dros、Daniel Gastager、Daniel Kordan、Marc Adamus、Rachael Talibart 的具名 LoRA。核对的 Civitai 返回中存在大量同名角色或无关画师；未得到可确认的对应摄影模型。本次检索不证明全平台不存在。用户写的 `livlib.tv` 本次 TLS 连接未成功，可核对的近似站点 `liblib.tv` 首页为 LibTV 视频创作工具；上表 Liblib 模型条目实际来自用户给定的 LiblibAI 模型库。Civitai 条目直接核对平台 API 和版本页，未把知乎跳转页当作模型源。[LibTV 首页](https://www.liblib.tv/) · [LiblibAI](https://www.liblib.art/) · [Civitai 版本 API 示例](https://civitai.com/api/v1/model-versions/153894)

## 从研究配置到产品包

1. **匹配。** 用户选场景，或复用已经存在的天空、水域、植被等本地信息提出 1–2 个建议，并能手动改类。保存「视觉目的、允许改变的区域、硬保护和禁添元素」。雾林或蓝调城市可以只复用这份描述、选择合法参考图；具体模型权重单独登记。
2. **验兼容。** 登记精确底模 revision、adapter 版本／SHA、目标层、rank/alpha、文本编码器、触发词、采样器、权重和图片尺寸。从 Civitai 版本元数据及 HTTP Range 读取 3 个公开文件的 safetensors 头，随后对 Liam Wong SDXL 与 Ansel Adams SDXL 两个完整文件重新计算 SHA-256，并与平台摘要一致。Qwen 条目仍只核到文件头。已核到的候选底模是 FLUX.1、SDXL、SD 1.5／3 或 Qwen。本机已验的 FLUX.3 Klein Q8 CLI 支持重复传参考图，其命令行没有 LoRA 装载入口。Seedream 5.5 的既有接入只承诺已验证的图片与提示接口。普通云请求不能当作已应用某个权重。[机器可读核对结果](../../specs/030-ai-retouching/evidence/generative-followup/lora-inventory.json) · [现有 FLUX.3 实测](../../specs/030-ai-retouching/flux-validation.md)
3. **验风格与保形。** 当前两套 SDXL 已用相同原片、种子、分辨率和底模完成无／有 LoRA 的整图图生图对照，未加保护遮罩。下一轮固定遮罩与结构条件，再加入可编辑 Adaptive 配方与仅使用参考图的候选做盲评。用本项目假设的 0.35／0.55／0.75 三档或作者区间做强度探索，按场景检查山脊、树列、招牌文字、船和地平线。权重有风格辨识度但易改地形时，仍停在研究库。后文的湖景出图测的是 FLUX.3 参考迁移，和第三方权重的实际出图分开记录。[本轮生成实验](generative-retouching-field-review.md)
4. **可交付的来源。** 优先取得摄影师合作样片与明确授权，或用自有实拍按光线特征训练。第三方模型分开核对底模许可、LoRA 权重的本地使用／转发／托管权、训练素材依据和摄影师姓名的展示权。产品可先提供自有参数与已验证的参考图入口；权重未核准的卡不显示「已安装／已复刻」。批准的包由用户显式下载，本地校验后可离线使用。
