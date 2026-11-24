# 资料库导出队列的 SQLite 附件验证

实验直接加载发布包的 Rust 资料库运行库，通过真实 C ABI 注册工作批、领取照片、准备文件、发布和确认。夹具从仓库旧版表结构开始，由生产接口升级至 v10。一张仓库 JPEG 提供待交付的真实字节。独立 keeper 连接直接读取 SQLite 票据和文件名预留。每次实验都在指定的构建目录生成并清理临时资料库。

在 macOS 仓库根目录运行以下命令。需要已构建的 release 资料库运行库和 Apple 命令行开发工具。

```sh
/usr/bin/python3 experiments/portable-processing/catalog/queue-transaction-probe/run.py \
  --build-dir output/035-development/catalog-queue-replay/build \
  --output output/035-development/catalog-queue-replay/receipt.json
```

`--runtime` 可指定另一份已封存的 `rawmaster-library.runtime`。`--only mapped-live` 可单跑一个场景。`--no-build` 复用指定目录内的工具。观测进程比对 Rust 与宿主 SQLite 的函数地址，报告不保存租约令牌。

系统 SQLite 3.54.0 上的九例均通过。非空 WAL 可通过真实 `JOURNAL_POINTER` 借用首字节映射，并与授权文件的 vnode 核对。空 WAL 的 `xFetch` 成功返回空指针。物理 1 字节干扰文件的原生 `xFileSize` 也返回 0，因此文件大小和当前名称不能单独证明打开了哪一份 WAL。交换同字节的 WAL 或 SHM 后，即使换回原名，活连接仍能观察到副本。拒绝时目标文件尚未创建，已准备票据保留。使用同一票据重试，最终 JPEG 的 SHA、字节数和重复确认后的状态一致。[逐案回执及原始摘要](../../../../specs/035-portable-processing-cores/evidence/catalog-queue-transaction-identity.json)

纯转发场景仅记录 SQLite 自身的文件打开、SHM 映射和锁。主动诊断场景会临时设置该 WAL 对象的 mmap 限额，随后归还借用并恢复限额。观测点是 Rust 自然读取资料库身份的查询已经返回一行时，读写状态来自同一条连接。诊断拒绝发生在写事务内的后续 SQLite 执行阶段。正式文件授权仍须在 Rust 原有独占链接和独占重命名的调用前分别核对。本实验覆盖本机 APFS、预先固定的测试附件和已编码的交付字节。
