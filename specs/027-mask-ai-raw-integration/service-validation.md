# 027 · 独立服务与性能验收

## 范围与判定

本轮完成的是 RAWMaster 之外的**独立模型服务与快照骨架**：语义描述、不可变快照、异步协调、原生取消、取消回滚、显式资源释放，以及真实 RAW 性能门禁。没有修改 RAWMaster 主 Package、UI 或现有渲染结果。

性能验收使用水鸟 Sony RAW，分析图为 2400×1600。每次运行先删除自己的基准快照目录，并断言首次操作不是快照命中、第二次 Subject 才允许命中，避免旧结果污染冷启动指标。[性能结果](../../experiments/MaskAI/Validation/Performance/performance-results.json)

## 新增独立能力

| 组件 | 实现与验证 |
| --- | --- |
| `SemanticMaskDescriptor` | 固定 kind、target、prompt、人物实例、源绑定、模型 ID／哈希、分析输入与算法版本 |
| `MaskSnapshotStore` | Gray8 内容寻址资产、最新语义索引、原子写入、尺寸／字节数／SHA-256 校验 |
| 不可变历史 | 同一描述的新内容生成新快照，旧引用继续可读取 |
| `MaskAICoordinator` | 串行原生执行、异步任务句柄、精确快照命中、任务取消与资源释放 |
| `ONNXCancellation` | 将取消接入 ORT RunOptionsSetTerminate，并在推理／写盘边界检查 |
| 取消回滚 | 写盘期间取消会删除本次索引和资产；不误删同描述的更新快照 |
| 资源释放 | 清空所有模型 session、SlimSAM embedding、场景概率和人物检测缓存 |
| `MemoryMeter` | 同时记录当前 RSS 与进程历史最大 RSS |

## 性能门槛与实测

| 操作 | 门槛 | 实测 | 结果 |
| --- | ---: | ---: | --- |
| Subject 冷创建（真实 RAW） | 6000 ms | 1621.93 ms | 通过 |
| Subject 快照命中 | 250 ms | 1.93 ms | 通过 |
| 首个风景场景分析 | 6000 ms | 740.44 ms | 通过 |
| 同图另一风景目标 | 1500 ms | 25.40 ms | 通过 |
| 首个物体 prompt | 6000 ms | 1358.41 ms | 通过 |
| 同图框选／复用 encoder | 2000 ms | 125.67 ms | 通过 |
| 快照读取与校验 | 100 ms | 1.48 ms | 通过 |
| 独立长任务中途取消 | 2000 ms | 393.96 ms | 通过 |

Landscape 的“共享场景”和 Object 的“复用 encoder”在结果中不是快照命中，因为它们的描述不同；它们分别复用模型内部的场景概率和图像 embedding。快照命中只用于完全相同的语义描述，三种缓存没有混为一谈。

## 优化与正确性修复

1. 初版 RAW 后续框选为 2546.51 ms，超过 2000 ms 门槛。主要瓶颈是纯 Swift 多次整图插值，改为 Core Image Gray8 缩放后，同一操作降至约 125.67 ms。
2. 初版性能目录残留旧快照，曾把首次操作错误标为缓存命中。基准已改为开始前清空自己的快照目录，并加入冷／暖断言。
3. 初版取消发生在写盘期间时，任务虽返回取消，最新索引仍可能可见。加入条件回滚后，取消任务没有可见快照。
4. 释放接口同时清理模型和图像派生缓存；测试验证所有公开状态标志在释放后归零。

## 内存验收

性能测试的最大 RSS 为 **3,149,791,232 字节（约 2.93 GiB）**，低于本轮 4,000,000,000 字节门槛。当前 RSS 从初始 435,748,864 字节变为释放后的 398,295,040 字节，下降约 35.7 MiB。该观测不证明所有分配器缓存都已归还系统，也不代替生产内存泄漏检测；它只说明本轮没有超过预算，且释放后没有相对初始值增长。

## 测试覆盖

独立模块当前包含离线几何与效果测试、快照测试、真实模型测试、真实 RAW 测试、协调器测试和性能验收。最终同时启用全部模型／RAW／性能测试后，结果为 **27 项测试、0 失败**，总耗时约 59.7 秒；完整回归进程最大 RSS 为 4,674,584,576 字节（约 **4.35 GiB**），其中性能子测试的所有门槛仍独立通过。[最终完整日志](../../experiments/MaskAI/Validation/final-suite.log)

测试可分层启用：

```bash
swift test
MASK_AI_MODEL_TESTS=1 swift test --filter CoordinatorTests
MASK_AI_RAW_TESTS=1 swift test --filter RAWIntegrationTests
MASK_AI_PERFORMANCE_TESTS=1 swift test --filter PerformanceAcceptanceTests
```

## 仍未闭合

- 这是独立服务验收，不是 RAWMaster 生产集成验收。
- 尚无生产 UI、配方迁移、跨照片同步、模型更新或正式资料库路径。
- 尚无真实人像／雪景 RAW 的正向质量资格，Snow 与负点仍受此前限制。
- 性能门槛是当前机器和样本的验收基线，不是所有 Mac 或所有 RAW 的保证。
- 尚未完成 Core ML 转换、Core ML EP 或生产模型分发验证。
