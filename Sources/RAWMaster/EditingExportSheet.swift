import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterCore
import RAWMasterImaging

struct EditingExportSheet: View {
    @ObservedObject var editing: EditingController
    @State private var format = PhotoRenderFormat.jpeg8
    @State private var exporting = false
    @State private var receipt: RenderedPhoto?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("导出成片").font(.title2.weight(.semibold)); Spacer(); Button("完成") { editing.showExport = false }.disabled(exporting).keyboardShortcut(.cancelAction) }
            if let version = editing.versions.first(where: { $0.id == editing.exportVersionID }) {
                Picker("导出版本", selection: $editing.exportVersionID) {
                    ForEach(editing.versions) { item in
                        Text((item.id == editing.work?.adoptedVersionID ? "当前采用 · " : "") + item.editingTitle + " · " + item.shortID).tag(Optional(item.id))
                    }
                }.disabled(exporting).accessibilityIdentifier("editing.export.version")
                Text(version.id == editing.work?.adoptedVersionID ? "当前采用版本" : "明确选择的版本（尚未采用也可导出）").font(.caption).foregroundStyle(.secondary)
                if let artifact = version.artifact {
                    LabeledContent("源图像", value: "\(artifact.pixelWidth) × \(artifact.pixelHeight) 像素")
                    if !artifact.resamplingChain.isEmpty { Text("此版本已重采样：" + artifact.resamplingChain.joined(separator: " → ")).font(.caption).foregroundStyle(AppPalette.warning) }
                } else { Text("使用保存的显影配方与原片计算裁切后尺寸。").font(.caption).foregroundStyle(.secondary) }
                Picker("格式", selection: $format) {
                    Text("JPEG · 8 位").tag(PhotoRenderFormat.jpeg8)
                    Text("TIFF · 16 位容器").tag(PhotoRenderFormat.tiff16)
                }.pickerStyle(.radioGroup).disabled(exporting)
                LabeledContent("色彩", value: "sRGB · 嵌入 ICC")
                LabeledContent("尺寸", value: "此版本实际像素 · 不放大")
                Text(format == .jpeg8 ? "JPEG 的透明区域合成到白色背景。" : "TIFF 保留透明通道；16 位容器不会恢复 AI 或外部图像已有的位深。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("导出独立成片文件；同名文件不会被覆盖。复制原始文件请使用“更多”中的“复制原文件”。导出记录保留在制作任务中，重启后仍可核对。").font(.caption).foregroundStyle(.secondary)
                if exporting { ProgressView("正在渲染并保存…").controlSize(.small) }
                if let receipt {
                    Label("已保存 \(receipt.artifact.pixelWidth) × \(receipt.artifact.pixelHeight) · \(receipt.artifact.bitDepth) 位 · \(receipt.artifact.colorSpace)", systemImage: "checkmark.circle.fill").foregroundStyle(AppPalette.keep).font(.caption)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([receipt.fileURL]) }
                }
                if let error { Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
                HStack { Spacer(); Button(exporting ? "正在导出…" : "选择位置并导出…") { export(version) }.buttonStyle(.borderedProminent).disabled(exporting || version.artifact == nil && !editing.sourceReady).accessibilityIdentifier("editing.export.confirm") }
            } else { Text("所选版本已不可用，请关闭后重新选择。").foregroundStyle(.secondary) }
        }.padding(24).frame(width: 520).background(AppPalette.panel).interactiveDismissDisabled(exporting)
            .onChange(of: editing.exportVersionID) { _, _ in if !exporting { receipt = nil; error = nil } }
    }
    private func export(_ version: EditingVersion) {
        guard let work = editing.work, work.id == version.workID else { return }
        let selectedFormat = format
        let panel = NSSavePanel(); panel.title = "导出成片"; panel.canCreateDirectories = true
        panel.allowedContentTypes = selectedFormat == .jpeg8 ? [.jpeg] : [.tiff]
        let stem = URL(fileURLWithPath: editing.asset?.filename ?? "photo").deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = stem + "-" + version.shortID + (selectedFormat == .jpeg8 ? ".jpg" : ".tiff")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true; receipt = nil; error = nil
        Task {
            do {
                receipt = try await editing.exportVersion(version, destination: destination, format: selectedFormat)
            } catch { self.error = "导出未完成：\(error.localizedDescription)。原有文件不会被覆盖。" }
            exporting = false
        }
    }
}
