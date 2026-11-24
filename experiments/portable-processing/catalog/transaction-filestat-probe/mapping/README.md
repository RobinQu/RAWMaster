# 工作台发布事务中的 SHM 映射

实验为 Rust 队列连接指定一个具名 VFS。SQLite 自己映射 SHM 第 0 页时，VFS 保存这次打开、映射、地址和长度。关闭主库或解除映射时，原见证失效。普通文件操作及锁协议转发给随库的 Unix VFS。已有 v10 夹具继续通过相同的 `rm_library_request_v1` 入口准备文件、执行无覆盖发布和确认。[VFS 实现](witness-vfs.c) · [上游 SQLite I/O 合约](https://sqlite.org/c3ref/io_methods.html)

| 测量方式 | 活事务中的映射检查 |
| --- | --- |
| `scan` | 每次按完整 `/proc/self/maps` 文本核对 SQLite 实际返回的地址、范围、权限、文件偏移、设备和 inode。 |
| `address` | 带入实际页地址做一次 104 字节 `PROCMAP_QUERY`。该查询由 Linux 6.11 起提供。 |
| `cached` | 在读事务中完整核对一次，后续写事务要求同一连接的打开代次、映射代次、原指针、长度和文件身份完全一致。 |

三种方式在每道边界都重新核对主文件、WAL、SHM 的实际描述符、本连接的锁位，以及授权目录中的当前条目。`auto` 仅在读事务发现内核缺少接口时选择同代复核。身份不符或写事务内的错误会使操作失败。试验中的证书只存在于单连接执行者的本次调用中。[身份检查](bounded.rs) · [Linux 映射查询](https://docs.kernel.org/filesystems/proc.html)

在仓库根目录执行以下命令。需要 Docker 和已缓存的 Cargo registry。源码和样片只读，测量使用容器内临时目录。`--rounds 6` 会在每组一次预热后按六种顺序运行。省略该参数可只做正确性复验。

```sh
study_dir="$PWD/output/035-development/catalog-mapping-replay"
study_image='rust@sha256:ade39a710ef85f3506cffcfec3e8a24ba090badef1dff2fb798f71d878833fea'
mkdir -p "$study_dir"
docker run --rm --platform linux/arm64 --cpus=1 \
  --mount "type=bind,source=$PWD,target=/repo,readonly" \
  --mount "type=bind,source=${CARGO_HOME:-$HOME/.cargo}/registry,target=/usr/local/cargo/registry,readonly" \
  --mount "type=bind,source=$study_dir,target=/work" \
  -e PYTHONDONTWRITEBYTECODE=1 --workdir /tmp "$study_image" \
  python3 /repo/experiments/portable-processing/catalog/transaction-filestat-probe/mapping/run.py \
  --build-dir /work --output /work/receipt.json --rounds 6
```

正确性用例复用十案发布夹具。换代用例关闭最后一条 SQLite 连接，由 SQLite 删除空 WAL 和 SHM，再打开同一主库生成新附件。旧授权应在读事务内被拒绝，原票据、暂存文件和空目标名保留。随后给这组生成的夹具明确授权，再执行原任务。两次 ACK 经过同一子进程内依次打开的两条队列连接。计时从成功获得 `BEGIN IMMEDIATE` 之后开始，到提交返回为止，诊断输出留到事务结束后。每组分别报告真实发布、首次持久化 ACK 和重复 ACK 的 P50 与 P95。[逐动作计时](timing.py) · [换代验证](epoch.py) · [验收回执](../../../../../specs/035-portable-processing-cores/evidence/catalog-transaction-mapping.json)
