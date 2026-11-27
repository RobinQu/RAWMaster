import AppKit
import Foundation
import RAWMasterCore
import RAWMasterImaging
import RAWMasterLibrary
import RAWMasterPhotoExport

extension AssetRecord {
    var exportPresentationName: String { virtualCopyName.map { "\(filename) · \($0)" } ?? filename }
}

enum PhotoExportFilename {
    static func validTemplate(_ value: String) -> Bool {
        (try? PhotoExportKernel.validateTemplate(value)) != nil
    }

    static func stem(for asset: AssetRecord, ordinal: Int, template: String, exportDate: Date) throws -> String {
        func dateText(_ date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        do {
            var stem = (asset.filename as NSString).deletingPathExtension
            if let name = asset.virtualCopyName {
                let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
                let suffix = name.components(separatedBy: separators).filter { !$0.isEmpty }.joined(separator: "-")
                stem += "-" + (suffix.isEmpty ? "副本" : suffix)
            }
            return try PhotoExportKernel.name(template: template, stem: stem,
                index: ordinal, exportDate: dateText(exportDate), captureDate: asset.capturedAt.map(dateText))
        } catch PhotoExportKernelError.capturedDateRequired {
            throw LibraryError.invalid("\(asset.filename) 缺少拍摄日期，请更换命名模板。")
        } catch PhotoExportKernelError.invalid {
            throw LibraryError.invalid("请检查命名模板、文件名长度和路径字符。")
        }
    }

}

struct WorkbenchPhotoDelivery {
    var id = UUID()
    let directory: URL
    let assets: [AssetRecord]
    var resumedCount: Int? = nil
    var running = true
    var completed = 0
    var currentName = ""
    var files = [URL]()
    var message: String?
    var total: Int { resumedCount ?? assets.count }
}

struct WorkbenchPQReview: Identifiable, Sendable {
    struct Line: Identifiable, Sendable {
        let id: String
        let name: String
        let version: String?
        let sourceDigest: String?
        let recipeDigest: String?
        let reason: String?
    }
    let id = UUID()
    let lines: [Line]
    var canSubmit: Bool { !lines.isEmpty && lines.allSatisfy { $0.reason == nil && $0.version != nil } }
    var identifiers: Set<String> { Set(lines.map(\.id)) }
}

struct WorkbenchPhotoScope {
    let batchID: UUID
    let candidates: [AssetRecord]
    let catalog: CatalogFrozenSelection?
    let fingerprints: [String: String]
    let editorInput: (assetID: String, input: Task<(PhotoWork, EditingVersion), Error>)?
    let workflowVersions: [String: String]
}

struct WorkbenchDeliveryDetails {
    let receipt: WorkbenchDeliveryCatalog.Receipt
    let directory: URL?
    let items: [WorkbenchDeliveryCatalog.Item]
}

enum WorkbenchDeliveryCheckpoint: String, Sendable {
    case beforePrepare, prepared, published
}

private final class WorkbenchEncodingAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var preparing = false

    func beginPreparation() { lock.withLock { preparing = true } }
    func canRetry(_ error: Error) -> Bool {
        guard lock.withLock({ !preparing }) else { return false }
        if let posix = error as? POSIXError { return [.EAGAIN, .EBUSY, .EINTR].contains(posix.code) }
        if let disk = error as? CocoaError { return disk.code == .fileWriteUnknown }
        return false
    }
}

extension AppModel {
    static var maximumWorkbenchExportCount: Int { PhotoExportKernel.maximumBatchPhotos }

    var workbenchExportCandidates: [AssetRecord] {
        let fallback = supportsProjectSearch ? filteredAssets : scopedAssets
        #if canImport(RAWMasterLibrary)
        let scope = isPagedGrid && exportCatalogScope != nil ? exportCatalogAssets : fallback
        #else
        let scope = fallback
        #endif
        guard let explicit = workbenchExportContext.exactAssetIDs else { return scope }
        let requested = Set(explicit)
        return scope.filter { requested.contains($0.id) }
    }

    func submitWorkbenchPhotoDelivery(directory: URL, naming: String, configuration: PhotoBatchExportConfiguration,
                                      ids: Set<String>, collision: String, pqReview: WorkbenchPQReview? = nil) {
        guard workbenchPhotoDeliveryTask == nil else { return }
        let candidates = workbenchExportCandidates
        let fingerprints = editingAdmissions.mapValues(\.fingerprint)
        let workflowVersions = workbenchExportContext.workflowVersions
        if workflowVersions.isEmpty, isNativeEditing, let asset = focusedAsset, ids.contains(asset.id), let editing,
           let fingerprint = fingerprints[asset.physicalAssetID], !editing.hasWorkbenchExport(for: asset.id),
           !editing.beginWorkbenchExport(asset: asset, admissionFingerprint: fingerprint) {
            workbenchPhotoDelivery = .init(directory: directory, assets: [], running: false,
                message: editing.message ?? "当前版本尚未准备好导出。")
            return
        }
        let submitted = WorkbenchPhotoDelivery(directory: directory, assets: candidates.filter { ids.contains($0.id) })
        let scope = WorkbenchPhotoScope(batchID: submitted.id, candidates: candidates, catalog: isPagedGrid ? exportCatalogScope : nil,
            fingerprints: fingerprints, editorInput: workflowVersions.isEmpty ? editing?.submitWorkbenchExportInput(for: ids) : nil,
            workflowVersions: workflowVersions)
        workbenchPhotoDelivery = submitted
        workbenchPhotoDeliveryTask = Task {
            defer {
                scope.editorInput?.input.cancel()
                workbenchPhotoDelivery?.running = false
                workbenchPhotoDeliveryTask = nil
                workbenchExplicitCancellation = nil
            }
            do {
                let result = try await exportWorkbenchPhotos(directory: directory, namingTemplate: naming, configuration: configuration,
                    includedIDs: ids, collision: collision, submittedScope: scope, pqReview: pqReview, delivered: { url in
                        guard self.workbenchPhotoDelivery?.id == submitted.id else { return }
                        self.workbenchPhotoDelivery?.files.append(url)
                    }) { done, _, name in
                    Task { @MainActor in
                        guard self.workbenchPhotoDelivery?.id == submitted.id, self.workbenchPhotoDelivery?.running == true,
                              done >= (self.workbenchPhotoDelivery?.completed ?? 0) else { return }
                        self.workbenchPhotoDelivery?.completed = done
                        self.workbenchPhotoDelivery?.currentName = name
                    }
                }
                workbenchPhotoDelivery?.files = result
                workbenchPhotoDelivery?.completed = submitted.assets.count
                workbenchPhotoDelivery?.message = "已写入 \(result.count) 个文件。"
            } catch {
                if workbenchExplicitCancellation != nil {
                    workbenchPhotoDelivery?.message = "已取消本批交付。已写入的文件保存在输出目录。"
                } else if Task.isCancelled || error is CancellationError {
                    workbenchPhotoDelivery?.message = "交付已中断。可从任务详情继续。"
                } else {
                    workbenchPhotoDelivery?.message = error.localizedDescription
                }
            }
        }
    }

    func stopWorkbenchPhotoDelivery() async {
        workbenchExecutionEpoch = UUID()
        let task = workbenchPhotoDeliveryTask
        task?.cancel()
        await task?.value
    }

    func cancelWorkbenchPhotoDelivery() async {
        guard let id = workbenchPhotoDelivery?.id, workbenchPhotoDeliveryTask != nil else { return }
        workbenchExplicitCancellation = id.uuidString.lowercased()
        if let lease = workbenchActiveLease {
            try? await WorkbenchDeliveryCatalog(database: libraryURL).stop(batchID: lease.batchID,
                generation: lease.generation, token: nil, cancel: true)
        }
        await stopWorkbenchPhotoDelivery()
    }

    func workbenchDeliveryDetails(_ id: String) async throws -> WorkbenchDeliveryDetails {
        let queue = WorkbenchDeliveryCatalog(database: libraryURL)
        let receipt = try await queue.receipt(batchID: id)
        guard let manifest = receipt.manifest,
              let access = try? WorkbenchDeliveryAccess.open(grantID: manifest.destination.grantID, database: libraryURL, in: defaults),
              (try? await queue.checkDirectory(batchID: id, directory: access.url)) != nil else {
            return .init(receipt: receipt, directory: nil, items: receipt.items.items)
        }
        defer { withExtendedLifetime(access) {} }
        var items: [WorkbenchDeliveryCatalog.Item] = []
        var advanced = false
        for item in receipt.items.items {
            try Task.checkCancellation()
            if item.state == .prepared && receipt.batch.phase != .running {
                let check = try await queue.acknowledge(batchID: id, ordinal: item.ordinal, directory: access.url)
                if check.status == "conflict" {
                    items.append(.init(ordinal: item.ordinal, state: item.state, filename: item.filename, sha256: item.sha256,
                        reason: WorkbenchDeliveryIssue.conflictingPrepared.rawValue, sceneExecution: item.sceneExecution))
                } else {
                    items.append(check.item)
                    advanced = advanced || check.item.state == .delivered
                }
            } else {
                items.append(item)
            }
        }
        let latest = advanced ? try await queue.receipt(batchID: id) : receipt
        return .init(receipt: latest, directory: access.url, items: items)
    }

    func reconnectWorkbenchDestination(_ details: WorkbenchDeliveryDetails, granted: URL) async throws {
        guard let destination = details.receipt.manifest?.destination else { throw WorkbenchDeliveryIssue.invalidReceipt }
        let access = WorkbenchDeliveryAccess(granted)
        do {
            try await WorkbenchDeliveryCatalog(database: libraryURL).checkDirectory(batchID: details.receipt.batch.batchID, directory: access.url)
        } catch {
            throw WorkbenchDeliveryIssue.targetOffline
        }
        try access.remember(grantID: destination.grantID, database: libraryURL, in: defaults)
    }

    func reconnectWorkbenchSource(_ details: WorkbenchDeliveryDetails, ordinal: Int, granted: URL) async throws {
        guard let manifest = details.receipt.manifest,
              let item = manifest.items.first(where: { $0.ordinal == ordinal }) else {
            throw WorkbenchDeliveryIssue.invalidReceipt
        }
        let id = details.receipt.batch.batchID
        let access = WorkbenchDeliveryAccess(granted)
        let input: WorkbenchDeliveryCatalog.FrozenInput
        if let inline = details.receipt.inlineInputs { input = inline[ordinal - 1] }
        else { input = try await WorkbenchDeliveryCatalog(database: libraryURL).input(batchID: id, ordinal: ordinal) }
        do {
            try await ProcessingAdmission.shared.withPermit(.export, resources: .init(cpu: 1, io: 1)) {
                try PhotoBatchRenderExporter.validateRelocatedSource(access.url, expected: input.version.source)
            }
        } catch {
            throw WorkbenchDeliveryIssue.sourceOffline
        }
        for sibling in manifest.items where sibling.source == item.source {
            try access.remember(grantID: Self.workbenchSourceGrant(batchID: id, ordinal: sibling.ordinal), database: libraryURL, in: defaults)
        }
    }

    private nonisolated static func workbenchSourceGrant(batchID: String, ordinal: Int) -> String {
        batchID + ".source." + String(ordinal)
    }

    func resumeWorkbenchPhotoDelivery(_ id: String) async throws {
        guard workbenchPhotoDeliveryTask == nil, let store = workbenchExportStore else { throw WorkbenchDeliveryIssue.leaseUnavailable }
        let epoch = workbenchExecutionEpoch
        let details = try await workbenchDeliveryDetails(id)
        guard let manifest = details.receipt.manifest, let uuid = UUID(uuidString: id) else {
            throw WorkbenchDeliveryIssue.invalidReceipt
        }
        let batch = details.receipt.batch
        guard batch.phase == .interrupted else { throw WorkbenchDeliveryIssue.leaseUnavailable }
        let access = try WorkbenchDeliveryAccess.open(grantID: manifest.destination.grantID, database: libraryURL, in: defaults)
        let queue = WorkbenchDeliveryCatalog(database: store.databaseURL)
        try await queue.checkDirectory(batchID: id, directory: access.url)
        let configuration: PhotoBatchExportConfiguration
        if let inline = details.receipt.inlineConfiguration { configuration = inline }
        else { configuration = try await queue.configuration(batchID: id) }
        let archive = try await workbenchArchive()
        let protected = try await Task.detached { try store.editingProtectedRoots() }.value
        guard workbenchPhotoDeliveryTask == nil, workbenchExecutionEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
        let lease = try await queue.begin(batch)
        if workbenchPhotoDeliveryTask != nil || workbenchExecutionEpoch != epoch || Task.isCancelled {
            try? await queue.stop(batchID: id, generation: lease.generation, token: lease.token, cancel: false)
            throw CancellationError()
        }
        let finished = details.items.filter(\.finished)
        let delivered = finished.compactMap { item in
            item.state == .delivered ? item.filename.map { access.url.appending(path: $0) } : nil
        }
        workbenchPhotoDelivery = .init(id: uuid, directory: access.url, assets: [], resumedCount: batch.itemCount,
            completed: finished.count, files: delivered)
        workbenchPhotoDeliveryTask = Task {
            defer {
                workbenchPhotoDelivery?.running = false
                workbenchPhotoDeliveryTask = nil
                workbenchExplicitCancellation = nil
            }
            do {
                let files = try await executeWorkbenchBatch(queue: queue, lease: lease, manifest: manifest, access: access,
                    archive: archive, configuration: configuration, protected: protected, startingItems: details.items,
                    captured: details.receipt.inlineInputs,
                    delivered: { file in self.workbenchPhotoDelivery?.files.append(file) }) { completed, _, name in
                        Task { @MainActor in
                            guard self.workbenchPhotoDelivery?.id == uuid, self.workbenchPhotoDelivery?.running == true,
                                  completed >= (self.workbenchPhotoDelivery?.completed ?? 0) else { return }
                            self.workbenchPhotoDelivery?.completed = completed
                            self.workbenchPhotoDelivery?.currentName = name
                        }
                    }
                workbenchPhotoDelivery?.completed = batch.itemCount
                workbenchPhotoDelivery?.files = files
                workbenchPhotoDelivery?.message = "已写入 \(files.count) 个文件。"
            } catch {
                if workbenchExplicitCancellation == id {
                    workbenchPhotoDelivery?.message = "已取消本批交付。已写入的文件保存在输出目录。"
                } else {
                    workbenchPhotoDelivery?.message = Task.isCancelled ? "交付已中断。可从任务详情继续。" : error.localizedDescription
                }
            }
        }
    }

    func cancelWorkbenchDelivery(_ batch: WorkbenchDeliveryCatalog.Batch) async throws {
        if workbenchPhotoDelivery?.id.uuidString.lowercased() == batch.batchID && workbenchPhotoDeliveryTask != nil {
            await cancelWorkbenchPhotoDelivery()
        } else {
            try await WorkbenchDeliveryCatalog(database: libraryURL).stop(batchID: batch.batchID,
                generation: batch.generation, token: nil, cancel: true)
        }
    }

    private func workbenchArchive() async throws -> EditingArchive {
        if let archive = editing?.archive { return archive }
        guard let store = workbenchExportStore else { throw EditingError.missingWork }
        let defaultRoot = libraryURL.deletingLastPathComponent().appendingPathComponent("Editing Archive", isDirectory: true)
        return try await Task.detached(priority: .userInitiated) {
            do { return try store.editingArchive() }
            catch EditingError.archiveNotConfigured { return try store.configureEditingArchive(root: defaultRoot) }
        }.value
    }

    private func workbenchExportInput(_ asset: AssetRecord) async throws -> (PhotoWork, EditingVersion) {
        guard let store = workbenchExportStore else { throw EditingError.missingWork }
        let fingerprint = editingAdmissions[asset.physicalAssetID]?.fingerprint
        if let id = workbenchExportContext.workflowVersions[asset.id] {
            return try await Task.detached { try Self.workbenchBatchCandidate(id, asset: asset, fingerprint: fingerprint, store: store) }.value
        }
        if let input = try await workbenchEditorInput(asset, fingerprint: fingerprint) { return input }
        return try await Task.detached(priority: .userInitiated) {
            try Self.workbenchStoredInput(asset, fingerprint: fingerprint, store: store)
                ?? Self.captureWorkbenchOriginal(asset, store: store)
        }.value
    }

    private func workbenchEditorInput(_ asset: AssetRecord, fingerprint: String?) async throws -> (PhotoWork, EditingVersion)? {
        if isNativeEditing, focusedID == asset.id, let editing, let fingerprint,
           !editing.hasWorkbenchExport(for: asset.id),
           !editing.beginWorkbenchExport(asset: asset, admissionFingerprint: fingerprint) {
            throw LibraryError.invalid(editing.message ?? "当前版本尚未准备好导出。")
        }
        if let input = try await editing?.workbenchExportInput(for: asset.id) {
            return try Self.checkedWorkbenchEditorInput(input, asset: asset, fingerprint: fingerprint)
        }
        return nil
    }

    private nonisolated static func checkedWorkbenchEditorInput(_ input: (PhotoWork, EditingVersion), asset: AssetRecord,
                                                                 fingerprint: String?) throws -> (PhotoWork, EditingVersion) {
        var (work, version) = input
        guard work.presentationID == asset.id, work.source.assetID == asset.physicalAssetID,
              work.source.projectID == asset.projectID, work.source.admissionFingerprint == fingerprint,
              version.workID == work.id, version.source.hasSameIdentity(as: work.source) else { throw EditingError.staleSource }
        work.source.sourceLocation = asset.resolvedURL
        version.source = work.source
        return (work, version)
    }

    private nonisolated static func workbenchBatchCandidate(_ id: String, asset: AssetRecord, fingerprint: String?,
                                                          store: LibraryStore) throws -> (PhotoWork, EditingVersion) {
        try store.withReadSnapshot {
            var version = try store.editingVersion(id: id)
            var work = try store.photoWork(id: version.workID)
            let frozen = try store.freezeSceneDelivery(versionID: id, format: .jpeg8)
            guard work.presentationID == asset.id, frozen.source.assetID == asset.physicalAssetID, frozen.source.projectID == asset.projectID,
                  frozen.source.admissionFingerprint == fingerprint else { throw EditingError.staleSource }
            version.source = frozen.source; work.source = frozen.source
            return (work, version)
        }
    }

    private nonisolated static func workbenchStoredInput(_ asset: AssetRecord, fingerprint: String?,
                                                         store: LibraryStore) throws -> (PhotoWork, EditingVersion)? {
        if let saved = try storedWorkbenchInput(asset, fingerprint: fingerprint, store: store) { return saved }
        guard let digest = asset.contentHash else { return nil }
        // The renderer verifies the immutable source against this digest before decoding.
        let source = try store.editingSourceSnapshot(assetID: asset.physicalAssetID,
            verifiedSHA256: digest.lowercased(), verifiedByteCount: asset.fileSize)
        return workbenchOriginal(source, location: asset.resolvedURL)
    }

    nonisolated static func storedWorkbenchInput(_ asset: AssetRecord, fingerprint: String?,
                                                 store: LibraryStore) throws -> (PhotoWork, EditingVersion)? {
        let existing = try store.editingWorks(for: asset).last {
            $0.presentationID == asset.id && $0.source.assetID == asset.physicalAssetID &&
                $0.source.admissionFingerprint == fingerprint && $0.source.byteCount == asset.fileSize &&
                (asset.contentHash?.lowercased() ?? $0.source.contentSHA256) == $0.source.contentSHA256
        }
        guard var work = existing else {
            guard asset.id == asset.physicalAssetID else { throw EditingError.missingWork }
            return nil
        }
        work.source.sourceLocation = asset.resolvedURL
        let adopted = try store.editingVersion(id: work.adoptedVersionID)
        var version = adopted
        if work.usesLiveRendition(over: adopted), let recipe = work.liveRecipe, let parent = work.liveParentVersionID {
            version = try store.editingVersion(id: parent)
            if recipe.sceneGraph != nil {
                version = try version.freezingSceneAppearance(recipe)
            } else {
                version = version.freezingDevelopmentDraft(recipe, presets: work.livePresetAdoptions)
            }
            if version.artifact == nil && (asset.availability != .available || !FileManager.default.isReadableFile(atPath: asset.resolvedURL.path)) {
                guard adopted.artifact != nil, adopted.recipe == recipe else {
                    throw LibraryError.invalid("\(asset.filename) 的当前调整需要原片。请找回原片，或从「已有编辑结果」选择已归档的成片。")
                }
                version = adopted.freezingDevelopmentDraft(recipe, presets: work.livePresetAdoptions)
            }
        }
        version.source = work.source
        return (work, version)
    }

    private nonisolated static func captureWorkbenchOriginal(_ asset: AssetRecord, store: LibraryStore) throws -> (PhotoWork, EditingVersion) {
        let source = try store.captureEditingSourceSnapshot(assetID: asset.physicalAssetID) { try Task.checkCancellation() }
        guard source.projectID == asset.projectID, source.byteCount == asset.fileSize else { throw EditingError.staleSource }
        return workbenchOriginal(source, location: asset.resolvedURL)
    }

    private nonisolated static func workbenchOriginal(_ source: EditingSourceSnapshot, location: URL) -> (PhotoWork, EditingVersion) {
        var source = source
        source.sourceLocation = location
        let work = PhotoWork(source: source)
        let version = EditingVersion(id: work.originalVersionID, workID: work.id, parentVersionID: nil, kind: .original, source: source)
        return (work, version)
    }

    func workbenchExportPreview(for asset: AssetRecord, maxPixel: Int) async throws -> (image: CGImage, metadata: PhotoExportMetadata) {
        let archive = try await workbenchArchive()
        let (work, version) = try await workbenchExportInput(asset)
        try Task.checkCancellation()
        return try await RenderExportService().preview(work: work, version: version, archive: archive, maxPixel: maxPixel)
    }

    func reviewWorkbenchPQ(_ assets: [AssetRecord]) async throws -> WorkbenchPQReview {
        try PhotoExportKernel.validatePhotoCount(assets.count)
        guard let store = workbenchExportStore else { throw EditingError.missingWork }
        var lines = [WorkbenchPQReview.Line]()
        for asset in assets {
            try Task.checkCancellation()
            var version: String?, source: String?, recipe: String?, reason: String?
            if asset.availability != .available { reason = asset.availability == .missing ? "原片离线" : "原片已变更" }
            else if asset.resolvedURL.pathExtension.lowercased() != "arw" { reason = "所选版本没有 HDR 母版" }
            else {
                do {
                    let (work, selected) = try await workbenchExportInput(asset)
                    guard selected.recipe.sceneGraph != nil else { throw WorkbenchDeliveryIssue.hdrMasterRequired }
                    let chosen = try store.checkedSceneDelivery(work: work, selection: selected, format: .avif10)
                    version = selected.id; source = chosen.source.contentSHA256; recipe = try chosen.program.fingerprint()
                } catch is CancellationError { throw CancellationError() }
                catch WorkbenchDeliveryIssue.hdrMasterRequired { reason = "所选版本没有 HDR 母版" }
                catch { reason = "请核对原片和当前 HDR 外观：\(error.localizedDescription)" }
            }
            lines.append(.init(id: asset.id, name: asset.exportPresentationName, version: version, sourceDigest: source, recipeDigest: recipe, reason: reason))
        }
        return WorkbenchPQReview(lines: lines)
    }

    /// Called immediately before durable registration. A UI review is a receipt for the shown
    /// version/digest, not authorization to substitute whatever the selection returns later.
    private nonisolated static func validatePQBatch(_ frozen: [(PhotoWork, EditingVersion)], against review: WorkbenchPQReview?,
                                                     store: LibraryStore) throws {
        if let review, !review.canSubmit || review.lines.count != frozen.count ||
            review.identifiers.count != review.lines.count || review.identifiers != Set(frozen.map { $0.0.presentationID }) {
            throw WorkbenchDeliveryIssue.pqSelectionChanged
        }
        let accepted = review.map { Dictionary(uniqueKeysWithValues: $0.lines.map { ($0.id, $0) }) }
        try store.withReadSnapshot {
            for (work, version) in frozen {
                try Task.checkCancellation()
                guard version.recipe.sceneGraph != nil else { throw WorkbenchDeliveryIssue.hdrMasterRequired }
                let chosen = try store.checkedSceneDelivery(work: work, selection: version, format: .avif10)
                if let accepted {
                    let shown = accepted[work.presentationID]
                    guard shown?.version == version.id, shown?.sourceDigest == chosen.source.contentSHA256,
                          shown?.recipeDigest == (try chosen.program.fingerprint()) else { throw WorkbenchDeliveryIssue.pqSelectionChanged }
                }
            }
        }
    }

    func exportWorkbenchPhotos(directory: URL, namingTemplate: String, configuration: PhotoBatchExportConfiguration,
                              includedIDs: Set<String>? = nil, collision: String = "rename",
                              submittedScope: WorkbenchPhotoScope? = nil, pqReview: WorkbenchPQReview? = nil,
                              delivered: (@MainActor @Sendable (URL) -> Void)? = nil,
                              progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> [URL] {
        guard let store = workbenchExportStore else { throw EditingError.missingWork }
        let candidates = submittedScope?.candidates ?? workbenchExportCandidates
        guard (includedIDs?.count ?? candidates.count) <= Self.maximumWorkbenchExportCount else {
            throw LibraryError.invalid("每批最多可交付 \(Self.maximumWorkbenchExportCount) 张照片，请缩小选片范围。")
        }
        let catalog = submittedScope == nil ? (isPagedGrid ? exportCatalogScope : nil) : submittedScope?.catalog
        let ids = includedIDs ?? Set(candidates.filter { $0.availability == .available }.map(\.id))
        try PhotoExportKernel.validatePhotoCount(ids.count)
        let selected = candidates.filter { ids.contains($0.id) }
        guard !selected.isEmpty, selected.count == ids.count else { throw LibraryError.invalid("导出选片范围已变化，请重新选择照片。") }
        guard ["rename", "skip"].contains(collision) else { throw LibraryError.invalid("无法识别重名处理方式。") }
        try configuration.validate()
        let date = Date()
        let stems = try selected.enumerated().map { try PhotoExportFilename.stem(for: $0.element, ordinal: $0.offset+1, template: namingTemplate, exportDate: date) }
        let protected = try await Task.detached { try store.editingProtectedRoots() }.value
        let archive = try await workbenchArchive()
        let batch = (submittedScope?.batchID ?? UUID()).uuidString.lowercased()
        let fingerprints = submittedScope?.fingerprints ?? editingAdmissions.mapValues(\.fingerprint)
        let selection = selected.map { (asset: $0, fingerprint: fingerprints[$0.physicalAssetID]) }
        let workflowVersions = submittedScope?.workflowVersions ?? workbenchExportContext.workflowVersions
        var current = [String: (PhotoWork, EditingVersion)]()
        if let input = submittedScope?.editorInput, let asset = selected.first(where: { $0.id == input.assetID }) {
            let frozen = try await withTaskCancellationHandler { try await input.input.value } onCancel: { input.input.cancel() }
            current[asset.id] = try Self.checkedWorkbenchEditorInput(frozen, asset: asset, fingerprint: fingerprints[asset.physicalAssetID])
        } else if submittedScope == nil, workflowVersions.isEmpty {
            for item in selection where (isNativeEditing && focusedID == item.asset.id) || editing?.hasWorkbenchExport(for: item.asset.id) == true {
                current[item.asset.id] = try await workbenchEditorInput(item.asset, fingerprint: item.fingerprint)
            }
        }
        let capture = Task.detached(priority: .userInitiated) { [current] in
            let saved = try store.withReadSnapshot {
                if let catalog { _ = try store.catalogAssets(for: catalog) }
                return try selection.map { item -> (PhotoWork, EditingVersion)? in
                    try Task.checkCancellation()
                    if !workflowVersions.isEmpty {
                        guard let id = workflowVersions[item.asset.id] else { throw EditingError.missingVersion }
                        return try Self.workbenchBatchCandidate(id, asset: item.asset, fingerprint: item.fingerprint, store: store)
                    }
                    return try current[item.asset.id] ?? Self.workbenchStoredInput(item.asset, fingerprint: item.fingerprint, store: store)
                }
            }
            // Reference-only assets without an admitted hash require file I/O. All stored recipe
            // reads finish in the catalogue snapshot before hashing those originals.
            return try zip(selection, saved).map { item, input in
                try Task.checkCancellation()
                return try input ?? Self.captureWorkbenchOriginal(item.asset, store: store)
            }
        }
        let frozen = try await withTaskCancellationHandler { try await capture.value } onCancel: { capture.cancel() }
        if configuration.format == .avif10 {
            try await Task.detached(priority: .utility) { try Self.validatePQBatch(frozen, against: pqReview, store: store) }.value
            try Task.checkCancellation()
        }
        try await Self.reconcileWorkbenchDeliveries(store)
        let access = WorkbenchDeliveryAccess(directory)
        try FileManager.default.createDirectory(at: access.url, withIntermediateDirectories: true)
        try access.remember(grantID: batch, database: libraryURL, in: defaults)
        let queue = WorkbenchDeliveryCatalog(database: store.databaseURL)
        let libraryID = try store.catalogLibraryIdentity()
        let destination = WorkbenchDeliveryManifest.Destination(grantID: batch, pathHint: access.url.path)
        let (manifest, lease) = try await queue.register(batchID: batch, libraryID: libraryID, destination: destination,
            context: .init(submittedAt: date, filenames: selected.map(\.exportPresentationName)), naming: namingTemplate, collision: collision,
            stems: stems, configuration: configuration, frozen: frozen)
        let inputs = frozen.map { WorkbenchDeliveryCatalog.FrozenInput(work: $0.0, version: $0.1) }
        return try await executeWorkbenchBatch(queue: queue, lease: lease, manifest: manifest, access: access,
            archive: archive, configuration: configuration, protected: protected, startingItems: [], captured: inputs,
            delivered: delivered, progress: progress)
    }

    private func executeWorkbenchBatch(queue: WorkbenchDeliveryCatalog, lease: WorkbenchDeliveryCatalog.Lease,
                                       manifest: WorkbenchDeliveryManifest, access: WorkbenchDeliveryAccess, archive: EditingArchive,
                                       configuration: PhotoBatchExportConfiguration, protected: [URL],
                                       startingItems: [WorkbenchDeliveryCatalog.Item], captured: [WorkbenchDeliveryCatalog.FrozenInput]?,
                                       delivered: (@MainActor @Sendable (URL) -> Void)?, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> [URL] {
        if workbenchPhotoDelivery?.id.uuidString.lowercased() == lease.batchID { workbenchActiveLease = lease }
        defer {
            if workbenchActiveLease?.batchID == lease.batchID { workbenchActiveLease = nil }
        }
        do {
            try Task.checkCancellation()
            let files = try await queue.maintain(lease) {
                try await self.renderWorkbenchBatch(queue: queue, lease: lease, manifest: manifest, access: access, archive: archive,
                    configuration: configuration, protected: protected, startingItems: startingItems, captured: captured,
                    delivered: delivered, progress: progress)
            }
            try Task.checkCancellation()
            try await queue.finish(lease)
            if Self.exportTimingEnabled { print(ExportTiming.shared.drain()) }
            return files
        } catch {
            let cancelled = workbenchExplicitCancellation == lease.batchID
            try? await queue.stop(batchID: lease.batchID, generation: lease.generation, token: cancelled ? nil : lease.token, cancel: cancelled)
            throw error
        }
    }

    private func renderWorkbenchBatch(queue: WorkbenchDeliveryCatalog, lease: WorkbenchDeliveryCatalog.Lease,
                                      manifest: WorkbenchDeliveryManifest, access: WorkbenchDeliveryAccess, archive: EditingArchive,
                                      configuration: PhotoBatchExportConfiguration, protected: [URL],
                                      startingItems: [WorkbenchDeliveryCatalog.Item], captured: [WorkbenchDeliveryCatalog.FrozenInput]?,
                                      delivered: (@MainActor @Sendable (URL) -> Void)?, progress: @Sendable (Int, Int, String) -> Void) async throws -> [URL] {
        let count = manifest.items.count
        let names = manifest.sourceContext.filenames
        guard count > 0, names.count == count, captured.map({ $0.count == count }) ?? true else {
            throw WorkbenchDeliveryIssue.invalidReceipt
        }
        let held = Dictionary(uniqueKeysWithValues: startingItems.map { ($0.ordinal, $0) })
        let pending = manifest.items.filter { held[$0.ordinal]?.finished != true }
        let sourceGrants = pending.reduce(into: [Int: String]()) { grants, item in
            let key = Self.workbenchSourceGrant(batchID: manifest.batchID, ordinal: item.ordinal)
            if WorkbenchDeliveryAccess.hasBookmark(grantID: key, in: defaults) { grants[item.ordinal] = key }
        }
        let sourceAccess = sourceGrants.compactMapValues { try? WorkbenchDeliveryAccess.open(grantID: $0, database: libraryURL, in: defaults) }
        let reserved = Set(manifest.items.map { $0.stem.precomposedStringWithCanonicalMapping.lowercased() })
        let reducedJPEG = configuration.format == .jpeg8 && (configuration.maximumLongEdge ?? Int.max) <= 4096 && reserved.count == count
        let useFour = ProcessingAdmission.shared.capacity.gpu >= 4 && (configuration.maximumLongEdge ?? Int.max) <= 2048
            && captured?.allSatisfy { input in
                ["jpeg", "jpg"].contains(input.version.source.sourceLocation.pathExtension.lowercased())
                    && PhotoBatchRenderExporter.neutralJPEGEdge(for: input.version, configuration: configuration) != nil
            } == true
        let workers = reducedJPEG ? (useFour ? 4 : 3) : 1
        let directory = access.url
        defer { withExtendedLifetime(access) {} }
        let checkpoint = workbenchDeliveryCheckpoint
        var results = manifest.items.map { item -> URL? in
            guard held[item.ordinal]?.state == .delivered, let filename = held[item.ordinal]?.filename else { return nil }
            return directory.appending(path: filename)
        }
        var completed = count - pending.count
        progress(completed, count, pending.first.map { names[$0.ordinal - 1] } ?? names[0])
        return try await withThrowingTaskGroup(of: (Int, Result<URL?, Error>).self) { group in
            func start(_ pendingIndex: Int) {
                let item = pending[pendingIndex]
                let source = sourceAccess[item.ordinal]
                let execution = BatchPhotoExecution(retainStageForRecovery: true,
                    bufferedThumbnail: workers == 4 && pending.count >= 20 && pendingIndex > 0)
                group.addTask {
                    do {
                        let output = try await Self.exportWorkbenchItem(item, manifest: manifest, queue: queue, parent: lease,
                            captured: captured?[item.ordinal - 1], relocation: source, archive: archive, directory: directory,
                            configuration: configuration, reserved: reserved, protected: protected, execution: execution, checkpoint: checkpoint)
                        return (item.ordinal - 1, .success(output))
                    } catch {
                        return (item.ordinal - 1, .failure(error))
                    }
                }
            }
            let initial = min(workers, pending.count)
            for index in 0 ..< initial { start(index) }
            var next = initial
            var firstError: Error?
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                switch result {
                case .success(let output):
                    results[index] = output
                    if let output { delivered?(output) }
                    completed += 1
                    progress(completed, count, names[index])
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                if next < pending.count {
                    start(next)
                    next += 1
                }
            }
            try Task.checkCancellation()
            if let firstError { throw firstError }
            return results.compactMap { $0 }
        }
    }

    private nonisolated static func exportWorkbenchItem(_ item: WorkbenchDeliveryManifest.Item, manifest: WorkbenchDeliveryManifest,
        queue: WorkbenchDeliveryCatalog, parent: WorkbenchDeliveryCatalog.Lease, captured: WorkbenchDeliveryCatalog.FrozenInput?,
        relocation: WorkbenchDeliveryAccess?, archive: EditingArchive, directory: URL, configuration: PhotoBatchExportConfiguration,
        reserved: Set<String>, protected: [URL], execution: BatchPhotoExecution,
        checkpoint: (@Sendable (Int, WorkbenchDeliveryCheckpoint) -> Void)?) async throws -> URL? {
        defer { withExtendedLifetime(relocation) {} }
        try Task.checkCancellation()
        let claim = try await queue.claim(parent, ordinal: item.ordinal)
        if claim.item.state == .delivered, let filename = claim.item.filename { return directory.appending(path: filename) }
        if claim.item.state == .skipped { return nil }
        guard let token = claim.itemToken else { throw WorkbenchDeliveryIssue.leaseUnavailable }
        let lease = WorkbenchDeliveryCatalog.ItemLease(parent: parent, ordinal: item.ordinal, token: token)
        do {
            return try await queue.maintain(parent, item: lease) {
                if claim.item.state == .prepared {
                    let actual = try await queue.acknowledge(batchID: parent.batchID, ordinal: item.ordinal, directory: directory)
                    if actual.status == "delivered", let filename = actual.item.filename { return directory.appending(path: filename) }
                    if actual.status == "conflict" { throw WorkbenchDeliveryIssue.conflictingPrepared }
                }
                let input: WorkbenchDeliveryCatalog.FrozenInput
                if let captured { input = captured }
                else { input = try await queue.input(batchID: parent.batchID, ordinal: item.ordinal) }
                var work = input.work
                var version = input.version
                guard work.presentationID == item.selectionID, work.id == item.workID,
                      version.id == item.versionID, version.workID == work.id,
                      WorkbenchDeliveryManifest.Source(version.source) == item.source,
                      version.source.hasSameIdentity(as: work.source) else { throw WorkbenchDeliveryIssue.invalidReceipt }
                var sourceAliasDirectory: URL?
                defer { if let sourceAliasDirectory { try? FileManager.default.removeItem(at: sourceAliasDirectory) } }
                if let relocation {
                    var location = relocation.url
                    let originalExtension = version.source.sourceLocation.pathExtension
                    if originalExtension.caseInsensitiveCompare(location.pathExtension) != .orderedSame {
                        // Keep the frozen decoder's format hint when the same bytes were renamed.
                        let fm = FileManager.default
                        let scratch = fm.temporaryDirectory.appending(path: "rawmaster-relocated-" + UUID().uuidString)
                        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        sourceAliasDirectory = scratch
                        var alias = scratch.appending(path: "source")
                        if !originalExtension.isEmpty { alias.appendPathExtension(originalExtension) }
                        try fm.createSymbolicLink(at: alias, withDestinationURL: location)
                        location = alias
                    }
                    work.source.sourceLocation = location
                    version.source.sourceLocation = location
                }
                if claim.item.state == .prepared, let filename = claim.item.filename {
                    guard version.artifact != nil || FileManager.default.isReadableFile(atPath: version.source.sourceLocation.path) else {
                        throw WorkbenchDeliveryIssue.sourceOffline
                    }
                    let destination = directory.appending(path: filename)
                    let work = work
                    let version = version
                    try await ProcessingAdmission.shared.withPermit(.export, resources: .init(cpu: 1, io: 1)) {
                        do {
                            try PhotoBatchRenderExporter.validatePreparedDelivery(work: work, version: version, archive: archive,
                                destination: destination, protectedURLs: protected)
                        } catch DevelopmentError.outputExists { throw WorkbenchDeliveryIssue.conflictingPrepared }
                        try Task.checkCancellation()
                        try Self.requirePublished(queue.publish(lease, directory: directory))
                    }
                    return try await Self.acknowledgedFile(queue, parent: parent, ordinal: item.ordinal, directory: directory)
                }
                let exporter = ImageEngines.makeBatchExporter()
                for suffix in 1 ... 10_000 {
                    try Task.checkCancellation()
                    let stem = suffix == 1 ? item.stem : "\(item.stem)-\(suffix)"
                    if suffix > 1 && reserved.contains(stem.precomposedStringWithCanonicalMapping.lowercased()) { continue }
                    let target = directory.appending(path: stem).appendingPathExtension(configuration.format.filenameExtension)
                    if FileManager.default.fileExists(atPath: target.path) {
                        if manifest.collision == "skip" {
                            _ = try await queue.skip(lease, directory: directory, suffix: suffix)
                            return nil
                        }
                        continue
                    }
                    guard version.artifact != nil || FileManager.default.isReadableFile(atPath: version.source.sourceLocation.path) else {
                        throw WorkbenchDeliveryIssue.sourceOffline
                    }
                    do {
                        for retry in 0 ... 2 {
                            let attempt = WorkbenchEncodingAttempt()

                            do {
                                let exportStarted = DispatchTime.now().uptimeNanoseconds
                                var deliveryExecution = execution
                                deliveryExecution.prepareWithExecution = { stage, _, receipt in
                                    attempt.beginPreparation()
                                    checkpoint?(item.ordinal, .beforePrepare)
                                    let prepareStarted = DispatchTime.now().uptimeNanoseconds
                                    let ticket = try await queue.prepare(lease, directory: directory, stage: stage, suffix: suffix, sceneExecution: receipt)
                                    ExportTiming.shared.add("prepare",
                                        Double(DispatchTime.now().uptimeNanoseconds - prepareStarted) / 1_000_000)
                                    if ticket.status == "destinationExists" { throw DevelopmentError.outputExists }
                                    guard ticket.item.state == .prepared else { throw WorkbenchDeliveryIssue.invalidReceipt }
                                    checkpoint?(item.ordinal, .prepared)
                                    return {
                                        let publishStarted = DispatchTime.now().uptimeNanoseconds
                                        do {
                                            let reply = try queue.publish(lease, directory: directory)
                                            ExportTiming.shared.add("publish",
                                                Double(DispatchTime.now().uptimeNanoseconds - publishStarted) / 1_000_000)
                                            // Publish now delivers in the same transaction, so the
                                            // separate acknowledgement round trip is unnecessary.
                                            try Self.requirePublished(reply)
                                        } catch {
                                            ExportTiming.shared.add("publish",
                                                Double(DispatchTime.now().uptimeNanoseconds - publishStarted) / 1_000_000)
                                            throw error
                                        }
                                        checkpoint?(item.ordinal, .published)
                                    }
                                }
                                _ = try await exporter.export(work: work, version: version, archive: archive, directory: directory,
                                    filename: stem, configuration: configuration, protectedURLs: protected, execution: deliveryExecution,
                                    preparePublication: nil)
                                ExportTiming.shared.add("export",
                                    Double(DispatchTime.now().uptimeNanoseconds - exportStarted) / 1_000_000)
                                ExportTiming.shared.item()
                                let acknowledgeStarted = DispatchTime.now().uptimeNanoseconds
                                let delivered = try await Self.acknowledgedFile(queue, parent: parent, ordinal: item.ordinal, directory: directory)
                                ExportTiming.shared.add("acknowledge",
                                    Double(DispatchTime.now().uptimeNanoseconds - acknowledgeStarted) / 1_000_000)
                                return delivered
                            } catch where retry < 2 && attempt.canRetry(error) {
                                try await Task.sleep(for: .milliseconds(250 << retry))
                            }
                        }
                    } catch is PreparedPhotoDestinationConflict {
                        throw WorkbenchDeliveryIssue.conflictingPrepared
                    } catch DevelopmentError.outputExists {
                        // These collisions predate a prepared ticket. An occupied prepared name stays frozen.
                        if manifest.collision == "skip" {
                            _ = try await queue.skip(lease, directory: directory, suffix: suffix)
                            return nil
                        }
                    }
                }
                throw WorkbenchDeliveryIssue.writeFailed
            }
        } catch {
            if !Task.isCancelled && !(error is CancellationError) {
                let reason = (error as? WorkbenchDeliveryIssue) ?? ((error as? EditingError) == .staleSource ? .sourceOffline : .writeFailed)
                try? await queue.fail(lease, reason: reason.rawValue)
                throw reason
            }
            throw error
        }
    }

    static let exportTimingEnabled = ProcessInfo.processInfo.environment["RAWMASTER_EXPORT_TIMING"] == "1"
    /// Diagnostics only: per-item bookkeeping versus rendering. Off unless an environment flag
    /// asks for it, so production carries one boolean load per item.
    private final class ExportTiming: @unchecked Sendable {
        static let shared = ExportTiming()
        private let lock = NSLock()
        private var totals: [String: Double] = [:]
        private var items = 0
        func add(_ name: String, _ seconds: Double) {
            guard AppModel.exportTimingEnabled else { return }
            lock.lock(); totals[name, default: 0] += seconds; lock.unlock()
        }
        func item() { guard AppModel.exportTimingEnabled else { return }; lock.lock(); items += 1; lock.unlock() }
        func drain() -> String {
            lock.lock(); defer { lock.unlock() }
            let count = max(1, items)
            let rows = totals.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))ms/\(String(format: "%.2f", $0.value / Double(count)))per" }
            let result = "EXPORT-TIMING items=\(items) " + rows.joined(separator: " ")
            totals.removeAll(); items = 0
            return result
        }
    }
    private nonisolated static func requirePublished(_ response: WorkbenchDeliveryCatalog.ItemReply) throws {
        switch response.status {
        case "published": return
        case "conflict": throw WorkbenchDeliveryIssue.conflictingPrepared
        case "missingStage": throw WorkbenchDeliveryIssue.missingStage
        default: throw WorkbenchDeliveryIssue.writeFailed
        }
    }

    private nonisolated static func acknowledgedFile(_ queue: WorkbenchDeliveryCatalog, parent: WorkbenchDeliveryCatalog.Lease,
        ordinal: Int, directory: URL) async throws -> URL {
        let response = try await queue.acknowledge(batchID: parent.batchID, ordinal: ordinal, directory: directory)
        guard response.status == "delivered", let name = response.item.filename else {
            throw response.status == "conflict" ? WorkbenchDeliveryIssue.conflictingPrepared : WorkbenchDeliveryIssue.writeFailed
        }
        return directory.appending(path: name)
    }

    private nonisolated static func deliveryIdentity(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(url.lastPathComponent, isDirectory: false)
    }

    /// Only a verified already-written destination can settle an interrupted workspace delivery.
    private nonisolated static func reconcileWorkbenchDeliveries(_ store: LibraryStore) async throws {
        let queue = CatalogTaskQueue(database: store.databaseURL)
        var after: String?
        while true {
            let page = try await queue.preparedExternalTasks(lane: "export", keyPrefix: "workbench-export-", after: after, limit: 64)
            for task in page {
                try Task.checkCancellation()
                let stage = task.publication
                // An inaccessible volume or a conflicting file belongs to this previous task.
                // It must never block a new batch to another destination.
                guard (try? await queue.verifyPreparedDestination(key: task.key)) == true else { continue }
                let _: Bool? = try store.completeVerifiedCatalogTask(key: task.key) { frozen in
                    guard case let .string(path)? = frozen["destination"],
                          Self.deliveryIdentity(URL(fileURLWithPath: path)) == Self.deliveryIdentity(stage.destination) else { return nil }
                    return (true, stage.sha256)
                }
            }
            guard page.count == 64 else { return }
            after = page.last?.key
        }
    }

}
