import AppKit
import Foundation
import RAWMasterCore
import RAWMasterImaging
import RAWMasterPhotoExport

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
            return try PhotoExportKernel.name(template: template, stem: (asset.filename as NSString).deletingPathExtension,
                index: ordinal, exportDate: dateText(exportDate), captureDate: asset.capturedAt.map(dateText))
        } catch PhotoExportKernelError.capturedDateRequired {
            throw LibraryError.invalid("\(asset.filename) 缺少拍摄日期，请更换命名模板。")
        } catch PhotoExportKernelError.invalid {
            throw LibraryError.invalid("请检查命名模板、文件名长度和路径字符。")
        }
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
        let existing = try await Task.detached(priority: .userInitiated) { try store.loadPhotoWorks(assetID: asset.id).first }.value
        var work: PhotoWork
        if let existing { work = existing }
        else {
            let source = try await Task.detached(priority: .userInitiated) {
                if let digest = asset.contentHash {
                    // The pixel provider verifies its immutable copy against this admitted digest before decoding.
                    return try store.editingSourceSnapshot(assetID: asset.id,
                        verifiedSHA256: digest.lowercased(), verifiedByteCount: asset.fileSize)
                }
                return try store.captureEditingSourceSnapshot(assetID: asset.id)
            }.value
            work = PhotoWork(source: source)
        }
        work.source.sourceLocation = asset.resolvedURL
        var version: EditingVersion
        if let editing, editing.asset?.id == asset.id, let live = editing.exportVersion, live.workID == work.id { version = live }
        else if let recipe = work.liveRecipe, let parent = work.liveParentVersionID {
            version = try await Task.detached { try store.editingVersion(id: parent) }.value
            if version.artifact == nil && (asset.availability != .available || !FileManager.default.isReadableFile(atPath: asset.resolvedURL.path)) {
                let adoptedID = work.adoptedVersionID
                let adopted = try await Task.detached { try store.editingVersion(id: adoptedID) }.value
                guard adopted.artifact != nil, adopted.recipe == recipe else {
                    throw LibraryError.invalid("\(asset.filename) 的当前调整需要原片。请找回原片，或从版本列表选择已归档的版本。")
                }
                version = adopted
            } else {
                version.recipe = recipe
            }
        } else if existing != nil {
            let adopted = work.adoptedVersionID
            version = try await Task.detached { try store.editingVersion(id: adopted) }.value
        } else {
            version = EditingVersion(id: work.originalVersionID, workID: work.id, parentVersionID: nil, kind: .original, source: work.source)
        }
        version.source = work.source
        return (work, version)
    }

    func workbenchExportPreview(for asset: AssetRecord, maxPixel: Int) async throws -> (image: CGImage, metadata: PhotoExportMetadata) {
        let archive = try await workbenchArchive()
        let (work, version) = try await workbenchExportInput(asset)
        try Task.checkCancellation()
        return try await RenderExportService().preview(work: work, version: version, archive: archive, maxPixel: maxPixel)
    }

    func exportWorkbenchPhotos(directory: URL, namingTemplate: String, configuration: PhotoBatchExportConfiguration,
                              includedIDs: Set<String>? = nil, collision: String = "rename",
                              progress: @Sendable (Int, Int, String) -> Void) async throws -> [URL] {
        guard let store = workbenchExportStore else { throw EditingError.missingWork }
        let candidates = workbenchExportCandidates
        guard (includedIDs?.count ?? candidates.count) <= Self.maximumWorkbenchExportCount else {
            throw LibraryError.invalid("每批最多可交付 \(Self.maximumWorkbenchExportCount) 张照片，请缩小选片范围。")
        }
        #if canImport(RAWMasterLibrary)
        if isPagedGrid, let frozen = exportCatalogScope {
            _ = try await Task.detached(priority: .userInitiated) { try store.catalogAssets(for: frozen) }.value
        }
        #endif
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reserved = Set(stems.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let uniqueNames = reserved.count == stems.count
        // Bound the decoded-source working set. Unbounded/full-size and duplicate-name
        // deliveries retain serial ordering and run without concurrent raster allocations.
        let workers = configuration.format == .jpeg8 && (configuration.maximumLongEdge ?? Int.max) <= 4096 && uniqueNames ? 3 : 1
        progress(0, selected.count, selected[0].filename)
        return try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            var results = Array<URL?>(repeating: nil, count: selected.count)
            func start(_ index: Int) {
                let asset = selected[index], base = stems[index]
                group.addTask {
                    let (work, version) = try await self.workbenchExportInput(asset)
                    let result = try await Self.exportPlannedPhoto(work: work, version: version, archive: archive,
                        directory: directory, name: base, configuration: configuration, collision: collision,
                        reserved: reserved, protected: protected)
                    return (index, result)
                }
            }
            let initial = min(workers, selected.count)
            for position in 0..<initial { start(position) }
            var next = initial
            var completed = 0
            while let (position, file) = try await group.next() {
                results[position] = file
                completed += 1
                progress(completed, selected.count, selected[position].filename)
                if next < selected.count {
                    start(next)
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    private nonisolated static func exportPlannedPhoto(work: PhotoWork, version: EditingVersion, archive: EditingArchive,
        directory: URL, name: String, configuration: PhotoBatchExportConfiguration, collision: String,
        reserved: Set<String>, protected: [URL]) async throws -> URL? {
        let exporter = ImageEngines.makeBatchExporter()
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let stem = suffix == 1 ? name : "\(name)-\(suffix)"
            let assignedToAnotherPhoto = suffix > 1 && reserved.contains(stem.precomposedStringWithCanonicalMapping.lowercased())
            let target = directory.appendingPathComponent(stem).appendingPathExtension(configuration.format.filenameExtension)
            if !assignedToAnotherPhoto && !FileManager.default.fileExists(atPath: target.path) {
                do {
                    return try await exporter.export(work: work, version: version, archive: archive, directory: directory,
                        filename: stem, configuration: configuration, protectedURLs: protected)
                } catch DevelopmentError.outputExists {
                    // A concurrent task may claim a destination during rendering.
                }
            }
            if collision == "skip" { return nil }
            suffix += 1
        }
    }
}
