import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct ExportWorkspaceInspector: View {
    @Binding var values: ExportWorkspaceSettings
    let photo: ExportPreviewPhoto?
    let firstAsset: AssetRecord?
    let openStyles: (PhotoExportLayout) -> Void
    @State private var showNaming = false
    @State private var showMetadata = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("交付设置").font(.headline)
                Picker("交付内容", selection: $values.mode) {
                    Text("成片").tag("render")
                    Text("原件与清单").tag("original")
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("export.workspace.mode")
                if values.mode == "render" {
                    if EditingController.sceneReviewEnabled {
                        Picker("成片目标", selection: $values.pqDelivery) {
                            Text("现有 SDR 格式").tag(false)
                            Text("HDR 成片").tag(true)
                        }.accessibilityIdentifier("export.workspace.sceneTarget")
                    }
                    if values.pqDelivery { pqControls } else { renderControls }
                } else { originalControls }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var renderControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("格式与大小").font(.subheadline.weight(.semibold))
            Picker("文件格式", selection: $values.configuration.format) {
                Text("JPEG · 8 位").tag(PhotoRenderFormat.jpeg8)
                Text("PNG · 16 位").tag(PhotoRenderFormat.png16)
                Text("TIFF · 16 位").tag(PhotoRenderFormat.tiff16)
            }.accessibilityIdentifier("export.workspace.format")
            Picker("长边", selection: $values.sizeChoice) {
                Text("原始尺寸").tag(0)
                ForEach([1080, 1350, 2048, 4096], id: \.self) { size in
                    Text("\(size, format: .number.grouping(.never)) px").tag(size)
                }
                Text("自定长边").tag(-1)
            }
            if values.sizeChoice == -1 {
                HStack {
                    Text("像素")
                    TextField("64–100000", value: $values.customLongEdge, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if values.configuration.format == .jpeg8 {
                HStack(spacing: 6) {
                    Text("质量")
                    Slider(value: $values.configuration.jpegQuality, in: 0.05...1, step: 0.01)
                        .accessibilityLabel("JPEG 质量")
                    Text(values.configuration.jpegQuality, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }.font(.caption)
            }
            Text("sRGB · 尺寸应用于最终画布，仅缩小").font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("边框与水印").font(.subheadline.weight(.semibold))
                Spacer()
                Button("制作与调整…") { openStyles(values.configuration.layout) }
                    .buttonStyle(.link).font(.caption).disabled(photo == nil)
                    .accessibilityIdentifier("export.workspace.style.edit")
            }
            if let photo {
                ExportStyleCards(photo: photo, layout: values.configuration.layout, compact: true, identifier: "export.workspace.style.") { style in
                    let next = ExportLayoutControls.choosing(style, for: values.configuration.layout)
                    if ExportLayoutControls.issue(for: next) != nil { openStyles(next) }
                    else { values.configuration.layout = next }
                }
            } else {
                Text(values.configuration.layout.style.exportTitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        Divider()
        namingControls
        Divider()
        DisclosureGroup("文件元数据", isExpanded: $showMetadata) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("写入", selection: $values.configuration.metadataPolicy) {
                    Text("移除拍摄信息").tag(PhotoExportMetadataPolicy.none)
                    Text("仅版权").tag(PhotoExportMetadataPolicy.rights)
                    Text("拍摄信息与版权").tag(PhotoExportMetadataPolicy.photo)
                }
                if values.configuration.metadataPolicy == .photo {
                    Toggle("包含 GPS 位置", isOn: $values.configuration.includeGPS)
                }
                Text("画面上的题注由边框与水印决定。").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 7)
        }
    }

    @ViewBuilder private var pqControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AVIF · 10 位 Rec.2020 PQ").font(.subheadline.weight(.semibold))
            Text("参考白 100 nits · 输出峰值 1000 nits")
            Text("版本全尺寸；此阶段不加边框水印，不写入原片描述性元数据。")
            Text("仅已保存的 HDR 母版可交付。预览为 SDR 代理；可移植预设保留 SDR 设置。")
        }.font(.caption)
        Divider()
        namingControls
    }

    private var namingControls: some View {
        DisclosureGroup("文件命名", isExpanded: $showNaming) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("命名模板", text: $values.namingTemplate).textFieldStyle(.roundedBorder)
                Text("{name} 原名　{index} 序号\n{date} 导出日　{captureDate} 拍摄日")
                    .font(.caption).foregroundStyle(.secondary)
                if let asset = firstAsset {
                    switch Result(catching: { try PhotoExportFilename.stem(for: asset, ordinal: 1,
                            template: values.namingTemplate, exportDate: Date()) }) {
                    case .success(let stem):
                        Text("示例　" + stem + "." + values.resolvedConfiguration.format.filenameExtension)
                            .font(.caption).lineLimit(2).textSelection(.enabled)
                    case .failure(let error):
                        Text(error.localizedDescription).font(.caption).foregroundStyle(AppPalette.warning)
                    }
                }
                Picker("重名", selection: $values.collision) {
                    Text("保留两份").tag("rename")
                    Text("跳过").tag("skip")
                }
            }.padding(.top, 7)
        }
    }

    @ViewBuilder private var originalControls: some View {
        Picker("交付方式", selection: $values.copyMode) {
            Text("原文件与清单").tag("files")
            Text("仅清单").tag("manifest")
        }
        if values.copyMode == "files" {
            Picker("文件类型", selection: $values.originalFormats) {
                ForEach(ExportFormats.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("复制勾选范围内符合类型的原文件，保留拍摄时的字节、文件名和目录关系。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Label("CSV 和 JSON 清单", systemImage: "list.bullet.rectangle")
            .font(.caption).foregroundStyle(.secondary)
    }
}
