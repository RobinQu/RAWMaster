# 资料库数据库选型：DuckDB 与 SQLite 实测（2026-11-26）

## 结论

**继续用 SQLite 作为资料库的权威存储，不整体迁移 DuckDB。**

DuckDB 的优势是真实存在的，但集中在**全库分析型聚合**：100 万文档时全库评分/相机/标签 facets 为 10.6–19.3 ms，SQLite 为 0.92–1.04 s；1 万行批量更新 0.7 ms 对 9.0 ms。它的弱点是**点查、增量写入、冷启动和多进程**：1000 次按 asset 点查 679 ms 对 7.6 ms，5000 行增量导入 693 ms 对 105 ms，100 万行导入 141 s 对 14.7 s，冷启动 15.2 ms 对 1.8 ms，且第二个进程连只读都打不开。

当前资料库首屏请求的是分页查询，**没有请求 facets**；分页本身在 100 万文档下也只有 2.4–7.5 ms（取决于排序）。真正拖慢首屏的是**缺失的索引和 2 MiB 的默认页缓存**，不是引擎：

| 100 万文档，同一查询 | 现状 | 加索引/缓存后 | DuckDB |
| --- | ---: | ---: | ---: |
| 全库按拍摄时间倒序首页 | 37.1 ms | **0.02 ms**（`docs_time`） | 6.2 ms |
| 项目内按拍摄时间升序首页 | 7.6 ms | **0.04 ms**（`docs_project_time`） | 1.1 ms |
| 文件名前缀 | 150.5 ms | **0.02 ms**（`docs_name`） | 1.1 ms |
| 默认“拍摄顺序”首页 | 21.9 ms（2 MiB 缓存） | **7.5 ms**（256 MiB 缓存） | 2.4 ms |

如果未来要做“任意筛选 + 全库 facets”的百万级浏览器，再考虑**只读 DuckDB sidecar**：SQLite 仍是权威库，DuckDB 只做从 SQLite 重建的派生分析副本。不要双写，不要让 UI 进程以读写方式打开 DuckDB。

## Alcedo 为什么用 DuckDB

AlcedoStudio 的用法（`output/research/perf-refs/alcedo`）：

- 每个项目一个 `.alcd` 包，内嵌一个 DuckDB 文件；
- `Database` 持有一个 `duckdb_database` 和一把全局 `recursive_mutex`，每次取连接都加锁，进程内所有数据库访问串行化；
- 写入按 ≤256 行一条多行 INSERT 摊薄；
- 文件名/EXIF 搜索用 DuckDB FTS（`PRAGMA create_fts_index`）；
- README 写的是 “embedded DuckDB engine for sub-millisecond filtering across massive libraries”。

这个选择对 Alcedo 是合理的：项目包是“导入一次、之后读多写少”的分析型目录，UI 一次只发一个查询，单进程桌面应用，没有每张照片的持久化收据，也没有导出调度器。它的搜索基准测试实际用的是 2 万文件（`library_search_benchmark_test.cpp` 的 `kFileCount = 20000`），不是百万级；“sub-millisecond”指的是搜索 WHERE 的构建和缓存命中，不是任意百万行分页。

RAWMaster 的目录形状不同：`documents` 是派生投影，但旁边还有 `assets`、`operations`、`scheduler`、交付回执；导入/导出/编辑三条 lane 共享一个库；导出每张都要提交回执；测试和工具可能另开进程。这些差异决定了不能直接照搬。

## 测试方法

基准脚本：[`catalog-database-bench.py`](catalog-database-bench.py)；完整中位数与 p95：[`evidence/catalog-database/results.json`](evidence/catalog-database/results.json)。

- schema 直接取自 `Modules/LibraryCatalog/src/query/schema.sql`（`documents` 30 列、`doc_tags`、真实索引）；
- 查询形状取自 `query/read.rs`：项目/全库分页、keyset 排序、评分/相机/标签 facets、标签页、文件名前缀、60 行 hydrate、按 asset 点查、点更新、批量更新、增量插入/删除；
- 规模 2 万 / 20 万 / 100 万文档，每文档 3 个标签（100 万时 300 万标签行），`record` JSON 约 0.9 KB；
- 两个引擎在同一个 Python 进程里跑，同样的多行 INSERT、同样一个事务导入；
- SQLite 给 256 MiB 页缓存（现状是 2 MiB），DuckDB 8 线程 / 4 GiB；
- SQLite 先按**现有索引**测，再加 `(gen,time_desc)` 和 `(gen,project_id,time_asc)` 两个覆盖索引测，用来区分“引擎慢”和“缺索引”；
- 写测试和多进程测试都在数据库副本上跑，避免前面的阶段污染后面的结果；
- 机器：macOS 27.0.1 arm64，16 CPU；DuckDB 2.0.1；SQLite 3.53.4。

## 结果

### 导入、体积、冷启动

| | 2 万 | 20 万 | 100 万 |
| --- | ---: | ---: | ---: |
| SQLite 导入 | 0.26 s | 2.71 s | **14.65 s** |
| DuckDB 导入 | 2.78 s | 27.66 s | 140.91 s |
| SQLite 文件 | 18.1 MB | 181.9 MB | 911.1 MB |
| DuckDB 文件 | 13.1 MB | 110.4 MB | **545.8 MB** |
| SQLite 冷启动+首页 | 1.90 ms | 1.68 ms | **1.81 ms** |
| DuckDB 冷启动+首页 | 10.35 ms | 15.59 ms | 15.23 ms |

DuckDB 的列式压缩确实更好（100 万时小 40%），但导入慢 9.6 倍，冷启动慢 8 倍。导入是投影重建的关键路径；141 s 对 15 s 是用户能感知的差异。

### 读：100 万文档（中位数，ms）

| 查询 | SQLite 现有索引 | SQLite + 两个索引 | DuckDB |
| --- | ---: | ---: | ---: |
| 全库按拍摄时间倒序首页 | 37.11 | **0.02** | 6.24 |
| 项目 + 评分 + 拍摄时间升序首页 | 7.60 | **0.04** | 1.13 |
| 项目评分 facet | 11.93 | 13.49 | **1.78** |
| 项目相机 facet | 14.02 | 13.12 | **2.40** |
| 全库评分 facet | 916.8 | 925.9 | **10.6** |
| 全库相机 facet | 1039.0 | 1052.2 | **15.5** |
| 全库标签 facet | 965.0 | 944.5 | **19.3** |
| 标签页（两个标签，60 行） | 16.71 | 16.17 | **5.34** |
| 文件名前缀 | 150.5 | 151.5（未加 name 索引） | **1.15** |
| 60 行按 doc hydrate | **0.03** | 0.03 | 0.55 |
| 1000 次按 asset 点查 | **7.58** | 8.11 | 679.2 |

补充的定向测量（100 万，独立于上表）：

- 文件名前缀加 `documents(gen,name_key)` 后：150.5 → **0.02 ms**；
- 默认“拍摄顺序”首页：SQLite 256 MiB 缓存 **7.54 ms**，2 MiB 缓存 21.92 ms，DuckDB 2.40 ms；
- 同样的默认首页带评分过滤的精确计数：SQLite 8.66 ms，DuckDB 1.93 ms（结果按查询指纹缓存，只在筛选变化时算一次）。

读的结论分三层：

1. **分页不是 DuckDB 的优势**。只要 SQLite 有匹配排序的索引，分页是 0.02–0.04 ms，比 DuckDB 快 30–270 倍。现有 schema 缺的是 `(gen,time_desc)`、`(gen,project_id,time_asc/desc)`、`(gen,name_key)` 这几条索引。
2. **默认“拍摄顺序”排序 SQLite 会退化**（100 万时 7.5–21.9 ms），因为它要排序项目子集；DuckDB 的 Top-N 是 2.4 ms。7.5 ms 仍在 UI 一帧内，不是必须换引擎的理由；如果以后要压到亚毫秒，需要一条覆盖 `session_ord` 等排序键、并带 `rm_natural` collation 的索引，成本较高。
3. **全库 facets 是 DuckDB 唯一决定性的读优势**（50–90 倍）。但当前 `AppModel.submitCatalogPage` 构造的 `CatalogGridRequest` 没有传 `facets`，所以这条路径还没被 UI 使用。等 facets 真的上首屏，再用汇总表或 sidecar 解决，不必现在就为它换库。

### 写：100 万文档（中位数，ms）

| 操作 | SQLite FULL | SQLite NORMAL | DuckDB |
| --- | ---: | ---: | ---: |
| 200 次单行更新（每次自动提交） | **14.6** | 18.6 | 31.9 |
| 1 万行评分批量更新 | 9.0 | 13.5 | **0.7** |
| 5000 文档 + 1.5 万标签增量插入 | **105.3** | 96.9 | 693.2 |
| 5000 文档删除 | 43.8 | 38.6 | **14.7** |
| checkpoint | **0.4** | 0.1 | 4.5 |
| 单行提交（默认 fsync） | **0.041** | 0.011 | 0.105 |
| 单行提交（`F_FULLFSYNC`） | 4.625 | — | 5.134 |

DuckDB 的增量插入成本约 **139 µs/行**，在 2 万、20 万、100 万三个规模几乎不变（693–702 ms / 5000 行），说明它是每行的索引/WAL 固定成本，不是表变大导致的。批量更新是 DuckDB 的强项（列式重写），但资料库的常见写入是单张评分/标记/回执，不是一次改 1 万行。

### 并发与多进程

- 4 个线程各做 50 次不相交的单行更新：SQLite 56.4 ms，DuckDB 23.4 ms，均无错误。DuckDB 在一个进程内可以并发写不相交的行。
- 第二个进程：SQLite 读写和只读都成功；DuckDB 在第一个进程以读写方式打开时，**读写和只读都失败**（`Conflicting lock is held`）。
- 如果所有进程都以只读方式打开，DuckDB 允许多进程并发读（单独验证过）。所以“只读分析 sidecar”可行，但重建时必须换新文件再原子替换。

## 解释

- **存储模型**：SQLite 是行式 B-tree，点查/小页/单行更新是主路径；DuckDB 是列式 + 向量化 + 并行扫描，适合大范围聚合，但二级索引不参与普通点查。实测 `EXPLAIN ANALYZE ... WHERE gen=1 AND asset_id=?` 走的是 **Sequential Scan**，即使把 `(gen,asset_id)` 建成 UNIQUE 也不改变；只有主键 `doc=?` 走 Index Scan。资料库按 asset 找文档是常见操作，这是结构性不匹配，不是 Python 绑定的开销。
- **更新模型**：DuckDB 的 UPDATE 是 delete+insert，单行更新要维护 ART 索引和 WAL；SQLite 是原地 B-tree 更新。批量更新反过来，DuckDB 一次重写一个 row group，SQLite 要逐行改索引。
- **导入模型**：DuckDB 的 PK + UNIQUE 约束在插入时逐行检查，`documents` 还有两个大 VARCHAR（`body`、`record`）；SQLite 的 rowid 表和 B-tree 插入更便宜。DuckDB 的 Appender/C API 可能缩小差距，但 9.6 倍的导入差不是绑定开销能解释的。
- **进程模型**：DuckDB 的设计目标是把数据缓存进 RAM 做分析，所以一个进程持有读写锁；跨进程读写要靠 Quack/DuckLake 之类的服务器/目录方案。RAWMaster 现在是单进程内嵌，但“单进程”是产品约束，不是当前代码的硬约束；一旦要加 CLI、后台索引器、第二窗口或多实例，DuckDB 就会挡住。
- **格式兼容**：DuckDB 2.0 的新文件格式旧版本读不了；官方只承诺“新版本读旧文件”，不承诺前向兼容。SQLite 的文件格式是长期稳定的。对需要保存多年、可能降级打开的资料库，这是产品风险。
- **依赖体积**：DuckDB 原生库约 49 MB（Python 扩展实测），SQLite 已经在系统里。对 macOS 应用的分发和启动都有成本。

## 决策

### 现在做（P0，不改引擎）

1. **保留 SQLite 作为权威库**：`assets`、`operations`、`scheduler`、交付回执、分页投影全部不动。
2. **给所有目录连接加页缓存**：
   ```sql
   PRAGMA cache_size=-262144;  -- 256 MiB
   PRAGMA temp_store=MEMORY;
   ```
   100 万文档默认首页 21.9 → 7.5 ms。Swift 的 `LibraryStore` 和 Rust 的 `open_reader`/`Queue::open` 都要加；注意 Rust 的只读连接也要设，不能只设写连接。
3. **补索引**（Rust `query/schema.sql` 的下一版迁移）：
   ```sql
   CREATE INDEX docs_time ON documents(gen, time_desc);
   CREATE INDEX docs_project_time_desc ON documents(gen, project_id, time_desc);
   CREATE INDEX docs_project_time_asc ON documents(gen, project_id, time_asc);
   CREATE INDEX docs_name ON documents(gen, name_key);
   ```
   100 万实测：全库时间首页 37.1 → 0.02 ms；项目时间首页 7.6 → 0.04 ms；文件名前缀 150.5 → 0.02 ms。
   默认“拍摄顺序”排序不在覆盖范围内，7.5 ms 可接受；若以后要压，再单独评估带 `rm_natural` collation 的覆盖索引。
4. **文本搜索走 FTS5**（`search_fts` 已存在），不要用 `LIKE '%...%'` 扫全表。

### 如果 facets 上首屏（P1）

优先在 SQLite 里做**增量汇总表**，而不是换引擎：

- `rating_counts(gen, scope, rating, files, captures)`；
- `camera_counts(gen, scope, camera_key, files, captures)`；
- `tag_counts(gen, scope, key, files, captures)`；
- 用触发器或投影构建时增量维护，模式与现有 `scope_counts` 一致；
- 这样全库 facets 从 0.9–1.0 s 降到 O(1)，代价是导入/更新的少量触发器开销（需要单独测量）。

只有当 facets 的筛选组合是**任意谓词**、无法用预聚合覆盖时，才考虑 DuckDB sidecar。

### 如果确实需要 DuckDB（P2）

把它限定为**只读分析副本**：

- SQLite 仍是唯一权威库，所有写入、回执、调度都在 SQLite；
- 后台任务从 SQLite 重建 DuckDB 文件（`EXPORT`/`INSERT ... SELECT`），完成后原子替换；
- UI 进程只以 `read_only=true` 打开；多个 UI 进程可以并发读；
- 重建期间旧文件继续服务，避免锁冲突；
- 接受 100 万文档约 141 s 的重建时间和约 49 MB 的二进制体积；
- 不做双写；DuckDB 副本丢了可以重建。

### 不建议

- 把权威目录整体迁到 DuckDB；
- 让 UI 进程以读写方式打开 DuckDB 并指望多进程/多窗口；
- 为了“sub-millisecond”的市场话术换库——实测 100 万文档的 DuckDB 分页是 1.1–6.2 ms，不是亚毫秒；SQLite 加对索引才是 0.02–0.04 ms。

## 什么情况下结论会变

- 产品明确放弃多进程/多实例，且 UI 需要**任意组合**的百万级 facets，预聚合表覆盖不了；
- DuckDB 的 C API/Appender 把增量导入差距压到 2 倍以内（需要在 Rust 里复测，Python 绑定不算数）；
- 资料库变成“导入一次、只读浏览”的项目包模型，写路径和回执不再重要；
- SQLite 的汇总表维护成本被实测证明高于 sidecar 的复杂度。

## 复现

```sh
python3 -m venv output/research/db-bench/.venv
output/research/db-bench/.venv/bin/pip install duckdb
output/research/db-bench/.venv/bin/python docs/research/catalog-database-bench.py
# 可选：ASSETS=20000 / 200000 / 1000000，ROUNDS=3
```

脚本默认把数据库和报告写到 `output/research/db-bench/`（已被 `.gitignore` 忽略）；本文的汇总数据在 [`evidence/catalog-database/results.json`](evidence/catalog-database/results.json)。

## 局限

- 两个引擎都通过 Python 绑定驱动；DuckDB 的 C API 在点查和批量插入上会更快，SQLite 的 Rust `rusqlite` 也会更快。相对结论（点查/增量写 SQLite 强、全库聚合 DuckDB 强）来自执行计划和数据结构，不是绑定开销。
- 合成数据的分布是均匀的，DuckDB 的压缩率在真实照片目录上可能不同；文件体积的 40% 优势应视为上限附近。
- `body_search` 用了 `LIKE ... LIMIT 60`，只用于说明“没有 FTS 时不要用它做全文搜索”，不是 FTS5/DuckDB FTS 的对比。
- 写测试的 `insert_5k` 包含 1.5 万标签行；DuckDB 的每行固定成本在三个规模一致，结论不受表大小影响。
- 多进程测试只验证了“第一个进程读写、第二个进程读写/只读”这一种组合；全只读并发的组合单独验证过。
