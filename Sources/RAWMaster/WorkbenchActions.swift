import AppKit
import Foundation
import UniformTypeIdentifiers
import RAWMasterCore

/// Export intent captures the explicit selection before presenting the sheet.
enum WorkbenchExportContext: Equatable {
    case project
    case selection(ids: [String])
    case photo(id: String)

    var exactAssetIDs: [String]? {
        switch self { case .project: return nil; case .selection(let ids): return ids; case .photo(let id): return [id] }
    }
    var isPhoto: Bool { if case .photo = self { return true }; return false }
    var title: String {
        switch self { case .project: return "导出项目"; case .selection: return "批量导出所选照片"; case .photo: return "导出当前照片" }
    }
}

/// Always copies resolved file bytes into a unique directory, including when the
/// imported path is a symlink. The editor can never write through to the original.
enum ExternalEditorCopy {
    static func prepare(source: URL, filename: String, directory: URL) throws -> URL {
        let resolved = source.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        do {
            try FileManager.default.copyItem(at: resolved, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

extension AppModel {
    var canLinkSelectedPair: Bool {
        guard canMaintainPairs, !isBusy, selectedIDs.count == 2 else { return false }
        let files = filteredAssets.filter { selectedIDs.contains($0.id) }
        return files.count == 2 && Set(files.map(\.sessionID)).count == 1
            && files.filter { CaptureFileFormat.isRAW($0.filename) }.count == 1
            && files.filter { CaptureFileFormat.isJPEG($0.filename) }.count == 1
    }
    var explicitExportAssets: [AssetRecord] {
        guard let ids = workbenchExportContext.exactAssetIDs else { return [] }
        let wanted = Set(ids)
        return filteredAssets.filter { wanted.contains($0.id) }
    }
    func openProjectExport() { guard canExport else { return }; workbenchExportContext = .project; showExport = true }
    func openSelectionExport() {
        guard canExport, !actionAssetIDs.isEmpty else { return }
        workbenchExportContext = .selection(ids: actionAssetIDs); showExport = true
    }
    func openPhotoExport() {
        guard canExport, let focusedAsset, filteredAssets.contains(where: { $0.id == focusedAsset.id }) else { return }
        workbenchExportContext = .photo(id: focusedAsset.id); showExport = true
    }
    func openContextExport() {
        switch mode { case .grid: openProjectExport(); case .single: openPhotoExport(); case .compare: openSelectionExport() }
    }
    var photoshopApplicationURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") }
    var canOpenExternalEditor: Bool {
        guard mode == .single, let id = focusedID else { return false }
        return canOpenExternalEditor(assetID: id)
    }
    func canOpenExternalEditor(assetID: String) -> Bool {
        !externalEditorPreparing && !isBusy && scopedAssets.contains { $0.id == assetID && $0.availability == .available }
    }
    func chooseExternalEditor() {
        guard let id = focusedID else { return }
        chooseExternalEditor(assetID: id)
    }
    func chooseExternalEditor(assetID: String) {
        guard canOpenExternalEditor(assetID: assetID) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择照片编辑器"; panel.message = "将创建工作副本，再使用此应用打开。"
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseFiles = true
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let application = panel.url else { return }
        openExternalEditor(assetID: assetID, application: application)
    }
    func openExternalEditor(application: URL) {
        guard let id = focusedID else { return }
        openExternalEditor(assetID: id, application: application)
    }
    func openExternalEditor(assetID: String, application: URL) {
        guard canOpenExternalEditor(assetID: assetID), let asset = scopedAssets.first(where: { $0.id == assetID }) else { return }
        let source = asset.resolvedURL, filename = asset.filename
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RAWMaster/Editor Copies", isDirectory: true)
        externalEditorPreparing = true; errorMessage = nil
        Task { [weak self] in
            do {
                let copy = try await Task.detached(priority: .userInitiated) {
                    try ExternalEditorCopy.prepare(source: source, filename: filename, directory: root)
                }.value
                guard let self else { return }
                NSWorkspace.shared.open([copy], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    Task { @MainActor in
                        self?.externalEditorPreparing = false
                        if let error { self?.errorMessage = "无法打开外部编辑器：\(error.localizedDescription)。工作副本保留在 \(copy.path)" }
                    }
                }
            } catch {
                self?.externalEditorPreparing = false
                self?.errorMessage = "无法创建编辑工作副本：\(error.localizedDescription)"
            }
        }
    }
}


extension AppModel {
    /// Production editing requires an admitted, ready physical photo. Library and import-history
    /// scopes may open that same admitted work without changing the user's browsing context.
    var canOpenNativeEditing: Bool {
        guard mode == .single, editing != nil, let asset = focusedAsset, asset.importState == .ready,
              let admission = editingAdmissions[asset.id], admission.projectID == asset.projectID,
              editingProjectIDs.contains(asset.projectID) else { return false }
        switch scope {
        case .all, .session: break
        case .project: guard scopeID == asset.projectID else { return false }
        case .group:
            guard let group = editingGroups[scopeID], group.projectID == asset.projectID,
                  group.assetIDs.contains(asset.id) else { return false }
        default: return false
        }
        return asset.availability == .available || editing?.hasSavedWork(assetID: asset.id, admissionFingerprint: admission.fingerprint) == true
    }
    func synchronizeNativeEditingContext() {
        guard let editing, editing.isPresented || editing.asset != nil else { return }
        if canOpenNativeEditing { editing.focus(focusedAsset, admissionFingerprint: focusedAsset.flatMap { editingAdmissions[$0.id]?.fingerprint }) }
        else { editing.leaveBrowsingContext() }
    }
    func returnFromNativeEditing() {
        editing?.leaveBrowsingContext(); showInspector = true
    }
    var isNativeEditing: Bool { canOpenNativeEditing && editing?.isPresented == true }
    func openNativeEditing() {
        guard canOpenNativeEditing else { return }
        editing?.focus(focusedAsset, admissionFingerprint: focusedAsset.flatMap { editingAdmissions[$0.id]?.fingerprint }); editing?.isPresented = true
    }
    func openRenderedPhotoExport() {
        guard canOpenNativeEditing else { return }
        editing?.prepareExport(asset: focusedAsset, admissionFingerprint: focusedAsset.flatMap { editingAdmissions[$0.id]?.fingerprint })
    }
}
