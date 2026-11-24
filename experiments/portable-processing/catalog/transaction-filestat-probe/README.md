# 在真实工作台事务中核对 SQLite 文件

实验复制当前 `Modules/LibraryCatalog` 源码和锁定依赖，在复制的 Rust 队列中加入身份断言，并为随库 SQLite 3.53.2 启用上游 `SQLITE_ENABLE_FILESTAT`。每次操作都在独立子进程内加载该实验库，以相同的 `rm_library_request_v1` ABI 调用工作台。持有源授权的父进程和独立的票据查询进程各用自己的描述符。输入为临时 v10 目录和仓库 JPEG。[正式队列与发布逻辑](../../../../Modules/LibraryCatalog/src/scheduler/batch/items.rs) · [SQLite 文件控制契约](https://www.sqlite.org/c3ref/c_fcntl_begin_atomic_write.html)

在仓库根目录复跑十项实验。命令需要 Docker、已缓存 `Modules/LibraryCatalog/Cargo.lock` 对应的 Cargo registry，以及一个新的输出文件名。构建只占用一个 CPU，临时数据库位于容器原生文件系统。输出目录保存实验 crate、编译产物及原始回执。

```sh
study_dir="$PWD/output/035-development/catalog-filestat-replay"
study_image='rust@sha256:ade39a710ef85f3506cffcfec3e8a24ba090badef1dff2fb798f71d878833fea'
mkdir -p "$study_dir"
docker run --rm --platform linux/arm64 --cpus=1 \
  --mount "type=bind,source=$PWD,target=/repo,readonly" \
  --mount "type=bind,source=${CARGO_HOME:-$HOME/.cargo}/registry,target=/usr/local/cargo/registry,readonly" \
  --mount "type=bind,source=$study_dir,target=/work" \
  -e PYTHONDONTWRITEBYTECODE=1 --workdir /tmp "$study_image" \
  python3 /repo/experiments/portable-processing/catalog/transaction-filestat-probe/run.py \
  --build-dir /work --out /work/receipt.json --image-digest "$study_image"
```

`--case empty-decoys-link` 单跑空 WAL 场景。工作台照常注册、领取、准备、发布并两次确认。读、写状态从当前连接的 `sqlite3_txn_state` 取得。`sqlite_filestat('main')` 读取同一连接 Pager 持有的主文件、日志和 SHM 描述符。检查借用这些描述符进行 `fstat`，逐个匹配预先持有的 `O_PATH` 授权与授权父目录中的当前条目。SHM 还要符合本连接的读写锁位，进程中有唯一对应设备号和 inode、偏移为零的共享映射。回执只记录观测状态及身份，不保存父子租约令牌。[检查实现](guard.rs) · [SQLite 事务状态](https://sqlite.org/c3ref/txn_state.html)

七个拒绝场景分别覆盖逐份同字节副本、打开整套其他 v10 目录、准备前、首次硬链接前、备用重命名前及 ACK 记账前。在指定子进程中，内核只向 `linkat` 返回 `EPERM` 以触发备用分支，随后真正执行 `renameat2(RENAME_NOREPLACE)`。可据阶段记录、空目标、原票据、暂存 inode、文件摘要及再次确认的结果复核。夹具只针对 Linux arm64。[十案驱动](run.py) · [归档回执](../../../../specs/035-portable-processing-cores/evidence/catalog-transaction-filestat.json)

生产接入需解决两项授权来源。其一是从本机授权的原主文件建立受控连接，获得每一代 WAL/SHM 的见证，容纳合法检查点和附件重建。其二是 macOS 的安全书签与 SQLite 互操作，已测系统构建缺少 FILESTAT 诊断。实验中的单连接进程、Linux 内核映射表与上游诊断 JSON 均是本次验证条件。生产实现还需选择稳定的私有接口，明确检查点和文件名变动时的恢复策略。[接入边界](../../../../specs/035-portable-processing-cores/catalog-queue.md)
