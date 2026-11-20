# 大批量导入性能验证

日期：2026-10-25。环境：Mac16,5，16个CPU逻辑核心、128GiB内存，macOS本地文件系统。基准使用Swift Debug构建和隔离资料库；Release另行编译/签名检查。首轮隔离基准未触碰用户真实资料库，保留原有未提交源码修改。随后按用户要求进行了真实会话复测、正常应用升级及产品内重扫/分组操作，见[现场跟进记录](live-session-validation.md)。

## 首轮同机测量

| 测量范围 | 数据规模 | 优化前 | 优化后 | 结果 |
| --- | --- | --- | --- | --- |
| 照片列表与membership投影 | 3000张、6000条关系 | 384.38ms | 22.69ms | 16.94倍；各读取3次取中位数 |
| reference接入 | 500个小图片文件 | 617.75ms | 522.38ms | 耗时减少15.4%；不含分组/界面 |
| RAW+JPEG自动配对 | 1500对、3000条已就绪素材 | 3594.82ms | 183.49ms | 19.59倍；元数据fixture，无图像I/O |
| 配对幂等重扫 | 同上 | 149.22ms | 147.91ms | 无新增配对，语义与开销稳定 |
| 元数据+内嵌预览 | 6张实际ARW，共423075840字节 | 637.87ms | 189.73ms | 3.36倍；同工具、相同ID/key精确比较内容 |
| RAW接入集成测试路径 | 同6张原片 | 1880.84ms | 1441.37ms | 耗时减少23.4%；包含store改动 |

最后一行是已有真实RAW测试中的计时区间，包含接入、自动分组、结果/原片核验及恢复流程，不包含AppModel质量分析或屏幕展示。单轮数据受缓存和机器负载影响，不能据此推算任意目录的端到端倍数。其他表项也只代表列明范围。原片使用隔离目录中的APFS副本，原目录字节未修改；并行/顺序结果元数据、native证据、预览特征精确相同，分组摘要除时间外相同，SHA保持一致。

3,000文件控制器导入+质量检查实测4.24s，5ms目标心跳间隔P95为6.32ms、最大20.93ms（697样本）；后台快照读取最长87.28ms、MainActor应用最长17.89ms。该测试不注入人工延时，不启用自动分组，文件为小型合成数据，质量分析走证据错误处理路径；验证调度和持久化，不测RAW解码吞吐。心跳不等同AppKit/SwiftUI/WindowServer实际帧时延，也没有同一控制器的优化前心跳数据。

## 正确性与恢复

- membership首条rowid、多个组的任意included、session过滤与顺序；索引持久化/重开和未知结构拒绝。
- 有界发现批次、取消尾批保存、取消后恢复幂等；copy/reference、位置指纹、源文件改变、人工选择保留、逐文件事务回滚。
- 嵌套读取快照、跨连接一致性以及异常后恢复；同步reload/范围修改使在途快照失效，最后快照完成后才结束任务。
- 实际导入/质量分析期间MainActor心跳；慢快照期间的人工修改不被旧结果覆盖；取消后再次导入使用新的generation；10000条进度只保留最新待处理值。
- 自动配对的已存在人工配对、解除记录、歧义、未就绪、相机/时间/尺寸不符、相对路径、幂等扫描及逐对workflow revision。
- worker并发上限、稳定顺序、失败/取消后全部join、真实父Task取消、子进程不继承兄弟描述符；原有超时、输出上限、管道回收保持。

针对性验证已通过：存储170项（169通过/1跳过）、UI47项（45通过/2跳过）、imaging21项（全部实际执行）、配对24项（全部实际执行）。这些有交叉，不能直接加总。完整回归和打包最终结果见下文交付记录。

## 重现

在仓库根目录运行。输出请用新的隔离路径；真实RAW目录必须是原片/副本，不能使用指向目录外的符号链接。

```sh
RAWMASTER_IMPORT_BENCHMARK_OUTPUT=/tmp/rawmaster-store.json swift test --jobs 4 --filter ImportPerformanceTests
RAWMASTER_PAIR_BENCHMARK_OUTPUT=/tmp/rawmaster-pair.json swift test --jobs 4 --filter PairScanPerformanceTests
RAWMASTER_IMPORT_UI_BENCHMARK=/tmp/rawmaster-ui.json swift test --jobs 4 --filter ImportResponsivenessTests
RAWMASTER_RUNTIME_RAW_DIRECTORY=/absolute/raw-copy-dir RAWMASTER_RUNTIME_TOOL_ROOT="$PWD/output/RAWMaster.app/Contents/Resources/MetadataTool" swift test --jobs 4 --filter 'OrderedMetadataWorkersTests|RuntimeSequenceMetadataTests'
```

本地日志位于`.slim/deepwork/017-*.log`；JSON与临时RAW副本位于`output/validation/017-import-performance/`，均忽略提交。

## 实际限制

完整内容身份保护仍需多次顺序读源文件，外接盘、网络目录或系统文件提供器的I/O延迟可能继续限制速度。后台快照仍覆盖整库，持有共享store锁期间，同步人工数据库操作可能短暂等待；派生缓存和状态发布仍占用MainActor。尚未测量30,000张真实RAW长任务或真实窗口帧率。

业务schema版本保持6，新增可选索引`membership_asset_id`。新版本可读取旧库并创建该索引；旧版严格对象校验可能拒绝含该索引的库，因此本轮不承诺旧二进制直接降级打开。首轮隔离验证未升级用户实际资料库；现场跟进安装了新应用，资料库按正常产品路径创建了该索引，已先制作一致备份。

## 首轮交付记录

完整 `swift test --jobs 4` 退出码0：607项，588通过、19项条件跳过，零失败。UI164、Imaging222、Core172、Diagnostics19、SequenceProbe30项。实际执行真实六张RAW导入、并行提取一致性、父任务取消/管道隔离、3000文件控制器心跳等回归。完整日志为`.slim/deepwork/017-full-tests.log`。

完整回归期间再次测量控制器：4.12s，心跳P95 6.31ms、最大22.67ms，后台读取最长83.60ms、应用最长17.18ms。Release编译、应用资源打包、图标检查和严格签名校验均通过；AVKit显式依赖保留。打包后全部Sources/Tests/Package.swift内容指纹与完整测试时一致，`git diff --check`通过。应用为`output/RAWMaster.app`，本地交付记录为`output/validation/017-import-performance/delivery.json`。沿用本机临时签名，未作发布公证。


## 现场跟进与当前交付

首轮607项回归和e2834b…二进制是追加内存修复前的记录。用户随后要求测试当前会话，实际52GB长任务暴露了读取缓冲滞留；追加修复、已安装版本、真实列表交互和最终回归以[现场跟进验证](live-session-validation.md)为准。
