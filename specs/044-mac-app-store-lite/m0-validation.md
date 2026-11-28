# 044 M0 · 本地渠道包与沙盒 RAW

从欢迎页或资料库菜单选择「新建资料库…」。在系统目录选取器中选定保存目录，填写名称后选择「创建并打开」。新包以 `.rawmasterlibrary` 保存在所选目录，可随后导入原片。迁移旧库以及通过打开备份包发起恢复也使用这个选址方式。无写权限或名称冲突时保留原库与选址草稿，换目录或改名后继续。取消回到原来的开始页或资料库。[工作台原型](../../docs/ui/prototype/index.html#welcome) · [现有库包流程](../042-local-library-workbench/spec.md#2-首次打开与资料库菜单)

系统保存面板的临时授权已在 ad-hoc 的 App Sandbox 探针中复现。选中尚不存在的库包路径后可创建该路径，同级的临时目录以 `NSCocoaErrorDomain` 513 拒绝。在获得父目录的写授权后才能复用现有的同目录暂存、排他重命名和同步事务。[Apple 沙盒文件授权](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

按工作台的现有新建入口走查，取消一次后复验焦点。以 `relative` 触发无效路径，再尝试 `/Volumes/只读照片盘`，确认保留库名并提示重新选择。改选 `/Volumes/照片盘`，确认生成同名新包并进入空库。可按原菜单打开原库。签名后的原生验收使用系统选取器、真实可写及未授权的外部目录执行对应动作。

M0 冻结样片为 PIXLS.US 条目 2414 的 Sony ILCE-7M3 14-bit 压缩 ARW。已下载并复核 `25,639,680` 字节、正向 `6000 × 4000`、SHA-256 `250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f`，制品授权为 CC0 1.0。[上游样片](https://raw.pixls.us/getfile.php/2414/nice/Sony%20-%20ILCE-7M3%20-%2014bit%2014bit%20compressed%20%283%3A2%29.ARW) · [上游样片清单](https://raw.pixls.us/json/getrepository.php) · [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)

## 本地渠道构建

同一个 `build-app.sh` 从 SwiftPM 与锁定的 Rust 依赖生成 Release。两条本地渠道共用编译设置，各自从新目录封装，以独立 Bundle ID 保存最近库和书签。`personal` 仍用 `io.robinqu.RAWMaster`，打开同一旧库时按所用签名身份重新授权。

```sh
RAWMASTER_BUILD_VERSION=1.0.1 RAWMASTER_DISTRIBUTION_OUTPUT="$PWD/output/m0/store-1" \
  scripts/build-app.sh release app-store-local
RAWMASTER_BUILD_VERSION=1.0.1 RAWMASTER_DISTRIBUTION_OUTPUT="$PWD/output/m0/website-1" \
  scripts/build-app.sh release website-local
```

组包先签 `Contents/Frameworks` 的 FlashRaw、图像引擎、资料库和 PhotoExport，再签主应用。签名权限为 App Sandbox、用户选取读写和应用范围书签。组包核验 Mach-O 架构、系统下限、install name、依赖和 rpath，并输出 `app-manifest.json`。官网渠道另产出安装到 `/Applications` 的独立验证 `.pkg` 和载荷摘要。四个图像与资料库运行库保留在固定包内位置。既有滤镜、降噪和 2× 成像资产随同验证，外部模型服务、脚本和组包归档不进入该构建。[构建入口](../../scripts/build-app.sh) · [本地组包审计](../../scripts/distribution/verify-local-app.py)
