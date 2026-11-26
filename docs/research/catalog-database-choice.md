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

| 查询 | SQLite 基础 schema | SQLite + 两个索引 | DuckDB |
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

1. **分页不是 DuckDB 的优势**。只要 SQLite 有匹配排序的索引，分页是 0.02–0.04 ms，比 DuckDB 快 30–270 倍。
2. **真实搜索缓存已经为五种排序建了 keyset 索引**，上表第一列只用了基础 `query/schema.sql`，所以“缺索引”的结论要收窄。`query/index.rs::initialize` 另外创建了 `library_original`、`project_original`、`library_descending`、`project_descending`、`library_filename`、`project_filename`、`library_stars`、`project_stars` 等索引，全部带完整的 tie-breaker。用这组真实索引复测 20 万文档：默认“拍摄顺序”首页 **0.0735 ms**，拍摄时间倒序 **0.0757 ms**，`EXPLAIN QUERY PLAN` 直接走 `project_original` / `project_descending`。因此 P0 **不需要新增分页索引**，只需要确认这些索引存在。
3. **全库 facets 是 DuckDB 唯一决定性的读优势**（50–90 倍）。但当前 `AppModel.submitCatalogPage` 构造的 `CatalogGridRequest` 没有传 `facets`，所以这条路径还没被 UI 使用。等 facets 真的上首屏，再用汇总表或 sidecar 解决，不必现在就为它换库。
4. **文件名前缀的 150 ms 不是真实查询**。真实 `filename` 过滤是 `instr` 子串（<3 字符）或 trigram FTS（≥3 字符），不是 B-tree 前缀；补 `(gen,name_key)` 索引只能加速前缀，不能加速 `instr`。短查询的正确解法是下一节的东亚 FTS，而不是再加一条 B-tree。

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
   100 万文档的排序型查询（基础 schema）21.9 → 7.5 ms；真实搜索缓存已有 keyset 索引，默认首页 0.07 ms，缓存主要帮助 facets 和临时排序。Swift 的 `LibraryStore` 和 Rust 的 `open_actual`/`open_reader`/`Queue::open` 都要加；注意 Rust 的只读连接也要设，不能只设写连接。
3. **不要重复加分页索引**：`query/index.rs::initialize` 已经为 `original`、`filename`、`capturedAscending`、`capturedDescending`、`ratingDescending` 建了 library/project 两套 keyset 索引，并带完整 tie-breaker。20 万文档实测 0.0735–0.0757 ms；先验证 `EXPLAIN QUERY PLAN`，缺哪条再补，不要照搬本文早期基于基础 schema 的 DDL。
4. **文本搜索走 FTS5**：`search_fts`（trigram）已存在，覆盖 ≥3 字符的子串；1–2 字符的东亚查询需要新增 CJK unigram 索引，见下一节。不要用 `LIKE '%...%'` 扫全表。

### 如果 facets 上首屏（P1）

优先在 SQLite 里做**按 generation + watermark 的汇总/缓存**，而不是换引擎：

- 评分/相机 facet 可以用 `documents` 上的触发器维护 `(gen, scope, rating/camera_key, files, captures)`，每条文档 4 次 upsert（library + project 两个 scope × file/capture）；
- 标签 facet 需要 `doc_tags` 与 `documents` 的 file/capture 去重，触发器成本更高；先做“按 watermark 的持久缓存”，同一代内重复请求 O(1)，首次请求仍按现有 GROUP BY 计算；
- 如果之后证明标签 facet 的首屏成本不可接受，再用 `facet_refs`/`facet_counts`（模式与 `object_refs`/`scope_counts` 相同）做增量维护；
- 全库 facets 从 0.9–1.0 s 降到缓存命中后的 O(1)，代价是写入/首次计算的成本，需要单独测量。

只有当 facets 的筛选组合是**任意谓词**、无法用预聚合覆盖时，才考虑 DuckDB sidecar。

### 东亚 FTS

现有 `search_fts` 用 `tokenize='trigram'`，只对 ≥3 字符的查询走索引；1–2 个汉字/假名/谚文会退回 `instr` 全表扫描。补一张 `search_cjk`：

- 只存 CJK 字符的 unigram（汉字、平假名、片假名、谚文、注音），用 `unicode61`；
- 查询 1 字符时匹配单个 token，2 字符时用短语 `"富 士"` 保证相邻；
- 非 CJK 段落插入一个 gap token，避免“富士Nikon山”被 `"士 山"` 误命中；
- ≥3 字符继续走 trigram，不增加第二张大表；
- 现有缓存原地建表并回填，不要求用户手动“重建索引”。

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

## 实施记录（2026-11-26）

### P0：页缓存与真实索引

- Swift `LibraryStore`、Rust `query::open_actual`（source + cache）、`navigation::open_reader`、`scheduler::Queue::open`、`processing::db`、`managed_files::writer` 都加了
  `PRAGMA cache_size=-262144; PRAGMA temp_store=MEMORY;`。
- 真实搜索缓存的分页索引不需要新增：`query/index.rs::initialize` 已有 `library_original`/`project_original`/`library_descending`/`project_descending`/`library_filename`/`project_filename`/`library_stars`/`project_stars` 等 keyset 索引。用真实索引复测 20 万文档：默认“拍摄顺序”首页 **0.0735 ms**，拍摄时间倒序 **0.0757 ms**，计划分别走 `project_original`、`project_descending`。因此没有加重复的 `docs_time`/`docs_project_time`。
- `name_key` B-tree 没有加：真实 `filename` 过滤是 `instr` 子串（<3 字符）或 trigram FTS（≥3 字符），B-tree 前缀索引帮不上；短查询由下面的 CJK unigram 表解决。

### P1：按 watermark 的 facets 缓存

- 新增 `facet_cache(gen, watermark, fingerprint, names, payload)`。
- `read::run` 在同一个读快照里查缓存；未命中时计算 facets，`query::page` 在快照结束后写入。键包含 generation、watermark、查询指纹和排序后的 facet 名，所以翻页、重复筛选、同一 watermark 下的再次请求都是 O(1)。
- 写入时清理旧 generation 和更旧 watermark 的行。
- 测试 `repeated_facet_pages_reuse_the_watermark_cache` 通过改写缓存 payload 证明第二次请求确实命中缓存。
- **没有立刻上增量触发器汇总表**：原型在 20 万文档上只维护 library 的 rating/camera（每文档 8 次 upsert）就把 5000 行插入从 **191 ms 拖到 262.5 ms（+37%）**；标签还要再乘，且当前 `CatalogGridRequest` 根本没有请求 facets。等 facets 真的上首屏、且首次请求成本不可接受时，再用 `facet_refs`/`facet_counts`（模式与 `object_refs`/`scope_counts` 相同）做增量维护。

### 东亚 FTS

- 新增 `search_cjk(name, body)`，`unicode61`，只存 CJK unigram。
- `text::cjk_index` 把汉字、平假名、片假名、谚文、注音拆成单字 token；非 CJK 段落插入 `U+E000` gap token，避免“富士Nikon山”命中 `"士 山"`。
- 1 字符查询匹配单 token；2 字符查询用短语 `"富 士"` 保证相邻；≥3 字符继续走 `search_fts` trigram。
- 现有缓存原地建表并回填（`search_features.cjk_v1` 标记），不需要用户手动“重建索引”；测试覆盖新缓存、旧缓存回填、汉字/假名/谚文、`filename` 与 `body` 两个字段、跨 Latin 的假相邻。
- 使用 `content='', contentless_delete=1`，不重复存 `name`/`body` 原文；旧 SQLite 不支持该选项时回退到普通 FTS5 表。
- 10 万条中文正文（每条约 144 个汉字 + 文件名）实测：
  - 只有 trigram：构建 2.21 s，文件 175.9 MB；
  - trigram + 普通 unigram：构建 4.27 s，文件 254.3 MB；
  - trigram + contentless unigram：构建 4.10 s，文件 203.2 MB；
  - 2 字查询 0.039 ms，3 字 1.84 ms，1 字 1.83 ms（匹配全部 10 万条）。
- 也就是说 CJK 表在 10 万条中文正文上增加约 27 MB 和约 1.9 s 构建时间；100 万条大致线性到 270 MB 量级。真实目录的中文正文通常比这个合成样本短，成本会更低。若仍嫌大，下一步只对 `filename` + caption/title/tag 建 CJK 表，而不是整个 `body`。

### 验证

- `cargo test --release --manifest-path Modules/LibraryCatalog/Cargo.toml`：全部通过（含 12 项 `query_pages`）。
- `swift test -c release --filter RAWMasterImagingTests`：1,081 项，86 跳过，0 失败。
- `swift build -c release --product RAWMaster`：通过。
