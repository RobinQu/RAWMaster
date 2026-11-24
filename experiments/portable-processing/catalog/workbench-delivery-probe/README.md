# 核对工作台逐项交付票据

`verify_tickets.py` 读取一次 035 混合负载留下的 `catalog.sqlite` 和相邻的 `delivery/`。夹具需包含一个已完成的内联中性 JPEG 批次。重新登记、暂存、发布和确认都在报告旁边新建的临时目录进行。SwiftUI 工作台正常入口的成品与计时可按 [032 导出基线](../../../../specs/032-export-workspace/performance.md) 复跑。

需要 Python 3.11 或以上，以及要检查的已构建资料库 C ABI。在仓库根目录运行以下命令，最后一个参数传入尚不存在的文件。

```sh
python3 experiments/portable-processing/catalog/workbench-delivery-probe/verify_tickets.py \
  --runtime .build/release/LibraryCatalog_RAWMasterLibrary.bundle/Contents/Resources/rawmaster-library.runtime \
  --fixture output/035-development/flux-mixed-candidate-batch29-cross-backend/mixed \
  --count 200 \
  --report output/035-development/queue-200-results.json
```

每项准备后读回持久票据，核对暂存文件的 inode、大小和源成品 SHA-256。发布后同一条票据仍为 `prepared`，确认后变为 `delivered`。再次确认首项与末项，检查批次完成、目录清单和 SQLite 完整性。报告按文件名列出 SHA-256，可与原生工作台清单逐项比较。断电和物理外置卷属于独立验收。该脚本使用已生成成品，单独测量的是资料库与文件交付协议。

另存的 [APFS 硬链接候选差分](qualified-link.patch) 对应比较中的 C。它在确认已同步的私有源目录仍然保持原状态时省掉一次目录同步。实测未改善整批吞吐，产品继续对正常发布的两个原目录执行完整同步。可以在独立 checkout 用以下命令检查差分是否适用。

```sh
git apply --check experiments/portable-processing/catalog/workbench-delivery-probe/qualified-link.patch
```

## 核对正常工作台的同轮票据

在 macOS 本机 APFS 上运行 032 的 `testRealWorkbenchBenchmarks` 时，额外设置 `RAWMASTER_EXPORT_BENCH_RECEIPTS=1`。完成全部计时并关闭模型后，测试将该轮的独立 SQLite 快照保存到 `rawmaster/receipts.sqlite`。保留原位置的输入和成品目录，复查时可将多轮同输入对照一起传入。以下示例检查主源两次，报告路径应尚不存在。

```sh
python3 experiments/portable-processing/catalog/workbench-delivery-probe/verify_benchmark_receipts.py \
  --round output/035-development/phase-ac/workbench/main-a1 \
  --round output/035-development/phase-ac/workbench/main-b1 \
  --report output/035-development/main-delivery-audit.json
```

脚本需要 Python 3.11 及以上。它只读打开每个快照，重新计算来源入选指纹与文件 SHA-256，再通过打开的成品描述符读取 APFS 卷、inode 和纳秒出生时间。每份冻结清单、目标、完成标记与项目票据必须相互吻合，所有输出目录还须只包含该批预期的文件。报告中的映射用原文件名、来源摘要、成品名、成品摘要与大小计算，能跨批次比较。

副源 JPEG 取自同场景的原生 2048 像素成品，副源 DNG 使用 032 的单条带 TIFF 头和独立生成的 RGGB 像素。可从已经生成的两份夹具重建这套输入。输出目录应尚不存在。

```sh
python3 experiments/portable-processing/catalog/workbench-delivery-probe/alternate_inputs.py \
  --template output/035-development/export-main/raw-source/R000.dng \
  --jpeg-delivery output/035-development/flux-mixed-candidate-batch29-cross-backend/mixed/delivery \
  --output output/035-development/alternate-inputs
```

## 比较 SQL 读取次数

`trace_snapshot.swift` 在同一 `LibraryStore` 上安装 `sqlite3_trace_v2`，按 SQL 正文计数，三种模式都调用公开的 `editingSourceSnapshot`。在已用 `swift build -c release --build-tests -Xswiftc -enable-testing` 构建的 macOS 工作树中，可以拿原生基准刚刚保存的独立快照复跑。将下列 `round` 改为需要检查的基准轮。

```sh
round=output/035-development/phase-ac/workbench/main-a1
scratch=$(mktemp -d)
cp "$round/rawmaster/receipts.sqlite" "$scratch/trace.sqlite"
python3 - "$scratch" <<'PY'
import json, pathlib, sqlite3, sys
scratch = pathlib.Path(sys.argv[1])
with sqlite3.connect((scratch / 'trace.sqlite').as_uri() + '?mode=ro', uri=True) as db:
    rows = db.execute("SELECT value FROM lc_meta WHERE key GLOB 'wb032.manifest.v1/*'")
    batch = max((json.loads(data) for (data,) in rows), key=lambda value: len(value['items']))
(scratch / 'inputs.json').write_text(json.dumps([item['version']['source'] for item in batch['items']]))
PY
for module in LibraryCatalog_RAWMasterLibrary PhotoExport_RAWMasterPhotoExport RAWMaster_RAWMasterCore; do
  ln -s "$PWD/.build/release/$module.bundle" "$scratch/$module.bundle"
done
swiftc -O -target arm64-apple-macos15.0 -I .build/release -I Sources/CSQLite \
  -Xcc -fmodule-map-file="$PWD/.build/out/Intermediates.noindex/GeneratedModuleMaps/CLibraryCatalogABI.modulemap" \
  experiments/portable-processing/catalog/workbench-delivery-probe/trace_snapshot.swift \
  .build/release/{RAWMasterCore,RAWMasterLibrary,CLibraryCatalogABI,RAWMasterPhotoExport}.o \
  -lsqlite3 -o "$scratch/trace"
for mode in read autocommit write; do
  "$scratch/trace" "$scratch/trace.sqlite" "$scratch/inputs.json" "$mode"
done
```

已建立读事务时，200 份快照各需 200 次资产与凭据查询。自动提交和 `BEGIN IMMEDIATE` 写事务各保留 400 次。相同输入的三个数组摘要应当一致。具体 SHA 随来源路径、资料库和入选记录变化。

核对后，`pack_verified_receipts.py` 可把多套输入的逐项持久记录压缩成一份 JSON Lines。每行是一个批次，包含原票据、来源与版本身份、原始资料库记录摘要及该批的 APFS 目标身份。打包时须再次匹配数据库和已核对的来源至成品映射摘要。可直接读取本轮 [3,872 份记录](../../../../specs/035-portable-processing-cores/evidence/workbench-snapshot-receipts.jsonl.gz)。

```sh
python3 experiments/portable-processing/catalog/workbench-delivery-probe/pack_verified_receipts.py \
  --audit output/035-development/phase-ac/workbench/main-receipts.json \
  --audit output/035-development/phase-ac/workbench/secondary-receipts.json \
  --output output/035-development/workbench-verified-tickets.jsonl.gz
```
