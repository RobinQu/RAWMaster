# 摄影社区里的用光与色调，如何转成首批预设

2026-11-22 查阅 · 支撑 030 产品选型与 D0 设计评审

在 500px 的获奖作品、评审意见和摄影师访谈中，人像同时有「保留现场光、让脸可读」和「用黑白明暗突出表情」两种诉求。风光有保留天空层次的需求，也有主动表现黄昏色温的选择。纪实同时需要彩色还原和黑白交付，对画面信息的要求取决于用途。这些差异决定了卡片的目标、默认值以及摄影师应该看哪里。

## 取样与解释

以人像、风光、纪实为三组，定向查找 500px 的年度评选、Quest、作者访谈和技法文章，用 LensCulture 的街头摄影指南、国际风光摄影师大赛和 World Press Photo 的作品与规则交叉核对。下表给出 11 个摄影来源，处理插件另列。赛事项区分评委与公众选择，街头创作与新闻纪实分开记录。这里的「主流」指能在这些编辑或摄影师样本里辨认、适合做一次产品验证的摄影语言。样本没有随机抽取，也没有平台全量点赞、下载或用户份额，不能据此给风格排人气名次。

| 样本 | 作品或来源给出的线索 | 对 RAWMaster 的设计取舍 |
| --- | --- | --- |
| P1 · 自然光人像 | 500px 逆光指南区分剪影与按面部曝光；专门讨论头发轮廓、背景光与补光。 | 「逆光人物提亮」先选人、只抬人物，剪影可直接跳过。将发际线与明亮背景设为对照点。[500px · Backlighting basics](https://iso.500px.com/backlighting-basics-seven-tips-for-the-perfect-glow/) |
| P2 · 黑白人像 | 500px 2025 人像组的公众选择 zamira，评语指向紧凑取景、高反差、皮肤纹理与眼神；评委选择另有其人。500px 的黑白人像编辑指南也把眼神、表情与光比放在首位。 | 「明暗黑白人像」允许调橙色明度和中间调反差，保持构图与皮纹。画布的 100% 检查点落在眼窝和受光面。[500px · Portrait Winners](https://500px.com/awards/portrait) · [500px · Capturing emotion with black and white portraits](https://iso.500px.com/capturing-emotion-with-black-and-white-portraits/) |
| L1 · 保留天空结构 | 国际风光摄影师大赛 2025 把 Stormy Sky 列为特别奖，获奖人为 Dennis Hualong Zhang。天空本身可以承载风景主体。 | 「天空压高光」只整理可恢复的云层。以枝梢、山脊、未改前景和真正过曝的负例验收。局部压光是本项目推导的做法。[ILPOTY · 2025 results](https://www.internationallandscapephotographer.com/index.php?catid=8&id=193%3A2025-ilpoty-awards-the-results&view=article) |
| L2 · 暖光与自然层次 | 500px Local Landscapes 亚军 Hasaan Fazal 的 *Before the Last Sun Sets*，评审点出了落日照到山顶、河面反光与阴影的关系。冠军 Eriks Zilbalodis 的 *Swamp things* 则以雾分开景深。500px 的黄金时刻指南描述低角度暖光与长影。蓝调时刻指南举 Daniel Gastager 拍摄加拿大 Emerald Lake 为例，解释同一画面里的暖灯与冷色环境。 | 「暮色冷暖」保留照片已有暖光和阴影层次，可分别减弱染色；反射必须与天空协调。雾景作为负例，另留「远山层次」做专项，避免把保留雾气理解成一律去雾。[500px · Local Landscapes Quest](https://iso.500px.com/local-landscape-quest-winner/) · [500px · Golden hour landscapes](https://iso.500px.com/enhancing-landscape-photography-golden-hour/) · [500px · Blue hour](https://iso.500px.com/what-is-the-blue-hour-and-how-to-make-the-most-of-it/) |
| D1 · 现场色与表情 | World Press Photo 2025 年度照片为 Samar Abu Elouf 的 *Mahmoud Ajjour, Aged Nine*。评委描述窗边暖光和脸上一侧的柔影，它们参与了照片的叙事。 | 「中性还原」初始保留本张当前白平衡，未调片即沿用拍摄设置，摄影师可以保留室内暖光或舞台色。参考张跨灯位只提议复核；组照配平是交付需求，这次取样没有测量它的流行程度。[World Press Photo · 2025 Photo of the Year](https://www.worldpressphoto.org/news/2025/world-press-photo-of-the-year-announced) |
| D2 · 黑白街头与严格纪实 | 500px 访谈中 Eline Deckers 讲述在安特卫普以强光和深影组织人物、允许阴影隐藏信息的创作选择。LensCulture《Street Photography Guide》第 2 页也将 Henri Cartier-Bresson 的黑白作品作为这个门类的经典例子。World Press Photo 的评审规则允许灰度转换，也会审查通过密度、对比或颜色隐去内容的处理。 | 「克制黑白」以现场标语、暗处旁观者作为检查点，预设保留暗部，和人像黑白的反差配方分开。严格模式提供来源记录；摄影师和外部编辑仍判断最终照片。[500px · Eline Deckers 访谈](https://iso.500px.com/eline-deckers-black-and-white-street-photography-in-antwerp-500px-photographer-spotlight/) · [LensCulture · Street Photography Guide，第 2 页](https://assets.lensculture.com/static/guides/pdf/LensCulture_Street_Photography_Guide_2025.pdf#page=2) · [World Press Photo · What counts as manipulation](https://www.worldpressphoto.org/contest/verification-process/what-counts-as-manipulation) |

## 从处理插件到可编辑的配方

| 插件中的实际依据 | 本项目落点 |
| --- | --- |
| Dreamer 2.2.2 的 `daily-core.js` 里有线性曝光 `exposure_ev` 与单调明暗曲线 `shadow_highlight`；`portrait-v3.js` 的 `skin_tone_even` 处理圈定皮肤的色差，`skin_smooth` 另做低频。 | 逆光卡只编译已确认目标的原生曝光与阴影。肤色去偏和自然肤质另有卡片、样本与上线条件，首批两张人像卡均保留身份与纹理。[发布包与源码定位](../../specs/030-ai-retouching/source-review.md) · [官方发布](https://github.com/2771096196/PSAI-Dreamer/releases/tag/v2.2.2-macos-arm64) |
| Dreamer 的 `style-recipes.js` 风格定义包含 `style_neutral_documentary`、`style_fresh_documentary`、`style_documentary_bw`，各有明确曲线和色度。风光角色文件描述地形、光向与倒影等保护要求。DxO Nik Silver Efex 将黑白预设、色彩滤镜、曲线、全局与选择性校正分开供人调节。 | 黑白两卡用 RAWMaster 自有混色与曲线，按人像和纪实分别校准；暮色走原生分级。天空分割、按张配平和纪实策略由 RAWMaster 实现。Dreamer 五个合成输入检验了作用范围与重复性，摄影观感仍需真实 RAW 盲评。[Dreamer 配方及验证](../../specs/030-ai-retouching/source-review.md) · [DxO · Nik Silver Efex 指南](https://userguides.dxo.com/en/nikcollection/silver-efex) |

## 首批选型

人像选「逆光人物提亮」「明暗黑白人像」，风光选「天空压高光」「暮色冷暖」，纪实选「中性还原」「克制黑白」，另加同组交付工具「同组参考配平」。七张卡都能在本机离线完成。首轮评审用不同肤色、雾景、剪切天空和彩色现场灯做反例，检查摄影师是否能识别不适用的卡，以及保留原来光线是否更合适。具体起调值、手工替代和操作验收分别落在[七张卡的设计](../../specs/030-ai-retouching/scene-presets.md)和[编码前体验设计](../../specs/030-ai-retouching/ux-design.md)。
