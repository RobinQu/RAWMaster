# 工作台交互验收

2026-10-25。测试和原生验收使用隔离资料库及独立应用标识；原片与正常资料库不作为开发测试目标。

## 已完成验证

- 全量 `swift test --jobs 4`：449项，10项按原有环境条件跳过，0失败；`output/validation/009-workbench-views/full-tests.log`。
- 追加实际精确导出测试后的定向27项通过；首次新增断言只因macOS `/var` 与 `/private/var` URL别名失败，改为双方解析符号链接后通过。产品复制与清单范围没有失败。保留首次日志和通过日志。
- 实际单JPEG导出在both/allOriginals两种格式下均仅复制JPEG，JSON与CSV仅该文件；不含关联RAW、其他保留照片，复制字节一致。工作副本测试覆盖只读原片、符号链接、不同副本与原片独立。
- 真实窗口：网格搜索常显且首次不抢焦点；点击展开；标签即时筛选；⌘F输入和字段Escape收起保留条件；右侧信息保持可用；空结果仍可清除；日期字段可用。
- 真实窗口：多选浮动栏、2张批量导出默认范围、序列创建用途（连拍/延时/HDR等）、选择RAW+JPG后关联按钮启用；单张只导出当前文件，提供Photoshop和其他编辑器菜单。
- 真实窗口：网格无底部胶片条，单张有，比较无；对比侧栏提供候选及三种模式；QA01+QA03点QA02后变为QA01+QA02，保留参照；EXIF读取实际快门等信息，直方图显示实际曲线和共同峰值。
- 原生截图工具产生2960×1880画布中含白边的截图，不能据此宣称1100×720原生窗口验收。使用可选 `WorkbenchLayoutCaptureTests` 直接挂载工作台得到精确1100×720逻辑尺寸、2200×1440像素的浅/深色布局截图及尺寸JSON；它不覆盖标题栏或WindowServer呈现性能。
- EXIF初次打开曾从中间显示，已设置topLeading默认锚点与按模式重建，布局截图确认文件头部可见。异常/极小快门数值改为安全格式化，避免整数转换溢出。

## 文件与证据

实现：`Sources/RAWMaster/{WorkbenchView,SearchReviewViews,ComparisonViews,WorkbenchActions,AppModel,WorkflowSheets,RAWMasterApp}.swift`。
测试：`Tests/RAWMasterUITests/{ComparisonWorkflowTests,WorkbenchActionTests,WorkbenchLayoutCaptureTests,ProjectReviewUITests}.swift`。
证据目录：`output/validation/009-workbench-views/`，其中`layout1100/`含6张明暗布局截图。

## 最终复核

- 最新29项增量测试全部通过（5比较、19项目精筛、4工作台动作、1布局），含新增极小/非有限EXIF快门数值测试及精确导出复制/CSV/JSON实测；`final-directed-tests.log`。原有全量449项结果仍保留，不将重复执行计为新增用例。
- 最终`layout1100-final/`六张浅/深色截图均经设计复核：筛选条件可内部滚动，日期与长名称可读，浮动栏清晰；EXIF从头开始且行对齐；两张直方图在540pt中央区域完整并排，说明换行，三张以上可横向滚动。源数据与共同刻度保持一致。
- 独立代码审查通过，未发现阻塞项；最终视觉审查通过。
- 本轮新增生产代码不修改Core/Imaging或序列算法；现有未提交功能均保留。原片和库数据未用于测试写入。

## Release 与安装

最终Release重建成功，应用图标/资源检查与深度严格签名校验通过；`final-release-build.log`。最终Release的独立QA副本再次检查：真实DNG/JPG的EXIF格式/大小/快门/光圈/ISO来源各自正确，初始滚动位置为0；两张实际直方图共同峰值5.4%，正常显示。截图`release-compare-metadata-native.jpg`与`release-compare-histogram-native.jpg`。

已更新安装到`/Users/robinqu/Applications/RAWMaster.app`，收据`output/installation/009-workbench-views-20261025-135135/install-report.json`。安装包与最终Release逐文件一致、签名复核成功。旧应用、资料库一致备份、偏好快照均保留。安装前后资料库主文件/WAL及偏好核对一致；可重建SHM读者索引不算业务数据。安装先正常退出旧应用，未中断运行任务。

安装后正常重新打开正式应用，恢复原项目、4张对比选择与焦点；观察到新的三模式侧栏、全局导入按钮和相应工具栏，比较模式无胶片条。没有在正式资料库执行开发测试或选片/分组/导出写入；正常启动/退出产生的浏览状态保存属于原应用行为。没有提交或推送仓库变更。
