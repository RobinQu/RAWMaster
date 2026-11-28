# 044 M1-03 · 032 保留拍摄时间

在 032 导出工作台选择「拍摄信息与版权」时，SDR JPEG 和 PNG16 继承已核验 Sony ARW 的拍摄时间。原片缺字段时沿用现有的 ImageIO 结果。对原片副本读取主 IFD 指向的标准 ExifIFD。在 ImageIO 缺少偏移或亚秒且整秒和已知伴随字段一致时，补入经严格解析的字段。导出使用原有的授权、元数据允许列表、暂存和交付回执。[032 导出规格](../032-export-workspace/spec.md) · [Exif 标准](https://www.cipa.jp/std/documents/e/CIPA_DC-X008-Translation-2016-E.pdf)

用 PIXLS.US 条目 2414 的同一张 Sony ILCE-7M3 RAW 验证，原件 SHA-256 为 `250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f`。ExifTool 13.59 从原件 ExifIFD 读取 `2018:03:13 16:38:13` 和 `+01:00`，ImageIO 的原片标签只提供前者。JPEG 把两值写入 ExifIFD，PNG16 把两值写入 XMP，原生解码均可读回。JPEG 的「仅版权」与「移除拍摄信息」两档，以及 PNG 的「移除拍摄信息」档省略拍摄时间。受测成片可解码，位深、ICC 和同格式解码后的 RGBA8 像素对照通过，GPS、机身序列号和 MakerNote 省略。取证前后原件摘要相同。[样片与许可](m0-validation.md) · [原生出片测试](../../Tests/RAWMasterImagingTests/PhotoExportLayoutTests.swift) · [文件回执](evidence/m1-032-capture-clock.json)

13 项 Release 定向测试通过。合成 ExifIFD 验证小端和大端、带前导零的 `005`、半小时偏移、截断标签，以及整秒、亚秒或偏移有冲突时的选择。真实 ARW 没有亚秒标签，实拍证据签收偏移，亚秒证据来自控制夹具。

自用 Release `20261129.004656` 已安装到 `/Applications/RAWMaster.app` 并严格验签。隔离库窗口和 SQLite 检查通过，安装前后 Metal ABI、YuNet 和 Intel 0095 回执一致。[Release 回执](evidence/m1-032-capture-clock.json)

TIFF16 的 ImageIO 元数据复制只在 XMP 输出拍摄日期，未在实际 ExifIFD 写入偏移。直接重新编码 TIFF 能写入该字段。TIFF16 采用现有的元数据复制合同，物理 EXIF 写入待另行验收。M1-03 的导入时钟、检查器、同次快门 RAW/JPEG 配对、Sony 序列字段及停止生产 Perl 调用仍待签收。
