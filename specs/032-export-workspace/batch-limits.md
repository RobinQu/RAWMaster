# 本地导出一次可以选多少张

核对日期为 2026-11-22。这里的张数指一次提交的源照片数。Adobe 的依据是官方桌面帮助，AlcedoStudio 的依据是公开提交 `61d59bc98afad3be7b0d855bebdb86d7b9225e62` 的图库和导出代码。

| 产品 | 单批选片张数 | 可以确认的行为 |
| --- | --- | --- |
| Lightroom 桌面版 | 查询到的本地导出手册未公布数字上限 | 「按所选格式导出照片」支持选片后导出到本机或外置盘，按钮显示本次选中张数。该页的 65,000 是一张照片的自定义边长上限，单位为像素。[Adobe 桌面版导出手册](https://helpx.adobe.com/cn/lightroom/desktop/save-share-and-export/save-share-photos.html) |
| Lightroom Classic | 查询到的网格选片、硬盘导出手册未公布数字上限 | 可先筛选，再用 `⌘A` 全选当前视图。导出对话框顶端显示张数，同批使用多个预设时，每张照片对应各预设的一份输出。Adobe 关于目录可容纳任意数量照片的说明适用于目录容量。[网格选片](https://helpx.adobe.com/cn/lightroom-classic/desktop/viewing-photos/browse-compare-photos.html) · [硬盘与多批量导出](https://helpx.adobe.com/cn/lightroom-classic/desktop/export-photos/exporting-photos-basic-workflow.html) · [目录容量](https://helpx.adobe.com/lightroom-classic/desktop/manage-catalogs-and-files/lightroom-catalog-basics.html) |
| AlcedoStudio | 所查版本的选片、加队、提交和调度路径未设固定张数门槛 | 全选取当前筛选查询的全部唯一文件，含折叠分组和未加载缩略图的照片。导出检查器加入完整选区，按元素 ID 去重，再把整份队列交给后端；服务按实际任务数逐项调度。[全选查询](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/library_module.cpp#L229-L277) · [加队与提交](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/qml/ExportInspectorPanel.qml#L275-L292) · [收集有效目标](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/import_export.cpp#L1040-L1051) · [清空队列并逐项提交](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/app/export_service.cpp#L352-L385) |

**AlcedoStudio 界面和源码中的四个数字**

- **36 行**是检查器展开显示的照片明细数，超出的照片以「另有 N 张」表示。标题仍显示整个队列的计数。[常量](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/qml/ExportInspectorPanel.qml#L49-L51) · [可见行及余数](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/qml/ExportInspectorPanel.qml#L109-L123) · [队列标题](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/qml/ExportInspectorPanel.qml#L1067-L1075)
- **200 张**决定预览列表排序方式。至多 200 张按文件名排序，超过时沿用入队顺序。两种情况下 `Targets()` 都遍历所有条目。另有一项停用测试把样本数截到 200，约束只在测试函数内。[排序规则](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/include/ui/alcedo_main/album_backend/export_queue.hpp#L33-L53) · [实际交付队列](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/export_queue.cpp#L134-L144) · [停用测试](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/tests/app/export_service_test.cpp#L417-L451)
- **1 个活跃批次、1 个渲染执行器、4 个导出工作线程**描述同一时刻可以执行多少工作。提交先检查是否已有批次运行；队列中的照片逐张渲染，编码可与后续工作重叠。[批次准入](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/ui/alcedo_main/album_backend/import_export.cpp#L575-L586) · [渲染执行器](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/include/app/export_service.hpp#L89-L99) · [线程池](https://github.com/zidage/AlcedoStudio/blob/61d59bc98afad3be7b0d855bebdb86d7b9225e62/alcedo_studio/src/include/app/export_service.hpp#L122-L130)

## RAWMaster 的单批限制

**一批最多 200 张已勾选的输入照片。** 成片、复制原件及仅清单共用此上限。候选列表可包含 1,200 张及以上，离线照片仍占已勾选名额。生成的 CSV、JSON 和各处显示行数独立计数。这个张数是 RAWMaster 的产品约束。

201 张会显示超出一张并阻止提交。用户可自行减选，或明确保留按输入顺序排列的前 200 张已勾选照片。原生验收读回了 200 张 JPEG 和仅清单的 200 个唯一 ID。[产品规格](spec.md) · [性能基线](performance.md)
