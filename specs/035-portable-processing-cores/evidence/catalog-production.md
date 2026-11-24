# 资料库生产实现验证

2026-11-23。测试对象为 `Modules/LibraryCatalog`、Swift 资料库入口和同一套 SQLite v9 任务表。下表区分 Rust 无界面执行、原生 Swift 调用和真实照片归档。

| 环境及入口 | 结果 | 覆盖范围 |
| --- | --- | --- |
| macOS arm64，Rust 完整测试集 | 68 通过，0 失败，5 项按环境跳过 | 包含 10 项队列测试及 v9 备份恢复 |
| Linux arm64，Debian Bookworm，Rust 完整测试集，bundled SQLite | 67 通过，0 失败，5 项按环境跳过 | 同样的 10 项队列测试及 v9 备份恢复。macOS 另有一项 ImageIO 几何测试 |
| macOS，RC4 的 `CatalogProcessing035Tests` | 12 通过，0 跳过，0 失败 | 经 Swift 调用 Rust，使用真实 v8 快照回放迁移，另测数据库事务回滚、取消、文件重试和预览 GPU 名额 |
| macOS，单独运行真实照片归档用例 | 两种配对主文件选择均通过 | 4 张 Sony ARW 加 1 张相机 JPEG，历史 v8 库的两种选择各有 2 份原件进入归档并成功恢复 |

真实 v8 快照含 6,928 个资产、1,408 个目录文件和 11 个编辑版本。本次回放中的历史回执、已注册资源及处理任务均为 0。测试在快照的临时副本上执行升级，比较六项计数、全部 1,408 个有序选片 ID 和原始快照的 SHA-256。升级后的外键检查无异常。另一用例验证升级前的 SQLite 备份可以按 v8 读取，并确认缺少注册索引的 v9 库在写入前即被拒绝。[Swift 迁移与任务测试](../../../Tests/RAWMasterCoreTests/CatalogProcessing035Tests.swift)

## 并发、取消与交付

| 情形 | 实际断言 |
| --- | --- |
| 多连接领取 | 8 个连接竞争有限的 CPU、GPU、I/O 与内存额度，额度保持在上限内。8 个并发调用提交同一键和配方，只产生一次领取。过期 token 在重领前即失效 |
| 取消与重试 | 被取消的创建者可以撤销自己的排队项，重复等待者不能撤销它。工作尚未开始时释放已经取得的 token。运行中的工作退出后才归还设备额度。一次真实的缺失文件读取在退避后恢复，只产生一个回执 |
| 预览与后台共享 GPU | 后台任务占用一个名额，另一后台任务达到等待阈值时，预览仍可取得保留名额，后续后台任务在额度释放后运行 |
| 已准备的导出 | 持久化前同步临时文件及目录。成功交付要求目标文件身份、字节数及 SHA-256 匹配，再同步文件和目标目录并提交回执。取消、进程重开或租约过期后，仅有临时文件的任务保留待核对状态 |
| 文件冲突与恢复 | 相同字节、不同 inode 的既有文件不能完成待核对任务。符号链接、目标内容变化和已确认的排他发布冲突均不能产生成功回执。v9 备份恢复后，旧主机租约失效，恢复后的库不会读取原主机的外部交付路径 |

卷离线与重新出现用临时目录移走和移回模拟。文件系统身份变化用已保存的设备号与 inode 不匹配模拟。真实可移动卷拔插和跨主机挂载身份尚待实机验收。真实照片归档使用 v8 库，v9 恢复的进程隔离和外部文件边界由独立的临时库用例验证。[Rust 队列测试](../../../Modules/LibraryCatalog/tests/scheduled_processing.rs) · [v9 恢复测试](../../../Modules/LibraryCatalog/tests/backup_packages.rs) · [真实照片归档测试](../../../Modules/LibraryCatalog/tests/real_photo_archive.rs)

## RC6 批次清单与两种恢复入口

macOS 和 Linux arm64 分别通过 16 项调度及 8 项备份测试。新增覆盖同时登记或明示续领、活租约竞争、未重领即到期、两种取消顺序、历史记录隔离，以及同 UUID 的大小写与原始文件名的 Unicode 往返。原始 C ABI 用同一 JSON 数字 `51.248178375505404` 登记后读取。原测试库返回位型 `40499fc44f1b2f61`，当前库返回正确位型 `40499fc44f1b2f60`。[逐位复验](catalog-batch-abi-float.json) · [批次队列回归](../../../Modules/LibraryCatalog/tests/scheduled_processing/workbench_batches.rs)

RC6 封存 Release 运行 13 项 `CatalogProcessing035Tests`、25 项 `EditingTests` 和 2 项 `ExportWorkspaceTests`，全部通过。Swift 编辑备份的原生回归让原资料库和恢复副本同时打开。副本换 writer 后只提供批次历史摘要，旧批次和逐项令牌在副本失效。原库的两种租约仍可核验。原暂存文件字节保持一致，正式目的地为空。交付工作台产生的两个逐项收据使用与界面相同的批次 ID。封存测试日志在 `output/035-development/candidate-rc6-mixed/`。[Swift 备份与租约用例](../../../Tests/RAWMasterCoreTests/CatalogProcessing035Tests.swift) · [工作台收据用例](../../../Tests/RAWMasterUITests/ExportWorkspaceTests.swift)

RC7 的 v2 批次清单用 SHA-256 引用工作版本和输出配置。两端分别通过 20 项队列及 8 项备份。两张照片各引用一份超过 8 MiB 的双 64³ LUT 正文，清单小于 4 KiB。交换合法的两份正文、角色不符、登记冲突以及同尺寸内容变更均被拒绝。备用资源在首次登记前已暂存，登记资源、清单与租约使用同一事务。当前以完整工作版本或配置为单位去重。[资源与批次回归](../../../Modules/LibraryCatalog/tests/scheduled_processing/workbench_batch_objects.rs)

同一 RC7 的 42 项 Swift 定向用例全部通过。实际 `PhotoWork`、`EditingVersion` 和 `PhotoBatchExportConfiguration` 经 C ABI 登记及读回。草稿沿用原版本 ID，两个 64³ LUT 的每个 Float32 RGB 字节相同，逐层强度的 Double 位型精确保持。Swift 编辑备份把 9 MiB 资源带到独立目录，拒绝降级清单、同长度内容篡改和保留命名空间冲突。工作台提交的原生重启续做仍待接线及实机复验。原始结果位于 `output/035-development/candidate-rc7/`。[Swift Codable 对拍](../../../Tests/RAWMasterUITests/ExportWorkspaceTests.swift) · [大配方备份回归](../../../Tests/RAWMasterCoreTests/EditingTests.swift)

## 复跑

在仓库根目录执行以下命令。离线运行需要已缓存 Cargo.lock 对应的依赖。Swift 的 `V8_SNAPSHOT` 指向一致的历史 v8 快照，测试自行创建临时副本。

```sh
cargo test --jobs 2 --locked --offline --manifest-path Modules/LibraryCatalog/Cargo.toml -- --test-threads=2
RAWMASTER_QUEUE_V8_SNAPSHOT="$V8_SNAPSHOT" swift test --filter CatalogProcessing035Tests

mkdir -p output/035-linux-catalog
docker run --rm --cpus=2 -v "$PWD:/src:ro" -v "$PWD/output/035-linux-catalog:/out" \
  -v "$HOME/.cargo/registry:/usr/local/cargo/registry:ro" -w /src \
  rust@sha256:7c7d4eb4d05b7781187a327809466cfddf29753f6defdc3d19a0e291951b7a37 \
  cargo test --jobs 2 --offline --locked --manifest-path Modules/LibraryCatalog/Cargo.toml \
  --features rusqlite/bundled --target-dir /out -- --test-threads=2
```

完整 Rust 测试集默认跳过五个需要额外输入的用例，分别涉及真实照片归档、六张 RAW 的延时视频报告、人物向量清单、Lightroom 源库及原生组渲染器。表中真实照片归档单独提供了对应输入。[真实归档用例的输入说明](../../../Modules/LibraryCatalog/tests/real_photo_archive.rs)

| 本地验收日志 | SHA-256 |
| --- | --- |
| `output/035-native-catalog/final-rust.log` | `7e85ffe02e1a6f042334ec63328531fffa16b36ce30efb6f825b1c0599f899f6` |
| `output/035-linux-catalog/final-rust.log` | `acade63a433a90c43f0d7886d39ba312f73d37e999c980f89895405914dbe8db` |
| `output/035-development/candidate-rc4/catalog.log` | `c1649b7dbef8bc39d78085c236a9f9db455024310777c90de24c19a5ace5b294` |
| `output/035-native-catalog/real-archive-035.json` | `1a198e99c2642511e21d17950de1c4f1408443a705f27376eb949961af179cc3` |
