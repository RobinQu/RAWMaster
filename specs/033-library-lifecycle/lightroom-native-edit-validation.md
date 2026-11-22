# Lightroom 主片与虚拟副本的本地编辑

在资料库的作品列表选中主片或虚拟副本，可从检查器进入该作品的本地编辑，调整曝光与裁切并保存为新版本。界面标明像素起点。已迁入的历史 JPEG 可在原件离线时使用。历史 JPEG 和已纳入原件同时可用时，首次编辑可选择起点。之后重开会沿用原先选择的资源或文件内容版本。

每次保存使用选中作品的 `workID` 和打开时的 `revision`。版本记录包含父版本、起点的 SHA-256 和归一化裁切范围。历史 JPEG 另记来源作品、迁入批次、受管资源和显影摘要绑定状态。原件另记文件及内容身份。同一物理文件可以供多个作品使用。Adobe 参数仍由迁入器原样封存。检查器可针对历史 JPEG 和本地渲染分别即时测量 RGB 直方图，并标明所选作品版本。历史 JPEG 的几何变换不明时，拍摄对焦点可由原件局部核对。[本地编辑及像素实现](../../Modules/LibraryCatalog/Swift/CatalogLocalEditing.swift) · [历史资源解析](../../Modules/LibraryCatalog/src/lightroom/media.rs)

## 实测

从真实 Lightroom Classic 源库重新运行当前迁入器，得到 2,465 个作品、2 个虚拟副本和 3,669 个登记资源。2 个虚拟副本中有 1 个带可验证的历史 JPEG。本次选中的主片和这个虚拟副本使用同一份 JPEG 字节，适合检查同源的版本隔离。自动化又分别在编辑主片前、后各创建了一个副本。

| 检查 | 观测 |
| --- | --- |
| 依次编辑与重开 | 4 个作品保存了 4 个不同版本和 4 个不同的像素摘要。先修改两个副本，主片像素与版本保持原值。随后从已编辑主片创建的副本继承当时外观，修改后各自独立。 |
| 目录包还原 | 隐藏旧库的受管资源目录后，4 个工作版本均从新库资源解析，重新生成的像素摘要及宽高 4/4 一致。 |
| 采样与身份约束 | 3 份历史预览直方图和 3 份本地渲染直方图按作品版本采样。过期版本保存被拒绝。伪造来源作品即使指向同一份 JPEG，也无法打开该资源。 |
| 完整包还原 | 另外用一张真实 Sony RAW 的私有副本建立已纳入原件场景。缺少历史预览的迁入描述由测试构造。修改虚拟副本并隐藏之前的物理文件后，还原库从新的副本位置读取同一内容，获得相同的 410 × 278 像素结果。选择原件后替换其字节，解码会拒绝该来源。 |
| 实际宿主交互 | 在独立 AppKit 窗口挂载应用的作品卡，点击编辑按钮，调节曝光滑块并点击保存。重开后选中副本的曝光值与活动版本均已更新，主片配方和版本保持原值。还原库上也通过了同一条操作路径。 |

预览使用本机 Core Image 和 ImageIO。本次像素对照在同一系统进行。编辑器提供的曝光与裁切是 RAWMaster 本地配方。可迁移的历史 JPEG 保留来源已有的分辨率。[脱敏观测](evidence/lightroom-native-work-edit.json)

## 复跑

需要 macOS、Xcode 的 Swift 6 工具链、Python 3 和当前资料库动态库。`MIGRATED_CATALOG` 指向用同一版本产品迁入的目录，其中至少一对主片和虚拟副本各有已验证的历史预览。临时目录须与源库独立。脚本用在线快照建立私有目录，在私有目录增删测试作品和执行还原。传入的 RAW 也先复制到临时目录。[回归入口](../../Modules/LibraryCatalog/tests/work_edit_replay.py) · [版本与还原断言](../../Modules/LibraryCatalog/tests/CatalogWorkEditProbe.swift) · [宿主交互断言](../../Modules/LibraryCatalog/tests/CatalogWorkEditUIProbe.swift)

```sh
python3 Modules/LibraryCatalog/tests/work_edit_replay.py \
  --catalog "$MIGRATED_CATALOG" --runtime "$RUNTIME" --scratch "$SCRATCH" \
  --raw "$RAW_ORIGINAL" --host "$APP_CHECKOUT"
```
