# 033 前三阶段交付验收

2026-11-22。资料库内核在 Rust 中维护，桌面窗口通过 C ABI 访问同一份 SQLite。联调基于 Camera Raw 完成的 `e2b9c68a`。回归使用现有目录的独立快照和已挂载的实际照片。

## 阶段一 · 目录、筛选和备份

默认库由应用管理。用户可以切换资料库、查看位置、制作可搬迁的包或在空目录还原。v7 升级先用 SQLite Online Backup 固定含已提交 WAL 的视图，在副本演练，再检查源修订并提交 v8。资料库格式、内容、物理位置和每次导入分别具有身份。旧版 v1 的真实迁移备份也已在副本上打开，比较了原有记录及源文件字节。

桌面网格每页读取 60 个条目。文件级谓词在同一成员内求交，翻页游标和批量操作绑定同一次查询修订。用已有库核对了 11 组查询的完整顺序、总数、游标遍历和批量目标，覆盖空结果、时间、评级、中文短词、项目及机型。[分页回归](../../Tests/RAWMasterUITests/LibraryPageParityTests.swift)

封存决定分别属于每次出现的每个原件。A 为 RAW 与机内 JPEG，B 显式选择仅供序列，C 是组内必要帧且最终排除，D 是异常文件。两轮对调 A 中最终保留的成员，每轮完整备份都只包含 A 的一个成员和 B。用 SHA-256 核对包内物理对象，移开源目录后还原并再开库，均恢复两个独立原件。随后显式恢复 C 并做下一代备份，原件数变成三个。实拍 JPEG 取自 A 的相机内嵌预览。完整备份保留同代目录、历史决定和必要编辑资源。[真实宿主回归](../../Tests/RAWMasterCoreTests/LibraryImportArchiveTests.swift) · [内核回归](../../Modules/LibraryCatalog/tests/real_photo_archive.rs)

## 阶段二 · 组织、检查与迁移

资料库菜单提供组织、检查器、受管文件与 Lightroom 迁入。目录、集合及集合组、限定范围的堆栈、规则、顺序和虚拟副本具有独立标识。受管移动和恢复逐个核验原件及旁车，保留离线、冲突和部分完成的状态。检查器将用户写入的 IPTC、历史来源字段、直方图像素来源和人工对焦判断分开保存。[组织与查询回归](../../Modules/LibraryCatalog/tests/query_organization.rs) · [受管文件回归](../../Modules/LibraryCatalog/tests/managed_files.rs)

Sony 实拍检查覆盖 16 个 RAW、3 款机身和 42 个区域。16 张均读回 EXIF 与 RGB 各 256 桶直方图。13 张有可定位的相机 AF 信息，3 张星空仅有中央回放回退，界面显示未知。11 个经人工确认清晰的区域均未误标。一张可见偏软的河岸照片也被机器判作未知，人工纠正后仍可纳入资料库。该样本缺少能确认是光学失焦的正例，尚不能估计此类漏报。[逐项结果](inspection-native-validation.md)

五份真实 Lightroom 目录共含 64,394 个作品，其中 123 个是虚拟副本。17,636 项普通集合成员顺序、16,693 项堆栈成员关系、648 组封面及折叠状态均与来源一致。15,494 份候选历史预览中有 15,472 份可解码，15,335 份还可核对到作品的同代显影修订。另有 137 份可打开但版本未证实，22 份无可解码图层。保留了 64,394 份 XMP、64,126 份显影原文和 145 项伴随文件引用。[五库逐项对账及还原结果](evidence/lightroom-release-validation.json)

Lightroom 按组织、元数据、可获得的历史外观分别对账。对每份源目录固定只读视图，按来源标识和版本保存 Adobe 显影原文、XMP 及依赖。源预览可解码、同代摘要可核验、较早代预览仍可取用是三种不同的展示状态。迁入本身不改变原片归档资格。已用同一目录的两个虚拟副本检查历史外观与还原的独立性。实际宿主的作品检查器可从指定主片或副本建立独立曝光、裁切版本。四个同源作品恢复后的版本、来源摘要、像素和尺寸全部相符。另用一张 Sony RAW 在完整还原后重新定位原件，复核了裁切像素。[作品编辑的宿主与还原测试](lightroom-native-edit-validation.md)

## 阶段三 · 分组制作与检索

先冻结所选组的成员顺序、文件、内容摘要、版本与配方，再发布受管成片。组、任务、作品和输入双向可追溯。六张真实 RAW 经桌面延时入口生成 6 帧视频，移走外部导出后仍能从资料库重开。星轨、HDR 与全景的受管母版均已原尺寸读回。24 张星轨中的前四张有构图变化，选参考帧保留前景后，两处塔身与参考图的相关性分别从 0.153 和 0.303 升至 0.977 和 0.985。真实运动 HDR 轮廓、近景视差仍需带标注的正例。[延时回归](../../Tests/RAWMasterUITests/LibraryGroupTimelapseRealTests.swift) · [合成与失败案例](group-render-validation.md)

文搜图使用固定 SigLIP2 图文双塔，权重 FP16、运算 FP32。12 个独立拍摄目录的 24 张留出照片上，10 个有答案的中文查询首位全部命中，3 个无答案查询中有 1 个误报。以下为首版 SFace 基线，当前生产模型及实拍见[跨日期、跨机身的人脸检索](face-retrieval-upgrade.md)。人脸检测与分组建议逐库授权，人工确认、合并、拆分及撤销独立于机器索引。建议阈值 0.80 下，完整样本的 1,137 个异人对均未误并，同人对只命中 69/690。按日期留出的跨日且跨机型同人对命中 0/41，跨时段找人仍依赖确认和人工合并。围栏用空间索引取候选，再核验实际坐标，覆盖凹多边形、反经线、极区和清空 GPS 后重建。[画面留出](evidence/discovery-scene-validation.json) · [人物分层结果](evidence/discovery-faces-validation.json) · [空间基线](evidence/geofence-baseline.json)

跨库检索只查询用户勾选的来源，按库展示覆盖、版本与结果。两份实拍库里的同名、同作品 ID 各自命中一次。原片、人物关系和围栏按来源约束，取消勾选后的迟到结果已剔除，单库离线时其余库仍返回结果。发行模型包实测可用。独立宿主通过 4 个已纳入的 RAW/JPEG 跑完 8 个本机索引作业，原片移开后仍能读取已核验 JPEG 代理。[跨库回归](evidence/discovery-federation-validation.json) · [智能检索实施和复跑步骤](discovery-implementation-evidence.md)

## 可复跑的真实窗口测量

在 Release 构建下使用现有 v7 快照的私有副本。每轮从打开到原生 AppKit 视图发生可见绘制计时，分别记录首卡和首张缩略图。四轮各实际导入 6 个 RAW，并在同库切换筛选。“导入中”仅统计从输入至绘制完全落在真实导入期间的样本。P95 采用最近秩，RSS 为测试进程峰值。缓存和首次迁移对比保留各自口径。[窗口测试及原始记录格式](../../Tests/RAWMasterUITests/LibraryGridPerformanceTests.swift)

| 实际窗口操作 | 样本数 | 首卡 P50 / P95 | 首张可见照片 P50 / P95 |
| --- | ---: | ---: | ---: |
| 第一次打开 v7、升级并建索引 | 4 | 3,158 / 3,245 ms | 3,170 / 3,271 ms |
| 重开已有索引的 v8 库 | 4 | 225 / 249 ms | 249 / 277 ms |
| 空闲时切换筛选 | 24 | 78 / 95 ms | 86 / 111 ms |
| 导入期间切换筛选 | 34 | 82 / 100 ms | 93 / 113 ms |

原有快照含 6,928 条文件记录、1,408 个已纳入文件，打开时窗口绘制 12 张可见卡片。空闲与导入时都在“所有照片”和“至少四星”两种非空结果间切换，并在两种结果上等待真实缩略图绘制。四轮的索引含 WAL/SHM 均为 7,589,888 字节，测试进程峰值 RSS 为 709,935,104 字节。首开包含旧库演练和迁移，重开复用已建索引。普通重开使用只读验证，检查器的原片保护路径在独立连接完成。[逐次窗口样本、备份与打包结果](evidence/library-delivery.json)

```sh
RM_CATALOG_BACKUP="$V7_SNAPSHOT" \
RAWMASTER_RUNTIME_RAW_DIRECTORY="$SIX_RAW" \
RAWMASTER_RUNTIME_TOOL_ROOT="$METADATA_TOOL" \
RAWMASTER_LIBRARY_UI_REPORT="$NEW_REPORT" \
swift test -c release --filter LibraryGridPerformanceTests
```

该检出的 Release 回归收集到 119 项界面测试和 355 项 Core 测试，各有 3 项按环境开关跳过，合计 468 项通过。单独运行的 18 项原生编辑测试全部通过，其中部分也在前述套件内。Rust 默认套件 48 项通过，4 项需要指定资产的用例另用真实 MP4、五份 Lightroom 目录、三种实拍合成和两轮完整备份分别执行。

完整备份的独立内核回归也可以直接复跑。RAW 目录需有六张真实原片，JPEG 路径指向其中对应原片的相机 JPEG，输出使用新路径。

~~~sh
RAWMASTER_CATALOG_SAMPLE_DIR="$SIX_RAW" RAWMASTER_CATALOG_SAMPLE_JPEG="$CAMERA_JPEG" \
RAWMASTER_CATALOG_ARCHIVE_REPORT="$NEW_ARCHIVE_REPORT" \
cargo test --release --locked --manifest-path Modules/LibraryCatalog/Cargo.toml \
  --test real_photo_archive -- --ignored
~~~

主工作目录已在 `210af4c1` 上完成当前源码的 Release 产品构建。独立检出的发行应用通过 macOS 签名校验。在临时 v7 真实库副本上直接启动打包可执行文件，得到 1,480 × 940 点的应用窗口，读出 v8、1,408 个纳入文件和已启动的搜索索引。用包内 Python、ONNX 和权重编码中文查询，得到归一化的 768 维向量。默认库、个人照片和 Lightroom 源目录均未用于覆盖式测试。

Server 冷热存储和远端计算沿用版本化命令、输入身份及作业收据，服务端开发与 100 TB 压测留待后续阶段。
