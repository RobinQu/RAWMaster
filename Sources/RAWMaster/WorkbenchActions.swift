import AppKit
import Foundation
import UniformTypeIdentifiers
import RAWMasterCore
import RAWMasterLibrary

enum WorkbenchExportMode: String { case render, original }

/// Export intent captures the explicit selection before presenting the sheet.
enum WorkbenchExportContext: Equatable {
    case project
    case selection(ids: [String])
    case photo(id: String)
    case workflowBatch(versions: [String: String])

    var exactAssetIDs: [String]? {
        switch self { case .project: return nil; case .selection(let ids): return ids; case .photo(let id): return [id]; case .workflowBatch(let versions): return versions.keys.sorted() }
    }
    var workflowVersions: [String: String] { if case .workflowBatch(let versions) = self { return versions }; return [:] }
    var isPhoto: Bool { if case .photo = self { return true }; return false }
    var title: String {
        switch self { case .project: return "导出项目"; case .selection: return "批量导出所选照片"; case .photo: return "导出当前照片"; case .workflowBatch: return "导出工作流候选" }
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
        return (isPagedGrid && exportCatalogScope != nil ? exportCatalogAssets : filteredAssets).filter { wanted.contains($0.id) }
    }
    func openProjectExport() { prepareLibraryExport(.project) }

    func openExportWorkspace(_ exportMode: WorkbenchExportMode) {
        guard canExport else { return }
        requestedWorkbenchExportMode = exportMode
        activateWorkflow(.export)
    }
    func openSelectionExport() {
        guard !actionAssetIDs.isEmpty else { return }
        prepareLibraryExport(.selection(ids: actionAssetIDs))
    }
    func prepareLibraryExport(_ context: WorkbenchExportContext) {
        pendingGridExport?.cancel()
        guard canExport else { return }
        guard isPagedGrid, let grid = catalogGrid, let store else {
            exportCatalogScope = nil
            workbenchExportContext = context; exportWorkspacePresented = true
            return
        }
        let epoch = grid.epoch, selected = selectedIDs
        func current() -> Bool { !Task.isCancelled && isPagedGrid && grid.epoch == epoch && selectedIDs == selected }
        func assets(_ scope: CatalogFrozenSelection) async throws -> [AssetRecord] {
            try await Task.detached(priority: .userInitiated) { try store.catalogAssets(for: scope) }.value
        }
        pendingGridExport = Task {
            do {
                var scope: CatalogFrozenSelection
                let items: [AssetRecord]
                do {
                    if let ids = context.exactAssetIDs {
                        if let frozenSelection, Set(ids) == Set(frozenSelection.assetIDs) { scope = frozenSelection }
                        else { scope = try grid.visibleSelection(ids) }
                    } else { scope = try await grid.frozenSelection() }
                    items = try await assets(scope)
                    guard current() else { return }
                } catch CatalogSelectionError.changed {
                    guard current() else { return }
                    let fresh = try await grid.readSelectionPage()
                    guard current() else { return }
                    let eligible = Set(fresh.selection.assetIDs)
                    guard let ids = context.exactAssetIDs, eligible.isSuperset(of: ids) else {
                        showRefreshedExportGrid(fresh.page, selection: fresh.selection)
                        errorMessage = context.exactAssetIDs == nil ? "项目范围已更新，请核对后重新导出。" : "选中的照片已不在当前范围内。请核对选片后重新导出。"
                        return
                    }
                    scope = fresh.selection.replacingMembers(ids)
                    items = try await assets(scope)
                    guard current() else { return }
                    showRefreshedExportGrid(fresh.page, selection: fresh.selection)
                }
                exportCatalogScope = scope; exportCatalogAssets = items
                workbenchExportContext = context; exportWorkspacePresented = true
            } catch { if current() { errorMessage = error.localizedDescription } }
        }
    }
    func openPhotoExport(_ mode: WorkbenchExportMode = .original) {
        guard canExport, let focusedAsset, filteredAssets.contains(where: { $0.id == focusedAsset.id }) else { return }
        switch mode {
        case .render: openRenderedPhotoExport()
        case .original: openOriginalPhotoExport(focusedAsset)
        }
    }
    private func openOriginalPhotoExport(_ asset: AssetRecord) {
        requestedWorkbenchExportMode = .original
        prepareLibraryExport(.photo(id: asset.id))
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
              let admission = editingAdmissions[asset.physicalAssetID], admission.projectID == asset.projectID,
              editingProjectIDs.contains(asset.projectID) else { return false }
        switch scope {
        case .all, .session: break
        case .project: guard scopeID == asset.projectID else { return false }
        case .group:
            guard let group = editingGroups[scopeID], group.projectID == asset.projectID,
                  group.assetIDs.contains(asset.physicalAssetID) else { return false }
        default: return false
        }
        return asset.availability == .available || editing?.hasSavedWork(assetID: asset.id, admissionFingerprint: admission.fingerprint) == true
    }
    func synchronizeNativeEditingContext() {
        guard let editing, editing.isPresented || editing.asset != nil else { return }
        if canOpenNativeEditing { editing.focus(focusedAsset, admissionFingerprint: focusedAsset.flatMap { editingAdmissions[$0.physicalAssetID]?.fingerprint }) }
        else { editing.leaveBrowsingContext() }
    }
    func returnFromNativeEditing() {
        editing?.leaveBrowsingContext(); showInspector = true
    }
    var isNativeEditing: Bool { canOpenNativeEditing && editing?.isPresented == true }
    func openNativeEditing() {
        guard canOpenNativeEditing else { return }
        editing?.focus(focusedAsset, admissionFingerprint: focusedAsset.flatMap { editingAdmissions[$0.physicalAssetID]?.fingerprint }); editing?.isPresented = true
    }
    func openSavedResultExport(_ version: EditingVersion) {
        guard canExport, let asset = focusedAsset, version.source.assetID == asset.physicalAssetID,
              let editing, editing.work?.presentationID == asset.id, editing.beginSavedResultExport(version) else { return }
        editing.closeSavedResults()
        requestedWorkbenchExportMode = .render
        prepareLibraryExport(.photo(id: asset.id))
    }
    func openRenderedPhotoExport(context: WorkbenchExportContext? = nil) {
        guard canExport, canOpenNativeEditing, let asset = focusedAsset,
              let admission = editingAdmissions[asset.physicalAssetID], let editing,
              editing.beginWorkbenchExport(asset: asset, admissionFingerprint: admission.fingerprint) else { return }
        requestedWorkbenchExportMode = .render
        prepareLibraryExport(context ?? .photo(id: asset.id))
    }
}
