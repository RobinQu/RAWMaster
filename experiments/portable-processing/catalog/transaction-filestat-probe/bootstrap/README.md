# Linux 受控资料库首次创建 WAL 和 SHM

这套夹具运行原工作台 v10 注册、领项、准备、无覆盖发布和确认命令。受信主管从新建资料库的持有者接收主文件、目录及独立记录的 libraryID 和 writer。首次正常 SQLite 连接关闭后，夹具先验证该目录中的 WAL 和 SHM 均已消失。[逐案驱动](run.py)

专用 worker 为每个连接建立一个带 nonce 的私有 Unix socket，并将作用域绑定到调用线程。固定版本的 Unix 后端在真实主库或 WAL 打开点、SQLite 原生 SHM 打开点向主管请求对应角色。主管在已经固定的目录中排他创建新附件，保留见证，通过 `SCM_RIGHTS` 将创建所得描述符交给 SQLite。SQLite 打开已有角色时，主管从持有的文件对象提供新的打开文件描述。主管和执行 SQLite 的进程分开，主管收发和关闭描述符不会释放后者的进程级 POSIX 锁。现有条目、缺少权限、消息不完整和范围不符均会结束本次尝试。[Unix 后端接入](owner_io.inc) · [主管](broker.py) · [Unix 套接字描述符传递](https://man7.org/linux/man-pages/man7/unix.7.html)

keeper 在实际取得 `BEGIN IMMEDIATE` 后，向主管送回 `sqlite_filestat('main')` 提供的主库、WAL 和 SHM 活描述符。主管对三者逐个执行 `F_DUPFD_QUERY`，并用独立打开同 inode 的描述符校准。keeper 在实际第 0 页地址核对共享映射。主管分别在主库及 SHM 上用 `F_GETLK` 独立查询内核记录的读锁、写锁和持锁 PID。主管核对资料库标识、写入者、schema v10 和当前目录条目之后，才准许队列命令进入。读锁与写锁的槽位来自此次固定的 SQLite 构建。[keeper](owner-keeper.rs) · [Linux 打开文件描述核对](https://github.com/torvalds/linux/blob/v6.11/fs/fcntl.c#L311-L324)

发布和确认仍由 Rust 原有事务与票据处理。读、写及最终文件操作前都核对当前授权代次及实际附件。待确认的 JPEG 即使遇到连接中断，仍可按原票据核对。Linux 夹具还执行原有的硬链接发布和独占重命名两条路径。[队列事务](../README.md) · [活动映射见证](../mapping/README.md)

### 重放

在仓库根目录运行。构建只修改输出目录中的 Rust crate 和 SQLite 源码副本。已缓存的本地 Cargo registry 只读。实验在容器内部新建权限为 0700 的临时目录。两条命令采用同一个构建目录。

```sh
study_dir="$PWD/output/035-development/catalog-bootstrap-replay"
study_image='rust@sha256:ade39a710ef85f3506cffcfec3e8a24ba090badef1dff2fb798f71d878833fea'
study_source=/repo/experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap
mkdir -p "$study_dir"
docker run --rm --platform linux/arm64 --cpus=1 \
  --mount "type=bind,source=$PWD,target=/repo,readonly" \
  --mount "type=bind,source=${CARGO_HOME:-$HOME/.cargo}/registry,target=/usr/local/cargo/registry,readonly" \
  --mount "type=bind,source=$study_dir,target=/work" \
  -e PYTHONDONTWRITEBYTECODE=1 --workdir /tmp "$study_image" \
  python3 "$study_source/build.py" --build-dir /work/build
docker run --rm --platform linux/arm64 --cpus=1 \
  --mount "type=bind,source=$PWD,target=/repo,readonly" \
  --mount "type=bind,source=$study_dir,target=/work" \
  -e PYTHONDONTWRITEBYTECODE=1 --workdir /tmp "$study_image" \
  python3 "$study_source/run.py" --build-dir /work/build --output /work/receipt.json
```

### 恢复与适用范围

- 部分创建后，只有原主管仍持有创建所得 inode 才能继续。附加文件最初已存在、创建过程中被占位、条目与活映射不一致，均保留陌生文件。夹具恢复原条目或移除自己设置的障碍后，重复提交原操作。普通维护程序另行处理已有回滚日志及来源不明的 WAL。
- 主管在受控目录拥有独占的命名管理权。它等待旧 worker 的实际 pidfd 就绪及最后的 checkpoint，再删除经核对的附件并建立新代次。SQLite worker 的 WAL/SHM 自动删除在此专用作用域内受限。系统对任意可由外部进程改名的目录没有按 inode 条件删除的通用契约。原主库失联、权限变化或主管见证丢失时，保留目录内容供显式恢复。
- 某次冷启动若遇 writer 不匹配，主管已经在受权目录创建了自己的新附件，用于读取真实事务内的身份。随后会拒绝激活。有外部文件副作用的工作台操作从成功激活之后才可执行。主管退出后，即使新进程拿回原目录和原主文件描述符，也无法自动接管旧附件。进程死亡若发生在文件发布之后，仍须沿原票据核对最终文件与摘要。[主管退出夹具](owner_loss.py)
- 使用 Linux 单机私有服务目录、固定 SQLite 3.53.2、真实 Procfs 和内核接口。Apple 系统 SQLite、外部卷、多用户共享目录、主机断电和服务端吞吐需要单独验证。生产服务接入还要将测试中通过继承环境传递的私有作用域改为服务内部类型化的能力，并完成跨进程恢复与性能验收。[构建范围](build.py) · [验收记录](../../../../../specs/035-portable-processing-cores/evidence/catalog-attachment-bootstrap.json)
