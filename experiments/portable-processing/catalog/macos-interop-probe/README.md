# macOS 两套 SQLite 共用工作台资料库

这组实验使用本机 APFS 的临时资料库，分别验证 Apple 系统 SQLite 与带 FILESTAT 的 SQLite 3.53.2 能否共享同一份 v10 工作台票据，以及第二套引擎能否在文件发布前核对实际使用的主库、WAL 和 SHM。

在仓库根目录运行。需要 Xcode 命令行工具、Rust、Python 3、已缓存的 Cargo 锁定依赖，以及已构建的 macOS release 资料库运行库。`--runtime` 可指定已封存的运行库。构建及测量产物写入指定的输出目录，临时资料库在每轮结束后清理。

```sh
probe=experiments/portable-processing/catalog/macos-interop-probe
study=output/035-development/phase-x/catalog
python3 "$probe/build.py" --build-dir "$study/build"
python3 "$probe/run.py" --build-dir "$study/build" --output "$study/replay.json"
```

系统进程通过正式发布包的迁移接口把旧夹具升级为 v10。独立实验进程静态链接复制的生产 Rust 资料库代码和 `libsqlite3-sys 0.38.2` 锁定的上游 SQLite，启用 `SQLITE_ENABLE_FILESTAT`。注册、领取、准备、发布和确认都经过 `rm_library_request_v1`。两个进程各自核对 Rust 运行库和 C 侧 SQLite 的版本函数地址，并记录 `dladdr` 返回的镜像。正式应用仍使用系统 SQLite。[构建入口](build.py) · [所用生产逐项交付流程](../../../../Modules/LibraryCatalog/src/scheduler/batch/items.rs)

## 可独立核对的结果

- 两个进程轮流持有 `BEGIN IMMEDIATE`。另一引擎的第二位写入者收到 `SQLITE_BUSY`，首位释放后可以写入。同一读事务跨越对方提交，分别保留原值 0 和 1。释放快照后分别读到 1 和 2。第三进程用自己的 `F_GETLK`、`F_OFD_GETLK` 查询对照主库与 SHM 的实际锁主。单跑这一组可加 `--only-locks`。[锁测量](system-peer.c) · [场景断言](run.py)
- 私有引擎从已活跃的同一连接取得实际描述符和 SHM 锁位。具名 VFS 转发 SQLite 正常的 `xShmMap`，内核按那次映射的地址返回 vnode、范围、偏移和共享状态。每个文件核对 APFS 卷 UUID、设备号、inode、纳秒出生时间、类型，以及原授权目录下的当前条目。写事务同时核对实际访问权限。整个身份检查借用 SQLite 已打开的描述符，不打开、复制或关闭主库数据描述符。[实际文件身份](mac-proof.c) · [事务检查](proof.rs)
- 同一私有写事务只有一个映射进程时，内核报告 `SM_PRIVATE`。父进程只读映射同字节副本时结果相同。父进程只读映射预持的原 SHM 后，内核报告 `SM_SHARED`，解除映射后又回到 `SM_PRIVATE`。独立 Apple SQLite 读者映射原件时也得到 `SM_SHARED`。候选仅接受通过内核共享状态和原 vnode 双重核对的情况。九个文件交付场景使用真实 Apple keeper。[五态数值与运行摘要](../../../../specs/035-portable-processing-cores/evidence/catalog-macos-interop.json)
- 交付使用仓库 JPEG。正常路径在 APFS 上执行独占硬链接。备用路径在夹具中令第一次硬链接返回 `EPERM`，随后执行原有的 `renameatx_np(RENAME_EXCL)`。故障夹具仅在协作进程已取得写事务时暂换一个测试文件名，并在 SQLite 离开该检查点前恢复原件。独立进程查看原锁与副本的锁，系统 keeper 查看逐项票据与预留。每例最后核对原暂存 inode、输出摘要、两次相同的 ACK、释放占位和独立 SQLite 完整性检查。[逐案回执和适用范围](../../../../specs/035-portable-processing-cores/evidence/catalog-macos-interop.json)

测试主管在 SQLite 创建附件后固定私有目录、主库、WAL 和 SHM，并在整次交付中保留这些描述符。外部可写目录里，SQLite 写锁本身无法阻止另一进程在最终检查后重命名条目。实际客户端接入还需验证沙箱子进程、跨进程安全书签、首次创建与合法换代时的授权、卷重挂、断电及主管异常退出后的恢复。系统运行库未提供此处使用的 FILESTAT SQL 接口。实际队列开销及通用文件系统支持需单独测量。[生产接入条件](../../../../specs/035-portable-processing-cores/catalog-queue.md)
