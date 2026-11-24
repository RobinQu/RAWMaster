import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterCore
import RAWMasterImaging

struct ExportWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var values = ExportWorkspaceSettings()
    @State private var basePreset = ExportWorkspacePresetChoice.builtins[0]
    @State private var personal: [ExportWorkspacePresetChoice] = []
    @State private var lastPreset: ExportWorkspacePresetChoice?
    @State private var newPreset: PresetNameDraft?
    @State private var transfer: ExportPresetTransfer?
    @State private var pendingShare: PhotoExportPreset?
    @State private var styleDraft: StyleDraft?
    @State private var selection = ExportWorkspaceSelection()
    @State private var preview: ExportPreviewPhoto?
    @State private var previewProblem: String?
    @State private var message: String?
    @State private var grantedDirectory: URL?
    @State private var showingDeliveryDetails = false
    @FocusState private var deliveryDetailsFocused: Bool
    @AppStorage private var directoryPath: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RAWMaster Exports", isDirectory: true)
        _directoryPath = AppStorage(wrappedValue: initialDirectory.path, "rawmaster.export.workspace.destination.v1", store: defaults)
    }

    private var allPresets: [ExportWorkspacePresetChoice] { ExportWorkspacePresetChoice.builtins + personal }
    private var running: Bool { model.workbenchPhotoDelivery?.running == true }
    private var modified: Bool { values != basePreset.settings }
    private var checked: Set<String> { selection.checked }
    private var directory: URL {
        if let grantedDirectory, directoryPath == grantedDirectory.path { return grantedDirectory }
        return URL(fileURLWithPath: directoryPath, isDirectory: true)
    }
    private var currentPreview: ExportPreviewPhoto? {
        guard let preview, preview.assetID == selection.focusedID, preview.original == (values.mode == "original") else { return nil }
        return preview
    }
    private var previewMaximum: Int { min(1040, max(1, values.resolvedConfiguration.maximumLongEdge ?? 1040)) }

    private struct PresetNameDraft: Identifiable {
        let id = UUID()
        let suggested: String
        let settings: ExportWorkspaceSettings
    }

    private struct StyleDraft: Identifiable {
        let id = UUID()
        let layout: PhotoExportLayout
    }

    var body: some View {
        let assets = running && model.workbenchPhotoDelivery?.resumedCount == nil
            ? (model.workbenchPhotoDelivery?.assets ?? []) : model.workbenchExportCandidates
        let inspected = assets.first { $0.id == selection.focusedID }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ExportAssetChecklist(assets: assets, limit: AppModel.maximumWorkbenchExportCount,
                                     checked: $selection.checked, focused: $selection.focusedID)
                    .frame(minWidth: 195, idealWidth: 220, maxWidth: 250)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    presetsBar
                    Divider()
                    inspection(inspected)
                }.frame(maxWidth: .infinity)
                Divider()
                ExportWorkspaceInspector(values: $values, photo: currentPreview,
                                         firstAsset: assets.first(where: { checked.contains($0.id) }),
                                         openStyles: editStyles)
                    .frame(width: 250)
            }.disabled(running)
            Divider()
            if let notice = message ?? model.workbenchPhotoDelivery?.message {
                HStack {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button {
                        if message != nil { message = nil }
                        else { model.workbenchPhotoDelivery?.message = nil }
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.padding(.horizontal, 16).padding(.vertical, 6)
                Divider()
            }
            footer(assets)
        }
        .onAppear { loadPresets() }
        .onChange(of: model.requestedWorkbenchExportMode, initial: true) { _, requested in
            if let requested {
                values.mode = requested.rawValue
                model.requestedWorkbenchExportMode = nil
            }
        }
        .onChange(of: assets.map(\.id), initial: true) { _, ids in selection.synchronize(ids) }
        .task(id: PreviewKey(id: inspected?.id, path: inspected?.resolvedURL.path, mode: values.mode)) {
            await loadPreview(inspected)
        }
        .sheet(isPresented: $showingDeliveryDetails, onDismiss: { deliveryDetailsFocused = true }) {
            WorkbenchDeliveryHistory(initial: model.workbenchPhotoDelivery?.id.uuidString.lowercased())
        }
        .sheet(item: $styleDraft) { draft in
            if let preview = currentPreview, let inspected {
                ExportWatermarkEditor(photo: preview, filename: inspected.filename, previewMaximum: previewMaximum,
                                      layout: draft.layout) {
                    values.configuration.layout = $0
                }
            }
        }
        .sheet(item: $newPreset) { draft in
            ExportPresetNameEditor(suggested: draft.suggested, used: allPresets.map(\.name)) { name in
                try save(draft.settings.portable(named: name))
            }
        }
        .sheet(item: $transfer, onDismiss: {
            if let pendingShare {
                self.pendingShare = nil
                writeSharedPreset(pendingShare)
            }
        }) { item in
            ExportPresetTransferReview(transfer: item) {
                if item.sharing { pendingShare = item.preset } else { acceptImport(item.preset) }
            }
        }
    }

    private var presetsBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("导出预设").font(.headline)
            HStack(spacing: 8) {
                Menu {
                    Button("上次设置") { if let lastPreset { apply(lastPreset) } }.disabled(lastPreset == nil)
                    Divider()
                    ForEach(ExportWorkspacePresetChoice.builtins) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                    if !personal.isEmpty {
                        Divider()
                        ForEach(personal) { preset in Button(preset.name) { apply(preset) } }
                    }
                } label: {
                    Label(basePreset.name + (modified ? " · 已修改" : ""), systemImage: "slider.horizontal.3")
                        .lineLimit(1)
                }
                .accessibilityLabel("切换导出预设").accessibilityIdentifier("export.workspace.presets")
                Button {
                    newPreset = PresetNameDraft(suggested: proposedName(basePreset.name + " 副本"), settings: values)
                } label: { Label("新建预设", systemImage: "plus") }
                    .accessibilityIdentifier("export.workspace.preset.new")
                Menu {
                    Button("导入预设文件…", action: importPreset)
                    Button("分享当前设置为文件…", action: sharePreset)
                } label: { Image(systemName: "square.and.arrow.up") }
                    .fixedSize().accessibilityLabel("导入或分享预设")
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private func inspection(_ asset: AssetRecord?) -> some View {
        if let asset {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(asset.filename).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(values.mode == "render" ? "成片预览" : "原件预览")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .underPageBackgroundColor))
                    if let preview = currentPreview {
                        if values.mode == "render" {
                            ExportStyledPhoto(photo: preview, layout: values.configuration.layout, maximum: previewMaximum)
                                .padding(14)
                        } else {
                            Image(decorative: preview.image, scale: 1).resizable().scaledToFit().padding(14)
                        }
                    } else if let previewProblem {
                        ContentUnavailableView("预览不可用", systemImage: "photo.badge.exclamationmark",
                                               description: Text(previewProblem))
                    } else {
                        ProgressView("读取照片…").font(.caption)
                    }
                }
                if values.mode == "render" {
                    HStack {
                        Label(values.configuration.layout.style.exportTitle, systemImage: "rectangle.inset.filled")
                        Spacer()
                        Button("编辑边框与水印…") { editStyles(values.configuration.layout) }.disabled(currentPreview == nil)
                            .accessibilityIdentifier("export.workspace.watermark")
                    }.font(.caption)
                }
            }.padding(15).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("暂无照片", systemImage: "photo.on.rectangle.angled",
                                   description: Text("从资料库选择要导出的照片。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func footer(_ assets: [AssetRecord]) -> some View {
        let delivery = model.workbenchPhotoDelivery
        let displayedDirectory = running ? (delivery?.directory ?? directory) : directory
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("输出目录").font(.caption).foregroundStyle(.secondary)
                Button { chooseDirectory() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(displayedDirectory.path).font(.callout).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }.buttonStyle(.plain).disabled(running).help(displayedDirectory.path)
                    .accessibilityIdentifier("export.workspace.destination")
            }
            Spacer()
            Button("任务详情") { showingDeliveryDetails = true }
                .focused($deliveryDetailsFocused)
                .accessibilityIdentifier("export.workspace.deliveryDetails")
            if let delivery, delivery.running {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: Double(delivery.completed), total: Double(max(1, delivery.total))).frame(width: 120)
                    Text("\(delivery.completed)/\(delivery.total) · \(delivery.currentName)").font(.caption2).lineLimit(1)
                    Text("可返回编辑，交付继续").font(.caption2).foregroundStyle(.secondary)
                }
                Button("取消导出") { Task { await model.cancelWorkbenchPhotoDelivery() } }
            } else {
                if let results = delivery?.files, !results.isEmpty {
                    Button("在 Finder 显示 \(results.count) 个文件") {
                        NSWorkspace.shared.activateFileViewerSelecting(results)
                    }.font(.caption).buttonStyle(.link)
                }
                if checked.count > AppModel.maximumWorkbenchExportCount {
                    Text("超出单批上限").font(.caption).foregroundStyle(AppPalette.warning)
                }
                let original = values.mode == "original"
                let label = original ? (values.copyMode == "manifest" ? "导出所选清单" : "交付原件") : "导出成片"
                Button("\(label)（\(checked.count)）") { submit(assets) }
                    .buttonStyle(.borderedProminent)
                    .disabled(checked.isEmpty || checked.count > AppModel.maximumWorkbenchExportCount || model.isBusy)
                    .accessibilityIdentifier("export.workspace.confirm")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private struct PreviewKey: Equatable { let id: String?; let path: String?; let mode: String }

    private func loadPreview(_ asset: AssetRecord?) async {
        preview = nil
        previewProblem = nil
        guard let asset else { return }
        let original = values.mode == "original"
        do {
            let image: CGImage
            let metadata: PhotoExportMetadata
            if original {
                let nsImage = try await ImagePipeline.shared.preview(at: asset.resolvedURL, maxPixel: 1040)
                guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DevelopmentError.unreadable }
                image = cgImage
                metadata = await Task.detached(priority: .utility) { PhotoExportMetadata.read(from: asset.resolvedURL) }.value
            } else {
                (image, metadata) = try await model.workbenchExportPreview(for: asset, maxPixel: 1040)
            }
            guard !Task.isCancelled else { return }
            preview = ExportPreviewPhoto(assetID: asset.id, original: original, image: image, metadata: metadata)
        } catch {
            if !Task.isCancelled { previewProblem = error.localizedDescription }
        }
    }

    private func apply(_ preset: ExportWorkspacePresetChoice) {
        basePreset = preset
        values = preset.settings
        message = nil
    }

    private func editStyles(_ layout: PhotoExportLayout) {
        styleDraft = StyleDraft(layout: layout)
    }

    private func loadPresets() {
        do {
            let records = try ExportWorkspacePresetLibrary.records(in: defaults)
            personal = records.compactMap { try? $0.choice() }
            lastPreset = try ExportWorkspacePresetLibrary.last(in: defaults)
            if personal.count < records.count { message = "部分已存预设暂时无法读取。" }
        } catch { message = error.localizedDescription }
    }

    private func proposedName(_ suggested: String) -> String {
        ExportWorkspacePresetLibrary.availableName(suggested, among: allPresets)
    }

    private func save(_ preset: PhotoExportPreset, importedName: String? = nil) throws {
        let choice = try ExportWorkspacePresetLibrary.append(preset, importedName: importedName, to: defaults)
        personal.append(choice)
        apply(choice)
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
            transfer = ExportPresetTransfer(preset: try PhotoExportPreset.read(data))
        } catch { message = "导入预设失败。\(error.localizedDescription)" }
    }

    private func acceptImport(_ preset: PhotoExportPreset) {
        do {
            loadPresets()
            if let existing = try ExportWorkspacePresetLibrary.matching(preset, among: allPresets) {
                apply(existing)
                message = "已使用现有同名预设。"
                return
            }
            let name = proposedName(preset.name)
            try save(ExportWorkspaceSettings(preset: preset).portable(named: name), importedName: preset.name)
            message = "已导入「\(name)」。"
        } catch { message = "导入预设失败。\(error.localizedDescription)" }
    }

    private func sharePreset() {
        let preset = values.portable(named: basePreset.name)
        do {
            _ = try preset.fileData()
            transfer = ExportPresetTransfer(preset: preset, sharing: true)
        } catch { message = "分享预设失败。\(error.localizedDescription)" }
    }

    private func writeSharedPreset(_ preset: PhotoExportPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = preset.name.replacingOccurrences(of: "/", with: "-") + ".rmexport.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preset.fileData().write(to: url, options: .atomic)
            message = "预设已保存为 \(url.lastPathComponent)。"
        }
        catch { message = "分享预设失败。\(error.localizedDescription)" }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            grantedDirectory = url
            directoryPath = url.path
        }
    }

    private func rememberSubmission() {
        do {
            try ExportWorkspacePresetLibrary.remember(values, in: defaults)
            lastPreset = try ExportWorkspacePresetLibrary.last(in: defaults)
        } catch {
            message = "本次设置无法记为上次设置。\(error.localizedDescription)"
        }
    }

    private func submit(_ assets: [AssetRecord]) {
        let ids = assets.filter { checked.contains($0.id) }.map(\.id)
        guard !running, !ids.isEmpty, ids.count <= AppModel.maximumWorkbenchExportCount else { return }
        message = nil
        if values.mode == "original" {
            let copy = values.copyMode != "manifest"
            if copy, model.exportSelection(ids: ids, formats: values.originalFormats, exactAssetIDs: ids)?.assetIDs.isEmpty != false {
                message = "勾选的文件中没有符合交付格式的原件。"
                return
            }
            rememberSubmission()
            model.export(ids: copy ? ids : [], destination: directory.path, formats: values.originalFormats,
                         exactAssetIDs: ids, csvLayout: .photoRows)
            return
        }
        if let issue = ExportLayoutControls.issue(for: values.configuration.layout) {
            message = issue
            return
        }
        let configuration = values.resolvedConfiguration
        let destination = directory, naming = values.namingTemplate, collision = values.collision
        do { try configuration.validate() } catch { message = error.localizedDescription; return }
        rememberSubmission()
        model.submitWorkbenchPhotoDelivery(directory: destination, naming: naming, configuration: configuration,
            ids: Set(ids), collision: collision)
    }
}
