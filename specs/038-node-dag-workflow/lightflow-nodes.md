# Lightflow Nodes 前端走查

2026-11-28 核对公开构建 `20261111155800-2d41ab1`。HTTPS 首页和编辑器脚本与 Spec 035 的留存版本逐字节一致。编辑器脚本 SHA-256 为 `0ca67eaec7788ac79439d6700c6791cff845bbb8938d6b2d295831871afc678e`，下表用从零开始的文件字节偏移定位打包代码。REA 静态证据 `ev_1ad168b6c05845b09acfab3ead672906d9375fe83a0a57a3e08d68059e41a493` 解析单个编辑器脚本，动态调用和其他资源的关系仍属部分覆盖。[发布首页](https://lightflow.dev/) · [编辑器脚本](https://lightflow.dev/assets/index-zP4kU_H7.js) · [发布清单](../035-portable-processing-cores/evidence/lightflow-release.json)

| 项目 | 发布包观察 |
| --- | --- |
| 节点位置和网格 | 指针先经画布平移、缩放的逆变换，再换算为节点坐标。拖动期间更新临时位置及连线。放手以八分之一格为精度提交一次 `Move Node`，Escape 或 `pointercancel` 丢弃临时位置。输入、输出端也有可移动坐标。移动期间可保持多选相对位置，靠近画布边缘时视口可随指针滚动。见 `842526`、`875250`、`877973`、`883399`–`885958`。网格步长随缩放变化、起点随平移变化，见 `889121`、`889410` 和 [CSS 网格](https://lightflow.dev/assets/index-DkoodY4j.css)。 |
| 多输入端口 | Parallel 和 Layer 按入边数分配已连接端口，再保留一个空闲的增加槽。已有端口按输入序号显示并分别命中，连线以边上的 `index` 定位端口。Layer 在相应端口附带可用的混合模式信息。混合节点随端口数增高，所有输出线从右侧端口出发。见 `827904`、`828742`、`830081`、`832434`。 |
| 添加 | 串行调色插入在当前节点之后，并把原有后继接到新节点。并行或图层调色从选中节点的输入分支分出一路，创建同类混合节点或复用已有混合节点，然后选中新调色节点并定位。见 `265018`、`265697`、`839937`、`840361`。 |
| 监看 | Solo 保存当前 Corrector 的 ID，选中另一节点时继续显示原 Solo，按新节点的 Solo 按钮才切换监看。再次按同一节点的 Solo 或点状态条可退出。全局调色旁路另存为 viewer 标志，允许和 Solo 同时为真，渲染结果优先显示旁路。两者维持图和历史记录。选中节点的眼睛按钮则写入自身 `enabled` 并进入历史。见 `844427`、`871469`、`892409`、`1259538`、`1261092` 及 [预览 Worker](https://lightflow.dev/assets/worker-PmnZFHwu.js) 的 `190366`–`190740`。 |
| 整理及取景 | 整理按上游深度排列，从最终输出向上追溯，同层的分支放到不同的行，先接入的支路沿主行。整理提交布局后适合全图，适合全图按钮只改变取景。按钮顺序为三个添加、Solo、调色旁路、整理、适合全图、全屏。见 `274377`、`842961`、`871736`、`873613`、`877298`、`891732`。 |

## 浏览器复演

用仓库 [Lightflow 隔离加载脚本](../../scripts/performance/lightflow-ui.py) 的 `start`，指向固定发布镜像和 [JPEG 样片](../../Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg)。在 Chrome Headless Shell `157.0.8103.78` 的 1440 × 900 视口，打开 Develop 底边的 Nodes，以指针操作面板。REA 监听器证据 `ev_a900c1f354d9d85be9b44bfc3bd794bf8e71540446fc143736c461fbe7e78014` 记录画布上的 `pointerdown`、`pointermove`、`pointerup`、`pointercancel` 及滚轮监听器。下面的状态变化来自单独的 CDP 操作复演。

1. 添加串行节点 B，从 A 开启 Solo 后点击 B，角标保持 `Solo 01`。在 B 上点 Solo 才改为 `Solo 02`。再开全局旁路，两个角标同时出现。关闭两种监看后，图节点、边和历史与添加 B 后一致。
2. 从 B 添加 Parallel，再从新增分支添加 Layer。Canvas DOM 中两个混合节点各显示连接槽 `1`、`2` 和空闲槽 `+`，两条输入线终点的垂直距离各为 18 个画布像素。点击右栏眼睛时观察到所选节点 `enabled` 由真变假，提示变为 `Enable this node`。再次点击后恢复。
3. 拖动新分支时读到临时位置变化，Escape 恢复原位置 `(312, 216)`。第二次拖动放手后，画布坐标变为 `(234, 175.5)`，历史只增加一项移动。Fit 改变缩放与偏移，坐标仍为 `(234, 175.5)`。Clean Up 恢复节点规整位置，边集与拖动前一致，撤销整理后可读回 `(234, 175.5)`。
4. 把新增分支成组并双击进入。开启组内 Solo 后再开全局旁路，存储的监看 ID 仍是组内 Corrector。`bypassGrade` 为真，`bypassBase` 为假，图配方与新建组后相同。

## 已发布引擎的监看范围

使用 128 × 128 不透明 RGBA16F 渐变，Base 曝光 `+0.25 EV`，A 和 B 曝光分别为 `−0.75 EV` 和 `+1 EV`，混合量分别为 `0.55` 和 `0.70`。含组的图为 `A → Group(B) → C`，C 曝光 `+0.5 EV`。用 macOS Chrome Headless `158.0.0.0`、Apple Metal WebGPU 读回每个已收敛帧，按原始 RGBA16F 字节计算 SHA-256。[Spec 035 的 WASM 读回方法](../035-portable-processing-cores/evidence/lightflow-graph.mjs) · [固定 WASM](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/web/lightflow_host_wasm_bg.wasm)

| 读回条件 | SHA-256 前 12 位 |
| --- | --- |
| 仅 A · 串行图 Solo A | `550bca934e29` |
| 仅 B | `b9a4e1c61af4` |
| 串行 A → B · 串行图 Solo B · 组内 Solo B | `2be94818b339` |
| A → Group(B) → C 完整输出 | `482e1436fc42` |
| 空调色图 · 串行图全局旁路 · 含组的图全局旁路 · 组内 Solo 与全局旁路同时开启 | `3d83858f87fc` |
| 空调色图且旁路 Base | `77bae9318c6b` |

同一行的完整哈希相等。Solo 读取选定节点及其原有上游，因此组内 B 带入组外 A，停在 B。全局旁路则从整张照片的 Base 取结果，作用域跨组。像素复验覆盖串行和单层组，需要另行验证复杂蒙版或更深嵌套的输出。RAWMaster 的入口、布局和可操作场景见 [规格](spec.md) 与 [验证记录](validation.md)。
