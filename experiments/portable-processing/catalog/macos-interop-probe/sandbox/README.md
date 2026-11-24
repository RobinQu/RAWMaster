# 已签命令行助手在 macOS 文件沙箱内处理真实工作台票据

主管在私有 APFS 目录中启动单独的签名进程。它先核对待启动程序的代码要求，再通过 Unix socket 的内核 audit token 核对正在连接的进程。通过后，主管才发送四个只读描述符和本次工作台命令。实际运行的 Rust C ABI、上游 SQLite 3.53.2 及文件交付逻辑均静态链接在该 helper 内。Apple 系统 SQLite 独立创建 v10 夹具并复核票据。

## 复现

在有 Xcode、本机 APFS、已缓存 Cargo 依赖及 release 资料库运行库的 macOS 机器上，从仓库根目录执行。已有 X2、Y2 构建可以复用。所有临时数据库、签名程序、策略文件和测试产物写入明确指定的输出目录。

```sh
probe=experiments/portable-processing/catalog/macos-interop-probe
interop=output/035-development/phase-x/catalog/build
bootstrap=output/035-development/phase-y/catalog/build
study=output/035-development/phase-z/catalog
python3 "$probe/build.py" --build-dir "$interop"
python3 "$probe/bootstrap/build.py" --build-dir "$bootstrap"
python3 "$probe/sandbox/build.py" --build-dir "$study/build" --interop-build "$interop"
python3 "$probe/sandbox/run.py" --build-dir "$study/build" --interop-build "$interop" \
  --bootstrap-build "$bootstrap" --output "$study/replay.json"
```

`--case permissions` 检查部署身份及文件权限。`--case refused-delivery` 测目标只读时的恢复。`--case refused-attachment-metadata` 复现缺少卷元数据权限的拒绝。`--case signed-cold-recreation` 测合法首次创建、退休和新代。完整运行还包括无故障交付。

## 什么在授权

- 程序用 ad-hoc 签名及 Hardened Runtime 构建。主管先用固定 identifier 与 CDHash 检查磁盘程序，只有匹配者才进入带资料库路径权限的策略。启动后，主管从已连接的 socket 读取 `LOCAL_PEERTOKEN` 与 `LOCAL_PEERPID`，用 `SecCodeCopyGuestWithAttributes` 定位该运行进程，再用相同要求调用 `SecCodeCheckValidity`。内核 PID、有效 UID、动态签名及签名信息都要符合预期。另一个特意使用相同 identifier 的有效签名程序会被拒绝。它也无法直接读取夹具的主库。[签名和构建](build.py) · [动态身份验证](verify.c)
- 测试用系统的 `sandbox-exec` 执行 deny-default Seatbelt 策略。它为当前 helper 提供必要的系统加载权限、指定 Unix socket，以及本次授予的路径。写资料库只允许三个具体名称，写文件只允许已选择的交付目录。在同目录未获授权的样件上，读取、以读写方式打开、创建文件和改名均返回 EPERM，另一个目录内的样件也不可读。相同 UID、相同签名 helper 的未加 Seatbelt 对照在同一组生成文件上五项均成功。[权限策略和主管](broker.py) · [系统调用对照](transport.c)
- 只读目录 FD 仍可以作为 `openat` 的基准。主管因此还要限制目录下允许访问的具体对象。Y2 的主管保留可写 WAL/SHM 描述符以见证其创建，转给只读 helper 时必须从原目录重新只读打开，且在原 FD 仍持有 inode 时核对身份。四个角色均检查收到的文件类型及 `O_ACCMODE`。实际 SQLite 事务仍另行核对原对象、卷 UUID、出生时刻、锁和共享映射。[接收与调用](entry.rs) · [原始 APFS 事务判定](../proof.rs)
- 实测 `fgetattrlist(ATTR_VOL_UUID)` 还需要实际 APFS 挂载根的 `file-read-metadata`。只授权资料库目录及三个文件时，领取照片会在受权目录 FD 上得到 EPERM，逐项表行数保持零。加入仅针对该挂载根的元数据权限后，正常请求成功。父目录及卷内其他文件没有获得递归写权限。[真实错误、卷及签名摘要](../../../../../specs/035-portable-processing-cores/evidence/catalog-macos-signed-helper.json)

目标只读时，真实硬链接和独占重命名均被拒绝。独立 SQLite 连接仍读到原已准备票据，暂存文件的 inode、摘要及占位不变。重新按原目标授予写权限后，Rust 用同一张票据交付原件，并两次得到相同 ACK。另一个场景在签名核对完成、待处理进程尚在仅限身份验证的策略内时，主管完成原附件 checkpoint 和退休。在发送描述符前重新读取代次，旧请求收到零个描述符和零条队列命令。新代激活后，仍引用旧代的请求同样没有获权。已发放的普通描述符由接收者持有，关闭通信通道不提供追溯撤销。[完整断言](run.py) · [归档逐案结果](../../../../../specs/035-portable-processing-cores/evidence/catalog-macos-signed-helper.json)

## 与桌面应用的边界

目前桌面工作台在宿主进程内保存绑定资料库身份的书签，重开时核对书签是否过期。对于已标记为安全作用域的书签，宿主还要求重新进入该作用域。发布脚本为应用和已有组渲染工具做 ad-hoc 签名。这个 PoC 验证了独立签名进程和真实内核文件限制。它使用已弃用的 `sandbox-exec`，其策略不直接充当产品的 App Sandbox 权益。Apple 的 App Sandbox 在首次运行时会于用户的 `~/Library/Containers` 建立容器。本实验限定在工作区生成的夹具内。仍需另行验收 Developer ID 或团队签名更新、真实 Powerbox 选取及书签跨进程交接、launchd/XPC、App Sandbox、热 WAL 恢复和外置卷重挂。[现有宿主授权](../../../../../Sources/RAWMaster/WorkbenchDeliveryAccess.swift) · [Apple 的 App Sandbox 文件授权](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) · [Apple 的 XPC 服务说明](https://developer.apple.com/documentation/xpc)
