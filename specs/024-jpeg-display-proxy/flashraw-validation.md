# FlashRaw 重构与性能验收

## 实现范围

- 新增 `CFlashRaw` 动态加载桥，支持 RAW／normalized、线性 F16、RGBA8 和区域解码。
- FlashRaw 的线性 F16 三通道帧经自有 Metal pass 转换为现有 RGBA32F 交互代理；EXIF 方向与缩放合并到同一 pass。
- 中性代理不再绑定曝光、白平衡和 RAW 降噪参数；连续修改这些参数共享同一基图。
- 后缀显式物化一次，校验、几何和输出共享该纹理，避免重复求值未缓存的 CI 图。
- 每个源复用交互 `CIContext`，并保留显式内存账目；共享 GPU 上限调整为 192 MiB，以容纳两张线性代理和显示输出。
- 自适应 Brilliance 的交互路径不再建立原生 RGF 瓦片文件；高级细节的交互路径由外层统一执行有限值校验。
- settled、保存和导出继续使用 Core Image canonical；FlashRaw 不改变最终显影契约。
- 构建脚本将 GPU 版 `libflashraw_capi.dylib` 和 MIT／Apache 许可打包到应用。
- `scripts/build-flashraw.sh` 固定 FlashRaw 提交 `2994e8c550bec70ab78a938ab28a74d7762124f4` 和归档 SHA-256，启用 `gpu,jpegxl`；已实际重建并确认 dylib 哈希一致。

## 真实 RAW 回归

使用 Sony 9504 × 6336 RAW，SHA-256 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`：

- 真实 C ABI 打开、线性 F16、Metal 转换、512 × 512 区域 RGBA8 均通过。
- 连续 4 次曝光／白平衡变化：代理 `fills = 1`，至少 3 次缓存命中。
- 聚焦回归：35 项通过，1 项按既有条件跳过。
- 完整 Debug 与 Release 各执行 1,612 项测试，66 项按既有条件跳过，0 失败（Imaging 788／44 跳过；UI 431／17；Core 324／3；AI 20／2；Diagnostics 19／0；SequenceProbe 30／0）。

日志：`output/tools/diagnostics/flashraw-full-debug-tests.log`、`flashraw-full-release-tests.log`、`flashraw-cache-test.log`。

## 性能测量

最终测量为 2400 × 1600 API 返回时间，每个操作连续 3 次。报告：`output/performance/flashraw-interactive-operators-20261120/interactive-performance.json`。

| 操作 | 中位数 |
| --- | ---: |
| 中性 | 16.2 ms |
| 曝光＋颜色 | 13.5 ms |
| 自适应 Brilliance | 32.2 ms |
| Texture | 18.9 ms |
| Clarity | 16.9 ms |
| Dehaze v1 | 19.1 ms |
| Dehaze v2 | 21.2 ms |
| 几何 | 11.0 ms |

已有 Camera Raw 19.0 同机基线的单次样本为：曝光约 149.9 ms、Clarity 约 228.9 ms、Dehaze 约 153.7 ms。该基线不是统计合格的多次中位数，因此这里只声称当前实现明显快于这些已有样本，不外推为所有操作和相机的全面领先。

### 同尺寸 Lightflow 对照

Lightflow 浏览器画布也实际调整为 2400 × 1600，使用同一 RAW 和 GPU-idle 帧事件。报告：`output/lightflow-research/same-size-runtime.json`。

| 操作 | Lightflow 帧完成 |
| --- | ---: |
| 曝光 | 6.0–17.4 ms |
| Texture | 12.8–14.9 ms |
| Clarity | 9.9–10.1 ms |
| Dehaze | 6.6–12.3 ms |

RAWMaster 的 API 返回与 Lightflow 的 GPU-idle 事件边界不同，不能直接做严格排名。当前结果已处于同一数量级；Texture／Clarity 接近该范围，Dehaze 和自适应 Brilliance 仍有进一步空间。

## 实际应用验收

- Release 应用包含 FlashRaw dylib，严格 ad-hoc 签名通过。
- 真实窗口成功进入初修并显示 2400 × 1600 预览。
- 实际输入曝光 0.25、进入 100%、返回适合窗口、复位曝光 0 均完成；窗口标题保持照片名和项目名。
- 应用通过 Cmd+Q 正常退出。
- 版本 24.0 已安装到 `/Applications/RAWMaster.app`；旧版保留在 `output/validation/flashraw-refactor/pre-install-backup/`。
- 安装后的 dylib SHA-256 为 `f8d79149d1c5689720200b9381c5442395eee0c2f8a08e5ff5b3956cd5d49d32`，与构建输入一致。

## 边界

- FlashRaw 与 Core Image 的默认显影不相同；本报告的 p99 差异不得被解释为像素等价。当前交互为近似预览，settled／保存／导出保持 canonical。
- 性能测量不是物理输入到屏幕的统一计时；若需进一步收紧到固定百分比，应使用同一 ScreenCaptureKit 协议重新测量三者。
- 目前只完成实际 RAW 样本和既有测试覆盖，不外推到全部 RAW 格式、所有相机和所有组合配方。
