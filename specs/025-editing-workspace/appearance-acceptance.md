# 编辑外观与后台信息的原生验收

2026-11-27 在源码提交 `72787d04` 的签名 Release 中使用仓库实拍 Sony ARW 复验。正常入口是资料库选片、打开「编辑」、在基础调整区选择外观。032 从编辑或资料库接收当前配方。独立测试资料库使用同一原片的只读引用与独立导出目录。[交互原型与浏览器记录](appearance-activity.md) · [签名、窗口与文件回执](evidence/appearance-activity/release-acceptance.json)

| 操作 | 原生观察 |
| --- | --- |
| 打开照片，从快照标题的更多菜单进入已有编辑结果，返回编辑 | 主检查器直接显示常用工具。工作表内可以单独预览原图、候选和归档成片。只有原片时说明当前没有已保存结果。查看和关闭保留草稿。旧结果可用同一份冻结输入分别取得预览和导出；离线归档 PNG 通过实文件核验。[有旧结果的工作表](evidence/appearance-activity/release-saved-results.webp) · [仅有原片时](evidence/appearance-activity/release-saved-empty.webp) |
| 在 60 MP 照片上点 HDR，再点 B&W、HDR | 一次点击应用，右侧沿用调色导航、左右栏和示波器。当前图的 SDR 白点为 100 nits，可设置 HDR 高光上限、预览和调整 SDR 派生。命名快照可在 HDR 内恢复，并通过历史撤销。冷启动重新读回 SDR、黑白与 HDR 的往返另用 24 MP 雪景验证。[HDR 编辑](evidence/appearance-activity/release-hdr.webp) · [参数与算子支持范围](../037-color-film-hdr/evidence/appearance-roundtrip-20261127.md) |
| 观看普通提示，迅速切换外观，手动关闭新提示，再从主窗波形及窗口菜单打开后台信息 | 画布至多一条。SimpleToast 的普通／错误时限是 3.5 秒／6 秒，旧回调只关闭匹配的消息。通知页仍列出手动关闭和超时的消息及所属照片。任务页读到真实交付状态和明细，日志页可核对实际的启动、打开资料库及交付记录。[画布提示](evidence/appearance-activity/release-toast.webp) · [通知历史](evidence/appearance-activity/release-notices.webp) · [任务](evidence/appearance-activity/release-tasks.webp) · [应用日志](evidence/appearance-activity/release-logs.webp) |
| 弹出后台窗口并返回取样完成的 SDR 照片，在 HDR 下切换直方图与矢量示波器 | SDR 绘图区同一区域前后的 RGB 字节摘要相同。原生异步测试记录采样请求数，失焦和重获焦点会保留现有结果，像素编辑造成的过期测量不能替换新图。分别读取两幅图的 AX 绘图边界，高度均为 96 pt。[矢量示波器](evidence/appearance-activity/release-vectorscope.webp) |
| 在编辑中直接导出全尺寸 SDR JPEG、再核对和导出 PQ AVIF，重开库和文件 | 两个批次指向同一份冻结 HDR 输入。当前采用的仍是原片，候选数为零。核对库内清单、图执行回执、成片字节 SHA-256 之后，独立解码两张 9504 × 6336 成片。JPEG 为 8 位 sRGB，AVIF 为 10 位、全范围 Rec.2020/PQ。直接导出和 032 批处理分别覆盖发布中断后的回执恢复。[逐项指标](evidence/appearance-activity/release-acceptance.json) |

实拍文件的 SHA-256 为 `7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89`。界面截图用于核对布局；EDR 状态和实际色彩信号分别读取 Metal drawable 与成片编码。绝对亮度校准、其它传感器准入和旧显影算子的完整迁移仍按各自的产品验收推进。[联合验收](../035-portable-processing-cores/roadmap.md) · [虚拟副本与命名快照](virtual-copies.md)

同源原生回归共 191 项，190 项通过，0 项失败。局部修复的空格平移／文本输入优先级用例单独重跑时，WindowServer 也未将 XCTest 宿主置于前台，该项记录为跳过。此次窗口失焦、回焦、关闭通知、切换两种示波器和返回调色均另在实际签名应用中验证。浏览器工作台 60 项和本轮 8 项专项全部通过。
