import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct EditingSavedResultsSheet: View {
    @ObservedObject var editing: EditingController
    @EnvironmentObject private var model: AppModel
    @State private var image: CGImage?
    @State private var previewIssue: String?
    @State private var retry = 0

    private var selected: EditingVersion? {
        editing.versions.first { $0.id == editing.savedResultsSelection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已有编辑结果").font(.title2.weight(.semibold))
                Spacer()
                Button(action: editing.closeSavedResults) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("关闭")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(AppPalette.thumbnailWell)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else if let previewIssue {
                    VStack(spacing: 6) {
                        Text(previewIssue).font(.caption).multilineTextAlignment(.center)
                        if editing.sourceReady || selected?.artifact != nil {
                            Button("重试") { retry += 1 }
                        }
                    }.padding()
                } else if selected != nil {
                    ProgressView("载入预览…").controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 180)
            .accessibilityElement(children: .contain).accessibilityLabel("结果预览")
            .task(id: [editing.savedResultsSelection ?? "", String(retry)]) { await loadPreview() }
            if let selected {
                Text(selected.editingTitle + " · " + selected.shortID)
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("editing.savedResults.previewTitle")
            }
            if !editing.versions.contains(where: { $0.kind != .original }) {
                Text("当前照片还没有已保存的编辑结果。").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(editing.versions.sorted { $0.createdAt > $1.createdAt }) { version in
                        resultRow(version)
                    }
                }
            }
            Divider()
            HStack {
                Button("关联外部编辑结果…") { editing.associateExternalResult(parentID: selected?.id) }
                    .disabled(editing.saving || selected == nil)
                Spacer()
                Button("返回编辑", action: editing.closeSavedResults)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("editing.savedResults.close")
            }
        }
        .padding(20).frame(minWidth: 450, idealWidth: 530, minHeight: 380, idealHeight: 540)
        .accessibilityElement(children: .contain).accessibilityIdentifier("editing.savedResults")
    }

    private func resultRow(_ version: EditingVersion) -> some View {
        let adopted = version.id == editing.work?.adoptedVersionID
        let disposition = editing.dispositions[version.id]
        let viewable = editing.sourceReady || version.artifact != nil
        let prompt = version.configuration["quickPromptRawOutputSHA256"] != nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(version.editingTitle + " · " + version.shortID, systemImage: version.kind == .original ? "camera" : "photo")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(adopted ? "当前采用" : disposition == .discarded ? "已放弃" : disposition == .retained ? "已保留" : "候选")
                    .font(.caption).foregroundStyle(adopted ? AppPalette.keep : .secondary)
            }
            HStack {
                Button("查看") { editing.showSavedResults(version.id) }
                    .accessibilityIdentifier("editing.savedResults.view." + version.id)
                if !adopted && disposition != .discarded {
                    Button("采用此结果") { editing.adopt(version) }
                        .disabled(editing.saving || !editing.canAdoptDisplayVersion(version))
                }
                Menu("更多操作") {
                    Button("导出此结果…") {
                        model.openSavedResultExport(version)
                    }.disabled(!model.canExport || !viewable || disposition == .discarded || (prompt && editing.work?.strictDocumentary == true))
                    if !prompt {
                        Button("从此继续") { editing.closeSavedResults(); editing.continueFrom(version) }
                            .disabled(!editing.sourceReady || disposition == .discarded)
                    }
                    if !adopted && version.kind != .original {
                        Divider()
                        if disposition == .discarded {
                            Button("恢复候选") { editing.disposition(version, .candidate) }
                        } else {
                            if disposition != .retained {
                                Button("保留候选") { editing.disposition(version, .retained) }
                            }
                            Button("放弃候选") { editing.disposition(version, .discarded) }
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }.controlSize(.small)
            if selected?.id == version.id {
                if let artifact = version.artifact {
                    Text("\(artifact.pixelWidth) × \(artifact.pixelHeight) · \(artifact.bitDepth) 位 · \(artifact.colorSpace)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !version.configuration.isEmpty || version.parentVersionID != nil {
                    DisclosureGroup("来源详情") {
                        if let parent = version.parentVersionID { Text("来源 · " + String(parent.prefix(6))) }
                        ForEach(version.configuration.keys.sorted(), id: \.self) { key in
                            Text(key + " · " + (version.configuration[key] ?? ""))
                        }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(10).background(selected?.id == version.id ? AppPalette.accent.opacity(0.10) : AppPalette.thumbnailWell,
                                  in: RoundedRectangle(cornerRadius: 6))
    }

    private func loadPreview() async {
        image = nil; previewIssue = nil
        guard let work = editing.work, let selected else { return }
        guard editing.sourceReady || selected.artifact != nil else {
            previewIssue = "原片离线，找回后可查看这个结果。"
            return
        }
        do {
            let frame = try await RenderExportService().preview(work: work, version: selected, archive: editing.archive, maxPixel: 720)
            guard !Task.isCancelled, selected.id == editing.savedResultsSelection else { return }
            image = frame.image
        } catch {
            guard !Task.isCancelled, selected.id == editing.savedResultsSelection else { return }
            previewIssue = error.localizedDescription
        }
    }
}
