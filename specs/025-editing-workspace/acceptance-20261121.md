# 编辑工作台功能与性能验收

日期：2026-11-21。状态：功能、Release 性能、隔离原生窗口验收及 27.0 安装均已完成。

## 本轮实现范围

- 暗房画布提供深灰、中灰、浅灰、纯黑四种固定背景，底部工具条切换并持久化；左右工具与底部胶片采用悬浮材质，照片保持全幅布局。
- 右侧调整为固定类目列＋详细面板；基础、曲线、混色、细节、光学、效果、分级、蒙版、修复和已有配方分别进入独立类目。
- RGB 直方图复用同一 128 像素代理采样，不增加额外 RAW 解码。Black 0–10%、Shadow 10–30%、Exposure 30–70%、Highlight 70–90%、White 90–100% 支持横向拖拽；White 已接入真实 Metal 像素运算和原生快速路径。
- Remove／Heal 使用既有纹理转移修复，Clone 使用独立 donor 像素复制，不复用或冒充 Heal 数学。
- 蒙版支持线性渐变、径向渐变、亮度范围和 Vision AI 主体；包含启停、反转、羽化、不透明度、分层排序、删除以及曝光／高光／阴影／饱和度调整。AI 结果保存为实际 PNG 蒙版，历史重放不重复推理。
- 导出为非模态工作台，保留显式多选范围；支持 JPEG、TIFF 16 位、PNG 16 位、原始／1080／2048／4096／自定长边、JPEG 质量、输出目录和 `{name}`／`{index}`／`{date}` 命名。每张照片使用当前配方，独立暂存并拒绝覆盖。

## 自动化功能结果

最终完整 Debug 日志：`output/tools/diagnostics/editing-workspace-full-tests-final-complete.log`。

| 测试包 | 执行 | 条件跳过 | 失败 |
| --- | ---: | ---: | ---: |
| UI | 448 | 18 | 0 |
| Imaging | 800 | 44 | 0 |
| Core | 326 | 3 | 0 |
| AI | 20 | 2 | 0 |
| 合计 | 1,594 | 67 | 0 |

专项证据包括：RGB 已知通道与透明像素、White 实际高光像素与透明通道、Camera Raw 分区边界、Clone 与 Heal 的不同像素结果、蒙版分层与 Codable 回放、蒙版撤销／重做与退出落库、真实 JPEG 缩放／质量／源文件不变／同名拒绝覆盖，以及两张照片的多选批量导出。

`git diff --check` 通过。第一轮完整回归发现的 Retouch 测试后端路由遗漏已修复并复跑；上述结果使用修复后的完整代码。

## 性能验收

使用同一 Sony RAW（9504 × 6336，SHA-256 `8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c`）、Release、2400 × 1600 交互代理、真实 EditingController／预览服务／AppKit 画布。计时从程序化配方提交到画布接受并返回绘制，不是物理输入到 WindowServer 呈现。

报告：`output/performance/editing-workspace-flashraw-20261121/editing-interaction-performance.json`；门禁：`comparison-summary.json`，`passed = true`。

| 场景 | 交互中位数 | 本组一次 canonical |
| --- | ---: | ---: |
| 曝光 | 16.063 ms | 1667.523 ms |
| 颜色 | 18.472 ms | 1841.930 ms |
| Texture | 23.442 ms | 3987.080 ms |
| Clarity | 32.696 ms | 4348.999 ms |
| 复合调整 | 36.622 ms | 4332.165 ms |
| 全部 36 个交互样本 | 26.132 ms | — |

首个曝光冷样本为 286.159 ms，仍计入整体统计。一次错误省略 FlashRaw 库路径的诊断运行曾使源图构建重复约 620–650 ms；分阶段日志确认原因后，该运行不作为交付性能结果。正确配置下源 RAW 在测试前后哈希一致。

Lightflow 同尺寸已有样本为曝光 6.0–17.4 ms、Texture 12.8–14.9 ms、Clarity 9.9–10.1 ms。两者计时边界不同，因此不声称严格同水平或统一百分比排名；当前结果通过项目既定绝对门槛。

### JPEG 代理复评

本轮不新增 JPEG 编辑代理。真实 RAW 的 FlashRAW 交互路径已通过现有性能门禁，引入第二套 JPEG 配方缓存会增加失效、存储与预览／导出一致性成本，尚无实测收益证明。浏览器已有缩略图策略保持不变，settled／保存／导出仍走完整显影。

## 原生窗口与安装

使用独立 `io.robinqu.RAWMaster.preview025`、隔离资料库和真实 9504 × 6336 RAW，未在正式资料库执行开发验收。

- 暗房悬浮双栏、左侧滤镜／历史入口、底部胶片和 RGB 通道显示正常；实际直方图曝光区拖拽将曝光从 0.55 调整为 1.05。
- 新建范围蒙版并在画布拖拽新建线性渐变，重启后“亮度范围 1”和“线性渐变 2”均恢复，图层参数可独立调整。
- 风景样本的 Vision 请求未检测到主体，界面给出明确提示并保留手动蒙版；这属于负向样本与降级路径验收，不宣称 AI 正向识别质量通过。
- 背景菜单选择纯黑后，独立偏好 `editing.darkroomBackground = black` 已核对。
- 导出工作台为非模态完整页面，实际显示当前照片、JPEG／TIFF／PNG、2048 预设、90% 质量、输出目录与命名模板；编辑→导出→编辑→资料库往返保持统一窗口标题和既有调整。
- 验收过程中修复了蒙版输入观察绑定和视图生命周期问题。最终版本未再出现持续“读取照片调整信息”，也未再出现蒙版完整渲染的 980 MB 瓦片错误。非主体蒙版使用 1×1 占位采样源，不再声明整帧第二依赖。

截图：`output/acceptance/editing-workspace-20261121/editing-final.jpg`、`export-workspace.jpg`。

最终 Release 构建版本为 27.0，`output/RAWMaster.app` 与 `/Applications/RAWMaster.app` 均通过 `codesign --verify --deep --strict`。两处二进制 SHA-256 均为 `d6ecefde42e15ad8fe1c08fab93972812a7f7be32f48921b6a1892f47e9a1d88`。隔离验收包因使用独立 bundle ID 重新签名，哈希不与正式包混用。

旧版 26.0、偏好和资料库备份保存在 `output/acceptance/editing-workspace-20261121/pre-install-backup/`。安装前正式应用未运行；安装后未启动正式资料库做开发写入。
