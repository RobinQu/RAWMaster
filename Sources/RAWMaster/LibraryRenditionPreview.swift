import AppKit
import RAWMasterCore
import RAWMasterImaging

extension AppModel {
    func renditionPreviewKey(for asset: AssetRecord) -> String {
        [asset.id, asset.resolvedURL.path, asset.availability.rawValue, asset.importState.rawValue,
         renditionPreviewRevisions[asset.id] ?? ""].joined(separator: "\u{1f}")
    }

    func libraryRenditionPreview(_ asset: AssetRecord, maxPixel: Int, loader: PanelImageLoader = .live) async throws -> NSImage {
        try await editing?.awaitPendingRenditionWrites(for: asset.id)
        guard (renditionPreviewRevisions[asset.id] != nil || asset.virtualCopySourceID != nil), let store else {
            return maxPixel > 0 ? try await loader.preview(asset, maxPixel) : try await loader.detail(asset)
        }
        let key = (renditionPreviewKey(for: asset) + "/\(maxPixel)") as NSString
        let cacheable = (1...600).contains(maxPixel)
        if cacheable, let cached = renditionThumbnails.object(forKey: key) { return cached }
        let fingerprint = editingAdmissions[asset.physicalAssetID]?.fingerprint
        let (work, version, archive) = try await Task.detached(priority: .utility) {
            guard let (work, version) = try Self.storedWorkbenchInput(asset, fingerprint: fingerprint, store: store) else {
                throw EditingError.staleSource
            }
            return (work, version, try store.editingArchive())
        }.value
        try Task.checkCancellation()
        let renderer = RenderExportService()
        let cg: CGImage
        if maxPixel > 0 {
            cg = try await renderer.preview(work: work, version: version, archive: archive, maxPixel: maxPixel).image
        } else {
            cg = try await renderer.fullResolutionPreview(work: work, version: version, archive: archive)
        }
        try Task.checkCancellation()
        let photo = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if cacheable { renditionThumbnails.setObject(photo, forKey: key, cost: cg.bytesPerRow * cg.height) }
        return photo
    }
}
