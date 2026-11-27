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
                Text("交付设置").font(AppDesign.Typography.sectionTitle)
                AppTabs(title: "交付内容", selection: $values.mode, options: ["render", "original"],
                        label: { $0 == "render" ? "成片" : "原件与清单" })
                    .accessibilityIdentifier("export.workspace.mode")
                if values.mode == "render" {
                    if EditingController.sceneReviewEnabled {
                        FlatExportMenu(title: "成片目标", selection: $values.pqDelivery, options: [false, true], label: { $0 ? "HDR 成片" : "现有 SDR 格式" }).accessibilityIdentifier("export.workspace.sceneTarget")
                    }
                    if values.pqDelivery { pqControls } else { renderControls }
                } else { originalControls }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var renderControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("格式与大小").font(.subheadline.weight(.semibold))
            FlatExportMenu(title: "文件格式", selection: $values.configuration.format,
                           options: [.jpeg8, .png16, .tiff16], label: {
                switch $0 {
                case .jpeg8: "JPEG · 8 位"
                case .png16: "PNG · 16 位"
                case .tiff16: "TIFF · 16 位"
                case .avif10: "AVIF · 10 位"
                }
            }).accessibilityIdentifier("export.workspace.format")
            FlatExportMenu(title: "长边", selection: $values.sizeChoice, options: [0, 1080, 1350, 2048, 4096, -1], label: { size in
                switch size {
                case 0: "原始尺寸"
                case -1: "自定长边"
                default: "\(size) px"
                }
            })
            if values.sizeChoice == -1 {
                HStack {
                    Text("像素")
                    AppNumberField(title: "自定长边像素", value: Binding(get: { Double(values.customLongEdge) },
                        set: { values.customLongEdge = Int($0) }), range: 64...100_000,
                        fractionDigits: 0, integrated: true, requiresInteger: true)
                        .padding(.horizontal, AppDesign.Spacing.inline)
                        .frame(height: AppDesign.Metric.rowHeight)
                        .background(AppDesign.fill(.rest), in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
                        .accessibilityIdentifier("export.workspace.longEdge")
                }
            }
            if values.configuration.format == .jpeg8 {
                AppSliderRow(title: "质量", value: $values.configuration.jpegQuality, range: 0.05...1, step: 0.01,
                             identifier: "export.workspace.quality", sliderLabel: "JPEG 质量",
                             readout: values.configuration.jpegQuality.formatted(.percent.precision(.fractionLength(0)))) {
                    values.configuration.jpegQuality = $0
                }
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
                FlatExportMenu(title: "写入", selection: $values.configuration.metadataPolicy, options: [.none, .rights, .photo], label: {
                    switch $0 {
                    case .none: "移除拍摄信息"
                    case .rights: "仅版权"
                    case .photo: "拍摄信息与版权"
                    }
                })
                if values.configuration.metadataPolicy == .photo {
                    Toggle("包含 GPS 位置", isOn: $values.configuration.includeGPS).toggleStyle(AppFlatCheckboxStyle())
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
            Text("HDR 成片使用本次冻结的场景母版。此处显示 SDR 代理。")
        }.font(.caption)
        Divider()
        namingControls
    }

    private var namingControls: some View {
        DisclosureGroup("文件命名", isExpanded: $showNaming) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("命名模板", text: $values.namingTemplate).textFieldStyle(.roundedBorder)
                Text("{name} 原名或原名-副本名　{index} 序号\n{date} 导出日　{captureDate} 拍摄日")
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
                FlatExportMenu(title: "重名", selection: $values.collision, options: ["rename", "skip"], label: { $0 == "rename" ? "保留两份" : "跳过" })
            }.padding(.top, 7)
        }
    }

    @ViewBuilder private var originalControls: some View {
        FlatExportMenu(title: "交付方式", selection: $values.copyMode, options: ["files", "manifest"], label: { $0 == "files" ? "原文件与清单" : "仅清单" })
        if values.copyMode == "files" {
            FlatExportMenu(title: "文件类型", selection: $values.originalFormats, options: ExportFormats.allCases, label: { $0.title })
            Text("复制勾选范围内符合类型的原文件，保留拍摄时的字节、文件名和目录关系。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Label("CSV 和 JSON 清单", systemImage: "list.bullet.rectangle")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct FlatExportMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: AppDesign.Spacing.inline) {
            Text(title).font(AppDesign.Typography.rowTitle)
            AppMenu(title: title, selection: $selection, options: options, label: label)
                .frame(minHeight: AppDesign.Metric.rowHeight)
        }
    }
}
