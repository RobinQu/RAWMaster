# 原片、副本与命名快照的原生验收

2026-11-27 在 macOS 的原生编辑控制器和 SQLite 目录上执行。样片取自仓库已有的 24 MP 雪地 ARW，SHA-256 为 `ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2`。每个测试单独建立和清理临时资料库。35 项编辑及工作流回归、2 项目录专项全部通过。[交互入口与浏览器验收](../../virtual-copies.md)

| 操作 | 实际核验 |
| --- | --- |
| 调整原片后立即退出，创建同源副本 | 副本取得刚写入的彩色配方，从空快照列表开始。原片保存饱和度 0.33，副本保存自己的黑白调整后进入 HDR，把场景节点调到 +1.75 EV。两个独立编辑器实例先后打开同一目录，分别取回原片彩色配方、副本完整 HDR 图、副本的黑白配方及相应快照。同源后台通知显示副本名，旧焦点的调整票据无法修改原片。[原生副本编辑测试](../../../../Tests/RAWMasterUITests/EditingVirtualCopyContextTests.swift) |
| 原片准备保存时离开编辑，先保存副本 | 测试控制两笔写入的完成次序。副本先持久化 −0.625 EV，原片随后持久化 +0.875 EV。资料库收到两次各自对应的呈现更新；编辑焦点始终指向副本。[迟到写入与刷新](../../../../Tests/RAWMasterUITests/EditingVirtualCopyContextTests.swift) |
| 分别命名、恢复和删除快照 | 「雪地彩色」和「雪地黑白」属于同一兼容调色分支，「雪地高光」保存完整 HDR DAG。换片或重新打开后，恢复的曝光、图、父版本和快照 ID 均与保存时吻合。HDR 与兼容调色的恢复都可撤销，删除也随库重开生效。彩色和黑白实际色度图占用 577 格和 1 格，每次均采样 10,880 个像素。HDR 同次取样 128 × 192，场景 AP1 峰值 13.452231，Rec.2020 目标峰值 1.4142137。[原生快照与像素测试](../../../../Tests/RAWMasterUITests/EditingAppearanceRoundTripTests.swift) |
| 两个 SQLite 连接同时创建快照 | 同一个 work、真实父版本与色彩分支下的两次创建都保留。第三个连接确认重命名和删除。关联错误的父版本或把 SDR 配方提交到 HDR 分支会报错。第 33 次创建被拒绝，原有 32 条仍在。[并发与旧目录兼容](../../../../Tests/RAWMasterCoreTests/DevelopmentSnapshotStorageTests.swift) |
| 采纳外部归档后创建副本，离线、重连并恢复 RAW 调整 | 使用两张像素和 SHA-256 都不同的真实 PNG。已有 +0.75 EV 的原片采纳外部返回后，副本预览和 032 都使用经哈希校验的归档字节。原片离线及重连后仍能读取这份归档。回到当前编辑可继续修改原来的 +0.75 EV，改到 −0.5 EV 后，下一份副本和新交付取回该配方，前一份副本继续指向原归档。[归档选择与交付冻结](../../../../Tests/RAWMasterUITests/EditingVirtualCopyContextTests.swift) |

单独复验 AI 制作任务时，先模拟归档发布遇到磁盘空间不足，再在界面出现可恢复状态后立即恢复保存。控制器等待同一尝试的收尾工作，核验已接收的结果并完成归档。供应方调用次数为 1；界面与 SQLite 均得到结果版本。[恢复保存回归](../../../../Tests/RAWMasterUITests/EditingWorkflowTests.swift)

签名包走查发现旧重命名弹窗点击「存储」后关闭，目录仍保留原名。新版重命名表单在打开时固定具体快照、呈现、父版本和调色分支。窗口焦点转入表单后，第二个快照可从「快照 2」改为「雪景彩色」，独立 SQLite 连接读到新名称，第一行保持原名。空白或 61 字名称在表单内提示。另一个连接删除快照后，旧表单不能重建它；切片后的保存也不能改到另一张照片。真实 HDR 快照通过同一入口保存名字并跨库重开。[重命名与焦点回归](../../../../Tests/RAWMasterUITests/EditingSnapshotTests.swift) · [HDR 重开](../../../../Tests/RAWMasterUITests/EditingAppearanceRoundTripTests.swift)

在仓库根目录运行以下命令即可重跑这组断言。真实 RAW 由环境变量指定。

```sh
RAWMASTER_SCENE_DELIVERY_SNOW_ARW="$PWD/output/037-038-product-3g3KH4/photos/snow.ARW" \
RAWMASTER_FLASHRAW_LIBRARY="$PWD/output/tools/flashraw-target/release/libflashraw_capi.dylib" \
swift test --filter 'testEarlierPhotoWorkPayloadResolvesItsDraftAndAdoptedArchive|testNamedSnapshotsMergeConcurrentWritesAndReopenByWorkParentAndAppearance|EditingVirtualCopyContextTests|EditingAppearanceRoundTripTests|EditingWorkflowTests|EditingCanvasTests|EditingSnapshotTests'
```
