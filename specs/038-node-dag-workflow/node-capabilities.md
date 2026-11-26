# Node 能力范围与 LightFlow 对照

2026-11-26 · 固定发布 `20261111155800-2d41ab1` 的第二轮静态复核。本文记录观察与 RAWMaster 设计映射，不声称恢复了完整 Rust 引擎或最新线上版本。

## 证据范围

REA 父证据：`ev_7c17d442fa302e9af5fb180580cf26b25bf0f0552b4e3613ec4285bb87c54b21`。5 份 JavaScript 资产共读取 1,948,330 字节、解析 510,205 个 AST 节点，语法解析失败为 0；静态关系和语义图均为 partial，存在别名与保留预算限制，6000 个保留 unknowns。静态解析不证明运行时执行。

完整两条 Evidence 已保存为[本机研究证据包](../../output/research/node-dag/lightflow-node-rea-20261126.json)，不加入产品分发。导出的 tracked-question ledger 数量为 0，不等于上述语义 unknowns 为 0。

另以原文件 UTF-8 零基字节区间复核下列注册表与工厂。源目录为本机 `output/research/node-dag/lightflow/`，研究资产不作为产品分发依赖。

| 资产 | SHA-256 |
| --- | --- |
| `assets/index-zP4kU_H7.js` | `0ca67eaec7788ac79439d6700c6791cff845bbb8938d6b2d295831871afc678e` |
| `assets/worker-PmnZFHwu.js` | `1c1203c0e3d6e4329d9ac2892b61fc4e3fca4e805c73b919ab17f72cf240d2fc` |
| `rust/web/lightflow_host_wasm.js` | `abfbf794fd93d16630a9a4427b73ae1ee0d6a370f5ecd496a00c0ea261aee055` |

## 普通图节点、阶段与工具不是同一类对象

主包 `[4938,9417)` 的 `Jc()` 分别保存 `source`、`retouch`、`base`、`grade`、`geometry`；`V0()` 创建 corrector 并用 `@input`、`@output` 终端连接。图工厂 `DO`（`[265050,267250)`）创建 parallel/layer，`_O`（`[272300,273510)`）创建 group。

| LightFlow 观察对象 | 观察到的能力 | RAWMaster 规格映射 |
| --- | --- | --- |
| Corrector | 单图像输入；稀疏 `tools`、mask、opacity、enabled | 调色节点；仅开放本节点参数分类、强度、忽略。Mask 从画布工具条编辑，明确拥有者 |
| Parallel Mixer | 有序多输入；归并调色支路 | Parallel；显示输入顺序、支路权重和忽略，不伪装成调色节点 |
| Layer Mixer | 有序多输入；逐输入 blend mode | Layer；基底与图层顺序、强度、混合模式及添加输入 |
| Group | 单入单出连续子图；嵌套节点与边 | 组摘要、强度/忽略、进入与退出、模板；不把内部参数广播给整组 |
| Input / Output | `@input` / `@output` 终端，非 corrector | 固定输入/输出边界；来源与最终输出状态，不显示调色分类 |
| Source / Base | 解码、镜头适配、源 Profile、拍摄白平衡与基础显影 | 照片输入阶段的能力与设置。源白平衡不解释成节点创意色温 |
| Geometry / Crop | crop、angle、quarterTurns、flipH/V、aspect | 画布底部 Crop；作用于整张照片，在图中只标识固定阶段 |
| Retouch | heal、clone、remove、inpaint；有序 strokes、sourceOffset、patch、opacity、enabled | 画布底部 Remove；全照片修饰阶段与候选管理，非自由复制的调色节点 |
| Mask component | semantic、brush、linear、radial、color、luminance、saturation、hue、depth、node | 画布底部 Mask；覆盖组件绑定明确的调色节点，统一入口不等于全图广播 |
| Outside | 克隆前节点 mask 并反转（`UO`，`[275412,276341)`） | “添加 Outside 调色”命令，不单独虚构一种引擎节点 |

普通图节点种类的上述集合来自明确工厂和分派；未解析的动态或 WASM 内部种类仍未知，不能据有限字符串搜索宣布不存在其他种类。

## Corrector 的九类参数域

`Qn` / `Gd` 的明确清单位于主包 `[5800,8632)`，显示名在 `[355249,355832)`；`OI()` 只对 `kind === corrector` 返回已用工具域。

| 参数域 | 观察到的字段族 | 原型对应分类 |
| --- | --- | --- |
| Basic | 创意温度/色调、曝光、对比、高光/阴影/白黑、纹理、清晰度、去雾、自然饱和度/饱和度 | 基础 |
| Color Wheels | lift/gamma/gain/offset、contrast/pivot、log wheels/ranges、分级轮、混合/平衡 | 色轮与分级 |
| HDR Wheels | 六个亮度区及全局曝光/饱和度、范围/过渡、色温/色调/色相、对比/pivot | HDR 色轮 |
| Curves | master/R/G/B、参数曲线及分割点、Hue-vs-Hue/Sat/Lum、Lum/Sat 相互曲线 | 曲线 |
| Color Mixer | 八色 HSL、RGB 3×3、保亮度与单色 | 混色 |
| Color Slice | red/skin/yellow/green/cyan/blue/magenta 的中心/宽度/色相/饱和度/密度、全局深度 | 色彩切片 |
| Color Warper | hueColumns、satRows、pins、strength、mesh | 色彩变形 |
| Detail | 锐化 amount/radius/detail/masking、明度/颜色降噪族、blur | 细节 |
| Effects | 暗角族、颗粒族、bloom/threshold、halation、LUT | 效果与 LUT |

原型字段是交互示意；正确默认值、原生单位、色彩空间、邻域半径与全质量实现由原生验收冻结。RAW 传感器细节、超分和 AI 请求不能因为“细节”标签而自动成为任意 corrector 的能力。

## 混合与图命令

`hw`（主包 `[356728,357505)`）列出 13 种 Layer 模式：normal、add、subtract、multiply、screen、overlay、soft-light、hard-light、lighten、darken、difference、color、luminosity。原型展示模式选择与顺序，不以 CSS 近似证明这些模式的像素公式。

`MX`（`[868600,873450)`）注册串行前/后/末尾、Parallel、Layer、Outside、忽略、复位、上一/下一、分组/解组、删除、复制/粘贴/属性粘贴、临时输出、命名、整理、适合全图、悬浮/全屏、组路径、组模板、整图模板与批量应用。RAWMaster 保留统一图命令，并把 Graph 改为与主图同时存在的非模态 Liquid Glass 悬浮面板。

本轮复用上述注册表的 `nodes.toggleSelected`、`nodes.fullScreen`、`nodes.autoLayout` 与节点/图命令分层；没有把完整注册表铺在检查器菜单里。RAWMaster 将节点列表与添加/整理/更多操作合并成一个下拉，右侧常驻「忽略该节点」及 Graph 开关。高级组、连接、模板和整图命令折叠保留。520×392 的最小外框及 240px 画布高度是 RAWMaster 的原型取值，不归因于 LightFlow。

端口使用索引边 `{from,to,index}`，mixer 有多个输入及一个待接空槽；普通节点为单输入。`HO` / `tg`（`[267900,269520)`）拒绝自连、回路、反向终端，并整理输入索引。RAWMaster 以命名 base/layer 槽表达基底与有序图层，不能把颜色混色参数域误计为图 mixer。

## Mask、修饰与执行边界

`Vr`（主包 `[893600,895500)`）给组件分配 add/subtract/intersect、invert、opacity、enabled；semantic 支持人物部位及风景目标；node 是遮罩引用，需单独验证依赖，不能等同普通图像边。遮罩复合的 refine 包含羽化、扩张、平滑、边缘/发丝和降噪。

修饰模式菜单位于 `[963000,964150)`，对象工厂在 `[956480,957122)`。Remove / Inpaint 的 patch 与 Heal / Clone 的 sourceOffset 在 worker `Gp` / `Hp`（`[163360,164130)`）分开签名。生成任务、蒙版分析与候选采用不应伪装成即时调色参数。

Worker 的 query/viewer 把 edit JSON 送入 `renderEncoded` / `viewerFrame`；WASM glue 的 `render` 调 `wasm.pixelengine_render`，返回 GPU 句柄、segments、cached、provisional、pending。可见 JavaScript 只证明该接口边界；本轮未反汇编 WASM、未重跑真实 GPU 夹具，内部图融合、准确混合公式、模型与性能继续未知。

[规格](spec.md) · [原型走查](validation.md)
