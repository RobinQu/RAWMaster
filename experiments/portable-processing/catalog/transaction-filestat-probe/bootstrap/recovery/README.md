# 从已提交、尚未 checkpoint 的 WAL 恢复导出

此实验让正在服务的主管进程收到 SIGKILL，用 pidfd 确认主管和 SQLite keeper 均已退出，再从服务私有的恢复记录启动另一组进程。新主管没有继承原资料库、WAL 或 SHM 的文件描述符。它继续使用上一实验的 `rm_library_request_v1`，真实执行工作台准备、独占发布和确认。[真实进程与逐案驱动](run.py) · [上一阶段的授权来源](../README.md)

## 主管记录什么

- 可信服务安装目录独立于可备份或复制的资料库。只有主管持有该目录中的独占锁和 HMAC 密钥。记录按序号和前一条 MAC 串联，每条通过临时写入、文件同步、原子改名和目录同步提交。新 worker 先在私有 socket 上等待。主管从内核收到它的凭证，核对 pidfd，将 boot ID、PID、启动时刻写入记录后才交付打开权限。主管重启时先核实上次全部已登记 worker 确已退出。[进程与授权](durable_owner.py) · [启动入口](launch.py)
- 主文件、WAL、SHM 和资料库目录以 `AT_HANDLE_FID | AT_HANDLE_MNT_ID_UNIQUE | AT_EMPTY_PATH` 从持有的 O_PATH 取得文件系统对象标识，连同角色和 Linux 启动身份记录。本机 overlayfs 为同一个对象返回了 44 字节的 type 248 标识。按名字、持有的描述符及改名后均一致，同字节副本的标识不同。普通可重开式句柄返回 EOPNOTSUPP。主数据库在整个试验中使用一个硬链接。[对象与记录实现](ledger.py) · [Linux 文件句柄接口](https://man7.org/linux/man-pages/man2/open_by_handle_at.2.html)
- 服务对外确认 PREPARED 或 DELIVERED 前，先记下当时已提交 WAL 前缀的 SHA-256、两份 salt、SQLite 的累积校验、最后提交帧和数据库页数，并绑定本次已承诺的清单及逐项票据摘要。重新启动先验证主文件的 checkpoint 版本和全部已承诺前缀，再让 SQLite 读取 WAL。未取得回复的后续合法提交可以保留。[WAL 校验与票据重读](ledger.py) · [SQLite WAL 格式](https://sqlite.org/fileformat.html#walformat)
- SHM 若仍在，需要匹配原对象；缺失则只允许从已经核实的主库和 WAL 创建新对象。keeper 在真实写事务中重新核对活描述符、32 KiB 共享映射、内核锁、两份 WAL 索引头及所有已承诺票据。主管收到一致结果后才准许有副作用的工作台操作。已发布且未收到 ACK 的文件沿原票据确认。[事务内库存查询](build.py) · [SQLite WAL 索引格式](https://sqlite.org/walformat.html)

## 复跑

在仓库根目录执行。第一次运行需要固定的 Linux 容器镜像及本地 Cargo registry 缓存。源码、registry 和仓库样片只读，SQLite 夹具全部在容器原生临时目录中生成。若已有上阶段的构建结果，可从第二条 Python 命令继续。

```sh
study_dir="$PWD/output/035-development/catalog-wal-recovery-replay"
study_image='rust@sha256:ade39a710ef85f3506cffcfec3e8a24ba090badef1dff2fb798f71d878833fea'
study_probe=/repo/experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap
mkdir -p "$study_dir"
run_linux() {
  docker run --rm --platform linux/arm64 --cpus=1 \
    --mount "type=bind,source=$PWD,target=/repo,readonly" \
    --mount "type=bind,source=${CARGO_HOME:-$HOME/.cargo}/registry,target=/usr/local/cargo/registry,readonly" \
    --mount "type=bind,source=$study_dir,target=/work" \
    -e PYTHONDONTWRITEBYTECODE=1 --workdir /tmp "$study_image" "$@"
}
run_linux python3 "$study_probe/build.py" --build-dir /work/build
run_linux python3 "$study_probe/recovery/build.py" --build-dir /work/build
run_linux python3 "$study_probe/recovery/run.py" --build-dir /work/build --output /work/receipt.json
```

归档运行通过 13 案。11 个场景最终交付 12 张 JPEG；另外两案分别保留了已丢失承诺帧及已承诺票据不符的现场。短写夹具让另一次真实 C ABI 注册遭遇内核文件长度限制，实际留下 801 字节的未完成帧，随后进程收到 SIGXFSZ。新主管仍恢复前一笔已经承诺的工作。已对外确认的帧被截去时，即便原 WAL inode 和已有 SQLite 提交仍然有效，服务也会保留现场。[构建、回执与逐案结果](../../../../../../specs/035-portable-processing-cores/evidence/catalog-wal-recovery.json)

## 可覆盖的服务条件

本候选覆盖同一次 Linux 启动、同一挂载、服务独占文件名管理和同一个 WAL checkpoint 代次。服务密钥及记录目录是独立的信任来源。整套恢复记录和密钥若一同回滚，需由另一个受信持久系统提供最新序号。这套实验的 C ABI 请求串行执行，记录 PREPARED 与 DELIVERED 对外确认前的状态。夹具对单个 WAL 检查最多 32 MiB，最多核对 16 张工作票据。生产接入需要协调 checkpoint 换代、并行写入、批量记录的检查成本和保留期限。掉电、主机重启、换卷、远程文件系统和 Apple 运行库需要单独验收。
