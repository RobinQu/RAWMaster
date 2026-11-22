# LightFlow 公开版本的资料库实现

2026-11-22 · 阶段一至三技术评审资料。LightFlow 的浏览器版本将目录事务放在 Rust／SQLite 中，又让用户从已有文件夹直接开始工作。两个实测结果影响 RAWMaster 的选择。同一文件仅改名，LightFlow 就多计一张。换成不同内容，只要文件名、长度和修改时间相同，它仍提示已在库中。资料库需要分别表达来源位置、文件内容和逻辑拍摄。 [产品规格](spec.md) · [LightFlow 官网](https://lightflow.dev/)

## 调研对象与复核方法

通过 HTTPS 重新取得线上首页、许可页、前端包、持久化 Worker、Rust 目录与机器学习 WASM 等 65 个同源资源，共 43,901,147 字节。首页指向构建 `20261111155800-2d41ab1`，Rust 清单标记构建时间为 2026-11-11 15:58 UTC、版本 `4df20b5d916f8d0e`。2026-11-22 09:48 UTC 完成抓取并记录每项的 URL、状态、长度和 SHA-256。下载范围覆盖下文资料库操作及本地复演所需文件，外部 ONNX 权重、第三方推理运行时与用户媒体不在镜像中。 [构建入口](https://lightflow.dev/assets/home-CD2BGesn.js) · [Rust 目标清单](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/version.json) · [许可说明](https://lightflow.dev/license)

| 证据 | 定位方式 |
| --- | --- |
| 公开编辑器与资料库入口 | 下文函数名对应这一版 `index-zP4kU_H7.js`，SHA-256 为 `0ca67eaec7788ac79439d6700c6791cff845bbb8938d6b2d295831871afc678e`。首页 SHA-256 为 `df73c8755895192cad1cb2ee6f2fbb1a6b82d45d1e8b6aaeeff7b622d13b829b`。[发布脚本](https://lightflow.dev/assets/index-zP4kU_H7.js) |
| REA 静态分析 | 对持久化 Worker、SQLite／目录迁移／ML 的 WASM 绑定及 CPU Worker 做定向静态分析，并从 UI 处理函数人工追踪到这些模块。下载目录快照 SHA-256 为 `839cc57f015d24c2826aa835bfa5cf038feb78c911e0825e9d6341386367ed97`。原始回执为 `rea-final-receipt.json`。[下载清单](evidence/lightflow-download-manifest.json) |
| 浏览器实测 | REA 在全新 Chromium 157.0.8103.78 配置中打开回环镜像。夹具向原版 Library 派发文件拖放、向搜索框输入文字，读取网格计数与目录 ID。网站请求限于本地镜像。两张合成 JPEG 只用于验证竞品行为。原始夹具和回执为 `browser-fixture.html` 与 `browser-rea.json`。[观测记录](evidence/lightflow-browser-observations.json) |

## 从建库到重新打开

| 操作 | 公开发布包的可观察行为 | 对 RAWMaster 的影响 |
| --- | --- | --- |
| 打开资料库 | `hD` 协调状态引擎，`persistOpen` 在 Worker 内打开 OPFS SQLite 池中的逻辑 `catalog.sqlite` 和操作日志，Worker 提供恢复、flush 与 checkpoint。浏览器还保留 IndexedDB 兼容路径及外部文件句柄。实测引擎报告 `storage=engine`、`adopted=true`，重开后 3 个 ID 完全相同。OPFS 枚举到 `files`、`journal`、`sqlite`，池在磁盘上呈现为不透明文件。 | 应用管理默认库，Swift 只请求打开、查询和写入，Rust 持有事务和升级边界。搬迁与备份应由目录快照和原件清单驱动。浏览器正常重开不能证明异常退出恢复或异机还原。[持久化 Worker](https://lightflow.dev/_b/20261111155800-2d41ab1/engine-state/persist-worker.js) · [SQLite 绑定](https://lightflow.dev/_b/20261111155800-2d41ab1/engine-state/persist/lightflow_host_wasm.js) |
| 导入与重扫 | `sG → aG` 用目录句柄的 `isSameEntry` 复用文件夹，以文件夹 ID 和相对路径生成照片键。只有完整扫描才标记消失的成员为 `missing`。同名 RAW/JPEG 的检查决定 XMP 优先归属，二者仍分别建记录。单文件 `hG` 取文件名、字节数、修改时间，用 `tf` 的 32 位 FNV-1a 生成键。`Sx` 每批并行补读最多 4 项。 | 路径和文件属性适合提示重扫候选。纳入、恢复及内容去重须以已核验的文件摘要和封存决定为准。RAW+JPEG 的处置逐文件保存，配对作为拍摄关系。取消的扫描应保留未枚举成员。[导入实现](https://lightflow.dev/assets/index-zP4kU_H7.js) |
| 文件与缓存 | `dT` 在引擎模式下定位 `lightflow-engine/files`，分别保存 `thumbs/<id>.webp`、`assets/<id>` 和 `imports/<id>/<name>`。无原生句柄的单文件导入尝试复制原件。有句柄时 `bS/cg` 对选定栅格格式做可选缓存，单文件至多 32 MiB，复制后留出至少 1 GiB 配额。 | 单列外盘位置、受管原件和可再生成代理。缓存命中不能取得归档资格，也不能证明独立备份已覆盖。当前阈值属于浏览器的选择。RAWMaster 的容量和淘汰应按本机工作集计量。[缓存实现](https://lightflow.dev/assets/index-zP4kU_H7.js) |
| 整理与筛选 | `Ex` 区分上次导入、快速集合和普通集合。`FG` 在可见成员中展开或折叠堆栈，`Nx` 在同一文件夹内依相邻拍摄时间差生成堆栈，`JA` 建立虚拟副本。右栏有直方图、关键词和元数据，`V$` 可显示 GPS。多选关键词可标出只在部分照片存在的值。`Vq` 的搜索和条件与可命名的筛选预设相连。 | 借鉴多选混合值、折叠与选择范围。给 RAWMaster 的拍摄、序列、集合和版本分别建关系。相邻时间可用于初筛候选，连拍／延时仍需保留证据、允许人工改组。GPS 坐标展示与地理围栏查询分别验收。[资料库界面实现](https://lightflow.dev/assets/index-zP4kU_H7.js) |

### 网格查询与 Lightroom 映射

**网格在内存中完成筛选与排序。** `PersistStore.visible(spec)` 提供 SQL 可见列表接口。该构建的 Library 网格订阅 `Yi → eo → wA → xT`。查询变化时，`xT` 会遍历内存中的 `order`，按星级、旗标、色标、类型、编辑状态及相机等条件过滤，再排序。文字查找对名称、路径、关键词、标题、说明、作者、版权、机身与镜头取小写，多词均须是子串。`wA` 再限制集合成员，网格仅挂载视口附近的卡片。相同输入会复用结果。RAWMaster 应让真实网格入口调用带游标的目录查询。测首屏时同时记录候选量、数据库查询计划及实际物化的行数。 [SQL 绑定](https://lightflow.dev/_b/20261111155800-2d41ab1/engine-state/persist/lightflow_host_wasm.js) · [网格与筛选实现](https://lightflow.dev/assets/index-zP4kU_H7.js)

**Lightroom 导入器和本产品支持的组织功能有不同边界。** 浏览器路径 `qG` 在无原生桥接时将整个 `.lrcat` 读成字节数组，交给 Rust 的 `importLightroomCatalog`。`ZG` 按不区分大小写的文件名找已入库候选，优先匹配路径后缀。多个同名候选都对不上后缀时取首个未分配项。源虚拟副本和目标虚拟副本均被跳过。`TA` 合并已解析元数据与部分显影调整，重建至少两项成功映射的堆栈。RAWMaster 的迁移账本应保存源目录及源对象 ID。歧义需进对账报告，虚拟副本及可获得的历史外观分别关联，Adobe 专有显影数据按原始字节封存。本次只追踪发布包中的导入调用与映射规则，未用真实 Adobe 目录核验兼容版本。 [目录解析绑定](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/io-catalog/web/lightflow_io_catalog_wasm.js) · [匹配实现](https://lightflow.dev/assets/index-zP4kU_H7.js) · [RAWMaster 迁移验收](lightroom-migration.md)

## 人脸、图像表征与模型缓存

CPU Worker 的模型清单将 YuNet 用于检测，SFace 对五点对齐到 112×112 的脸裁切输出 128 维归一化向量。DINOv2-small 的视觉特征为每个 token 384 维。Worker 的 `identify` 分支通过 `mlRun` 将像素、候选外观向量和取消信号交给 Rust 预后处理与模型运行时。显影界面有跨照片复制蒙版时跟随人物或物体的选项。所查 Library 搜索框走前述文字筛选链。这些视觉模型和编辑能力尚不足以证明有中文文搜图、全库人物聚类、人工拆并或向量索引。 [CPU Worker 与模型清单](https://lightflow.dev/assets/cpuWorker-DaXiU2P4.js) · [ML 绑定](https://lightflow.dev/_b/20261111155800-2d41ab1/rust/ml/web/lightflow_ml_wasm.js) · [编辑器与资料库入口](https://lightflow.dev/assets/index-zP4kU_H7.js)

模型清单附权重来源、版本化 URL、字节数、SHA-256 和执行后端。缓存有独立目录与预算，`EG/RG` 按最近使用顺序回收，保护正在打开、下载或排队的模型。RAWMaster 可采用按需安装和任务注明模型版本。文搜图须采用共享空间中的图文编码器，人脸任务另行评估检测、嵌入、聚类和人工纠错。候选权重、授权与真实照片误并率要独立核对。该次浏览器复演没有加载权重，亦未测量推理质量、速度或显存。 [模型缓存实现](https://lightflow.dev/assets/index-zP4kU_H7.js) · [权重读取实现](https://lightflow.dev/assets/cpuWorker-DaXiU2P4.js) · [智能检索规格](search.md)

## 可复核的浏览器结果

| 在空资料库执行的动作 | 观测 |
| --- | --- |
| 拖入一红一蓝两张 JPEG，以 `Study_Amber_01.jpg`、`Study_Blue_02.jpg` 命名 | 目录和网格均为 2。两张均为 771 字节，SHA-256 不同 |
| 在资料库搜索框输入 `amber study` | 网格为 1，命中 `Study_Amber_01.jpg`。文字的大小写与文件名不同，两词顺序相反 |
| 清空筛选，再次拖入原名、原字节、原修改时间的红图 | 目录仍为 2，界面提示已有记录 |
| 红图只改名为 `Renamed_Copy.jpg` 再拖入 | 目录增为 3，上次导入只显示新名称 |
| 将蓝图以原红图的名字和修改时间拖入 | 两者的 SHA-256 分别以 `5950d62a`、`f5e8e002` 开头。界面提示已有记录，3 个 ID 均未改变 |
| 等待 1.5 秒后重新加载页面 | 仍有相同的 3 个 ID，Rust 目录已采用。实测覆盖正常重开 |

发布包、离线夹具和分析回执位于本机忽略目录 `output/library-033-research/lightflow/`。抓取清单与匿名浏览器记录随本规格保存，可逐个核对 URL 和摘要，或对照同版本函数复查。表中合成样本只用于竞品路径核验。RAWMaster 的回归、检索质量和性能使用本项目现有照片。[浏览器逐步记录](evidence/lightflow-browser-observations.json) · [同源下载清单](evidence/lightflow-download-manifest.json) · [本机照片基线](validation.md)
