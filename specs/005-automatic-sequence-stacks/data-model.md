# 005 · 数据与事务合同草案

2026-10-24 · 设计提案；当前生产仍为 schema 3，本轮未迁移。具体表名和接口在实施合同审查时冻结。

## 领域不变量

`StackScope` 与 ImportSession 一对一，由 sessionID 稳定派生，不随算法版本创建可并存作用域。`PhotoStack` 是至少两张不同照片的连续区间，具有稳定 ID、类型、默认封面、来源、保护、单调 revision 和 provenance。类型为 burst / interval；仅当成员资格达标而类别未定时允许 sequence，界面标“拍摄序列”，不计为两类识别通过。

成员顺序必须等于**完整会话**共享自然路径顺序，唯一 primary 归属，不跨项目/会话、不嵌套。未知/失败/其他相机行仍占位并阻断桥接。首版人工拆分/相邻合并也遵守连续性；非连续/重叠用途关系继续使用 CaptureGroup。堆叠封面必须是成员，不代表精选。

成员、封面、保护与折叠不修改 assetID、内容 hash、评级、决定、CaptureGroup 及 included。折叠是本地浏览偏好，不是领域命令或否定识别的记忆。相同内容不同已登记资产仍是独立身份。

## 证据与输入 token

`SequenceCaptureEvidence` 绑定 assetID + contentHash + extractorVersion + evidenceRevision，保留原始 EXIF 时间/子秒/offset、严格解析的 civil time、精度、可选 UTC、方向、可选真实曝光时长、设备证据和警告。无有效 offset 不造 UTC；旧 capturedAt 不作可信兜底。原设备标识经验证后仅保存本地 opaque digest 及来源。单相机声明独立于时钟证据，绑定封存清单及 revision；撤销或扩充清单使相关输入失效。

`StackInputToken` 包含 scope/inputRevision、structureRevision、排序/策略/提取器/算法版本、正规输入摘要。不可变输入保留全体 ordinal 和 barrier；引擎只输出连续 ordinal 区间、类型/理由、覆盖和版本，不输出 SQL 或可信 after 状态。Core 由封存清单重建成员，检查范围、连续/互斥、设备/时钟及保护约束。

成员增减、内容/证据、来源声明、排序、人工保护/结构变化使相关输出过期。评分、保留/排除或用途组参与变化不使纯图像分析失效。路径移动但同内容只重验读取凭据，不等同内容变化。首版同会话结构 revision 可采用保守整体失效，暂不做复杂合并。

读取、SHA/特征计算在 DB 锁外；复用的证据须已绑定同一内容。补读历史素材验证预期内容摘要，读前后核对文件凭据；已知内容变化不能改写旧 hash 或沿用旧证据。文件系统与 SQLite 无跨系统原子性，读后外部改写窗口由可用性检测继续失效，不把一次 stat 当内容证明。

## 持久结构提案：schema 3 → 4

| 结构 | 职责与约束 |
|---|---|
| stack_scopes | session_id UNIQUE；input/structure revision、排序版本和来源声明 |
| sequence_evidence | asset_id 主键，内容/提取器/证据版本与紧凑摘要；可重建缓存 |
| photo_stacks | 稳定 ID、scope、kind、cover、origin、protected、revision、逻辑写入头、tombstone、provenance |
| stack_asset_state | 主键(scope_id,asset_id)，stack_id/position 同空或同非空，UNIQUE(stack_id,position)；占用/散片/keepSingle/人工分区及因果头，解除后仍保留 ABA 证据 |
| stack_jobs | 正规请求、trigger、generation、state、token、attempt/checkpoint、结果摘要与 commandID |
| stack_job_inputs | 主键(job_id,ordinal)，一次保存的封存清单，含失败 barrier，不反复写全量快照 |
| stack_job_candidates | 分段 staging 输出与 coverage，不能被当作当前 active membership |
| stack_commands | 正规请求、精确结构分量 before/after、依赖头、补偿链与版本 |

DB 唯一/归属约束与发布事务末校验共同保证成员不重复、连续和封面合法。增加受识别 schema 对象时同步修改 preflight 合同，避免当前拒绝额外对象的校验与新索引冲突。优先内联 UNIQUE；不创建通用同步/CRDT 表。

迁移前做包含有效 WAL 的一致 SQLite 备份，预检后单事务迁移。v1/v2 经现有路径直升4也仅需一次升级前一致备份；更高/未知非空 schema 在写入前拒绝。失败回滚、旧操作保留。升级只建空结构，不读 RAW、不推断设备、不转换或自动重算旧组；旧资产默认散片。

## 任务状态与应用边界

trigger 为 importFinalization / historicalRerun。状态覆盖 queued → collectingEvidence → analyzing → readyToApply → applying → completed / partial，以及 cancelled / interrupted / stale / failed；历史 readyToApply 等待用户明确应用，新导入允许自动应用。单纯关面板不取消，取消递增 generation 并阻断所有迟到写入。

ImportSession.status 保留文件导入语义；分组状态独立。证据可增量收集，输入封存后分析跨页尾部，完整输出 staging 后才发布。先不做可见暂态堆叠。UI 整体任务必须区分原片成功、分组完成/待重试；旧 completed 会话不因未分组变导入失败。

历史作用域显式为完整 sessionIDs，空范围拒绝，不能解读为全库。batchID 聚合多个会话任务，每会话独立事务；预览和应用前分别重验 token。短事务同时写 active stack/membership、保护、命令/operations、job结果；崩溃只能见提交前或完整提交后。请求 ID 同正规请求幂等，不同请求复用同 ID 拒绝；已应用 resume 不重复提交。相同有序成员/kind 保留原 stackID 和偏好，无结构变化不伪造撤销。

## 替换、人工保护与失败覆盖

仅替换完整分析区内未保护的自动结构。人工创建/拆分/合并/改类型/封面默认保护；用户明确清除保护/允许重算才纳入新预览。单纯展开不保护，单纯解锁也不偷偷提交覆盖。

拆分形成受保护分区；一侧只有一张则成为受保护散片，不造单成员堆叠。unstack 解除 active membership，并写逐成员 keepSingle 记忆，后续不能重新收纳或从两侧跨越。保护绑定 assetID/会话，不绑定易变 ordinal/路径。引擎把保护范围当 barrier，Core 再核验。

coverage 区分完整分析、检查后证据不足、暂时无法读取/未完成。完整检查后不足可以把旧自动结构变回散片；暂时读不了不等于否定，保留旧结构并标未复核。旧堆跨未读区时整个旧堆及触及范围退出替换区，不替换半堆。摘要报告 partial、保留与未处理范围。

## 精确恢复与撤销

命令包括自动 job应用、连续范围创建/合并（create/mergeRange）、拆分、改类型/封面、解除、允许重算和历史恢复。create/mergeRange 至少两张、同会话、完整基础顺序连续，只能包含散片或完整旧堆；不能自动纳入未选成员或拆取部分旧堆。输出为一条默认保护的人工堆叠命令，预览完整影响并精确补偿。按受影响完整结构分量记录堆、占用、保护和逻辑头；恢复先核对当前 after 和因果头，原子反向恢复，不能搬走后来占用者、扩大范围或恢复整份评级快照。同资产结构 ABA 即使外观相同也冲突；后续独立打星不冲突。物理 revision 只增，补偿 ID 保留，缺 before head 不默认 nil。

自动导入和异步历史重跑只写持久命令，不压入普通 ⌘Z。独立“撤销这次分组”入口执行显式补偿，随后该用户动作进入统一运行期栈；人工堆叠修改也按真实时序入栈。自动应用的撤销不附送 keepSingle，它精确还原原结构；已消耗 job 不因 resume 再发布，未来明确新重跑可再次识别。长期禁止重建应使用解除/忽略动作。

恢复 interrupted 任务需重验版本/清单/内容/位置/保护，仅复用有效 checkpoint。历史等待预览应用的任务重启后仍需明确应用，不能因恢复后台计算自动越过该步。可清理可重建 staging/特征，保留 current provenance、命令和恢复所需快照；缓存/备份需预算，资源耗尽报 incomplete。

## 实施验证要求

覆盖唯一占用/连续性、受保护单张、重叠用途组保持、部分覆盖替换、取消晚回调/重复 resume、评级不使 job 失效而结构变化拒绝、同请求幂等/异请求拒绝、命令注入失败全事务回滚、ABA/冲突补偿、active-WAL一致备份与 v1–3升级/失败重开。正式资料库先在一致副本验证；数据安全通过不等于算法质量通过。
