# macOS App Sandbox 中的工作台交付

夹具以 ad-hoc 签名的后台应用启动内嵌 XPC 服务，服务开启 Hardened Runtime 和 App Sandbox。宿主和服务在激活连接前分别设置对方的 identifier 和 CDHash 要求，收到系统认证的 hello 回复后才发送当前请求的文件描述符及书签。服务使用编入自身签名的 P-256 公钥核验宿主 CDHash 授权文件。沙盒只为这一个测试策略文件申请了精确的只读临时例外。资料库、样片和交付目录的权限来自每次收到的能力。[签名及权限](bundle.py) · [宿主](host.m) · [XPC 服务](service.m)

## 本机复跑

需要 macOS、APFS、Xcode 命令行工具、Rust、Python 3.11+，以及本仓库已构建的 macOS 资料库 runtime。下面的 `X2` 指向已按上一级说明构建的夹具，须含 `system-keeper` 和 `instrumented-catalog`。首次启动时 macOS 会为生成的唯一 bundle identifier 建立测试容器。已授权的测试在工作区的输出目录创建一次性资料库和照片，未弹出系统文件选择面板。[X2 构建步骤](../README.md)

```sh
PROBE=experiments/portable-processing/catalog/macos-interop-probe/xpc
X2=output/035-development/phase-x/catalog/build
AA=output/035-development/phase-aa/catalog
mkdir -p "$AA"
python3 "$PROBE/core.py" --interop-build "$X2" --build-dir "$AA/build"
python3 "$PROBE/bundle.py" --build-dir "$AA/build/bundles" \
  --core-static "$AA/build/target/debug/librawmaster_library.a"
python3 "$PROBE/run.py" --interop-build "$X2" \
  --bundle-dir "$AA/build/bundles" --report "$AA/archive.json"
```

构建会生成新的临时签名授权密钥，完成签名后清理私钥。重建得到不同 CDHash 属于预期结果。服务和 Rust 核心静态链接在同一进程，独立的 Apple SQLite keeper 持有测试库。原始报告保存签名、进程号和每次 Rust 活事务的对象、权威与锁取值，过滤租约令牌和书签字节。[逐项断言](run.py) · [汇总结果](../../../../../specs/035-portable-processing-cores/evidence/catalog-macos-xpc.json)

## 如何读回执

- 相同 UID 和相同标识的第二个签名客户端在握手处失败。另一案让正确客户端配置一个不同的服务 CDHash。两个方向都先核对身份。另在真实 PREPARED 票据存在时发送错误客户端的合法发布意图，独立 keeper 仍读到原票据、原暂存及一个占位。
- 仅传只读照片 FD 时，服务可读取原 JPEG，写回该 FD 得到 EBADF，重新按文件名打开及访问同目录其他照片得到 EPERM。默认共享的临时书签在作用域内对指定照片可读写，停止访问后再次按路径打开得到 EPERM。因此仅需读取 RAW 原件的服务方法适合接收只读 FD。试验只打开可写文件描述符，未修改任何 JPEG。
- 本机首次在新启动的沙盒服务内解析刚发出的临时书签，会返回 stale。服务只在当前已签连接发送新鲜临时书签和原 FD 时，临时进入作用域并比对获准的父目录、原名、设备/inode、出生纳秒及 APFS 卷 UUID。随后按 Foundation API 重制书签，要求再次解析得到 fresh、原对象仍一致，再平衡两次作用域。无作用域对照、旧持久书签、同字节错文件及错 inode 的描述符都会在领取期间被拒。宿主保存的历史书签继续走原有过期处理。[Apple 的跨进程书签说明](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- 服务分别领取资料库和输出目录的作用域。默认发布路径调用真实 v10 逐件准备、排他发布及两次确认。缺少输出目录作用域时，已准备票据与原件继续可用。关闭当前请求的作用域后，服务重新按名称读取资料库会得到 EPERM。已交出的普通 FD 由接收者负责关闭。

当前桌面应用在宿主进程持有书签并调用 Swift/Rust。这个实验使用单独打包的上游 SQLite 3.53.2 FILESTAT 实验核心，真实系统 3.54.0 的 v10 runtime 与之共享夹具。上线仍需 Developer ID / 团队更新策略、由用户实际选取的持久书签、沙盒宿主自身取得资料库与输出目录的正常入口，以及外置卷、应用重启和用户授权撤回验收。[当前宿主](../../../../../Sources/RAWMaster/WorkbenchDeliveryAccess.swift) · [Apple XPC 签名要求](https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_code_signing_requirement%28_%3A_%3A%29)
