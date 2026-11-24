# 在本机 APFS 建立工作台资料库的第一代附件

这个实验从一份实际升至 v10 的本地资料库开始。主管持有该目录和主库的原始文件描述符。私有 SQLite 首次需要 WAL、SHM 时，主管在原目录排他创建它们，把创建所得的描述符交给 SQLite，并核对 SQLite 在写事务中实际使用的三个描述符。工作台继续通过上一实验的 Rust C ABI 执行准备、发布和确认。[两套引擎的互操作夹具](../README.md) · [正式工作台逐项流程](../../../../../Modules/LibraryCatalog/src/scheduler/batch/items.rs)

## 复现

在 macOS 仓库根目录运行。需要本机 APFS、Xcode、Python、已缓存的锁定 Cargo 依赖及已构建的 release 资料库运行库。若已有上一实验的构建目录，可复用其中的 Rust 工作台程序和 Apple 锁观察器。所有数据库、候选二进制和回执都生成在指定的输出目录。

```sh
probe=experiments/portable-processing/catalog/macos-interop-probe
interop=output/035-development/phase-x/catalog/build
study=output/035-development/phase-y/catalog
python3 "$probe/build.py" --build-dir "$interop"
python3 "$probe/bootstrap/build.py" --build-dir "$study/build"
python3 "$probe/bootstrap/run.py" --build-dir "$study/build" \
  --interop-build "$interop" --output "$study/replay.json"
```

`--runtime` 可指定封存的 `rawmaster-library.runtime`。`--case old-live-reader` 可单跑读者跨越票据提交的场景。完整运行另有四个系统默认关闭对照。

## 授权与换代

- **明确初始状态。** 系统 SQLite 3.54.0 的创建者用正式运行库完成迁移。其本机默认 `PERSIST_WAL` 为 1。四种正常最后关闭条件均留下零字节 WAL 和 32,768 字节 SHM。要构造两份附件均从缺失开始的夹具，原创建者确认 TRUNCATE 将帧数清零，再将自己的 `SQLITE_FCNTL_PERSIST_WAL` 从 1 设为 0 并复核。SQLite 正常关闭后，主管确认两份附件均已消失。这次显式设置只用于夹具原创建者。[构建及原创建者设置](build.py)
- **确认真实的打开文件。** 通过固定版本 SQLite Unix 后端的主库、WAL 和 SHM 打开点向主管请求相应角色。打开主库时须匹配原文件。创建附件时使用固定目录内的 `openat(O_CREAT | O_EXCL | O_NOFOLLOW)`。双方通过仅供该子进程使用的 Unix datagram socket 和每次启动的随机数传递 `SCM_RIGHTS`。Darwin 在该环境支持这种套接字，`SOCK_SEQPACKET` 返回 `EPROTONOSUPPORT`。各条 SQLite 连接分别打开受权文件。主管保留自己交出描述符的副本，另起进程观察锁。[主管与收发协议](supervisor.py) · [所复用的角色协议](../../transaction-filestat-probe/bootstrap/owner_io.inc)
- **验证真正使用的附件。** 单线程 keeper 在真实 `BEGIN IMMEDIATE` 中把 FILESTAT 的三个活描述符送回主管，然后暂停。主管依次改变已交出描述符的当前偏移，再从返还的描述符读出，反向也相同。另行打开同一 inode 的偏移保持原值。每次立即还原全部偏移并确认文件长度。第三个进程检查主库和 SHM 的真实读写锁，父进程归还接收的描述符副本后再查一次。主管只读映射已获授权的原 SHM，keeper 验证自身自然取得的 32,768 字节映射、内核 vnode、卷与原目录。完整九案的 18 次激活中，实际 WAL 都为零字节。[keeper](keeper.c) · [实际锁和文件回执](../../../../../specs/035-portable-processing-cores/evidence/catalog-macos-bootstrap.json)
- **保留原票据。** 合法换代需要全部登记的工作台请求和 Apple 读者退出，TRUNCATE 成功，日志帧数、已写回帧数及 WAL 字节数均为零，并从原连接再读同一张已准备票据。keeper 实际退出后，主管只移除自己持有且仍与原目录条目匹配的两个附件。测试保留旧授权描述符，确认链接数为零。在两份附件仍缺失时，独立 Apple 进程以 immutable 方式从单独的主库读出原票据。新代重建后，旧授权对真实工作台请求返回拒绝，新授权能交付原暂存 inode，并连续两次得到相同的确认。[场景与断言](run.py)

原目录从创建起只由测试主管管理。未知空附件、部分创建后出现同名陌生文件、同字节异 inode、仍活着的旧读者均会阻止对应操作。有旧快照时，SQLite 实际只将 7 帧中的 4 帧写回并返回 BUSY。另一例虽已没有脏页，仍活着的 Apple 读者也会阻止主管退休该代。[逐案结果](../../../../../specs/035-portable-processing-cores/evidence/catalog-macos-bootstrap.json)

现有应用和系统 SQLite 均保持原配置。主管异常退出、退休途中发生 I/O 故障、热 WAL、断电、外部可写目录、卷重挂、App Sandbox 与安全书签传递都需要独立恢复和授权设计。偏移挑战要求所有使用该打开文件描述的线程都停在握手点，仅用于这套专用的可复核夹具。本实验未测量吞吐。[生产接入边界](../../../../../specs/035-portable-processing-cores/catalog-queue.md)
