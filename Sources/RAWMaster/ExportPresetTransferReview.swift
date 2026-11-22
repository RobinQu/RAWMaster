import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct ExportPresetTransfer: Identifiable {
    let id = UUID()
    let preset: PhotoExportPreset
    var sharing = false
}

struct ExportPresetTransferReview: View {
    let transfer: ExportPresetTransfer
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preset = transfer.preset
        let config = preset.configuration
        let appearance = config.layout.resolvedAppearance
        let render = preset.mode == "render"
        let signatureActive = render && ["signature", "both"].contains(appearance.mark)
        let logoActive = render && appearance.mark != "off"
        VStack(alignment: .leading, spacing: 15) {
            Text(transfer.sharing ? "分享当前导出预设" : "导入导出预设").font(.title2.weight(.semibold))
            Text(preset.name).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                row("交付", render ? "成片 · " + config.format.filenameExtension.uppercased() : (preset.copyMode == "manifest" ? "仅清单" : "原件与清单"))
                if render {
                    row("尺寸", config.maximumLongEdge.map { "长边 \($0) px" } ?? "原始尺寸")
                }
                row(render ? "命名" : "成片命名", preset.namingTemplate)
                row("版式", config.layout.style.exportTitle)
                row("题注位置", (appearance.place == "footer" ? "底部留白" : "照片内") + " · " +
                    (ExportLayoutControls.anchors.first { $0.0 == appearance.anchor }?.1 ?? appearance.anchor))
                if !render {
                    row("原件元数据", preset.copyMode == "manifest" ? "只交付清单" : "按原字节复制，保留已有拍摄信息与 GPS")
                }
                row("成片元数据", metadataName(config.metadataPolicy))
                row("成片 GPS", config.metadataPolicy == .photo && config.includeGPS ? "随成片写入" :
                    (config.includeGPS ? "当前元数据策略关闭，预设保存了 GPS 开关" : "不写入"))
                row("署名", appearance.signature.isEmpty ? "未设置" :
                    appearance.signature + (signatureActive ? "（印在照片上）" : "（当前关闭，保存在预设中）"))
                GridRow {
                    Text("Logo").foregroundStyle(.secondary)
                    if let logo = appearance.logo, let bytes = Data(base64Encoded: logo.base64), let image = NSImage(data: bytes) {
                        HStack(spacing: 8) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 45, height: 30)
                            Text(logoActive ? "内嵌图像，随水印绘制" : "内嵌图像，当前关闭")
                        }
                    } else { Text("未包含") }
                }
            }.font(.callout).textSelection(.enabled)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(transfer.sharing ? "选取文件位置…" : "导入并使用") { onConfirm(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(transfer.sharing ? "export.workspace.preset.share.confirm" : "export.workspace.preset.import.confirm")
            }
        }.padding(20).frame(width: 460)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value) }
    }

    private func metadataName(_ policy: PhotoExportMetadataPolicy) -> String {
        switch policy {
        case .none: "移除拍摄信息"
        case .rights: "仅版权"
        case .photo: "拍摄信息与版权"
        }
    }
}

struct ExportPresetNameEditor: View {
    let used: [String]
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var issue: String?

    init(suggested: String, used: [String], onSave: @escaping (String) throws -> Void) {
        _name = State(initialValue: suggested)
        self.used = used
        self.onSave = onSave
    }

    var body: some View {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = used.contains { $0.localizedCaseInsensitiveCompare(clean) == .orderedSame }
        VStack(alignment: .leading, spacing: 14) {
            Text("新建导出预设").font(.title3.weight(.semibold))
            TextField("预设名称", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("export.workspace.preset.name")
            if duplicate || clean.utf16.count > 70 || issue != nil {
                Text(duplicate ? "该名称已使用。" : (issue ?? "预设名称最多 70 个字符。"))
                    .font(.caption).foregroundStyle(AppPalette.warning)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try onSave(clean); dismiss() }
                    catch { issue = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("export.workspace.preset.save")
                    .disabled(clean.isEmpty || clean.utf16.count > 70 || duplicate)
            }
        }.padding(20).frame(width: 360)
    }
}
